import AppKit
import ApplicationServices
import DockCore
import SwiftUI

// MARK: - Focus Follows Mouse
//
// Rest the pointer on a window and it comes forward, its app with it, in the spirit of
// AutoRaise. Two mouse-moved monitors, one for other apps and one for Atelier's own windows,
// only note where the pointer is; nothing else happens while it moves. Once it has stayed put
// for the delay, one look at the window list and one Accessibility hit test, off the main
// thread, decide whether what lies beneath is an ordinary window of another app. If it is,
// the window is raised with AXRaise and its app activated. Turning it off removes the monitors.
//
// It holds back over the menu bar, the Dock, the desktop, Mission Control, open menus, sheets
// and popovers, full-screen spaces and Atelier's own windows, and while a mouse button or the
// pause key is down. Atelier's click-through panels (the border ring, the dimming shade) are
// looked through, as the pointer itself looks through them.

@MainActor
final class FocusFollowsMouse: ObservableObject {
    static let shared = FocusFollowsMouse()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "ffm.enabled"); apply() } }
    /// How long the pointer must rest before the window under it comes forward, 0.1 to 1 second.
    @Published var delay: Double {
        didSet {
            // Assigning inside didSet does not call it again, so the clamp is stored right here.
            let clamped = FocusFollowsRules.clampDelay(delay)
            if clamped != delay { delay = clamped }
            store.set(delay, forKey: "ffm.delay")
            rest.delay = delay
        }
    }
    /// Holding Control lets the pointer cross windows without raising any of them.
    @Published var pauseWithControl: Bool { didSet { store.set(pauseWithControl, forKey: "ffm.pauseControl") } }
    /// For tests: windows raised since launch, and the app of the last one.
    @Published private(set) var raises = 0
    @Published private(set) var lastApp: String?

    private let store = UserDefaults.standard
    private var monitors: [Any] = []
    private var rest: PointerRest
    /// One timer for the whole feature, moved forward each time a new rest begins, so a moving
    /// pointer costs a date assignment and nothing more.
    private var timer: Timer?
    /// A look is under way off the main thread; a second one waits for the next rest.
    private var looking = false

    var active: Bool { !monitors.isEmpty }

    var diagnostics: String { "ffmOn=\(active) ffmRaises=\(raises) ffmLast=\(lastApp?.replacingOccurrences(of: " ", with: "_") ?? "-")" }

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "ffm.enabled")
        let delay = FocusFollowsRules.clampDelay(d.object(forKey: "ffm.delay") as? Double ?? 0.3)
        self.delay = delay
        pauseWithControl = d.object(forKey: "ffm.pauseControl") as? Bool ?? true
        rest = PointerRest(delay: delay)
    }

    func resume() { if enabled { apply() } }

    private func apply() {
        if enabled {
            guard monitors.isEmpty, AXIsProcessTrusted() else { return }
            let timer = Timer(fire: .distantFuture, interval: 1_000_000, repeats: true) { _ in
                MainActor.assumeIsolated { FocusFollowsMouse.shared.settled() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { _ in
                MainActor.assumeIsolated { FocusFollowsMouse.shared.moved() }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
                MainActor.assumeIsolated { FocusFollowsMouse.shared.moved() }
                return event
            }) { monitors.append(local) }
        } else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors = []
            timer?.invalidate()
            timer = nil
            rest = PointerRest(delay: delay)
        }
        objectWillChange.send()
    }

    /// Runs for every pointer move, so it only notes where the pointer is.
    private func moved() {
        let now = ProcessInfo.processInfo.systemUptime
        guard rest.move(to: NSEvent.mouseLocation, at: now) else { return }
        timer?.fireDate = Date(timeIntervalSinceNow: rest.due - now)
    }

    /// The pointer has been still for the delay.
    private func settled() {
        guard enabled, rest.isRested(at: ProcessInfo.processInfo.systemUptime) else { return }
        // A rest is used once, whatever comes of it: letting go of Control or the mouse button
        // later, without moving, must not suddenly raise something.
        rest.spend()
        guard !paused, !looking, let point = CGEvent(source: nil)?.location else { return }
        let passThrough = Set(NSApp.windows.filter { $0.ignoresMouseEvents && $0.isVisible }.map(\.windowNumber))
        let own = getpid()
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let generation = rest.generation
        // The window the window server would give a click to, looking through every
        // click-through overlay on screen, whoever owns it.
        let hit = NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0)
        looking = true
        Task.detached(priority: .userInitiated) {
            let found = Self.look(at: point, ownPID: own, passThrough: passThrough, frontPID: front, hit: hit)
            await MainActor.run { FocusFollowsMouse.shared.bring(found, generation: generation) }
        }
    }

    private var paused: Bool {
        FocusFollowsRules.isPaused(buttonsDown: NSEvent.pressedMouseButtons,
                                   controlHeld: NSEvent.modifierFlags.contains(.control),
                                   pauseWithControl: pauseWithControl)
    }

    private func bring(_ found: Found?, generation: Int) {
        looking = false
        // The pointer may have moved on, or a button gone down, while the look was under way.
        guard enabled, let found, generation == rest.generation, !paused,
              let app = NSRunningApplication(processIdentifier: found.pid), !app.isTerminated else { return }
        Self.raise(found)
        app.activate()
        raises += 1
        lastApp = app.localizedName
    }

    // MARK: Looking, off the main thread

    /// A window that may be raised, and the app it belongs to.
    struct Found: @unchecked Sendable {
        let window: AXUIElement
        let pid: pid_t
    }

    /// What lies under the pointer, if it is an ordinary window of another app that is not
    /// already in front. Every Accessibility call has a short timeout, so a hung app costs a
    /// quarter of a second at most, and never on the main thread.
    nonisolated private static func look(at point: CGPoint, ownPID: pid_t, passThrough: Set<Int>, frontPID: pid_t?, hit: Int) -> Found? {
        let list = listedWindows()
        guard !FocusFollowsRules.menuOpen(in: list),
              case .window(let listed) = FocusFollowsRules.under(point, in: list, ownPID: ownPID, passThrough: passThrough, hit: hit)
        else { return nil }

        // The hit test asks the app that owns the window, not the whole system, so Atelier's
        // own panels, which the window list has already looked through, cannot answer instead.
        let app = DockAX.application(listed.pid)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success, var element = hit else { return nil }
        var chain: [AXUIElement] = []
        for _ in 0..<24 {
            AXUIElementSetMessagingTimeout(element, 0.25)
            chain.append(element)
            guard let role = DockAX.attribute(element, kAXRoleAttribute) as? String, role != "AXWindow",
                  let parent = DockAX.attribute(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            element = parent as! AXUIElement
        }
        let roles = chain.map { DockAX.attribute($0, kAXRoleAttribute) as? String ?? "" }
        guard let index = FocusFollowsRules.windowIndex(inChain: roles) else { return nil }
        let window = chain[index]

        guard FocusFollowsRules.isRaisable(role: roles[index],
                                           subrole: DockAX.attribute(window, kAXSubroleAttribute) as? String,
                                           minimized: flag(window, kAXMinimizedAttribute),
                                           fullScreen: flag(window, "AXFullScreen")) else { return nil }
        // The window the hit test found must be the one the window list sees on top; a sheet
        // or a child window in between would show up as a different number.
        if let id = DockAX.windowID(AXRef(element: window)), Int(id) != listed.number { return nil }

        // Nothing to do over the window already in front, and nothing at all while the front
        // window fills a space of its own.
        if let frontPID {
            let front = DockAX.application(frontPID)
            if let focused = DockAX.attribute(front, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let focusedWindow = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(focusedWindow, 0.25)
                if flag(focusedWindow, "AXFullScreen") { return nil }
                if frontPID == listed.pid && CFEqual(focusedWindow, window) { return nil }
            }
        }
        return Found(window: window, pid: listed.pid)
    }

    /// On-screen windows, front to back, as the window server has them.
    nonisolated private static func listedWindows() -> [FocusFollowsRules.Listed] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return info.compactMap { entry in
            guard let number = entry[kCGWindowNumber as String] as? Int,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
            return FocusFollowsRules.Listed(number: number, pid: pid, layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                                            alpha: entry[kCGWindowAlpha as String] as? Double ?? 1, bounds: rect)
        }
    }

    nonisolated private static func flag(_ element: AXUIElement, _ name: String) -> Bool {
        (DockAX.attribute(element, name) as? Bool) == true
    }

    /// Makes the window its app's main window and puts it on top. The app is activated after,
    /// on the main thread; being main already, this window is the one that takes the keyboard.
    nonisolated private static func raise(_ found: Found) {
        AXUIElementSetAttributeValue(found.window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(found.window, kAXRaiseAction as CFString)
        // Activation from a background app can be declined; asking through Accessibility as
        // well brings the app forward either way.
        AXUIElementSetAttributeValue(DockAX.application(found.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }
}

// MARK: - Card and stage

struct FocusFollowsMouseCard: View {
    @ObservedObject private var ffm = FocusFollowsMouse.shared
    private var trusted: Bool { AXIsProcessTrusted() }

    var body: some View {
        HeroCard("Focus Follows Mouse", pitch: "Rest the pointer on a window and it comes forward. No click.",
                 isOn: $ffm.enabled, hue: DS.Spectrum.windows,
                 readout: String(format: "%.1f s", ffm.delay), readoutCaption: "Delay",
                 preview: .overlay("engine.focusFollows", "Focus Follows Mouse", isOn: ffm.enabled) { size in
                     FocusFollowsPreview(size: size)
                 }) {
            LivePlate { size, since in FocusFollowsPlate(size: size, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HeroSlider(title: "Delay", value: $ffm.delay, range: 0.1...1.0, hue: DS.Spectrum.windows) {
                    String(format: "%.1f s", $0)
                }
                SettingRow(title: "Hold ⌃ to Pause", detail: "Keep Control down to cross windows without raising them.",
                           density: .compact) {
                    LuxSwitch(isOn: $ffm.pauseWithControl, label: "Hold Control to Pause", tint: DS.Spectrum.windows)
                }
                Text("The menu bar, Dock, desktop, menus, sheets and full-screen spaces are left alone.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!trusted)
    }
}

/// The hero plate: two overlapping windows and a pointer resting on the one behind. On hover
/// the pointer travels in, a ring fills for the delay, and the back window comes forward.
struct FocusFollowsPlate: View {
    @ObservedObject private var ffm = FocusFollowsMouse.shared
    let size: CGSize
    let since: Date?

    var body: some View {
        let cycle = 1.2 + ffm.delay + 1.6
        // At rest: the pointer has arrived and the ring is half full.
        PlateClock(since: since, rest: 1.2 + ffm.delay / 2) { time in
            scene(time.truncatingRemainder(dividingBy: cycle))
        }
    }

    private func scene(_ t: Double) -> some View {
        let w = min(size.width * 0.3, 176), h = min(size.height * 0.56, 82)
        let travel = min(t / 1.2, 1)
        let eased = travel * travel * (3 - 2 * travel)
        let waited = min(max((t - 1.2) / max(ffm.delay, 0.1), 0), 1)
        let risen = min(max((t - 1.2 - ffm.delay) / 0.25, 0), 1)
        let back = CGPoint(x: size.width * 0.5 - w * 0.32, y: size.height * 0.5 - h * 0.16)
        let front = CGPoint(x: size.width * 0.5 + w * 0.32, y: size.height * 0.5 + h * 0.16)
        let start = CGPoint(x: front.x + w * 0.2, y: front.y + h * 0.2)
        let end = CGPoint(x: back.x - w * 0.3, y: back.y - h * 0.22)
        return ZStack {
            PlateWindow(tint: Color(red: 0.98, green: 0.62, blue: 0.4), focused: risen > 0.5, corner: 7)
                .frame(width: w, height: h)
                .scaleEffect(0.97 + 0.03 * risen)
                .position(back)
                .zIndex(risen > 0.5 ? 2 : 0)
            PlateWindow(tint: DS.Spectrum.windows, focused: risen <= 0.5, corner: 7)
                .frame(width: w, height: h)
                .position(front)
                .zIndex(1)
            pointer(waited: waited, risen: risen)
                .position(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
                .zIndex(3)
        }
        .frame(width: size.width, height: size.height)
    }

    private func pointer(waited: Double, risen: Double) -> some View {
        ZStack(alignment: .topLeading) {
            Circle().trim(from: 0, to: waited)
                .stroke(DS.Spectrum.windows.opacity(1 - risen), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 26, height: 26)
                .offset(x: -9, y: -9)
            Image(systemName: "cursorarrow").font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
        }
        .frame(width: 20, height: 20, alignment: .topLeading)
    }
}

/// Two overlapping windows. The pointer drifts onto the one behind, rests there while a small
/// ring fills for the delay, and that window rises to the front. Then it all starts again.
struct FocusFollowsPreview: View {
    @ObservedObject private var ffm = FocusFollowsMouse.shared
    let size: CGSize

    var body: some View {
        let w = size.width * 0.4
        let cycle = 1.6 + ffm.delay + 1.4
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            // 0–1.2 s the pointer travels, then it waits out the delay, then the window rises.
            let travel = min(t / 1.2, 1)
            let eased = travel * travel * (3 - 2 * travel)
            let waited = min(max((t - 1.2) / max(ffm.delay, 0.1), 0), 1)
            let risen = min(max((t - 1.2 - ffm.delay) / 0.25, 0), 1)
            let start = CGPoint(x: size.width * 0.6, y: size.height * 0.62)
            let end = CGPoint(x: size.width * 0.3, y: size.height * 0.3)
            ZStack {
                MockWindow(width: w, title: "Notes") { NotesContent(width: w).frame(height: w * 0.56) }
                    .scaleEffect(0.97 + 0.03 * risen)
                    .offset(x: -size.width * 0.12, y: -size.height * 0.08)
                    .zIndex(risen > 0 ? 2 : 0)
                MockWindow(width: w, title: "Safari") { BrowserContent(width: w).frame(height: w * 0.56) }
                    .offset(x: size.width * 0.1, y: size.height * 0.07)
                    .zIndex(1)
                    .opacity(1 - 0.15 * risen)
                pointer(waited: waited, risen: risen)
                    .position(x: start.x + (end.x - start.x) * eased, y: start.y + (end.y - start.y) * eased)
                    .zIndex(3)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func pointer(waited: Double, risen: Double) -> some View {
        let s = size.width * 0.026
        return ZStack(alignment: .topLeading) {
            Circle().trim(from: 0, to: waited)
                .stroke(.white.opacity(0.85 * (1 - risen)), style: StrokeStyle(lineWidth: s * 0.16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: s * 1.6, height: s * 1.6)
                .offset(x: -s * 0.55, y: -s * 0.55)
            Image(systemName: "cursorarrow").font(.system(size: s, weight: .bold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        }
    }
}
