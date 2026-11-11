import AppKit
import DockCore
import QuartzCore

/// Counts frames the Studio window actually got, to measure smoothness honestly.
/// Read through atelier://diag. Late and missed frames are judged against the display the window
/// is on: most Macs refresh at 60 Hz, only ProMotion MacBook Pros reach 120.
@MainActor
final class FrameMeter: NSObject {
    static let shared = FrameMeter()
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private weak var view: NSView?
    /// The budget of the display the window is on now; it moves with the window.
    private var budget: ShellFrameBudget {
        ShellFrameBudget(maximumFramesPerSecond: view?.window?.screen?.maximumFramesPerSecond ?? NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    func attach(_ view: NSView) {
        guard link == nil else { return }
        self.view = view
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = Self.displayRate(for: view)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Each hitch with what was going on, for atelier://diag.
    private(set) var hitches: [String] = []
    private var start = CACurrentMediaTime()

    @objc private func tick(_ link: CADisplayLink) {
        if last > 0 {
            let ms = (link.timestamp - last) * 1000
            if ms > budget.hitchMs, hitches.count < 80 {
                let model = ManagerModel.current
                let pointer = NSEvent.mouseLocation
                hitches.append(String(format: "t=%.2fs %.0fms scrolling=%@ camera=%@ preview=%@ chapter=%@ key=%@ mouse=%.0f,%.0f",
                                      link.timestamp - start, ms, ScrollActivity.scrolling ? "y" : "n",
                                      model?.cameraMoving == true ? "y" : "n",
                                      StagePreview.shared.active?.id ?? "-", model?.chapter.rawValue ?? "-",
                                      NSApp.keyWindow?.title ?? "-", pointer.x, pointer.y))
            }
            intervals.append(ms)
        }
        last = link.timestamp
        if intervals.count > 4000 { intervals.removeFirst(2000) }
    }

    func report() -> [String] {
        defer { intervals = []; hitches = []; start = CACurrentMediaTime() }
        guard !intervals.isEmpty else { return ["frames=0"] }
        let sorted = intervals.sorted()
        let p = { (q: Double) in sorted[min(Int(Double(sorted.count) * q), sorted.count - 1)] }
        let budget = self.budget
        let late = intervals.filter { $0 > budget.lateMs }.count
        let hitch = intervals.filter { $0 > budget.hitchMs }.count
        return [String(format: "frames=%d display=%dHz median=%.1fms p95=%.1fms max=%.1fms late(>%.1fms)=%d hitch(>%.0fms)=%d",
                       intervals.count, budget.refreshRate, p(0.5), p(0.95), sorted.last ?? 0, budget.lateMs, late,
                       budget.hitchMs, hitch)] + hitches.map { "  hitch " + $0 }
    }

    /// Asks for the display's own top rate: 120 on ProMotion, 60 elsewhere. Asking a 60 Hz
    /// display for 120 is harmless, but saying so keeps every link here honest about its pace.
    static func displayRate(for view: NSView?) -> CAFrameRateRange {
        let rate = Float(ShellFrameBudget(maximumFramesPerSecond: view?.window?.screen?.maximumFramesPerSecond
                                          ?? NSScreen.main?.maximumFramesPerSecond ?? 60).refreshRate)
        return CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
    }
}

/// atelier://scrolltest: scrolls the Studio's right panel down and back up at display rate, the
/// way a trackpad does, so FrameMeter can time scrolling without anyone at the Mac.
@MainActor
final class ScrollProbe: NSObject {
    static let shared = ScrollProbe()
    private var link: CADisplayLink?
    private weak var scroll: NSScrollView?
    private var frame = 0
    /// How far the last run got, for atelier://diag: proof that it scrolled at all.
    var note = "none"
    private var reached = 0.0

    func run(in window: NSWindow?, minHeight: Double = 300) {
        guard link == nil, let content = window?.contentView else { return }
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(content)
        // The panel: the right-most tall scroll view.
        guard let panel = found.filter({ $0.frame.height >= minHeight })
            .max(by: { $0.convert($0.bounds, to: nil).maxX < $1.convert($1.bounds, to: nil).maxX }) else { return }
        scroll = panel
        frame = 0
        reached = 0
        let link = panel.displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = FrameMeter.displayRate(for: panel)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        guard let scroll, let document = scroll.documentView else { link?.invalidate(); link = nil; return }
        frame += 1
        // What a real scroll does too: hover previews hold off while it moves.
        ScrollActivity.note()
        // 1.6 s down at 14 points a frame, then 1.6 s back up.
        let limit = max(0, document.frame.height - scroll.contentView.bounds.height)
        let down = frame <= 192
        var origin = scroll.contentView.bounds.origin
        origin.y = min(limit, max(0, origin.y + (down ? 14 : -14) * (document.isFlipped ? 1 : -1)))
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        reached = max(reached, abs(scroll.contentView.bounds.origin.y))
        note = "scrolled \(Int(reached)) of \(Int(limit)) pt in \(type(of: scroll))"
        if frame >= 384 { link?.invalidate(); link = nil }
    }
}


/// atelier://scrolltest?real: trackpad-like scroll events posted through the window server at
/// the pointer, so they take the same path as a person's: hover, scroll phases, AppKit.
@MainActor
final class RealScrollProbe: NSObject {
    static let shared = RealScrollProbe()
    /// A mouse wheel: notched line steps instead of a trackpad's continuous pixels.
    var wheel = false
    /// Jiggle the pointer while scrolling, as a hand does.
    var jiggle = true
    private var link: CADisplayLink?
    private var frame = 0

    func run(in window: NSWindow?) {
        guard link == nil, let view = window?.contentView else { return }
        frame = 0
        let link = view.displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = FrameMeter.displayRate(for: view)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        frame += 1
        // Three flicks down and three up, each 40 frames of motion and a 20 frame rest.
        let cycle = (frame - 1) % 60, flick = (frame - 1) / 60
        if flick >= 6 { link?.invalidate(); link = nil; return }
        let down = flick < 3
        // The hand moves a little while it scrolls, as a person's does.
        if jiggle, let at = CGEvent(source: nil)?.location,
           let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                              mouseCursorPosition: CGPoint(x: at.x + (frame % 2 == 0 ? 1.5 : -1.5), y: at.y), mouseButton: .left) {
            move.post(tap: .cghidEventTap)
        }
        let sign: Double = down ? -1 : 1
        if wheel {
            // A notch every 4 frames, about what a quick spin gives.
            if cycle < 40, cycle % 4 == 0,
               let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: Int32(sign * 3), wheel2: 0, wheel3: 0) {
                event.post(tap: .cghidEventTap)
            }
            return
        }
        if cycle < 20 {
            // The fingers: began, changed, ended.
            post(Int32(sign * 22), phase: cycle == 0 ? 1 : cycle == 19 ? 4 : 2, momentum: 0)
        } else if cycle < 56 {
            // Momentum after the fingers lift, slowing down: began 1, continue 2, end 3.
            let left = Double(56 - cycle) / 36
            post(Int32(sign * max(1, 22 * left)), phase: 0, momentum: cycle == 20 ? 1 : cycle == 55 ? 3 : 2)
        }
    }

    private func post(_ delta: Int32, phase: Int64, momentum: Int64) {
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.post(tap: .cghidEventTap)
    }
}


/// atelier://hovertest: the pointer sweeps down the right panel and back, over its cards, with
/// real mouse-moved events, so hover costs can be timed without a hand on the mouse.
@MainActor
final class HoverProbe: NSObject {
    static let shared = HoverProbe()
    private var link: CADisplayLink?
    private var frame = 0
    private var rect = CGRect.zero

    /// Set before run: a point (top-left screen coordinates) to sweep across sideways instead.
    var line: CGRect?

    func run(in window: NSWindow?) {
        guard link == nil, let window, let view = window.contentView, let screen = window.screen ?? NSScreen.main else { return }
        // The panel's column, in the top-left based coordinates events use.
        let f = window.frame
        let top = screen.frame.maxY - f.maxY
        rect = line ?? CGRect(x: f.maxX - 400, y: top + 120, width: 360, height: f.height - 200)
        frame = 0
        let link = view.displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = FrameMeter.displayRate(for: view)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step() {
        frame += 1
        guard frame <= 288 else { link?.invalidate(); link = nil; return }
        // Zig-zag across the column while going down, then back up: 2.4 s.
        let t = Double(frame % 144) / 144
        let down = frame <= 144
        var y = rect.minY + rect.height * (down ? t : 1 - t)
        var x = rect.minX + rect.width * (0.5 + 0.45 * sin(Double(frame) / 9))
        if line != nil {
            x = rect.minX + rect.width * (down ? t : 1 - t)
            y = rect.midY
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }
}
