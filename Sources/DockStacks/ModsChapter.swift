import AppKit
import DockCore
import SwiftUI

/// Mods: the community catalog of plugins and themes, and in its own tier native mods.
/// Browse, Installed, Updates; a mod's page opens in place.
struct ModsChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var store = ModStore.shared
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var themes = ThemeEngine.shared
    @ObservedObject private var bridge = DockBridge.shared
    @State private var tab: ModsTab = .browse
    @State private var selected: String?
    @State private var nativeAsk: ModEntry?
    /// An author's page, by GitHub handle.
    @State private var author: String?

    var body: some View {
        // The sheets hang off the whole chapter: on a zero-height view at the end of a long page
        // they stayed off screen and never came up (the permission ask after installing a plugin).
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if let id = selected, let entry = store.index?.mod(id) {
                ModPage(entry: entry, back: { withAnimation(DS.Motion.reveal) { selected = nil } }, install: install,
                        go: { model.go($0) }, openAuthor: openAuthor)
            } else if let handle = author, let index = store.index, let person = index.author(handle) {
                ModAuthorPage(author: person, mods: index.mods(by: handle), back: { withAnimation(DS.Motion.reveal) { author = nil } },
                              open: { id in withAnimation(DS.Motion.reveal) { selected = id } })
            } else {
                ModsTabsView(model: model, tab: $tab, open: { id in withAnimation(DS.Motion.reveal) { selected = id } }, install: install,
                             openAuthor: openAuthor)
            }
        }
        .background { sheets }
    }

    private var sheets: some View {
        Color.clear
            .sheet(item: $store.pendingPermission) { plugin in
                PluginPermissionsSheet(plugin: plugin) { granted in
                    if let granted { PluginRegistry.shared.enable(plugin, granting: granted) }
                    store.reviewed(plugin.id)
                    store.pendingPermission = nil
                    store.nextPermission()
                }
            }
            .sheet(item: $store.review) { review in
                ModReviewSheet(review: review) { go in
                    if go { store.confirm(review) } else { store.review = nil }
                }
            }
            .sheet(item: Binding(get: { store.pendingImport.map(ImportRequest.init) }, set: { if $0 == nil { store.pendingImport = nil } })) { request in
                ModImportSheet(setup: request.setup) { go in
                    store.pendingImport = nil
                    if go { Task { await store.apply(request.setup) } }
                }
            }
            .sheet(item: $nativeAsk) { entry in
                NativeModWarningSheet(entry: entry) { go in
                    nativeAsk = nil
                    if go { store.requestInstall(entry) }
                }
            }
            .onAppear {
                store.refreshIfStale()
                registry.reload()
                themes.reload()
                openRequested()
            }
            .onChange(of: store.requestedPage) { openRequested() }
            .onChange(of: store.index?.mods.count) { openRequested() }
    }

    /// Opens the page a link asked for, once the catalog that lists it has loaded.
    private func openRequested() {
        guard let id = store.requestedPage else { return }
        if store.index?.mod(id) != nil {
            withAnimation(DS.Motion.reveal) { selected = id }
            store.requestedPage = nil
        } else if store.index == nil {
            store.refreshIfStale()
        } else {
            store.notice = "That mod isn't in the catalog."
            store.requestedPage = nil
        }
    }

    /// Every install goes through the review: new permissions, a changed author key or an older
    /// version are shown before anything is downloaded.
    private func install(_ entry: ModEntry) {
        if entry.kind == .native, store.installedVersion(entry.id) == nil { nativeAsk = entry } else { store.requestInstall(entry) }
    }

    private func openAuthor(_ handle: String) {
        withAnimation(DS.Motion.reveal) { selected = nil; author = handle }
    }
}

/// A setup waiting for the import sheet, as a sheet item.
private struct ImportRequest: Identifiable {
    let setup: AtelierSetup
    var id: Date { setup.created }
}

enum ModsTab: Hashable { case browse, installed, updates, library }

/// The three tabs, with the catalog's status line above them.
struct ModsTabsView: View {
    @ObservedObject var model: ManagerModel
    @Binding var tab: ModsTab
    let open: (String) -> Void
    let install: (ModEntry) -> Void
    var openAuthor: (String) -> Void = { _ in }
    @ObservedObject private var store = ModStore.shared

    var body: some View {
        Text("Plugins and themes made by the community, checked and signed before they reach your Mac. Plugins still ask for each permission.")
            .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, DS.Space.xs)

        ModsStatusLine()

        let count = store.updates.count
        Segments(selection: $tab, options: [(.browse, "Browse"), (.installed, "Installed"),
                                            (.updates, count > 0 ? "Updates (\(count))" : "Updates"), (.library, "Library")])

        if let notice = store.notice {
            Label(notice, systemImage: "checkmark.circle.fill").font(DS.caption).foregroundStyle(ModsHue.tint)
                .padding(.horizontal, DS.Space.xs)
        }

        switch tab {
        case .browse: ModsBrowse(open: open, openAuthor: openAuthor)
        case .installed: ModsInstalled(open: open)
        case .updates: ModsUpdates(open: open)
        // What used to be Themes & Plugins: making, importing and managing your own.
        case .library: ThemesChapter(model: model)
        }
    }
}

/// Where the catalog stands: verified and fresh, loading, offline on a cached copy, or failed.
struct ModsStatusLine: View {
    @ObservedObject private var store = ModStore.shared

    var body: some View {
        HStack(spacing: DS.Space.s) {
            switch store.phase {
            case .loading:
                ProgressView().controlSize(.small)
                Text("Checking the catalog…").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            case .offline(let why):
                Image(systemName: "wifi.slash").foregroundStyle(.orange)
                Text("Offline. Showing the catalog from \(age). \(why)").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failed(let why):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(why).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            case .loaded, .idle:
                if store.index != nil {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(DS.Spectrum.input)
                    Text("Catalog verified · \(store.index?.mods.count ?? 0) mods · updated \(age)").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                } else {
                    Text("The catalog has not been loaded yet.").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
            }
            Spacer(minLength: DS.Space.s)
            Button("Check Now") { store.refresh() }.buttonStyle(ModPill(prominent: false))
                .disabled(store.phase == .loading)
        }
        .padding(.horizontal, DS.Space.xs)
    }

    private var age: String {
        guard let date = store.index?.generated else { return "earlier" }
        return date.formatted(.relative(presentation: .named))
    }
}

/// The gallery: Featured, New and everything, or the results of a search.
struct ModsBrowse: View {
    let open: (String) -> Void
    var openAuthor: (String) -> Void = { _ in }
    @ObservedObject private var store = ModStore.shared
    @ObservedObject private var bridge = DockBridge.shared
    @State private var query = ""
    @State private var kind: ModKind? = nil

    var body: some View {
        if let index = store.index {
            controls
            let native = bridge.status.isReady
            let shown = ModQuery.filter(index.mods, kind: kind, text: query, includeNative: native)
            if query.isEmpty, kind == nil {
                let featured = index.featuredMods.filter { $0.kind != .native || native }
                if !featured.isEmpty {
                    SectionHeader("Featured this week", symbol: "star", detail: index.featuredNote, hue: ModsHue.tint)
                    grid(featured, featured: true)
                }
                // Collections the maintainers put together, one shelf each.
                ForEach(index.collections) { collection in
                    let mods = index.mods(in: collection).filter { $0.kind != .native || native }
                    if !mods.isEmpty {
                        ModShelf(title: collection.title, detail: collection.description, mods: mods, open: open)
                    }
                }
                // New only earns its place once the catalog is bigger than a screenful.
                let fresh = shown.count > 8 ? ModQuery.newest(shown.filter { !index.featured.contains($0.id) }, count: 4) : []
                if !fresh.isEmpty {
                    SectionHeader("New", symbol: "sparkle", hue: ModsHue.tint)
                    grid(fresh)
                }
                SectionHeader("All mods", symbol: "square.grid.2x2", detail: "\(shown.count) in the catalog.", hue: ModsHue.tint)
                grid(shown)
            } else if shown.isEmpty && authors(index).isEmpty {
                ThemesEmptyShelf(symbol: "magnifyingglass", text: "Nothing matches. Try another word, or another kind.")
            } else if shown.isEmpty {
                ModAuthorRows(authors: authors(index), index: index, open: openAuthor)
            } else {
                if kind == nil, !authors(index).isEmpty { ModAuthorRows(authors: authors(index), index: index, open: openAuthor) }
                SectionHeader(kind == .native ? "Native mods" : "Results", symbol: kind?.symbol ?? "magnifyingglass",
                              detail: "\(shown.count) found.", hue: ModsHue.tint)
                if kind == .native { NativeBanner() }
                grid(shown)
            }
            submit
        } else if case .loading = store.phase {
            ModsPlaceholder(symbol: "arrow.down.circle", title: "Loading the catalog",
                            text: "Atelier downloads the catalog from GitHub and checks its signature.")
        } else {
            ModsPlaceholder(symbol: "wifi.exclamationmark", title: "The catalog is not available",
                            text: failure + " Atelier shows the catalog again as soon as it can reach it.") {
                Button("Try Again") { store.refresh() }.buttonStyle(ModPill())
            }
            submit
        }
    }

    private var failure: String {
        if case .failed(let why) = store.phase { return why }
        return "It has not been downloaded yet."
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Ink.tertiary)
                TextField("Search mods", text: $query).textFieldStyle(.plain).font(.system(size: 12.5))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(DS.Ink.tertiary) }
                        .buttonStyle(Pressable()).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            Segments(selection: $kind, options: kinds)
        }
        .padding(.top, DS.Space.s)
    }

    /// Plugins and Themes always; any other kind once the catalog has one; Native with the Bridge.
    private var kinds: [(ModKind?, String)] {
        var list: [(ModKind?, String)] = [(nil, "All"), (.plugin, "Plugins"), (.theme, "Themes")]
        let present = Set(store.index?.mods.map(\.kind) ?? [])
        for k in ModKind.allCases where k != .plugin && k != .theme && k != .native && present.contains(k) { list.append((k, k.plural)) }
        if bridge.status.isReady { list.append((.native, "Native")) }
        return list
    }

    /// Authors whose name or handle has every word of the search.
    private func authors(_ index: ModIndex) -> [ModAuthor] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return index.allAuthors.filter { a in
            let hay = (a.name + " " + a.github).lowercased()
            return words.allSatisfy(hay.contains)
        }
    }

    private func grid(_ mods: [ModEntry], featured: Bool = false) -> some View {
        LazyVGrid(columns: ModCard.columns, spacing: DS.Space.m) {
            ForEach(mods) { entry in ModCard(entry: entry, featured: featured) { open(entry.id) } }
        }
    }

    private var submit: some View {
        RowGroup {
            Button { NSWorkspace.shared.open(ModsConfig.submitPage) } label: {
                SettingRow(title: "Share your own", detail: "Open a pull request on github.com/kaizensx/atelier-mods. Every mod is checked by the catalog’s workflow and a person.",
                           symbol: "square.and.arrow.up", density: .compact) {
                    Image(systemName: "arrow.up.right").foregroundStyle(DS.Ink.tertiary)
                }
            }
            .buttonStyle(Pressable(scale: 0.99))
        }
        .padding(.top, DS.Space.m)
    }
}

/// Everything installed, from the catalog or not.
struct ModsInstalled: View {
    let open: (String) -> Void
    @ObservedObject private var store = ModStore.shared
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var themes = ThemeEngine.shared

    var body: some View {
        let mine = store.installed.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
        ModSetupRow().padding(.top, DS.Space.s)
        if mine.isEmpty {
            ThemesEmptyShelf(symbol: "shippingbox", text: "Nothing installed yet. Find plugins and themes in Browse.")
        } else {
            SectionHeader("Installed", symbol: "shippingbox", detail: "\(mine.count) on this Mac.", hue: ModsHue.tint)
            RowGroup {
                ForEach(mine, id: \.id) { mod in row(mod) }
            }
        }
    }

    private func name(_ mod: InstalledModInfo) -> String {
        switch mod.kind {
        case .plugin: registry.installed.first { $0.id == mod.id }?.manifest.name ?? mod.id
        case .theme: themes.installed.first { $0.id == mod.id }?.document.name ?? mod.id
        case .native: store.index?.mod(mod.id)?.name ?? mod.id
        }
    }

    private func row(_ mod: InstalledModInfo) -> some View {
        let entry = store.index?.mod(mod.id)
        let newer = entry.map { ModVersions.isNewer($0.version, than: mod.version) } ?? false
        let source = entry != nil ? (store.fromCatalog[mod.id] != nil ? "From the catalog" : "In the catalog") : "Added by you"
        let on = mod.kind == .plugin && registry.enabled.contains(mod.id)
        let plugin = registry.installed.first { $0.id == mod.id }
        return SettingRow(title: name(mod), detail: "\(mod.kind.title) · \(mod.version) · \(source)",
                          symbol: mod.kind.symbol, density: .compact) {
            HStack(spacing: DS.Space.s) {
                if newer, let entry {
                    Button("Update to \(entry.version)") { store.requestInstall(entry) }.buttonStyle(ModPill())
                }
                if let held = store.held[mod.id] { ModChip(text: "Held at \(held)", symbol: "pin", hue: .orange) }
                if store.work[mod.id] != nil { ProgressView().controlSize(.small) }
                if let plugin {
                    // A plugin runs only while it is on; switching it on asks for its permissions first.
                    LuxSwitch(isOn: Binding(get: { on }, set: { want in
                        if want {
                            if plugin.manifest.permissions.isEmpty { registry.enable(plugin, granting: []) }
                            else { store.pendingPermission = plugin }
                        } else { registry.disable(plugin.id) }
                    }), label: "Turn \(name(mod)) on or off")
                }
                // Short label so a plugin's switch, remove and chevron stay on one line.
                ModHoldPill(title: "Remove") { store.remove(mod.id) }.help("Hold to remove")
                if entry != nil { menu(mod) }
                if entry != nil {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                }
            }
        }
        // The whole row opens the mod's page, not only a small button.
        .contentShape(Rectangle())
        .onTapGesture { if entry != nil { open(mod.id) } }
    }
}

extension ModsInstalled {
    /// More for a row: roll back, take updates again, open the page.
    fileprivate func menu(_ mod: InstalledModInfo) -> some View {
        Menu {
            Button("Open Page") { open(mod.id) }
            if let target = store.rollbackTarget(mod.id) {
                Button("Roll Back to \(target.version)") { store.rollBack(mod.id) }
            }
            if store.held[mod.id] != nil {
                Button("Allow Updates") { store.release(mod.id) }
            }
        } label: {
            Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundStyle(DS.Ink.secondary)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More for \(name(mod))")
    }
}

/// Updates: what is newer in the catalog, what each one would newly ask for, and Update All.
struct ModsUpdates: View {
    let open: (String) -> Void
    @ObservedObject private var store = ModStore.shared
    @ObservedObject private var registry = PluginRegistry.shared
    @ObservedObject private var themes = ThemeEngine.shared

    var body: some View {
        let updates = store.updates
        RowGroup {
            SettingRow(title: "Check every day", detail: lastChecked, symbol: "arrow.triangle.2.circlepath", density: .compact) {
                LuxSwitch(isOn: $store.autoCheck, label: "Check for mod updates every day")
            }
        }
        .padding(.top, DS.Space.s)
        if !store.needsReview.isEmpty {
            ForEach(store.needsReview, id: \.self) { id in
                if let plugin = registry.installed.first(where: { $0.id == id }) {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        Text("\(plugin.manifest.name) was updated and asks for new permissions. It is off until you allow them.")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: DS.Space.s)
                        Button("Review") { store.pendingPermission = plugin }.buttonStyle(ModPill())
                    }
                    .padding(.horizontal, DS.Space.xs)
                }
            }
        }
        if updates.isEmpty {
            ThemesEmptyShelf(symbol: "checkmark.circle", text: store.index == nil
                             ? "Updates show here once the catalog has been checked."
                             : "Everything is up to date.")
        } else {
            HStack {
                SectionHeader("\(updates.count) update\(updates.count == 1 ? "" : "s")", symbol: "arrow.down.circle", hue: ModsHue.tint)
                Button("Update All") { Task { await store.updateAll() } }.buttonStyle(ModPill())
                    .padding(.top, DS.Space.xl)
                    .disabled(!store.work.isEmpty)
            }
            RowGroup {
                ForEach(updates) { update in row(update) }
            }
        }
    }

    private var lastChecked: String {
        guard let last = store.lastCheck else { return "Not checked yet." }
        return "Last checked " + last.formatted(.relative(presentation: .named)) + "."
    }

    private func row(_ update: ModUpdate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(title: update.entry.name, detail: "\(update.from) → \(update.to)" + (update.entry.versions.first?.notes.map { " · " + $0 } ?? ""),
                       symbol: update.entry.kind.symbol, density: .compact) {
                HStack(spacing: DS.Space.s) {
                    if store.work[update.id] != nil { ProgressView().controlSize(.small) }
                    Button("Details") { open(update.id) }.buttonStyle(ModPill(prominent: false))
                    if !store.reviewFor(update.entry).canInstallUnattended {
                        ModChip(text: "Needs review", symbol: "hand.raised.fill", hue: .orange, strong: true)
                    } else if let held = store.held[update.id] {
                        ModChip(text: "Held at \(held)", symbol: "pin", hue: .orange)
                    }
                    if update.compatible {
                        Button(store.reviewFor(update.entry).canInstallUnattended ? "Update" : "Review…") { store.requestInstall(update.entry) }
                            .buttonStyle(ModPill())
                    } else {
                        ModChip(text: "Needs Atelier \(update.entry.minAtelier ?? "")", hue: .orange, strong: true)
                    }
                }
            }
            if update.diff.needsConsent {
                WrapStack(spacing: 5, lineSpacing: 5) {
                    Text("Newly asks for").font(DS.caption).foregroundStyle(.orange)
                    ForEach(update.diff.added, id: \.self) { p in
                        ModChip(text: PluginPermission(rawValue: p)?.title ?? p, symbol: PluginPermission(rawValue: p)?.symbol, hue: .orange)
                    }
                    ForEach(update.diff.addedHosts, id: \.self) { host in ModChip(text: host, symbol: "network", hue: .orange) }
                }
                .padding(.leading, 28)
            }
            if let failure = store.failures[update.id] {
                Text(failure).font(DS.caption).foregroundStyle(.orange).padding(.leading, 28).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

/// An empty, loading or error state with room for one action.
struct ModsPlaceholder<Action: View>: View {
    let symbol: String
    let title: String
    let text: String
    var action: Action

    init(symbol: String, title: String, text: String, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.symbol = symbol; self.title = title; self.text = text; self.action = action()
    }

    var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: symbol).font(.system(size: 26, weight: .medium)).foregroundStyle(ModsHue.tint)
                .frame(width: 56, height: 56).background(ModsHue.tint.opacity(0.12), in: .circle)
            Text(title).font(DS.title).foregroundStyle(DS.Ink.primary)
            Text(text).font(DS.body).foregroundStyle(DS.Ink.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 420)
            action
        }
        .padding(DS.Space.xxl)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Ink.edge, style: StrokeStyle(lineWidth: 0.75, dash: [5, 4]))
        }
        .padding(.top, DS.Space.m)
    }
}
