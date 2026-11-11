import AppKit
import ScreenCaptureKit
import SwiftUI

// Window Previews for Live Peek: one still picture of each window, taken when the pointer
// rests on an app's tile. Never a stream. ScreenCaptureKit does the capture in its own
// process, at thumbnail size, so nothing is scaled on the main thread; pictures are kept for
// a few seconds so sliding back and forth along the bar does not capture again.

/// One window in the peek card.
struct DockThumb: Identifiable, Equatable {
    var id: CGWindowID
    var title: String
    var minimized: Bool
    /// Width over height of the window.
    var aspect: Double
    var image: NSImage?

    static func == (a: DockThumb, b: DockThumb) -> Bool {
        a.id == b.id && a.title == b.title && a.minimized == b.minimized && a.image === b.image
    }
}

// MARK: - Layout

/// Where the window card sits and where each picture is in it, in panel points. The view and
/// the dock's hit testing both use this, so a click lands on the picture that is drawn.
enum DockPeekLayout {
    static let cell = CGSize(width: 164, height: 104)
    static let titleHeight = 18.0
    static let spacing = 10.0
    static let padding = 12.0
    static let header = 40.0
    static let most = 6
    /// The notch under the card that points at the tile.
    static let notch = 7.0
    static let minWidth = 244.0

    /// Columns for `count` pictures: one row of up to four along a horizontal bar, then a
    /// grid of three; two across beside a vertical bar.
    static func columns(_ count: Int, edge: OwnDockEdge) -> Int {
        let n = max(min(count, most), 1)
        if edge.horizontal { return n <= 4 ? n : 3 }
        return n == 1 ? 1 : 2
    }

    static func rows(_ count: Int, edge: OwnDockEdge) -> Int {
        let n = max(min(count, most), 1)
        let columns = columns(n, edge: edge)
        return (n + columns - 1) / columns
    }

    private static var item: CGSize { CGSize(width: cell.width, height: cell.height + titleHeight) }

    static func size(count: Int, edge: OwnDockEdge) -> CGSize {
        let columns = Double(columns(count, edge: edge)), rows = Double(rows(count, edge: edge))
        let width = columns * item.width + (columns - 1) * spacing + padding * 2
        let height = padding * 2 + header + rows * item.height + (rows - 1) * spacing
        return CGSize(width: max(width, minWidth), height: height)
    }

    /// The card's frame: clear of the lens, centred on the tile's live centre, and kept on
    /// screen. Only clamping at a screen edge moves it off centre; the notch still points
    /// at the tile then.
    static func frame(count: Int, scene: DockScene) -> CGRect {
        frame(size: size(count: count, edge: scene.edge), scene: scene)
    }

    static func frame(size: CGSize, scene: DockScene) -> CGRect {
        let panel = scene.panel
        switch scene.edge {
        case .bottom, .top:
            let x = clamp(scene.peekAlong, size.width / 2 + 10, panel.width - size.width / 2 - 10)
            let y = scene.edge == .bottom ? panel.height - scene.peekCross - size.height : scene.peekCross
            return CGRect(x: x - size.width / 2, y: y, width: size.width, height: size.height)
        case .left, .right:
            let y = clamp(scene.peekAlong, size.height / 2 + 10, panel.height - size.height / 2 - 10)
            let x = scene.edge == .left ? scene.peekCross : panel.width - scene.peekCross - size.width
            return CGRect(x: x, y: y - size.height / 2, width: size.width, height: size.height)
        }
    }

    /// Where along the card's dock-side edge the notch sits, in card points.
    static func notchOffset(card: CGRect, scene: DockScene) -> Double {
        let corner = DS.Radius.card + notch
        if scene.edge.horizontal { return clamp(scene.peekAlong - card.minX, corner, card.width - corner) }
        return clamp(scene.peekAlong - card.minY, corner, card.height - corner)
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        high < low ? (low + high) / 2 : min(max(value, low), high)
    }

    /// One picture's frame inside the card, in card points. Every row is centred, the last
    /// one too when it is short.
    static func cellFrame(_ index: Int, count: Int, edge: OwnDockEdge) -> CGRect {
        let n = max(min(count, most), 1)
        let columns = columns(n, edge: edge)
        let row = index / columns, column = index % columns
        let inRow = min(columns, n - row * columns)
        let width = size(count: n, edge: edge).width
        let rowWidth = Double(inRow) * item.width + Double(inRow - 1) * spacing
        let x = (width - rowWidth) / 2 + Double(column) * (item.width + spacing)
        let y = padding + header + Double(row) * (item.height + spacing)
        return CGRect(x: x, y: y, width: item.width, height: item.height)
    }

    /// Which picture is under `point`, in panel points.
    static func hit(_ point: CGPoint, count: Int, scene: DockScene) -> Int? {
        let card = frame(count: count, scene: scene)
        guard card.contains(point) else { return nil }
        let local = CGPoint(x: point.x - card.minX, y: point.y - card.minY)
        let n = min(count, most)
        return (0..<n).first { cellFrame($0, count: n, edge: scene.edge).insetBy(dx: -4, dy: -4).contains(local) }
    }
}

// MARK: - Capture

/// Still pictures of windows, taken one at a time, kept briefly.
@MainActor
final class DockWindowShots {
    static let shared = DockWindowShots()

    private var images: [CGWindowID: (image: NSImage, at: Date)] = [:]
    private var content: (value: SCShareableContent, at: Date)?
    /// How long a picture stays good.
    private let keep = 4.0

    /// Screen Recording is allowed. Cheap: it reads a flag, it never asks.
    var allowed: Bool { CGPreflightScreenCaptureAccess() }

    func cached(_ id: CGWindowID) -> NSImage? {
        guard let entry = images[id], Date().timeIntervalSince(entry.at) < keep else { return nil }
        return entry.image
    }

    /// Takes a picture of each window that has none fresh, calling `got` as each arrives.
    /// `width` is in pixels; the height follows each window's shape.
    func capture(_ ids: [CGWindowID], width: Int, got: @escaping @MainActor (CGWindowID, NSImage) -> Void) async {
        let now = Date()
        images = images.filter { now.timeIntervalSince($0.value.at) < keep * 3 }
        let needed = ids.filter { cached($0) == nil }
        guard !needed.isEmpty, allowed else { return }
        guard var listing = await shareable(fresh: false) else { return }
        // A window opened since the last listing: list once more.
        if needed.contains(where: { id in !listing.windows.contains { $0.windowID == id } }),
           let again = await shareable(fresh: true) {
            listing = again
        }
        for id in needed {
            guard !Task.isCancelled else { return }
            guard let window = listing.windows.first(where: { $0.windowID == id }), window.frame.width > 1 else { continue }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            let aspect = window.frame.height / window.frame.width
            config.width = width
            config.height = max(Int((Double(width) * aspect).rounded()), 1)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            config.captureResolution = .nominal
            guard let picture = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { continue }
            let image = NSImage(cgImage: picture, size: NSSize(width: picture.width, height: picture.height))
            images[id] = (image, Date())
            got(id, image)
        }
    }

    /// The list of windows ScreenCaptureKit can see, reused for two seconds.
    private func shareable(fresh: Bool) async -> SCShareableContent? {
        if !fresh, let content, Date().timeIntervalSince(content.at) < 2 { return content.value }
        let value = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        if let value { content = (value, Date()) }
        return value
    }
}

// MARK: - Card

/// Live Peek with window pictures: the app, then one picture per window with its title.
struct DockThumbCard: View {
    let peek: DockPeek
    let theme: DockTheme
    let edge: OwnDockEdge
    /// The picture under the pointer.
    let hot: Int?
    /// Where the notch points, along the card's dock-side edge.
    var notch: Double?

    private var glass: AGlass { theme.tint.map { AGlass.regular.tint($0) } ?? .regular }

    var body: some View {
        let shown = Array(peek.thumbs.prefix(DockPeekLayout.most))
        let size = DockPeekLayout.size(count: shown.count, edge: edge)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                if !peek.path.isEmpty {
                    Image(nsImage: DockIcons.image(peek.path)).resizable().interpolation(.high).frame(width: 28, height: 28)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(peek.title).font(DS.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Text(peek.status).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: size.width - DockPeekLayout.padding * 2, height: 30, alignment: .leading)
            .offset(x: DockPeekLayout.padding, y: DockPeekLayout.padding)
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, thumb in
                let frame = DockPeekLayout.cellFrame(index, count: shown.count, edge: edge)
                cell(thumb, hot: hot == index)
                    .frame(width: frame.width, height: frame.height, alignment: .top)
                    .offset(x: frame.minX, y: frame.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .atelierGlass(glass, in: .rect(cornerRadius: DS.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous).strokeBorder(DS.Ink.hairline, lineWidth: 0.5)
        }
        .overlay { if let notch { DockPeekNotch(edge: edge, offset: notch, glass: glass, size: size) } }
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(peek.title), \(shown.count) windows")
    }

    private func cell(_ thumb: DockThumb, hot: Bool) -> some View {
        let box = DockPeekLayout.cell
        return VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(DS.Ink.fill)
                if let image = thumb.image {
                    let fit = min(box.width / max(thumb.aspect, 0.2), box.height)
                    Image(nsImage: image).resizable().interpolation(.medium)
                        .frame(width: min(fit * thumb.aspect, box.width), height: fit)
                        .clipShape(.rect(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                        .opacity(thumb.minimized ? 0.72 : 1)
                } else if !peek.path.isEmpty, !ScreenRecordingFlag.allowed {
                    // No picture can be taken without Screen Recording: the app's icon stands in.
                    VStack(spacing: 5) {
                        Image(nsImage: DockIcons.image(peek.path)).resizable().interpolation(.high)
                            .frame(width: 44, height: 44).opacity(thumb.minimized ? 0.6 : 1)
                        if thumb.minimized {
                            Text("Minimised").font(.system(size: 10.5)).foregroundStyle(DS.Ink.tertiary)
                        }
                    }
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: thumb.minimized ? "minus.square" : "macwindow")
                            .font(.system(size: 20, weight: .regular)).foregroundStyle(DS.Ink.tertiary)
                        Text(thumb.minimized ? "Minimised" : "Taking a picture…")
                            .font(.system(size: 10.5)).foregroundStyle(DS.Ink.tertiary)
                    }
                }
                if thumb.minimized {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(.black.opacity(0.45), in: .circle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(5)
                }
            }
            .frame(width: box.width, height: box.height)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(hot ? theme.accent : DS.Ink.hairline, lineWidth: hot ? 2 : 0.5)
            }
            .scaleEffect(hot ? 1.03 : 1)
            Text(thumb.title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(hot ? DS.Ink.primary : DS.Ink.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: box.width)
        }
        .animation(DS.Motion.touch, value: hot)
    }
}

/// The small point on the card's dock side, over the tile the card belongs to.
struct DockPeekNotch: View {
    let edge: OwnDockEdge
    let offset: Double
    let glass: AGlass
    let size: CGSize

    var body: some View {
        let side = DockPeekLayout.notch * 2
        let point: CGPoint = switch edge {
        case .bottom: CGPoint(x: offset, y: size.height + DockPeekLayout.notch / 2)
        case .top: CGPoint(x: offset, y: -DockPeekLayout.notch / 2)
        case .left: CGPoint(x: -DockPeekLayout.notch / 2, y: offset)
        case .right: CGPoint(x: size.width + DockPeekLayout.notch / 2, y: offset)
        }
        Color.clear
            .atelierGlass(glass, in: DockNotchShape(edge: edge))
            .frame(width: edge.horizontal ? side : DockPeekLayout.notch, height: edge.horizontal ? DockPeekLayout.notch : side)
            .position(point)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A triangle pointing away from the card, toward the bar.
struct DockNotchShape: Shape {
    let edge: OwnDockEdge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .bottom:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        case .top:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        case .left:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        case .right:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
        path.closeSubpath()
        return path
    }
}

// MARK: - Arrange mode

/// The Done button that floats by the bar while Arrange Dock is on.
enum DockArrangeLayout {
    static let size = CGSize(width: 132, height: 30)

    static func frame(_ scene: DockScene) -> CGRect {
        let bar = scene.bar, panel = scene.panel
        var center: CGPoint
        if scene.edge.horizontal {
            let room = bar.minX - 16 - size.width
            center = CGPoint(x: room > 8 ? bar.minX - 16 - size.width / 2 : bar.maxX + 16 + size.width / 2, y: bar.midY)
            center.x = min(max(center.x, size.width / 2 + 6), panel.width - size.width / 2 - 6)
        } else {
            let room = panel.height - bar.maxY - 16 - size.height
            center = CGPoint(x: bar.midX, y: room > 8 ? bar.maxY + 16 + size.height / 2 : bar.minY - 16 - size.height / 2)
            center.x = scene.edge == .left ? max(center.x, size.width / 2 + 6) : min(center.x, panel.width - size.width / 2 - 6)
        }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

struct DockArrangePill: View {
    let theme: DockTheme

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            Text("Done Arranging").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.black.opacity(0.85))
        .frame(width: DockArrangeLayout.size.width, height: DockArrangeLayout.size.height)
        .background(theme.accent, in: .capsule)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .accessibilityLabel("Done Arranging")
    }
}

/// The remove button on a tile in Arrange mode.
struct DockRemoveBadge: View {
    let size: Double

    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: max(size * 0.17, 8), weight: .bold))
            .foregroundStyle(.white)
            .frame(width: max(size * 0.36, 16), height: max(size * 0.36, 16))
            .background(Circle().fill(Color(white: 0.18)))
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .accessibilityLabel("Remove")
    }
}
