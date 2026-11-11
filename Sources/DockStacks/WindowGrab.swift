import AppKit
import DockCore
import QuartzCore
import SwiftUI

// MARK: - Move & Resize Anywhere
//
// Hold a chord of modifier keys and drag anywhere inside a window to move it, or drag with
// the right button to resize it from the corner nearest the grab, the way Linux desktops and
// Easy Move+Resize work. A mouse tap sees each click before apps do. A click with the chord
// held is swallowed at once and the window under it is looked up a moment later on the main
// actor, so the tap callback never waits on Accessibility. While the button is down, drags
// only record where the pointer is; a display link then writes the window's frame at most
// once per frame, always from the newest pointer, so a slow app never builds up a queue of
// stale moves. A click that finds no window it may move (the desktop, the Dock, a full-screen
// window, Atelier itself) is replayed unchanged. Turning it off removes the tap.

private nonisolated(unsafe) var grabTap: CFMachPort?
/// The chord's flags, read by the tap so a plain click never reaches the main actor.
private nonisolated(unsafe) var grabChord = GrabGeometry.Chord.controlCommand
/// Whether a grab or a replayed click is in progress, so its drags and mouse-up are routed.
private nonisolated(unsafe) var grabBusy = false
/// Stamped on clicks Atelier replays, so the tap does not catch them again.
private let grabMark: Int64 = 0x41544752

private func grabCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                          _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        TapRevoke.disabled(type)
        if let grabTap { CGEvent.tapEnable(tap: grabTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard event.getIntegerValueField(.eventSourceUserData) != grabMark else { return Unmanaged.passUnretained(event) }
    // The cheap test first: most clicks carry no chord and nothing is being dragged.
    let starts = type == .leftMouseDown || type == .rightMouseDown
    guard grabBusy || (starts && grabChord.isHeld(in: event.flags)) else { return Unmanaged.passUnretained(event) }
    // The tap's source is on the main run loop, so this is the main thread and the event
    // never leaves it.
    nonisolated(unsafe) let event = event
    let swallow = MainActor.assumeIsolated { WindowGrab.shared.handle(type, event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}

@MainActor
final class WindowGrab: ObservableObject {
    static let shared = WindowGrab()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "grab.enabled"); apply() } }
    @Published var chord: GrabGeometry.Chord {
        didSet { store.set(chord.rawValue, forKey: "grab.chord"); grabChord = chord }
    }
    @Published var raiseOnGrab: Bool { didSet { store.set(raiseOnGrab, forKey: "grab.raise") } }

    /// For tests: grabs that moved or resized a window since launch, and frames written.
    private(set) var moves = 0
    private(set) var resizes = 0
    private(set) var frames = 0
    var tapActive: Bool { grabTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    var diagnostics: String { "grabTap=\(tapActive) grabMoves=\(moves) grabResizes=\(resizes) grabFrames=\(frames)" }
    /// True while a window follows the pointer. Snap Zones poll the hardware button, which
    /// stays down during a grab, and may read this to stay out of the way.
    var isGrabbing: Bool { session?.window != nil && session?.released == false }

    private let store = UserDefaults.standard
    private var source: CFRunLoopSource?
    private var link: CADisplayLink?
    private let ticker = GrabTicker()
    private var session: Session?
    /// The button of a click that was replayed because no window could be grabbed. Its drags
    /// and mouse-up go straight through to whatever is under the pointer.
    private var passthrough: CGMouseButton?
    private lazy var systemWide: AXUIElement = {
        let element = AXUIElementCreateSystemWide()
        // Hit-testing waits on the app under the pointer; one that has stopped answering
        // should cost a tenth of a second, not the six-second default.
        AXUIElementSetMessagingTimeout(element, 0.1)
        return element
    }()

    private struct Session {
        let button: CGMouseButton
        let resizing: Bool
        /// The click as it came in, kept to replay it if there is nothing to grab.
        let down: CGEvent
        let anchor: CGPoint
        var pointer: CGPoint
        var applied: CGPoint?
        var resolved = false
        var window: AXUIElement?
        var start = CGRect.zero
        var corner = GrabGeometry.Corner(right: true, bottom: true)
        /// The smallest size the app has accepted so far; grows when it refuses one.
        var minimum = CGSize(width: 120, height: 60)
        /// The chord was let go: the window stays where it is until the button comes up.
        var released = false
        var changed = false
    }

    private init() {
        enabled = UserDefaults.standard.bool(forKey: "grab.enabled")
        chord = UserDefaults.standard.string(forKey: "grab.chord").flatMap(GrabGeometry.Chord.init) ?? .controlCommand
        raiseOnGrab = UserDefaults.standard.object(forKey: "grab.raise") as? Bool ?? true
        grabChord = chord
    }

    func resume() { if enabled { apply() } }

    /// Accessibility just arrived: a tap made before it went away is made again, and one that
    /// was waiting for it starts.
    func rearm() {
        guard enabled else { return }
        removeTap()
        apply()
    }

    private func apply() {
        if enabled {
            guard grabTap == nil, AXIsProcessTrusted() else { objectWillChange.send(); return }
            let types: [CGEventType] = [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                                        .rightMouseDown, .rightMouseDragged, .rightMouseUp, .flagsChanged]
            let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1) << $1.rawValue }
            guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                              eventsOfInterest: mask, callback: grabCallback, userInfo: nil) else { TapRevoke.creationFailed(); return }
            grabTap = tap
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            self.source = source
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            removeTap()
        }
        objectWillChange.send()
    }

    private func removeTap() {
        guard let tap = grabTap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        grabTap = nil
        source = nil
        stopLink()
        session = nil
        passthrough = nil
        grabBusy = false
    }

    // MARK: Events

    /// Called from the tap for every chord click and, while busy, every mouse event and
    /// modifier change. Returns true to swallow the event. Does no Accessibility work.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let location = event.location
        switch type {
        case .leftMouseDown, .rightMouseDown:
            // A second button during a grab, or a fresh click during a replay, is not ours.
            guard session == nil, passthrough == nil, let copy = event.copy() else { return false }
            let button: CGMouseButton = type == .leftMouseDown ? .left : .right
            session = Session(button: button, resizing: button == .right, down: copy, anchor: location, pointer: location)
            grabBusy = true
            // Looked up on the next turn of the run loop, so the tap returns straight away.
            DispatchQueue.main.async { MainActor.assumeIsolated { WindowGrab.shared.resolve() } }
            return true
        case .leftMouseDragged, .rightMouseDragged:
            let button: CGMouseButton = type == .leftMouseDragged ? .left : .right
            if passthrough == button { return false }
            guard session?.button == button else { return false }
            session?.pointer = location
            if session?.resolved == true, session?.window != nil, session?.released == false { startLink() }
            return true
        case .leftMouseUp, .rightMouseUp:
            let button: CGMouseButton = type == .leftMouseUp ? .left : .right
            if passthrough == button {
                passthrough = nil
                grabBusy = session != nil
                return false
            }
            guard session?.button == button else { return false }
            session?.pointer = location
            finish()
            return true
        case .flagsChanged:
            // Letting go of the chord drops the window where it is, even with the button down.
            if let current = session, !current.released, !chord.isHeld(in: event.flags) {
                if current.resolved, current.window != nil { step() }
                session?.released = true
                stopLink()
            }
            return false
        default:
            return false
        }
    }

    /// Finds the window under the click. With none that may be moved, the click is replayed
    /// so the app or the desktop gets it after all.
    private func resolve() {
        guard var current = session, !current.resolved else { return }
        current.resolved = true
        if let window = grabbableWindow(at: current.anchor), let frame = frame(of: window) {
            AXUIElementSetMessagingTimeout(window, 0.1)
            current.window = window
            current.start = frame
            current.corner = GrabGeometry.corner(for: current.anchor, in: frame)
            session = current
            if raiseOnGrab { raise(window) }
            if current.pointer != current.anchor, !current.released { startLink() }
        } else {
            session = nil
            current.down.setIntegerValueField(.eventSourceUserData, value: grabMark)
            current.down.post(tap: .cghidEventTap)
            passthrough = current.button
            grabBusy = true
        }
    }

    /// The mouse came up: write the last position, count the grab and stand down.
    private func finish() {
        guard let current = session else { return }
        if !current.resolved {
            // The click was quicker than the lookup. Settle it now, in order: a replayed
            // click must come up after it goes down.
            resolve()
            if passthrough == current.button {
                replayUp(current)
                passthrough = nil
                grabBusy = false
                return
            }
        }
        if session?.released == false { step() }
        if session?.changed == true {
            if current.resizing { resizes += 1 } else { moves += 1 }
        }
        stopLink()
        session = nil
        grabBusy = passthrough != nil
    }

    private func replayUp(_ current: Session) {
        let type: CGEventType = current.button == .left ? .leftMouseUp : .rightMouseUp
        guard let up = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: current.pointer,
                               mouseButton: current.button) else { return }
        up.flags = current.down.flags
        up.setIntegerValueField(.eventSourceUserData, value: grabMark)
        up.post(tap: .cghidEventTap)
    }

    // MARK: Moving

    private func startLink() {
        if let link { link.isPaused = false; return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let next = screen?.displayLink(target: ticker, selector: #selector(GrabTicker.tick(_:))) else {
            step()
            return
        }
        next.add(to: .main, forMode: .common)
        link = next
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    /// One frame: the window follows the newest pointer. Nothing is written when the pointer
    /// has not moved since the last frame, so an idle hold costs nothing.
    fileprivate func step() {
        guard var current = session, let window = current.window, !current.released,
              current.pointer != current.applied else {
            link?.isPaused = true
            return
        }
        let delta = CGVector(dx: current.pointer.x - current.anchor.x, dy: current.pointer.y - current.anchor.y)
        current.applied = current.pointer
        if current.resizing {
            let target = GrabGeometry.resized(current.start, corner: current.corner, by: delta, minimum: current.minimum)
            set(window, size: target.size)
            // The bottom-right corner keeps its origin whatever size the app takes. Any other
            // corner moves the origin, which must follow the size the app really accepted.
            if current.corner.right && current.corner.bottom {
                // Nothing to read back.
            } else {
                let got = size(of: window) ?? target.size
                current.minimum = GrabGeometry.learnMinimum(current.minimum, asked: target.size, got: got)
                set(window, origin: GrabGeometry.anchoredOrigin(current.start, corner: current.corner, size: got))
            }
        } else {
            set(window, origin: GrabGeometry.moved(current.start, by: delta).origin)
        }
        current.changed = true
        frames += 1
        session = current
    }

    // MARK: Accessibility

    /// The standard window under `point`, unless it belongs to Atelier or fills its own Space.
    private func grabbableWindow(at point: CGPoint) -> AXUIElement? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        // Most elements name their window directly; walking up the parents covers the rest.
        if let window = value(element, kAXWindowAttribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
            element = window as! AXUIElement
        } else {
            for _ in 0..<32 {
                if (value(element, kAXRoleAttribute) as? String) == kAXWindowRole { break }
                guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
                element = parent as! AXUIElement
            }
        }
        guard (value(element, kAXRoleAttribute) as? String) == kAXWindowRole,
              (value(element, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
              (value(element, "AXFullScreen") as? Bool) != true else { return nil }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable) == .success,
              settable.boolValue else { return nil }
        return element
    }

    private func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success ? raw : nil
    }

    private func axValue<T>(_ element: AXUIElement, _ attribute: String, _ type: AXValueType, _ empty: T) -> T? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var result = empty
        return AXValueGetValue(raw as! AXValue, type, &result) ? result : nil
    }

    private func frame(of window: AXUIElement) -> CGRect? {
        guard let origin = axValue(window, kAXPositionAttribute, .cgPoint, CGPoint.zero),
              let size = size(of: window) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private func size(of window: AXUIElement) -> CGSize? { axValue(window, kAXSizeAttribute, .cgSize, CGSize.zero) }

    private func set(_ window: AXUIElement, origin: CGPoint) {
        var point = origin
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private func set(_ window: AXUIElement, size: CGSize) {
        var dimensions = size
        guard let value = AXValueCreate(.cgSize, &dimensions) else { return }
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
    }

    /// Brings the window to the front of its app and the app to the front of the others, as
    /// an ordinary click on the window would have done.
    private func raise(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid), !app.isActive else { return }
        app.activate()
    }
}

/// The display link's target. CADisplayLink wants an Objective-C selector, and the link runs
/// on the main run loop, so the call lands on the main actor.
private final class GrabTicker: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated { WindowGrab.shared.step() }
    }
}

// MARK: - Card

struct WindowGrabCard: View {
    @ObservedObject private var grab = WindowGrab.shared
    /// False only from offline renders; live, the row below follows the permission itself.
    var trusted = true

    var body: some View {
        HeroCard("Move & Resize Anywhere",
                 pitch: "Hold \(grab.chord.symbols) and drag anywhere in a window. Right-drag resizes it.",
                 isOn: $grab.enabled, hue: DS.Spectrum.windows,
                 readout: grab.chord.symbols, readoutCaption: "Keys",
                 preview: .overlay("engine.grab", "Move & Resize Anywhere", isOn: grab.enabled) { size in
                     WindowGrabPreview(size: size, chord: grab.chord.symbols)
                 }) {
            LivePlate { size, since in WindowGrabPlate(size: size, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                NeedsAccessRow(reason: "To grab the window under the pointer.", previewTrusted: trusted ? nil : false)
                HStack(spacing: 12) {
                    Text("Keys").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 60, alignment: .leading)
                    Segments(selection: $grab.chord, options: GrabGeometry.Chord.allCases.map { ($0, $0.symbols) })
                }
                SettingRow(title: "Raise When Grabbed", detail: "Bring the window and its app forward as you grab it.",
                           density: .compact) {
                    LuxSwitch(isOn: $grab.raiseOnGrab, label: "Raise When Grabbed", tint: DS.Spectrum.windows)
                }
                Text("Full-screen windows and Atelier’s own are left alone. A click with nothing to grab goes through.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The hero plate: a window at rest beside the ghost of where it was. On hover it is carried
/// along an arc by the hand, then pulled out from its corner and let go. Four seconds a loop.
struct WindowGrabPlate: View {
    let size: CGSize
    let since: Date?

    var body: some View {
        // At rest it is caught mid-carry, a window away from its outline.
        PlateClock(since: since, rest: 1) { time in scene(time) }
    }

    private func scene(_ time: Double) -> some View {
        let t = time.truncatingRemainder(dividingBy: 4) / 4
        let moving = t < 0.5
        let phase = moving ? t / 0.5 : (t - 0.5) / 0.5
        let ease = 0.5 - cos(phase * .pi * 2) / 2
        let w = min(size.width * 0.3, 180), h = min(size.height * 0.5, 74)
        let shift = moving ? CGSize(width: ease * size.width * 0.16, height: -sin(phase * .pi) * 14) : .zero
        let grow = moving ? 0 : ease
        let width = w * (1 + grow * 0.3), height = h * (1 + grow * 0.3)
        let origin = CGPoint(x: size.width * 0.36 - w / 2, y: size.height * 0.5 - h / 2)
        return ZStack(alignment: .topLeading) {
            // Where the window started: a dashed outline, so the move reads as a move.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: w, height: h)
                .offset(x: origin.x, y: origin.y)
            ZStack(alignment: .topLeading) {
                PlateWindow(tint: DS.Spectrum.windows, focused: true, corner: 7)
                    .frame(width: width, height: height)
                Image(systemName: moving ? "hand.raised.fill" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .position(moving ? CGPoint(x: width * 0.5, y: height * 0.55) : CGPoint(x: width - 4, y: height - 4))
                    .frame(width: width, height: height, alignment: .topLeading)
            }
            .offset(x: origin.x + shift.width, y: origin.y + shift.height)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// A window that slides with a grabbing hand while the chord chip shows the keys held, then
/// grows from its bottom-right corner. One loop takes four seconds.
struct WindowGrabPreview: View {
    let size: CGSize
    let chord: String

    var body: some View {
        let w = size.width * 0.36
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4) / 4
            // First half: move along a gentle arc and back. Second half: pull the corner out and back.
            let moving = t < 0.5
            let phase = moving ? t / 0.5 : (t - 0.5) / 0.5
            let ease = 0.5 - cos(phase * .pi * 2) / 2
            let shift = moving ? CGSize(width: ease * w * 0.45, height: -sin(phase * .pi) * w * 0.08 + ease * w * 0.06) : .zero
            let grow = moving ? 0 : ease
            let width = w * (1 + grow * 0.35)
            let height = w * 0.56 * (1 + grow * 0.3)
            ZStack(alignment: .topLeading) {
                MockWindow(width: width, title: "Notes") {
                    VStack(alignment: .leading, spacing: w * 0.025) {
                        ForEach(0..<5, id: \.self) { line in
                            Capsule().fill(.white.opacity(0.14))
                                .frame(width: width * (line == 0 ? 0.45 : 0.82 - Double(line % 3) * 0.12), height: w * 0.022)
                        }
                    }
                    .padding(w * 0.04)
                    .frame(width: width, height: height - w * 0.06, alignment: .topLeading)
                }
                Image(systemName: moving ? "hand.raised.fill" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: w * 0.07, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, y: 2)
                    .position(moving ? CGPoint(x: width * 0.5, y: height * 0.45)
                                     : CGPoint(x: width - w * 0.03, y: height - w * 0.03))
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .offset(shift)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottom) {
                HStack(spacing: w * 0.02) {
                    Text(chord).font(.system(size: w * 0.05, weight: .semibold)).monospaced()
                    Text(moving ? "Drag to move" : "Right-drag to resize").font(.system(size: w * 0.04, weight: .medium)).opacity(0.8)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, w * 0.04).padding(.vertical, w * 0.018)
                .background(.black.opacity(0.45), in: .capsule)
                .padding(.bottom, size.height * 0.1)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
