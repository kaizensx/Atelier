import AppKit
import SwiftUI

// MARK: - Dim Inactive Windows
//
// The window you are working in stays bright; everything behind it sinks into a soft shade,
// in the spirit of HazeOver. One click-through panel per screen holds the shade, and it is
// ordered just below the focused window, so only what lies under that window is covered. The
// Dock and the menu bar sit on higher levels and are never touched. Turning it off removes
// the panels.

@MainActor
final class InactiveDim: ObservableObject {
    static let shared = InactiveDim()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "dim.enabled"); apply() } }
    /// How dark the shade is, 0.1 to 0.8.
    @Published var amount: Double { didSet { store.set(amount, forKey: "dim.amount"); paint() } }
    /// Shade colour: plain black, or a hint of the wallpaper.
    @Published var tint: DimTint { didSet { store.set(tint.rawValue, forKey: "dim.tint"); paint() } }
    /// For tests: how many screens are shaded right now, and below which window.
    @Published private(set) var shaded = 0
    @Published private(set) var below: CGWindowID?

    private let store = UserDefaults.standard
    private var panels: [NSPanel] = []
    private var screensChanged: NSObjectProtocol?
    private var wallpaperColor = NSColor.black

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "dim.enabled")
        amount = d.object(forKey: "dim.amount") as? Double ?? 0.35
        tint = DimTint(rawValue: d.string(forKey: "dim.tint") ?? "") ?? .black
    }

    func resume() { if enabled { apply() } }

    private func apply() {
        if enabled {
            guard AXIsProcessTrusted() else { return }
            if screensChanged == nil {
                screensChanged = NotificationCenter.default.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { InactiveDim.shared.rebuild() }
                }
            }
            rebuild()
            FocusTracker.shared.join("dim") { InactiveDim.shared.update() }
        } else {
            FocusTracker.shared.leave("dim")
            if let screensChanged { NotificationCenter.default.removeObserver(screensChanged) }
            screensChanged = nil
            panels.forEach { $0.orderOut(nil) }
            panels = []
            shaded = 0
            below = nil
        }
    }

    private func rebuild() {
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { screen in
            let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            panel.isReleasedWhenClosed = false
            panel.setFrame(screen.frame, display: false)
            return panel
        }
        paint()
        update()
    }

    private func paint() {
        if tint == .wallpaper, let url = Wallpaper.url(), let image = NSImage(contentsOf: url) {
            wallpaperColor = NSColor(Effects.dominant(of: image))
        }
        let base: NSColor = tint == .wallpaper ? (wallpaperColor.blended(withFraction: 0.55, of: .black) ?? .black) : .black
        for panel in panels { panel.backgroundColor = base.withAlphaComponent(amount) }
    }

    private func update() {
        guard enabled else { return }
        // Atelier's own window counts as no window: shading the desk around it fights its chrome.
        guard let focus = FocusTracker.shared.focus, let id = focus.windowID, !FocusTracker.isAtelier(focus) else {
            // The desktop or a full-screen window has focus: nothing to keep bright, so no shade.
            fade(out: true)
            return
        }
        let first = shaded == 0
        for panel in panels { panel.order(.below, relativeTo: Int(id)) }
        shaded = panels.count
        below = id
        if first { fade(out: false) }
    }

    /// The shade eases in and out, so switching to the desktop does not flash the screen.
    private func fade(out: Bool) {
        if out && shaded == 0 { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = out ? 0.16 : 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            for panel in panels {
                if !out { panel.alphaValue = 0 }
                panel.animator().alphaValue = out ? 0 : 1
            }
        } completionHandler: {
            MainActor.assumeIsolated {
                guard out, InactiveDim.shared.below == nil || FocusTracker.shared.focus == nil else { return }
                InactiveDim.shared.panels.forEach { $0.orderOut(nil); $0.alphaValue = 1 }
            }
        }
        if out { shaded = 0; below = nil }
    }
}

enum DimTint: String, CaseIterable, Identifiable {
    case black, wallpaper
    var id: String { rawValue }
    var title: String { self == .black ? "Shade" : "Wallpaper Tint" }
}

// MARK: - Card and stage

struct InactiveDimCard: View {
    let trusted: Bool
    @ObservedObject private var dim = InactiveDim.shared

    var body: some View {
        HeroCard("Dim Inactive Windows", pitch: "Everything behind your window sinks into shade.",
                 isOn: $dim.enabled, hue: DS.Spectrum.windows,
                 readout: "\(Int((dim.amount * 100).rounded()))%", readoutCaption: "Shade",
                 preview: .overlay("engine.dim", "Dim Inactive Windows", isOn: dim.enabled) { size in DimPreview(size: size) }) {
            LivePlate { size, since in DimPreview(size: size, plate: true, since: since) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Segments(selection: $dim.tint, options: DimTint.allCases.map { ($0, $0.title) })
                HeroSlider(title: "Shade", value: $dim.amount, range: 0.1...0.8, hue: DS.Spectrum.windows) {
                    "\(Int(($0 * 100).rounded()))%"
                }
                Text("The Dock, the menu bar and Atelier itself stay bright.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        }
        .disabled(!trusted)
    }
}

/// Two windows on the stage: the one behind sinks into shade, the front one stays bright.
/// On a hero plate, three windows share the desk and the light moves between them on hover.
struct DimPreview: View {
    @ObservedObject private var dim = InactiveDim.shared
    let size: CGSize
    var plate = false
    var since: Date?

    var body: some View {
        if plate {
            PlateClock(since: since, rest: 0, fps: 30) { t in plateScene(focus: Int(t / 1.5) % 3) }
        } else {
            stage
        }
    }

    private var shade: Color { dim.tint == .black ? .black : Color(red: 0.12, green: 0.1, blue: 0.2) }

    private var stage: some View {
        let w = size.width * 0.42
        return ZStack {
            MockWindow(width: w, title: "Notes") { NotesContent(width: w).frame(height: w * 0.56) }
                .offset(x: -size.width * 0.14, y: -size.height * 0.06)
            // The shade leaves the menu bar and the Dock out, as the real one does.
            ShadeShape(edge: CFPreferencesCopyAppValue("orientation" as CFString, "com.apple.dock" as CFString) as? String ?? "bottom")
                .fill(shade, style: FillStyle(eoFill: true))
                .opacity(dim.amount)
                .allowsHitTesting(false)
            MockWindow(width: w, title: "Safari") { BrowserContent(width: w).frame(height: w * 0.56) }
                .offset(x: size.width * 0.12, y: size.height * 0.08)
        }
        .frame(width: size.width, height: size.height)
        .animation(DS.Motion.settle, value: dim.amount)
    }

    /// Three windows side by side; all but the focused one sit under the shade.
    private func plateScene(focus: Int) -> some View {
        let w = min(size.width * 0.22, 134), h = min(size.height * 0.54, 80)
        let tints = [DS.Spectrum.windows, Color(red: 0.98, green: 0.62, blue: 0.4), Color(red: 0.5, green: 0.9, blue: 0.72)]
        return ZStack {
            // The desk itself is shaded too; only the focused window is lifted out of it.
            shade.opacity(dim.amount * 0.8)
            ForEach(0..<3, id: \.self) { index in
                PlateWindow(tint: tints[index], focused: index == focus, corner: 7)
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(shade)
                            .opacity(index == focus ? 0 : dim.amount)
                    }
                    .frame(width: w, height: h)
                    // Shifted left of centre, clear of the readout in the corner.
                    .offset(x: Double(index - 1) * w * 1.1 - size.width * 0.05, y: Double(index == 1 ? -6 : 6))
            }
        }
        .frame(width: size.width, height: size.height)
        .animation(DS.Motion.arrive, value: focus)
        .animation(DS.Motion.hover, value: dim.amount)
    }
}

/// The whole stage less the menu bar strip, with a hole where the Dock sits.
private struct ShadeShape: Shape {
    let edge: String

    /// Where the stage draws the Dock's bar, as fractions of the stage.
    private var dock: CGRect {
        switch edge {
        case "left": CGRect(x: 0.003, y: 0.24, width: 0.042, height: 0.52)
        case "right": CGRect(x: 0.955, y: 0.24, width: 0.042, height: 0.52)
        default: CGRect(x: 0.243, y: 0.925, width: 0.494, height: 0.073)
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bar = StageRegion.menuBar.height * rect.height
        path.addRect(CGRect(x: rect.minX, y: rect.minY + bar, width: rect.width, height: rect.height - bar))
        let hole = CGRect(x: dock.minX * rect.width, y: dock.minY * rect.height, width: dock.width * rect.width, height: dock.height * rect.height)
        path.addRoundedRect(in: hole, cornerSize: CGSize(width: rect.width * 0.014, height: rect.width * 0.014), style: .continuous)
        return path
    }
}
