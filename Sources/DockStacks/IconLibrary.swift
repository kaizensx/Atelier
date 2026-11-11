import AppKit
import CryptoKit
import SwiftUI

/// macOSicons.com through the search the site itself uses (POST macosicons.com/api/search,
/// found by reading its own requests). No key. Searches are cached for a month and images for
/// good, so Atelier asks the site as little as possible. Credit for each icon is kept.
@MainActor
enum IconLibrary {
    struct Hit: Codable, Hashable, Identifiable {
        let appName: String
        let lowResPngUrl: String?
        let icnsUrl: String?
        let category: String?
        let credit: String?
        let usersName: String?
        let isLiquidGlass: Bool?
        let downloads: Int?
        var id: String { (lowResPngUrl ?? icnsUrl ?? appName) }
    }

    private struct Answer: Codable { let hits: [Hit] }

    enum Failure: LocalizedError {
        case http(Int), empty
        var errorDescription: String? {
            switch self {
            case .http(429): "macOSicons is busy. Try again in a minute."
            case .http(let code): "macOSicons answered with error \(code)."
            case .empty: "No icons found."
            }
        }
    }

    /// Kept for callers that still ask. The search needs no key, so it is always there.
    static var available: Bool { true }

    // MARK: Cache

    private static var folder: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func name(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24).description
    }

    // MARK: Search

    static func search(_ query: String) async throws -> [Hit] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !clean.isEmpty else { return [] }
        // "r2": relevance order. Older cached answers were newest-first and are left to expire.
        let cached = folder.appendingPathComponent("r2-" + name(clean) + ".json")
        if let data = try? Data(contentsOf: cached),
           let modified = (try? cached.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
           Date().timeIntervalSince(modified) < 30 * 86_400,
           let answer = try? JSONDecoder().decode(Answer.self, from: data) {
            return answer.hits
        }
        var request = URLRequest(url: URL(string: "https://macosicons.com/api/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Atelier (macOS customisation app)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": clean,
            // No sort: the site's own relevance. Newest-first buried the matches under any icon
            // whose app name merely contained the word.
            "searchOptions": ["filters": [], "hitsPerPage": 50, "page": 1, "sort": [String]()],
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        let answer = try JSONDecoder().decode(Answer.self, from: data)
        try? data.write(to: cached, options: .atomic)
        return answer.hits
    }

    /// A small picture for the grid, decoded off the main thread and kept in memory. Decoding
    /// fifty 1024 px PNGs on the main thread is what made the picker stutter while scrolling.
    nonisolated static func thumbnail(_ hit: Hit, pixels: Int = 112) async -> CGImage? {
        guard let text = hit.lowResPngUrl ?? hit.icnsUrl, let url = URL(string: text) else { return nil }
        let key = text as NSString
        if let hit = Thumbs.cache.object(forKey: key) { return hit.image }
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier/Icons", isDirectory: true)
            .appendingPathComponent("i-" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined().prefix(24) + "." + ext)
        if !FileManager.default.fileExists(atPath: file.path) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        let image: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ] as CFDictionary)
        }.value
        if let image { Thumbs.cache.setObject(Thumbs.Box(image), forKey: key) }
        return image
    }

    static func image(_ hit: Hit) async -> NSImage? {
        guard let text = hit.lowResPngUrl ?? hit.icnsUrl, let url = URL(string: text) else { return nil }
        let file = folder.appendingPathComponent("i-" + name(text) + "." + (url.pathExtension.isEmpty ? "png" : url.pathExtension))
        if let image = NSImage(contentsOf: file) { return image }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data) else { return nil }
        try? data.write(to: file, options: .atomic)
        return image
    }
}

/// Decoded grid pictures, shared by every picker.
enum Thumbs {
    final class Box: @unchecked Sendable { let image: CGImage; init(_ image: CGImage) { self.image = image } }
    nonisolated(unsafe) static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 600
        return cache
    }()
}

// MARK: - Picker

/// Search macOSicons and pick an icon. Reach it through `IconChooserMenu` (HubIcons.swift), the
/// one icon menu every place that changes an icon uses.
struct IconLibraryPicker: View {
    let query: String
    let onPick: (NSImage) -> Void
    @State private var text = ""
    @State private var hits: [IconLibrary.Hit] = []
    @State private var images: [String: CGImage] = [:]
    @State private var choosing: String?
    @State private var message: String?
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Ink.secondary)
                TextField("Search macOSicons", text: $text).textFieldStyle(.plain).onSubmit { run() }
                if loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(DS.Ink.fill, in: .capsule)
            if let message {
                Text(message).font(DS.caption).foregroundStyle(DS.Ink.secondary)
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 10), count: 5), spacing: 12) {
                    ForEach(hits) { hit in
                        Button {
                            // The grid holds small pictures; the full one is fetched for the pick.
                            guard choosing == nil else { return }
                            choosing = hit.id
                            Task {
                                if let image = await IconLibrary.image(hit) { onPick(image) }
                                choosing = nil
                            }
                        } label: {
                            VStack(spacing: 4) {
                                Group {
                                    if let image = images[hit.id] {
                                        Image(decorative: image, scale: 2).resizable()
                                            .opacity(choosing == hit.id ? 0.5 : 1)
                                    } else {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(DS.Ink.fill)
                                    }
                                }
                                .frame(width: 56, height: 56)
                                Text(hit.appName.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)))
                                    .font(.system(size: 9)).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                            }
                            .frame(width: 64)
                            .contentShape(.rect)
                        }
                        .buttonStyle(Pressable(scale: 0.94))
                        .help("\(hit.appName) by \(hit.usersName ?? "the macOSicons community")")
                        .task(id: hit.id) {
                            if images[hit.id] == nil, let image = await IconLibrary.thumbnail(hit) { images[hit.id] = image }
                        }
                    }
                }
            }
            .frame(height: 300)
            Text("Icons by the macOSicons community. Hover an icon to see who made it.")
                .font(.system(size: 10)).foregroundStyle(DS.Ink.tertiary)
        }
        .padding(16)
        .frame(width: 400)
        .onAppear {
            text = query
            if !query.isEmpty { run() }
        }
    }

    private func run() {
        let current = text
        loading = true
        message = nil
        Task {
            do {
                let found = try await IconLibrary.search(current)
                hits = found
                message = found.isEmpty ? IconLibrary.Failure.empty.errorDescription : nil
            } catch {
                hits = []
                message = error.localizedDescription
            }
            loading = false
        }
    }
}


// MARK: - Apply to an app bundle

extension IconLibrary {
    /// Finder shows a custom icon stored in the bundle. Only apps the owner can write to;
    /// Apple's own apps sit on the sealed system volume and refuse.
    static func canApply(toApp path: String) -> Bool {
        !path.hasPrefix("/System/") && FileManager.default.isWritableFile(atPath: path)
    }

    /// Through CustomIcons, so the change is listed and can be put back like any other.
    @discardableResult
    static func apply(_ image: NSImage, toApp path: String) -> Bool {
        guard canApply(toApp: path) else { return false }
        return CustomIcons.shared.set(image, on: URL(fileURLWithPath: path))
    }

    @discardableResult
    static func restore(app path: String) -> Bool { CustomIcons.shared.revert(path) }

    static func hasCustomIcon(_ path: String) -> Bool { CustomIcons.shared.hasCustomIcon(path) }
}

// MARK: - Floating picker

/// The macOSicons search in its own small window, for places with no SwiftUI view to hang a
/// popover on: the Atelier Dock's tile menu, the menu bar. "Choose File…" keeps the old way.
@MainActor
enum IconPickerPanel {
    private static var panel: NSPanel?

    static func show(query: String, title: String, near point: NSPoint? = nil,
                     onPick: @escaping (NSImage) -> Void, onFile: (() -> Void)? = nil) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 470),
                            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow], backing: .buffered, defer: false)
        panel.title = title
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        let root = VStack(alignment: .leading, spacing: 0) {
            IconLibraryPicker(query: query) { image in
                onPick(image)
                close()
            }
            HStack {
                if let onFile {
                    Button("Choose File…") { close(); onFile() }
                }
                Spacer()
                Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .padding(.top, 18)
        panel.contentViewController = NSHostingController(rootView: root)
        if let point, let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main {
            let size = panel.frame.size
            var origin = NSPoint(x: point.x - size.width / 2, y: point.y + 24)
            origin.x = min(max(origin.x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - size.width - 8)
            origin.y = min(max(origin.y, screen.visibleFrame.minY + 8), screen.visibleFrame.maxY - size.height - 8)
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        // The dock's hover card would open over the picker the moment the menu closes, since
        // the pointer is still on the tile. Hold it while the picker is up, and sit above it.
        OwnDock.shared.holdPeek(true)
        panel.level = .popUpMenu
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        closer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: .main) { _ in
            MainActor.assumeIsolated { OwnDock.shared.holdPeek(false) }
        }
    }

    private static var closer: NSObjectProtocol?

    static func close() {
        panel?.close()
        panel = nil
        OwnDock.shared.holdPeek(false)
        if let closer { NotificationCenter.default.removeObserver(closer) }
        closer = nil
    }
}
