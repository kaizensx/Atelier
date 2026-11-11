import AppKit
import Security
import SwiftUI

// MARK: - Rendering

/// Draws a folder in any colour with a symbol, emoji or picture on it, from the system's
/// own folder icon so it matches the current macOS style.
enum FolderArt {
    enum Glyph: Equatable {
        case none, symbol(String), emoji(String), image(NSImage)
    }

    static func render(colour: NSColor, glyph: Glyph, side: CGFloat = 512) -> NSImage {
        let base = NSWorkspace.shared.icon(for: .folder)
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return NSImage(size: rect.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let cgBase = base.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: AffineTransform(scale: 1)]) else { return false }
            context.draw(cgBase, in: rect)
            // Recolour, keeping the folder's own light and shade.
            context.saveGState()
            context.clip(to: rect, mask: cgBase)
            context.setBlendMode(.color)
            context.setFillColor(colour.cgColor)
            context.fill(rect)
            context.setBlendMode(.softLight)
            context.setFillColor(colour.withAlphaComponent(0.35).cgColor)
            context.fill(rect)
            context.restoreGState()
            // The folder's front face sits a little below centre.
            let face = CGRect(x: side * 0.3, y: side * 0.2, width: side * 0.4, height: side * 0.4)
            let ink = colour.blended(withFraction: 0.55, of: .black) ?? .black
            switch glyph {
            case .none: break
            case let .symbol(name):
                let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.3, weight: .semibold)
                    .applying(.init(paletteColors: [ink.withAlphaComponent(0.85)]))
                if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                    symbol.draw(in: fit(symbol.size, in: face))
                }
            case let .emoji(text):
                let font = NSFont.systemFont(ofSize: side * 0.3)
                let string = NSAttributedString(string: text, attributes: [.font: font])
                let size = string.size()
                string.draw(at: CGPoint(x: face.midX - size.width / 2, y: face.midY - size.height / 2))
            case let .image(image):
                image.draw(in: fit(image.size, in: face.insetBy(dx: -side * 0.05, dy: -side * 0.05)))
            }
            return true
        }
    }

    private static func fit(_ size: CGSize, in box: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: box.midX - fitted.width / 2, y: box.midY - fitted.height / 2, width: fitted.width, height: fitted.height)
    }
}

// MARK: - Store

/// Custom icons Atelier has set, so each can be put back. NSWorkspace.setIcon writes a
/// hidden Icon\r file (folders and bundles) and nothing else; passing nil removes it.
@MainActor
final class CustomIcons: ObservableObject {
    static let shared = CustomIcons()
    @Published private(set) var paths: [String] = UserDefaults.standard.stringArray(forKey: "customIcons.paths") ?? []
    @Published var notice: String?

    enum Refusal: String {
        case system = "System items are protected by macOS."
        case notWritable = "You cannot change this item. App Store apps belong to the system account."
    }

    func refusal(for url: URL) -> Refusal? {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/Library/Apple/") { return .system }
        return FileManager.default.isWritableFile(atPath: path) ? nil : .notWritable
    }

    /// Whether the bundle carries a code signature. Changing its icon adds a file inside it.
    nonisolated static func isSigned(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return false }
        return dictionary[kSecCodeInfoIdentifier as String] != nil
    }

    func set(_ image: NSImage, on url: URL) {
        if let refusal = refusal(for: url) { notice = refusal.rawValue; return }
        guard NSWorkspace.shared.setIcon(image, forFile: url.path, options: []) else {
            notice = "macOS did not accept the icon for \(url.lastPathComponent)."
            return
        }
        if !paths.contains(url.path) { paths.append(url.path); save() }
        notice = nil
        refresh(url)
    }

    func revert(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path), !NSWorkspace.shared.setIcon(nil, forFile: path, options: []) {
            notice = "Could not put back the icon of \(url.lastPathComponent)."
            return
        }
        paths.removeAll { $0 == path }
        save()
        refresh(url)
    }

    private func save() { UserDefaults.standard.set(paths, forKey: "customIcons.paths") }

    /// Finder notices on its own; the Dock caches app icons until its tile is refreshed.
    private func refresh(_ url: URL) {
        NSWorkspace.shared.noteFileSystemChanged(url.path)
        if url.pathExtension == "app" { notice = "The Dock shows the new icon after the app is reopened." }
    }
}

// MARK: - Folder studio

/// Folder & App Icons, in the Files light: a lit plate with the icon drawn large, a palette,
/// a gallery of glyphs, and a gallery of everything Atelier has changed so far.
private enum IconsStudio {
    static let hue = DS.Spectrum.input
    static let graphite = Color(red: 0.06, green: 0.065, blue: 0.08)

    static func hex(_ colour: Color) -> String {
        guard let rgb = NSColor(colour).usingColorSpace(.sRGB) else { return "—" }
        let r = Int((rgb.redComponent * 255).rounded()), g = Int((rgb.greenComponent * 255).rounded()), b = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(r, 255)), max(0, min(g, 255)), max(0, min(b, 255)))
    }
}

/// The studio's plate: graphite, lit from below in `light`, the subject in the middle.
private struct IconsPlate<Content: View>: View {
    var light: Color
    var badge: String? = "Beyond macOS"
    var readout: String?
    var readoutCaption: String?
    var height: Double = 180
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            RadialGradient(colors: [light.opacity(0.42), .clear],
                           center: UnitPoint(x: 0.5, y: 1.15), startRadius: 0, endRadius: 300)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let badge { HeroBadge(text: badge, hue: IconsStudio.hue).padding(10) }
            if let readout {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(readout).font(DS.Typo.readout).foregroundStyle(.white).contentTransition(.numericText())
                    if let readoutCaption {
                        Text(readoutCaption.uppercased()).font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
                    }
                }
                .padding(DS.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(height: height)
        .background(IconsStudio.graphite)
        .clipShape(.rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        }
    }
}

/// The studio's main button, in the Files light.
private struct IconsApplyPill: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.black.opacity(0.85))
                .padding(.horizontal, 16).frame(minWidth: 76).frame(height: 30)
                .background(IconsStudio.hue, in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(Pressable(scale: 0.95))
    }
}

/// A square gallery cell: hover tints, the chosen one ringed in the Files light. Nothing moves.
private struct IconsCell<Content: View>: View {
    let selected: Bool
    var side: Double = 40
    var radius: Double = 10
    let label: String
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button(action: action) {
            content
                .frame(width: side, height: side)
                .background(shape.fill(selected ? IconsStudio.hue.opacity(0.2) : (hover ? DS.Ink.fillStrong : DS.Ink.fill)))
                .overlay { shape.strokeBorder(selected ? IconsStudio.hue : DS.Ink.hairline, lineWidth: selected ? 1.5 : 0.5) }
                .contentShape(shape)
        }
        .buttonStyle(Pressable(scale: 0.94))
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct FolderIconStudio: View {
    @ObservedObject private var icons = CustomIcons.shared
    @State private var folder: URL?
    @State private var colour = Color(red: 0.98, green: 0.55, blue: 0.2)
    @State private var mode = 0
    @State private var symbol = "star.fill"
    @State private var emoji = "🎨"
    @State private var picture: NSImage?
    /// A whole icon in place of the folder, from a picture or macOSicons.
    @State private var whole: NSImage?

    private static let swatches: [Color] = [
        Color(red: 0.98, green: 0.36, blue: 0.36), Color(red: 0.98, green: 0.55, blue: 0.2), Color(red: 0.98, green: 0.8, blue: 0.2),
        Color(red: 0.3, green: 0.8, blue: 0.45), Color(red: 0.25, green: 0.7, blue: 0.95), Color(red: 0.55, green: 0.45, blue: 0.95),
        Color(red: 0.95, green: 0.45, blue: 0.75), Color(red: 0.55, green: 0.57, blue: 0.6),
    ]
    private static let symbols = ["star.fill", "heart.fill", "folder.fill", "doc.text.fill", "photo.fill", "music.note",
                                  "film.fill", "hammer.fill", "briefcase.fill", "graduationcap.fill", "gamecontroller.fill", "leaf.fill",
                                  "camera.fill", "paintbrush.fill", "chevron.left.forwardslash.chevron.right", "lock.fill"]
    /// Wraps to the card's width, so nothing runs past its edge.
    private static let grid = [GridItem(.adaptive(minimum: 40, maximum: 44), spacing: DS.Space.s)]

    private var glyph: FolderArt.Glyph {
        switch mode {
        case 1: .symbol(symbol)
        case 2: emoji.isEmpty ? .none : .emoji(String(emoji.prefix(2)))
        case 3: picture.map(FolderArt.Glyph.image) ?? .none
        default: .none
        }
    }

    /// What Apply writes: the whole icon in Replace mode, else a coloured folder.
    private func finished(side: CGFloat = 512) -> NSImage? {
        if mode == 4 { return whole }
        return FolderArt.render(colour: NSColor(colour), glyph: glyph, side: side)
    }

    private var folderName: String { folder?.lastPathComponent ?? "Folder" }

    var body: some View {
        SectionHeader("Folder icons", symbol: "folder.badge.gearshape",
                      detail: "Colour a folder and put a symbol, emoji or picture on it, or replace it with an icon from macOSicons.",
                      hue: IconsStudio.hue)
        Card(style: folder == nil ? .standard : .lit(IconsStudio.hue), padding: DS.Inset.plate) {
            VStack(alignment: .leading, spacing: 0) {
                plate
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(alignment: .center, spacing: DS.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder?.lastPathComponent ?? "No folder chosen")
                                .font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text(folder == nil ? "Pick a folder, then style it below." : "Finder shows the new icon at once.")
                                .font(DS.body).foregroundStyle(DS.Ink.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(folder?.path ?? "")
                        Chip(folder == nil ? "Choose Folder…" : "Change…") { folder = Self.pick(folders: true) }
                        if let folder, let image = finished() {
                            IconsApplyPill(title: "Apply") { icons.set(image, on: folder) }
                        }
                    }
                    Segments(selection: $mode, options: [(0, "Plain"), (1, "Symbol"), (2, "Emoji"), (3, "Picture"), (4, "Replace")])
                    if mode != 4 { palette }
                    switch mode {
                    case 1:
                        LazyVGrid(columns: Self.grid, alignment: .leading, spacing: DS.Space.s) {
                            ForEach(Self.symbols, id: \.self) { name in
                                IconsCell(selected: symbol == name, label: name, action: { symbol = name }) {
                                    Image(systemName: name).font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(symbol == name ? DS.Ink.primary : DS.Ink.secondary)
                                }
                            }
                        }
                        TextField("Any SF Symbol name", text: $symbol).textFieldStyle(.roundedBorder).font(DS.caption)
                    case 2:
                        TextField("Emoji", text: $emoji).textFieldStyle(.roundedBorder).frame(width: 120)
                    case 3:
                        chooser(picture == nil ? "Choose Picture…" : "Change Picture…", note: "Sits on the folder's front, in its colour.") { picture = $0 }
                    case 4:
                        chooser(whole == nil ? "Choose Icon…" : "Change Icon…", note: "Takes the folder's place entirely.") { whole = $0 }
                    default: EmptyView()
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.top, 14)
                .padding(.bottom, DS.Space.s)
            }
        }
        .animation(DS.Motion.reveal, value: mode)
        CustomIconList(kind: .folders)
    }

    /// The icon drawn large in its own colour's light; the readout is the colour itself.
    private var plate: some View {
        IconsPlate(light: mode == 4 ? IconsStudio.hue : colour,
                   readout: mode == 4 ? nil : IconsStudio.hex(colour), readoutCaption: mode == 4 ? nil : "Colour") {
            Group {
                if let image = finished(side: 256) {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous).fill(DS.Ink.fill)
                        .overlay { Image(systemName: "photo").font(.system(size: 26)).foregroundStyle(DS.Ink.tertiary) }
                        .padding(14)
                }
            }
            .frame(width: 128, height: 128)
            .accessibilityLabel("Folder icon preview")
        }
    }

    private var palette: some View {
        HStack(spacing: DS.Space.s) {
            ForEach(Self.swatches.indices, id: \.self) { index in
                let swatch = Self.swatches[index]
                let chosen = swatch == colour
                Button { colour = swatch } label: {
                    Circle().fill(swatch).frame(width: 24, height: 24)
                        .overlay { Circle().strokeBorder(.white.opacity(chosen ? 0.95 : 0.15), lineWidth: chosen ? 2 : 0.5) }
                        .padding(3)
                        .overlay { Circle().strokeBorder(swatch.opacity(chosen ? 0.8 : 0), lineWidth: 1.5) }
                        .frame(width: 32, height: 32).contentShape(Circle())
                }
                .buttonStyle(Pressable(scale: 0.9)).accessibilityLabel("Colour \(index + 1)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
            ColorPicker("Custom colour", selection: $colour, supportsOpacity: false).labelsHidden()
                .frame(width: 32, height: 32)
            Spacer(minLength: 0)
        }
    }

    private func chooser(_ title: String, note: String, pick: @escaping (NSImage) -> Void) -> some View {
        HStack(spacing: 10) {
            IconChooserMenu(query: folder == nil ? "folder" : folderName, title: title, onPick: pick)
            Text(note).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    static func pick(folders: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.treatsFilePackagesAsDirectories = false
        if !folders { panel.allowedContentTypes = [.application]; panel.directoryURL = URL(fileURLWithPath: "/Applications") }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func pickImage() -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return NSImage(contentsOf: url)
    }
}

// MARK: - App icons

struct AppIconStudio: View {
    @ObservedObject private var icons = CustomIcons.shared
    @ObservedObject private var atelier = AtelierIcons.shared
    @State private var app: URL?
    @State private var replacement: NSImage?
    @State private var signed = false

    private static let gallery = [GridItem(.adaptive(minimum: 92), spacing: DS.Space.s)]

    var body: some View {
        SectionHeader("App icons", symbol: "app.badge",
                      detail: "Your own icon, or one from macOSicons, on apps you can write to. Revert puts the original back.",
                      hue: IconsStudio.hue)
        Card(style: replacement == nil ? .standard : .lit(IconsStudio.hue), padding: DS.Inset.plate) {
            VStack(alignment: .leading, spacing: 0) {
                if app == nil {
                    picker
                } else {
                    IconsPlate(light: IconsStudio.hue, height: 168) {
                        HStack(spacing: DS.Space.xxl) {
                            iconTile(app.map { NSWorkspace.shared.icon(forFile: $0.path) }, label: "Now")
                            Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(IconsStudio.hue.opacity(0.9))
                            iconTile(replacement, label: "New")
                        }
                    }
                    .transition(.opacity)
                }
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack(spacing: DS.Space.s) {
                        if let app {
                            Text(app.deletingPathExtension().lastPathComponent)
                                .font(DS.Typo.hero).tracking(-0.3).foregroundStyle(DS.Ink.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Spacer(minLength: 0)
                        }
                        Chip(app == nil ? "Another App…" : "Change App…") {
                            if let url = FolderIconStudio.pick(folders: false) { choose(url) }
                        }
                        if let app {
                            IconChooserMenu(query: app.deletingPathExtension().lastPathComponent,
                                            title: replacement == nil ? "New Icon…" : "Change…") { replacement = $0 }
                        }
                        if let app, let replacement, icons.refusal(for: app) == nil {
                            IconsApplyPill(title: "Apply") { icons.set(replacement, on: app) }
                        }
                    }
                    if let app {
                        if let refusal = icons.refusal(for: app) {
                            Text(refusal.rawValue + " Atelier can still show your icon in Orbit, the Launcher widget and Command.")
                                .font(DS.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                if let replacement {
                                    Chip("Use in Atelier Only") { atelier.set(replacement, for: app.path) }
                                }
                                if atelier.has(app.path) { Chip("Use Original in Atelier") { atelier.reset(app.path) } }
                            }
                        } else if signed {
                            Text("This app is signed: its seal reads as changed, and an update puts the original back.")
                                .font(DS.caption).foregroundStyle(.orange.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                                .help("The icon is stored as a hidden file inside the app, so its seal reads as changed; apps that check themselves may complain, and an update puts the original back.")
                        }
                    }
                }
                .padding(.horizontal, DS.Space.s)
                .padding(.top, 14)
                .padding(.bottom, DS.Space.s)
            }
        }
        .animation(DS.Motion.reveal, value: app)
        CustomIconList(kind: .apps)
        if let notice = icons.notice { Text(notice).font(DS.caption).foregroundStyle(DS.Ink.tertiary) }
    }

    /// No app yet: the apps worth trying first, as a gallery.
    private var picker: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Pick an app").font(DS.title).foregroundStyle(DS.Ink.primary)
            if Self.suggestions.isEmpty {
                Text("Choose any app you installed yourself. Apple's apps are sealed.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary)
            } else {
                LazyVGrid(columns: Self.gallery, alignment: .leading, spacing: DS.Space.s) {
                    ForEach(Self.suggestions, id: \.self) { url in
                        AppIconsSuggestion(url: url) { choose(url) }
                    }
                }
            }
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.top, DS.Space.s)
    }

    private func choose(_ url: URL) {
        withAnimation(DS.Motion.reveal) { app = url }
        replacement = nil
        signed = CustomIcons.isSigned(url)
    }

    /// Apps you can try it on at once: user-installed ones first, since system apps are sealed.
    static let suggestions: [URL] = {
        let names = ["Spotify", "Discord", "Visual Studio Code", "Slack", "Notion", "Figma", "Arc", "Google Chrome",
                     "Firefox", "Telegram", "WhatsApp", "Zoom", "Obsidian", "Raycast", "iTerm", "Xcode", "Pages", "Keynote"]
        let found = names.map { URL(fileURLWithPath: "/Applications/\($0).app") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return Array(found.prefix(5))
    }()

    private func iconTile(_ image: NSImage?, label: String) -> some View {
        VStack(spacing: 6) {
            Group {
                if let image { Image(nsImage: image).resizable() }
                else {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(DS.Ink.fill)
                        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(DS.Ink.edge, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                        .overlay(Image(systemName: "sparkles").font(.system(size: 22, weight: .medium)).foregroundStyle(DS.Ink.tertiary))
                        .padding(6)
                }
            }
            .frame(width: 88, height: 88)
            Text(label.uppercased()).font(DS.Typo.badge).tracking(0.8).foregroundStyle(DS.Ink.secondary)
        }
    }
}

/// One suggested app in the picker gallery.
private struct AppIconsSuggestion: View {
    let url: URL
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let name = url.deletingPathExtension().lastPathComponent
        Button(action: action) {
            VStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 52, height: 52)
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .background(hover ? DS.Ink.fillStrong : DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .accessibilityLabel(name)
    }
}

/// Items with an Atelier icon, as a gallery, each with Revert.
struct CustomIconList: View {
    enum Kind { case folders, apps }
    let kind: Kind
    @ObservedObject private var icons = CustomIcons.shared
    private static let gallery = [GridItem(.adaptive(minimum: 104), spacing: DS.Space.s)]

    var body: some View {
        let items = icons.paths.filter { ($0.hasSuffix(".app")) == (kind == .apps) }
        if !items.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    HStack {
                        Text(kind == .apps ? "Your app icons" : "Your folders").font(DS.Typo.section).foregroundStyle(DS.Ink.primary)
                        Spacer()
                        Text("\(items.count)").font(DS.Typo.value).foregroundStyle(DS.Ink.tertiary)
                    }
                    LazyVGrid(columns: Self.gallery, alignment: .leading, spacing: DS.Space.s) {
                        ForEach(items, id: \.self) { path in
                            IconsGalleryTile(path: path) { icons.revert(path) }
                        }
                    }
                }
            }
        }
    }
}

/// One changed item: its icon large, its name, Revert. Hover tints only.
private struct IconsGalleryTile: View {
    let path: String
    let revert: () -> Void
    @State private var hover = false

    var body: some View {
        let url = URL(fileURLWithPath: path)
        let name = url.pathExtension == "app" ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        VStack(spacing: 6) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high).frame(width: 56, height: 56)
            Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Ink.primary)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
            Button(action: revert) {
                Text("Revert").font(.system(size: 11, weight: .medium)).foregroundStyle(hover ? DS.Ink.primary : DS.Ink.secondary)
                    .padding(.horizontal, 10).frame(height: 22)
                    .background(DS.Ink.fillStrong, in: .capsule)
            }
            .buttonStyle(Pressable(scale: 0.95))
            .accessibilityLabel("Revert \(name)")
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(hover ? DS.Ink.fillStrong : DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
        .animation(DS.Motion.hover, value: hover)
        .onHover { hover = $0 }
        .help(path)
    }
}
