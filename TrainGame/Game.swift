import SceneKit
import Observation
import simd
import os

enum CameraMode: Int, CaseIterable {
    case chase, cab, side, trackside, aerial

    var title: String {
        switch self {
        case .chase: return "Chase"
        case .cab: return "Cab"
        case .side: return "Side"
        case .trackside: return "Trackside"
        case .aerial: return "Aerial"
        }
    }
}

enum WeatherMode: Equatable {
    case live
    case manual(WeatherKind)

    static let all: [WeatherMode] = [.live] + WeatherKind.allCases.map { .manual($0) }
}

/// Everything the HUD shows. Published from the render loop a few times a second.
struct HUDState: Equatable {
    var speedKmh = 0
    var notch = 0
    var nextStation = ""
    var distance = 0
    /// Normalized 0...1 approach progress when within 320m of the next station (nil otherwise).
    var approachProgress: Float?
    var inStopZone = false
    var onboard = 0
    var delivered = 0
    var weather = "Clear"
    var weatherSymbol = "sun.max.fill"
    var timeOfDay = "Day · auto"
    var timeSymbol = "sun.max.fill"
    var camera = "Chase"
    var banner: String?
    var showHints = true
}

@Observable
final class GameModel {
    var hud = HUDState()
}

final class Game: NSObject, SCNSceneRendererDelegate {
    static let maxNotch = 4
    static let minNotch = -3

    let scene = SCNScene()
    let model = GameModel()
    let cameraNode = SCNNode()
    let input = InputController()

    private let track: Track
    private let terrain: Terrain
    private let train = Train()
    private let weatherFX: WeatherFX
    private let audio = TrainAudio()
    private let weatherService = WeatherService()
    private let people = SCNNode()
    private var stations: [Station] = []

    // Simulation state (render thread only).
    private var head: Float = 0
    private var speed: Float = 0
    private var notch = 0
    private var odometer: Float = 0
    private var time: Float = 0
    private var lastTime: TimeInterval?
    private var dwellUntil: Float?
    private var boardingCount = 0
    private var nextIndex = 0
    private var onboard = 0
    private var delivered = 0
    private var flashMessage: (text: String, until: Float)?
    private var hintsOverride: Bool?

    private var cameraMode = CameraMode.chase
    private var cameraPosition = V3(0, 0, 0)
    private var cameraTarget = V3(0, 0, 0)
    private var cameraSnap = true
    private var tracksideAnchor: Float?
    private var orbitAngle: Float = 0

    private var weatherModeIndex = 0
    private var timeModeIndex = 0
    private var lastPublished = HUDState()
    private var publishTimer: Float = 0

    private struct SharedState {
        var liveReport: WeatherService.Report?
        var pendingDebug: DebugOverride?
    }

    struct DebugOverride {
        var camera: CameraMode?
        var weather: WeatherKind?
        var timeOfDay: TimeOfDayMode?
        var notch: Int?
        var headFraction: Float?
    }

    private let sharedState = OSAllocatedUnfairLock(initialState: SharedState())
    /// Turned off by the test harness so stray key presses can't disturb a scripted run.
    var inputEnabled = true

    override init() {
        let builtTrack = Track()
        track = builtTrack
        let stops: [(String, Float)] = [("Grindelwald", 0.03), ("Kandersteg", 0.36), ("Andermatt", 0.69)]
        terrain = Terrain(track: builtTrack, stationDistances: stops.map { $0.1 * builtTrack.length })
        weatherFX = WeatherFX(scene: scene)
        super.init()
        buildWorld(stops: stops)
    }

    // MARK: Setup

    private func buildWorld(stops: [(String, Float)]) {
        scene.rootNode.addChildNode(terrain.node)
        scene.rootNode.addChildNode(people)

        let sharedTrackMat = MeshBuilder.defaultMaterial(doubleSided: false)

        for (i, stop) in stops.enumerated() {
            let station = Station(name: stop.0, distance: stop.1 * track.length, track: track,
                                  people: people, seed: UInt64(100 + i))
            stations.append(station)
            scene.rootNode.addChildNode(station.root)

            // Each station platform gets its own tight mesh node so it frustum-culls with the station.
            var platformMesh = MeshBuilder()
            station.addPlatform(to: &platformMesh)
            scene.rootNode.addChildNode(SCNNode(geometry: platformMesh.geometry(doubleSided: false, material: sharedTrackMat)))
        }

        buildChunkedTrack(material: sharedTrackMat)
        buildViaduct(material: sharedTrackMat)
        buildTunnel(material: sharedTrackMat)

        for car in train.cars { scene.rootNode.addChildNode(car.node) }

        let camera = SCNCamera()
        camera.zNear = 0.3
        camera.zFar = 9000
        camera.fieldOfView = 58
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        head = stations[0].distance
        train.place(on: track, head: head, odometer: 0, speed: 0)
        updateCamera(dt: 0)
        weatherFX.onThunder = { [weak self] in self?.audio.thunder() }
    }

    /// Splits ballast, rails, and sleepers into 16 arc-length chunks so SceneKit frustum- and shadow-culls efficiently.
    private func buildChunkedTrack(material: SCNMaterial) {
        let chunkCount = 16
        let chunkLen = track.length / Float(chunkCount)
        let ballastColor = RGBA(0.42, 0.39, 0.35, 1)
        let railColor = RGBA(0.56, 0.57, 0.62, 1)
        let sleeperColor = RGBA(0.30, 0.20, 0.13, 1)

        for c in 0..<chunkCount {
            let start = Float(c) * chunkLen
            let end = Float(c + 1) * chunkLen
            var mesh = MeshBuilder()

            // Ballast bed everywhere except across the open stone viaduct deck.
            let vStart = track.viaduct.start, vEnd = track.viaduct.end
            let ballastProfile = [SIMD2<Float>(-7.0, -3.5), SIMD2(-2.3, 0), SIMD2(2.3, 0), SIMD2(7.0, -3.5)]
            if end <= vStart || start >= vEnd {
                mesh.ribbon(track: track, from: start, to: end, step: 3, profile: ballastProfile, color: ballastColor)
            } else {
                if start < vStart {
                    mesh.ribbon(track: track, from: start, to: vStart, step: 3, profile: ballastProfile, color: ballastColor)
                }
                if end > vEnd {
                    mesh.ribbon(track: track, from: vEnd, to: end, step: 3, profile: ballastProfile, color: ballastColor)
                }
            }

            // Steel rails
            for x: Float in [-0.79, 0.65] {
                mesh.ribbon(track: track, from: start, to: end, step: 2.5,
                            profile: [SIMD2(x, 0.14), SIMD2(x, Train.railTop),
                                      SIMD2(x + 0.14, Train.railTop), SIMD2(x + 0.14, 0.14)],
                            color: railColor)
            }

            // Wooden sleepers (skip hidden bottom faces to save thousands of invisible triangles).
            var d = ceil(start / 2.5) * 2.5
            while d < end {
                let f = track.frame(at: d)
                mesh.box(center: f.position + f.up * 0.08, side: f.side, up: f.up, forward: f.forward,
                         half: V3(1.3, 0.08, 0.14), color: sleeperColor, includeBottom: false)
                d += 2.5
            }

            let chunkNode = SCNNode(geometry: mesh.geometry(doubleSided: false, material: material))
            // Track bed & sleepers sit flush on terrain and don't need to cast expensive directional shadows.
            chunkNode.castsShadow = false
            scene.rootNode.addChildNode(chunkNode)
        }
    }

    /// Builds a Landwasser-inspired curved stone arch viaduct across the alpine river gorge.
    private func buildViaduct(material: SCNMaterial) {
        var mesh = MeshBuilder()
        let vStart = track.viaduct.start
        let vEnd = track.viaduct.end
        let stone = RGBA(0.66, 0.63, 0.57, 1)
        let stoneDark = RGBA(0.56, 0.53, 0.48, 1)
        let stoneTrim = RGBA(0.74, 0.71, 0.65, 1)

        // Bridge deck & twin stone parapets
        mesh.ribbon(track: track, from: vStart - 2, to: vEnd + 2, step: 2.5,
                    profile: [SIMD2(-3.0, -1.6), SIMD2(-3.0, 0.02), SIMD2(3.0, 0.02), SIMD2(3.0, -1.6)],
                    color: stone, caps: true)
        mesh.ribbon(track: track, from: vStart - 2, to: vEnd + 2, step: 2.5,
                    profile: [SIMD2(-3.05, 0), SIMD2(-3.05, 1.05), SIMD2(-2.55, 1.05), SIMD2(-2.55, 0)],
                    color: stoneTrim, caps: true)
        mesh.ribbon(track: track, from: vStart - 2, to: vEnd + 2, step: 2.5,
                    profile: [SIMD2(2.55, 0), SIMD2(2.55, 1.05), SIMD2(3.05, 1.05), SIMD2(3.05, 0)],
                    color: stoneTrim, caps: true)

        // Stone piers & semicircular masonry spandrel arches
        let archCount = 12
        let span = (vEnd - vStart) / Float(archCount)
        let pierHalfZ: Float = 1.85
        let halfW: Float = 2.75

        for k in 0...archCount {
            let d = vStart + Float(k) * span
            let f = track.frame(at: d)
            let bottomY = min(terrain.height(x: f.position.x, z: f.position.z) - 5, Terrain.waterLevel - 6)
            let topY = f.position.y - 1.5
            let h = max(topY - bottomY, 4)

            // Tapered stone pier (wider plinth at base, sleek crown at deck)
            let pTop = V3(f.position.x, topY, f.position.z)
            let pBot = V3(f.position.x, bottomY, f.position.z)
            let horizFwd = simd_normalize(V3(f.forward.x, 0, f.forward.z))
            let horizSide = simd_normalize(simd_cross(V3(0, 1, 0), horizFwd))

            let topX: Float = halfW + 0.15, botX: Float = halfW + 0.75 + h * 0.025
            let topZ: Float = pierHalfZ, botZ: Float = pierHalfZ + 0.65 + h * 0.02

            func corner(_ base: V3, _ sx: Float, _ sz: Float) -> V3 {
                base + horizSide * sx + horizFwd * sz
            }
            let tFL = corner(pTop, -topX, topZ), tFR = corner(pTop, topX, topZ)
            let tBL = corner(pTop, -topX, -topZ), tBR = corner(pTop, topX, -topZ)
            let bFL = corner(pBot, -botX, botZ), bFR = corner(pBot, botX, botZ)
            let bBL = corner(pBot, -botX, -botZ), bBR = corner(pBot, botX, -botZ)

            mesh.quad(bFL, bFR, tFR, tFL, stoneDark)   // +forward face
            mesh.quad(bBR, bBL, tBL, tBR, stoneDark)   // -forward face
            mesh.quad(bBL, bFL, tFL, tBL, stone)       // -side face
            mesh.quad(bFR, bBR, tBR, tFR, stone)       // +side face
        }

        // Semicircular spandrel arches between consecutive piers
        let archSegs = 8
        for k in 0..<archCount {
            let d0 = vStart + Float(k) * span + pierHalfZ * 0.85
            let d1 = vStart + Float(k + 1) * span - pierHalfZ * 0.85
            guard d1 > d0 else { continue }

            func archDrop(_ u: Float) -> Float {
                let c = 2 * u - 1
                return 1.85 + 9.2 * (1 - sqrt(max(0, 1 - c * c)))
            }

            var prevTopL = V3(0, 0, 0), prevTopR = V3(0, 0, 0)
            var prevBotL = V3(0, 0, 0), prevBotR = V3(0, 0, 0)
            for s in 0...archSegs {
                let u = Float(s) / Float(archSegs)
                let d = lerp(d0, d1, u)
                let f = track.frame(at: d)
                let drop = archDrop(u)
                let topL = f.position - f.side * halfW - f.up * 1.5
                let topR = f.position + f.side * halfW - f.up * 1.5
                let botL = f.position - f.side * halfW - f.up * drop
                let botR = f.position + f.side * halfW - f.up * drop

                if s > 0 {
                    // Left & right stone spandrel faces + curved arch underside soffit
                    mesh.quad(prevBotL, botL, topL, prevTopL, stone)
                    mesh.quad(prevTopR, topR, botR, prevBotR, stone)
                    mesh.quad(prevBotR, botR, botL, prevBotL, stoneDark)
                }
                prevTopL = topL; prevTopR = topR
                prevBotL = botL; prevBotR = botR
            }
        }

        let viaductNode = SCNNode(geometry: mesh.geometry(doubleSided: false, material: material))
        scene.rootNode.addChildNode(viaductNode)
    }

    /// Builds an alpine stone mountain tunnel with inward-facing arch lining, masonry portals, and warm wall lamps.
    private func buildTunnel(material: SCNMaterial) {
        var mesh = MeshBuilder()
        var lamps = MeshBuilder()

        let tStart = track.tunnel.start
        let tEnd = track.tunnel.end
        let boreDark = RGBA(0.24, 0.23, 0.25, 1)
        let portalStone = RGBA(0.55, 0.53, 0.49, 1)
        let portalTrim = RGBA(0.68, 0.65, 0.60, 1)
        let rockCap = RGBA(0.38, 0.37, 0.35, 1)

        // Horseshoe tunnel interior bore profile (width ±3.6m, crown height 7.5m).
        let boreProfile: [SIMD2<Float>] = [
            SIMD2(-3.6, -0.5), SIMD2(-3.6, 4.4), SIMD2(-2.7, 6.5),
            SIMD2(-1.1, 7.5),  SIMD2(1.1, 7.5),  SIMD2(2.7, 6.5),
            SIMD2(3.6, 4.4),   SIMD2(3.6, -0.5),
        ]
        // `flip: true` points normals inward toward the train inside the tunnel.
        mesh.ribbon(track: track, from: tStart, to: tEnd, step: 3.5, profile: boreProfile, color: boreDark, flip: true)

        // Outer rock & masonry sleeves over the first & last 56m so the tunnel pierces the mountain seamlessly.
        let sleeveProfile: [SIMD2<Float>] = [
            SIMD2(-9.5, -3.0), SIMD2(-6.5, 5.4), SIMD2(-3.6, 9.2),
            SIMD2(0, 10.6),    SIMD2(3.6, 9.2),  SIMD2(6.5, 5.4),
            SIMD2(9.5, -3.0),
        ]
        mesh.ribbon(track: track, from: tStart + 0.8, to: tStart + 58, step: 4, profile: sleeveProfile, color: rockCap)
        mesh.ribbon(track: track, from: tEnd - 58, to: tEnd - 0.8, step: 4, profile: sleeveProfile, color: rockCap)

        // Stone masonry portals at both ends (pilasters, lintel, cornice, keystone).
        for (d, sign) in [(tStart, Float(-1)), (tEnd, Float(1))] {
            let f = track.frame(at: d)
            let fwd = f.forward * sign
            let side = f.side * sign
            // Left & right masonry piers flanking the tunnel opening
            for xSign: Float in [-1, 1] {
                mesh.box(center: f.position + side * (xSign * 4.55) + f.up * 3.7,
                         side: side, up: f.up, forward: fwd,
                         half: V3(1.15, 4.4, 1.35), color: portalStone, includeBottom: false)
                // Flared retaining wing walls
                mesh.box(center: f.position + side * (xSign * 6.4) + f.up * 2.1 + fwd * 0.4,
                         side: side, up: f.up, forward: fwd,
                         half: V3(1.2, 3.0, 0.9), color: portalStone, includeBottom: false)
            }
            // Heavy stone arch lintel & cornice cap across top
            mesh.box(center: f.position + f.up * 8.15, side: side, up: f.up, forward: fwd,
                     half: V3(5.8, 1.15, 1.4), color: portalStone, includeBottom: false)
            mesh.box(center: f.position + f.up * 9.5, side: side, up: f.up, forward: fwd,
                     half: V3(6.1, 0.35, 1.6), color: portalTrim, includeBottom: false)
            // Carved stone keystone at crown
            mesh.box(center: f.position + f.up * 7.55 + fwd * 0.15, side: side, up: f.up, forward: fwd,
                     half: V3(0.65, 0.85, 1.45), color: portalTrim, includeBottom: false)
        }

        // Warm amber tunnel wall lamps alternating along the interior stone bore.
        var lampD = tStart + 18
        var lampIdx = 0
        let lampCol = RGBA(1.0, 0.82, 0.42, 1)
        while lampD < tEnd - 14 {
            let f = track.frame(at: lampD)
            let sideSign: Float = lampIdx % 2 == 0 ? -1 : 1
            let pos = f.position + f.side * (sideSign * 3.30) + f.up * 4.15
            lamps.box(center: pos, side: f.side, up: f.up, forward: f.forward,
                      half: V3(0.14, 0.24, 0.24), color: lampCol)
            lampD += 26
            lampIdx += 1
        }

        let tunnelNode = SCNNode(geometry: mesh.geometry(doubleSided: false, material: material))
        scene.rootNode.addChildNode(tunnelNode)

        if !lamps.isEmpty {
            let lampMat = SCNMaterial()
            lampMat.lightingModel = .constant
            lampMat.diffuse.contents = rgb(1.0, 0.84, 0.46)
            lampMat.emission.contents = rgb(1.0, 0.78, 0.34)
            let lampNode = SCNNode(geometry: lamps.geometry(doubleSided: false, material: lampMat))
            lampNode.castsShadow = false
            scene.rootNode.addChildNode(lampNode)
        }
    }

    /// Starts sound and the live-weather lookup. Call once, on the main thread.
    func start(muted: Bool = false, liveWeather: Bool = true) {
        audio.start(muted: muted)
        guard liveWeather else { return }
        weatherService.onReport = { [weak self] report in
            self?.sharedState.withLock { $0.liveReport = report }
        }
        weatherService.start()
    }

    /// Lets the test harness drive the game without a controller.
    func debugSet(camera: CameraMode? = nil, weather: WeatherKind? = nil,
                  timeOfDay: TimeOfDayMode? = nil, notch: Int? = nil, headFraction: Float? = nil) {
        sharedState.withLock {
            $0.pendingDebug = DebugOverride(camera: camera, weather: weather,
                                            timeOfDay: timeOfDay, notch: notch, headFraction: headFraction)
        }
    }

    // MARK: Frame update

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime now: TimeInterval) {
        let dt = Float(min(now - (lastTime ?? now), 0.05))
        lastTime = now
        time += dt

        let (live, debug): (WeatherService.Report?, DebugOverride?) = sharedState.withLock { state in
            let result = (state.liveReport, state.pendingDebug)
            state.pendingDebug = nil
            return result
        }

        let commands = inputEnabled ? input.poll(dt: dt) : InputCommands()
        if commands.throttleUp { notch = min(notch + 1, Game.maxNotch) }
        if commands.throttleDown { notch = max(notch - 1, Game.minNotch) }
        if commands.nextCamera {
            let next = CameraMode(rawValue: (cameraMode.rawValue + 1) % CameraMode.allCases.count)!
            setCamera(next)
            flash("Camera · \(next.title)", seconds: 1.6)
        }
        if commands.weatherNext {
            weatherModeIndex = (weatherModeIndex + 1) % WeatherMode.all.count
            flashWeatherBanner()
        }
        if commands.weatherPrevious {
            weatherModeIndex = (weatherModeIndex + WeatherMode.all.count - 1) % WeatherMode.all.count
            flashWeatherBanner()
        }
        if commands.nextTimeOfDay {
            timeModeIndex = (timeModeIndex + 1) % TimeOfDayMode.all.count
            let tm = TimeOfDayMode.all[timeModeIndex]
            let label = weatherFX.timeOfDayDisplay(for: tm).title
            flash("Time · \(label)", seconds: 1.8)
        }
        if commands.toggleHints {
            let currentShown = hintsOverride ?? (time < 30)
            hintsOverride = !currentShown
        }

        if let debug {
            if let camera = debug.camera { setCamera(camera) }
            if let weather = debug.weather {
                weatherModeIndex = WeatherMode.all.firstIndex(of: .manual(weather)) ?? 0
            }
            if let tod = debug.timeOfDay {
                timeModeIndex = TimeOfDayMode.all.firstIndex(of: tod) ?? 0
                weatherFX.snapTimeOfDay(tod)
            }
            if let n = debug.notch { notch = n }
            if let frac = debug.headFraction {
                head = track.wrap(frac * track.length)
                dwellUntil = nil
                cameraSnap = true
            }
        }

        updateTrain(dt: dt)
        updateStations()
        train.place(on: track, head: head, odometer: odometer, speed: speed)

        let tunnelAmt = max(track.tunnelFactor(at: head), track.tunnelFactor(at: head - Train.totalLength * 0.45))
        let viaductAmt = max(track.viaductFactor(at: head), track.viaductFactor(at: head - Train.totalLength * 0.45))

        updateCamera(dt: dt)

        let mode = WeatherMode.all[weatherModeIndex]
        let kind: WeatherKind
        switch mode {
        case .live: kind = live?.kind ?? .clear
        case .manual(let k): kind = k
        }
        let timeMode = TimeOfDayMode.all[timeModeIndex]
        let cameraInTunnel = track.tunnelFactor(at: head)
        weatherFX.update(dt: dt, target: kind, timeMode: timeMode,
                         cameraPosition: cameraPosition,
                         tunnelFactor: (cameraMode == .chase || cameraMode == .cab) ? cameraInTunnel : 0)

        let power: Float = notch > 0 ? Float(notch) / Float(Game.maxNotch) : 0
        let brake: Float = notch < 0 ? Float(-notch) / Float(-Game.minNotch) : 0

        train.updateEffects(power: power, speed: speed, hornOn: commands.horn,
                            nightLevel: weatherFX.nightLevel, tunnelFactor: tunnelAmt,
                            fogFactor: weatherFX.fogLevel, time: time)
        terrain.update(time: time, nightLevel: weatherFX.nightLevel, skyHorizon: weatherFX.currentSkyHorizon)
        for station in stations {
            station.setNightGlow(max(weatherFX.nightLevel, weatherFX.fogLevel * 0.45))
        }

        audio.update(speed: speed, power: power, brake: brake, hornOn: commands.horn,
                     rain: weatherFX.rainLevel, wind: weatherFX.windLevel,
                     viaduct: viaductAmt, tunnel: tunnelAmt)

        publishHUD(dt: dt, mode: mode, kind: kind, timeMode: timeMode, live: live)
    }

    private func flashWeatherBanner() {
        switch WeatherMode.all[weatherModeIndex] {
        case .live: flash("Weather · Live", seconds: 1.6)
        case .manual(let k): flash("Weather · \(k.title)", seconds: 1.6)
        }
    }

    private func updateTrain(dt: Float) {
        if dwellUntil != nil {
            // Doors are open: hold the train.
            notch = min(notch, 0)
            speed = 0
            return
        }
        var acceleration: Float = 0
        if notch > 0 {
            acceleration = Float(notch) / Float(Game.maxNotch) * 1.22 * max(0, 1 - speed / 27)
        } else if notch < 0 {
            acceleration = Float(notch) / Float(-Game.minNotch) * 2.65
        }
        // Subtle alpine grade physics: engine works a bit harder climbing and coasts gently downhill.
        let grade = track.grade(at: head - train.locoOffset)
        if speed > 0.05 || notch > 0 {
            acceleration -= grade * 1.35
        }
        if speed > 0 { acceleration -= 0.03 + 0.0006 * speed * speed }
        speed = max(0, speed + acceleration * dt)
        head = track.wrap(head + speed * dt)
        odometer += speed * dt
    }

    private func updateStations() {
        let station = stations[nextIndex]
        let delta = track.signedDelta(from: head, to: station.distance)

        // Hold semaphore red as train approaches its next scheduled stop.
        if dwellUntil == nil && delta > -Station.stopPast && delta < 380 {
            station.setSignalClear(false)
        }

        if let until = dwellUntil {
            if time >= until {
                dwellUntil = nil
                onboard += boardingCount
                boardingCount = 0
                station.setSignalClear(true)
                audio.playDepartureBell()
                nextIndex = (nextIndex + 1) % stations.count
                flash("All aboard! Throttle up to depart", seconds: 5)
            }
        } else if delta < -Station.stopPast - 1 {
            flash("Missed \(station.name)", seconds: 4)
            nextIndex = (nextIndex + 1) % stations.count
        } else if delta <= Station.stopShort && speed < 0.05 && notch <= 0 {
            let leaving = onboard == 0 ? 0 : max(1, Int(Float(onboard) * Float.random(in: 0.3...0.6)))
            onboard -= leaving
            delivered += leaving
            boardingCount = station.exchange(head: head, coachOffsets: train.coachOffsets, deboarding: leaving)
            dwellUntil = time + 3.5 + 0.3 * Float(max(boardingCount, leaving))
            if abs(delta) <= 4.5 {
                flash("Perfect stop at \(station.name)!", seconds: 2.6)
            }
        }

        for other in stations where other.needsRestock {
            if abs(track.signedDelta(from: head, to: other.distance)) > 350 {
                other.restock()
                other.setSignalClear(false)
            }
        }
    }

    // MARK: Camera

    private func setCamera(_ mode: CameraMode) {
        cameraMode = mode
        cameraSnap = true
        tracksideAnchor = nil
    }

    private func updateCamera(dt: Float) {
        let up = V3(0, 1, 0)
        let front = track.frame(at: head)
        let middle = track.frame(at: head - Train.totalLength / 2)
        var position: V3, target: V3
        var smoothing: Float = 0
        var fieldOfView: CGFloat = 58
        var clampToTerrain = true

        switch cameraMode {
        case .chase:
            // Pull cleanly inside the tunnel bore when passing through the mountain so the camera never clips rock.
            let tunnelBlend = max(track.tunnelFactor(at: head), track.tunnelFactor(at: head - 38))
            let distBehind = lerp(40, 22, tunnelBlend)
            let lateral = lerp(-6.5, -1.1, tunnelBlend)
            let height = lerp(9.0, 5.65, tunnelBlend)
            let behind = track.frame(at: head - distBehind)
            position = behind.position + behind.side * lateral + up * height
            target = front.position + front.forward * lerp(22, 34, tunnelBlend) + up * 2.5
            smoothing = 5.5
            if tunnelBlend > 0.12 { clampToTerrain = false }

        case .cab:
            let cab = track.frame(at: head - 7.0)
            let sway = sin(odometer * 0.38) * 0.03 * min(speed / 12, 1)
            position = cab.position + cab.side * (1.75 + sway) + cab.up * (Train.railTop + 3.0)
            target = position + cab.forward * 60 - up * 4
            if track.isInTunnel(head - 7.0, margin: 12) { clampToTerrain = false }

        case .side:
            position = middle.position - middle.side * 44 + up * 7
            target = middle.position + middle.forward * 6 + up * 2

        case .trackside:
            if let anchor = tracksideAnchor {
                let ahead = track.signedDelta(from: head, to: anchor)
                if ahead < -120 || ahead > 300 { tracksideAnchor = nil }
            }
            if tracksideAnchor == nil {
                var candidate = track.wrap(head + 150)
                // Avoid placing the trackside tripod buried inside the mountain tunnel.
                if track.isInTunnel(candidate, margin: 20) {
                    candidate = track.wrap(track.tunnel.end + 28)
                }
                tracksideAnchor = candidate
                cameraSnap = true
            }
            position = track.offsetPoint(tracksideAnchor!, lateral: -12, height: 2.4)
            target = track.point(at: head - 14) + up * 2.2
            fieldOfView = 40

        case .aerial:
            orbitAngle += dt * 0.12
            position = middle.position + V3(cos(orbitAngle) * 95, 58, sin(orbitAngle) * 95)
            target = middle.position + up * 2
        }

        if clampToTerrain {
            position.y = max(position.y, terrain.height(x: position.x, z: position.z) + 1.8)
        }

        if cameraSnap || smoothing == 0 {
            cameraPosition = position
            cameraTarget = target
            cameraSnap = false
        } else {
            let k = 1 - exp(-smoothing * dt)
            cameraPosition += (position - cameraPosition) * k
            cameraTarget += (target - cameraTarget) * k
        }
        cameraNode.camera?.fieldOfView = fieldOfView
        cameraNode.simdPosition = cameraPosition
        cameraNode.simdLook(at: cameraTarget, up: up, localFront: V3(0, 0, -1))
    }

    // MARK: HUD

    private func flash(_ text: String, seconds: Float) {
        flashMessage = (text, time + seconds)
    }

    private func publishHUD(dt: Float, mode: WeatherMode, kind: WeatherKind,
                            timeMode: TimeOfDayMode, live: WeatherService.Report?) {
        publishTimer -= dt
        guard publishTimer <= 0 else { return }
        publishTimer = 0.1

        let station = stations[nextIndex]
        let delta = track.signedDelta(from: head, to: station.distance)

        var state = HUDState()
        state.speedKmh = Int((speed * 3.6).rounded())
        state.notch = notch
        state.nextStation = station.name
        state.distance = max(0, Int(delta))
        if delta < 320 && delta > -Station.stopPast - 2 {
            state.approachProgress = clamp(1 - delta / 320, 0, 1.04)
            state.inStopZone = delta <= Station.stopShort && delta >= -Station.stopPast
        }
        state.onboard = onboard
        state.delivered = delivered
        state.camera = cameraMode.title
        state.weatherSymbol = kind.symbol
        let tod = weatherFX.timeOfDayDisplay(for: timeMode)
        state.timeOfDay = tod.title
        state.timeSymbol = tod.symbol
        state.showHints = hintsOverride ?? (time < 30)

        switch mode {
        case .manual:
            state.weather = kind.title
        case .live:
            if let live {
                let temperature = live.temperature.map { " · \(Int($0.rounded()))°C" } ?? ""
                state.weather = "\(kind.title)\(temperature) · live, \(live.place)"
            } else {
                state.weather = "Live weather…"
            }
        }

        if let message = flashMessage, time < message.until {
            state.banner = message.text
        } else if dwellUntil != nil {
            state.banner = "\(station.name) · doors open"
        } else if delta <= Station.stopShort && speed > 0.05 {
            state.banner = "Stop here"
        } else if delta < 350 && speed > 6 {
            state.banner = "Approaching \(station.name), brake now"
        }

        guard state != lastPublished else { return }
        lastPublished = state
        DispatchQueue.main.async { [model] in model.hud = state }
    }
}
