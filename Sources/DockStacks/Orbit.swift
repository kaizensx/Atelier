import AppKit
import Carbon.HIToolbox
import CoreServices
import DockCore
import ImageIO
import SwiftUI

// MARK: - Small types

struct OrbitDrag: Equatable {
    var entry: OrbitEntry
    var key: String
    var origin: CGPoint
    var location: CGPoint
    var fromFolder: UUID?
    var page: Int
}

struct OrbitAction: Identifiable {
    let title: String
    let symbol: String
    let run: @MainActor () -> Void
    var id: String { title }
}

struct OrbitActionMenu: Equatable {
    enum Mode: Equatable { case main, stacks, constellations }
    var key: String
    var point: CGPoint
    var mode = Mode.main
    var selection = 0
}

/// A public material behind the world. Its strength is the owner's.
struct OrbitVeil: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct OrbitShortcut: Equatable, Sendable {
    let key: UInt32
    let modifiers: UInt32
    let label: String

    static let all = [
        OrbitShortcut(key: UInt32(kVK_Space), modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧ Space"),
        OrbitShortcut(key: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey), label: "⌥⇧ Space"),
        OrbitShortcut(key: UInt32(kVK_ANSI_O), modifiers: UInt32(controlKey | optionKey), label: "⌃⌥ O"),
    ]

    /// Input source switching owns Control-Space, so check what the system has reserved.
    var clashesWithSystem: Bool {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr,
              let list = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return false }
        return list.contains { entry in
            guard entry[kHISymbolicHotKeyEnabled as String] as? Bool == true,
                  (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint32Value == key,
                  let flags = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value else { return false }
            return flags == modifiers || flags == Self.cocoaFlags(modifiers)
        }
    }

    private static func cocoaFlags(_ carbon: UInt32) -> UInt32 {
        var flags: UInt32 = 0
        if carbon & UInt32(shiftKey) != 0 { flags |= 1 << 17 }
        if carbon & UInt32(controlKey) != 0 { flags |= 1 << 18 }
        if carbon & UInt32(optionKey) != 0 { flags |= 1 << 19 }
        if carbon & UInt32(cmdKey) != 0 { flags |= 1 << 20 }
        return flags
    }
}

enum OrbitStore {
    @MainActor static var file = Support.root.appendingPathComponent("orbit-folders.json")

    @MainActor static func load() -> [OrbitFolder] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([OrbitFolder].self, from: data)) ?? []
    }

    @MainActor static func save(_ folders: [OrbitFolder]) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(folders).write(to: file, options: .atomic)
    }
}

// MARK: - Orbit

@MainActor
final class Orbit: ObservableObject {
    static let shared = Orbit()

    private enum Key {
        static let enabled = "orbit.enabled"
        static let shortcut = "orbit.shortcut"
        static let options = "orbit.options"
        static let launches = "orbit.launches"
        // Before options were one value.
        static let arrangement = "orbit.arrangement"
        static let drift = "orbit.drift"
    }

    // Settings
    @Published var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: Key.enabled)
            registerHotKey()
            updateButtonMonitor()
        }
    }
    @Published var shortcut: Int {
        didSet {
            UserDefaults.standard.set(shortcut, forKey: Key.shortcut)
            registerHotKey()
        }
    }
    /// Every choice in the settings chapter. Saved shortly after each change, applied at once.
    @Published var options: OrbitOptions {
        didSet { if options != oldValue { optionsChanged(from: oldValue) } }
    }
    @Published private(set) var activeShortcut: OrbitShortcut?

    // World
    @Published private(set) var shown = false
    @Published private(set) var entered = false
    @Published private(set) var size = CGSize(width: 1440, height: 900)
    @Published private(set) var pages: [OrbitPage] = []
    @Published private(set) var recents: [OrbitSlot] = []
    @Published private(set) var results: [OrbitSlot] = []
    @Published private(set) var query = ""
    @Published private(set) var searchArmed = false
    @Published private(set) var page = 0
    @Published private(set) var selection: String? {
        didSet { engine.set(selection: selection); updateHold() }
    }
    @Published private(set) var openFolder: UUID? { didSet { updateHold() } }
    @Published private(set) var folderOrigin = CGPoint.zero
    @Published private(set) var liftedKey: String?
    @Published private(set) var menu: OrbitActionMenu? { didSet { updateHold() } }
    @Published private(set) var toast: String?
    @Published private(set) var folders: [OrbitFolder] = []
    @Published private(set) var reduceMotion = false
    @Published private(set) var wallpaperRGB: OrbitRGB?
    /// Height the system Dock takes at the bottom, so the bar never sits on it.
    @Published private(set) var bottomInset = 0.0

    /// The field. Its layers move at display rate without touching SwiftUI.
    let engine = OrbitEngine()

    /// Under the pointer: the field's entry, a recent or a folder member. Not published: nothing redraws for it.
    private(set) var hovered: String?
    private var fieldHovered: String?
    private var drag: OrbitDrag?
    private var dropTarget: String?
    private var pointer = CGPoint(x: 720, y: 450)

    private var panel: FloatingPanel?
    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var scrollMonitor: Any?
    private var outsideMonitor: Any?
    private var buttonMonitors: [Any] = []
    private var started = false
    private var categories: [String: OrbitCategory] = [:]
    private var used: [String: Date] = [:]
    private var counts: [String: Int] = [:]
    private var byPath: [String: StackItem] = [:]
    private var wheelRest = Date.distantPast
    private var tracking = false
    private var edgeFlip: Task<Void, Never>?
    private var toastEnd: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var folderReset: Task<Void, Never>?
    private var dragToken = 0
    private var stale = true
    private var press: (key: String?, travelled: Double, began: Bool) = (nil, 0, false)
    let search = OrbitSearchSources()

    private init() {
        let store = UserDefaults.standard
        enabled = store.object(forKey: Key.enabled) as? Bool ?? true
        shortcut = min(max(store.integer(forKey: Key.shortcut), 0), OrbitShortcut.all.count - 1)
        var loaded = store.data(forKey: Key.options).map(OrbitOptions.decode) ?? OrbitOptions()
        if store.data(forKey: Key.options) == nil {
            if store.string(forKey: Key.arrangement) == "pages" { loaded.layout = .pages }
            if let drift = store.object(forKey: Key.drift) as? Bool { loaded.drift = drift }
        }
        options = loaded
        counts = (store.dictionary(forKey: Key.launches) as? [String: Int]) ?? [:]
        folders = OrbitStore.load()
        engine.artFor = { [unowned self] entry in self.art(for: entry) }
        engine.labelFor = { [unowned self] name in OrbitArt.label(name, style: OrbitLabelStyle(self.options)) }
        engine.titleArt = { [unowned self] page, large, count in
            OrbitArt.title(page.id == "results" ? "Results" : page.title, symbol: large ? page.group.symbol : nil,
                           hue: page.group.rgb, count: count, large: large, ink: self.options.ink, font: self.options.labelFont)
        }
        OrbitIconStore.shared.arrived = { [weak self] in
            guard let self, self.shown else { return }
            self.engine.refreshArt()
        }
        search.changed = { [weak self] in
            guard let self, self.searching else { return }
            self.refreshResults(animated: true)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        installHandler()
        registerHotKey()
        updateButtonMonitor()
        // The catalog fills in the background, so catch it a moment after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.warm() }
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Orbit.shared.close() }
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if Orbit.shared.shown { Orbit.shared.refreshRunning() } }
            }
        }
    }

    /// Opens or closes Orbit. Safe to call from anywhere on the main actor: hot corners, menus, URLs.
    func toggle() { shown ? close() : show() }

    private func screenForOpening() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        switch options.display {
        case .main: return NSScreen.screens.first ?? NSScreen.main
        case .pointer: return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        }
    }

    private func show() {
        let requested = CACurrentMediaTime()
        let mouse = NSEvent.mouseLocation
        guard let screen = screenForOpening() else { return }
        CommandController.shared.close()
        BubbleController.shared.close()
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        size = screen.frame.size
        bottomInset = max(screen.visibleFrame.minY - screen.frame.minY, 0)
        pointer = screen.frame.contains(mouse)
            ? CGPoint(x: mouse.x - screen.frame.minX, y: screen.frame.maxY - mouse.y)
            : CGPoint(x: size.width / 2, y: size.height / 2)
        query = ""
        searchArmed = false
        results = []
        selection = nil
        hovered = nil
        fieldHovered = nil
        openFolder = nil
        menu = nil
        drag = nil
        liftedKey = nil
        dropTarget = nil
        press = (nil, 0, false)
        let panel = self.panel ?? makePanel()
        panel.setFrame(screen.frame, display: false)
        engine.configure(size: size, scale: screen.backingScaleFactor,
                         field: OrbitLayout.field(size, OrbitLayoutParams(options)))
        engine.restyle(engineStyle)
        engine.swipe = 0
        // New apps and icons are caught in the background; the field opens with what is known now.
        warm()
        rebuild(animated: false)
        refreshRunning()
        if options.nebula == .wallpaper { sampleWallpaper() }
        engine.open(pointer: pointer, requested: requested)
        panel.orderFrontRegardless()
        panel.makeKey()
        shown = true
        updateHold()
        startMonitors()
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        DispatchQueue.main.async { self.entered = true }
    }

    func close() {
        guard shown else { return }
        shown = false
        entered = false
        menu = nil
        edgeFlip?.cancel()
        stopMonitors()
        engine.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
            guard let self, !self.shown else { return }
            self.panel?.orderOut(nil)
            self.engine.set(launching: nil)
            self.engine.set(hiddenEntry: nil)
            self.engine.endGhost()
            self.openFolder = nil
        }
    }

    private func makePanel() -> FloatingPanel {
        let panel = FloatingPanel(frame: NSRect(origin: .zero, size: size))
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: OrbitWorld(orbit: self))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }

    func motion(_ animation: Animation) -> Animation {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .easeInOut(duration: 0.16) : animation
    }

    var engineStyle: OrbitEngineStyle {
        OrbitEngineStyle(options, accent: NSColor(DS.Ink.accent).usingColorSpace(.sRGB)?.cgColor
                            ?? CGColor(srgbRed: 0.55, green: 0.72, blue: 1, alpha: 1),
                         reduceMotion: reduceMotion)
    }

    private func updateHold() {
        engine.hold = searching || selection != nil || menu != nil || openFolder != nil
    }

    /// Frame timings, for atelier://diag.
    func diagnostics() -> [String] { engine.diagnostics() }

    // MARK: Options

    private func optionsChanged(from old: OrbitOptions) {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self, let data = try? JSONEncoder().encode(self.options) else { return }
            UserDefaults.standard.set(data, forKey: Key.options)
        }
        if options.openButton != old.openButton { updateButtonMonitor() }
        if options.searchSettings && !old.searchSettings { search.loadPanes() }
        guard shown else {
            stale = stale || options.needsReplan(from: old)
            return
        }
        engine.restyle(engineStyle)
        if options.needsRestyle(from: old) { engine.refreshArt(labels: true) }
        if options.needsReplan(from: old) {
            engine.configure(size: size, scale: Double(panel?.backingScaleFactor ?? 2),
                             field: OrbitLayout.field(size, OrbitLayoutParams(options)))
            rebuild(animated: true)
        }
        if options.nebula == .wallpaper && old.nebula != .wallpaper { sampleWallpaper() }
    }

    func apply(_ theme: OrbitTheme) {
        options = theme.apply(to: options)
    }

    func resetOptions() {
        options = OrbitOptions()
    }

    // MARK: Hot key and buttons

    private func installHandler() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // HotKey in Command.swift claims every press on the application target, so ours
        // lives one level up on the dispatcher, where it can pass on what is not its own.
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == Orbit.signature else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Orbit.shared.toggle() }
            return noErr
        }, 1, &type, nil, &eventHandler)
    }

    nonisolated private static let signature = OSType(0x4F52_4254)

    /// Tries the chosen shortcut, then the others, so a clash never leaves Orbit unreachable.
    private func registerHotKey() {
        guard started else { return }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        activeShortcut = nil
        guard enabled else { return }
        let ordered = [OrbitShortcut.all[shortcut]] + OrbitShortcut.all.filter { $0 != OrbitShortcut.all[shortcut] }
        for candidate in ordered where !candidate.clashesWithSystem {
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: 2)
            if RegisterEventHotKey(candidate.key, candidate.modifiers, id, GetEventDispatcherTarget(), 0, &reference) == noErr {
                hotKey = reference
                activeShortcut = candidate
                return
            }
        }
    }

    /// A spare mouse button opens and closes Orbit, if the owner picked one.
    private func updateButtonMonitor() {
        for monitor in buttonMonitors { NSEvent.removeMonitor(monitor) }
        buttonMonitors = []
        guard started, enabled, let number = options.openButton.number else { return }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown, handler: { event in
            let pressed = event.buttonNumber
            MainActor.assumeIsolated { if pressed == number { Orbit.shared.toggle() } }
        }) { buttonMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown, handler: { event in
            guard event.buttonNumber == number else { return event }
            MainActor.assumeIsolated { Orbit.shared.toggle() }
            return nil
        }) { buttonMonitors.append(local) }
    }

    // MARK: Catalog

    private func warm() {
        let paths = AppCatalog.shared.apps.map(\.value)
        guard !paths.isEmpty else { return }
        let missing = OrbitIconStore.shared.missing(paths)
        let known = categories
        let style = OrbitLabelStyle(options)
        let names = OrbitArt.missingLabels(AppCatalog.shared.apps.map(\.name), style: style)
        Task.detached(priority: .utility) {
            var icons: [String: (image: CGImage, hue: OrbitRGB)] = [:], kinds: [String: OrbitCategory] = [:]
            var dates: [String: Date] = [:], uses: [String: Int] = [:], labels: [String: CGImage] = [:]
            for path in missing {
                if let drawn = OrbitIconStore.render(path) { icons[path] = drawn }
            }
            for name in names {
                if let drawn = OrbitArt.renderLabel(name, style: style) { labels[name] = drawn }
            }
            for path in paths {
                kinds[path] = known[path] ?? OrbitCategory.of(path: path)
                if let item = MDItemCreate(nil, path as CFString) {
                    if let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { dates[path] = date }
                    if let count = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int { uses[path] = count }
                }
            }
            await MainActor.run { [icons, kinds, dates, uses, labels] in
                OrbitIconStore.shared.store(icons)
                OrbitArt.store(labels: labels, style: style)
                let changed = kinds != self.categories || !icons.isEmpty
                self.categories = kinds
                self.used.merge(dates) { old, new in max(old, new) }
                self.systemCounts = uses
                if self.shown {
                    self.engine.refreshArt()
                    if changed { self.rebuild(animated: true) }
                } else {
                    self.stale = true
                }
            }
        }
    }

    private var systemCounts: [String: Int] = [:]

    private func category(of path: String) -> OrbitCategory {
        if let known = categories[path] { return known }
        let found = OrbitCategory.of(path: path)
        categories[path] = found
        return found
    }

    private var usage: OrbitUsage {
        var merged = systemCounts
        for (path, count) in counts { merged[path, default: 0] += count }
        return OrbitUsage(lastUsed: used, counts: merged, hues: OrbitIconStore.shared.hues, categories: categories)
    }

    private func art(for entry: OrbitEntry) -> CGImage? {
        if entry.isFolder { return OrbitArt.folder(entry.paths, size: options.iconSize, highlighted: false) }
        return OrbitIconStore.shared.cached(entry.path)
    }

    private func rebuild(animated: Bool) {
        let catalog = AppCatalog.shared.apps
        byPath = Dictionary(catalog.map { ($0.value, $0) }, uniquingKeysWith: { first, _ in first })
        for app in catalog where categories[app.value] == nil { _ = category(of: app.value) }
        let apps = catalog.map { OrbitApp(path: $0.value, name: $0.name) }
        pages = OrbitPlanner.pages(apps: apps, folders: folders, options: options, usage: usage, size: size)
        page = min(page, max(pages.count - 1, 0))
        stale = false

        let hidden = Set(options.hidden)
        if options.showRecents {
            let recent = used.filter { byPath[$0.key] != nil && !hidden.contains($0.key) }.sorted { $0.value > $1.value }.prefix(8)
            let startX = size.width / 2 - OrbitLayout.recentStep * Double(recent.count - 1) / 2
            recents = recent.enumerated().compactMap { index, pair in
                byPath[pair.key].map { app in
                    OrbitSlot(key: "recent:\(app.value)", entry: .app(OrbitApp(path: app.value, name: app.name)),
                              spot: OrbitSpot(center: CGPoint(x: startX + OrbitLayout.recentStep * Double(index), y: 122)))
                }
            }
        } else {
            recents = []
        }
        if searching { refreshResults(animated: animated) } else { engine.present(pages, current: page, animated: animated) }
    }

    func refreshRunning() {
        let paths = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }
        engine.setRunning(Set(paths))
    }

    private func sampleWallpaper() {
        Task.detached(priority: .utility) {
            guard let url = Wallpaper.url(), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 32,
                  ] as CFDictionary) else { return }
            let colour = OrbitIconStore.averageColour(thumb)
            await MainActor.run { Orbit.shared.wallpaperRGB = colour }
        }
    }

    // MARK: Search

    var searching: Bool { !query.isEmpty }

    private func refreshResults(animated: Bool) {
        let field = OrbitLayout.field(size, OrbitLayoutParams(options))
        let params = OrbitLayoutParams(options)
        let hidden = Set(options.hidden)
        var entries = AppCatalog.shared.apps.filter { !hidden.contains($0.value) }
            .map { OrbitEntry.app(OrbitApp(path: $0.value, name: $0.name)) }
        if options.searchSettings { entries += search.panes }
        let limit = OrbitLayout.resultCapacity(params, field: field)
        var shown = OrbitPlanner.results(query, entries: entries, fuzzy: options.fuzzy, usage: usage, limit: limit)
        if options.searchFiles {
            let known = Set(shown.map(\.id))
            shown += search.files.filter { !known.contains($0.id) }.prefix(max(limit - shown.count, 0))
        }
        let spots = OrbitLayout.resultSpots(count: shown.count, params, field: field)
        results = zip(shown, spots).map { OrbitSlot(key: $0.id, entry: $0, spot: $1) }
        let page = OrbitPage(id: "results", group: OrbitPlanner.resultsGroup, part: 0, slots: results, rings: [], core: 0,
                             titlePoint: CGPoint(x: field.midX, y: field.minY + 22))
        engine.present([page], current: 0, animated: animated)
    }

    private func setQuery(_ text: String) {
        let was = searching
        query = text
        if text.isEmpty {
            results = []
            searchArmed = false
            search.stopFiles()
            engine.present(pages, current: page, animated: true)
        } else {
            if options.searchFiles { search.findFiles(text) }
            refreshResults(animated: true)
        }
        if was != searching { updateHold() }
        selection = results.first?.key
    }

    // MARK: Reading the world

    var currentPage: OrbitPage? { pages.indices.contains(page) ? pages[page] : nil }

    /// What the nebula takes its colour from.
    var skyHue: OrbitRGB {
        switch options.nebula {
        case .custom: return options.nebulaColour
        case .wallpaper: return wallpaperRGB ?? options.nebulaColour
        case .constellation: return searching ? OrbitRGB(DS.Ink.accent) : (currentPage?.group.rgb ?? OrbitRGB(DS.Ink.accent))
        }
    }

    private var fieldSlots: [OrbitSlot] { searching ? results : (currentPage?.slots ?? []) }

    var folderBeingShown: OrbitEntry? {
        guard let openFolder else { return nil }
        for page in pages {
            if let slot = page.slots.first(where: { $0.entry.folder == openFolder }) { return slot.entry }
        }
        return nil
    }

    var cell: Double { options.iconSize + 34 }

    func folderSlots(_ entry: OrbitEntry) -> [OrbitSlot] {
        entry.paths.enumerated().map { index, path in
            OrbitSlot(key: "in:\(path)", entry: .app(OrbitApp(path: path, name: byPath[path]?.name ?? path)),
                      spot: OrbitSpot(center: OrbitLayout.folderPoint(index: index, count: entry.paths.count, size: size, cell: cell)))
        }
    }

    private var navigable: [OrbitSlot] {
        if let folder = folderBeingShown { return folderSlots(folder) }
        return fieldSlots + (searching ? [] : recents)
    }

    private func slot(for key: String) -> OrbitSlot? {
        navigable.first { $0.key == key }
    }

    /// Where an entry is on screen now: the field moves, recents and folder members stand still.
    private func point(of slot: OrbitSlot) -> CGPoint {
        if slot.key.hasPrefix("recent:") || slot.key.hasPrefix("in:") { return slot.spot.center }
        return engine.globalPoint(slot.key) ?? slot.spot.point(engine.driftTime)
    }

    // MARK: Pointer on the field

    func fieldHover(_ location: CGPoint?) {
        guard drag == nil else { return }
        let key = location.flatMap { engine.hit($0) }
        guard key != fieldHovered else { return }
        fieldHovered = key
        engine.set(hovered: key)
        if let key { hovered = key } else if hovered?.hasPrefix("recent:") == false && hovered?.hasPrefix("in:") == false { hovered = nil }
    }

    func fieldPressChanged(start: CGPoint, location: CGPoint) {
        if !press.began {
            press = (engine.hit(start), 0, true)
            engine.set(pressed: press.key)
        }
        press.travelled = max(press.travelled, hypot(location.x - start.x, location.y - start.y))
        guard press.travelled > 6, let key = press.key, !searching, let slot = fieldSlots.first(where: { $0.key == key }) else { return }
        engine.set(pressed: nil)
        dragChanged(slot.entry, key: key, origin: point(of: slot), location: location, fromFolder: nil)
    }

    func fieldPressEnded(location: CGPoint) {
        let current = press
        press = (nil, 0, false)
        engine.set(pressed: nil)
        if current.travelled > 6 {
            if drag != nil { dragEnded(location: location) }
        } else if let key = current.key {
            activate(key)
        } else {
            backgroundTapped()
        }
    }

    func hover(_ key: String, _ inside: Bool) {
        if inside { hovered = key } else if hovered == key { hovered = fieldHovered }
    }

    func backgroundTapped() {
        if menu != nil { dismissMenu() }
        else if openFolder != nil { closeFolder() }
        else { close() }
    }

    func activate(_ key: String) {
        guard let slot = slot(for: key) else { return }
        dismissMenu()
        if let folder = slot.entry.folder {
            present(folder: folder)
        } else {
            launch(slot.entry, key: key)
        }
    }

    private func launch(_ entry: OrbitEntry, key: String) {
        switch entry.kind {
        case .app, .folder:
            let item = byPath[entry.path] ?? StackItem(kind: .app, name: entry.name, value: entry.path)
            Launcher.open(item)
            used[entry.path] = Date()
            counts[entry.path, default: 0] += 1
            UserDefaults.standard.set(counts, forKey: Key.launches)
        case .pane, .file:
            if let text = entry.url, let url = URL(string: text) { NSWorkspace.shared.open(url) }
        }
        if !key.hasPrefix("recent:") && !key.hasPrefix("in:") { engine.set(launching: key) }
        close()
    }

    private func present(folder: UUID) {
        selection = nil
        folderReset?.cancel()
        let id = "folder:\(folder.uuidString)"
        let key = fieldSlots.first { $0.entry.folder == folder }?.key
        folderOrigin = key.flatMap { engine.globalPoint($0) } ?? CGPoint(x: size.width / 2, y: size.height / 2)
        engine.set(hiddenEntry: id)
        withAnimation(motion(DS.Motion.arrive)) { openFolder = folder }
    }

    func closeFolder() {
        selection = nil
        panel?.makeFirstResponder(nil)
        withAnimation(motion(DS.Motion.arrive)) { openFolder = nil }
        folderReset = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, let self, self.openFolder == nil else { return }
            self.engine.set(hiddenEntry: nil)
        }
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }), folders[index].name != name else { return }
        folders[index].name = name
        OrbitStore.save(folders)
        rebuild(animated: false)
    }

    func endEditing() { panel?.makeFirstResponder(nil) }

    // MARK: Dragging

    func dragChanged(_ entry: OrbitEntry, key: String, origin: CGPoint, location: CGPoint, fromFolder: UUID?) {
        dragToken += 1
        guard !searching else { return }
        if drag == nil || drag?.key != key {
            selection = nil
            drag = OrbitDrag(entry: entry, key: key, origin: origin, location: location, fromFolder: fromFolder, page: page)
            liftedKey = key
            engine.set(lifted: key)
            engine.set(hovered: nil)
            engine.beginGhost(art(for: entry), at: location)
        } else {
            drag?.location = location
            engine.moveGhost(to: location)
        }
        guard fromFolder == nil else { return }
        let target = engine.nearest(to: location, within: 58 * cell / 96, skipping: key)
        if target != dropTarget {
            if target != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
            dropTarget = target
            engine.set(dropTarget: target)
        }
        watchEdges(location)
    }

    /// Holding a dragged icon against the edge of the screen turns the page.
    private func watchEdges(_ location: CGPoint) {
        let direction = location.x < 36 ? -1 : location.x > size.width - 36 ? 1 : 0
        guard direction != 0 else {
            edgeFlip?.cancel()
            edgeFlip = nil
            return
        }
        guard edgeFlip == nil else { return }
        edgeFlip = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled, let self else { return }
            self.go(to: self.page + direction)
            self.edgeFlip = nil
        }
    }

    private func finishDrag() {
        drag = nil
        liftedKey = nil
        dropTarget = nil
        engine.set(dropTarget: nil)
        engine.set(lifted: nil)
        engine.endGhost()
    }

    func dragEnded(location: CGPoint) {
        edgeFlip?.cancel()
        edgeFlip = nil
        guard let current = drag else { return }
        if let source = current.fromFolder {
            let frame = OrbitLayout.folderFrame(count: folderBeingShown?.paths.count ?? 1, size: size, cell: cell)
            if !frame.contains(location) {
                finishDrag()
                remove(current.entry.path, from: source)
                return
            }
        } else if let target = dropTarget, let slot = fieldSlots.first(where: { $0.key == target }) {
            finishDrag()
            merge(current.entry, onto: slot.entry)
            return
        }
        let token = dragToken
        let home = current.fromFolder == nil ? (engine.globalPoint(current.key) ?? current.origin) : current.origin
        engine.returnGhost(to: home)
        dropTarget = nil
        engine.set(dropTarget: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.dragToken == token else { return }
            self.finishDrag()
        }
    }

    private func merge(_ source: OrbitEntry, onto target: OrbitEntry) {
        var folder: UUID
        if let id = target.folder ?? source.folder, let index = folders.firstIndex(where: { $0.id == id }) {
            folder = id
            let incoming = (source.paths + target.paths).filter { !folders[index].paths.contains($0) }
            folders[index].paths += incoming
            if let other = source.folder, other != id { folders.removeAll { $0.id == other } }
        } else {
            let name = target.paths.first.map { options.group(for: OrbitPlanner.groupID(of: $0, options: options, usage: usage)).title } ?? "Folder"
            let made = OrbitFolder(name: name, paths: target.paths + source.paths)
            folder = made.id
            folders.append(made)
        }
        // A pinned app that joins a folder is no longer pinned on its own.
        options.favourites.removeAll { source.paths.contains($0) || target.paths.contains($0) }
        OrbitStore.save(folders)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        rebuild(animated: true)
        if let page = pages.firstIndex(where: { $0.slots.contains { $0.entry.folder == folder } }), page != self.page { go(to: page) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in self?.present(folder: folder) }
    }

    private func remove(_ path: String, from id: UUID) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].paths.removeAll { $0 == path }
        if folders[index].paths.count < 2 {
            folders.remove(at: index)
            closeFolder()
        }
        OrbitStore.save(folders)
        rebuild(animated: true)
    }

    private func ungroup(_ id: UUID) {
        folders.removeAll { $0.id == id }
        OrbitStore.save(folders)
        if openFolder == id { closeFolder() }
        rebuild(animated: true)
    }

    func removeAllFolders() {
        folders = []
        OrbitStore.save(folders)
        if shown { rebuild(animated: true) } else { stale = true }
    }

    // MARK: Apps and constellations, from the menu and from settings

    func toggleFavourite(_ path: String) {
        if options.favourites.contains(path) { options.favourites.removeAll { $0 == path } }
        else { options.favourites.append(path) }
    }

    func hide(_ path: String, _ hidden: Bool) {
        if hidden { if !options.hidden.contains(path) { options.hidden.append(path) } }
        else { options.hidden.removeAll { $0 == path } }
    }

    func assign(_ path: String, to group: String?) {
        if let group { options.assigned[path] = group } else { options.assigned.removeValue(forKey: path) }
    }

    func groupID(of path: String) -> String {
        _ = category(of: path)
        return OrbitPlanner.groupID(of: path, options: options, usage: usage)
    }

    func addCategory(named name: String) {
        let colour = OrbitRGB.palette[options.customCategories.count % OrbitRGB.palette.count]
        options.customCategories.append(OrbitCustomCategory(name: name, colour: colour))
    }

    func removeCategory(_ id: String) {
        options.customCategories.removeAll { $0.id == id }
        options.assigned = options.assigned.filter { $0.value != id }
    }

    // MARK: Quick actions

    func presentMenu(for key: String) {
        guard let slot = slot(for: key) else { return }
        let point = point(of: slot)
        let width = 236.0, height = 190.0
        let below = point.y + 62 + height < size.height - 16
        let anchor = CGPoint(x: min(max(point.x, width / 2 + 16), size.width - width / 2 - 16),
                             y: below ? point.y + 62 + height / 2 : point.y - 62 - height / 2)
        selection = key
        withAnimation(motion(DS.Motion.settle)) { menu = OrbitActionMenu(key: key, point: anchor) }
    }

    func highlightMenuRow(_ index: Int) { menu?.selection = index }

    func dismissMenu() {
        guard menu != nil else { return }
        withAnimation(motion(DS.Motion.touch)) { menu = nil }
    }

    private func switchMenu(to mode: OrbitActionMenu.Mode) {
        withAnimation(motion(DS.Motion.settle)) {
            menu?.mode = mode
            menu?.selection = 0
        }
    }

    var menuActions: [OrbitAction] {
        guard let menu, let slot = slot(for: menu.key) else { return [] }
        let entry = slot.entry
        switch menu.mode {
        case .stacks: return stackActions(entry)
        case .constellations: return constellationActions(entry)
        case .main: break
        }
        var rows = [OrbitAction(title: entry.isFolder ? "Open Folder" : "Open", symbol: "arrow.up.forward.app") { [weak self] in
            self?.activate(menu.key)
        }]
        guard entry.kind == .app || entry.kind == .folder else { return rows }
        if !entry.isFolder {
            let path = entry.path
            rows.append(OrbitAction(title: "Show in Finder", symbol: "folder") { [weak self] in
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                self?.close()
            })
            let pinned = options.favourites.contains(path)
            rows.append(OrbitAction(title: pinned ? "Unpin from Centre" : "Pin to Centre", symbol: pinned ? "pin.slash" : "pin") { [weak self] in
                self?.dismissMenu()
                self?.toggleFavourite(path)
            })
            rows.append(OrbitAction(title: "Move to Constellation", symbol: "sparkles") { [weak self] in
                self?.switchMenu(to: .constellations)
            })
            rows.append(OrbitAction(title: "Hide from Orbit", symbol: "eye.slash") { [weak self] in
                self?.dismissMenu()
                self?.selection = nil
                self?.hide(path, true)
            })
        }
        rows.append(OrbitAction(title: entry.isFolder ? "Add All to Stack" : "Add to Stack", symbol: "square.stack.3d.up") { [weak self] in
            self?.switchMenu(to: .stacks)
        })
        if let id = entry.folder {
            rows.append(OrbitAction(title: "Ungroup", symbol: "square.grid.3x3") { [weak self] in
                self?.dismissMenu()
                self?.ungroup(id)
            })
        }
        if menu.key.hasPrefix("in:"), let id = openFolder {
            let path = entry.path
            rows.append(OrbitAction(title: "Remove from Folder", symbol: "minus.circle") { [weak self] in
                self?.dismissMenu()
                self?.remove(path, from: id)
            })
        }
        return rows
    }

    private func constellationActions(_ entry: OrbitEntry) -> [OrbitAction] {
        let path = entry.path
        let current = groupID(of: path)
        return options.groups.prefix(12).map { group in
            OrbitAction(title: group.title, symbol: group.id == current ? "checkmark" : group.symbol) { [weak self] in
                self?.dismissMenu()
                self?.assign(path, to: group.id == (self?.category(of: path).rawValue ?? "") ? nil : group.id)
            }
        }
    }

    private func stackActions(_ entry: OrbitEntry) -> [OrbitAction] {
        let stacks = StackStore.list().filter { (try? StackStore.load($0))?.rule == SmartRule.none }
        guard !stacks.isEmpty else {
            return [OrbitAction(title: "Create a Stack in Atelier", symbol: "plus") { [weak self] in
                self?.close()
                ManagerWindow.shared.show(chapter: Chapter.stacks.rawValue)
            }]
        }
        let items = entry.paths.map { byPath[$0] ?? StackItem(kind: .app, name: entry.name, value: $0) }
        return stacks.prefix(7).map { url in
            let title = url.deletingPathExtension().lastPathComponent
            return OrbitAction(title: title, symbol: "square.stack.3d.up.fill") { [weak self] in
                self?.dismissMenu()
                self?.add(items, to: url, title: title)
            }
        }
    }

    private func add(_ items: [StackItem], to url: URL, title: String) {
        Task.detached(priority: .userInitiated) {
            let message: String
            do {
                var document = try StackStore.load(url)
                let fresh = items.filter { item in !document.items.contains { $0.value == item.value } }
                if fresh.isEmpty {
                    message = "Already in \(title)"
                } else {
                    document.items += fresh.map(\.freshCopy)
                    _ = try StackActions.apply(document, existing: url)
                    message = "Added to \(title)"
                }
            } catch {
                message = error.localizedDescription
            }
            await MainActor.run { self.flash(message) }
        }
    }

    private func flash(_ message: String) {
        withAnimation(motion(DS.Motion.arrive)) { toast = message }
        toastEnd?.cancel()
        toastEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let self else { return }
            withAnimation(self.motion(DS.Motion.arrive)) { self.toast = nil }
        }
    }

    // MARK: Pages

    func go(to target: Int) {
        guard pages.indices.contains(target), !searching else {
            engine.go(to: -1)
            return
        }
        page = target
        engine.go(to: target)
        selection = nil
    }

    // MARK: Events

    private func startMonitors() {
        stopMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) ?? false } ? nil : event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouse(event) ?? false } ? nil : event
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) ?? false } ? nil : event
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopMonitors() {
        for monitor in [keyMonitor, mouseMonitor, scrollMonitor, outsideMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        keyMonitor = nil
        mouseMonitor = nil
        scrollMonitor = nil
        outsideMonitor = nil
    }

    private func handleMouse(_ event: NSEvent) -> Bool {
        let secondary = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
        guard secondary, let hovered else { return false }
        presentMenu(for: hovered)
        return true
    }

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard !searching, openFolder == nil, menu == nil, drag == nil else { return false }
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        if event.phase.isEmpty && event.momentumPhase.isEmpty {
            // A mouse wheel has no gesture, so one notch turns one page.
            guard abs(delta) > 0, Date() > wheelRest else { return true }
            wheelRest = Date().addingTimeInterval(0.4)
            go(to: page + (delta > 0 ? -1 : 1))
            return true
        }
        guard event.momentumPhase.isEmpty else { return true }
        if event.phase == .began {
            tracking = true
            selection = nil
        }
        if event.phase == .changed || event.phase == .began {
            let swipe = engine.swipe
            let atEdge = (page == 0 && swipe + delta > 0) || (page == pages.count - 1 && swipe + delta < 0)
            engine.swipe = swipe + (atEdge ? delta * 0.3 : delta)
        }
        if event.phase == .ended || event.phase == .cancelled, tracking {
            tracking = false
            let swipe = engine.swipe
            let threshold = min(size.width * 0.14, 180)
            let target = abs(swipe) > threshold ? page + (swipe > 0 ? -1 : 1) : page
            if pages.indices.contains(target) { go(to: target) } else { engine.go(to: -1) }
        }
        return true
    }

    /// Type to search, arrows move by sight, Return opens, Shift-Return shows actions,
    /// Esc steps back one layer at a time.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard panel?.isKeyWindow == true else { return false }
        if panel?.firstResponder is NSTextView {
            if event.keyCode == 53 {
                endEditing()
                return true
            }
            return false
        }
        if menu != nil { return handleMenuKey(event) }
        let command = event.modifierFlags.contains(.command)
        switch event.keyCode {
        case 53:
            if searching || searchArmed { setQuery("") }
            else if openFolder != nil { closeFolder() }
            else { close() }
        case 36, 76:
            if event.modifierFlags.contains(.shift) {
                if let selection { presentMenu(for: selection) }
            } else if let selection {
                activate(selection)
            }
        case 48:
            if openFolder == nil, !searching, !pages.isEmpty {
                go(to: (page + (event.modifierFlags.contains(.shift) ? pages.count - 1 : 1)) % pages.count)
            }
        case 51:
            if command { setQuery("") } else if !query.isEmpty { setQuery(String(query.dropLast())) }
        case 123: move(-1, 0)
        case 124: move(1, 0)
        case 125: move(0, 1)
        case 126: move(0, -1)
        default:
            if command, options.numberKeys, let digit = event.charactersIgnoringModifiers.flatMap(Int.init), digit >= 1 {
                if !searching, openFolder == nil { go(to: digit - 1) }
                return true
            }
            if command, event.charactersIgnoringModifiers == "f" {
                searchArmed = true
                return true
            }
            guard !command, !event.modifierFlags.contains(.control), openFolder == nil,
                  let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
            else { return false }
            if characters == " " && query.isEmpty { return true }
            if !options.typeToSearch && !searchArmed && query.isEmpty {
                // Typing is off: a slash, or Command-F, starts a search.
                if characters == "/" { searchArmed = true }
                return true
            }
            setQuery(query + characters)
        }
        return true
    }

    private func handleMenuKey(_ event: NSEvent) -> Bool {
        let count = menuActions.count
        switch event.keyCode {
        case 53, 123:
            if menu?.mode != .main { switchMenu(to: .main) } else { dismissMenu() }
        case 125: if count > 0 { menu?.selection = ((menu?.selection ?? 0) + 1) % count }
        case 126: if count > 0 { menu?.selection = ((menu?.selection ?? 0) + count - 1) % count }
        case 36, 76, 124:
            if let index = menu?.selection, menuActions.indices.contains(index) { menuActions[index].run() }
        default: break
        }
        return true
    }

    /// Moves to whatever sits most directly in that direction, on rings and grids alike.
    private func move(_ dx: Double, _ dy: Double) {
        let slots = navigable
        guard let key = selection, let current = slots.first(where: { $0.key == key }) else {
            selection = slots.first?.key
            return
        }
        let from = point(of: current)
        let placed = slots.filter { $0.key != key }.map { ($0.key, point(of: $0)) }
        let best = placed.compactMap { other, point -> (String, Double)? in
            let x = point.x - from.x, y = point.y - from.y
            let along = x * dx + y * dy
            guard along > 12 else { return nil }
            return (other, along + abs(x * dy - y * dx) * 2.4)
        }.min { $0.1 < $1.1 }
        if let best {
            selection = best.0
        } else if dx != 0, openFolder == nil, !searching, pages.indices.contains(page + Int(dx)) {
            let y = from.y
            go(to: page + Int(dx))
            let arrival = fieldSlots.min {
                abs($0.spot.point(engine.driftTime).y - y) + $0.spot.point(engine.driftTime).x * dx
                    < abs($1.spot.point(engine.driftTime).y - y) + $1.spot.point(engine.driftTime).x * dx
            }
            selection = arrival?.key
        } else if options.wrapNavigation {
            // Off the edge: come back in from the far side, on the same line.
            let wrap = placed.min { a, b in
                let ax = (a.1.x - from.x) * dx + (a.1.y - from.y) * dy, bx = (b.1.x - from.x) * dx + (b.1.y - from.y) * dy
                let ap = abs((a.1.x - from.x) * dy - (a.1.y - from.y) * dx), bp = abs((b.1.x - from.x) * dy - (b.1.y - from.y) * dx)
                return ax + ap * 0.6 < bx + bp * 0.6
            }
            if let wrap { selection = wrap.0 }
        }
    }
}

private extension StackItem {
    var freshCopy: StackItem { StackItem(kind: kind, name: name, value: value, children: children) }
}
