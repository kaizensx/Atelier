import AppKit
import CoreServices
import DockCore
import ServiceManagement

enum Palette {
    static let colors: [NSColor] = [
        NSColor(white: 0.82, alpha: 0.75),
        NSColor(srgbRed: 0.04, green: 0.45, blue: 0.98, alpha: 1),
        NSColor(srgbRed: 0.45, green: 0.30, blue: 0.92, alpha: 1),
        NSColor(srgbRed: 0.95, green: 0.25, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.52, blue: 0.10, alpha: 1),
        NSColor(srgbRed: 0.12, green: 0.70, blue: 0.42, alpha: 1),
        NSColor(srgbRed: 0.15, green: 0.16, blue: 0.19, alpha: 1),
    ]
}

enum IconRenderer {
    static func image(_ spec: IconSpec, title: String, items: [StackItem]) -> NSImage {
        let size = 1024.0
        return NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            // A finished icon, from the icon library or the user's own picture, is drawn as
            // it is: it carries its own shape.
            if spec.style == .image, !spec.image.isEmpty, let picture = NSImage(contentsOfFile: spec.image) {
                picture.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver,
                             fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
                return true
            }
            let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
            let path = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
            let index = Palette.colors.indices.contains(spec.color) ? spec.color : 0
            let base = Palette.colors[index]
            if index == 0 {
                base.setFill()
                path.fill()
            } else {
                let top = base.blended(withFraction: 0.22, of: .white) ?? base
                let bottom = base.blended(withFraction: 0.14, of: .black) ?? base
                NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
            }
            NSColor(white: 1, alpha: 0.3).setStroke()
            path.lineWidth = 6
            path.stroke()
            let ink = index == 0 ? NSColor(white: 0.12, alpha: 1) : NSColor.white
            switch spec.style {
            case .apps, .image: drawGrid(items, in: tile)
            case .text: drawText(spec.text.isEmpty ? title : spec.text, in: tile.insetBy(dx: 70, dy: 70), ink)
            case .symbol: drawSymbol(spec.symbol, in: tile, ink)
            }
            return true
        }
    }

    private static func drawGrid(_ items: [StackItem], in tile: NSRect) {
        let columns = 3, padding = 44.0, gap = 34.0
        let cell = (tile.width - padding * 2 - gap * Double(columns - 1)) / Double(columns)
        for (index, item) in items.prefix(columns * columns).enumerated() {
            let x = tile.minX + padding + Double(index % columns) * (cell + gap)
            let y = tile.minY + padding + Double(index / columns) * (cell + gap)
            ItemIcon.image(for: item).draw(
                in: NSRect(x: x, y: y, width: cell, height: cell),
                from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private static func drawSymbol(_ name: String, in tile: NSRect, _ ink: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 420, weight: .semibold)
            .applying(.init(hierarchicalColor: ink))
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let box = NSRect(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2,
                         width: symbol.size.width, height: symbol.size.height)
        symbol.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                    respectFlipped: true, hints: nil)
    }

    private static func drawText(_ text: String, in box: NSRect, _ ink: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        func attributes(_ size: Double) -> [NSAttributedString.Key: Any] {
            let base = NSFont.systemFont(ofSize: size, weight: .bold)
            let rounded = base.fontDescriptor.withDesign(.rounded)
                .flatMap { NSFont(descriptor: $0, size: size) } ?? base
            return [.font: rounded, .paragraphStyle: paragraph, .foregroundColor: ink]
        }
        func height(_ attrs: [NSAttributedString.Key: Any]) -> Double {
            (text as NSString).boundingRect(with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
                                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                                            attributes: attrs).height
        }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var chosen = 60.0
        for size in stride(from: 340.0, through: 60.0, by: -10.0) {
            let attrs = attributes(size)
            let widest = words.map { ($0 as NSString).size(withAttributes: attrs).width }.max() ?? 0
            if widest <= box.width && height(attrs) <= box.height { chosen = size; break }
        }
        let attrs = attributes(chosen)
        let textHeight = height(attrs)
        let frame = NSRect(x: box.minX, y: box.midY - textHeight / 2, width: box.width, height: textHeight)
        (text as NSString).draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attrs)
    }
}

enum ItemIcon {
    static func image(for item: StackItem) -> NSImage {
        switch item.kind {
        case .app, .file: return NSWorkspace.shared.icon(forFile: item.value)
        case .url: return symbol("globe", .systemBlue)
        case .shortcut: return symbol("square.2.layers.3d.fill", .systemPink)
        case .group: return group(item.children)
        case .plugin: return PluginStackValue(item.value).map(PluginHookIcons.image) ?? symbol("puzzlepiece.extension", .systemGray)
        }
    }

    private static func symbol(_ name: String, _ color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .medium)
            .applying(.init(hierarchicalColor: color))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) ?? NSImage()
    }

    private static func group(_ items: [StackItem]) -> NSImage {
        IconRenderer.image(IconSpec(), title: "", items: items)
    }
}

@MainActor
enum Launcher {
    static func open(_ item: StackItem) {
        switch item.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.value), configuration: .init())
        case .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: item.value))
        case .url:
            if let url = URL(string: item.value) { NSWorkspace.shared.open(url) }
        case .shortcut:
            let name = item.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "shortcuts://run-shortcut?name=\(name)") { NSWorkspace.shared.open(url) }
        case .group:
            break
        case .plugin:
            if let value = PluginStackValue(item.value), let action = value.action { PluginHooks.shared.perform(value.plugin, action) }
        }
    }
}

/// Installed apps, plus usage dates kept fresh in the background so the bubble never waits.
@MainActor
final class AppCatalog {
    static let shared = AppCatalog()
    private(set) var apps: [StackItem] = []
    private var lastUsed: [String: Date] = [:]
    private var installed: [String: Date] = [:]

    func refresh() {
        Task.detached(priority: .utility) {
            let result = Self.scan()
            await MainActor.run {
                self.apps = result.apps
                self.lastUsed = result.used
                self.installed = result.installed
            }
        }
    }

    private nonisolated static func scan() -> (apps: [StackItem], used: [String: Date], installed: [String: Date]) {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications"]
        var found: [String: StackItem] = [:]
        func add(_ path: String) {
            let item = StackItem.path(path)
            if found[item.name] == nil { found[item.name] = item }
        }
        for root in roots {
            for entry in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
                let path = root + "/" + entry
                if entry.hasSuffix(".app") {
                    add(path)
                } else {
                    for inner in (try? fm.contentsOfDirectory(atPath: path)) ?? [] where inner.hasSuffix(".app") {
                        add(path + "/" + inner)
                    }
                }
            }
        }
        var used: [String: Date] = [:], installed: [String: Date] = [:]
        for item in found.values {
            guard let md = MDItemCreate(nil, item.value as CFString) else { continue }
            used[item.value] = MDItemCopyAttribute(md, kMDItemLastUsedDate) as? Date
            installed[item.value] = MDItemCopyAttribute(md, kMDItemDateAdded) as? Date
        }
        let apps = found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return (apps, used, installed)
    }

    /// Dates the catalogue already knows, for sorting and filtering without the disk.
    func facts(_ item: StackItem) -> StackFacts {
        StackFacts(added: installed[item.value], used: lastUsed[item.value])
    }

    func items(for rule: SmartRule, fallback: [StackItem]) -> [StackItem] {
        let limit = 12
        switch rule {
        case .none:
            return fallback
        case .running:
            return NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.path }
                .map(StackItem.path)
        case .recentlyUsed:
            return apps.filter { lastUsed[$0.value] != nil }
                .sorted { lastUsed[$0.value]! > lastUsed[$1.value]! }
                .prefix(limit).map { $0 }
        case .recentlyInstalled:
            return apps.filter { installed[$0.value] != nil }
                .sorted { installed[$0.value]! > installed[$1.value]! }
                .prefix(limit).map { $0 }
        }
    }
}

/// Bubble tint sampled from the wallpaper.
@MainActor
final class Mood {
    static let shared = Mood()
    private(set) var color: NSColor?

    func refresh() {
        guard let url = Wallpaper.url() else { return }
        Task.detached(priority: .utility) {
            let sampled = Self.average(of: url)
            await MainActor.run { self.color = sampled }
        }
    }

    private nonisolated static func average(of url: URL) -> NSColor? {
        guard let image = NSImage(contentsOf: url),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                            isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.colorAt(x: 0, y: 0)
    }
}

/// Stack lifecycle: the Dock must let go of a stack before its file is renamed.
enum StackActions {
    static func writeIcon(_ document: StackDocument, at url: URL) throws {
        let image = IconRenderer.image(document.icon, title: document.title, items: document.items)
        guard NSWorkspace.shared.setIcon(image, forFile: url.path) else {
            throw DockFailure("Could not apply the icon.")
        }
    }

    static func apply(_ source: StackDocument, existing: URL?) throws -> URL {
        var document = source
        document.title = try StackStore.cleanTitle(source.title)
        let fm = FileManager.default
        try fm.createDirectory(at: StackStore.folder, withIntermediateDirectories: true)
        let target = StackStore.url(forTitle: document.title)
        let renaming = existing != nil && existing?.path != target.path
        if existing == nil || renaming, fm.fileExists(atPath: target.path) {
            throw DockFailure("A stack already exists named “\(document.title)”.")
        }

        if let existing {
            let previous = try? StackStore.load(existing)
            if !renaming, let previous, sameIcon(previous, document) {
                try StackStore.save(document, to: target)
                return target
            }
            // The Dock only rereads a package's icon when its tile is added again.
            var slot: Int?
            try DockStore.update("Before changing \(existing.deletingPathExtension().lastPathComponent)") {
                slot = Tiles.detach(path: existing.path, from: &$0)
            }
            do {
                if renaming { try fm.moveItem(at: existing, to: target) }
                try StackStore.save(document, to: target)
                try writeIcon(document, at: target)
            } catch {
                let current = fm.fileExists(atPath: target.path) ? target : existing
                try? DockStore.update("Restore stack") {
                    Tiles.attach(Tiles.stack(path: current.path, label: document.title), to: &$0, at: slot)
                }
                throw error
            }
            try DockStore.update("Stack \(document.title)") {
                Tiles.attach(Tiles.stack(path: target.path, label: document.title), to: &$0, at: slot)
            }
        } else {
            try StackStore.save(document, to: target)
            try writeIcon(document, at: target)
            try DockStore.update("Stack \(document.title)") {
                Tiles.attach(Tiles.stack(path: target.path, label: document.title), to: &$0, at: nil)
            }
        }
        return target
    }

    private static func sameIcon(_ a: StackDocument, _ b: StackDocument) -> Bool {
        guard a.icon == b.icon else { return false }
        switch a.icon.style {
        case .apps: return a.items.prefix(9).map(\.value) == b.items.prefix(9).map(\.value)
        case .text: return !a.icon.text.isEmpty || a.title == b.title
        case .symbol: return true
        case .image: return true
        }
    }

    /// A new stack on disk only, for the Atelier Dock. The macOS Dock is not touched.
    static func make(_ source: StackDocument) throws -> URL {
        var document = source
        document.title = try StackStore.cleanTitle(source.title)
        try FileManager.default.createDirectory(at: StackStore.folder, withIntermediateDirectories: true)
        let target = StackStore.url(forTitle: document.title)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw DockFailure("A stack already exists named “\(document.title)”.")
        }
        try StackStore.save(document, to: target)
        try writeIcon(document, at: target)
        return target
    }

    /// Saves an edited stack. One in the macOS Dock goes through `apply`, which lets the
    /// Dock reread a new icon. One that is not is saved in place and the Dock never hears
    /// of it; its package keeps its name so the Atelier Dock's tile still finds it.
    static func update(_ document: StackDocument, at url: URL, systemDock: Bool) throws -> URL {
        if systemDock { return try apply(document, existing: url) }
        let previous = try? StackStore.load(url)
        try StackStore.save(document, to: url)
        if previous.map({ !sameIcon($0, document) }) ?? true { try writeIcon(document, at: url) }
        return url
    }

    /// Saves how the stack looks and behaves without touching the Dock. Only a new icon
    /// needs the Dock to let go of the tile; this never changes the icon.
    static func saveStyle(_ style: StackStyle, smart: StackSmart?, at url: URL) throws {
        var document = try StackStore.load(url)
        document.style = style
        document.smart = smart
        if smart == nil { document.rule = .none }
        try StackStore.save(document, to: url)
    }

    static func delete(_ url: URL) throws {
        try DockStore.update("Remove \(url.deletingPathExtension().lastPathComponent)") {
            Tiles.detach(path: url.path, from: &$0)
        }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Dock Folders folders still in the Dock.
    static func convertibleFolders() -> [(path: String, title: String, apps: [String], text: String, style: String, color: Int)] {
        guard let plist = try? DockStore.read() else { return [] }
        return Tiles.others(plist).compactMap { tile in
            guard let path = Tiles.path(of: tile),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(".dockfolder.json")),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
            return (path, URL(fileURLWithPath: path).lastPathComponent, json["apps"] as? [String] ?? [],
                    json["iconText"] as? String ?? "", json["style"] as? String ?? "apps", json["color"] as? Int ?? 0)
        }
    }

    /// The stack takes the folder's place. The folder stays on disk.
    static func convert(folderPath: String, title: String, apps: [String], text: String, style: String, color: Int) throws {
        var document = StackDocument(title: title)
        document.items = apps.map(StackItem.path)
        document.icon.style = style == "text" ? .text : .apps
        document.icon.text = text
        document.icon.color = color
        let target = StackStore.url(forTitle: try StackStore.cleanTitle(title))
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw DockFailure("A stack already exists named “\(title)”.")
        }
        try FileManager.default.createDirectory(at: StackStore.folder, withIntermediateDirectories: true)
        try StackStore.save(document, to: target)
        try writeIcon(document, at: target)
        try DockStore.update("Convert \(title)") {
            let slot = Tiles.detach(path: folderPath, from: &$0)
            Tiles.attach(Tiles.stack(path: target.path, label: title), to: &$0, at: slot)
        }
    }
}

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// The login item as a switch can watch: the system's answer, read again after every change,
/// since registering is the system's to accept or put off until the user approves it.
@MainActor
final class LoginItemState: ObservableObject {
    static let shared = LoginItemState()
    @Published private(set) var enabled = LoginItem.enabled
    @Published private(set) var note: String?

    func set(_ on: Bool) {
        do { try LoginItem.set(on); note = nil } catch { note = error.localizedDescription }
        enabled = LoginItem.enabled
        if on, SMAppService.mainApp.status == .requiresApproval {
            note = "Approve Atelier in System Settings › General › Login Items."
        }
        // The status can settle a moment later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.enabled = LoginItem.enabled }
    }
}
