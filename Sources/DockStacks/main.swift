import AppKit
import SwiftUI
import DockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var launchedWithDocument = false

    func applicationWillTerminate(_ notification: Notification) {
        MinimizeRedirect.shared.releaseAll()
        OwnDock.restoreOnQuit()
        HyperKey.shared.restoreOnQuit()
        MousePrecision.shared.restoreOnQuit()
        LightEngine.shared.restoreOnQuit()
        SystemDockPeek.shared.restoreOnQuit()
        OwnDockGestures.shared.restoreOnQuit()
        NotchFree.shared.restoreOnQuit()
        TitleBarGestures.shared.restoreOnQuit()
        RadialMenu.shared.restoreOnQuit()
        SoundMixer.shared.restoreOnQuit()
        VirtualDisplays.shared.restoreOnQuit()
        DisplayMemory.shared.restoreOnQuit()
        Updater.shared.restoreOnQuit()
        ExternalMonitors.shared.restoreOnQuit()
        FanControl.shared.restoreOnQuit()
        EdgeStash.shared.restoreOnQuit()
        CrashGuard.noteCleanExit()
        // Remove Everything: the restores above may have written a key or the clean-exit marker.
        AtelierRevert.finishRemoval()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        WindowBorders.shared.resume()
        WebWallpaper.shared.resume()
        SpacesIndicator.shared.resume()
        AppearanceSchedule.shared.resume()
        TypingSounds.shared.resume()
        InactiveDim.shared.resume()
        ScreenCorners.shared.resume()
        WheelDirection.shared.resume()
        QuitGuard.shared.resume()
        LightEngine.shared.resume()
        NotchFree.shared.resume()
        VirtualDisplays.shared.resume()
        AtelierHUD.shared.resume()
        ExternalMonitors.shared.resume()
        KeyboardLight.shared.resume()
        ThermalsMenu.shared.resume()
        FanControl.shared.resume()
        TrackpadGestures.shared.resume()
        TitleBarGestures.shared.resume()
        SoundMixer.shared.resume()
        MousePrecision.shared.resume()
        HyperKey.shared.resume()
        WindowGrab.shared.resume()
        FocusFollowsMouse.shared.resume()
        WindowSwitcher.shared.resume()
        RadialMenu.shared.resume()
        EdgeStash.shared.resume()
        // The Dock bridge: detect its state; it re-loads only if the owner enabled Load at Login.
        Task { await DockBridge.shared.refresh() }
        BeyondSIP.shared.resume()
        MenuCalendar.shared.resume()
        CrashGuard.start()
        ScrollActivity.install()
        // A crash while the system Dock was replaced must not leave it hidden.
        OwnDock.recoverAtLaunch()
        AppCatalog.shared.refresh()
        Mood.shared.refresh()
        HotKey.install()
        Effects.shared.start()
        ClipboardHistory.shared.apply()
        // After HotKey.install: Carbon runs the newest handler first.
        WindowEngine.shared.start()
        DisplayMemory.shared.resume()
        Updater.shared.resume()
        Orbit.shared.start()
        OwnDock.shared.start()
        SystemDockPeek.shared.resume()
        OwnDockGestures.shared.resume()
        LiveWallpaper.shared.start()
        WidgetBoard.shared.start()
        // Once: an old Desktop Clock or Desktop Vitals becomes a widget in the same place.
        WidgetBoard.shared.adoptDesktopEffects(from: Effects.shared)
        WidgetBoard.shared.restoreClassicDesktopLooks()
        ThemeEngine.shared.start()
        PluginRegistry.shared.start()
        KeyRemapper.shared.start()
        DailyWallpaper.shared.start()
        installStatusItem()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Mood.shared.refresh() } }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            MainActor.assumeIsolated { AppCatalog.shared.refresh() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { ThemeEngine.shared.tick(); SceneSchedule.tick() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // Back from a crash: quietly, with no window in the owner's face.
            if !self.launchedWithDocument, !CommandLine.arguments.contains("--relaunched-after-crash") { ManagerWindow.shared.show() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        launchedWithDocument = true
        guard let url = urls.first else { return }
        if ThemeEngine.shared.handleOpen(url) { return }
        if url.scheme == "dockstacks" || url.scheme == "atelier" {
            openFromScheme(url)
        } else {
            BubbleController.shared.toggle(url)
        }
    }

    private func openFromScheme(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        if url.host() == "studio" {
            let chapter = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
            ManagerWindow.shared.show(chapter: chapter)
            return
        }
        if url.host() == "grant" {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }
        if url.host() == "mintest" {
            MinimizeRedirect.shared.test(up: url.query()?.contains("up") == true)
            return
        }
        if url.host() == "scrolltest" {
            if url.query()?.contains("real") == true {
                RealScrollProbe.shared.wheel = url.query()?.contains("wheel") == true
                RealScrollProbe.shared.jiggle = url.query()?.contains("still") != true
                RealScrollProbe.shared.run(in: NSApp.windows.first { $0.title == "Atelier" })
            } else if url.query()?.contains("picker") == true {
                ScrollProbe.shared.run(in: NSApp.windows.first { $0.title.hasPrefix("Icon for") && $0.isVisible }, minHeight: 200)
            } else {
                ScrollProbe.shared.run(in: NSApp.windows.first { $0.title == "Atelier" })
            }
            return
        }
        if url.host() == "clicktest", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let x = items.first(where: { $0.name == "x" })?.value.flatMap(Double.init),
           let y = items.first(where: { $0.name == "y" })?.value.flatMap(Double.init) {
            // A real click through the window server, for checking the minimise tap.
            let point = CGPoint(x: x, y: y)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            return
        }
        if url.host() == "icontest", let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value {
            // Checks a tile's own icon end to end; "reset" puts the original back.
            if url.query()?.contains("reset") == true {
                OwnDock.shared.resetIcon(id)
            } else if let image = NSImage(systemSymbolName: "star.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 256, weight: .regular)) {
                OwnDock.shared.setIcon(image, for: id)
            }
            return
        }
        if url.host() == "previewtest" {
            // Checks the stage's dock preview path: a design, or nothing to end it.
            if url.query() == "demo" {
                StagePreview.shared.begin(.demo("test.corner", "Atelier Hot Corners", isOn: false, region: nil, Demos.corner("Mission Control")))
            } else if url.query() == "orbit" {
                StagePreview.shared.begin(.demo("test.orbit", "Drift", isOn: false, region: nil, Demos.orbitDrift))
            } else if let name = url.query(), let design = DockDesign(rawValue: name) {
                StagePreview.shared.begin(.dock("test." + name, design.title) { look in
                    (look.design, look.appearance) = OwnDock.choosing(design, design: look.design, appearance: look.appearance)
                })
            } else {
                StagePreview.shared.clear()
            }
            return
        }
        if url.host() == "statedump" {
            // What the app reads for every setting, to compare against `defaults read`.
            let engine = PersonalModel.shared.engine
            var lines: [String] = []
            for s in PersonalCatalog.all {
                let raw = engine.prefs.raw(s.key, domain: engine.prefs.storeDomain(s), currentHost: s.currentHost)
                let value = engine.prefs.read(s)
                lines.append(["P", s.area.rawValue, engine.prefs.storeDomain(s), s.currentHost ? "host" : "any", s.key,
                              raw.map { "\($0)" } ?? "-", value.map { "\($0)" } ?? "-",
                              PersonalRow.isOn(s, value) ? "ON" : "off", s.fallback.map { "\($0)" } ?? "-",
                              engine.prefs.isReachable(s) ? "ok" : "blocked", s.title,
                              s.domain == "NSGlobalDomain" ? (UserDefaults.standard.object(forKey: s.key).map { "\($0)" } ?? "-") : "."].joined(separator: "\t"))
            }
            for t in TweakCatalog.all {
                lines.append(["T", t.area.rawValue, t.domain, "any", t.key, Prefs.current(t.key, domain: t.domain) ?? "-", t.value,
                              Prefs.matches(t.key, value: t.value, domain: t.domain) ? "ON" : "off", "-", "ok", t.title].joined(separator: "\t"))
            }
            try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "atelier-state.tsv", atomically: true, encoding: .utf8)
            return
        }
        if url.host() == "hovertest" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let n = { (k: String) in items.first(where: { $0.name == k })?.value.flatMap(Double.init) }
            if let x = n("x"), let y = n("y"), let w = n("w") { HoverProbe.shared.line = CGRect(x: x, y: y, width: w, height: 1) }
            else { HoverProbe.shared.line = nil }
            HoverProbe.shared.run(in: NSApp.windows.first { $0.title == "Atelier" })
            return
        }
        if url.host() == "calendar" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let on = items.first(where: { $0.name == "on" })?.value { MenuCalendar.shared.enabled = on == "1" }
            else if items.contains(where: { $0.name == "close" }) { MenuCalendar.shared.closePopover() }
            else { MenuCalendar.shared.openPopover() }
            return
        }
        if url.host() == "pickertest" {
            IconPickerPanel.show(query: "folder", title: "Icon for Test", onPick: { _ in })
            return
        }
        if url.host() == "diag" {
            // Permission state, for checking a build without the UI.
            let rendered = LivingCanvas.rendered
            LivingCanvas.rendered = 0
            let lines = StudioThisMac.facts().report.split(separator: "\n").map(String.init)
                + FrameMeter.shared.report() + Orbit.shared.diagnostics() + ["wallpaperFrames=\(rendered)",
                "accessibility=\(AXIsProcessTrusted())",
                HyperKey.shared.diagnostics, WindowGrab.shared.diagnostics, FocusFollowsMouse.shared.diagnostics, WindowSwitcher.shared.diagnostics, MenuCalendar.shared.diagnostics, LightEngine.shared.diagnostics, NotchFree.shared.diagnostics, VirtualDisplays.shared.diagnostics, DisplayMemory.shared.diagnostics, Updater.shared.diagnostics, AtelierHUD.shared.diagnostics, ExternalMonitors.shared.diagnostics, ThermalsMenu.shared.diagnostics, FanControl.shared.diagnostics,
                TrackpadGestures.shared.diagnostics, TitleBarGestures.shared.diagnostics, SoundMixer.shared.diagnostics, MousePrecision.shared.diagnostics, InstantSpaces.shared.diagnostics, DockBridge.shared.diagnostics, BeyondSIP.diagnostics, SystemDockPeek.shared.diagnostics, EdgeStash.shared.diagnostics, RadialMenu.shared.diagnostics, OwnDockGestures.shared.diagnostics,
                "typingPlayed=\(TypingSounds.shared.played) appearanceDark=\(Appearance.isDark) " +
                "dimShaded=\(InactiveDim.shared.shaded) dimBelow=\(InactiveDim.shared.below.map(String.init) ?? "-") " +
                "roundCorners=\(ScreenCorners.shared.count) wheelTap=\(WheelDirection.shared.tapActive) wheelFlipped=\(WheelDirection.shared.flipped) wheelGlided=\(WheelDirection.shared.glided) " +
                "quitTap=\(QuitGuard.shared.tapActive) quitStopped=\(QuitGuard.shared.stopped) quitQuits=\(QuitGuard.shared.quits) " +
                "bordersTarget=\(WindowBorders.shared.target.map { "\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" } ?? "-")",
                "minimize=\(MinimizeRedirect.shared.note)",
                "stage=preview:\(ManagerModel.current?.preview != nil) look:\(ManagerModel.current?.previewLook != nil) chapter:\(ManagerModel.current?.chapter.rawValue ?? "-") active:\(StagePreview.shared.active?.id ?? "-") dockPointer:\(StageDockPointer.shared.point.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-")",
                "scrollProbe=\(ScrollProbe.shared.note)",
            ]
            try? lines.joined(separator: "\n").write(toFile: NSTemporaryDirectory() + "atelier-diag.txt", atomically: true, encoding: .utf8)
            return
        }
        if url.host() == "effect", let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            // Effects can be driven from Shortcuts: atelier://effect?skin=aurora&clock=1
            let effects = Effects.shared
            for item in items {
                let value = item.value ?? ""
                switch item.name {
                case "skin": effects.skin = SkinPreset(rawValue: value) ?? .none
                case "clock": WidgetBoard.shared.desktopClock = value == "1"
                case "focus": effects.focus = value == "1"
                case "shelf": effects.shelf = value == "1"
                case "rounded": effects.rounded = Double(value) ?? 0
                case "living": effects.living = Hue(rawValue: value)
                case "pulse": effects.pulse = value == "1"
                case "ripples": effects.ripples = value == "1"
                case "line": effects.dayLine = value == "1"
                case "glow": effects.dockGlow = value == "1"
                case "widgets": WidgetBoard.shared.desktopVitals = value == "1"
                case "clockstyle": WidgetBoard.shared.desktopClockStyle = ClockStyle(rawValue: value) ?? .thin
                case "focusmin": effects.startFocus(minutes: Double(value) ?? 25)
                case "focusstop": effects.focusEnd = nil
                case "flash": effects.flash(.purple)
                case "dockedge": LiveDock.setOrientation(value)
                case "docksize": LiveDock.setSize(Double(value) ?? 64)
                case "layout": if let layout = WindowGeometry.Layout(rawValue: value) { WindowEngine.shared.apply(layout) }
                case "shuffle": WindowEngine.shared.shuffle()
                case "compare": withAnimation(.smooth(duration: 0.55)) { StageChanges.shared.showingBefore = value == "before" }
                case "photo":
                    // photo=featured:Category or nasa:query — sets the first result.
                    let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
                    if let source = WallpaperSource(rawValue: parts.first ?? "") {
                        Task { @MainActor in
                            if let first = try? await WallpaperLibrary.search(source, query: parts.count > 1 ? parts[1] : "").first {
                                _ = try? await WallpaperLibrary.use(first)
                            }
                        }
                    }
                case "restorewallpaper": Effects.shared.restoreOriginalWallpaper()
                case "replace": OwnDock.shared.replaceSystem = value == "1"
                case "owndock": OwnDock.shared.enabled = value == "1"
                case "orbit": Orbit.shared.toggle()
                case "board": WidgetBoard.shared.enabled = value == "1"
                case "widget":
                    // widget=calendar:1
                    let parts = value.split(separator: ":")
                    if let kind = parts.first.flatMap({ WidgetKind(rawValue: String($0)) }) {
                        WidgetBoard.shared.set(kind, on: parts.last != "0")
                    }
                case "livewall": LiveWallpaper.shared.enabled = value == "1"
                case "shader": if let shader = LivingShader(rawValue: value) { LiveWallpaper.shared.shader = shader }
                case "look": if let look = Look.all.first(where: { $0.name == value }) { effects.apply(look) }
                default: break
                }
            }
            return
        }
        if url.host() == "spaces" { InstantSpaces.shared.handle(url); return }
        if url.host() == "light" { LightEngine.shared.handleTest(items ?? []); return }
        if url.host() == "notchfree" { NotchFree.shared.handleTest(items ?? []); return }
        if url.host() == "virtual" { VirtualDisplays.shared.handleTest(items ?? []); return }
        if url.host() == "update" { Updater.shared.handleTest(items ?? []); return }
        if url.host() == "displaymemory" { DisplayMemory.shared.handleTest(items ?? []); return }
        if url.host() == "ddc" { ExternalMonitors.shared.handleTest(items ?? []); return }
        if url.host() == "fans" { FanControl.shared.handleTest(items ?? []); return }
        if url.host() == "mixer" { SoundMixer.shared.handleTest(items ?? []); return }
        if url.host() == "titlebar" { TitleBarGestures.shared.handleTest(items ?? []); return }
        if url.host() == "radial" { RadialMenu.shared.handleTest(items ?? []); return }
        if url.host() == "dockpeek" { SystemDockPeek.shared.handleTest(items ?? []); return }
        if url.host() == "dockgestures" { OwnDockGestures.shared.handleTest(items ?? []); return }
        if url.host() == "stash" { EdgeStash.shared.handleTest(items ?? []); return }
        if url.host() == "hud" {
            let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "preview" }?.value
            AtelierHUD.shared.preview(kind: HUDKind(rawValue: kind ?? "") ?? .volume)
            return
        }
        if url.host() == "gesture" {
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                if item.name == "simulate", let gesture = item.value.flatMap(TrackpadGesture.init(rawValue:)) { TrackpadGestures.shared.simulate(gesture) }
                if item.name == "haptic" { Haptics.shared.play(item.value.flatMap { ["light": .light, "medium": .medium, "firm": .firm][$0] } ?? .medium) }
            }
            return
        }
        if url.host() == "command" { CommandController.shared.toggle(); return }
        guard url.host() == "open", let name = items?.first(where: { $0.name == "name" })?.value else { return }
        let stack = StackStore.url(forTitle: name)
        if FileManager.default.fileExists(atPath: stack.path) { BubbleController.shared.toggle(stack) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ManagerWindow.shared.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set by "Quit Atelier Completely" in the menu bar item, the one way a person ends it.
    static var quitForReal = false

    /// Atelier behaves like part of the system: ⌘Q and Quit close the Studio to the menu bar,
    /// and its Dock, widgets and effects carry on. It really quits when the person chooses
    /// "Quit Atelier Completely", or when macOS logs out, restarts or shuts down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))
        if Self.quitForReal || reason != nil { return .terminateNow }
        ManagerWindow.shared.studioWindow?.close()
        return .terminateCancel
    }

    /// Hiding Atelier (⌘H, Hide in a Dock menu, Hide Others from another app) would take its
    /// Dock, widgets and effects off the screen. Only the Studio window goes; Atelier's panels
    /// are marked as staying, and the app is unhidden at once.
    func applicationWillHide(_ notification: Notification) {
        let studio = ManagerWindow.shared.studioWindow
        for window in NSApp.windows where window !== studio { window.canHide = false }
    }

    func applicationDidHide(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.unhideWithoutActivation()
            ManagerWindow.shared.studioWindow?.close()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Atelier")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(action("Open Atelier", #selector(openManager)))
        menu.addItem(action("Command", #selector(openCommand)))
        let stacks = StackStore.list()
        if !stacks.isEmpty {
            menu.addItem(.separator())
            for url in stacks {
                let entry = action(url.deletingPathExtension().lastPathComponent, #selector(openStack(_:)))
                entry.representedObject = url
                menu.addItem(entry)
            }
        }
        let profiles = ProfileStore.load()
        if !profiles.isEmpty {
            menu.addItem(.separator())
            for profile in profiles {
                let entry = action(profile.name, #selector(applyProfile(_:)))
                entry.representedObject = profile.id.uuidString
                menu.addItem(entry)
            }
        }
        menu.addItem(.separator())
        menu.addItem(action("Quit Atelier Completely", #selector(quit)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openManager() { ManagerWindow.shared.show() }
    @objc private func openCommand() { CommandController.shared.toggle() }
    @objc private func openStack(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { BubbleController.shared.toggle(url) }
    }

    @objc private func quit() {
        AppDelegate.quitForReal = true
        NSApp.terminate(nil)
    }

    @objc private func applyProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let profile = ProfileStore.load().first(where: { $0.id.uuidString == id }) else { return }
        let url = profile.url, name = profile.name
        Task.detached { try? DockStore.apply(snapshotAt: url, label: "Scene \(name)") }
    }
}

// Build helper: writes the app's own icon as a PNG.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--export-icon" {
    var spec = IconSpec()
    spec.style = .symbol
    spec.symbol = "square.stack.3d.up.fill"
    spec.color = 2
    if let tiff = IconRenderer.image(spec, title: "", items: []).tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    }
    exit(0)
}


// Command line, for scripts and Shortcuts. Prints the stack path.
if CommandLine.arguments.count >= 3 {
    let args = CommandLine.arguments
    do {
        switch args[1] {
        case "--apply":
            let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
            let document = try JSONDecoder().decode(StackDocument.self, from: data)
            let existing = args.count > 3 ? URL(fileURLWithPath: args[3]) : nil
            print(try StackActions.apply(document, existing: existing).path)
            exit(0)
        case "--delete":
            try StackActions.delete(URL(fileURLWithPath: args[2]))
            exit(0)
        case "--full-width":
            try DockStore.update("Full Width") { Tiles.setFullWidth(args[2] == "on", in: &$0) }
            exit(0)
        default:
            break
        }
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

