import AppKit
import SwiftUI
import WebKit

// MARK: - Website Wallpaper
//
// Any web page as the desktop, in the spirit of Plash: a live map, a dashboard, a generative
// piece. One web view per display, at the desktop's own level so windows and icons stay above
// it, ignoring the mouse unless you ask to browse it. Your wallpaper setting is never touched;
// turning it off closes the windows.

struct WebWallpaperPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let address: String
    let symbol: String

    static let all = [
        WebWallpaperPreset(id: "wind", title: "Wind Map", address: "https://earth.nullschool.net/#current/wind/surface/level/orthographic",
                           symbol: "wind"),
        WebWallpaperPreset(id: "radar", title: "Rain Radar", address: "https://www.rainviewer.com/map.html", symbol: "cloud.rain"),
        WebWallpaperPreset(id: "lightning", title: "Lightning", address: "https://map.blitzortung.org/", symbol: "bolt"),
        WebWallpaperPreset(id: "flights", title: "Flights", address: "https://globe.adsbexchange.com/", symbol: "airplane"),
    ]
}

@MainActor
final class WebWallpaper: NSObject, ObservableObject, WKNavigationDelegate {
    static let shared = WebWallpaper()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "web.enabled"); apply() } }
    @Published private(set) var address: String
    /// Clicks and scrolls reach the page, which then sits above the desktop icons.
    @Published var interactive: Bool { didSet { store.set(interactive, forKey: "web.interactive"); placeAll() } }
    /// Minutes between reloads; 0 never.
    @Published var reloadMinutes: Int { didSet { store.set(reloadMinutes, forKey: "web.reload"); scheduleReload() } }
    @Published private(set) var status: String?
    @Published private(set) var title: String?

    private let store = UserDefaults.standard
    private var surfaces: [CGDirectDisplayID: (panel: NSPanel, web: WKWebView)] = [:]
    private var reloadTimer: Timer?
    private var screensObserver: NSObjectProtocol?

    private override init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "web.enabled")
        address = d.string(forKey: "web.address") ?? WebWallpaperPreset.all[0].address
        interactive = d.bool(forKey: "web.interactive")
        reloadMinutes = d.integer(forKey: "web.reload")
        super.init()
    }

    func resume() { if enabled { apply() } }

    /// Takes an address as typed: a bare host gains https, and only web and local file addresses pass.
    static func normalised(_ typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") || text.hasPrefix("~") { return URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }
        let withScheme = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
              ["https", "http", "file"].contains(scheme), scheme == "file" || url.host != nil else { return nil }
        return url
    }

    func load(_ typed: String) {
        guard let url = Self.normalised(typed) else { status = "That is not a web address."; return }
        address = url.absoluteString
        store.set(address, forKey: "web.address")
        status = nil
        if enabled { surfaces.values.forEach { open(url, in: $0.web) } } else { enabled = true }
    }

    private func apply() {
        if enabled { build() } else { tearDown() }
    }

    private func build() {
        guard let url = Self.normalised(address) else { status = "That is not a web address."; return }
        let screens = Dictionary(NSScreen.screens.compactMap { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID).map { ($0, screen) }
        }, uniquingKeysWith: { a, _ in a })
        for id in surfaces.keys where screens[id] == nil { surfaces[id]?.panel.orderOut(nil); surfaces[id] = nil }
        for (id, screen) in screens where surfaces[id] == nil {
            let configuration = WKWebViewConfiguration()
            // A wallpaper never starts sound by itself.
            configuration.mediaTypesRequiringUserActionForPlayback = .all
            let web = WKWebView(frame: screen.frame, configuration: configuration)
            web.navigationDelegate = self
            // A transparent page shows the wallpaper under it. `drawsBackground` is WebKit's own
            // switch, reached by key; it is asked for first, so a release without it cannot
            // throw, and the public under-page colour covers the overscroll either way.
            if web.responds(to: NSSelectorFromString("_setDrawsBackground:")) || web.responds(to: NSSelectorFromString("setDrawsBackground:")) {
                web.setValue(false, forKey: "drawsBackground")
            }
            web.underPageBackgroundColor = .clear
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            panel.isReleasedWhenClosed = false
            panel.contentView = web
            surfaces[id] = (panel, web)
            open(url, in: web)
        }
        placeAll()
        scheduleReload()
        if screensObserver == nil {
            screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                     object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if WebWallpaper.shared.enabled { WebWallpaper.shared.build() } }
            }
        }
    }

    private func open(_ url: URL, in web: WKWebView) {
        if url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        else { web.load(URLRequest(url: url)) }
    }

    /// Desktop level, click-through; or just above the icons while browsing.
    private func placeAll() {
        let screens = NSScreen.screens
        for (id, surface) in surfaces {
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id }
            if let screen { surface.panel.setFrame(screen.frame, display: false) }
            surface.panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(interactive ? .desktopIconWindow : .desktopWindow)) + 1)
            surface.panel.ignoresMouseEvents = !interactive
            surface.panel.orderFrontRegardless()
        }
    }

    private func scheduleReload() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        guard enabled, reloadMinutes > 0 else { return }
        let timer = Timer(timeInterval: Double(reloadMinutes) * 60, repeats: true) { _ in
            MainActor.assumeIsolated { WebWallpaper.shared.surfaces.values.forEach { $0.web.reload() } }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        reloadTimer = timer
    }

    private func tearDown() {
        reloadTimer?.invalidate()
        reloadTimer = nil
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver) }
        screensObserver = nil
        for surface in surfaces.values {
            surface.web.stopLoading()
            surface.panel.orderOut(nil)
        }
        surfaces = [:]
        title = nil
    }

    /// The window numbers on screen now, for tests.
    var windowNumbers: [Int] { surfaces.values.map(\.panel.windowNumber) }

    // MARK: Navigation

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            status = nil
            title = webView.title
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { status = error.localizedDescription }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { status = error.localizedDescription }
    }
}

// MARK: - Chapter card

struct WebWallpaperCard: View {
    @ObservedObject private var web = WebWallpaper.shared
    @State private var typed = ""
    private let hue = DS.Spectrum.surfaces

    private var host: String { URL(string: web.address)?.host ?? web.address }

    var body: some View {
        HeroCard("Website Wallpaper",
                 pitch: web.status ?? web.title.map { "Showing “\($0)”." } ?? "Any web page as your desktop: a live map, a dashboard, an art piece.",
                 isOn: $web.enabled, hue: hue,
                 readout: web.reloadMinutes == 0 ? "Live" : "\(web.reloadMinutes) min",
                 readoutCaption: web.reloadMinutes == 0 ? "Never reloads" : "Reloads every",
                 preview: .overlay("web.wallpaper", "Website Wallpaper", isOn: web.enabled) { size in WebWallpaperPreview(size: size, address: web.address) }) {
            WebWallpaperPlate(host: host)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: 8) {
                    Image(systemName: "globe").foregroundStyle(DS.Ink.tertiary)
                    TextField("Web address or file path", text: $typed)
                        .textFieldStyle(.plain).font(.system(size: 12.5, weight: .medium))
                        .onSubmit { web.load(typed) }
                    Chip("Show") { web.load(typed) }.disabled(WebWallpaper.normalised(typed) == nil)
                }
                .padding(.leading, 12).padding(.trailing, 3).frame(height: 36)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                .onAppear { typed = web.address }
                .onChange(of: web.address) { _, address in typed = address }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.Space.s), GridItem(.flexible(), spacing: DS.Space.s)],
                          spacing: DS.Space.s) {
                    ForEach(WebWallpaperPreset.all) { preset in presetTile(preset) }
                }
                SettingRow(title: "Browse It", detail: "Clicks and scrolls reach the page, above your icons.", density: .compact) {
                    LuxSwitch(isOn: $web.interactive, label: "Browse It", tint: hue)
                }
                SettingRow(title: "Reload", density: .compact) {
                    Segments(selection: $web.reloadMinutes, options: [(0, "Never"), (5, "5 min"), (15, "15 min"), (60, "Hourly")])
                        .frame(width: 280)
                }
            }
        }
    }

    private func presetTile(_ preset: WebWallpaperPreset) -> some View {
        let chosen = web.address == preset.address
        return Button { typed = preset.address; web.load(preset.address) } label: {
            HStack(spacing: 8) {
                Image(systemName: preset.symbol).font(.system(size: 12, weight: .semibold)).frame(width: 16)
                    .foregroundStyle(chosen ? hue : DS.Ink.secondary)
                Text(preset.title).font(DS.Typo.rowTitle)
                    .foregroundStyle(chosen ? DS.Ink.primary : DS.Ink.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).frame(height: 34)
            .background(chosen ? hue.opacity(0.14) : DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .strokeBorder(chosen ? hue.opacity(0.7) : .clear, lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: DS.Radius.control))
        }
        .buttonStyle(Pressable(scale: 0.97))
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// A page on a desk, as a plate: wind lines over a deep map field with the site's name on it.
/// Drawn once at rest; the lines flow only while the pointer is on the plate.
private struct WebWallpaperPlate: View {
    let host: String

    var body: some View {
        HeroLife { live in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [Color(red: 0.03, green: 0.07, blue: 0.16), Color(red: 0.05, green: 0.2, blue: 0.3)],
                               startPoint: .top, endPoint: .bottom)
                HeroClock(live: live, rest: 12) { t in
                    Canvas { ctx, canvas in
                        for i in 0..<90 {
                            let y = Double(i % 12) / 12 * canvas.height + 8
                            let phase = Double(i) * 0.37 + t * 0.6
                            let x0 = (Double(i * 53 % 997) / 997 * canvas.width + t * 34).truncatingRemainder(dividingBy: canvas.width)
                            var path = Path()
                            path.move(to: CGPoint(x: x0, y: y + sin(phase) * 6))
                            path.addCurve(to: CGPoint(x: x0 + 54, y: y + sin(phase + 1) * 6),
                                          control1: CGPoint(x: x0 + 18, y: y + sin(phase + 0.4) * 11),
                                          control2: CGPoint(x: x0 + 36, y: y - sin(phase + 0.7) * 11))
                            ctx.stroke(path, with: .color(.white.opacity(0.1 + Double(i % 5) * 0.05)), lineWidth: 1)
                        }
                    }
                }
                Label(host, systemImage: "globe")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(.black.opacity(0.4), in: .capsule)
                    .padding(DS.Space.m)
            }
        }
    }
}

/// The stage's idea of a page on the desktop: a deep map-like field with the address on it.
struct WebWallpaperPreview: View {
    let size: CGSize
    let address: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.07, blue: 0.16), Color(red: 0.05, green: 0.2, blue: 0.3)],
                           startPoint: .top, endPoint: .bottom)
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                Canvas { ctx, canvas in
                    let t = context.date.timeIntervalSinceReferenceDate
                    for i in 0..<140 {
                        let y = Double(i % 14) / 14 * canvas.height + 10
                        let phase = Double(i) * 0.37 + t * 0.6
                        var path = Path()
                        let x0 = (Double(i * 53 % 997) / 997 * canvas.width + t * 40).truncatingRemainder(dividingBy: canvas.width)
                        path.move(to: CGPoint(x: x0, y: y + sin(phase) * 8))
                        path.addCurve(to: CGPoint(x: x0 + 60, y: y + sin(phase + 1) * 8),
                                      control1: CGPoint(x: x0 + 20, y: y + sin(phase + 0.4) * 14),
                                      control2: CGPoint(x: x0 + 40, y: y - sin(phase + 0.7) * 14))
                        ctx.stroke(path, with: .color(.white.opacity(0.12 + Double(i % 5) * 0.05)), lineWidth: 1)
                    }
                }
            }
            Label(URL(string: address)?.host ?? address, systemImage: "globe")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 12).frame(height: 28)
                .background(.black.opacity(0.4), in: .capsule)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, size.height * 0.08)
        }
        .frame(width: size.width, height: size.height)
    }
}
