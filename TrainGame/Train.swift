import SceneKit
import simd

/// Builds and animates any of the three selectable trains (Steam Express, Shinkansen Bullet, Cargo Freight).
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

    let kind: TrainKind
    private(set) var cars: [Car] = []
    /// Offsets (behind the head) of the passenger/cargo car centres.
    let coachOffsets: [Float] = [26.7, 44.3, 61.9]
    let locoOffset: Float = 5.5

    private var axles: [(pivot: SCNNode, radius: Float)] = []
    private var leftRod: SCNNode?
    private var rightRod: SCNNode?
    private var cargoLoadNodes: [SCNNode] = []

    private let smoke = SCNParticleSystem()
    private let whistleSteam = SCNParticleSystem()
    private let cylinderSteamL = SCNParticleSystem()
    private let cylinderSteamR = SCNParticleSystem()

    private let headlight = SCNLight()
    private let headlightBeamMat = SCNMaterial()
    private let headlightLensMat = SCNMaterial()
    private let fireboxMat = SCNMaterial()
    private let coachWindowMat = SCNMaterial()

    private var axlePrototypes: [String: SCNNode] = [:]
    private var coachBodyPrototype: SCNNode?
    private var coachWindowsPrototype: SCNNode?

    init(kind: TrainKind = .steam) {
        self.kind = kind
        setupSharedMaterials()
        configureParticles()

        switch kind {
        case .steam:
            cars.append(Car(node: buildSteamLocomotive(), offset: locoOffset, halfWheelbase: 3.4))
            cars.append(Car(node: buildTender(), offset: 14.6, halfWheelbase: 1.7))
            for offset in coachOffsets {
                cars.append(Car(node: buildSteamCoach(), offset: offset, halfWheelbase: 5.6))
            }
        case .bullet:
            cars.append(Car(node: buildBulletLead(isTail: false), offset: 9.0, halfWheelbase: 6.0))
            cars.append(Car(node: buildBulletCoach(), offset: 26.8, halfWheelbase: 5.8))
            cars.append(Car(node: buildBulletCoach(), offset: 44.4, halfWheelbase: 5.8))
            cars.append(Car(node: buildBulletLead(isTail: true), offset: 62.2, halfWheelbase: 6.0))
        case .freight:
            cars.append(Car(node: buildFreightLocomotive(), offset: 7.5, halfWheelbase: 4.8))
            for (idx, offset) in coachOffsets.enumerated() {
                cars.append(Car(node: buildCargoFlatcar(variant: idx), offset: offset, halfWheelbase: 5.6))
            }
        }
    }

    private func setupSharedMaterials() {
        coachWindowMat.lightingModel = .blinn
        coachWindowMat.diffuse.contents = rgb(0.10, 0.14, 0.18)
        coachWindowMat.specular.contents = rgb(0.35, 0.35, 0.40)
        coachWindowMat.emission.contents = rgb(0, 0, 0)

        headlightLensMat.lightingModel = .blinn
        headlightLensMat.diffuse.contents = kind == .bullet ? rgb(0.92, 0.97, 1.0) : rgb(1.0, 0.96, 0.78)
        headlightLensMat.emission.contents = kind == .bullet ? rgb(0.85, 0.95, 1.0) : rgb(0.95, 0.85, 0.55)

        headlightBeamMat.lightingModel = .constant
        headlightBeamMat.diffuse.contents = rgb(1.0, 0.94, 0.74, 0.0)
        headlightBeamMat.blendMode = .add
        headlightBeamMat.writesToDepthBuffer = false
        headlightBeamMat.isDoubleSided = false

        fireboxMat.lightingModel = .constant
        fireboxMat.diffuse.contents = rgb(1.0, 0.42, 0.08)
        fireboxMat.emission.contents = rgb(0.8, 0.25, 0.04)
    }

    /// Shows or hides visible cargo containers & timber on Freight flatcars with a snappy pop animation.
    func setCargoLoaded(_ loaded: Bool) {
        for (i, cargo) in cargoLoadNodes.enumerated() {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.35 + Double(i) * 0.08
            cargo.isHidden = !loaded
            cargo.simdScale = loaded ? V3(1, 1, 1) : V3(0.01, 0.01, 0.01)
            SCNTransaction.commit()
        }
    }

    func place(on track: Track, head: Float, odometer: Float, speed: Float = 0) {
        let speedSq = min(speed, kind.maxSpeed) * min(speed, kind.maxSpeed)
        for car in cars {
            let d = head - car.offset
            let front = track.point(at: d + car.halfWheelbase)
            let back = track.point(at: d - car.halfWheelbase)
            let forward = simd_normalize(front - back)
            var side = simd_normalize(simd_cross(V3(0, 1, 0), forward))
            var up = simd_cross(forward, side)

            let curv = track.curvature(at: d)
            let bankFactor: Float = kind == .bullet ? 0.012 : 0.022
            let bank = clamp(curv * speedSq * bankFactor, -0.085, 0.085)
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

        if let rightRod, let leftRod {
            let driveAngle = (odometer / 0.8).truncatingRemainder(dividingBy: twoPi)
            let crankRadius: Float = 0.30
            rightRod.simdPosition = V3(1.02, 0.80 - sin(driveAngle) * crankRadius, 0.50 + cos(driveAngle) * crankRadius)
            let leftAngle = driveAngle + .pi / 2
            leftRod.simdPosition = V3(-1.02, 0.80 - sin(leftAngle) * crankRadius, 0.50 + cos(leftAngle) * crankRadius)
        }
    }

    func updateEffects(power: Float, speed: Float, hornOn: Bool, nightLevel: Float,
                       tunnelFactor: Float, fogFactor: Float, time: Float) {
        switch kind {
        case .steam:
            smoke.birthRate = CGFloat(5 + 52 * power + min(speed, 10) * 0.9)
            smoke.particleVelocity = CGFloat(3.8 + 5.2 * power)
            let shade = lerp(0.92, 0.42, power)
            let alpha = lerp(0.45, 0.68, power)
            smoke.particleColor = rgb(shade, shade, shade * 1.02, alpha)
            whistleSteam.birthRate = hornOn ? 85 : 0
            let cylRate: CGFloat = (power > 0.1 && speed < 7.5) ? CGFloat(32 * power * (1 - speed / 7.5)) : 0
            cylinderSteamL.birthRate = cylRate
            cylinderSteamR.birthRate = cylRate

        case .bullet:
            // Clean electric Shinkansen — zero exhaust!
            smoke.birthRate = 0
            whistleSteam.birthRate = 0
            cylinderSteamL.birthRate = 0
            cylinderSteamR.birthRate = 0

        case .freight:
            // Subtle diesel exhaust plume scaling with throttle notch
            smoke.birthRate = CGFloat(2 + 24 * power)
            smoke.particleVelocity = CGFloat(2.5 + 3.5 * power)
            smoke.particleColor = rgb(0.32, 0.33, 0.36, 0.22 + 0.25 * power)
            whistleSteam.birthRate = 0
            cylinderSteamL.birthRate = 0
            cylinderSteamR.birthRate = 0
        }

        let lampLevel = clamp(max(nightLevel, max(tunnelFactor, fogFactor * 0.65)), 0, 1)
        headlight.intensity = CGFloat(lampLevel * (kind == .bullet ? 3400 : 2800))
        if kind == .bullet {
            headlightLensMat.emission.contents = rgb(0.90, 0.96, 1.0)
            let beamAlpha = clamp(lampLevel * 0.20 + fogFactor * lampLevel * 0.14, 0, 0.32)
            headlightBeamMat.diffuse.contents = rgb(0.86, 0.95, 1.0, beamAlpha)
        } else {
            headlightLensMat.emission.contents = rgb(lerp(0.6, 1.0, lampLevel), lerp(0.55, 0.94, lampLevel), lerp(0.35, 0.72, lampLevel))
            let beamAlpha = clamp(lampLevel * 0.18 + fogFactor * lampLevel * 0.14, 0, 0.30)
            headlightBeamMat.diffuse.contents = rgb(1.0, 0.93, 0.72, beamAlpha)
        }

        let windowGlow = clamp(max(nightLevel * 1.15 - 0.12, tunnelFactor * 0.95), 0, 1)
        if kind == .bullet {
            // Crisp modern warm-white interior lighting for Shinkansen coaches
            coachWindowMat.emission.contents = rgb(0.95 * windowGlow, 0.94 * windowGlow, 0.85 * windowGlow)
            coachWindowMat.diffuse.contents = rgb(lerp(0.10, 0.96, windowGlow), lerp(0.14, 0.94, windowGlow), lerp(0.20, 0.86, windowGlow))
        } else {
            coachWindowMat.emission.contents = rgb(1.0 * windowGlow, 0.74 * windowGlow, 0.30 * windowGlow)
            coachWindowMat.diffuse.contents = rgb(lerp(0.10, 0.95, windowGlow), lerp(0.14, 0.76, windowGlow), lerp(0.18, 0.38, windowGlow))
        }

        if kind == .steam {
            let flicker = 0.85 + 0.15 * sin(time * 13.7) * sin(time * 5.3)
            let fire = (0.35 + 0.65 * power) * flicker * (0.5 + 0.5 * lampLevel)
            fireboxMat.emission.contents = rgb(1.0 * fire, 0.38 * fire, 0.05 * fire)
        }
    }

    // MARK: Shared Helpers

    private func material(_ color: PColor, emission: PColor? = nil) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .blinn
        m.diffuse.contents = color
        m.specular.contents = rgb(0.28, 0.28, 0.30)
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

    private func attachHeadlight(to car: SCNNode, lensPos: V3, beamZ: Float) {
        headlight.type = .spot
        headlight.color = kind == .bullet ? rgb(0.90, 0.96, 1.0) : rgb(1.0, 0.92, 0.72)
        headlight.intensity = 0
        headlight.spotInnerAngle = 15
        headlight.spotOuterAngle = 40
        headlight.attenuationStartDistance = 12
        headlight.attenuationEndDistance = 130
        headlight.castsShadow = false
        let lightNode = SCNNode()
        lightNode.light = headlight
        lightNode.simdPosition = lensPos + V3(0, 0, 0.25)
        lightNode.simdEulerAngles = V3(-0.08, .pi, 0)
        car.addChildNode(lightNode)

        let beamCone = SCNCone(topRadius: 0.24, bottomRadius: 3.6, height: 28)
        beamCone.radialSegmentCount = 16
        beamCone.materials = [headlightBeamMat]
        let beamNode = SCNNode(geometry: beamCone)
        beamNode.simdPosition = V3(0, lensPos.y - 1.0, beamZ)
        beamNode.simdEulerAngles = V3(-.pi / 2 + 0.075, 0, 0)
        beamNode.castsShadow = false
        car.addChildNode(beamNode)
    }

    private func addAxle(key: String, radius: Float, z: Float, color: PColor, into parent: SCNNode) {
        let proto: SCNNode
        if let existing = axlePrototypes[key] {
            proto = existing
        } else {
            let group = SCNNode()
            let wheelMat = material(color)
            let darkMat = material(rgb(0.08, 0.08, 0.08))
            let steelMat = material(rgb(0.22, 0.22, 0.25))

            group.addChildNode(part(cylinder(min(radius * 0.22, 0.14), 1.85, segments: 10), steelMat,
                                    at: V3(0, 0, 0), euler: V3(0, 0, .pi / 2)))
            for x: Float in [-0.85, 0.85] {
                group.addChildNode(part(cylinder(radius, 0.22, segments: 18), wheelMat,
                                        at: V3(x, 0, 0), euler: V3(0, 0, .pi / 2)))
                let outward: Float = x > 0 ? 0.12 : -0.12
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

    // MARK: 1. Steam Express

    private func buildSteamLocomotive() -> SCNNode {
        let car = SCNNode()
        let body = SCNNode()
        let black = material(rgb(0.07, 0.07, 0.08))
        let green = material(rgb(0.05, 0.30, 0.16))
        let red = material(rgb(0.70, 0.08, 0.08))
        let brass = material(rgb(0.85, 0.65, 0.20))
        let glass = material(rgb(0.10, 0.14, 0.18))
        let steel = material(rgb(0.72, 0.74, 0.78))

        body.addChildNode(part(box(2.0, 0.45, 10.6), black, at: V3(0, 1.25, 0)))
        body.addChildNode(part(box(2.6, 0.12, 7.2), black, at: V3(0, 1.5, 1.7)))
        body.addChildNode(part(cylinder(1.0, 6.4, segments: 20), green, at: V3(0, 2.5, 1.3), euler: V3(.pi / 2, 0, 0)))
        body.addChildNode(part(cylinder(1.04, 1.0, segments: 20), black, at: V3(0, 2.5, 4.8), euler: V3(.pi / 2, 0, 0)))
        for z: Float in [-0.6, 1.0, 2.6] {
            body.addChildNode(part(cylinder(1.02, 0.12, segments: 20), brass, at: V3(0, 2.5, z), euler: V3(.pi / 2, 0, 0)))
        }
        body.addChildNode(part(cylinder(0.3, 1.2, segments: 16), black, at: V3(0, 3.95, 4.7)))
        body.addChildNode(part(cylinder(0.38, 0.16, segments: 16), brass, at: V3(0, 4.55, 4.7)))
        let dome1 = SCNSphere(radius: 0.42); dome1.segmentCount = 16
        let dome2 = SCNSphere(radius: 0.36); dome2.segmentCount = 16
        body.addChildNode(part(dome1, brass, at: V3(0, 3.45, 2.2)))
        body.addChildNode(part(dome2, brass, at: V3(0, 3.42, 0.3)))
        body.addChildNode(part(cylinder(0.08, 0.55, segments: 10), brass, at: V3(0.28, 3.58, -1.6)))
        body.addChildNode(part(box(2.7, 2.5, 2.8), green, at: V3(0, 2.6, -3.6)))
        body.addChildNode(part(box(2.74, 0.8, 1.3), glass, at: V3(0, 3.1, -3.6)))
        body.addChildNode(part(box(1.6, 0.6, 2.84), glass, at: V3(0, 3.2, -3.6)))
        body.addChildNode(part(box(3.0, 0.14, 3.4), black, at: V3(0, 3.92, -3.6)))
        body.addChildNode(part(box(2.6, 0.5, 0.3), red, at: V3(0, 1.0, 5.4)))
        for x: Float in [-0.85, 0.85] {
            body.addChildNode(part(cylinder(0.18, 0.45, segments: 12), black, at: V3(x, 1.0, 5.62), euler: V3(.pi / 2, 0, 0)))
        }
        for x: Float in [-1.15, 1.15] {
            body.addChildNode(part(cylinder(0.36, 1.3, segments: 14), black, at: V3(x, 0.9, 3.5), euler: V3(.pi / 2, 0, 0)))
        }
        car.addChildNode(body.flattenedClone())

        let rodGeom = box(0.08, 0.14, 4.1)
        rodGeom.materials = [steel]
        let lRod = SCNNode(geometry: rodGeom); lRod.simdPosition = V3(-1.02, 0.80, 0.50)
        let rRod = SCNNode(geometry: rodGeom); rRod.simdPosition = V3(1.02, 0.80, 0.50)
        car.addChildNode(lRod); car.addChildNode(rRod)
        leftRod = lRod; rightRod = rRod

        car.addChildNode(part(cylinder(0.23, 0.26, segments: 14), headlightLensMat,
                              at: V3(0, 3.72, 5.25), euler: V3(.pi / 2, 0, 0)))
        attachHeadlight(to: car, lensPos: V3(0, 3.72, 5.25), beamZ: 19.2)
        car.addChildNode(part(box(0.85, 0.65, 0.12), fireboxMat, at: V3(0, 2.15, -2.28)))

        for z: Float in [2.3, 0.5, -1.3] {
            addAxle(key: "drive", radius: 0.8, z: z, color: rgb(0.70, 0.08, 0.08), into: car)
        }
        addAxle(key: "lead", radius: 0.45, z: 4.3, color: rgb(0.70, 0.08, 0.08), into: car)
        addAxle(key: "trail", radius: 0.5, z: -3.6, color: rgb(0.70, 0.08, 0.08), into: car)

        let chimneyTop = SCNNode(); chimneyTop.simdPosition = V3(0, 4.7, 4.7); chimneyTop.addParticleSystem(smoke)
        let whistleNode = SCNNode(); whistleNode.simdPosition = V3(0.28, 3.88, -1.6); whistleNode.addParticleSystem(whistleSteam)
        let cylL = SCNNode(); cylL.simdPosition = V3(-1.35, 0.72, 3.6); cylL.addParticleSystem(cylinderSteamL)
        let cylR = SCNNode(); cylR.simdPosition = V3(1.35, 0.72, 3.6); cylR.addParticleSystem(cylinderSteamR)
        car.addChildNode(chimneyTop); car.addChildNode(whistleNode); car.addChildNode(cylL); car.addChildNode(cylR)
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

    private func buildSteamCoach() -> SCNNode {
        let car = SCNNode()
        if coachBodyPrototype == nil {
            let body = SCNNode()
            let red = material(rgb(0.72, 0.10, 0.10))
            let cream = material(rgb(0.93, 0.89, 0.76))
            let dark = material(rgb(0.07, 0.07, 0.08))
            body.addChildNode(part(box(2.8, 2.5, 16.6, chamfer: 0.12), red, at: V3(0, 2.15, 0)))
            for i in 0...10 {
                body.addChildNode(part(box(2.87, 0.86, 0.32), red, at: V3(0, 2.7, -7.7 + Float(i) * 1.54)))
            }
            body.addChildNode(part(box(2.85, 0.14, 16.6), cream, at: V3(0, 2.1, 0)))
            body.addChildNode(part(box(2.5, 0.32, 16.6, chamfer: 0.15), material(rgb(0.45, 0.46, 0.48)), at: V3(0, 3.52, 0)))
            for z: Float in [-5.6, 5.6] { body.addChildNode(part(box(2.0, 0.5, 3.0), dark, at: V3(0, 0.6, z))) }
            for z: Float in [-8.35, 8.35] { body.addChildNode(part(box(1.2, 2.0, 0.5), dark, at: V3(0, 2.0, z))) }
            coachBodyPrototype = body.flattenedClone()

            let win = box(2.84, 0.84, 15.4)
            win.materials = [coachWindowMat]
            let winNode = SCNNode(geometry: win); winNode.simdPosition = V3(0, 2.7, 0)
            coachWindowsPrototype = winNode
        }
        car.addChildNode(coachBodyPrototype!.clone())
        car.addChildNode(coachWindowsPrototype!.clone())
        for z: Float in [-6.5, -4.7, 4.7, 6.5] {
            addAxle(key: "coach", radius: 0.46, z: z, color: rgb(0.1, 0.1, 0.1), into: car)
        }
        return car
    }

    // MARK: 2. Shinkansen Bullet Train

    private func buildBulletLead(isTail: Bool) -> SCNNode {
        let car = SCNNode()
        let body = SCNNode()
        let pearl = material(rgb(0.95, 0.96, 0.98))
        let cobalt = material(rgb(0.08, 0.32, 0.78))
        let sky = material(rgb(0.16, 0.58, 0.94))
        let dark = material(rgb(0.10, 0.12, 0.16))
        let visor = material(rgb(0.06, 0.09, 0.14))
        let sign: Float = isTail ? -1 : 1

        // Sleek aerodynamic hull
        body.addChildNode(part(box(2.9, 2.55, 13.0, chamfer: 0.55), pearl, at: V3(0, 2.15, -1.8 * sign)))
        // Iconic tapered Shinkansen bullet nose cone
        let nose = SCNCone(topRadius: 0.18, bottomRadius: 1.48, height: 6.4)
        nose.radialSegmentCount = 20
        body.addChildNode(part(nose, pearl, at: V3(0, 1.72, 6.4 * sign), euler: V3(sign * .pi / 2 - sign * 0.08, 0, 0)))
        // Aerodynamic skirt
        body.addChildNode(part(box(2.94, 0.75, 15.8, chamfer: 0.2), dark, at: V3(0, 0.85, -0.4 * sign)))
        // Cobalt & sky-blue Shinkansen racing stripes
        body.addChildNode(part(box(2.96, 0.34, 13.4), cobalt, at: V3(0, 1.65, -1.5 * sign)))
        body.addChildNode(part(box(2.96, 0.14, 14.0), sky, at: V3(0, 1.98, -1.2 * sign)))
        // Sloped wrap-around cockpit visor
        body.addChildNode(part(box(2.35, 0.68, 2.6, chamfer: 0.2), visor, at: V3(0, 2.82, 4.0 * sign), euler: V3(sign * 0.34, 0, 0)))
        // Roof pantograph
        body.addChildNode(part(box(1.4, 0.12, 1.6), dark, at: V3(0, 3.55, -5.2 * sign)))
        body.addChildNode(part(box(0.10, 0.75, 0.10), dark, at: V3(0, 3.92, -5.2 * sign), euler: V3(0.4, 0, 0)))
        body.addChildNode(part(box(1.5, 0.08, 0.22), dark, at: V3(0, 4.25, -5.0 * sign)))
        car.addChildNode(body.flattenedClone())

        // Glowing flush side windows
        let win = box(2.93, 0.62, 9.2)
        win.materials = [coachWindowMat]
        let winNode = SCNNode(geometry: win)
        winNode.simdPosition = V3(0, 2.55, -2.5 * sign)
        car.addChildNode(winNode)

        // Twin LED headlamps (front) or red tail lights (rear)
        let lampMat = isTail ? material(rgb(0.95, 0.14, 0.12), emission: rgb(0.95, 0.12, 0.10)) : headlightLensMat
        for x: Float in [-0.72, 0.72] {
            car.addChildNode(part(box(0.36, 0.18, 0.25), lampMat, at: V3(x, 1.78, 7.6 * sign)))
        }
        if !isTail {
            attachHeadlight(to: car, lensPos: V3(0, 1.85, 8.6), beamZ: 22.8)
        }

        for z: Float in [-6.0, -4.4, 3.6, 5.2] {
            addAxle(key: "bullet", radius: 0.44, z: z, color: rgb(0.14, 0.15, 0.18), into: car)
        }
        return car
    }

    private func buildBulletCoach() -> SCNNode {
        let car = SCNNode()
        if coachBodyPrototype == nil {
            let body = SCNNode()
            let pearl = material(rgb(0.95, 0.96, 0.98))
            let cobalt = material(rgb(0.08, 0.32, 0.78))
            let sky = material(rgb(0.16, 0.58, 0.94))
            let dark = material(rgb(0.10, 0.12, 0.16))

            body.addChildNode(part(box(2.9, 2.55, 16.8, chamfer: 0.55), pearl, at: V3(0, 2.15, 0)))
            body.addChildNode(part(box(2.94, 0.75, 16.8, chamfer: 0.18), dark, at: V3(0, 0.85, 0)))
            body.addChildNode(part(box(2.96, 0.34, 16.8), cobalt, at: V3(0, 1.65, 0)))
            body.addChildNode(part(box(2.96, 0.14, 16.8), sky, at: V3(0, 1.98, 0)))
            for i in 0...11 {
                body.addChildNode(part(box(2.95, 0.64, 0.24), pearl, at: V3(0, 2.55, -7.7 + Float(i) * 1.40)))
            }
            for z: Float in [-8.45, 8.45] {
                body.addChildNode(part(box(2.1, 2.2, 0.4), dark, at: V3(0, 2.0, z)))
            }
            coachBodyPrototype = body.flattenedClone()

            let win = box(2.93, 0.62, 15.6)
            win.materials = [coachWindowMat]
            let winNode = SCNNode(geometry: win); winNode.simdPosition = V3(0, 2.55, 0)
            coachWindowsPrototype = winNode
        }
        car.addChildNode(coachBodyPrototype!.clone())
        car.addChildNode(coachWindowsPrototype!.clone())
        for z: Float in [-6.4, -4.6, 4.6, 6.4] {
            addAxle(key: "bullet", radius: 0.44, z: z, color: rgb(0.14, 0.15, 0.18), into: car)
        }
        return car
    }

    // MARK: 3. Cargo Freight Diesel-Electric & Loadable Flatcars

    private func buildFreightLocomotive() -> SCNNode {
        let car = SCNNode()
        let body = SCNNode()
        let yellow = material(rgb(0.92, 0.68, 0.10))
        let navy = material(rgb(0.10, 0.18, 0.36))
        let dark = material(rgb(0.10, 0.10, 0.12))
        let steel = material(rgb(0.55, 0.57, 0.60))

        // Heavy steel underframe & front pilot
        body.addChildNode(part(box(2.85, 0.65, 13.8), dark, at: V3(0, 1.05, 0)))
        body.addChildNode(part(box(2.9, 0.20, 14.0), yellow, at: V3(0, 1.42, 0)))
        // Front cab
        body.addChildNode(part(box(2.8, 2.35, 3.6, chamfer: 0.12), yellow, at: V3(0, 2.65, 3.6)))
        body.addChildNode(part(box(2.92, 0.25, 3.9), navy, at: V3(0, 3.88, 3.6)))
        // Long diesel engine hood + side navy stripe + radiator grilles
        body.addChildNode(part(box(2.25, 2.0, 8.8, chamfer: 0.1), navy, at: V3(0, 2.48, -2.2)))
        body.addChildNode(part(box(2.30, 0.45, 8.85), yellow, at: V3(0, 1.85, -2.2)))
        body.addChildNode(part(box(2.32, 0.75, 2.4), steel, at: V3(0, 2.85, -4.4)))
        // Short nose hood in front of cab
        body.addChildNode(part(box(2.3, 1.25, 1.8, chamfer: 0.1), navy, at: V3(0, 2.08, 6.0)))
        // Exhaust stack
        body.addChildNode(part(cylinder(0.24, 0.55, segments: 12), dark, at: V3(0, 3.68, -0.8)))
        car.addChildNode(body.flattenedClone())

        // Glowing cab windshield
        let cabWin = box(2.84, 0.72, 3.64)
        cabWin.materials = [coachWindowMat]
        let winNode = SCNNode(geometry: cabWin); winNode.simdPosition = V3(0, 3.12, 3.6)
        car.addChildNode(winNode)

        // Dual front headlights
        for x: Float in [-0.55, 0.55] {
            car.addChildNode(part(cylinder(0.18, 0.22, segments: 12), headlightLensMat,
                                  at: V3(x, 2.22, 6.92), euler: V3(.pi / 2, 0, 0)))
        }
        attachHeadlight(to: car, lensPos: V3(0, 2.3, 6.95), beamZ: 21.0)

        let exhaust = SCNNode(); exhaust.simdPosition = V3(0, 4.0, -0.8); exhaust.addParticleSystem(smoke)
        car.addChildNode(exhaust)

        for z: Float in [-5.2, -3.5, 3.5, 5.2] {
            addAxle(key: "freight", radius: 0.50, z: z, color: rgb(0.14, 0.14, 0.16), into: car)
        }
        return car
    }

    private func buildCargoFlatcar(variant: Int) -> SCNNode {
        let car = SCNNode()
        let deck = SCNNode()
        let dark = material(rgb(0.16, 0.17, 0.19))
        let wood = material(rgb(0.45, 0.30, 0.17))
        let yellow = material(rgb(0.88, 0.65, 0.12))

        deck.addChildNode(part(box(2.85, 0.36, 16.4), dark, at: V3(0, 1.05, 0)))
        deck.addChildNode(part(box(2.75, 0.10, 16.2), wood, at: V3(0, 1.28, 0)))
        for z: Float in [-7.8, 0, 7.8] {
            deck.addChildNode(part(box(2.90, 0.25, 0.35), yellow, at: V3(0, 1.08, z)))
        }
        car.addChildNode(deck.flattenedClone())

        // Loadable cargo group (shipping containers, stacked timber logs, or crates)
        let cargo = SCNNode()
        switch variant % 3 {
        case 0:
            // Two vibrant intermodal shipping containers (orange & teal)
            cargo.addChildNode(part(box(2.48, 2.25, 7.1, chamfer: 0.06), material(rgb(0.90, 0.34, 0.12)), at: V3(0, 2.45, 3.85)))
            cargo.addChildNode(part(box(2.48, 2.25, 7.1, chamfer: 0.06), material(rgb(0.10, 0.56, 0.62)), at: V3(0, 2.45, -3.85)))
        case 1:
            // Stacked Alpine Timber Logs bound by steel stakes
            let bark = material(rgb(0.42, 0.26, 0.14))
            for row in 0..<3 {
                let cols = 4 - (row % 2)
                for c in 0..<cols {
                    let x = (Float(c) - Float(cols - 1) * 0.5) * 0.58
                    let y = 1.62 + Float(row) * 0.50
                    cargo.addChildNode(part(cylinder(0.28, 13.8, segments: 10), bark,
                                            at: V3(x, y, 0), euler: V3(.pi / 2, 0, 0)))
                }
            }
            for x: Float in [-1.25, 1.25] {
                for z: Float in [-5.5, 0, 5.5] {
                    cargo.addChildNode(part(box(0.12, 1.9, 0.12), dark, at: V3(x, 2.25, z)))
                }
            }
        default:
            // Cobalt container + stacked wooden cargo crates
            cargo.addChildNode(part(box(2.48, 2.25, 7.2, chamfer: 0.06), material(rgb(0.16, 0.38, 0.78)), at: V3(0, 2.45, 3.8)))
            let crateMat = material(rgb(0.76, 0.58, 0.32))
            for z: Float in [-1.6, -4.0, -6.4] {
                cargo.addChildNode(part(box(2.1, 1.6, 2.0, chamfer: 0.05), crateMat, at: V3(0, 2.12, z)))
            }
        }
        let flatCargo = cargo.flattenedClone()
        car.addChildNode(flatCargo)
        cargoLoadNodes.append(flatCargo)

        for z: Float in [-6.5, -4.7, 4.7, 6.5] {
            addAxle(key: "coach", radius: 0.46, z: z, color: rgb(0.1, 0.1, 0.1), into: car)
        }
        return car
    }

    // MARK: Particles

    private func configureParticles() {
        smoke.particleImage = Images.softDot
        smoke.birthRate = 0
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
        grow.fromValue = 0.8; grow.toValue = 4.8
        let fade = CAKeyframeAnimation()
        fade.values = [0.0, 0.6, 0.35, 0.0]; fade.keyTimes = [0, 0.1, 0.6, 1]
        smoke.propertyControllers = [
            .size: SCNParticlePropertyController(animation: grow),
            .opacity: SCNParticlePropertyController(animation: fade),
        ]

        whistleSteam.particleImage = Images.softDot
        whistleSteam.birthRate = 0
        whistleSteam.particleLifeSpan = 0.85
        whistleSteam.particleVelocity = 6.5
        whistleSteam.emittingDirection = SCNVector3(V3(0.08, 1, -0.15))
        whistleSteam.spreadingAngle = 16
        whistleSteam.particleSize = 0.38
        whistleSteam.particleColor = rgb(0.98, 0.99, 1.0, 0.72)
        whistleSteam.blendMode = .alpha
        whistleSteam.isLightingEnabled = false
        whistleSteam.isAffectedByGravity = false
        whistleSteam.loops = true

        let wGrow = CABasicAnimation(); wGrow.fromValue = 0.4; wGrow.toValue = 1.8
        let wFade = CAKeyframeAnimation(); wFade.values = [0.0, 0.8, 0.0]; wFade.keyTimes = [0, 0.18, 1]
        whistleSteam.propertyControllers = [
            .size: SCNParticlePropertyController(animation: wGrow),
            .opacity: SCNParticlePropertyController(animation: wFade),
        ]

        for (ps, dir) in [(cylinderSteamL, V3(-1, 0.12, -0.2)), (cylinderSteamR, V3(1, 0.12, -0.2))] {
            ps.particleImage = Images.softDot
            ps.birthRate = 0
            ps.particleLifeSpan = 0.9
            ps.particleVelocity = 3.6
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

/// Interactive 3D cab interior cockpit mounted to the camera in Cab View.
/// Features live animated speedometer & pressure dials, a moving throttle/brake lever,
/// illuminated toggle switches, and station approach/stop indicator lamps.
final class CabDashboard {
    let root = SCNNode()

    private let deskMat = SCNMaterial()
    private let trimMat = SCNMaterial()
    private let knobMat = SCNMaterial()

    private let speedNeedlePivot = SCNNode()
    private let powerNeedlePivot = SCNNode()
    private let throttleLeverPivot = SCNNode()

    private let hornLampMat = SCNMaterial()
    private let brakeLampMat = SCNMaterial()
    private let headlightLampMat = SCNMaterial()
    private let signalLampMat = SCNMaterial()
    private let wiperLampMat = SCNMaterial()

    private let wiperLeftPivot = SCNNode()
    private let wiperRightPivot = SCNNode()
    private var wiperPhase: Float = 0
    private var wiperAngle: Float = 0

    private var smoothSpeedNeedle: Float = 0
    private var smoothPowerNeedle: Float = 0
    private var smoothLeverAngle: Float = 0

    init() {
        root.isHidden = true
        build()
        applyTheme(.steam)
    }

    func applyTheme(_ kind: TrainKind) {
        switch kind {
        case .steam:
            deskMat.diffuse.contents = rgb(0.10, 0.16, 0.12)
            trimMat.diffuse.contents = rgb(0.84, 0.65, 0.22)     // gleaming brass
            knobMat.diffuse.contents = rgb(0.78, 0.12, 0.10)     // classic red steam handle
        case .bullet:
            deskMat.diffuse.contents = rgb(0.16, 0.18, 0.22)
            trimMat.diffuse.contents = rgb(0.18, 0.56, 0.96)     // Shinkansen cobalt trim
            knobMat.diffuse.contents = rgb(0.12, 0.42, 0.86)
        case .freight:
            deskMat.diffuse.contents = rgb(0.14, 0.15, 0.17)
            trimMat.diffuse.contents = rgb(0.92, 0.70, 0.12)     // industrial hazard yellow
            knobMat.diffuse.contents = rgb(0.92, 0.68, 0.10)
        }
    }

    /// Updates all live 3D gauges, levers, automatic windshield wipers, and indicator lamps each frame.
    /// `signalState`: 0 = clear/off, 1 = caution amber, 2 = brake/stop red, 3 = go green.
    func update(dt: Float, speedNorm: Float, notch: Int, hornOn: Bool,
                headlightOn: Bool, signalState: Int, precipLevel: Float, time: Float) {
        let k = 1 - exp(-dt * 9.0)

        // Speedometer needle: sweeps from +2.15 rad (left, 0 km/h) to -2.15 rad (right, max speed).
        let targetSpeedAngle = lerp(2.15, -2.15, clamp(speedNorm, 0, 1))
        smoothSpeedNeedle += (targetSpeedAngle - smoothSpeedNeedle) * k
        speedNeedlePivot.simdEulerAngles = V3(0, 0, smoothSpeedNeedle)

        // Power/Pressure gauge needle: sweeps with notch (-3...4).
        let notchNorm = clamp(Float(notch - Game.minNotch) / Float(Game.maxNotch - Game.minNotch), 0, 1)
        let targetPowerAngle = lerp(2.0, -2.0, notchNorm)
        smoothPowerNeedle += (targetPowerAngle - smoothPowerNeedle) * k
        powerNeedlePivot.simdEulerAngles = V3(0, 0, smoothPowerNeedle)

        // Physical throttle/brake lever tilts forward (+notch) or pulls back (-notch).
        let targetLever = Float(notch) * -0.15
        smoothLeverAngle += (targetLever - smoothLeverAngle) * k
        throttleLeverPivot.simdEulerAngles = V3(smoothLeverAngle, 0, 0)

        // Automatic windshield wipers in rain or snow!
        let wipersActive = precipLevel > 0.04
        if wipersActive {
            let sweepRate: Float = 2.6 + min(precipLevel, 1.5) * 1.4
            wiperPhase += sweepRate * dt
            let sweep = 0.5 - 0.5 * cos(wiperPhase) // smooth 0...1...0 arc
            wiperAngle = lerp(-1.28, 0.18, sweep)
        } else {
            // Smoothly park wipers flat along the lower windshield sill
            wiperAngle += (-1.28 - wiperAngle) * (1 - exp(-dt * 6.0))
            if abs(wiperAngle + 1.28) < 0.01 { wiperPhase = 0 }
        }
        wiperLeftPivot.simdEulerAngles = V3(0, 0, wiperAngle)
        wiperRightPivot.simdEulerAngles = V3(0, 0, wiperAngle)

        // Indicator lamps
        hornLampMat.emission.contents = hornOn ? rgb(1.0, 0.78, 0.12) : rgb(0.08, 0.06, 0.02)
        hornLampMat.diffuse.contents = hornOn ? rgb(1.0, 0.84, 0.24) : rgb(0.26, 0.22, 0.12)

        let braking = notch < 0
        brakeLampMat.emission.contents = braking ? rgb(1.0, 0.14, 0.10) : rgb(0.08, 0.02, 0.02)
        brakeLampMat.diffuse.contents = braking ? rgb(1.0, 0.24, 0.18) : rgb(0.28, 0.12, 0.12)

        headlightLampMat.emission.contents = headlightOn ? rgb(0.35, 0.88, 1.0) : rgb(0.03, 0.08, 0.10)
        headlightLampMat.diffuse.contents = headlightOn ? rgb(0.55, 0.94, 1.0) : rgb(0.14, 0.22, 0.26)

        wiperLampMat.emission.contents = wipersActive ? rgb(0.24, 0.72, 1.0) : rgb(0.02, 0.05, 0.08)
        wiperLampMat.diffuse.contents = wipersActive ? rgb(0.45, 0.86, 1.0) : rgb(0.14, 0.18, 0.24)

        let blink: Float = sin(time * 8.0) > 0 ? 1.0 : 0.30
        switch signalState {
        case 1:
            signalLampMat.emission.contents = rgb(1.0 * blink, 0.68 * blink, 0.08)
            signalLampMat.diffuse.contents = rgb(1.0, 0.75, 0.16)
        case 2:
            signalLampMat.emission.contents = rgb(1.0 * blink, 0.10 * blink, 0.08)
            signalLampMat.diffuse.contents = rgb(1.0, 0.18, 0.14)
        case 3:
            signalLampMat.emission.contents = rgb(0.16, 0.96, 0.38)
            signalLampMat.diffuse.contents = rgb(0.24, 1.0, 0.46)
        default:
            signalLampMat.emission.contents = rgb(0.04, 0.06, 0.05)
            signalLampMat.diffuse.contents = rgb(0.15, 0.18, 0.16)
        }
    }

    private func build() {
        deskMat.lightingModel = .blinn
        deskMat.specular.contents = rgb(0.25, 0.25, 0.28)
        trimMat.lightingModel = .blinn
        trimMat.specular.contents = rgb(0.55, 0.55, 0.55)
        knobMat.lightingModel = .blinn

        let darkFrame = SCNMaterial()
        darkFrame.lightingModel = .blinn
        darkFrame.diffuse.contents = rgb(0.06, 0.07, 0.09)

        let chrome = SCNMaterial()
        chrome.lightingModel = .blinn
        chrome.diffuse.contents = rgb(0.78, 0.80, 0.84)
        chrome.specular.contents = rgb(0.9, 0.9, 0.9)

        func addBox(_ w: Float, _ h: Float, _ l: Float, _ mat: SCNMaterial, at pos: V3,
                    euler: V3 = V3(0, 0, 0), chamfer: Float = 0.006, to parent: SCNNode = root) {
            let g = SCNBox(width: CGFloat(w), height: CGFloat(h), length: CGFloat(l), chamferRadius: CGFloat(chamfer))
            g.materials = [mat]
            let n = SCNNode(geometry: g)
            n.simdPosition = pos
            n.simdEulerAngles = euler
            n.castsShadow = false
            parent.addChildNode(n)
        }

        // Windshield A-pillars & overhead sun visor
        addBox(0.075, 1.12, 0.08, darkFrame, at: V3(-0.88, 0.04, -0.92), euler: V3(0, 0, -0.05))
        addBox(0.075, 1.12, 0.08, darkFrame, at: V3(0.88, 0.04, -0.92), euler: V3(0, 0, 0.05))
        addBox(1.88, 0.09, 0.12, darkFrame, at: V3(0, 0.51, -0.92))
        addBox(1.82, 0.016, 0.04, trimMat, at: V3(0, 0.464, -0.88))

        // Main sloped control desk raised cleanly into the lower-third safe zone (never cut off on TV!)
        addBox(1.94, 0.34, 0.36, deskMat, at: V3(0, -0.355, -0.92), euler: V3(0.22, 0, 0), chamfer: 0.02)
        // Lower skirt extending safely past the bottom edge for any screen aspect ratio
        addBox(1.94, 0.26, 0.18, darkFrame, at: V3(0, -0.52, -0.86), chamfer: 0)
        // Accent trim lip across the upper sill of the console
        addBox(1.86, 0.018, 0.03, trimMat, at: V3(0, -0.175, -0.99))

        // Twin automatic windshield wipers mounted right along the windshield sill
        func buildWiper(_ pivot: SCNNode, at pos: V3) {
            pivot.simdPosition = pos
            let arm = SCNBox(width: 0.008, height: 0.24, length: 0.006, chamferRadius: 0)
            arm.materials = [darkFrame]
            let armNode = SCNNode(geometry: arm)
            armNode.simdPosition = V3(0, 0.12, 0)
            armNode.castsShadow = false
            pivot.addChildNode(armNode)

            let blade = SCNBox(width: 0.012, height: 0.19, length: 0.008, chamferRadius: 0)
            blade.materials = [darkFrame]
            let bladeNode = SCNNode(geometry: blade)
            bladeNode.simdPosition = V3(0.008, 0.21, -0.003)
            bladeNode.castsShadow = false
            pivot.addChildNode(bladeNode)

            let hub = SCNSphere(radius: 0.012); hub.segmentCount = 8
            hub.materials = [chrome]
            let hubNode = SCNNode(geometry: hub)
            hubNode.castsShadow = false
            pivot.addChildNode(hubNode)

            pivot.simdEulerAngles = V3(0, 0, -1.28)
            root.addChildNode(pivot)
        }
        buildWiper(wiperLeftPivot, at: V3(-0.22, -0.168, -0.985))
        buildWiper(wiperRightPivot, at: V3(0.28, -0.168, -0.985))

        // 1. Live Analog Speedometer & Power/Pressure Gauges (comfortably above bottom edge!)
        buildGauge(at: V3(-0.34, -0.228, -0.85), radius: 0.066, needlePivot: speedNeedlePivot,
                   needleColor: rgb(1.0, 0.24, 0.16))
        buildGauge(at: V3(-0.15, -0.228, -0.85), radius: 0.058, needlePivot: powerNeedlePivot,
                   needleColor: rgb(1.0, 0.80, 0.16))

        // 2. Central Illuminated Status Lamps (Signal / Brake / Horn / Headlight / Wipers)
        let lamps: [(x: Float, mat: SCNMaterial)] = [
            (-0.02, signalLampMat),
            (0.032, brakeLampMat),
            (0.084, hornLampMat),
            (0.136, headlightLampMat),
            (0.188, wiperLampMat),
        ]
        for (lx, lMat) in lamps {
            lMat.lightingModel = .blinn
            let bezel = SCNCylinder(radius: 0.017, height: 0.014); bezel.radialSegmentCount = 12
            bezel.materials = [trimMat]
            let bn = SCNNode(geometry: bezel)
            bn.simdPosition = V3(lx, -0.212, -0.84)
            bn.simdEulerAngles = V3(1.15, 0, 0)
            bn.castsShadow = false
            root.addChildNode(bn)

            let lens = SCNSphere(radius: 0.0125); lens.segmentCount = 10
            lens.materials = [lMat]
            let ln = SCNNode(geometry: lens)
            ln.simdPosition = V3(lx, -0.207, -0.833)
            ln.castsShadow = false
            root.addChildNode(ln)
        }

        // Row of 5 metallic toggle switches right below the lamps
        for i in 0..<5 {
            let sx = -0.02 + Float(i) * 0.052
            addBox(0.022, 0.028, 0.014, darkFrame, at: V3(sx, -0.268, -0.825), euler: V3(-0.35, 0, 0), chamfer: 0.002)
            let toggle = SCNCylinder(radius: 0.0038, height: 0.024); toggle.radialSegmentCount = 8
            toggle.materials = [chrome]
            let tn = SCNNode(geometry: toggle)
            tn.simdPosition = V3(sx, -0.265, -0.815)
            tn.simdEulerAngles = V3(i % 2 == 0 ? 1.25 : 0.75, 0, 0)
            tn.castsShadow = false
            root.addChildNode(tn)
        }

        // 3. Physical Moving Throttle / Brake Lever Quadrant on the right side of the console
        let qPos = V3(0.34, -0.245, -0.84)
        addBox(0.085, 0.022, 0.16, darkFrame, at: qPos, euler: V3(0.22, 0, 0), chamfer: 0.005)
        let greenMat = SCNMaterial(); greenMat.lightingModel = .constant; greenMat.diffuse.contents = rgb(0.2, 0.88, 0.36)
        let redMat = SCNMaterial(); redMat.lightingModel = .constant; redMat.diffuse.contents = rgb(0.95, 0.22, 0.18)
        addBox(0.012, 0.006, 0.065, greenMat, at: qPos + V3(-0.028, 0.015, -0.036), euler: V3(0.22, 0, 0), chamfer: 0)
        addBox(0.012, 0.006, 0.055, redMat, at: qPos + V3(-0.028, 0.003, 0.038), euler: V3(0.22, 0, 0), chamfer: 0)

        throttleLeverPivot.simdPosition = qPos + V3(0, 0.005, 0)
        let shaft = SCNCylinder(radius: 0.007, height: 0.125); shaft.radialSegmentCount = 10
        shaft.materials = [chrome]
        let shaftNode = SCNNode(geometry: shaft)
        shaftNode.simdPosition = V3(0, 0.062, 0)
        shaftNode.castsShadow = false
        throttleLeverPivot.addChildNode(shaftNode)

        let handle = SCNCylinder(radius: 0.0155, height: 0.075); handle.radialSegmentCount = 12
        handle.materials = [knobMat]
        let handleNode = SCNNode(geometry: handle)
        handleNode.simdPosition = V3(0, 0.125, 0)
        handleNode.simdEulerAngles = V3(0, 0, .pi / 2)
        handleNode.castsShadow = false
        throttleLeverPivot.addChildNode(handleNode)
        root.addChildNode(throttleLeverPivot)
    }

    private func buildGauge(at pos: V3, radius: Float, needlePivot: SCNNode, needleColor: PColor) {
        let holder = SCNNode()
        holder.simdPosition = pos
        holder.simdEulerAngles = V3(-0.32, 0, 0)

        // Outer metallic bezel
        let bezel = SCNCylinder(radius: CGFloat(radius * 1.12), height: 0.022); bezel.radialSegmentCount = 20
        bezel.materials = [trimMat]
        let bezelNode = SCNNode(geometry: bezel)
        bezelNode.simdEulerAngles = V3(.pi / 2, 0, 0)
        bezelNode.castsShadow = false
        holder.addChildNode(bezelNode)

        // Softly backlit dark instrument face
        let faceMat = SCNMaterial()
        faceMat.lightingModel = .constant
        faceMat.diffuse.contents = rgb(0.08, 0.10, 0.13)
        let face = SCNCylinder(radius: CGFloat(radius), height: 0.025); face.radialSegmentCount = 20
        face.materials = [faceMat]
        let faceNode = SCNNode(geometry: face)
        faceNode.simdEulerAngles = V3(.pi / 2, 0, 0)
        faceNode.castsShadow = false
        holder.addChildNode(faceNode)

        // Glowing tick marks around the 240° dial arc
        let tickWhite = SCNMaterial(); tickWhite.lightingModel = .constant; tickWhite.diffuse.contents = rgb(0.92, 0.94, 0.96)
        let tickRed = SCNMaterial(); tickRed.lightingModel = .constant; tickRed.diffuse.contents = rgb(0.98, 0.28, 0.22)
        for i in 0...8 {
            let t = Float(i) / 8.0
            let angle = lerp(2.15, -2.15, t)
            let tick = SCNBox(width: 0.004, height: CGFloat(radius * 0.22), length: 0.004, chamferRadius: 0)
            tick.materials = [i >= 7 ? tickRed : tickWhite]
            let tn = SCNNode(geometry: tick)
            tn.simdPosition = V3(-sin(angle) * radius * 0.78, cos(angle) * radius * 0.78, 0.014)
            tn.simdEulerAngles = V3(0, 0, angle)
            tn.castsShadow = false
            holder.addChildNode(tn)
        }

        // Animated glowing needle
        needlePivot.simdPosition = V3(0, 0, 0.017)
        let nMat = SCNMaterial(); nMat.lightingModel = .constant; nMat.diffuse.contents = needleColor
        let needle = SCNBox(width: 0.0055, height: CGFloat(radius * 0.74), length: 0.004, chamferRadius: 0)
        needle.materials = [nMat]
        let needleNode = SCNNode(geometry: needle)
        needleNode.simdPosition = V3(0, radius * 0.30, 0)
        needleNode.castsShadow = false
        needlePivot.addChildNode(needleNode)

        let cap = SCNSphere(radius: 0.009); cap.segmentCount = 8
        cap.materials = [trimMat]
        let capNode = SCNNode(geometry: cap)
        capNode.castsShadow = false
        needlePivot.addChildNode(capNode)

        holder.addChildNode(needlePivot)
        root.addChildNode(holder)
    }
}
