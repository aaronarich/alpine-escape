import AVFoundation
import os

/// Real-time procedural stereo sound synthesizer for the steam train, rails, alpine echo whistle,
/// air brakes, viaduct/tunnel acoustics, departure bell, and weather — zero external audio files.
final class TrainAudio {
    private struct Params {
        var speed: Float = 0       // metres per second
        var power: Float = 0       // 0...1, engine effort
        var brake: Float = 0       // 0...1, braking force
        var hornOn = false
        var rain: Float = 0
        var wind: Float = 0
        var viaduct: Float = 0     // 0...1, bridge deck resonance
        var tunnel: Float = 0      // 0...1, enclosed mountain tunnel reverb & rumble
        var thunderRequests: UInt32 = 0
        var bellRequests: UInt32 = 0
    }

    // Lock protecting shared params; audio thread uses `withLockIfAvailable` once per buffer so it never blocks.
    private let shared = OSAllocatedUnfairLock(initialState: Params())
    private var audioSnapshot = Params()

    private let engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var sampleRate: Float = 48000
    private var muted = false

    // Synth state, touched exclusively by the audio render thread.
    private var seed: UInt32 = 0x1234_5678
    private var sSpeed: Float = 0, sPower: Float = 0, sBrake: Float = 0
    private var sRain: Float = 0, sWind: Float = 0
    private var sViaduct: Float = 0, sTunnel: Float = 0
    private var wasBrakingMoving = false

    private var chuffPhase: Float = 0
    private var chuffIndex = 0
    private var chuffEnv: Float = 0
    private var lpFast: Float = 0, lpSlow: Float = 0
    private var brownL: Float = 0, brownR: Float = 0

    private var jointPhase: Float = 0
    private var clackEnv: Float = 0
    private var clackDelay = 0
    private var clackPhase: Float = 0
    private var clackSide: Float = 1

    private var brakeHP: Float = 0
    private var brakeSquealPhase: Float = 0
    private var airReleaseEnv: Float = 0

    private var hornEnv: Float = 0
    private var hornP0: Float = 0, hornP1: Float = 0, hornP2: Float = 0
    private var hornVib: Float = 0

    // Fixed-size power-of-2 ring buffer for alpine valley & tunnel horn echo (no audio-thread allocations).
    private let echoMask = 32767
    private var echoBuf = [Float](repeating: 0, count: 32768)
    private var echoWrite = 0
    private var echoLP: Float = 0

    // Weather & thunder
    private var rainLPL: Float = 0, rainLPR: Float = 0
    private var windLPL: Float = 0, windLPR: Float = 0
    private var windLFO: Float = 0
    private var thunderHandled: UInt32 = 0
    private var thunderEnv: Float = 0
    private var thunderLP: Float = 0

    // Swiss station departure bell (two-tone E5 -> C#5 chime)
    private var bellHandled: UInt32 = 0
    private var bellEnv1: Float = 0, bellEnv2: Float = 0
    private var bellDelay = 0
    private var bellP1: Float = 0, bellP2: Float = 0

    func update(speed: Float, power: Float, brake: Float, hornOn: Bool,
                rain: Float, wind: Float, viaduct: Float, tunnel: Float) {
        shared.withLock { state in
            state.speed = speed
            state.power = power
            state.brake = brake
            state.hornOn = hornOn
            state.rain = rain
            state.wind = wind
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
        self.muted = muted
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

    /// Exposed so the synth can be checked without an audio device.
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

    /// Generates 4 harmonics using Chebyshev identities from a single sin/cos pair (5x faster than 5x sin).
    @inline(__always)
    private func whistleVoice(_ phase: Float) -> Float {
        let a = 6.2831853 * phase
        let s1 = sin(a)
        let c1 = cos(a)
        let c2 = 2 * c1 * c1 - 1
        let s2 = 2 * s1 * c1
        let s3 = s1 * (4 * c1 * c1 - 1)
        let s4 = 2 * s2 * c2
        return s1 + 0.50 * s2 + 0.32 * s3 + 0.17 * s4
    }

    private func nextStereoSample(_ p: Params) -> (Float, Float) {
        let dt = 1.0 / sampleRate
        let whiteL = nextWhite()
        let whiteR = nextWhite()
        let white = (whiteL + whiteR) * 0.5

        sSpeed += (p.speed - sSpeed) * 0.001
        sPower += (p.power - sPower) * 0.0005
        sBrake += (p.brake - sBrake) * 0.0008
        sRain += (p.rain - sRain) * 0.0002
        sWind += (p.wind - sWind) * 0.0002
        sViaduct += (p.viaduct - sViaduct) * 0.0003
        sTunnel += (p.tunnel - sTunnel) * 0.0003

        lpFast += (white - lpFast) * 0.16
        lpSlow += (white - lpSlow) * 0.012

        var outL: Float = 0
        var outR: Float = 0

        // 1. Steam exhaust chuffs (multiplicative decay — zero exp() per sample).
        if sSpeed > 0.15 {
            let rate = 1.2 + sSpeed * 0.42
            chuffPhase += rate * dt
            if chuffPhase >= 1 {
                chuffPhase -= 1
                chuffIndex = (chuffIndex + 1) & 3
                chuffEnv = chuffIndex == 0 ? 1.0 : 0.72
            }
            let attack = min(chuffPhase * 36, 1)
            chuffEnv *= max(0, 1 - rate * 5.8 * dt)
            let chuff = (lpFast - lpSlow) * attack * chuffEnv * (0.22 + 0.85 * sPower) * 1.15
            outL += chuff
            outR += chuff
        } else {
            chuffEnv *= 0.995
        }

        // 2. Idle boiler steam hiss.
        let idleHiss = (white - lpFast) * 0.012 * max(0, 1 - sSpeed / 3)
        outL += idleHiss
        outR += idleHiss

        // 3. Stereo rolling rumble + hollow viaduct resonance + deep enclosed tunnel roar.
        brownL = (brownL + whiteL * 0.03) * 0.997
        brownR = (brownR + whiteR * 0.03) * 0.997
        let rollGain = min(sSpeed / 18, 1) * (0.30 + sViaduct * 0.24 + sTunnel * 0.48)
        outL += brownL * rollGain
        outR += brownR * rollGain

        // 4. Rail joint clickety-clack with subtle stereo alternation.
        jointPhase += sSpeed * dt / 16
        if jointPhase >= 1 {
            jointPhase -= 1
            clackEnv = 1
            clackSide = -clackSide
            clackDelay = Int(2.2 / max(sSpeed, 1) * sampleRate)
        }
        if clackDelay > 0 {
            clackDelay -= 1
            if clackDelay == 0 { clackEnv = 0.85 }
        }
        if clackEnv > 0.0005 {
            clackEnv *= max(0, 1 - 55 * dt)
            clackPhase += (112 + sViaduct * 28) * dt
            if clackPhase >= 1 { clackPhase -= 1 }
            let clack = (sin(6.2831853 * clackPhase) * 0.5 + lpFast * 1.5) * clackEnv * 0.30 * min(sSpeed / 4, 1)
            let panL: Float = clackSide > 0 ? 1.12 : 0.88
            let panR: Float = clackSide > 0 ? 0.88 : 1.12
            outL += clack * panL
            outR += clack * panR
        }

        // 5. Air brakes & gentle pneumatic release puff when coming to a halt.
        if sBrake > 0.08 && sSpeed > 0.4 {
            wasBrakingMoving = true
            let hp = white - lpFast
            brakeHP += (hp - brakeHP) * 0.25
            let brakeAmt = sBrake * min(sSpeed / 6, 1)
            brakeSquealPhase += (1420 - sSpeed * 12) * dt
            if brakeSquealPhase >= 1 { brakeSquealPhase -= 1 }
            let squeal = sin(6.2831853 * brakeSquealPhase) * 0.016 * smoothstep(0.4, 8, sSpeed) * (1 - smoothstep(10, 18, sSpeed))
            let brakeSig = (brakeHP * 0.045 + squeal) * brakeAmt
            outL += brakeSig
            outR += brakeSig
        } else if wasBrakingMoving && sSpeed < 0.2 {
            wasBrakingMoving = false
            airReleaseEnv = 0.9
        }
        if airReleaseEnv > 0.001 {
            airReleaseEnv *= max(0, 1 - 3.6 * dt)
            let puff = (white - lpFast) * airReleaseEnv * 0.055
            outL += puff
            outR += puff
        }

        // 6. Three-note steam whistle with gentle breath vibrato & stereo alpine mountain / tunnel echo!
        let hornTarget: Float = p.hornOn ? 1 : 0
        hornEnv += (hornTarget - hornEnv) * (hornTarget > hornEnv ? 0.0022 : 0.00045)
        var dryHorn: Float = 0
        if hornEnv > 0.0005 {
            hornVib += 5.4 * dt
            if hornVib >= 1 { hornVib -= 1 }
            let pitchMod: Float = 1.0 + 0.0028 * sin(6.2831853 * hornVib)
            hornP0 += 311.1 * pitchMod * dt; if hornP0 >= 1 { hornP0 -= 1 }
            hornP1 += 370.0 * pitchMod * dt; if hornP1 >= 1 { hornP1 -= 1 }
            hornP2 += 466.2 * pitchMod * dt; if hornP2 >= 1 { hornP2 -= 1 }
            let chord = whistleVoice(hornP0) + whistleVoice(hornP1) + whistleVoice(hornP2)
            let chiff = (white - lpFast) * 0.14
            dryHorn = (tanh(chord * 0.56) + chiff) * hornEnv * 0.30
            outL += dryHorn
            outR += dryHorn
        }

        // Valley/tunnel stereo echo line fed by the whistle.
        let delayL = min(Int(sampleRate * (0.34 - sTunnel * 0.16)), echoMask - 1)
        let delayR = min(Int(sampleRate * (0.48 - sTunnel * 0.22)), echoMask - 1)
        let tapL = echoBuf[(echoWrite - delayL) & echoMask]
        let tapR = echoBuf[(echoWrite - delayR) & echoMask]
        let echoFeedback = 0.26 + sTunnel * 0.30
        echoLP += ((tapL + tapR) * 0.5 - echoLP) * 0.12
        echoBuf[echoWrite] = dryHorn + echoLP * echoFeedback
        echoWrite = (echoWrite + 1) & echoMask
        let echoWet: Float = 0.22 + sTunnel * 0.26
        outL += tapL * echoWet
        outR += tapR * echoWet

        // 7. Swiss station departure bell (warm two-tone E5 -> C#5 chime).
        if p.bellRequests != bellHandled {
            bellHandled = p.bellRequests
            bellEnv1 = 1.0
            bellDelay = Int(sampleRate * 0.26)
        }
        if bellDelay > 0 {
            bellDelay -= 1
            if bellDelay == 0 { bellEnv2 = 0.9 }
        }
        if bellEnv1 > 0.0005 || bellEnv2 > 0.0005 {
            var b: Float = 0
            if bellEnv1 > 0.0005 {
                bellP1 += 659.25 * dt; if bellP1 >= 1 { bellP1 -= 1 }
                b += (sin(6.2831853 * bellP1) + 0.35 * sin(12.5663706 * bellP1)) * bellEnv1
                bellEnv1 *= max(0, 1 - 2.4 * dt)
            }
            if bellEnv2 > 0.0005 {
                bellP2 += 554.37 * dt; if bellP2 >= 1 { bellP2 -= 1 }
                b += (sin(6.2831853 * bellP2) + 0.35 * sin(12.5663706 * bellP2)) * bellEnv2
                bellEnv2 *= max(0, 1 - 1.8 * dt)
            }
            outL += b * 0.11
            outR += b * 0.13
        }

        // 8. Stereo weather (rain, gusting wind, thunder — muffled inside the tunnel).
        let exterior = 1 - sTunnel * 0.72
        if sRain > 0.005 {
            rainLPL += (whiteL - rainLPL) * 0.35
            rainLPR += (whiteR - rainLPR) * 0.35
            let rg = min(sRain, 1.6) * 0.085 * exterior
            outL += rainLPL * rg
            outR += rainLPR * rg
        }
        windLFO += 0.13 * dt
        if windLFO >= 1 { windLFO -= 1 }
        let gust = sin(6.2831853 * windLFO)
        let windAlpha = 0.012 + 0.006 * gust
        windLPL += (whiteL - windLPL) * windAlpha
        windLPR += (whiteR - windLPR) * windAlpha
        let wg = sWind * (0.7 + 0.3 * gust) * 1.1 * exterior
        outL += windLPL * wg
        outR += windLPR * wg

        if p.thunderRequests != thunderHandled {
            thunderHandled = p.thunderRequests
            thunderEnv = 1
        }
        if thunderEnv > 0.0005 {
            thunderLP += (white - thunderLP) * 0.004
            let tSig = thunderLP * thunderEnv * 8.5 * (1 - sTunnel * 0.45)
            outL += tSig
            outR += tSig * 0.94
            thunderEnv *= max(0, 1 - dt / 1.4)
        }

        return (clamp(outL, -1, 1), clamp(outR, -1, 1))
    }
}
