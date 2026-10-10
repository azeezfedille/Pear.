import SwiftUI

/// Brand palette (matches the logo files).
enum Brand {
    static let accent = Color(red: 124 / 255, green: 108 / 255, blue: 255 / 255)   // #7C6CFF
    static let cream  = Color(red: 245 / 255, green: 241 / 255, blue: 234 / 255)   // #F5F1EA
    static let ink    = Color(red: 18 / 255, green: 18 / 255, blue: 20 / 255)      // #121214
    static let tile   = Color(red: 26 / 255, green: 26 / 255, blue: 31 / 255)      // #1A1A1F
    static let splash = Color(red: 11 / 255, green: 11 / 255, blue: 13 / 255)      // #0B0B0D
}

/// Letter outlines of the "pear." wordmark, in the 380x240 animation canvas. Shared by the animation and the static logo.
enum PearGlyphs {
    static let pO = "M68.3 173.1L80.7 173.1L80.7 154L80.4 143.9C85.3 148.2 90.7 150.7 95.9 150.7C109.2 150.7 121.3 139 121.3 118.7C121.3 100.4 112.9 88.6 98 88.6C91.3 88.6 84.9 92.2 79.7 96.5L79.5 96.5L78.5 90L68.3 90Z"
    static let pH = "M93.5 140.3C89.9 140.3 85.3 138.9 80.7 135L80.7 106.1C85.7 101.4 90.1 98.9 94.7 98.9C104.6 98.9 108.5 106.5 108.5 118.9C108.5 132.6 102.1 140.3 93.5 140.3Z"
    static let eO = "M159.7 150.7C167.3 150.7 174.2 148 179.6 144.3L175.3 136.5C171 139.3 166.5 140.9 161.2 140.9C151 140.9 143.9 134.1 142.9 122.8L181.3 122.8C181.6 121.3 181.9 119 181.9 116.5C181.9 99.9 173.5 88.6 157.8 88.6C144 88.6 130.8 100.4 130.8 119.6C130.8 139.2 143.5 150.7 159.7 150.7Z"
    static let eH = "M142.8 114.3C144 103.9 150.6 98.3 158 98.3C166.6 98.3 171.2 104.1 171.2 114.3Z"
    static let aO = "M208.7 150.7C215.8 150.7 222.1 147 227.5 142.4L227.9 142.4L228.9 149.2L239 149.2L239 113.6C239 97.8 232.2 88.6 217.5 88.6C208.1 88.6 199.8 92.4 193.7 96.3L198.3 104.7C203.3 101.5 209.1 98.7 215.4 98.7C224.1 98.7 226.5 104.7 226.6 111.5C202 114.1 191.3 120.7 191.3 133.5C191.3 143.9 198.5 150.7 208.7 150.7Z"
    static let aH = "M212.5 140.8C207.2 140.8 203.2 138.4 203.2 132.5C203.2 126 209.1 121.5 226.6 119.4L226.6 133.8C221.8 138.3 217.6 140.8 212.5 140.8Z"
    static let rO = "M255.4 149.2L267.8 149.2L267.8 112.4C271.5 103 277.3 99.6 282.1 99.6C284.6 99.6 286 100 288.1 100.6L290.3 89.7C288.4 89 286.6 88.6 283.7 88.6C277.3 88.6 271 93.1 266.8 100.6L266.6 100.6L265.5 90L255.4 90Z"
    static let dot = "M305 150.7C309.7 150.7 313.4 146.9 313.4 141.9C313.4 136.8 309.7 133.2 305 133.2C300.4 133.2 296.7 136.8 296.7 141.9C296.7 146.9 300.4 150.7 305 150.7Z"

    /// p, e, a, r with their counters (outer outlines wind opposite to the counters: fill with nonzero).
    static let letters: Path = {
        var p = Path()
        for d in [pO, pH, eO, eH, aO, aH, rO] { p.addPath(Outline.parse(d).path) }
        return p
    }()
    static let dotPath: Path = Outline.parse(dot).path
    /// Tight bounds of the wordmark inside the canvas coordinates.
    static let wordmarkBox = CGRect(x: 68.3, y: 88.6, width: 245.1, height: 84.5)
}

enum PearMode {
    /// Full cycle: monogram, face, wink, "pear.", back to the monogram.
    case loop
    /// Plays once and rests on "pear.".
    case intro
    /// Monogram, face, wink, monogram. Loops until the caller removes it (buffering).
    case loader
}

/// Vector data and morph maths for the "pear." face animation, ported from the HTML prototype.
///
/// Every shape is an outline resampled to `samples` points by arc length. A morph moves each point of
/// shape A to the matching point of shape B (start offsets are aligned so outlines don't twist), which is
/// how the P turns into eyes and a smile and then into the letters. Held poses are drawn from the exact
/// vector paths. Everything is built once, off the main thread (see `MediaHubApp`), and is immutable after.
final class PearGeometry: @unchecked Sendable {
    static let shared = PearGeometry()
    static let canvas = CGSize(width: 380, height: 240)
    private static let samples = 128

    struct Frame {
        let tile: Double
        let cream: Path
        let accent: Path
    }

    // MARK: Public

    /// Frame at `ms` since the start (already multiplied by speed).
    func frame(at ms: Double, mode: PearMode) -> Frame {
        let seq = Self.sequence(mode)
        var t = max(ms, 0)
        if seq.loops { t = t.truncatingRemainder(dividingBy: seq.total) }
        else if t >= seq.total { return held(seq.end ?? 0) }
        var i = 0
        while i < seq.steps.count - 1, t > seq.steps[i].ms { t -= seq.steps[i].ms; i += 1 }
        let step = seq.steps[i]
        switch step.kind {
        case .hold(let s): return held(s)
        case .morph(let a, let b): return morph(a, b, min(max(t / step.ms, 0), 1))
        }
    }

    /// The pose to show when motion is reduced.
    func restFrame(mode: PearMode) -> Frame { held(Self.sequence(mode).end ?? 0) }

    /// Length in ms of a one-shot mode, nil for modes that loop.
    static func duration(of mode: PearMode) -> Double? {
        let s = sequence(mode)
        return s.loops ? nil : s.total
    }

    let tile: Path

    // MARK: Build

    private final class Poly {
        var pts: [CGPoint]
        let isPoint: Bool
        init(_ pts: [CGPoint], isPoint: Bool) { self.pts = pts; self.isPoint = isPoint }
    }

    private struct Track {
        let accent: Bool
        let polys: [Poly]
        let delay: [Int: CGFloat]     // morph key (a * 10 + b) -> start fraction
        let end: [Int: CGFloat]       // morph key -> end fraction
    }

    private var tracks: [Track] = []
    private var exactCream: [Path] = []
    private var exactAccent: [Path] = []
    /// Tile opacity per pose: visible behind the monogram and face, gone for the wordmark.
    private static let tileOpacity: [Double] = [1, 1, 1, 0, 1, 0, 1]

    private init() {
        tile = Outline.rrect(130, 60, 120, 120, 28.8).path
        var exactC = [Path](repeating: Path(), count: 7)
        var exactA = [Path](repeating: Path(), count: 7)

        for def in Self.definitions() {
            var polys: [Poly] = []
            var exact: [Path?] = []
            for (i, spec) in def.specs.enumerated() {
                // Identical specs share one outline, so alignment applies to every pose that uses it.
                if let j = def.specs[..<i].firstIndex(of: spec) { polys.append(polys[j]); exact.append(exact[j]); continue }
                guard let outline = spec.outline else {
                    if case .point(let x, let y) = spec {
                        polys.append(Poly(Array(repeating: CGPoint(x: x, y: y), count: Self.samples), isPoint: true))
                    }
                    exact.append(nil)
                    continue
                }
                var pts = Outline.resample(outline.flattened(), count: Self.samples)
                let area = Self.area(pts)
                // Outer outlines wind one way, counters the other, so nonzero fill leaves the holes open.
                if (!def.hole && area < 0) || (def.hole && area > 0) { pts.reverse() }
                polys.append(Poly(pts, isPoint: false))
                exact.append(outline.path)
            }
            Self.align(polys)
            tracks.append(Track(accent: def.accent, polys: polys, delay: def.delay, end: def.end))
            for i in 0..<7 {
                guard let p = exact[i] else { continue }
                if def.accent { exactA[i].addPath(p) } else { exactC[i].addPath(p) }
            }
        }
        exactCream = exactC
        exactAccent = exactA
    }

    // MARK: Frames

    private func held(_ i: Int) -> Frame {
        Frame(tile: Self.tileOpacity[i], cream: exactCream[i], accent: exactAccent[i])
    }

    private func morph(_ a: Int, _ b: Int, _ u: Double) -> Frame {
        var cream = Path(), accent = Path()
        let key = a * 10 + b
        for tr in tracks {
            let pa = tr.polys[a], pb = tr.polys[b]
            if pa.isPoint && pb.isPoint { continue }            // zero area: nothing to draw
            let dl = tr.delay[key] ?? 0, en = tr.end[key] ?? 1
            let p = CGFloat(Self.ease(min(max((u - Double(dl)) / Double(en - dl), 0), 1)))
            let A = pa.pts, B = pb.pts
            if tr.accent { Self.append(&accent, A, B, p) } else { Self.append(&cream, A, B, p) }
        }
        return Frame(tile: Self.tileOpacity[a] + (Self.tileOpacity[b] - Self.tileOpacity[a]) * Self.ease(u),
                     cream: cream, accent: accent)
    }

    private static func append(_ path: inout Path, _ A: [CGPoint], _ B: [CGPoint], _ p: CGFloat) {
        for j in 0..<A.count {
            let pt = CGPoint(x: A[j].x + (B[j].x - A[j].x) * p, y: A[j].y + (B[j].y - A[j].y) * p)
            if j == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
    }

    private static func ease(_ u: Double) -> Double {
        u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2
    }

    // MARK: Alignment

    private static func area(_ P: [CGPoint]) -> CGFloat {
        var a: CGFloat = 0
        for i in 0..<P.count {
            let p = P[i], q = P[(i + 1) % P.count]
            a += p.x * q.y - q.x * p.y
        }
        return a / 2
    }

    /// Pose graph: which poses are morphed between (0 monogram, 1 face, 2 wink, 3 wordmark).
    private static let edges = [(0, 1), (1, 2), (1, 3), (3, 0)]

    /// Rotates each outline's start point so it lines up with its neighbours in the pose graph.
    private static func align(_ polys: [Poly]) {
        let m = samples
        for _ in 0..<3 {
            for i in 1...3 {
                let poly = polys[i]
                if poly.isPoint { continue }
                var neighbours: [[CGPoint]] = []
                for (a, b) in edges {
                    let o = a == i ? b : (b == i ? a : -1)
                    if o >= 0, !polys[o].isPoint, polys[o] !== poly { neighbours.append(polys[o].pts) }
                }
                if neighbours.isEmpty { continue }
                var best = CGFloat.infinity, bestShift = 0
                for k in 0..<m {
                    var c: CGFloat = 0
                    for n in neighbours {
                        var idx = k
                        for j in 0..<m {
                            let dx = n[j].x - poly.pts[idx].x, dy = n[j].y - poly.pts[idx].y
                            c += dx * dx + dy * dy
                            idx += 1; if idx == m { idx = 0 }
                        }
                    }
                    if c < best { best = c; bestShift = k }
                }
                if bestShift != 0 { poly.pts = Array(poly.pts[bestShift...] + poly.pts[..<bestShift]) }
            }
        }
    }

    // MARK: Shapes

    private enum Spec: Equatable {
        case point(CGFloat, CGFloat)
        case circle(CGFloat, CGFloat, CGFloat, ccw: Bool)
        case rrect(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)
        case arc(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)     // cx, cy, R, width, from°, to°
        case glyph(String)

        var outline: Outline? {
            switch self {
            case .point: return nil
            case .circle(let x, let y, let r, let ccw): return .circle(x, y, r, ccw: ccw)
            case .rrect(let x, let y, let w, let h, let r): return .rrect(x, y, w, h, r)
            case .arc(let x, let y, let R, let w, let a0, let a1): return .arcShape(x, y, R, w, a0, a1)
            case .glyph(let d): return .parse(d)
            }
        }
    }

    private struct Def {
        let accent: Bool
        let hole: Bool
        let specs: [Spec]
        var delay: [Int: CGFloat] = [:]
        var end: [Int: CGFloat] = [:]
    }

    private static func key(_ a: Int, _ b: Int) -> Int { a * 10 + b }

    /// One outline per pose: [monogram, face, wink, wordmark, then variants used by the transitions back to the monogram].
    private static func poses(_ l: Spec, _ f: Spec, _ w: Spec, _ d: Spec,
                              p4: Spec? = nil, p5: Spec? = nil, p6: Spec? = nil) -> [Spec] {
        [l, f, w, d, p4 ?? l, p5 ?? d, p6 ?? f]
    }

    private static func definitions() -> [Def] {
        typealias G = PearGlyphs
        let a = Spec.point(191.6, 111.2), b = Spec.point(94.6, 119.6)
        let eyeL = Spec.rrect(164, 91, 16, 28, 8), eyeR = Spec.rrect(200, 91, 16, 28, 8)
        let smile = Spec.arc(190, 103, 38, 9, 45, 135), wink = Spec.arc(208, 121, 15.5, 8, 230, 310)
        let eOc = Spec.point(156.4, 119.6), eHc = Spec.point(157.0, 106.3)
        let aOc = Spec.point(215.1, 119.6), aHc = Spec.point(214.9, 130.1)
        let rOc = Spec.point(272.9, 118.9)
        return [
            // P stem -> left eye -> (collapses into the word)
            Def(accent: false, hole: false,
                specs: poses(.rrect(158, 82.4, 20.8, 75.2, 10.4), eyeL, eyeL, .point(72.6, 160))),
            // P bowl -> right eye / winking eye -> p
            Def(accent: false, hole: false,
                specs: poses(.circle(191.6, 111.2, 30.4, ccw: false), eyeR, wink, .glyph(G.pO)),
                delay: [key(0, 1): 0.15, key(5, 4): 0.1]),
            // counter of the P -> p counter
            Def(accent: false, hole: true,
                specs: poses(.circle(191.6, 111.2, 12.6, ccw: true), a, a, .glyph(G.pH), p4: a, p5: b, p6: b),
                delay: [key(6, 3): 0.55, key(1, 0): 0.55], end: [key(0, 1): 0.45]),
            Def(accent: false, hole: false, specs: poses(eOc, eOc, eOc, .glyph(G.eO)), delay: [key(6, 3): 0.1]),
            Def(accent: false, hole: true, specs: poses(eHc, eHc, eHc, .glyph(G.eH), p5: eHc), delay: [key(6, 3): 0.6]),
            Def(accent: false, hole: false, specs: poses(aOc, aOc, aOc, .glyph(G.aO)), delay: [key(6, 3): 0.2, key(5, 4): 0.1]),
            Def(accent: false, hole: true, specs: poses(aHc, aHc, aHc, .glyph(G.aH), p5: aHc), delay: [key(6, 3): 0.65]),
            Def(accent: false, hole: false, specs: poses(rOc, rOc, rOc, .glyph(G.rO)), delay: [key(6, 3): 0.3, key(5, 4): 0.2]),
            // accent dot -> smile -> period
            Def(accent: true, hole: false,
                specs: poses(.circle(191.6, 111.2, 13.6, ccw: false), smile, smile, .glyph(G.dot)),
                delay: [key(0, 1): 0.05, key(1, 0): 0.05, key(6, 3): 0.1, key(5, 4): 0.2]),
        ]
    }

    // MARK: Timelines (ms, before the speed multiplier)

    private struct Script {
        enum Kind { case hold(Int), morph(Int, Int) }
        struct Step { let kind: Kind; let ms: Double }
        let steps: [Step]
        let loops: Bool
        let end: Int?
        var total: Double { steps.reduce(0) { $0 + $1.ms } }
    }

    private static func hold(_ s: Int, _ ms: Double) -> Script.Step { .init(kind: .hold(s), ms: ms) }
    private static func move(_ a: Int, _ b: Int, _ ms: Double) -> Script.Step { .init(kind: .morph(a, b), ms: ms) }

    private static func sequence(_ mode: PearMode) -> Script {
        switch mode {
        case .loop:
            return Script(steps: [hold(0, 1000), move(0, 1, 900), hold(1, 700), move(1, 2, 240), hold(2, 380),
                                    move(2, 1, 240), hold(1, 350), move(6, 3, 1000), hold(3, 1500), move(3, 5, 240),
                                    move(5, 4, 1000), move(4, 0, 240)], loops: true, end: nil)
        case .intro:
            return Script(steps: [hold(0, 600), move(0, 1, 800), hold(1, 500), move(1, 2, 220), hold(2, 300),
                                    move(2, 1, 220), hold(1, 300), move(6, 3, 1000)], loops: false, end: 3)
        case .loader:
            return Script(steps: [hold(0, 200), move(0, 1, 700), hold(1, 300), move(1, 2, 240), hold(2, 300),
                                    move(2, 1, 240), hold(1, 200), move(1, 0, 700)], loops: true, end: nil)
        }
    }
}

// MARK: - Outlines

/// A closed vector outline: kept as exact curves for drawing and flattened to points for morphing.
struct Outline {
    enum Cmd { case move(CGPoint), line(CGPoint), cubic(CGPoint, CGPoint, CGPoint), close }
    private(set) var cmds: [Cmd] = []

    mutating func move(_ x: CGFloat, _ y: CGFloat) { cmds.append(.move(CGPoint(x: x, y: y))) }
    mutating func line(_ x: CGFloat, _ y: CGFloat) { cmds.append(.line(CGPoint(x: x, y: y))) }
    mutating func close() { cmds.append(.close) }

    /// Circular arc starting at the current point. Degrees, y down: a positive sweep runs clockwise on screen.
    mutating func arc(center c: CGPoint, r: CGFloat, from a0: CGFloat, to a1: CGFloat) {
        let n = max(1, Int(ceil(abs(a1 - a0) / 90)))
        let step = (a1 - a0) / CGFloat(n)
        for i in 0..<n {
            let t0 = (a0 + step * CGFloat(i)) * .pi / 180
            let t1 = (a0 + step * CGFloat(i + 1)) * .pi / 180
            let k = 4.0 / 3.0 * tan((t1 - t0) / 4) * r
            let p1 = CGPoint(x: c.x + r * cos(t1), y: c.y + r * sin(t1))
            cmds.append(.cubic(CGPoint(x: c.x + r * cos(t0) - k * sin(t0), y: c.y + r * sin(t0) + k * cos(t0)),
                               CGPoint(x: p1.x + k * sin(t1), y: p1.y - k * cos(t1)), p1))
        }
    }

    static func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, ccw: Bool = false) -> Outline {
        var o = Outline()
        let s: CGFloat = ccw ? -1 : 1
        let c = CGPoint(x: cx, y: cy)
        o.move(cx - r, cy)
        o.arc(center: c, r: r, from: 180, to: 180 + 180 * s)
        o.arc(center: c, r: r, from: 180 + 180 * s, to: 180 + 360 * s)
        o.close()
        return o
    }

    static func rrect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Outline {
        var o = Outline()
        o.move(x + r, y); o.line(x + w - r, y)
        o.arc(center: CGPoint(x: x + w - r, y: y + r), r: r, from: -90, to: 0)
        o.line(x + w, y + h - r)
        o.arc(center: CGPoint(x: x + w - r, y: y + h - r), r: r, from: 0, to: 90)
        o.line(x + r, y + h)
        o.arc(center: CGPoint(x: x + r, y: y + h - r), r: r, from: 90, to: 180)
        o.line(x, y + r)
        o.arc(center: CGPoint(x: x + r, y: y + r), r: r, from: 180, to: 270)
        o.close()
        return o
    }

    /// A stroked arc (round caps) as a filled outline: radius `R`, stroke `w`, from `a0` to `a1` degrees.
    static func arcShape(_ cx: CGFloat, _ cy: CGFloat, _ R: CGFloat, _ w: CGFloat, _ a0: CGFloat, _ a1: CGFloat) -> Outline {
        var o = Outline()
        let h = w / 2, c = CGPoint(x: cx, y: cy)
        func P(_ a: CGFloat, _ r: CGFloat) -> CGPoint {
            CGPoint(x: cx + r * cos(a * .pi / 180), y: cy + r * sin(a * .pi / 180))
        }
        let start = P(a0, R + h)
        o.move(start.x, start.y)
        o.arc(center: c, r: R + h, from: a0, to: a1)
        o.arc(center: P(a1, R), r: h, from: a1, to: a1 + 180)
        o.arc(center: c, r: R - h, from: a1, to: a0)
        o.arc(center: P(a0, R), r: h, from: a0 + 180, to: a0 + 360)
        o.close()
        return o
    }

    /// Absolute M / L / C / Z path data (all the glyph outlines use).
    static func parse(_ d: String) -> Outline {
        var o = Outline()
        var cmd: Character = "M"
        var nums: [CGFloat] = []
        var buf = ""
        func flushNumber() { if !buf.isEmpty { nums.append(CGFloat(Double(buf) ?? 0)); buf = "" } }
        func apply() {
            switch cmd {
            case "M", "L":
                var i = 0
                while i + 1 < nums.count {
                    if cmd == "M" && i == 0 { o.move(nums[i], nums[i + 1]) } else { o.line(nums[i], nums[i + 1]) }
                    i += 2
                }
            case "C":
                var i = 0
                while i + 5 < nums.count {
                    o.cmds.append(.cubic(CGPoint(x: nums[i], y: nums[i + 1]), CGPoint(x: nums[i + 2], y: nums[i + 3]),
                                         CGPoint(x: nums[i + 4], y: nums[i + 5])))
                    i += 6
                }
            case "Z": o.close()
            default: break
            }
            nums.removeAll()
        }
        for ch in d {
            if ch.isLetter { flushNumber(); apply(); cmd = ch }
            else if ch == " " || ch == "," { flushNumber() }
            else { buf.append(ch) }
        }
        flushNumber(); apply()
        return o
    }

    var path: Path {
        var p = Path()
        for c in cmds {
            switch c {
            case .move(let a): p.move(to: a)
            case .line(let a): p.addLine(to: a)
            case .cubic(let c1, let c2, let e): p.addCurve(to: e, control1: c1, control2: c2)
            case .close: p.closeSubpath()
            }
        }
        return p
    }

    /// Dense polyline following the curves.
    func flattened(steps: Int = 24) -> [CGPoint] {
        var pts: [CGPoint] = []
        var cur = CGPoint.zero
        for c in cmds {
            switch c {
            case .move(let a), .line(let a): pts.append(a); cur = a
            case .cubic(let c1, let c2, let e):
                for i in 1...steps {
                    let t = CGFloat(i) / CGFloat(steps), u = 1 - t
                    pts.append(CGPoint(
                        x: u * u * u * cur.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * e.x,
                        y: u * u * u * cur.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * e.y))
                }
                cur = e
            case .close: break
            }
        }
        return pts
    }

    /// `count` points spaced evenly by arc length along the closed polyline, starting at its first point.
    static func resample(_ pts: [CGPoint], count m: Int) -> [CGPoint] {
        let n = pts.count
        var cum: [CGFloat] = [0]
        for i in 1...n {
            let a = pts[i - 1], b = pts[i % n]
            cum.append(cum[i - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = cum[n]
        var out: [CGPoint] = []
        out.reserveCapacity(m)
        var seg = 0
        for k in 0..<m {
            let target = total * CGFloat(k) / CGFloat(m)
            while seg < n - 1, cum[seg + 1] < target { seg += 1 }
            let a = pts[seg], b = pts[(seg + 1) % n]
            let len = cum[seg + 1] - cum[seg]
            let f = len > 0 ? (target - cum[seg]) / len : 0
            out.append(CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
        }
        return out
    }
}
