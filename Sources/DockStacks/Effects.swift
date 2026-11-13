import AppKit
import ImageIO
import DockCore
import SwiftUI
import UniformTypeIdentifiers

/// A generated wallpaper's palette. Five colours, deep to light, curated from photographs and
/// print gradients rather than spun from a hue wheel. Display P3 values.
enum Hue: String, CaseIterable, Identifiable {
    case aurora, dusk, ocean, ember, mono, bloom, fjord, sahara, lagoon, iris, yours
    var id: String { rawValue }

    var title: String {
        switch self {
        case .aurora: "Aurora"
        case .dusk: "Big Sur Dusk"
        case .ocean: "Pacific"
        case .ember: "Ember"
        case .mono: "Graphite"
        case .bloom: "Peony"
        case .fjord: "Fjord"
        case .sahara: "Sahara"
        case .lagoon: "Lagoon"
        case .iris: "Iris"
        case .yours: "From Your Wallpaper"
        }
    }

    /// sRGB hex, converted to Display P3 on the way in.
    private var hex: [String] {
        switch self {
        case .aurora: ["05101F", "0E4A5E", "2FB58C", "6E5CF0", "D6F7F2"]
        case .dusk: ["1A1030", "54307E", "D5617F", "F7A072", "FFE6C4"]
        case .ocean: ["03121F", "0A3A66", "1580A8", "73C6E6", "E6F6FF"]
        case .ember: ["140604", "5E1C0C", "C2471A", "F2A33A", "FFE9BE"]
        case .mono: ["0C0D10", "26292F", "53585F", "9AA0A8", "E8EBEE"]
        case .bloom: ["2A1530", "86406E", "EE8FB1", "FBC7A8", "FFF3EA"]
        case .fjord: ["08130F", "1D3A2E", "4C7A5C", "A5C3A0", "EEF3E6"]
        case .sahara: ["24130A", "844820", "D68F4C", "F1C38E", "FFF1DD"]
        case .lagoon: ["031A1E", "076064", "1AA6A0", "8EE2D0", "F0FFF9"]
        case .iris: ["0A0A2B", "2D2A88", "6B5BE0", "B49DFF", "F3EFFF"]
        case .yours: ["101418", "2A3340", "5A6B80", "A0B0C0", "EEF2F6"]
        }
    }

    /// The five colours. From Your Wallpaper reads the colours sampled from the owner's wallpaper.
    @MainActor var colours: [SIMD3<Float>] {
        if self == .yours, let stops = LiveWallpaper.shared.wallpaperStops, stops.count == 4 {
            return stops + [stops[3] + (SIMD3<Float>(repeating: 1) - stops[3]) * 0.6]
        }
        return hex.map(Self.p3)
    }

    private static func p3(_ hex: String) -> SIMD3<Float> {
        let v = Int(hex, radix: 16) ?? 0
        let srgb = SIMD3<Float>(Float((v >> 16) & 255), Float((v >> 8) & 255), Float(v & 255)) / 255
        func lin(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        func enc(_ c: Float) -> Float { c <= 0.0031308 ? c * 12.92 : 1.055 * pow(max(c, 0), 1 / 2.4) - 0.055 }
        let l = SIMD3(lin(srgb.x), lin(srgb.y), lin(srgb.z))
        let p = SIMD3(0.8225 * l.x + 0.1774 * l.y, 0.0332 * l.x + 0.9669 * l.y, 0.0171 * l.x + 0.0724 * l.y + 0.9108 * l.z)
        return SIMD3(enc(p.x), enc(p.y), enc(p.z))
    }

    /// Nine colours for a 3 by 3 mesh at an hour: the fallback when Metal is missing, and the
    /// colours other features take an accent from.
    @MainActor func mesh(hour: Int) -> [Color] {
        let c = colours.map { LivingPalette.color($0) }
        let order = [1, 2, 3, 0, 3, 2, 0, 1, 4]
        let night = 1 - DayLight.daylight(hour: Double(hour))
        return order.map { c[$0].opacity(1) }.enumerated().map { index, colour in
            index == 4 ? colour : colour.atelierMix(with: .black, by: night * 0.35)
        }
    }

    static let points: [SIMD2<Float>] = [
        [0, 0], [0.5, 0], [1, 0],
        [0, 0.5], [0.42, 0.56], [1, 0.46],
        [0, 1], [0.6, 1], [1, 1],
    ]

    /// The uniforms the mesh wallpaper shader paints with.
    @MainActor func uniforms(hour: Double, seed: Float, grain: Double) -> LivingUniforms {
        var u = LivingUniforms()
        let c = colours
        u.palette0 = SIMD4(c[0], c[4].x)
        u.palette1 = SIMD4(c[1], c[4].y)
        u.palette2 = SIMD4(c[2], c[4].z)
        u.palette3 = SIMD4(c[3], 0)
        u.daylight = Float(DayLight.daylight(hour: hour))
        u.golden = Float(DayLight.golden(hour: hour))
        u.day = Float(hour / 24)
        u.seed = seed
        u.grain = Float(grain)
        return u
    }

    var defaultSeed: Float { Float((Hue.allCases.firstIndex(of: self) ?? 0) * 7) + 3.3 }
}

/// Renders the generated wallpapers: thumbnails for the app, full size for the desktop.
@MainActor
enum HueRenderer {
    private static var thumbnails: [String: CGImage] = [:]

    static func image(_ hue: Hue, hour: Double, seed: Float, grain: Double, width: Int, height: Int) -> CGImage? {
        LivingEngine.shared?.still(fragment: "meshWallpaperFragment", uniforms: hue.uniforms(hour: hour, seed: seed, grain: grain),
                                   width: width, height: height)
    }

    /// Small and cached. The key carries everything that changes the picture.
    static func thumbnail(_ hue: Hue, hour: Int, seed: Float? = nil) -> CGImage? {
        let seed = seed ?? hue.defaultSeed
        let colours = hue == .yours ? hue.colours.map { "\($0)" }.joined() : ""
        let key = "\(hue.rawValue)-\(hour)-\(seed)-\(colours)"
        if let found = thumbnails[key] { return found }
        guard let made = image(hue, hour: Double(hour), seed: seed, grain: 0, width: 480, height: 300) else { return nil }
        if thumbnails.count > 120 { thumbnails = [:] }
        thumbnails[key] = made
        return made
    }
}

/// A generated wallpaper at a small size, for cards and the stage. Same shader as the real one.
struct MeshCanvas: View {
    let hue: Hue
    let hour: Int
    var seed: Float? = nil

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image = HueRenderer.thumbnail(hue, hour: hour, seed: seed) {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    AtelierMesh(width: 3, height: 3, points: Hue.points, colors: hue.mesh(hour: hour))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }
}

/// Everything here floats over the system, is click-through, and goes with the app.
@MainActor
final class Effects: ObservableObject {
    static let shared = Effects()
    private let store = UserDefaults.standard

    @Published var skin: SkinPreset {
        didSet {
            guard skin != oldValue else { return }
            store.set(skin.rawValue, forKey: "skin")
            applySkin()
            if dockGlow { applyGlow() }
        }
    }
    @Published var rounded: Double { didSet { store.set(rounded, forKey: "rounded"); applyRounded() } }
    @Published var focus: Bool { didSet { store.set(focus, forKey: "focus"); applyFocus() } }
    @Published var focusDim: Double { didSet { store.set(focusDim, forKey: "focusDim"); focusPanels.forEach { $0.alphaValue = focusDim } } }
    @Published var clock: Bool { didSet { store.set(clock, forKey: "clock"); applyClock() } }
    @Published var shelf: Bool { didSet { store.set(shelf, forKey: "shelf"); Shelf.shared.setEnabled(shelf) } }
    @Published var pulse: Bool { didSet { store.set(pulse, forKey: "pulse"); applyPulse() } }
    @Published var ripples: Bool { didSet { store.set(ripples, forKey: "ripples"); applyRipples() } }
    @Published var dayLine: Bool { didSet { store.set(dayLine, forKey: "dayLine"); applyDayLine() } }
    @Published var dockGlow: Bool { didSet { store.set(dockGlow, forKey: "dockGlow"); applyGlow() } }
    @Published var widgets: Bool { didSet { store.set(widgets, forKey: "widgets"); applyWidgets() } }
    @Published var clockStyle: ClockStyle { didSet { store.set(clockStyle.rawValue, forKey: "clockStyle"); applyClock() } }
    /// Bumped after icon keys change, so the stage redraws from the real values.
    @Published var iconRevision = 0
    @Published var focusEnd: Date? { didSet { applyIsland() } }
    @Published var look: String? { didSet { store.set(look, forKey: "look") } }
    @Published var living: Hue? { didSet { store.set(living?.rawValue, forKey: "living"); applyLiving() } }
    /// Where the generated wallpaper's colour fields sit. Shuffle picks another.
    @Published var livingSeed: Double { didSet { store.set(livingSeed, forKey: "livingSeed"); repaintLiving() } }
    @Published var livingGrain: Double { didSet { store.set(livingGrain, forKey: "livingGrain"); repaintLiving() } }
    /// Follows the hour, or holds one look.
    @Published var livingCycle: DayCycle { didSet { store.set(livingCycle.rawValue, forKey: "livingCycle"); repaintLiving() } }

    private let pulseModel = PulseModel()
    private var pulsePanels: [NSPanel] = []
    private var pulseObserver: NSObjectProtocol?
    private var rippleMonitor: Any?
    private var linePanels: [NSPanel] = []
    private var glowPanels: [NSPanel] = []
    private var widgetPanels: [NSPanel] = []
    private var islandPanels: [NSPanel] = []
    private var islandTimer: Timer?
    private var roundedPanels: [NSPanel] = []
    private var focusPanels: [NSPanel] = []
    private var clockPanels: [NSPanel] = []
    private var focusTimer: Timer?
    private var hourTimer: Timer?

    private init() {
        skin = SkinPreset(rawValue: store.string(forKey: "skin") ?? "") ?? .none
        rounded = store.double(forKey: "rounded")
        focus = store.bool(forKey: "focus")
        focusDim = store.object(forKey: "focusDim") as? Double ?? 0.6
        clock = store.bool(forKey: "clock")
        shelf = store.bool(forKey: "shelf")
        living = Hue(rawValue: store.string(forKey: "living") ?? "")
        livingSeed = store.object(forKey: "livingSeed") as? Double ?? 0
        livingGrain = store.object(forKey: "livingGrain") as? Double ?? 0.15
        livingCycle = DayCycle(rawValue: store.string(forKey: "livingCycle") ?? "") ?? .clock
        pulse = store.bool(forKey: "pulse")
        ripples = store.bool(forKey: "ripples")
        dayLine = store.bool(forKey: "dayLine")
        dockGlow = store.bool(forKey: "dockGlow")
        widgets = store.bool(forKey: "widgets")
        clockStyle = ClockStyle(rawValue: store.string(forKey: "clockStyle") ?? "") ?? .thin
        look = store.string(forKey: "look")
    }

    func startFocus(minutes: Double) {
        focusEnd = Date().addingTimeInterval(minutes * 60)
        focusTotal = minutes * 60
        applyIsland()
    }

    private(set) var focusTotal: TimeInterval = 1500

    private func applyIsland() {
        islandTimer?.invalidate()
        clear(&islandPanels)
        guard let end = focusEnd, let screen = NSScreen.main else { return }
        let height = Self.menuBar(screen).bar.height
        let notch = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX + 100
        let frame = NSRect(x: notch + 6, y: screen.frame.maxY - height + 2, width: 104, height: height - 4)
        islandPanels.append(panel(frame, level: .statusBar, content: FocusIslandView(end: end, total: focusTotal)))
        islandTimer = Timer.scheduledTimer(withTimeInterval: end.timeIntervalSinceNow, repeats: false) { _ in
            MainActor.assumeIsolated {
                Effects.shared.focusEnd = nil
                Effects.shared.flash(.white)
                SoundPackRuntime.timerDone()
            }
        }
    }

    private func applyDayLine() {
        clear(&linePanels)
        guard dayLine else { return }
        for screen in NSScreen.screens {
            let bar = Self.menuBar(screen).bar
            let frame = NSRect(x: bar.minX, y: bar.minY - 2, width: bar.width, height: 2)
            linePanels.append(panel(frame, level: .statusBar, content: DayLine()))
        }
    }

    private func applyGlow() {
        clear(&glowPanels)
        // The Dock's own display, not the key window's, and only a Dock along the bottom: the
        // glow is shaped to pool under it. The card says so when the Dock is at a side or hidden.
        guard dockGlow, let (screen, edge) = DesktopAvailability.dock(), edge == .bottom else { return }
        let dockHeight = screen.visibleFrame.minY - screen.frame.minY
        let frame = NSRect(x: screen.frame.midX - 560, y: screen.frame.minY - 20, width: 1120, height: dockHeight + 90)
        let level = NSWindow.Level(rawValue: NSWindow.Level.dock.rawValue - 1)
        let colors = [.none, .notchless, .glass, .frosted].contains(skin) ? SkinPreset.aurora.colors : skin.colors
        glowPanels.append(panel(frame, level: level, content: DockGlowView(colors: colors)))
    }

    private func applyWidgets() {
        clear(&widgetPanels)
        guard widgets else { return }
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        for screen in NSScreen.screens {
            widgetPanels.append(panel(screen.visibleFrame, level: level, content: DesktopVitals()))
        }
    }

    private func applyRipples() {
        if let rippleMonitor { NSEvent.removeMonitor(rippleMonitor) }
        rippleMonitor = nil
        guard ripples else { return }
        rippleMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
            MainActor.assumeIsolated { Effects.shared.ripple() }
        }
    }

    private func ripple() {
        let point = NSEvent.mouseLocation, size = 96.0
        let frame = NSRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        let shot = panel(frame, level: .screenSaver, content: RippleView())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { shot.orderOut(nil) }
    }

    private func applyPulse() {
        if let pulseObserver { NSWorkspace.shared.notificationCenter.removeObserver(pulseObserver) }
        pulseObserver = nil
        clear(&pulsePanels)
        guard pulse else { return }
        for screen in NSScreen.screens {
            pulsePanels.append(panel(screen.frame, level: .screenSaver, content: PulseHost(model: pulseModel)))
        }
        pulseObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let path = app?.bundleURL?.path
            MainActor.assumeIsolated {
                guard let path else { return }
                Effects.shared.flash(Effects.dominant(of: NSWorkspace.shared.icon(forFile: path)))
            }
        }
    }

    func flash(_ color: Color) {
        pulseModel.color = color
        pulseModel.shown = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { self.pulseModel.shown = false }
    }

    /// The most saturated colour in a tiny render of the icon.
    static func dominant(of image: NSImage) -> Color {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 12, pixelsHigh: 12, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return .white }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 12, height: 12))
        NSGraphicsContext.restoreGraphicsState()
        var best = NSColor.white, score = 0.0
        for x in 0..<12 {
            for y in 0..<12 {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.alphaComponent > 0.6 else { continue }
                let value = color.saturationComponent * color.brightnessComponent
                if value > score { score = value; best = color }
            }
        }
        return Color(nsColor: best)
    }

    /// Reshapes the whole Mac. Icons need a Dock restart, so that part runs off the main thread.
    func apply(_ look: Look) {
        self.look = look.name
        skin = look.skin
        // A Look with a clock adds or restyles one; a Look without leaves the owner's clocks alone.
        if let style = look.clock { WidgetBoard.shared.desktopClockStyle = style }
        dockGlow = look.glow
        living = look.hue
        let theme = look.theme, tint = look.tint, rgb = look.rgb
        Task.detached {
            try? IconTint.write(theme: theme, tint: tint, rgb: rgb)
            await MainActor.run { Effects.shared.iconRevision += 1 }
        }
    }

    private var started = false

    func start() {
        // The skin keeps its panels across screen changes; it listens for them itself.
        if !started { applySkin() }
        // Rounded Screen had two homes; Rounded Screen Corners in Display & Appearance is the one
        // left. A radius set here carries over once, so corners someone turned on stay round.
        if rounded > 0.5 {
            let corners = ScreenCorners.shared
            if !corners.enabled {
                corners.radius = min(max(rounded, 4), 28)
                corners.enabled = true
            }
            rounded = 0
        }
        applyRounded(); applyFocus(); applyClock()
        applyPulse(); applyRipples(); applyDayLine(); applyGlow(); applyWidgets()
        Shelf.shared.setEnabled(shelf)
        if living != nil { applyLiving() }
        // Desktop+ rebuilds its panels with ours on a screen change.
        DesktopPlus.shared.start()
        // Once only: this runs again on every screen change, and each run used to add another observer.
        guard !started else { return }
        started = true
        HotCorners.shared.start()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { Effects.shared.start() } }
    }

    private func panel(_ frame: NSRect, level: NSWindow.Level, content: some View) -> NSPanel {
        let panel = FloatingPanel(frame: frame)
        panel.level = level
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.contentView = NSHostingView(rootView: content.frame(width: frame.width, height: frame.height))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }

    private func clear(_ panels: inout [NSPanel]) {
        panels.forEach { $0.orderOut(nil) }
        panels = []
    }

    // MARK: Menu bar skin

    /// The real menu bar on a display. See MenuBarGeometry for why it is not the safe area.
    static func menuBar(_ screen: NSScreen) -> MenuBarGeometry {
        MenuBarGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
                        leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    /// The skin keeps its own panels and changes them in place.
    private func applySkin() { MenuBarSkin.shared.apply() }

    // MARK: Rounded screen

    private func applyRounded() {
        clear(&roundedPanels)
        guard rounded > 0 else { return }
        let radius = rounded
        for screen in NSScreen.screens {
            roundedPanels.append(panel(screen.frame, level: .screenSaver, content: Canvas { context, size in
                var path = Path(CGRect(origin: .zero, size: size))
                path.addRoundedRect(in: CGRect(origin: .zero, size: size),
                                    cornerSize: CGSize(width: radius, height: radius), style: .continuous)
                context.fill(path, with: .color(.black), style: FillStyle(eoFill: true))
            }))
        }
    }

    // MARK: Focus light

    /// One dark panel per screen, kept directly under the front window. No Accessibility needed.
    private func applyFocus() {
        focusTimer?.invalidate()
        clear(&focusPanels)
        guard focus else { return }
        for screen in NSScreen.screens {
            let panel = panel(screen.frame, level: .normal, content: Color.black)
            panel.alphaValue = focusDim
            focusPanels.append(panel)
        }
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { Effects.shared.trackFront() }
        }
    }

    private func trackFront() {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return }
        let window = list.first {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == front && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        guard let number = window?[kCGWindowNumber as String] as? Int else { return }
        focusPanels.forEach { $0.order(.below, relativeTo: number) }
    }

    // MARK: Desktop clock

    private func applyClock() {
        clear(&clockPanels)
        guard clock else { return }
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        for screen in NSScreen.screens {
            clockPanels.append(panel(screen.visibleFrame, level: level, content: DesktopClock(style: clockStyle)))
        }
    }

    // MARK: Living wallpaper

    @Published var notice: String?
    private var paintedKey = ""
    private var slot = false

    private var generatedFolder: URL { Support.root.appendingPathComponent("Wallpapers", isDirectory: true) }

    /// Before Atelier sets a generated wallpaper for the first time, it writes down the owner's
    /// own: the one in the wallpaper store, and each display's. They are never removed, so the way
    /// back always exists. A wallpaper this app cannot read is one it could not put back, so it
    /// never replaces it.
    func keepOriginalWallpaper() -> Bool {
        // While the owner's own wallpaper is showing (nothing of Atelier's is on the desktop), it
        // is the one to come back to: written down afresh, since they may have changed it since.
        let ownShowing = !store.bool(forKey: "livingActive")
        var displays = store.dictionary(forKey: "originalWallpapers") as? [String: String] ?? [:]
        var options = store.dictionary(forKey: "originalWallpaperOptions") as? [String: [String: Any]] ?? [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID else { continue }
            let key = LiveWallpaper.uuid(of: id)
            guard displays[key] == nil || ownShowing, let url = NSWorkspace.shared.desktopImageURL(for: screen),
                  !url.path.hasPrefix(generatedFolder.path), FileManager.default.isReadableFile(atPath: url.path) else { continue }
            displays[key] = url.absoluteString
            options[key] = Self.plistOptions(NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:])
        }
        store.set(displays, forKey: "originalWallpapers")
        store.set(options, forKey: "originalWallpaperOptions")
        if ownShowing { store.removeObject(forKey: "originalWallpaper") }
        if let kept = store.url(forKey: "originalWallpaper"), FileManager.default.isReadableFile(atPath: kept.path) { return true }
        let url = Wallpaper.url()
        switch DesktopCompat.originalWallpaperProblem(foundFile: url != nil, readable: url.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false) {
        case .unreadable:
            notice = "Your current wallpaper is in a folder Atelier can’t read, so it couldn’t be restored later. Move it out of Downloads, or allow Downloads access in System Settings, then try again."
            return false
        case .systemWallpaper:
            // Aerials, dynamic and built-in wallpapers and colours are not files that can be set
            // back. Nothing is replaced until the owner picks a picture of their own first.
            notice = "Your wallpaper is one of Apple’s Aerial, dynamic or colour wallpapers, which Atelier can’t put back by itself. Choose a picture in System Settings, Wallpaper, then try again."
            return false
        case .none:
            break
        }
        guard let url else { return false }
        store.set(url, forKey: "originalWallpaper")
        return true
    }

    /// Desktop picture options as property-list values: scaling, clipping, and the fill colour as sRGB.
    private static func plistOptions(_ options: [NSWorkspace.DesktopImageOptionKey: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let scaling = options[.imageScaling] as? NSNumber { result["scaling"] = scaling.intValue }
        if let clipping = options[.allowClipping] as? NSNumber { result["clipping"] = clipping.boolValue }
        if let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB) {
            result["fill"] = [fill.redComponent, fill.greenComponent, fill.blueComponent, fill.alphaComponent].map(Double.init)
        }
        return result
    }

    private static func workspaceOptions(_ saved: [String: Any]) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        var options: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let scaling = saved["scaling"] as? Int { options[.imageScaling] = scaling }
        if let clipping = saved["clipping"] as? Bool { options[.allowClipping] = clipping }
        if let fill = saved["fill"] as? [Double], fill.count == 4 {
            options[.fillColor] = NSColor(srgbRed: fill[0], green: fill[1], blue: fill[2], alpha: fill[3])
        }
        return options
    }

    /// A downloaded photo as the wallpaper on every display. The owner's own is written down
    /// first, so Restore Original brings it back exactly like after a generated one.
    @discardableResult
    func setPhotoWallpaper(_ url: URL) -> Bool {
        if living != nil { living = nil }
        guard keepOriginalWallpaper() else { return false }
        var failed: String?
        for screen in NSScreen.screens {
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]) }
            catch { failed = error.localizedDescription }
        }
        if let failed { notice = "Couldn’t set the wallpaper: \(failed)"; return false }
        store.set(true, forKey: "livingActive")
        refreshWallpaperViews()
        return true
    }

    /// The stage, the Studio room and palettes read the wallpaper: tell them it changed. The
    /// wallpaper store is written a moment after the call, so look again shortly.
    func refreshWallpaperViews() {
        for delay in [0.0, 1.2] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                Wallpaper.invalidate()
                Effects.shared.objectWillChange.send()
            }
        }
    }

    /// A picture Atelier set (a photo from the library or a generated one) is on the desktop in
    /// place of the owner's own.
    var replacedWallpaper: Bool { living != nil || store.bool(forKey: "livingActive") }

    /// The owner's own wallpaper as Atelier wrote it down, for showing what Restore brings back.
    var originalWallpaperURL: URL? { store.url(forKey: "originalWallpaper") }

    /// Puts the owner's own wallpaper back on every display Atelier changed. Safe to call any time:
    /// with nothing changed it does nothing. No file is deleted, generated ones included.
    func restoreOriginalWallpaper() {
        if living != nil { living = nil; return }   // didSet comes back here
        hourTimer?.invalidate()
        paintedKey = ""
        guard store.bool(forKey: "livingActive") else { return }
        let displays = store.dictionary(forKey: "originalWallpapers") as? [String: String] ?? [:]
        let main = store.url(forKey: "originalWallpaper")
        let kept = store.dictionary(forKey: "originalWallpaperOptions") as? [String: [String: Any]] ?? [:]
        var failed: String?
        for (index, screen) in NSScreen.screens.enumerated() {
            let own = screen.displayID.flatMap { displays[LiveWallpaper.uuid(of: $0)] }.flatMap(URL.init(string:))
            // The store's record is the reliable one for the main display; others use their own.
            let pick = index == 0 ? (main ?? own) : (own.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil } ?? main)
            guard let url = pick else { continue }
            // Scaling, clipping and fill colour as they were, so a fitted picture is not filled.
            let saved = screen.displayID.flatMap { kept[LiveWallpaper.uuid(of: $0)] } ?? [:]
            do { try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: Self.workspaceOptions(saved)) }
            catch { failed = error.localizedDescription }
        }
        if let failed {
            notice = "Couldn’t restore your wallpaper: \(failed)"
        } else {
            notice = nil
            store.set(false, forKey: "livingActive")
            refreshWallpaperViews()
        }
    }

    private func applyLiving() {
        hourTimer?.invalidate()
        guard living != nil else {
            restoreOriginalWallpaper()
            return
        }
        guard keepOriginalWallpaper() else { living = nil; return }
        if living == .yours, LiveWallpaper.shared.wallpaperStops == nil { LiveWallpaper.shared.sampleWallpaper() }
        paintedKey = ""
        paintLiving()
        hourTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Effects.shared.paintLiving() }
        }
    }

    private func repaintLiving() {
        guard living != nil else { return }
        paintedKey = ""
        paintLiving()
    }

    func shuffleLiving() { livingSeed = Double(Int.random(in: 1...999)) }

    /// The hour the picture shows: the real one, or the held look.
    private var livingHour: Double { livingCycle.heldHour ?? Double(Calendar.current.component(.hour, from: Date())) }

    /// Paints at each display's full native resolution (5K and up), then encodes off the main
    /// thread. Two files per display, used in turn: the wallpaper agent caches by path.
    private func paintLiving() {
        guard let hue = living else { return }
        let hour = livingHour
        let key = "\(hue.rawValue)-\(hour)-\(livingSeed)-\(livingGrain)-\(hue == .yours ? hue.colours.description : "")"
        guard key != paintedKey else { return }
        paintedKey = key
        let folder = generatedFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        slot.toggle()
        let suffix = slot ? "a" : "b"
        let format = Self.imageFormat
        for (index, screen) in NSScreen.screens.enumerated() {
            let (width, height) = DesktopCompat.wallpaperPixels(width: screen.frame.width, height: screen.frame.height, scale: screen.backingScaleFactor)
            let seed = hue.defaultSeed + Float(livingSeed) + Float(index) * 0.37
            guard let image = HueRenderer.image(hue, hour: hour, seed: seed, grain: livingGrain, width: width, height: height) else {
                notice = "Couldn’t paint the wallpaper: the shaders are missing from this build."
                continue
            }
            let url = folder.appendingPathComponent("living-\(index)-\(suffix).\(format.rawValue)")
            let display = screen.displayID
            Task.detached(priority: .utility) {
                guard Self.write(image, to: url, as: format) else { return }
                await MainActor.run {
                    guard Effects.shared.living != nil,
                          let target = NSScreen.screens.first(where: { $0.displayID == display }) else { return }
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(url, for: target)
                        UserDefaults.standard.set(true, forKey: "livingActive")
                    } catch {
                        Effects.shared.notice = "Couldn’t set the wallpaper: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    /// HEIC where this Mac can encode it, PNG where it cannot (older Intel Macs). Asked once.
    private static let imageFormat: DesktopCompat.ImageFormat = {
        let types = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        return DesktopCompat.wallpaperFormat(writable: types)
    }()

    /// HEIC at high quality keeps the dither that stops banding, at a fraction of a PNG's size.
    nonisolated static func write(_ image: CGImage, to url: URL, as format: DesktopCompat.ImageFormat = .heic) -> Bool {
        let type = (format == .heic ? UTType.heic : UTType.png).identifier as CFString
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { return false }
        let options: [CFString: Any] = format == .heic ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }
}

struct DesktopClock: View {
    var style = ClockStyle.thin

    @ViewBuilder private func face(_ date: Date) -> some View {
        let time = Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        switch style {
        case .thin: time.font(.system(size: 148, weight: .thin)).tracking(-5).monospacedDigit()
        case .bold: time.font(.system(size: 136, weight: .heavy)).tracking(-6).monospacedDigit()
        case .mono: time.font(.system(size: 124, weight: .light, design: .monospaced)).tracking(-8)
        case .words:
            Text(WordClock.text(date).capitalized)
                .font(.system(size: 76, weight: .semibold)).tracking(-2.4)
                .frame(maxWidth: 800, alignment: .leading).lineSpacing(-6)
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: -6) {
                Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.leading, 8).padding(.bottom, style == .words ? 12 : 0)
                face(context.date).foregroundStyle(.white.opacity(0.92))
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
            .padding(54)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

struct PulseHost: View {
    @ObservedObject var model: PulseModel
    var body: some View { EdgeGlow(color: model.color, shown: model.shown) }
}

// MARK: - Notch Shelf

@MainActor
final class ShelfModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var open = false
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 10) {
            if model.files.isEmpty {
                Image(systemName: "tray.and.arrow.down.fill")
                Text("Drop to keep").font(.system(size: 13, weight: .medium))
            }
            ForEach(model.files, id: \.self) { url in
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable().frame(width: 40, height: 40)
                    .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                    .onTapGesture { NSWorkspace.shared.open(url) }
                    .help(url.lastPathComponent)
            }
            if !model.files.isEmpty {
                Button { model.files = [] } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                        .frame(width: 30, height: 30).contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Clear shelf")
            }
        }
        .padding(.horizontal, 20).frame(height: 66)
        .atelierGlass(.regular, in: .capsule)
        .scaleEffect(model.open ? (targeted ? 1.05 : 1) : 0.8, anchor: .top)
        .opacity(model.open ? 1 : 0)
        .animation(DS.Motion.settle, value: model.open)
        .animation(DS.Motion.touch, value: targeted)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .dropDestination(for: URL.self) { urls, _ in
            model.files += urls.filter { !model.files.contains($0) }
            return true
        } isTargeted: { targeted = $0 }
    }
}

/// Appears under the notch while something is being dragged near it.
@MainActor
final class Shelf {
    static let shared = Shelf()
    private let model = ShelfModel()
    private var panel: FloatingPanel?
    private var timer: Timer?

    func setEnabled(_ on: Bool) {
        timer?.invalidate()
        timer = nil
        guard on else { panel?.orderOut(nil); model.open = false; return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { _ in
            MainActor.assumeIsolated { Shelf.shared.tick() }
        }
    }

    private func tick() {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) else { return }
        let size = NSSize(width: 620, height: 120)
        let top = Effects.menuBar(screen).bar.minY
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height - 6, width: size.width, height: size.height)
        let mouse = NSEvent.mouseLocation
        let dragging = NSEvent.pressedMouseButtons & 1 == 1
        let near = abs(mouse.x - screen.frame.midX) < 340 && mouse.y > top - 180
        let inside = frame.insetBy(dx: -30, dy: -30).contains(mouse)
        let show = (dragging && near) || (!model.files.isEmpty && (inside || mouse.y > top - 4 && abs(mouse.x - screen.frame.midX) < 120))
        guard show != model.open else { return }
        if show {
            let panel = self.panel ?? make(frame)
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            model.open = true
        } else {
            model.open = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self, !self.model.open else { return }
                self.panel?.orderOut(nil)
            }
        }
    }

    private func make(_ frame: NSRect) -> FloatingPanel {
        let panel = FloatingPanel(frame: frame)
        panel.contentView = NSHostingView(rootView: ShelfView(model: model))
        self.panel = panel
        return panel
    }
}

// MARK: - Clipboard

/// Off by default. Text only, in memory only, gone when the app quits.
@MainActor
final class ClipboardHistory {
    static let shared = ClipboardHistory()
    private(set) var items: [String] = []
    private var timer: Timer?
    private var lastChange = NSPasteboard.general.changeCount

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "clipboard") }
        set { UserDefaults.standard.set(newValue, forKey: "clipboard"); apply() }
    }

    func apply() {
        timer?.invalidate()
        timer = nil
        guard enabled else { items = []; return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { ClipboardHistory.shared.poll() }
        }
    }

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != lastChange else { return }
        lastChange = board.changeCount
        // The same privacy rule as the Clipboard widget: concealed, transient and generated copies are skipped.
        guard let text = ClipboardPrivacy.keptText(types: board.types?.map(\.rawValue),
                                                   text: board.string(forType: .string)) else { return }
        items.removeAll { $0 == text }
        items.insert(text, at: 0)
        items = Array(items.prefix(30))
    }
}

// Calculator: DockCore/Calculator.swift, a parser of its own. NSExpression aborted on bad input.

// MARK: - Unique effects

enum ClockStyle: String, CaseIterable, Identifiable {
    case thin, bold, mono, words
    var id: String { rawValue }
    var title: String { rawValue == "words" ? "Word Clock" : rawValue.capitalized }
}

enum WordClock {
    static func text(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        var hour = parts.hour ?? 0
        let minute = Int((Double(parts.minute ?? 0) / 5).rounded()) * 5
        let names = ["twelve", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven"]
        func name(_ h: Int) -> String { names[((h % 12) + 12) % 12] }
        switch minute {
        case 0, 60:
            if minute == 60 { hour += 1 }
            return "\(name(hour)) o’clock"
        case 15: return "quarter past \(name(hour))"
        case 30: return "half past \(name(hour))"
        case 45: return "quarter to \(name(hour + 1))"
        case 5, 10, 20, 25: return "\(number(minute)) past \(name(hour))"
        default: return "\(number(60 - minute)) to \(name(hour + 1))"
        }
    }

    private static func number(_ value: Int) -> String {
        [5: "five", 10: "ten", 20: "twenty", 25: "twenty five"][value] ?? "\(value)"
    }
}

/// The screen edge lights up in the colour of the app you just switched to.
struct EdgeGlow: View {
    let color: Color
    let shown: Bool

    var body: some View {
        Rectangle()
            .strokeBorder(color, lineWidth: 44)
            .blur(radius: 34)
            .opacity(shown ? 0.95 : 0)
            .animation(shown ? .easeOut(duration: 0.14) : .easeIn(duration: 0.75), value: shown)
    }
}

@MainActor
final class PulseModel: ObservableObject {
    @Published var color = Color.white
    @Published var shown = false
}

struct RippleView: View {
    @State private var go = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2.5)
            Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5).scaleEffect(0.62)
        }
        .scaleEffect(go ? 1 : 0.12)
        .opacity(go ? 0 : 1)
        .onAppear { withAnimation(.easeOut(duration: 0.55)) { go = true } }
    }
}

struct DayLine: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: context.date)
            let fraction = (Double(parts.hour ?? 0) * 60 + Double(parts.minute ?? 0)) / 1440
            GeometryReader { geometry in
                LinearGradient(colors: [.cyan, .blue, .purple, .pink, .orange], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width)
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * fraction) }
            }
        }
    }
}

struct DockGlowView: View {
    let colors: [Color]
    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
            .blur(radius: 30)
            .opacity(0.85)
            .padding(.horizontal, 24)
            .padding(.vertical, 30)
    }
}

struct FocusIslandView: View {
    let end: Date
    let total: TimeInterval

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, end.timeIntervalSince(context.date))
            HStack(spacing: 8) {
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: left / total)
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                Text(Duration.seconds(left), format: .time(pattern: .minuteSecond))
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black, in: .capsule)
        }
    }
}

struct DesktopVitals: View {
    @StateObject private var vitals = Vitals()
    var body: some View {
        HStack(spacing: 22) {
            Ring(title: "Memory", value: vitals.memory, tint: .white)
            Ring(title: "Disk", value: vitals.disk, tint: .white)
            if let battery = vitals.battery { Ring(title: "Battery", value: battery, tint: .white) }
        }
        .scaleEffect(0.8, anchor: .bottomTrailing)
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .onAppear { vitals.start() }
    }
}

struct Look: Identifiable {
    let name: String
    let skin: SkinPreset
    let hue: Hue?
    let theme: String?
    let tint: String?
    let rgb: String?
    let clock: ClockStyle?
    let glow: Bool
    var id: String { name }

    static let all = [
        Look(name: "Classic", skin: .none, hue: nil, theme: nil, tint: nil, rgb: nil, clock: nil, glow: false),
        Look(name: "Midnight", skin: .notchless, hue: .mono, theme: "ClearDark", tint: nil, rgb: nil, clock: .thin, glow: false),
        Look(name: "Aurora", skin: .aurora, hue: .aurora, theme: "TintedDark", tint: "Other", rgb: "0.100000 0.850000 0.750000 1.000000", clock: .thin, glow: true),
        Look(name: "Ember", skin: .sunset, hue: .ember, theme: "TintedDark", tint: "Orange", rgb: nil, clock: .bold, glow: true),
        Look(name: "Ocean", skin: .ocean, hue: .ocean, theme: "TintedDark", tint: "Blue", rgb: nil, clock: .words, glow: true),
        Look(name: "Dusk", skin: .graphite, hue: .dusk, theme: "TintedDark", tint: "Purple", rgb: nil, clock: .mono, glow: false),
    ]

    /// The colour the replica uses for this look's tinted icons.
    var tintColor: Color? {
        guard theme?.hasPrefix("Tinted") == true else { return nil }
        return IconTint.color(tint: tint, rgb: rgb)
    }
    var clear: Bool { theme?.hasPrefix("Clear") == true }
}

enum IconTint {
    static func color(tint: String?, rgb: String?) -> Color {
        if tint == "Other", let rgb {
            let v = rgb.split(separator: " ").compactMap { Double($0) }
            if v.count >= 3 { return Color(red: v[0], green: v[1], blue: v[2]) }
        }
        return ["Blue": Color.blue, "Purple": .purple, "Pink": .pink, "Orange": .orange,
                "Yellow": .yellow, "Green": .green, "Graphite": .gray][tint ?? ""] ?? .purple
    }

    /// Icon keys take effect after a Dock restart.
    nonisolated static func write(theme: String?, tint: String?, rgb: String?) throws {
        // Clear and Tinted icon styles exist from macOS 26; earlier releases would misread them.
        guard PersonalAvailability.themeIconStyleSupported("tinted") || theme == nil else { return }
        let domain = "NSGlobalDomain"
        let values = ["AppleIconAppearanceTheme": theme, "AppleIconAppearanceTintColor": tint, "AppleIconAppearanceCustomTintColor": rgb]
        for (key, value) in values {
            if let value { try Prefs.write(key, type: "string", value: value, domain: domain) }
            else if Prefs.current(key, domain: domain) != nil { try Prefs.delete(key, domain: domain) }
        }
        Prefs.restart("Dock")
    }
}
