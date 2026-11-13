import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

/// Mods › Library (what was Themes & Plugins): the owner's themes, import and export, "Create Theme from my Mac", and
/// the plugin manager. Drop a `.ateliertheme` or `.atelierplugin` anywhere on the panel.
struct ThemesChapter: View {
    @ObservedObject var model: ManagerModel
    @ObservedObject private var engine = ThemeEngine.shared
    @State private var creating = false
    @State private var linking = false
    @State private var dropping = false
    @State private var failure: String?
    @State private var installedPlugin: InstalledPlugin?

    var body: some View {
        LooksStatusBar(model: model)

        SectionHeader("Make and share", symbol: "wand.and.sparkles",
                      detail: "Drop a .ateliertheme, an .atelierplugin or a pack on these tiles to install it.", hue: DS.Ink.accent)
        Grid(horizontalSpacing: DS.Space.m, verticalSpacing: DS.Space.m) {
            GridRow {
                ActionTile(title: "Create Theme from my Mac", detail: "Save how everything looks now.", symbol: "wand.and.sparkles", prominent: true) { creating = true }
                ActionTile(title: "Import Theme…", detail: "A .ateliertheme or theme JSON.", symbol: "square.and.arrow.down") { importPanel() }
            }
            GridRow {
                ActionTile(title: "Open Theme Link…", detail: "atelier://theme?url=…", symbol: "link") { linking = true }
                ActionTile(title: "Show Themes Folder", detail: "~/Library/Application Support/Atelier", symbol: "folder") {
                    try? FileManager.default.createDirectory(at: ThemeEngine.folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([ThemeEngine.folder])
                }
            }
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.055, blue: 0.07).opacity(0.92))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                            .strokeBorder(DS.Ink.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    }
                    .overlay {
                        VStack(spacing: DS.Space.s) {
                            Image(systemName: "arrow.down.circle.fill").font(.system(size: 26, weight: .semibold)).foregroundStyle(DS.Ink.accent)
                            Text("Drop to install").font(DS.title).foregroundStyle(DS.Ink.primary)
                        }
                    }
                    .transition(.opacity)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in drop(providers) }
        .animation(DS.Motion.hover, value: dropping)

        if engine.downloading {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Downloading theme…").font(DS.caption).foregroundStyle(DS.Ink.secondary) }
                .padding(.horizontal, DS.Space.xs)
        }
        ForEach([failure, engine.problem].compactMap { $0 }, id: \.self) { text in
            Label(text, systemImage: "exclamationmark.triangle.fill").font(DS.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .padding(.horizontal, DS.Space.xs)
        }
        if let notice = engine.notice {
            Label(notice, systemImage: "checkmark.circle.fill").font(DS.caption).foregroundStyle(DS.Ink.accent)
                .padding(.horizontal, DS.Space.xs)
        }

        SectionHeader("Your themes", symbol: "paintpalette", hue: DS.Ink.accent)
        if engine.installed.isEmpty {
            ThemesEmptyShelf(symbol: "paintpalette",
                             text: "No themes of your own yet. Create one from your Mac, or drop a .ateliertheme on the tiles above.")
        } else {
            LazyVGrid(columns: LookCard.columns, spacing: DS.Space.m) {
                ForEach(engine.installed) { theme in
                    VStack(spacing: DS.Space.s) {
                        LookCard(theme: theme, applied: engine.appliedID == theme.id) {
                            engine.apply(theme)
                            model.applied += 1
                        } hover: { over in
                            ThemePreview.shared.show(over ? theme : nil, on: model)
                        }
                        HStack(spacing: 6) {
                            if !theme.warnings.isEmpty {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                    .help(theme.warnings.map(\.description).joined(separator: "\n"))
                            }
                            Text(theme.document.author.map { "By \($0)" } ?? "").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: DS.Space.s)
                            HoldButton(title: "Hold to Remove") { engine.remove(theme) }
                                .frame(width: 156)
                        }
                        .padding(.horizontal, DS.Space.xs)
                    }
                }
            }
        }

        PluginManagerSection()

        PacksLibrarySection()

        SectionHeader("For makers", symbol: "doc.text", hue: DS.Ink.accent)
        RowGroup {
            SettingRow(title: "Theme format", detail: "A folder with atelier-theme.json, plus optional pictures and sounds.",
                       symbol: "paintpalette", density: .compact) {
                Text("THEMES.md").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
            }
            .help("Documented in docs/THEMES.md in Atelier’s source, with a JSON Schema and examples.")
            SettingRow(title: "Plugin format", detail: "A folder with manifest.json and a script.",
                       symbol: "puzzlepiece.extension", density: .compact) {
                Text("PLUGINS.md").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
            }
            .help("Documented in docs/PLUGINS.md in Atelier’s source, with a JSON Schema and examples.")
        }
        Color.clear.frame(height: 0)
            .sheet(isPresented: $creating) { CreateThemeSheet { creating = false } }
            .sheet(isPresented: $linking) { ThemeLinkSheet { linking = false } }
            .sheet(item: $installedPlugin) { plugin in
                PluginPermissionsSheet(plugin: plugin) { granted in
                    if let granted { PluginRegistry.shared.enable(plugin, granting: granted) }
                    installedPlugin = nil
                }
            }
            .onAppear { engine.reload(); PluginRegistry.shared.reload() }
            .onDisappear { ThemePreview.shared.show(nil, on: model) }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // Both bundles are packages (Info.plist), so a plain folder type would grey them out.
        let bundles = [("net.dasantos.atelier.theme", ThemeSchema.bundleExtension),
                       ("net.dasantos.atelier.plugin", PluginManifest.bundleExtension)]
            + ModPackKind.allCases.map { ("net.dasantos.atelier." + $0.rawValue + "pack", $0.bundleExtension) }
        let types = bundles.compactMap { id, ext in
            UTType(id) ?? UTType(filenameExtension: ext, conformingTo: .package)
        }
        panel.allowedContentTypes = types + [.json, .folder]
        panel.message = "Choose a .ateliertheme, an .atelierplugin, a pack or an atelier-theme.json"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        install(url)
    }

    private func install(_ url: URL) {
        failure = nil
        engine.problem = nil
        do {
            if ModPackKind.of(extension: url.pathExtension) != nil {
                try ModPackStore.shared.install(from: url)
            } else if url.pathExtension == PluginManifest.bundleExtension {
                let plugin = try PluginRegistry.shared.install(from: url)
                if plugin.manifest.permissions.isEmpty { PluginRegistry.shared.enable(plugin, granting: []) } else { installedPlugin = plugin }
            } else {
                try engine.install(from: url)
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { install(url) } }
        }
        return true
    }
}

/// A big, quiet button with a symbol, used for the chapter's main actions. The first is lit.
private struct ActionTile: View {
    let title: String
    let detail: String
    let symbol: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            // Glyph above the words: beside them, a half-width tile left the text a sliver.
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Image(systemName: symbol).font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(prominent ? Color.black.opacity(0.8) : DS.Ink.accent)
                    .frame(width: 36, height: 36)
                    .background(prominent ? AnyShapeStyle(DS.Ink.accent) : AnyShapeStyle(DS.Ink.accent.opacity(0.14)),
                                in: .rect(cornerRadius: DS.Radius.pill, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DS.Inset.card)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 84)
            .background { CardSurface(style: prominent ? .lit(DS.Ink.accent) : .standard) }
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .strokeBorder(.white.opacity(hovering ? 0.16 : 0), lineWidth: 0.5)
            }
            .contentShape(.rect(cornerRadius: DS.Radius.card, style: .continuous))
        }
        .buttonStyle(Pressable(scale: 0.985))
        .onHover { hovering = $0 }
        .animation(DS.Motion.hover, value: hovering)
    }
}

/// An empty shelf: what goes here, and how it gets here.
struct ThemesEmptyShelf: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(DS.Ink.tertiary)
                .frame(width: 36, height: 36)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.pill, style: .continuous))
            Text(text).font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DS.Inset.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(DS.Ink.edge, style: StrokeStyle(lineWidth: 0.75, dash: [5, 4]))
        }
    }
}

/// Names the theme, then saves it to the Themes folder, a folder of the owner's choice, or both.
private struct CreateThemeSheet: View {
    let done: () -> Void
    @State private var name = "My Mac"
    @State private var author = NSFullUserName()
    @State private var install = true
    @State private var error: String?
    @State private var preview: ThemeDocument = ThemeApplier.capture()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                LooksScreen { LookMiniature(theme: preview, bundle: nil) }
                    .frame(width: 168)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Create Theme from my Mac").font(.system(size: 17, weight: .semibold))
                    Text("Saves your Atelier Dock, widgets, menu bar, wallpaper, Studio, icons and clock as one theme.")
                        .font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Form {
                TextField("Name", text: $name)
                TextField("Author", text: $author)
                Toggle("Add to my themes", isOn: $install)
            }
            .formStyle(.grouped)
            .frame(height: 150)
            Text("Sections: " + preview.touched.joined(separator: ", ")).font(DS.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(DS.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save As…") { save(choosing: true) }
                Button(install ? "Create" : "Save…") { save(choosing: !install) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private func save(choosing: Bool) {
        let engine = ThemeEngine.shared
        let title = name.trimmingCharacters(in: .whitespaces)
        do {
            if install {
                let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: temp) }
                try engine.install(from: engine.export(name: title, author: author, to: temp))
            }
            if choosing {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.prompt = "Save Here"
                guard panel.runModal() == .OK, let folder = panel.url else { if install { done() }; return }
                let url = try engine.export(name: title, author: author, to: folder)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            done()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Paste a theme link. The theme is downloaded and installed, never applied, so it can be
/// previewed first.
private struct ThemeLinkSheet: View {
    let done: () -> Void
    @State private var text = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open Theme Link").font(.system(size: 17, weight: .semibold))
            Text("Paste an atelier://theme?url=… link, or an https link to an atelier-theme.json or a zipped .ateliertheme. Atelier downloads it, checks it, and adds it to your themes without applying it.")
                .font(DS.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("atelier://theme?url=https://…", text: $text).textFieldStyle(.roundedBorder)
            if let error { Text(error).font(DS.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Download") { open() }.keyboardShortcut(.defaultAction).disabled(text.isEmpty || working)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func open() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var link = URL(string: trimmed)
        if link?.scheme == "https", let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~/:")) {
            link = URL(string: "atelier://theme?url=" + encoded)
        }
        guard let link else { error = "That is not a link."; return }
        working = true
        Task {
            do {
                _ = try await ThemeEngine.shared.open(link: link)
                done()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
