import AppKit
import DockCore
import SwiftUI

// MARK: - Atelier Mods: cards, the mod page and its pieces

enum ModsHue {
    static let tint = Color(red: 0.62, green: 0.58, blue: 1.0)
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.36)

    static func kind(_ kind: ModKind) -> Color {
        switch kind {
        case .plugin: DS.Spectrum.input
        case .theme: DS.Spectrum.sound
        case .native: danger
        default: pack
        }
    }
}

/// Decoded screenshots, by SHA-256. The views read it synchronously first, so an offscreen
/// render (or a second visit) draws at once.
@MainActor
enum ModShotCache {
    static var images: [String: NSImage] = [:]
}

/// A screenshot, loaded through ModStore (cache first, checked against the signed hash), with a
/// quiet placeholder in the mod's colour while it loads or when it cannot.
struct ModShotView: View {
    let shot: ModScreenshot?
    let kind: ModKind
    var radius = DS.Radius.plate
    @State private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Color.clear
            .aspectRatio(16 / 10, contentMode: .fit)
            .overlay {
                if let picture = image ?? shot.flatMap({ ModShotCache.images[$0.sha256.lowercased()] }) {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        LinearGradient(colors: [ModsHue.kind(kind).opacity(0.22), ModsHue.kind(kind).opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                        Image(systemName: kind.symbol).font(.system(size: 22, weight: .medium)).foregroundStyle(ModsHue.kind(kind).opacity(0.7))
                    }
                }
            }
            .clipShape(shape)
            .overlay { shape.strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
            .task(id: shot?.sha256) {
                guard let shot, image == nil else { return }
                let key = shot.sha256.lowercased()
                if let cached = ModShotCache.images[key] { image = cached; return }
                if let data = await ModStore.shared.screenshot(shot), let picture = NSImage(data: data) {
                    ModShotCache.images[key] = picture
                    image = picture
                }
            }
    }
}

/// A small capsule: kind, permission, state.
struct ModChip: View {
    let text: String
    var symbol: String?
    var hue: Color = DS.Ink.secondary
    var strong = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).fixedSize()
        }
        .foregroundStyle(strong ? Color.black.opacity(0.82) : hue)
        .padding(.horizontal, 7).frame(height: 20)
        .background(strong ? AnyShapeStyle(hue) : AnyShapeStyle(hue.opacity(0.14)), in: .capsule)
    }
}

/// The pill buttons the Mods chapter uses: Install, Update, Apply.
struct ModPill: ButtonStyle {
    var prominent = true
    var hue: Color = ModsHue.tint
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(prominent ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fill), in: .capsule)
            .overlay { Capsule().strokeBorder(prominent ? Color.white.opacity(0.2) : DS.Ink.edge, lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Remove, sized for a row: hold to confirm, release to cancel, like HoldButton.
struct ModHoldPill: View {
    var title = "Hold to Remove"
    let action: () -> Void
    @State private var holding = false

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 12).frame(height: 28)
            .background(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle().fill(Color.red.opacity(0.75)).frame(width: holding ? geometry.size.width : 0)
                }
            }
            .background(Color.red.opacity(0.2))
            .clipShape(.capsule)
            .scaleEffect(holding ? 0.97 : 1)
            .onLongPressGesture(minimumDuration: 1.2, perform: action) { pressing in
                withAnimation(pressing ? .linear(duration: 1.2) : DS.Motion.exit) { holding = pressing }
            }
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

/// Where a mod stands on this Mac, for its card and its page.
enum ModState: Equatable {
    case available, installed(String), update(from: String), incompatible(String), working(ModStore.Work)

    @MainActor static func of(_ entry: ModEntry, in store: ModStore) -> ModState {
        if let work = store.work[entry.id] { return .working(work) }
        if let mine = store.installedVersion(entry.id) {
            return ModVersions.isNewer(entry.version, than: mine) ? .update(from: mine) : .installed(mine)
        }
        if !store.isCompatible(entry) { return .incompatible(entry.minAtelier ?? "") }
        return .available
    }
}

/// A card in the gallery: screenshot, name, author, kind, permissions.
struct ModCard: View {
    let entry: ModEntry
    var featured = false
    let open: () -> Void
    @ObservedObject private var store = ModStore.shared
    @State private var hovering = false

    static let columns = [GridItem(.adaptive(minimum: 220, maximum: 360), spacing: DS.Space.m, alignment: .top)]

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                ModShotView(shot: entry.screenshots.first, kind: entry.kind)
                    .overlay(alignment: .topTrailing) { stateBadge.padding(DS.Space.s) }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(entry.version).font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                    }
                    Text(entry.summary).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                }
                WrapStack(spacing: 5, lineSpacing: 5) {
                    ModChip(text: entry.kind.title, symbol: entry.kind.symbol, hue: ModsHue.kind(entry.kind))
                    ForEach(entry.pluginPermissions) { p in ModChip(text: p.title, symbol: p.symbol) }
                }
                HStack(spacing: 6) {
                    Text("By \(entry.author)" + (entry.github.isEmpty ? "" : " · @\(entry.github)"))
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                    Spacer(minLength: 4)
                    ModStats(entry: entry)
                }
            }
            .padding(DS.Space.s + 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background { CardSurface(style: featured ? .lit(ModsHue.tint) : .standard) }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.16 : 0), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.985))
        .onHover { hovering = $0 }
        .animation(DS.Motion.hover, value: hovering)
        .accessibilityLabel("\(entry.name), \(entry.kind.title) by \(entry.author)")
    }

    @ViewBuilder private var stateBadge: some View {
        switch ModState.of(entry, in: store) {
        case .installed: ModChip(text: "Installed", symbol: "checkmark", hue: DS.Spectrum.input, strong: true)
        case .update: ModChip(text: "Update", symbol: "arrow.down.circle", hue: ModsHue.tint, strong: true)
        case .incompatible: ModChip(text: "Needs newer Atelier", hue: .orange, strong: true)
        case .working: ProgressView().controlSize(.small).padding(4).background(.black.opacity(0.5), in: .circle)
        case .available: EmptyView()
        }
    }
}

/// The mod page: screenshots, description, permissions, history, and the one button that matters.
struct ModPage: View {
    let entry: ModEntry
    let back: () -> Void
    let install: (ModEntry) -> Void
    /// Opens another chapter, for the "In Atelier" shortcuts.
    var go: (Chapter) -> Void = { _ in }
    /// Opens an author's page, by GitHub handle.
    var openAuthor: (String) -> Void = { _ in }
    @ObservedObject private var store = ModStore.shared
    @ObservedObject private var registry = PluginRegistry.shared
    /// So "Add to Dock" turns into "Dock" as soon as the tile is there.
    @ObservedObject private var dock = OwnDock.shared
    @State private var shot = 0

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            Button(action: back) {
                Label("All mods", systemImage: "chevron.left").font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.secondary)
            }
            .buttonStyle(Pressable())

            header

            if entry.kind == .native { NativeBanner() }

            if let failure = store.failures[entry.id] {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(DS.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }

            if !entry.screenshots.isEmpty { carousel }

            if !entry.description.isEmpty {
                Card { ModMarkdown(text: entry.description) }
            }

            if entry.kind == .plugin, store.installedVersion(entry.id) != nil,
               let plugin = registry.installed.first(where: { $0.id == entry.id }), !plugin.manifest.settings.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Settings", symbol: "slider.horizontal.3", detail: "Kept for this plugin. Secrets go to your Keychain.", hue: ModsHue.tint)
                    PluginSettingsForm(plugin: plugin).padding(.top, DS.Space.s)
                }
            }
            if entry.kind.isPack { PackPageSection(id: entry.id) }

            if entry.kind == .plugin, store.installedVersion(entry.id) != nil { inAtelier }

            if entry.kind == .plugin { permissions }

            details

            if entry.versions.count > 0 { history }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: entry.kind.symbol).font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 44, height: 44)
                .background(ModsHue.kind(entry.kind), in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name).font(DS.Typo.hero).foregroundStyle(DS.Ink.primary)
                Text("By \(entry.author)" + (entry.github.isEmpty ? "" : " · @\(entry.github)") + " · \(entry.kind.title) · \(entry.version)")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                Text(entry.summary).font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                HStack(spacing: DS.Space.s) {
                    if ModCommunity.isHandle(entry.github) {
                        Button { openAuthor(entry.github) } label: {
                            Label("More by \(entry.author)", systemImage: "person.crop.circle").font(DS.caption).foregroundStyle(ModsHue.tint)
                        }
                        .buttonStyle(Pressable())
                    }
                    ModStats(entry: entry)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        let state = ModState.of(entry, in: store)
        VStack(alignment: .trailing, spacing: DS.Space.s) {
            switch state {
            case .available:
                Button(entry.kind == .native ? "Install…" : "Install") { install(entry) }.buttonStyle(ModPill(hue: entry.kind == .native ? ModsHue.danger : ModsHue.tint))
            case .update(let from):
                Button("Update") { install(entry) }.buttonStyle(ModPill())
                Text("You have \(from)").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            case .installed:
                if entry.kind == .theme, let theme = ThemeEngine.shared.theme(entry.id) {
                    Button("Apply") { ThemeEngine.shared.apply(theme) }.buttonStyle(ModPill())
                } else if entry.kind.isPack, let pack = ModPackStore.shared.pack(entry.id) {
                    PackUseButton(pack: pack)
                } else {
                    ModChip(text: "Installed", symbol: "checkmark", hue: DS.Spectrum.input, strong: true)
                }
            case .incompatible(let need):
                ModChip(text: "Needs Atelier \(need)", hue: .orange, strong: true)
            case .working(let work):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(work == .downloading ? "Downloading…" : work == .installing ? "Installing…" : "Removing…").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
            }
            if case .installed = state { removeButton } else if case .update = state { removeButton }
            if let target = store.rollbackTarget(entry.id), store.work[entry.id] == nil {
                Button("Roll Back to \(target.version)") { store.rollBack(entry.id) }.buttonStyle(ModPill(prominent: false))
            }
            if let held = store.held[entry.id] {
                Button("Allow Updates") { store.release(entry.id) }.buttonStyle(ModPill(prominent: false))
                    .help("Held at \(held) after a rollback. Update All leaves it there until you allow updates.")
            }
            if let homepage = entry.homepage {
                Button("Homepage") { NSWorkspace.shared.open(homepage) }.buttonStyle(ModPill(prominent: false))
            }
            if let discussion = entry.discussion {
                Button("Discuss on GitHub") { NSWorkspace.shared.open(discussion) }.buttonStyle(ModPill(prominent: false))
            }
        }
    }

    private var removeButton: some View {
        ModHoldPill { store.remove(entry.id) }
    }

    private var carousel: some View {
        let shots = entry.screenshots
        let index = min(shot, shots.count - 1)
        return VStack(spacing: DS.Space.s) {
            ModShotView(shot: shots[index], kind: entry.kind, radius: DS.Radius.card)
                .overlay(alignment: .leading) { arrow("chevron.left", enabled: index > 0) { shot = index - 1 } }
                .overlay(alignment: .trailing) { arrow("chevron.right", enabled: index < shots.count - 1) { shot = index + 1 } }
                .id(shots[index].sha256)
                .transition(.opacity)
            HStack(spacing: 6) {
                if let caption = shots[index].caption {
                    Text(caption).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if shots.count > 1 {
                    ForEach(shots.indices, id: \.self) { i in
                        Circle().fill(i == index ? DS.Ink.primary : DS.Ink.track).frame(width: 6, height: 6)
                            .onTapGesture { withAnimation(DS.Motion.reveal) { shot = i } }
                    }
                }
            }
        }
        .animation(DS.Motion.reveal, value: shot)
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                .frame(width: 30, height: 30).background(.black.opacity(0.45), in: .circle)
        }
        .buttonStyle(Pressable())
        .padding(DS.Space.s)
        .opacity(enabled ? 1 : 0)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "chevron.left" ? "Previous screenshot" : "Next screenshot")
    }

    /// Where this plugin shows up, read from what it registered while running. A quick way to
    /// find its pieces; the author's own description above stays as it is.
    private var inAtelier: some View {
        let id = entry.id
        let on = registry.enabled.contains(id)
        let tiles = registry.dockTiles.filter { $0.plugin == id }
        let widgets = registry.widgets.filter { $0.plugin == id }
        let commands = registry.commands.filter { $0.plugin == id }
        let corners = registry.cornerActions.filter { $0.plugin == id }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("In Atelier", symbol: "scope", detail: "Where this plugin shows up on your Mac.", hue: ModsHue.tint)
            RowGroup {
                if !on {
                    SettingRow(title: "Off", detail: "Turn it on to use it. Its Dock tile, widgets and commands show up here.",
                               symbol: "power", density: .compact) {
                        if let plugin = registry.installed.first(where: { $0.id == id }) {
                            Button("Turn On") {
                                if plugin.manifest.permissions.isEmpty { registry.enable(plugin, granting: []) }
                                else { store.pendingPermission = plugin }
                            }.buttonStyle(ModPill())
                        }
                    }
                } else if tiles.isEmpty && widgets.isEmpty && commands.isEmpty && corners.isEmpty && !PluginHooks.shared.hasAny(id) {
                    SettingRow(title: "Nothing to open", detail: "This plugin works in the background and adds nothing you can open.",
                               symbol: "gearshape.2", density: .compact) { EmptyView() }
                }
                if on {
                    ForEach(tiles) { tile in
                        SettingRow(title: tile.spec.title, detail: "Dock tile, on your Atelier Dock.",
                                   symbol: "dock.rectangle", density: .compact) {
                            if dock.hasPlugin(.tile, key: tile.id) {
                                Button("Dock") { go(.dock) }.buttonStyle(ModPill(prominent: false))
                            } else {
                                Button("Add to Dock") { dock.addPlugin(.tile, key: tile.id) }.buttonStyle(ModPill())
                            }
                        }
                    }
                    ForEach(widgets) { widget in
                        SettingRow(title: widget.spec.title, detail: "Widget. In Widgets, add a Plugin widget and pick it.",
                                   symbol: "square.grid.2x2", density: .compact) {
                            Button("Widgets") { go(.widgets) }.buttonStyle(ModPill(prominent: false))
                        }
                    }
                    ForEach(commands) { command in
                        SettingRow(title: command.spec.title, detail: "Command. Also in the Command palette.",
                                   symbol: "command", density: .compact) {
                            Button("Run") { registry.run(command) }.buttonStyle(ModPill(prominent: false))
                        }
                    }
                    ForEach(corners) { corner in
                        SettingRow(title: corner.spec.title, detail: "Hot corner action. Put it on a corner in Hot Corners.",
                                   symbol: "rectangle.inset.topleft.filled", density: .compact) {
                            Button("Hot Corners") { go(.corners) }.buttonStyle(ModPill(prominent: false))
                        }
                    }
                    PluginHookRows(plugin: id, go: go)
                }
            }
            .padding(.top, DS.Space.s)
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Permissions", symbol: "hand.raised", detail: "Asked for when you switch it on. Nothing is granted by default.", hue: ModsHue.tint)
            RowGroup {
                if entry.pluginPermissions.isEmpty {
                    SettingRow(title: "None", detail: "Draws widgets and tiles and keeps its own small settings. No network, no files.",
                               symbol: "checkmark.shield", density: .compact) { EmptyView() }
                }
                ForEach(entry.pluginPermissions) { permission in
                    SettingRow(title: permission.title, detail: detail(for: permission), symbol: permission.symbol, density: .compact) { EmptyView() }
                }
            }
            .padding(.top, DS.Space.s)
        }
    }

    private func detail(for permission: PluginPermission) -> String {
        guard permission == .network, !entry.hosts.isEmpty else { return permission.detail }
        return "Download data over https from \(entry.hosts.joined(separator: ", ")). Nothing else on the network."
    }

    private var details: some View {
        RowGroup {
            row("Version", entry.version)
            row("Signed", entry.signedByAuthor ? "By the author and the catalog" : "By the catalog")
            if let key = entry.authorKey { row("Author key", ModAuthorSignature.fingerprint(key)) }
            if let n = entry.downloads { row("Installs", ModCounts.short(n)) }
            if let n = entry.likes { row("Likes", ModCounts.short(n)) }
            if let need = entry.minAtelier { row("Needs Atelier", need + " or newer") }
            if let license = entry.license { row("Licence", license) }
            row("Size", ByteCountFormatter.string(fromByteCount: Int64(entry.package.size), countStyle: .file))
            if let updated = entry.updated { row("Updated", updated.formatted(date: .abbreviated, time: .omitted)) }
            row("Identifier", entry.id)
            Button { NSWorkspace.shared.open(ModsConfig.reportPage) } label: {
                SettingRow(title: "Report a problem", detail: "Opens the catalog’s issue form on GitHub.", symbol: "flag", density: .compact) {
                    Image(systemName: "arrow.up.right").foregroundStyle(DS.Ink.tertiary)
                }
            }
            .buttonStyle(Pressable(scale: 0.99))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        SettingRow(title: title, density: .compact) {
            Text(value).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary).lineLimit(1).textSelection(.enabled)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Version history", symbol: "clock.arrow.circlepath", hue: ModsHue.tint)
            RowGroup {
                ForEach(entry.versions, id: \.version) { v in
                    let mine = store.installedVersion(entry.id)
                    SettingRow(title: v.version + (v.version == entry.version ? " (latest)" : "") + (v.version == mine ? " · installed" : ""),
                               detail: v.notes ?? "No notes.", density: .compact) {
                        HStack(spacing: DS.Space.s) {
                            Text(v.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "")
                                .font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                            // Any version, older ones with a warning on the review sheet first.
                            if v.version != mine, store.work[entry.id] == nil, entry.kind != .native || store.nativeAvailable {
                                Button("Install This Version") { store.install(entry, version: v.version) }
                                    .buttonStyle(ModPill(prominent: false))
                            }
                        }
                    }
                }
            }
            .padding(.top, DS.Space.s)
        }
    }
}

/// Native mods are a different kind of thing; the page says so before anything else.
struct NativeBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 18)).foregroundStyle(ModsHue.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text("Runs inside the Dock").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                Text("A native mod is compiled code loaded through the Dock Bridge. It is not sandboxed: it can see and change every window. A maintainer read its source before it was listed, but only install it if you trust its author.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Inset.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardSurface(style: .lit(ModsHue.danger)) }
    }
}

/// The last word before a native mod is installed. Install stays off until the risk is acknowledged.
struct NativeModWarningSheet: View {
    let entry: ModEntry
    let done: (Bool) -> Void
    @State private var understood = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 28)).foregroundStyle(ModsHue.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install “\(entry.name)” into the Dock?").font(.system(size: 17, weight: .semibold))
                    Text("Native mod by \(entry.author)\(entry.github.isEmpty ? "" : " (@\(entry.github))"). Version \(entry.version).")
                        .font(DS.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                bullet("cpu", "It is compiled code that runs inside the Dock, with the Dock’s access to every window and Space.")
                bullet("shield.slash", "Atelier cannot sandbox it, limit it or check what it does while it runs.")
                bullet("person.badge.shield.checkmark", "A maintainer reviewed its source before listing it. Review lowers the risk; it does not remove it.")
                bullet("arrow.uturn.backward", "If the Dock misbehaves, remove the mod here and restart the Dock, or turn off the Dock Bridge in Beyond SIP.")
            }
            Toggle("I understand, and I trust this author", isOn: $understood)
                .toggleStyle(.checkbox).font(DS.body)
            HStack {
                if let homepage = entry.homepage {
                    Button("View Source") { NSWorkspace.shared.open(homepage) }
                }
                Spacer()
                Button("Cancel") { done(false) }.keyboardShortcut(.cancelAction)
                Button("Install") { done(true) }
                    .disabled(!understood)
                    .tint(ModsHue.danger)
            }
        }
        .padding(22)
        .frame(width: 470)
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(ModsHue.danger)
            Text(text).font(DS.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Markdown, simply: headings, paragraphs, lists, quotes and code blocks; links, bold, italics
/// and code inline. Images and HTML are not drawn. Links only open over https.
struct ModMarkdown: View {
    let text: String

    enum Block: Equatable {
        case heading(Int, String), paragraph(String), bullet(String), numbered(String, String), quote(String), code(String), rule
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = [], paragraph: [String] = [], code: [String]? = nil
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flush(); blocks.append(.heading(level, String(line.dropFirst(level + 1)))); continue
                }
            }
            if line == "---" || line == "***" { flush(); blocks.append(.rule); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { flush(); blocks.append(.bullet(String(line.dropFirst(2)))); continue }
            if line.hasPrefix(">") { flush(); blocks.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces))); continue }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                flush(); blocks.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...]))); continue
            }
            if line.hasPrefix("![") { continue }
            paragraph.append(line)
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    static func inline(_ text: String) -> AttributedString {
        var value = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        for run in value.runs where run.link != nil {
            if run.link?.scheme != "https" { value[run.range].link = nil }
        }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .tint(ModsHue.tint)
        .textSelection(.enabled)
    }

    @ViewBuilder private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text)).font(.system(size: level == 1 ? 17 : level == 2 ? 15 : 13.5, weight: .semibold))
                .foregroundStyle(DS.Ink.primary).padding(.top, DS.Space.xs)
        case .paragraph(let text):
            Text(Self.inline(text)).font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(DS.Ink.tertiary)
                Text(Self.inline(text)).font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(n + ".").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                Text(Self.inline(text)).font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .quote(let text):
            // The bar is an overlay, so it is exactly as tall as the quote.
            Text(Self.inline(text)).font(DS.body).italic().foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 11)
                .overlay(alignment: .leading) { Capsule().fill(ModsHue.tint.opacity(0.6)).frame(width: 3) }
        case .code(let text):
            Text(text).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(DS.Ink.primary.opacity(0.85))
                .padding(DS.Space.s).frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.pill, style: .continuous))
        case .rule:
            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
        }
    }
}
