import SceneKit
import simd

/// A steam locomotive, tender and three coaches built from shared, batched primitives.
/// Every car's origin sits at its centre, on top of the rails, facing +Z.
final class Train {
    struct Car {
        let node: SCNNode
        /// Distance from the front of the train back to this car's centre.
        let offset: Float
        let halfWheelbase: Float
    }

    static let railTop: Float = 0.33
    static let totalLength: Float = 70.4

    private(set) var cars: [Car] = []
    /// Offsets (behind the head) of the coach centres, used as door positions.
    let coachOffsets: [Float] = [26.7, 44.3, 61.9]
    let locoOffset: Float = 5.5

    private var axles: [(pivot: SCNNode, radius: Float)] = []
    private var leftRod: SCNNode?
    private var rightRod: SCNNode?

    private let smoke = SCNParticleSystem()
    private let whistleSteam = SCNParticleSystem()
    private let cylinderSteamL = SCNParticleSystem()
    private let cylinderSteamR = SCNParticleSystem()

    private let headlight = SCNLight()
    private let headlightBeamMat = SCNMaterial()
    private let headlightLensMat = SCNMaterial()
    private let fireboxMat = SCNMaterial()
    private let coachWindowMat = SCNMaterial()

    // Cached flattened prototypes so identical axles and coaches share GPU geometry.
    private var axlePrototypes: [String: SCNNode] = [:]
    private var coachBodyPrototype: SCNNode?
    private var coachWindowsPrototype: SCNNode?

    init() {
        setupSharedMaterials()
        cars.append(Car(node: buildLocomotive(), offset: locoOffset, halfWheelbase: 3.4))
        cars.append(Car(node: buildTender(), offset: 14.6, halfWheelbase: 1.7))
        for offset in coachOffsets {
            cars.append(Car(node: buildCoach(), offset: offset, halfWheelbase: 5.6))
        }
    }

    private func setupSharedMaterials() {
        coachWindowMat.lightingModel = .blinn
        coachWindowMat.diffuse.contents = rgb(0.10, 0.14, 0.18)
        coachWindowMat.specular.contents = rgb(0.35, 0.35, 0.40)
        coachWindowMat.emission.contents = rgb(0, 0, 0)

        headlightLensMat.lightingModel = .blinn
        headlightLensMat.diffuse.contents = rgb(1.0, 0.96, 0.78)
        headlightLensMat.emission.contents = rgb(0.95, 0.85, 0.55)

        headlightBeamMat.lightingModel = .constant
        headlightBeamMat.diffuse.contents = rgb(1.0, 0.94, 0.74, 0.0)
        headlightBeamMat.blendMode = .add
        headlightBeamMat.writesToDepthBuffer = false
        headlightBeamMat.isDoubleSided = false

        fireboxMat.lightingModel = .constant
        fireboxMat.diffuse.contents = rgb(1.0, 0.42, 0.08)
        fireboxMat.emission.contents = rgb(0.8, 0.25, 0.04)
    }

    func place(on track: Track, head: Float, odometer: Float, speed: Float = 0) {
        let speedSq = min(speed, 27) * min(speed, 27)
        for car in cars {
            let d = head - car.offset
            let front = track.point(at: d + car.halfWheelbase)
            let back = track.point(at: d - car.halfWheelbase)
            let forward = simd_normalize(front - back)
            var side = simd_normalize(simd_cross(V3(0, 1, 0), forward))
            var up = simd_cross(forward, side)

            // Subtle curve banking (superelevation) adds weight and dynamism in bends.
            let curv = track.curvature(at: d)
            let bank = clamp(curv * speedSq * 0.022, -0.075, 0.075)
            if abs(bank) > 0.0005 {
                let c = cos(bank), s = sin(bank)
                let newSide = side * c + up * s
                let newUp = up * c - side * s
                side = newSide
                up = newUp
            }

            let center = (front + back) / 2 + up * Train.railTop
            car.node.simdTransform = makeTransform(side: side, up: up, forward: forward, position: center)
        }

        let twoPi = Float.pi * 2
        for axle in axles {
            let angle = (odometer / axle.radius).truncatingRemainder(dividingBy: twoPi)
            axle.pivot.simdRotation = SIMD4(1, 0, 0, angle)
        }

        // Animate locomotive coupling rods in sync with the 0.8m driving wheels (quartered 90° left/right).
        let driveAngle = (odometer / 0.8).truncatingRemainder(dividingBy: twoPi)
        let crankRadius: Float = 0.30
        if let rightRod {
            rightRod.simdPosition = V3(
                1.02,
                0.80 - sin(driveAngle) * crankRadius,
                0.50 + cos(driveAngle) * crankRadius
            )
        }
        if let leftRod {
            let leftAngle = driveAngle + .pi / 2
            leftRod.simdPosition = V3(
                -1.02,
                0.80 - sin(leftAngle) * crankRadius,
                0.50 + cos(leftAngle) * crankRadius
            )
        }
    }

    func updateEffects(power: Float, speed: Float, hornOn: Bool, nightLevel: Float,
                       tunnelFactor: Float, fogFactor: Float, time: Float) {
        // Chimney smoke: darker, vigorous plumes under power; pale wispy steam when coasting.
        smoke.birthRate = CGFloat(5 + 52 * power + min(speed, 10) * 0.9)
        smoke.particleVelocity = CGFloat(3.8 + 5.2 * power)
        let shade = lerp(0.92, 0.42, power)
        let alpha = lerp(0.45, 0.68, power)
        smoke.particleColor = rgb(shade, shade, shade * 1.02, alpha)

        // Brass steam whistle plume while horn is sounding.
        whistleSteam.birthRate = hornOn ? 85 : 0

        // Cylinder steam puffs when pulling away from a standstill under power.
        let cylRate: CGFloat = (power > 0.1 && speed < 7.5)
            ? CGFloat(32 * power * (1 - speed / 7.5))
            : 0
        cylinderSteamL.birthRate = cylRate
        cylinderSteamR.birthRate = cylRate

        // Warm coach windows, headlight spotlight & subtle light cone at dusk/night/fog/tunnel.
        let lampLevel = clamp(max(nightLevel, max(tunnelFactor, fogFactor * 0.65)), 0, 1)
        headlight.intensity = CGFloat(lampLevel * 2800)
        headlightLensMat.emission.contents = rgb(
            lerp(0.6, 1.0, lampLevel),
            lerp(0.55, 0.94, lampLevel),
            lerp(0.35, 0.72, lampLevel)
        )
        let beamAlpha = clamp(lampLevel * 0.18 + fogFactor * lampLevel * 0.14, 0, 0.30)
        headlightBeamMat.diffuse.contents = rgb(1.0, 0.93, 0.72, beamAlpha)

        let windowGlow = clamp(max(nightLevel * 1.15 - 0.12, tunnelFactor * 0.95), 0, 1)
        coachWindowMat.emission.contents = rgb(1.0 * windowGlow, 0.74 * windowGlow, 0.30 * windowGlow)
        coachWindowMat.diffuse.contents = rgb(
            lerp(0.10, 0.95, windowGlow),
            lerp(0.14, 0.76, windowGlow),
            lerp(0.18, 0.38, windowGlow)
        )

        // Subtle flickering coal firebox glow inside the cab.
        let flicker = 0.85 + 0.15 * sin(time * 13.7) * sin(time * 5.3)
        let fire = (0.35 + 0.65 * power) * flicker * (0.5 + 0.5 * lampLevel)
        fireboxMat.emission.contents = rgb(1.0 * fire, 0.38 * fire, 0.05 * fire)
    }

    // MARK: Parts

    private func material(_ color: PColor, emission: PColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = color
        m.specular.contents = rgb(0.25, 0.25, 0.25)
        if let emission { m.emission.contents = emission }
        return m
    }

    private func part(_ geometry: SCNGeometry, _ mat: SCNMaterial, at position: V3,
                      euler: V3 = V3(0, 0, 0)) -> SCNNode {
        geometry.materials = [mat]
        let node = SCNNode(geometry: geometry)
        node.simdPosition = position
        node.simdEulerAngles = euler
        return node
    }

    private func box(_ w: Float, _ h: Float, _ l: Float, chamfer: Float = 0) -> SCNBox {
        SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: CGFloat(chamfer))
    }

    private func cylinder(_ radius: Float, _ height: Float, segments: Int = 18) -> SCNCylinder {
        let c = SCNCylinder(radius: CGFloat(radius), height: CGFloat(height))
        c.radialSegmentCount = segments
        return c
    }

    /// Adds a single flattened wheelset (left wheel, right wheel, counterweights, and axle rod)
    /// sharing geometry across identical axles — cuts wheel draw calls by 6x.
    private func addAxle(key: String, radius: Float, z: Float, color: PColor, into parent: SCNNode) {
        let proto: SCNNode
        if let existing = axlePrototypes[key] {
            proto = existing
        } else {
            let group = SCNNode()
            let wheelMat = material(color)
            let darkMat = material(rgb(0.08, 0.08, 0.08))
            let steelMat = material(rgb(0.22, 0.22, 0.25))

            // Connecting axle shaft
            group.addChildNode(part(cylinder(min(radius * 0.22, 0.14), 1.85, segments: 10), steelMat,
                                    at: V3(0, 0, 0), euler: V3(0, 0, .pi / 2)))
            for x: Float in [-0.85, 0.85] {
                group.addChildNode(part(cylinder(radius, 0.22, segments: 18), wheelMat,
                                        at: V3(x, 0, 0), euler: V3(0, 0, .pi / 2)))
                let outward: Float = x > 0 ? 0.12 : -0.12
                // Counterweight crescent makes wheel rotation unmistakable.
                group.addChildNode(part(box(0.07, radius * 0.65, radius * 0.34), darkMat,
                                        at: V3(x + outward, radius * 0.42, 0)))
                group.addChildNode(part(cylinder(radius * 0.25, 0.28, segments: 12), darkMat,
                                        at: V3(x, 0, 0), euler: V3(0, 0, .pi / 2)))
            }
            proto = group.flattenedClone()
            axlePrototypes[key] = proto
        }

        let pivot = proto.clone()
        pivot.simdPosition = V3(0, radius, z)
        parent.addChildNode(pivot)
        axles.append((pivot, radius))
    }

    private func buildLocomotive() -> SCNNode {
        let car = SCNNode()
        let body = SCNNode()
        let black = material(rgb(0.07, 0.07, 0.08))
        let green = material(rgb(0.05, 0.30, 0.16))
        let red = material(rgb(0.70, 0.08, 0.08))
        let brass = material(rgb(0.85, 0.65, 0.20))
        let glass = material(rgb(0.10, 0.14, 0.18))
        let steel = material(rgb(0.72, 0.74, 0.78))

        body.addChildNode(part(box(2.0, 0.45, 10.6), black, at: V3(0, 1.25, 0)))
        body.addChildNode(part(box(2.6, 0.12, 7.2), black, at: V3(0, 1.5, 1.7)))                 // running board
        body.addChildNode(part(cylinder(1.0, 6.4, segments: 20), green, at: V3(0, 2.5, 1.3), euler: V3(.pi / 2, 0, 0)))
        body.addChildNode(part(cylinder(1.04, 1.0, segments: 20), black, at: V3(0, 2.5, 4.8), euler: V3(.pi / 2, 0, 0)))
        for z: Float in [-0.6, 1.0, 2.6] {                                                      // boiler bands
            body.addChildNode(part(cylinder(1.02, 0.12, segments: 20), brass, at: V3(0, 2.5, z), euler: V3(.pi / 2, 0, 0)))
        }
        body.addChildNode(part(cylinder(0.3, 1.2, segments: 16), black, at: V3(0, 3.95, 4.7)))  // chimney
        body.addChildNode(part(cylinder(0.38, 0.16, segments: 16), brass, at: V3(0, 4.55, 4.7)))
        let dome1 = SCNSphere(radius: 0.42); dome1.segmentCount = 16
        let dome2 = SCNSphere(radius: 0.36); dome2.segmentCount = 16
        body.addChildNode(part(dome1, brass, at: V3(0, 3.45, 2.2)))
        body.addChildNode(part(dome2, brass, at: V3(0, 3.42, 0.3)))
        // Brass steam whistle perched right in front of the cab
        body.addChildNode(part(cylinder(0.08, 0.55, segments: 10), brass, at: V3(0.28, 3.58, -1.6)))
        body.addChildNode(part(box(2.7, 2.5, 2.8), green, at: V3(0, 2.6, -3.6)))                // cab
        body.addChildNode(part(box(2.74, 0.8, 1.3), glass, at: V3(0, 3.1, -3.6)))
        body.addChildNode(part(box(1.6, 0.6, 2.84), glass, at: V3(0, 3.2, -3.6)))
        body.addChildNode(part(box(3.0, 0.14, 3.4), black, at: V3(0, 3.92, -3.6)))
        body.addChildNode(part(box(2.6, 0.5, 0.3), red, at: V3(0, 1.0, 5.4)))                   // buffer beam
        // Front buffers
        for x: Float in [-0.85, 0.85] {
            body.addChildNode(part(cylinder(0.18, 0.45, segments: 12), black,
                                   at: V3(x, 1.0, 5.62), euler: V3(.pi / 2, 0, 0)))
        }
        // Steam cylinders
        for x: Float in [-1.15, 1.15] {
            body.addChildNode(part(cylinder(0.36, 1.3, segments: 14), black,
                                   at: V3(x, 0.9, 3.5), euler: V3(.pi / 2, 0, 0)))
        }
        car.addChildNode(body.flattenedClone())

        // Animated coupling rods (left & right) orbiting with the driving wheels.
        let rodGeom = box(0.08, 0.14, 4.1)
        rodGeom.materials = [steel]
        let lRod = SCNNode(geometry: rodGeom)
        lRod.simdPosition = V3(-1.02, 0.80, 0.50)
        let rRod = SCNNode(geometry: rodGeom)
        rRod.simdPosition = V3(1.02, 0.80, 0.50)
        car.addChildNode(lRod)
        car.addChildNode(rRod)
        leftRod = lRod
        rightRod = rRod

        // Dynamic headlight lens, spotlight, and subtle volumetric beam cone.
        car.addChildNode(part(cylinder(0.23, 0.26, segments: 14), headlightLensMat,
                              at: V3(0, 3.72, 5.25), euler: V3(.pi / 2, 0, 0)))

        headlight.type = .spot
        headlight.color = rgb(1.0, 0.92, 0.72)
        headlight.intensity = 0
        headlight.spotInnerAngle = 14
        headlight.spotOuterAngle = 38
        headlight.attenuationStartDistance = 12
        headlight.attenuationEndDistance = 120
        headlight.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = headlight
        lightNode.simdPosition = V3(0, 3.72, 5.45)
        lightNode.simdEulerAngles = V3(-0.08, .pi, 0) // SCNLight aims down local -Z; rotate to +Z.
        car.addChildNode(lightNode)

        let beamCone = SCNCone(topRadius: 0.22, bottomRadius: 3.4, height: 26)
        beamCone.radialSegmentCount = 16
        beamCone.materials = [headlightBeamMat]
        let beamNode = SCNNode(geometry: beamCone)
        beamNode.simdPosition = V3(0, 2.75, 18.2)
        beamNode.simdEulerAngles = V3(-.pi / 2 + 0.075, 0, 0)
        beamNode.castsShadow = false
        car.addChildNode(beamNode)

        // Warm glowing firebox inside the cab (visible in cab/chase views at dusk & night).
        car.addChildNode(part(box(0.85, 0.65, 0.12), fireboxMat, at: V3(0, 2.15, -2.28)))

        // Batched wheelsets (5 axles instead of 10 x 3 = 30 child nodes).
        for z: Float in [2.3, 0.5, -1.3] {
            addAxle(key: "drive", radius: 0.8, z: z, color: rgb(0.70, 0.08, 0.08), into: car)
        }
        addAxle(key: "lead", radius: 0.45, z: 4.3, color: rgb(0.70, 0.08, 0.08), into: car)
        addAxle(key: "trail", radius: 0.5, z: -3.6, color: rgb(0.70, 0.08, 0.08), into: car)

        configureParticles()
        let chimneyTop = SCNNode()
        chimneyTop.simdPosition = V3(0, 4.7, 4.7)
        chimneyTop.addParticleSystem(smoke)
        car.addChildNode(chimneyTop)

        let whistleNode = SCNNode()
        whistleNode.simdPosition = V3(0.28, 3.88, -1.6)
        whistleNode.addParticleSystem(whistleSteam)
        car.addChildNode(whistleNode)

        let cylL = SCNNode()
        cylL.simdPosition = V3(-1.35, 0.72, 3.6)
        cylL.addParticleSystem(cylinderSteamL)
        car.addChildNode(cylL)

        let cylR = SCNNode()
        cylR.simdPosition = V3(1.35, 0.72, 3.6)
        cylR.addParticleSystem(cylinderSteamR)
        car.addChildNode(cylR)

        return car
    }

    private func buildTender() -> SCNNode {
        let car = SCNNode()
        let body = SCNNode()
        body.addChildNode(part(box(2.0, 0.4, 5.6), material(rgb(0.07, 0.07, 0.08)), at: V3(0, 1.1, 0)))
        body.addChildNode(part(box(2.6, 1.9, 5.4), material(rgb(0.05, 0.30, 0.16)), at: V3(0, 2.2, 0)))
        body.addChildNode(part(box(2.1, 0.45, 4.2, chamfer: 0.2), material(rgb(0.04, 0.04, 0.04)), at: V3(0, 3.25, 0)))
        car.addChildNode(body.flattenedClone())
        for z: Float in [-1.7, 0, 1.7] {
            addAxle(key: "tender", radius: 0.5, z: z, color: rgb(0.1, 0.1, 0.1), into: car)
        }
        return car
    }

    private func buildCoach() -> SCNNode {
        let car = SCNNode()

        if coachBodyPrototype == nil {
            let body = SCNNode()
            let red = material(rgb(0.72, 0.10, 0.10))
            let cream = material(rgb(0.93, 0.89, 0.76))
            let dark = material(rgb(0.07, 0.07, 0.08))

            body.addChildNode(part(box(2.8, 2.5, 16.6, chamfer: 0.12), red, at: V3(0, 2.15, 0)))
            for i in 0...10 {                                                       // window pillars
                let z = -7.7 + Float(i) * 1.54
                body.addChildNode(part(box(2.87, 0.86, 0.32), red, at: V3(0, 2.7, z)))
            }
            body.addChildNode(part(box(2.85, 0.14, 16.6), cream, at: V3(0, 2.1, 0)))
            body.addChildNode(part(box(2.5, 0.32, 16.6, chamfer: 0.15), material(rgb(0.45, 0.46, 0.48)), at: V3(0, 3.52, 0)))
            for z: Float in [-5.6, 5.6] {
                body.addChildNode(part(box(2.0, 0.5, 3.0), dark, at: V3(0, 0.6, z)))
            }
            for z: Float in [-8.35, 8.35] {                                         // corridor bellows
                body.addChildNode(part(box(1.2, 2.0, 0.5), dark, at: V3(0, 2.0, z)))
            }
            coachBodyPrototype = body.flattenedClone()

            // Coach windows kept on a separate shared node so night emission updates in 1 material write.
            let win = box(2.84, 0.84, 15.4)
            win.materials = [coachWindowMat]
            let winNode = SCNNode(geometry: win)
            winNode.simdPosition = V3(0, 2.7, 0)
            coachWindowsPrototype = winNode
        }

        car.addChildNode(coachBodyPrototype!.clone())
        car.addChildNode(coachWindowsPrototype!.clone())
        for z: Float in [-6.5, -4.7, 4.7, 6.5] {
            addAxle(key: "coach", radius: 0.46, z: z, color: rgb(0.1, 0.1, 0.1), into: car)
        }
        return car
    }

    private func configureParticles() {
        // Main chimney smoke
        smoke.particleImage = Images.softDot
        smoke.birthRate = 6
        smoke.particleLifeSpan = 3.5
        smoke.particleLifeSpanVariation = 0.8
        smoke.particleVelocity = 5
        smoke.particleVelocityVariation = 1.5
        smoke.emittingDirection = SCNVector3(V3(0, 1, 0))
        smoke.spreadingAngle = 14
        smoke.acceleration = SCNVector3(V3(0, 0.6, 0))
        smoke.particleSize = 1.0
        smoke.particleSizeVariation = 0.3
        smoke.particleColor = rgb(0.92, 0.92, 0.92, 0.55)
        smoke.blendMode = .alpha
        smoke.isLightingEnabled = false
        smoke.isAffectedByGravity = false
        smoke.loops = true

        let grow = CABasicAnimation()
        grow.fromValue = 0.8
        grow.toValue = 4.8
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 0.6, 0.35, 0.0]
        fade.keyTimes = [0, 0.1, 0.6, 1]
        smoke.propertyControllers = [
            .size: SCNParticlePropertyController(animation: grow),
            .opacity: SCNParticlePropertyController(animation: fade),
        ]

        // Steam whistle puff
        whistleSteam.particleImage = Images.softDot
        whistleSteam.birthRate = 0
        whistleSteam.particleLifeSpan = 0.85
        whistleSteam.particleLifeSpanVariation = 0.2
        whistleSteam.particleVelocity = 6.5
        whistleSteam.particleVelocityVariation = 1.2
        whistleSteam.emittingDirection = SCNVector3(V3(0.08, 1, -0.15))
        whistleSteam.spreadingAngle = 16
        whistleSteam.particleSize = 0.38
        whistleSteam.particleSizeVariation = 0.14
        whistleSteam.particleColor = rgb(0.98, 0.99, 1.0, 0.72)
        whistleSteam.blendMode = .alpha
        whistleSteam.isLightingEnabled = false
        whistleSteam.isAffectedByGravity = false
        whistleSteam.loops = true

        let wGrow = CABasicAnimation()
        wGrow.fromValue = 0.4
        wGrow.toValue = 1.8
        let wFade = CAKeyframeAnimation()
        wFade.values = [0.0, 0.8, 0.0]
        wFade.keyTimes = [0, 0.18, 1]
        whistleSteam.propertyControllers = [
            .size: SCNParticlePropertyController(animation: wGrow),
            .opacity: SCNParticlePropertyController(animation: wFade),
        ]

        // Side cylinder steam wisps on departure
        for (ps, dir) in [(cylinderSteamL, V3(-1, 0.12, -0.2)), (cylinderSteamR, V3(1, 0.12, -0.2))] {
            ps.particleImage = Images.softDot
            ps.birthRate = 0
            ps.particleLifeSpan = 0.9
            ps.particleVelocity = 3.6
            ps.particleVelocityVariation = 0.8
            ps.emittingDirection = SCNVector3(dir)
            ps.spreadingAngle = 22
            ps.particleSize = 0.55
            ps.particleColor = rgb(0.96, 0.97, 1.0, 0.50)
            ps.blendMode = .alpha
            ps.isLightingEnabled = false
            ps.isAffectedByGravity = false
            ps.loops = true
            ps.propertyControllers = [
                .size: SCNParticlePropertyController(animation: wGrow),
                .opacity: SCNParticlePropertyController(animation: wFade),
            ]
        }
    }
}
