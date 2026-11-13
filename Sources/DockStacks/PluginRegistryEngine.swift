import AppKit
import DockCore
import IOKit.ps

// The registry's newer duties: plugins started on demand, settings, messages between plugins,
// taps on widget buttons, lifecycle events, the resource meter and safe mode.
extension PluginRegistry {

    // MARK: Start-up

    func startEngine() {
        // Safe mode is decided in start(), before any plugin launches.
        let workspace = NSWorkspace.shared.notificationCenter
        let main = OperationQueue.main
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ event: PluginEvent, payload: @escaping @MainActor () -> JSONValue = { .object([:]) }) {
            _ = center.addObserver(forName: name, object: nil, queue: main) { _ in
                MainActor.assumeIsolated { PluginRegistry.shared.emit(event, payload: payload()) }
            }
        }
        on(workspace, NSWorkspace.willSleepNotification, .sleep)
        on(workspace, NSWorkspace.didWakeNotification, .wake)
        on(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsLocked"), .screensLocked)
        on(DistributedNotificationCenter.default(), Notification.Name("com.apple.screenIsUnlocked"), .screensUnlocked)
        on(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification, .displaysChanged) {
            .object(["count": .number(Double(NSScreen.screens.count))])
        }
        PowerWatch.start()
        lastPower = PowerWatch.current()
        // Wakes plugins on their timer, and puts idle ones back to sleep.
        engineTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { PluginRegistry.shared.engineTick() }
        }
    }

    /// Called by PowerWatch when the power source or battery level changes.
    func powerChanged() {
        let now = PowerWatch.current()
        guard now != lastPower else { return }
        lastPower = now
        emit(.powerSource, payload: now)
    }

    // MARK: On demand

    /// Starts an enabled plugin the way its manifest asks: now, or on demand with what it
    /// contributes on show meanwhile.
    func start(_ plugin: InstalledPlugin) {
        guard plugin.manifest.startsOnDemand else { launch(plugin); return }
        showContributions(plugin)
        status[plugin.id] = safeMode == nil ? "Waiting: starts when you use it." : "Off: Atelier started in safe mode."
        if let timer = plugin.manifest.contributes.timer { wakeDates[plugin.id] = Date().addingTimeInterval(timer) }
    }

    /// Whether a plugin is on but its script has not started yet.
    func isAsleep(_ id: String) -> Bool { enabled.contains(id) && runtimes[id] == nil }

    func showContributions(_ plugin: InstalledPlugin) {
        let id = plugin.id, name = plugin.manifest.name, given = plugin.manifest.contributes
        for spec in given.widgets where !widgets.contains(where: { $0.plugin == id && $0.spec.id == spec.id }) {
            widgets.append(PluginWidget(plugin: id, spec: spec))
        }
        for spec in given.tiles where !dockTiles.contains(where: { $0.plugin == id && $0.spec.id == spec.id }) {
            dockTiles.append(PluginDockTile(plugin: id, spec: spec))
        }
        for spec in given.commands where !commands.contains(where: { $0.plugin == id && $0.spec.id == spec.id }) {
            commands.append(PluginCommand(plugin: id, pluginName: name, spec: spec))
        }
        for spec in given.corners where !cornerActions.contains(where: { $0.plugin == id && $0.spec.id == spec.id }) {
            cornerActions.append(PluginCornerAction(plugin: id, pluginName: name, spec: spec))
        }
    }

    /// The running engine of a plugin, started now when `trigger` is one of its activations.
    func runtime(_ id: String, for trigger: PluginActivation?) -> PluginRuntime? {
        if let running = runtimes[id] { return running }
        guard enabled.contains(id), safeMode == nil, let plugin = installed.first(where: { $0.id == id }) else { return nil }
        if let trigger, plugin.manifest.activation?.contains(trigger) != true { return nil }
        append(id, "info", "Started: \(trigger?.text ?? "message").")
        launch(plugin)
        return runtimes[id]
    }

    func wakeSleepers(for event: PluginEvent, payload: JSONValue) {
        for plugin in installed where isAsleep(plugin.id) && plugin.manifest.activation?.contains(.onEvent(event)) == true {
            runtime(plugin.id, for: .onEvent(event))?.emit(event.rawValue, payload: payload)
        }
    }

    func engineTick() {
        let now = Date()
        for plugin in installed where isAsleep(plugin.id) {
            guard let interval = plugin.manifest.contributes.timer, let due = wakeDates[plugin.id], due <= now else { continue }
            wakeDates[plugin.id] = now.addingTimeInterval(interval)
            runtime(plugin.id, for: .onTimer)?.emit(PluginEvent.timer.rawValue, payload: .object(["date": .number(now.timeIntervalSince1970 * 1000)]))
        }
        for plugin in installed where plugin.manifest.startsOnDemand {
            guard let runtime = runtimes[plugin.id] else { continue }
            let visible = visibleWidgets.filter { $0.key.hasPrefix(plugin.id + "/") }.values.reduce(0, +)
            runtime.idleState { timers, pending, last in
                let registry = PluginRegistry.shared
                guard registry.runtimes[plugin.id] === runtime,
                      PluginIdle.canSleep(timers: timers, visibleWidgets: visible, pendingRequests: pending, lastCall: last, now: Date()) else { return }
                registry.sleep(plugin.id)
            }
        }
    }

    /// Stops an idle plugin started on demand. Its storage is saved; its contributions stay.
    func sleep(_ id: String) {
        guard let plugin = installed.first(where: { $0.id == id }) else { return }
        stopRuntime(id)
        append(id, "info", "Asleep after \(Int(PluginIdle.limit / 60)) minutes without use.")
        start(plugin)
    }

    func widgetAppeared(_ key: String) { visibleWidgets[key, default: 0] += 1 }
    func widgetDisappeared(_ key: String) {
        visibleWidgets[key, default: 1] -= 1
        if visibleWidgets[key] ?? 0 <= 0 { visibleWidgets[key] = nil }
    }

    // MARK: Taps in plugin views

    /// A tap on a button or toggle a plugin drew. One call, under the usual time limit.
    func action(_ plugin: String, _ action: String, payload: JSONValue = .null) {
        guard PluginNode.isActionID(action) else { return }
        // The Mods Playground runs its script outside the registry.
        if plugin.hasPrefix("playground.") { PlaygroundModel.tap(plugin: plugin, action, payload: payload); return }
        runtimes[plugin]?.invoke("action:" + action, payload: payload)
    }

    // MARK: Messages between plugins

    func deliver(_ payload: JSONValue, from id: String, to target: String) {
        guard let sender = installed.first(where: { $0.id == id })?.manifest else { return }
        guard let receiver = installed.first(where: { $0.id == target })?.manifest else {
            append(id, "warn", "Message to \(target) not delivered: it is not installed."); return
        }
        guard PluginMessaging.allows(from: sender, to: receiver) else {
            append(id, "warn", "Message to \(target) not delivered: it does not list \(id) under messages.receive."); return
        }
        guard enabled.contains(target), let runtime = runtime(target, for: nil) else {
            append(id, "warn", "Message to \(target) not delivered: it is off."); return
        }
        runtime.emit(PluginEvent.message.rawValue, payload: .object(["from": .string(id), "payload": payload]))
    }

    // MARK: Settings

    private func storageURL(_ id: String) -> URL { PluginRuntime.dataFolder.appendingPathComponent(id + ".json") }

    private func storage(_ id: String) -> PluginStorage {
        if let cached = settingsCache[id] { return cached }
        let loaded = (try? Data(contentsOf: storageURL(id))).map(PluginStorage.init(data:)) ?? PluginStorage()
        settingsCache[id] = loaded
        return loaded
    }

    /// What a setting holds now, or its default. Secrets are never read here: see `hasSecret`.
    func settingValue(_ plugin: InstalledPlugin, _ setting: PluginSetting) -> JSONValue {
        guard setting.kind != .secret else { return .null }
        return storage(plugin.id).values[setting.storageKey] ?? setting.defaultValue ?? .null
    }

    func hasSecret(_ plugin: InstalledPlugin, _ setting: PluginSetting) -> Bool {
        PluginSecrets.has(plugin: plugin.id, key: setting.key)
    }

    /// The owner changed a setting. Returns a problem to show, or nil.
    @discardableResult
    func setSetting(_ plugin: InstalledPlugin, _ setting: PluginSetting, _ value: JSONValue) -> String? {
        let checked: JSONValue
        switch setting.check(value) {
        case .success(let good): checked = good
        case .failure(let failure): return failure.description
        }
        if setting.kind == .secret {
            guard PluginSecrets.write(plugin: plugin.id, key: setting.key, value: checked.string) else { return "The Keychain refused to save it." }
        } else {
            var store = storage(plugin.id)
            do { try store.set(setting.storageKey, checked.isNull ? nil : checked) } catch { return error.description }
            settingsCache[plugin.id] = store
            // A running plugin owns its storage; it saves the value and tells the script.
            if runtimes[plugin.id] == nil {
                try? FileManager.default.createDirectory(at: PluginRuntime.dataFolder, withIntermediateDirectories: true)
                try? store.data.write(to: storageURL(plugin.id), options: .atomic)
            }
        }
        runtimes[plugin.id]?.applySetting(setting, value: checked)
        settingsRevision += 1
        return nil
    }

    func noteSetting(_ plugin: InstalledPlugin, key: String, value: JSONValue) {
        if let setting = plugin.manifest.setting(key), setting.kind != .secret {
            var store = storage(plugin.id)
            try? store.set(setting.storageKey, value.isNull ? nil : value)
            settingsCache[plugin.id] = store
        }
        settingsRevision += 1
    }

    // MARK: Resource meter

    func stats(_ id: String, reply: @escaping @MainActor @Sendable (PluginMeter.Snapshot?) -> Void) {
        guard let runtime = runtimes[id] else { reply(nil); return }
        runtime.stats { reply($0) }
    }

    // MARK: Safe mode

    private static var runningMarker: URL { CrashGuard.folder.appendingPathComponent("plugins-running") }
    private static let streakKey = "plugins.crashStreak"

    /// Two launches in a row that crashed while plugins ran: this one starts with plugins off.
    func enterSafeModeIfNeeded() {
        let running = ((try? String(contentsOf: Self.runningMarker, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let streak = PluginSafeMode.streak(previous: UserDefaults.standard.integer(forKey: Self.streakKey),
                                           lastRunCrashed: CrashGuard.lastRunCrashed, pluginsWereRunning: !running.isEmpty)
        UserDefaults.standard.set(streak, forKey: Self.streakKey)
        guard PluginSafeMode.isSafe(streak: streak) else { return }
        safeMode = running
        safeModeBannerShown = true
        for id in Array(runtimes.keys) { stopRuntime(id) }
        for id in running { status[id] = "Off: Atelier started in safe mode." }
        try? FileManager.default.removeItem(at: Self.runningMarker)
    }

    /// The owner turned plugins back on after safe mode.
    func leaveSafeMode() {
        safeMode = nil
        safeModeBannerShown = false
        UserDefaults.standard.set(0, forKey: Self.streakKey)
        for plugin in installed where enabled.contains(plugin.id) { status[plugin.id] = nil }
        reload()
    }

    /// Which plugins run, on disk, for the safe-mode check after a crash.
    func noteRunning() {
        let ids = runtimes.keys.sorted()
        guard ids != lastRunning else { return }
        lastRunning = ids
        try? FileManager.default.createDirectory(at: CrashGuard.folder, withIntermediateDirectories: true)
        try? Data(ids.joined(separator: "\n").utf8).write(to: Self.runningMarker, options: .atomic)
    }
}

/// The power source and battery level, for the `powerSource` event.
@MainActor
enum PowerWatch {
    private static var source: CFRunLoopSource?

    static func start() {
        guard source == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { PluginRegistry.shared.powerChanged() } }
        }
        guard let made = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        source = made
        CFRunLoopAddSource(CFRunLoopGetMain(), made, .defaultMode)
    }

    /// `{ onBattery, level }`, level 0…1 or null on a Mac without a battery.
    static func current() -> JSONValue {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return .object(["onBattery": .bool(false), "level": .null]) }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var level: JSONValue = .null
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            level = .number((Double(capacity) / Double(maximum) * 100).rounded() / 100)
            break
        }
        return .object(["onBattery": .bool(type == kIOPSBatteryPowerValue), "level": level])
    }
}
