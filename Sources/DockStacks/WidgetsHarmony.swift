import AppKit
import ApplicationServices
import SwiftUI

// MARK: - Icon Harmony

/// How a widget makes room for a Finder desktop icon that sits over it.
enum IconHarmony: String, CaseIterable, Identifiable {
    case off, halo, cutout, fade
    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Off"
        case .halo: "Halo"
        case .cutout: "Cut-out"
        case .fade: "Fade"
        }
    }

    var detail: String {
        switch self {
        case .off: "Widgets draw as they are, under the icons."
        case .halo: "A soft dark pool under each icon and its name, so they read on any widget."
        case .cutout: "The widget opens a soft hole where an icon sits, and the wallpaper shows through."
        case .fade: "The widget fades away under each icon."
        }
    }

    /// The treatment a tile really gets. A widget with no surface fades, since a halo would darken bare wallpaper,
    /// and a widget in a window above the icons can only let them show through.
    static func effective(_ chosen: IconHarmony, style: WidgetStyle, above: Bool) -> IconHarmony {
        guard chosen != .off else { return .off }
        if above { return chosen == .fade ? .fade : .cutout }
        if style.material == .bare, chosen == .halo { return .fade }
        return chosen
    }
}

/// Finder's desktop icons, read through Accessibility. Read only, off the main thread, every 3 seconds
/// and only while the board is on screen with Icon Harmony on or being arranged.
@MainActor
final class DesktopIcons: ObservableObject {
    static let shared = DesktopIcons()

    /// Each icon with its name, in global top-left coordinates, the space Accessibility reports in.
    @Published private(set) var frames: [CGRect] = []
    /// Whether Accessibility answered at all, for the hint in Settings.
    @Published private(set) var readable = true

    private var task: Task<Void, Never>?
    private var observer: NSObjectProtocol?

    var running: Bool { task != nil }

    func run(_ on: Bool) {
        guard on != running else { return }
        if on {
            task = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            // Finder relaunching, or coming forward after an icon moved, is worth a look straight away.
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                let finder = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.finder"
                guard finder else { return }
                MainActor.assumeIsolated { Task { await DesktopIcons.shared.refresh() } }
            }
        } else {
            task?.cancel()
            task = nil
            if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            observer = nil
            if !frames.isEmpty { frames = [] }
        }
    }

    func refresh() async {
        guard AXIsProcessTrusted() else {
            if readable { readable = false }
            if !frames.isEmpty { frames = [] }
            return
        }
        if !readable { readable = true }
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier else {
            if !frames.isEmpty { frames = [] }
            return
        }
        let found = await Task.detached(priority: .utility) { DesktopIcons.read(finder: pid) }.value
        // Publishing only on change keeps every tile still while icons stay put.
        if found != frames { frames = found }
    }

    #if DEBUG
    /// Fixed frames, for rendering checks without Finder.
    func preview(_ frames: [CGRect]) { self.frames = frames }
    #endif

    /// The icons that overlap a tile, in the tile's own coordinates.
    func holes(in rect: CGRect) -> [CGRect] {
        guard !frames.isEmpty, rect.width > 0 else { return [] }
        return frames.compactMap { frame in
            guard frame.intersects(rect) else { return nil }
            return frame.offsetBy(dx: -rect.minX, dy: -rect.minY)
        }
    }

    /// Finder's desktop is a scroll area among the application's children, with one image element per icon.
    nonisolated static func read(finder pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        var result: [CGRect] = []
        for child in children(app) where role(child) == kAXScrollAreaRole as String {
            collect(child, depth: 0, into: &result)
        }
        return result.map(withLabel).sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    private nonisolated static func collect(_ element: AXUIElement, depth: Int, into result: inout [CGRect]) {
        guard depth < 4, result.count < 400 else { return }
        for child in children(element) {
            let kind = role(child)
            if kind == kAXImageRole as String, let frame = frame(child), frame.width > 4, frame.height > 4 {
                result.append(frame)
            } else if kind == kAXGroupRole as String || kind == kAXListRole as String || kind == kAXScrollAreaRole as String {
                collect(child, depth: depth + 1, into: &result)
            }
        }
    }

    private nonisolated static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private nonisolated static func role(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        var values: CFArray?
        let names = [kAXPositionAttribute, kAXSizeAttribute] as CFArray
        guard AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(), &values) == .success,
              let list = values as? [AnyObject], list.count == 2 else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard CFGetTypeID(list[0]) == AXValueGetTypeID(), CFGetTypeID(list[1]) == AXValueGetTypeID(),
              AXValueGetValue(list[0] as! AXValue, .cgPoint, &point),
              AXValueGetValue(list[1] as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// An icon frame that covers only the picture gets room for its name below, two lines' worth.
    nonisolated static func withLabel(_ frame: CGRect) -> CGRect {
        guard frame.height <= frame.width * 1.15 else { return frame.insetBy(dx: -4, dy: -4) }
        let label = max(30, frame.width * 0.42)
        let width = max(frame.width + 24, frame.width * 1.5)
        return CGRect(x: frame.midX - width / 2, y: frame.minY - 4, width: width, height: frame.height + label + 8)
    }
}

/// Draws a widget so the icons over it stay legible: a halo, a cut-out or a fade.
/// The treatment never changes the view's structure while it stays the same, so faces keep their state.
struct IconHarmonyLayer: ViewModifier {
    let mode: IconHarmony
    /// The tile in global top-left coordinates.
    let rect: CGRect
    let radius: Double
    /// Off while arranging, when the board sits above the icons anyway.
    let active: Bool
    @ObservedObject private var icons = DesktopIcons.shared

    init(mode: IconHarmony, rect: CGRect, radius: Double, active: Bool) {
        self.mode = mode
        self.rect = rect
        self.radius = radius
        self.active = active
    }

    func body(content: Content) -> some View {
        let holes = active && mode != .off ? icons.holes(in: rect) : []
        switch mode {
        case .off:
            content
        case .halo:
            content.overlay {
                HarmonyHalo(holes: holes, radius: radius)
                    .allowsHitTesting(false)
                    .animation(.smooth(duration: 0.4), value: holes)
            }
        case .cutout, .fade:
            content.mask {
                HarmonyMask(holes: holes, fade: mode == .fade)
                    .padding(-HarmonyMask.bleed)
                    .animation(.smooth(duration: 0.4), value: holes)
            }
        }
    }
}

/// Soft dark pools, one per icon, laid over the widget under Finder's icons.
private struct HarmonyHalo: View {
    let holes: [CGRect]
    let radius: Double

    var body: some View {
        Canvas { context, size in
            guard !holes.isEmpty else { return }
            context.clip(to: Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: radius, style: .continuous))
            for hole in holes {
                let well = hole.insetBy(dx: -hole.width * 0.22, dy: -hole.height * 0.16)
                let center = CGPoint(x: well.midX, y: well.midY)
                let reach = max(well.width, well.height) * 0.72
                context.fill(Path(ellipseIn: well.insetBy(dx: -reach * 0.25, dy: -reach * 0.25)),
                             with: .radialGradient(Gradient(stops: [
                                 .init(color: .black.opacity(0.66), location: 0),
                                 .init(color: .black.opacity(0.5), location: 0.5),
                                 .init(color: .black.opacity(0), location: 1),
                             ]), center: center, startRadius: 0, endRadius: reach))
            }
        }
    }
}

/// White where the widget shows, a feathered hole or a soft dip where an icon sits.
private struct HarmonyMask: View {
    let holes: [CGRect]
    let fade: Bool
    /// The mask reaches past the tile, so the widget's shadow is never clipped.
    static let bleed = 60.0

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            guard !holes.isEmpty else { return }
            context.blendMode = .destinationOut
            for hole in holes {
                let shifted = hole.offsetBy(dx: Self.bleed, dy: Self.bleed)
                if fade {
                    let center = CGPoint(x: shifted.midX, y: shifted.midY)
                    let reach = max(shifted.width, shifted.height) * 0.75
                    context.fill(Path(ellipseIn: shifted.insetBy(dx: -reach * 0.3, dy: -reach * 0.3)),
                                 with: .radialGradient(Gradient(stops: [
                                     .init(color: .black.opacity(0.94), location: 0),
                                     .init(color: .black.opacity(0.8), location: 0.55),
                                     .init(color: .black.opacity(0), location: 1),
                                 ]), center: center, startRadius: 0, endRadius: reach))
                } else {
                    context.drawLayer { layer in
                        layer.addFilter(.blur(radius: 7))
                        layer.fill(Path(roundedRect: shifted.insetBy(dx: -4, dy: -4), cornerRadius: 16, style: .continuous), with: .color(.black))
                    }
                }
            }
        }
    }
}

/// Faint outlines where Finder's icons are, drawn while arranging, when the board covers them.
struct IconMarks: View {
    let origin: CGPoint
    let size: CGSize
    @ObservedObject private var icons = DesktopIcons.shared

    var body: some View {
        let local = icons.holes(in: CGRect(origin: origin, size: size))
        Canvas { context, _ in
            for hole in local {
                let path = Path(roundedRect: hole.insetBy(dx: 6, dy: 4), cornerRadius: 12, style: .continuous)
                context.fill(path, with: .color(.white.opacity(0.05)))
                context.stroke(path, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
