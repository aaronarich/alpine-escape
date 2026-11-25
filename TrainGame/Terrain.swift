import SceneKit
import simd

/// Low-poly alpine mountains shaped around the track, with a turquoise lake, viaduct gorge,
/// tunnel ridge, varied forests, boulders, and glowing Swiss chalet villages.
/// All static meshes are spatially chunked (6x6) so SceneKit frustum- and shadow-culls efficiently.
final class Terrain {
    static let waterLevel: Float = 12

    let node = SCNNode()
    private let size: Float = 3400
    private let cells = 168          // divisible by chunkGrid (6 * 28)
    private let chunkGrid = 6
    private var heights: [Float] = []
    private let track: Track

    private let waterMaterial = SCNMaterial()
    private let chaletWindowMaterial = SCNMaterial()
    private var sailboats: [(node: SCNNode, center: V3, radius: Float, speed: Float, phase: Float)] = []

    init(track: Track, stationDistances: [Float] = []) {
        self.track = track

        let n = cells + 1
        let cell = size / Float(cells)
        heights = [Float](repeating: 0, count: n * n)

        // Generate heightmap rows concurrently across CPU cores for snappy startup.
        heights.withUnsafeMutableBufferPointer { buffer in
            let basePtr = buffer.baseAddress!
            DispatchQueue.concurrentPerform(iterations: n) { j in
                let z = -self.size / 2 + Float(j) * cell
                let rowOffset = j * n
                for i in 0..<n {
                    let x = -self.size / 2 + Float(i) * cell
                    basePtr[rowOffset + i] = self.generateHeight(x: x, z: z)
                }
            }
        }

        buildGroundChunks()
        node.addChildNode(buildWater())
        buildSceneryChunks(stationDistances: stationDistances)
        buildSailboats()
    }

    // MARK: Queries

    func height(x: Float, z: Float) -> Float {
        let cell = size / Float(cells)
        let u = clamp((x + size / 2) / cell, 0, Float(cells) - 0.001)
        let v = clamp((z + size / 2) / cell, 0, Float(cells) - 0.001)
        let i = Int(u), j = Int(v)
        let tx = u - Float(i), tz = v - Float(j)
        let n = cells + 1
        let a = heights[j * n + i], b = heights[j * n + i + 1]
        let c = heights[(j + 1) * n + i], d = heights[(j + 1) * n + i + 1]
        return lerp(lerp(a, b, tx), lerp(c, d, tx), tz)
    }

    func update(time: Float, nightLevel: Float, skyHorizon: V3) {
        // Gentle alpine sailboat cruising & wave bobbing on the central lake.
        for boat in sailboats {
            let a = time * boat.speed + boat.phase
            let px = boat.center.x + cos(a) * boat.radius
            let pz = boat.center.z + sin(a) * boat.radius
            let bob = sin(time * 1.4 + boat.phase * 2) * 0.12
            let roll = sin(time * 1.1 + boat.phase) * 0.05
            boat.node.simdPosition = V3(px, Terrain.waterLevel + bob, pz)
            boat.node.simdEulerAngles = V3(0, -a, roll)
        }

        // Warm glowing village windows as twilight and night arrive.
        let glow = clamp((nightLevel - 0.15) / 0.6, 0, 1)
        chaletWindowMaterial.emission.contents = rgb(1.0 * glow, 0.72 * glow, 0.28 * glow)
        chaletWindowMaterial.diffuse.contents = rgb(
            lerp(0.16, 1.0, glow),
            lerp(0.22, 0.80, glow),
            lerp(0.30, 0.42, glow)
        )

        // Blend lake colour gently with the sky horizon for golden-hour & moonlit reflections.
        let baseWater = V3(0.11, 0.36, 0.50)
        let blended = lerp(baseWater, skyHorizon * V3(0.45, 0.55, 0.65), 0.35)
        waterMaterial.diffuse.contents = rgb(blended.x, blended.y, blended.z)
    }

    // MARK: Height Generation

    private func generateHeight(x: Float, z: Float) -> Float {
        let (dist, along, trackY) = track.nearest(x: x, z: z)
        let centerDist = (x * x + z * z).squareRoot()

        // Flat shelf next to the rails, rolling meadows beyond it, jagged peaks further out.
        let corridor = smoothstep(30, 150, dist)
        var baseY = lerp(trackY - 1.0, 40, smoothstep(120, 450, dist))
        let rolling = (Noise.fbm(x * 0.006, z * 0.006, octaves: 3) - 0.5) * 26 * corridor

        let mountainMask = smoothstep(70, 650, dist) * smoothstep(120, 420, centerDist)
        let n1 = Noise.fbm(x * 0.0013 + 7.3, z * 0.0013 + 1.9, octaves: 5)
        let ridge = 1 - abs(2 * Noise.fbm(x * 0.0031 + 40, z * 0.0031 + 17, octaves: 4) - 1)
        let peaks = (pow(n1, 1.5) * 560 + ridge * 72) * mountainMask

        let bowl = 48 * (1 - smoothstep(0, 340, centerDist))

        // 1. Stone viaduct gorge: carve a dramatic alpine river valley right under the bridge.
        let viaductAlong = smoothstep(track.viaduct.start + 6, track.viaduct.start + 52, along)
            * (1 - smoothstep(track.viaduct.end - 52, track.viaduct.end - 6, along))
        let viaductAcross = 1 - smoothstep(28, 195, dist)
        let gorgeMask = viaductAlong * viaductAcross

        // 2. Alpine mountain tunnel: raise a rocky shoulder smoothly OVER the middle of the tunnel.
        //    Keep a generous 36m clearance past each portal mouth so no coarse 20m terrain triangle crosses the opening.
        let tunnelAlong = smoothstep(track.tunnel.start + 36, track.tunnel.start + 74, along)
            * (1 - smoothstep(track.tunnel.end - 74, track.tunnel.end - 36, along))
        let tunnelAcross = 1 - smoothstep(42, 220, dist)
        let tunnelRidge = (48 + ridge * 32) * tunnelAlong * tunnelAcross

        var h = baseY + rolling + peaks - bowl + tunnelRidge
        if gorgeMask > 0 {
            let gorgeBed = Terrain.waterLevel - 7.5 + (Noise.value(x * 0.03, z * 0.03) - 0.5) * 2.5
            h = lerp(h, gorgeBed, gorgeMask)
        }

        // Keep immediate tunnel portal approaches flush below rail level so portals open cleanly.
        let inStartClear = along >= track.tunnel.start - 24 && along <= track.tunnel.start + 30
        let inEndClear = along >= track.tunnel.end - 30 && along <= track.tunnel.end + 24
        if (inStartClear || inEndClear) && dist < 24 {
            let clearMask = 1 - smoothstep(12, 24, dist)
            h = lerp(h, trackY - 1.15, clearMask)
        }

        return h
    }

    // MARK: Chunked Ground

    private func buildGroundChunks() {
        let n = cells + 1
        let cell = size / Float(cells)
        let cellsPerChunk = cells / chunkGrid
        let sharedMaterial = MeshBuilder.defaultMaterial(doubleSided: false)

        func vertex(_ i: Int, _ j: Int) -> V3 {
            V3(-size / 2 + Float(i) * cell, heights[j * n + i], -size / 2 + Float(j) * cell)
        }

        for cj in 0..<chunkGrid {
            for ci in 0..<chunkGrid {
                var mesh = MeshBuilder()
                mesh.reserve(triangles: cellsPerChunk * cellsPerChunk * 2)
                let iStart = ci * cellsPerChunk, iEnd = iStart + cellsPerChunk
                let jStart = cj * cellsPerChunk, jEnd = jStart + cellsPerChunk
                for j in jStart..<jEnd {
                    for i in iStart..<iEnd {
                        let p00 = vertex(i, j), p10 = vertex(i + 1, j)
                        let p01 = vertex(i, j + 1), p11 = vertex(i + 1, j + 1)
                        mesh.tri(p00, p01, p10, groundColor(p00, p01, p10))
                        mesh.tri(p10, p01, p11, groundColor(p10, p01, p11))
                    }
                }
                let chunkNode = SCNNode(geometry: mesh.geometry(doubleSided: false, material: sharedMaterial))
                node.addChildNode(chunkNode)
            }
        }
    }

    private func groundColor(_ a: V3, _ b: V3, _ c: V3) -> RGBA {
        let center = (a + b + c) / 3
        let normal = simd_normalize(simd_cross(b - a, c - a))
        let tint = Noise.value(center.x * 0.05, center.z * 0.05)
        let snowLine = 212 + (Noise.fbm(center.x * 0.004, center.z * 0.004, octaves: 2) - 0.5) * 80

        if center.y < Terrain.waterLevel + 1.8 {
            return RGBA(0.68, 0.64, 0.50, 1)
        }
        if center.y > snowLine && normal.y > 0.48 {
            let s = 0.90 + tint * 0.08
            return RGBA(s, s, s + 0.03, 1)
        }
        if normal.y < 0.74 || center.y > 168 {
            let g = 0.35 + tint * 0.14
            return RGBA(g, g * 0.97, g * 0.93, 1)
        }
        let fade = smoothstep(38, 168, center.y)
        let low = V3(0.28, 0.52, 0.20) + V3(0.10, 0.10, 0.04) * tint
        let high = V3(0.36, 0.43, 0.24)
        let color = lerp(low, high, fade)
        return RGBA(color.x, color.y, color.z, 1)
    }

    // MARK: Water & Sailboats

    private func buildWater() -> SCNNode {
        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))
        waterMaterial.lightingModel = .blinn
        waterMaterial.diffuse.contents = rgb(0.14, 0.40, 0.54)
        waterMaterial.specular.contents = rgb(0.85, 0.88, 0.92)
        waterMaterial.shininess = 0.75
        plane.materials = [waterMaterial]
        let water = SCNNode(geometry: plane)
        water.simdEulerAngles = V3(-.pi / 2, 0, 0)
        water.simdPosition = V3(0, Terrain.waterLevel, 0)
        water.castsShadow = false
        return water
    }

    private func buildSailboats() {
        var hullMesh = MeshBuilder()
        let hullCol = RGBA(0.88, 0.85, 0.80, 1)
        let woodCol = RGBA(0.45, 0.26, 0.14, 1)
        let sailCol = RGBA(0.98, 0.97, 0.94, 1)
        let stripeCol = RGBA(0.75, 0.16, 0.14, 1)

        // Small low-poly sailboat facing +Z
        hullMesh.box(center: V3(0, 0.35, 0), side: V3(1, 0, 0), up: V3(0, 1, 0), forward: V3(0, 0, 1),
                     half: V3(1.1, 0.45, 2.8), color: hullCol, includeBottom: false)
        hullMesh.box(center: V3(0, 0.78, 0), side: V3(1, 0, 0), up: V3(0, 1, 0), forward: V3(0, 0, 1),
                     half: V3(1.14, 0.10, 2.82), color: stripeCol, includeBottom: false)
        // Bow wedge
        hullMesh.tri(V3(-1.1, 0.8, 2.8), V3(0, 0.9, 4.4), V3(1.1, 0.8, 2.8), woodCol)
        hullMesh.tri(V3(-1.1, 0.8, 2.8), V3(-1.1, -0.1, 2.8), V3(0, 0.9, 4.4), hullCol)
        hullMesh.tri(V3(1.1, 0.8, 2.8), V3(0, 0.9, 4.4), V3(1.1, -0.1, 2.8), hullCol)
        // Mast
        hullMesh.box(center: V3(0, 4.2, 0.3), side: V3(1, 0, 0), up: V3(0, 1, 0), forward: V3(0, 0, 1),
                     half: V3(0.08, 3.6, 0.08), color: woodCol, includeBottom: false)
        // Mainsail & jib (both sides so sails read from any angle)
        hullMesh.tri(V3(0.05, 7.4, 0.3), V3(0.05, 1.5, 0.3), V3(0.05, 1.5, -2.5), sailCol)
        hullMesh.tri(V3(-0.05, 7.4, 0.3), V3(-0.05, 1.5, -2.5), V3(-0.05, 1.5, 0.3), sailCol)
        hullMesh.tri(V3(0.05, 6.2, 0.4), V3(0.05, 1.6, 3.6), V3(0.05, 1.6, 0.4), sailCol)
        hullMesh.tri(V3(-0.05, 6.2, 0.4), V3(-0.05, 1.6, 0.4), V3(-0.05, 1.6, 3.6), sailCol)

        let boatGeometry = hullMesh.geometry(doubleSided: false)
        let orbits: [(V3, Float, Float, Float)] = [
            (V3(-30, 0, 20), 95, 0.045, 0.4),
            (V3(55, 0, -40), 72, -0.055, 2.1),
            (V3(-70, 0, -85), 60, 0.04, 4.2),
        ]
        for (center, radius, speed, phase) in orbits {
            let boatNode = SCNNode(geometry: boatGeometry)
            boatNode.castsShadow = false
            node.addChildNode(boatNode)
            sailboats.append((boatNode, center, radius, speed, phase))
        }
    }

    // MARK: Chunked Scenery (Trees, Boulders, Swiss Villages)

    private func chunkIndex(x: Float, z: Float) -> Int {
        let u = clamp((x + size / 2) / size, 0, 0.9999)
        let v = clamp((z + size / 2) / size, 0, 0.9999)
        return Int(v * Float(chunkGrid)) * chunkGrid + Int(u * Float(chunkGrid))
    }

    private func buildSceneryChunks(stationDistances: [Float]) {
        var rng = SeededRNG(seed: 42)
        var chunks = [MeshBuilder](repeating: MeshBuilder(), count: chunkGrid * chunkGrid)
        var chaletWindows = MeshBuilder()

        // 1. Place cozy Swiss chalet villages near stations & scenic meadows.
        var placedChalets: [V3] = []
        let villageAnchors: [Float] = stationDistances + [track.length * 0.82]
        let chaletWalls: [RGBA] = [
            RGBA(0.60, 0.41, 0.25, 1),
            RGBA(0.76, 0.64, 0.46, 1),
            RGBA(0.88, 0.84, 0.75, 1),
            RGBA(0.50, 0.34, 0.21, 1),
        ]
        let chaletRoofs: [RGBA] = [
            RGBA(0.45, 0.20, 0.14, 1),
            RGBA(0.32, 0.26, 0.23, 1),
            RGBA(0.52, 0.25, 0.16, 1),
        ]

        for anchor in villageAnchors {
            var count = 0
            var tries = 0
            while count < 10 && tries < 180 {
                tries += 1
                let along = track.wrap(anchor + Float.random(in: -140...120, using: &rng))
                let sideSign: Float = Bool.random(using: &rng) ? 1 : -1
                let lateral = Float.random(in: 28...115, using: &rng) * sideSign
                let f = track.frame(at: along)
                let x = f.position.x + f.side.x * lateral
                let z = f.position.z + f.side.z * lateral
                guard abs(x) < size * 0.46, abs(z) < size * 0.46 else { continue }

                let h = height(x: x, z: z)
                guard h > Terrain.waterLevel + 4.5, h < 125 else { continue }
                guard abs(height(x: x + 6, z: z) - h) < 2.6, abs(height(x: x, z: z + 6) - h) < 2.6 else { continue }

                let near = track.nearest(x: x, z: z)
                guard near.distance > 25 else { continue }
                // Don't drop chalets right on top of the station building itself.
                if near.distance < 40 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 36 }) {
                    continue
                }
                let pos = V3(x, h, z)
                if placedChalets.contains(where: { simd_distance($0, pos) < 16 }) { continue }

                let scale = Float.random(in: 0.85...1.25, using: &rng)
                let yaw = atan2(f.forward.x, f.forward.z) + Float.random(in: -0.4...0.4, using: &rng)
                let wall = chaletWalls.randomElement(using: &rng)!
                let roof = chaletRoofs.randomElement(using: &rng)!
                let snowRoof = h > 95
                let idx = chunkIndex(x: x, z: z)
                chunks[idx].chalet(base: pos, yaw: yaw, scale: scale, wall: wall, roof: roof,
                                   snowRoof: snowRoof, windows: &chaletWindows)
                placedChalets.append(pos)
                count += 1
            }
        }

        // 2. Place varied alpine forest (spruces, golden larches, snow-dusted evergreens).
        var placedTrees = 0, attempts = 0
        while placedTrees < 2600 && attempts < 36000 {
            attempts += 1
            var x: Float, z: Float
            if attempts % 3 != 0 {
                let f = track.frame(at: Float.random(in: 0..<track.length, using: &rng))
                let lateral = Float.random(in: 17...195, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                x = f.position.x + f.side.x * lateral
                z = f.position.z + f.side.z * lateral
            } else {
                x = Float.random(in: -size * 0.47...size * 0.47, using: &rng)
                z = Float.random(in: -size * 0.47...size * 0.47, using: &rng)
            }
            guard abs(x) < size * 0.48, abs(z) < size * 0.48 else { continue }
            let h = height(x: x, z: z)
            guard h > Terrain.waterLevel + 2.5, h < 182 else { continue }
            guard abs(height(x: x + 5, z: z) - h) < 4.8, abs(height(x: x, z: z + 5) - h) < 4.8 else { continue }
            guard Noise.fbm(x * 0.011 + 3, z * 0.011 + 9, octaves: 2) > 0.43 else { continue }

            let near = track.nearest(x: x, z: z)
            // Keep clear of the rails, viaduct, and portals (trees on top of the tunnel mountain are welcome!).
            let onTunnelRoof = track.isInTunnel(near.along) && h > near.y + 14
            if !onTunnelRoof {
                guard near.distance > 16 else { continue }
                if near.distance < 32 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 58 }) {
                    continue
                }
            }
            if placedChalets.contains(where: { (x - $0.x) * (x - $0.x) + (z - $0.z) * (z - $0.z) < 120 }) { continue }

            let s = Float.random(in: 0.8...1.65, using: &rng)
            let kindRoll = Float.random(in: 0...1, using: &rng)
            let isSnowy = h > 136 || (h > 115 && kindRoll > 0.72)
            let isLarch = !isSnowy && kindRoll < 0.14

            let lowerColor: RGBA
            let upperColor: RGBA
            if isLarch {
                let warm = Float.random(in: 0...0.08, using: &rng)
                lowerColor = RGBA(0.68 + warm, 0.46 + warm, 0.12, 1)
                upperColor = RGBA(0.80 + warm, 0.58 + warm, 0.16, 1)
            } else {
                let g = Float.random(in: 0.0...0.08, using: &rng)
                lowerColor = RGBA(0.09 + g, 0.30 + g, 0.15 + g * 0.5, 1)
                upperColor = isSnowy
                    ? RGBA(0.86, 0.90, 0.93, 1)
                    : RGBA(0.11 + g, 0.35 + g, 0.17 + g * 0.5, 1)
            }

            let idx = chunkIndex(x: x, z: z)
            chunks[idx].cone(base: V3(x, h - 0.4, z), radius: 0.45 * s, height: 2.5 * s, sides: 5,
                             color: RGBA(0.32, 0.21, 0.12, 1))
            chunks[idx].cone(base: V3(x, h + 1.4 * s, z), radius: 2.7 * s, height: 5.0 * s, sides: 6, color: lowerColor)
            chunks[idx].cone(base: V3(x, h + 4.3 * s, z), radius: 1.9 * s, height: 4.5 * s, sides: 6, color: upperColor)
            placedTrees += 1
        }

        // 3. Scatter faceted alpine boulders along shorelines, slopes, and gorge walls.
        var rocksPlaced = 0, rockAttempts = 0
        while rocksPlaced < 260 && rockAttempts < 2400 {
            rockAttempts += 1
            let f = track.frame(at: Float.random(in: 0..<track.length, using: &rng))
            let lateral = Float.random(in: 13...160, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let x = f.position.x + f.side.x * lateral
            let z = f.position.z + f.side.z * lateral
            guard abs(x) < size * 0.47, abs(z) < size * 0.47 else { continue }
            let h = height(x: x, z: z)
            guard h > Terrain.waterLevel + 0.5, h < 210 else { continue }
            guard abs(height(x: x + 4, z: z) - h) < 2.6, abs(height(x: x, z: z + 4) - h) < 2.6 else { continue }
            let near = track.nearest(x: x, z: z)
            guard near.distance > 12 else { continue }
            if near.distance < 24 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 55 }) {
                continue
            }

            let shade = Float.random(in: 0.38...0.52, using: &rng)
            let rockColor = RGBA(shade, shade * 0.98, shade * 0.95, 1)
            let rx = Float.random(in: 1.3...3.6, using: &rng)
            let ry = Float.random(in: 0.9...2.8, using: &rng)
            let rz = Float.random(in: 1.3...3.6, using: &rng)
            let idx = chunkIndex(x: x, z: z)
            chunks[idx].rock(center: V3(x, h + ry * 0.15, z), scale: V3(rx, ry, rz), color: rockColor, rng: &rng)
            rocksPlaced += 1
        }

        let sharedMat = MeshBuilder.defaultMaterial(doubleSided: false)
        for chunk in chunks where !chunk.isEmpty {
            let chunkNode = SCNNode(geometry: chunk.geometry(doubleSided: false, material: sharedMat))
            node.addChildNode(chunkNode)
        }

        if !chaletWindows.isEmpty {
            chaletWindowMaterial.lightingModel = .lambert
            chaletWindowMaterial.diffuse.contents = rgb(0.16, 0.22, 0.30)
            chaletWindowMaterial.emission.contents = rgb(0, 0, 0)
            chaletWindowMaterial.isDoubleSided = false
            let winNode = SCNNode(geometry: chaletWindows.geometry(doubleSided: false, material: chaletWindowMaterial))
            winNode.castsShadow = false
            node.addChildNode(winNode)
        }
    }
}
