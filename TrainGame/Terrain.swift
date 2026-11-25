import SceneKit
import simd

/// Spatially chunked (6x6) landscape generator supporting both the Swiss Alps
/// (mountains, lake, chalets, evergreens) and Tokyo (skyscrapers, Tokyo Tower, sakura parks, bay).
final class Terrain {
    static let waterLevel: Float = 12

    let node = SCNNode()
    private let theme: WorldTheme
    private let size: Float = 3400
    private let cells = 168          // divisible by chunkGrid (6 * 28)
    private let chunkGrid = 6
    private var heights: [Float] = []
    private let track: Track

    private let waterMaterial = SCNMaterial()
    private let warmWindowMaterial = SCNMaterial()
    private let neonMaterial = SCNMaterial()
    private var sailboats: [(node: SCNNode, center: V3, radius: Float, speed: Float, phase: Float)] = []

    init(track: Track, theme: WorldTheme = .alps, stationDistances: [Float] = []) {
        self.track = track
        self.theme = theme

        let n = cells + 1
        let cell = size / Float(cells)
        heights = [Float](repeating: 0, count: n * n)

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
        switch theme {
        case .alps:
            buildAlpineScenery(stationDistances: stationDistances)
            buildSailboats()
        case .tokyo:
            buildTokyoScenery(stationDistances: stationDistances)
            buildTokyoTower()
            buildSailboats()
        }
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
        for boat in sailboats {
            let a = time * boat.speed + boat.phase
            let px = boat.center.x + cos(a) * boat.radius
            let pz = boat.center.z + sin(a) * boat.radius
            let bob = sin(time * 1.4 + boat.phase * 2) * 0.12
            let roll = sin(time * 1.1 + boat.phase) * 0.05
            boat.node.simdPosition = V3(px, Terrain.waterLevel + bob, pz)
            boat.node.simdEulerAngles = V3(0, -a, roll)
        }

        let glow = clamp((nightLevel - 0.12) / 0.55, 0, 1)
        switch theme {
        case .alps:
            warmWindowMaterial.emission.contents = rgb(1.0 * glow, 0.72 * glow, 0.28 * glow)
            warmWindowMaterial.diffuse.contents = rgb(
                lerp(0.16, 1.0, glow),
                lerp(0.22, 0.80, glow),
                lerp(0.30, 0.42, glow)
            )
            let baseWater = V3(0.11, 0.36, 0.50)
            let blended = lerp(baseWater, skyHorizon * V3(0.45, 0.55, 0.65), 0.35)
            waterMaterial.diffuse.contents = rgb(blended.x, blended.y, blended.z)
        case .tokyo:
            // Skyscraper windows glow warm gold & cool office white at twilight/night; neon pops brightly!
            warmWindowMaterial.emission.contents = rgb(0.96 * glow, 0.86 * glow, 0.58 * glow)
            warmWindowMaterial.diffuse.contents = rgb(
                lerp(0.22, 0.96, glow),
                lerp(0.28, 0.88, glow),
                lerp(0.36, 0.64, glow)
            )
            let neonBoost = lerp(0.35, 1.0, glow)
            neonMaterial.emission.contents = rgb(neonBoost, neonBoost, neonBoost)
            let baseBay = V3(0.08, 0.24, 0.38)
            let blended = lerp(baseBay, skyHorizon * V3(0.40, 0.48, 0.60), 0.35)
            waterMaterial.diffuse.contents = rgb(blended.x, blended.y, blended.z)
        }
    }

    // MARK: Height Generation

    private func generateHeight(x: Float, z: Float) -> Float {
        let (dist, along, trackY) = track.nearest(x: x, z: z)
        let centerDist = (x * x + z * z).squareRoot()

        // Common viaduct river/bay channel & tunnel ridge shaping
        let viaductAlong = smoothstep(track.viaduct.start + 6, track.viaduct.start + 52, along)
            * (1 - smoothstep(track.viaduct.end - 52, track.viaduct.end - 6, along))
        let viaductAcross = 1 - smoothstep(28, 195, dist)
        let gorgeMask = viaductAlong * viaductAcross

        let tunnelAlong = smoothstep(track.tunnel.start + 36, track.tunnel.start + 74, along)
            * (1 - smoothstep(track.tunnel.end - 74, track.tunnel.end - 36, along))
        let tunnelAcross = 1 - smoothstep(42, 220, dist)

        var h: Float
        switch theme {
        case .alps:
            let corridor = smoothstep(30, 150, dist)
            let baseY = lerp(trackY - 1.0, 40, smoothstep(120, 450, dist))
            let rolling = (Noise.fbm(x * 0.006, z * 0.006, octaves: 3) - 0.5) * 26 * corridor
            let mountainMask = smoothstep(70, 650, dist) * smoothstep(120, 420, centerDist)
            let n1 = Noise.fbm(x * 0.0013 + 7.3, z * 0.0013 + 1.9, octaves: 5)
            let ridge = 1 - abs(2 * Noise.fbm(x * 0.0031 + 40, z * 0.0031 + 17, octaves: 4) - 1)
            let peaks = (pow(n1, 1.5) * 560 + ridge * 72) * mountainMask
            let bowl = 48 * (1 - smoothstep(0, 340, centerDist))
            let tunnelRidge = (48 + ridge * 32) * tunnelAlong * tunnelAcross
            h = baseY + rolling + peaks - bowl + tunnelRidge

        case .tokyo:
            // Urban Tokyo basin: mostly flat city blocks around the loop, Tokyo Bay lagoon in center,
            // and a distant Mount Fuji-inspired horizon rim far outside the city!
            let baseY = lerp(trackY - 1.0, 24.5, smoothstep(60, 260, dist))
            let gentle = (Noise.fbm(x * 0.004, z * 0.004, octaves: 2) - 0.5) * 4.5 * smoothstep(40, 200, dist)
            let bayBowl = 20 * (1 - smoothstep(120, 360, centerDist))
            // Keep a raised central park island right at (0, 0) for Tokyo Tower!
            let towerIsland = 15 * (1 - smoothstep(55, 130, centerDist))
            // Distant Mt. Fuji cone rising majestically on the far western horizon!
            let fujiDist = hypot(x + 1280, z + 1150)
            let fuji = 460 * pow(max(0, 1 - fujiDist / 680), 1.65)
            let urbanHill = 32 * tunnelAlong * tunnelAcross
            h = baseY + gentle - bayBowl + towerIsland + fuji + urbanHill
        }

        if gorgeMask > 0 {
            let gorgeBed = Terrain.waterLevel - 7.5 + (Noise.value(x * 0.03, z * 0.03) - 0.5) * 2.0
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
                node.addChildNode(SCNNode(geometry: mesh.geometry(doubleSided: false, material: sharedMaterial)))
            }
        }
    }

    private func groundColor(_ a: V3, _ b: V3, _ c: V3) -> RGBA {
        let center = (a + b + c) / 3
        let normal = simd_normalize(simd_cross(b - a, c - a))
        let tint = Noise.value(center.x * 0.05, center.z * 0.05)

        switch theme {
        case .alps:
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

        case .tokyo:
            // Snow-capped Mt. Fuji on the horizon
            if center.y > 260 {
                let s = 0.92 + tint * 0.06
                return RGBA(s, s, s + 0.03, 1)
            }
            if center.y > 75 {
                let g = 0.30 + tint * 0.10
                return RGBA(g * 0.92, g * 0.94, g * 1.05, 1)
            }
            if center.y < Terrain.waterLevel + 1.5 {
                return RGBA(0.55, 0.56, 0.58, 1) // harbor seawall concrete
            }
            // Central Tokyo Tower park + green pocket parks mixed with sleek urban asphalt/concrete blocks
            let centerDist = hypot(center.x, center.z)
            let parkNoise = Noise.fbm(center.x * 0.008 + 12, center.z * 0.008 + 4, octaves: 2)
            if centerDist < 125 || parkNoise > 0.64 {
                return RGBA(0.28 + tint * 0.08, 0.48 + tint * 0.08, 0.26, 1)
            }
            let asphalt = 0.34 + tint * 0.07
            return RGBA(asphalt, asphalt * 1.01, asphalt * 1.05, 1)
        }
    }

    // MARK: Water & Sailboats

    private func buildWater() -> SCNNode {
        let plane = SCNPlane(width: CGFloat(size), height: CGFloat(size))
        waterMaterial.lightingModel = .blinn
        waterMaterial.diffuse.contents = theme == .alps ? rgb(0.14, 0.40, 0.54) : rgb(0.09, 0.26, 0.40)
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

        hullMesh.box(center: V3(0, 0.35, 0), side: V3(1, 0, 0), up: V3(0, 1, 0), forward: V3(0, 0, 1),
                     half: V3(1.1, 0.45, 2.8), color: hullCol, includeBottom: false)
        hullMesh.box(center: V3(0, 0.78, 0), side: V3(1, 0, 0), up: V3(0, 1, 0), forward: V3(0, 0, 1),
                     half: V3(1.14, 0.10, 2.82), color: stripeCol, includeBottom: false)
        hullMesh.tri(V3(-1.1, 0.8, 2.8), V3(0, 0.9, 4.4), V3(1.1, 0.8, 2.8), woodCol)
        hullMesh.tri(V3(-1.1, 0.8, 2.8), V3(-1.1, -0.1, 2.8), V3(0, 0.9, 4.4), hullCol)
        hullMesh.tri(V3(1.1, 0.8, 2.8), V3(0, 0.9, 4.4), V3(1.1, -0.1, 2.8), hullCol)
        hullMesh.box(center: V3(0, 4.2, 0.3), side: V3(1, 0, 0), up: V3(0, 1, 0), forward: V3(0, 0, 1),
                     half: V3(0.08, 3.6, 0.08), color: woodCol, includeBottom: false)
        hullMesh.tri(V3(0.05, 7.4, 0.3), V3(0.05, 1.5, 0.3), V3(0.05, 1.5, -2.5), sailCol)
        hullMesh.tri(V3(-0.05, 7.4, 0.3), V3(-0.05, 1.5, -2.5), V3(-0.05, 1.5, 0.3), sailCol)
        hullMesh.tri(V3(0.05, 6.2, 0.4), V3(0.05, 1.6, 3.6), V3(0.05, 1.6, 0.4), sailCol)
        hullMesh.tri(V3(-0.05, 6.2, 0.4), V3(-0.05, 1.6, 0.4), V3(-0.05, 1.6, 3.6), sailCol)

        let boatGeometry = hullMesh.geometry(doubleSided: false)
        let orbits: [(V3, Float, Float, Float)] = theme == .alps
            ? [(V3(-30, 0, 20), 95, 0.045, 0.4), (V3(55, 0, -40), 72, -0.055, 2.1), (V3(-70, 0, -85), 60, 0.04, 4.2)]
            : [(V3(0, 0, 0), 215, 0.032, 0.7), (V3(0, 0, 0), 250, -0.028, 3.4)]
        for (center, radius, speed, phase) in orbits {
            let boatNode = SCNNode(geometry: boatGeometry)
            boatNode.castsShadow = false
            node.addChildNode(boatNode)
            sailboats.append((boatNode, center, radius, speed, phase))
        }
    }

    // MARK: Chunk Helper

    private func chunkIndex(x: Float, z: Float) -> Int {
        let u = clamp((x + size / 2) / size, 0, 0.9999)
        let v = clamp((z + size / 2) / size, 0, 0.9999)
        return Int(v * Float(chunkGrid)) * chunkGrid + Int(u * Float(chunkGrid))
    }

    // MARK: Swiss Alps Scenery

    private func buildAlpineScenery(stationDistances: [Float]) {
        var rng = SeededRNG(seed: 42)
        var chunks = [MeshBuilder](repeating: MeshBuilder(), count: chunkGrid * chunkGrid)
        var chaletWindows = MeshBuilder()

        var placedChalets: [V3] = []
        let villageAnchors: [Float] = stationDistances + [track.length * 0.82]
        let chaletWalls: [RGBA] = [
            RGBA(0.60, 0.41, 0.25, 1), RGBA(0.76, 0.64, 0.46, 1),
            RGBA(0.88, 0.84, 0.75, 1), RGBA(0.50, 0.34, 0.21, 1),
        ]
        let chaletRoofs: [RGBA] = [
            RGBA(0.45, 0.20, 0.14, 1), RGBA(0.32, 0.26, 0.23, 1), RGBA(0.52, 0.25, 0.16, 1),
        ]

        for anchor in villageAnchors {
            var count = 0, tries = 0
            while count < 10 && tries < 180 {
                tries += 1
                let along = track.wrap(anchor + Float.random(in: -140...120, using: &rng))
                let lateral = Float.random(in: 28...115, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                let f = track.frame(at: along)
                let x = f.position.x + f.side.x * lateral
                let z = f.position.z + f.side.z * lateral
                guard abs(x) < size * 0.46, abs(z) < size * 0.46 else { continue }
                let h = height(x: x, z: z)
                guard h > Terrain.waterLevel + 4.5, h < 125 else { continue }
                guard abs(height(x: x + 6, z: z) - h) < 2.6, abs(height(x: x, z: z + 6) - h) < 2.6 else { continue }
                let near = track.nearest(x: x, z: z)
                guard near.distance > 25 else { continue }
                if near.distance < 40 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 36 }) { continue }
                let pos = V3(x, h, z)
                if placedChalets.contains(where: { simd_distance($0, pos) < 16 }) { continue }

                let scale = Float.random(in: 0.85...1.25, using: &rng)
                let yaw = atan2(f.forward.x, f.forward.z) + Float.random(in: -0.4...0.4, using: &rng)
                let idx = chunkIndex(x: x, z: z)
                chunks[idx].chalet(base: pos, yaw: yaw, scale: scale,
                                   wall: chaletWalls.randomElement(using: &rng)!,
                                   roof: chaletRoofs.randomElement(using: &rng)!,
                                   snowRoof: h > 95, windows: &chaletWindows)
                placedChalets.append(pos)
                count += 1
            }
        }

        // Alpine forest (spruces, golden larches, snow-dusted evergreens)
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
            let onTunnelRoof = track.isInTunnel(near.along) && h > near.y + 14
            if !onTunnelRoof {
                guard near.distance > 16 else { continue }
                if near.distance < 32 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 58 }) { continue }
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
                upperColor = isSnowy ? RGBA(0.86, 0.90, 0.93, 1) : RGBA(0.11 + g, 0.35 + g, 0.17 + g * 0.5, 1)
            }

            let idx = chunkIndex(x: x, z: z)
            chunks[idx].cone(base: V3(x, h - 0.4, z), radius: 0.45 * s, height: 2.5 * s, sides: 5,
                             color: RGBA(0.32, 0.21, 0.12, 1))
            chunks[idx].cone(base: V3(x, h + 1.4 * s, z), radius: 2.7 * s, height: 5.0 * s, sides: 6, color: lowerColor)
            chunks[idx].cone(base: V3(x, h + 4.3 * s, z), radius: 1.9 * s, height: 4.5 * s, sides: 6, color: upperColor)
            placedTrees += 1
        }

        // Grounded alpine boulders
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
            if near.distance < 24 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 55 }) { continue }

            let shade = Float.random(in: 0.38...0.52, using: &rng)
            let rx = Float.random(in: 1.3...3.6, using: &rng)
            let ry = Float.random(in: 0.9...2.8, using: &rng)
            let rz = Float.random(in: 1.3...3.6, using: &rng)
            chunks[chunkIndex(x: x, z: z)].rock(center: V3(x, h + ry * 0.15, z), scale: V3(rx, ry, rz),
                                                color: RGBA(shade, shade * 0.98, shade * 0.95, 1), rng: &rng)
            rocksPlaced += 1
        }

        // Grazing Swiss alpine cows & rustic wooden pasture fences in flat meadows near the rails!
        var cowsPlaced = 0, cowAttempts = 0
        let fenceWood = RGBA(0.44, 0.29, 0.16, 1)
        while cowsPlaced < 44 && cowAttempts < 700 {
            cowAttempts += 1
            let f = track.frame(at: Float.random(in: 0..<track.length, using: &rng))
            let lateral = Float.random(in: 18...78, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let x = f.position.x + f.side.x * lateral
            let z = f.position.z + f.side.z * lateral
            guard abs(x) < size * 0.45, abs(z) < size * 0.45 else { continue }
            let h = height(x: x, z: z)
            guard h > Terrain.waterLevel + 4.0, h < 95 else { continue }
            guard abs(height(x: x + 4, z: z) - h) < 1.8, abs(height(x: x, z: z + 4) - h) < 1.8 else { continue }
            let near = track.nearest(x: x, z: z)
            guard near.distance > 16 else { continue }
            if near.distance < 34 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 58 }) { continue }

            let idx = chunkIndex(x: x, z: z)
            let yaw = Float.random(in: 0..<(2 * .pi), using: &rng)
            chunks[idx].cow(base: V3(x, h, z), yaw: yaw, brown: Bool.random(using: &rng))

            // Add a short rustic wooden fence rail beside every third cow cluster
            if cowsPlaced % 3 == 0 {
                let ffwd = V3(f.forward.x, 0, f.forward.z)
                let fNorm = simd_length(ffwd) > 0.01 ? simd_normalize(ffwd) : V3(0, 0, 1)
                let fSide = simd_cross(V3(0, 1, 0), fNorm)
                let fenceBase = V3(x, h, z) - f.side * (lateral > 0 ? 5.5 : -5.5)
                for p: Float in [-4.5, 0, 4.5] {
                    chunks[idx].box(center: fenceBase + fNorm * p + V3(0, 0.55, 0),
                                    side: fSide, up: V3(0, 1, 0), forward: fNorm,
                                    half: V3(0.09, 0.65, 0.09), color: fenceWood, includeBottom: false)
                }
                for ry: Float in [0.42, 0.88] {
                    chunks[idx].box(center: fenceBase + V3(0, ry, 0),
                                    side: fSide, up: V3(0, 1, 0), forward: fNorm,
                                    half: V3(0.06, 0.07, 4.7), color: fenceWood, includeBottom: false)
                }
            }
            cowsPlaced += 1
        }

        // Colorful alpine wildflower tufts dotting sunny green meadows near the tracks
        let flowerColors: [RGBA] = [
            RGBA(0.98, 0.84, 0.14, 1), // yellow buttercup
            RGBA(0.98, 0.98, 0.96, 1), // white edelweiss
            RGBA(0.58, 0.36, 0.94, 1), // alpine violet
            RGBA(0.96, 0.44, 0.64, 1), // alpine rose
        ]
        let up = V3(0, 1, 0), sAxis = V3(1, 0, 0), fAxis = V3(0, 0, 1)
        for _ in 0..<420 {
            let f = track.frame(at: Float.random(in: 0..<track.length, using: &rng))
            let lateral = Float.random(in: 10...58, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let x = f.position.x + f.side.x * lateral
            let z = f.position.z + f.side.z * lateral
            guard abs(x) < size * 0.46, abs(z) < size * 0.46 else { continue }
            let h = height(x: x, z: z)
            guard h > Terrain.waterLevel + 3.0, h < 110 else { continue }
            let near = track.nearest(x: x, z: z)
            guard near.distance > 9.5 else { continue }
            let col = flowerColors.randomElement(using: &rng)!
            chunks[chunkIndex(x: x, z: z)].box(center: V3(x, h + 0.16, z), side: sAxis, up: up, forward: fAxis,
                                               half: V3(0.32, 0.18, 0.32), color: col, includeBottom: false)
        }

        finalizeSceneryChunks(chunks: chunks, windows: chaletWindows, neon: MeshBuilder())
    }

    // MARK: Tokyo Urban Skyline Scenery

    private func buildTokyoScenery(stationDistances: [Float]) {
        var rng = SeededRNG(seed: 2026)
        var chunks = [MeshBuilder](repeating: MeshBuilder(), count: chunkGrid * chunkGrid)
        var officeWindows = MeshBuilder()
        var neonSigns = MeshBuilder()

        let buildingColors: [RGBA] = [
            RGBA(0.76, 0.78, 0.82, 1), RGBA(0.54, 0.58, 0.66, 1),
            RGBA(0.68, 0.72, 0.76, 1), RGBA(0.42, 0.47, 0.56, 1),
            RGBA(0.84, 0.82, 0.78, 1), RGBA(0.32, 0.38, 0.48, 1),
        ]
        let neonPalette: [RGBA] = [
            RGBA(1.0, 0.22, 0.45, 1), RGBA(0.16, 0.86, 1.0, 1),
            RGBA(1.0, 0.78, 0.14, 1), RGBA(0.26, 1.0, 0.54, 1),
            RGBA(0.95, 0.32, 1.0, 1),
        ]

        // 1. Place dense colorful Tokyo skyscrapers & mid-rise buildings lining the tracks and districts.
        var placedTowers: [(x: Float, z: Float, r: Float)] = []
        var count = 0, attempts = 0
        while count < 290 && attempts < 4500 {
            attempts += 1
            let x: Float, z: Float
            if attempts % 4 != 0 {
                let f = track.frame(at: Float.random(in: 0..<track.length, using: &rng))
                let lateral = Float.random(in: 24...240, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                x = f.position.x + f.side.x * lateral
                z = f.position.z + f.side.z * lateral
            } else {
                x = Float.random(in: -size * 0.40...size * 0.40, using: &rng)
                z = Float.random(in: -size * 0.40...size * 0.40, using: &rng)
            }
            guard abs(x) < size * 0.43, abs(z) < size * 0.43 else { continue }
            // Keep Tokyo Tower island & Mt. Fuji clear
            guard hypot(x, z) > 130, hypot(x + 1280, z + 1150) > 650 else { continue }

            let h = height(x: x, z: z)
            guard h > Terrain.waterLevel + 3.5, h < 68 else { continue }
            let near = track.nearest(x: x, z: z)
            guard near.distance > 22 else { continue }
            if near.distance < 38 && stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0 - 43)) < 58 }) { continue }

            let hw = Float.random(in: 6.5...15.5, using: &rng)
            let hl = Float.random(in: 6.5...15.5, using: &rng)
            let radius = hypot(hw, hl) + 4.5
            if placedTowers.contains(where: { hypot($0.x - x, $0.z - z) < $0.r + radius * 0.7 }) { continue }

            // Taller skyscrapers cluster near Shibuya, Shinjuku & Tokyo Station!
            let nearHub = stationDistances.contains(where: { abs(track.signedDelta(from: near.along, to: $0)) < 260 })
            let towerH = nearHub
                ? Float.random(in: 34...118, using: &rng)
                : Float.random(in: 16...72, using: &rng)

            let yaw = Float(Int.random(in: 0..<4, using: &rng)) * (.pi / 2) + Float.random(in: -0.12...0.12, using: &rng)
            let fwd = V3(sin(yaw), 0, cos(yaw))
            let side = V3(cos(yaw), 0, -sin(yaw))
            let up = V3(0, 1, 0)
            let col = buildingColors.randomElement(using: &rng)!
            let idx = chunkIndex(x: x, z: z)

            // Main skyscraper shaft
            chunks[idx].box(center: V3(x, h + towerH * 0.5 - 2, z), side: side, up: up, forward: fwd,
                            half: V3(hw, towerH * 0.5 + 2, hl), color: col, includeBottom: false)

            // Stepped mechanical penthouse / rooftop spire on taller towers
            if towerH > 46 {
                let pentH = Float.random(in: 4...10, using: &rng)
                chunks[idx].box(center: V3(x, h + towerH + pentH * 0.5, z), side: side, up: up, forward: fwd,
                                half: V3(hw * 0.62, pentH * 0.5, hl * 0.62),
                                color: RGBA(col.x * 0.85, col.y * 0.85, col.z * 0.88, 1), includeBottom: false)
                if towerH > 72 {
                    chunks[idx].box(center: V3(x, h + towerH + pentH + 7, z), side: side, up: up, forward: fwd,
                                    half: V3(0.45, 7.5, 0.45), color: RGBA(0.85, 0.86, 0.88, 1), includeBottom: false)
                }
            }

            // Glowing horizontal window bands on all 4 skyscraper faces
            let winCol = RGBA(1.0, 0.92, 0.72, 1)
            let bandStep: Float = 7.5
            var wy: Float = h + 6.5
            while wy < h + towerH - 4.5 {
                let bandH: Float = 1.65
                let ox = hw + 0.08, oz = hl + 0.08
                let bx = hw * 0.84, bz = hl * 0.84
                func pt(_ sx: Float, _ sy: Float, _ sz: Float) -> V3 {
                    V3(x, sy, z) + side * sx + fwd * sz
                }
                officeWindows.quad(pt(-bx, wy - bandH, oz), pt(bx, wy - bandH, oz),
                                   pt(bx, wy + bandH, oz), pt(-bx, wy + bandH, oz), winCol)
                officeWindows.quad(pt(bx, wy - bandH, -oz), pt(-bx, wy - bandH, -oz),
                                   pt(-bx, wy + bandH, -oz), pt(bx, wy + bandH, -oz), winCol)
                officeWindows.quad(pt(ox, wy - bandH, bz), pt(ox, wy - bandH, -bz),
                                   pt(ox, wy + bandH, -bz), pt(ox, wy + bandH, bz), winCol)
                officeWindows.quad(pt(-ox, wy - bandH, -bz), pt(-ox, wy - bandH, bz),
                                   pt(-ox, wy + bandH, bz), pt(-ox, wy + bandH, -bz), winCol)
                wy += bandStep
            }

            // Vibrant neon rooftop & facade billboards (iconic Shibuya / Shinjuku night energy!)
            if nearHub || Float.random(in: 0...1, using: &rng) < 0.42 {
                let nCol = neonPalette.randomElement(using: &rng)!
                let signY = h + towerH + 2.4
                neonSigns.box(center: V3(x, signY, z) + fwd * (hl * 0.75), side: side, up: up, forward: fwd,
                              half: V3(hw * 0.72, 2.2, 0.35), color: nCol)
            }
            // Glowing red rooftop aviation beacon on tall skyscrapers
            if towerH > 72 {
                neonSigns.box(center: V3(x, h + towerH + 22, z), side: side, up: up, forward: fwd,
                              half: V3(0.85, 0.85, 0.85), color: RGBA(1.0, 0.16, 0.12, 1))
            }

            placedTowers.append((x, z, radius))
            count += 1
        }

        // Iconic red Japanese Torii gates framing the Tokyo Tower park & station approaches!
        for k in 0..<6 {
            let angle = Float(k) / 6.0 * 2 * .pi + 0.3
            let tx = cos(angle) * 62
            let tz = sin(angle) * 62
            let th = height(x: tx, z: tz)
            if th > Terrain.waterLevel + 1.5 {
                chunks[chunkIndex(x: tx, z: tz)].toriiGate(base: V3(tx, th, tz), yaw: angle + .pi / 2, scale: 1.15)
            }
        }
        for sd in stationDistances {
            let f = track.frame(at: track.wrap(sd - 110))
            let tx = f.position.x - f.side.x * 20
            let tz = f.position.z - f.side.z * 20
            let th = height(x: tx, z: tz)
            if th > Terrain.waterLevel + 2.0 {
                let yaw = atan2(f.side.x, f.side.z)
                chunks[chunkIndex(x: tx, z: tz)].toriiGate(base: V3(tx, th, tz), yaw: yaw, scale: 1.0)
            }
        }

        // 2. Scatter pink Sakura cherry blossom trees & urban park greens around stations, parks, and Tokyo Tower!
        var trees = 0, tAttempts = 0
        while trees < 950 && tAttempts < 12000 {
            tAttempts += 1
            let x: Float, z: Float
            if tAttempts % 5 == 0 {
                // Cluster sakura trees around the central Tokyo Tower park
                let a = Float.random(in: 0..<(2 * .pi), using: &rng)
                let r = Float.random(in: 24...110, using: &rng)
                x = cos(a) * r
                z = sin(a) * r
            } else {
                let f = track.frame(at: Float.random(in: 0..<track.length, using: &rng))
                let lateral = Float.random(in: 14...135, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
                x = f.position.x + f.side.x * lateral
                z = f.position.z + f.side.z * lateral
            }
            guard abs(x) < size * 0.45, abs(z) < size * 0.45 else { continue }
            let h = height(x: x, z: z)
            guard h > Terrain.waterLevel + 2.2, h < 65 else { continue }
            let near = track.nearest(x: x, z: z)
            guard near.distance > 14 else { continue }
            if placedTowers.contains(where: { hypot($0.x - x, $0.z - z) < $0.r }) { continue }

            let s = Float.random(in: 0.75...1.35, using: &rng)
            let isSakura = Float.random(in: 0...1, using: &rng) < 0.65
            let canopy = isSakura
                ? RGBA(0.98, 0.70 + Float.random(in: 0...0.12, using: &rng), 0.80 + Float.random(in: 0...0.08, using: &rng), 1)
                : RGBA(0.18, 0.46 + Float.random(in: 0...0.08, using: &rng), 0.22, 1)
            let idx = chunkIndex(x: x, z: z)
            chunks[idx].cone(base: V3(x, h - 0.3, z), radius: 0.38 * s, height: 2.8 * s, sides: 5,
                             color: RGBA(0.32, 0.22, 0.16, 1))
            chunks[idx].cone(base: V3(x, h + 1.8 * s, z), radius: 2.9 * s, height: 3.4 * s, sides: 6, color: canopy)
            chunks[idx].cone(base: V3(x, h + 3.8 * s, z), radius: 2.1 * s, height: 2.8 * s, sides: 6, color: canopy)
            trees += 1
        }

        finalizeSceneryChunks(chunks: chunks, windows: officeWindows, neon: neonSigns)
    }

    /// Iconic red-and-white Tokyo Tower landmark standing on the central bay park island!
    private func buildTokyoTower() {
        var mesh = MeshBuilder()
        let baseH = height(x: 0, z: 0)
        let red = RGBA(0.92, 0.22, 0.14, 1)
        let white = RGBA(0.96, 0.96, 0.98, 1)
        let up = V3(0, 1, 0), side = V3(1, 0, 0), fwd = V3(0, 0, 1)

        // 4 tapered lattice-inspired legs rising to the main observation deck
        let tiers: [(y0: Float, y1: Float, r0: Float, r1: Float, color: RGBA)] = [
            (0, 42, 26, 16, red),
            (42, 84, 16, 10, white),
            (84, 126, 10, 6.2, red),
            (126, 162, 6.2, 3.6, white),
            (162, 200, 3.6, 1.5, red),
            (200, 232, 1.5, 0.4, white),
        ]
        for tier in tiers {
            let ym = baseH + (tier.y0 + tier.y1) * 0.5
            let hh = (tier.y1 - tier.y0) * 0.5
            let rm = (tier.r0 + tier.r1) * 0.5
            // 4 corner legs + horizontal cross-bracing
            let legR = max(1.1, rm * 0.18)
            for sx: Float in [-1, 1] {
                for sz: Float in [-1, 1] {
                    mesh.box(center: V3(sx * rm * 0.72, ym, sz * rm * 0.72),
                             side: side, up: up, forward: fwd,
                             half: V3(legR, hh, legR), color: tier.color, includeBottom: false)
                }
            }
            mesh.box(center: V3(0, baseH + tier.y1, 0), side: side, up: up, forward: fwd,
                     half: V3(tier.r1 * 0.85, 1.2, tier.r1 * 0.85), color: tier.color, includeBottom: false)
        }
        // Main & top observation decks
        mesh.box(center: V3(0, baseH + 86, 0), side: side, up: up, forward: fwd,
                 half: V3(13.5, 4.2, 13.5), color: white, includeBottom: false)
        mesh.box(center: V3(0, baseH + 162, 0), side: side, up: up, forward: fwd,
                 half: V3(6.8, 3.2, 6.8), color: white, includeBottom: false)

        let towerNode = SCNNode(geometry: mesh.geometry(doubleSided: false))
        node.addChildNode(towerNode)
    }

    private func finalizeSceneryChunks(chunks: [MeshBuilder], windows: MeshBuilder, neon: MeshBuilder) {
        let sharedMat = MeshBuilder.defaultMaterial(doubleSided: false)
        for chunk in chunks where !chunk.isEmpty {
            node.addChildNode(SCNNode(geometry: chunk.geometry(doubleSided: false, material: sharedMat)))
        }

        if !windows.isEmpty {
            warmWindowMaterial.lightingModel = .lambert
            warmWindowMaterial.diffuse.contents = rgb(0.18, 0.24, 0.32)
            warmWindowMaterial.emission.contents = rgb(0, 0, 0)
            warmWindowMaterial.isDoubleSided = false
            let winNode = SCNNode(geometry: windows.geometry(doubleSided: false, material: warmWindowMaterial))
            winNode.castsShadow = false
            node.addChildNode(winNode)
        }

        if !neon.isEmpty {
            neonMaterial.lightingModel = .constant
            neonMaterial.diffuse.contents = PColor.white
            neonMaterial.emission.contents = rgb(0.5, 0.5, 0.5)
            neonMaterial.isDoubleSided = false
            let neonNode = SCNNode(geometry: neon.geometry(doubleSided: false, material: neonMaterial))
            neonNode.castsShadow = false
            node.addChildNode(neonNode)
        }
    }
}
