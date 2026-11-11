import CoreGraphics
import Foundation

// MARK: - Window minimise effects, as meshes
//
// While the Atelier Dock replaces the macOS one, Atelier draws the minimise itself: a picture of
// the window, warped through a mesh, on a transparent overlay at display rate. Everything here is
// pure: an effect and a progress give the mesh (positions, picture coordinates, alpha, shade),
// and the overlay only uploads it. Progress 0 is the window where it was, 1 is inside the tile.
// Restoring plays the same mesh from 1 back to 0, so every effect has its matching way back
// (Glass Shatter reassembles, Dissolve streams back out, and so on).
//
// The maths is done in "canonical" coordinates: x across the dock, y growing toward the dock.
// That way one Genie works for a dock at the bottom, the left or the right.

/// The edge the Atelier Dock is on: the effects run toward it.
public enum MinimizeEdge: String, CaseIterable, Sendable {
    case bottom, left, right, top
}

public enum MinimizeEffect: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Whatever `com.apple.dock mineffect` says: Genie, Scale or Suck.
    case system
    case genie, scale, suck
    case lamp, fold, dissolve, portal, shatter, liquid

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "Follow macOS"
        case .genie: "Genie"
        case .scale: "Scale"
        case .suck: "Suck"
        case .lamp: "Magic Lamp"
        case .fold: "Fold"
        case .dissolve: "Dissolve"
        case .portal: "Portal"
        case .shatter: "Glass Shatter"
        case .liquid: "Liquid"
        }
    }

    public var detail: String {
        switch self {
        case .system: "The effect set in Desktop & Dock settings."
        case .genie: "The window pours into its tile through a funnel."
        case .scale: "The window shrinks straight into its tile."
        case .suck: "The window is pulled in from the corner nearest the tile."
        case .lamp: "A genie that narrows to a wisp and twists on the way."
        case .fold: "The window folds like paper, then slips into the tile."
        case .dissolve: "The window breaks into particles that stream into the tile."
        case .portal: "The window ripples and spirals into the tile."
        case .shatter: "The window shatters into glass. It reassembles on the way back."
        case .liquid: "The window melts and pours into the tile."
        }
    }

    /// The effect actually drawn. `system` reads macOS's own setting; anything unknown is Genie,
    /// as it is in macOS.
    public func resolved(systemEffect: String?) -> MinimizeEffect {
        guard self == .system else { return self }
        switch systemEffect?.lowercased() {
        case "scale": return .scale
        case "suck": return .suck
        default: return .genie
        }
    }

    /// With Reduce Motion on, every effect is a short Scale.
    public func reduced(_ reduceMotion: Bool) -> MinimizeEffect { reduceMotion ? .scale : self }
}

/// One vertex of the drawn mesh. Positions in the overlay's points (bottom-left origin), picture
/// coordinates with v = 0 at the window's top. `shade` multiplies the colour (above 1 brightens).
public struct MinimizeVertex: Equatable, Sendable {
    public var x: Float, y: Float, u: Float, v: Float, alpha: Float, shade: Float
    public init(x: Float, y: Float, u: Float, v: Float, alpha: Float = 1, shade: Float = 1) {
        self.x = x; self.y = y; self.u = u; self.v = v; self.alpha = alpha; self.shade = shade
    }
}

public struct MinimizeMesh: Sendable {
    public var vertices: [MinimizeVertex] = []
    /// Triangles, three per entry group.
    public var indices: [UInt32] = []
    public init() {}
}

/// Where the window is, where its tile is and which edge the dock is on. Cocoa-style rects
/// (y up) in the overlay's own coordinates.
public struct MinimizeGeometry: Equatable, Sendable {
    public var window: CGRect
    public var tile: CGRect
    public var edge: MinimizeEdge
    public init(window: CGRect, tile: CGRect, edge: MinimizeEdge) {
        self.window = window; self.tile = tile; self.edge = edge
    }
}

public enum MinimizeTiming {
    /// macOS takes about half a second; shift held makes it slow motion, as in macOS.
    public static func duration(_ effect: MinimizeEffect, restoring: Bool, slow: Bool) -> Double {
        let base: Double
        switch effect {
        case .scale: base = 0.36
        case .dissolve, .shatter, .portal: base = 0.62
        case .fold, .liquid, .lamp: base = 0.56
        default: base = 0.5
        }
        return (restoring ? base * 0.92 : base) * (slow ? slowMotion : 1)
    }

    public static let slowMotion = 8.0

    /// Mesh progress at a time into the animation. Going in it starts gently and speeds into
    /// the tile; coming back it leaves the tile fast and settles softly.
    public static func progress(elapsed: Double, duration: Double, restoring: Bool) -> Double {
        let t = min(max(elapsed / max(duration, 0.001), 0), 1)
        if restoring {
            let e = 1 - pow(1 - t, 3)    // ease out
            return 1 - e
        }
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2   // ease in-out
    }
}

public enum MinimizeEffects {
    /// Grid density of the warped effects: columns across, rows along.
    public static let columns = 20
    public static let rows = 30

    // MARK: Canonical coordinates

    /// Real (Cocoa, y up) to canonical (x across the dock, y toward the dock).
    public static func canonical(_ p: CGPoint, _ edge: MinimizeEdge) -> CGPoint {
        switch edge {
        case .bottom: CGPoint(x: p.x, y: -p.y)
        case .left: CGPoint(x: p.y, y: -p.x)
        case .right: CGPoint(x: p.y, y: p.x)
        case .top: CGPoint(x: p.x, y: p.y)
        }
    }

    public static func real(_ c: CGPoint, _ edge: MinimizeEdge) -> CGPoint {
        switch edge {
        case .bottom: CGPoint(x: c.x, y: -c.y)
        case .left: CGPoint(x: -c.y, y: c.x)
        case .right: CGPoint(x: c.y, y: c.x)
        case .top: CGPoint(x: c.x, y: c.y)
        }
    }

    /// A rect in canonical coordinates, as its across and along spans.
    struct Box {
        var l: Double, r: Double, t: Double, b: Double   // t < b: b is nearer the dock
        var w: Double { r - l }
        var h: Double { b - t }
        var cx: Double { (l + r) / 2 }
        var cy: Double { (t + b) / 2 }
        init(_ rect: CGRect, _ edge: MinimizeEdge) {
            let a = canonical(CGPoint(x: rect.minX, y: rect.minY), edge)
            let c = canonical(CGPoint(x: rect.maxX, y: rect.maxY), edge)
            l = min(a.x, c.x); r = max(a.x, c.x); t = min(a.y, c.y); b = max(a.y, c.y)
        }
    }

    /// The window point a picture coordinate shows, in canonical coordinates.
    static func base(u: Double, v: Double, _ g: MinimizeGeometry) -> CGPoint {
        let w = g.window
        return canonical(CGPoint(x: w.minX + u * w.width, y: w.maxY - v * w.height), g.edge)
    }

    // MARK: Small maths

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
    public static func smoothstep(_ x: Double) -> Double { let t = clamp01(x); return t * t * (3 - 2 * t) }
    static func easeIn(_ x: Double) -> Double { let t = clamp01(x); return t * t * t }
    static func easeInOut(_ x: Double) -> Double { let t = clamp01(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    /// A stable pseudo-random number in 0..<1 for an integer seed.
    public static func hash(_ n: Int) -> Double {
        var x = UInt64(bitPattern: Int64(n)) &* 0x9E37_79B9_7F4A_7C15
        x ^= x >> 31; x = x &* 0xBF58_476D_1CE4_E5B9; x ^= x >> 29
        return Double(x % 1_000_003) / 1_000_003
    }

    /// The rect inside the tile the window lands in: the window's shape, fitted to the tile.
    static func landing(_ g: MinimizeGeometry) -> CGRect {
        let t = g.tile, w = g.window
        guard w.width > 0, w.height > 0 else { return t }
        let scale = min(t.width / w.width, t.height / w.height) * 0.9
        let size = CGSize(width: w.width * scale, height: w.height * scale)
        return CGRect(x: t.midX - size.width / 2, y: t.midY - size.height / 2, width: size.width, height: size.height)
    }

    // MARK: The mesh

    public static func mesh(_ effect: MinimizeEffect, progress: Double, geometry g: MinimizeGeometry) -> MinimizeMesh {
        let t = clamp01(progress)
        switch effect {
        case .system, .genie: return grid(g) { u, v in genie(u: u, v: v, t: t, g, lamp: false) }
        case .lamp: return grid(g) { u, v in genie(u: u, v: v, t: t, g, lamp: true) }
        case .scale: return grid(g, columns: 1, rows: 1) { u, v in scale(u: u, v: v, t: t, g) }
        case .suck: return grid(g) { u, v in suck(u: u, v: v, t: t, g) }
        case .fold: return grid(g, columns: foldPanels * 5, rows: foldPanels * 5) { u, v in fold(u: u, v: v, t: t, g) }
        case .liquid: return grid(g) { u, v in liquid(u: u, v: v, t: t, g) }
        case .portal: return grid(g, columns: 28, rows: 28) { u, v in portal(u: u, v: v, t: t, g) }
        case .dissolve: return dissolve(t: t, g)
        case .shatter: return shatter(t: t, g)
        }
    }

    /// A connected grid whose vertices `place` puts, given their picture coordinates.
    static func grid(_ g: MinimizeGeometry, columns: Int = columns, rows: Int = rows,
                     place: (Double, Double) -> (CGPoint, Double, Double)) -> MinimizeMesh {
        var mesh = MinimizeMesh()
        mesh.vertices.reserveCapacity((columns + 1) * (rows + 1))
        for j in 0...rows {
            for i in 0...columns {
                let u = Double(i) / Double(columns), v = Double(j) / Double(rows)
                let (c, alpha, shade) = place(u, v)
                let p = real(c, g.edge)
                mesh.vertices.append(MinimizeVertex(x: Float(p.x), y: Float(p.y), u: Float(u), v: Float(v),
                                                    alpha: Float(alpha), shade: Float(shade)))
            }
        }
        let stride = UInt32(columns + 1)
        mesh.indices.reserveCapacity(columns * rows * 6)
        for j in 0..<UInt32(rows) {
            for i in 0..<UInt32(columns) {
                let a = j * stride + i, b = a + 1, c = a + stride, d = c + 1
                mesh.indices += [a, b, c, b, d, c]
            }
        }
        return mesh
    }

    // MARK: Genie and Magic Lamp

    /// Apple's genie, in two overlapping phases: the far edge narrows toward the tile along a
    /// smooth funnel while the top stays put, then the picture slides down the funnel and is
    /// squeezed into the tile row by row.
    static func genie(u: Double, v: Double, t: Double, _ g: MinimizeGeometry, lamp: Bool) -> (CGPoint, Double, Double) {
        let w = Box(g.window, g.edge), tile = Box(landing(g), g.edge)
        let p0 = base(u: u, v: v, g)
        // Across and along, as fractions of the window in canonical terms (u and v are the
        // picture's, which turn with the dock's edge).
        let s = clamp01((p0.x - w.l) / max(w.w, 1))
        let bend = smoothstep(t / 0.42)               // the funnel forms
        let slide = easeIn((t - 0.18) / 0.82)         // the picture runs down it
        // Rows travel until the top row sits on the tile's near edge.
        let travel = max(tile.t - w.t, 1)
        var y = p0.y + travel * slide
        let squeeze = tile.h / max(w.h, 1)
        if y > tile.t { y = tile.t + (y - tile.t) * lerp(1, squeeze, slide) }
        // The funnel: window width at the window's top, tile width at the tile.
        let span = max(tile.t - w.t, 1)
        let k = smoothstep((min(y, tile.t) - w.t) / span)
        let curve = lamp ? pow(k, 0.7) : k
        let left = lerp(w.l, lerp(w.l, tile.l, curve), bend)
        let right = lerp(w.r, lerp(w.r, tile.r, curve), bend)
        var x = lerp(left, right, s)
        var shade = 1.0
        if lamp {
            // A wisp: the middle of the funnel pinches narrower than the tile and sways.
            let pinch = sin(Double.pi * k) * bend * (1 - slide * 0.6)
            x = lerp(x, (left + right) / 2, 0.55 * pinch)
            x += sin(Double.pi * k * 2) * (tile.cx - w.cx) * 0.18 * bend * (1 - slide)
            shade = 1 - 0.22 * pinch * (0.5 + 0.5 * cos((s - 0.5) * 6))
        }
        let alpha = 1 - smoothstep((t - 0.88) / 0.12)
        return (CGPoint(x: x, y: y), alpha, shade)
    }

    // MARK: Scale

    static func scale(u: Double, v: Double, t: Double, _ g: MinimizeGeometry) -> (CGPoint, Double, Double) {
        let land = landing(g)
        let from = base(u: u, v: v, g)
        let to = canonical(CGPoint(x: land.minX + u * land.width, y: land.maxY - v * land.height), g.edge)
        let e = t
        return (CGPoint(x: lerp(from.x, to.x, e), y: lerp(from.y, to.y, e)), 1 - smoothstep((t - 0.7) / 0.3), 1)
    }

    // MARK: Suck

    /// The part of the window nearest the tile goes first and the far corners are dragged after.
    static func suck(u: Double, v: Double, t: Double, _ g: MinimizeGeometry) -> (CGPoint, Double, Double) {
        let land = landing(g)
        let from = base(u: u, v: v, g)
        let tile = Box(land, g.edge)
        let w = Box(g.window, g.edge)
        let far = hypot(max(abs(w.l - tile.cx), abs(w.r - tile.cx)), max(abs(w.t - tile.cy), abs(w.b - tile.cy)))
        let d = clamp01(hypot(from.x - tile.cx, from.y - tile.cy) / max(far, 1))
        let local = clamp01(t * 1.7 - d * 0.7)
        let e = easeInOut(local)
        let to = canonical(CGPoint(x: land.midX + (u - 0.5) * land.width * 0.4, y: land.midY - (v - 0.5) * land.height * 0.4), g.edge)
        return (CGPoint(x: lerp(from.x, to.x, e), y: lerp(from.y, to.y, e)), 1 - smoothstep((t - 0.85) / 0.15), 1)
    }

    // MARK: Fold

    static let foldPanels = 6

    /// The window folds into an accordion against its edge nearest the dock, its creases lit
    /// and shaded, then the folded stack slips into the tile.
    static func fold(u: Double, v: Double, t: Double, _ g: MinimizeGeometry) -> (CGPoint, Double, Double) {
        let w = Box(g.window, g.edge)
        let land = Box(landing(g), g.edge)
        let p0 = base(u: u, v: v, g)
        let across = clamp01((p0.x - w.l) / max(w.w, 1)), along = clamp01((p0.y - w.t) / max(w.h, 1))
        let folding = easeInOut(t / 0.55)
        let fly = easeIn((t - 0.4) / 0.6)
        let angle = folding * 1.38                              // nearly flat at the end
        let panels = Double(foldPanels)
        let index = min(floor(along * panels + 1e-9), panels - 1)
        let within = along * panels - index                          // 0 at a panel's top crease
        let height = w.h * cos(angle)
        // Stacked against the near edge: the folded block shrinks toward the dock.
        let top = w.b - height
        let y = top + (index + within) / panels * height
        // Creases away from the eye pinch inward a little, as a folded sheet in perspective does.
        let even = Int(index) % 2 == 0
        let depth = even ? within : 1 - within
        let pinch = 1 - 0.1 * sin(angle) * depth
        var x = w.cx + (lerp(w.l, w.r, across) - w.cx) * pinch
        let shade = 1 - 0.45 * sin(angle) * depth + 0.12 * sin(angle) * (1 - depth)
        // The folded block flies into the tile.
        let blockTop = top, blockH = max(height, 0.0001)
        let rel = (y - blockTop) / blockH
        let toY = land.t + rel * land.h * max(cos(angle), 0.15)
        let toX = land.cx + (x - w.cx) * land.w / max(w.w, 1)
        x = lerp(x, toX, fly)
        let finalY = lerp(y, toY + land.h * (1 - max(cos(angle), 0.15)) / 2, fly)
        return (CGPoint(x: x, y: finalY), 1 - smoothstep((t - 0.86) / 0.14), shade)
    }

    // MARK: Liquid

    /// Columns melt at their own pace and the window pours down the funnel, wobbling.
    static func liquid(u: Double, v: Double, t: Double, _ g: MinimizeGeometry) -> (CGPoint, Double, Double) {
        let lag = 0.16 * (0.5 + 0.5 * sin(u * 9.4 + 1.3)) * (0.6 + 0.4 * hash(Int(u * 20)))
        let local = clamp01((t - lag) / (1 - lag))
        let (p, alpha, _) = genie(u: u, v: v, t: local, g, lamp: false)
        let melt = sin(Double.pi * t)
        // Drips: lower rows sag more, and the sheet ripples sideways.
        let sag = melt * 26 * v * v * (0.6 + 0.4 * sin(u * 13 + 0.7))
        let wobble = sin(p.y * 0.045 - t * 16) * 9 * melt * (0.3 + v)
        let shine = 1 + 0.18 * melt * sin(v * 14 - t * 12 + u * 3)
        return (CGPoint(x: p.x + wobble, y: p.y + sag * (1 - t)), alpha, shine)
    }

    // MARK: Portal

    /// The window ripples, then spirals into the tile as into a drain.
    static func portal(u: Double, v: Double, t: Double, _ g: MinimizeGeometry) -> (CGPoint, Double, Double) {
        let land = landing(g)
        let center = canonical(CGPoint(x: land.midX, y: land.midY), g.edge)
        let p0 = base(u: u, v: v, g)
        let w = Box(g.window, g.edge)
        let far = max(hypot(w.l - center.x, w.t - center.y), hypot(w.r - center.x, w.t - center.y),
                      hypot(w.l - center.x, w.b - center.y), hypot(w.r - center.x, w.b - center.y), 1)
        let dx = p0.x - center.x, dy = p0.y - center.y
        let r0 = hypot(dx, dy), a0 = atan2(dy, dx)
        let n = r0 / far
        let local = clamp01(t * 1.5 - n * 0.5)
        let e = easeInOut(local)
        let ripple = sin(r0 * 0.06 - t * 26) * 10 * sin(Double.pi * local) * (1 - e)
        let r = max(r0 * (1 - e) + ripple, 0)
        // Straight in from afar, then a tight whirl once close to the tile: the portal stays
        // small, so nothing swings off the screen's edge around it.
        let eye = max(max(land.width, land.height) * 2.6, 120)
        let a = a0 + 2.6 * Double.pi * smoothstep(1 - r / eye) * e
        let shade = 1 + 0.35 * sin(Double.pi * local)
        return (CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)), 1 - smoothstep((t - 0.85) / 0.15), shade)
    }

    // MARK: Dissolve

    public static let particleColumns = 44
    public static let particleRows = 30

    /// The window breaks into small squares that stream along curved paths into the tile,
    /// the edge nearest the dock first. Each square glows a little on the way.
    static func dissolve(t: Double, _ g: MinimizeGeometry) -> MinimizeMesh {
        let land = landing(g)
        let cols = particleColumns, rows = particleRows
        let w = Box(g.window, g.edge)
        let tile = Box(land, g.edge)
        var mesh = MinimizeMesh()
        mesh.vertices.reserveCapacity(cols * rows * 4)
        mesh.indices.reserveCapacity(cols * rows * 6)
        for j in 0..<rows {
            for i in 0..<cols {
                let seed = j * 977 + i
                let u0 = Double(i) / Double(cols), u1 = Double(i + 1) / Double(cols)
                let v0 = Double(j) / Double(rows), v1 = Double(j + 1) / Double(rows)
                let c0 = base(u: (u0 + u1) / 2, v: (v0 + v1) / 2, g)
                let nearness = (c0.y - w.t) / max(w.h, 1)              // 1 at the dock's side
                let delay = 0.5 * ((1 - nearness) * 0.55 + hash(seed) * 0.45)
                let local = clamp01((t - delay) / 0.5)
                let e = easeInOut(local)
                let target = CGPoint(x: tile.l + hash(seed + 11) * tile.w, y: tile.t + hash(seed + 23) * tile.h)
                // A curved path: out to one side and up a little, then down into the tile.
                let side = (hash(seed + 5) - 0.5) * max(w.w, 200) * 0.5
                let control = CGPoint(x: c0.x + side, y: c0.y - 40 - hash(seed + 7) * 90)
                let a = 1 - e
                let px = a * a * c0.x + 2 * a * e * control.x + e * e * target.x
                let py = a * a * c0.y + 2 * a * e * control.y + e * e * target.y
                let size = 1 - 0.8 * e
                let alpha = 1 - smoothstep((local - 0.7) / 0.3)
                let shade = 1 + 0.55 * sin(Double.pi * local)
                let start = UInt32(mesh.vertices.count)
                for (u, v) in [(u0, v0), (u1, v0), (u0, v1), (u1, v1)] {
                    let corner = base(u: u, v: v, g)
                    let p = real(CGPoint(x: px + (corner.x - c0.x) * size, y: py + (corner.y - c0.y) * size), g.edge)
                    mesh.vertices.append(MinimizeVertex(x: Float(p.x), y: Float(p.y), u: Float(u), v: Float(v),
                                                        alpha: Float(alpha), shade: Float(shade)))
                }
                mesh.indices += [start, start + 1, start + 2, start + 1, start + 3, start + 2]
            }
        }
        return mesh
    }

    // MARK: Glass Shatter

    public static let shardColumns = 9
    public static let shardRows = 7

    /// The window cracks into triangular shards that burst out, spin and fall into the tile.
    /// Shards share their corners at rest, so the window is whole at 0.
    static func shatter(t: Double, _ g: MinimizeGeometry) -> MinimizeMesh {
        let cols = shardColumns, rows = shardRows
        let land = landing(g)
        let w = Box(g.window, g.edge)
        let tile = Box(land, g.edge)
        // Jittered lattice in picture coordinates; the border stays straight.
        func corner(_ i: Int, _ j: Int) -> (Double, Double) {
            var u = Double(i) / Double(cols), v = Double(j) / Double(rows)
            if i > 0 && i < cols { u += (hash(i * 131 + j * 17) - 0.5) * 0.7 / Double(cols) }
            if j > 0 && j < rows { v += (hash(i * 71 + j * 193 + 5) - 0.5) * 0.7 / Double(rows) }
            return (u, v)
        }
        var mesh = MinimizeMesh()
        mesh.vertices.reserveCapacity(cols * rows * 6)
        for j in 0..<rows {
            for i in 0..<cols {
                let a = corner(i, j), b = corner(i + 1, j), c = corner(i, j + 1), d = corner(i + 1, j + 1)
                let flip = hash(i * 3 + j * 29) > 0.5
                let tris = flip ? [[a, b, d], [a, d, c]] : [[a, b, c], [b, d, c]]
                for (n, tri) in tris.enumerated() {
                    let seed = (j * cols + i) * 2 + n
                    let points = tri.map { base(u: $0.0, v: $0.1, g) }
                    let cx = points.map(\.x).reduce(0, +) / 3, cy = points.map(\.y).reduce(0, +) / 3
                    let delay = 0.28 * hash(seed + 3)
                    let local = clamp01((t - delay) / 0.72)
                    let burst = smoothstep(local / 0.35)
                    let fall = easeIn((local - 0.15) / 0.85)
                    // Out from the window's centre first, then into the tile.
                    let ox = (cx - w.cx) * 0.22 + (hash(seed + 9) - 0.5) * 60
                    let oy = (cy - w.cy) * 0.22 - 30 - hash(seed + 13) * 50
                    let target = CGPoint(x: tile.l + hash(seed + 21) * tile.w, y: tile.t + hash(seed + 31) * tile.h)
                    let midX = cx + ox * burst, midY = cy + oy * burst
                    let px = lerp(midX, target.x, fall), py = lerp(midY, target.y, fall)
                    let spin = (hash(seed + 41) - 0.5) * 7 * local
                    let size = 1 - 0.88 * fall
                    let alpha = 1 - smoothstep((local - 0.8) / 0.2)
                    let glint = 1 + 0.5 * sin(Double.pi * burst) * hash(seed + 51)
                    for (k, point) in points.enumerated() {
                        let rx = (point.x - cx) * size, ry = (point.y - cy) * size
                        let p = real(CGPoint(x: px + rx * cos(spin) - ry * sin(spin), y: py + rx * sin(spin) + ry * cos(spin)), g.edge)
                        mesh.vertices.append(MinimizeVertex(x: Float(p.x), y: Float(p.y), u: Float(tri[k].0), v: Float(tri[k].1),
                                                            alpha: Float(alpha), shade: Float(glint)))
                    }
                }
            }
        }
        mesh.indices = (0..<UInt32(mesh.vertices.count)).map { $0 }
        return mesh
    }

    /// The bounds of everything a mesh draws, for tests and for sizing.
    public static func bounds(_ mesh: MinimizeMesh, visibleOnly: Bool = false) -> CGRect {
        var rect = CGRect.null
        for v in mesh.vertices where !visibleOnly || v.alpha > 0.001 {
            rect = rect.union(CGRect(x: Double(v.x), y: Double(v.y), width: 0, height: 0))
        }
        return rect
    }
}
