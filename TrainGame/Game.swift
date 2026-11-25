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
    var approachProgress: Float?
    var inStopZone = false
    var onboard = 0
    var delivered = 0
    var cargoDelivered = 0
    var activeMission: String?
    var worldTitle = "Swiss Alps"
    var worldSymbol = "mountain.2.fill"
    var trainTitle = "Steam Express"
    var trainSymbol = "flame.fill"
    var weather = "Clear"
    var weatherSymbol = "sun.max.fill"
    var timeOfDay = "Day · auto"
    var timeSymbol = "sun.max.fill"
    var camera = "Chase"
    var banner: String?
    var showHints = true
    var menuOpen = false
    var menuRow = 0
    var confettiTrigger = 0
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

    private let worldRoot = SCNNode()
    private let trainRoot = SCNNode()
    private let people = SCNNode()

    private var theme: WorldTheme = .alps
    private var trainKind: TrainKind = .steam
    private var track: Track
    private var terrain: Terrain
    private var train: Train
    private let weatherFX: WeatherFX
    private let audio = TrainAudio()
    private let weatherService = WeatherService()
    private var stations: [Station] = []

    // Drive-through Train Wash animated rollers & soap spray
    private var washRollers: [SCNNode] = []
    private var washSprays: [SCNParticleSystem] = []
    private var wasInWash = false

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
    private var cargoDelivered = 0
    private var cargoLoaded = false
    private var currentCargoName = ""
    private var cargoTargetIndex = 1
    private var cargoCounter = 0
    private var confettiTrigger = 0
    private var flashMessage: (text: String, until: Float)?
    private var hintsOverride: Bool?

    private var menuOpen = false
    private var menuRow = 0

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
        var world: WorldTheme?
        var train: TrainKind?
        var camera: CameraMode?
        var weather: WeatherKind?
        var timeOfDay: TimeOfDayMode?
        var notch: Int?
        var headFraction: Float?
        var triggerConfetti: Bool = false
    }

    private let sharedState = OSAllocatedUnfairLock(initialState: SharedState())
    var inputEnabled = true

    override init() {
        let initialTheme: WorldTheme = .alps
        let builtTrack = Track(theme: initialTheme)
        track = builtTrack
        terrain = Terrain(track: builtTrack, theme: initialTheme,
                          stationDistances: initialTheme.stops.map { $0.fraction * builtTrack.length })
        train = Train(kind: .steam)
        weatherFX = WeatherFX(scene: scene)
        super.init()

        scene.rootNode.addChildNode(worldRoot)
        scene.rootNode.addChildNode(trainRoot)

        let camera = SCNCamera()
        camera.zNear = 0.3
        camera.zFar = 9000
        camera.fieldOfView = 58
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        mountWorld()
        mountTrain()
        head = stations[0].distance
        train.place(on: track, head: head, odometer: 0, speed: 0)
        updateCamera(dt: 0)
        weatherFX.onThunder = { [weak self] in self?.audio.thunder() }
    }

    // MARK: World & Train Mounting / Hot-Swapping

    private func mountWorld() {
        worldRoot.childNodes.forEach { $0.removeFromParentNode() }
        people.childNodes.forEach { $0.removeFromParentNode() }
        stations.removeAll()
        washRollers.removeAll()
        washSprays.removeAll()

        worldRoot.addChildNode(terrain.node)
        worldRoot.addChildNode(people)

        let sharedTrackMat = MeshBuilder.defaultMaterial(doubleSided: false)
        for (i, stop) in theme.stops.enumerated() {
            let station = Station(name: stop.name, distance: stop.fraction * track.length, track: track,
                                  people: people, seed: UInt64(100 + i + theme.rawValue * 50))
            stations.append(station)
            worldRoot.addChildNode(station.root)

            var platformMesh = MeshBuilder()
            station.addPlatform(to: &platformMesh)
            worldRoot.addChildNode(SCNNode(geometry: platformMesh.geometry(doubleSided: false, material: sharedTrackMat)))
        }

        buildChunkedTrack(material: sharedTrackMat)
        buildViaduct(material: sharedTrackMat)
        buildTunnel(material: sharedTrackMat)
        buildTrainWash()
    }

    private func mountTrain() {
        trainRoot.childNodes.forEach { $0.removeFromParentNode() }
        for car in train.cars { trainRoot.addChildNode(car.node) }
        if train.kind == .freight {
            if !cargoLoaded {
                assignNextCargoMission(from: nextIndex)
            }
            train.setCargoLoaded(cargoLoaded)
        }
    }

    private func switchWorld(to newTheme: WorldTheme) {
        guard newTheme != theme else { return }
        theme = newTheme
        let frac = head / track.length
        let newTrack = Track(theme: newTheme)
        track = newTrack
        terrain = Terrain(track: newTrack, theme: newTheme,
                          stationDistances: newTheme.stops.map { $0.fraction * newTrack.length })
        mountWorld()
        head = track.wrap(frac * track.length)
        dwellUntil = nil
        wasInWash = false
        if train.kind == .freight {
            assignNextCargoMission(from: nextIndex)
            train.setCargoLoaded(cargoLoaded)
        }
        train.place(on: track, head: head, odometer: odometer, speed: speed)
        cameraSnap = true
        tracksideAnchor = nil
    }

    private func switchTrain(to newKind: TrainKind) {
        guard newKind != trainKind else { return }
        trainKind = newKind
        train = Train(kind: newKind)
        speed = min(speed, newKind.maxSpeed)
        mountTrain()
        train.place(on: track, head: head, odometer: odometer, speed: speed)
    }

    private func assignNextCargoMission(from stationIndex: Int) {
        cargoLoaded = true
        cargoTargetIndex = (stationIndex + 1) % stations.count
        let names = theme.cargoTypes
        currentCargoName = names[cargoCounter % names.count]
        cargoCounter += 1
        nextIndex = cargoTargetIndex
    }

    // MARK: Track, Viaduct, Tunnel & Train Wash Construction

    private func buildChunkedTrack(material: SCNMaterial) {
        let chunkCount = 16
        let chunkLen = track.length / Float(chunkCount)
        let ballastColor = theme == .tokyo ? RGBA(0.50, 0.51, 0.54, 1) : RGBA(0.42, 0.39, 0.35, 1)
        let railColor = RGBA(0.56, 0.57, 0.62, 1)
        let sleeperColor = theme == .tokyo ? RGBA(0.62, 0.63, 0.65, 1) : RGBA(0.30, 0.20, 0.13, 1)

        for c in 0..<chunkCount {
            let start = Float(c) * chunkLen
            let end = Float(c + 1) * chunkLen
            var mesh = MeshBuilder()

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

            for x: Float in [-0.79, 0.65] {
                mesh.ribbon(track: track, from: start, to: end, step: 2.5,
                            profile: [SIMD2(x, 0.14), SIMD2(x, Train.railTop),
                                      SIMD2(x + 0.14, Train.railTop), SIMD2(x + 0.14, 0.14)],
                            color: railColor)
            }

            var d = ceil(start / 2.5) * 2.5
            while d < end {
                let f = track.frame(at: d)
                mesh.box(center: f.position + f.up * 0.08, side: f.side, up: f.up, forward: f.forward,
                         half: V3(1.3, 0.08, 0.14), color: sleeperColor, includeBottom: false)
                d += 2.5
            }

            let chunkNode = SCNNode(geometry: mesh.geometry(doubleSided: false, material: material))
            chunkNode.castsShadow = false
            worldRoot.addChildNode(chunkNode)
        }
    }

    private func buildViaduct(material: SCNMaterial) {
        var mesh = MeshBuilder()
        let vStart = track.viaduct.start
        let vEnd = track.viaduct.end
        let stone = theme == .tokyo ? RGBA(0.75, 0.77, 0.80, 1) : RGBA(0.66, 0.63, 0.57, 1)
        let stoneDark = theme == .tokyo ? RGBA(0.62, 0.64, 0.68, 1) : RGBA(0.56, 0.53, 0.48, 1)
        let stoneTrim = theme == .tokyo ? RGBA(0.84, 0.86, 0.90, 1) : RGBA(0.74, 0.71, 0.65, 1)

        mesh.ribbon(track: track, from: vStart - 2, to: vEnd + 2, step: 2.5,
                    profile: [SIMD2(-3.0, -1.6), SIMD2(-3.0, 0.02), SIMD2(3.0, 0.02), SIMD2(3.0, -1.6)],
                    color: stone, caps: true)
        mesh.ribbon(track: track, from: vStart - 2, to: vEnd + 2, step: 2.5,
                    profile: [SIMD2(-3.05, 0), SIMD2(-3.05, 1.05), SIMD2(-2.55, 1.05), SIMD2(-2.55, 0)],
                    color: stoneTrim, caps: true)
        mesh.ribbon(track: track, from: vStart - 2, to: vEnd + 2, step: 2.5,
                    profile: [SIMD2(2.55, 0), SIMD2(2.55, 1.05), SIMD2(3.05, 1.05), SIMD2(3.05, 0)],
                    color: stoneTrim, caps: true)

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

            mesh.quad(bFL, bFR, tFR, tFL, stoneDark)
            mesh.quad(bBR, bBL, tBL, tBR, stoneDark)
            mesh.quad(bBL, bFL, tFL, tBL, stone)
            mesh.quad(bFR, bBR, tBR, tFR, stone)
        }

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
                    mesh.quad(prevBotL, botL, topL, prevTopL, stone)
                    mesh.quad(prevTopR, topR, botR, prevBotR, stone)
                    mesh.quad(prevBotR, botR, botL, prevBotL, stoneDark)
                }
                prevTopL = topL; prevTopR = topR
                prevBotL = botL; prevBotR = botR
            }
        }

        worldRoot.addChildNode(SCNNode(geometry: mesh.geometry(doubleSided: false, material: material)))
    }

    private func buildTunnel(material: SCNMaterial) {
        var mesh = MeshBuilder()
        var lamps = MeshBuilder()

        let tStart = track.tunnel.start
        let tEnd = track.tunnel.end
        let boreDark = RGBA(0.24, 0.23, 0.25, 1)
        let portalStone = theme == .tokyo ? RGBA(0.64, 0.66, 0.70, 1) : RGBA(0.55, 0.53, 0.49, 1)
        let portalTrim = theme == .tokyo ? RGBA(0.18, 0.62, 0.92, 1) : RGBA(0.68, 0.65, 0.60, 1)
        let rockCap = theme == .tokyo ? RGBA(0.42, 0.44, 0.48, 1) : RGBA(0.38, 0.37, 0.35, 1)

        let boreProfile: [SIMD2<Float>] = [
            SIMD2(-3.6, -0.5), SIMD2(-3.6, 4.4), SIMD2(-2.7, 6.5),
            SIMD2(-1.1, 7.5),  SIMD2(1.1, 7.5),  SIMD2(2.7, 6.5),
            SIMD2(3.6, 4.4),   SIMD2(3.6, -0.5),
        ]
        mesh.ribbon(track: track, from: tStart, to: tEnd, step: 3.5, profile: boreProfile, color: boreDark, flip: true)

        let sleeveProfile: [SIMD2<Float>] = [
            SIMD2(-9.5, -3.0), SIMD2(-6.5, 5.4), SIMD2(-3.6, 9.2),
            SIMD2(0, 10.6),    SIMD2(3.6, 9.2),  SIMD2(6.5, 5.4),
            SIMD2(9.5, -3.0),
        ]
        mesh.ribbon(track: track, from: tStart + 0.8, to: tStart + 58, step: 4, profile: sleeveProfile, color: rockCap)
        mesh.ribbon(track: track, from: tEnd - 58, to: tEnd - 0.8, step: 4, profile: sleeveProfile, color: rockCap)

        for (d, sign) in [(tStart, Float(-1)), (tEnd, Float(1))] {
            let f = track.frame(at: d)
            let fwd = f.forward * sign
            let side = f.side * sign
            for xSign: Float in [-1, 1] {
                mesh.box(center: f.position + side * (xSign * 4.55) + f.up * 3.7,
                         side: side, up: f.up, forward: fwd,
                         half: V3(1.15, 4.4, 1.35), color: portalStone, includeBottom: false)
                mesh.box(center: f.position + side * (xSign * 6.4) + f.up * 2.1 + fwd * 0.4,
                         side: side, up: f.up, forward: fwd,
                         half: V3(1.2, 3.0, 0.9), color: portalStone, includeBottom: false)
            }
            mesh.box(center: f.position + f.up * 8.15, side: side, up: f.up, forward: fwd,
                     half: V3(5.8, 1.15, 1.4), color: portalStone, includeBottom: false)
            mesh.box(center: f.position + f.up * 9.5, side: side, up: f.up, forward: fwd,
                     half: V3(6.1, 0.35, 1.6), color: portalTrim, includeBottom: false)
            mesh.box(center: f.position + f.up * 7.55 + fwd * 0.15, side: side, up: f.up, forward: fwd,
                     half: V3(0.65, 0.85, 1.45), color: portalTrim, includeBottom: false)
        }

        // Warm amber tunnel lamps in the Alps; vibrant cyan/pink neon light bars in Tokyo!
        var lampD = tStart + 18
        var lampIdx = 0
        while lampD < tEnd - 14 {
            let f = track.frame(at: lampD)
            let sideSign: Float = lampIdx % 2 == 0 ? -1 : 1
            let pos = f.position + f.side * (sideSign * 3.30) + f.up * 4.15
            let col: RGBA = theme == .tokyo
                ? (lampIdx % 2 == 0 ? RGBA(0.18, 0.88, 1.0, 1) : RGBA(1.0, 0.32, 0.72, 1))
                : RGBA(1.0, 0.82, 0.42, 1)
            lamps.box(center: pos, side: f.side, up: f.up, forward: f.forward,
                      half: V3(0.14, 0.22, theme == .tokyo ? 0.95 : 0.24), color: col)
            lampD += 26
            lampIdx += 1
        }

        worldRoot.addChildNode(SCNNode(geometry: mesh.geometry(doubleSided: false, material: material)))

        if !lamps.isEmpty {
            let lampMat = SCNMaterial()
            lampMat.lightingModel = .constant
            lampMat.diffuse.contents = PColor.white
            lampMat.emission.contents = PColor.white
            let lampNode = SCNNode(geometry: lamps.geometry(doubleSided: false, material: lampMat))
            lampNode.castsShadow = false
            worldRoot.addChildNode(lampNode)
        }
    }

    /// Builds a vibrant drive-through Train Wash with spinning bristle brushes and bubbly soap-water spray!
    private func buildTrainWash() {
        let centerD = (track.wash.start + track.wash.end) * 0.5
        let f = track.frame(at: centerD)
        let washNode = SCNNode()
        washNode.simdTransform = makeTransform(side: f.side, up: f.up, forward: f.forward, position: f.position)

        func mat(_ c: PColor, emission: PColor? = nil) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .blinn
            m.diffuse.contents = c
            if let emission { m.emission.contents = emission }
            return m
        }

        let teal = mat(rgb(0.08, 0.68, 0.78))
        let white = mat(rgb(0.95, 0.97, 0.99))
        let yellow = mat(rgb(0.96, 0.78, 0.14))
        let blueSign = mat(rgb(0.08, 0.34, 0.74), emission: rgb(0.04, 0.18, 0.42))

        // Static gantry arches straddling the track
        let frameGroup = SCNNode()
        for z: Float in [-9.0, 0.0, 9.0] {
            for x: Float in [-3.4, 3.4] {
                let col = SCNBox(width: 0.55, height: 6.4, length: 0.55, chamferRadius: 0.06)
                col.materials = [teal]
                let n = SCNNode(geometry: col); n.simdPosition = V3(x, 3.2, z)
                frameGroup.addChildNode(n)

                let base = SCNBox(width: 0.72, height: 1.0, length: 0.72, chamferRadius: 0.05)
                base.materials = [yellow]
                let b = SCNNode(geometry: base); b.simdPosition = V3(x, 0.5, z)
                frameGroup.addChildNode(b)
            }
            let beam = SCNBox(width: 7.4, height: 0.6, length: 0.65, chamferRadius: 0.06)
            beam.materials = [white]
            let bn = SCNNode(geometry: beam); bn.simdPosition = V3(0, 6.2, z)
            frameGroup.addChildNode(bn)
        }
        // Longitudinal canopy rails & bright sign fascia
        for x: Float in [-3.4, 3.4] {
            let rail = SCNBox(width: 0.35, height: 0.35, length: 19.0, chamferRadius: 0)
            rail.materials = [teal]
            let rn = SCNNode(geometry: rail); rn.simdPosition = V3(x, 6.2, 0)
            frameGroup.addChildNode(rn)
        }
        for z: Float in [-9.35, 9.35] {
            let sign = SCNBox(width: 6.4, height: 1.15, length: 0.16, chamferRadius: 0.05)
            sign.materials = [blueSign]
            let sn = SCNNode(geometry: sign); sn.simdPosition = V3(0, 6.55, z)
            frameGroup.addChildNode(sn)
        }
        washNode.addChildNode(frameGroup.flattenedClone())

        // Crisp "TRAIN WASH" sign text on both entry & exit arches
        let textMat = mat(PColor.white, emission: rgb(0.5, 0.5, 0.5))
        for (z, yaw) in [(Float(-9.45), Float.pi), (Float(9.45), Float(0))] {
            let text = SCNText(string: "TRAIN WASH", extrusionDepth: 0.25)
            text.font = PFont.boldSystemFont(ofSize: 8)
            text.flatness = 0.5
            text.materials = [textMat]
            let label = SCNNode(geometry: text)
            let (lo, hi) = text.boundingBox
            var pivot = matrix_identity_float4x4
            pivot.columns.3 = SIMD4((Float(lo.x) + Float(hi.x)) / 2, (Float(lo.y) + Float(hi.y)) / 2, 0, 1)
            label.simdPivot = pivot
            label.simdScale = V3(0.085, 0.085, 0.085)
            label.simdEulerAngles = V3(0, yaw, 0)
            label.simdPosition = V3(0, 6.55, z)
            label.castsShadow = false
            washNode.addChildNode(label)
        }

        // 4 spinning vertical blue-and-white bristle roller brushes!
        let brushBlue = mat(rgb(0.14, 0.54, 0.96))
        let brushProto = SCNNode()
        let cyl = SCNCylinder(radius: 0.72, height: 4.1); cyl.radialSegmentCount = 14
        cyl.materials = [brushBlue]
        brushProto.addChildNode(SCNNode(geometry: cyl))
        for i in 0..<4 {
            let fin = SCNBox(width: 1.56, height: 3.9, length: 0.14, chamferRadius: 0)
            fin.materials = [i % 2 == 0 ? white : teal]
            let fn = SCNNode(geometry: fin)
            fn.simdEulerAngles = V3(0, Float(i) * .pi / 4, 0)
            brushProto.addChildNode(fn)
        }
        let flatBrush = brushProto.flattenedClone()

        for z: Float in [-4.5, 4.5] {
            for x: Float in [-2.18, 2.18] {
                let roller = flatBrush.clone()
                roller.simdPosition = V3(x, 2.5, z)
                washNode.addChildNode(roller)
                washRollers.append(roller)
            }
        }

        // Overhead bubbly soap foam & misty water spray particle systems!
        for z: Float in [-5.0, 5.0] {
            let spray = SCNParticleSystem()
            spray.particleImage = Images.softDot
            spray.birthRate = 0
            spray.particleLifeSpan = 0.75
            spray.particleLifeSpanVariation = 0.25
            spray.emitterShape = SCNBox(width: 4.4, height: 0.3, length: 4.0, chamferRadius: 0)
            spray.birthLocation = .volume
            spray.birthDirection = .constant
            spray.emittingDirection = SCNVector3(V3(0, -1, 0))
            spray.spreadingAngle = 28
            spray.particleVelocity = 7.5
            spray.particleVelocityVariation = 2.0
            spray.particleSize = 0.42
            spray.particleSizeVariation = 0.22
            spray.particleColor = rgb(0.84, 0.96, 1.0, 0.78)
            spray.blendMode = .alpha
            spray.isLightingEnabled = false
            spray.isAffectedByGravity = false
            spray.loops = true

            let sNode = SCNNode()
            sNode.simdPosition = V3(0, 5.75, z)
            sNode.addParticleSystem(spray)
            washNode.addChildNode(sNode)
            washSprays.append(spray)
        }

        worldRoot.addChildNode(washNode)
    }

    // MARK: Lifecycle & Debug

    func start(muted: Bool = false, liveWeather: Bool = true) {
        audio.start(muted: muted)
        guard liveWeather else { return }
        weatherService.onReport = { [weak self] report in
            self?.sharedState.withLock { $0.liveReport = report }
        }
        weatherService.start()
    }

    func debugSet(world: WorldTheme? = nil, train: TrainKind? = nil, camera: CameraMode? = nil,
                  weather: WeatherKind? = nil, timeOfDay: TimeOfDayMode? = nil,
                  notch: Int? = nil, headFraction: Float? = nil, triggerConfetti: Bool = false) {
        sharedState.withLock {
            $0.pendingDebug = DebugOverride(world: world, train: train, camera: camera, weather: weather,
                                            timeOfDay: timeOfDay, notch: notch, headFraction: headFraction,
                                            triggerConfetti: triggerConfetti)
        }
    }

    // MARK: Frame Update

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime now: TimeInterval) {
        let dt = Float(min(now - (lastTime ?? now), 0.05))
        lastTime = now
        time += dt

        let (live, debug): (WeatherService.Report?, DebugOverride?) = sharedState.withLock { state in
            let result = (state.liveReport, state.pendingDebug)
            state.pendingDebug = nil
            return result
        }

        let commands = inputEnabled ? input.poll(dt: dt, menuOpen: menuOpen) : InputCommands()
        handleCommands(commands)

        if let debug {
            if let w = debug.world { switchWorld(to: w) }
            if let t = debug.train { switchTrain(to: t) }
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
            if debug.triggerConfetti { confettiTrigger += 1 }
        }

        updateTrain(dt: dt)
        updateStations()
        train.place(on: track, head: head, odometer: odometer, speed: speed)

        let tunnelAmt = max(track.tunnelFactor(at: head), track.tunnelFactor(at: head - Train.totalLength * 0.45))
        let viaductAmt = max(track.viaductFactor(at: head), track.viaductFactor(at: head - Train.totalLength * 0.45))
        let washAmt = max(track.washFactor(at: head),
                          max(track.washFactor(at: head - 30), track.washFactor(at: head - 62)))
        updateTrainWash(dt: dt, washAmt: washAmt)

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
                     night: weatherFX.nightLevel, viaduct: viaductAmt,
                     tunnel: tunnelAmt, wash: washAmt,
                     trainKind: train.kind, isUrban: theme == .tokyo)

        publishHUD(dt: dt, mode: mode, kind: kind, timeMode: timeMode, live: live)
    }

    private func handleCommands(_ commands: InputCommands) {
        if commands.toggleMenu {
            menuOpen.toggle()
            return
        }

        if menuOpen {
            if commands.throttleUp { menuRow = (menuRow + 3) % 4 }
            if commands.throttleDown { menuRow = (menuRow + 1) % 4 }
            let delta = commands.weatherPrevious ? -1 : ((commands.weatherNext || commands.selectTap) ? 1 : 0)
            if delta != 0 {
                switch menuRow {
                case 0:
                    let all = WorldTheme.allCases
                    let idx = (theme.rawValue + delta + all.count) % all.count
                    switchWorld(to: all[idx])
                case 1:
                    let all = TrainKind.allCases
                    let idx = (trainKind.rawValue + delta + all.count) % all.count
                    switchTrain(to: all[idx])
                case 2:
                    timeModeIndex = (timeModeIndex + delta + TimeOfDayMode.all.count) % TimeOfDayMode.all.count
                default:
                    weatherModeIndex = (weatherModeIndex + delta + WeatherMode.all.count) % WeatherMode.all.count
                }
            }
            return
        }

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
            let label = weatherFX.timeOfDayDisplay(for: TimeOfDayMode.all[timeModeIndex]).title
            flash("Time · \(label)", seconds: 1.8)
        }
        if commands.switchWorld {
            let next: WorldTheme = theme == .alps ? .tokyo : .alps
            switchWorld(to: next)
            flash("Landscape · \(next.title)", seconds: 2.2)
        }
        if let newTrain = commands.switchTrain {
            switchTrain(to: newTrain)
            flash("Train · \(newTrain.title)", seconds: 2.2)
        }
        if commands.toggleHints {
            let currentShown = hintsOverride ?? (time < 30)
            hintsOverride = !currentShown
        }
    }

    private func updateTrainWash(dt: Float, washAmt: Float) {
        let spinSpeed: Float = washAmt > 0.02 ? 9.5 : 1.2
        for (i, roller) in washRollers.enumerated() {
            let dir: Float = i % 2 == 0 ? 1 : -1
            roller.simdEulerAngles.y += dir * spinSpeed * dt
        }
        let sprayRate: CGFloat = washAmt > 0.02 ? CGFloat(washAmt * 180) : 0
        for spray in washSprays {
            spray.birthRate = sprayRate
        }
        if washAmt > 0.25 {
            wasInWash = true
        } else if wasInWash && washAmt < 0.02 {
            wasInWash = false
            confettiTrigger += 1
            flash("Sparkling clean! ✨", seconds: 3.0)
        }
    }

    private func flashWeatherBanner() {
        switch WeatherMode.all[weatherModeIndex] {
        case .live: flash("Weather · Live", seconds: 1.6)
        case .manual(let k): flash("Weather · \(k.title)", seconds: 1.6)
        }
    }

    private func updateTrain(dt: Float) {
        if dwellUntil != nil {
            notch = min(notch, 0)
            speed = 0
            return
        }
        var acceleration: Float = 0
        if notch > 0 {
            acceleration = Float(notch) / Float(Game.maxNotch) * train.kind.maxAcceleration * max(0, 1 - speed / train.kind.maxSpeed)
        } else if notch < 0 {
            acceleration = Float(notch) / Float(-Game.minNotch) * train.kind.maxBrake
        }
        let grade = track.grade(at: head - train.locoOffset)
        if speed > 0.05 || notch > 0 {
            acceleration -= grade * 1.35
        }
        if speed > 0 {
            let drag: Float = train.kind == .bullet ? 0.00028 : 0.0006
            acceleration -= 0.03 + drag * speed * speed
        }
        speed = max(0, speed + acceleration * dt)
        head = track.wrap(head + speed * dt)
        odometer += speed * dt
    }

    private func updateStations() {
        let station = stations[nextIndex]
        let delta = track.signedDelta(from: head, to: station.distance)

        if dwellUntil == nil && delta > -Station.stopPast && delta < 380 {
            station.setSignalClear(false)
        }

        if let until = dwellUntil {
            if time >= until {
                dwellUntil = nil
                if train.kind == .freight {
                    assignNextCargoMission(from: nextIndex)
                    train.setCargoLoaded(true)
                    station.setSignalClear(true)
                    audio.playDepartureBell()
                    flash("Loaded \(currentCargoName) → \(stations[nextIndex].name)", seconds: 4.5)
                } else {
                    onboard += boardingCount
                    boardingCount = 0
                    station.setSignalClear(true)
                    audio.playDepartureBell()
                    nextIndex = (nextIndex + 1) % stations.count
                    flash("All aboard! Throttle up to depart", seconds: 4.5)
                }
            }
        } else if delta < -Station.stopPast - 1 {
            flash("Missed \(station.name)", seconds: 4)
            nextIndex = (nextIndex + 1) % stations.count
        } else if delta <= Station.stopShort && speed < 0.05 && notch <= 0 {
            if train.kind == .freight {
                if cargoLoaded {
                    cargoLoaded = false
                    train.setCargoLoaded(false)
                    cargoDelivered += 1
                    confettiTrigger += 1
                    flash("Delivered \(currentCargoName) to \(station.name)! 🎉", seconds: 3.4)
                }
                dwellUntil = time + 3.2
            } else {
                let leaving = onboard == 0 ? 0 : max(1, Int(Float(onboard) * Float.random(in: 0.3...0.6)))
                onboard -= leaving
                delivered += leaving
                boardingCount = station.exchange(head: head, coachOffsets: train.coachOffsets, deboarding: leaving)
                dwellUntil = time + 3.5 + 0.3 * Float(max(boardingCount, leaving))
                if leaving > 0 || abs(delta) <= 4.5 {
                    confettiTrigger += 1
                }
                if abs(delta) <= 4.5 {
                    flash("Perfect stop at \(station.name)! 🎉", seconds: 2.8)
                } else if leaving > 0 {
                    flash("Delivered \(leaving) passengers to \(station.name)! 🎉", seconds: 2.8)
                }
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
            let cab = track.frame(at: head - (train.kind == .bullet ? 4.5 : 7.0))
            let sway = sin(odometer * 0.38) * 0.03 * min(speed / 12, 1)
            let cabLat: Float = train.kind == .bullet ? 0.0 : 1.75
            let cabH: Float = train.kind == .bullet ? 2.8 : 3.0
            position = cab.position + cab.side * (cabLat + sway) + cab.up * (Train.railTop + cabH)
            target = position + cab.forward * 65 - up * 3.5
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
        publishTimer = 0.08

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
        state.cargoDelivered = cargoDelivered
        if train.kind == .freight && cargoLoaded {
            state.activeMission = "Deliver \(currentCargoName) → \(station.name)"
        }
        state.worldTitle = theme.title
        state.worldSymbol = theme.symbol
        state.trainTitle = train.kind.title
        state.trainSymbol = train.kind.symbol
        state.camera = cameraMode.title
        state.weatherSymbol = kind.symbol
        let tod = weatherFX.timeOfDayDisplay(for: timeMode)
        state.timeOfDay = tod.title
        state.timeSymbol = tod.symbol
        state.showHints = hintsOverride ?? (time < 30)
        state.menuOpen = menuOpen
        state.menuRow = menuRow
        state.confettiTrigger = confettiTrigger

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
            state.banner = train.kind == .freight ? "\(station.name) · loading cargo" : "\(station.name) · doors open"
        } else if delta <= Station.stopShort && speed > 0.05 {
            state.banner = "Stop here"
        } else if delta < (train.kind == .bullet ? 520 : 350) && speed > 6 {
            state.banner = "Approaching \(station.name), brake now"
        }

        guard state != lastPublished else { return }
        lastPublished = state
        DispatchQueue.main.async { [model] in model.hud = state }
    }
}
