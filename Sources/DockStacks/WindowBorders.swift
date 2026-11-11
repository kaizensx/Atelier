import AppKit
import DockCore
import ApplicationServices
import SwiftUI

// MARK: - Window Borders
//
// A light ring around the window you are working in, in the spirit of JankyBorders, built only
// on public pieces: an Accessibility observer on the front app says when its focused window
// changes, moves or resizes, and a click-through panel ordered just above that window draws
// the ring. Nothing is injected; turning it off removes the panel and the observer.

enum BorderStyle: String, CaseIterable, Codable, Identifiable {
    case accent, aurora, sunset, ice, mono, wallpaper, spectrum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accent: "Accent"
        case .aurora: "Aurora"
        case .sunset: "Sunset"
        case .ice: "Ice"
        case .mono: "Mono"
        case .wallpaper: "Wallpaper"
        case .spectrum: "Spectrum"
        }
    }

    /// The gradient stops, going round the window.
    @MainActor func colors(wallpaper: Color) -> [Color] {
        switch self {
        case .accent: [Color.accentColor, Color.accentColor.opacity(0.55), Color.accentColor]
        case .aurora: [Color(red: 0.2, green: 0.95, blue: 0.7), Color(red: 0.35, green: 0.45, blue: 1), Color(red: 0.75, green: 0.35, blue: 1),
                       Color(red: 0.2, green: 0.95, blue: 0.7)]
        case .sunset: [Color(red: 1, green: 0.55, blue: 0.3), Color(red: 1, green: 0.3, blue: 0.5), Color(red: 0.6, green: 0.3, blue: 0.95),
                       Color(red: 1, green: 0.55, blue: 0.3)]
        case .ice: [.white, Color(red: 0.6, green: 0.85, blue: 1), .white]
        case .mono: [.white.opacity(0.9), .white.opacity(0.5), .white.opacity(0.9)]
        case .wallpaper: [wallpaper, wallpaper.opacity(0.5), wallpaper]
        case .spectrum: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .red]
        }
    }

    /// Spectrum turns slowly; the rest hold still and cost nothing between moves.
    var turns: Bool { self == .spectrum }
}

@MainActor
final class WindowBorders: ObservableObject {
    static let shared = WindowBorders()

    @Published var enabled: Bool { didSet { save(enabled, "enabled"); apply() } }
    @Published var style: BorderStyle { didSet { save(style.rawValue, "style"); refreshLook() } }
    @Published var width: Double { didSet { save(width, "width"); update() } }
    @Published var glow: Double { didSet { save(glow, "glow"); update() } }
    @Published var radius: Double { didSet { save(radius, "radius"); update() } }
    /// What the ring is drawn with, for the panel and the stage alike.
    @Published private(set) var wallpaperColor = Color.accentColor
    /// The window being ringed, in screen points (top-left origin), for tests and the stage.
    @Published private(set) var target: CGRect?

    private let store = UserDefaults.standard
    private var panel: NSPanel?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "borders.enabled")
        style = BorderStyle(rawValue: d.string(forKey: "borders.style") ?? "") ?? .aurora
        width = d.object(forKey: "borders.width") as? Double ?? 4
        glow = d.object(forKey: "borders.glow") as? Double ?? 0.6
        // Until the owner picks a radius, the ring follows this release's window corners.
        radius = d.object(forKey: "borders.radius") as? Double ?? WindowsCompatCorners.windowRadius(major: MacPlatform.major)
    }

    private func save(_ value: Any, _ key: String) { store.set(value, forKey: "borders." + key) }

    /// Called once at launch: picks up where the last session left off.
    func resume() { if enabled { apply() } }

    private func apply() {
        if enabled {
            guard AXIsProcessTrusted() else { return }
            refreshLook()
            FocusTracker.shared.join("borders") { WindowBorders.shared.update() }
        } else {
            FocusTracker.shared.leave("borders")
            panel?.orderOut(nil)
            panel = nil
            target = nil
        }
    }

    // MARK: Following the front window

    private func update() {
        guard enabled, let focus = FocusTracker.shared.focus else { hide(); return }
        // Atelier's own window has its own chrome; a ring around it would fight it.
        guard !FocusTracker.isAtelier(focus) else { hide(); return }
        let rect = focus.frame
        target = rect
        let pad = width + 6 + glow * 18
        // Accessibility speaks top-left screen points; AppKit wants bottom-left.
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height).insetBy(dx: -pad, dy: -pad)
        let panel = self.panel ?? makePanel()
        panel.setFrame(cocoa, display: false)
        (panel.contentView as? NSHostingView<BorderRing>)?.rootView = ring(pad: pad)
        if let id = focus.windowID {
            panel.order(.above, relativeTo: Int(id))
        } else {
            panel.orderFront(nil)
        }
    }

    private func hide() {
        target = nil
        panel?.orderOut(nil)
    }

    private func ring(pad: Double) -> BorderRing {
        BorderRing(colors: style.colors(wallpaper: wallpaperColor), width: width, glow: glow, radius: radius, pad: pad, turns: style.turns)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .transient, .fullScreenNone]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ring(pad: 10))
        self.panel = panel
        return panel
    }

    private func refreshLook() {
        if style == .wallpaper, let url = Wallpaper.url(), let image = NSImage(contentsOf: url) {
            wallpaperColor = Effects.dominant(of: image)
        }
        if enabled { update() }
    }
}

/// The ring itself: a gradient stroke hugging the window's corners, with a soft glow of the
/// same colours behind it.
struct BorderRing: View {
    let colors: [Color]
    let width: Double
    let glow: Double
    let radius: Double
    let pad: Double
    let turns: Bool

    var body: some View {
        if turns {
            TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                ring(angle: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 8) / 8 * 360)
            }
        } else {
            ring(angle: 0)
        }
    }

    private func ring(angle: Double) -> some View {
        // The panel reaches `pad` past the window on every side; the band sits on the window's
        // edge, outside it, with the corner radius grown by the band so the curves stay concentric.
        let shape = RoundedRectangle(cornerRadius: radius + pad, style: .continuous).inset(by: pad - width)
        let paint = AngularGradient(colors: colors, center: .center, angle: .degrees(angle))
        return ZStack {
            shape.strokeBorder(paint, lineWidth: width + 2)
                .blur(radius: 4 + glow * 12)
                .opacity(glow)
            shape.strokeBorder(paint, lineWidth: width)
        }
    }
}

/// A window with the ring around it, at stage size for the chapter's preview, or at plate size
/// for the hero card. On the plate the glow is drawn with layered strokes, never a blur, and the
/// window drifts (so the ring is seen to follow it) only while `since` is set, which is on hover.
struct BorderPreview: View {
    @ObservedObject private var borders = WindowBorders.shared
    let size: CGSize
    var plate = false
    var since: Date?

    var body: some View {
        if plate {
            PlateClock(since: since, rest: 0) { t in plateScene(t) }
        } else {
            stage
        }
    }

    private var stage: some View {
        let w = size.width * 0.44
        return MockWindow(width: w, title: "Safari") { BrowserContent(width: w).frame(height: w * 0.56) }
            .overlay {
                let scale = w / 900
                let band = max(borders.width * scale * 2.2, 1.2)
                BorderRing(colors: borders.style.colors(wallpaper: borders.wallpaperColor), width: band,
                           glow: borders.glow, radius: min(w * 0.035, 18), pad: band + 8, turns: borders.style.turns)
                    .padding(-(band + 8))
            }
            .frame(width: size.width, height: size.height)
    }

    private func plateScene(_ t: Double) -> some View {
        let w = min(size.width * 0.34, 210), h = min(size.height * 0.6, 92)
        // A slow figure of eight: the ring is a follower, so show it following.
        let drift = CGSize(width: sin(t * 0.9) * size.width * 0.07, height: sin(t * 1.8) * size.height * 0.05)
        let colors = borders.style.colors(wallpaper: borders.wallpaperColor)
        let paint = AngularGradient(colors: colors, center: .center,
                                    angle: .degrees(borders.style.turns ? t / 8 * 360 : 0))
        let band = 1.2 + borders.width * 0.42
        let corner = 2 + borders.radius * 0.3
        let gap = 1.5
        let ringCorner = corner + gap + band / 2
        return ZStack {
            PlateWindow(tint: DS.Ink.secondary, focused: false, corner: 6)
                .frame(width: w * 0.86, height: h * 0.9)
                .offset(x: -size.width * 0.2, y: -size.height * 0.08)
            PlateWindow(tint: colors.first ?? DS.Spectrum.windows, focused: true, corner: corner)
                .frame(width: w, height: h)
                .background {
                    // The glow: three wider, fainter strokes behind the window. Static cost only.
                    ZStack {
                        ForEach(1..<4) { k in
                            RoundedRectangle(cornerRadius: ringCorner + Double(k) * 3, style: .continuous)
                                .stroke(paint, lineWidth: band + Double(k) * 5)
                                .opacity(borders.glow * 0.34 / Double(k))
                                .padding(-(gap + band / 2 + Double(k) * 3))
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: ringCorner, style: .continuous)
                        .stroke(paint, lineWidth: band)
                        .padding(-(gap + band / 2))
                }
                .offset(drift)
        }
        .frame(width: size.width, height: size.height)
    }
}
