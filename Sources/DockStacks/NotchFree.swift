import AppKit
import CoreGraphics
import DockCore

// MARK: - Notch-Free and Display Modes
//
// A notched MacBook Pro lists each scaled size twice: at the panel's own shape (1728×1117) and
// at 16:10 (1728×1080). The 16:10 twin starts below the notch: macOS paints the rows above it
// black and the menu bar moves down under them, so the notch disappears into a true black band.
// Notch-Free switches the built-in display to the twin of whatever size it is at and back; the
// UI scale stays the same because the width and the scale do. DockCore's NotchFreeLogic finds
// the twin from the mode list and the screen's safe area, never from a table of models.
//
// The same engine owns the Display Modes picker: every mode, the hidden duplicate low-resolution
// ones and every refresh rate included, with a 15-second "Keep this mode?" probation like System
// Settings. A mode change that is not kept reverts by itself, and one interrupted by a crash
// reverts at the next launch.
//
// Public API only (CGDisplayCopyAllDisplayModes, CGConfigureDisplayWithDisplayMode). Changes are
// made `.forSession` by default, so a logout or restart always brings the system's own mode back;
// quitting Atelier restores the original mode too, and the relaunch puts Notch-Free back.
//
// Interaction: LightEngine watches display reconfiguration. A mode change is one: it treats the
// next ~0.6 s as "away" (Boost pauses and glides back) and its watchdog re-writes the gamma tables
// macOS resets on the change. While Notch-Free is on the built-in screen has no safe area, so
// `MacPlatform.hasNotch` is false and notch-aware features place themselves as on a plain screen,
// which is right: there is no notch in the picture any more.

/// CoreGraphics' display modes, as DockCore's plain values, and the one place that applies them.
enum DisplayModeKit {
    /// Every mode, the duplicate low-resolution ones included.
    static func cgModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        return (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode]) ?? []
    }

    static func info(_ mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(modeID: mode.ioDisplayModeID, width: mode.width, height: mode.height,
                        pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate,
                        ioFlags: mode.ioFlags, usableForDesktop: mode.isUsableForDesktopGUI())
    }

    static func modes(_ display: CGDirectDisplayID) -> [DisplayModeInfo] { cgModes(display).map(info) }

    static func current(_ display: CGDirectDisplayID) -> DisplayModeInfo? { CGDisplayCopyDisplayMode(display).map(info) }

    /// Every display macOS knows, mirrored ones included.
    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    /// A stable name for a display across reconnects and reboots, for the defaults.
    static func uuid(_ display: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? { return text }
        return "\(CGDisplayVendorNumber(display))-\(CGDisplayModelNumber(display))-\(CGDisplaySerialNumber(display))"
    }

    static func display(withUUID uuid: String) -> CGDirectDisplayID? {
        onlineDisplays().first { self.uuid($0) == uuid }
    }

    @MainActor static func screen(_ display: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { LightEngine.displayID(of: $0) == display }
    }

    @MainActor static func name(_ display: CGDirectDisplayID) -> String {
        if let screen = screen(display) { return screen.localizedName }
        return CGDisplayIsBuiltin(display) != 0 ? "Built-in Display" : "Display \(display)"
    }

    static func scope(_ name: String) -> CGConfigureOption {
        switch name {
        case "app": .forAppOnly
        case "permanent": .permanently
        default: .forSession
        }
    }

    /// Switches `display` to `mode`. The mode is looked up again by its id and size, so a stale
    /// value (the display reconnected meanwhile) fails instead of applying something else.
    @discardableResult
    static func apply(_ mode: DisplayModeInfo, on display: CGDirectDisplayID, scope: CGConfigureOption) -> CGError {
        guard let target = cgModes(display).first(where: { info($0) == mode })
                ?? cgModes(display).first(where: { $0.ioDisplayModeID == mode.modeID && info($0).sameResolution(mode) })
        else { return .illegalArgument }
        var config: CGDisplayConfigRef?
        var error = CGBeginDisplayConfiguration(&config)
        guard error == .success, let config else { return error }
        error = CGConfigureDisplayWithDisplayMode(config, display, target, nil)
        guard error == .success else {
            CGCancelDisplayConfiguration(config)
            return error
        }
        return CGCompleteDisplayConfiguration(config, scope)
    }
}

@MainActor
final class NotchFree: ObservableObject {
    static let shared = NotchFree()

    enum Keys {
        static let enabled = "notchFree.enabled"
        /// The built-in display's mode before Notch-Free changed it: JSON DisplayModeInfo.
        static let original = "notchFree.original"
        /// The notch's share of the screen height, last measured while the notch was visible.
        static let fraction = "notchFree.fraction"
        /// A mode change on probation, so a crash during it reverts at the next launch.
        static let pending = "notchFree.pendingRevert"
        /// "session" (default), "app" or "permanent": how long a mode change lasts.
        static let scope = "notchFree.scope"
        static let showDuplicates = "notchFree.showDuplicates"
    }

    /// What is on probation, saved so the next launch can undo it.
    private struct Pending: Codable {
        var display: String
        var previous: DisplayModeInfo
        /// The probation was turning Notch-Free on: reverting turns it off again.
        var enabling: Bool
    }

    /// One display the picker can drive.
    struct Display: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let builtIn: Bool
    }

    @Published private(set) var enabled: Bool
    @Published private(set) var displays: [Display] = []
    @Published var selectedDisplay: CGDirectDisplayID?
    @Published private(set) var modes: [DisplayModeInfo] = []
    @Published private(set) var current: DisplayModeInfo?
    @Published private(set) var revert: ModeRevertState = .idle
    @Published private(set) var secondsLeft = 0
    @Published private(set) var lastError: String?
    @Published var showDuplicates: Bool { didSet { store.set(showDuplicates, forKey: Keys.showDuplicates) } }

    private let store = UserDefaults.standard
    private var revertDisplay: CGDirectDisplayID?
    private var revertEnabling = false
    private var revertTimer: Timer?
    private var observer: NSObjectProtocol?
    /// Set while we change a mode ourselves, so the screen-change notification it causes is not
    /// mistaken for someone else's change.
    private var applyingUntil = 0.0

    /// The built-in display's modes, read at most every half second: the cards ask several
    /// times per frame while the countdown runs. `refresh()` and every apply drop it.
    private var modeCache: (display: CGDirectDisplayID, time: Double, modes: [DisplayModeInfo])?

    private func cachedModes(_ display: CGDirectDisplayID) -> [DisplayModeInfo] {
        if let cache = modeCache, cache.display == display, now - cache.time < 0.5 { return cache.modes }
        let list = DisplayModeKit.modes(display)
        modeCache = (display, now, list)
        return list
    }

    private init() {
        enabled = store.bool(forKey: Keys.enabled)
        showDuplicates = store.bool(forKey: Keys.showDuplicates)
    }

    private var scope: CGConfigureOption { DisplayModeKit.scope(store.string(forKey: Keys.scope) ?? "session") }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    // MARK: Built-in display

    /// The notched built-in display, whether or not Notch-Free is hiding the notch right now.
    var builtInDisplay: CGDirectDisplayID? {
        DisplayModeKit.onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }
    }

    /// The notch's share of the screen height: from the safe area while the notch shows, else
    /// what was last measured, else from the panel's mode list.
    func notchFraction(for display: CGDirectDisplayID, modes: [DisplayModeInfo]) -> Double? {
        if let screen = DisplayModeKit.screen(display),
           let measured = NotchFreeLogic.notchFraction(safeAreaTop: screen.safeAreaInsets.top, screenHeight: screen.frame.height) {
            store.set(measured, forKey: Keys.fraction)
            return measured
        }
        if let saved = store.object(forKey: Keys.fraction) as? Double, saved > 0 { return saved }
        return NotchFreeLogic.notchFraction(fromModes: modes)
    }

    var availability: FeatureAvailability {
        guard let display = builtInDisplay else { return .unavailable("Needs a built-in display (the lid is closed or there is none)") }
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list) else { return .unavailable("This display has no notch") }
        if let current = DisplayModeKit.current(display),
           NotchFreeLogic.notchFreeMode(for: current, in: list, notchFraction: fraction) == nil,
           !NotchFreeLogic.isNotchFree(current, in: list, notchFraction: fraction) {
            return .limited("\(current.sizeText) has no notch-free twin; pick another size")
        }
        return .available
    }

    /// Whether the built-in display is at a notch-free mode right now.
    var isNotchFreeNow: Bool {
        guard let display = builtInDisplay, let current = DisplayModeKit.current(display) else { return false }
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list) else { return false }
        return NotchFreeLogic.isNotchFree(current, in: list, notchFraction: fraction)
    }

    /// The two modes the switch moves between, for the miniature: (with notch, without).
    var pair: (notched: DisplayModeInfo, free: DisplayModeInfo)? {
        guard let display = builtInDisplay, let current = DisplayModeKit.current(display) else { return nil }
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list) else { return nil }
        if let free = NotchFreeLogic.notchFreeMode(for: current, in: list, notchFraction: fraction) { return (current, free) }
        if let notched = NotchFreeLogic.notchedMode(for: current, in: list, notchFraction: fraction) { return (notched, current) }
        return nil
    }

    // MARK: Lifecycle

    func resume() {
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { NotchFree.shared.screensChanged() }
        }
        // A probation the last run never finished (it crashed or was killed): nobody kept it.
        if let data = store.data(forKey: Keys.pending), let pending = try? JSONDecoder().decode(Pending.self, from: data) {
            store.removeObject(forKey: Keys.pending)
            if let display = DisplayModeKit.display(withUUID: pending.display) {
                DisplayModeKit.apply(pending.previous, on: display, scope: scope)
            }
            if pending.enabling { setStored(false) }
        }
        if enabled {
            ensureNotchFree()
        } else if let original = savedOriginal(), let display = builtInDisplay {
            // Off, yet a mode we changed is still on record: put it back.
            if DisplayModeKit.current(display) != original { DisplayModeKit.apply(original, on: display, scope: scope) }
            store.removeObject(forKey: Keys.original)
        }
        refresh()
    }

    /// For `applicationWillTerminate`: the original mode back, at once. Notch-Free stays on in
    /// the settings, so the next launch hides the notch again.
    func restoreOnQuit() {
        revertTimer?.invalidate()
        revertTimer = nil
        if case .pending(let previous, _, _) = revert, let display = revertDisplay {
            DisplayModeKit.apply(previous, on: display, scope: scope)
            store.removeObject(forKey: Keys.pending)
            if revertEnabling { setStored(false) }
            revert = .idle
        }
        if enabled { restoreNotched() }
    }

    // MARK: Notch-Free

    /// The switch. Turning it on goes through the same 15-second probation as a picked mode.
    func setEnabled(_ on: Bool, confirm: Bool = true) {
        lastError = nil
        guard let display = builtInDisplay, let current = DisplayModeKit.current(display) else {
            lastError = "No built-in display is active."
            return
        }
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list) else {
            lastError = "This display has no notch."
            return
        }
        if on {
            if NotchFreeLogic.isNotchFree(current, in: list, notchFraction: fraction) {
                setStored(true)
                refresh()
                return
            }
            guard let target = NotchFreeLogic.notchFreeMode(for: current, in: list, notchFraction: fraction) else {
                lastError = "\(current.sizeText) has no notch-free twin. Pick another size first."
                return
            }
            saveOriginal(current)
            setStored(true)
            change(display, from: current, to: target, confirm: confirm, enabling: true)
        } else {
            setStored(false)
            if case .pending = revert, revertEnabling {
                // Turned off while on probation: that is a revert.
                revertNow()
                return
            }
            restoreNotched()
            refresh()
        }
    }

    /// Notch-Free is on: make sure the built-in display is at a notch-free mode. Run at launch
    /// and when the size is changed elsewhere (System Settings), so the notch stays hidden.
    private func ensureNotchFree() {
        guard let display = builtInDisplay, let current = DisplayModeKit.current(display) else { return }
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list),
              let target = NotchFreeLogic.notchFreeMode(for: current, in: list, notchFraction: fraction) else { return }
        saveOriginal(current)
        applyingUntil = now + 2
        modeCache = nil
        let error = DisplayModeKit.apply(target, on: display, scope: scope)
        if error != .success { lastError = "macOS refused the notch-free mode (\(error.rawValue))." }
    }

    /// Back to the mode with the notch: the saved original when it is the twin of the current
    /// size, otherwise the twin of whatever size the display is at now.
    private func restoreNotched() {
        defer { store.removeObject(forKey: Keys.original) }
        guard let display = builtInDisplay, let current = DisplayModeKit.current(display) else { return }
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list),
              NotchFreeLogic.isNotchFree(current, in: list, notchFraction: fraction) else { return }
        var target = NotchFreeLogic.notchedMode(for: current, in: list, notchFraction: fraction)
        if let original = savedOriginal(), original.width == current.width, original.scale == current.scale,
           list.contains(original) { target = original }
        guard let target else { return }
        applyingUntil = now + 2
        modeCache = nil
        DisplayModeKit.apply(target, on: display, scope: scope)
    }

    private func screensChanged() {
        refresh()
        // Someone else changed the size while Notch-Free is on: follow them below the notch.
        guard enabled, now > applyingUntil, case .idle = revert else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            MainActor.assumeIsolated {
                let engine = NotchFree.shared
                if engine.enabled, !engine.isNotchFreeNow, case .idle = engine.revert { engine.ensureNotchFree() }
            }
        }
    }

    private func setStored(_ on: Bool) {
        enabled = on
        store.set(on, forKey: Keys.enabled)
    }

    private func saveOriginal(_ mode: DisplayModeInfo) {
        if let data = try? JSONEncoder().encode(mode) { store.set(data, forKey: Keys.original) }
    }

    private func savedOriginal() -> DisplayModeInfo? {
        store.data(forKey: Keys.original).flatMap { try? JSONDecoder().decode(DisplayModeInfo.self, from: $0) }
    }

    // MARK: Display Modes picker

    /// Re-reads displays and the selected display's modes.
    func refresh() {
        modeCache = nil
        let active = DisplayModeKit.onlineDisplays().filter { CGDisplayIsActive($0) != 0 && CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
        displays = active.map { Display(id: $0, name: DisplayModeKit.name($0), builtIn: CGDisplayIsBuiltin($0) != 0) }
            .sorted { ($0.builtIn ? 0 : 1, $0.id) < ($1.builtIn ? 0 : 1, $1.id) }
        if selectedDisplay == nil || !displays.contains(where: { $0.id == selectedDisplay }) {
            selectedDisplay = displays.first?.id
        }
        if let display = selectedDisplay {
            modes = DisplayModeKit.modes(display)
            current = DisplayModeKit.current(display)
        } else {
            modes = []
            current = nil
        }
    }

    func select(_ display: CGDirectDisplayID) {
        selectedDisplay = display
        refresh()
    }

    /// Whether `mode` agrees with Notch-Free being on: it is a notch-free one, or it has no twin.
    private func followsNotchFree(_ mode: DisplayModeInfo, on display: CGDirectDisplayID) -> Bool {
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list) else { return true }
        return NotchFreeLogic.notchFreeMode(for: mode, in: list, notchFraction: fraction) == nil
    }

    /// True for a notch-free mode, false for one with a notch-free twin, nil for neither.
    private func notchFreeState(of mode: DisplayModeInfo, on display: CGDirectDisplayID) -> Bool? {
        let list = cachedModes(display)
        guard let fraction = notchFraction(for: display, modes: list) else { return nil }
        if NotchFreeLogic.isNotchFree(mode, in: list, notchFraction: fraction) { return true }
        return NotchFreeLogic.notchFreeMode(for: mode, in: list, notchFraction: fraction) != nil ? false : nil
    }

    var groups: [DisplayAspectGroup] {
        DisplayModeGrouping.groups(modes, current: current, hiDPIOnly: !showDuplicates)
    }

    /// The picker: switch the selected display to `mode`, on probation for 15 seconds.
    func choose(_ mode: DisplayModeInfo, confirm: Bool = true) {
        guard let display = selectedDisplay, let current = DisplayModeKit.current(display), mode != current else { return }
        lastError = nil
        // Picking a size with the notch on the built-in display is a wish to see the notch:
        // Notch-Free turns off rather than pulling the screen back below it.
        if enabled, display == builtInDisplay, !followsNotchFree(mode, on: display) {
            setStored(false)
            store.removeObject(forKey: Keys.original)
        }
        change(display, from: current, to: mode, confirm: confirm, enabling: false)
    }

    private func change(_ display: CGDirectDisplayID, from previous: DisplayModeInfo, to mode: DisplayModeInfo,
                        confirm: Bool, enabling: Bool) {
        applyingUntil = now + 2
        modeCache = nil
        let error = DisplayModeKit.apply(mode, on: display, scope: scope)
        guard error == .success else {
            lastError = "macOS refused \(mode.sizeText) at \(mode.refreshText) (\(error.rawValue))."
            if enabling { setStored(false) }
            refresh()
            return
        }
        if confirm {
            if case .pending = revert, revertDisplay != display { keep() }
            // A second change on probation keeps the first one's way back and its kind.
            let wasPending: Bool = if case .pending = revert { true } else { false }
            revertEnabling = wasPending ? (revertEnabling || enabling) : enabling
            revertDisplay = display
            step(.applied(previous: previous, applied: mode, now: now))
        }
        refresh()
    }

    func keep() { step(.keep) }

    func revertNow() { step(.revertNow) }

    private func step(_ event: ModeRevertEvent) {
        let (state, action) = ModeRevertMachine.next(revert, event)
        revert = state
        secondsLeft = ModeRevertMachine.remaining(state, now: now)
        if case .restore(let previous) = action, let display = revertDisplay {
            applyingUntil = now + 2
        modeCache = nil
            let error = DisplayModeKit.apply(previous, on: display, scope: scope)
            if error != .success { lastError = "Could not go back to \(previous.sizeText) (\(error.rawValue))." }
            if revertEnabling {
                setStored(false)
                store.removeObject(forKey: Keys.original)
            } else if display == builtInDisplay, let wanted = notchFreeState(of: previous, on: display), wanted != enabled {
                // Back to a mode below the notch: the switch says so again (and the reverse).
                setStored(wanted)
            }
        }
        if case .pending(let previous, _, _) = state, let display = revertDisplay {
            let pending = Pending(display: DisplayModeKit.uuid(display), previous: previous, enabling: revertEnabling)
            if let data = try? JSONEncoder().encode(pending) { store.set(data, forKey: Keys.pending) }
            if revertTimer == nil {
                revertTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    MainActor.assumeIsolated { NotchFree.shared.step(.tick(now: NotchFree.shared.now)) }
                }
            }
        } else {
            store.removeObject(forKey: Keys.pending)
            revertTimer?.invalidate()
            revertTimer = nil
            revertEnabling = false
            refresh()
        }
    }

    // MARK: Diagnostics and tests

    var diagnostics: String {
        let display = builtInDisplay
        let list = display.map(cachedModes) ?? []
        let fraction = display.flatMap { notchFraction(for: $0, modes: list) }
        let pending: String = if case .pending(let previous, let applied, _) = revert {
            "\(secondsLeft)s:\(previous.signature)->\(applied.signature)"
        } else { "no" }
        return [
            "notchFree=\(enabled ? "on" : "off")",
            "notchFreeNow=\(isNotchFreeNow)",
            "notchFreeDisplay=\(display.map(String.init) ?? "-")",
            "notchFreeMode=\(display.flatMap(DisplayModeKit.current)?.signature ?? "-")",
            "notchFreePair=\(pair.map { "\($0.notched.sizeText)|\($0.free.sizeText)" } ?? "-")",
            "notchFreeFraction=\(fraction.map { String(format: "%.4f", $0) } ?? "-")",
            "notchFreeOriginal=\(savedOriginal()?.signature ?? "-")",
            "notchFreeScope=\(store.string(forKey: Keys.scope) ?? "session")",
            "displayModes=\(modes.count) displayModesSelected=\(selectedDisplay.map(String.init) ?? "-") displayModesPending=\(pending)",
            "notchFreeError=\(lastError ?? "-")",
        ].joined(separator: " ")
    }

    /// `atelier://notchfree?on=1|0`, `?mode=<ioDisplayModeID>[&display=<id>]`, `?keep=1`,
    /// `?revert=1`, `?confirm=0` (skip probation), `?scope=session|app|permanent`, `?dump=1`
    /// (every mode of every display to $TMPDIR/atelier-modes.txt).
    func handleTest(_ items: [URLQueryItem]) {
        let value = { (name: String) in items.first { $0.name == name }?.value }
        let confirm = value("confirm") != "0"
        if let scope = value("scope"), ["session", "app", "permanent"].contains(scope) { store.set(scope, forKey: Keys.scope) }
        if let display = value("display").flatMap(UInt32.init) { select(display) }
        if let on = value("on") { setEnabled(on == "1", confirm: confirm) }
        if let id = value("mode").flatMap(Int32.init) {
            refresh()
            if let mode = modes.first(where: { $0.modeID == id }) { choose(mode, confirm: confirm) }
            else { lastError = "No mode \(id) on display \(selectedDisplay.map(String.init) ?? "-")." }
        }
        if value("keep") != nil { keep() }
        if value("revert") != nil { revertNow() }
        if value("dump") != nil {
            var lines: [String] = []
            for display in DisplayModeKit.onlineDisplays() {
                lines.append("display \(display) \(DisplayModeKit.name(display)) builtin=\(CGDisplayIsBuiltin(display)) current=\(DisplayModeKit.current(display)?.signature ?? "-")")
                lines += cachedModes(display).map { "  \($0.signature) flags=0x\(String($0.ioFlags, radix: 16)) usable=\($0.usableForDesktop)" }
            }
            try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "atelier-modes.txt", atomically: true, encoding: .utf8)
        }
    }
}
