import AVFoundation
import os

/// Compact 2-pole Chamberlin State-Variable Filter (zero allocations, real-time safe).
/// Shapes noise and impulses into warm resonant bodies instead of raw white-noise static.
private struct SVF {
    var lp: Float = 0
    var bp: Float = 0

    /// Processes one sample with normalized frequency `f` (~2*sin(pi*fc/sr), clamped < 0.85)
    /// and damping `q` (smaller = more resonant, e.g. 0.15...1.2).
    @inline(__always)
    mutating func process(_ input: Float, f: Float, q: Float) -> (lp: Float, bp: Float, hp: Float) {
        let hp = input - lp - q * bp
        bp += f * hp
        lp += f * bp
        // Gentle safety clamp prevents numerical blowup at extreme modulation.
        bp = clamp(bp, -8, 8)
        lp = clamp(lp, -8, 8)
        return (lp, bp, hp)
    }
}

/// Real-time procedural stereo soundscape for Alpine Express:
/// - Warm resonant steam locomotive (deep cylinder chuffs, boiler simmer, air pump, valve rhythm)
/// - Metallic steel-on-steel bogie clickety-clack & viaduct/tunnel rolling acoustics
/// - Expressive 3-chime brass steam whistle with pitch scoop & stereo alpine/tunnel echo
/// - Realistic air brakes & pneumatic stop release
/// - Living alpine environment (songbirds by day, crickets at night, pine breeze, raindrop patter, rolling thunder)
/// - Harmonic Swiss station departure bell
final class TrainAudio {
    private struct Params {
        var speed: Float = 0        // metres per second
        var power: Float = 0        // 0...1, engine effort
        var brake: Float = 0        // 0...1, braking force
        var hornOn = false
        var rain: Float = 0
        var wind: Float = 0
        var night: Float = 0        // 0 = day, 1 = night
        var viaduct: Float = 0      // 0...1, bridge resonance
        var tunnel: Float = 0       // 0...1, enclosed tunnel acoustics
        var thunderRequests: UInt32 = 0
        var bellRequests: UInt32 = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Params())
    private var audioSnapshot = Params()

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sampleRate: Float = 48000

    // Synth state — touched exclusively by the audio render thread.
    private var seed: UInt32 = 0x1234_5678
    private var sSpeed: Float = 0, sPower: Float = 0, sBrake: Float = 0
    private var sRain: Float = 0, sWind: Float = 0, sNight: Float = 0
    private var sViaduct: Float = 0, sTunnel: Float = 0
    private var wasBrakingMoving = false

    // 1. Steam locomotive (deep exhaust chuff + breathy valve puff + boiler simmer + idle air pump)
    private var chuffPhase: Float = 0
    private var chuffIndex = 0
    private var chuffBodyEnv: Float = 0
    private var chuffPuffEnv: Float = 0
    private var chuffClickEnv: Float = 0
    private var chuffBodyFilter = SVF()
    private var chuffPuffFilter = SVF()
    private var chuffSubPhase: Float = 0
    private var simmerFilter = SVF()
    private var airPumpTimer: Float = 1.4
    private var airPumpEnv: Float = 0
    private var airPumpPhase: Float = 0

    // 2. Steel rail rolling hum & paired metallic bogie clickety-clack
    private var rollFilterL = SVF()
    private var rollFilterR = SVF()
    private var tunnelResFilter = SVF()
    private var jointPhase: Float = 0
    private var bogieStep = 0
    private var bogieTimer = 0
    private var clackEnv: Float = 0
    private var clackPan: Float = 1
    private var clackP1: Float = 0, clackP2: Float = 0, clackP3: Float = 0
    private var clackPingFilter = SVF()

    // 3. Air brakes & pneumatic stop release
    private var brakeAirFilter = SVF()
    private var brakeP1: Float = 0, brakeP2: Float = 0
    private var airReleaseEnv: Float = 0
    private var airReleaseFilter = SVF()

    // 4. Three-chime brass steam whistle + stereo alpine valley / tunnel echo
    private var hornEnv: Float = 0
    private var hornPitchEnv: Float = 0
    private var hornP0: Float = 0, hornP1: Float = 0, hornP2: Float = 0
    private var hornVib: Float = 0
    private var hornWarmFilter = SVF()
    private var hornChiffFilter = SVF()

    private let echoMask = 32767
    private var echoBuf = [Float](repeating: 0, count: 32768)
    private var echoWrite = 0
    private var echoLP: Float = 0

    // 5. Swiss station departure bell (inharmonic brass partials)
    private var bellHandled: UInt32 = 0
    private var bellEnv1: Float = 0, bellEnv2: Float = 0
    private var bellDelay = 0
    private var bellP1a: Float = 0, bellP1b: Float = 0, bellP1c: Float = 0
    private var bellP2a: Float = 0, bellP2b: Float = 0, bellP2c: Float = 0

    // 6. Alpine environment: pine breeze, organic raindrops, rolling thunder, daytime songbirds, night crickets
    private var breezeFilterL = SVF()
    private var breezeFilterR = SVF()
    private var breezeLFO: Float = 0
    private var rainBedFilterL = SVF()
    private var rainBedFilterR = SVF()
    private var dropEnvL: Float = 0, dropEnvR: Float = 0
    private var dropFreqL: Float = 1400, dropFreqR: Float = 1600
    private var dropPhaseL: Float = 0, dropPhaseR: Float = 0

    private var thunderHandled: UInt32 = 0
    private var thunderEnv: Float = 0
    private var thunderCrackEnv: Float = 0
    private var thunderFilter = SVF()

    // Daytime alpine songbird synthesizer (occasional cheerful stereo melodic chirps)
    private var birdTimer: Float = 1.8
    private var birdNotesLeft = 0
    private var birdNoteEnv: Float = 0
    private var birdNoteTime: Float = 0
    private var birdNoteDur: Float = 0.14
    private var birdBaseFreq: Float = 2800
    private var birdSweep: Float = 600
    private var birdPhase: Float = 0
    private var birdPan: Float = 0.5 // 0 = left, 1 = right

    // Nighttime alpine crickets (soft stereo rhythmic 4.1 kHz pulses)
    private var cricketPhase: Float = 0
    private var cricketChirpPhase: Float = 0
    private var cricketPulsePhase: Float = 0

    func update(speed: Float, power: Float, brake: Float, hornOn: Bool,
                rain: Float, wind: Float, night: Float, viaduct: Float, tunnel: Float) {
        shared.withLock { state in
            state.speed = speed
            state.power = power
            state.brake = brake
            state.hornOn = hornOn
            state.rain = rain
            state.wind = wind
            state.night = night
            state.viaduct = viaduct
            state.tunnel = tunnel
        }
    }

    func thunder() {
        shared.withLock { $0.thunderRequests &+= 1 }
    }

    func playDepartureBell() {
        shared.withLock { $0.bellRequests &+= 1 }
    }

    func start(muted: Bool = false) {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let typeVal = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: typeVal) == .ended else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.engine.start()
        }
        #endif

        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = hardwareRate > 0 ? hardwareRate : 48000
        sampleRate = Float(rate)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }

        let node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            if let fresh = self.shared.withLockIfAvailable({ $0 }) {
                self.audioSnapshot = fresh
            }
            let p = self.audioSnapshot
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            let count = Int(frameCount)
            if buffers.count >= 2,
               let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
               let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<count {
                    let (l, r) = self.nextStereoSample(p)
                    left[frame] = l
                    right[frame] = r
                }
            } else if let mono = buffers.first?.mData?.assumingMemoryBound(to: Float.self) {
                for frame in 0..<count {
                    let (l, r) = self.nextStereoSample(p)
                    mono[frame] = (l + r) * 0.5
                }
            }
            return noErr
        }
        source = node
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = muted ? 0 : 0.85
        do { try engine.start() } catch { print("Audio failed to start: \(error)") }
    }

    func nextSample() -> Float {
        let p = shared.withLock { $0 }
        let (l, r) = nextStereoSample(p)
        return (l + r) * 0.5
    }

    @inline(__always)
    private func nextWhite() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(Int32(bitPattern: seed)) * (1.0 / 2_147_483_648.0)
    }

    @inline(__always)
    private func rand01() -> Float {
        seed ^= seed << 13
        seed ^= seed >> 17
        seed ^= seed << 5
        return Float(seed & 0x00FF_FFFF) * (1.0 / 16_777_216.0)
    }

    @inline(__always)
    private func freqCoeff(_ hz: Float) -> Float {
        min(6.2831853 * hz / sampleRate, 0.82)
    }

    /// Generates 4 warm harmonics using Chebyshev identities from a single sin/cos pair.
    @inline(__always)
    private func whistleVoice(_ phase: Float) -> Float {
        let a = 6.2831853 * phase
        let s1 = sin(a)
        let c1 = cos(a)
        let c2 = 2 * c1 * c1 - 1
        let s2 = 2 * s1 * c1
        let s3 = s1 * (4 * c1 * c1 - 1)
        let s4 = 2 * s2 * c2
        return s1 + 0.42 * s2 + 0.22 * s3 + 0.09 * s4
    }

    private func nextStereoSample(_ p: Params) -> (Float, Float) {
        let dt = 1.0 / sampleRate
        let whiteL = nextWhite()
        let whiteR = nextWhite()
        let white = (whiteL + whiteR) * 0.5

        sSpeed += (p.speed - sSpeed) * 0.0008
        sPower += (p.power - sPower) * 0.0005
        sBrake += (p.brake - sBrake) * 0.0008
        sRain += (p.rain - sRain) * 0.0002
        sWind += (p.wind - sWind) * 0.0002
        sNight += (p.night - sNight) * 0.0001
        sViaduct += (p.viaduct - sViaduct) * 0.0003
        sTunnel += (p.tunnel - sTunnel) * 0.0003

        var outL: Float = 0
        var outR: Float = 0

        // =====================================================================
        // 1. STEAM LOCOMOTIVE: Punchy resonant exhaust chuffs + warm boiler simmer + idle air pump
        // =====================================================================
        if sSpeed > 0.15 {
            // 4 exhaust beats per wheel revolution (0.8m driving wheel radius -> circumference 5.03m).
            let revRate = sSpeed / 5.03
            let chuffRate = max(0.8, revRate * 4.0)
            chuffPhase += chuffRate * dt
            if chuffPhase >= 1 {
                chuffPhase -= 1
                chuffIndex = (chuffIndex + 1) & 3
                let accent: Float = chuffIndex == 0 ? 1.0 : (chuffIndex == 2 ? 0.86 : 0.72)
                chuffBodyEnv = accent
                chuffPuffEnv = accent
                if chuffIndex == 0 || chuffIndex == 2 {
                    chuffClickEnv = 0.45
                }
            }

            // Sharp separation at low speeds, blending gently into a rhythmic steam thrum at cruise speed.
            let decayRate = max(9.5, chuffRate * 5.2)
            chuffBodyEnv *= max(0, 1 - decayRate * dt)
            chuffPuffEnv *= max(0, 1 - (decayRate * 0.72) * dt)
            chuffClickEnv *= max(0, 1 - 120 * dt)

            // Deep cylinder chest thump (~85-135 Hz pitched body + resonant low bandpass)
            let bodyFreq: Float = 82 + min(sSpeed * 2.2, 42) + sPower * 22
            chuffSubPhase += bodyFreq * dt
            if chuffSubPhase >= 1 { chuffSubPhase -= 1 }
            let subThump = sin(6.2831853 * chuffSubPhase) * chuffBodyEnv * chuffBodyEnv * 0.24
            let bodyNoise = chuffBodyFilter.process(white, f: freqCoeff(165 + sPower * 80), q: 0.45).bp * chuffBodyEnv * 0.42

            // Warm breathy steam puff (~420-680 Hz bandpass — NO harsh high-frequency static!)
            let puff = chuffPuffFilter.process(white, f: freqCoeff(440 + sPower * 220), q: 0.55).bp * chuffPuffEnv * 0.20

            // Subtle iron valve-gear click on main strokes
            let rodClick = sin(6.2831853 * chuffSubPhase * 3.7) * chuffClickEnv * 0.035

            // Reduce chuff volume smoothly when coasting at speed (like a real closed-regulator steam engine).
            let effort = 0.14 + 0.86 * sPower
            let speedTame = 1.0 / (1.0 + sSpeed * 0.035)
            let locoSig = (subThump + bodyNoise + puff + rodClick) * effort * speedTame * (1 + sTunnel * 0.25)
            outL += locoSig
            outR += locoSig
        } else {
            chuffBodyEnv *= 0.992
            chuffPuffEnv *= 0.992
        }

        // Warm low-frequency boiler simmer & gentle Westinghouse air-pump pulse when idling at a station.
        let idleAmt = max(0, 1 - sSpeed / 4.0)
        if idleAmt > 0.01 {
            let simmer = simmerFilter.process(white, f: freqCoeff(190), q: 0.7).lp * 0.045 * idleAmt
            airPumpTimer -= dt
            if airPumpTimer <= 0 {
                airPumpTimer = 2.1 + rand01() * 0.9
                airPumpEnv = 1.0
            }
            var pumpSig: Float = 0
            if airPumpEnv > 0.001 {
                airPumpEnv *= max(0, 1 - 14 * dt)
                airPumpPhase += 145 * dt
                if airPumpPhase >= 1 { airPumpPhase -= 1 }
                pumpSig = sin(6.2831853 * airPumpPhase) * airPumpEnv * 0.032 * idleAmt
            }
            outL += simmer + pumpSig
            outR += simmer + pumpSig
        }

        // =====================================================================
        // 2. STEEL RAILS: Warm low rolling hum + paired metallic bogie "da-dum, da-dum"
        // =====================================================================
        if sSpeed > 0.1 {
            let speedNorm = min(sSpeed / 20.0, 1.0)
            // Deep, warm rail bed resonance (65-115 Hz low-pass — zero fizz)
            let rollCut: Float = 72 + speedNorm * 45 + sViaduct * 55 + sTunnel * 35
            let rL = rollFilterL.process(whiteL, f: freqCoeff(rollCut), q: 0.65).lp
            let rR = rollFilterR.process(whiteR, f: freqCoeff(rollCut), q: 0.65).lp
            let rollGain = speedNorm * (0.28 + sViaduct * 0.22 + sTunnel * 0.36)
            outL += rL * rollGain
            outR += rR * rollGain

            // Hollow tunnel cavern air resonance (~140 Hz)
            if sTunnel > 0.02 {
                let cav = tunnelResFilter.process(white, f: freqCoeff(138), q: 0.22).bp * sTunnel * speedNorm * 0.18
                outL += cav
                outR += cav
            }

            // Paired bogie rail-joint rhythm: two axles close together, then next bogie!
            jointPhase += sSpeed * dt / 18.0
            if jointPhase >= 1 {
                jointPhase -= 1
                bogieStep = 1
                clackEnv = 1.0
                clackPan = -clackPan
                bogieTimer = Int(1.8 / max(sSpeed, 1.0) * sampleRate)
            }
            if bogieTimer > 0 {
                bogieTimer -= 1
                if bogieTimer == 0 {
                    if bogieStep == 1 {
                        // Second axle of first bogie
                        clackEnv = 0.85
                        bogieStep = 2
                        bogieTimer = Int(4.4 / max(sSpeed, 1.0) * sampleRate)
                    } else if bogieStep == 2 {
                        // First axle of trailing bogie
                        clackEnv = 0.78
                        clackPan = -clackPan
                        bogieStep = 3
                        bogieTimer = Int(1.8 / max(sSpeed, 1.0) * sampleRate)
                    } else if bogieStep == 3 {
                        // Second axle of trailing bogie
                        clackEnv = 0.68
                        bogieStep = 0
                    }
                }
            }
            if clackEnv > 0.0005 {
                clackEnv *= max(0, 1 - 68 * dt)
                let bridgePitch: Float = 1.0 + sViaduct * 0.18
                clackP1 += 185 * bridgePitch * dt; if clackP1 >= 1 { clackP1 -= 1 }
                clackP2 += 420 * bridgePitch * dt; if clackP2 >= 1 { clackP2 -= 1 }
                clackP3 += 890 * bridgePitch * dt; if clackP3 >= 1 { clackP3 -= 1 }
                let steelRing = sin(6.2831853 * clackP1) * 0.55
                    + sin(6.2831853 * clackP2) * 0.30
                    + sin(6.2831853 * clackP3) * 0.15
                let thud = clackPingFilter.process(white, f: freqCoeff(260), q: 0.45).bp * 0.45
                let clack = (steelRing + thud) * clackEnv * 0.17 * min(sSpeed / 3.5, 1) * (1 + sViaduct * 0.35 + sTunnel * 0.3)
                outL += clack * (clackPan > 0 ? 1.15 : 0.85)
                outR += clack * (clackPan > 0 ? 0.85 : 1.15)
            }
        }

        // =====================================================================
        // 3. AIR BRAKES: Metallic brake-shoe resonance + pneumatic stop sigh
        // =====================================================================
        if sBrake > 0.08 && sSpeed > 0.4 {
            wasBrakingMoving = true
            let brakeAmt = sBrake * min(sSpeed / 5.0, 1.0)
            // Narrow resonant metallic brake-shoe hum (warm, musical, never screechy static)
            let squealWindow = smoothstep(0.4, 5.5, sSpeed) * (1 - smoothstep(9.0, 18.0, sSpeed))
            brakeP1 += (1180 - sSpeed * 10) * dt; if brakeP1 >= 1 { brakeP1 -= 1 }
            brakeP2 += (1775 - sSpeed * 14) * dt; if brakeP2 >= 1 { brakeP2 -= 1 }
            let shoe = (sin(6.2831853 * brakeP1) * 0.65 + sin(6.2831853 * brakeP2) * 0.35) * 0.022 * squealWindow
            let air = brakeAirFilter.process(white, f: freqCoeff(750), q: 0.45).bp * 0.032
            let sig = (shoe + air) * brakeAmt
            outL += sig
            outR += sig
        } else if wasBrakingMoving && sSpeed < 0.25 {
            wasBrakingMoving = false
            airReleaseEnv = 1.0
        }
        if airReleaseEnv > 0.001 {
            airReleaseEnv *= max(0, 1 - 4.2 * dt)
            let sweepHz = 450 + airReleaseEnv * 900
            let puff = airReleaseFilter.process(white, f: freqCoeff(sweepHz), q: 0.55).bp * airReleaseEnv * 0.075
            outL += puff
            outR += puff
        }

        // =====================================================================
        // 4. THREE-CHIME BRASS STEAM WHISTLE + STEREO ALPINE VALLEY / TUNNEL ECHO
        // =====================================================================
        let hornTarget: Float = p.hornOn ? 1 : 0
        hornEnv += (hornTarget - hornEnv) * (hornTarget > hornEnv ? 0.0024 : 0.0005)
        hornPitchEnv += (hornTarget - hornPitchEnv) * (hornTarget > hornPitchEnv ? 0.0009 : 0.00035)
        var dryHorn: Float = 0
        if hornEnv > 0.0005 {
            hornVib += 5.1 * dt
            if hornVib >= 1 { hornVib -= 1 }
            // Authentic steam chamber pitch scoop up on attack + gentle breath vibrato
            let scoop: Float = 0.972 + 0.028 * hornPitchEnv
            let pitchMod: Float = scoop * (1.0 + 0.0022 * sin(6.2831853 * hornVib))
            hornP0 += 311.13 * pitchMod * dt; if hornP0 >= 1 { hornP0 -= 1 } // Eb4
            hornP1 += 369.99 * pitchMod * dt; if hornP1 >= 1 { hornP1 -= 1 } // Gb4
            hornP2 += 466.16 * pitchMod * dt; if hornP2 >= 1 { hornP2 -= 1 } // Bb4
            let rawChord = whistleVoice(hornP0) + whistleVoice(hornP1) * 0.92 + whistleVoice(hornP2) * 0.82
            let warmChord = hornWarmFilter.process(tanh(rawChord * 0.48), f: freqCoeff(1450), q: 0.85).lp
            let breath = hornChiffFilter.process(white, f: freqCoeff(1150), q: 0.35).bp * 0.055
            dryHorn = (warmChord + breath) * hornEnv * 0.34
            outL += dryHorn
            outR += dryHorn
        }

        // Warmly low-passed stereo alpine valley / tunnel echo line
        let delayL = min(Int(sampleRate * (0.36 - sTunnel * 0.18)), echoMask - 1)
        let delayR = min(Int(sampleRate * (0.52 - sTunnel * 0.24)), echoMask - 1)
        let tapL = echoBuf[(echoWrite - delayL) & echoMask]
        let tapR = echoBuf[(echoWrite - delayR) & echoMask]
        let echoFeedback = 0.28 + sTunnel * 0.30
        echoLP += ((tapL + tapR) * 0.5 - echoLP) * 0.09
        echoBuf[echoWrite] = dryHorn + echoLP * echoFeedback
        echoWrite = (echoWrite + 1) & echoMask
        let echoWet: Float = 0.24 + sTunnel * 0.28
        outL += tapL * echoWet
        outR += tapR * echoWet

        // =====================================================================
        // 5. SWISS STATION DEPARTURE BELL (warm brass inharmonic partials)
        // =====================================================================
        if p.bellRequests != bellHandled {
            bellHandled = p.bellRequests
            bellEnv1 = 1.0
            bellDelay = Int(sampleRate * 0.28)
        }
        if bellDelay > 0 {
            bellDelay -= 1
            if bellDelay == 0 { bellEnv2 = 0.92 }
        }
        if bellEnv1 > 0.0005 || bellEnv2 > 0.0005 {
            var b: Float = 0
            if bellEnv1 > 0.0005 {
                bellP1a += 659.25 * dt; if bellP1a >= 1 { bellP1a -= 1 }
                bellP1b += 1318.5 * dt; if bellP1b >= 1 { bellP1b -= 1 }
                bellP1c += 1819.5 * dt; if bellP1c >= 1 { bellP1c -= 1 }
                let tone = sin(6.2831853 * bellP1a) * 0.65
                    + sin(6.2831853 * bellP1b) * 0.25 * bellEnv1
                    + sin(6.2831853 * bellP1c) * 0.14 * bellEnv1 * bellEnv1
                b += tone * bellEnv1
                bellEnv1 *= max(0, 1 - 2.1 * dt)
            }
            if bellEnv2 > 0.0005 {
                bellP2a += 554.37 * dt; if bellP2a >= 1 { bellP2a -= 1 }
                bellP2b += 1108.7 * dt; if bellP2b >= 1 { bellP2b -= 1 }
                bellP2c += 1530.0 * dt; if bellP2c >= 1 { bellP2c -= 1 }
                let tone = sin(6.2831853 * bellP2a) * 0.65
                    + sin(6.2831853 * bellP2b) * 0.25 * bellEnv2
                    + sin(6.2831853 * bellP2c) * 0.14 * bellEnv2 * bellEnv2
                b += tone * bellEnv2
                bellEnv2 *= max(0, 1 - 1.65 * dt)
            }
            outL += b * 0.14
            outR += b * 0.16
        }

        // =====================================================================
        // 6. ALPINE ENVIRONMENT: Musical pine breeze, organic raindrops, songbirds, crickets, thunder
        // =====================================================================
        let exterior = 1 - sTunnel * 0.82

        // Soft sweeping pine-forest breeze (narrow resonant bandpass, zero harsh static)
        breezeLFO += 0.09 * dt
        if breezeLFO >= 1 { breezeLFO -= 1 }
        let gust = 0.5 + 0.5 * sin(6.2831853 * breezeLFO)
        if sWind > 0.08 {
            let breezeAmt = max(0, sWind - 0.06) * exterior
            let bFreqL = 240 + gust * 190
            let bFreqR = 265 + (1 - gust) * 175
            let bL = breezeFilterL.process(whiteL, f: freqCoeff(bFreqL), q: 0.35).bp
            let bR = breezeFilterR.process(whiteR, f: freqCoeff(bFreqR), q: 0.35).bp
            let gain = breezeAmt * (0.045 + 0.035 * gust)
            outL += bL * gain
            outR += bR * gain
        }

        // Organic rain: warm muffled backdrop + distinct stereo roof raindrop patters
        if sRain > 0.02 {
            let rAmt = min(sRain, 1.6) * exterior
            let bedL = rainBedFilterL.process(whiteL, f: freqCoeff(680), q: 0.85).bp
            let bedR = rainBedFilterR.process(whiteR, f: freqCoeff(740), q: 0.85).bp
            outL += bedL * rAmt * 0.038
            outR += bedR * rAmt * 0.038

            // Random micro raindrop plinks on coach roof & windows
            let dropProb = rAmt * 18.0 * dt
            if dropEnvL < 0.05 && rand01() < dropProb {
                dropEnvL = 0.5 + rand01() * 0.5
                dropFreqL = 950 + rand01() * 1100
            }
            if dropEnvR < 0.05 && rand01() < dropProb {
                dropEnvR = 0.5 + rand01() * 0.5
                dropFreqR = 950 + rand01() * 1100
            }
            if dropEnvL > 0.002 {
                dropEnvL *= max(0, 1 - 85 * dt)
                dropPhaseL += dropFreqL * dt; if dropPhaseL >= 1 { dropPhaseL -= 1 }
                outL += sin(6.2831853 * dropPhaseL) * dropEnvL * 0.024 * rAmt
            }
            if dropEnvR > 0.002 {
                dropEnvR *= max(0, 1 - 85 * dt)
                dropPhaseR += dropFreqR * dt; if dropPhaseR >= 1 { dropPhaseR -= 1 }
                outR += sin(6.2831853 * dropPhaseR) * dropEnvR * 0.024 * rAmt
            }
        }

        // Daytime alpine songbirds (cheerful distant stereo chirps in calm weather outside the tunnel)
        let calmDay = max(0, 1 - sNight * 1.4) * max(0, 1 - sRain * 2.0) * exterior
        if calmDay > 0.1 {
            if birdNotesLeft == 0 {
                birdTimer -= dt
                if birdTimer <= 0 {
                    birdTimer = 2.6 + rand01() * 4.8
                    birdNotesLeft = 2 + Int(rand01() * 2.9)
                    birdBaseFreq = 2250 + rand01() * 1250
                    birdPan = 0.15 + rand01() * 0.70
                    birdNoteEnv = 1.0
                    birdNoteTime = 0
                    birdNoteDur = 0.09 + rand01() * 0.08
                    birdSweep = (rand01() > 0.45 ? 1 : -1) * (350 + rand01() * 650)
                }
            } else {
                birdNoteTime += dt
                if birdNoteTime < birdNoteDur {
                    let u = birdNoteTime / birdNoteDur
                    let env = sin(Float.pi * u) * sin(Float.pi * u)
                    let freq = birdBaseFreq + birdSweep * sin(Float.pi * u * 0.85)
                    birdPhase += freq * dt; if birdPhase >= 1 { birdPhase -= 1 }
                    let chirp = sin(6.2831853 * birdPhase) * env * 0.026 * calmDay
                    outL += chirp * (1.0 - birdPan) * 1.3
                    outR += chirp * birdPan * 1.3
                } else if birdNoteTime >= birdNoteDur + 0.065 {
                    birdNotesLeft -= 1
                    birdNoteTime = 0
                    birdBaseFreq = clamp(birdBaseFreq + (rand01() - 0.5) * 420, 2100, 3800)
                    birdSweep = (rand01() > 0.5 ? 1 : -1) * (300 + rand01() * 550)
                }
            }
        }

        // Nighttime alpine crickets (soft, peaceful stereo evening chorus)
        let calmNight = smoothstep(0.35, 0.8, sNight) * max(0, 1 - sRain * 2.0) * exterior
        if calmNight > 0.02 {
            cricketChirpPhase += 1.45 * dt; if cricketChirpPhase >= 1 { cricketChirpPhase -= 1 }
            cricketPulsePhase += 28.0 * dt; if cricketPulsePhase >= 1 { cricketPulsePhase -= 1 }
            let burst = cricketChirpPhase < 0.34 ? sin(Float.pi * cricketChirpPhase / 0.34) : 0
            let pulse = max(0, sin(6.2831853 * cricketPulsePhase))
            cricketPhase += 4150 * dt; if cricketPhase >= 1 { cricketPhase -= 1 }
            let cSig = sin(6.2831853 * cricketPhase) * burst * pulse * 0.011 * calmNight
            outL += cSig * 1.15
            outR += cSig * 0.85
        }

        // Deep rolling alpine thunder (initial crack + resonant sub-bass 55 Hz roll)
        if p.thunderRequests != thunderHandled {
            thunderHandled = p.thunderRequests
            thunderEnv = 1.0
            thunderCrackEnv = 1.0
        }
        if thunderEnv > 0.001 {
            let rumble = thunderFilter.process(white, f: freqCoeff(62), q: 0.55).lp * thunderEnv * 0.52
            let crack = thunderCrackEnv > 0.005 ? (white * thunderCrackEnv * 0.08) : 0
            let tSig = (rumble + crack) * (1 - sTunnel * 0.5)
            outL += tSig
            outR += tSig * 0.94
            thunderEnv *= max(0, 1 - dt / 1.9)
            thunderCrackEnv *= max(0, 1 - 14 * dt)
        }

        return (clamp(outL, -1, 1), clamp(outR, -1, 1))
    }
}
