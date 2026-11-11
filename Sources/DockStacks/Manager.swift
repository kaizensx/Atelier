import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var hour: Int?

    var url: URL { ProfileStore.folder.appendingPathComponent("\(id.uuidString).plist") }
}

enum ProfileStore {
    static var folder: URL { Support.root.appendingPathComponent("Profiles", isDirectory: true) }
    private static var index: URL { folder.appendingPathComponent("profiles.json") }

    static func load() -> [Profile] {
        guard let data = try? Data(contentsOf: index) else { return [] }
        return (try? JSONDecoder().decode([Profile].self, from: data)) ?? []
    }

    static func save(_ profiles: [Profile]) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(profiles).write(to: index)
    }
}

struct LivePreset: Identifiable {
    let title: String
    let symbol: String
    let query: String
    var id: String { title }

    static let all = [
        LivePreset(title: "Recent Images", symbol: "photo.stack",
                   query: "kMDItemContentTypeTree == \"public.image\" && kMDItemFSContentChangeDate >= $time.today(-30)"),
        LivePreset(title: "Recent PDFs", symbol: "doc.richtext",
                   query: "kMDItemContentType == \"com.adobe.pdf\" && kMDItemFSContentChangeDate >= $time.today(-30)"),
        LivePreset(title: "Videos", symbol: "film.stack",
                   query: "kMDItemContentTypeTree == \"public.movie\""),
        LivePreset(title: "Screenshots", symbol: "camera.viewfinder",
                   query: "kMDItemIsScreenCapture == 1"),
        LivePreset(title: "New Apps", symbol: "sparkles",
                   query: "kMDItemContentType == \"com.apple.application-bundle\" && kMDItemDateAdded >= $time.today(-30)"),
    ]
}

@MainActor
final class ManagerModel: ObservableObject {
    @Published var chapter = Chapter.home
    /// The chapter whose panel is built. It changes one frame before `chapter`, so the panel's
    /// views are made while nothing moves and the camera then glides at full frame rate.
    @Published var panelChapter = Chapter.home
    /// True while the stage camera flies to a new chapter. Costly GPU layers on the stage (live
    /// glass, shadows) stand in with cheap copies until it lands, so the flight holds 120 Hz.
    @Published var cameraMoving = false
    /// A chapter's panel is sliding in: hover previews wait for it to land.
    @Published private(set) var panelArriving = false
    private var panelLanding: DispatchWorkItem?

    /// Only a chapter change: the pointer is set aside while the stage and panel travel. A
    /// preview never sets it, or the row under the pointer would lose its own hover.
    @Published private(set) var chapterFlying = false
    private var flightLanding: DispatchWorkItem?

    func noteChapterFlight() {
        chapterFlying = true
        flightLanding?.cancel()
        let land = DispatchWorkItem { [weak self] in self?.chapterFlying = false }
        flightLanding = land
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: land)
    }

    func notePanelArrival() {
        panelArriving = true
        panelLanding?.cancel()
        let land = DispatchWorkItem { [weak self] in
            self?.panelArriving = false
            StagePreview.shared.panelSettled()
        }
        panelLanding = land
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: land)
    }
    private var cameraLanding: DispatchWorkItem?

    func noteCameraMove() {
        cameraLanding?.cancel()
        if !cameraMoving { cameraMoving = true }
        let land = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.22)) { self?.cameraMoving = false }
        }
        cameraLanding = land
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: land)
    }
    @Published var preview: DockPlistBox?
    @Published var previewSize: Double?
    @Published var previewLook: Look?
    @Published var previewTint: Color?
    @Published var previewClear = false
    @Published var hoverTweak: Tweak?
    @Published var applied = 0
    @Published var stacks: [URL] = []
    @Published var selected: URL?
    @Published var draft = StackDocument(title: "New Stack")
    @Published var busy = false
    @Published var status = ""
    @Published var failure: String?
    @Published var dock: DockPlistBox = DockPlistBox()
    @Published var snapshots: [Snapshot] = []
    @Published var profiles: [Profile] = ProfileStore.load()
    @Published var convertible: [Convertible] = []
    private var lastScheduledHour: Int?

    struct Convertible: Identifiable {
        let path: String, title: String, apps: [String], text: String, style: String, color: Int
        var id: String { path }
    }

    /// The Studio's model, for the few things outside its views that move its camera.
    static weak var current: ManagerModel?

    init() { reload(); pick(stacks.first); Self.current = self }

    private var refreshing = false
    private var lastRefresh = Date.distantPast

    /// When the Studio window comes back to the front: the same reads as `reload`, off the main
    /// thread, and only what changed is published. Reloading everything on the main thread
    /// every time any window became key re-rendered the whole Studio for most of a second.
    func refreshQuietly() {
        guard !refreshing, !busy, Date().timeIntervalSince(lastRefresh) > 1.5 else { return }
        refreshing = true
        lastRefresh = Date()
        Task.detached(priority: .utility) {
            let stacks = StackStore.list()
            let snapshots = Timeline.list()
            nonisolated(unsafe) let dock = try? DockStore.read()
            let folders = StackActions.convertibleFolders().map {
                Convertible(path: $0.path, title: $0.title, apps: $0.apps, text: $0.text, style: $0.style, color: $0.color)
            }
            nonisolated(unsafe) let found = (stacks, snapshots, folders)
            await MainActor.run {
                self.refreshing = false
                if found.0 != self.stacks { self.stacks = found.0 }
                if found.1.map(\.id) != self.snapshots.map(\.id) { self.snapshots = found.1 }
                if let dock, !NSDictionary(dictionary: dock).isEqual(to: self.dock.plist) { self.dock = DockPlistBox(dock) }
                if found.2.map(\.id) != self.convertible.map(\.id) { self.convertible = found.2 }
            }
        }
    }

    func reload() {
        stacks = StackStore.list()
        snapshots = Timeline.list()
        dock = DockPlistBox(try? DockStore.read())
        convertible = StackActions.convertibleFolders().map {
            Convertible(path: $0.path, title: $0.title, apps: $0.apps, text: $0.text, style: $0.style, color: $0.color)
        }
    }

    func pick(_ url: URL?) {
        selected = url
        status = ""
        if let url, let document = try? StackStore.load(url) { draft = document }
        else { draft = StackDocument(title: "New Stack") }
    }

    /// Dock work blocks for seconds, so it runs off the main thread with a visible state.
    /// Work asked for while other work runs. It waits its turn instead of being dropped, so a
    /// switch flipped while the Dock restarts still lands.
    private var waiting: [(String, @Sendable () throws -> Void, (@MainActor () -> Void)?)] = []

    func perform(_ message: String, _ work: @escaping @Sendable () throws -> Void, then: (@MainActor () -> Void)? = nil) {
        guard !busy else { waiting.append((message, work, then)); return }
        busy = true
        status = message
        Task.detached(priority: .userInitiated) {
            let result = Result { try work() }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success: self.status = ""; self.applied += 1
                case .failure(let error): self.status = ""; self.failure = error.localizedDescription
                }
                self.reload()
                then?()
                if !self.waiting.isEmpty {
                    let (message, work, then) = self.waiting.removeFirst()
                    self.perform(message, work, then: then)
                }
            }
        }
    }

    func applyStack() {
        let document = draft, existing = selected
        guard !busy else { return }
        busy = true
        status = "Updating the Dock…"
        Task.detached(priority: .userInitiated) {
            let result = Result { try StackActions.apply(document, existing: existing) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let url):
                    self.reload()
                    self.pick(url)
                    self.status = ""
                    self.applied += 1
                case .failure(let error):
                    self.status = ""
                    self.failure = error.localizedDescription
                }
            }
        }
    }

    func deleteStack() {
        guard let url = selected else { return }
        perform("Removing…", { try StackActions.delete(url) }) { self.pick(self.stacks.first) }
    }

    func exportStack() {
        guard let url = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do { try FileManager.default.copyItem(at: url, to: target) }
        catch { failure = error.localizedDescription }
    }

    func importStack() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(exportedAs: "net.dasantos.dockstack")]
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let document = try StackStore.load(source)
            perform("Importing…", { _ = try StackActions.apply(document, existing: nil) })
        } catch { failure = error.localizedDescription }
    }

    func setDock(_ key: String, _ value: sending Any?) {
        let sendable = PlistValue(value)
        perform("Applying…", {
            try DockStore.update("Dock: \(key)") { plist in
                if let value = sendable.value { plist[key] = value } else { plist.removeValue(forKey: key) }
            }
        })
    }

    /// Turning a tweak off puts back what was there, so a user's own setting survives.
    func setTweak(_ tweak: Tweak, on: Bool) {
        // A key the running macOS does not honour is never written.
        guard tweak.isAvailableHere else { return }
        let domain = tweak.domain, key = tweak.key, type = tweak.type, value = tweak.value, process = tweak.process
        let memory = "original." + tweak.id
        let store = UserDefaults.standard
        if on, store.object(forKey: memory) == nil {
            store.set(Prefs.current(key, domain: domain) ?? "", forKey: memory)
        }
        let original = store.string(forKey: memory) ?? ""
        if !on { store.removeObject(forKey: memory) }
        perform("Applying…", {
            if domain == "com.apple.dock" { try Timeline.record(DockStore.read(), label: "Tweak \(key)") }
            if on { try Prefs.write(key, type: type, value: value, domain: domain) }
            else if original.isEmpty { try Prefs.delete(key, domain: domain) }
            else { try Prefs.write(key, type: type, value: original, domain: domain) }
            if let process { Prefs.restart(process) }
        })
    }

    func addLive(_ preset: LivePreset) {
        let title = preset.title, query = preset.query
        changeTiles("Live stack \(title)") { Tiles.addSmart(label: title, query: query, to: &$0) }
    }

    func removeLive(_ label: String) {
        changeTiles("Remove \(label)") { Tiles.removeSmart(label: label, from: &$0) }
    }

    func setCorner(_ key: String, to value: Int) {
        perform("Applying…", {
            // The modifier is the user's: changing the action keeps it.
            try DockStore.update("Corner \(key)") { AppleHotCorner.set(key, to: value, in: &$0) }
        })
    }

    /// Live Dock calls take a moment to reach the preferences.
    func refreshDock(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.dock = DockPlistBox(try? DockStore.read()) }
    }

    func changeTiles(_ label: String, _ change: @escaping @Sendable (inout DockPlist) -> Void) {
        perform("Applying…", { try DockStore.update(label, change: change) })
    }

    func saveProfile(named name: String) {
        let profile = Profile(name: name)
        perform("Saving…", {
            try FileManager.default.createDirectory(at: ProfileStore.folder, withIntermediateDirectories: true)
            try DockStore.exportData().write(to: profile.url)
        }) {
            self.profiles.append(profile)
            ProfileStore.save(self.profiles)
        }
    }

    func apply(_ profile: Profile) {
        let url = profile.url, name = profile.name
        perform("Switching to \(name)…", { try DockStore.apply(snapshotAt: url, label: "Scene \(name)") })
    }

    func removeProfile(_ profile: Profile) {
        profiles.removeAll { $0.id == profile.id }
        try? FileManager.default.removeItem(at: profile.url)
        ProfileStore.save(profiles)
    }

    func setHour(_ hour: Int?, for profile: Profile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].hour = hour
        ProfileStore.save(profiles)
    }

    /// Called every minute; a profile fires once when its hour arrives.
    func tick() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour != lastScheduledHour else { return }
        defer { lastScheduledHour = hour }
        guard lastScheduledHour != nil, let profile = profiles.first(where: { $0.hour == hour }) else { return }
        apply(profile)
    }

    /// Removes every stack tile and all app data. The Dock otherwise stays as it is.
    func uninstall() {
        perform("Cleaning up…", {
            let paths = StackStore.list().map(\.path)
            try DockStore.update("Remove Atelier") { plist in
                for path in paths { Tiles.detach(path: path, from: &plist) }
            }
            try? LoginItem.set(false)
            try FileManager.default.removeItem(at: Support.root)
        }) { NSApp.terminate(nil) }
    }
}

struct PlistValue: @unchecked Sendable {
    let value: Any?
    init(_ value: Any?) { self.value = value }
}

struct DockPlistBox {
    var plist: DockPlist
    init(_ plist: DockPlist? = nil) { self.plist = plist ?? [:] }
    func bool(_ key: String) -> Bool { plist[key] as? Bool ?? (plist[key] as? Int).map { $0 != 0 } ?? false }
    func double(_ key: String, _ fallback: Double) -> Double { (plist[key] as? NSNumber)?.doubleValue ?? fallback }
    func string(_ key: String, _ fallback: String) -> String { plist[key] as? String ?? fallback }
    var fullWidth: Bool { Tiles.isFullWidth(plist) }
}

struct ItemsEditor: View {
    @Binding var items: [StackItem]
    @State private var showingApps = false
    @State private var editingGroup: StackItem?
    @State private var linkText = ""
    @State private var shortcutText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Items").font(.headline)
                Text("\(items.count)").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button { showingApps = true } label: { Label("Apps", systemImage: "plus.app") }
                    .popover(isPresented: $showingApps) { AppPicker(items: $items) }
                Button("File") { pickFiles() }
                Button("Group") { items.append(StackItem(kind: .group, name: "Group")) }
            }
            HStack(spacing: 8) {
                TextField("Link, https://…", text: $linkText).textFieldStyle(.roundedBorder).onSubmit(addLink)
                TextField("Shortcut name", text: $shortcutText).textFieldStyle(.roundedBorder).onSubmit(addShortcut)
            }
            VStack(spacing: 0) {
                ForEach(items) { item in
                    HStack(spacing: 10) {
                        Image(nsImage: ItemIcon.image(for: item)).resizable().frame(width: 26, height: 26)
                        Text(item.name).lineLimit(1)
                        Spacer()
                        if item.kind == .group {
                            Button("Edit") { editingGroup = item }.controlSize(.small)
                        }
                        Button { move(item, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain).accessibilityLabel("Move up")
                        Button { move(item, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain).accessibilityLabel("Move down")
                        Button { items.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain).accessibilityLabel("Remove \(item.name)")
                    }
                    .padding(.vertical, 6).padding(.horizontal, 10)
                    Divider()
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.4)))
            .dropDestination(for: URL.self) { urls, _ in
                items += urls.filter(\.isFileURL).map { StackItem.path($0.path) }
                return true
            }
            Text("Drag apps or files here.").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $editingGroup) { group in GroupEditor(group: group) { updated in
            if let index = items.firstIndex(where: { $0.id == updated.id }) { items[index] = updated }
        } }
    }

    private func move(_ item: StackItem, _ delta: Int) {
        guard let index = items.firstIndex(of: item), items.indices.contains(index + delta) else { return }
        items.swapAt(index, index + delta)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        items += panel.urls.map { StackItem.path($0.path) }
    }

    private func addLink() {
        guard let url = URL(string: linkText), url.scheme != nil else { return }
        items.append(StackItem(kind: .url, name: url.host() ?? linkText, value: linkText))
        linkText = ""
    }

    private func addShortcut() {
        guard !shortcutText.isEmpty else { return }
        items.append(StackItem(kind: .shortcut, name: shortcutText, value: shortcutText))
        shortcutText = ""
    }
}

struct GroupEditor: View {
    @State var group: StackItem
    let save: (StackItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Group name", text: $group.name)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold, design: .rounded))
            ScrollView { ItemsEditor(items: $group.children) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save(group); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 520, height: 460)
    }
}

struct AppPicker: View {
    @Binding var items: [StackItem]
    @State private var search = ""

    var body: some View {
        let apps = AppCatalog.shared.apps.filter { search.isEmpty || Fuzzy.score(search, in: $0.name) != nil }
        VStack(spacing: 8) {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            List(apps) { app in
                Toggle(isOn: Binding(
                    get: { items.contains { $0.value == app.value } },
                    set: { on in
                        if on { items.append(StackItem.path(app.value)) }
                        else { items.removeAll { $0.value == app.value } }
                    })) {
                    HStack(spacing: 8) {
                        Image(nsImage: ItemIcon.image(for: app)).resizable().frame(width: 20, height: 20)
                        Text(app.name)
                    }
                }
            }
        }
        .padding(10).frame(width: 300, height: 420)
    }
}
