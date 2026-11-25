import simd

/// Selectable world landscapes.
enum WorldTheme: Int, CaseIterable {
    case alps, tokyo

    var title: String {
        switch self {
        case .alps:  return "Swiss Alps"
        case .tokyo: return "Tokyo"
        }
    }

    var symbol: String {
        switch self {
        case .alps:  return "mountain.2.fill"
        case .tokyo: return "building.2.fill"
        }
    }

    var stops: [(name: String, fraction: Float)] {
        switch self {
        case .alps:
            return [("Grindelwald", 0.03), ("Kandersteg", 0.36), ("Andermatt", 0.69)]
        case .tokyo:
            return [("Shibuya", 0.03), ("Shinjuku", 0.36), ("Tokyo Station", 0.69)]
        }
    }

    var cargoTypes: [String] {
        switch self {
        case .alps:
            return ["Alpine Timber", "Swiss Cheese", "Mountain Gear", "Express Mail"]
        case .tokyo:
            return ["Electronics", "Ramen Crates", "Robotics Parts", "Express Parcels"]
        }
    }
}

/// Selectable train models with distinct visuals, speeds, and synthesized audio.
enum TrainKind: Int, CaseIterable {
    case steam, bullet, freight

    var title: String {
        switch self {
        case .steam:   return "Steam Express"
        case .bullet:  return "Shinkansen Bullet"
        case .freight: return "Cargo Freight"
        }
    }

    var symbol: String {
        switch self {
        case .steam:   return "flame.fill"
        case .bullet:  return "bolt.fill"
        case .freight: return "shippingbox.fill"
        }
    }

    /// Top cruising speed in metres per second.
    var maxSpeed: Float {
        switch self {
        case .steam:   return 27.0  // ~97 km/h
        case .bullet:  return 56.0  // ~202 km/h
        case .freight: return 23.5  // ~85 km/h
        }
    }

    /// Peak forward acceleration at full throttle.
    var maxAcceleration: Float {
        switch self {
        case .steam:   return 1.25
        case .bullet:  return 2.45
        case .freight: return 1.05
        }
    }

    /// Peak braking deceleration at full brake.
    var maxBrake: Float {
        switch self {
        case .steam:   return 2.7
        case .bullet:  return 4.6
        case .freight: return 2.4
        }
    }
}

struct TrackFrame {
    var position: V3
    var forward: V3
    /// The model's +X axis. Platforms and station buildings sit on this side of the track.
    var side: V3
    var up: V3
}

/// A named interval along the closed track loop (assuming `start < end` without wrap).
struct TrackSpan {
    let start: Float
    let end: Float
    var length: Float { end - start }

    func contains(_ d: Float, margin: Float = 0) -> Bool {
        d >= start - margin && d <= end + margin
    }

    /// Smooth 0...1 weight that ramps in over `fade` metres inside both ends of the span.
    func factor(at d: Float, fade: Float = 14) -> Float {
        guard d >= start, d <= end else { return 0 }
        return smoothstep(start, start + fade, d) * (1 - smoothstep(end - fade, end, d))
    }
}

/// A closed loop of track, stored as points spaced about one metre apart.
final class Track {
    private struct Segment {
        let minX: Float, maxX: Float
        let minZ: Float, maxZ: Float
        let startIndex: Int, endIndex: Int
    }

    let theme: WorldTheme
    let points: [V3]
    let length: Float
    let viaduct: TrackSpan
    let tunnel: TrackSpan
    let wash: TrackSpan

    private let spacing: Float
    private let coarsePoints: [V3]
    private let coarseDistances: [Float]
    private let segments: [Segment]

    init(theme: WorldTheme = .alps) {
        self.theme = theme
        let dense = 24000
        var raw: [V3] = []
        raw.reserveCapacity(dense + 1)
        for i in 0...dense {
            raw.append(Track.curve(Float(i) / Float(dense) * 2 * .pi, theme: theme))
        }
        var cumulative: [Float] = [0]
        cumulative.reserveCapacity(dense + 1)
        for i in 1...dense {
            cumulative.append(cumulative[i - 1] + simd_distance(raw[i], raw[i - 1]))
        }
        let total = cumulative[dense]
        let count = Int(total.rounded(.down))
        let step = total / Float(count)

        var resampled: [V3] = []
        resampled.reserveCapacity(count)
        var j = 0
        for i in 0..<count {
            let target = Float(i) * step
            while j < dense - 1 && cumulative[j + 1] < target { j += 1 }
            let segment = cumulative[j + 1] - cumulative[j]
            let t = segment > 0 ? (target - cumulative[j]) / segment : 0
            resampled.append(lerp(raw[j], raw[j + 1], t))
        }
        points = resampled
        length = total
        spacing = step

        // Place iconic landmarks cleanly between stations (0.03, 0.36, 0.69).
        viaduct = TrackSpan(start: total * 0.155, end: total * 0.225)
        tunnel = TrackSpan(start: total * 0.485, end: total * 0.555)
        let washCenter = total * 0.84
        wash = TrackSpan(start: washCenter - 15, end: washCenter + 15)

        // Coarse spatial acceleration structure for fast nearest-track queries.
        let coarseStride = 6
        var cPoints: [V3] = []
        var cDist: [Float] = []
        cPoints.reserveCapacity(count / coarseStride + 1)
        cDist.reserveCapacity(count / coarseStride + 1)
        var idx = 0
        while idx < count {
            cPoints.append(resampled[idx])
            cDist.append(Float(idx) * step)
            idx += coarseStride
        }
        coarsePoints = cPoints
        coarseDistances = cDist

        let segSize = 24
        var builtSegments: [Segment] = []
        builtSegments.reserveCapacity((cPoints.count + segSize - 1) / segSize)
        var s = 0
        while s < cPoints.count {
            let e = min(s + segSize, cPoints.count)
            var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
            var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
            for k in s..<e {
                let p = cPoints[k]
                if p.x < minX { minX = p.x }
                if p.x > maxX { maxX = p.x }
                if p.z < minZ { minZ = p.z }
                if p.z > maxZ { maxZ = p.z }
            }
            builtSegments.append(Segment(minX: minX, maxX: maxX, minZ: minZ, maxZ: maxZ,
                                         startIndex: s, endIndex: e))
            s = e
        }
        segments = builtSegments
    }

    /// The loop's shape: gentle alpine climbs in the Alps, flatter express grades in Tokyo.
    private static func curve(_ a: Float, theme: WorldTheme) -> V3 {
        let r = 650 + 120 * sin(3 * a + 0.7) + 50 * sin(5 * a + 2.1)
        let y: Float
        switch theme {
        case .alps:
            y = 40 + 8 * sin(2 * a + 0.4) + 3 * sin(3 * a + 1.0)
        case .tokyo:
            y = 26 + 3.0 * sin(2 * a + 0.4) + 1.2 * sin(3 * a + 1.0)
        }
        return V3(cos(a) * r, y, sin(a) * r)
    }

    func wrap(_ d: Float) -> Float {
        var r = d.truncatingRemainder(dividingBy: length)
        if r < 0 { r += length }
        return r
    }

    /// Shortest signed distance along the track from `a` to `b` (positive means `b` is ahead).
    func signedDelta(from a: Float, to b: Float) -> Float {
        var d = wrap(b - a)
        if d > length / 2 { d -= length }
        return d
    }

    func point(at d: Float) -> V3 {
        let u = wrap(d) / spacing
        let whole = Int(u)
        let i = whole % points.count
        return lerp(points[i], points[(i + 1) % points.count], u - Float(whole))
    }

    func frame(at d: Float) -> TrackFrame {
        let p = point(at: d)
        let forward = simd_normalize(point(at: d + 1.5) - point(at: d - 1.5))
        let side = simd_normalize(simd_cross(V3(0, 1, 0), forward))
        let up = simd_cross(forward, side)
        return TrackFrame(position: p, forward: forward, side: side, up: up)
    }

    func offsetPoint(_ d: Float, lateral: Float, height: Float) -> V3 {
        let f = frame(at: d)
        return f.position + f.side * lateral + f.up * height
    }

    func grade(at d: Float) -> Float {
        frame(at: d).forward.y
    }

    func curvature(at d: Float) -> Float {
        let f0 = frame(at: d - 6)
        let f1 = frame(at: d + 6)
        let df = f1.forward - f0.forward
        return simd_dot(df, f0.side) / 12.0
    }

    func isOnViaduct(_ d: Float, margin: Float = 0) -> Bool {
        viaduct.contains(wrap(d), margin: margin)
    }

    func isInTunnel(_ d: Float, margin: Float = 0) -> Bool {
        tunnel.contains(wrap(d), margin: margin)
    }

    func isInWash(_ d: Float, margin: Float = 0) -> Bool {
        wash.contains(wrap(d), margin: margin)
    }

    func viaductFactor(at d: Float) -> Float {
        viaduct.factor(at: wrap(d), fade: 10)
    }

    func tunnelFactor(at d: Float) -> Float {
        tunnel.factor(at: wrap(d), fade: 14)
    }

    func washFactor(at d: Float) -> Float {
        wash.factor(at: wrap(d), fade: 4)
    }

    /// Fast AABB-pruned nearest-point query against the coarse track loop.
    func nearest(x: Float, z: Float) -> (distance: Float, along: Float, y: Float) {
        var bestSeg = 0
        var bestBoxSq = Float.greatestFiniteMagnitude
        for i in 0..<segments.count {
            let seg = segments[i]
            let dx = x < seg.minX ? (seg.minX - x) : (x > seg.maxX ? (x - seg.maxX) : 0)
            let dz = z < seg.minZ ? (seg.minZ - z) : (z > seg.maxZ ? (z - seg.maxZ) : 0)
            let boxSq = dx * dx + dz * dz
            if boxSq < bestBoxSq {
                bestBoxSq = boxSq
                bestSeg = i
            }
        }

        var bestSq = Float.greatestFiniteMagnitude
        var bestIdx = 0

        func scan(_ seg: Segment) {
            for k in seg.startIndex..<seg.endIndex {
                let p = coarsePoints[k]
                let dx = p.x - x, dz = p.z - z
                let dSq = dx * dx + dz * dz
                if dSq < bestSq {
                    bestSq = dSq
                    bestIdx = k
                }
            }
        }

        scan(segments[bestSeg])
        for i in 0..<segments.count where i != bestSeg {
            let seg = segments[i]
            let dx = x < seg.minX ? (seg.minX - x) : (x > seg.maxX ? (x - seg.maxX) : 0)
            let dz = z < seg.minZ ? (seg.minZ - z) : (z > seg.maxZ ? (z - seg.maxZ) : 0)
            if dx * dx + dz * dz < bestSq {
                scan(seg)
            }
        }

        return (bestSq.squareRoot(), coarseDistances[bestIdx], coarsePoints[bestIdx].y)
    }
}
