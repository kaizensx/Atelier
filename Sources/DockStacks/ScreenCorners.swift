import AppKit
import SwiftUI

// MARK: - Rounded Screen Corners
//
// Soft, rounded corners on every display, like the ones on a MacBook's notch side, drawn by
// four tiny click-through panels per screen that sit above everything, full-screen apps
// included. Each panel is only as big as the curve, so nothing else on screen is covered.

enum CornerSet: String, CaseIterable, Identifiable {
    case all, top, bottom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All Four"
        case .top: "Top"
        case .bottom: "Bottom"
        }
    }
    /// Corners in AppKit terms: bottom-left origin, so `minY` is the bottom edge.
    var corners: [Corner] {
        switch self {
        case .all: Corner.allCases
        case .top: [.topLeft, .topRight]
        case .bottom: [.bottomLeft, .bottomRight]
        }
    }
}

enum Corner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

@MainActor
final class ScreenCorners: ObservableObject {
    static let shared = ScreenCorners()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "corners.round.enabled"); rebuild() } }
    @Published var radius: Double { didSet { store.set(radius, forKey: "corners.round.radius"); rebuild() } }
    @Published var set: CornerSet { didSet { store.set(set.rawValue, forKey: "corners.round.set"); rebuild() } }
    /// For tests: the panels on screen right now.
    @Published private(set) var count = 0

    private let store = UserDefaults.standard
    private var panels: [NSPanel] = []
    private var screensChanged: NSObjectProtocol?

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "corners.round.enabled")
        radius = d.object(forKey: "corners.round.radius") as? Double ?? 12
        set = CornerSet(rawValue: d.string(forKey: "corners.round.set") ?? "") ?? .all
    }

    func resume() { if enabled { rebuild() } }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        if enabled {
            if screensChanged == nil {
                screensChanged = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { ScreenCorners.shared.rebuild() }
                }
            }
            let size = radius.rounded()
            for screen in NSScreen.screens {
                let f = screen.frame
                for corner in set.corners {
                    let origin = switch corner {
                    case .topLeft: CGPoint(x: f.minX, y: f.maxY - size)
                    case .topRight: CGPoint(x: f.maxX - size, y: f.maxY - size)
                    case .bottomLeft: CGPoint(x: f.minX, y: f.minY)
                    case .bottomRight: CGPoint(x: f.maxX - size, y: f.minY)
                    }
                    panels.append(panel(CGRect(origin: origin, size: CGSize(width: size, height: size)), corner: corner))
                }
            }
        } else if let screensChanged {
            NotificationCenter.default.removeObserver(screensChanged)
            self.screensChanged = nil
        }
        count = panels.count
    }

    private func panel(_ frame: CGRect, corner: Corner) -> NSPanel {
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above the menu bar, the Dock and full-screen apps; below the pointer.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.sharingType = .none
        panel.contentView = NSHostingView(rootView: CornerFillet(corner: corner).fill(.black, style: FillStyle(eoFill: true)).clipped())
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return panel
    }
}

/// The black that fills the space between a square corner and its curve.
struct CornerFillet: Shape {
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        // The square less a circle centred on the opposite corner: what remains is the curve's
        // outside. Filled even-odd and clipped to the square.
        let r = rect.width
        let center = switch corner {
        case .topLeft: CGPoint(x: r, y: r)
        case .topRight: CGPoint(x: 0, y: r)
        case .bottomLeft: CGPoint(x: r, y: 0)
        case .bottomRight: CGPoint(x: 0, y: 0)
        }
        var path = Path()
        path.addRect(rect)
        path.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        return path
    }
}

// MARK: - Card and stage

struct ScreenCornersCard: View {
    @ObservedObject private var corners = ScreenCorners.shared

    var body: some View {
        HeroCard("Rounded Screen Corners",
                 pitch: "Soft corners on every display, above everything, full-screen apps too. Clicks pass straight through.",
                 isOn: $corners.enabled, hue: DS.Spectrum.surfaces,
                 readout: "\(Int(corners.radius.rounded())) pt", readoutCaption: corners.set.title,
                 preview: .overlay("display.corners", "Rounded Screen Corners", isOn: corners.enabled) { size in
                     ScreenCornersPreview(size: size)
                 }) {
            CornersPlate(radius: corners.radius, set: corners.set)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Segments(selection: $corners.set, options: CornerSet.allCases.map { ($0, $0.title) })
                HStack(spacing: 12) {
                    Text("Radius").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 52, alignment: .leading)
                    LuxSlider(value: $corners.radius, range: 4...28, label: "Corner radius", tint: DS.Spectrum.surfaces)
                    Text("\(Int(corners.radius.rounded())) pt").font(DS.Typo.value)
                        .foregroundStyle(DS.Ink.secondary).frame(width: 40, alignment: .trailing)
                }
            }
        }
    }
}

/// A small screen with the chosen corners, and the loupe over one of them at six times life
/// size. Under the pointer the loupe's corner eases from square to round and back, the change
/// the feature makes, shown where the eye can see it.
private struct CornersPlate: View {
    let radius: Double
    let set: CornerSet

    var body: some View {
        let corner = set.corners.first ?? .topLeft
        HeroLife { live in
            HStack(spacing: 26) {
                screen
                HeroClock(live: live, rest: .pi / 2) { t in
                    // Square, round, held, square again: a smooth 0 to 1 and back.
                    let k = (1 - cos(t * 1.4)) / 2
                    CornerLoupe(corner: corner, radius: live ? radius * k : radius, diameter: 104, shadow: false)
                }
            }
            .padding(.leading, 34)
            .padding(.top, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .animation(DS.Motion.settle, value: radius)
        .animation(DS.Motion.settle, value: set)
        .accessibilityHidden(true)
    }

    /// The display: a desktop, a menu bar, and the black of the bezel showing at each rounded corner.
    private var screen: some View {
        let w = 150.0, h = 96.0
        // At this size a 12 pt corner is a speck; drawn about three times larger so it reads.
        let r = min(radius * 0.55, 18)
        let round = Set(set.corners)
        return ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.18, green: 0.34, blue: 0.44), Color(red: 0.52, green: 0.38, blue: 0.3)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(.black.opacity(0.3)).frame(height: 8)
        }
        .frame(width: w, height: h)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: round.contains(.topLeft) ? r : 0,
                                          bottomLeadingRadius: round.contains(.bottomLeft) ? r : 0,
                                          bottomTrailingRadius: round.contains(.bottomRight) ? r : 0,
                                          topTrailingRadius: round.contains(.topRight) ? r : 0, style: .circular))
        .padding(5)
        .background(.black, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
    }
}

/// The stage's screen with the same corners, and a loupe over one of them: at stage size a
/// 12 pt curve is a few pixels, so the lens shows it as it looks up close.
struct ScreenCornersPreview: View {
    @ObservedObject private var corners = ScreenCorners.shared
    let size: CGSize

    var body: some View {
        let screen = NSScreen.main?.frame.width ?? 1728
        let r = max(3, corners.radius * size.width / screen)
        let corner = corners.set.corners.first ?? .topLeft
        ZStack {
            ForEach(Array(corners.set.corners.enumerated()), id: \.offset) { _, corner in
                CornerFillet(corner: corner).fill(.black, style: FillStyle(eoFill: true))
                    .frame(width: r, height: r).clipped()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner))
            }
            CornerLoupe(corner: corner, radius: corners.radius, diameter: size.width * 0.2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(corner))
                .padding(.horizontal, size.width * 0.07)
                .padding(.vertical, size.height * 0.12)
        }
        .frame(width: size.width, height: size.height)
        .animation(DS.Motion.settle, value: corners.radius)
        .animation(DS.Motion.settle, value: corners.set)
    }

    private func alignment(_ corner: Corner) -> Alignment {
        switch corner {
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        }
    }
}

/// A round lens centred on a screen corner, at about six times life size: bezel black on the
/// outside, the desktop and (for a top corner) the menu bar inside, and the curve between.
private struct CornerLoupe: View {
    let corner: Corner
    let radius: Double
    let diameter: Double
    /// Off on a hero plate, which scales when pressed and must not re-render a shadow each frame.
    var shadow = true

    var body: some View {
        let zoom = diameter / 90
        let r = radius * zoom
        let half = diameter / 2
        let top = corner == .topLeft || corner == .topRight
        ZStack(alignment: .topLeading) {
            Color.black
            // The screen fills the quarter past the corner, its own corner rounded; drawn for
            // top-left, then mirrored. Clipping rather than painting black over it leaves no seam.
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.18, green: 0.34, blue: 0.44), Color(red: 0.52, green: 0.38, blue: 0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if top {
                    Rectangle().fill(.black.opacity(0.28)).frame(height: 24 * zoom)
                }
                if corner == .topLeft {
                    Image(systemName: "apple.logo").font(.system(size: 9 * zoom)).foregroundStyle(.white.opacity(0.9))
                        .offset(x: 16 * zoom, y: 6 * zoom)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: r, style: .circular))
            .frame(width: half, height: half)
            .offset(x: half, y: half)
        }
        .frame(width: diameter, height: diameter)
        .scaleEffect(x: corner == .topRight || corner == .bottomRight ? -1 : 1,
                     y: corner == .bottomLeft || corner == .bottomRight ? -1 : 1)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1.5))
        .shadow(color: .black.opacity(shadow ? 0.5 : 0), radius: shadow ? 14 : 0, y: shadow ? 6 : 0)
    }
}
