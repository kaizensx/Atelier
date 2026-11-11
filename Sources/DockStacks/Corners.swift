import AppKit
import Carbon.HIToolbox
import DockCore
import SwiftUI

/// What a hot spot does. Only actions with a public way in are here: Notification Centre
/// and Do Not Disturb have none, so they stay with macOS hot corners and Shortcuts.
enum CornerAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case none
    case orbit, command, toggleOwnDock, toggleWidgets, focusLight
    case showDesktop, missionControl, appExpose, apps, lockScreen, sleepDisplay, screenSaver, screenshot
    case layout, shuffle, quitFront, hideOthers
    case annotate, findCursor, colourPicker
    case open, shortcut, plugin

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable {
        case atelier = "Atelier", system = "System", windows = "Windows", tools = "Tools", launch = "Open & Run"
        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .none, .orbit, .command, .toggleOwnDock, .toggleWidgets, .focusLight: .atelier
        case .showDesktop, .missionControl, .appExpose, .apps, .lockScreen, .sleepDisplay, .screenSaver, .screenshot: .system
        case .layout, .shuffle, .quitFront, .hideOthers: .windows
        case .annotate, .findCursor, .colourPicker: .tools
        case .open, .shortcut, .plugin: .launch
        }
    }

    var title: String {
        switch self {
        case .none: "Nothing"
        case .orbit: "Orbit"
        case .command: "Command"
        case .toggleOwnDock: "Atelier Dock"
        case .toggleWidgets: "Widgets"
        case .focusLight: "Focus Light"
        case .showDesktop: "Show Desktop"
        case .missionControl: "Mission Control"
        case .appExpose: "App Exposé"
        // Launchpad until macOS 26, which replaced it with the Apps app.
        case .apps: DockCompat.launcherTitle(major: MacPlatform.major)
        case .lockScreen: "Lock Screen"
        case .sleepDisplay: "Sleep Display"
        case .screenSaver: "Screen Saver"
        case .screenshot: "Screenshot"
        case .layout: "Window Layout"
        case .shuffle: "Shuffle"
        case .quitFront: "Quit Front App"
        case .hideOthers: "Hide Others"
        case .annotate: "Annotate"
        case .findCursor: "Find Cursor"
        case .colourPicker: "Pick Colour"
        case .open: "Open…"
        case .shortcut: "Run Shortcut"
        case .plugin: "Plugin Action"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .orbit: "circle.hexagongrid"
        case .command: "command"
        case .toggleOwnDock: "dock.rectangle"
        case .toggleWidgets: "square.grid.2x2"
        case .focusLight: "light.max"
        case .showDesktop: "menubar.dock.rectangle"
        case .missionControl: "rectangle.3.group"
        case .appExpose: "rectangle.stack"
        case .apps: "square.grid.3x3"
        case .lockScreen: "lock"
        case .sleepDisplay: "moon.zzz"
        case .screenSaver: "sparkles.tv"
        case .screenshot: "camera.viewfinder"
        case .layout: "rectangle.split.2x1"
        case .shuffle: "shuffle"
        case .quitFront: "xmark.app"
        case .hideOthers: "eye.slash"
        case .annotate: "pencil.tip.crop.circle"
        case .findCursor: "cursorarrow.rays"
        case .colourPicker: "eyedropper"
        case .open: "arrow.up.forward.app"
        case .shortcut: "square.2.layers.3d"
        case .plugin: "puzzlepiece.extension"
        }
    }

    /// What it needs that may be missing.
    var note: String? {
        switch self {
        case .lockScreen: "Sends Control-Command-Q. Needs Accessibility."
        case .layout, .shuffle: "Needs Accessibility, like the Window Engine."
        case .showDesktop, .appExpose: "Asks Mission Control to do it."
        default: nil
        }
    }
}

struct CornerBinding: Codable, Hashable, Sendable {
    var action: CornerAction = .none
    var modifiers = HotModifiers()
    /// Seconds the pointer must rest before it fires.
    var dwell = 0.15
    /// A path or URL for Open, a name for Run Shortcut.
    var target = ""
    /// A `WindowGeometry.Layout` raw value for Window Layout.
    var layout = WindowGeometry.Layout.maximize.rawValue

    var isActive: Bool {
        switch action {
        case .none: false
        case .open, .shortcut, .plugin: !target.trimmingCharacters(in: .whitespaces).isEmpty
        default: true
        }
    }
}

/// Atelier's own hot corners and edges. One global mouse monitor, only while a spot has an
/// action; a one-shot timer only while the pointer rests in a spot. No polling.
@MainActor
final class HotCorners: ObservableObject {
    static let shared = HotCorners()
    private let store = UserDefaults.standard

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "corners.enabled"); apply() } }
    @Published private(set) var bindings: [HotSpot: CornerBinding] = [:]
    @Published var cooldown: Double { didSet { store.set(cooldown, forKey: "corners.cooldown") } }
    @Published var pauseFullScreen: Bool { didSet { store.set(pauseFullScreen, forKey: "corners.pauseFullScreen") } }
    @Published var pauseDragging: Bool { didSet { store.set(pauseDragging, forKey: "corners.pauseDragging") } }
    @Published var flourish: Bool { didSet { store.set(flourish, forKey: "corners.flourish") } }
    /// Counts fires, so the chapter's diagram can ripple the same spot.
    @Published private(set) var fired: (spot: HotSpot, count: Int)?
    @Published private(set) var lastError: String?

    private var started = false
    private var monitor: Any?
    private var flagsMonitor: Any?
    private var screens: [CGRect] = []
    private var trigger = HotTrigger()
    private var currentScreen: CGRect?
    private var pending: DispatchWorkItem?
    private var lastPoint = CGPoint(x: -1, y: -1)
    private var fireCount = 0

    private init() {
        enabled = store.bool(forKey: "corners.enabled")
        cooldown = store.object(forKey: "corners.cooldown") as? Double ?? 1.2
        pauseFullScreen = store.object(forKey: "corners.pauseFullScreen") as? Bool ?? true
        pauseDragging = store.object(forKey: "corners.pauseDragging") as? Bool ?? true
        flourish = store.object(forKey: "corners.flourish") as? Bool ?? true
        if let data = store.data(forKey: "corners.bindings"),
           let saved = try? JSONDecoder().decode([String: CornerBinding].self, from: data) {
            for (key, value) in saved { if let spot = HotSpot(rawValue: key) { bindings[spot] = value } }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { HotCorners.shared.cacheScreens() }
        }
        apply()
    }

    func binding(_ spot: HotSpot) -> CornerBinding { bindings[spot] ?? CornerBinding() }

    func set(_ binding: CornerBinding, for spot: HotSpot) {
        bindings[spot] = binding.action == .none ? nil : binding
        let raw = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(raw) { store.set(data, forKey: "corners.bindings") }
        apply()
    }

    var hasActiveSpots: Bool { bindings.values.contains(where: \.isActive) }

    private func apply() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        monitor = nil
        flagsMonitor = nil
        pending?.cancel()
        pending = nil
        trigger = HotTrigger()
        guard started, enabled, hasActiveSpots else { return }
        cacheScreens()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            MainActor.assumeIsolated { HotCorners.shared.moved() }
        }
        // A modifier pressed while already resting in a spot should still count.
        if bindings.values.contains(where: { $0.isActive && !$0.modifiers.isEmpty }) {
            flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { _ in
                MainActor.assumeIsolated { HotCorners.shared.check() }
            }
        }
    }

    private func cacheScreens() { screens = NSScreen.screens.map(\.frame) }

    /// The hot path: a few comparisons per event, and nothing at all away from the rim.
    private func moved() {
        let point = NSEvent.mouseLocation
        guard point != lastPoint else { return }
        lastPoint = point
        let screen = screens.first { $0.insetBy(dx: -2, dy: -2).contains(point) }
        var spot: HotSpot?
        if let screen {
            spot = HotZones.spot(at: point, screen: screen, screens: screens)
            if let found = spot, bindings[found]?.isActive != true { spot = nil }
        }
        currentScreen = screen
        let dwell = spot.map { binding($0).dwell } ?? 0
        switch trigger.update(spot: spot, now: CACurrentMediaTime(), dwell: dwell) {
        case .none: break
        case .cancel:
            pending?.cancel()
            pending = nil
        case let .schedule(_, delay):
            pending?.cancel()
            guard delay > 0.001 else { check(); return }
            let work = DispatchWorkItem { MainActor.assumeIsolated { HotCorners.shared.check() } }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func check() {
        guard let spot = trigger.current else { return }
        let binding = binding(spot)
        let now = CACurrentMediaTime()
        guard trigger.ready(now: now, dwell: binding.dwell, cooldown: cooldown) == spot else { return }
        let held = Self.modifiers()
        guard held.isSuperset(of: binding.modifiers) else { return }
        if pauseDragging && NSEvent.pressedMouseButtons != 0 { return }
        if pauseFullScreen && Self.frontIsFullScreen() { return }
        trigger.markFired(now: now)
        fire(spot, binding: binding, screen: currentScreen)
    }

    /// Runs a spot's action now. Also used by the chapter's Try It button.
    func fire(_ spot: HotSpot, binding: CornerBinding, screen: CGRect?) {
        fireCount += 1
        fired = (spot, fireCount)
        if flourish, let screen { CornerRipple.show(at: spot, on: screen) }
        perform(binding)
    }

    private static func modifiers() -> HotModifiers {
        let flags = NSEvent.modifierFlags
        var held = HotModifiers()
        if flags.contains(.control) { held.insert(.control) }
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.shift) { held.insert(.shift) }
        if flags.contains(.command) { held.insert(.command) }
        return held
    }

    /// Accessibility when we have it. Without it, a front window covering a whole screen
    /// (menu bar included) is the tell.
    private static func frontIsFullScreen() -> Bool {
        if AXIsProcessTrusted() { return WindowEngine.shared.frontIsFullScreen() }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let sizes = Set(NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height))" })
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid, (info[kCGWindowLayer as String] as? Int) == 0,
                  let raw = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { return false }
            return sizes.contains("\(Int(bounds.width))x\(Int(bounds.height))")
        }
    }

    // MARK: Actions

    private func perform(_ binding: CornerBinding) {
        lastError = nil
        switch binding.action {
        case .plugin:
            if !PluginRegistry.shared.runCorner(binding.target) { lastError = "That plugin action isn’t running." }
        case .none: break
        case .orbit: Orbit.shared.toggle()
        case .command: CommandController.shared.toggle()
        case .toggleOwnDock: OwnDock.shared.enabled.toggle()
        case .toggleWidgets: WidgetBoard.shared.enabled.toggle()
        case .focusLight: Effects.shared.focus.toggle()
        case .showDesktop: Self.missionControl("1")
        case .missionControl: Self.missionControl(nil)
        case .appExpose: Self.missionControl("2")
        case .apps:
            let path = DockCompat.launcherPath(major: MacPlatform.major) { FileManager.default.fileExists(atPath: $0) }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .lockScreen: Self.postKey(kVK_ANSI_Q, flags: [.maskControl, .maskCommand])
        case .sleepDisplay: Self.run("/usr/bin/pmset", ["displaysleepnow"])
        case .screenSaver: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
        case .screenshot: NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
        case .layout: WindowEngine.shared.apply(WindowGeometry.Layout(rawValue: binding.layout) ?? .maximize)
        case .shuffle: WindowEngine.shared.shuffle()
        case .quitFront:
            let own = ProcessInfo.processInfo.processIdentifier
            if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != own,
               app.bundleIdentifier != "com.apple.finder" { app.terminate() }
        case .hideOthers:
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let own = ProcessInfo.processInfo.processIdentifier
            for app in NSWorkspace.shared.runningApplications
            where app.activationPolicy == .regular && app.processIdentifier != front && app.processIdentifier != own {
                app.hide()
            }
        case .annotate: DesktopPlus.shared.toggleAnnotate()
        case .findCursor: DesktopPlus.shared.findCursor()
        case .colourPicker: DesktopPlus.shared.pickColour()
        case .open: open(binding.target)
        case .shortcut:
            let name = binding.target.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            Self.run("/usr/bin/shortcuts", ["run", name])
        }
    }

    private func open(_ target: String) {
        let text = target.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let path = (text as NSString).expandingTildeInPath
        if text.hasPrefix("/") || text.hasPrefix("~") {
            guard FileManager.default.fileExists(atPath: path) else { lastError = "Nothing at \(text)."; return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } else if let url = URL(string: text), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else {
            lastError = "“\(text)” is not a path or a link."
        }
    }

    /// The Mission Control app takes 1 for Show Desktop and 2 for App Exposé.
    private static func missionControl(_ argument: String?) {
        let binary = "/System/Applications/Mission Control.app/Contents/MacOS/Mission Control"
        if FileManager.default.isExecutableFile(atPath: binary) {
            run(binary, argument.map { [$0] } ?? [])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        }
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { HotCorners.shared.lastError = "Couldn’t run \(path): \(error.localizedDescription)" }
    }

    private static func postKey(_ key: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - Flourish

/// A ring of glass light that blooms out of the spot that fired, then goes.
enum CornerRipple {
    @MainActor static func show(at spot: HotSpot, on screen: CGRect) {
        let reach = 460.0
        let unit = spot.unit
        // The anchor point in screen space (AppKit, y up).
        let anchor = CGPoint(x: screen.minX + unit.x * screen.width, y: screen.maxY - unit.y * screen.height)
        let frame = CGRect(x: anchor.x - reach, y: anchor.y - reach, width: reach * 2, height: reach * 2).intersection(screen)
        guard !frame.isEmpty else { return }
        let origin = UnitPoint(x: (anchor.x - frame.minX) / frame.width, y: 1 - (anchor.y - frame.minY) / frame.height)
        let panel = FloatingPanel(frame: frame)
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: CornerRippleView(origin: origin, reach: reach)
            .frame(width: frame.width, height: frame.height))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { panel.orderOut(nil) }
    }
}

struct CornerRippleView: View {
    let origin: UnitPoint
    let reach: Double
    @State private var go = false

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width * origin.x, y: geometry.size.height * origin.y)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [DS.Ink.accent.opacity(0.35), .clear], center: .center, startRadius: 0, endRadius: reach * 0.5))
                    .frame(width: reach, height: reach)
                    .scaleEffect(go ? 1.4 : 0.2)
                Circle()
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.95), DS.Ink.accent.opacity(0.6)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 3)
                    .frame(width: reach * 1.2, height: reach * 1.2)
                    .scaleEffect(go ? 1 : 0.05)
                    .blur(radius: go ? 3 : 0)
                Circle()
                    .strokeBorder(.white.opacity(0.5), lineWidth: 1.5)
                    .frame(width: reach * 0.8, height: reach * 0.8)
                    .scaleEffect(go ? 1 : 0.05)
            }
            .position(center)
            .opacity(go ? 0 : 1)
        }
        .onAppear { withAnimation(.timingCurve(0.2, 0.7, 0.3, 1, duration: 0.8)) { go = true } }
    }
}
