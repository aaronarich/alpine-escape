import AVFoundation
import os

/// Compact 2-pole Chamberlin State-Variable Filter (zero allocations, real-time safe).
private struct SVF {
    var lp: Float = 0
    var bp: Float = 0

    @inline(__always)
    mutating func process(_ input: Float, f: Float, q: Float) -> (lp: Float, bp: Float, hp: Float) {
        let hp = input - lp - q * bp
        bp += f * hp
        lp += f * bp
        bp = clamp(bp, -8, 8)
        lp = clamp(lp, -8, 8)
        return (lp, bp, hp)
    }
}

/// Real-time procedural stereo soundscape for Alpine Express & Tokyo Express:
/// - Distinct engines: punchy Steam chugga-chugga, musical Japanese Shinkansen VVVF inverter hum,
///   and deep Cargo Freight diesel-electric prime mover thrum
/// - Train-specific horns (brass steam chime, bright Japanese electric dual-tone, deep freight air horn)
/// - Metallic bogie clickety-clack, viaduct/tunnel acoustics, bubbly Train Wash spray
/// - Swiss station bell (Alps) & Tokyo Hassha departure melody (Tokyo)
/// - Living environment: songbirds by day, crickets at night, pine breeze, raindrops, rolling thunder
final class TrainAudio {
    private struct Params {
        var speed: Float = 0
        var power: Float = 0
        var brake: Float = 0
        var hornOn = false
        var rain: Float = 0
        var wind: Float = 0
        var night: Float = 0
        var viaduct: Float = 0
        var tunnel: Float = 0
        var wash: Float = 0
        var trainKind: Int = 0      // 0 = steam, 1 = bullet, 2 = freight
        var isUrban = false
        var thunderRequests: UInt32 = 0
        var bellRequests: UInt32 = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Params())
    private var audioSnapshot = Params()

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sampleRate: Float = 48000

    // Synth state — audio render thread only.
    private var seed: UInt32 = 0x1234_5678
    private var sSpeed: Float = 0, sPower: Float = 0, sBrake: Float = 0
    private var sRain: Float = 0, sWind: Float = 0, sNight: Float = 0
    private var sViaduct: Float = 0, sTunnel: Float = 0, sWash: Float = 0
    private var wasBrakingMoving = false

    // 1a. Steam locomotive (punchy pitched cylinder boom + tight resonant steam puff + side rod tap)
    private var chuffPhase: Float = 0
    private var chuffIndex = 0
    private var chuffBoomEnv: Float = 0
    private var chuffPuffEnv: Float = 0
    private var chuffRodEnv: Float = 0
    private var chuffBoomPhase: Float = 0
    private var chuffRodPhase: Float = 0
    private var chuffPuffFilter = SVF()
    private var simmerFilter = SVF()
    private var airPumpTimer: Float = 1.5
    private var airPumpEnv: Float = 0
    private var airPumpPhase: Float = 0

    // 1b. Shinkansen Bullet VVVF electric inverter & aerodynamic glide
    private var vvvfP1: Float = 0, vvvfP2: Float = 0, vvvfP3: Float = 0
    private var aeroFilterL = SVF(), aeroFilterR = SVF()

    // 1c. Freight diesel-electric prime mover
    private var dieselCylPhase: Float = 0
    private var dieselTonePhase: Float = 0
    private var dieselFilter = SVF()

    // 2. Steel rail rolling hum & paired metallic bogie clickety-clack
    private var rollFilterL = SVF(), rollFilterR = SVF()
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

    // 4. Train horn + stereo valley/city/tunnel echo
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

    // 5. Departure chime (2-tone Swiss bell in Alps, 4-note Hassha melody in Tokyo)
    private var bellHandled: UInt32 = 0
    private var melodyNotesLeft = 0
    private var melodyTimer: Float = 0
    private var melodyNoteIndex = 0
    private var melodyIsTokyo = false
    private var chimeEnv: Float = 0
    private var chimeFreq: Float = 659.25
    private var chimePa: Float = 0, chimePb: Float = 0, chimePc: Float = 0

    // 6. Drive-through Train Wash (bubbly water spray + spinning brush swish)
    private var washFilterL = SVF(), washFilterR = SVF()
    private var washBrushLFO: Float = 0
    private var bubbleEnv: Float = 0
    private var bubbleFreq: Float = 650
    private var bubblePhase: Float = 0

    // 7. Environment: breeze, raindrops, thunder, songbirds, crickets
    private var breezeFilterL = SVF(), breezeFilterR = SVF()
    private var breezeLFO: Float = 0
    private var rainBedFilterL = SVF(), rainBedFilterR = SVF()
    private var dropEnvL: Float = 0, dropEnvR: Float = 0
    private var dropFreqL: Float = 1400, dropFreqR: Float = 1600
    private var dropPhaseL: Float = 0, dropPhaseR: Float = 0

    private var thunderHandled: UInt32 = 0
    private var thunderEnv: Float = 0
    private var thunderCrackEnv: Float = 0
    private var thunderFilter = SVF()

    private var birdTimer: Float = 1.8
    private var birdNotesLeft = 0
    private var birdNoteTime: Float = 0
    private var birdNoteDur: Float = 0.14
    private var birdBaseFreq: Float = 2800
    private var birdSweep: Float = 600
    private var birdPhase: Float = 0
    private var birdPan: Float = 0.5

    private var cricketPhase: Float = 0
    private var cricketChirpPhase: Float = 0
    private var cricketPulsePhase: Float = 0

    func update(speed: Float, power: Float, brake: Float, hornOn: Bool,
                rain: Float, wind: Float, night: Float, viaduct: Float,
                tunnel: Float, wash: Float, trainKind: TrainKind, isUrban: Bool) {
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
            state.wash = wash
            state.trainKind = trainKind.rawValue
            state.isUrban = isUrban
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
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(Int32(bitPattern: seed)) * (1.0 / 2_147_483_648.0)
    }

    @inline(__always)
    private func rand01() -> Float {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
        return Float(seed & 0x00FF_FFFF) * (1.0 / 16_777_216.0)
    }

    @inline(__always)
    private func freqCoeff(_ hz: Float) -> Float {
        min(6.2831853 * hz / sampleRate, 0.82)
    }

    @inline(__always)
    private func whistleVoice(_ phase: Float) -> Float {
        let a = 6.2831853 * phase
        let s1 = sin(a), c1 = cos(a)
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
        sWash += (p.wash - sWash) * 0.0008

        var outL: Float = 0
        var outR: Float = 0

        // =====================================================================
        // 1. TRAIN PROPULSION (Distinct per train type!)
        // =====================================================================
        if p.trainKind == 0 {
            // --- STEAM EXPRESS: Punchy rhythmic "CHUGGA-CHUGGA" cylinder boom + tight warm puff ---
            if sSpeed > 0.12 {
                let chuffRate = max(0.9, (sSpeed / 5.03) * 4.0)
                chuffPhase += chuffRate * dt
                if chuffPhase >= 1 {
                    chuffPhase -= 1
                    chuffIndex = (chuffIndex + 1) & 3
                    let accent: Float = chuffIndex == 0 ? 1.0 : (chuffIndex == 2 ? 0.85 : 0.68)
                    chuffBoomEnv = accent
                    chuffPuffEnv = accent
                    chuffRodEnv = (chuffIndex == 0 || chuffIndex == 2) ? 0.65 : 0.25
                }

                // Crisp beat separation: rapid decay keeps every chug distinct instead of blurring into noise.
                let boomDecay = max(16.0, chuffRate * 7.5)
                let puffDecay = max(13.0, chuffRate * 6.5)
                chuffBoomEnv *= max(0, 1 - boomDecay * dt)
                chuffPuffEnv *= max(0, 1 - puffDecay * dt)
                chuffRodEnv *= max(0, 1 - 90 * dt)

                // Pitched cylinder chest thump (sweeps 112 Hz -> 46 Hz on each exhaust beat!)
                let boomHz: Float = 46 + chuffBoomEnv * (66 + sPower * 24)
                chuffBoomPhase += boomHz * dt; if chuffBoomPhase >= 1 { chuffBoomPhase -= 1 }
                let boom = tanh(sin(6.2831853 * chuffBoomPhase) * 1.45) * chuffBoomEnv * 0.34

                // Tight low-mid steam chest exhalation (320-480 Hz resonant, strictly band-limited)
                let puff = chuffPuffFilter.process(white, f: freqCoeff(320 + sPower * 160), q: 0.42).bp * chuffPuffEnv * 0.22

                // Subtle iron connecting-rod clank
                chuffRodPhase += 340 * dt; if chuffRodPhase >= 1 { chuffRodPhase -= 1 }
                let rod = sin(6.2831853 * chuffRodPhase) * chuffRodEnv * 0.045

                let effort = 0.20 + 0.80 * sPower
                let speedBalance = 1.0 / (1.0 + sSpeed * 0.028)
                let sig = (boom + puff + rod) * effort * speedBalance * (1 + sTunnel * 0.25)
                outL += sig; outR += sig
            } else {
                chuffBoomEnv *= 0.99; chuffPuffEnv *= 0.99
            }

            // Quiet warm boiler simmer + gentle idle Westinghouse air pump when stopped
            let idleAmt = max(0, 1 - sSpeed / 3.5)
            if idleAmt > 0.01 {
                let simmer = simmerFilter.process(white, f: freqCoeff(165), q: 0.7).lp * 0.032 * idleAmt
                airPumpTimer -= dt
                if airPumpTimer <= 0 {
                    airPumpTimer = 2.2 + rand01() * 0.9
                    airPumpEnv = 1.0
                }
                var pump: Float = 0
                if airPumpEnv > 0.001 {
                    airPumpEnv *= max(0, 1 - 15 * dt)
                    airPumpPhase += 135 * dt; if airPumpPhase >= 1 { airPumpPhase -= 1 }
                    pump = sin(6.2831853 * airPumpPhase) * airPumpEnv * 0.028 * idleAmt
                }
                outL += simmer + pump; outR += simmer + pump
            }

        } else if p.trainKind == 1 {
            // --- SHINKANSEN BULLET: Iconic rising-pitch Japanese VVVF electric inverter hum + sleek glide ---
            if sSpeed > 0.1 {
                let speedNorm = min(sSpeed / 56.0, 1.0)
                // Musical VVVF traction inverter whine (prominent while accelerating or braking!)
                let motorLoad = max(sPower, sBrake * 0.75) * (1 - smoothstep(0.45, 0.95, speedNorm) * 0.55)
                let baseHz: Float = 115 + min(sSpeed * 11.5, 420)
                vvvfP1 += baseHz * dt; if vvvfP1 >= 1 { vvvfP1 -= 1 }
                vvvfP2 += (baseHz * 1.498) * dt; if vvvfP2 >= 1 { vvvfP2 -= 1 } // musical fifth harmonic
                vvvfP3 += (baseHz * 2.0) * dt; if vvvfP3 >= 1 { vvvfP3 -= 1 }
                let inverter = (sin(6.2831853 * vvvfP1) * 0.55
                                + sin(6.2831853 * vvvfP2) * 0.25
                                + sin(6.2831853 * vvvfP3) * 0.16) * motorLoad * 0.11

                // Smooth high-speed aerodynamic whoosh above 80 km/h
                let aeroAmt = smoothstep(16, 54, sSpeed) * 0.065
                let aL = aeroFilterL.process(whiteL, f: freqCoeff(220 + speedNorm * 260), q: 0.55).bp * aeroAmt
                let aR = aeroFilterR.process(whiteR, f: freqCoeff(235 + speedNorm * 250), q: 0.55).bp * aeroAmt
                outL += inverter + aL
                outR += inverter + aR
            }

        } else {
            // --- CARGO FREIGHT: Deep rhythmic multi-cylinder diesel-electric prime mover thrum ---
            let rpm: Float = 13.5 + sPower * 24.0 + min(sSpeed * 0.35, 8.0)
            dieselCylPhase += rpm * dt; if dieselCylPhase >= 1 { dieselCylPhase -= 1 }
            let pulse = 0.55 + 0.45 * sin(6.2831853 * dieselCylPhase)
            let toneHz: Float = 44 + sPower * 42 + min(sSpeed * 0.8, 16)
            dieselTonePhase += toneHz * dt; if dieselTonePhase >= 1 { dieselTonePhase -= 1 }
            let dieselOsc = sin(6.2831853 * dieselTonePhase) * 0.60
                + sin(12.5663706 * dieselTonePhase) * 0.32
                + sin(18.8495559 * dieselTonePhase) * 0.18
            let grit = dieselFilter.process(white, f: freqCoeff(110 + sPower * 90), q: 0.5).bp * 0.18
            let load = 0.28 + 0.72 * sPower
            let sig = (tanh(dieselOsc * 1.3) * 0.18 + grit) * pulse * load
            outL += sig; outR += sig
        }

        // =====================================================================
        // 2. STEEL RAILS: Deep rolling hum + metallic 4-hit bogie "da-dum, da-dum"
        // =====================================================================
        if sSpeed > 0.1 {
            let speedNorm = min(sSpeed / 24.0, 1.0)
            let rollCut: Float = 68 + speedNorm * 45 + sViaduct * 55 + sTunnel * 35
            let rL = rollFilterL.process(whiteL, f: freqCoeff(rollCut), q: 0.65).lp
            let rR = rollFilterR.process(whiteR, f: freqCoeff(rollCut), q: 0.65).lp
            let bulletQuiet: Float = p.trainKind == 1 ? 0.68 : 1.0
            let rollGain = speedNorm * bulletQuiet * (0.24 + sViaduct * 0.22 + sTunnel * 0.36)
            outL += rL * rollGain
            outR += rR * rollGain

            if sTunnel > 0.02 {
                let cav = tunnelResFilter.process(white, f: freqCoeff(138), q: 0.22).bp * sTunnel * speedNorm * 0.18
                outL += cav; outR += cav
            }

            let railLength: Float = p.trainKind == 1 ? 24.0 : 18.0
            jointPhase += sSpeed * dt / railLength
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
                        clackEnv = 0.85; bogieStep = 2
                        bogieTimer = Int(4.4 / max(sSpeed, 1.0) * sampleRate)
                    } else if bogieStep == 2 {
                        clackEnv = 0.76; clackPan = -clackPan; bogieStep = 3
                        bogieTimer = Int(1.8 / max(sSpeed, 1.0) * sampleRate)
                    } else if bogieStep == 3 {
                        clackEnv = 0.66; bogieStep = 0
                    }
                }
            }
            if clackEnv > 0.0005 {
                clackEnv *= max(0, 1 - 72 * dt)
                let bridgePitch: Float = 1.0 + sViaduct * 0.18
                clackP1 += 188 * bridgePitch * dt; if clackP1 >= 1 { clackP1 -= 1 }
                clackP2 += 425 * bridgePitch * dt; if clackP2 >= 1 { clackP2 -= 1 }
                clackP3 += 890 * bridgePitch * dt; if clackP3 >= 1 { clackP3 -= 1 }
                let steelRing = sin(6.2831853 * clackP1) * 0.55
                    + sin(6.2831853 * clackP2) * 0.30
                    + sin(6.2831853 * clackP3) * 0.15
                let thud = clackPingFilter.process(white, f: freqCoeff(250), q: 0.45).bp * 0.38
                let clack = (steelRing + thud) * clackEnv * 0.17 * bulletQuiet * min(sSpeed / 3.5, 1) * (1 + sViaduct * 0.35 + sTunnel * 0.3)
                outL += clack * (clackPan > 0 ? 1.15 : 0.85)
                outR += clack * (clackPan > 0 ? 0.85 : 1.15)
            }
        }

        // =====================================================================
        // 3. AIR BRAKES & PNEUMATIC STOP RELEASE
        // =====================================================================
        if sBrake > 0.08 && sSpeed > 0.4 {
            wasBrakingMoving = true
            let brakeAmt = sBrake * min(sSpeed / 5.0, 1.0)
            let squealWindow = smoothstep(0.4, 5.5, sSpeed) * (1 - smoothstep(10.0, 20.0, sSpeed))
            brakeP1 += (1180 - sSpeed * 9) * dt; if brakeP1 >= 1 { brakeP1 -= 1 }
            brakeP2 += (1775 - sSpeed * 12) * dt; if brakeP2 >= 1 { brakeP2 -= 1 }
            let shoe = (sin(6.2831853 * brakeP1) * 0.65 + sin(6.2831853 * brakeP2) * 0.35) * 0.022 * squealWindow
            let air = brakeAirFilter.process(white, f: freqCoeff(720), q: 0.45).bp * 0.028
            let sig = (shoe + air) * brakeAmt
            outL += sig; outR += sig
        } else if wasBrakingMoving && sSpeed < 0.25 {
            wasBrakingMoving = false
            airReleaseEnv = 1.0
        }
        if airReleaseEnv > 0.001 {
            airReleaseEnv *= max(0, 1 - 4.4 * dt)
            let puff = airReleaseFilter.process(white, f: freqCoeff(420 + airReleaseEnv * 850), q: 0.55).bp * airReleaseEnv * 0.07
            outL += puff; outR += puff
        }

        // =====================================================================
        // 4. TRAIN-SPECIFIC HORN + STEREO VALLEY / TUNNEL ECHO
        // =====================================================================
        let hornTarget: Float = p.hornOn ? 1 : 0
        hornEnv += (hornTarget - hornEnv) * (hornTarget > hornEnv ? 0.0028 : 0.00055)
        hornPitchEnv += (hornTarget - hornPitchEnv) * (hornTarget > hornPitchEnv ? 0.0010 : 0.0004)
        var dryHorn: Float = 0
        if hornEnv > 0.0005 {
            hornVib += 5.0 * dt; if hornVib >= 1 { hornVib -= 1 }
            let scoop: Float = p.trainKind == 1 ? 1.0 : (0.974 + 0.026 * hornPitchEnv)
            let pitchMod: Float = scoop * (1.0 + (p.trainKind == 1 ? 0.0008 : 0.0022) * sin(6.2831853 * hornVib))

            let f0: Float, f1: Float, f2: Float
            if p.trainKind == 1 {
                // Sleek bright Japanese Shinkansen dual-tone electric chime (A4 + C#5 + A5)
                f0 = 440.0; f1 = 554.37; f2 = 880.0
            } else if p.trainKind == 2 {
                // Deep powerful freight diesel 3-chime air horn (Bb3 + D4 + F4)
                f0 = 233.08; f1 = 293.66; f2 = 349.23
            } else {
                // Classic warm Alpine brass steam whistle (Eb4 + Gb4 + Bb4)
                f0 = 311.13; f1 = 369.99; f2 = 466.16
            }
            hornP0 += f0 * pitchMod * dt; if hornP0 >= 1 { hornP0 -= 1 }
            hornP1 += f1 * pitchMod * dt; if hornP1 >= 1 { hornP1 -= 1 }
            hornP2 += f2 * pitchMod * dt; if hornP2 >= 1 { hornP2 -= 1 }
            let rawChord = whistleVoice(hornP0) + whistleVoice(hornP1) * 0.92 + whistleVoice(hornP2) * (p.trainKind == 1 ? 0.35 : 0.80)
            let cut: Float = p.trainKind == 1 ? 2100 : 1400
            let warmChord = hornWarmFilter.process(tanh(rawChord * 0.48), f: freqCoeff(cut), q: 0.85).lp
            let breath = p.trainKind == 0 ? hornChiffFilter.process(white, f: freqCoeff(1100), q: 0.35).bp * 0.05 : 0
            dryHorn = (warmChord + breath) * hornEnv * 0.34
            outL += dryHorn; outR += dryHorn
        }

        let delayL = min(Int(sampleRate * (0.36 - sTunnel * 0.18)), echoMask - 1)
        let delayR = min(Int(sampleRate * (0.52 - sTunnel * 0.24)), echoMask - 1)
        let tapL = echoBuf[(echoWrite - delayL) & echoMask]
        let tapR = echoBuf[(echoWrite - delayR) & echoMask]
        let echoFeedback = 0.28 + sTunnel * 0.30
        echoLP += ((tapL + tapR) * 0.5 - echoLP) * 0.09
        echoBuf[echoWrite] = dryHorn + echoLP * echoFeedback
        echoWrite = (echoWrite + 1) & echoMask
        let echoWet: Float = 0.24 + sTunnel * 0.28
        outL += tapL * echoWet; outR += tapR * echoWet

        // =====================================================================
        // 5. STATION DEPARTURE CHIME (Swiss Brass Bell / Tokyo Hassha Melody!)
        // =====================================================================
        if p.bellRequests != bellHandled {
            bellHandled = p.bellRequests
            melodyIsTokyo = p.isUrban
            melodyNoteIndex = 0
            melodyNotesLeft = p.isUrban ? 4 : 2
            melodyTimer = 0
        }
        if melodyNotesLeft > 0 {
            melodyTimer -= dt
            if melodyTimer <= 0 {
                if melodyIsTokyo {
                    // Cheerful 4-note Tokyo station Hassha melody (C5 -> E5 -> G5 -> C6)
                    let notes: [Float] = [523.25, 659.25, 783.99, 1046.50]
                    chimeFreq = notes[melodyNoteIndex % notes.count]
                    melodyTimer = 0.19
                } else {
                    // Warm 2-tone Swiss railway station bell (E5 -> C#5)
                    chimeFreq = melodyNoteIndex == 0 ? 659.25 : 554.37
                    melodyTimer = 0.29
                }
                chimeEnv = 1.0
                melodyNoteIndex += 1
                melodyNotesLeft -= 1
            }
        }
        if chimeEnv > 0.0005 {
            chimePa += chimeFreq * dt; if chimePa >= 1 { chimePa -= 1 }
            chimePb += chimeFreq * 2.0 * dt; if chimePb >= 1 { chimePb -= 1 }
            chimePc += chimeFreq * 2.76 * dt; if chimePc >= 1 { chimePc -= 1 }
            let bell = (sin(6.2831853 * chimePa) * 0.65
                        + sin(6.2831853 * chimePb) * 0.24 * chimeEnv
                        + sin(6.2831853 * chimePc) * 0.12 * chimeEnv * chimeEnv) * chimeEnv
            chimeEnv *= max(0, 1 - (melodyIsTokyo ? 3.2 : 1.9) * dt)
            outL += bell * 0.14
            outR += bell * 0.16
        }

        // =====================================================================
        // 6. DRIVE-THROUGH TRAIN WASH (bubbly water spray + spinning brushes!)
        // =====================================================================
        if sWash > 0.01 {
            washBrushLFO += 3.2 * dt; if washBrushLFO >= 1 { washBrushLFO -= 1 }
            let swish = 0.65 + 0.35 * sin(6.2831853 * washBrushLFO)
            let sprayL = washFilterL.process(whiteL, f: freqCoeff(850 + swish * 420), q: 0.45).bp
            let sprayR = washFilterR.process(whiteR, f: freqCoeff(920 + (1 - swish) * 400), q: 0.45).bp
            outL += sprayL * sWash * swish * 0.14
            outR += sprayR * sWash * swish * 0.14

            // Cheerful soapy bubble pops!
            if bubbleEnv < 0.05 && rand01() < sWash * 24.0 * dt {
                bubbleEnv = 0.7 + rand01() * 0.3
                bubbleFreq = 480 + rand01() * 520
            }
            if bubbleEnv > 0.005 {
                bubbleEnv *= max(0, 1 - 36 * dt)
                bubbleFreq += 1400 * dt // upward bubble pop chirp!
                bubblePhase += bubbleFreq * dt; if bubblePhase >= 1 { bubblePhase -= 1 }
                let pop = sin(6.2831853 * bubblePhase) * bubbleEnv * 0.045 * sWash
                outL += pop; outR += pop
            }
        }

        // =====================================================================
        // 7. LIVING ENVIRONMENT (Breeze, Raindrops, Birds, Crickets, Thunder)
        // =====================================================================
        let exterior = 1 - sTunnel * 0.82

        breezeLFO += 0.09 * dt; if breezeLFO >= 1 { breezeLFO -= 1 }
        let gust = 0.5 + 0.5 * sin(6.2831853 * breezeLFO)
        if sWind > 0.08 {
            let breezeAmt = max(0, sWind - 0.06) * exterior
            let bL = breezeFilterL.process(whiteL, f: freqCoeff(240 + gust * 190), q: 0.35).bp
            let bR = breezeFilterR.process(whiteR, f: freqCoeff(265 + (1 - gust) * 175), q: 0.35).bp
            let gain = breezeAmt * (0.042 + 0.032 * gust)
            outL += bL * gain; outR += bR * gain
        }

        if sRain > 0.02 {
            let rAmt = min(sRain, 1.6) * exterior
            let bedL = rainBedFilterL.process(whiteL, f: freqCoeff(680), q: 0.85).bp
            let bedR = rainBedFilterR.process(whiteR, f: freqCoeff(740), q: 0.85).bp
            outL += bedL * rAmt * 0.036; outR += bedR * rAmt * 0.036

            let dropProb = rAmt * 18.0 * dt
            if dropEnvL < 0.05 && rand01() < dropProb { dropEnvL = 0.5 + rand01() * 0.5; dropFreqL = 950 + rand01() * 1100 }
            if dropEnvR < 0.05 && rand01() < dropProb { dropEnvR = 0.5 + rand01() * 0.5; dropFreqR = 950 + rand01() * 1100 }
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

        // Daytime songbirds (stronger in Swiss Alps, softer in Tokyo parks)
        let calmDay = max(0, 1 - sNight * 1.4) * max(0, 1 - sRain * 2.0) * exterior * (p.isUrban ? 0.45 : 1.0)
        if calmDay > 0.1 {
            if birdNotesLeft == 0 {
                birdTimer -= dt
                if birdTimer <= 0 {
                    birdTimer = 2.6 + rand01() * 4.8
                    birdNotesLeft = 2 + Int(rand01() * 2.9)
                    birdBaseFreq = 2250 + rand01() * 1250
                    birdPan = 0.15 + rand01() * 0.70
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
                    let chirp = sin(6.2831853 * birdPhase) * env * 0.025 * calmDay
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

        // Nighttime alpine crickets (Alps only)
        let calmNight = smoothstep(0.35, 0.8, sNight) * max(0, 1 - sRain * 2.0) * exterior * (p.isUrban ? 0 : 1)
        if calmNight > 0.02 {
            cricketChirpPhase += 1.45 * dt; if cricketChirpPhase >= 1 { cricketChirpPhase -= 1 }
            cricketPulsePhase += 28.0 * dt; if cricketPulsePhase >= 1 { cricketPulsePhase -= 1 }
            let burst = cricketChirpPhase < 0.34 ? sin(Float.pi * cricketChirpPhase / 0.34) : 0
            let pulse = max(0, sin(6.2831853 * cricketPulsePhase))
            cricketPhase += 4150 * dt; if cricketPhase >= 1 { cricketPhase -= 1 }
            let cSig = sin(6.2831853 * cricketPhase) * burst * pulse * 0.011 * calmNight
            outL += cSig * 1.15; outR += cSig * 0.85
        }

        // Deep rolling thunder
        if p.thunderRequests != thunderHandled {
            thunderHandled = p.thunderRequests
            thunderEnv = 1.0
            thunderCrackEnv = 1.0
        }
        if thunderEnv > 0.001 {
            let rumble = thunderFilter.process(white, f: freqCoeff(62), q: 0.55).lp * thunderEnv * 0.52
            let crack = thunderCrackEnv > 0.005 ? (white * thunderCrackEnv * 0.08) : 0
            let tSig = (rumble + crack) * (1 - sTunnel * 0.5)
            outL += tSig; outR += tSig * 0.94
            thunderEnv *= max(0, 1 - dt / 1.9)
            thunderCrackEnv *= max(0, 1 - 14 * dt)
        }

        return (clamp(outL, -1, 1), clamp(outR, -1, 1))
    }
}
