import AppKit
import Carbon.HIToolbox
import DockCore
import IOKit.pwr_mgt
import SwiftUI

/// Shared state the overlays read, so a change animates instead of rebuilding a panel.
@MainActor
final class DesktopPlusLook: ObservableObject {
    @Published var glowColor = Color.white
    @Published var night = 0.0
    @Published var halo: CGPoint?
    @Published var haloShown = false
    @Published var keys: [KeyPress] = []
    @Published var swatch: (color: Color, hex: String)?

    struct KeyPress: Identifiable, Equatable {
        let id = UUID()
        let label: String
    }
}

/// Desktop overlays and on-demand tools. Every overlay is click-through and lives in a panel
/// that goes with the process. Nothing watches anything while its feature is off.
@MainActor
final class DesktopPlus: ObservableObject {
    static let shared = DesktopPlus()
    private let store = UserDefaults.standard
    let look = DesktopPlusLook()

    // Screen
    @Published var edgeGlow: Bool { didSet { save(edgeGlow, "edgeGlow"); applyEdgeGlow() } }
    @Published var edgeGlowWidth: Double { didSet { save(edgeGlowWidth, "edgeGlowWidth"); if edgeGlow { applyEdgeGlow() } } }
    @Published var vignette: Bool { didSet { save(vignette, "vignette"); applyVignette() } }
    @Published var vignetteStrength: Double { didSet { save(vignetteStrength, "vignetteStrength"); if vignette { applyVignette() } } }
    @Published var grain: Bool { didSet { save(grain, "grain"); applyGrain() } }
    @Published var grainStrength: Double { didSet { save(grainStrength, "grainStrength"); if grain { applyGrain() } } }
    @Published var nightTint: Bool { didSet { save(nightTint, "nightTint"); applyNight() } }
    /// Minutes after midnight.
    @Published var nightStart: Double { didSet { save(nightStart, "nightStart"); if nightTint { applyNight() } } }
    @Published var nightEnd: Double { didSet { save(nightEnd, "nightEnd"); if nightTint { applyNight() } } }
    @Published var nightWarmth: Double { didSet { save(nightWarmth, "nightWarmth"); if nightTint { applyNight() } } }
    // Designer
    @Published var grid: Bool { didSet { save(grid, "grid"); applyGrid() } }
    @Published var gridSpacing: Double { didSet { save(gridSpacing, "gridSpacing"); if grid { applyGrid() } } }
    // Presenting
    @Published var cursorHalo: Bool { didSet { save(cursorHalo, "cursorHalo"); applyHaloMonitor() } }
    @Published var keystrokes: Bool { didSet { save(keystrokes, "keystrokes"); applyKeystrokes() } }
    @Published var keystrokesAll: Bool { didSet { save(keystrokesAll, "keystrokesAll") } }
    // Desktop
    @Published var cleanDesktop: Bool { didSet { save(cleanDesktop, "cleanDesktop"); applyCleanDesktop() } }
    @Published var cleanRestoreOnQuit: Bool { didSet { save(cleanRestoreOnQuit, "cleanRestoreOnQuit") } }
    @Published var menuBarHider: Bool { didSet { save(menuBarHider, "menuBarHider"); applyHider() } }
    @Published private(set) var menuBarCollapsed = false
    // Power
    @Published private(set) var caffeinateUntil: Date?
    @Published private(set) var caffeinateForever = false
    // Tools
    @Published private(set) var annotating = false
    @Published private(set) var measuring = false
    @Published private(set) var colours: [String] = []
    @Published var notice: String?

    private var started = false
    private var edgePanels: [NSPanel] = []
    private var vignettePanels: [NSPanel] = []
    private var grainPanels: [NSPanel] = []
    private var nightPanels: [NSPanel] = []
    private var gridPanels: [NSPanel] = []
    private var activationObserver: NSObjectProtocol?
    private var nightTimer: Timer?
    private var haloMonitor: Any?
    private var haloPanel: NSPanel?
    private var haloGeneration = 0
    private var shake = ShakeDetector()
    private var keyMonitor: Any?
    private var keyPanel: NSPanel?
    private var keyGeneration = 0
    private var hiderToggle: NSStatusItem?
    private var hiderSeparator: NSStatusItem?
    private var assertion: IOPMAssertionID = 0
    private var caffeinateTimer: Timer?
    private var toolPanel: NSPanel?
    private var toolKeyMonitor: Any?
    /// Closes a full-screen tool when it loses the keyboard, so it can never sit over the
    /// screen eating clicks after Escape has stopped reaching it.
    private var toolResignObserver: NSObjectProtocol?
    private var sampling = false
    private var swatchPanel: NSPanel?
    private var swatchGeneration = 0

    private init() {
        func bool(_ key: String) -> Bool { UserDefaults.standard.bool(forKey: "desktopPlus." + key) }
        func number(_ key: String, _ fallback: Double) -> Double {
            UserDefaults.standard.object(forKey: "desktopPlus." + key) as? Double ?? fallback
        }
        edgeGlow = bool("edgeGlow")
        edgeGlowWidth = number("edgeGlowWidth", 18)
        vignette = bool("vignette")
        vignetteStrength = number("vignetteStrength", 0.45)
        grain = bool("grain")
        grainStrength = number("grainStrength", 0.35)
        nightTint = bool("nightTint")
        nightStart = number("nightStart", 21 * 60)
        nightEnd = number("nightEnd", 7 * 60)
        nightWarmth = number("nightWarmth", 0.5)
        grid = bool("grid")
        gridSpacing = number("gridSpacing", 8)
        cursorHalo = bool("cursorHalo")
        keystrokes = bool("keystrokes")
        keystrokesAll = bool("keystrokesAll")
        cleanDesktop = bool("cleanDesktop")
        cleanRestoreOnQuit = UserDefaults.standard.object(forKey: "desktopPlus.cleanRestoreOnQuit") as? Bool ?? true
        menuBarHider = bool("menuBarHider")
    }

    private func save(_ value: Any, _ key: String) { store.set(value, forKey: "desktopPlus." + key) }

    /// Safe to call again on a screen change: panels are rebuilt, observers are not doubled.
    func start() {
        // A display change moves the menu bar's room, so a collapsed divider is fitted again.
        if menuBarCollapsed { setCollapsed(true) }
        applyEdgeGlow(); applyVignette(); applyGrain(); applyNight(); applyGrid()
        guard !started else { return }
        started = true
        applyHaloMonitor(); applyKeystrokes(); applyHider()
        recoverCleanDesktop()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { DesktopPlus.shared.quitting() }
        }
    }

    private func quitting() {
        if cleanRestoreOnQuit && store.bool(forKey: "desktopPlus.cleanApplied") {
            // Synchronous: the process is about to go.
            Self.restoreDesktopIcons(prior: store.string(forKey: "desktopPlus.cleanPrior"), method: appliedMethod)
            store.set(false, forKey: "desktopPlus.cleanApplied")
            store.removeObject(forKey: "desktopPlus.cleanMethod")
        }
        releaseCaffeinate()
    }

    // MARK: Panels

    private func overlay(_ frame: NSRect, level: NSWindow.Level, fullScreen: Bool = true, content: some View) -> NSPanel {
        let panel = FloatingPanel(frame: frame)
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, fullScreen ? .fullScreenAuxiliary : .fullScreenNone]
        panel.contentView = NSHostingView(rootView: content.frame(width: frame.width, height: frame.height).allowsHitTesting(false))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }

    private func clear(_ panels: inout [NSPanel]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    // MARK: Edge Glow

    /// A soft rim of light in the active app's colour. It changes on app switch, nothing else.
    private func applyEdgeGlow() {
        clear(&edgePanels)
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        guard edgeGlow else { return }
        if let path = NSWorkspace.shared.frontmostApplication?.bundleURL?.path {
            look.glowColor = Effects.dominant(of: NSWorkspace.shared.icon(forFile: path))
        }
        let width = edgeGlowWidth
        for screen in NSScreen.screens {
            edgePanels.append(overlay(screen.frame, level: .screenSaver, fullScreen: false, content: EdgeGlowRing(look: look, width: width)))
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let path = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleURL?.path
            MainActor.assumeIsolated {
                guard let path, path != Bundle.main.bundlePath else { return }
                let color = Effects.dominant(of: NSWorkspace.shared.icon(forFile: path))
                withAnimation(.easeInOut(duration: 0.6)) { DesktopPlus.shared.look.glowColor = color }
            }
        }
    }

    // MARK: Vignette, grain, night

    private func applyVignette() {
        clear(&vignettePanels)
        guard vignette else { return }
        for screen in NSScreen.screens {
            vignettePanels.append(overlay(screen.frame, level: .screenSaver, content: VignetteView(strength: vignetteStrength)))
        }
    }

    private func applyGrain() {
        clear(&grainPanels)
        guard grain, let image = GrainTexture.image else { return }
        for screen in NSScreen.screens {
            grainPanels.append(overlay(screen.frame, level: .screenSaver, content: GrainView(image: image, strength: grainStrength)))
        }
    }

    private func applyNight() {
        nightTimer?.invalidate()
        nightTimer = nil
        clear(&nightPanels)
        guard nightTint else { look.night = 0; return }
        updateNight(animated: false)
        for screen in NSScreen.screens {
            nightPanels.append(overlay(screen.frame, level: .screenSaver, content: NightTintView(look: look, warmth: nightWarmth)))
        }
    }

    /// One timer at a time, set for the next moment the tint changes.
    private func updateNight(animated: Bool) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let minute = Double((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        let value = NightSchedule.strength(minute: minute, start: nightStart, end: nightEnd, fade: 45)
        if animated { withAnimation(.easeInOut(duration: 2)) { look.night = value } } else { look.night = value }
        let wait = NightSchedule.secondsUntilNextUpdate(minute: minute, start: nightStart, end: nightEnd, fade: 45)
        nightTimer?.invalidate()
        let timer = Timer(timeInterval: wait, repeats: false) { _ in
            MainActor.assumeIsolated { DesktopPlus.shared.updateNight(animated: true) }
        }
        timer.tolerance = min(wait * 0.1, 20)
        RunLoop.main.add(timer, forMode: .common)
        nightTimer = timer
    }

    var nightNow: Double { look.night }

    // MARK: Grid

    private func applyGrid() {
        clear(&gridPanels)
        guard grid else { return }
        for screen in NSScreen.screens {
            gridPanels.append(overlay(screen.frame, level: .screenSaver, content: PixelGrid(spacing: gridSpacing, scale: screen.backingScaleFactor)))
        }
    }

    // MARK: Cursor halo

    private func applyHaloMonitor() {
        if let haloMonitor { NSEvent.removeMonitor(haloMonitor) }
        haloMonitor = nil
        guard cursorHalo || look.haloShown else { return }
        haloMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { _ in
            MainActor.assumeIsolated { DesktopPlus.shared.pointerMoved() }
        }
    }

    private func pointerMoved() {
        let point = NSEvent.mouseLocation
        if look.haloShown { moveHalo(to: point) }
        if cursorHalo, shake.add(x: point.x, time: CACurrentMediaTime()) { findCursor() }
    }

    /// A ring of light that closes in on the pointer. Shake to call it, or bind it to a key or corner.
    func findCursor() {
        let point = NSEvent.mouseLocation
        let size = 320.0
        if haloPanel == nil {
            let panel = overlay(NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                                level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1), content: CursorHaloView(look: look))
            haloPanel = panel
        }
        moveHalo(to: point)
        haloPanel?.orderFrontRegardless()
        look.haloShown = true
        applyHaloMonitor()
        haloGeneration += 1
        let current = haloGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let plus = DesktopPlus.shared
            guard plus.haloGeneration == current else { return }
            plus.look.haloShown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard plus.haloGeneration == current else { return }
                plus.haloPanel?.orderOut(nil)
                plus.applyHaloMonitor()
            }
        }
    }

    private func moveHalo(to point: CGPoint) {
        guard let panel = haloPanel else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }

    // MARK: Keystrokes

    /// Key events from other apps need Accessibility. Secure fields (passwords) are never shown.
    private func applyKeystrokes() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        keyPanel?.orderOut(nil)
        look.keys = []
        guard keystrokes else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            let code = Int(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let characters = event.charactersIgnoringModifiers ?? ""
            MainActor.assumeIsolated { DesktopPlus.shared.key(code: code, flags: flags, characters: characters) }
        }
    }

    private func key(code: Int, flags: NSEvent.ModifierFlags, characters: String) {
        guard !IsSecureEventInputEnabled() else { return }
        let strong = !flags.intersection([.command, .control, .option]).isEmpty
        guard keystrokesAll || strong || KeyNames.standalone.contains(code) else { return }
        var label = ""
        if flags.contains(.control) { label += "⌃" }
        if flags.contains(.option) { label += "⌥" }
        if flags.contains(.shift) { label += "⇧" }
        if flags.contains(.command) { label += "⌘" }
        if code == kVK_Space { label += "Space" }
        else if KeyNames.standalone.contains(code) { label += KeyNames.name(code) }
        else { label += characters.uppercased() }
        showKey(label)
    }

    private func showKey(_ label: String) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }
        let frame = NSRect(x: screen.frame.midX - 360, y: screen.visibleFrame.minY + 40, width: 720, height: 90)
        if keyPanel == nil {
            keyPanel = overlay(frame, level: .screenSaver, content: KeystrokeStrip(look: look))
        }
        if keyPanel?.frame != frame { keyPanel?.setFrame(frame, display: false) }
        keyPanel?.orderFrontRegardless()
        withAnimation(DS.Motion.settle) {
            look.keys.append(.init(label: label))
            if look.keys.count > 5 { look.keys.removeFirst(look.keys.count - 5) }
        }
        keyGeneration += 1
        let current = keyGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let plus = DesktopPlus.shared
            guard plus.keyGeneration == current else { return }
            withAnimation(DS.Motion.exit) { plus.look.keys = [] }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if plus.keyGeneration == current { plus.keyPanel?.orderOut(nil) }
            }
        }
    }

    // MARK: Clean desktop

    /// How Clean Desktop hides the icons, kept with what was there before so it goes back exactly.
    private enum CleanMethod: String {
        /// macOS 14 on: Desktop & Dock's "Show Items: On Desktop" off. The icons come back whenever
        /// you go to the desktop (clicking the wallpaper, Show Desktop, F11), and Finder keeps running
        /// its desktop. WindowManager observes the key, so nothing restarts.
        case windowManager
        /// Up to macOS 13: Finder's `CreateDesktop`. It removes Finder's desktop altogether, so
        /// it is never used where the gentler switch exists.
        case finder

        static var preferred: CleanMethod { MacPlatform.major >= 14 ? .windowManager : .finder }
        var key: String { self == .windowManager ? "StandardHideDesktopIcons" : "CreateDesktop" }
        var domain: String { self == .windowManager ? "com.apple.WindowManager" : "com.apple.finder" }
        var hidden: String { self == .windowManager ? "true" : "false" }
        var restarts: String? { self == .finder ? "Finder" : nil }
    }

    /// The method the applied state used. Before it was recorded, Clean Desktop always used Finder's.
    private var appliedMethod: CleanMethod {
        store.string(forKey: "desktopPlus.cleanMethod").flatMap(CleanMethod.init(rawValue:)) ?? .finder
    }

    private func applyCleanDesktop() {
        let applied = store.bool(forKey: "desktopPlus.cleanApplied")
        if cleanDesktop && !applied {
            let method = CleanMethod.preferred
            let prior = Prefs.current(method.key, domain: method.domain)
            store.set(prior, forKey: "desktopPlus.cleanPrior")
            store.set(method.rawValue, forKey: "desktopPlus.cleanMethod")
            store.set(true, forKey: "desktopPlus.cleanApplied")
            Task.detached {
                do {
                    try Prefs.write(method.key, type: "bool", value: method.hidden, domain: method.domain)
                    if let process = method.restarts { Prefs.restart(process) }
                } catch {
                    await MainActor.run { DesktopPlus.shared.notice = "Couldn’t hide desktop icons: \(error.localizedDescription)" }
                }
            }
        } else if !cleanDesktop && applied {
            restoreCleanDesktop()
        }
    }

    /// After a crash, or a quit that was set to restore: put the icons back, then re-apply if wanted.
    /// An older Atelier hid them with Finder's `CreateDesktop`, which leaves no desktop to go to:
    /// that is undone and, where the gentler switch exists, applied again with it.
    private func recoverCleanDesktop() {
        let applied = store.bool(forKey: "desktopPlus.cleanApplied")
        if applied && (!cleanDesktop || appliedMethod != CleanMethod.preferred) {
            restoreCleanDesktop()
            if cleanDesktop { applyCleanDesktop() }
        } else if cleanDesktop && !applied {
            applyCleanDesktop()
        }
    }

    private func restoreCleanDesktop() {
        let method = appliedMethod
        let prior = store.string(forKey: "desktopPlus.cleanPrior")
        store.set(false, forKey: "desktopPlus.cleanApplied")
        store.removeObject(forKey: "desktopPlus.cleanMethod")
        Task.detached { Self.restoreDesktopIcons(prior: prior, method: method) }
    }

    nonisolated private static func restoreDesktopIcons(prior: String?, method: CleanMethod) {
        if let prior {
            let off = prior == "false" || prior == "0"
            try? Prefs.write(method.key, type: "bool", value: off ? "false" : "true", domain: method.domain)
        } else {
            try? Prefs.delete(method.key, domain: method.domain)
        }
        if let process = method.restarts { Prefs.restart(process) }
    }

    // MARK: Menu bar hider

    private static let hiderToggleName = "atelier.hider.toggle"
    private static let hiderDividerName = "atelier.hider.divider"

    /// Two status items, public API only. Everything left of the divider is pushed off the bar
    /// while it is collapsed. The pair first lands beside Control Centre, so every other icon
    /// starts out tucked; Command-drag an icon right of the divider to keep it showing.
    private func applyHider() {
        for item in [hiderToggle, hiderSeparator].compactMap({ $0 }) { NSStatusBar.system.removeStatusItem(item) }
        hiderToggle = nil
        hiderSeparator = nil
        menuBarCollapsed = false
        guard menuBarHider else { return }
        // A new status item lands at the far left, with nothing left of the divider to hide.
        // Seed a place by Control Centre once; macOS keeps it up to date when either is moved.
        for (name, slot) in [(Self.hiderToggleName, DesktopCompat.hiderToggleSlot), (Self.hiderDividerName, DesktopCompat.hiderDividerSlot)] {
            let key = "NSStatusItem Preferred Position " + name
            if store.object(forKey: key) == nil { store.set(slot, forKey: key) }
        }
        let toggle = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = Self.hiderToggleName
        toggle.button?.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Collapse menu bar items")
        toggle.button?.target = self
        toggle.button?.action = #selector(toggleHider)
        let separator = NSStatusBar.system.statusItem(withLength: 10)
        separator.autosaveName = Self.hiderDividerName
        separator.button?.image = NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Divider")
        separator.button?.appearsDisabled = true
        hiderToggle = toggle
        hiderSeparator = separator
    }

    @objc private func toggleHider() {
        setCollapsed(!menuBarCollapsed)
    }

    func setCollapsed(_ collapsed: Bool) {
        guard let separator = hiderSeparator else { return }
        menuBarCollapsed = collapsed
        separator.length = collapsed ? collapseLength(separator) : 10
        separator.button?.image = collapsed ? nil : NSImage(systemSymbolName: "line.diagonal", accessibilityDescription: "Divider")
        hiderToggle?.button?.image = NSImage(systemSymbolName: collapsed ? "chevron.right" : "chevron.left",
                                             accessibilityDescription: collapsed ? "Show menu bar items" : "Collapse menu bar items")
    }

    /// How long the divider grows. macOS 27 drops a divider wider than half its display, and a
    /// dropped divider hides nothing, so the length follows the display the menu bar is on.
    private func collapseLength(_ separator: NSStatusItem) -> Double {
        let window = separator.button?.window
        let screen = window?.screen ?? NSScreen.screens.first
        // The window is wider than the item by its insets; measured at rest, 16 pt on macOS 27.
        let padding = window.map { Double($0.frame.width) - separator.length } ?? 16
        let width = screen.map { Double($0.frame.width) } ?? 1440
        return DesktopCompat.hiderLength(major: MacPlatform.major, screenWidth: width,
                                         padding: separator.length == 10 ? padding : 16)
    }

    // MARK: Caffeinate

    /// Keeps the display awake for a while. The assertion goes with the process, and on quit.
    func caffeinate(minutes: Double?) {
        releaseCaffeinate()
        let reason = "Atelier Caffeinate" as CFString
        guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                          IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &assertion) == kIOReturnSuccess else {
            notice = "macOS refused to keep the display awake."
            return
        }
        guard let minutes else { caffeinateForever = true; return }
        caffeinateUntil = Date().addingTimeInterval(minutes * 60)
        let timer = Timer(timeInterval: minutes * 60, repeats: false) { _ in
            MainActor.assumeIsolated { DesktopPlus.shared.releaseCaffeinate() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        caffeinateTimer = timer
    }

    func releaseCaffeinate() {
        caffeinateTimer?.invalidate()
        caffeinateTimer = nil
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        caffeinateUntil = nil
        caffeinateForever = false
    }

    // MARK: Invoked tools

    /// One full-screen tool at a time, on the screen under the pointer. Escape always leaves.
    private func openTool(_ content: some View) {
        closeTool()
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let panel = FloatingPanel(frame: screen.frame)
        panel.level = .screenSaver
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: content.frame(width: screen.frame.width, height: screen.frame.height))
        panel.setFrame(screen.frame, display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        toolPanel = panel
        // Escape leaves, and so does a right-click: a way out that needs no keyboard focus.
        toolKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .rightMouseDown]) { event in
            guard event.type == .rightMouseDown || event.keyCode == UInt16(kVK_Escape) else { return event }
            MainActor.assumeIsolated { DesktopPlus.shared.closeTool() }
            return nil as NSEvent?
        }
        toolResignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                                                    queue: .main) { _ in
            // Switching apps (⌘-Tab, a click on another screen) takes the keyboard away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let plus = DesktopPlus.shared
                if let panel = plus.toolPanel, !panel.isKeyWindow { plus.closeTool() }
            }
        }
    }

    func closeTool() {
        if let toolKeyMonitor { NSEvent.removeMonitor(toolKeyMonitor) }
        toolKeyMonitor = nil
        if let toolResignObserver { NotificationCenter.default.removeObserver(toolResignObserver) }
        toolResignObserver = nil
        toolPanel?.orderOut(nil)
        toolPanel = nil
        annotating = false
        measuring = false
    }

    func toggleAnnotate() {
        if annotating { closeTool(); return }
        openTool(AnnotateCanvas(done: { MainActor.assumeIsolated { DesktopPlus.shared.closeTool() } }))
        annotating = true
    }

    func toggleRuler() {
        if measuring { closeTool(); return }
        openTool(RulerCanvas())
        measuring = true
    }

    /// The system loupe. It needs no capture permission and returns one colour.
    func pickColour() {
        // One loupe at a time; a second press while it is up does nothing.
        guard !sampling else { return }
        sampling = true
        NSColorSampler().show { picked in
            MainActor.assumeIsolated { DesktopPlus.shared.sampling = false }
            guard let picked, let rgb = picked.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                             Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
            let color = Color(nsColor: rgb)
            MainActor.assumeIsolated { DesktopPlus.shared.picked(hex: hex, color: color) }
        }
    }

    private func picked(hex: String, color: Color) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hex, forType: .string)
        colours.removeAll { $0 == hex }
        colours.insert(hex, at: 0)
        colours = Array(colours.prefix(8))
        look.swatch = (color, hex)
        let point = NSEvent.mouseLocation
        let frame = NSRect(x: point.x + 18, y: point.y - 64, width: 190, height: 52)
        swatchPanel?.orderOut(nil)
        swatchPanel = overlay(frame, level: NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1), content: SwatchToast(look: look))
        swatchGeneration += 1
        let current = swatchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard DesktopPlus.shared.swatchGeneration == current else { return }
            DesktopPlus.shared.swatchPanel?.orderOut(nil)
            DesktopPlus.shared.swatchPanel = nil
        }
    }
}

// MARK: - What works on this Mac

/// The Desktop+, Effects and wallpaper cards ask here before they show their controls.
@MainActor
enum DesktopAvailability {
    /// Live and still wallpapers, generated wallpapers and their previews all draw with Metal.
    static var metal: FeatureAvailability {
        LivingEngine.shared == nil ? .unavailable(LivingEngine.failure ?? "Live wallpapers need Metal graphics.") : .available
    }

    static var notchShelf: FeatureAvailability {
        MacPlatform.hasNotch ? .available : .limited("No notch on this display: the shelf opens below the middle of the menu bar.")
    }

    static var focusIsland: FeatureAvailability {
        MacPlatform.hasNotch ? .available : .limited("No notch on this display: the countdown sits right of the menu bar's centre.")
    }

    /// The display whose Dock is showing, and where on it the Dock sits.
    static func dock() -> (screen: NSScreen, edge: DesktopCompat.DockEdge)? {
        for screen in NSScreen.screens {
            let edge = DesktopCompat.dockEdge(frame: screen.frame, visible: screen.visibleFrame)
            if edge != .hidden { return (screen, edge) }
        }
        return nil
    }

    static var dockGlow: FeatureAvailability {
        switch dock()?.edge {
        case .bottom: .available
        case .left, .right: .limited("Glows under a Dock at the bottom of the screen. Yours is at the side.")
        case .hidden, nil: .limited("Glows while the Dock is showing. Yours is hidden, so the glow waits.")
        }
    }

    /// Keys typed in other apps reach a global monitor only with Accessibility.
    static var keystrokes: FeatureAvailability {
        AXIsProcessTrusted() ? .available
            : .limited("Needs Accessibility: allow Atelier in System Settings, Privacy & Security, Accessibility.")
    }

    /// Public status item API only: nothing to grant. macOS 27's shorter divider is fitted to the display.
    static var menuBarHider: FeatureAvailability { .available }

    /// Desktop Macs have no battery to pause on.
    static var pauseOnBattery: FeatureAvailability {
        BatteryMeter.hasInternalBattery ? .available : .unavailable("This Mac has no battery.")
    }
}

// MARK: - Overlay views

struct EdgeGlowRing: View {
    @ObservedObject var look: DesktopPlusLook
    let width: Double

    var body: some View {
        Rectangle()
            .strokeBorder(look.glowColor, lineWidth: width * 1.6)
            .blur(radius: width)
            .opacity(0.55)
    }
}

struct VignetteView: View {
    let strength: Double
    var body: some View {
        GeometryReader { geometry in
            let reach = hypot(geometry.size.width, geometry.size.height) / 2
            RadialGradient(colors: [.clear, .clear, .black.opacity(strength * 0.85)], center: .center,
                           startRadius: reach * 0.35, endRadius: reach)
        }
    }
}

enum GrainTexture {
    /// 256 px of luminance noise, made once. Tiled, it never repeats visibly at screen scale.
    @MainActor static let image: CGImage? = {
        let size = 256
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for index in 0..<(size * size) {
            let value = UInt8.random(in: 0...255, using: &generator)
            pixels[index * 4] = value
            pixels[index * 4 + 1] = value
            pixels[index * 4 + 2] = value
            pixels[index * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

struct GrainView: View {
    let image: CGImage
    let strength: Double
    var body: some View {
        Image(decorative: image, scale: 2).resizable(resizingMode: .tile)
            .opacity(0.03 + strength * 0.09)
    }
}

struct NightTintView: View {
    @ObservedObject var look: DesktopPlusLook
    let warmth: Double
    var body: some View {
        Color(red: 1, green: 0.52 - warmth * 0.12, blue: 0.12)
            .opacity(look.night * (0.08 + warmth * 0.22))
    }
}

/// Hairlines on whole points, and a stronger line every eight.
struct PixelGrid: View {
    let spacing: Double
    let scale: Double

    var body: some View {
        Canvas { context, size in
            let step = max(spacing, 2)
            let hairline = 1 / max(scale, 1)
            var minor = Path(), major = Path()
            var index = 0
            var x = 0.0
            while x <= size.width {
                let line = Path(CGRect(x: x, y: 0, width: hairline, height: size.height))
                if index % 8 == 0 { major.addPath(line) } else { minor.addPath(line) }
                x += step; index += 1
            }
            index = 0
            var y = 0.0
            while y <= size.height {
                let line = Path(CGRect(x: 0, y: y, width: size.width, height: hairline))
                if index % 8 == 0 { major.addPath(line) } else { minor.addPath(line) }
                y += step; index += 1
            }
            context.fill(minor, with: .color(Color(red: 0.3, green: 0.85, blue: 1).opacity(0.13)))
            context.fill(major, with: .color(Color(red: 0.3, green: 0.85, blue: 1).opacity(0.32)))
        }
    }
}

struct CursorHaloView: View {
    @ObservedObject var look: DesktopPlusLook
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [DS.Ink.accent.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 120))
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 3)
                .frame(width: look.haloShown ? 64 : 300, height: look.haloShown ? 64 : 300)
                .shadow(color: DS.Ink.accent, radius: 12)
        }
        .opacity(look.haloShown ? 1 : 0)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: look.haloShown)
    }
}

struct KeystrokeStrip: View {
    @ObservedObject var look: DesktopPlusLook
    var body: some View {
        HStack(spacing: 8) {
            ForEach(look.keys) { key in
                Text(key.label)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).frame(height: 54)
                    .atelierGlass(.regular, in: .rect(cornerRadius: 16, style: .continuous))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct SwatchToast: View {
    @ObservedObject var look: DesktopPlusLook
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(look.swatch?.color ?? .clear).frame(width: 28, height: 28)
                .overlay { RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.4), lineWidth: 0.5) }
            VStack(alignment: .leading, spacing: 1) {
                Text(look.swatch?.hex ?? "").font(.system(size: 14, weight: .semibold, design: .monospaced))
                Text("Copied").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.65))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .atelierGlass(.regular, in: .capsule)
    }
}

// MARK: - Annotate

private struct Stroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
    let color: Color
    let width: Double
}

struct AnnotateCanvas: View {
    let done: () -> Void
    @State private var strokes: [Stroke] = []
    @State private var current: Stroke?
    @State private var color = Color(red: 1, green: 0.27, blue: 0.35)
    @State private var width = 5.0
    private let palette: [Color] = [Color(red: 1, green: 0.27, blue: 0.35), .yellow, Color(red: 0.3, green: 0.9, blue: 0.5),
                                    Color(red: 0.35, green: 0.65, blue: 1), .white]

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.04)
            Canvas { context, _ in
                for stroke in strokes + (current.map { [$0] } ?? []) {
                    context.stroke(Self.path(stroke.points), with: .color(stroke.color),
                                   style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
                }
            }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if current == nil { current = Stroke(points: [value.startLocation], color: color, width: width) }
                    current?.points.append(value.location)
                }
                .onEnded { _ in
                    if let current { strokes.append(current) }
                    current = nil
                })
            toolbar.padding(.top, 54)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            ForEach(palette.indices, id: \.self) { index in
                Button { color = palette[index] } label: {
                    Circle().fill(palette[index]).frame(width: 20, height: 20)
                        .overlay { Circle().strokeBorder(.white, lineWidth: color == palette[index] ? 2 : 0).padding(-3) }
                        .contentShape(Circle())
                }
                .buttonStyle(Pressable(scale: 0.9))
                .accessibilityLabel("Colour \(index + 1)")
            }
            Divider().frame(height: 18)
            Segments(selection: $width, options: [(3.0, "Fine"), (5.0, "Pen"), (12.0, "Marker")]).frame(width: 190)
            Button { if !strokes.isEmpty { strokes.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(Pressable()).keyboardShortcut("z", modifiers: .command).accessibilityLabel("Undo")
            Button { strokes = [] } label: { Image(systemName: "trash") }
                .buttonStyle(Pressable()).accessibilityLabel("Clear")
            Button(action: done) { Text("Done  ⎋").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(Pressable())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16).frame(height: 46)
        .atelierGlass(.regular, in: .capsule)
    }

    /// Midpoint curves, so a quick scribble reads as ink rather than a polyline.
    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else { points.dropFirst().forEach { path.addLine(to: $0) }; return path }
        for index in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[index].x + points[index + 1].x) / 2, y: (points[index].y + points[index + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[index])
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }
}

// MARK: - Ruler

struct RulerCanvas: View {
    @State private var pointer: CGPoint?
    @State private var start: CGPoint?
    @State private var end: CGPoint?
    private let ink = Color(red: 0.3, green: 0.85, blue: 1)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.03)
                if let pointer {
                    Path { path in
                        path.move(to: CGPoint(x: pointer.x, y: 0)); path.addLine(to: CGPoint(x: pointer.x, y: geometry.size.height))
                        path.move(to: CGPoint(x: 0, y: pointer.y)); path.addLine(to: CGPoint(x: geometry.size.width, y: pointer.y))
                    }
                    .stroke(ink.opacity(0.75), lineWidth: 0.5)
                    label("\(Int(pointer.x)), \(Int(pointer.y))").position(x: pointer.x + 52, y: pointer.y + 18)
                }
                if let start, let end {
                    let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
                    Rectangle().fill(ink.opacity(0.12)).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                    Rectangle().strokeBorder(ink, lineWidth: 1).frame(width: box.width, height: box.height).offset(x: box.minX, y: box.minY)
                    label("\(Int(box.width)) × \(Int(box.height)) pt").position(x: box.midX, y: box.maxY + 18)
                }
                HStack(spacing: 10) {
                    Text("Drag to measure · ⌘C copies · Esc or right-click to leave")
                        .font(.system(size: 12, weight: .medium))
                    Button { DesktopPlus.shared.closeTool() } label: { Text("Done  ⎋").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(Pressable())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 32).atelierGlass(.regular, in: .capsule)
                .frame(maxWidth: .infinity).padding(.top, 54)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase { pointer = point } else { pointer = nil }
            }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in start = value.startLocation; end = value.location; pointer = value.location })
            .background {
                Button("") { copy() }.keyboardShortcut("c", modifiers: .command).opacity(0)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(.white)
            .padding(.horizontal, 7).frame(height: 20)
            .background(.black.opacity(0.7), in: .capsule)
    }

    private func copy() {
        guard let start, let end else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(Int(abs(end.x - start.x))) × \(Int(abs(end.y - start.y)))", forType: .string)
    }
}
