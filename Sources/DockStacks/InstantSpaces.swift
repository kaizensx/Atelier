import AppKit
import SwiftUI
import DockCore

// MARK: - Instant Spaces
//
// Two things a stock Mac cannot do. Switch desktops with no slide at all: Atelier posts the
// Dock's own three-finger swipe with a huge fling and almost no travel, so the switch commits
// with nothing left to animate (~35 ms on macOS 27.3, against about a second for
// Control-Arrow). And send a window to another desktop from the keyboard, the menu bar or a
// drag, through the window-management bridge SkyLight keeps for itself (as yabai does with
// SIP on), or on macOS 14 through the older calls that still worked there. Both are checked
// at run time: if the swipe does not land, Atelier says so and falls back to Control-Arrow; a
// send method that does not move the window is dropped for the next, and with none left,
// sending says it is unavailable. Before macOS 27 the swipe is the bare Dock-control event
// InstantSpaceSwitcher and yabai post there; 27 needs the IOHID payload and a companion.
//
// Shortcuts come from Atelier's own event tap, so they work even with Mission Control's
// "Switch to Desktop N" shortcuts turned off, and the tap swallows them so Mission Control's
// slow version never runs as well.

/// Read by the tap's C callback, which runs outside any actor.
private nonisolated(unsafe) var spacesTap: CFMachPort?
private nonisolated(unsafe) var spacesChord = SpaceChord.control
/// Keys whose key-down was swallowed, so their key-up goes too.
private nonisolated(unsafe) var spacesHeld = Set<Int64>()

private func spacesCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                            _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let spacesTap { CGEvent.tapEnable(tap: spacesTap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let code = event.getIntegerValueField(.keyboardEventKeycode)
    if type == .keyUp {
        return spacesHeld.remove(code) == nil ? Unmanaged.passUnretained(event) : nil
    }
    guard type == .keyDown, let action = SpaceHotkey.match(keycode: code, flags: event.flags.rawValue, chord: spacesChord) else {
        return Unmanaged.passUnretained(event)
    }
    spacesHeld.insert(code)
    // A held key repeats; one jump per press is what anyone means.
    if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
        DispatchQueue.main.async { MainActor.assumeIsolated { InstantSpaces.shared.perform(action) } }
    }
    return nil
}

enum SpacesProbe: String {
    case untested, works, fallback
}

/// A window as the Spaces card draws it: where it is, on which desktop, and whose it is.
struct SpaceWindow: Identifiable, Equatable {
    let id: UInt32
    let pid: pid_t
    let app: String
    let title: String
    let frame: CGRect      // global, top-left origin (Quartz)
    let space: Int
}

@MainActor
final class InstantSpaces: ObservableObject {
    static let shared = InstantSpaces()

    @Published var instant: Bool {
        didSet {
            store.set(instant, forKey: "spaces.instant")
            // Switching it back on is a request to try again, e.g. after granting Accessibility.
            if instant, probe == .fallback { probe = .untested; notice = nil }
        }
    }
    @Published var hotkeys: Bool { didSet { store.set(hotkeys, forKey: "spaces.hotkeys"); applyTap() } }
    @Published var chord: SpaceChord {
        didSet { store.set(chord.rawValue, forKey: "spaces.chord"); spacesChord = chord }
    }
    @Published private(set) var probe = SpacesProbe.untested
    @Published private(set) var lastMs: Double?
    @Published private(set) var jumps = 0
    @Published private(set) var sends = 0
    @Published private(set) var windows: [SpaceWindow] = []
    @Published private(set) var notice: String?

    /// The ways this Mac can send a window, best first; a method that is tried and does not
    /// move the window is dropped for the rest of the session (see `send(window:toSpace:)`).
    private var sendMethods = SpacesEngine.sendMethods
    var canSend: Bool { !sendMethods.isEmpty }
    /// Sending, as this Mac can do it: the menu, the card and the shortcuts all ask this.
    var sendAvailability: FeatureAvailability {
        canSend ? .available : .unavailable("Sending windows to a desktop isn’t possible on this version of macOS")
    }

    /// The Control-Arrow fallback only exists while Mission Control's own shortcuts are on.
    var fallbackAvailability: FeatureAvailability {
        let arrows = SpacesEngine.arrowShortcuts
        return arrows.left && arrows.right ? .available
            : .limited("Mission Control’s Control-Arrow shortcuts are off, so there is no fallback if a switch doesn’t take")
    }

    var tapActive: Bool { spacesTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    var diagnostics: String {
        InstantSpacesReport.line(instant: instant, jumps: jumps, sends: sends, probe: probe.rawValue,
                                 send: sendMethods.first?.rawValue ?? "unavailable", hotkeys: hotkeys, tap: tapActive, lastMs: lastMs)
    }

    private let store = UserDefaults.standard
    private var source: CFRunLoopSource?
    /// While swipes are still landing, the window server reports a stale Space; trust our own
    /// prediction for a moment instead, or a quick second jump would overshoot.
    private var predicted: Int?
    private var lastPost = Date.distantPast
    private var generation = 0

    private init() {
        instant = UserDefaults.standard.object(forKey: "spaces.instant") as? Bool ?? true
        hotkeys = UserDefaults.standard.bool(forKey: "spaces.hotkeys")
        chord = SpaceChord(rawValue: UserDefaults.standard.string(forKey: "spaces.chord") ?? "") ?? .control
        spacesChord = chord
    }

    /// Called from `SpacesIndicator.resume()`, once at launch.
    func resume() { applyTap() }

    // MARK: Switching

    /// Goes to a desktop by its ManagedSpaceID: instantly when that is on and working,
    /// otherwise with Control-Arrow, macOS's own (animated) way. Both act on the display under
    /// the pointer, so with separate Spaces per display a desktop elsewhere is not reachable.
    func go(toSpace target: Int) {
        let all = SpacesEngine.displays()
        let display: ManagedDisplay
        switch SpaceWalk.route(to: target, in: all, cursorDisplay: SpacesEngine.cursorDisplayIdentifier()) {
        case .display(let index): display = all[index]
        case .otherDisplay:
            notice = "That desktop is on another display. Move the pointer to that display, then try again."
            return
        case .unknown: return
        }
        let order = display.spaces.map(\.id)
        let inFlight = Date().timeIntervalSince(lastPost) < 1
        let from = (inFlight ? predicted : nil) ?? display.current
        guard let steps = SpaceWalk.steps(in: order, from: from, to: target), steps != 0 else { return }
        guard instant, probe != .fallback, SpacesEngine.canPost, SpacesEngine.jump(steps: steps) else {
            slide(steps)
            return
        }
        jumps += 1
        predicted = target
        lastPost = Date()
        generation += 1
        confirm(target, generation: generation, started: Date())
    }

    /// Desktop N (1-based, desktops only, in Mission Control's order) of the display under
    /// the pointer when each display has its own Spaces, else of the one shared list.
    func go(toDesktop number: Int) {
        guard let desktops = SpaceWalk.displayForShortcuts(SpacesEngine.displays(),
                                                           cursorDisplay: SpacesEngine.cursorDisplayIdentifier())?.desktops,
              desktops.indices.contains(number - 1) else { return }
        go(toSpace: desktops[number - 1].id)
    }

    /// The display that holds a space right now, for checking where a switch landed.
    private func display(holding space: Int) -> ManagedDisplay? {
        SpacesEngine.displays().first { $0.spaces.contains { $0.id == space } }
    }

    /// Watches the window server until the jump lands. The first time it does not, instant
    /// switching is marked as not working on this Mac and the jump is finished the slow way.
    private func confirm(_ target: Int, generation: Int, started: Date) {
        let elapsed = Date().timeIntervalSince(started)
        if display(holding: target)?.current == target {
            lastMs = elapsed * 1000
            if probe != .works { probe = .works }
            return
        }
        guard elapsed < 0.6 else {
            guard generation == self.generation, probe != .works else { return }
            probe = .fallback
            notice = "Instant switching didn’t take on this Mac, so Atelier uses Control-Arrow."
            if let display = display(holding: target),
               let steps = SpaceWalk.steps(in: display.spaces.map(\.id), from: display.current, to: target) { slide(steps) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { self.confirm(target, generation: generation, started: started) }
    }

    /// Control-Arrow, one press per step, spaced so each slide finishes before the next. It
    /// only works while Mission Control still has its "Move left/right a space" shortcuts.
    private func slide(_ steps: Int) {
        let shortcuts = SpacesEngine.arrowShortcuts
        guard steps > 0 ? shortcuts.right : shortcuts.left else {
            notice = "Turn on “Move left a space” and “Move right a space” in System Settings › Keyboard › Keyboard Shortcuts › Mission Control, so Atelier can fall back to them."
            return
        }
        for step in 0..<abs(steps) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.45) { SpacesEngine.controlArrow(right: steps > 0) }
        }
    }

    // MARK: Sending

    /// Sends the front app's focused window to desktop N, numbered as the shortcuts number them.
    func sendFocused(toDesktop number: Int) {
        guard let desktops = SpaceWalk.displayForShortcuts(SpacesEngine.displays(),
                                                           cursorDisplay: SpacesEngine.cursorDisplayIdentifier())?.desktops,
              desktops.indices.contains(number - 1) else { return }
        sendFocused(toSpace: desktops[number - 1].id)
    }

    /// Sends the front app's focused window to a desktop by its ManagedSpaceID.
    func sendFocused(toSpace space: Int) {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid(),
              let window = SpacesEngine.focusedWindow(of: app.processIdentifier) else {
            notice = "No window to send: click the window first."
            return
        }
        send(window: window, toSpace: space)
    }

    func send(window: UInt32, toSpace space: Int) {
        guard let method = sendMethods.first else {
            notice = "Sending windows isn’t available on this version of macOS."
            return
        }
        guard SpacesEngine.spaces(ofWindow: window) != [space] else { return }
        guard SpacesEngine.move(windows: [window], toSpace: space, using: method) else {
            dropSendMethod(method, retrying: window, toSpace: space)
            return
        }
        // Every method answers before the move lands, and a refused one says nothing at all,
        // so the window server is asked where the window went. One that did not move it is
        // dropped and the next is tried, so an older release falls through to what works.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if SpacesEngine.spaces(ofWindow: window).contains(space) {
                self.sends += 1
                self.notice = nil
                self.refreshWindows()
            } else {
                self.dropSendMethod(method, retrying: window, toSpace: space)
            }
        }
    }

    private func dropSendMethod(_ method: SpaceSendMethod, retrying window: UInt32, toSpace space: Int) {
        objectWillChange.send()
        sendMethods.removeAll { $0 == method }
        if sendMethods.isEmpty {
            notice = "This version of macOS didn’t let Atelier move the window."
        } else {
            send(window: window, toSpace: space)
        }
    }

    func perform(_ action: SpaceHotkey) {
        switch action {
        case .jump(let n): go(toDesktop: n)
        case .send(let n): sendFocused(toDesktop: n)
        }
    }

    // MARK: Windows per desktop, for the card

    /// Every ordinary window on every desktop, with the desktop it lives on. Sticky windows
    /// (on all desktops) and Atelier's own are left out: there is nothing to send.
    func refreshWindows() {
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let own = getpid()
        var found: [SpaceWindow] = []
        for entry in info where found.count < 80 {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != own,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.width >= 80, frame.height >= 60 else { continue }
            let app = entry[kCGWindowOwnerName as String] as? String ?? ""
            guard !["Window Server", "Dock", "Control Center", "Notification Center"].contains(app) else { continue }
            let spaces = SpacesEngine.spaces(ofWindow: id)
            guard spaces.count == 1 else { continue }
            found.append(SpaceWindow(id: id, pid: pid, app: app, title: entry[kCGWindowName as String] as? String ?? "",
                                     frame: frame, space: spaces[0]))
        }
        if found != windows { windows = found }
    }

    // MARK: Shortcuts

    private func applyTap() {
        if hotkeys {
            guard spacesTap == nil else { return }
            guard AXIsProcessTrusted() else {
                notice = "Desktop shortcuts need Accessibility."
                return
            }
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
            // Appended at the tail, so Hyper Key's tap (at the head) has already added ⌃⌥⇧⌘ by
            // the time a Hyper chord gets here, whichever of the two was switched on first.
            if let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: spacesCallback, userInfo: nil) {
                spacesTap = tap
                let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
                CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
                self.source = source
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        } else if let tap = spacesTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
            CFMachPortInvalidate(tap)
            spacesTap = nil
            source = nil
            spacesHeld.removeAll()
        }
        objectWillChange.send()
    }

    // MARK: URL hook

    /// atelier://spaces?go=N · ?send=N (focused window to desktop N) · ?instant=0|1 · ?refresh
    /// N is the 1-based desktop number. Used by test/spacetest --app.
    func handle(_ url: URL) {
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            switch item.name {
            case "go": item.value.flatMap(Int.init).map(go(toDesktop:))
            case "send": item.value.flatMap(Int.init).map(sendFocused(toDesktop:))
            case "instant": instant = item.value == "1"
            case "refresh": refreshWindows()
            default: break
            }
        }
    }
}
