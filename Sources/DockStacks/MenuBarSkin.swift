import AppKit
import CoreImage
import DockCore
import SwiftUI

// MARK: - Skins

/// A look painted behind the real menu bar. The raw values of the first six are stored by
/// older builds and by Looks, so they stay.
enum SkinPreset: String, CaseIterable, Identifiable {
    case none, glass, frosted, wallpaper, aurora, notchless, graphite, sunset, ocean, midnight, solid
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "Off"
        case .glass: "Liquid Glass"
        case .frosted: "Frosted"
        case .wallpaper: "Wallpaper Tint"
        case .aurora: "Aurora"
        case .notchless: "No Notch"
        case .graphite: "Graphite"
        case .sunset: "Sunset"
        case .ocean: "Ocean"
        case .midnight: "Midnight"
        case .solid: "Solid Colour"
        }
    }

    var detail: String {
        switch self {
        case .none: "The menu bar as macOS draws it."
        case .glass: "Apple's Liquid Glass, tinted with your colour."
        case .frosted: "Your wallpaper, frosted, exactly behind the bar."
        case .wallpaper: "A soft gradient of the colours along the top of your wallpaper."
        case .aurora: "Slow light drifting along the bar."
        case .notchless: "Pure black, so the notch disappears into the bar."
        case .graphite: "Deep grey with a fine highlight, like anodised metal."
        case .sunset: "Peach into rose into dusk violet."
        case .ocean: "Deep navy into teal."
        case .midnight: "Near black with an indigo glow."
        case .solid: "One colour of your choosing."
        }
    }

    /// Stops for the gradient skins, and a summary of the others. Other features (the dock glow,
    /// Own Dock's accent) read these too.
    @MainActor var colors: [Color] {
        switch self {
        case .none: [.clear]
        case .notchless: [.black]
        case .glass: [Color(red: 0.62, green: 0.70, blue: 0.86), Color(red: 0.78, green: 0.82, blue: 0.92)]
        case .frosted, .wallpaper: [Color(red: 0.36, green: 0.40, blue: 0.52), Color(red: 0.52, green: 0.50, blue: 0.62)]
        case .sunset: [Color(red: 0.96, green: 0.62, blue: 0.48), Color(red: 0.88, green: 0.44, blue: 0.54), Color(red: 0.44, green: 0.30, blue: 0.62)]
        case .ocean: [Color(red: 0.03, green: 0.10, blue: 0.24), Color(red: 0.04, green: 0.30, blue: 0.42), Color(red: 0.08, green: 0.46, blue: 0.50)]
        case .aurora: [Color(red: 0.03, green: 0.10, blue: 0.16), Color(red: 0.10, green: 0.62, blue: 0.52), Color(red: 0.40, green: 0.30, blue: 0.80)]
        case .graphite: [Color(white: 0.11), Color(white: 0.17), Color(white: 0.11)]
        case .midnight: [Color(red: 0.02, green: 0.02, blue: 0.06), Color(red: 0.10, green: 0.08, blue: 0.26), Color(red: 0.02, green: 0.02, blue: 0.06)]
        case .solid: [MenuBarSkin.shared.tint, MenuBarSkin.shared.tint]
        }
    }

    /// Roughly how light the skin is, 0 to 1, for keeping the menu bar's text readable on it.
    @MainActor var luminance: Double {
        switch self {
        case .none, .glass: return 0.5
        case .frosted, .wallpaper: return MenuBarSkin.shared.wallpaperLuminance
        case .solid: return MenuBarSkin.luminance(of: MenuBarSkin.shared.tint)
        default:
            let values = colors.map(MenuBarSkin.luminance(of:))
            return values.reduce(0, +) / Double(max(values.count, 1))
        }
    }
}

enum SkinEdge: String, CaseIterable, Identifiable {
    // The Day Line lives in one place, Effects' own (Menu Bar › Day Line), not as an edge too.
    case none, hairline, shadow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "None"
        case .hairline: "Line"
        case .shadow: "Shadow"
        }
    }
}

/// Which colour macOS is using for the menu bar's text. macOS picks it from the wallpaper and the
/// appearance; nothing outside macOS can set it, so the skin adapts to it instead.
enum MenuTextTone: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "Auto"
        case .light: "White Text"
        case .dark: "Black Text"
        }
    }
}

/// What one display's skin draws right now. The panel keeps one of these and only its values
/// change, so a change cross-fades instead of rebuilding the window.
@MainActor
final class SkinScreen: ObservableObject {
    @Published var preset = SkinPreset.none
    @Published var size = CGSize(width: 1, height: 24)
    @Published var notch: CGRect?
    @Published var shadowRoom: CGFloat = 0
}

/// One click-through panel per menu bar, directly below the bar in the window order and exactly
/// on top of it on screen.
final class SkinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit keeps windows out of the menu bar: on ordering front it moves a frame that overlaps
    /// the bar down until it sits just below it. That is the "skin below the bar" bug. The skin's
    /// whole purpose is to be in that strip, so its frame is taken as given.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    convenience init(frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // The window server's Menubar window is at kCGMainMenuWindowLevel (24). One below it is
        // behind the bar's text and above everything an app can draw in that strip.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue - 1)
        // Every Space, still while Spaces slide, never in a full-screen Space (no
        // .fullScreenAuxiliary): there the bar is hidden and the skin would cover the app.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
    }
}

// MARK: - Model

@MainActor
final class MenuBarSkin: ObservableObject {
    static let shared = MenuBarSkin()
    private let store = UserDefaults.standard

    /// How strongly the skin covers what is behind it, 0.3 to 1.
    @Published var strength: Double { didSet { store.set(strength, forKey: "skinStrength") } }
    @Published var floating: Bool { didSet { store.set(floating, forKey: "skinFloating"); apply() } }
    /// Rounds the bar's lower corners, or the floating bar's ends.
    @Published var radius: Double { didSet { store.set(radius, forKey: "skinRadius") } }
    @Published var edge: SkinEdge { didSet { store.set(edge.rawValue, forKey: "skinEdge"); apply() } }
    @Published var notchBlend: Bool { didSet { store.set(notchBlend, forKey: "skinNotchBlend") } }
    @Published var motion: Bool { didSet { store.set(motion, forKey: "skinMotion") } }
    @Published var legible: Bool { didSet { store.set(legible, forKey: "skinLegible") } }
    @Published var textTone: MenuTextTone { didSet { store.set(textTone.rawValue, forKey: "skinTextTone") } }
    @Published var tint: Color { didSet { store.set(Self.hex(tint), forKey: "skinTint") } }

    /// Per display, keyed by display UUID. Missing means the main skin.
    @Published private(set) var displaySkins: [String: SkinPreset]
    /// Per app, keyed by bundle identifier: while that app is in front, its skin shows.
    @Published private(set) var appSkins: [String: SkinPreset]
    @Published var scheduled: Bool { didSet { store.set(scheduled, forKey: "skinScheduled"); apply() } }
    @Published var nightSkin: SkinPreset { didSet { store.set(nightSkin.rawValue, forKey: "skinNight"); apply() } }
    @Published var nightBegins: Double { didSet { store.set(nightBegins, forKey: "skinNightBegins"); apply() } }
    @Published var dayBegins: Double { didSet { store.set(dayBegins, forKey: "skinDayBegins"); apply() } }

    /// The top strip of the wallpaper, blurred, and its colours: for Frosted and Wallpaper Tint.
    @Published private(set) var strip: CGImage?
    @Published private(set) var stripColors: [Color] = []
    private(set) var wallpaperLuminance = 0.4
    @Published private(set) var frontApp: String?

    private var panels: [CGDirectDisplayID: (panel: SkinPanel, screen: SkinScreen)] = [:]
    private var started = false
    private var clock: Timer?

    private init() {
        strength = store.object(forKey: "skinStrength") as? Double ?? 0.85
        floating = store.bool(forKey: "skinFloating")
        radius = store.object(forKey: "skinRadius") as? Double ?? 0
        // An edge saved as the old Day Line becomes the Day Line itself.
        if store.string(forKey: "skinEdge") == "dayLine" {
            store.set(SkinEdge.none.rawValue, forKey: "skinEdge")
            store.set(true, forKey: "dayLine")
            DispatchQueue.main.async { Effects.shared.dayLine = true }
        }
        edge = SkinEdge(rawValue: store.string(forKey: "skinEdge") ?? "") ?? .none
        notchBlend = store.bool(forKey: "skinNotchBlend")
        motion = store.object(forKey: "skinMotion") as? Bool ?? true
        legible = store.object(forKey: "skinLegible") as? Bool ?? true
        textTone = MenuTextTone(rawValue: store.string(forKey: "skinTextTone") ?? "") ?? .auto
        tint = Self.color(hex: store.string(forKey: "skinTint") ?? "") ?? Color(red: 0.36, green: 0.42, blue: 0.86)
        displaySkins = (store.dictionary(forKey: "skinDisplays") as? [String: String] ?? [:]).compactMapValues(SkinPreset.init(rawValue:))
        appSkins = (store.dictionary(forKey: "skinApps") as? [String: String] ?? [:]).compactMapValues(SkinPreset.init(rawValue:))
        scheduled = store.bool(forKey: "skinScheduled")
        nightSkin = SkinPreset(rawValue: store.string(forKey: "skinNight") ?? "") ?? .midnight
        nightBegins = store.object(forKey: "skinNightBegins") as? Double ?? 20
        dayBegins = store.object(forKey: "skinDayBegins") as? Double ?? 7
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    // MARK: Choosing

    func setSkin(_ skin: SkinPreset?, forDisplay uuid: String) {
        displaySkins[uuid] = skin
        store.set(displaySkins.mapValues(\.rawValue), forKey: "skinDisplays")
        apply()
    }

    func setSkin(_ skin: SkinPreset?, forApp bundle: String) {
        appSkins[bundle] = skin
        store.set(appSkins.mapValues(\.rawValue), forKey: "skinApps")
        apply()
    }

    func isNight(at hour: Double) -> Bool {
        dayBegins <= nightBegins ? !(hour >= dayBegins && hour < nightBegins) : (hour >= nightBegins && hour < dayBegins)
    }

    /// The front app's skin, then the night skin, then the display's own, then the main one.
    func skin(forDisplay uuid: String?) -> SkinPreset {
        let base = Effects.shared.skin
        // Rules and schedules only change a skin that is on: Off always means off.
        guard base != .none else { return .none }
        if let frontApp, let own = appSkins[frontApp] { return own }
        if scheduled, isNight(at: DayLight.hourNow) { return nightSkin }
        if let uuid, let own = displaySkins[uuid] { return own }
        return base
    }

    /// The text colour macOS is most likely using: white in Dark Mode and over dark wallpapers.
    var textIsLight: Bool {
        switch textTone {
        case .light: return true
        case .dark: return false
        case .auto:
            let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return dark || wallpaperLuminance < 0.55
        }
    }

    // MARK: Panels

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let bundle = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                let skin = MenuBarSkin.shared
                guard skin.frontApp != bundle else { return }
                skin.frontApp = bundle
                if !skin.appSkins.isEmpty { skin.apply() }
            }
        }
        workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarSkin.shared.apply() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuBarSkin.shared.apply() }
        }
        readWallpaper()
    }

    /// Brings every panel in line with the settings. Panels are kept and changed in place; only a
    /// display that appeared or went away adds or removes one. Nothing is torn down to change a look.
    func apply() {
        start()
        clock?.invalidate()
        clock = nil
        if scheduled, Effects.shared.skin != .none {
            let timer = Timer(timeInterval: 60, repeats: true) { _ in MainActor.assumeIsolated { MenuBarSkin.shared.apply() } }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        }
        // Without separate Spaces, only the main display has a menu bar.
        let screens = NSScreen.screensHaveSeparateSpaces ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        var seen = Set<CGDirectDisplayID>()
        for screen in screens {
            guard let id = screen.displayID else { continue }
            seen.insert(id)
            let geometry = MenuBarGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame, safeTop: screen.safeAreaInsets.top,
                                           leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
            let preset = skin(forDisplay: LiveWallpaper.uuid(of: id))
            // No window at all until a skin is wanted on this display.
            if preset == .none, panels[id] == nil { continue }
            let room: CGFloat = edge == .shadow ? 10 : 0
            let frame = geometry.panelFrame(shadow: room)
            let entry = panels[id] ?? make(frame)
            panels[id] = entry
            if entry.panel.frame != frame { entry.panel.setFrame(frame, display: false) }
            entry.screen.size = geometry.bar.size
            entry.screen.notch = geometry.notchInBar()
            entry.screen.shadowRoom = room
            withAnimation(.easeInOut(duration: 0.35)) { entry.screen.preset = preset }
            // An auto-hidden bar reserves no strip; a skin there would sit over windows.
            let visible = preset != .none && geometry.shown
            show(entry.panel, visible)
        }
        for (id, entry) in panels where !seen.contains(id) {
            entry.panel.orderOut(nil)
            panels[id] = nil
        }
    }

    private func make(_ frame: NSRect) -> (panel: SkinPanel, screen: SkinScreen) {
        let state = SkinScreen()
        let panel = SkinPanel(frame: frame)
        let host = NSHostingView(rootView: SkinSurface(screen: state))
        host.sizingOptions = []
        panel.contentView = host
        panel.alphaValue = 0
        panel.setFrame(frame, display: false)
        return (panel, state)
    }

    private func show(_ panel: SkinPanel, _ on: Bool) {
        if on {
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.orderFrontRegardless()
            }
            // The first frame is drawn before it fades in, so it never flashes empty.
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                panel.animator().alphaValue = 1
            }
        } else if panel.isVisible {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { if panel.alphaValue < 0.01 { panel.orderOut(nil) } }
            })
        }
    }

    // MARK: Wallpaper

    /// Reads the top of the wallpaper once: blurred for Frosted, averaged for Wallpaper Tint, and
    /// measured for the text colour. Only the image is read.
    func readWallpaper() {
        guard let image = Wallpaper.image()?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let screen = NSScreen.screens.first else { return }
        let aspect = screen.frame.width / max(screen.frame.height, 1)
        let barShare = 40 / max(screen.frame.height, 1)
        guard let made = Self.topStrip(of: image, screenAspect: aspect, share: barShare) else { return }
        strip = made.image
        stripColors = made.colors.map { Color(.displayP3, red: $0.x, green: $0.y, blue: $0.z) }
        wallpaperLuminance = made.luminance
    }

    /// The part of a picture that fills the strip under the bar when the picture fills the
    /// screen, blurred. Pure CoreImage, any thread.
    nonisolated static func topStrip(of image: CGImage, screenAspect: CGFloat, share: CGFloat)
        -> (image: CGImage, colors: [SIMD3<Double>], luminance: Double)? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let imageAspect = width / height
        // Fill: crop the sides of a wider picture, the bottom of a taller one shows less.
        let visibleWidth = imageAspect > screenAspect ? height * screenAspect : width
        let visibleHeight = imageAspect > screenAspect ? height : width / screenAspect
        let x = (width - visibleWidth) / 2
        let top = (height - visibleHeight) / 2
        let band = max(visibleHeight * share * 3, 8)
        // CoreImage's origin is bottom left.
        let crop = CGRect(x: x, y: height - top - band, width: visibleWidth, height: band)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.displayP3) as Any])
        let source = CIImage(cgImage: image).cropped(to: crop)
        let blurred = source.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(band) * 0.35)
            .cropped(to: CGRect(x: crop.minX, y: crop.maxY - band / 3, width: crop.width, height: band / 3))
        guard let out = context.createCGImage(blurred, from: blurred.extent, format: .RGBA8,
                                              colorSpace: CGColorSpace(name: CGColorSpace.displayP3)) else { return nil }
        // Eight colours along the strip.
        let samples = 8
        var bytes = [UInt8](repeating: 0, count: samples * 4)
        guard let small = CGContext(data: &bytes, width: samples, height: 1, bitsPerComponent: 8, bytesPerRow: samples * 4,
                                    space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        small.interpolationQuality = .medium
        small.draw(out, in: CGRect(x: 0, y: 0, width: samples, height: 1))
        let colors = (0..<samples).map { SIMD3<Double>(Double(bytes[$0 * 4]), Double(bytes[$0 * 4 + 1]), Double(bytes[$0 * 4 + 2])) / 255 }
        let luminance = colors.map { 0.2126 * $0.x + 0.7152 * $0.y + 0.0722 * $0.z }.reduce(0, +) / Double(samples)
        return (out, colors, luminance)
    }

    // MARK: Colour helpers

    static func luminance(of color: Color) -> Double {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return 0.5 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    static func hex(_ color: Color) -> String {
        let c = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        return String(format: "%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    static func color(hex: String) -> Color? {
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

// MARK: - Drawing

/// The skin itself, as one view for the panel and for every preview, so they always match.
/// `still` previews never animate: a preview that ticks on its own is a preview that flickers.
struct SkinArt: View {
    let preset: SkinPreset
    let size: CGSize
    var notch: CGRect? = nil
    var still = false
    @ObservedObject private var skin = MenuBarSkin.shared

    private var shape: some Shape {
        if skin.floating {
            let r = MenuBarGeometry.floating(size)
            let corner = skin.radius > 0 ? min(skin.radius, r.height / 2) : r.height / 2
            return AnyShape(RoundedRectangle(cornerRadius: corner, style: .continuous).path(in: r))
        }
        let r = min(skin.radius, size.height / 2)
        return AnyShape(UnevenRoundedRectangle(bottomLeadingRadius: r, bottomTrailingRadius: r, style: .continuous))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            fill
                .opacity(preset == .notchless ? 1 : skin.strength)
                .overlay { legibilityVeil }
                .clipShape(shape)
                .overlay { edgeArt }
            if skin.notchBlend || preset == .notchless, let notch, preset != .none { notchPill(notch) }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder private var fill: some View {
        switch preset {
        case .none: Color.clear
        case .glass:
            Rectangle().fill(.clear)
                .atelierGlass(.regular.tint(skin.tint.opacity(0.32)), in: Rectangle())
        case .frosted:
            ZStack {
                if let strip = skin.strip {
                    Image(decorative: strip, scale: 1).resizable()
                } else {
                    LinearGradient(colors: SkinPreset.frosted.colors, startPoint: .leading, endPoint: .trailing)
                }
                // Frost: a pale veil and a breath of light along the top edge.
                Color.white.opacity(0.10)
                LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .bottom)
            }
        case .wallpaper:
            LinearGradient(colors: skin.stripColors.isEmpty ? SkinPreset.wallpaper.colors : skin.stripColors,
                           startPoint: .leading, endPoint: .trailing)
                .saturation(1.15)
        case .aurora: AuroraBand(still: still || !skin.motion)
        case .notchless: Color.black
        case .graphite:
            ZStack(alignment: .top) {
                LinearGradient(colors: preset.colors, startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5)
            }
        case .midnight:
            ZStack {
                Color(red: 0.02, green: 0.02, blue: 0.055)
                RadialGradient(colors: [Color(red: 0.20, green: 0.16, blue: 0.52).opacity(0.75), .clear],
                               center: .center, startRadius: 0, endRadius: max(size.width * 0.32, 1))
                    .scaleEffect(x: 1, y: 0.4, anchor: .center)
            }
        case .solid: skin.tint
        default:
            LinearGradient(colors: preset.colors, startPoint: .leading, endPoint: .trailing)
        }
    }

    /// Keeps the skin on the readable side of the text colour macOS chose.
    @ViewBuilder private var legibilityVeil: some View {
        if skin.legible, preset != .none, preset != .glass, preset != .notchless {
            let light = skin.textIsLight
            let l = preset.luminance * skin.strength
            if light {
                Color.black.opacity(l > 0.42 ? min(1 - 0.42 / max(l, 0.01), 0.75) : 0)
            } else {
                Color.white.opacity(l < 0.62 ? min((0.62 - l) / max(1 - l, 0.01), 0.75) : 0)
            }
        }
    }

    @ViewBuilder private var edgeArt: some View {
        switch skin.edge {
        case .none: EmptyView()
        case .hairline:
            VStack { Spacer(); Rectangle().fill(skin.textIsLight ? Color.white.opacity(0.16) : Color.black.opacity(0.18)).frame(height: 0.5) }
        case .shadow: EmptyView()
        }
    }

    private func notchPill(_ notch: CGRect) -> some View {
        // The camera housing, grown into a pill that reaches the bar's lower edge.
        let height = size.height
        let width = notch.width + height * 0.9
        return UnevenRoundedRectangle(bottomLeadingRadius: height / 2, bottomTrailingRadius: height / 2, style: .continuous)
            .fill(.black)
            .frame(width: width, height: height)
            .shadow(color: .black.opacity(0.35), radius: 3)
            .offset(x: notch.midX - width / 2)
    }
}

/// Slow ribbons of light. Thirty frames a second is more than it needs: it moves a few points a second.
struct AuroraBand: View {
    var still = false

    var body: some View {
        if still {
            band(40)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)) { context in
                band(context.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func band(_ t: Double) -> some View {
        let s = t * 0.05
        let points: [SIMD2<Float>] = [
            [0, 0], [Float(0.30 + 0.06 * sin(s)), 0], [Float(0.66 + 0.06 * sin(s * 1.3 + 1)), 0], [1, 0],
            [0, 1], [Float(0.36 + 0.07 * sin(s * 0.8 + 2)), 1], [Float(0.70 + 0.05 * sin(s * 1.1 + 3)), 1], [1, 1],
        ]
        let deep = Color(red: 0.02, green: 0.06, blue: 0.11)
        let teal = Color(red: 0.06, green: 0.46 + 0.08 * sin(s * 2), blue: 0.42)
        let violet = Color(red: 0.30, green: 0.22, blue: 0.62 + 0.06 * sin(s * 1.7))
        return AtelierMesh(width: 4, height: 2, points: points,
                            colors: [deep, teal, violet, deep, deep, violet.opacity(0.9), teal.opacity(0.8), deep])
    }
}

/// What the panel hosts: the skin, and room below it for a shadow when asked.
struct SkinSurface: View {
    @ObservedObject var screen: SkinScreen
    @ObservedObject private var skin = MenuBarSkin.shared

    var body: some View {
        VStack(spacing: 0) {
            SkinArt(preset: screen.preset, size: screen.size, notch: screen.notch)
                .shadow(color: .black.opacity(skin.edge == .shadow && screen.preset != .none ? 0.35 : 0), radius: 5, y: 2)
            Spacer(minLength: 0)
        }
        .frame(width: screen.size.width, height: screen.size.height + screen.shadowRoom, alignment: .top)
    }
}

/// A miniature menu bar over a skin: for the chapter, the swatches, and the stage. It never
/// animates by itself.
struct MenuBarSkinPreview: View {
    let preset: SkinPreset
    var width: CGFloat = 360
    var height: CGFloat = 22
    var items = true
    @ObservedObject private var skin = MenuBarSkin.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            SkinArt(preset: preset, size: CGSize(width: width, height: height),
                    notch: CGRect(x: width * 0.446, y: 0, width: width * 0.107, height: height * 0.96), still: true)
            if items { row }
        }
        .frame(width: width, height: height)
        .clipped()
    }

    /// What the bar sits on: the wallpaper's own top strip when it is known.
    @ViewBuilder private var backdrop: some View {
        if let strip = skin.strip {
            Image(decorative: strip, scale: 1).resizable()
        } else {
            LinearGradient(colors: [Color(white: 0.25), Color(white: 0.15)], startPoint: .leading, endPoint: .trailing)
        }
    }

    private var row: some View {
        let size = height * 0.5
        // A narrow bar drops menus from the right, as a real one does, instead of cutting names short.
        return ViewThatFits(in: .horizontal) {
            items(menus: ["File", "Edit", "View"])
            items(menus: ["File"])
            items(menus: [])
        }
        .font(.system(size: size, weight: .medium))
        .foregroundStyle(skin.textIsLight ? Color.white.opacity(0.95) : Color.black.opacity(0.85))
        .padding(.horizontal, height * 0.6)
        .frame(width: width, height: height)
    }

    private func items(menus: [String]) -> some View {
        HStack(spacing: height * 0.55) {
            Image(systemName: "apple.logo")
            Text("Finder").fontWeight(.bold).fixedSize()
            ForEach(menus, id: \.self) { Text($0).fixedSize() }
            Spacer(minLength: height * 0.55)
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text("10:09").fixedSize()
        }
    }
}
