import AppKit
import CryptoKit
import DockCore
import SwiftUI

// MARK: - Choosing an icon

/// The one way to change an icon anywhere in Atelier: a menu with "Choose a Picture…" (any image,
/// icon file, or an app or folder lending its own icon) and "Find on macOSicons…" (the community
/// library, no key), plus "Use Original" when there is something to put back.
///
///     IconChooserMenu(query: app.name, canReset: AtelierIcons.shared.has(app.path),
///                     onPick: { AtelierIcons.shared.set($0, for: app.path) },
///                     onReset: { AtelierIcons.shared.reset(app.path) })
///
/// The label defaults to a small "Icon…" pill; pass `label:` for an icon-shaped button instead.
struct IconChooserMenu<Label: View>: View {
    /// What to search macOSicons for first, usually the app's name.
    let query: String
    var canReset = false
    let onPick: (NSImage) -> Void
    var onReset: (() -> Void)?
    @ViewBuilder var label: Label
    @State private var library = false

    var body: some View {
        Menu {
            Button("Choose a Picture…") { if let image = Self.pickPicture(for: query) { onPick(image) } }
            Button("Find on macOSicons…") { library = true }
            if canReset, let onReset {
                Divider()
                Button("Use Original", action: onReset)
            }
        } label: {
            label
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Change icon of \(query)")
        .popover(isPresented: $library) {
            IconLibraryPicker(query: query) { image in
                library = false
                onPick(image)
            }
        }
    }

    /// An image, an .icns, or an app or folder whose own icon is wanted.
    static func pickPicture(for title: String) -> NSImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .icns, .applicationBundle, .folder]
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = title.isEmpty ? "Choose a picture. An app or a folder lends its own icon."
            : "Choose a picture for \(title). An app or a folder lends its own icon."
        panel.prompt = "Use Picture"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        if url.pathExtension == "app" || url.hasDirectoryPath { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(contentsOf: url)
    }
}

extension IconChooserMenu where Label == IconChooserPill {
    init(query: String, title: String = "Icon…", canReset: Bool = false,
         onPick: @escaping (NSImage) -> Void, onReset: (() -> Void)? = nil) {
        self.init(query: query, canReset: canReset, onPick: onPick, onReset: onReset) { IconChooserPill(title: title) }
    }
}

/// The default label: the same pill the Dock's tile inspector uses.
struct IconChooserPill: View {
    let title: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "photo").font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(DS.Ink.primary)
        .padding(.horizontal, 12).frame(height: 30)
        .background(DS.Ink.fillStrong, in: .capsule)
        .contentShape(.capsule)
    }
}

// MARK: - Atelier's own icons

/// Icons Atelier shows in its own places (Orbit, the Launcher widget, Command) in place of an
/// item's real one. Nothing outside Atelier changes, so it works for system and App Store apps
/// too; to change an app's icon everywhere, Folder & App Icons writes it into the app instead.
/// Keyed by the item's path or link. Each is a 512 point PNG beside Atelier's other data.
@MainActor
final class AtelierIcons: ObservableObject {
    static let shared = AtelierIcons()
    /// Bumped on every change so views that show icons draw again.
    @Published private(set) var revision = 0
    private var cache: [String: NSImage] = [:]
    private var missing = Set<String>()

    /// With the rest of Atelier's data, so Remove Everything takes it too.
    nonisolated static var folder: URL { Support.root.appendingPathComponent("AtelierIcons", isDirectory: true) }

    nonisolated static func file(for key: String) -> URL {
        let name = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32)
        return folder.appendingPathComponent(name + ".png")
    }

    /// Off the main thread too (Orbit draws its icons in the background). A stat and, when there
    /// is one, a read.
    nonisolated static func override(for key: String) -> NSImage? {
        let url = file(for: key)
        // One picked for this item wins; then the icon pack in use, by the app's bundle id.
        guard FileManager.default.fileExists(atPath: url.path) else { return IconPackRuntime.image(forPath: key) }
        return NSImage(contentsOf: url)
    }

    /// Whether an icon was picked for this item (not one from an icon pack).
    func has(_ key: String) -> Bool { FileManager.default.fileExists(atPath: Self.file(for: key).path) }

    /// The icon pack changed: every memoised icon is read again, everywhere.
    func packChanged() {
        cache = [:]
        missing = []
        DockIcons.reloadAll()
        OrbitIconStore.shared.forgetAll()
        DockIcons.loaded?()
        revision += 1
    }

    /// The custom icon, if any, memoised so a list of rows reads the disk once per item.
    func custom(_ key: String) -> NSImage? {
        if let hit = cache[key] { return hit }
        if missing.contains(key) { return nil }
        if let image = Self.override(for: key) { cache[key] = image; return image }
        missing.insert(key)
        return nil
    }

    /// The custom icon, or the file's own.
    func icon(forPath path: String) -> NSImage { custom(path) ?? NSWorkspace.shared.icon(forFile: path) }

    func set(_ image: NSImage, for key: String) {
        guard let png = Self.render(image) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try png.write(to: Self.file(for: key), options: .atomic)
        } catch { return }
        cache[key] = NSImage(data: png)
        missing.remove(key)
        changed(key)
    }

    func reset(_ key: String) {
        try? FileManager.default.removeItem(at: Self.file(for: key))
        cache[key] = nil
        missing.insert(key)
        changed(key)
    }

    /// Caches elsewhere (Orbit's bitmaps) hear first, synchronously; then views redraw.
    private func changed(_ key: String) {
        DockIcons.reload(key)
        DockIcons.loaded?()
        NotificationCenter.default.post(name: .atelierIconChanged, object: key)
        revision += 1
    }

    /// A 512 point square PNG, so any picture draws as fast as an app icon.
    private static func render(_ image: NSImage) -> Data? {
        let side = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let size = image.size
        let scale = min(Double(side) / max(size.width, 1), Double(side) / max(size.height, 1))
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: NSRect(x: (Double(side) - drawn.width) / 2, y: (Double(side) - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}

extension Notification.Name {
    /// Object: the key (path or link) whose Atelier icon changed.
    static let atelierIconChanged = Notification.Name("atelierIconChanged")
}

// MARK: - Atelier's app icon

/// Atelier's own icon, in the Dock and the app switcher while it runs. Kept with the other
/// custom icons under a key of its own; nothing in the app bundle changes.
struct StudioIconCard: View {
    @ObservedObject private var icons = AtelierIcons.shared
    static let key = "atelier.app-icon"

    /// Called at launch, so a chosen icon is back before the Dock shows Atelier.
    @MainActor static func restore() {
        if let image = AtelierIcons.shared.custom(key) { NSApp.applicationIconImage = image }
    }

    var body: some View {
        let custom = icons.custom(Self.key)
        Card {
            HStack(spacing: 14) {
                Image(nsImage: custom ?? NSApp.applicationIconImage).resizable().interpolation(.high).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Atelier's Icon").font(DS.title)
                    Text("In the Dock and the app switcher while Atelier runs.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                IconChooserMenu(query: "Atelier", canReset: custom != nil, onPick: { image in
                    icons.set(image, for: Self.key)
                    NSApp.applicationIconImage = image
                }, onReset: {
                    icons.reset(Self.key)
                    NSApp.applicationIconImage = nil
                })
            }
        }
    }
}
