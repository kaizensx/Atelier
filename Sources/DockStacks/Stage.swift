import AppKit
import DockCore
import SwiftUI

/// A place in the Studio. Its identity is a plain string, so a new area needs no case here: register
/// a `NavItem` with `Chapter("your-id")` in NavRegistry.swift and it exists. The named ones below are
/// the places other code links to (`ManagerWindow.shared.show(chapter: Chapter.dock.rawValue)`).
/// Titles, sections and symbols live in the registry, not here.
struct Chapter: RawRepresentable, Hashable, Identifiable, Sendable {
    let rawValue: String
    init?(rawValue: String) {
        guard !rawValue.isEmpty else { return nil }
        self.rawValue = rawValue
    }
    init(_ id: String) { rawValue = id }
    var id: String { rawValue }

    static let home = Chapter("home"), looks = Chapter("looks"), themes = Chapter("themes")
    static let wallpaper = Chapter("wallpaper"), livewall = Chapter("livewall"), widgets = Chapter("widgets"), effects = Chapter("effects")
    static let dock = Chapter("dock"), stacks = Chapter("stacks"), orbit = Chapter("orbit"), corners = Chapter("corners")
    static let menubar = Chapter("menubar")
    static let engine = Chapter("engine"), windows = Chapter("windows")
    static let finder = Chapter("finder"), folders = Chapter("folders")
    static let apps = Chapter("apps")
    static let appearance = Chapter("appearance"), input = Chapter("input"), sounds = Chapter("sounds"), animations = Chapter("animations")
    static let toolbox = Chapter("toolbox"), capture = Chapter("capture")
    static let scenes = Chapter("scenes"), time = Chapter("time")
    static let system = Chapter("system")
    /// Folded into other places. They still open from old links, as `routed`.
    static let owndock = Chapter("owndock"), unique = Chapter("unique"), lab = Chapter("lab"), vitals = Chapter("vitals")
    static let display = Chapter("display")

    @MainActor var title: String { NavRegistry.item(for: routed)?.title ?? rawValue.capitalized }

    /// Chapters that were folded into others still open from old links, as the chapter that holds them now.
    /// An id nobody registered opens Home.
    @MainActor var routed: Chapter { NavRegistry.resolve(self) }

    /// Where the camera lands: zoom, and the focus point in stage units (0...1).
    @MainActor var camera: (zoom: Double, focus: UnitPoint) {
        switch self {
        // A dock on a side or the top edge would sit under the sidebar or the panel at the
        // dock's usual zoom: the camera stays at rest so the whole dock shows (StageDockSide).
        case .dock where StageDockSide.shared.side, .stacks where StageDockSide.shared.side: (1.0, .center)
        // Never smaller than the viewport: the stage is what is being changed, so it stays big.
        case .home: (1.0, .center)
        case .looks: (1.04, .center)
        case .finder, .windows, .capture: (1.12, .center)
        case .dock: (1.34, UnitPoint(x: 0.5, y: 0.7))
        case .stacks: (1.34, UnitPoint(x: 0.58, y: 0.62))
        case .corners: (1.0, .center)
        // The status items live at the bar's right end: lean there, so the panel never covers them.
        case .menubar: (1.34, UnitPoint(x: 0.85, y: 0.28))
        case Chapter("controlCenter"): (1.5, UnitPoint(x: 0.95, y: 0.2))
        case .wallpaper: (1.02, .center)
        case .effects: (1.0, .center)
        case .scenes: (1.34, UnitPoint(x: 0.5, y: 0.7))
        case .time: (0.96, UnitPoint(x: 0.5, y: 0.56))
        default: (1.0, .center)
        }
    }

    var hasPanel: Bool { self != .home && self != .time }
}

enum Wallpaper {
    @MainActor private static var cached: NSImage?

    /// `desktopImageURL` reports a stale default on this macOS. The real choice is in the
    /// wallpaper store, a binary plist where the file URLs can be read straight from the bytes.
    /// The first one is the current wallpaper. Do not test it for existence: without the
    /// Downloads permission a real file looks missing, and an older wallpaper would win.
    nonisolated static func urls() -> [URL] {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        guard let data = try? Data(contentsOf: store) else { return [] }
        let text = String(decoding: data, as: UTF8.self)
        let pattern = /file:\/\/\/[A-Za-z0-9%._\-\/]+?\.(?:heic|jpg|jpeg|png|tiff|tif|webp)/.ignoresCase()
        // Atelier's own generated images are never "the user's wallpaper".
        return text.matches(of: pattern).compactMap { URL(string: String($0.output)) }
            .filter { !$0.path.contains("DockStacks/Wallpapers") }
    }

    nonisolated static func url() -> URL? { current().first }

    /// The main display's own answer first, when it names a real picture of the owner's: it
    /// follows changes at once. Only a system default there is distrusted (it can be stale),
    /// and then the store's records decide.
    /// Views read this while they render (the Studio's room, the stage), so the answer is kept
    /// for a second and a half: reading it means a plist, a regular expression and file checks.
    nonisolated(unsafe) private static var memo: (at: Date, urls: [URL])?
    private static let memoLock = NSLock()

    nonisolated static func current() -> [URL] {
        memoLock.lock()
        if let memo, Date().timeIntervalSince(memo.at) < 1.5 { memoLock.unlock(); return memo.urls }
        memoLock.unlock()
        let urls = readCurrent()
        memoLock.lock()
        memo = (Date(), urls)
        memoLock.unlock()
        return urls
    }

    nonisolated private static func readCurrent() -> [URL] {
        var list: [URL] = []
        if let screen = NSScreen.screens.first, let own = NSWorkspace.shared.desktopImageURL(for: screen),
           !own.path.hasPrefix("/System/"), FileManager.default.fileExists(atPath: own.path) {
            list.append(own)
        }
        return list + urls().filter { !list.contains($0) }
    }

    @MainActor private static var cachedStamp: Date?

    /// The wallpaper store's own modification date: a cheap stat that says when to reload.
    nonisolated private static func storeStamp() -> Date? {
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        return (try? FileManager.default.attributesOfItem(atPath: store.path))?[.modificationDate] as? Date
    }

    /// Drops the cached picture, for when Atelier has just changed the wallpaper itself.
    @MainActor static func invalidate() {
        cached = nil
        cachedStamp = nil
        memoLock.lock(); memo = nil; memoLock.unlock()
    }

    @MainActor static func image() -> NSImage? {
        let stamp = storeStamp()
        if let cached, stamp == cachedStamp { return cached }
        cachedStamp = stamp
        cached = nil
        for url in current() {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1800,
                  ] as CFDictionary) else { continue }
            let result = NSImage(cgImage: image, size: .zero)
            cached = result
            return result
        }
        return nil
    }
}

struct ReplicaTile: Identifiable {
    enum Kind { case icon(NSImage), separator, gap(Double), flex }
    let id: String
    let kind: Kind
    var running = false
    var title = ""
}

enum Replica {
    @MainActor private static var icons: [String: NSImage] = [:]

    @MainActor private static func icon(_ path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        // Reading these folders would raise a privacy prompt just to draw an icon.
        let home = NSHomeDirectory()
        let guarded = ["Downloads", "Documents", "Desktop"].contains { path.hasPrefix("\(home)/\($0)") }
        let image = guarded ? NSWorkspace.shared.icon(for: .folder) : NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }

    /// The name the real Dock shows above a tile.
    private static func label(of tile: Tile, path: String?) -> String {
        if let data = tile["tile-data"] as? [String: Any], let label = data["file-label"] as? String { return label }
        return path.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? ""
    }

    @MainActor static func tiles(from plist: DockPlist) -> [ReplicaTile] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path })
        var result = [ReplicaTile(id: "finder", kind: .icon(icon("/System/Library/CoreServices/Finder.app")), running: true, title: "Finder")]
        func add(_ tiles: [Tile], _ zone: String) {
            for (index, tile) in tiles.enumerated() {
                let id = "\(zone)\(index)"
                switch Tiles.type(of: tile) {
                case "small-spacer-tile": result.append(ReplicaTile(id: id, kind: .gap(0.4)))
                case "spacer-tile": result.append(ReplicaTile(id: id, kind: .gap(1)))
                case "flex-spacer-tile": result.append(ReplicaTile(id: id, kind: .flex))
                case "smartfolder-tile":
                    result.append(ReplicaTile(id: id, kind: .icon(NSWorkspace.shared.icon(for: .folder)), title: label(of: tile, path: nil)))
                default:
                    guard let path = Tiles.path(of: tile) else { continue }
                    result.append(ReplicaTile(id: id, kind: .icon(icon(path)), running: running.contains(path), title: label(of: tile, path: path)))
                }
            }
        }
        add(Tiles.apps(plist), "a")
        if plist["show-recents"] as? Bool ?? true, let recents = plist["recent-apps"] as? [Tile], !recents.isEmpty {
            result.append(ReplicaTile(id: "recents", kind: .separator))
            add(recents, "r")
        }
        result.append(ReplicaTile(id: "sep", kind: .separator))
        add(Tiles.others(plist), "o")
        let trash = NSImage(named: NSImage.trashFullName) ?? NSImage()
        result.append(ReplicaTile(id: "trash", kind: .icon(trash), title: "Trash"))
        return result
    }
}

/// The user's real Dock, redrawn. It magnifies and labels under the pointer like the real one.
struct ReplicaDock: View {
    let tiles: [ReplicaTile]
    let size: Double
    let magnify: Double
    let entered: Bool
    var tint: Color?
    var clear = false
    var dots = true
    var vertical = false
    var edge = "bottom"
    @State private var pointer: CGPoint?

    private func distance(from frame: CGRect) -> Double? {
        guard let pointer else { return nil }
        return Double(vertical ? abs(frame.midY - pointer.y) : abs(frame.midX - pointer.x))
    }

    private func scale(at frame: CGRect) -> Double {
        guard let distance = distance(from: frame), magnify > 1 else { return 1 }
        let reach = distance / (size * 2.4)
        return 1 + (magnify - 1) * exp(-reach * reach)
    }

    private var anchor: UnitPoint { edge == "left" ? .leading : edge == "right" ? .trailing : .bottom }

    /// Separators and running dots: white on glass and on a dark Dock, near-black on the light
    /// frosted Dock of Sonoma and Sequoia, as the real one draws them.
    private var inkOnPlatter: Color {
        MacPlatform.stageChrome.liquidGlass || Appearance.isDark ? .white : Color(white: 0.1)
    }

    /// The release's Dock: Liquid Glass from Tahoe on; before it the frosted platter of Sonoma and
    /// Sequoia, tighter in its corners, light or dark with the Mac's appearance.
    @ViewBuilder private var platter: some View {
        let chrome = MacPlatform.stageChrome
        let shape = RoundedRectangle(cornerRadius: size * chrome.dockCornerFraction, style: .continuous)
        if chrome.liquidGlass {
            shape.fill(.ultraThinMaterial)
                .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
        } else {
            let dark = Appearance.isDark
            shape.fill(.ultraThinMaterial)
                .overlay { shape.fill(dark ? Color.black.opacity(0.18) : Color.white.opacity(0.3)) }
                .overlay { shape.strokeBorder(dark ? Color.white.opacity(0.16) : Color.white.opacity(0.45), lineWidth: 0.5) }
                .environment(\.colorScheme, dark ? .dark : .light)
        }
    }

    var body: some View {
        let hasFlex = tiles.contains { if case .flex = $0.kind { return true } else { return false } }
        let layout = vertical ? AnyLayout(VStackLayout(spacing: size * 0.13))
                              : AnyLayout(HStackLayout(alignment: .bottom, spacing: size * 0.13))
        layout {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                cell(tile, index: index)
            }
        }
        .padding(.horizontal, size * (vertical ? 0.16 : 0.26))
        .padding(.vertical, size * (vertical ? 0.26 : 0.16))
        .frame(maxWidth: hasFlex && !vertical ? .infinity : nil)
        .background { platter }
        .onContinuousHover(coordinateSpace: .named("dock")) { phase in
            withAnimation(DS.Motion.touch) {
                if case .active(let location) = phase { pointer = location } else { pointer = nil }
            }
        }
    }

    @ViewBuilder private func cell(_ tile: ReplicaTile, index: Int) -> some View {
        switch tile.kind {
        case .separator:
            Rectangle().fill(inkOnPlatter.opacity(0.24))
                .frame(width: vertical ? size * 0.8 : 1, height: vertical ? 1 : size * 0.8)
                .padding(.bottom, vertical ? 0 : size * 0.1)
        case .gap(let units):
            Color.clear.frame(width: size * units, height: size)
        case .flex:
            Spacer(minLength: 0)
        case .icon(let image):
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("dock"))
                let factor = scale(at: frame)
                BitmapIcon(image: image)
                    .frame(width: size, height: size)
                    .saturation(tint != nil || clear ? 0 : 1)
                    .colorMultiply(tint ?? .white)
                    .opacity(clear ? 0.72 : 1)
                    .scaleEffect(factor, anchor: anchor)
                    .overlay(alignment: labelAlignment) {
                        if let distance = distance(from: frame), distance < size * 0.56, !tile.title.isEmpty {
                            label(tile.title, lift: size * factor)
                        }
                    }
            }
            .frame(width: size, height: size)
            .overlay(alignment: .bottom) {
                if tile.running && dots && !vertical {
                    Circle().fill(inkOnPlatter.opacity(0.8)).frame(width: 3, height: 3).offset(y: 6)
                }
            }
            .offset(y: entered ? 0 : 90)
            .opacity(entered ? 1 : 0)
            .animation(DS.Motion.arrive.delay(0.5 + Double(index) * 0.028), value: entered)
        }
    }

    private var labelAlignment: Alignment { edge == "left" ? .trailing : edge == "right" ? .leading : .top }

    /// The small name tag the real Dock floats beside the hovered tile.
    private func label(_ text: String, lift: Double) -> some View {
        Text(text)
            .font(.system(size: max(9, size * 0.24), weight: .medium))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, size * 0.2).padding(.vertical, size * 0.07)
            .atelierGlass(.regular, in: .rect(cornerRadius: MacPlatform.stageChrome.capsuleLabels ? size : size * 0.12, style: .continuous))
            .offset(x: edge == "left" ? lift + 8 : edge == "right" ? -lift - 8 : 0,
                    y: edge == "bottom" ? size - lift - size * 0.56 : 0)
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
    }
}

struct MockWindow<Content: View>: View {
    let width: Double
    var title = ""
    var shadow = true
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: width * 0.012) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: width * 0.016) }
                Text(title).font(.system(size: width * 0.022, weight: .semibold)).lineLimit(1).padding(.leading, width * 0.02)
                Spacer()
            }
            .padding(width * 0.02)
            content
        }
        .frame(width: width)
        .background {
            let shape = RoundedRectangle(cornerRadius: min(width * 0.035, 18), style: .continuous)
            shape.fill(LinearGradient(colors: [Color(white: 0.19), Color(white: 0.115)], startPoint: .top, endPoint: .bottom))
                .opacity(0.96)
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.04)],
                                                           startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
        }
        .clipShape(.rect(cornerRadius: min(width * 0.035, 18), style: .continuous))
        .shadow(color: .black.opacity(shadow ? 0.45 : 0), radius: shadow ? 24 : 0, y: shadow ? 14 : 0)
    }
}

/// What a browser shows: an address bar, a hero picture and a column of text.
struct BrowserContent: View {
    let width: Double
    var body: some View {
        let u = width
        VStack(alignment: .leading, spacing: u * 0.035) {
            HStack(spacing: u * 0.02) {
                Image(systemName: "lock.fill").font(.system(size: u * 0.028))
                Text("apple.com").font(.system(size: u * 0.034, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.65))
            .frame(maxWidth: .infinity).frame(height: u * 0.07)
            .background(.white.opacity(0.07), in: .capsule)
            RoundedRectangle(cornerRadius: u * 0.03, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.55, blue: 0.35), Color(red: 0.55, green: 0.3, blue: 0.85),
                                              Color(red: 0.15, green: 0.2, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: u * 0.015) {
                        Capsule().fill(.white.opacity(0.9)).frame(width: u * 0.4, height: u * 0.03)
                        Capsule().fill(.white.opacity(0.55)).frame(width: u * 0.26, height: u * 0.02)
                    }
                    .padding(u * 0.04)
                }
                .frame(height: u * 0.42)
            ForEach([0.92, 0.84, 0.88, 0.6], id: \.self) { w in
                Capsule().fill(.white.opacity(0.13)).frame(width: u * 0.86 * w, height: u * 0.018)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, u * 0.05).padding(.bottom, u * 0.04)
    }
}

/// What a notes app shows: a list of notes beside the open one.
struct NotesContent: View {
    let width: Double
    var body: some View {
        let u = width
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: u * 0.02) {
                ForEach(0..<5, id: \.self) { i in
                    VStack(alignment: .leading, spacing: u * 0.012) {
                        Capsule().fill(.white.opacity(i == 0 ? 0.75 : 0.35)).frame(width: u * [0.24, 0.2, 0.26, 0.18, 0.22][i], height: u * 0.02)
                        Capsule().fill(.white.opacity(0.14)).frame(width: u * 0.28, height: u * 0.014)
                    }
                    .padding(u * 0.022)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(i == 0 ? Color(red: 0.95, green: 0.75, blue: 0.2).opacity(0.28) : .clear,
                                in: .rect(cornerRadius: u * 0.02, style: .continuous))
                }
                Spacer(minLength: 0)
            }
            .padding(u * 0.025)
            .frame(width: u * 0.38)
            .background(.white.opacity(0.035))
            VStack(alignment: .leading, spacing: u * 0.03) {
                Capsule().fill(.white.opacity(0.85)).frame(width: u * 0.3, height: u * 0.034)
                ForEach([0.5, 0.46, 0.52, 0.3, 0.48, 0.42, 0.5, 0.24], id: \.self) { w in
                    Capsule().fill(.white.opacity(0.16)).frame(width: u * w, height: u * 0.016)
                }
                Spacer(minLength: 0)
            }
            .padding(u * 0.05)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A picture that reads as "a photo" at any size.
struct PhotoFill: View {
    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [Color(red: 0.2, green: 0.32, blue: 0.62), Color(red: 0.95, green: 0.6, blue: 0.42)],
                           startPoint: .top, endPoint: .bottom)
            GeometryReader { g in
                Path { p in
                    let w = g.size.width, h = g.size.height
                    p.move(to: CGPoint(x: 0, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h * 0.7))
                    p.addLine(to: CGPoint(x: w * 0.3, y: h * 0.42))
                    p.addLine(to: CGPoint(x: w * 0.52, y: h * 0.62))
                    p.addLine(to: CGPoint(x: w * 0.72, y: h * 0.48))
                    p.addLine(to: CGPoint(x: w, y: h * 0.68))
                    p.addLine(to: CGPoint(x: w, y: h))
                }
                .fill(Color(red: 0.12, green: 0.1, blue: 0.2).opacity(0.85))
            }
        }
    }
}

struct FinderMock: View {
    let width: Double
    let on: (String, String, String) -> Bool
    private func key(_ name: String, _ value: String = "true") -> Bool { on("com.apple.finder", name, value) }

    var body: some View {
        let f = width * 0.024
        let files = (key("_FXSortFoldersFirst") ? ["Projects", "Photos"] : []) + ["Notes.txt", "Budget.pdf", "Plan.key"] + (key("_FXSortFoldersFirst") ? [] : ["Projects", "Photos"])
        MockWindow(width: width, title: key("_FXShowPosixPathInTitle") ? "/Users/you/Documents" : "Documents") {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: f * 0.7) {
                    if !key("ShowRecentTags", "false") {
                        Text("Tags").foregroundStyle(.secondary)
                        Label("Red", systemImage: "circle.fill")
                    }
                    Text("Favourites").foregroundStyle(.secondary)
                    Text("Desktop"); Text("Documents"); Text("Downloads")
                }
                .font(.system(size: f * 0.9))
                .padding(f).frame(width: width * 0.24, alignment: .leading)
                VStack(alignment: .leading, spacing: f * 0.6) {
                    if key("AppleShowAllFiles") { row(".git", dim: true); row(".DS_Store", dim: true) }
                    ForEach(files, id: \.self) { row($0, folder: !$0.contains(".")) }
                }
                .padding(f).frame(maxWidth: .infinity, alignment: .leading)
                if key("ShowPreviewPane") {
                    RoundedRectangle(cornerRadius: f * 0.5).fill(.white.opacity(0.08))
                        .frame(width: width * 0.2).padding(f)
                }
            }
            .frame(height: width * 0.36, alignment: .top)
            if key("ShowPathbar") { bar("Macintosh HD › Users › you › Documents") }
            if key("ShowStatusBar") { bar("5 items, 412 GB available") }
        }
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }

    private func row(_ name: String, folder: Bool = false, dim: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: folder ? "folder.fill" : "doc").foregroundStyle(folder ? .blue : .secondary)
            Text(name)
        }
        .font(.system(size: width * 0.024)).opacity(dim ? 0.5 : 1)
    }

    private func bar(_ text: String) -> some View {
        Text(text).font(.system(size: width * 0.019)).foregroundStyle(.secondary)
            .padding(.horizontal, width * 0.024).padding(.vertical, width * 0.01)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05))
    }
}

struct TilingMock: View {
    let size: CGSize
    let margins: Bool
    let wide: Bool

    var body: some View {
        let gap = size.width * (wide ? 0.028 : margins ? 0.01 : 0.001)
        HStack(spacing: gap) {
            let half = (size.width - gap * 3) / 2
            MockWindow(width: half, title: "Safari") { BrowserContent(width: half).frame(maxHeight: .infinity) }
            MockWindow(width: half, title: "Notes") { NotesContent(width: half).frame(maxHeight: .infinity) }
        }
        .padding(gap)
        .padding(.top, size.width * 0.018)
        .padding(.bottom, size.height * 0.11)
        .animation(DS.Motion.arrive, value: gap)
    }
}

struct CaptureMock: View {
    let width: Double
    let shadow: Bool
    let thumbnail: Bool
    let stage: CGSize
    var dated = true

    private var name: String { dated ? "Screenshot 2026-11-07 at 09.41.12" : "Screenshot" }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            MockWindow(width: width * 1.6, title: "Preview", shadow: shadow) {
                PhotoFill().frame(height: width * 0.8)
                    .clipShape(.rect(cornerRadius: width * 0.02, style: .continuous))
                    .padding([.horizontal, .bottom], width * 0.03)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 3) {
                Image(systemName: "photo").font(.system(size: width * 0.09)).foregroundStyle(.white.opacity(0.9))
                Text(name + ".png").font(.system(size: width * 0.034, weight: .medium)).lineLimit(2)
                    .multilineTextAlignment(.center).frame(width: width * 0.42)
                    .contentTransition(.opacity)
            }
            .shadow(color: .black.opacity(0.6), radius: 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(stage.width * 0.02).padding(.top, stage.height * 0.05)
            if thumbnail {
                PhotoFill()
                    .frame(width: width * 0.5, height: width * 0.32)
                    .clipShape(.rect(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .shadow(color: .black.opacity(0.4), radius: 10)
                    .padding(stage.width * 0.02)
                    .padding(.bottom, stage.height * 0.12)
            }
        }
    }
}

/// A stand-in document window for the settings that only show inside apps.
struct ShowcaseMock: View {
    let width: Double
    let tabs: Bool
    let bars: Bool
    let tinted: Bool

    var body: some View {
        MockWindow(width: width, title: tabs ? "" : "Report") {
            VStack(spacing: 0) {
                if tabs {
                    HStack(spacing: 2) {
                        tab("Report", front: true); tab("Notes", front: false); tab("Budget", front: false)
                    }
                    .padding(.horizontal, width * 0.012).padding(.bottom, width * 0.008)
                    .transition(.offset(y: -8).combined(with: .opacity))
                }
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: width * 0.016) {
                        ForEach(0..<7, id: \.self) { line in
                            Capsule().fill(.white.opacity(line == 0 ? 0.3 : 0.12))
                                .frame(width: width * (line == 0 ? 0.4 : [0.78, 0.7, 0.82, 0.62, 0.74, 0.5][line - 1]), height: width * 0.012)
                        }
                    }
                    .padding(width * 0.03)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    if bars {
                        ZStack(alignment: .top) {
                            Rectangle().fill(.white.opacity(0.05))
                            Capsule().fill(.white.opacity(0.42)).frame(width: width * 0.012, height: width * 0.14).padding(.top, width * 0.02)
                        }
                        .frame(width: width * 0.024)
                        .transition(.opacity)
                    }
                }
                .frame(height: width * 0.34)
            }
        }
        .background {
            // Wallpaper colour seeping through the window, as it does by default.
            if tinted {
                RoundedRectangle(cornerRadius: width * 0.03, style: .continuous)
                    .fill(LinearGradient(colors: [.blue.opacity(0.3), .purple.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .blur(radius: width * 0.03)
            }
        }
    }

    private func tab(_ title: String, front: Bool) -> some View {
        Text(title).font(.system(size: width * 0.02, weight: .medium))
            .foregroundStyle(front ? DS.Ink.primary : DS.Ink.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, width * 0.008)
            .background(.white.opacity(front ? 0.13 : 0.04), in: .rect(cornerRadius: width * 0.012, style: .continuous))
    }
}

/// The system's Save sheet, in its compact or expanded form.
struct SavePanelMock: View {
    let width: Double
    let expanded: Bool
    let cloud: Bool

    var body: some View {
        let f = width * 0.034
        VStack(alignment: .leading, spacing: f * 0.7) {
            field("Save As:", "Untitled")
            field("Where:", cloud ? "iCloud Drive" : "On My Mac", symbol: cloud ? "icloud" : "laptopcomputer")
            if expanded {
                HStack(alignment: .top, spacing: f * 0.5) {
                    column(["Desktop", "Documents", "Downloads"], selected: 1)
                    column(["Projects", "Photos", "Notes.txt"], selected: 0)
                }
                .frame(height: width * 0.32)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
            HStack(spacing: f * 0.5) {
                Spacer()
                button("Cancel", accent: false)
                button("Save", accent: true)
            }
        }
        .font(.system(size: f))
        .padding(f)
        .frame(width: width)
        .background(Color(white: 0.17), in: .rect(cornerRadius: width * 0.03, style: .continuous))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    private func field(_ label: String, _ value: String, symbol: String? = nil) -> some View {
        HStack(spacing: width * 0.02) {
            Text(label).foregroundStyle(DS.Ink.secondary).frame(width: width * 0.2, alignment: .trailing)
            HStack(spacing: width * 0.012) {
                if let symbol { Image(systemName: symbol).foregroundStyle(DS.Ink.accent) }
                Text(value)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, width * 0.014).padding(.vertical, width * 0.008)
            .background(.white.opacity(0.08), in: .rect(cornerRadius: width * 0.012, style: .continuous))
        }
    }

    private func column(_ names: [String], selected: Int) -> some View {
        VStack(alignment: .leading, spacing: width * 0.008) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                HStack(spacing: width * 0.01) {
                    Image(systemName: name.contains(".") ? "doc" : "folder.fill").foregroundStyle(name.contains(".") ? .secondary : Color.blue)
                    Text(name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, width * 0.01).padding(.vertical, width * 0.004)
                .background(index == selected ? DS.Ink.accent.opacity(0.35) : .clear, in: .rect(cornerRadius: width * 0.008))
            }
            Spacer(minLength: 0)
        }
        .padding(width * 0.012)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: width * 0.012, style: .continuous))
    }

    private func button(_ title: String, accent: Bool) -> some View {
        Text(title).padding(.horizontal, width * 0.03).padding(.vertical, width * 0.008)
            .background(accent ? DS.Ink.accent.opacity(0.85) : .white.opacity(0.12), in: .capsule)
            .foregroundStyle(accent ? Color.black : DS.Ink.primary)
    }
}

/// Sample icons on the replica's desktop, for the settings that are about them.
struct DesktopIconsMock: View {
    let size: CGSize
    let foldersFirst: Bool

    private var names: [String] {
        foldersFirst ? ["Archive", "Clients", "Invoice.pdf", "Photo.heic"] : ["Invoice.pdf", "Clients", "Photo.heic", "Archive"]
    }

    var body: some View {
        let unit = size.width * 0.05
        VStack(spacing: unit * 0.26) {
            ForEach(names, id: \.self) { name in
                VStack(spacing: 2) {
                    Image(systemName: name.contains(".") ? "doc.fill" : "folder.fill")
                        .font(.system(size: unit * 0.56))
                        .foregroundStyle(name.contains(".") ? Color.white.opacity(0.9) : .blue)
                    Text(name).font(.system(size: unit * 0.2, weight: .medium)).lineLimit(1)
                }
                .frame(width: unit)
                .shadow(color: .black.opacity(0.55), radius: 2)
            }
        }
        .animation(DS.Motion.arrive, value: foldersFirst)
        .padding(.top, size.height * 0.07).padding(.trailing, size.width * 0.018)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

struct HotspotButton: View {
    let label: String
    /// The name tag goes under it, for a hotspot at the top of the stage.
    var below = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(hovering ? 0.07 : 0))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(hovering ? 0.5 : 0), lineWidth: 1)
                }
                .overlay(alignment: below ? .bottom : .top) {
                    if hovering {
                        Text(label)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .fixedSize()
                            .atelierGlass(.regular, in: .capsule)
                            .offset(y: below ? 38 : -38)
                            .transition(.scale(scale: 0.9, anchor: below ? .top : .bottom).combined(with: .opacity))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.99))
        .onHover { over in withAnimation(DS.Motion.touch) { hovering = over } }
        .accessibilityLabel(label)
    }
}

/// A miniature of the user's actual screen. It is the app's navigation.
///
/// With Live Mirror on, it is the real screen, so whatever was applied simply shows. The
/// redrawn replica then only appears for things that are not true yet: a hovered tweak, a
/// Look being tried, an old Dock on the timeline.
struct MacStage: View {
    @ObservedObject private var themePreview = ThemePreview.shared
    @ObservedObject var model: ManagerModel
    @ObservedObject private var effects = Effects.shared
    @ObservedObject private var display = Display.shared
    @ObservedObject private var changes = StageChanges.shared
    @ObservedObject private var living = LiveWallpaper.shared
    @ObservedObject private var board = WidgetBoard.shared
    @ObservedObject private var ownDock = OwnDock.shared
    @ObservedObject private var still = StillBackground.shared
    @ObservedObject private var preview = StagePreview.shared
    let size: CGSize
    let entered: Bool
    @State private var dockPeek = false
    /// The widget being dragged on the stage: its handle draws it, so the board's copy steps aside.
    @State private var liftedWidget: String?
    @State private var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The stage takes the shape of the real screen.
    private var canvas: CGSize { Self.canvas(in: size) }
    static func canvas(in size: CGSize) -> CGSize {
        let aspect = screenAspect
        if aspect >= size.width / size.height { return CGSize(width: size.width, height: size.width / aspect) }
        return CGSize(width: size.height * aspect, height: size.height)
    }
    static var screenAspect: Double {
        guard let frame = NSScreen.screens.first?.frame, frame.height > 0 else { return 1.6 }
        return frame.width / frame.height
    }

    /// The menu bar's height as a fraction of the screen's width, measured on the display that
    /// holds it: 24 points on most displays, the notch's height (32 to 38) on a notched MacBook,
    /// whatever the visible frame says when it says anything. Fractions keep the stage resolution-free.
    static var menuBarFraction: Double {
        guard let screen = NSScreen.screens.first, screen.frame.width > 0 else { return 24 / 1440 }
        let height = ShellMenuBar.height(frameMaxY: screen.frame.maxY, visibleMaxY: screen.visibleFrame.maxY,
                                         notchInset: screen.safeAreaInsets.top)
        return height / screen.frame.width
    }

    /// The camera housing, as fractions of the screen's width, only when the stage's screen has one:
    /// a MacBook with a notch driving an external display as main shows no notch on the stage.
    static var notch: (width: Double, height: Double)? {
        guard let screen = NSScreen.screens.first, screen.safeAreaInsets.top > 0, screen.frame.width > 0,
              let width = ShellMenuBar.notchWidth(screenWidth: screen.frame.width,
                                                  leftArea: screen.auxiliaryTopLeftArea.map { Double($0.width) },
                                                  rightArea: screen.auxiliaryTopRightArea.map { Double($0.width) }) else { return nil }
        return (width / screen.frame.width, screen.safeAreaInsets.top / screen.frame.width)
    }

    /// Light or Dark as the Mac is set, not as the Studio (always dark) draws itself.
    private var systemDark: Bool { Appearance.isDark }
    private var chrome: ShellStageChrome { MacPlatform.stageChrome }
    private var barHeight: Double { canvas.width * Self.menuBarFraction }

    /// While the owner compares, the stage draws the moment before the last change. While a control
    /// is hovered, it draws the Mac with that control's change made (`StagePreview`).
    private var past: StageSnapshot? { changes.showingBefore ? changes.before : preview.active?.snapshot }
    /// The camera as it is now: the chapter's, leaning toward a hovered control's region.
    private var camera: (zoom: Double, focus: UnitPoint) { stageCamera(model.chapter, preview: preview.active?.region) }
    /// The stage edits the real Mac only while it shows the real Mac.
    private var interactive: Bool { past == nil && model.preview == nil && model.previewLook == nil }
    private var dockBox: DockPlistBox { past.map { DockPlistBox($0.dock) } ?? model.dock }
    private var plist: DockPlist { past?.dock ?? (model.preview ?? model.dock).plist }

    /// A stored preference, or the one kept from before when comparing.
    private func pref(_ key: String, _ domain: String) -> String? {
        if let past, Self.tracked.contains(domain + "." + key) { return past.pref(key, domain: domain) }
        return Prefs.current(key, domain: domain)
    }
    private static let tracked = Set(TweakCatalog.all.map(\.id) + StageSnapshot.iconKeys.map { "NSGlobalDomain." + $0 })

    /// What the stage shows: the live state, overridden by whatever is being previewed.
    private var look: Look? { model.previewLook }
    private var shownSkin: SkinPreset { look?.skin ?? past?.skin ?? effects.skin }
    private var shownHue: Hue? { look != nil ? look?.hue : past.map(\.hue) ?? effects.living }
    private var shownClock: Bool { look.map { $0.clock != nil } ?? past?.clock ?? effects.clock }
    private var shownStyle: ClockStyle { look?.clock ?? past?.clockStyle ?? effects.clockStyle }
    private var shownGlow: Bool { look?.glow ?? past?.glow ?? effects.dockGlow }
    private var shownVitals: Bool { past?.vitals ?? effects.widgets }
    private var shownFocus: Bool { past?.focus ?? effects.focus }
    private var shownDayLine: Bool { past?.dayLine ?? effects.dayLine }
    private var shownRounded: Double { past?.rounded ?? effects.rounded }
    private var shownNight: Bool { past?.nightShift ?? display.nightShift }
    private var shownWarmth: Double { past?.warmth ?? display.warmth }
    private var shownTrueTone: Bool { past?.trueTone ?? display.trueTone }
    private var shownLiving: LivingShader? {
        if model.previewLook != nil, let shader = themePreview.shader { return shader }
        let on = past?.livingOn ?? living.enabled
        return on ? (past?.shader ?? living.shader) : nil
    }
    private var shownBoard: [WidgetKind] {
        guard past?.boardOn ?? board.enabled else { return [] }
        return (past?.placements ?? board.placements).map(\.kind)
    }
    private var shownOwnDock: OwnDockEdge? {
        guard past?.ownDockOn ?? ownDock.enabled else { return nil }
        return past?.ownDockEdge ?? ownDock.edge
    }
    private var tint: Color? {
        if let look { return look.tintColor }
        if let color = model.previewTint { return color }
        guard pref("AppleIconAppearanceTheme", "NSGlobalDomain")?.hasPrefix("Tinted") == true else { return nil }
        return IconTint.color(tint: pref("AppleIconAppearanceTintColor", "NSGlobalDomain"),
                              rgb: pref("AppleIconAppearanceCustomTintColor", "NSGlobalDomain"))
    }
    private var clearIcons: Bool {
        if let look { return look.clear }
        if model.previewClear { return true }
        return pref("AppleIconAppearanceTheme", "NSGlobalDomain")?.hasPrefix("Clear") == true
    }

    /// A tweak counts as on when it is applied, or when the pointer is resting on it.
    private func on(_ domain: String, _ key: String, _ value: String = "true") -> Bool {
        if model.hoverTweak?.domain == domain, model.hoverTweak?.key == key { return true }
        return pref(key, domain).map { Prefs.same($0, value) } ?? false
    }
    /// A numeric setting, seen through the same hover rule as `on`.
    private func number(_ domain: String, _ key: String, default fallback: Double) -> Double {
        if model.hoverTweak?.domain == domain, model.hoverTweak?.key == key { return Double(model.hoverTweak?.value ?? "") ?? fallback }
        return Double(pref(key, domain) ?? "") ?? fallback
    }
    private var tileSize: Double { (model.previewSize ?? dockBox.double("tilesize", 64)) * canvas.width / 1728 * 1.15 }

    /// How the hovered tweak reaches the stage, whatever chapter it was found in.
    private var hover: TweakStage.Surface? { model.hoverTweak.map(TweakStage.surface) }

    /// A before-and-after card is on the stage.
    private var demoShowing: Bool {
        if case .demo? = hover, model.hoverTweak != nil { return true }
        return hover == nil && preview.active?.demo != nil
    }

    private var previewing: Bool {
        model.preview != nil || model.previewLook != nil || model.previewTint != nil || model.previewClear || hover != nil
            || preview.active != nil
    }

    var body: some View {
        ZStack {
            replica
            chapterEcho
            // A before-and-after plays over a dimmed screen, so the widgets and rings under it
            // do not show through the card.
            if demoShowing {
                Color.black.opacity(0.5)
                    .frame(width: canvas.width, height: canvas.height)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if case .demo(let spec)? = hover, let tweak = model.hoverTweak {
                DemoCard(tweak: tweak, spec: spec, applied: Prefs.matches(tweak.key, value: tweak.value, domain: tweak.domain))
                    .id(tweak.id)
                    .scaleEffect(min(1.45 / camera.zoom, canvas.width * 0.8 / DemoCard.width))
                    .position(spot(0, 0.01))
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            // An effect over the whole screen, drawn on the stage while its setting is hovered.
            if let overlay = preview.active?.overlay {
                overlay(canvas)
                    .frame(width: canvas.width, height: canvas.height)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            // Any setting's own before-and-after, for what the replica cannot draw by itself.
            if hover == nil, let active = preview.active, let demo = active.demo {
                DemoCard(title: active.title ?? "", spec: demo, applied: active.applied)
                    .id(active.id)
                    .scaleEffect(min(1.45 / camera.zoom, canvas.width * 0.8 / DemoCard.width))
                    .position(spot(0, 0.01))
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
            if model.chapter == .stacks { bubble }
            if model.chapter == .home { hotspots }
            handles
            if !previewing, !changes.facts.isEmpty {
                ChangeSpotlight(changes: changes, canvas: canvas, zoom: max(camera.zoom, 1))
            }
            if let active = preview.active {
                PreviewHalo(active: active, canvas: canvas, zoom: max(camera.zoom, 1)).id(active.id)
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: canvas.width * 0.014, style: .continuous)
                    .strokeBorder(DS.Ink.accent.opacity(0.9), lineWidth: 2)
                    .background(DS.Ink.accent.opacity(0.06))
                    .overlay(alignment: .top) {
                        StageNote(symbol: "plus.square.on.square", text: "Drop to add it here").padding(.top, canvas.height * 0.08)
                    }
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
        .dropDestination(for: String.self) { items, location in
            drop(items, at: location)
        } isTargeted: { over in
            withAnimation(DS.Motion.touch) { dropTargeted = over && interactive }
        }
        .clipShape(.rect(cornerRadius: canvas.width * 0.014, style: .continuous))
        // The bezel: a hairline of light around the glass.
        .overlay {
            RoundedRectangle(cornerRadius: canvas.width * 0.014, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
        }
        // The plinth: a floor of shade the screen stands on, and a faint line of light where it
        // meets the floor. Gradients only, never `.shadow`: the stage scales during every camera
        // move, and a shadow would be blurred again on each of those frames.
        .background(alignment: .bottom) { StagePlinth(canvas: canvas) }
        .coordinateSpace(name: "dock")
        .onContinuousHover(coordinateSpace: .named("dock")) { phase in trackDock(phase) }
        .frame(width: size.width, height: size.height)
        .animation(.smooth(duration: 0.55), value: changes.showingBefore)
        .onAppear { changes.attach(dock: { [model] in model.dock.plist }, model: model) }
    }

    /// A point in the part of the stage the camera is showing: `dx` and `dy` run from the
    /// middle of that view, in stage fractions before zoom.
    private func spot(_ dx: Double, _ dy: Double) -> CGPoint {
        let camera = self.camera
        let zoom = max(camera.zoom, 1)
        return CGPoint(x: canvas.width * min(max(camera.focus.x + dx / zoom, 0.14), 0.86),
                       y: canvas.height * min(max(camera.focus.y + dy / zoom, 0.1), 0.86))
    }

    /// Everything the stage redraws for itself when it cannot look at the real screen.
    @ViewBuilder private var replica: some View {
        ZStack {
            wallpaper
            if showsDesktopIcons { DesktopIconsMock(size: canvas, foldersFirst: on("com.apple.finder", "_FXSortFoldersFirstOnDesktop")).allowsHitTesting(false) }
            if shownClock {
                DesktopClock(style: shownStyle).scaleEffect(canvas.width / 1728, anchor: .bottomLeading)
                    .frame(width: canvas.width, height: canvas.height)
                    .offset(y: -canvas.height * 0.1)
                    .allowsHitTesting(false)
            }
            if !shownBoard.isEmpty { widgetsLayer }
            if shownVitals { vitals }
            if shownFocus {
                Color.black.opacity(effects.focusDim).allowsHitTesting(false).transition(.opacity)
            }
            // A preview drawn over the whole stage brings its own windows; the chapter's
            // miniature steps aside so the two do not overlap.
            chapterProps
                .opacity(preview.active?.overlay == nil ? 1 : 0)
                .animation(DS.Motion.settle, value: preview.active?.overlay == nil)
            if shownNight {
                Color.orange.opacity(0.1 + shownWarmth * 0.26).blendMode(.multiply).allowsHitTesting(false)
            }
            if shownTrueTone {
                Color(red: 1, green: 0.93, blue: 0.82).opacity(0.5).blendMode(.multiply).allowsHitTesting(false)
            }
            DesktopPlusReplica(size: canvas)
            menuBar
            if shownDayLine { dayLine }
            if let end = effects.focusEnd { island(end) }
            if shownGlow { dockGlow }
            if !(past?.systemReplaced ?? ownDock.systemReplaced) { dock }
            if let edge = shownOwnDock { ownDockLayer(edge) }
            if shownRounded > 0 { roundedCorners }
        }
    }

    @ViewBuilder private var wallpaper: some View {
        if let shader = shownLiving {
            LivingPreview(shader: shader)
                .frame(width: canvas.width, height: canvas.height)
                .allowsHitTesting(false)
        } else if past?.stillOn ?? still.enabled, let image = still.image {
            Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                .frame(width: canvas.width, height: canvas.height)
        } else if let hue = shownHue {
            MeshCanvas(hue: hue, hour: Calendar.current.component(.hour, from: Date()))
                .frame(width: canvas.width, height: canvas.height)
        } else if let image = Wallpaper.image() {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: canvas.width, height: canvas.height)
                .scaleEffect(entered || reduceMotion ? 1 : 1.04)
                .animation(DS.Motion.arrive, value: entered)
        } else {
            LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom)
        }
    }

    private var menuClockTicks: Bool {
        on("com.apple.menuextra.clock", "ShowSeconds") || on("com.apple.menuextra.clock", "FlashDateSeparators")
    }

    private var menuBar: some View {
        let ticks = menuClockTicks
        let bar = barHeight
        let light = MenuBarSkin.shared.textIsLight
        return VStack {
            TimelineView(.periodic(from: .now, by: ticks ? 0.5 : 20)) { context in
                menuRow(context.date)
            }
            // Larger than life for legibility, but never taller than the bar can hold: a 24 point
            // bar on an external display is two thirds of a notched MacBook's.
            .font(.system(size: min(canvas.width * 0.0095, bar * 0.62)))
            .foregroundStyle(light ? Color.white.opacity(0.9) : Color.black.opacity(0.85))
            .padding(.horizontal, canvas.width * 0.012)
            .frame(height: bar)
            .background(alignment: .topLeading) {
                // One view for every skin, never ticking by itself: changes cross-fade instead of swapping view types.
                SkinArt(preset: shownSkin, size: CGSize(width: canvas.width, height: bar), still: true)
                    .background { if shownSkin == .none { menuBand(light: light) } }
                    .animation(.easeInOut(duration: 0.35), value: shownSkin)
            }
            .overlay(alignment: .top) { if let notch = Self.notch { notchShape(notch) } }
            .offset(y: entered ? 0 : -40)
            .animation(DS.Motion.arrive.delay(0.4), value: entered)
            Spacer()
        }
    }

    /// The stock menu bar's own backdrop. Sonoma and Sequoia frost it, light or dark to suit the
    /// text over it (the bar follows the wallpaper under it, so it can be dark in Light mode);
    /// Tahoe and later leave it clear over the wallpaper, with only a breath of shade for the text.
    @ViewBuilder private func menuBand(light: Bool) -> some View {
        if chrome.menuBarBand {
            Rectangle().fill(.ultraThinMaterial)
                .overlay(light ? Color.black.opacity(0.22) : Color.white.opacity(0.42))
                .environment(\.colorScheme, light ? .dark : .light)
        } else {
            Color.black.opacity(0.14)
        }
    }

    /// The camera housing, black like the real one, with the softly rounded lower corners it has.
    private func notchShape(_ notch: (width: Double, height: Double)) -> some View {
        let width = canvas.width * notch.width, height = canvas.width * notch.height
        return UnevenRoundedRectangle(bottomLeadingRadius: height * 0.32, bottomTrailingRadius: height * 0.32, style: .continuous)
            .fill(Color.black)
            .frame(width: width, height: height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func menuRow(_ now: Date) -> some View {
        let unit = canvas.width / 1728 * 1.27
        let gap = number("NSGlobalDomain", "NSStatusItemSpacing", default: 16) * unit
        let pad = number("NSGlobalDomain", "NSStatusItemSelectionPadding", default: 10) * unit
        let highlight = model.hoverTweak?.key == "NSStatusItemSelectionPadding"
        return HStack(spacing: 14) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.semibold)
            Text("File"); Text("Edit"); Text("View"); Text("Go"); Text("Window"); Text("Help")
            Spacer()
            LiveStatusItems(gap: gap, pad: pad, highlight: highlight)
                .animation(DS.Motion.arrive, value: gap)
            menuClock(now)
        }
    }

    @ViewBuilder private func menuClock(_ now: Date) -> some View {
        if on("com.apple.menuextra.clock", "IsAnalog") {
            AnalogFace(date: now).frame(width: canvas.width * 0.0105, height: canvas.width * 0.0105)
        } else {
            let seconds = on("com.apple.menuextra.clock", "ShowSeconds")
            let flash = on("com.apple.menuextra.clock", "FlashDateSeparators")
            let text = LiveStatusItems.clockText(now, seconds: seconds)
            let dark = flash && Int(now.timeIntervalSinceReferenceDate * 2) % 2 == 1
            Text(dark ? text.replacingOccurrences(of: ":", with: " ") : text).monospacedDigit()
        }
    }

    private var dockGlow: some View {
        VStack {
            Spacer()
            DockGlowView(colors: shownSkin == .none || shownSkin == .notchless ? SkinPreset.aurora.colors : shownSkin.colors)
                .frame(width: canvas.width * 0.72, height: canvas.height * 0.26)
                .offset(y: canvas.height * 0.06)
        }
        .allowsHitTesting(false)
    }

    private var vitals: some View {
        let scale = canvas.width / 1728
        return DesktopVitals()
            .frame(width: canvas.width / scale, height: canvas.height / scale)
            .scaleEffect(scale)
            .frame(width: canvas.width, height: canvas.height)
            .allowsHitTesting(false)
    }

    private var dayLine: some View {
        VStack(spacing: 0) {
            DayLine().frame(height: max(canvas.width * 0.0014, 1.5)).padding(.top, barHeight)
            Spacer()
        }
        .allowsHitTesting(false)
    }

    private func island(_ end: Date) -> some View {
        let scale = canvas.width / 1728 * 1.3
        return FocusIslandView(end: end, total: effects.focusTotal)
            .frame(width: 104, height: 24)
            .scaleEffect(scale)
            .frame(width: 104 * scale, height: barHeight)
            .offset(x: canvas.width * 0.11)
            .frame(maxHeight: .infinity, alignment: .top)
            .allowsHitTesting(false)
    }

    /// Effects.rounded paints black corners over the screen. This paints them over the replica.
    private var roundedCorners: some View {
        let radius = shownRounded * canvas.width / 1728 * 2
        return Canvas { context, bounds in
            var path = Path(CGRect(origin: .zero, size: bounds))
            path.addRoundedRect(in: CGRect(origin: .zero, size: bounds), cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            context.fill(path, with: .color(.black), style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
    }

    private var showsDesktopIcons: Bool {
        guard !on("com.apple.WindowManager", "StandardHideDesktopIcons") else { return false }
        return model.chapter == .finder || model.chapter == .windows || model.hoverTweak?.key == "_FXSortFoldersFirstOnDesktop"
    }

    /// The chapter whose window is on the stage. A hovered tweak brings its own, so a tweak shown
    /// outside its home chapter (the Dock's hidden keys) shows the same mock its home does.
    private var propChapter: Chapter {
        switch hover {
        case .finder: .finder
        case .tiling: .windows
        case .capture: .capture
        case .demo: model.chapter
        default: model.chapter
        }
    }

    /// Faithful miniatures for the areas that live in windows.
    @ViewBuilder private var chapterProps: some View {
        switch propChapter {
        case .finder: FinderMock(width: canvas.width * 0.56, on: on)
        case .windows: TilingMock(size: canvas, margins: on("com.apple.WindowManager", "EnableTiledWindowMargins"),
                                  wide: on("com.apple.WindowManager", "TiledWindowSpacing", "24"))
        case .capture: CaptureMock(width: canvas.width * 0.3, shadow: !on("com.apple.screencapture", "disable-shadow"),
                                   thumbnail: !on("com.apple.screencapture", "show-thumbnail", "false"), stage: canvas,
                                   dated: !on("com.apple.screencapture", "include-date", "false"))
        case .appearance: ShowcaseMock(width: canvas.width * 0.5, tabs: on("NSGlobalDomain", "AppleWindowTabbingMode", "always"),
                                       bars: on("NSGlobalDomain", "AppleShowScrollBars", "Always"),
                                       tinted: !on("NSGlobalDomain", "AppleReduceDesktopTinting"))
        case .input: SavePanelMock(width: canvas.width * 0.4, expanded: on("NSGlobalDomain", "NSNavPanelExpandedStateForSaveMode"),
                                   cloud: !on("NSGlobalDomain", "NSDocumentSaveNewDocumentsToCloud", "false"))
        default: EmptyView()
        }
    }

    /// Effects that fire on an event, replayed on the replica so they can be seen at all.
    @ViewBuilder private var chapterEcho: some View {
        switch model.chapter {
        case .effects:
            // App Pulse and Click Ripples moved here from Unique, with the Notch Shelf.
            EventEcho(size: canvas, pulse: effects.pulse, ripples: effects.ripples)
            if effects.shelf { ShelfEcho(size: canvas) }
        case .corners:
            CornersReplica(model: model, size: canvas)
        default:
            EmptyView()
        }
    }

    private var edge: String {
        dockBox.string("orientation", "bottom")
    }

    private var hiddenDock: Bool { dockBox.bool("autohide") && !dockPeek }

    /// With auto-hide on, the replica's Dock waits off-screen for the pointer, like the real one.
    private func trackDock(_ phase: HoverPhase) {
        // The stage's Atelier Dock feels the pointer like the real one: the lens opens under it.
        if shownOwnDock != nil {
            let area = ownDockArea
            // Only near the bar, the way the real dock opens only under the pointer.
            let reach = ownDock.tile * screenScale * 1.9
            let edgeNow = shownOwnDock ?? .bottom
            let nearBar: (CGPoint) -> Bool = { p in
                switch edgeNow {
                case .bottom: p.y > area.maxY - reach
                case .top: p.y < area.minY + reach
                case .left: p.x < area.minX + reach
                case .right: p.x > area.maxX - reach
                }
            }
            if case .active(let point) = phase, area.contains(point), nearBar(point) {
                StageDockPointer.shared.point = CGPoint(x: point.x - area.minX, y: point.y - area.minY)
            } else if StageDockPointer.shared.point != nil {
                StageDockPointer.shared.point = nil
            }
        }
        guard dockBox.bool("autohide") else { return }
        var near = false
        if case .active(let point) = phase {
            let reach = dockPeek ? tileSize * 1.6 : tileSize * 0.5
            near = switch edge {
            case "left": point.x < reach
            case "right": point.x > canvas.width - reach
            default: point.y > canvas.height - reach
            }
        }
        if near != dockPeek { withAnimation(DS.Motion.arrive) { dockPeek = near } }
    }

    private var dock: some View {
        let away = hiddenDock ? tileSize * 1.7 : 0
        // Click the macOS Dock to open its chapter, or carry it to another edge: the real one moves.
        return StageDockMover(canvas: canvas, alignment: edge == "left" ? .leading : edge == "right" ? .trailing : .bottom,
                              edges: ["left", "bottom", "right"], enabled: interactive,
                              tap: { if model.chapter != .dock { model.go(.dock) } },
                              move: { value in
                                  guard value != edge else { return }
                                  LiveDock.setOrientation(value)
                                  model.refreshDock(after: 0.6)
                              }) {
            ReplicaDock(tiles: Replica.tiles(from: plist), size: tileSize,
                        magnify: dockBox.bool("magnification") ? dockBox.double("largesize", 76) / max(dockBox.double("tilesize", 64), 1) : 1,
                        entered: entered, tint: tint, clear: clearIcons,
                        dots: !on("com.apple.dock", "show-process-indicators", "false"),
                        vertical: edge != "bottom", edge: edge)
                .padding(canvas.width * 0.006)
                .offset(x: edge == "left" ? -away : edge == "right" ? away : 0, y: edge == "bottom" ? away : 0)
                .animation(DS.Motion.arrive, value: model.preview?.fullWidth ?? dockBox.fullWidth)
                .animation(DS.Motion.arrive, value: hiddenDock)
                .animation(DS.Motion.camera, value: edge)
        }
    }

    // MARK: Editing on the stage

    /// Handles over what can be picked up. Only while the stage shows the Mac as it really is.
    @ViewBuilder private var handles: some View {
        if interactive {
            ZStack(alignment: .topLeading) {
                if let edge = shownOwnDock {
                    StageOwnDockHandles(dock: ownDock, edge: edge, area: ownDockArea, scale: screenScale, canvas: canvas) { id in
                        StageFocus.shared.dockTile = id
                        if model.chapter != .dock { model.go(.dock) }
                    }
                }
                if shownClock {
                    HotspotButton(label: "Desktop Clock") { model.go(.widgets) }
                        .frame(width: canvas.width * StageRegion.clock.width, height: canvas.height * StageRegion.clock.height)
                        .offset(x: canvas.width * StageRegion.clock.minX, y: canvas.height * StageRegion.clock.minY)
                }
                if !shownBoard.isEmpty {
                    let shown = Set(shownBoard)
                    StageWidgetHandles(places: stagePlacements.filter { shown.contains($0.kind) }, area: visibleArea,
                                       scale: screenScale, lifted: $liftedWidget) { place in
                        board.selection = place.uid
                        if model.chapter != .widgets { model.go(.widgets) }
                    }
                }
                if model.chapter != .menubar {
                    HotspotButton(label: "Menu Bar", below: true) { model.go(.menubar) }
                        .frame(width: canvas.width, height: max(barHeight, 12))
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .transition(.opacity)
        }
    }

    /// A widget dropped from the gallery lands where it was dropped, on the real desktop.
    private func drop(_ items: [String], at location: CGPoint) -> Bool {
        guard interactive, let kind = items.lazy.compactMap(StageDrop.widgetKind).first,
              let screen = NSScreen.screens.first else { return false }
        let k = screenScale, area = visibleArea
        let point = CGPoint(x: (location.x - area.minX) / k, y: (location.y - area.minY) / k)
        if !board.enabled { board.enabled = true }
        withAnimation(DS.Motion.arrive) {
            guard let id = board.add(kind), let placed = board.placement(id) else { return }
            let span = placed.span
            let column = Int(((point.x - WidgetBoard.inset) / WidgetBoard.pitch - Double(span.columns) / 2).rounded())
            let row = Int(((point.y - WidgetBoard.inset) / WidgetBoard.pitch - Double(span.rows) / 2).rounded())
            let slot = board.slot(span: span, excluding: id, column: column, row: row, screen: placed.screen,
                                  fallback: true, size: screen.visibleFrame.size)
            board.update(id) {
                $0.column = slot.column
                $0.row = slot.row
            }
        }
        if model.chapter != .widgets { model.go(.widgets) }
        return true
    }

    /// A miniature bubble, so editing a stack shows what it opens into.
    private var bubble: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 4) {
                    Text(model.draft.title).font(.system(size: canvas.width * 0.011, weight: .semibold))
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(canvas.width * 0.034), spacing: 3), count: 4), spacing: 3) {
                        ForEach(model.draft.items.prefix(8)) { item in
                            Image(nsImage: ItemIcon.image(for: item)).resizable().frame(width: canvas.width * 0.03, height: canvas.width * 0.03)
                        }
                    }
                }
                .padding(canvas.width * 0.012)
                .frame(width: canvas.width * 0.17)
                .atelierGlass(.regular, in: .rect(cornerRadius: canvas.width * 0.02))
                .padding(.trailing, canvas.width * 0.09)
                .padding(.bottom, canvas.height * 0.15)
                .transition(.scale(scale: 0.3, anchor: .bottom).combined(with: .opacity))
            }
        }
    }

    private var hotspots: some View {
        ZStack {
            HotspotButton(label: "Wallpaper") { model.go(.wallpaper) }
                .frame(width: canvas.width * 0.5, height: canvas.height * 0.5)
                .offset(y: -canvas.height * 0.08)
            // The Dock and the menu bar are their own hotspots now, everywhere: click to open their
            // chapter, drag to move them. See `handles`.
            ForEach([(Alignment.topLeading), .topTrailing, .bottomLeading, .bottomTrailing], id: \.self) { corner in
                HotspotButton(label: "Hot Corners") { model.go(.corners) }
                    .frame(width: canvas.width * 0.07, height: canvas.width * 0.07)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
            }
        }
    }

    // MARK: Layers from Atelier's own desktop tools

    /// Screen points to stage points.
    private var screenScale: Double {
        canvas.width / max(NSScreen.screens.first?.frame.width ?? 1728, 1)
    }

    /// Where the visible frame sits on the stage: below the menu bar, beside the Dock.
    private var visibleArea: CGRect {
        guard let screen = NSScreen.screens.first else { return CGRect(origin: .zero, size: canvas) }
        let full = screen.frame, visible = screen.visibleFrame, k = screenScale
        return CGRect(x: (visible.minX - full.minX) * k, y: (full.maxY - visible.maxY) * k,
                      width: visible.width * k, height: visible.height * k)
    }

    /// The widgets on the main display, as they are or as they were.
    private var stagePlacements: [WidgetPlacement] {
        let key = NSScreen.screens.first.map(WidgetBoard.key) ?? "main"
        guard let past else { return board.placements(on: key, fallback: true) }
        let connected = Set(NSScreen.screens.map(WidgetBoard.key))
        return past.placements.filter { $0.screen == key || !connected.contains($0.screen) }
    }

    /// A weather widget with no city yet. The replica shows nothing there, not a placeholder.
    static func waitingForCity(_ place: WidgetPlacement) -> Bool { place.kind == .weather && place.options.place == nil }

    private var widgetsLayer: some View {
        let area = visibleArea, k = screenScale
        let shown = Set(shownBoard)
        return ZStack(alignment: .topLeading) {
            ForEach(stagePlacements.filter { shown.contains($0.kind) && !Self.waitingForCity($0) }) { place in
                let origin = WidgetBoard.origin(column: place.column, row: place.row)
                let size = WidgetBoard.tileSize(place)
                WidgetFace(kind: place.kind, board: board, size: size, placement: place)
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(k, anchor: .topLeading)
                    .frame(width: size.width * k, height: size.height * k, alignment: .topLeading)
                    .offset(x: area.minX + origin.x * k, y: area.minY + origin.y * k)
                    .opacity(liftedWidget == place.uid ? 0 : 1)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Replacing the system Dock, the Atelier Dock sits flush at the screen edge, below only the menu bar.
    private var ownDockArea: CGRect {
        let replaced = past?.systemReplaced ?? ownDock.systemReplaced
        return replaced ? CGRect(x: 0, y: visibleArea.minY, width: canvas.width, height: canvas.height - visibleArea.minY)
                        : visibleArea
    }

    private func ownDockLayer(_ edge: OwnDockEdge) -> some View {
        let area = ownDockArea
        return OwnDockMiniature(dock: ownDock, edge: edge, area: area.size, scale: screenScale, moving: model.cameraMoving)
            .offset(x: area.minX, y: area.minY)
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            .transition(.offset(y: 20).combined(with: .opacity))
    }
}

/// What the stage stands on: a soft ellipse of shade under its lower edge, and a reflection line
/// where screen meets floor. Drawn at stage size and only ever scaled with it: nothing here is
/// blurred, so a camera move costs no extra pass.
struct StagePlinth: View {
    let canvas: CGSize

    var body: some View {
        ZStack(alignment: .bottom) {
            // Fills the rounded screen so the replica's transparent edges read as glass on black.
            RoundedRectangle(cornerRadius: canvas.width * 0.014, style: .continuous)
                .fill(.black)
                .frame(width: canvas.width, height: canvas.height)
            Ellipse()
                .fill(EllipticalGradient(colors: [.black.opacity(0.7), .black.opacity(0.3), .clear],
                                         center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
                .frame(width: canvas.width * 1.12, height: canvas.height * 0.26)
                .offset(y: canvas.height * 0.1)
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .white.opacity(0.14), location: 0.5),
                                   .init(color: .clear, location: 1)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: canvas.width * 0.86, height: 0.75)
                .offset(y: canvas.height * 0.012)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .bottom)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension Alignment: @retroactive Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(String(describing: self))
    }
}

/// The owner's invitation to swap the replica for the real screen.
struct StageNote: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 14).frame(height: 34)
            .fixedSize()
            .atelierGlass(.regular, in: .capsule)
            .allowsHitTesting(false)
    }
}

/// The menu bar clock's analog face.
struct AnalogFace: View {
    let date: Date

    var body: some View {
        Canvas { context, bounds in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            let middle = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
            let radius = min(bounds.width, bounds.height) / 2
            context.stroke(Path(ellipseIn: CGRect(origin: .zero, size: bounds).insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.9)), lineWidth: 0.8)
            func hand(_ angle: Double, _ length: Double) {
                var path = Path()
                path.move(to: middle)
                path.addLine(to: CGPoint(x: middle.x + sin(angle) * radius * length, y: middle.y - cos(angle) * radius * length))
                context.stroke(path, with: .color(.white), lineWidth: 1)
            }
            hand(Double(parts.minute ?? 0) / 60 * 2 * .pi, 0.78)
            hand((Double(parts.hour ?? 0).truncatingRemainder(dividingBy: 12) + Double(parts.minute ?? 0) / 60) / 12 * 2 * .pi, 0.5)
        }
    }
}

/// App Pulse and Click Ripples only fire on an event, so the replica plays them on a loop
/// while their chapter is open.
struct EventEcho: View {
    let size: CGSize
    let pulse: Bool
    let ripples: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.demoFreeze) private var freeze

    var body: some View {
        if pulse || ripples {
            TimelineView(.animation(paused: reduceMotion || freeze != nil)) { context in
                let t = freeze ?? (reduceMotion ? 0.3 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.6))
                let scale = size.width / 1728
                ZStack {
                    if pulse {
                        Rectangle().strokeBorder(Color.purple, lineWidth: 44 * scale * 1.4)
                            .blur(radius: 34 * scale)
                            .opacity(0.95 * flash(t))
                    }
                    if ripples {
                        ripple(t, at: CGPoint(x: size.width * 0.34, y: size.height * 0.42), delay: 1.4)
                        ripple(t, at: CGPoint(x: size.width * 0.62, y: size.height * 0.58), delay: 2.4)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func flash(_ t: Double) -> Double {
        t < 0.14 ? t / 0.14 : max(0, 1 - (t - 0.14) / 0.75)
    }

    private func ripple(_ t: Double, at point: CGPoint, delay: Double) -> some View {
        let p = min(max((t - delay) / 0.55, 0), 1)
        let width = size.width * 0.07
        return ZStack {
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2)
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1).scaleEffect(0.62)
        }
        .frame(width: width, height: width)
        .scaleEffect(0.12 + 0.88 * p)
        .opacity(t < delay ? 0 : 1 - p)
        .position(point)
    }
}

/// The Notch Shelf, opened as it would be while a file is being dragged to the top.
struct ShelfEcho: View {
    let size: CGSize

    var body: some View {
        HStack(spacing: size.width * 0.02) {
            ForEach(["doc.fill", "photo.fill", "doc.richtext.fill"], id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: size.width * 0.026)).foregroundStyle(.white.opacity(0.9))
            }
            Text("Drop files to park them").font(.system(size: size.width * 0.012, weight: .medium)).foregroundStyle(DS.Ink.secondary)
        }
        .padding(.horizontal, size.width * 0.03).padding(.vertical, size.width * 0.016)
        .atelierGlass(.regular, in: .rect(cornerRadius: size.width * 0.018))
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, size.width * 0.026)
        .allowsHitTesting(false)
        .transition(.offset(y: -20).combined(with: .opacity))
    }
}

// MARK: - Tweak demonstrations

extension EnvironmentValues {
    /// Stops the demonstrations at a chosen second. Reduce Motion stops them at their best frame.
    @Entry var demoFreeze: Double?
}

/// A spring that settles `over` seconds after `start`, written as a function of time so a
/// demonstration can show the real duration of the thing it demonstrates. Zero is a cut.
private func rise(_ t: Double, at start: Double, over: Double) -> Double {
    guard t > start else { return 0 }
    guard over > 0 else { return 1 }
    let omega = 6 / over, x = (t - start) * omega
    return min(1 - (1 + x) * exp(-x), 1)
}

private func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

/// One way of showing a tweak that has nothing permanent to look at.
struct DemoSpec {
    var period = 3.0
    /// The moment that tells the story, for Reduce Motion.
    var still: Double?
    var off: String
    var on: String
    var note: String?
    let draw: @MainActor (Bool, Double) -> AnyView

    init<V: View>(period: Double = 3, still: Double? = nil, off: String, on: String, note: String? = nil,
                  @ViewBuilder draw: @escaping @MainActor (Bool, Double) -> V) {
        self.period = period
        self.still = still
        self.off = off
        self.on = on
        self.note = note
        self.draw = { AnyView(draw($0, $1)) }
    }
}

/// Where each tweak shows. Everything not named here gets a card, so a new tweak is never blank.
enum TweakStage {
    enum Surface: Equatable {
        case dock, menu, finder, tiling, capture, demo(DemoSpec)

        static func == (a: Surface, b: Surface) -> Bool {
            switch (a, b) {
            case (.dock, .dock), (.menu, .menu), (.finder, .finder), (.tiling, .tiling), (.capture, .capture), (.demo, .demo): true
            default: false
            }
        }
    }

    @MainActor static func surface(_ tweak: Tweak) -> Surface {
        switch tweak.key {
        case "show-process-indicators": .dock
        case "ShowSeconds", "IsAnalog", "FlashDateSeparators": .menu
        case "ShowStatusBar", "ShowPathbar", "ShowPreviewPane", "_FXShowPosixPathInTitle", "_FXSortFoldersFirst",
             "AppleShowAllFiles", "ShowRecentTags": .finder
        case "EnableTiledWindowMargins", "TiledWindowSpacing": .tiling
        case "disable-shadow", "show-thumbnail", "include-date": .capture
        default: .demo(demos[tweak.key] ?? fallback(tweak))
        }
    }

    @MainActor private static func fallback(_ tweak: Tweak) -> DemoSpec {
        DemoSpec(period: 2, still: 1, off: "Off", on: "On", note: "This one changes behaviour, so there is nothing to draw yet.") { on, _ in
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 34)).foregroundStyle(on ? DS.Ink.accent : DS.Ink.tertiary)
        }
    }

    private static let unmeasured = "Default timing is approximate."

    @MainActor private static let demos: [String: DemoSpec] = [
        // Dock
        "genie-speed": DemoSpec(period: 2.4, still: 0.72, off: "Default rate, 0.5", on: "Rate 0.25",
                                note: "Whether a lower rate means faster is not confirmed yet.") { on, t in
            GenieScene(t: t, duration: on ? 0.25 : 0.5)
        },
        "slow-motion-allowed": DemoSpec(period: 4, still: 1.6, off: "Shift does nothing", on: "Hold Shift to slow it") { on, t in
            GenieScene(t: t, duration: on ? 2.4 : 0.5, keys: ["⇧"])
        },
        "autohide-delay": DemoSpec(period: 2.8, still: 1.05, off: "Waits about 0.5 s", on: "No wait", note: unmeasured) { on, t in
            DockEdgeScene(t: t, reveal: true, delay: on ? 0 : 0.5, duration: 0.4)
        },
        "autohide-time-modifier": DemoSpec(period: 2.4, still: 0.8, off: "Hides in about 0.5 s", on: "About 0.1 s", note: unmeasured) { on, t in
            DockEdgeScene(t: t, reveal: false, delay: 0, duration: on ? 0.1 : 0.5)
        },
        "launchanim": DemoSpec(period: 2.8, still: 0.9, off: "The icon bounces while it opens", on: "It opens without a bounce") { on, t in BounceScene(t: t, bounces: !on) },
        "no-bouncing": DemoSpec(period: 2.8, still: 0.9, off: "The icon bounces", on: "The icon stays still") { on, t in BounceScene(t: t, bounces: !on) },
        "scroll-to-open": DemoSpec(period: 3, still: 2, off: "Scrolling does nothing", on: "Scrolling fans it open") { on, t in ScrollOpenScene(t: t, on: on) },
        "show-recent-count": DemoSpec(period: 2, still: 1, off: "The system's own count", on: "Exactly three",
                                      note: "The default count was not measured.") { on, _ in RecentsScene(on: on) },
        "mouse-over-hilite-stack": DemoSpec(period: 3, still: 1.4, off: "No highlight", on: "Highlight under the pointer") { on, t in StackHighlightScene(t: t, on: on) },
        "enable-spring-load-actions-on-all-items": DemoSpec(period: 3.2, still: 2.2, off: "Only folders spring open", on: "Any item springs open") { on, t in SpringScene(t: t, opens: on) },
        "adaptive-glass": DemoSpec(period: 2, still: 1, off: "Dock glass", on: "Adaptive glass",
                                   note: "No visible difference was found in a Dock capture on this Mac.") { _, _ in
            ZStack { MiniDock(count: 6).position(x: 150, y: 150) }.frame(width: DemoCard.paneW, height: DemoCard.paneH)
        },
        "spring-to-expose": DemoSpec(period: 3.2, still: 2.3, off: "Windows spread out", on: "Windows stay put") { on, t in SpringExposeScene(t: t, spreads: !on) },
        "hilite-windows-in-expose": DemoSpec(period: 2.6, still: 1.5, off: "Hovered window glows", on: "No glow") { on, t in ExposeScene(t: t, ring: !on) },
        "show-space-bindings": DemoSpec(period: 2, still: 1, off: "No Space shown", on: "Space shown on the app",
                                        note: "Effect read from the Dock's code, not confirmed on screen.") { on, _ in SpaceBindingScene(on: on) },
        // Windows
        "EnableStandardClickToShowDesktop": DemoSpec(period: 3, still: 1.9, off: "The click does nothing", on: "Windows step aside") { on, t in ClickDesktopScene(t: t, on: on) },
        "StandardHideDesktopIcons": DemoSpec(period: 2, still: 1, off: "Icons on the desktop", on: "A clean desktop") { on, _ in DesktopIconsScene(on: on, foldersFirst: false) },
        "AutoHide": DemoSpec(period: 3, still: 2, off: "Strip stays", on: "Strip hides itself") { on, t in
            StripScene(hidden: on ? rise(t, at: 1, over: 0.5) : 0)
        },
        "EnableStageManagerHotKey": DemoSpec(period: 3, still: 2, off: "The keys do nothing", on: "Control-Escape toggles it") { on, t in
            ZStack {
                StripScene(hidden: on ? 1 - rise(t, at: 1, over: 0.5) : 1)
                KeyCaps(keys: ["⌃", "esc"], down: t > 0.8 && t < 1.4).position(x: 150, y: 164)
            }
        },
        "HiddenStripPeekWidth": DemoSpec(period: 2, still: 1, off: "Hidden completely", on: "A 12 point sliver stays") { on, _ in
            StripScene(hidden: 1, peek: on ? 18 : 0)
        },
        "AnimationSpeed": DemoSpec(period: 3, still: 1.25, off: "Normal speed", on: "1.6 times as fast",
                                   note: "Effect read from the name of the key, not confirmed on screen.") { on, t in
            StripScene(hidden: 0, swap: rise(t, at: 1, over: on ? 0.31 : 0.5))
        },
        "AppleEdgeResizeExteriorSize": DemoSpec(period: 2.4, still: 1.2, off: "4 point band", on: "10 point band") { on, t in
            ResizeScene(t: t, band: on ? 10 : 4, corner: 12)
        },
        "AppleEdgeResizeCornerSize": DemoSpec(period: 2.4, still: 1.2, off: "12 point corner", on: "20 point corner") { on, t in
            ResizeScene(t: t, band: 4, corner: on ? 20 : 12, showCorner: true)
        },
        "NSWindowShouldDragOnGesture": DemoSpec(period: 3, still: 2, off: "Only the title bar drags", on: "Drag from anywhere") { on, t in DragAnywhereScene(t: t, on: on) },
        "NSWindowResizeTime": DemoSpec(period: 2.4, still: 0.84, off: "0.2 s", on: "0.05 s") { on, t in SheetScene(t: t, duration: on ? 0.05 : 0.2) },
        "NSAutomaticWindowAnimationsEnabled": DemoSpec(period: 2.4, still: 0.88, off: "Windows zoom open", on: "Windows just appear") { on, t in WindowOpenScene(t: t, duration: on ? 0 : 0.25) },
        "AppleSpacesSwitchOnActivate": DemoSpec(period: 3, still: 2, off: "Jumps to the app's Space", on: "You stay here") { on, t in SpacesScene(t: t, jumps: !on) },
        // Menu bar
        "NSStatusItemSpacing": DemoSpec(period: 2, still: 1, off: "16 points apart", on: "6 points apart", note: "Takes effect after logging out.") { on, _ in StatusScene(spacing: on ? 6 : 16, padding: 10, selected: false) },
        "NSStatusItemSelectionPadding": DemoSpec(period: 2, still: 1, off: "10 point highlight", on: "4 point highlight", note: "Takes effect after logging out.") { on, _ in StatusScene(spacing: 16, padding: on ? 4 : 10, selected: true) },
        // Finder
        "_FXSortFoldersFirstOnDesktop": DemoSpec(period: 2, still: 1, off: "Folders mixed in", on: "Folders on top") { on, _ in DesktopIconsScene(on: false, foldersFirst: on) },
        "FXEnableExtensionChangeWarning": DemoSpec(period: 3, still: 1.8, off: "Finder asks first", on: "Renames at once") { on, t in RenameScene(t: t, warns: !on) },
        "QuitMenuItem": DemoSpec(period: 2, still: 1, off: "No Quit item", on: "Quit Finder in the menu") { on, _ in FinderMenuScene(on: on) },
        "DisableAllAnimations": DemoSpec(period: 2.4, still: 0.88, off: "Finder animates", on: "Finder cuts") { on, t in WindowOpenScene(t: t, duration: on ? 0 : 0.25, title: "Documents") },
        // Interface
        "NSScrollAnimationEnabled": DemoSpec(period: 3, still: 0.82, off: "Glides to a stop", on: "Moves line by line") { on, t in ScrollScene(t: t, duration: on ? 0 : 0.3) },
        "NSUseAnimatedFocusRing": DemoSpec(period: 2.4, still: 0.78, off: "Ring closes in", on: "Ring just appears") { on, t in FocusRingScene(t: t, duration: on ? 0 : 0.25) },
        "NSToolbarTitleViewRolloverDelay": DemoSpec(period: 2.4, still: 0.95, off: "Waits 0.25 s", on: "Responds at once") { on, t in RolloverScene(t: t, delay: on ? 0 : 0.25) },
        "QLPanelAnimationDuration": DemoSpec(period: 2.6, still: 0.92, off: "Zooms from the file", on: "Opens at once") { on, t in QuickLookScene(t: t, duration: on ? 0 : 0.3) },
        "NSNavPanelExpandedStateForSaveMode": DemoSpec(period: 2, still: 1, off: "Opens compact", on: "Opens expanded") { on, _ in
            SavePanelMock(width: 250, expanded: on, cloud: false)
        },
        "NSDocumentSaveNewDocumentsToCloud": DemoSpec(period: 2, still: 1, off: "Starts in iCloud Drive", on: "Starts on this Mac") { on, _ in
            SavePanelMock(width: 250, expanded: false, cloud: !on)
        },
        // Appearance
        "AppleReduceDesktopTinting": DemoSpec(period: 2, still: 1, off: "Picks up the wallpaper", on: "Stays neutral") { on, _ in
            ZStack {
                LinearGradient(colors: [Color(red: 0.8, green: 0.45, blue: 0.3), Color(red: 0.6, green: 0.25, blue: 0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
                MiniWindow(w: 200, h: 120, title: "Notes",
                           fill: on ? Color(white: 0.18) : Color(red: 0.24, green: 0.14, blue: 0.2)) { MiniLines() }
            }
        },
        "AppleShowScrollBars": DemoSpec(period: 3, still: 2.2, off: "Bars show while scrolling", on: "Bars always show") { on, t in ScrollBarScene(t: t, always: on) },
        "AppleWindowTabbingMode": DemoSpec(period: 3, still: 2, off: "New documents get a window", on: "New documents get a tab") { on, t in TabsScene(t: t, tabs: on) },
        "AppleActionOnDoubleClick": DemoSpec(period: 3, still: 2, off: "Double-click zooms", on: "Double-click does nothing") { on, t in TitleBarScene(t: t, zooms: !on) },
    ]
}

/// A tweak explained on the stage: the same moment, without it and with it, side by side.
struct DemoCard: View {
    static let paneW = 300.0, paneH = 186.0
    static let width = paneW * 2 + 12 + 36

    let title: String
    let spec: DemoSpec
    let applied: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(tweak: Tweak, spec: DemoSpec, applied: Bool) {
        self.init(title: tweak.title, spec: spec, applied: applied)
    }

    /// Any setting's before and after, not only a macOS tweak's.
    init(title: String, spec: DemoSpec, applied: Bool) {
        self.title = title
        self.spec = spec
        self.applied = applied
    }
    @Environment(\.demoFreeze) private var freeze
    @State private var start = Date()

    private var stopped: Bool { reduceMotion || freeze != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DisplayTitle(text: title, size: 22)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: stopped)) { context in
                let moment = freeze ?? (reduceMotion ? spec.still ?? spec.period / 2
                                        : context.date.timeIntervalSince(start).truncatingRemainder(dividingBy: spec.period))
                HStack(spacing: 12) {
                    pane(on: false, moment)
                    pane(on: true, moment)
                }
            }
            if let note = spec.note {
                Text(note).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: Self.width, alignment: .leading)
        .atelierGlass(.regular, in: .rect(cornerRadius: DS.Radius.panel))
    }

    private func pane(on: Bool, _ t: Double) -> some View {
        let edges = stopped ? 1 : min(min(t / 0.18, (spec.period - t) / 0.22), 1)
        return VStack(alignment: .leading, spacing: 7) {
            ZStack {
                LinearGradient(colors: [Color(red: 0.16, green: 0.2, blue: 0.42), Color(red: 0.32, green: 0.16, blue: 0.4)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                spec.draw(on, t).opacity(max(edges, 0))
            }
            .frame(width: Self.paneW, height: Self.paneH)
            .clipShape(.rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(on == applied ? DS.Ink.accent.opacity(0.8) : DS.Ink.hairline, lineWidth: on == applied ? 1.5 : 0.5)
            }
            HStack(spacing: 6) {
                Text(on ? "On" : "Off").font(DS.eyebrow).foregroundStyle(on ? DS.Ink.accent : DS.Ink.secondary)
                Text(on ? spec.on : spec.off).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if on == applied { Text("Now").font(DS.eyebrow).foregroundStyle(DS.Ink.accent) }
            }
        }
    }
}

// MARK: Demo parts

private struct MiniWindow<Content: View>: View {
    var w = 190.0
    var h = 120.0
    var title = ""
    var fill = Color(white: 0.16)
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 7, height: 7) }
                Text(title).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(DS.Ink.secondary).lineLimit(1).padding(.leading, 4)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 20)
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).clipped()
        }
        .frame(width: w, height: h)
        .background(fill, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.4), radius: 9, y: 5)
    }
}

private struct MiniLines: View {
    var count = 4
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<count, id: \.self) { line in
                Capsule().fill(.white.opacity(line == 0 ? 0.28 : 0.13)).frame(width: [84.0, 120, 100, 132, 92, 116][line % 6], height: 4)
            }
        }
        .padding(10)
    }
}

private struct AppTile: View {
    let index: Int
    var size = 24.0
    private static let colors: [Color] = [.blue, .green, .orange, .pink, .purple, .teal, .indigo]
    private static let symbols = ["safari.fill", "message.fill", "music.note", "photo.fill", "calendar", "map.fill", "paperplane.fill"]

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(Self.colors[index % 7].gradient)
            .frame(width: size, height: size)
            .overlay { Image(systemName: Self.symbols[index % 7]).font(.system(size: size * 0.5)).foregroundStyle(.white) }
    }
}

private struct MiniDock: View {
    var count = 6
    var size = 24.0

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { AppTile(index: $0, size: size) }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

private struct Pointer: View {
    var body: some View {
        Image(systemName: "cursorarrow").font(.system(size: 17, weight: .medium)).foregroundStyle(.white)
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
    }
}

/// A pointer that travels between two spots, its tip on the spot.
private func pointer(from a: CGPoint, to b: CGPoint, _ p: Double) -> some View {
    Pointer().position(x: mix(a.x, b.x, p) + 5, y: mix(a.y, b.y, p) + 8)
}

private struct ClickRing: View {
    let p: Double
    var body: some View {
        Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5)
            .frame(width: 34, height: 34).scaleEffect(0.2 + 0.8 * p).opacity(p > 0 && p < 1 ? 1 - p : 0)
    }
}

private struct KeyCaps: View {
    let keys: [String]
    var down = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key).font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 8).frame(minWidth: 28, minHeight: 26)
                    .background(.white.opacity(down ? 0.32 : 0.14), in: .rect(cornerRadius: 6, style: .continuous))
                    .scaleEffect(down ? 0.94 : 1)
            }
        }
    }
}

// MARK: Dock scenes

private struct GenieShape: Shape {
    let p: Double

    func path(in rect: CGRect) -> Path {
        let cx = rect.midX, sink = 166.0, top = mix(26, sink, pow(p, 1.7)), bottom = mix(126, sink, min(p * 1.7, 1))
        let topHalf = mix(84, 7, pow(p, 1.3)), bottomHalf = mix(84, 7, min(p * 1.7, 1)), mid = (top + bottom) / 2
        var path = Path()
        path.move(to: CGPoint(x: cx - topHalf, y: top))
        path.addLine(to: CGPoint(x: cx + topHalf, y: top))
        path.addCurve(to: CGPoint(x: cx + bottomHalf, y: bottom), control1: CGPoint(x: cx + topHalf, y: mid), control2: CGPoint(x: cx + bottomHalf, y: mid))
        path.addLine(to: CGPoint(x: cx - bottomHalf, y: bottom))
        path.addCurve(to: CGPoint(x: cx - topHalf, y: top), control1: CGPoint(x: cx - bottomHalf, y: mid), control2: CGPoint(x: cx - topHalf, y: mid))
        path.closeSubpath()
        return path
    }
}

private struct GenieScene: View {
    let t: Double
    let duration: Double
    var keys: [String] = []

    var body: some View {
        let p = rise(t, at: 0.6, over: duration)
        ZStack {
            MiniDock().position(x: 150, y: 164)
            GenieShape(p: p)
                .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                .opacity(p > 0.99 ? 0 : 1)
            MiniLines(count: 5).position(x: 150, y: 80).opacity(1 - min(p * 4, 1))
            if !keys.isEmpty { KeyCaps(keys: keys, down: t > 0.3).position(x: 34, y: 28) }
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct DockEdgeScene: View {
    let t: Double
    let reveal: Bool
    let delay: Double
    let duration: Double

    var body: some View {
        let top = CGPoint(x: 120, y: 60), edge = CGPoint(x: 150, y: 166)
        let arrive = rise(t, at: 0.2, over: 0.5), leave = rise(t, at: 0.6, over: 0.4)
        let shown = reveal ? rise(t, at: 0.7 + delay, over: duration) : 1 - rise(t, at: 0.7, over: duration)
        ZStack {
            MiniDock().position(x: 150, y: mix(214, 160, shown))
            if reveal { pointer(from: top, to: edge, arrive) } else { pointer(from: edge, to: top, leave) }
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct BounceScene: View {
    let t: Double
    let bounces: Bool

    var body: some View {
        let lift = bounces && t > 0.4 ? abs(sin((t - 0.4) * .pi * 2.4)) * 26 * max(1 - (t - 0.4) / 2, 0) : 0
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(0..<6, id: \.self) { index in
                VStack(spacing: 3) {
                    AppTile(index: index).offset(y: index == 2 ? -lift : 0)
                    Circle().fill(.white.opacity(index == 2 && t > 0.5 ? 0.85 : 0)).frame(width: 3, height: 3)
                }
            }
        }
        .padding(.horizontal, 6).padding(.top, 6).padding(.bottom, 2)
        .background(.ultraThinMaterial.opacity(0.9), in: .rect(cornerRadius: 12, style: .continuous))
        .position(x: 150, y: 158)
    }
}

private struct ScrollOpenScene: View {
    let t: Double
    let on: Bool

    var body: some View {
        let open = on ? rise(t, at: 1.1, over: 0.45) : 0
        ZStack {
            MiniDock(count: 5).position(x: 150, y: 164)
            ForEach(0..<4, id: \.self) { index in
                Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(.white.opacity(0.9))
                    .scaleEffect(0.5 + 0.5 * open)
                    .offset(x: Double(index) * 11 * open, y: -Double(index + 1) * 28 * open)
                    .rotationEffect(.degrees(Double(index) * 4 * open))
                    .opacity(open)
                    .position(x: 176, y: 144)
            }
            Image(systemName: "arrow.up.and.down").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white).opacity(t > 0.5 && t < 1.2 ? 1 : 0)
                .position(x: 218, y: 122)
            pointer(from: CGPoint(x: 100, y: 50), to: CGPoint(x: 176, y: 160), rise(t, at: 0.1, over: 0.5))
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct RecentsScene: View {
    let on: Bool

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { AppTile(index: $0) }
            Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 22)
            ForEach(3..<(on ? 6 : 7), id: \.self) { AppTile(index: $0).opacity($0 == 6 ? 0.45 : 1) }
        }
        .padding(6)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
        .position(x: 150, y: 150)
    }
}

private struct StackHighlightScene: View {
    let t: Double
    let on: Bool

    var body: some View {
        let cell = min(Int(t / 0.75), 3)
        let columns = [GridItem(.fixed(46)), GridItem(.fixed(46))]
        ZStack {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    AppTile(index: index, size: 34).frame(width: 46, height: 46)
                        .background {
                            if on, index == cell { RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.3)) }
                        }
                }
            }
            .frame(width: 112)
            .padding(10)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16, style: .continuous))
            .position(x: 150, y: 93)
            pointer(from: CGPoint(x: cell % 2 == 0 ? 126 : 176, y: cell < 2 ? 68 : 120),
                    to: CGPoint(x: cell % 2 == 0 ? 126 : 176, y: cell < 2 ? 68 : 120), 1)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct SpringScene: View {
    let t: Double
    let opens: Bool

    var body: some View {
        let carry = rise(t, at: 0.2, over: 0.8)
        let spring = opens ? rise(t, at: 1.5, over: 0.3) : 0
        ZStack {
            MiniDock(count: 5).position(x: 150, y: 164)
            MiniWindow(w: 150, h: 96, title: "Messages") { MiniLines() }
                .scaleEffect(0.7 + 0.3 * spring).opacity(spring).position(x: 150, y: 74)
            Image(systemName: "doc.fill").font(.system(size: 22)).foregroundStyle(.white)
                .shadow(radius: 3).position(x: mix(52, 122, carry), y: mix(48, 150, carry))
                .opacity(1 - spring)
            pointer(from: CGPoint(x: 58, y: 54), to: CGPoint(x: 128, y: 156), carry)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct SpringExposeScene: View {
    let t: Double
    let spreads: Bool

    var body: some View {
        let carry = rise(t, at: 0.2, over: 0.8)
        let spread = spreads ? rise(t, at: 1.5, over: 0.4) : 0
        ZStack {
            MiniDock(count: 5).position(x: 150, y: 164)
            MiniWindow(w: 130, h: 84, title: "Report") { MiniLines(count: 3) }
                .position(x: mix(136, 76, spread), y: mix(68, 62, spread)).scaleEffect(1 - 0.12 * spread)
            MiniWindow(w: 130, h: 84, title: "Budget") { MiniLines(count: 3) }
                .position(x: mix(164, 224, spread), y: mix(82, 62, spread)).scaleEffect(1 - 0.12 * spread)
            Image(systemName: "doc.fill").font(.system(size: 20)).foregroundStyle(.white)
                .shadow(radius: 3).position(x: mix(40, 150, carry), y: mix(30, 150, carry))
            pointer(from: CGPoint(x: 46, y: 36), to: CGPoint(x: 156, y: 156), carry)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct ExposeScene: View {
    let t: Double
    let ring: Bool

    var body: some View {
        let hover = t > 0.9
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                let x = [62.0, 150, 238][index], y = [66.0, 118, 66][index]
                MiniWindow(w: 84, h: 56) { EmptyView() }
                    .overlay {
                        if ring, hover, index == 1 {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DS.Ink.accent, lineWidth: 3).padding(-3)
                        }
                    }
                    .position(x: x, y: y)
            }
            pointer(from: CGPoint(x: 40, y: 150), to: CGPoint(x: 150, y: 120), rise(t, at: 0.2, over: 0.6))
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct SpaceBindingScene: View {
    let on: Bool

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(index == 1 ? 0.28 : 0.13))
                        .frame(width: 74, height: 46)
                        .overlay(alignment: .bottomTrailing) {
                            if on, index == 1 { AppTile(index: 2, size: 18).padding(4) }
                        }
                    Text("Desktop \(index + 1)").font(.system(size: 9, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                }
                .position(x: 66 + Double(index) * 84, y: 60)
            }
            MiniDock(count: 5).position(x: 150, y: 158)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

// MARK: Window scenes

private struct ClickDesktopScene: View {
    let t: Double
    let on: Bool

    var body: some View {
        let aside = on ? rise(t, at: 1.2, over: 0.45) : 0
        ZStack {
            MiniWindow(w: 130, h: 92, title: "Report") { MiniLines(count: 3) }.position(x: mix(100, -10, aside), y: 78)
            MiniWindow(w: 130, h: 92, title: "Notes") { MiniLines(count: 3) }.position(x: mix(180, 310, aside), y: 104)
            ClickRing(p: min(max((t - 1.1) / 0.4, 0), 1)).position(x: 260, y: 164)
            pointer(from: CGPoint(x: 150, y: 40), to: CGPoint(x: 260, y: 164), rise(t, at: 0.2, over: 0.7))
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct DesktopIconsScene: View {
    let on: Bool
    let foldersFirst: Bool

    var body: some View {
        DesktopIconsMock(size: CGSize(width: 560, height: DemoCard.paneH), foldersFirst: foldersFirst)
            .opacity(on ? 0 : 1)
            .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct StripScene: View {
    let hidden: Double
    var peek = 0.0
    var swap = 0.0

    var body: some View {
        let shift = hidden * (58 + 22 - peek)
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color(white: 0.24 + Double(index) * 0.03))
                    .overlay { RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 0.5) }
                    .frame(width: 58, height: 38)
                    .overlay { AppTile(index: index + 2, size: 15) }
                    .rotation3DEffect(.degrees(18), axis: (0, 1, 0), perspective: 0.5)
                    .position(x: 44 - shift, y: 46 + Double(index) * 48)
            }
            MiniWindow(w: mix(176, 58, swap), h: mix(136, 38, swap), title: swap < 0.4 ? "Notes" : "") { MiniLines() }
                .position(x: mix(180, 44, swap), y: mix(92, 142, swap))
            MiniWindow(w: mix(58, 176, swap), h: mix(38, 136, swap), title: swap > 0.6 ? "Report" : "") { EmptyView() }
                .opacity(swap)
                .position(x: mix(44, 180, swap), y: mix(46, 92, swap))
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct ResizeScene: View {
    let t: Double
    let band: Double
    let corner: Double
    var showCorner = false

    var body: some View {
        // Drawn at twice the size. The real bands are too thin to compare by eye.
        let scale = 2.0
        let throb = 0.6 + 0.3 * sin(t / 2.4 * 2 * .pi)
        ZStack {
            MiniWindow(w: 170, h: 110, title: "Window") { MiniLines() }
                .background {
                    RoundedRectangle(cornerRadius: 9 + band * scale, style: .continuous)
                        .strokeBorder(DS.Ink.accent.opacity(showCorner ? 0.25 : throb), lineWidth: band * scale)
                        .padding(-band * scale)
                }
                .overlay(alignment: .bottomTrailing) {
                    if showCorner {
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Ink.accent.opacity(throb))
                            .frame(width: corner * scale, height: corner * scale)
                            .offset(x: corner * scale / 2, y: corner * scale / 2)
                    }
                }
                .position(x: 150, y: 93)
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                .shadow(radius: 2).position(x: 150 + 85 + corner * 0.8, y: 93 + 55 + corner * 0.8)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct DragAnywhereScene: View {
    let t: Double
    let on: Bool

    var body: some View {
        let drag = rise(t, at: 1, over: 0.7)
        let moved = on ? drag : 0
        ZStack {
            MiniWindow(w: 150, h: 100, title: "Window") { MiniLines() }.position(x: mix(110, 180, moved), y: mix(92, 76, moved))
            pointer(from: CGPoint(x: 112, y: 100), to: CGPoint(x: 182, y: 84), drag)
            KeyCaps(keys: ["⌃", "⌘"], down: t > 0.5).position(x: 150, y: 164)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct SheetScene: View {
    let t: Double
    let duration: Double

    var body: some View {
        let p = rise(t, at: 0.8, over: duration)
        ZStack {
            MiniWindow(w: 200, h: 136, title: "Report") { MiniLines() }.position(x: 150, y: 93)
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.26))
                .overlay { VStack(spacing: 5) { Capsule().fill(.white.opacity(0.3)).frame(width: 70, height: 4); Capsule().fill(DS.Ink.accent).frame(width: 34, height: 11) } }
                .frame(width: 130, height: 62)
                .scaleEffect(y: p, anchor: .top)
                .opacity(p > 0 ? 1 : 0)
                .position(x: 150, y: 77 + 31 * p)
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct WindowOpenScene: View {
    let t: Double
    let duration: Double
    var title = "Report"

    var body: some View {
        let p = rise(t, at: 0.8, over: duration)
        MiniWindow(w: 190, h: 124, title: title) { MiniLines() }
            .scaleEffect(0.84 + 0.16 * p).opacity(p).position(x: 150, y: 93)
    }
}

private struct SpacesScene: View {
    let t: Double
    let jumps: Bool

    var body: some View {
        let slide = jumps ? rise(t, at: 1, over: 0.6) : 0
        ZStack {
            HStack(spacing: 0) {
                ZStack {
                    MiniWindow(w: 140, h: 94, title: "Report") { MiniLines(count: 3) }
                    Text("Desktop 1").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Ink.secondary).offset(y: 68)
                }
                .frame(width: DemoCard.paneW)
                ZStack {
                    MiniWindow(w: 140, h: 94, title: "Safari") { MiniLines(count: 3) }
                    Text("Desktop 2").font(.system(size: 10, weight: .medium)).foregroundStyle(DS.Ink.secondary).offset(y: 68)
                }
                .frame(width: DemoCard.paneW)
            }
            .offset(x: DemoCard.paneW / 2 - slide * DemoCard.paneW)
            .frame(width: DemoCard.paneW, height: DemoCard.paneH)
            KeyCaps(keys: ["⌘", "⇥"], down: t > 0.6 && t < 1.2).position(x: 150, y: 22)
        }
        .clipped()
    }
}

// MARK: Menu bar and Finder scenes

private struct StatusScene: View {
    let spacing: Double
    let padding: Double
    let selected: Bool

    var body: some View {
        let symbols = ["battery.75percent", "wifi", "magnifyingglass", "switch.2", "speaker.wave.2.fill"]
        HStack(spacing: spacing) {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol).font(.system(size: 13))
                    .padding(.horizontal, selected && symbol == "wifi" ? padding : 0)
                    .padding(.vertical, 3)
                    .background { if selected && symbol == "wifi" { RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(0.28)) } }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 28)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(.black.opacity(0.28))
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct RenameScene: View {
    let t: Double
    let warns: Bool

    var body: some View {
        let typed = t > 0.7
        let alert = warns ? rise(t, at: 1.05, over: 0.3) : 0
        ZStack {
            VStack(spacing: 6) {
                Image(systemName: "doc.fill").font(.system(size: 40)).foregroundStyle(.white.opacity(0.92))
                Text(typed ? "Notes.md" : "Notes.txt")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(DS.Ink.accent.opacity(typed ? 0.6 : 0), in: .rect(cornerRadius: 4))
            }
            .position(x: 150, y: 68)
            VStack(spacing: 7) {
                Text("Are you sure you want to change the extension?").font(.system(size: 10.5, weight: .semibold)).multilineTextAlignment(.center)
                HStack(spacing: 6) {
                    Text("Keep .txt").font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3).background(.white.opacity(0.14), in: .capsule)
                    Text("Use .md").font(.system(size: 10, weight: .medium)).padding(.horizontal, 8).padding(.vertical, 3).background(DS.Ink.accent.opacity(0.8), in: .capsule).foregroundStyle(.black)
                }
            }
            .padding(11).frame(width: 190)
            .background(Color(white: 0.2), in: .rect(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 5)
            .scaleEffect(0.92 + 0.08 * alert).opacity(alert)
            .position(x: 150, y: 118)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct FinderMenuScene: View {
    let on: Bool

    var body: some View {
        var items = ["About Finder", "Settings…", "Empty Trash…", "Hide Finder", "Hide Others"]
        if on { items.append("Quit Finder") }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "apple.logo")
                Text("Finder").fontWeight(.semibold)
                Text("File"); Text("Edit"); Text("View")
                Spacer()
            }
            .font(.system(size: 11)).padding(.horizontal, 10).frame(height: 22)
            .background(.black.opacity(0.28))
            VStack(alignment: .leading, spacing: 3) {
                ForEach(items, id: \.self) { item in
                    Text(item).font(.system(size: 11))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(item == "Quit Finder" ? DS.Ink.accent.opacity(0.7) : .clear, in: .rect(cornerRadius: 4))
                }
            }
            .padding(5).frame(width: 150)
            .background(Color(white: 0.2), in: .rect(cornerRadius: 9, style: .continuous))
            .padding(.leading, 26).padding(.top, 1)
            Spacer(minLength: 0)
        }
    }
}

// MARK: Interface scenes

private struct ScrollScene: View {
    let t: Double
    let duration: Double

    var body: some View {
        let distance = 34 * (rise(t, at: 0.7, over: duration) + rise(t, at: 1.5, over: duration) + rise(t, at: 2.2, over: duration))
        MiniWindow(w: 210, h: 140, title: "Mail") {
            VStack(spacing: 0) {
                ForEach(0..<12, id: \.self) { row in
                    HStack(spacing: 7) {
                        Circle().fill(.white.opacity(0.18)).frame(width: 14, height: 14)
                        Capsule().fill(.white.opacity(0.16)).frame(width: [120.0, 90, 140, 104][row % 4], height: 4)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 9).frame(height: 34)
                }
            }
            .offset(y: -distance)
            .clipped()
        }
        .clipShape(.rect(cornerRadius: 9, style: .continuous))
        .position(x: 150, y: 93)
    }
}

private struct FocusRingScene: View {
    let t: Double
    let duration: Double

    var body: some View {
        let p = rise(t, at: 0.7, over: duration)
        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(0.1))
            .frame(width: 170, height: 28)
            .overlay(alignment: .leading) { Text("Search").font(.system(size: 12)).foregroundStyle(DS.Ink.tertiary).padding(.leading, 9) }
            .overlay {
                RoundedRectangle(cornerRadius: 6 + (1 - p) * 10, style: .continuous)
                    .strokeBorder(DS.Ink.accent, lineWidth: 3)
                    .padding(-3 - (1 - p) * 16)
                    .opacity(p)
            }
            .position(x: 150, y: 93)
    }
}

private struct RolloverScene: View {
    let t: Double
    let delay: Double

    var body: some View {
        let shown = rise(t, at: 0.7 + delay, over: 0.12)
        ZStack {
            MiniWindow(w: 210, h: 120, title: "") { MiniLines() }.position(x: 150, y: 93)
            HStack(spacing: 4) {
                Image(systemName: "doc.fill").font(.system(size: 10)).opacity(shown)
                Text("Report").font(.system(size: 10.5, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).opacity(shown)
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.white.opacity(0.14 * shown), in: .rect(cornerRadius: 5))
            .position(x: 150, y: 43)
            pointer(from: CGPoint(x: 90, y: 128), to: CGPoint(x: 152, y: 46), rise(t, at: 0.15, over: 0.5))
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

private struct QuickLookScene: View {
    let t: Double
    let duration: Double

    var body: some View {
        let p = rise(t, at: 0.8, over: duration)
        ZStack {
            VStack(spacing: 3) {
                Image(systemName: "photo.fill").font(.system(size: 24)).foregroundStyle(.white.opacity(0.9))
                Text("Photo.heic").font(.system(size: 9.5, weight: .medium))
            }
            .position(x: 46, y: 148)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [.orange, .pink, .indigo], startPoint: .top, endPoint: .bottom))
                .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5) }
                .frame(width: 170, height: 124)
                .scaleEffect(0.16 + 0.84 * p)
                .opacity(p > 0 ? 1 : 0)
                .position(x: mix(46, 176, p), y: mix(148, 80, p))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            KeyCaps(keys: ["space"], down: t > 0.5 && t < 1).position(x: 62, y: 28)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}

// MARK: Appearance scenes

private struct ScrollBarScene: View {
    let t: Double
    let always: Bool

    var body: some View {
        let moving = t > 0.6 && t < 1.5
        let fading = always ? 1 : t < 0.6 ? 0 : t < 1.5 ? 1 : max(1 - (t - 1.5) / 0.3, 0)
        let travel = rise(t, at: 0.6, over: 0.7) * 48
        MiniWindow(w: 210, h: 140, title: "Notes") {
            ZStack(alignment: .topTrailing) {
                MiniLines(count: 14).offset(y: -travel)
                Capsule().fill(.white.opacity(moving ? 0.6 : 0.42)).frame(width: 6, height: 48)
                    .padding(.trailing, 3).padding(.top, 3 + travel).opacity(fading)
            }
            .clipped()
        }
        .position(x: 150, y: 93)
    }
}

private struct TabsScene: View {
    let t: Double
    let tabs: Bool

    var body: some View {
        let p = rise(t, at: 1, over: 0.35)
        ZStack {
            MiniWindow(w: 200, h: 124, title: tabs && p > 0 ? "" : "Report") {
                VStack(spacing: 0) {
                    if tabs, p > 0 {
                        HStack(spacing: 2) {
                            tab("Report", front: false)
                            tab("Untitled", front: true).frame(width: 96 * p)
                        }
                        .padding(.horizontal, 5).padding(.bottom, 3)
                    }
                    MiniLines()
                }
            }
            .position(x: 140, y: 90)
            if !tabs {
                MiniWindow(w: 200, h: 124, title: "Untitled") { MiniLines(count: 1) }
                    .scaleEffect(0.86 + 0.14 * p).opacity(p).position(x: 164, y: 106)
            }
            KeyCaps(keys: ["⌘", "N"], down: t > 0.7 && t < 1.2).position(x: 256, y: 26)
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }

    private func tab(_ title: String, front: Bool) -> some View {
        Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            .frame(maxWidth: .infinity).padding(.vertical, 3)
            .background(.white.opacity(front ? 0.16 : 0.05), in: .rect(cornerRadius: 4))
    }
}

private struct TitleBarScene: View {
    let t: Double
    let zooms: Bool

    var body: some View {
        let p = zooms ? rise(t, at: 1.2, over: 0.4) : 0
        ZStack {
            MiniWindow(w: mix(170, 276, p), h: mix(104, 160, p), title: "Report") { MiniLines() }
                .position(x: 150, y: mix(84, 93, p))
            ClickRing(p: min(max((t - 0.9) / 0.3, 0), 1)).position(x: 180, y: mix(42, 23, p))
            ClickRing(p: min(max((t - 1.1) / 0.3, 0), 1)).position(x: 180, y: mix(42, 23, p))
            pointer(from: CGPoint(x: 120, y: 150), to: CGPoint(x: 180, y: 42), rise(t, at: 0.2, over: 0.6))
        }
        .frame(width: DemoCard.paneW, height: DemoCard.paneH)
    }
}



/// The right side of the stage's menu bar, read from the same settings ControlCenter reads:
/// a module shows when it is set to Always, the battery carries its percentage when asked.
struct LiveStatusItems: View {
    let gap: Double
    let pad: Double
    let highlight: Bool
    @ObservedObject private var personal = PersonalModel.shared

    private static let modules = PersonalCatalog.settings(in: .controlCenter).filter {
        $0.section == "Menu Bar Items" && $0.domain == "com.apple.controlcenter"
    }

    private static func setting(_ key: String) -> PersonalSetting? { PersonalCatalog.all.first { $0.key == key } }

    private func shown(_ setting: PersonalSetting) -> Bool { personal.value(setting) == .int(18) }

    private func flag(_ key: String) -> Bool {
        guard let setting = Self.setting(key) else { return false }
        if case let .toggle(on, _) = setting.control { return (personal.value(setting) ?? setting.fallback) == on }
        return false
    }

    var body: some View {
        let extras = Self.modules.filter { !["Battery", "WiFi"].contains($0.key) && shown($0) }
        HStack(spacing: gap) {
            ForEach(extras.reversed(), id: \.id) { module in
                Image(systemName: Demos.menuSymbol(module.title.lowercased())).transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            if let battery = Self.modules.first(where: { $0.key == "Battery" }), shown(battery) {
                HStack(spacing: 3) {
                    if flag("BatteryShowPercentage") { Text("82%") }
                    Image(systemName: "battery.75percent")
                }
            }
            if let wifi = Self.modules.first(where: { $0.key == "WiFi" }), shown(wifi) {
                Image(systemName: "wifi")
                    .padding(.horizontal, highlight ? pad * 0.5 : 0)
                    .background { if highlight { RoundedRectangle(cornerRadius: 3).fill(.white.opacity(0.25)).padding(-1) } }
            }
            if flag("NSStatusItem VisibleCC Item-0") { Image(systemName: "magnifyingglass") }
            Image(systemName: "switch.2")
        }
        .animation(DS.Motion.arrive, value: personal.revision)
    }

    /// The menu bar clock as this Mac sets it: date, weekday, AM/PM and 24-hour time.
    @MainActor static func clockText(_ now: Date, seconds: Bool) -> String {
        let defaults = UserDefaults(suiteName: "com.apple.menuextra.clock")
        let showDate = defaults?.object(forKey: "ShowDate") as? Int ?? 0
        let weekday = defaults?.object(forKey: "ShowDayOfWeek") as? Bool ?? true
        let ampm = defaults?.object(forKey: "ShowAMPM") as? Bool ?? true
        let force24 = UserDefaults.standard.object(forKey: "AppleICUForce24HourTime") as? Bool
        let uses24 = force24 ?? !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a").contains("a")
        let formatter = DateFormatter()
        formatter.locale = .current
        var parts: [String] = []
        if weekday { parts.append("EEE") }
        if showDate != 2 { parts.append("d MMM") }
        let time = (uses24 ? "HH:mm" : "h:mm") + (seconds ? ":ss" : "") + (!uses24 && ampm ? " a" : "")
        formatter.dateFormat = (parts.joined(separator: " ") + "  " + time).trimmingCharacters(in: .whitespaces)
        return formatter.string(from: now)
    }
}
