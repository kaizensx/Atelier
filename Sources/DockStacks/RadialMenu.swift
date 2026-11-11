import AppKit
import Carbon.HIToolbox
import DockCore
import QuartzCore
import SwiftUI

// MARK: - Radial Window Menu
//
// Hold a trigger (Hyper, ⌃⌥, Right ⌥, Right ⌘ or fn, and optionally the middle mouse button) and
// a ring of glass opens around the pointer. Moving the pointer, or the arrow keys, picks a
// layout: the centre maximises, the inner ring holds halves and corners, the outer ring thirds.
// A glass slab shows where the window will land; letting go glides it there on Window Engine's
// spring. Escape cancels. Inspired by Loop (MrKai77/Loop); the look is Atelier's own.
//
// Cost: with the switch off there is no tap, no timer, no panel. With it on there is one
// session event tap for key, modifier and (when chosen) middle-button events; it decides in a
// few comparisons and passes everything on unless the ring is open. The 120 Hz display link
// runs only while the ring is on screen. The picking and timing rules live in DockCore
// (RadialMenuLogic.swift) with tests.

private nonisolated(unsafe) var radialTap: CFMachPort?
/// Mirrors for the C callback, which must answer without touching the main actor when idle.
private nonisolated(unsafe) var radialWantsHyper = false
private nonisolated(unsafe) var radialWantsMiddle = false
/// Stamped on the middle click Atelier sends back, so the tap lets it pass.
private let radialMark: Int64 = 0x41524144

/// Called from Hyper Key's tap when the remapped Caps Lock (F18) goes down or up.
func radialHyperKey(down: Bool) {
    guard radialWantsHyper else { return }
    MainActor.assumeIsolated { RadialMenu.shared.hyper(down: down) }
}

private func radialCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                            _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let radialTap { CGEvent.tapEnable(tap: radialTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if event.getIntegerValueField(.eventSourceUserData) == radialMark { return Unmanaged.passUnretained(event) }
    switch type {
    case .flagsChanged:
        let flags = event.flags.rawValue
        MainActor.assumeIsolated { RadialMenu.shared.flags(flags) }
        return Unmanaged.passUnretained(event)
    case .keyDown, .keyUp:
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        // F18 belongs to Hyper Key, which reports it through `radialHyperKey`.
        if code == HyperKeyState.hyperKeycode { return Unmanaged.passUnretained(event) }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let swallow = MainActor.assumeIsolated { RadialMenu.shared.key(code, down: type == .keyDown, isRepeat: isRepeat) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    case .otherMouseDown, .otherMouseUp:
        guard radialWantsMiddle, event.getIntegerValueField(.mouseEventButtonNumber) == 2 else {
            return Unmanaged.passUnretained(event)
        }
        let swallow = MainActor.assumeIsolated { RadialMenu.shared.middle(down: type == .otherMouseDown) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    default:
        return Unmanaged.passUnretained(event)
    }
}

private final class RadialTicker: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { RadialMenu.shared.frame() }
    }
}

@MainActor
final class RadialMenu: ObservableObject {
    static let shared = RadialMenu()
    private let store = UserDefaults.standard

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "radial.enabled"); apply() } }
    @Published var trigger: RadialTrigger {
        didSet { store.set(trigger.rawValue, forKey: "radial.trigger"); gate.reset(); apply() }
    }
    @Published var middleButton: Bool { didSet { store.set(middleButton, forKey: "radial.middle"); apply() } }
    @Published var thirds: Bool { didSet { store.set(thirds, forKey: "radial.thirds"); picker.tuning.thirds = thirds } }
    @Published var haptics: Bool { didSet { store.set(haptics, forKey: "radial.haptics") } }
    @Published private(set) var lastApplied: RadialPick?

    private var source: CFRunLoopSource?
    private var trustObserver: NSObjectProtocol?

    private enum Opener { case keys, hyper, middle, test }
    private var gate = RadialGate()
    private var opener = Opener.keys
    private var armToken = 0
    private var picker = RadialPicker()
    private var keys = RadialKeys()
    /// Arrow keys own the pick until the pointer travels this far from where it was.
    private var keysOwn: CGPoint?
    /// Key-ups to swallow: their key-downs were the ring's.
    private var swallowUps: Set<Int64> = []

    private var anchor = CGPoint.zero
    private var openedAt = 0.0
    private var testOffset: CGPoint?
    private var testUntil: Double?
    /// The window and display as read at open; every pick's frame is computed from it.
    private var openTarget: WindowEngine.RadialTarget?
    private var windowNumber: Int?
    private var hasWindow = false

    private let ring = RadialRing()
    private let preview = RadialPreview()
    private let ticker = RadialTicker()
    private var link: CADisplayLink?
    private var frameTimes: [Double] = []

    // Counters for the report.
    private var opens = 0, commits = 0, cancels = 0, clicks = 0, chords = 0, changes = 0
    private var lastFPS = 0.0
    private var lastMedianFrame = 0.0

    private init() {
        enabled = store.bool(forKey: "radial.enabled")
        trigger = RadialTrigger(rawValue: store.string(forKey: "radial.trigger") ?? "") ?? .controlOption
        middleButton = store.bool(forKey: "radial.middle")
        thirds = store.object(forKey: "radial.thirds") as? Bool ?? true
        haptics = store.object(forKey: "radial.haptics") as? Bool ?? true
        picker.tuning.thirds = thirds
    }

    func resume() {
        if trustObserver == nil {
            // Accessibility granted later starts the tap without a relaunch.
            trustObserver = DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { MainActor.assumeIsolated { RadialMenu.shared.apply() } }
            }
        }
        if enabled { apply() }
    }

    func restoreOnQuit() {
        if gate.isOpen { close(commit: false) }
        stopTap()
    }

    var tapActive: Bool { radialTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    var availability: FeatureAvailability {
        if !AXIsProcessTrusted() { return .limited("Needs Accessibility, to read keys and move windows") }
        if trigger == .hyper && !(HyperKey.shared.enabled && HyperKey.shared.tapActive) {
            return .limited("Hyper needs Hyper Key on, in Keyboard")
        }
        if trigger == .function { return .limited("If fn opens Emoji or Dictation, set Press fn to Do Nothing in Keyboard settings") }
        return .available
    }

    var diagnostics: String {
        "radialEnabled=\(enabled) radialTrigger=\(trigger.rawValue) radialTap=\(tapActive) radialMiddle=\(middleButton) " +
            "radialOpen=\(gate.isOpen) radialPick=\(gate.isOpen ? picker.selection.pick.rawValue : "-") radialOpens=\(opens) radialCommits=\(commits) radialCancels=\(cancels) " +
            "radialChords=\(chords) radialClicks=\(clicks) radialChanges=\(changes) radialFPS=\(String(format: "%.1f", lastFPS)) radialFrameMedianMs=\(String(format: "%.2f", lastMedianFrame)) " +
            "radialLast=\(lastApplied?.rawValue ?? "-")"
    }

    // MARK: Tap

    private func apply() {
        radialWantsHyper = enabled && trigger == .hyper
        radialWantsMiddle = enabled && middleButton
        stopTap()
        guard enabled, AXIsProcessTrusted() else {
            if gate.isOpen { close(commit: false) }
            gate.reset()
            return
        }
        var mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue
                               | 1 << CGEventType.flagsChanged.rawValue)
        if middleButton {
            mask |= CGEventMask(1 << CGEventType.otherMouseDown.rawValue | 1 << CGEventType.otherMouseUp.rawValue)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: radialCallback, userInfo: nil) else { return }
        radialTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.source = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stopTap() {
        guard let tap = radialTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        radialTap = nil
        source = nil
    }

    // MARK: Events (from the tap, on the main thread)

    fileprivate func flags(_ raw: UInt64) {
        guard trigger != .hyper else { return }
        if gate.isOpen {
            if opener == .keys, !trigger.holds(raw) { finish(gate.triggerUp()) }
            return
        }
        if gate.isArming {
            guard opener == .keys else { return }
            if trigger.exactly(raw) { return }
            if trigger.holds(raw) { chords += 1; _ = gate.otherInput() } else { _ = gate.triggerUp() }
            return
        }
        if trigger.exactly(raw) { arm(.keys, delay: trigger.delay) }
    }

    fileprivate func hyper(down: Bool) {
        guard trigger == .hyper else { return }
        if down {
            if gate.phase == .idle { arm(.hyper, delay: trigger.delay) }
        } else if opener == .hyper {
            finish(gate.triggerUp())
        }
    }

    /// Returns true to swallow the event.
    fileprivate func middle(down: Bool) -> Bool {
        if down {
            guard gate.phase == .idle else { return gate.isOpen }
            arm(.middle, delay: 0.18)
            return true
        }
        guard opener == .middle, gate.phase != .idle else { return false }
        let action = gate.triggerUp()
        if action == .click { replayMiddleClick() }
        finish(action)
        return true
    }

    /// Returns true to swallow the event.
    fileprivate func key(_ code: Int64, down: Bool, isRepeat: Bool) -> Bool {
        if !down, swallowUps.remove(code) != nil { return true }
        guard down else { return false }
        guard gate.isOpen else {
            if gate.isArming, opener != .middle { chords += 1; _ = gate.otherInput() }
            return false
        }
        swallowUps.insert(code)
        if isRepeat { return true }
        switch Int(code) {
        case kVK_Escape: finish(gate.escape())
        case kVK_Return, kVK_Space, kVK_ANSI_KeypadEnter: finish(gate.triggerUp())
        default:
            guard let arrow = RadialArrow(keycode: code) else {
                // Any other key means the trigger was the start of a shortcut: step aside and
                // let the key through, so the ring never eats a chord.
                swallowUps.remove(code)
                chords += 1
                close(commit: false)
                return false
            }
            pressArrow(arrow)
        }
        return true
    }

    private func pressArrow(_ arrow: RadialArrow) {
        let next = keys.press(arrow, current: picker.selection, thirds: thirds)
        // Releasing keeps the pick, so the held set only matters for corners.
        keys.release(arrow)
        keysOwn = cursorOffset()
        if picker.force(next) { pickChanged() }
        ring.select(picker.selection, animated: !reduceMotion)
    }

    private func arm(_ who: Opener, delay: Double) {
        opener = who
        _ = gate.triggerDown(now: CACurrentMediaTime())
        armToken += 1
        let token = armToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                let menu = RadialMenu.shared
                guard menu.armToken == token else { return }
                if menu.gate.tick(now: CACurrentMediaTime(), delay: delay) == .open { menu.open(at: nil) }
            }
        }
    }

    private func finish(_ action: RadialGate.Action) {
        switch action {
        case .commit: close(commit: true)
        case .cancel: close(commit: false)
        case .click: clicks += 1
        case .none, .open: break
        }
    }

    private func replayMiddleClick() {
        let location = CGEvent(source: nil)?.location ?? .zero
        let source = CGEventSource(stateID: .hidSystemState)
        for type in [CGEventType.otherMouseDown, .otherMouseUp] {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                      mouseButton: .center) else { continue }
            event.setIntegerValueField(.eventSourceUserData, value: radialMark)
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: Open and close

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var primaryHeight: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }

    /// The pointer in Accessibility coordinates (top left origin, y down).
    private func cursorPoint() -> CGPoint {
        let point = NSEvent.mouseLocation
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private func cursorOffset() -> CGPoint {
        if let testOffset { return testOffset }
        let cursor = cursorPoint()
        return CGPoint(x: cursor.x - anchor.x, y: cursor.y - anchor.y)
    }

    /// `point` is in Accessibility coordinates; nil opens at the pointer.
    private func open(at point: CGPoint?) {
        let engine = WindowEngine.shared
        engine.start()
        let wanted = point ?? cursorPoint()
        // The window must exist before the ring promises to move it.
        let first = engine.radialTarget(.maximize, at: wanted, windowNumber: true)
        hasWindow = first != nil
        if !hasWindow && opener != .test {
            gate.reset()
            NSSound.beep()
            return
        }
        windowNumber = first?.windowNumber
        openTarget = first
        let screen = NSScreen.screens.first {
            WindowGeometry.flipped($0.frame, primaryHeight: primaryHeight).contains(wanted)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let bounds = WindowGeometry.flipped(screen.frame, primaryHeight: primaryHeight)
        let centre = RadialGeometry.clampedCentre(x: wanted.x, y: wanted.y, radius: RadialRing.reach,
                                                  minX: bounds.minX, minY: bounds.minY, maxX: bounds.maxX, maxY: bounds.maxY)
        anchor = CGPoint(x: centre.x, y: centre.y)
        picker.tuning.thirds = thirds
        picker.reset()
        keys.reset()
        keysOwn = nil
        if opener != .test { testOffset = nil; testUntil = nil }
        if let testOffset { picker.update(dx: testOffset.x, dy: testOffset.y) }
        opens += 1
        openedAt = CACurrentMediaTime()
        frameTimes = []
        ring.show(at: anchor, primaryHeight: primaryHeight, thirds: thirds, hue: NSColor(DS.Spectrum.windows),
                  reduceMotion: reduceMotion)
        ring.select(picker.selection, animated: false)
        ring.pointer(cursorOffset())
        showPreview()
        startLink(screen: screen)
    }

    private func close(commit: Bool) {
        stopLink()
        gate.reset()
        armToken += 1
        let selection = picker.selection
        ring.hide(committed: commit, reduceMotion: reduceMotion)
        preview.hide()
        testOffset = nil
        testUntil = nil
        guard commit else { cancels += 1; return }
        commits += 1
        guard let layout = WindowGeometry.Layout(rawValue: selection.pick.rawValue) else { return }
        if hasWindow, WindowEngine.shared.radialApply(layout, at: anchor) != nil { lastApplied = selection.pick }
    }

    private func pickChanged() {
        changes += 1
        if haptics { Haptics.shared.play(.light) }
        showPreview()
    }

    private func showPreview() {
        guard hasWindow, let layout = WindowGeometry.Layout(rawValue: picker.selection.pick.rawValue) else { return }
        // Pure geometry from what was read at open: no Accessibility call while the hand moves.
        guard let first = openTarget else { return }
        let frame = layout.frame(in: first.display.visible, gap: WindowEngine.shared.gap, current: first.current.size)
        preview.show(title: layout.title, frame: frame, display: first.display, primaryHeight: first.primaryHeight,
                     below: windowNumber)
    }

    // MARK: The frame loop

    private func startLink(screen: NSScreen) {
        stopLink()
        let next = screen.displayLink(target: ticker, selector: #selector(RadialTicker.tick(_:)))
        // ProMotion drops the rate when nothing moves; the pointer dot must keep up with the hand.
        next.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        next.add(to: .main, forMode: .common)
        link = next
    }

    private func stopLink() {
        if frameTimes.count > 10, let first = frameTimes.first, let last = frameTimes.last, last > first {
            lastFPS = Double(frameTimes.count - 1) / (last - first)
            let intervals = zip(frameTimes.dropFirst(), frameTimes).map { $0 - $1 }.sorted()
            lastMedianFrame = intervals[intervals.count / 2] * 1000
        }
        link?.invalidate()
        link = nil
    }

    fileprivate func frame() {
        guard gate.isOpen else { stopLink(); return }
        let now = CACurrentMediaTime()
        if frameTimes.count < 4000 { frameTimes.append(now) }
        if let until = testUntil, now >= until { close(commit: false); return }
        // A lost key-up (Secure Input, a sleep) must not leave the ring stuck open.
        if lostTrigger() { finish(gate.triggerUp()); return }
        if now - openedAt > 30 { close(commit: false); return }
        let offset = cursorOffset()
        if let owned = keysOwn {
            if hypot(offset.x - owned.x, offset.y - owned.y) > 24 { keysOwn = nil }
        }
        if keysOwn == nil, picker.update(dx: offset.x, dy: offset.y) {
            ring.select(picker.selection, animated: !reduceMotion)
            pickChanged()
        }
        ring.pointer(offset)
    }

    private func lostTrigger() -> Bool {
        switch opener {
        case .keys: return !trigger.holds(CGEventSource.flagsState(.combinedSessionState).rawValue)
        case .middle:
            // Either record will do: posted clicks show in the session's, the hand's in the HID system's.
            return !CGEventSource.buttonState(.combinedSessionState, button: .center)
                && !CGEventSource.buttonState(.hidSystemState, button: .center)
        case .hyper, .test: return false
        }
    }

    // MARK: Test hook

    /// atelier://radial?…  on=0|1  trigger=hyper|controlOption|rightOption|rightCommand|function
    /// middle=0|1 thirds=0|1 haptics=0|1 · simulate=<angle>&distance=<pt> (pick only, no UI)
    /// keys=left,left or keys=left+up (arrow picks from the centre) · show=1[&x=&y=][&angle=&distance=][&hold=s]
    /// (the ring at a point, for screenshots) · move=<angle>&distance= (moves the shown ring's
    /// pointer) · commit=1 · hide=1 · apply=<layout> · place=x,y,w,h · report=1.
    /// Writes $TMPDIR/atelier-radial.txt.
    func handleTest(_ items: [URLQueryItem]) {
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        func number(_ name: String) -> Double? { value(name).flatMap(Double.init) }
        var lines: [String] = []
        for item in items {
            let v = item.value ?? ""
            switch item.name {
            case "on": enabled = v == "1"
            case "trigger": if let t = RadialTrigger(rawValue: v) { trigger = t } else { lines.append("error=unknown-trigger(\(v))") }
            case "middle": middleButton = v == "1"
            case "thirds": thirds = v == "1"
            case "haptics": haptics = v == "1"
            default: break
            }
        }
        if let angle = number("simulate") {
            let distance = number("distance") ?? 70
            var dry = RadialPicker(tuning: picker.tuning)
            let offset = RadialGeometry.offset(angle: angle, distance: distance)
            dry.update(dx: offset.dx, dy: offset.dy)
            lines.append(describe("simulate", angle: angle, distance: distance, dry.selection))
        }
        if let raw = value("keys") {
            var sim = RadialKeys()
            var selection = RadialSelection.centre
            // "left,left" presses twice; "left+up" holds both, for a corner.
            for chord in raw.split(separator: ",") {
                let arrows = chord.split(separator: "+").compactMap { RadialArrow(rawValue: String($0)) }
                if arrows.isEmpty { lines.append("error=unknown-arrow(\(chord))"); continue }
                for arrow in arrows { selection = sim.press(arrow, current: selection, thirds: thirds) }
                arrows.forEach { sim.release($0) }
            }
            lines.append("keys=\(raw) pick=\(selection.pick.rawValue) band=\(selection.band) sector=\(selection.sector.map { "\($0)" } ?? "-")")
        }
        if value("show") == "1" {
            if gate.isOpen { close(commit: false) }
            let screen = NSScreen.main?.frame ?? .zero
            let point = CGPoint(x: number("x") ?? screen.midX, y: number("y") ?? screen.height / 2)
            if let angle = number("angle") {
                let offset = RadialGeometry.offset(angle: angle, distance: number("distance") ?? 70)
                testOffset = CGPoint(x: offset.dx, y: offset.dy)
            } else {
                testOffset = nil
            }
            testUntil = CACurrentMediaTime() + min(number("hold") ?? 8, 30)
            opener = .test
            _ = gate.triggerDown(now: 0)
            _ = gate.tick(now: 1, delay: 0)
            open(at: point)
            lines.append("shown=\(gate.isOpen) anchor=\(Int(anchor.x)),\(Int(anchor.y)) window=\(hasWindow) " +
                         "pick=\(picker.selection.pick.rawValue)")
        }
        if let angle = number("move"), gate.isOpen {
            let offset = RadialGeometry.offset(angle: angle, distance: number("distance") ?? 70)
            testOffset = CGPoint(x: offset.dx, y: offset.dy)
            lines.append("moved pick-on-next-frame angle=\(angle)")
        }
        if value("commit") == "1", gate.isOpen {
            let pick = picker.selection.pick
            close(commit: true)
            lines.append("committed=\(pick.rawValue) window=\(hasWindow)")
        }
        if value("hide") == "1", gate.isOpen { close(commit: false); lines.append("hidden=1") }
        if let raw = value("place") {
            let parts = raw.split(separator: ",").compactMap { Double($0) }
            if parts.count == 4 {
                let ok = WindowEngine.shared.radialPlaceFront(CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3]))
                lines.append("placed=\(ok)")
            }
        }
        if let raw = value("apply") {
            if let layout = WindowGeometry.Layout(rawValue: raw) {
                let point = WindowEngine.shared.radialTarget(.center, at: cursorPoint(), windowNumber: false)
                    .map { CGPoint(x: $0.current.midX, y: $0.current.midY) } ?? cursorPoint()
                if let target = WindowEngine.shared.radialApply(layout, at: point) {
                    lastApplied = RadialPick(rawValue: raw)
                    lines.append("applied=\(raw) app=\(target.appName) from=\(rect(target.current)) to=\(rect(target.frame))")
                } else {
                    lines.append("error=no-movable-window trusted=\(AXIsProcessTrusted())")
                }
            } else {
                lines.append("error=unknown-layout(\(raw))")
            }
        }
        if let front = WindowEngine.shared.radialTarget(.center, at: cursorPoint(), windowNumber: false) {
            lines.append("front=\(front.appName) frame=\(rect(front.current))")
        } else {
            lines.append("front=-")
        }
        lines.append("availability=\(availability.note ?? "available")")
        lines.append(diagnostics)
        try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "atelier-radial.txt", atomically: true, encoding: .utf8)
    }

    private func describe(_ label: String, angle: Double, distance: Double, _ selection: RadialSelection) -> String {
        var line = "\(label)=\(angle) distance=\(distance) pick=\(selection.pick.rawValue) band=\(selection.band) " +
            "sector=\(selection.sector.map { "\($0)" } ?? "-")"
        if let layout = WindowGeometry.Layout(rawValue: selection.pick.rawValue),
           let target = WindowEngine.shared.radialTarget(layout, at: cursorPoint(), windowNumber: false) {
            line += " target=\(rect(target.frame))"
        }
        return line
    }

    private func rect(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))x\(Int(r.height))" }
}

// MARK: - The ring

/// Glass, light and a travelling highlight, drawn with Core Animation so every frame is the
/// render server's work: the main thread only moves the pointer dot and, on a change of pick,
/// starts one spring.
@MainActor
private final class RadialRing {
    static let centreRadius = 26.0
    static let innerRange = 34.0...98.0
    static let outerRange = 106.0...150.0
    /// How far the ring and its glow reach from the centre, for keeping it on screen.
    static let reach = 190.0
    private static let side = 2 * reach

    private var panel: NSPanel?
    private let root = CALayer()
    private let glass = NSVisualEffectView()
    private let tint = CAShapeLayer()
    private let dividers = CAShapeLayer()
    private let glyphs = CALayer()
    private let highlight = CALayer()
    private let wedge = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let core = CAShapeLayer()
    private let tether = CAShapeLayer()
    private let dot = CALayer()
    private let label = CATextLayer()
    private let pill = CALayer()
    private var rotation = 0.0
    private var builtThirds: Bool?
    private var hue = NSColor.systemPurple
    private var generation = 0
    private var shownSelection: RadialSelection?

    func show(at centre: CGPoint, primaryHeight: Double, thirds: Bool, hue: NSColor, reduceMotion: Bool) {
        generation += 1
        let side = Self.side
        let frame = NSRect(x: centre.x - side / 2, y: primaryHeight - centre.y - side / 2, width: side, height: side)
        let panel = panel ?? makePanel(frame)
        if builtThirds != thirds || !self.hue.isEqual(hue) {
            self.hue = hue
            build(thirds: thirds)
        }
        panel.setFrame(frame, display: false)
        shownSelection = nil
        panel.orderFrontRegardless()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.removeAllAnimations()
        root.opacity = 1
        root.transform = CATransform3DIdentity
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduceMotion ? 0.15 : 0.12
        root.add(fade, forKey: "in.opacity")
        if !reduceMotion {
            let grow = CASpringAnimation(perceptualDuration: 0.32, bounce: 0.16)
            grow.keyPath = "transform.scale"
            grow.fromValue = 0.78
            grow.toValue = 1
            root.add(grow, forKey: "in.scale")
        }
        glass.alphaValue = 1
    }

    func hide(committed: Bool, reduceMotion: Bool) {
        guard let panel, panel.isVisible else { return }
        generation += 1
        let current = generation
        CATransaction.begin()
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1))
        CATransaction.setAnimationDuration(committed ? 0.2 : 0.16)
        root.opacity = 0
        if !reduceMotion { root.transform = CATransform3DMakeScale(committed ? 1.08 : 0.9, committed ? 1.08 : 0.9, 1) }
        CATransaction.commit()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = committed ? 0.2 : 0.16
            glass.animator().alphaValue = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
    }

    /// The pointer's offset from the centre, screen-style (y down).
    func pointer(_ offset: CGPoint) {
        let distance = hypot(offset.x, offset.y)
        let limit = Self.outerRange.upperBound + 6
        let scale = distance > limit ? limit / distance : 1
        let c = Self.side / 2
        let point = CGPoint(x: c + offset.x * scale, y: c - offset.y * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.position = point
        let line = CGMutablePath()
        line.move(to: CGPoint(x: c, y: c))
        line.addLine(to: point)
        tether.path = line
        tether.opacity = distance > Self.centreRadius ? 1 : 0
        CATransaction.commit()
    }

    func select(_ selection: RadialSelection, animated: Bool) {
        guard selection != shownSelection else { return }
        let previous = shownSelection
        shownSelection = selection
        label.string = WindowGeometry.Layout(rawValue: selection.pick.rawValue)?.title ?? ""
        let inCentre = selection.band == .center
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.16 : 0)
        CATransaction.setDisableActions(!animated)
        core.opacity = inCentre ? 1 : 0
        highlight.opacity = inCentre ? 0 : 1
        CATransaction.commit()
        guard let segment = RadialMap.segment(for: selection) else { return }
        let range = selection.band == .outer ? Self.outerRange : Self.innerRange
        let path = Self.wedgePath(span: segment.span, range: range, inset: 1.5)
        let arc = Self.arcPath(span: segment.span, radius: range.upperBound - 1)
        // Shortest way round, kept continuous so a spring never spins the long way.
        let target = rotation + RadialGeometry.delta(from: rotation, to: segment.angle)
        let sameSegment = previous.flatMap { RadialMap.segment(for: $0) } == segment && previous?.band == selection.band
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fromRotation = (highlight.presentation()?.value(forKeyPath: "transform.rotation.z") as? Double) ?? rotation * .pi / 180
        let fromPath = wedge.presentation()?.path ?? wedge.path
        let fromArc = rim.presentation()?.path ?? rim.path
        highlight.setValue(target * .pi / 180, forKeyPath: "transform.rotation.z")
        wedge.path = path
        rim.path = arc
        CATransaction.commit()
        let comingFromCentre = previous?.band == .center || previous == nil
        if animated && !comingFromCentre && !sameSegment {
            let spring = CASpringAnimation(perceptualDuration: 0.26, bounce: 0.14)
            spring.keyPath = "transform.rotation.z"
            spring.fromValue = fromRotation
            spring.toValue = target * .pi / 180
            highlight.add(spring, forKey: "turn")
            for (layer, from) in [(wedge, fromPath), (rim, fromArc)] where from != nil {
                let morph = CASpringAnimation(perceptualDuration: 0.24, bounce: 0)
                morph.keyPath = "path"
                morph.fromValue = from
                morph.toValue = layer.path
                layer.add(morph, forKey: "morph")
            }
        } else {
            highlight.removeAnimation(forKey: "turn")
        }
        rotation = target
    }

    // MARK: Building

    private func makePanel(_ frame: NSRect) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        glass.frame = content.bounds
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        content.addSubview(glass)
        // The layer tree sits above the glass view.
        let overlay = NSView(frame: content.bounds)
        overlay.wantsLayer = true
        overlay.layer?.addSublayer(root)
        content.addSubview(overlay)
        panel.contentView = content
        self.panel = panel
        return panel
    }

    private func build(thirds: Bool) {
        builtThirds = thirds
        let side = Self.side, c = side / 2
        let centre = CGPoint(x: c, y: c)
        root.frame = CGRect(x: 0, y: 0, width: side, height: side)
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        let bands = thirds ? [Self.innerRange, Self.outerRange] : [Self.innerRange]

        // Glass: one mask for the centre disc and the rings.
        glass.maskImage = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: c - Self.centreRadius, y: c - Self.centreRadius,
                                        width: Self.centreRadius * 2, height: Self.centreRadius * 2)).fill()
            for band in bands {
                let ring = NSBezierPath(ovalIn: NSRect(x: c - band.upperBound, y: c - band.upperBound,
                                                       width: band.upperBound * 2, height: band.upperBound * 2))
                ring.append(NSBezierPath(ovalIn: NSRect(x: c - band.lowerBound, y: c - band.lowerBound,
                                                        width: band.lowerBound * 2, height: band.lowerBound * 2)).reversed)
                ring.fill()
            }
            return true
        }

        let shapes = CGMutablePath()
        shapes.addEllipse(in: CGRect(x: c - Self.centreRadius, y: c - Self.centreRadius, width: Self.centreRadius * 2, height: Self.centreRadius * 2))
        for band in bands {
            shapes.addEllipse(in: CGRect(x: c - band.upperBound, y: c - band.upperBound, width: band.upperBound * 2, height: band.upperBound * 2))
            shapes.addEllipse(in: CGRect(x: c - band.lowerBound, y: c - band.lowerBound, width: band.lowerBound * 2, height: band.lowerBound * 2))
        }
        tint.frame = root.bounds
        tint.path = shapes
        tint.fillRule = .evenOdd
        tint.fillColor = hue.withAlphaComponent(0.07).cgColor
        tint.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        tint.lineWidth = 0.75
        root.addSublayer(tint)

        // Dividers between segments, and a glyph of each layout.
        let lines = CGMutablePath()
        glyphs.frame = root.bounds
        glyphs.sublayers?.forEach { $0.removeFromSuperlayer() }
        for (band, range) in zip([RadialBand.inner, .outer], bands) {
            for segment in RadialMap.segments(band) {
                let edge = (segment.first.angle - 22.5) * .pi / 180
                lines.move(to: CGPoint(x: c + cos(edge) * (range.lowerBound + 5), y: c + sin(edge) * (range.lowerBound + 5)))
                lines.addLine(to: CGPoint(x: c + cos(edge) * (range.upperBound - 5), y: c + sin(edge) * (range.upperBound - 5)))
                let mid = segment.angle * .pi / 180, r = (range.lowerBound + range.upperBound) / 2
                glyphs.addSublayer(glyph(segment.pick, at: CGPoint(x: c + cos(mid) * r, y: c + sin(mid) * r),
                                         small: band == .outer))
            }
        }
        glyphs.addSublayer(glyph(.maximize, at: centre, small: true))
        dividers.frame = root.bounds
        dividers.path = lines
        dividers.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
        dividers.lineWidth = 0.75
        dividers.lineCap = .round
        root.addSublayer(dividers)

        // The highlight: a lit wedge with a bright rim and a soft glow, turned by one rotation.
        highlight.frame = root.bounds
        highlight.sublayers?.forEach { $0.removeFromSuperlayer() }
        wedge.frame = highlight.bounds
        wedge.fillColor = hue.withAlphaComponent(0.5).cgColor
        wedge.shadowColor = hue.cgColor
        wedge.shadowOpacity = 0.9
        wedge.shadowRadius = 14
        wedge.shadowOffset = .zero
        rim.frame = highlight.bounds
        rim.fillColor = nil
        rim.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        rim.lineWidth = 2
        rim.lineCap = .round
        rim.shadowColor = NSColor.white.cgColor
        rim.shadowOpacity = 0.8
        rim.shadowRadius = 4
        rim.shadowOffset = .zero
        highlight.addSublayer(wedge)
        highlight.addSublayer(rim)
        highlight.opacity = 0
        root.insertSublayer(highlight, above: tint)

        core.frame = root.bounds
        core.path = CGPath(ellipseIn: CGRect(x: c - Self.centreRadius + 2, y: c - Self.centreRadius + 2,
                                             width: (Self.centreRadius - 2) * 2, height: (Self.centreRadius - 2) * 2), transform: nil)
        core.fillColor = hue.withAlphaComponent(0.55).cgColor
        core.shadowColor = hue.cgColor
        core.shadowOpacity = 0.9
        core.shadowRadius = 12
        core.shadowOffset = .zero
        core.opacity = 1
        root.insertSublayer(core, above: highlight)
        root.addSublayer(glyphs)

        tether.frame = root.bounds
        tether.strokeColor = NSColor.white.withAlphaComponent(0.22).cgColor
        tether.lineWidth = 1.5
        tether.lineCap = .round
        root.addSublayer(tether)

        dot.bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        dot.cornerRadius = 5
        dot.backgroundColor = NSColor.white.cgColor
        dot.shadowColor = hue.cgColor
        dot.shadowOpacity = 1
        dot.shadowRadius = 6
        dot.shadowOffset = .zero
        dot.position = centre
        root.addSublayer(dot)

        // The pick's name, on a small dark pill under the ring.
        let top = (thirds ? Self.outerRange.upperBound : Self.innerRange.upperBound)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.fontSize = 12
        label.alignmentMode = .center
        label.foregroundColor = NSColor.white.cgColor
        label.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 0, y: 4, width: 128, height: 16)
        pill.bounds = CGRect(x: 0, y: 0, width: 128, height: 24)
        pill.cornerRadius = 12
        pill.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        pill.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        pill.borderWidth = 0.5
        pill.position = CGPoint(x: c, y: c - top - 22)
        pill.sublayers?.forEach { $0.removeFromSuperlayer() }
        pill.addSublayer(label)
        root.addSublayer(pill)
    }

    /// A tiny screen with the layout lit, the same geometry the window will take.
    private func glyph(_ pick: RadialPick, at point: CGPoint, small: Bool) -> CALayer {
        let size = small ? CGSize(width: 17, height: 11) : CGSize(width: 21, height: 14)
        let layer = CAShapeLayer()
        layer.bounds = CGRect(origin: .zero, size: size)
        layer.position = point
        layer.path = CGPath(roundedRect: layer.bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 2.5, cornerHeight: 2.5, transform: nil)
        layer.fillColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        layer.lineWidth = 1
        if let layout = WindowGeometry.Layout(rawValue: pick.rawValue) {
            let inner = layer.bounds.insetBy(dx: 1, dy: 1)
            // Layout frames are y-down; the layer is y-up.
            var tile = layout.frame(in: CGRect(origin: .zero, size: inner.size), gap: 1.2,
                                    current: CGSize(width: inner.width * 0.55, height: inner.height * 0.6))
            tile.origin.y = inner.height - tile.maxY
            let fill = CAShapeLayer()
            fill.frame = layer.bounds
            fill.path = CGPath(roundedRect: tile.offsetBy(dx: inner.minX, dy: inner.minY), cornerWidth: 1, cornerHeight: 1, transform: nil)
            fill.fillColor = NSColor.white.withAlphaComponent(0.88).cgColor
            layer.addSublayer(fill)
        }
        return layer
    }

    /// An annular sector centred on angle 0, built from a fixed number of points so any two
    /// wedges morph smoothly into each other.
    static func wedgePath(span: Double, range: ClosedRange<Double>, inset: Double) -> CGPath {
        let c = side / 2, steps = 28
        let half = (span / 2 - 0.9) * .pi / 180
        let inner = range.lowerBound + inset, outer = range.upperBound - inset
        let path = CGMutablePath()
        for step in 0...steps {
            let a = -half + 2 * half * Double(step) / Double(steps)
            let point = CGPoint(x: c + cos(a) * outer, y: c + sin(a) * outer)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        for step in (0...steps).reversed() {
            let a = -half + 2 * half * Double(step) / Double(steps)
            path.addLine(to: CGPoint(x: c + cos(a) * inner, y: c + sin(a) * inner))
        }
        path.closeSubpath()
        return path
    }

    static func arcPath(span: Double, radius: Double) -> CGPath {
        let c = side / 2, steps = 28
        let half = (span / 2 - 5) * .pi / 180
        let path = CGMutablePath()
        for step in 0...steps {
            let a = -half + 2 * half * Double(step) / Double(steps)
            let point = CGPoint(x: c + cos(a) * radius, y: c + sin(a) * radius)
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

// MARK: - The landing slab

/// Window Engine's own glass slab (SnapPreviewView), on a panel of its own just below the
/// window that will move.
@MainActor
private final class RadialPreview {
    private let model = SnapPreviewModel()
    private var panel: NSPanel?
    private var generation = 0

    func show(title: String, frame: CGRect, display: WindowGeometry.Display, primaryHeight: Double, below number: Int?) {
        generation += 1
        let area = WindowGeometry.flipped(display.frame, primaryHeight: primaryHeight)
        let panel = panel ?? {
            let panel = NSPanel(contentRect: area, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            panel.contentView = NSHostingView(rootView: SnapPreviewView(model: model))
            self.panel = panel
            return panel
        }()
        let local = frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        model.title = title
        if !model.visible || panel.frame != area {
            panel.setFrame(area, display: false)
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { model.rect = local }
        } else {
            model.rect = local
        }
        if let number {
            panel.level = .normal
            panel.order(.below, relativeTo: number)
        } else {
            panel.level = .floating
            panel.orderFrontRegardless()
        }
        model.visible = true
    }

    func hide() {
        guard model.visible else { return }
        model.visible = false
        generation += 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
    }
}
