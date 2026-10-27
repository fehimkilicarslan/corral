import CoreGraphics
import Foundation
import SwiftUI

/// The pictures behind the badges: small generative scenes, drawn as a
/// density field and printed through an ordered dither in the badge's metal.
///
/// A symbol in a circle says which badge this is and nothing else. These say
/// something about the habit — the plan is a blueprint with contour lines, the
/// conductor is as many waves as you ran agents at once, the streak is a flame
/// that grows with the streak — in the look of a one-bit screen. No photographs
/// and no image files: every plate is computed, from a seed and a few of your
/// own numbers, so two people's plates differ where their work differs.
///
/// Each scene is a function from a cell to an ink density between 0 and 1. The
/// image is made at cell resolution — a few thousand cells for a badge — and
/// scaled up without interpolation, so the pixels stay square at any size.
enum DitherArt {

    struct Params: Hashable {
        var seed: UInt64
        /// How far along the habit is, 0–1. Scenes grow with it.
        var strength: Double
        /// A count a scene draws from: waves, nodes, days.
        var count: Int
    }

    /// The ink a plate is printed in, as plain components: the image is built
    /// byte by byte, below SwiftUI's colours.
    struct Ink: Hashable {
        var red: Double
        var green: Double
        var blue: Double
        /// Opacity of full ink. Locked plates print faint.
        var strength: Double = 1
        /// The half-tone, as a share of full ink.
        var mid: Double = 0.42
    }

    /// One cell of the plate, in every coordinate a scene might want: unit
    /// (`u`, `v` from the top left), centred and aspect-true (`x`, `y` in
    /// heights, y downwards), and the integer grid for pixel-exact patterns.
    struct Cell {
        let u: Double, v: Double
        let x: Double, y: Double
        let col: Int, row: Int
        let cols: Int, rows: Int
        var aspect: Double { Double(cols) / Double(rows) }
    }

    typealias Field = (Cell) -> Double

    // ─ Rendering ────────────────────────────────────────────────────────────

    private static let cache = NSCache<NSString, CGImage>()

    static func image(_ scene: ArtScene, _ params: Params, ink: Ink, cols: Int, rows: Int) -> CGImage? {
        let cols = max(4, cols), rows = max(4, rows)
        let strength = (params.strength * 20).rounded() / 20
        let key = "\(scene.rawValue)|\(params.seed)|\(strength)|\(params.count)|\(ink.hashValue)|\(cols)x\(rows)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        var rounded = params
        rounded.strength = strength
        guard let image = render(field(scene, rounded, aspect: Double(cols) / Double(rows)),
                                 ink: ink, cols: cols, rows: rows)
        else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    /// Bayer 8×8: every threshold from 0 to 63 once, arranged so that any
    /// density turns into an even, cross-hatched texture rather than noise.
    static let bayer: [[Int]] = [
        [0, 32, 8, 40, 2, 34, 10, 42],
        [48, 16, 56, 24, 50, 18, 58, 26],
        [12, 44, 4, 36, 14, 46, 6, 38],
        [60, 28, 52, 20, 62, 30, 54, 22],
        [3, 35, 11, 43, 1, 33, 9, 41],
        [51, 19, 59, 27, 49, 17, 57, 25],
        [15, 47, 7, 39, 13, 45, 5, 37],
        [63, 31, 55, 23, 61, 29, 53, 21],
    ]

    /// Three levels — paper, half ink, full ink — which is what keeps the
    /// plates readable when they are small: two would lose the shading, more
    /// would lose the look.
    static func level(_ density: Double, col: Int, row: Int, levels: Int = 3) -> Int {
        let d = min(1, max(0, density))
        let threshold = (Double(bayer[row & 7][col & 7]) + 0.5) / 64
        let scaled = d * Double(levels - 1)
        let floor = scaled.rounded(.down)
        return Int(floor) + (scaled - floor > threshold ? 1 : 0)
    }

    static func render(_ field: Field, ink: Ink, cols: Int, rows: Int) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: cols * rows * 4)
        let aspect = Double(cols) / Double(rows)
        let alphas = [0.0, ink.mid * ink.strength, ink.strength]
        for row in 0..<rows {
            for col in 0..<cols {
                let u = (Double(col) + 0.5) / Double(cols)
                let v = (Double(row) + 0.5) / Double(rows)
                let cell = Cell(u: u, v: v, x: (u - 0.5) * aspect, y: v - 0.5,
                                col: col, row: row, cols: cols, rows: rows)
                let q = level(field(cell), col: col, row: row)
                guard q > 0 else { continue }
                let a = alphas[min(q, 2)]
                let i = (row * cols + col) * 4
                // Premultiplied, as the bitmap below declares.
                bytes[i] = UInt8((ink.red * a * 255).rounded())
                bytes[i + 1] = UInt8((ink.green * a * 255).rounded())
                bytes[i + 2] = UInt8((ink.blue * a * 255).rounded())
                bytes[i + 3] = UInt8((a * 255).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: cols * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // ─ Noise and shapes ─────────────────────────────────────────────────────

    static func hash(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
        var h = UInt64(bitPattern: Int64(x)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(y)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= seed &* 0x1656_67B1_9E37_79F9
        h ^= h >> 33
        h &*= 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 33
        h &*= 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 33
        return Double(h >> 11) / Double(UInt64(1) << 53)
    }

    /// Value noise: the hash on a lattice, eased between its corners.
    static func noise(_ x: Double, _ y: Double, _ seed: UInt64) -> Double {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        let fx = x - Double(x0), fy = y - Double(y0)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(x0, y0, seed), b = hash(x0 + 1, y0, seed)
        let c = hash(x0, y0 + 1, seed), d = hash(x0 + 1, y0 + 1, seed)
        return (a + (b - a) * sx) + ((c + (d - c) * sx) - (a + (b - a) * sx)) * sy
    }

    static func fbm(_ x: Double, _ y: Double, _ seed: UInt64, octaves: Int = 4) -> Double {
        var sum = 0.0, amplitude = 0.5, frequency = 1.0, total = 0.0
        for octave in 0..<octaves {
            sum += amplitude * noise(x * frequency, y * frequency, seed &+ UInt64(octave) &* 977)
            total += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return sum / total
    }

    static func segment(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / max(1e-9, dx * dx + dy * dy)))
        return hypot(px - (ax + t * dx), py - (ay + t * dy))
    }

    /// Signed distance to a rounded box centred at the origin.
    static func roundedBox(_ px: Double, _ py: Double, halfWidth: Double, halfHeight: Double, radius: Double) -> Double {
        let qx = abs(px) - halfWidth + radius, qy = abs(py) - halfHeight + radius
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - radius
    }

    static func fract(_ x: Double) -> Double { x - x.rounded(.down) }

    static func seed(_ text: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in text.utf8 { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return h
    }
}

// ─ Scenes ───────────────────────────────────────────────────────────────────

/// One scene per badge, named after it.
enum ArtScene: String, CaseIterable {
    case plan, verify, testFirst, calm, codify
    case steer, pushback, context
    case conductor, delegator
    case shipper, tidy
    case night, early, marathon, streak, concise, polite, catchphrase

    static func of(_ archetype: Archetype) -> ArtScene {
        switch archetype.title {
        case "The Architect": return .plan
        case "The Verifier": return .verify
        case "The Conductor": return .conductor
        case "The Navigator": return .steer
        case "The Shipper": return .shipper
        case "The Night Owl": return .night
        default: return .marathon
        }
    }
}

extension DitherArt {

    static func field(_ scene: ArtScene, _ k: Params, aspect: Double) -> Field {
        let seed = k.seed
        switch scene {

        // A blueprint: a construction grid under the contour lines of terrain
        // nobody has built on yet.
        case .plan:
            return { c in
                let step = max(6, c.rows / 4)
                let half = max(3, step / 2)
                let height = fbm(c.u * 1.5 * c.aspect, c.v * 1.5, seed, octaves: 3)
                if abs(fract(height * 7) - 0.5) < 0.055 { return 1 }
                if c.col % step == 0 || c.row % step == 0 { return 0.42 }
                if (c.col % half == 0 && c.row % 2 == 0) || (c.row % half == 0 && c.col % 2 == 0) { return 0.2 }
                return height > 0.62 ? 0.14 : 0
            }

        // A wall of test results, a few of them failing, under a check.
        case .verify:
            let failRate = 0.04 + 0.16 * (1 - k.strength)
            return { c in
                let d = min(segment(c.x, c.y, -0.32, 0.0, -0.1, 0.22), segment(c.x, c.y, -0.1, 0.22, 0.34, -0.27))
                if d < 0.07 { return 1 }
                if d < 0.12 { return 0 }
                guard c.col % 4 != 3, c.row % 4 != 3 else { return 0 }
                let failed = hash(c.col / 4, c.row / 4, seed) < failRate
                if failed { return (c.col % 4 == 1 && c.row % 4 == 1) ? 0 : 0.95 }
                return 0.36
            }

        // Three test tubes, filled to different marks, bubbling.
        case .testFirst:
            let spacing = min(0.34, aspect / 4)
            let tubes = (0..<3).map { i -> (x: Double, level: Double) in
                (Double(i - 1) * spacing, 0.3 - (0.22 + 0.36 * hash(i, 7, seed)))
            }
            return { c in
                for tube in tubes {
                    let w = 0.075, top = -0.38, bottom = 0.3
                    let dx = c.x - tube.x
                    let inside: (Double) -> Bool = { r in
                        (abs(dx) < r && c.y > top && c.y < bottom) || hypot(dx, c.y - bottom) < r
                    }
                    guard inside(w) else { continue }
                    if !inside(w - 0.024) || (c.y < top + 0.03) { return 1 }
                    if c.y > tube.level {
                        return hash(c.col, c.row, seed &+ 3) < 0.07 ? 0 : 0.62
                    }
                    return 0.08
                }
                return abs(c.y - 0.42) < 0.012 ? 0.5 : 0
            }

        // A heartbeat — P, QRS, T — settling into a flat, quiet line.
        case .calm:
            // Two or three beats whatever the plate's shape, the first one
            // whole, before the line goes flat.
            let period = min(0.55, max(0.45, aspect * 0.3))
            let offset = 0.35 * period - (0.14 - 0.5) * aspect
            let scale = 0.55 + 0.45 * min(1, aspect / 2.8)
            let trace: (Double) -> Double = { x in
                let amp = max(0, 1 - (x / aspect + 0.5) / 0.66) * scale
                let p = fract((x + offset) / period + 10)
                var s = 0.0
                switch p {
                case 0.05..<0.20: s = -0.07 * sin(.pi * (p - 0.05) / 0.15)
                case 0.28..<0.32: s = 0.06 * (p - 0.28) / 0.04
                case 0.32..<0.38: s = 0.06 - 0.62 * (p - 0.32) / 0.06
                case 0.38..<0.45: s = -0.56 + 0.84 * (p - 0.38) / 0.07
                case 0.45..<0.52: s = 0.28 - 0.28 * (p - 0.45) / 0.07
                case 0.60..<0.80: s = -0.11 * sin(.pi * (p - 0.6) / 0.2)
                default: s = 0
                }
                return 0.1 + s * amp
            }
            return { c in
                let dx = 1 / Double(c.rows)
                let ys = [trace(c.x - dx), trace(c.x), trace(c.x + dx)]
                if c.y >= ys.min()! - 0.026 && c.y <= ys.max()! + 0.026 { return 1 }
                if abs(c.y - ys[1]) < 0.09 { return 0.26 }
                if c.col % 10 == 0 { return 0.2 }
                return c.row % 3 == 0 ? 0.12 : 0
            }

        // A page of rules: a title, lines of words, a margin, a cursor.
        case .codify:
            return { c in
                let height = max(4, c.rows / 7)
                let r = c.row / height, within = c.row % height
                let margin = max(3, c.cols / 9)
                if c.col == margin { return 0.45 }
                let title = r == 0
                guard within >= 1 && within <= (title ? 3 : 2) else { return 0 }
                if c.col > margin - 4 && c.col < margin - 1 { return title ? 0 : 0.5 }
                guard c.col > margin + 1 else { return 0 }
                let end = Double(c.cols) * (title ? 0.5 : 0.55 + 0.38 * hash(r, 999, seed))
                let x = c.col - margin - 2
                if Double(c.col) > end {
                    let last = (c.rows / height) - 1
                    return (r == last && Double(c.col) < end + 3) ? 1 : 0
                }
                let word = x / 8, into = x % 8
                let length = 3 + Int(hash(word, r, seed) * 5)
                guard into < min(length, 7) else { return 0 }
                return title ? 1 : 0.58
            }

        // A wheel, turned a little, with the arcs of its motion.
        case .steer:
            let tilt = (hash(1, 1, seed) - 0.5) * 0.8
            return { c in
                let x = c.x, y = c.y - 0.02
                let r = hypot(x, y)
                if abs(r - 0.34) < 0.036 || r < 0.075 { return 1 }
                for k in 0..<3 {
                    let a = .pi / 2 + tilt + Double(k) * 2 * .pi / 3
                    if segment(x, y, 0, 0, 0.34 * cos(a), 0.34 * sin(a)) < 0.026 { return 1 }
                }
                let angle = atan2(y, x) - tilt
                if abs(r - 0.45) < 0.013 && fract(angle * 3 / (2 * .pi) + 0.1) < 0.33 { return 0.75 }
                return r < 0.34 ? 0.07 + 0.3 * (1 - r / 0.34) : 0
            }

        // Branches leaving a trunk: the road not taken, taken.
        case .pushback:
            var segments: [(Double, Double, Double, Double, Double)] = []
            var nodes: [(Double, Double)] = []
            func grow(_ x: Double, _ y: Double, _ angle: Double, _ length: Double, _ depth: Int, _ id: Int) {
                let ex = x + cos(angle) * length, ey = y + sin(angle) * length
                segments.append((x, y, ex, ey, max(0.012, 0.034 * pow(0.78, Double(depth)))))
                nodes.append((ex, ey))
                guard depth < 4 else { return }
                let spread = 0.32 + 0.3 * hash(id, depth, seed)
                grow(ex, ey, angle - spread, length * 0.72, depth + 1, id * 2)
                grow(ex, ey, angle + spread * 0.8, length * 0.7, depth + 1, id * 2 + 1)
            }
            grow(0, 0.5, -.pi / 2, 0.3, 0, 1)
            return { c in
                for (x, y) in nodes where hypot(c.x - x, c.y - y) < 0.032 {
                    return hypot(c.x - x, c.y - y) < 0.014 ? 0 : 1
                }
                for (ax, ay, bx, by, w) in segments where segment(c.x, c.y, ax, ay, bx, by) < w { return 1 }
                return (c.col % 6 == 0 && c.row % 6 == 0) ? 0.5 : 0
            }

        // Clutter wiped clean in one stroke.
        case .context:
            return { c in
                let edge = -0.05 + 0.3 * c.y + 0.02 * sin(c.y * 22)
                if abs(c.x - edge) < 0.035 { return 1 }
                if c.x < edge {
                    let n = fbm(Double(c.col) / 3.5, Double(c.row) / 3.5, seed, octaves: 2)
                    return n > 0.5 ? 0.9 : 0.24
                }
                return hash(c.col, c.row, seed) < 0.012 ? 0.7 : 0
            }

        // One wave per agent you have run at once.
        case .conductor:
            let count = max(2, min(6, k.count))
            let waves = (0..<count).map { i -> (base: Double, amp: Double, freq: Double, phase: Double) in
                let base = -0.38 + 0.76 * (Double(i) + 0.5) / Double(count)
                return (base, 0.3 / Double(count), 1.2 + Double(i) * 0.65, hash(i, 3, seed))
            }
            return { c in
                var fill = 0.0
                for w in waves {
                    let angle = 2 * .pi * (w.freq * c.u + w.phase)
                    let y = w.base + w.amp * sin(angle)
                    let slope = w.amp * 2 * .pi * w.freq * cos(angle) / c.aspect
                    if abs(c.y - y) < 0.02 * sqrt(1 + slope * slope) { return 1 }
                    // Between the wave and its rest line.
                    if (c.y - y) * (c.y - w.base) < 0 { fill = max(fill, 0.26) }
                }
                if c.col % max(6, c.cols / 8) == 0 { return max(fill, 0.16) }
                return fill
            }

        // A hub and the subagents it sent out.
        case .delegator:
            let spokes = max(3, min(9, 3 + k.count / 25))
            let spread = min(aspect * 0.9, 2.2)
            let ends = (0..<spokes).map { j -> (Double, Double) in
                let a = 2 * .pi * Double(j) / Double(spokes) + hash(j, 5, seed) * 0.35
                return (cos(a) * 0.34 * spread, sin(a) * 0.34)
            }
            return { c in
                let r = hypot(c.x, c.y)
                if r < 0.09 { return 1 }
                if r > 0.115 && r < 0.13 { return 0.6 }
                for (x, y) in ends {
                    let d = hypot(c.x - x, c.y - y)
                    if d < 0.05 { return d < 0.022 ? 0 : 1 }
                }
                for (x, y) in ends where segment(c.x, c.y, 0, 0, x, y) < 0.013 {
                    let t = hypot(c.x, c.y) / max(0.01, hypot(x, y))
                    return fract(t * 9) < 0.6 ? 0.8 : 0
                }
                let orbit = hypot(c.x / spread, c.y)
                return abs(orbit - 0.34) < 0.007 ? 0.3 : 0
            }

        // A contribution grid, busier towards today.
        case .shipper:
            return { c in
                let size = max(3, c.rows / 7)
                let top = (c.rows - 7 * size) / 2
                let row = c.row - top
                guard row >= 0, row < 7 * size, row % size < size - 1, c.col % size < size - 1 else { return 0 }
                let sx = c.col / size, sy = row / size
                let activity = fbm(Double(sx) * 0.45, Double(sy) * 0.6, seed, octaves: 2) * 0.75
                    + c.u * 0.45 * (0.4 + k.strength)
                switch activity {
                case ..<0.32: return 0.12
                case ..<0.48: return 0.38
                case ..<0.62: return 0.62
                case ..<0.76: return 0.84
                default: return 1
                }
            }

        // A sorted log: bars in order, left-aligned to one rule.
        case .tidy:
            return { c in
                if abs(c.u - 0.12) < 0.5 / Double(c.cols) { return 0.45 }
                for i in 0..<6 {
                    let center = -0.35 + Double(i) * 0.14
                    guard abs(c.y - center) < 0.035 else { continue }
                    if c.u > 0.04 && c.u < 0.08 { return 0.5 }
                    let end = 0.14 + (0.8 - Double(i) * 0.11) * (0.92 + 0.08 * hash(i, 2, seed))
                    if c.u > 0.14 && c.u < end { return i == 0 ? 1 : 0.8 }
                }
                return 0
            }

        // A crescent over a ridge, and the stars.
        case .night:
            let mx = min(aspect * 0.25, 0.55), my = -0.16, r = 0.19
            return { c in
                let ridge = 0.26 + 0.1 * fbm(c.u * 3 * c.aspect, 0.5, seed)
                if abs(c.y - ridge) < 0.014 { return 1 }
                if c.y > ridge { return 0.55 }
                let d = hypot(c.x - mx, c.y - my)
                if d < r && hypot(c.x - mx - 0.085, c.y - my + 0.05) > r * 0.9 { return 1 }
                if d > r && d < r + 0.06 { return 0.3 }
                if hash(c.col, c.row, seed) < 0.018 { return 1 }
                return 0.05 + 0.32 * max(0, c.y + 0.5) * max(0, c.y + 0.5)
            }

        // The sun clearing the horizon, its rays, its reflection.
        case .early:
            let horizon = 0.16, radius = 0.26
            return { c in
                let d = hypot(c.x, c.y - horizon)
                if abs(c.y - horizon) < 0.012 { return 1 }
                if c.y < horizon {
                    if d < radius { return 1 }
                    let ray = fract((atan2(c.y - horizon, c.x) / (2 * .pi)) * 14) < 0.5
                    let fade = max(0, 1 - (d - radius) / 0.7)
                    return ray ? 0.5 * fade + 0.08 : 0.16 * fade
                }
                let depth = c.y - horizon
                if c.row % 3 == 0 && abs(c.x) < radius * max(0, 1 - depth * 2.2) { return 0.9 }
                return c.row % 3 == 0 ? 0.18 : 0.04
            }

        // A long road to a far point, hills on either side.
        case .marathon:
            let vy = -0.1
            return { c in
                if c.y < vy {
                    let hills = vy - 0.1 - 0.12 * fbm(c.u * 2.2 * c.aspect, 3, seed)
                    if abs(c.y - hills) < 0.012 { return 1 }
                    if c.y > hills { return 0.4 }
                    if hypot(c.x - min(c.aspect * 0.3, 0.6), c.y + 0.32) < 0.06 { return 0.9 }
                    return 0
                }
                let t = (c.y - vy) / (0.5 - vy)
                let half = 0.015 + t * 0.42 * min(c.aspect, 2)
                if abs(abs(c.x) - half) < 0.008 + t * 0.02 { return 1 }
                if abs(c.x) < half {
                    if abs(c.x) < 0.004 + t * 0.014 && fract(0.7 / (t + 0.08)) < 0.5 { return 0.9 }
                    return 0.08
                }
                return 0.16 + 0.24 * fbm(c.u * 6, c.v * 3, seed)
            }

        // A flame that grows with the streak.
        case .streak:
            let height = 0.55 + 0.36 * k.strength
            let phase = hash(4, 4, seed) * 6
            return { c in
                let up = 0.5 - c.y
                let t = (up - 0.06) / height
                if t >= 0 && t <= 1 {
                    let wobble = 0.05 * sin(up * 9 + phase) * up
                        + 0.035 * (noise(c.u * 5 * c.aspect, c.v * 5 - phase, seed) - 0.5)
                    let width = 0.3 * pow(1 - t, 0.8) * sqrt(min(1, (t + 0.02) / 0.25))
                    let q = abs(c.x + wobble) / max(0.001, width)
                    if q < 1 {
                        if q < 0.42 && t < 0.55 { return 1 }
                        return 0.5 + 0.5 * (1 - q) * (1 - t)
                    }
                }
                if abs(c.y - 0.44) < 0.02 && abs(c.x) < 0.3 { return 0.32 }
                return (up < 0.5 + height * 0.2 && hash(c.col, c.row, seed) < 0.01) ? 0.8 : 0
            }

        // A prompt, a cursor, and one straight line to the point.
        case .concise:
            let left = -0.5 * aspect + 0.12
            return { c in
                if segment(c.x, c.y, left, -0.13, left + 0.13, 0) < 0.03
                    || segment(c.x, c.y, left + 0.13, 0, left, 0.13) < 0.03 { return 1 }
                if c.x > left + 0.2 && c.x < left + 0.29 && abs(c.y) < 0.11 { return 1 }
                let end = 0.5 * c.aspect - 0.1
                if c.x > left + 0.36 && c.x < end - 0.05 && abs(c.y) < 0.013 { return 0.85 }
                if c.x >= end - 0.09 && c.x < end && abs(c.y) < (end - c.x) * 0.9 { return 1 }
                return c.row % 2 == 0 ? 0.1 : 0
            }

        // A heart, shaded like a halftone, with a ring of its echo.
        case .polite:
            return { c in
                let x = c.x / 0.34, y = -(c.y - 0.03) / 0.34 * 1.08
                let a = x * x + y * y - 1
                let inside = a * a * a - x * x * y * y * y
                let r = hypot(c.x, c.y)
                if inside <= 0 {
                    return inside > -0.03 ? 1 : 0.5 + 0.45 * max(0, 1 - r / 0.4)
                }
                if abs(r - 0.46) < 0.01 && Int(atan2(c.y, c.x) * 20).isMultiple(of: 2) { return 0.6 }
                return 0.22 * max(0, 1 - r / 0.75)
            }

        // The same thing said again, and again, fainter each time.
        case .catchphrase:
            let step = min(0.2, aspect / 8)
            return { c in
                for i in 0..<5 {
                    let cx = -2 * step + Double(i) * step, cy = -0.07 + Double(i) * 0.03
                    let d = roundedBox(c.x - cx, c.y - cy, halfWidth: 0.27, halfHeight: 0.19, radius: 0.07)
                    if abs(d) < 0.024 { return 1 - Double(i) * 0.17 }
                    if i == 0 && d < 0 {
                        let line = abs(c.y - cy + 0.06) < 0.024 || abs(c.y - cy - 0.04) < 0.024
                        return line && c.x < cx + 0.16 && c.x > cx - 0.19 ? 0.62 : 0
                    }
                    if i == 0 && c.y > cy + 0.18 && c.y < cy + 0.32 && c.x > cx - 0.16
                        && c.x < cx - 0.16 + (cy + 0.32 - c.y) {
                        return 1
                    }
                }
                return 0
            }
        }
    }
}

// ─ Views ────────────────────────────────────────────────────────────────────

extension BadgeTier {
    var ink: DitherArt.Ink {
        switch self {
        case .locked: return .init(red: 0.55, green: 0.57, blue: 0.62, strength: 0.55)
        case .bronze: return .init(red: 0.80, green: 0.50, blue: 0.27)
        case .silver: return .init(red: 0.55, green: 0.60, blue: 0.69)
        case .gold: return .init(red: 0.91, green: 0.69, blue: 0.18)
        }
    }
}

extension DitherArt.Params {

    /// A badge's plate: seeded by the badge, grown by how far you have come,
    /// and fed the one count its scene draws.
    static func of(_ badge: Badge, report: InsightReport?) -> DitherArt.Params {
        let strength = badge.hasData ? (Double(badge.tier.rawValue) + badge.progress) / 4 : 0.15
        var count = 0
        if let report {
            switch badge.id {
            case "conductor": count = report.peakParallel
            case "delegator": count = report.dispatches
            case "streak": count = report.longestStreak
            default: break
            }
        }
        return .init(seed: DitherArt.seed(badge.id), strength: strength, count: count)
    }
}

extension DitherArt.Ink {
    /// Corral's own terracotta, for the archetype's plate.
    static let accent = DitherArt.Ink(red: 0.85, green: 0.47, blue: 0.34)

    /// The same ink for a white page. Ink that glows on a dark row is a pale
    /// wash on a light one, and its half-tone at 42% all but disappears, so
    /// on light the ink is darker and the half-tone heavier.
    var onLight: DitherArt.Ink {
        .init(red: red * 0.8, green: green * 0.8, blue: blue * 0.8, strength: strength, mid: 0.62)
    }
}

extension DitherArt.Params {

    /// The archetype's plate is the plate of the badge it is named for,
    /// printed larger — so the picture on the card is one you earned.
    static func of(_ archetype: Archetype, badges: [Badge], report: InsightReport?) -> DitherArt.Params {
        let scene = ArtScene.of(archetype)
        if let badge = badges.first(where: { $0.id == scene.rawValue }) {
            var params = DitherArt.Params.of(badge, report: report)
            params.strength = max(params.strength, 0.5)
            return params
        }
        return .init(seed: DitherArt.seed(archetype.title), strength: 0.5, count: report?.peakParallel ?? 0)
    }
}

/// A scene, printed to fill whatever space it is given. `cell` is the size of
/// one dither pixel, in points.
struct DitherPlate: View {
    let scene: ArtScene
    let params: DitherArt.Params
    let ink: DitherArt.Ink
    var cell: CGFloat = 2.5
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { proxy in
            let cols = Int(proxy.size.width / cell), rows = Int(proxy.size.height / cell)
            let printed = scheme == .light ? ink.onLight : ink
            if let image = DitherArt.image(scene, params, ink: printed, cols: cols, rows: rows) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

/// A badge's plate, at any size, in its tier's ink.
struct BadgeArt: View {
    let badge: Badge
    var report: InsightReport?
    var cell: CGFloat = 2.5

    var body: some View {
        DitherPlate(
            scene: ArtScene(rawValue: badge.id) ?? .marathon,
            params: .of(badge, report: report),
            ink: badge.tier.ink,
            cell: cell
        )
    }
}
