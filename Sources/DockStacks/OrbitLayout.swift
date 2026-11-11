import CoreGraphics
import Foundation

// Where things sit, for every layout. Pure geometry: no views, no AppKit.

/// A place on the field. Ring spots travel an ellipse, still spots stay put.
struct OrbitSpot: Equatable, Sendable {
    var center: CGPoint
    var rx = 0.0
    var ry = 0.0
    var phase = 0.0
    var rate = 0.0
    /// An ellipse sweeps fastest over its flat sides. Rings even that walk out; a galaxy turns rigidly.
    var even = true

    @inline(__always) private func angle(_ time: Double) -> Double {
        let u = phase + rate * time
        guard even else { return u }
        return u + (rx - ry) / (2 * (rx + ry)) * sin(2 * u)
    }

    @inline(__always) func point(_ time: Double) -> CGPoint {
        guard rx > 0 else { return center }
        let a = angle(time)
        return CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a))
    }

    /// Point and depth together, one sin and one cos. Depth is 0 at the far side, 1 at the near side.
    @inline(__always) func place(_ time: Double) -> (CGPoint, Double) {
        guard rx > 0 else { return (center, 1) }
        let a = angle(time)
        let s = sin(a)
        return (CGPoint(x: center.x + rx * cos(a), y: center.y + ry * s), (s + 1) / 2)
    }

    func depth(_ time: Double) -> Double { place(time).1 }
}

struct OrbitRing: Identifiable, Equatable, Sendable {
    let rx: Double
    let ry: Double
    var id: Double { ry }
}

struct OrbitLayoutParams: Equatable, Sendable {
    var style = OrbitLayoutStyle.orbits
    var rings = 0
    var spacing = 92.0
    var icon = 62.0
    var speed = 1.0
    var direction = OrbitDriftDirection.alternate
    var recents = true

    init() {}

    init(_ options: OrbitOptions) {
        style = options.layout
        rings = options.rings
        spacing = options.ringSpacing
        icon = options.iconSize
        speed = options.driftSpeed
        direction = options.driftDirection
        recents = options.showRecents
    }

    var cell: Double { icon + 34 }
    var scale: Double { cell / 96 }
}

enum OrbitLayout {
    static let recentStep = 58.0

    static func field(_ size: CGSize, _ p: OrbitLayoutParams) -> CGRect {
        let top = p.recents ? 178.0 : 112.0
        return CGRect(x: 0, y: top, width: size.width, height: max(300, size.height - top - 100))
    }

    static func titlePoint(_ p: OrbitLayoutParams, field: CGRect, core: Bool) -> CGPoint {
        p.style.centredTitle && !core ? CGPoint(x: field.midX, y: field.midY) : CGPoint(x: field.midX, y: field.minY + 22)
    }

    /// How many fit on one page, favourites included.
    static func capacity(_ p: OrbitLayoutParams, field: CGRect, core: Int) -> Int {
        switch p.style {
        case .orbits: return max(ringPlan(field, p, core: core > 0).reduce(0) { $0 + $1.capacity }, 1) + min(core, 5)
        case .galaxy: return max(galaxy(field, p, core: core > 0, limit: .max).count, 1) + min(core, 5)
        case .grid:
            let shape = gridShape(field, p, step: 1.3)
            return shape.columns * shape.rows
        case .pages:
            let shape = gridShape(field, p, step: 1.29)
            return shape.columns * shape.rows
        case .honeycomb: return max(honeycomb(field, p).count, 1)
        case .arc: return max(arc(field, p).count, 1)
        }
    }

    static func spots(count: Int, core: Int, _ p: OrbitLayoutParams, field: CGRect) -> (spots: [OrbitSpot], rings: [OrbitRing]) {
        switch p.style {
        case .orbits:
            let pinned = min(core, 5, count)
            var spots = coreRow(pinned, p, field: field)
            var rings: [OrbitRing] = [], left = count - pinned
            for (index, plan) in spread(ringPlan(field, p, core: pinned > 0), count: left, field: field, p, core: pinned > 0).enumerated() where left > 0 {
                let shown = min(plan.capacity, left)
                left -= shown
                rings.append(plan.ring)
                let rate = sign(index, p) * 0.024 * p.speed / (1 + Double(index) * 0.35)
                for item in 0..<shown {
                    spots.append(OrbitSpot(
                        center: CGPoint(x: field.midX, y: field.midY), rx: plan.ring.rx, ry: plan.ring.ry,
                        phase: 2 * .pi * Double(item) / Double(shown) - .pi / 2 + Double(index) * 0.6, rate: rate))
                }
            }
            return (spots, rings)
        case .galaxy:
            let pinned = min(core, 5, count)
            return (coreRow(pinned, p, field: field) + galaxy(field, p, core: pinned > 0, limit: count - pinned), [])
        case .grid, .pages:
            let step = p.style == .grid ? 1.3 : 1.29
            let shape = gridShape(field, p, step: step)
            let stepX = p.cell * step, stepY = p.cell * (p.style == .grid ? 1.22 : 1.17)
            let shown = min(count, shape.columns * shape.rows)
            let columns = p.style == .grid
                ? min(shape.columns, max(Int(Double(shown).squareRoot() * 1.5), 3))
                : shape.columns
            let used = min(max(shown, 1), columns)
            let rows = Int((Double(max(shown, 1)) / Double(columns)).rounded(.up))
            let left = field.midX - stepX * Double(used - 1) / 2
            let top = p.style == .grid
                ? max(field.minY + 62 + stepY / 2, field.midY + 20 - stepY * Double(rows - 1) / 2)
                : field.minY + 62 + stepY / 2
            return ((0..<shown).map { index in
                OrbitSpot(center: CGPoint(x: left + stepX * Double(index % columns), y: top + stepY * Double(index / columns)))
            }, [])
        case .honeycomb:
            return (Array(honeycomb(field, p).prefix(count)), [])
        case .arc:
            return (Array(arc(field, p).prefix(count)), [])
        }
    }

    /// Search results always take a plain grid: the eye reads it fastest.
    static func resultSpots(count: Int, _ p: OrbitLayoutParams, field: CGRect) -> [OrbitSpot] {
        var grid = p
        grid.style = .pages
        return spots(count: count, core: 0, grid, field: field).spots
    }

    static func resultCapacity(_ p: OrbitLayoutParams, field: CGRect) -> Int {
        var grid = p
        grid.style = .pages
        return capacity(grid, field: field, core: 0)
    }

    // MARK: Rings

    private static func sign(_ index: Int, _ p: OrbitLayoutParams) -> Double {
        switch p.direction {
        case .alternate: index.isMultiple(of: 2) ? 1 : -1
        case .clockwise: 1
        case .counter: -1
        }
    }

    private static func aspect(_ field: CGRect, _ p: OrbitLayoutParams) -> Double {
        let top = field.height / 2 - p.cell * 0.46
        return min(max((field.width / 2 - p.cell * 0.8) / max(top, 1), 1), 1.6)
    }

    /// Rings grow outward from the title, wider than tall, as many as the screen holds.
    static func ringPlan(_ field: CGRect, _ p: OrbitLayoutParams, core: Bool) -> [(ring: OrbitRing, capacity: Int)] {
        // With favourites in the middle the title moves to the top, so the outer ring keeps clear of it.
        let top = field.height / 2 - p.cell * 0.46 - (core ? 40 : 0)
        let aspect = aspect(field, p)
        let step = max(p.spacing, p.cell * 0.72)
        var plan: [(OrbitRing, Int)] = []
        var ry = max(p.cell * 1.42, 96) + (core ? p.cell * 0.42 : 0)
        while ry <= top && (p.rings == 0 || plan.count < p.rings) {
            let rx = ry * aspect
            let around = Double.pi * (3 * (rx + ry) - ((3 * rx + ry) * (rx + 3 * ry)).squareRoot())
            plan.append((OrbitRing(rx: rx, ry: ry), max(Int(around / (p.cell + 10)), 3)))
            ry += step
        }
        if plan.isEmpty {
            let ry = max(top, 90)
            plan = [(OrbitRing(rx: ry * aspect, ry: ry), 8)]
        }
        return plan
    }

    /// A small constellation opens up to fill the sky instead of huddling at the centre.
    private static func spread(_ plan: [(ring: OrbitRing, capacity: Int)], count: Int, field: CGRect,
                               _ p: OrbitLayoutParams, core: Bool) -> [(ring: OrbitRing, capacity: Int)] {
        var used = 0, filled = 0
        for ring in plan where filled < count {
            filled += ring.capacity
            used += 1
        }
        guard let first = plan.first?.ring else { return plan }
        let aspect = first.rx / first.ry
        let top = field.height / 2 - p.cell * 0.46 - (core ? 40 : 0)
        guard used > 1 else {
            let ry = min(first.ry + Double(count) * 9, top)
            return [(OrbitRing(rx: ry * aspect, ry: ry), plan[0].capacity)]
        }
        let step = min(max(p.spacing, p.cell * 0.72) * 1.43, (top - first.ry) / Double(used - 1))
        return plan.enumerated().map { index, entry in
            guard index < used else { return entry }
            let ry = first.ry + Double(index) * step
            return (OrbitRing(rx: ry * aspect, ry: ry), entry.capacity)
        }
    }

    /// Favourites hold the middle of the sky in a short row.
    private static func coreRow(_ count: Int, _ p: OrbitLayoutParams, field: CGRect) -> [OrbitSpot] {
        guard count > 0 else { return [] }
        let step = p.cell * 1.14
        let left = field.midX - step * Double(count - 1) / 2
        return (0..<count).map { OrbitSpot(center: CGPoint(x: left + step * Double($0), y: field.midY)) }
    }

    // MARK: Galaxy

    /// Two arms wound around the middle, turning as one.
    private static func galaxy(_ field: CGRect, _ p: OrbitLayoutParams, core: Bool, limit: Int) -> [OrbitSpot] {
        let tilt = 0.62
        let centre = CGPoint(x: field.midX, y: field.midY)
        let reach = min(field.width / 2 - p.cell * 0.6, (field.height / 2 - p.cell * 0.5) / tilt)
        // Two arms interleave, so one turn of an arm must clear two rows, measured on the squashed axis.
        let pitch = 2 * max(p.spacing, p.cell * 0.8) / tilt * 0.82
        let growth = pitch / (2 * .pi)
        let rate = (p.direction == .counter ? -1.0 : 1.0) * 0.018 * p.speed
        let start = core ? p.cell * 2.1 : p.cell * 1.55
        var arms: [(r: Double, theta: Double)] = [(start, 0), (start, .pi)]
        var spots: [OrbitSpot] = []
        var blocked = [false, false]
        while spots.count < limit && !(blocked[0] && blocked[1]) {
            for arm in 0..<2 where spots.count < limit && !blocked[arm] {
                let (r, theta) = arms[arm]
                if r > reach {
                    blocked[arm] = true
                    continue
                }
                spots.append(OrbitSpot(center: centre, rx: r, ry: r * tilt, phase: theta, rate: rate, even: false))
                // Even steps along the arm, measured on screen.
                let along = p.cell * 1.18 / max(r * (0.5 + 0.5 * tilt), 1)
                arms[arm] = (r + growth * along, theta + along)
            }
        }
        return spots
    }

    // MARK: Grids

    private static func gridShape(_ field: CGRect, _ p: OrbitLayoutParams, step: Double) -> (columns: Int, rows: Int) {
        (min(max(Int((field.width - 120) / (p.cell * step)), 3), 9), max(Int((field.height - 62) / (p.cell * 1.17)), 2))
    }

    /// Hexagons ring by ring from the middle, so the first apps sit at the centre.
    private static func honeycomb(_ field: CGRect, _ p: OrbitLayoutParams) -> [OrbitSpot] {
        let dx = p.cell * 1.16 + max(p.spacing - 92, -30) * 0.3
        let dy = dx * 0.866
        let centre = CGPoint(x: field.midX, y: field.midY + 26)
        let bounds = CGRect(x: field.minX + p.cell * 0.6, y: field.minY + 52,
                            width: field.width - p.cell * 1.2, height: field.height - 52 - p.cell * 0.2)
        let directions = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
        var spots = [OrbitSpot(center: centre)]
        for ring in 1..<40 {
            var q = -ring, r = ring
            var any = false
            for (dq, dr) in directions {
                for _ in 0..<ring {
                    let point = CGPoint(x: centre.x + dx * (Double(q) + Double(r) / 2), y: centre.y + dy * Double(r))
                    if bounds.contains(point) {
                        spots.append(OrbitSpot(center: point))
                        any = true
                    }
                    q += dq
                    r += dr
                }
            }
            if !any { break }
        }
        return spots
    }

    /// Rows of arcs like a fanned dock, the first apps in the middle of the lowest arc.
    private static func arc(_ field: CGRect, _ p: OrbitLayoutParams) -> [OrbitSpot] {
        let span = 55.0 * .pi / 180
        let base = field.maxY - p.cell * 0.5
        let r0 = min((field.width / 2 - p.cell) / sin(span), field.height * 1.4)
        let centre = CGPoint(x: field.midX, y: base + r0 * cos(span))
        let rowStep = max(p.spacing, p.cell * 0.8) * 1.12
        let ceiling = field.minY + 62 + p.cell * 0.5
        var spots: [OrbitSpot] = []
        var radius = r0
        while centre.y - radius >= ceiling {
            let wide = asin(min((field.width / 2 - p.cell * 0.6) / radius, 1))
            let low = acos(min(r0 * cos(span) / radius, 1))
            let half = min(wide, low)
            let fit = max(Int(2 * half * radius / (p.cell * 1.0)), 0)
            let count = fit.isMultiple(of: 2) ? fit + 1 : fit
            let gap = count > 1 ? 2 * half / Double(count - 1) : 0
            // Centre first, then outward to either side.
            for k in 0..<count {
                let side = k == 0 ? 0 : (k.isMultiple(of: 2) ? -1.0 : 1.0) * Double((k + 1) / 2)
                let angle = side * gap
                spots.append(OrbitSpot(center: CGPoint(x: centre.x + radius * sin(angle), y: centre.y - radius * cos(angle))))
            }
            radius += rowStep
        }
        return spots
    }

    // MARK: Folder

    /// The expanded folder sits at the middle of the world.
    static func folderFrame(count: Int, size: CGSize, cell: Double) -> CGRect {
        let step = cell + 12
        let columns = min(max(count, 3), 5)
        let rows = Int((Double(max(count, 1)) / Double(columns)).rounded(.up))
        let width = Double(columns) * step + 44
        let height = Double(rows) * step + 118
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    static func folderPoint(index: Int, count: Int, size: CGSize, cell: Double) -> CGPoint {
        let step = cell + 12
        let frame = folderFrame(count: count, size: size, cell: cell)
        let columns = min(max(count, 3), 5)
        return CGPoint(x: frame.minX + 22 + step / 2 + Double(index % columns) * step,
                       y: frame.minY + 86 + step / 2 + Double(index / columns) * step)
    }
}
