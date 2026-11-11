import AppKit
import QuartzCore

// The field at display rate. One display link from the panel's screen moves bitmap layers:
// no view tree is rebuilt per frame, nothing is drawn per frame, nothing is blurred per frame.

struct OrbitSpring: Sendable {
    var value: Double
    var velocity = 0.0
    var target: Double

    init(_ value: Double) {
        self.value = value
        target = value
    }

    var resting: Bool { value == target && velocity == 0 }

    @inline(__always) mutating func step(_ dt: Double, response: Double, damping: Double) {
        guard !resting else { return }
        let omega = 2 * Double.pi / response
        let force = -omega * omega * (value - target) - 2 * damping * omega * velocity
        velocity += force * dt
        value += velocity * dt
        if abs(value - target) < 0.0004 && abs(velocity) < 0.004 {
            value = target
            velocity = 0
        }
    }

    mutating func snap(_ to: Double) {
        value = to
        target = to
        velocity = 0
    }

    /// Where a spring released at rest from 0 towards 1 is after `t` seconds.
    @inline(__always) static func curve(_ t: Double, response: Double, damping: Double) -> Double {
        guard t > 0 else { return 0 }
        let omega = 2 * Double.pi / response
        if damping >= 1 { return 1 - exp(-omega * t) * (1 + omega * t) }
        let damped = omega * (1 - damping * damping).squareRoot()
        return 1 - exp(-damping * omega * t) * (cos(damped * t) + damping * omega / damped * sin(damped * t))
    }
}

struct OrbitEngineStyle: Equatable {
    var icon = 62.0
    var labels = OrbitLabelMode.always
    var hoverScale = 1.09
    var openStyle = OrbitOpenStyle.spiral
    var showRings = true
    var showRunning = true
    var stars = true
    var drift = true
    var depth = true
    var reduceMotion = false
    var accent = CGColor(srgbRed: 0.55, green: 0.72, blue: 1, alpha: 1)

    var cell: Double { icon + 34 }

    init() {}

    init(_ options: OrbitOptions, accent: CGColor, reduceMotion: Bool) {
        icon = options.iconSize
        labels = options.labels
        hoverScale = options.hoverScale
        openStyle = options.openStyle
        showRings = options.showRings
        showRunning = options.showRunning
        stars = options.stars
        drift = options.drift && options.layout.drifts
        depth = options.layout.drifts
        self.reduceMotion = reduceMotion
        self.accent = accent
    }
}

/// One entry on the field: a container holding shadow, icon, label and running dot.
@MainActor
final class OrbitItemLayer {
    let root = CALayer()
    let shadow = CALayer()
    let icon = CALayer()
    let label = CALayer()
    let dot = CALayer()
    var key = ""
    var entryID = ""
    var spot = OrbitSpot(center: .zero)
    var hasIcon = false
    var entry: OrbitEntry?

    var scale = OrbitSpring(1)
    var focus = OrbitSpring(0)
    var appear = OrbitSpring(1)
    var blend = OrbitSpring(1)
    var from: CGPoint?
    var delay = 0.0
    /// What the last frame showed, in page coordinates.
    var shown = CGPoint.zero
    var shownScale = 1.0
    var shownAlpha = 1.0

    private var lastPosition = CGPoint(x: -1, y: -1)
    private var lastScale = -1.0
    private var lastAlpha = -1.0
    private var lastLabel = -1.0
    private var lastZ = -1.0

    init(scale: Double) {
        for layer in [root, shadow, icon, label, dot] { layer.contentsScale = scale }
        root.addSublayer(shadow)
        root.addSublayer(icon)
        root.addSublayer(dot)
        root.addSublayer(label)
        icon.minificationFilter = .trilinear
        icon.magnificationFilter = .linear
        shadow.opacity = 0.32
        dot.backgroundColor = CGColor(gray: 1, alpha: 0.85)
        dot.isHidden = true
    }

    func layout(icon size: Double) {
        let cell = size + 34
        let top = (cell - (size + 22)) / 2
        root.bounds = CGRect(x: 0, y: 0, width: cell, height: cell)
        icon.frame = CGRect(x: (cell - size) / 2, y: top, width: size, height: size)
        let shadowSide = size * 96 / 60
        shadow.frame = CGRect(x: (cell - shadowSide) / 2, y: top + size / 2 - shadowSide / 2 + 3,
                              width: shadowSide, height: shadowSide)
        dot.frame = CGRect(x: cell / 2 - 2, y: top + size + 2, width: 4, height: 4)
        dot.cornerRadius = 2
        placeLabel(cell: cell, top: top, size: size)
        lastScale = -1
    }

    var labelImage: CGImage? {
        didSet { label.contents = labelImage }
    }

    func placeLabel(cell: Double, top: Double, size: Double) {
        guard let picture = labelImage else { return }
        let width = Double(picture.width) / label.contentsScale, height = Double(picture.height) / label.contentsScale
        label.frame = CGRect(x: (cell - width) / 2, y: top + size + 8 + 7 - height / 2, width: width, height: height)
    }

    @inline(__always) func apply(position: CGPoint, scale: Double, alpha: Double, label labelAlpha: Double, z: Double) {
        if abs(position.x - lastPosition.x) > 0.01 || abs(position.y - lastPosition.y) > 0.01 {
            root.position = position
            lastPosition = position
        }
        if abs(scale - lastScale) > 0.0005 {
            root.transform = CATransform3DMakeScale(scale, scale, 1)
            lastScale = scale
        }
        if abs(alpha - lastAlpha) > 0.002 {
            root.opacity = Float(alpha)
            lastAlpha = alpha
        }
        if abs(labelAlpha - lastLabel) > 0.002 {
            label.opacity = Float(labelAlpha)
            lastLabel = labelAlpha
        }
        if z != lastZ {
            root.zPosition = z
            lastZ = z
        }
    }
}

/// One page: its rings, its title and its entries, slid as one.
@MainActor
final class OrbitPageLayer {
    let id: String
    let root = CALayer()
    let glow = CAGradientLayer()
    let title = CALayer()
    var rings: [CALayer] = []
    var items: [OrbitItemLayer] = []
    var titlePoint = CGPoint.zero
    private var lastOffset = Double.nan
    private var lastFade = -1.0

    init(id: String, scale: Double) {
        self.id = id
        root.anchorPoint = .zero
        glow.type = .radial
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        for layer in [root, glow, title] { layer.contentsScale = scale }
        root.addSublayer(glow)
        root.addSublayer(title)
    }

    func apply(offset: Double, fade: Double) {
        if offset != lastOffset {
            root.position = CGPoint(x: offset, y: 0)
            lastOffset = offset
        }
        if abs(fade - lastFade) > 0.002 {
            let scale = 0.7 + 0.3 * fade
            for ring in rings {
                ring.opacity = Float(fade)
                ring.transform = CATransform3DMakeScale(scale, scale, 1)
            }
            title.opacity = Float(fade)
            glow.opacity = Float(fade)
            lastFade = fade
        }
    }
}

@MainActor
final class OrbitEngine: NSObject {
    let root = CALayer()
    let ghostRoot = CALayer()
    private let stars = CALayer()
    private let halo = CALayer()
    private let drop = CALayer()
    private let ghost = CALayer()
    private let leavingLayer = CALayer()

    private(set) var pages: [OrbitPageLayer] = []
    private var leaving: [(layer: OrbitItemLayer, start: Double, from: CGPoint)] = []
    private(set) var size = CGSize(width: 1440, height: 900)
    private(set) var style = OrbitEngineStyle()
    private var contentsScale = 2.0
    private var field = CGRect.zero

    // Navigation
    private var pageSpring = OrbitSpring(0)
    private(set) var current = 0
    var swipe = 0.0 { didSet { if swipe != oldValue { wake() } } }

    // Pointer and keyboard
    private(set) var hovered: String?
    private(set) var pressed: String?
    private(set) var dropTarget: String?
    private(set) var launching: String?
    private(set) var lifted: String?
    private(set) var selection: String?
    private(set) var hiddenEntry: String?
    /// Set by Orbit for anything that should hold the drift: search, menus, folders, keys.
    var hold = false { didSet { if hold != oldValue { wake() } } }

    // Entrance
    private var openedAt: Double?
    private var closingAt: Double?
    private var pointer = CGPoint.zero
    private(set) var isOpen = false
    private(set) var driftTime = Double.random(in: 0...120)
    private var last = CACurrentMediaTime()

    // Halo and ghost
    private var haloX = OrbitSpring(0), haloY = OrbitSpring(0), haloAlpha = OrbitSpring(0)
    private var ghostX = OrbitSpring(0), ghostY = OrbitSpring(0), ghostScale = OrbitSpring(1), ghostAlpha = OrbitSpring(0)
    private var ghostReturning = false

    // Art
    var artFor: (OrbitEntry) -> CGImage? = { _ in nil }
    var labelFor: (String) -> CGImage? = { _ in nil }
    private var running = Set<String>()

    // Display link and measurements
    private var link: CADisplayLink?
    private var animating = false
    private var openCall: CFTimeInterval?
    private(set) var openLatencies: [Double] = []
    private var stepTimes: [Double] = []
    private var intervals: [Double] = []
    private var lastTimestamp: CFTimeInterval = 0

    override init() {
        super.init()
        root.isGeometryFlipped = true
        root.anchorPoint = .zero
        ghostRoot.isGeometryFlipped = true
        ghostRoot.anchorPoint = .zero
        for layer in [stars, halo, drop, ghost, leavingLayer] { root.addSublayer(layer) }
        ghost.removeFromSuperlayer()
        ghostRoot.addSublayer(ghost)
        stars.anchorPoint = .zero
        leavingLayer.anchorPoint = .zero
        halo.cornerRadius = 22
        halo.cornerCurve = .continuous
        halo.backgroundColor = CGColor(gray: 1, alpha: 0.14)
        halo.borderWidth = 1.5
        halo.shadowRadius = 16
        halo.shadowOpacity = 1
        halo.shadowOffset = .zero
        halo.opacity = 0
        halo.zPosition = -1
        drop.borderWidth = 2
        drop.cornerCurve = .continuous
        drop.opacity = 0
        drop.zPosition = 3
        drop.shadowRadius = 12
        drop.shadowOpacity = 0.7
        drop.shadowOffset = .zero
        ghost.opacity = 0
        ghost.shadowColor = CGColor(gray: 0, alpha: 1)
        ghost.shadowOpacity = 0.5
        ghost.shadowRadius = 18
        ghost.shadowOffset = CGSize(width: 0, height: 12)
        leavingLayer.zPosition = 4
    }

    // MARK: Setup

    /// Follows the screen the view is on, and asks for its full rate: 120 Hz on ProMotion.
    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.isPaused = !animating
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func detach() {
        link?.invalidate()
        link = nil
    }

    func configure(size: CGSize, scale: Double, field: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        self.field = field
        let changed = size != self.size || scale != contentsScale || stars.sublayers == nil
        self.size = size
        contentsScale = scale
        root.bounds = CGRect(origin: .zero, size: size)
        ghostRoot.bounds = root.bounds
        leavingLayer.bounds = root.bounds
        for layer in [root, ghostRoot, stars, halo, drop, ghost, leavingLayer] { layer.contentsScale = scale }
        if changed { makeStars() }
    }

    func restyle(_ style: OrbitEngineStyle) {
        let old = self.style
        self.style = style
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.borderColor = style.accent.copy(alpha: 0.9)
        halo.shadowColor = style.accent.copy(alpha: 0.5)
        drop.borderColor = style.accent
        drop.shadowColor = style.accent
        halo.bounds = CGRect(x: 0, y: 0, width: style.cell + 6, height: style.cell + 6)
        drop.bounds = CGRect(x: 0, y: 0, width: style.icon + 10, height: style.icon + 10)
        drop.cornerRadius = (style.icon + 10) * 0.27
        ghost.bounds = CGRect(x: 0, y: 0, width: style.icon, height: style.icon)
        stars.isHidden = !style.stars
        if old.icon != style.icon || old.showRunning != style.showRunning {
            for page in pages {
                for item in page.items {
                    item.layout(icon: style.icon)
                    item.dot.isHidden = !(style.showRunning && running.contains(item.entry?.path ?? ""))
                }
            }
        }
        for page in pages { for ring in page.rings { ring.isHidden = !style.showRings } }
        CATransaction.commit()
        wake()
    }

    private func makeStars() {
        stars.sublayers?.forEach { $0.removeFromSuperlayer() }
        stars.bounds = CGRect(x: 0, y: 0, width: size.width + 400, height: size.height)
        stars.position = CGPoint(x: -200, y: 0)
        var generator = OrbitSeed(state: 0x5EED)
        let paths = (0..<4).map { _ in CGMutablePath() }
        let count = Int(130 * max(size.width * size.height / (1440 * 900), 0.6))
        for _ in 0..<count {
            let x = generator.next() * (size.width + 400)
            let y = generator.next() * size.height
            let side = 0.7 + generator.next() * 1.5
            let bucket = min(Int(generator.next() * 4), 3)
            paths[bucket].addEllipse(in: CGRect(x: x, y: y, width: side, height: side))
        }
        for (index, path) in paths.enumerated() {
            let shape = CAShapeLayer()
            shape.path = path
            shape.fillColor = CGColor(gray: 1, alpha: 0.12 + 0.09 * Double(index))
            shape.frame = stars.bounds
            shape.contentsScale = contentsScale
            stars.addSublayer(shape)
        }
    }

    // MARK: Pages

    /// Shows a new plan. Entries that were on screen travel to their new places.
    func present(_ plan: [OrbitPage], current index: Int, animated: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let width = size.width
        var visible: [String: (OrbitItemLayer, CGPoint)] = [:]
        if animated, pages.indices.contains(current) {
            let page = pages[current]
            let offset = (Double(current) - pageSpring.value) * width + swipe
            for item in page.items where item.shownAlpha > 0.05 {
                visible[item.entryID] = (item, CGPoint(x: item.shown.x + offset, y: item.shown.y))
            }
        }
        var pool: [String: [OrbitItemLayer]] = [:]
        for page in pages {
            for item in page.items where visible[item.entryID]?.0 !== item { pool[item.entryID, default: []].append(item) }
        }
        var oldPages = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let target = min(max(index, 0), max(plan.count - 1, 0))
        let settled = openedAt == nil && isOpen
        var built: [OrbitPageLayer] = []
        for (pageIndex, page) in plan.enumerated() {
            let layer = oldPages.removeValue(forKey: page.id) ?? OrbitPageLayer(id: page.id, scale: contentsScale)
            layer.root.bounds = CGRect(origin: .zero, size: size)
            if layer.root.superlayer == nil { root.insertSublayer(layer.root, above: stars) }
            layer.titlePoint = page.titlePoint
            dress(layer, page)
            var items: [OrbitItemLayer] = []
            for slot in page.slots {
                let item: OrbitItemLayer
                if pageIndex == target, let match = visible.removeValue(forKey: slot.entry.id) {
                    item = match.0
                    item.from = CGPoint(x: match.1.x - (Double(pageIndex) - Double(target)) * width - swipe, y: match.1.y)
                    item.blend.value = 0
                    item.blend.velocity = 0
                    item.blend.target = 1
                } else if let reused = pool[slot.entry.id]?.popLast() {
                    item = reused
                    item.from = nil
                    item.blend.snap(1)
                    if pageIndex == target && animated && settled { item.appear.value = 0; item.appear.target = 1 }
                } else {
                    item = OrbitItemLayer(scale: contentsScale)
                    item.layout(icon: style.icon)
                    if pageIndex == target && animated && settled { item.appear.snap(0); item.appear.target = 1 }
                }
                if item.root.superlayer !== layer.root { layer.root.addSublayer(item.root) }
                fill(item, slot)
                items.append(item)
            }
            layer.items = items
            built.append(layer)
        }
        // What was on screen and has no place now fades where it stood.
        let now = CACurrentMediaTime()
        for (item, point) in visible.values {
            leavingLayer.addSublayer(item.root)
            leaving.append((item, now, point))
        }
        for items in pool.values { for item in items { item.root.removeFromSuperlayer() } }
        for page in oldPages.values { page.root.removeFromSuperlayer() }
        pages = built
        current = target
        pageSpring.snap(Double(target))
        if !animated { swipe = 0 }
        wake()
    }

    private func dress(_ layer: OrbitPageLayer, _ page: OrbitPage) {
        layer.rings.forEach { $0.removeFromSuperlayer() }
        let centre = CGPoint(x: field.midX, y: field.midY)
        layer.rings = page.rings.map { ring in
            let gradient = CAGradientLayer()
            gradient.colors = [CGColor(gray: 1, alpha: 0.04), CGColor(gray: 1, alpha: 0.13)]
            gradient.frame = CGRect(x: centre.x - ring.rx - 1, y: centre.y - ring.ry - 1, width: ring.rx * 2 + 2, height: ring.ry * 2 + 2)
            let mask = CAShapeLayer()
            mask.path = CGPath(ellipseIn: CGRect(x: 1, y: 1, width: ring.rx * 2, height: ring.ry * 2), transform: nil)
            mask.fillColor = nil
            mask.strokeColor = CGColor(gray: 0, alpha: 1)
            mask.lineWidth = 0.75
            mask.frame = gradient.bounds
            gradient.mask = mask
            gradient.isHidden = !style.showRings
            gradient.contentsScale = contentsScale
            mask.contentsScale = contentsScale
            gradient.zPosition = -2
            layer.root.addSublayer(gradient)
            return gradient
        }
        let large = page.titlePoint.y > field.minY + 40
        let count = page.id == "results" && page.slots.isEmpty ? "No matches" : (page.count == 1 ? "1 item" : "\(page.count) items")
        let image = titleArt(page, large, count)
        layer.title.contents = image
        if let image {
            let width = Double(image.width) / contentsScale, height = Double(image.height) / contentsScale
            // The count sits on the anchor point the old layout used.
            layer.title.bounds = CGRect(x: 0, y: 0, width: width, height: height)
            layer.title.position = CGPoint(x: page.titlePoint.x, y: page.titlePoint.y - (large ? 15 : 4))
        }
        layer.title.zPosition = -1
        layer.glow.isHidden = !large
        let hue = page.group.rgb
        layer.glow.colors = [CGColor(srgbRed: hue.r, green: hue.g, blue: hue.b, alpha: 0.28), CGColor(srgbRed: hue.r, green: hue.g, blue: hue.b, alpha: 0)]
        layer.glow.bounds = CGRect(x: 0, y: 0, width: 248, height: 248)
        layer.glow.position = page.titlePoint
        layer.glow.zPosition = -3
    }

    var titleArt: (OrbitPage, Bool, String) -> CGImage? = { _, _, _ in nil }

    private func fill(_ item: OrbitItemLayer, _ slot: OrbitSlot) {
        item.key = slot.key
        item.entryID = slot.entry.id
        item.spot = slot.spot
        if item.entry != slot.entry || !item.hasIcon {
            let image = artFor(slot.entry)
            item.icon.contents = image
            item.hasIcon = image != nil
            item.labelImage = labelFor(slot.entry.name)
            item.placeLabel(cell: style.cell, top: (style.cell - (style.icon + 22)) / 2, size: style.icon)
            item.entry = slot.entry
        }
        item.shadow.contents = OrbitArt.shadow
        item.dot.isHidden = !(style.showRunning && running.contains(slot.entry.path))
    }

    /// Icons that arrived late, or labels in a new style.
    func refreshArt(labels: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for page in pages {
            for item in page.items {
                guard let entry = item.entry else { continue }
                if !item.hasIcon || entry.isFolder {
                    let image = artFor(entry)
                    item.icon.contents = image
                    item.hasIcon = image != nil
                }
                if labels {
                    item.labelImage = labelFor(entry.name)
                    item.placeLabel(cell: style.cell, top: (style.cell - (style.icon + 22)) / 2, size: style.icon)
                }
            }
        }
        CATransaction.commit()
    }

    func setRunning(_ paths: Set<String>) {
        guard paths != running else { return }
        running = paths
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for page in pages { for item in page.items {
            item.dot.isHidden = !(style.showRunning && running.contains(item.entry?.path ?? ""))
        } }
        CATransaction.commit()
    }

    /// Turns to a page, or with an index out of range springs back to the current one.
    func go(to index: Int) {
        // The swipe so far becomes part of the travel, so the page never jumps.
        pageSpring.value -= swipe / max(size.width, 1)
        swipe = 0
        if pages.indices.contains(index) {
            current = index
            pageSpring.target = Double(index)
        }
        if style.reduceMotion { pageSpring.snap(pageSpring.target) }
        wake()
    }

    var pageValue: Double { pageSpring.value }

    // MARK: Open and close

    func open(pointer: CGPoint, requested: CFTimeInterval) {
        self.pointer = pointer
        openCall = requested
        let now = CACurrentMediaTime()
        openedAt = now
        closingAt = nil
        isOpen = true
        launching = nil
        hiddenEntry = nil
        hovered = nil
        pressed = nil
        lifted = nil
        dropTarget = nil
        selection = nil
        haloAlpha.snap(0)
        ghostAlpha.snap(0)
        last = now
        let centre = CGPoint(x: field.midX, y: field.midY)
        for page in pages {
            for item in page.items {
                let rest = item.spot.point(driftTime)
                item.scale.snap(1)
                item.focus.snap(0)
                item.appear.snap(1)
                item.blend.snap(1)
                item.from = nil
                switch style.openStyle {
                case .spiral: item.delay = min(hypot(rest.x - pointer.x, rest.y - pointer.y) / 2600, 0.24)
                case .bloom: item.delay = min(hypot(rest.x - centre.x, rest.y - centre.y) / 1800, 0.3)
                case .fade: item.delay = min(hypot(rest.x - pointer.x, rest.y - pointer.y) / 4000, 0.12)
                case .zoom: item.delay = 0
                }
                if style.reduceMotion { item.delay = 0 }
            }
        }
        for entry in leaving { entry.layer.root.removeFromSuperlayer() }
        leaving.removeAll()
        step(now: now)
        wake()
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        openedAt = nil
        closingAt = CACurrentMediaTime()
        hovered = nil
        pressed = nil
        wake()
    }

    // MARK: Pointer state

    func set(hovered key: String?) { if hovered != key { hovered = key; wake() } }
    func set(pressed key: String?) { if pressed != key { pressed = key; wake() } }
    func set(dropTarget key: String?) { if dropTarget != key { dropTarget = key; wake() } }
    func set(launching key: String?) { if launching != key { launching = key; wake() } }
    func set(lifted key: String?) { if lifted != key { lifted = key; wake() } }
    func set(hiddenEntry id: String?) { if hiddenEntry != id { hiddenEntry = id; wake() } }

    func set(selection key: String?) {
        guard selection != key else { return }
        let had = selection != nil
        selection = key
        if let key, let point = globalPoint(key), !had {
            haloX.snap(point.x)
            haloY.snap(point.y)
        }
        wake()
    }

    var currentPage: OrbitPageLayer? { pages.indices.contains(current) ? pages[current] : nil }

    private func offset(of index: Int) -> Double { (Double(index) - pageSpring.value) * size.width + swipe }

    /// Where an entry of the current page stands now, in world coordinates.
    func globalPoint(_ key: String) -> CGPoint? {
        guard let page = currentPage, let item = page.items.first(where: { $0.key == key }) else { return nil }
        if !isOpen && openedAt == nil && item.shown == .zero {
            return item.spot.point(driftTime)
        }
        return CGPoint(x: item.shown.x + offset(of: current), y: item.shown.y)
    }

    /// The entry under a point of the current page, nearest first.
    func hit(_ point: CGPoint) -> String? {
        guard let page = currentPage else { return nil }
        let dx0 = offset(of: current)
        var best: (String, Double)?
        for item in page.items where item.shownAlpha > 0.2 && item.key != lifted {
            let reach = style.cell / 2 * item.shownScale
            let dx = point.x - (item.shown.x + dx0), dy = point.y - item.shown.y
            guard abs(dx) < reach, abs(dy) < reach else { continue }
            let distance = dx * dx + dy * dy
            if best == nil || distance < best!.1 { best = (item.key, distance) }
        }
        return best?.0
    }

    /// Nearest entry to a point, within a reach, skipping one key.
    func nearest(to point: CGPoint, within reach: Double, skipping key: String) -> String? {
        guard let page = currentPage else { return nil }
        let dx0 = offset(of: current)
        var best: (String, Double)?
        for item in page.items where item.key != key {
            let distance = hypot(point.x - (item.shown.x + dx0), point.y - item.shown.y)
            if distance < reach && (best == nil || distance < best!.1) { best = (item.key, distance) }
        }
        return best?.0
    }

    // MARK: Ghost

    func beginGhost(_ image: CGImage?, at point: CGPoint) {
        ghost.contents = image
        ghostX.snap(point.x)
        ghostY.snap(point.y)
        ghostScale.value = 1
        ghostScale.target = 1.12
        ghostAlpha.snap(1)
        ghostReturning = false
        wake()
    }

    func moveGhost(to point: CGPoint) {
        ghostX.target = point.x
        ghostY.target = point.y
        ghostReturning = false
        ghostScale.target = 1.12
        wake()
    }

    func returnGhost(to point: CGPoint) {
        ghostX.target = point.x
        ghostY.target = point.y
        ghostScale.target = 1
        ghostReturning = true
        wake()
    }

    func endGhost() {
        ghostAlpha.snap(0)
        ghostReturning = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ghost.opacity = 0
        CATransaction.commit()
    }

    // MARK: Frames

    func wake() {
        animating = true
        guard let link, link.isPaused else { return }
        last = CACurrentMediaTime()
        lastTimestamp = 0
        link.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp > 0 {
            intervals.append((link.timestamp - lastTimestamp) * 1000)
            if intervals.count > 2400 { intervals.removeFirst(1200) }
        }
        lastTimestamp = link.timestamp
        if let openCall {
            openLatencies.append((link.targetTimestamp - openCall) * 1000)
            if openLatencies.count > 20 { openLatencies.removeFirst() }
            self.openCall = nil
        }
        let started = CACurrentMediaTime()
        step(now: link.targetTimestamp)
        stepTimes.append((CACurrentMediaTime() - started) * 1000)
        if stepTimes.count > 2400 { stepTimes.removeFirst(1200) }
        if !animating {
            link.isPaused = true
            lastTimestamp = 0
        }
    }

    var drifting: Bool {
        style.drift && !style.reduceMotion && !hold && isOpen && hovered == nil && pressed == nil
            && lifted == nil && swipe == 0 && pageSpring.resting
    }

    /// One frame. Public so it can be measured without a display.
    func step(now: Double) {
        let dt = min(max(now - last, 0), 1.0 / 30)
        last = now
        var busy = false
        if drifting {
            driftTime += dt
            busy = true
        }
        if style.reduceMotion { pageSpring.snap(pageSpring.target) }
        pageSpring.step(dt, response: 0.55, damping: 0.92)
        if !pageSpring.resting { busy = true }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let width = size.width
        let centre = CGPoint(x: field.midX, y: field.midY)
        let parallax = -(pageSpring.value * 26) + swipe * 0.05
        stars.position = CGPoint(x: -200 + parallax, y: 0)

        // Rings and titles arrive together; entries follow on their own delays.
        var fade = 1.0
        var closing: Double?
        if let openedAt {
            let t = now - openedAt
            fade = style.reduceMotion ? min(t / 0.18, 1) : OrbitSpring.curve(t, response: 0.55, damping: 0.92)
            busy = true
            if t > 1.6 { self.openedAt = nil }
        } else if let closingAt {
            let t = min((now - closingAt) / 0.26, 1)
            let q = 1 - t * t * (3 - 2 * t)
            closing = q
            fade = q
            busy = true
            if t >= 1 { self.closingAt = nil }
        } else if !isOpen {
            fade = 0
        }

        let opening = openedAt
        for (index, page) in pages.enumerated() {
            let offset = (Double(index) - pageSpring.value) * width + swipe
            let near = abs(offset) < width - 0.5 && (!style.reduceMotion || index == current)
            if page.root.isHidden == near { page.root.isHidden = !near }
            guard near else { continue }
            page.apply(offset: offset, fade: fade)
            for item in page.items {
                if frame(item, now: now, dt: dt, opening: opening, closing: closing, centre: centre) { busy = true }
            }
        }

        // Entries without a place now.
        if !leaving.isEmpty {
            busy = true
            leaving.removeAll { entry in
                let t = (now - entry.start) / 0.2
                if t >= 1 {
                    entry.layer.root.removeFromSuperlayer()
                    return true
                }
                entry.layer.apply(position: entry.from, scale: entry.layer.shownScale * (1 - 0.3 * t),
                                  alpha: entry.layer.shownAlpha * (1 - t), label: 1 - t, z: 0)
                return false
            }
        }

        // Halo on the selection.
        if let selection, let point = globalPoint(selection), closing == nil {
            haloX.target = point.x
            haloY.target = point.y
            haloAlpha.target = 1
        } else {
            haloAlpha.target = 0
        }
        haloX.step(dt, response: 0.22, damping: 0.86)
        haloY.step(dt, response: 0.22, damping: 0.86)
        haloAlpha.step(dt, response: 0.2, damping: 1)
        if !(haloX.resting && haloY.resting && haloAlpha.resting) { busy = true }
        halo.position = CGPoint(x: haloX.value, y: haloY.value)
        halo.opacity = Float(max(haloAlpha.value, 0) * fade)

        // Ring on a drop target.
        if let dropTarget, let point = globalPoint(dropTarget) {
            let top = (style.cell - (style.icon + 22)) / 2
            drop.position = CGPoint(x: point.x, y: point.y - style.cell / 2 + top + style.icon / 2)
            drop.opacity = 1
        } else if drop.opacity != 0 {
            drop.opacity = 0
        }

        // The dragged entry under the pointer.
        if ghostAlpha.value > 0 {
            let response = ghostReturning ? 0.3 : 0.1
            ghostX.step(dt, response: response, damping: 1)
            ghostY.step(dt, response: response, damping: 1)
            ghostScale.step(dt, response: 0.22, damping: 0.8)
            if !(ghostX.resting && ghostY.resting && ghostScale.resting) { busy = true }
            ghost.position = CGPoint(x: ghostX.value, y: ghostY.value)
            ghost.transform = CATransform3DMakeScale(ghostScale.value, ghostScale.value, 1)
            ghost.opacity = 1
        }

        CATransaction.commit()
        animating = busy
    }

    /// One entry's frame. Returns whether it is still moving.
    @inline(__always)
    private func frame(_ item: OrbitItemLayer, now: Double, dt: Double, opening: Double?, closing: Double?,
                       centre: CGPoint) -> Bool {
        var busy = false
        let (rest, depth) = item.spot.place(driftTime)
        var point = rest
        if let from = item.from {
            item.blend.step(dt, response: 0.45, damping: 1)
            let e = item.blend.value
            point = CGPoint(x: from.x + (rest.x - from.x) * e, y: from.y + (rest.y - from.y) * e)
            if item.blend.resting { item.from = nil } else { busy = true }
        }

        let key = item.key
        let isLaunching = key == launching
        let target: Double = isLaunching ? 1.5 : key == pressed ? 0.93 : key == dropTarget ? 1.18
            : key == hovered ? style.hoverScale : 1
        item.scale.target = target
        item.scale.step(dt, response: isLaunching ? 0.42 : 0.22, damping: isLaunching ? 1 : 0.8)
        item.focus.target = key == hovered || key == selection ? 1 : 0
        item.focus.step(dt, response: 0.22, damping: 1)
        item.appear.step(dt, response: 0.42, damping: 0.9)
        if !(item.scale.resting && item.focus.resting && item.appear.resting) { busy = true }

        var alpha = 1.0, scale = 1.0
        var progress: Double?
        if let opening {
            let t = now - opening - item.delay
            progress = style.reduceMotion ? min(max(t / 0.18, 0), 1)
                : style.openStyle == .fade ? OrbitSpring.curve(t, response: 0.5, damping: 1)
                : OrbitSpring.curve(t, response: 0.66, damping: 0.8)
        } else if let closing, !isLaunching {
            progress = closing
        } else if !isOpen && !isLaunching {
            progress = 0
        }
        if let p = progress {
            if style.reduceMotion {
                alpha = p
            } else {
                switch style.openStyle {
                case .spiral:
                    let vx = rest.x - pointer.x, vy = rest.y - pointer.y
                    let spin = (1 - p) * 1.1, c = cos(spin), s = sin(spin)
                    point = CGPoint(x: pointer.x + (vx * c - vy * s) * p - (rest.x - point.x),
                                    y: pointer.y + (vx * s + vy * c) * p - (rest.y - point.y))
                    scale = 0.2 + 0.8 * min(max(p, 0), 1.1)
                    alpha = min(max(p * 1.4, 0), 1)
                case .bloom:
                    point = CGPoint(x: centre.x + (point.x - centre.x) * p, y: centre.y + (point.y - centre.y) * p)
                    scale = max(p, 0)
                    alpha = min(max(p * 1.6, 0), 1)
                case .fade:
                    scale = 0.97 + 0.03 * min(max(p, 0), 1)
                    alpha = min(max(p, 0), 1)
                case .zoom:
                    let z = 1.25 - 0.25 * p
                    point = CGPoint(x: centre.x + (point.x - centre.x) * z, y: centre.y + (point.y - centre.y) * z)
                    scale = z
                    alpha = min(max(p, 0), 1)
                }
            }
        }

        let depthScale = style.depth ? 0.9 + 0.13 * depth : 1
        let appear = item.appear.value
        let shownScale = item.scale.value * depthScale * scale * (0.55 + 0.45 * appear)
        var shownAlpha = (style.depth ? 0.8 + 0.2 * depth : 1) * alpha * min(max(appear, 0), 1)
        if key == lifted || item.entryID == hiddenEntry { shownAlpha = 0 }
        if isLaunching { shownAlpha *= max(0, 1 - (item.scale.value - 1) / 0.5) }
        let labelAlpha: Double
        switch style.labels {
        case .always: labelAlpha = 0.84 + 0.16 * item.focus.value
        case .hover: labelAlpha = item.focus.value
        case .never: labelAlpha = 0
        }
        item.shown = point
        item.shownScale = shownScale
        item.shownAlpha = shownAlpha
        item.apply(position: point, scale: shownScale, alpha: shownAlpha, label: labelAlpha,
                   z: key == hovered ? 2 : (key == launching ? 3 : depth))
        return busy
    }

    // MARK: Measurements

    func diagnostics() -> [String] {
        func summary(_ values: [Double], _ name: String) -> String {
            guard !values.isEmpty else { return "\(name): none" }
            let sorted = values.sorted()
            let q = { (p: Double) in sorted[min(Int(Double(sorted.count) * p), sorted.count - 1)] }
            return String(format: "%@: n=%d median=%.2fms p95=%.2fms max=%.2fms", name, sorted.count, q(0.5), q(0.95), sorted.last ?? 0)
        }
        let late = intervals.filter { $0 > 12.5 }.count
        return [summary(stepTimes, "orbitStep"), summary(intervals, "orbitFrameInterval") + " late(>12.5ms)=\(late)",
                summary(openLatencies, "orbitOpenToFirstFrame")]
    }
}

struct OrbitSeed {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double((state >> 40) & 0xFFFFF) / 0xFFFFF
    }
}

/// The view the field's layers live in. Mouse events pass through to SwiftUI above it.
final class OrbitLayerView: NSView {
    let engine: OrbitEngine
    let ghostOnly: Bool

    init(engine: OrbitEngine, ghostOnly: Bool) {
        self.engine = engine
        self.ghostOnly = ghostOnly
        super.init(frame: .zero)
        let host = CALayer()
        host.addSublayer(ghostOnly ? engine.ghostRoot : engine.root)
        layer = host
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (ghostOnly ? engine.ghostRoot : engine.root).position = .zero
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !ghostOnly else { return }
        if window != nil { engine.attach(to: self) } else { engine.detach() }
    }
}
