import SceneKit
import CoreLocation
import simd

enum WeatherKind: String, CaseIterable {
    case clear, cloudy, fog, rain, snow, storm

    var title: String {
        switch self {
        case .clear: return "Clear"
        case .cloudy: return "Cloudy"
        case .fog: return "Fog"
        case .rain: return "Rain"
        case .snow: return "Snow"
        case .storm: return "Thunderstorm"
        }
    }

    var symbol: String {
        switch self {
        case .clear: return "sun.max.fill"
        case .cloudy: return "cloud.fill"
        case .fog: return "cloud.fog.fill"
        case .rain: return "cloud.rain.fill"
        case .snow: return "cloud.snow.fill"
        case .storm: return "cloud.bolt.rain.fill"
        }
    }

    /// Maps a WMO weather code (as returned by Open-Meteo) to one of our kinds.
    init(wmoCode: Int) {
        switch wmoCode {
        case 0, 1: self = .clear
        case 2, 3: self = .cloudy
        case 45, 48: self = .fog
        case 71...77, 85, 86: self = .snow
        case 95...99: self = .storm
        case 51...67, 80...82: self = .rain
        default: self = .cloudy
        }
    }

    fileprivate var params: WeatherParams {
        switch self {
        case .clear:
            return WeatherParams(top: V3(0.22, 0.50, 0.92), horizon: V3(0.74, 0.86, 0.97),
                                 fogStart: 1500, fogEnd: 6000, sun: 1150, ambient: 480,
                                 rain: 0, snow: 0, wind: 0.05, overcast: 0.0, fogFactor: 0.0)
        case .cloudy:
            return WeatherParams(top: V3(0.52, 0.57, 0.64), horizon: V3(0.78, 0.80, 0.83),
                                 fogStart: 700, fogEnd: 3600, sun: 520, ambient: 640,
                                 rain: 0, snow: 0, wind: 0.2, overcast: 0.55, fogFactor: 0.15)
        case .fog:
            return WeatherParams(top: V3(0.74, 0.76, 0.78), horizon: V3(0.80, 0.81, 0.82),
                                 fogStart: 14, fogEnd: 340, sun: 240, ambient: 700,
                                 rain: 0, snow: 0, wind: 0.1, overcast: 0.85, fogFactor: 1.0)
        case .rain:
            return WeatherParams(top: V3(0.36, 0.40, 0.46), horizon: V3(0.58, 0.61, 0.65),
                                 fogStart: 120, fogEnd: 1500, sun: 260, ambient: 520,
                                 rain: 1, snow: 0, wind: 0.35, overcast: 0.78, fogFactor: 0.45)
        case .snow:
            return WeatherParams(top: V3(0.76, 0.79, 0.84), horizon: V3(0.87, 0.89, 0.93),
                                 fogStart: 65, fogEnd: 850, sun: 360, ambient: 740,
                                 rain: 0, snow: 1, wind: 0.5, overcast: 0.72, fogFactor: 0.55)
        case .storm:
            return WeatherParams(top: V3(0.14, 0.16, 0.21), horizon: V3(0.32, 0.35, 0.40),
                                 fogStart: 100, fogEnd: 1100, sun: 120, ambient: 340,
                                 rain: 1.5, snow: 0, wind: 0.8, overcast: 0.95, fogFactor: 0.65)
        }
    }
}

enum TimePreset: String, CaseIterable {
    case morning, midday, sunset, night

    /// Normalized solar phase in 0...1 (0 = sunrise, 0.25 = noon, 0.5 = sunset, 0.75 = midnight).
    var phase: Float {
        switch self {
        case .morning: return 0.10
        case .midday:  return 0.26
        case .sunset:  return 0.486
        case .night:   return 0.75
        }
    }

    var title: String {
        switch self {
        case .morning: return "Morning"
        case .midday:  return "Midday"
        case .sunset:  return "Golden Hour"
        case .night:   return "Alpine Night"
        }
    }

    var symbol: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .midday:  return "sun.max.fill"
        case .sunset:  return "sunset.fill"
        case .night:   return "moon.stars.fill"
        }
    }
}

enum TimeOfDayMode: Equatable {
    case auto
    case manual(TimePreset)

    static let all: [TimeOfDayMode] = [.auto] + TimePreset.allCases.map { .manual($0) }
}

private struct WeatherParams {
    var top: V3, horizon: V3
    var fogStart: Float, fogEnd: Float
    var sun: Float, ambient: Float
    var rain: Float, snow: Float, wind: Float
    var overcast: Float, fogFactor: Float

    mutating func approach(_ t: WeatherParams, _ k: Float) {
        top = lerp(top, t.top, k); horizon = lerp(horizon, t.horizon, k)
        fogStart = lerp(fogStart, t.fogStart, k); fogEnd = lerp(fogEnd, t.fogEnd, k)
        sun = lerp(sun, t.sun, k); ambient = lerp(ambient, t.ambient, k)
        rain = lerp(rain, t.rain, k); snow = lerp(snow, t.snow, k); wind = lerp(wind, t.wind, k)
        overcast = lerp(overcast, t.overcast, k); fogFactor = lerp(fogFactor, t.fogFactor, k)
    }
}

enum Images {
    static func make(width: Int, height: Int, draw: (CGContext) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        draw(ctx)
        return ctx.makeImage()
    }

    /// A soft white blob used for smoke and snow.
    static let softDot: CGImage? = make(width: 64, height: 64) { ctx in
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)]
        guard let gradient = CGGradient(colorsSpace: ctx.colorSpace, colors: colors as CFArray, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 32, y: 32), startRadius: 0,
                               endCenter: CGPoint(x: 32, y: 32), endRadius: 31, options: [.drawsBeforeStartLocation])
    }

    static func sky(top: V3, horizon: V3) -> CGImage? {
        make(width: 4, height: 128) { ctx in
            func color(_ v: V3) -> CGColor {
                CGColor(red: CGFloat(clamp(v.x, 0, 1)),
                        green: CGFloat(clamp(v.y, 0, 1)),
                        blue: CGFloat(clamp(v.z, 0, 1)), alpha: 1)
            }
            let mid = lerp(top, horizon, 0.58)
            let colors = [color(top), color(mid), color(horizon), color(horizon)]
            guard let gradient = CGGradient(colorsSpace: ctx.colorSpace, colors: colors as CFArray,
                                            locations: [0, 0.36, 0.56, 1]) else { return }
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 128), end: CGPoint(x: 0, y: 0), options: [])
        }
    }
}

/// Owns the sky, celestial bodies, drifting clouds, fog, lights, dynamic day/night arc, and precipitation.
final class WeatherFX {
    private let scene: SCNScene
    private let sun = SCNLight()
    private let sunNode = SCNNode()
    private let ambient = SCNLight()
    private let rain = SCNParticleSystem()
    private let snow = SCNParticleSystem()
    private let precipRig = SCNNode()

    private let skyRig = SCNNode()
    private let sunDisc = SCNNode()
    private let moonDisc = SCNNode()
    private let starField = SCNNode()
    private let cloudRingA = SCNNode()
    private let cloudRingB = SCNNode()
    private let cloudMat = SCNMaterial()

    private var current = WeatherKind.clear.params
    private var skyTop = V3(-1, -1, -1)
    private var skyHorizon = V3(-1, -1, -1)
    private var skyRefreshCooldown: Float = 0

    /// Normalized time of day in 0...1 (starts in crisp mid-morning around 10 AM).
    private(set) var dayPhase: Float = 0.19
    private(set) var nightLevel: Float = 0
    private(set) var currentSkyHorizon = V3(0.74, 0.86, 0.97)
    var fogLevel: Float { current.fogFactor }

    private var flash: Float = 0
    private var nextFlash: Float = 4
    private var lastCamera: V3?
    private var cloudTime: Float = 0

    var rainLevel: Float { current.rain }
    var windLevel: Float { max(current.wind, current.snow * 0.5) }
    var onThunder: (() -> Void)?

    init(scene: SCNScene) {
        self.scene = scene

        sun.type = .directional
        sun.color = rgb(1.0, 0.96, 0.88)
        sun.castsShadow = true
        sun.shadowColor = rgb(0, 0, 0, 0.45)
        #if os(tvOS)
        sun.shadowMapSize = CGSize(width: 1536, height: 1536)
        sun.shadowCascadeCount = 2
        sun.shadowSampleCount = 2
        sun.maximumShadowDistance = 280
        #else
        sun.shadowMapSize = CGSize(width: 2048, height: 2048)
        sun.shadowCascadeCount = 3
        sun.shadowSampleCount = 4
        sun.maximumShadowDistance = 320
        #endif
        sun.shadowRadius = 2.5
        sunNode.light = sun
        sunNode.simdEulerAngles = V3(-0.85, 0.7, 0)
        scene.rootNode.addChildNode(sunNode)

        ambient.type = .ambient
        ambient.color = rgb(0.85, 0.90, 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        buildSkyElements()
        configurePrecipitation()

        scene.fogDensityExponent = 1.4
        apply(tunnelFactor: 0)
    }

    private func buildSkyElements() {
        // Sun & moon discs on the far sky rig (centered on camera each frame).
        let sunSphere = SCNSphere(radius: 130)
        sunSphere.segmentCount = 16
        let sunMat = SCNMaterial()
        sunMat.lightingModel = .constant
        sunMat.diffuse.contents = rgb(1.0, 0.96, 0.82)
        sunSphere.materials = [sunMat]
        sunDisc.geometry = sunSphere
        sunDisc.castsShadow = false
        skyRig.addChildNode(sunDisc)

        let moonSphere = SCNSphere(radius: 95)
        moonSphere.segmentCount = 16
        let moonMat = SCNMaterial()
        moonMat.lightingModel = .constant
        moonMat.diffuse.contents = rgb(0.88, 0.92, 1.0)
        moonSphere.materials = [moonMat]
        moonDisc.geometry = moonSphere
        moonDisc.castsShadow = false
        skyRig.addChildNode(moonDisc)

        // Procedural alpine starfield (single draw call point cloud).
        var rng = SeededRNG(seed: 9001)
        let starCount = 380
        var starPositions: [V3] = []
        starPositions.reserveCapacity(starCount)
        for _ in 0..<starCount {
            let az = Float.random(in: 0..<(2 * .pi), using: &rng)
            let el = Float.random(in: 0.08...1.45, using: &rng)
            let r: Float = 4700
            starPositions.append(V3(cos(el) * cos(az) * r, sin(el) * r, cos(el) * sin(az) * r))
        }
        let starData = starPositions.withUnsafeBufferPointer { Data(buffer: $0) }
        let starSource = SCNGeometrySource(data: starData, semantic: .vertex, vectorCount: starCount,
                                           usesFloatComponents: true, componentsPerVector: 3,
                                           bytesPerComponent: 4, dataOffset: 0, dataStride: MemoryLayout<V3>.stride)
        let starElement = SCNGeometryElement(data: nil, primitiveType: .point, primitiveCount: starCount, bytesPerIndex: 0)
        starElement.pointSize = 2.6
        starElement.minimumPointScreenSpaceRadius = 1.2
        starElement.maximumPointScreenSpaceRadius = 3.2
        let starGeom = SCNGeometry(sources: [starSource], elements: [starElement])
        let starMat = SCNMaterial()
        starMat.lightingModel = .constant
        starMat.diffuse.contents = rgb(0.95, 0.97, 1.0)
        starGeom.materials = [starMat]
        starField.geometry = starGeom
        starField.castsShadow = false
        starField.opacity = 0
        skyRig.addChildNode(starField)

        scene.rootNode.addChildNode(skyRig)

        // Drifting low-poly alpine clouds (2 slowly orbiting batched meshes around the mountain rim).
        cloudMat.lightingModel = .lambert
        cloudMat.diffuse.contents = rgb(0.98, 0.98, 1.0)
        cloudMat.isDoubleSided = false

        func buildCloudRing(count: Int, minR: Float, maxR: Float, minY: Float, maxY: Float) -> SCNNode {
            var mesh = MeshBuilder()
            let up = V3(0, 1, 0), side = V3(1, 0, 0), fwd = V3(0, 0, 1)
            for i in 0..<count {
                let a = Float(i) / Float(count) * 2 * .pi + Float.random(in: -0.25...0.25, using: &rng)
                let r = Float.random(in: minR...maxR, using: &rng)
                let y = Float.random(in: minY...maxY, using: &rng)
                let center = V3(cos(a) * r, y, sin(a) * r)
                let puffs = Int.random(in: 3...5, using: &rng)
                for p in 0..<puffs {
                    let ox = Float(p - puffs / 2) * Float.random(in: 24...38, using: &rng)
                    let oy = Float.random(in: -6...12, using: &rng)
                    let oz = Float.random(in: -18...18, using: &rng)
                    let sx = Float.random(in: 24...44, using: &rng)
                    let sy = Float.random(in: 10...19, using: &rng)
                    let sz = Float.random(in: 20...36, using: &rng)
                    let shade = Float.random(in: 0.92...1.0, using: &rng)
                    mesh.box(center: center + V3(ox, oy, oz), side: side, up: up, forward: fwd,
                             half: V3(sx, sy, sz), color: RGBA(shade, shade, shade, 1), includeBottom: true)
                }
            }
            let ringNode = SCNNode(geometry: mesh.geometry(doubleSided: false, material: cloudMat))
            ringNode.castsShadow = false
            return ringNode
        }

        cloudRingA.addChildNode(buildCloudRing(count: 10, minR: 850, maxR: 1550, minY: 360, maxY: 440))
        cloudRingB.addChildNode(buildCloudRing(count: 8, minR: 1450, maxR: 2200, minY: 430, maxY: 530))
        scene.rootNode.addChildNode(cloudRingA)
        scene.rootNode.addChildNode(cloudRingB)
    }

    private func configurePrecipitation() {
        // Tighter frustum-adjacent emitter boxes look just as dense with ~45% fewer simulated particles.
        rain.birthRate = 0
        rain.particleLifeSpan = 0.58
        rain.emitterShape = SCNBox(width: 52, height: 24, length: 52, chamferRadius: 0)
        rain.birthLocation = .volume
        rain.birthDirection = .constant
        rain.emittingDirection = SCNVector3(V3(0.08, -1, 0.03))
        rain.particleVelocity = 42
        rain.particleVelocityVariation = 6
        rain.particleSize = 0.024
        rain.stretchFactor = 0.019
        rain.particleColor = rgb(0.82, 0.86, 0.92, 0.55)
        rain.isLightingEnabled = false
        rain.isAffectedByGravity = false
        rain.blendMode = .alpha
        rain.loops = true

        snow.birthRate = 0
        snow.particleImage = Images.softDot
        snow.particleLifeSpan = 2.3
        snow.emitterShape = SCNBox(width: 64, height: 28, length: 64, chamferRadius: 0)
        snow.birthLocation = .volume
        snow.birthDirection = .constant
        snow.emittingDirection = SCNVector3(V3(0.25, -1, 0.1))
        snow.spreadingAngle = 24
        snow.particleVelocity = 4.6
        snow.particleVelocityVariation = 1.8
        snow.particleSize = 0.17
        snow.particleSizeVariation = 0.07
        snow.particleColor = rgb(1, 1, 1, 0.9)
        snow.isLightingEnabled = false
        snow.isAffectedByGravity = false
        snow.blendMode = .alpha
        snow.loops = true

        precipRig.addParticleSystem(rain)
        precipRig.addParticleSystem(snow)
        scene.rootNode.addChildNode(precipRig)
    }

    /// Human-readable label & SF Symbol for the current solar phase (used in HUD).
    func timeOfDayDisplay(for mode: TimeOfDayMode) -> (title: String, symbol: String) {
        switch mode {
        case .manual(let preset):
            return (preset.title, preset.symbol)
        case .auto:
            let p = dayPhase
            if p < 0.14 { return ("Morning · auto", "sunrise.fill") }
            if p < 0.40 { return ("Day · auto", "sun.max.fill") }
            if p < 0.56 { return ("Sunset · auto", "sunset.fill") }
            if p < 0.93 { return ("Night · auto", "moon.stars.fill") }
            return ("Dawn · auto", "sunrise.fill")
        }
    }

    func snapTimeOfDay(_ mode: TimeOfDayMode) {
        if case .manual(let preset) = mode {
            dayPhase = preset.phase
        }
    }

    func update(dt: Float, target: WeatherKind, timeMode: TimeOfDayMode,
                cameraPosition: V3, tunnelFactor: Float) {
        current.approach(target.params, 1 - exp(-dt * 1.3))

        switch timeMode {
        case .auto:
            // Full sunrise-to-sunrise alpine cycle over ~10 minutes.
            dayPhase = (dayPhase + dt / 600.0).truncatingRemainder(dividingBy: 1.0)
        case .manual(let preset):
            // Ease smoothly along the shortest arc around the 0...1 clock.
            var diff = preset.phase - dayPhase
            if diff > 0.5 { diff -= 1 }
            if diff < -0.5 { diff += 1 }
            dayPhase = (dayPhase + diff * (1 - exp(-dt * 2.4)) + 1).truncatingRemainder(dividingBy: 1.0)
        }

        if target == .storm {
            nextFlash -= dt
            if nextFlash <= 0 {
                flash = 1
                nextFlash = Float.random(in: 5...13)
                onThunder?()
            }
        }
        flash *= exp(-dt * 8)

        // Move sky & clouds smoothly.
        skyRig.simdPosition = cameraPosition
        cloudTime += dt * (0.004 + current.wind * 0.012)
        cloudRingA.simdEulerAngles = V3(0, cloudTime, 0)
        cloudRingB.simdEulerAngles = V3(0, -cloudTime * 0.65, 0)

        // Precipitation is spawned in a box around the camera, pushed ahead by motion.
        let velocity = lastCamera.map { (cameraPosition - $0) / max(dt, 0.001) } ?? V3(0, 0, 0)
        lastCamera = cameraPosition
        let lead = simd_length(velocity) < 80 ? velocity * 0.45 : V3(0, 0, 0)
        precipRig.simdPosition = cameraPosition + lead + V3(0, 5, 0)

        skyRefreshCooldown = max(0, skyRefreshCooldown - dt)
        apply(tunnelFactor: tunnelFactor)
    }

    private func apply(tunnelFactor: Float) {
        // Compute sun direction along an alpine arc tilted nicely to cast scenic mountain shadows.
        let angle = dayPhase * 2 * .pi
        let sunElevation = sin(angle) // +1 noon, 0 sunrise/sunset, -1 midnight
        let sunDir = simd_normalize(V3(cos(angle) * 0.85, sunElevation, 0.48))
        let moonDir = -sunDir

        // Day/twilight/night blend weights.
        let dayFactor = smoothstep(-0.08, 0.25, sunElevation)
        let sunsetBand = exp(-pow((sunElevation - 0.04) / 0.18, 2)) * (1 - current.overcast * 0.65)
        nightLevel = clamp(1 - smoothstep(-0.18, 0.14, sunElevation), 0, 1)

        // Blend base weather sky colours with sunset alpenglow and midnight indigo.
        let nightTop = V3(0.02, 0.04, 0.11)
        let nightHorizon = V3(0.06, 0.10, 0.20)
        let sunsetTop = V3(0.24, 0.20, 0.44)
        let sunsetHorizon = V3(0.98, 0.54, 0.24)

        var targetTop = lerp(nightTop, current.top, dayFactor)
        var targetHorizon = lerp(nightHorizon, current.horizon, dayFactor)
        targetTop = lerp(targetTop, sunsetTop, sunsetBand * 0.78)
        targetHorizon = lerp(targetHorizon, sunsetHorizon, sunsetBand * 0.94)
        currentSkyHorizon = targetHorizon

        // Position celestial discs & stars.
        sunDisc.simdPosition = sunDir * 4400
        sunDisc.isHidden = sunElevation < -0.10 || current.overcast > 0.82
        sunDisc.opacity = CGFloat(clamp(smoothstep(-0.06, 0.12, sunElevation) * (1 - current.overcast * 0.85), 0, 1))

        moonDisc.simdPosition = moonDir * 4400
        moonDisc.isHidden = moonDir.y < -0.05 || current.overcast > 0.85
        moonDisc.opacity = CGFloat(clamp(smoothstep(0.0, 0.2, moonDir.y) * nightLevel * (1 - current.overcast * 0.8), 0, 1))

        let starAlpha = clamp((nightLevel - 0.35) / 0.55, 0, 1) * (1 - current.overcast * 0.9)
        starField.isHidden = starAlpha < 0.01
        starField.opacity = CGFloat(starAlpha)

        // Tint drifting alpine clouds cleanly with sunlight, sunset coral, storm grey, or moonlight.
        let cloudColor = lerp(
            lerp(V3(0.18, 0.22, 0.34), V3(0.96, 0.97, 0.99), dayFactor),
            V3(1.0, 0.66, 0.44),
            sunsetBand * 0.8
        ) * lerp(1.0, 0.42, current.overcast * 0.7)
        cloudMat.diffuse.contents = rgb(cloudColor.x, cloudColor.y, cloudColor.z)
        let cloudAlpha = 1 - smoothstep(0.5, 0.95, current.fogFactor)
        cloudRingA.opacity = CGFloat(cloudAlpha)
        cloudRingB.opacity = CGFloat(cloudAlpha)

        // Update sky gradient texture (throttled to avoid unneeded GPU texture uploads).
        let skyDelta = simd_distance(targetTop, skyTop) + simd_distance(targetHorizon, skyHorizon)
        if skyDelta > 0.015 && (skyRefreshCooldown <= 0 || skyTop.x < 0) {
            skyTop = targetTop
            skyHorizon = targetHorizon
            skyRefreshCooldown = 0.12
            scene.background.contents = Images.sky(top: skyTop, horizon: skyHorizon)
            scene.fogColor = rgb(skyHorizon.x, skyHorizon.y, skyHorizon.z)
        }

        // Aim directional light from the sun by day, or the moon at night.
        let activeDir = sunElevation >= -0.04 ? sunDir : moonDir
        let safeDir = simd_normalize(V3(activeDir.x, max(activeDir.y, 0.12), activeDir.z))
        sunNode.simdLook(at: -safeDir, up: V3(0, 1, 0), localFront: V3(0, 0, -1))

        let daySunColor = lerp(V3(1.0, 0.96, 0.88), V3(1.0, 0.56, 0.28), sunsetBand * 0.9)
        let moonColor = V3(0.45, 0.58, 0.86)
        let lightColor = lerp(moonColor, daySunColor, dayFactor)
        sun.color = rgb(lightColor.x, lightColor.y, lightColor.z)

        let tunnelDim = 1 - tunnelFactor * 0.86
        let moonIntensity: Float = 260 * (1 - current.overcast * 0.6)
        let effectiveSun = lerp(moonIntensity, current.sun, dayFactor) * tunnelDim
        sun.intensity = CGFloat(effectiveSun)

        let ambColor = lerp(V3(0.28, 0.36, 0.58), lerp(V3(0.85, 0.90, 1.0), V3(0.95, 0.68, 0.58), sunsetBand * 0.6), dayFactor)
        ambient.color = rgb(ambColor.x, ambColor.y, ambColor.z)
        let baseAmbient = lerp(175, current.ambient, dayFactor) * (1 - tunnelFactor * 0.78)
        ambient.intensity = CGFloat(baseAmbient + flash * 2400 * (1 - tunnelFactor * 0.7))

        scene.fogStartDistance = CGFloat(current.fogStart)
        scene.fogEndDistance = CGFloat(current.fogEnd)

        // Pause precipitation cleanly while inside the alpine rock tunnel.
        let outside = max(0, 1 - tunnelFactor * 1.6)
        rain.birthRate = CGFloat(current.rain < 0.02 ? 0 : current.rain * 2800 * outside)
        snow.birthRate = CGFloat(current.snow < 0.02 ? 0 : current.snow * 1450 * outside)
    }
}

/// Looks up the current real-world weather for the player's location via Open-Meteo.
/// If location is unavailable or declined, it falls back to the weather in the Swiss Alps.
final class WeatherService: NSObject, CLLocationManagerDelegate {
    struct Report {
        let kind: WeatherKind
        let temperature: Double?
        let place: String
    }

    var onReport: ((Report) -> Void)?

    private let manager = CLLocationManager()
    private var timer: Timer?
    private var lastCoordinate: (lat: Double, lon: Double, place: String)?
    private static let fallback = (lat: 46.62, lon: 8.04, place: "Swiss Alps")

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        handleAuthorization()
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            guard let self, let c = self.lastCoordinate else { return }
            self.fetch(lat: c.lat, lon: c.lon, place: c.place)
        }
    }

    private func handleAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            fetch(lat: Self.fallback.lat, lon: Self.fallback.lon, place: Self.fallback.place)
        default:
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        handleAuthorization()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let c = locations.last?.coordinate else { return }
        fetch(lat: c.latitude, lon: c.longitude, place: "your location")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if lastCoordinate == nil {
            fetch(lat: Self.fallback.lat, lon: Self.fallback.lon, place: Self.fallback.place)
        }
    }

    private struct Response: Decodable {
        struct Current: Decodable {
            let weather_code: Int
            let temperature_2m: Double?
        }
        let current: Current
    }

    private func fetch(lat: Double, lon: Double, place: String) {
        lastCoordinate = (lat, lon, place)
        // Coordinates are rounded to two decimals (about a kilometre) before they leave the device.
        let query = String(format: "latitude=%.2f&longitude=%.2f&current=weather_code,temperature_2m", lat, lon)
        guard let url = URL(string: "https://api.open-meteo.com/v1/forecast?" + query) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
            let report = Report(kind: WeatherKind(wmoCode: response.current.weather_code),
                                temperature: response.current.temperature_2m, place: place)
            DispatchQueue.main.async { self?.onReport?(report) }
        }.resume()
    }
}
