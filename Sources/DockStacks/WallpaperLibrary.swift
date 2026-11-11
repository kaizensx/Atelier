import AppKit
import CryptoKit
import Security
import SwiftUI

/// Real photographs as wallpapers, from sources that allow it: Wikimedia Commons' featured
/// pictures (each with its own free licence and author), NASA's image library (public domain
/// unless credited otherwise), Bing's image of the day, and Unsplash through its official API
/// with the owner's own free key. Every photo keeps its credit; downloads go to
/// ~/Pictures/Atelier Wallpapers and are never deleted by Atelier.
enum WallpaperSource: String, CaseIterable, Identifiable, Codable {
    case featured, nasa, bing, unsplash
    var id: String { rawValue }

    var title: String {
        switch self {
        case .featured: "Featured"
        case .nasa: "NASA"
        case .bing: "Daily"
        case .unsplash: "Unsplash"
        }
    }

    var detail: String {
        switch self {
        case .featured: "Featured pictures chosen by the Wikimedia Commons community. Free licences; the author is credited."
        case .nasa: "The NASA image library: Earth, space and missions. Generally public domain."
        case .bing: "Bing's image of the day, the last week of them."
        case .unsplash: "Unsplash photos through its official API. Needs your free Unsplash Access Key."
        }
    }
}

struct WallpaperPhoto: Identifiable, Hashable, Codable {
    let id: String
    let source: WallpaperSource
    let title: String
    let thumbnail: URL
    /// A link that downloads the photo at full size, or near the screen's width.
    let full: URL
    let credit: String
    let licence: String?
    let page: URL?
    /// Unsplash asks apps to ping this when a photo is used.
    let downloadPing: URL?
}

@MainActor
enum WallpaperLibrary {
    /// Commons featured categories that make good desktops.
    static let featuredTopics: [(title: String, category: String)] = [
        ("Landscapes", "Featured_pictures_of_landscapes"),
        ("Night Sky", "Featured_pictures_of_astronomy"),
        ("Mountains", "Featured_pictures_of_mountains"),
        ("Water", "Featured_pictures_of_water"),
        ("Cities", "Featured_pictures_of_cityscapes"),
        ("Nature", "Featured_pictures_of_plants"),
    ]

    private static let agent = "Atelier (macOS customisation app)"

    private static var screenWidth: Int {
        Int((NSScreen.screens.map { $0.frame.width * $0.backingScaleFactor }.max() ?? 3024).rounded())
    }

    // MARK: Unsplash key

    private static let service = "net.dasantos.atelier.unsplash"

    static var unsplashKey: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func setUnsplashKey(_ value: String?) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(base as CFDictionary)
        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    // MARK: Fetching

    enum Failure: LocalizedError {
        case noKey, http(Int), empty
        /// The photo downloaded, but the wallpaper was not changed; the reason is macOS's or the original's.
        case refused(String)
        var errorDescription: String? {
            switch self {
            case .noKey: "Add your Unsplash Access Key below to search Unsplash."
            case .http(401): "Unsplash did not accept the Access Key."
            case .http(403): "Unsplash's hourly limit is used up. Try again later."
            case .http(let code): "The server answered with error \(code)."
            case .empty: "No photos found."
            case let .refused(reason): reason
            }
        }
    }

    private static func json(_ url: URL, headers: [String: String] = [:]) async throws -> Any {
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.http(status) }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// `query` is a free search, or for Featured, a topic's category when it starts with "Category:".
    static func search(_ source: WallpaperSource, query: String) async throws -> [WallpaperPhoto] {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .featured: return try await commons(cleaned)
        case .nasa: return try await nasa(cleaned.isEmpty ? "earth from space" : cleaned)
        case .bing: return try await bing()
        case .unsplash: return try await unsplash(cleaned.isEmpty ? "wallpaper" : cleaned)
        }
    }

    private static func commons(_ query: String) async throws -> [WallpaperPhoto] {
        var parts = URLComponents(string: "https://commons.wikimedia.org/w/api.php")!
        let search = query.hasPrefix("Category:") ? "incategory:\(query.dropFirst(9))"
            : "incategory:Featured_pictures_on_Wikimedia_Commons \(query)"
        parts.queryItems = [
            .init(name: "action", value: "query"), .init(name: "format", value: "json"),
            .init(name: "generator", value: "search"), .init(name: "gsrnamespace", value: "6"),
            .init(name: "gsrsearch", value: search), .init(name: "gsrlimit", value: "36"),
            .init(name: "prop", value: "imageinfo"), .init(name: "iiprop", value: "url|size|extmetadata"),
            .init(name: "iiurlwidth", value: "\(screenWidth)"), .init(name: "origin", value: "*"),
        ]
        guard let root = try await json(parts.url!) as? [String: Any],
              let pages = (root["query"] as? [String: Any])?["pages"] as? [String: [String: Any]] else { return [] }
        return pages.values.compactMap { page -> WallpaperPhoto? in
            guard let title = page["title"] as? String, let info = (page["imageinfo"] as? [[String: Any]])?.first,
                  let width = info["width"] as? Int, let height = info["height"] as? Int, width > height,
                  let full = (info["thumburl"] as? String).flatMap(URL.init(string:)) else { return nil }
            // Small thumbnails come from the same scaler: swap the width in the path.
            let thumb = URL(string: full.absoluteString.replacingOccurrences(of: "/\(screenWidth)px-", with: "/480px-")) ?? full
            let meta = info["extmetadata"] as? [String: [String: Any]] ?? [:]
            let artist = (meta["Artist"]?["value"] as? String).map(stripTags) ?? "Wikimedia Commons"
            let licence = meta["LicenseShortName"]?["value"] as? String
            let name = title.replacingOccurrences(of: "File:", with: "").replacingOccurrences(of: "_", with: " ")
            return WallpaperPhoto(id: "commons:" + title, source: .featured,
                                  title: (name as NSString).deletingPathExtension, thumbnail: thumb, full: full,
                                  credit: artist, licence: licence,
                                  page: (info["descriptionurl"] as? String).flatMap(URL.init(string:)), downloadPing: nil)
        }
        .sorted { $0.title < $1.title }
    }

    private static func nasa(_ query: String) async throws -> [WallpaperPhoto] {
        var parts = URLComponents(string: "https://images-api.nasa.gov/search")!
        parts.queryItems = [.init(name: "q", value: query), .init(name: "media_type", value: "image"), .init(name: "page_size", value: "36")]
        guard let root = try await json(parts.url!) as? [String: Any],
              let items = (root["collection"] as? [String: Any])?["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item -> WallpaperPhoto? in
            guard let data = (item["data"] as? [[String: Any]])?.first, let id = data["nasa_id"] as? String,
                  let preview = ((item["links"] as? [[String: Any]])?.first?["href"] as? String).flatMap(URL.init(string:)) else { return nil }
            // The library serves every size under the same name: ~orig is the original.
            let full = URL(string: preview.absoluteString.replacingOccurrences(of: "~thumb.", with: "~orig.")
                                                        .replacingOccurrences(of: "~medium.", with: "~orig.")) ?? preview
            return WallpaperPhoto(id: "nasa:" + id, source: .nasa, title: data["title"] as? String ?? id,
                                  thumbnail: preview, full: full,
                                  credit: (data["photographer"] as? String) ?? (data["center"] as? String).map { "NASA \($0)" } ?? "NASA",
                                  licence: "Public domain (NASA)",
                                  page: URL(string: "https://images.nasa.gov/details/\(id)"), downloadPing: nil)
        }
    }

    private static func bing() async throws -> [WallpaperPhoto] {
        let url = URL(string: "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-GB")!
        guard let root = try await json(url) as? [String: Any], let images = root["images"] as? [[String: Any]] else { return [] }
        return images.compactMap { image -> WallpaperPhoto? in
            guard let base = image["urlbase"] as? String, let start = image["startdate"] as? String,
                  let full = URL(string: "https://www.bing.com\(base)_UHD.jpg"),
                  let thumb = URL(string: "https://www.bing.com\(base)_800x480.jpg") else { return nil }
            let copyright = image["copyright"] as? String ?? "Bing"
            return WallpaperPhoto(id: "bing:" + start, source: .bing, title: image["title"] as? String ?? copyright,
                                  thumbnail: thumb, full: full, credit: copyright, licence: "For use as a wallpaper",
                                  page: (image["copyrightlink"] as? String).flatMap(URL.init(string:)), downloadPing: nil)
        }
    }

    private static func unsplash(_ query: String) async throws -> [WallpaperPhoto] {
        guard let key = unsplashKey else { throw Failure.noKey }
        var parts = URLComponents(string: "https://api.unsplash.com/search/photos")!
        parts.queryItems = [.init(name: "query", value: query), .init(name: "per_page", value: "30"),
                            .init(name: "orientation", value: "landscape"), .init(name: "content_filter", value: "high")]
        guard let root = try await json(parts.url!, headers: ["Authorization": "Client-ID \(key)", "Accept-Version": "v1"]) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return [] }
        let width = screenWidth
        return results.compactMap { photo -> WallpaperPhoto? in
            guard let id = photo["id"] as? String, let urls = photo["urls"] as? [String: String],
                  let raw = urls["raw"], let small = urls["small"].flatMap(URL.init(string:)),
                  let full = URL(string: raw + "&w=\(width)&q=90&fm=jpg") else { return nil }
            let user = photo["user"] as? [String: Any]
            let name = user?["name"] as? String ?? "Unsplash"
            let links = photo["links"] as? [String: String]
            return WallpaperPhoto(id: "unsplash:" + id, source: .unsplash,
                                  title: (photo["alt_description"] as? String)?.capitalized ?? "Photo by \(name)",
                                  thumbnail: small, full: full, credit: "\(name) on Unsplash", licence: "Unsplash License",
                                  page: links?["html"].flatMap { URL(string: $0 + "?utm_source=atelier&utm_medium=referral") },
                                  downloadPing: links?["download_location"].flatMap(URL.init(string:)))
        }
    }

    private static func stripTags(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Using a photo

    static var folder: URL {
        let url = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Atelier Wallpapers", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static let thumbnails = NSCache<NSURL, NSImage>()

    static func thumbnail(_ url: URL) async -> NSImage? {
        if let cached = thumbnails.object(forKey: url as NSURL) { return cached }
        var request = URLRequest(url: url)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        // Decode and shrink off the main thread: a big JPEG decoded while drawing stalls a frame.
        let cg: CGImage? = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 520,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }.value
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        thumbnails.setObject(image, forKey: url as NSURL)
        return image
    }

    /// Downloads the photo, keeps its credit beside it, and sets it on every display.
    static func use(_ photo: WallpaperPhoto) async throws -> URL {
        let digest = SHA256.hash(data: Data(photo.id.utf8)).map { String(format: "%02x", $0) }.joined().prefix(12)
        let safe = photo.title.replacingOccurrences(of: "/", with: "-").prefix(60)
        let file = folder.appendingPathComponent("\(safe) \(digest).jpg")
        if !FileManager.default.fileExists(atPath: file.path) {
            var request = URLRequest(url: photo.full)
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
            let (temp, response) = try await URLSession.shared.download(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw Failure.http(status) }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temp, to: file)
            let credit = "\(photo.title)\n\(photo.credit)\(photo.licence.map { "\n" + $0 } ?? "")\(photo.page.map { "\n" + $0.absoluteString } ?? "")\n"
            try? credit.write(to: file.deletingPathExtension().appendingPathExtension("credit.txt"), atomically: true, encoding: .utf8)
        }
        if let ping = photo.downloadPing, let key = unsplashKey {
            var request = URLRequest(url: ping)
            request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: request)
        }
        guard Effects.shared.setPhotoWallpaper(file) else {
            throw Failure.refused(Effects.shared.notice ?? "The wallpaper could not be changed.")
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(photo), forKey: "wallpaperLibrary.current")
        return file
    }

    static var current: WallpaperPhoto? {
        UserDefaults.standard.data(forKey: "wallpaperLibrary.current").flatMap { try? JSONDecoder().decode(WallpaperPhoto.self, from: $0) }
    }
}

/// Changes the wallpaper once a day from the chosen source, only while the owner has it on.
@MainActor
final class DailyWallpaper: ObservableObject {
    static let shared = DailyWallpaper()
    private let store = UserDefaults.standard
    private var timer: Timer?

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "dailyWallpaper.on"); schedule() } }
    @Published var source: WallpaperSource { didSet { store.set(source.rawValue, forKey: "dailyWallpaper.source") } }
    @Published var topic: String { didSet { store.set(topic, forKey: "dailyWallpaper.topic") } }

    private init() {
        enabled = store.bool(forKey: "dailyWallpaper.on")
        source = WallpaperSource(rawValue: store.string(forKey: "dailyWallpaper.source") ?? "") ?? .bing
        topic = store.string(forKey: "dailyWallpaper.topic") ?? ""
    }

    func start() { schedule() }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard enabled else { return }
        changeIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { DailyWallpaper.shared.changeIfDue() }
        }
    }

    func changeIfDue(force: Bool = false) {
        let today = Calendar.current.startOfDay(for: Date())
        if !force, let last = store.object(forKey: "dailyWallpaper.last") as? Date, last >= today { return }
        Task {
            guard let photos = try? await WallpaperLibrary.search(source, query: topic), !photos.isEmpty else { return }
            let pick = source == .bing ? photos[0] : photos.randomElement()!
            if (try? await WallpaperLibrary.use(pick)) != nil { store.set(today, forKey: "dailyWallpaper.last") }
        }
    }
}

// MARK: - UI

struct WallpaperLibraryCard: View {
    @State private var source = WallpaperSource.featured
    @State private var query = ""
    @State private var topic = WallpaperLibrary.featuredTopics[0].category
    @State private var photos: [WallpaperPhoto] = []
    @State private var images: [String: NSImage] = [:]
    @State private var message: String?
    @State private var loading = false
    @State private var applying: String?
    @State private var key = ""
    @State private var hasKey = WallpaperLibrary.unsplashKey != nil
    @State private var hovered: String?
    @ObservedObject private var daily = DailyWallpaper.shared
    private let hue = DS.Spectrum.surfaces
    private let columns = [GridItem(.flexible(), spacing: DS.Space.s), GridItem(.flexible(), spacing: DS.Space.s),
                           GridItem(.flexible(), spacing: DS.Space.s)]

    var body: some View {
        SectionHeader("Photographs", symbol: "photo.on.rectangle", detail: source.detail, hue: hue)
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Segments(selection: $source, options: WallpaperSource.allCases.map { ($0, $0.title) })
                controls
                if let message { Text(message).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true) }
                grid
                if let current = WallpaperLibrary.current {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "c.circle").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.tertiary)
                        Text("\(current.title) · \(current.credit)\(current.licence.map { " · " + $0 } ?? "")")
                            .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Current photo: \(current.title), \(current.credit)")
                }
            }
        }
        .onChange(of: source) { load() }
        .onAppear { if photos.isEmpty { load() } }
        RowGroup {
            SettingRow(title: "New Wallpaper Every Day",
                       detail: "From \(daily.source.title)\(daily.topic.isEmpty ? "" : ", \(daily.topic.replacingOccurrences(of: "Category:", with: "").replacingOccurrences(of: "_", with: " "))").",
                       symbol: "calendar", density: .compact) {
                LuxSwitch(isOn: $daily.enabled, label: "New Wallpaper Every Day", tint: hue)
            }
            .help("Restore Original always brings yours back.")
            if daily.enabled {
                SettingRow(title: "Use \(source.title) for Daily", symbol: "arrow.down.circle", density: .compact) {
                    HStack(spacing: DS.Space.s) {
                        Chip("Use") { daily.source = source; daily.topic = source == .featured ? "Category:\(topic)" : query }
                        Chip("Change Now") { daily.changeIfDue(force: true) }
                    }
                }
            }
        }
        .animation(DS.Motion.reveal, value: daily.enabled)
    }

    @ViewBuilder private var controls: some View {
        switch source {
        case .featured:
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(WallpaperLibrary.featuredTopics, id: \.category) { item in
                        let chosen = topic == item.category
                        Button { topic = item.category; load() } label: {
                            Text(item.title).font(.system(size: 12, weight: .medium))
                                .foregroundStyle(chosen ? DS.Ink.primary : DS.Ink.secondary)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(chosen ? hue.opacity(0.16) : DS.Ink.fill, in: .capsule)
                                .overlay { Capsule().strokeBorder(chosen ? hue.opacity(0.6) : .clear, lineWidth: 0.75) }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(Pressable(scale: 0.96))
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
            }
        case .bing:
            EmptyView()
        case .unsplash where !hasKey:
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SecureField("Unsplash Access Key", text: $key).textFieldStyle(.plain)
                        .padding(.horizontal, 12).frame(height: 32).background(DS.Ink.fill, in: .capsule)
                    Button("Save") {
                        WallpaperLibrary.setUnsplashKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        hasKey = WallpaperLibrary.unsplashKey != nil
                        key = ""
                        load()
                    }
                    .disabled(key.isEmpty)
                }
                Button("Get a free key at unsplash.com/developers…") { NSWorkspace.shared.open(URL(string: "https://unsplash.com/oauth/applications")!) }
                    .buttonStyle(.plain).font(DS.caption).foregroundStyle(hue)
            }
        default:
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(DS.Ink.secondary)
                TextField(source == .nasa ? "Earth, nebula, aurora…" : "Mountains, ocean, city at night…", text: $query)
                    .textFieldStyle(.plain).onSubmit { load() }
                if loading { ProgressView().controlSize(.small) }
                if source == .unsplash {
                    Button { WallpaperLibrary.setUnsplashKey(nil); hasKey = false; photos = [] } label: { Image(systemName: "key.slash") }
                        .buttonStyle(.plain).foregroundStyle(DS.Ink.tertiary).help("Remove the Unsplash key")
                        .accessibilityLabel("Remove the Unsplash key")
                }
            }
            .padding(.horizontal, 12).frame(height: 34).background(DS.Ink.fill, in: .capsule)
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: DS.Space.s) {
            ForEach(photos.prefix(24)) { photo in
                let shape = RoundedRectangle(cornerRadius: DS.Radius.pill, style: .continuous)
                Button { apply(photo) } label: {
                    ZStack(alignment: .bottomLeading) {
                        // A fixed box first, the picture inside it: a panorama can't widen the grid.
                        Color.clear
                            .frame(maxWidth: .infinity).frame(height: 84)
                            .overlay {
                                if let image = images[photo.id] {
                                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    DS.Ink.fill
                                }
                            }
                            .clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                        Color.white.opacity(hovered == photo.id ? 0.07 : 0)
                        // Only the name shows on the tile; the full credit is in the help tag.
                        Text(photo.credit).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.88))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true).padding(7)
                        if applying == photo.id {
                            Color.black.opacity(0.35)
                            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .clipShape(shape)
                    .overlay { shape.strokeBorder(.white.opacity(hovered == photo.id ? 0.26 : 0.08), lineWidth: 0.5) }
                    .animation(DS.Motion.hover, value: hovered)
                    .contentShape(.rect)
                }
                .buttonStyle(Pressable(scale: 0.97))
                .onHover { inside in
                    if inside, !ScrollActivity.scrolling { hovered = photo.id } else if hovered == photo.id { hovered = nil }
                }
                .help("\(photo.title)\n\(photo.credit)\(photo.licence.map { "\n" + $0 } ?? "")")
                .accessibilityLabel("\(photo.title), \(photo.credit)")
                .task(id: photo.id) {
                    if images[photo.id] == nil, let image = await WallpaperLibrary.thumbnail(photo.thumbnail) { images[photo.id] = image }
                }
            }
        }
    }

    private func load() {
        let source = source, query = source == .featured ? "Category:\(topic)" : query
        loading = true
        message = nil
        Task {
            do {
                let found = try await WallpaperLibrary.search(source, query: query)
                photos = found
                message = found.isEmpty ? WallpaperLibrary.Failure.empty.errorDescription : nil
            } catch {
                photos = []
                message = error.localizedDescription
            }
            loading = false
        }
    }

    private func apply(_ photo: WallpaperPhoto) {
        applying = photo.id
        Task {
            do {
                _ = try await WallpaperLibrary.use(photo)
                message = "Set. The photo and its credit are in Pictures › Atelier Wallpapers."
            } catch {
                message = "Couldn’t set it: \(error.localizedDescription)"
            }
            applying = nil
        }
    }
}
