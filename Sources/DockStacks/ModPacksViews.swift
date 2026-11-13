import AppKit
import DockCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Mod packs: views
//
// The Mods chapter's filter chips and the pack previews on a mod's page, the Library's list of
// packs, and the small choosers each pack kind adds where it belongs: sound packs in Typing
// Sounds and the Dock's sounds, shader packs in Live Wallpaper, effect packs in the minimise
// effect picker.

extension ModsHue {
    static let pack = Color(red: 0.46, green: 0.86, blue: 0.95)
}

/// Browse: a second row of chips for the pack kinds, under the main kinds.
struct PackKindFilter: View {
    @Binding var kind: ModKind?

    var body: some View {
        WrapStack(spacing: 6, lineSpacing: 6) {
            Text("Packs").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            ForEach(ModPackKind.allCases) { pack in
                let selected = kind?.pack == pack
                Button {
                    withAnimation(DS.Motion.touch) { kind = selected ? nil : ModKind(pack) }
                } label: {
                    ModChip(text: pack.plural, symbol: pack.symbol, hue: ModsHue.pack, strong: selected)
                }
                .buttonStyle(Pressable())
                .accessibilityLabel("Show \(pack.plural)")
            }
        }
    }
}

/// The one action a pack has, as a pill: Use, Wear, Add; or a quiet In Use with a way out.
struct PackUseButton: View {
    let pack: InstalledPack
    @ObservedObject private var store = ModPackStore.shared

    var body: some View {
        if store.isInUse(pack) {
            HStack(spacing: 6) {
                ModChip(text: inUse, symbol: "checkmark", hue: DS.Spectrum.input, strong: true)
                Button(stop) { store.stopUsing(pack) }.buttonStyle(ModPill(prominent: false))
            }
        } else {
            Button(action) { store.use(pack) }.buttonStyle(ModPill())
        }
    }

    private var action: String {
        switch pack.kind {
        case .icons, .sounds, .effects: "Use"
        case .shader, .look: "Wear"
        case .layouts: "Add to Layouts"
        }
    }

    private var inUse: String { pack.kind == .layouts ? "Added" : "In use" }
    private var stop: String {
        switch pack.kind {
        case .layouts: "Remove Layouts"
        case .look: "Revert"
        default: "Stop"
        }
    }
}

/// On a pack's page in Mods: its preview once installed.
struct PackPageSection: View {
    let id: String
    @ObservedObject private var store = ModPackStore.shared

    var body: some View {
        if let pack = store.pack(id) {
            PackPreview(pack: pack)
        } else {
            Text("Install it to preview it here. Packs are data only: nothing in them runs.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                .padding(.horizontal, DS.Space.xs)
        }
    }
}

/// A pack's contents, the way each kind is best seen.
struct PackPreview: View {
    let pack: InstalledPack

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(pack.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(DS.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch pack.pack {
            case .icons(let icons): IconPackPreview(pack: pack, icons: icons)
            case .sounds(let sounds): SoundPackPreview(pack: pack, sounds: sounds)
            case .shader(let shader): ShaderPackPreview(shader: shader).frame(maxWidth: 520)
            case .layouts(let layouts): LayoutPackPreview(layouts: layouts.layouts)
            case .effects(let effects): EffectPackPreview(pack: pack, effects: effects.effects)
            case .look(let look): LookPackPreview(pack: pack, look: look)
            }
        }
    }
}

// MARK: Icons

struct IconPackPreview: View {
    let pack: InstalledPack
    let icons: IconPack
    @ObservedObject private var store = ModPackStore.shared
    @State private var all = false

    private let columns = [GridItem(.adaptive(minimum: 74, maximum: 96), spacing: DS.Space.s)]

    var body: some View {
        let keys = icons.icons.keys.sorted { label($0).localizedCaseInsensitiveCompare(label($1)) == .orderedAscending }
        let shown = all ? keys : Array(keys.prefix(48))
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("\(keys.count) icons. Click one to keep that app's own icon while the pack is in use.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, spacing: DS.Space.s) {
                    ForEach(shown, id: \.self) { key in cell(key) }
                }
                if keys.count > shown.count {
                    Button("Show all \(keys.count)") { all = true }.buttonStyle(ModPill(prominent: false))
                }
            }
        }
    }

    private func label(_ key: String) -> String {
        if IconPack.specialKeys.contains(key) { return key == "trash.full" ? "Trash (full)" : key.capitalized }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return String(key.split(separator: ".").last ?? Substring(key))
    }

    private func cell(_ key: String) -> some View {
        let original = store.iconOriginals.contains(key)
        let image = icons.icons[key].flatMap { NSImage(contentsOf: pack.file($0)) }
        return Button {
            store.setOriginal(key, !original)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if let image { Image(nsImage: image).resizable().interpolation(.high) } else { Image(systemName: "questionmark.square.dashed") }
                }
                .frame(width: 48, height: 48)
                .opacity(original ? 0.35 : 1)
                .overlay(alignment: .bottomTrailing) {
                    if original { ModChip(text: "Original", hue: .orange, strong: true).scaleEffect(0.8).offset(x: 8, y: 6) }
                }
                Text(label(key)).font(.system(size: 10)).foregroundStyle(DS.Ink.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .help(original ? "\(key): keeps its own icon. Click to use the pack's." : "\(key): click to keep its own icon.")
        .accessibilityLabel("\(label(key)), \(original ? "own icon" : "pack icon")")
    }
}

// MARK: Sounds

struct SoundPackPreview: View {
    let pack: InstalledPack
    let sounds: SoundPack
    @ObservedObject private var store = ModPackStore.shared

    var body: some View {
        RowGroup {
            ForEach(SoundSlot.allCases.filter { sounds.sounds[$0] != nil }) { slot in
                SettingRow(title: slot.title, detail: sounds.sounds[slot], symbol: "speaker.wave.2", density: .compact) {
                    play(sounds.sounds[slot]!)
                }
            }
            if sounds.hasTyping {
                ForEach(TypingSlot.allCases, id: \.self) { slot in
                    let variants = sounds.variants(slot)
                    SettingRow(title: "Typing: \(slot.rawValue)", detail: "\(variants.count) variant\(variants.count == 1 ? "" : "s")",
                               symbol: "keyboard", density: .compact) {
                        HStack(spacing: 4) { ForEach(variants.prefix(4), id: \.self) { play($0) } }
                    }
                }
                if store.soundPackID == pack.id {
                    SettingRow(title: "Use for Typing Sounds", detail: "In place of the built-in voice.", symbol: "keyboard", density: .compact) {
                        LuxSwitch(isOn: $store.typingFromPack, label: "Use for Typing Sounds", tint: DS.Spectrum.sound)
                    }
                }
            }
        }
    }

    private func play(_ path: String) -> some View {
        Button { SoundPackRuntime.preview(pack.file(path)) } label: {
            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(Color.black.opacity(0.8))
                .frame(width: 26, height: 26).background(DS.Spectrum.sound, in: .circle)
        }
        .buttonStyle(Pressable())
        .accessibilityLabel("Play \(path)")
    }
}

/// Where sounds are set: Typing Sounds, and the Dock's sounds. Default is Atelier's own.
struct SoundPackPicker: View {
    let typing: Bool
    @ObservedObject private var store = ModPackStore.shared

    var body: some View {
        let packs = store.packs(.sounds)
        if !packs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("Sound Pack").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    Picker("Sound Pack", selection: $store.soundPackID) {
                        Text("Built-in").tag(String?.none)
                        ForEach(packs) { pack in Text(pack.name).tag(Optional(pack.id)) }
                    }
                    .labelsHidden().fixedSize()
                }
                if typing, let id = store.soundPackID, case .sounds(let sounds)? = store.pack(id)?.pack, sounds.hasTyping {
                    HStack(spacing: 10) {
                        Text("Play the pack's key sounds").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        LuxSwitch(isOn: $store.typingFromPack, label: "Play the sound pack's key sounds", tint: DS.Spectrum.sound)
                    }
                }
            }
        }
    }
}

// MARK: Shaders

/// A shader pack moving, drawn by the same engine as the desktop, a few frames a second.
struct ShaderPackPreview: View {
    let shader: ShaderPack
    var frames = 12.0
    @State private var start = Date()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1 / frames)) { context in
            let time = 20 + context.date.timeIntervalSince(start) * shader.speed
            Group {
                if let image = ShaderPackRuntime.still(shader, width: 384, height: 240, time: time) {
                    Image(decorative: image, scale: 1).resizable()
                } else {
                    LinearGradient(colors: shader.palette.map(Color.init), startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
        .accessibilityLabel("Preview of \(shader.header.name)")
    }
}

/// Live Wallpaper: installed shader packs as extra choices, under the built-in gallery.
struct ShaderPackGallery: View {
    let hue: Color
    @ObservedObject private var store = ModPackStore.shared
    @ObservedObject private var live = LiveWallpaper.shared
    private let columns = [GridItem(.flexible(), spacing: DS.Space.m), GridItem(.flexible(), spacing: DS.Space.m),
                           GridItem(.flexible(), spacing: DS.Space.m)]

    var body: some View {
        let packs = store.packs(.shader)
        if !packs.isEmpty {
            SectionHeader("From shader packs", symbol: ModPackKind.shader.symbol,
                          detail: "Built-in shaders, recoloured and retuned by the community. Click to wear one.", hue: hue)
            LazyVGrid(columns: columns, spacing: DS.Space.m) {
                ForEach(packs) { pack in
                    if case .shader(let shader) = pack.pack {
                        Button { store.use(pack) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                ShaderPackPreview(shader: shader, frames: 4)
                                HStack {
                                    Text(pack.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                                    Spacer(minLength: 4)
                                    if store.isInUse(pack) { Image(systemName: "checkmark.circle.fill").foregroundStyle(hue) }
                                }
                            }
                        }
                        .buttonStyle(Pressable(scale: 0.985))
                    }
                }
            }
        }
    }
}

// MARK: Layouts

struct LayoutDiagram: View {
    let layout: CustomLayout
    var hue: Color = ModsHue.pack

    var body: some View {
        Canvas { context, size in
            let screen = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: screen, cornerRadius: 6), with: .color(.white.opacity(0.06)))
            for (index, zone) in layout.zones.enumerated() {
                let rect = CGRect(x: zone.x * size.width, y: zone.y * size.height,
                                  width: zone.width * size.width, height: zone.height * size.height).insetBy(dx: 2, dy: 2)
                let path = Path(roundedRect: rect, cornerRadius: 4)
                context.fill(path, with: .color(hue.opacity(0.18 + 0.06 * Double(index % 3))))
                context.stroke(path, with: .color(hue.opacity(0.8)), lineWidth: 1)
                context.draw(Text("\(index + 1)").font(.system(size: 10, weight: .semibold)).foregroundColor(.white.opacity(0.8)),
                             at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
        .accessibilityLabel("\(layout.name), \(layout.zones.count) zones")
    }
}

struct LayoutPackPreview: View {
    let layouts: [CustomLayout]
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: DS.Space.m)]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Added to Window Engine's custom layouts: Shift-drag a window to use their zones.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                LazyVGrid(columns: columns, spacing: DS.Space.m) {
                    ForEach(layouts) { layout in
                        VStack(alignment: .leading, spacing: 4) {
                            LayoutDiagram(layout: layout)
                            Text(layout.name).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }
}

// MARK: Effects

struct EffectPackPreview: View {
    let pack: InstalledPack
    let effects: [PackMinimizeEffect]
    @State private var shown: String?
    @AppStorage(MinimizeEffectSetting.packKey) private var packRaw: String?

    var body: some View {
        let current = effects.first { $0.id == shown } ?? effects.first
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                WrapStack(spacing: 6, lineSpacing: 6) {
                    ForEach(effects) { effect in
                        Button { shown = effect.id } label: {
                            ModChip(text: effect.name, symbol: packRaw == pack.id + "/" + effect.id ? "checkmark" : nil,
                                    hue: ModsHue.pack, strong: effect.id == current?.id)
                        }
                        .buttonStyle(Pressable())
                    }
                }
                if let current {
                    MinimizeEffectPlate(effect: current.base, accent: ModsHue.pack, custom: current)
                        .frame(height: 170).frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.28)))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Preview of \(current.name)")
                    HStack {
                        Text("\(current.name): from \(current.base.title), \(String(format: "%.2f", current.duration)) s, \(current.curve.rawValue).")
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        Spacer(minLength: DS.Space.s)
                        Button("Use for Minimise") { packRaw = pack.id + "/" + current.id }.buttonStyle(ModPill())
                            .disabled(packRaw == pack.id + "/" + current.id)
                    }
                }
            }
        }
    }
}

/// In the minimise effect picker: installed effect packs' effects as extra choices.
struct EffectPackChoices: View {
    @Binding var selection: String?
    @ObservedObject private var store = ModPackStore.shared

    var body: some View {
        let choices: [(String, String)] = store.packs(.effects).flatMap { pack -> [(String, String)] in
            guard case .effects(let effects) = pack.pack else { return [] }
            return effects.effects.map { (pack.id + "/" + $0.id, $0.name) }
        }
        if !choices.isEmpty {
            WrapStack(spacing: 6, lineSpacing: 6) {
                Text("From effect packs").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                ForEach(choices, id: \.0) { id, name in
                    Button { selection = selection == id ? nil : id } label: {
                        ModChip(text: name, symbol: ModPackKind.effects.symbol, hue: DockHubHue.tint, strong: selection == id)
                    }
                    .buttonStyle(Pressable())
                }
            }
        }
    }
}

// MARK: Looks

struct LookPackPreview: View {
    let pack: InstalledPack
    let look: LookPack

    var body: some View {
        let theme = try? ThemeEngine.load(pack.file(look.theme))
        RowGroup {
            SettingRow(title: "Theme", detail: theme?.document.name ?? look.theme, symbol: "paintpalette", density: .compact) { EmptyView() }
            if let image = look.wallpaperImage {
                SettingRow(title: "Wallpaper", detail: "A picture: \(image)", symbol: "photo", density: .compact) {
                    if let picture = NSImage(contentsOf: pack.file(image)) {
                        Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill).frame(width: 64, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
            if let shader = look.wallpaperShader {
                SettingRow(title: "Wallpaper", detail: "Shader pack " + describe(shader), symbol: ModPackKind.shader.symbol, density: .compact) { EmptyView() }
            }
            if !look.dock.isEmpty {
                SettingRow(title: "Dock", detail: dock, symbol: "dock.rectangle", density: .compact) { EmptyView() }
            }
            if let icons = look.iconPack {
                SettingRow(title: "Icons", detail: "Icon pack " + describe(icons), symbol: ModPackKind.icons.symbol, density: .compact) { EmptyView() }
            }
            if let sounds = look.soundPack {
                SettingRow(title: "Sounds", detail: "Sound pack " + describe(sounds), symbol: ModPackKind.sounds.symbol, density: .compact) { EmptyView() }
            }
            SettingRow(title: "Revert", detail: "Wearing a Look saves your setup first. Revert in Looks puts all of it back.",
                       symbol: "arrow.uturn.backward", density: .compact) { EmptyView() }
        }
    }

    private func describe(_ ref: PackReference) -> String {
        switch ref {
        case .embedded(let path): "inside the Look (\(path))"
        case .installed(let id): ModPackStore.shared.pack(id)?.name ?? "\(id) (not installed)"
        }
    }

    private var dock: String {
        var parts: [String] = []
        if let edge = look.dock.edge { parts.append("on the \(edge)") }
        if let tile = look.dock.tileSize { parts.append("\(Int(tile)) pt icons") }
        if let large = look.dock.magnifiedSize { parts.append("\(Int(large)) pt magnified") }
        if let magnify = look.dock.magnification { parts.append(magnify ? "magnification on" : "magnification off") }
        if let hide = look.dock.autohide { parts.append(hide ? "hides itself" : "always shown") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Library

/// Library: every installed pack, by kind, with its action, a preview and Remove.
struct PacksLibrarySection: View {
    @ObservedObject private var store = ModPackStore.shared
    @State private var open: String?

    var body: some View {
        SectionHeader("Your packs", symbol: "shippingbox",
                      detail: "Icons, sounds, shaders, layouts, effects and Looks. Data only: nothing in a pack runs.", hue: DS.Ink.accent)
        HStack(spacing: DS.Space.s) {
            Button("Add Pack…") { importPanel() }.buttonStyle(ModPill())
            Button("Show Packs Folder") {
                try? FileManager.default.createDirectory(at: ModPackStore.root, withIntermediateDirectories: true)
                NSWorkspace.shared.activateFileViewerSelecting([ModPackStore.root])
            }
            .buttonStyle(ModPill(prominent: false))
        }
        .padding(.horizontal, DS.Space.xs)
        ForEach([store.problem].compactMap { $0 }, id: \.self) { text in
            Label(text, systemImage: "exclamationmark.triangle.fill").font(DS.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(.horizontal, DS.Space.xs)
        }
        if let notice = store.notice {
            Label(notice, systemImage: "checkmark.circle.fill").font(DS.caption).foregroundStyle(DS.Ink.accent).padding(.horizontal, DS.Space.xs)
        }
        if store.installed.isEmpty {
            ThemesEmptyShelf(symbol: "shippingbox", text: "No packs yet. Find them in Browse, or add a pack folder from Finder.")
        } else {
            RowGroup {
                ForEach(store.installed) { pack in
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        SettingRow(title: pack.name, detail: "\(pack.kind.title) · \(pack.pack.header.version)" + (pack.pack.header.author.isEmpty ? "" : " · \(pack.pack.header.author)"),
                                   symbol: pack.kind.symbol, density: .compact) {
                            HStack(spacing: DS.Space.s) {
                                PackUseButton(pack: pack)
                                ModHoldPill(title: "Remove") { store.remove(pack.id) }.help("Hold to remove")
                                Image(systemName: open == pack.id ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation(DS.Motion.reveal) { open = open == pack.id ? nil : pack.id } }
                        if open == pack.id { PackPreview(pack: pack).padding(.bottom, DS.Space.s) }
                    }
                }
            }
        }
        SettingRow(title: "Pack formats", detail: "One JSON file and its pictures or sounds per pack. Every file is checked before use.",
                   symbol: "doc.text", density: .compact) {
            Text("PACKS.md").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
        }
        .help("Documented in docs/PACKS.md in Atelier’s source, with an example of each kind in examples/packs.")
        .padding(.horizontal, DS.Space.xs)
        Color.clear.frame(height: 0).onAppear { store.reload() }
    }

    private func importPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = ModPackKind.allCases.compactMap {
            UTType("net.dasantos.atelier." + $0.rawValue + "pack") ?? UTType(filenameExtension: $0.bundleExtension, conformingTo: .package)
        } + [.folder]
        panel.message = "Choose a pack: " + ModPackKind.allCases.map { "." + $0.bundleExtension }.joined(separator: ", ")
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.problem = nil
        do { try store.install(from: url) } catch {
            store.problem = (error as? ModCatalogError)?.description ?? error.localizedDescription
        }
    }
}
