import SceneKit
import simd

/// Shared low-poly passenger geometries & materials so station visits never allocate new GPU meshes.
private enum PassengerAssets {
    static let bodies: [SCNGeometry] = {
        let palette: [PColor] = [
            rgb(0.85, 0.20, 0.20), rgb(0.20, 0.45, 0.85), rgb(0.95, 0.75, 0.15),
            rgb(0.20, 0.65, 0.40), rgb(0.60, 0.30, 0.70), rgb(0.90, 0.50, 0.20),
            rgb(0.25, 0.28, 0.34),
        ]
        return palette.map { color in
            let capsule = SCNCapsule(capRadius: 0.27, height: 1.45)
            capsule.radialSegmentCount = 10
            capsule.capSegmentCount = 5
            capsule.heightSegmentCount = 1
            capsule.firstMaterial?.diffuse.contents = color
            capsule.firstMaterial?.lightingModel = .lambert
            return capsule
        }
    }()

    static let head: SCNGeometry = {
        let sphere = SCNSphere(radius: 0.21)
        sphere.segmentCount = 10
        sphere.firstMaterial?.diffuse.contents = rgb(0.93, 0.76, 0.62)
        sphere.firstMaterial?.lightingModel = .lambert
        return sphere
    }()

    static let suitcase: SCNGeometry = {
        let bag = SCNBox(width: 0.16, height: 0.38, length: 0.48, chamferRadius: 0.03)
        bag.firstMaterial?.diffuse.contents = rgb(0.42, 0.24, 0.12)
        bag.firstMaterial?.lightingModel = .lambert
        return bag
    }()
}

/// A platform, alpine chalet station with canopy, water tower, lanterns, animated semaphore signal,
/// and the passengers waiting there.
final class Station {
    static let platformTop: Float = 1.0
    /// Platform extent along the track, relative to the stop marker (where the front of the train stops).
    static let platformBack: Float = -92
    static let platformFront: Float = 6
    /// How far short of / past the marker the front of the train may stop and still count.
    static let stopShort: Float = 20
    static let stopPast: Float = 5

    let name: String
    let distance: Float
    let root = SCNNode()
    private(set) var waiting: [SCNNode] = []
    var needsRestock = false

    private let track: Track
    private let people: SCNNode
    private let doorPoint: V3
    private var rng: SeededRNG

    private let warmGlowMat = SCNMaterial()
    private let signalLampMat = SCNMaterial()
    private var semaphorePivot: SCNNode?
    private var signalClear = false

    init(name: String, distance: Float, track: Track, people: SCNNode, seed: UInt64) {
        self.name = name
        self.distance = distance
        self.track = track
        self.people = people
        self.rng = SeededRNG(seed: seed)

        warmGlowMat.lightingModel = .lambert
        warmGlowMat.diffuse.contents = rgb(0.24, 0.32, 0.42)
        warmGlowMat.emission.contents = rgb(0, 0, 0)

        signalLampMat.lightingModel = .constant
        signalLampMat.diffuse.contents = rgb(1.0, 0.22, 0.16)
        signalLampMat.emission.contents = rgb(1.0, 0.22, 0.16)

        let center = distance + (Station.platformBack + Station.platformFront) / 2
        let f = track.frame(at: center)
        doorPoint = f.position + f.side * 6.6 + f.up * Station.platformTop
        root.simdTransform = makeTransform(side: f.side, up: f.up, forward: f.forward, position: f.position)
        buildBuilding()
        restock()
    }

    /// Adds the platform (which follows the curve of the track) to a track chunk mesh.
    func addPlatform(to mesh: inout MeshBuilder) {
        let from = distance + Station.platformBack, to = distance + Station.platformFront
        let top = Station.platformTop
        mesh.ribbon(track: track, from: from, to: to, step: 2,
                    profile: [SIMD2(1.75, -1.8), SIMD2(1.75, top), SIMD2(7.0, top), SIMD2(7.0, -1.8)],
                    color: RGBA(0.62, 0.62, 0.60, 1), caps: true)
        mesh.ribbon(track: track, from: from, to: to, step: 2,
                    profile: [SIMD2(1.76, top + 0.03), SIMD2(2.1, top + 0.03)],
                    color: RGBA(0.95, 0.80, 0.15, 1))
    }

    func setNightGlow(_ level: Float) {
        let glow = clamp(level * 1.15 - 0.10, 0, 1)
        warmGlowMat.emission.contents = rgb(1.0 * glow, 0.78 * glow, 0.34 * glow)
        warmGlowMat.diffuse.contents = rgb(
            lerp(0.24, 1.0, glow),
            lerp(0.32, 0.85, glow),
            lerp(0.42, 0.45, glow)
        )
    }

    /// Switches the mechanical departure semaphore between Red (Stop) and Green (Clear).
    func setSignalClear(_ clear: Bool) {
        guard clear != signalClear else { return }
        signalClear = clear
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.55
        semaphorePivot?.simdEulerAngles = V3(0, 0, clear ? 0.72 : 0)
        SCNTransaction.commit()
        if clear {
            signalLampMat.diffuse.contents = rgb(0.20, 0.96, 0.42)
            signalLampMat.emission.contents = rgb(0.20, 0.96, 0.42)
        } else {
            signalLampMat.diffuse.contents = rgb(1.0, 0.22, 0.16)
            signalLampMat.emission.contents = rgb(1.0, 0.22, 0.16)
        }
    }

    private func buildBuilding() {
        func mat(_ c: PColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .lambert
            m.diffuse.contents = c
            return m
        }

        let staticGroup = SCNNode()
        func addStatic(_ g: SCNGeometry, _ m: SCNMaterial, _ p: V3, euler: V3 = V3(0, 0, 0)) {
            g.materials = [m]
            let n = SCNNode(geometry: g)
            n.simdPosition = p
            n.simdEulerAngles = euler
            staticGroup.addChildNode(n)
        }

        let cream = mat(rgb(0.93, 0.88, 0.76))
        let timber = mat(rgb(0.42, 0.26, 0.14))
        let roof = mat(rgb(0.48, 0.20, 0.14))
        let darkIron = mat(rgb(0.18, 0.19, 0.21))
        let signBlue = mat(rgb(0.10, 0.16, 0.36))
        let woodTank = mat(rgb(0.52, 0.34, 0.20))

        // Local axes: x = away from track (+side), y = up, z = along track (+forward).
        // Main chalet station house + pitched roof
        addStatic(SCNBox(width: 8, height: 5.8, length: 17, chamferRadius: 0), cream, V3(12, 1.9, 0))
        addStatic(SCNBox(width: 8.2, height: 0.28, length: 17.2, chamferRadius: 0), timber, V3(12, 4.5, 0))
        addStatic(SCNPyramid(width: 10.6, height: 3.8, length: 19.6), roof, V3(12, 4.8, 0))
        addStatic(SCNBox(width: 0.2, height: 2.3, length: 1.5, chamferRadius: 0), timber, V3(7.95, 2.15, 0))

        // Wooden platform canopy sheltering waiting passengers
        addStatic(SCNBox(width: 4.6, height: 0.18, length: 24, chamferRadius: 0), roof,
                  V3(6.2, 4.45, 0), euler: V3(0, 0, 0.14))
        for z: Float in [-10, -3.5, 3.5, 10] {
            addStatic(SCNBox(width: 0.22, height: 3.3, length: 0.22, chamferRadius: 0), timber, V3(4.3, 2.6, z))
        }

        // Station wooden water tower near the locomotive stop point (+43m ahead of platform center)
        let wtX: Float = 8.4, wtZ: Float = 40
        for dx: Float in [-1.1, 1.1] {
            for dz: Float in [-1.1, 1.1] {
                addStatic(SCNBox(width: 0.26, height: 4.6, length: 0.26, chamferRadius: 0), timber,
                          V3(wtX + dx, 2.2, wtZ + dz))
            }
        }
        let tank = SCNCylinder(radius: 1.85, height: 3.2); tank.radialSegmentCount = 14
        addStatic(tank, woodTank, V3(wtX, 6.0, wtZ))
        let cap = SCNCone(topRadius: 0.05, bottomRadius: 2.15, height: 1.4); cap.radialSegmentCount = 14
        addStatic(cap, roof, V3(wtX, 8.3, wtZ))
        // Water crane spout pointing toward the tender
        let spout = SCNCylinder(radius: 0.16, height: 2.8); spout.radialSegmentCount = 8
        addStatic(spout, darkIron, V3(wtX - 2.3, 5.2, wtZ), euler: V3(0, 0, 1.25))

        // Name boards + posts
        for z: Float in [-24, 24] {
            addStatic(SCNBox(width: 0.16, height: 1.3, length: 7.4, chamferRadius: 0), signBlue, V3(6.7, 3.6, z))
            for post: Float in [-3.2, 3.2] {
                addStatic(SCNBox(width: 0.14, height: 2.6, length: 0.14, chamferRadius: 0), darkIron, V3(6.7, 2.0, z + post))
            }
        }

        // Platform lamp posts
        let lampZ: [Float] = [-36, -15, 15, 34]
        for z in lampZ {
            let pole = SCNCylinder(radius: 0.07, height: 3.6); pole.radialSegmentCount = 8
            addStatic(pole, darkIron, V3(5.6, 2.75, z))
            addStatic(SCNBox(width: 0.52, height: 0.12, length: 0.52, chamferRadius: 0), darkIron, V3(5.6, 4.92, z))
        }

        // Semaphore signal mast right beside the stop marker (+44m ahead of center)
        let sigX: Float = 2.65, sigZ: Float = 44.5
        addStatic(SCNBox(width: 0.18, height: 6.2, length: 0.18, chamferRadius: 0), darkIron, V3(sigX, 3.1, sigZ))

        // Flatten all static station architecture into a single draw call!
        root.addChildNode(staticGroup.flattenedClone())

        // Emissive station windows & lantern globes (grouped & sharing `warmGlowMat`)
        let glowGroup = SCNNode()
        for z: Float in [-5.2, 5.2] {
            let w = SCNBox(width: 0.22, height: 1.3, length: 1.8, chamferRadius: 0)
            w.materials = [warmGlowMat]
            let n = SCNNode(geometry: w)
            n.simdPosition = V3(7.95, 2.85, z)
            glowGroup.addChildNode(n)
        }
        for z in lampZ {
            let bulb = SCNBox(width: 0.34, height: 0.40, length: 0.34, chamferRadius: 0.04)
            bulb.materials = [warmGlowMat]
            let n = SCNNode(geometry: bulb)
            n.simdPosition = V3(5.6, 4.68, z)
            glowGroup.addChildNode(n)
        }
        let flatGlow = glowGroup.flattenedClone()
        flatGlow.geometry?.materials = [warmGlowMat]
        flatGlow.castsShadow = false
        root.addChildNode(flatGlow)

        // Animated semaphore arm + signal lamp
        let pivot = SCNNode()
        pivot.simdPosition = V3(sigX, 5.65, sigZ - 0.12)
        let armGeom = SCNBox(width: 1.65, height: 0.26, length: 0.08, chamferRadius: 0)
        armGeom.materials = [mat(rgb(0.85, 0.12, 0.10))]
        let armNode = SCNNode(geometry: armGeom)
        armNode.simdPosition = V3(-0.78, 0, 0)
        pivot.addChildNode(armNode)
        let stripeGeom = SCNBox(width: 0.22, height: 0.27, length: 0.09, chamferRadius: 0)
        stripeGeom.materials = [mat(rgb(0.96, 0.96, 0.96))]
        let stripeNode = SCNNode(geometry: stripeGeom)
        stripeNode.simdPosition = V3(-1.2, 0, 0)
        pivot.addChildNode(stripeNode)
        root.addChildNode(pivot)
        semaphorePivot = pivot

        let lens = SCNSphere(radius: 0.18)
        lens.segmentCount = 10
        lens.materials = [signalLampMat]
        let lensNode = SCNNode(geometry: lens)
        lensNode.simdPosition = V3(sigX, 5.15, sigZ - 0.16)
        lensNode.castsShadow = false
        root.addChildNode(lensNode)

        // Crisp extruded station name text on both sign boards
        let whiteMat = mat(PColor.white)
        for z: Float in [-24, 24] {
            let text = SCNText(string: name, extrusionDepth: 0.35)
            text.font = PFont.boldSystemFont(ofSize: 10)
            text.flatness = 0.5
            text.materials = [whiteMat]
            let label = SCNNode(geometry: text)
            let (lo, hi) = text.boundingBox
            var pivotMat = matrix_identity_float4x4
            pivotMat.columns.3 = SIMD4((Float(lo.x) + Float(hi.x)) / 2, (Float(lo.y) + Float(hi.y)) / 2, 0, 1)
            label.simdPivot = pivotMat
            label.simdScale = V3(0.085, 0.085, 0.085)
            label.simdEulerAngles = V3(0, -.pi / 2, 0)
            label.simdPosition = V3(6.58, 3.6, z)
            label.castsShadow = false
            root.addChildNode(label)
        }
    }

    // MARK: Passengers

    private func makePassenger() -> SCNNode {
        let node = SCNNode()
        let bodyNode = SCNNode(geometry: PassengerAssets.bodies.randomElement(using: &rng)!)
        bodyNode.simdPosition = V3(0, 0.72, 0)
        let headNode = SCNNode(geometry: PassengerAssets.head)
        headNode.simdPosition = V3(0, 1.62, 0)
        node.addChildNode(bodyNode)
        node.addChildNode(headNode)
        if Bool.random(using: &rng) {
            let bagNode = SCNNode(geometry: PassengerAssets.suitcase)
            bagNode.simdPosition = V3(0.34, 0.22, 0)
            node.addChildNode(bagNode)
        }
        return node
    }

    func restock() {
        needsRestock = false
        guard waiting.isEmpty else { return }
        for _ in 0..<Int.random(in: 4...9, using: &rng) {
            let p = makePassenger()
            let d = distance + Float.random(in: -70 ... -10, using: &rng)
            p.simdPosition = track.offsetPoint(d, lateral: Float.random(in: 3.3...5.8, using: &rng),
                                               height: Station.platformTop)
            people.addChildNode(p)
            waiting.append(p)
        }
    }

    /// Walks waiting passengers to the coaches and lets `count` passengers off. Returns how many boarded.
    func exchange(head: Float, coachOffsets: [Float], deboarding count: Int) -> Int {
        let top = Station.platformTop
        let doors = coachOffsets.flatMap { offset in
            [-5.5, 5.5].map { self.track.offsetPoint(head - offset + Float($0), lateral: 1.9, height: top) }
        }

        for i in 0..<count {
            let p = makePassenger()
            p.simdPosition = doors[i % doors.count]
            p.opacity = 0
            people.addChildNode(p)
            let jitter = V3(Float.random(in: -0.6...0.6, using: &rng), 0, Float.random(in: -0.6...0.6, using: &rng))
            let target = doorPoint + jitter
            let walk = Double(simd_distance(p.simdPosition, target) / 3.2)
            p.runAction(.sequence([
                .wait(duration: 0.4 + Double(i) * 0.28),
                .fadeIn(duration: 0.25),
                .move(to: SCNVector3(target), duration: walk),
                .fadeOut(duration: 0.3),
                .removeFromParentNode(),
            ]))
        }

        let boarding = waiting
        waiting = []
        needsRestock = true
        for (i, p) in boarding.enumerated() {
            let door = doors.min { simd_distance($0, p.simdPosition) < simd_distance($1, p.simdPosition) }!
            let walk = Double(simd_distance(p.simdPosition, door) / 3.2)
            p.runAction(.sequence([
                .wait(duration: 1.2 + Double(i) * 0.3),
                .move(to: SCNVector3(door), duration: walk),
                .fadeOut(duration: 0.3),
                .removeFromParentNode(),
            ]))
        }
        return boarding.count
    }
}
