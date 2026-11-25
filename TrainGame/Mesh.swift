import SceneKit
import simd

#if os(macOS)
import AppKit
typealias PColor = NSColor
typealias PFont = NSFont
#else
import UIKit
typealias PColor = UIColor
typealias PFont = UIFont
#endif

typealias V3 = SIMD3<Float>
typealias RGBA = SIMD4<Float>

func rgb(_ r: Float, _ g: Float, _ b: Float, _ a: Float = 1) -> PColor {
    PColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: CGFloat(a))
}

func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}

func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
func lerp(_ a: V3, _ b: V3, _ t: Float) -> V3 { a + (b - a) * t }

func makeTransform(side: V3, up: V3, forward: V3, position: V3) -> simd_float4x4 {
    simd_float4x4(SIMD4(side, 0), SIMD4(up, 0), SIMD4(forward, 0), SIMD4(position, 1))
}

/// Deterministic random numbers so the world is the same on every launch.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

enum Noise {
    static func hash(_ x: Int32, _ y: Int32) -> Float {
        var h = UInt32(bitPattern: x) &* 374761393 &+ UInt32(bitPattern: y) &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Float(h & 0xFFFF) / 65535
    }

    static func value(_ x: Float, _ y: Float) -> Float {
        let fx = x.rounded(.down), fy = y.rounded(.down)
        let ix = Int32(fx), iy = Int32(fy)
        var tx = x - fx, ty = y - fy
        tx = tx * tx * (3 - 2 * tx)
        ty = ty * ty * (3 - 2 * ty)
        let a = hash(ix, iy), b = hash(ix &+ 1, iy)
        let c = hash(ix, iy &+ 1), d = hash(ix &+ 1, iy &+ 1)
        return lerp(lerp(a, b, tx), lerp(c, d, tx), ty)
    }

    /// Fractal noise in 0...1.
    static func fbm(_ x: Float, _ y: Float, octaves: Int) -> Float {
        var sum: Float = 0, amp: Float = 0.5, norm: Float = 0
        var px = x, py = y
        for _ in 0..<octaves {
            sum += value(px, py) * amp
            norm += amp
            amp *= 0.5
            px = px * 2.03 + 11.7
            py = py * 2.03 + 5.3
        }
        return sum / norm
    }
}

/// Tightly packed interleaved vertex (36 bytes, zero padding) for flat-shaded meshes.
struct MeshVertex {
    var px: Float, py: Float, pz: Float
    var nx: Float, ny: Float, nz: Float
    var r: Float, g: Float, b: Float
}

/// Collects flat-shaded, vertex-coloured triangles into a single compact SceneKit geometry.
struct MeshBuilder {
    private(set) var vertices: [MeshVertex] = []

    var isEmpty: Bool { vertices.isEmpty }
    var triangleCount: Int { vertices.count / 3 }

    mutating func reserve(triangles: Int) {
        vertices.reserveCapacity(vertices.count + triangles * 3)
    }

    mutating func tri(_ a: V3, _ b: V3, _ c: V3, _ color: RGBA) {
        var n = simd_cross(b - a, c - a)
        let len = simd_length(n)
        n = len > 1e-8 ? n / len : V3(0, 1, 0)
        vertices.append(MeshVertex(px: a.x, py: a.y, pz: a.z, nx: n.x, ny: n.y, nz: n.z, r: color.x, g: color.y, b: color.z))
        vertices.append(MeshVertex(px: b.x, py: b.y, pz: b.z, nx: n.x, ny: n.y, nz: n.z, r: color.x, g: color.y, b: color.z))
        vertices.append(MeshVertex(px: c.x, py: c.y, pz: c.z, nx: n.x, ny: n.y, nz: n.z, r: color.x, g: color.y, b: color.z))
    }

    mutating func quad(_ a: V3, _ b: V3, _ c: V3, _ d: V3, _ color: RGBA) {
        tri(a, b, c, color)
        tri(a, c, d, color)
    }

    mutating func box(center: V3, side: V3, up: V3, forward: V3, half: V3, color: RGBA, includeBottom: Bool = true) {
        let sx = side * half.x, uy = up * half.y, fz = forward * half.z
        func p(_ i: Float, _ j: Float, _ k: Float) -> V3 { center + sx * i + uy * j + fz * k }
        quad(p(-1, 1, -1), p(-1, 1, 1), p(1, 1, 1), p(1, 1, -1), color)      // top
        if includeBottom {
            quad(p(-1, -1, -1), p(1, -1, -1), p(1, -1, 1), p(-1, -1, 1), color)  // bottom
        }
        quad(p(-1, -1, -1), p(-1, -1, 1), p(-1, 1, 1), p(-1, 1, -1), color)  // -side
        quad(p(1, -1, -1), p(1, 1, -1), p(1, 1, 1), p(1, -1, 1), color)      // +side
        quad(p(-1, -1, -1), p(-1, 1, -1), p(1, 1, -1), p(1, -1, -1), color)  // -forward
        quad(p(-1, -1, 1), p(1, -1, 1), p(1, 1, 1), p(-1, 1, 1), color)      // +forward
    }

    mutating func cone(base: V3, radius: Float, height: Float, sides: Int, color: RGBA) {
        let apex = base + V3(0, height, 0)
        for i in 0..<sides {
            let a0 = Float(i) / Float(sides) * 2 * .pi
            let a1 = Float(i + 1) / Float(sides) * 2 * .pi
            let p0 = base + V3(cos(a0) * radius, 0, sin(a0) * radius)
            let p1 = base + V3(cos(a1) * radius, 0, sin(a1) * radius)
            let shade: Float = i % 2 == 0 ? 1.0 : 0.88
            tri(apex, p1, p0, RGBA(color.x * shade, color.y * shade, color.z * shade, 1))
        }
    }

    /// Low-poly faceted ellipsoid puff (subdivided octahedron) for fluffy, organic clouds.
    mutating func cloudPuff(center: V3, radius: V3, color: RGBA) {
        let baseOcta: [(V3, V3, V3)] = [
            (V3(0, 1, 0), V3(0, 0, 1), V3(1, 0, 0)),
            (V3(0, 1, 0), V3(1, 0, 0), V3(0, 0, -1)),
            (V3(0, 1, 0), V3(0, 0, -1), V3(-1, 0, 0)),
            (V3(0, 1, 0), V3(-1, 0, 0), V3(0, 0, 1)),
            (V3(0, -1, 0), V3(1, 0, 0), V3(0, 0, 1)),
            (V3(0, -1, 0), V3(0, 0, -1), V3(1, 0, 0)),
            (V3(0, -1, 0), V3(-1, 0, 0), V3(0, 0, -1)),
            (V3(0, -1, 0), V3(0, 0, 1), V3(-1, 0, 0)),
        ]
        func emit(_ a: V3, _ b: V3, _ c: V3) {
            let pa = center + a * radius
            let pb = center + b * radius
            let pc = center + c * radius
            let avgY = (a.y + b.y + c.y) / 3.0
            // Soft warm sunlit tops, gently shaded cool undersides.
            let shade = lerp(0.84, 1.0, clamp((avgY + 1.0) * 0.5, 0, 1))
            tri(pa, pb, pc, RGBA(color.x * shade, color.y * shade, color.z * shade, 1))
        }
        // Subdivide each octahedron face once into 4 smooth facets (32 tris per puff).
        for (a, b, c) in baseOcta {
            let ab = simd_normalize((a + b) * 0.5)
            let bc = simd_normalize((b + c) * 0.5)
            let ca = simd_normalize((c + a) * 0.5)
            emit(a, ab, ca)
            emit(ab, b, bc)
            emit(ca, bc, c)
            emit(ab, bc, ca)
        }
    }

    /// Low-poly faceted alpine boulder.
    mutating func rock(center: V3, scale: V3, color: RGBA, rng: inout SeededRNG) {
        let top = center + V3(Float.random(in: -0.2...0.2, using: &rng) * scale.x,
                              scale.y * Float.random(in: 0.75...1.1, using: &rng),
                              Float.random(in: -0.2...0.2, using: &rng) * scale.z)
        let bottom = center - V3(0, scale.y * 0.45, 0)
        let sides = 6
        var ring: [V3] = []
        ring.reserveCapacity(sides)
        for i in 0..<sides {
            let a = Float(i) / Float(sides) * 2 * .pi + Float.random(in: -0.25...0.25, using: &rng)
            let r = Float.random(in: 0.72...1.15, using: &rng)
            let y = Float.random(in: -0.15...0.25, using: &rng) * scale.y
            ring.append(center + V3(cos(a) * scale.x * r, y, sin(a) * scale.z * r))
        }
        for i in 0..<sides {
            let p0 = ring[i], p1 = ring[(i + 1) % sides]
            let s1: Float = i % 2 == 0 ? 1.04 : 0.86
            let s2: Float = 0.78
            tri(top, p1, p0, RGBA(color.x * s1, color.y * s1, color.z * s1, 1))
            tri(bottom, p0, p1, RGBA(color.x * s2, color.y * s2, color.z * s2, 1))
        }
    }

    /// Low-poly Swiss alpine chalet with stone foundation, timber walls, gabled roof, and chimney.
    /// Optionally emits lit window quads into `windowMesh` for dusk/night warmth.
    mutating func chalet(base: V3, yaw: Float, scale: Float, wall: RGBA, roof: RGBA,
                         snowRoof: Bool, windows: inout MeshBuilder) {
        let forward = V3(sin(yaw), 0, cos(yaw))
        let side = V3(cos(yaw), 0, -sin(yaw))
        let up = V3(0, 1, 0)

        let hw: Float = 3.2 * scale   // half width (side)
        let hl: Float = 4.2 * scale   // half length (forward)
        let hBase: Float = 1.6 * scale
        let hWall: Float = 2.6 * scale
        let hPeak: Float = 2.5 * scale

        // Stone foundation sunk slightly into the slope so chalets never float on hills.
        box(center: base + up * (hBase * 0.5 - 1.6 * scale), side: side, up: up, forward: forward,
            half: V3(hw * 1.02, hBase * 0.5 + 1.6 * scale, hl * 1.02),
            color: RGBA(0.56, 0.54, 0.50, 1), includeBottom: false)

        // Timber upper walls
        box(center: base + up * (hBase + hWall * 0.5), side: side, up: up, forward: forward,
            half: V3(hw, hWall * 0.5, hl), color: wall, includeBottom: false)

        // Wooden balcony ledge on front & back gables
        box(center: base + up * (hBase + 0.12 * scale), side: side, up: up, forward: forward,
            half: V3(hw * 1.06, 0.14 * scale, hl * 1.12),
            color: RGBA(0.32, 0.20, 0.12, 1), includeBottom: false)

        // Gable triangles (front & back)
        let eaveY = hBase + hWall
        let peakY = eaveY + hPeak
        func pt(_ sx: Float, _ sy: Float, _ sz: Float) -> V3 {
            base + side * sx + up * sy + forward * sz
        }
        let gableColor = RGBA(wall.x * 0.9, wall.y * 0.9, wall.z * 0.9, 1)
        tri(pt(-hw, eaveY, hl), pt(hw, eaveY, hl), pt(0, peakY, hl), gableColor)
        tri(pt(hw, eaveY, -hl), pt(-hw, eaveY, -hl), pt(0, peakY, -hl), gableColor)

        // Overhanging pitched roof (two thick slopes)
        let ovX: Float = hw + 0.85 * scale
        let ovZ: Float = hl + 0.95 * scale
        let ovY: Float = eaveY - 0.32 * scale
        let roofCol = snowRoof ? RGBA(0.92, 0.94, 0.97, 1) : roof
        let roofDark = RGBA(roofCol.x * 0.90, roofCol.y * 0.90, roofCol.z * 0.92, 1)
        let thick: Float = 0.22 * scale

        // +side roof slope (outward normal points +side, +up)
        quad(pt(0, peakY + thick, -ovZ), pt(0, peakY + thick, ovZ),
             pt(ovX, ovY + thick, ovZ), pt(ovX, ovY + thick, -ovZ), roofCol)
        // -side roof slope (outward normal points -side, +up)
        quad(pt(0, peakY + thick, ovZ), pt(0, peakY + thick, -ovZ),
             pt(-ovX, ovY + thick, -ovZ), pt(-ovX, ovY + thick, ovZ), roofDark)
        // Roof underside/fascia rim so gables look solid from below
        let fascia = RGBA(0.30, 0.18, 0.10, 1)
        quad(pt(ovX, ovY, -ovZ), pt(ovX, ovY + thick, -ovZ),
             pt(ovX, ovY + thick, ovZ), pt(ovX, ovY, ovZ), fascia)
        quad(pt(-ovX, ovY, ovZ), pt(-ovX, ovY + thick, ovZ),
             pt(-ovX, ovY + thick, -ovZ), pt(-ovX, ovY, -ovZ), fascia)

        // Chimney
        box(center: base + side * (hw * 0.35) + up * (peakY + 0.25 * scale) + forward * (-hl * 0.2),
            side: side, up: up, forward: forward,
            half: V3(0.38 * scale, 0.95 * scale, 0.38 * scale),
            color: RGBA(0.45, 0.38, 0.34, 1), includeBottom: false)

        // Warm chalet windows (front, back, and both sides) placed into emissive window mesh
        let winCol = RGBA(1.0, 0.85, 0.45, 1)
        let wy = hBase + hWall * 0.52
        let wh: Float = 0.45 * scale
        let ww: Float = 0.42 * scale
        for zSign: Float in [-1, 1] {
            let wz = zSign * (hl + 0.04 * scale)
            for xOff: Float in [-hw * 0.44, hw * 0.44] {
                if zSign > 0 {
                    windows.quad(pt(xOff - ww, wy - wh, wz), pt(xOff + ww, wy - wh, wz),
                                 pt(xOff + ww, wy + wh, wz), pt(xOff - ww, wy + wh, wz), winCol)
                } else {
                    windows.quad(pt(xOff + ww, wy - wh, wz), pt(xOff - ww, wy - wh, wz),
                                 pt(xOff - ww, wy + wh, wz), pt(xOff + ww, wy + wh, wz), winCol)
                }
            }
        }
        for xSign: Float in [-1, 1] {
            let wx = xSign * (hw + 0.04 * scale)
            for zOff: Float in [-hl * 0.45, hl * 0.45] {
                if xSign > 0 {
                    windows.quad(pt(wx, wy - wh, zOff + ww), pt(wx, wy - wh, zOff - ww),
                                 pt(wx, wy + wh, zOff - ww), pt(wx, wy + wh, zOff + ww), winCol)
                } else {
                    windows.quad(pt(wx, wy - wh, zOff - ww), pt(wx, wy - wh, zOff + ww),
                                 pt(wx, wy + wh, zOff + ww), pt(wx, wy + wh, zOff - ww), winCol)
                }
            }
        }
    }

    /// Cute low-poly grazing Swiss alpine cow (white body, dark spots, head & legs).
    mutating func cow(base: V3, yaw: Float, brown: Bool) {
        let fwd = V3(sin(yaw), 0, cos(yaw))
        let side = V3(cos(yaw), 0, -sin(yaw))
        let up = V3(0, 1, 0)
        let coat = brown ? RGBA(0.54, 0.34, 0.18, 1) : RGBA(0.95, 0.94, 0.91, 1)
        let spot = brown ? RGBA(0.95, 0.94, 0.91, 1) : RGBA(0.14, 0.13, 0.13, 1)
        let nose = RGBA(0.86, 0.64, 0.60, 1)

        // Torso & spot patch
        box(center: base + up * 1.05, side: side, up: up, forward: fwd, half: V3(0.44, 0.42, 0.88), color: coat, includeBottom: false)
        box(center: base + up * 1.12 + fwd * 0.15, side: side, up: up, forward: fwd, half: V3(0.46, 0.26, 0.38), color: spot, includeBottom: false)
        // Head & muzzle
        box(center: base + up * 1.18 + fwd * 1.05, side: side, up: up, forward: fwd, half: V3(0.26, 0.26, 0.30), color: coat, includeBottom: false)
        box(center: base + up * 1.08 + fwd * 1.32, side: side, up: up, forward: fwd, half: V3(0.22, 0.16, 0.12), color: nose, includeBottom: false)
        // 4 legs
        for sx: Float in [-0.28, 0.28] {
            for sz: Float in [-0.62, 0.62] {
                box(center: base + side * sx + up * 0.38 + fwd * sz, side: side, up: up, forward: fwd,
                    half: V3(0.10, 0.38, 0.10), color: coat, includeBottom: false)
            }
        }
    }

    /// Iconic red Japanese Torii shrine gate for Tokyo's sakura parks!
    mutating func toriiGate(base: V3, yaw: Float, scale: Float = 1.0) {
        let fwd = V3(sin(yaw), 0, cos(yaw))
        let side = V3(cos(yaw), 0, -sin(yaw))
        let up = V3(0, 1, 0)
        let vermilion = RGBA(0.88, 0.18, 0.12, 1)
        let darkCap = RGBA(0.14, 0.14, 0.16, 1)

        for sx: Float in [-2.6, 2.6] {
            box(center: base + side * (sx * scale) + up * (3.2 * scale), side: side, up: up, forward: fwd,
                half: V3(0.32 * scale, 3.4 * scale, 0.32 * scale), color: vermilion, includeBottom: false)
            box(center: base + side * (sx * scale) + up * (0.5 * scale), side: side, up: up, forward: fwd,
                half: V3(0.44 * scale, 0.6 * scale, 0.44 * scale), color: darkCap, includeBottom: false)
        }
        // Lower tie beam (nuki) & upper curved lintel (kasagi)
        box(center: base + up * (4.9 * scale), side: side, up: up, forward: fwd,
            half: V3(3.4 * scale, 0.24 * scale, 0.24 * scale), color: vermilion, includeBottom: false)
        box(center: base + up * (6.2 * scale), side: side, up: up, forward: fwd,
            half: V3(4.1 * scale, 0.34 * scale, 0.40 * scale), color: vermilion, includeBottom: false)
        box(center: base + up * (6.58 * scale), side: side, up: up, forward: fwd,
            half: V3(4.25 * scale, 0.16 * scale, 0.46 * scale), color: darkCap, includeBottom: false)
    }

    /// Sweeps a 2D profile (x = sideways, y = up) along the track with outward-facing normals.
    /// Set `flip = true` to invert normals inward (e.g. for a tunnel interior lining).
    mutating func ribbon(track: Track, from: Float, to: Float, step: Float,
                         profile: [SIMD2<Float>], color: RGBA, caps: Bool = false, flip: Bool = false) {
        let span = to - from
        guard span > 0.01, profile.count >= 2 else { return }
        let segments = max(1, Int((span / step).rounded(.up)))
        var previous: [V3] = []
        previous.reserveCapacity(profile.count)
        for s in 0...segments {
            let d = from + span * Float(s) / Float(segments)
            let f = track.frame(at: d)
            var ring: [V3] = []
            ring.reserveCapacity(profile.count)
            for p in profile {
                ring.append(f.position + f.side * p.x + f.up * p.y)
            }
            if s > 0 {
                for i in 0..<(ring.count - 1) {
                    if flip {
                        quad(previous[i], previous[i + 1], ring[i + 1], ring[i], color)
                    } else {
                        quad(previous[i], ring[i], ring[i + 1], previous[i + 1], color)
                    }
                }
            }
            if caps && (s == 0 || s == segments) && ring.count >= 3 {
                let isEnd = (s == segments) != flip
                for i in 1..<(ring.count - 1) {
                    if isEnd {
                        tri(ring[0], ring[i + 1], ring[i], color)
                    } else {
                        tri(ring[0], ring[i], ring[i + 1], color)
                    }
                }
            }
            previous = ring
        }
    }

    /// Creates a shared matte vertex-coloured material for chunked static meshes.
    static func defaultMaterial(doubleSided: Bool = false) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = PColor.white
        material.isDoubleSided = doubleSided
        return material
    }

    func geometry(doubleSided: Bool = false, material: SCNMaterial? = nil) -> SCNGeometry {
        let count = vertices.count
        let stride = MemoryLayout<MeshVertex>.stride
        let data = vertices.withUnsafeBufferPointer { Data(buffer: $0) }
        let vSource = SCNGeometrySource(data: data, semantic: .vertex, vectorCount: count,
                                        usesFloatComponents: true, componentsPerVector: 3,
                                        bytesPerComponent: 4, dataOffset: 0, dataStride: stride)
        let nSource = SCNGeometrySource(data: data, semantic: .normal, vectorCount: count,
                                        usesFloatComponents: true, componentsPerVector: 3,
                                        bytesPerComponent: 4, dataOffset: 12, dataStride: stride)
        let cSource = SCNGeometrySource(data: data, semantic: .color, vectorCount: count,
                                        usesFloatComponents: true, componentsPerVector: 3,
                                        bytesPerComponent: 4, dataOffset: 24, dataStride: stride)
        // Implicit sequential vertex order (0, 1, 2, ...) saves allocating & uploading an index buffer.
        let element = SCNGeometryElement(data: nil, primitiveType: .triangles,
                                         primitiveCount: count / 3, bytesPerIndex: 0)
        let geometry = SCNGeometry(sources: [vSource, nSource, cSource], elements: [element])
        geometry.materials = [material ?? MeshBuilder.defaultMaterial(doubleSided: doubleSided)]
        return geometry
    }
}
