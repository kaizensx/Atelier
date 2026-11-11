import AppKit
import DockCore
import SwiftUI

// MARK: - Revert everything
//
// One place that knows every change Atelier makes to macOS and how each module puts it back.
// It only calls each module's own restore (its ledger, its switch, its restoreOnQuit); it never
// guesses a value. Two ways in, from Settings:
//
//   * Revert All macOS Changes: everything back, Atelier stays installed with its features off.
//   * Remove Everything: the same, then Atelier's stacks, login item, crash guard, data,
//     caches and settings go, and it quits for real (so applicationWillTerminate runs every
//     module's restoreOnQuit, the macOS Dock included).
//
// Both first show `RevertSheet`, a summary built from the live ledgers, so nothing happens
// that the person has not seen listed.

@MainActor
enum AtelierRevert {
    struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
    }

    /// Set while Remove Everything finishes, so the app delegate deletes Atelier's settings
    /// again after the last restoreOnQuit has written to them.
    private(set) static var removing = false

    // MARK: What would change

    /// The changes in place right now, from each module's own record.
    static func plan() -> [Item] {
        var items: [Item] = []
        func add(_ id: String, _ title: String, _ detail: String, _ symbol: String) {
            items.append(Item(id: id, title: title, detail: detail, symbol: symbol))
        }
        let tweaks = changedTweaks().count
        if tweaks > 0 { add("tweaks", count(tweaks, "tweak"), "Dock, Finder, window and menu bar keys go back to what they were.", "slider.horizontal.3") }
        let personal = PersonalModel.shared.changedCount
        if personal > 0 || DesktopIconsCard.hasStoredOriginal {
            add("personal", personal > 0 ? count(personal, "system setting") : "Desktop icon layout",
                "Each one goes back to its value before Atelier, absent keys included.", "gearshape.2")
        }
        if ThemeEngine.shared.canRevert { add("theme", "Theme", "The look from before your first theme: accent, icons, wallpaper.", "paintpalette") }
        let icons = CustomIcons.shared.paths.count
        if icons > 0 { add("icons", count(icons, "custom icon"), "Folders and apps get their own icons back.", "folder") }
        if Effects.shared.replacedWallpaper || LiveWallpaper.shared.enabled || DailyWallpaper.shared.enabled {
            add("wallpaper", "Wallpaper", "Your own wallpaper comes back. Live and daily wallpapers turn off.", "photo")
        }
        if OwnDock.shared.replacesSystemDock { add("dock", "macOS Dock", "Apple's Dock comes back; Atelier's Dock stops replacing it.", "dock.rectangle") }
        if HyperKey.shared.enabled || !KeyRemapper.shared.active.isEmpty {
            add("keys", "Keyboard mapping", "Hyper Key and remapped keys are cleared from hidutil.", "keyboard")
        }
        if KeyboardLight.shared.available && !KeyboardLight.shared.isDefault {
            add("kbd", "Keyboard light", "Auto-brightness on, and the rest time this Mac had before.", "light.max")
        }
        if MousePrecision.shared.enabled { add("mouse", "Mouse precision", "Each mouse gets its own acceleration back.", "computermouse") }
        if NotchFree.shared.enabled { add("notch", "Notch-Free", "The built-in display goes back to its size with the notch.", "macbook") }
        let virtual = VirtualDisplays.shared.specs.count
        if virtual > 0 { add("virtual", count(virtual, "virtual display"), "Mirroring is undone and each one is removed.", "rectangle.on.rectangle") }
        let light = LightEngine.shared
        if light.dimOn || light.candleOn || light.boostOn {
            add("light", "Display light", "Dim, warmth and XDR Boost off: the system's own colour curves return.", "sun.max")
        }
        if !lightModeApps().isEmpty { add("lightapps", count(lightModeApps().count, "app") + " kept in Light mode", "They follow the system appearance again.", "circle.lefthalf.filled") }
        if DesktopPlus.shared.cleanDesktop { add("clean", "Clean desktop", "Desktop icons show again.", "menubar.dock.rectangle") }
        if FanControl.shared.enabled { add("fans", "Fan Control", "The fans go back to automatic.", "fan") }
        return items
    }

    /// Steps that need an administrator password. Offered as switches in the sheet.
    static var fanHelperInstalled: Bool { FanControl.shared.helper != .absent }
    static var bridgeInstalled: Bool { DockBridge.shared.installed }

    /// What Remove Everything takes away besides the reverts.
    static func removalPlan() -> [Item] {
        var items: [Item] = []
        let stacks = StackStore.list().count
        if stacks > 0 { items.append(Item(id: "stacks", title: count(stacks, "stack"), detail: "Their tiles leave the Dock.", symbol: "square.stack.3d.up")) }
        if LoginItem.enabled { items.append(Item(id: "login", title: "Open at Login", detail: "Atelier no longer opens when you log in.", symbol: "power")) }
        items.append(Item(id: "guard", title: "Crash guard", detail: "The AtelierGuard launch agent is unregistered.", symbol: "lifepreserver"))
        items.append(Item(id: "data", title: "Atelier's data", detail: "Stacks, scenes, timeline, themes, the kept previous version, caches and settings.", symbol: "trash"))
        return items
    }

    // MARK: Doing it

    /// Puts every macOS change back and leaves the features off. Admin steps run only when
    /// asked, with one administrator prompt between them. Returns what could not be undone.
    static func everything(removeFanHelper: Bool, removeBridge: Bool, progress: @escaping @MainActor (String) -> Void) async -> [String] {
        var problems: [String] = []

        progress("Handing the fans back…")
        FanControl.shared.setPreset(.system)

        progress("Putting tweaks back…")
        problems += await revertTweaks()

        progress("Putting system settings back…")
        problems += PersonalModel.shared.revertAll()

        progress("Putting the look back…")
        if ThemeEngine.shared.canRevert { ThemeEngine.shared.revert() }
        for path in CustomIcons.shared.paths { CustomIcons.shared.revert(path) }
        if let notice = CustomIcons.shared.notice, !CustomIcons.shared.paths.isEmpty { problems.append(notice) }
        // After the theme, which may itself set a wallpaper: the owner's own goes on last.
        LiveWallpaper.shared.enabled = false
        DailyWallpaper.shared.enabled = false
        Effects.shared.restoreOriginalWallpaper()
        for app in lightModeApps() { LightApps.shared.set(app, light: false) }
        if DesktopPlus.shared.cleanDesktop { DesktopPlus.shared.cleanDesktop = false }

        progress("Bringing the macOS Dock back…")
        if OwnDock.shared.replaceSystem { OwnDock.shared.replaceSystem = false }
        OwnDock.restoreOnQuit()

        progress("Clearing keyboard and mouse changes…")
        if !KeyRemapper.shared.active.isEmpty { KeyRemapper.shared.clear() }
        if HyperKey.shared.enabled { HyperKey.shared.enabled = false }
        if KeyboardLight.shared.available && !KeyboardLight.shared.isDefault { KeyboardLight.shared.restoreDefaults() }
        if MousePrecision.shared.enabled { MousePrecision.shared.enabled = false }

        progress("Putting the displays back…")
        // Switches off through each module's own path, which restores what it changed; the
        // restoreOnQuit calls are for quitting and would also stop what stays on.
        if NotchFree.shared.enabled { NotchFree.shared.setEnabled(false, confirm: false) }
        if !VirtualDisplays.shared.specs.isEmpty { VirtualDisplays.shared.removeAll() }
        let light = LightEngine.shared
        if light.dimOn { light.dimOn = false }
        if light.candleOn { light.candleOn = false }
        if light.boostOn { light.boostOn = false }

        var admin: [String] = []
        var reasons: [String] = []
        if removeFanHelper, fanHelperInstalled {
            FanControl.shared.handBackForRemoval()
            admin.append(FanHelperInstall.removeScript)
            reasons.append("remove the fan helper")
        }
        if removeBridge, bridgeInstalled {
            admin.append(DockBridge.shared.uninstallScript)
            reasons.append("remove the Dock Bridge")
        }
        if !admin.isEmpty {
            progress("Waiting for the administrator password…")
            if let failure = await AdminPrompt.run(admin.joined(separator: "; "), reason: reasons.joined(separator: " and ")) {
                problems.append("Could not \(reasons.joined(separator: " and ")): \(failure)")
            }
            FanControl.shared.refreshHelper()
            await DockBridge.shared.refresh()
        }
        return problems
    }

    /// Everything above, then Atelier itself: stacks out of the Dock, login item, crash guard,
    /// data, caches, settings. Ends by quitting for real, which runs every restoreOnQuit.
    static func removeAtelier(removeFanHelper: Bool, removeBridge: Bool, progress: @escaping @MainActor (String) -> Void) async -> [String] {
        var problems = await everything(removeFanHelper: removeFanHelper, removeBridge: removeBridge, progress: progress)

        progress("Taking stacks out of the Dock…")
        let paths = StackStore.list().map(\.path)
        let dock = await Task.detached(priority: .userInitiated) { () -> String? in
            do {
                try DockStore.update("Remove Atelier") { plist in
                    for path in paths { Tiles.detach(path: path, from: &plist) }
                }
                return nil
            } catch { return error.localizedDescription }
        }.value
        if let dock { problems.append("Stacks: \(dock)") }

        progress("Removing the login item and crash guard…")
        try? LoginItem.set(false)
        await CrashGuard.unregister()

        progress("Deleting Atelier's data…")
        // The picture on the desktop may still be one Atelier generated, if the owner's own could
        // not be put back: that folder stays, so the desktop never points at a deleted file.
        let keepWallpapers = Effects.shared.replacedWallpaper
        if keepWallpapers {
            problems.append("Your own wallpaper could not be put back, so Atelier's wallpaper folder was kept. Choose a wallpaper in System Settings, then delete ~/Library/Application Support/DockStacks.")
        }
        await Task.detached(priority: .userInitiated) { deleteFiles(keepWallpapers: keepWallpapers) }.value
        removing = true
        deleteSettings()
        return problems
    }

    /// Quits for real. applicationShouldTerminate cancels any other quit (Atelier closes to the
    /// menu bar), which is why Remove Everything used to leave Atelier running.
    static func quitAfterRemoval() {
        AppDelegate.quitForReal = true
        NSApp.terminate(nil)
    }

    /// From applicationWillTerminate, after every restoreOnQuit: some of them write a key on the
    /// way out, so the settings and the crash guard's clean-exit marker are removed once more.
    static func finishRemoval() {
        guard removing else { return }
        deleteSettings()
        try? FileManager.default.removeItem(at: CrashGuard.folder)
        let atelier = CrashGuard.folder.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: atelier.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: atelier)
        }
    }

    // MARK: Pieces

    private static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }

    /// Tweaks Atelier turned on: each keeps the value it replaced under "original.<id>".
    private static func changedTweaks() -> [Tweak] {
        TweakCatalog.all.filter { UserDefaults.standard.object(forKey: "original." + $0.id) != nil }
    }

    /// The same as ManagerModel.setTweak(_, on: false), for all of them at once, each process
    /// restarted once at the end.
    private static func revertTweaks() async -> [String] {
        struct Undo: Sendable { let id: String, domain: String, key: String, type: String, original: String, title: String }
        let store = UserDefaults.standard
        let tweaks = changedTweaks()
        let undo = tweaks.map { Undo(id: $0.id, domain: $0.domain, key: $0.key, type: $0.type,
                                     original: store.string(forKey: "original." + $0.id) ?? "", title: $0.title) }
        let processes = Set(tweaks.compactMap(\.process))
        let dockTouched = tweaks.contains { $0.domain == "com.apple.dock" }
        let failed = await Task.detached(priority: .userInitiated) { () -> [String: String] in
            if dockTouched { _ = try? Timeline.record(DockStore.read(), label: "Revert all tweaks") }
            var failed: [String: String] = [:]
            for item in undo {
                do {
                    if item.original.isEmpty { try Prefs.delete(item.key, domain: item.domain) }
                    else { try Prefs.write(item.key, type: item.type, value: item.original, domain: item.domain) }
                } catch { failed[item.id] = "\(item.title): \(error.localizedDescription)" }
            }
            for process in processes.sorted() { Prefs.restart(process) }
            return failed
        }.value
        // A tweak that failed keeps its memory, so a later try still knows the original.
        for tweak in tweaks where failed[tweak.id] == nil { store.removeObject(forKey: "original." + tweak.id) }
        return failed.values.sorted()
    }

    private static func lightModeApps() -> [LightApp] {
        LightApps.shared.apps.filter { !$0.sandboxed && LightApps.shared.isLight($0) }
    }

    /// Atelier's folders: Application Support (DockStacks and Atelier: themes, the kept previous
    /// version, the crash guard) and its caches (updates, icons, weather).
    nonisolated private static func deleteFiles(keepWallpapers: Bool) {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        var own = [Support.root]
        if keepWallpapers {
            own = ((try? fm.contentsOfDirectory(at: Support.root, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent != "Wallpapers" }
        }
        for url in own + [support.appendingPathComponent("Atelier", isDirectory: true),
                    caches.appendingPathComponent("net.dasantos.dockstacks", isDirectory: true),
                    caches.appendingPathComponent("Atelier", isDirectory: true)] {
            try? fm.removeItem(at: url)
        }
    }

    private static func deleteSettings() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.synchronize()
    }
}

// MARK: - Sheet

/// The summary shown before either action: every change that will be undone, the optional
/// administrator steps, and one button. While it runs, a progress line; afterwards, any step
/// that could not be undone.
struct RevertSheet: View {
    enum Mode: String, Identifiable { case revert, remove; var id: String { rawValue } }
    let mode: Mode
    @Environment(\.dismiss) private var dismiss
    @State private var items: [AtelierRevert.Item] = []
    @State private var removal: [AtelierRevert.Item] = []
    @State private var removeFanHelper = true
    @State private var removeBridge = true
    @State private var running: String?
    @State private var problems: [String]?

    private var title: String { mode == .remove ? "Remove Everything" : "Revert All macOS Changes" }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(DS.Typo.readout).foregroundStyle(DS.Ink.primary)
                Text(mode == .remove
                     ? "Everything Atelier changed goes back, then Atelier deletes its data and quits. Move Atelier to the Trash afterwards."
                     : "Everything Atelier changed goes back and those features turn off. Atelier stays installed.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if items.isEmpty {
                        Text("Atelier has no macOS changes in place right now.").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    } else {
                        list("Put back", items)
                    }
                    if AtelierRevert.fanHelperInstalled || AtelierRevert.bridgeInstalled {
                        RowGroup {
                            if AtelierRevert.fanHelperInstalled {
                                SettingRow(title: "Remove the fan helper", detail: "Its LaunchDaemon in /Library. Asks for an administrator password.",
                                           symbol: "fan", density: .compact) {
                                    LuxSwitch(isOn: $removeFanHelper, label: "Remove the fan helper")
                                }
                            }
                            if AtelierRevert.bridgeInstalled {
                                SettingRow(title: "Remove the Dock Bridge", detail: "Atelier.osax in /Library/ScriptingAdditions. Asks for an administrator password.",
                                           symbol: "puzzlepiece.extension", density: .compact) {
                                    LuxSwitch(isOn: $removeBridge, label: "Remove the Dock Bridge")
                                }
                            }
                        }
                    }
                    if mode == .remove { list("Then removed", removal) }
                    if let problems, !problems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Not undone").font(DS.Typo.rowTitle).foregroundStyle(DS.Spectrum.sensors)
                            ForEach(problems, id: \.self) { Text($0).font(DS.caption).foregroundStyle(DS.Ink.secondary) }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
            HStack(spacing: DS.Space.s) {
                if let running {
                    ProgressView().controlSize(.small)
                    Text(running).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
                Spacer()
                if problems != nil && mode == .revert {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.disabled(running != nil)
                    Button(mode == .remove ? "Remove Everything" : "Revert All") { start() }
                        .keyboardShortcut(.defaultAction)
                        .tint(mode == .remove ? .red : DS.Ink.accent)
                        .disabled(running != nil)
                }
            }
        }
        .padding(DS.Inset.card)
        .frame(width: 520)
        .onAppear {
            items = AtelierRevert.plan()
            removal = AtelierRevert.removalPlan()
        }
    }

    private func list(_ heading: String, _ rows: [AtelierRevert.Item]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            RowGroup {
                ForEach(rows) { item in
                    SettingRow(title: item.title, detail: item.detail, symbol: item.symbol, density: .compact) { EmptyView() }
                }
            }
        }
    }

    private func start() {
        guard running == nil else { return }
        running = "Starting…"
        let fan = removeFanHelper, bridge = removeBridge
        Task { @MainActor in
            let report: @MainActor (String) -> Void = { running = $0 }
            switch mode {
            case .revert:
                problems = await AtelierRevert.everything(removeFanHelper: fan, removeBridge: bridge, progress: report)
                items = AtelierRevert.plan()
                running = nil
                if problems?.isEmpty == true { dismiss() }
            case .remove:
                problems = await AtelierRevert.removeAtelier(removeFanHelper: fan, removeBridge: bridge, progress: report)
                running = "Quitting…"
                // A moment for the last Dock and Finder restarts to be seen, then quit for real.
                try? await Task.sleep(for: .milliseconds(600))
                AtelierRevert.quitAfterRemoval()
            }
        }
    }
}
