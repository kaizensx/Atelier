import AppKit
import ImageIO
import SwiftUI
import DockCore

// MARK: - Spaces card
//
// Your desktops as little screens: the wallpaper, an outline where each window sits, the
// current one lit. Click one to go there; drag a window chip onto one to send that window.
// Nothing is captured from the screen: the outlines are the window server's own bounds and
// the picture is the wallpaper file, so the card costs nothing while it sits there.

/// Whether the card is on screen, so Space changes only re-read windows when someone is looking.
@MainActor enum SpacesCardPresence {
    static var visible = false
}

/// A small copy of the current wallpaper. macOS only says which picture is on the current
/// desktop, so every card shows that one; when there is no readable file (a dynamic or
/// aerial wallpaper), each desktop gets its own soft gradient instead.
@MainActor
final class DesktopWallpaperThumb: ObservableObject {
    static let shared = DesktopWallpaperThumb()
    @Published private(set) var image: NSImage?
    private var loaded: URL?

    func load() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen), url != loaded else { return }
        loaded = url
        Task.detached(priority: .utility) {
            // Decoded off the main thread, at card size: a 6K HEIC would cost frames otherwise.
            let options = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 520,
                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return }
            await MainActor.run { DesktopWallpaperThumb.shared.image = NSImage(cgImage: cg, size: .zero) }
        }
    }
}

@MainActor private enum AppIcons {
    static var cache: [pid_t: NSImage] = [:]
    static func icon(_ pid: pid_t) -> NSImage? {
        if let icon = cache[pid] { return icon }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        cache[pid] = icon
        return icon
    }
}

/// Instant Spaces as a hero: straight to any desktop, no slide. Its plate is your desktops in a
/// row; under the pointer the lit one jumps from desktop to desktop with no motion between.
struct InstantSpacesHero: View {
    @ObservedObject private var indicator = SpacesIndicator.shared
    @ObservedObject private var instant = InstantSpaces.shared
    @ObservedObject private var wallpaper = DesktopWallpaperThumb.shared

    var body: some View {
        HeroCard("Instant Spaces",
                 pitch: "Straight to any desktop, no slide, even with Reduce Motion off. Control-Arrow takes about a second.",
                 isOn: $instant.instant, hue: DS.Spectrum.surfaces,
                 readout: "\(Int((instant.lastMs ?? 31).rounded())) ms",
                 readoutCaption: instant.lastMs == nil ? "Typical switch" : "Last switch",
                 preview: .overlay("spaces.instant", "Switch Instantly", isOn: instant.instant) { size in
                     SpacesSwitchPreview(size: size, measured: instant.lastMs)
                 }) {
            SpacesPlate(spaces: indicator.spaces, wallpaper: wallpaper.image)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SettingRow(title: "Desktop Shortcuts", detail: shortcutDetail, density: .compact) {
                    LuxSwitch(isOn: $instant.hotkeys, label: "Desktop Shortcuts", tint: DS.Spectrum.surfaces)
                }
                Segments(selection: $instant.chord, options: SpaceChord.allCases.map { ($0, $0.title) })
                    .disabled(!instant.hotkeys)
                    .opacity(instant.hotkeys ? 1 : 0.4)
                SpacesStatus(instant: instant)
            }
        }
        .onAppear {
            indicator.refresh()
            wallpaper.load()
        }
    }

    private var shortcutDetail: String {
        let chord = instant.chord
        let send = chord.sendFlags == nil ? "Hyper leaves no chord for sending." : "Add ⇧ to send the front window there."
        return "\(chord.label(1))…\(chord.label(9)) jumps to a desktop. \(send)"
    }
}

/// Up to five desktops as little screens, the current one lit. Static at rest; under the pointer
/// the light cuts from one to the next, never sliding, which is the whole point.
private struct SpacesPlate: View {
    let spaces: [DesktopSpace]
    let wallpaper: NSImage?

    var body: some View {
        let shown = spaces.isEmpty ? (1...4).map { DesktopSpace(id: "\($0)", number: $0, current: $0 == 1) } : Array(spaces.prefix(5))
        let current = shown.firstIndex(where: \.current) ?? 0
        HeroLife { live in
            Group {
                if live {
                    TimelineView(.periodic(from: .now, by: 0.7)) { context in
                        let step = Int(context.date.timeIntervalSinceReferenceDate / 0.7)
                        strip(shown, lit: (current + step) % shown.count)
                    }
                } else {
                    strip(shown, lit: current)
                }
            }
            .padding(.leading, 18)
            .padding(.top, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .accessibilityHidden(true)
    }

    private func strip(_ shown: [DesktopSpace], lit: Int) -> some View {
        HStack(spacing: 10) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, space in
                thumb(space, lit: index == lit)
            }
        }
    }

    private func thumb(_ space: DesktopSpace, lit: Bool) -> some View {
        let w = 78.0, h = 50.0
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(spacing: 5) {
            ZStack {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().interpolation(.medium).scaledToFill()
                        .frame(width: w, height: h).clipped()
                } else {
                    let hue = (0.58 + Double(space.number) * 0.11).truncatingRemainder(dividingBy: 1)
                    LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.62),
                                            Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.28)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                Color.black.opacity(lit ? 0 : 0.45)
            }
            .frame(width: w, height: h)
            .clipShape(shape)
            .overlay { shape.strokeBorder(lit ? DS.Spectrum.surfaces : .white.opacity(0.14), lineWidth: lit ? 1.5 : 0.5) }
            Text("\(space.number)").font(.system(size: 10.5, weight: lit ? .bold : .medium)).monospacedDigit()
                .foregroundStyle(lit ? DS.Spectrum.surfaces : .white.opacity(0.55))
        }
    }
}

/// How switching is going on this Mac: permission, the last measured switch, or the fallback.
private struct SpacesStatus: View {
    @ObservedObject var instant: InstantSpaces

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !AXIsProcessTrusted() {
                HStack(spacing: 10) {
                    Text("Needs Accessibility to switch instantly and to hear the shortcuts.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    Chip("Allow") { NSWorkspace.shared.open(URL(string: "atelier://grant")!) }
                }
            } else {
                switch instant.probe {
                case .works:
                    Text("Last switch took \(Int(instant.lastMs ?? 0)) ms. Control-Arrow takes about a second.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary).monospacedDigit()
                case .fallback:
                    Text(instant.notice ?? "Instant switching didn’t take on this Mac, so Atelier uses Control-Arrow.")
                        .font(DS.caption).foregroundStyle(DS.Spectrum.sensors)
                case .untested:
                    Text(instant.instant ? "Instant switching is checked the first time you use it."
                         : "Moving between desktops uses Control-Arrow, macOS’s own shortcut.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
            }
            if instant.probe != .fallback, let notice = instant.notice {
                Text(notice).font(DS.caption).foregroundStyle(DS.Spectrum.sensors)
            }
            AvailabilityNote(availability: instant.sendAvailability)
            AvailabilityNote(availability: instant.fallbackAvailability)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Spaces in the menu bar: the badge, and your desktops to click or drop windows on.
struct SpacesCard: View {
    @ObservedObject private var indicator = SpacesIndicator.shared
    @ObservedObject private var instant = InstantSpaces.shared
    @ObservedObject private var wallpaper = DesktopWallpaperThumb.shared

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SettingRow(title: "Spaces in the Menu Bar", detail: "Which desktop you are on, at a glance. Click it to jump to another one.") {
                    LuxSwitch(isOn: $indicator.enabled, label: "Spaces in the Menu Bar", tint: DS.Spectrum.surfaces)
                }
                Segments(selection: $indicator.look, options: SpacesLook.allCases.map { ($0, $0.title) })
                gallery
                windowChips
            }
        }
        .onAppear {
            SpacesCardPresence.visible = true
            indicator.refresh()
            instant.refreshWindows()
            wallpaper.load()
        }
        .onDisappear { SpacesCardPresence.visible = false }
        .stagePreview(.overlay("spaces.indicator", "Spaces in the Menu Bar", isOn: indicator.enabled) { size in
            SpacesPreview(size: size)
        })
    }

    // MARK: Desktops

    private var gallery: some View {
        let screen = CGDisplayBounds(CGMainDisplayID())
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(indicator.spaces) { space in
                    DesktopThumb(space: space, windows: instant.windows.filter { $0.space == space.sid },
                                 wallpaper: wallpaper.image, screen: screen,
                                 name: Binding(get: { indicator.names[space.id] ?? "" }, set: { indicator.rename(space, to: $0) }),
                                 canReceive: instant.canSend,
                                 onGo: { instant.go(toSpace: space.sid) },
                                 onDrop: { instant.send(window: $0, toSpace: space.sid) })
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 4)
        }
        .scrollClipDisabled()
    }

    // MARK: Windows on this desktop

    @ViewBuilder private var windowChips: some View {
        let here = indicator.spaces.first(where: \.current).map { current in instant.windows.filter { $0.space == current.sid } } ?? []
        if instant.canSend, indicator.spaces.count > 1, !here.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("ON THIS DESKTOP").font(DS.eyebrow).foregroundStyle(DS.Ink.tertiary).kerning(0.6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(here) { window in
                            WindowChip(window: window)
                                .draggable(WindowDrag.encode(window.id)) { WindowChip(window: window, lifted: true) }
                        }
                    }
                    .padding(.vertical, 2)
                }
                Text("Drag a window onto another desktop to send it there.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        }
    }

}

/// Window drags carry a plain string, so they can never be mistaken for a file or text drop.
enum WindowDrag {
    static let prefix = "atelier-window:"
    static func encode(_ id: UInt32) -> String { prefix + String(id) }
    static func decode(_ text: String) -> UInt32? {
        text.hasPrefix(prefix) ? UInt32(text.dropFirst(prefix.count)) : nil
    }
}

/// One desktop as a little screen.
struct DesktopThumb: View {
    let space: DesktopSpace
    let windows: [SpaceWindow]
    let wallpaper: NSImage?
    let screen: CGRect
    @Binding var name: String
    let canReceive: Bool
    let onGo: () -> Void
    let onDrop: (UInt32) -> Void

    @State private var hovering = false
    @State private var targeted = false

    private let width = 176.0
    private var height: Double { width * max(screen.height, 1) / max(screen.width, 1) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 11, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onGo) { screenFace }
                .buttonStyle(Pressable(scale: 0.96))
                .onHover { hovering = $0 }
                .dropDestination(for: String.self) { items, _ in
                    guard canReceive, let id = items.compactMap(WindowDrag.decode).first else { return false }
                    onDrop(id)
                    return true
                } isTargeted: { targeted = $0 && canReceive }
                .accessibilityLabel(space.current ? "Desktop \(space.number), current" : "Go to desktop \(space.number)")
            TextField("Desktop \(space.number)", text: $name)
                .textFieldStyle(.plain).font(.system(size: 12, weight: space.current ? .semibold : .medium))
                .foregroundStyle(space.current ? DS.Ink.primary : DS.Ink.secondary)
                .frame(width: width)
        }
    }

    private var screenFace: some View {
        ZStack(alignment: .topLeading) {
            backdrop
            Color.black.opacity(space.current ? 0 : 0.3)
            // The window list runs front to back: draw the eight front-most, back first, so the
            // front window sits on top and a busy desktop still reads instead of fogging over.
            ForEach(Array(windows.prefix(8).reversed())) { window in outline(window) }
            numberBadge.padding(7)
            if targeted {
                shape.fill(DS.Ink.accent.opacity(0.18))
                Label("Send here", systemImage: "arrow.down.to.line")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 9).frame(height: 22)
                    .background(DS.Ink.accent, in: .capsule)
                    .frame(width: width, height: height)
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(space.current ? DS.Ink.accent : .white.opacity(targeted ? 0.9 : 0.14),
                               style: StrokeStyle(lineWidth: space.current || targeted ? 2 : 0.75, dash: targeted ? [5, 4] : []))
        }
        // One radius for both states: only the colour changes, so the shadow is never re-blurred mid-animation.
        .shadow(color: space.current ? DS.Ink.accent.opacity(0.45) : .black.opacity(0.35), radius: 10, y: space.current ? 0 : 5)
        .scaleEffect(targeted ? 1.06 : hovering && !space.current ? 1.03 : 1)
        .animation(DS.Motion.touch, value: hovering)
        .animation(DS.Motion.settle, value: targeted)
        .animation(DS.Motion.arrive, value: space.current)
    }

    @ViewBuilder private var backdrop: some View {
        if let wallpaper {
            Image(nsImage: wallpaper).resizable().interpolation(.high).scaledToFill()
                .frame(width: width, height: height).clipped()
        } else {
            // A gradient of its own per desktop, so they still tell apart.
            let hue = (0.58 + Double(space.number) * 0.11).truncatingRemainder(dividingBy: 1)
            LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.62),
                                    Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.7, brightness: 0.28)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func outline(_ window: SpaceWindow) -> some View {
        let k = width / max(screen.width, 1)
        let rect = CGRect(x: (window.frame.minX - screen.minX) * k, y: (window.frame.minY - screen.minY) * k,
                          width: window.frame.width * k, height: window.frame.height * k)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(.black.opacity(0.22))
            .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.3)).frame(height: min(3.5, rect.height * 0.2)) }
            .overlay {
                if rect.width > 26, rect.height > 22, let icon = AppIcons.icon(window.pid) {
                    Image(nsImage: icon).resizable().frame(width: 13, height: 13).shadow(color: .black.opacity(0.35), radius: 1.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(.white.opacity(0.55), lineWidth: 0.6))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }

    private var numberBadge: some View {
        HStack(spacing: 5) {
            Text("\(space.number)").font(.system(size: 10.5, weight: .bold)).monospacedDigit()
            if space.current { Text("Here").font(.system(size: 10, weight: .semibold)) }
        }
        .foregroundStyle(space.current ? .white : .white.opacity(0.85))
        .padding(.horizontal, 7).frame(height: 18)
        .background(space.current ? AnyShapeStyle(DS.Ink.accent) : AnyShapeStyle(.black.opacity(0.4)), in: .capsule)
    }
}

struct WindowChip: View {
    let window: SpaceWindow
    var lifted = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon = AppIcons.icon(window.pid) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
            Text(window.title.isEmpty ? window.app : window.title)
                .font(.system(size: 11.5, weight: .medium)).lineLimit(1).frame(maxWidth: 150, alignment: .leading)
        }
        .padding(.leading, 7).padding(.trailing, 10).frame(height: 28)
        .background(lifted ? AnyShapeStyle(DS.Ink.accent.opacity(0.85)) : AnyShapeStyle(DS.Ink.fillStrong), in: .capsule)
        .foregroundStyle(DS.Ink.primary)
        .contentShape(Capsule())
    }
}

// MARK: - Stage

/// The badge at stage size, sitting in the replica's menu bar, left of the status items.
struct SpacesPreview: View {
    @ObservedObject private var indicator = SpacesIndicator.shared
    let size: CGSize

    var body: some View {
        SpacesBadge(spaces: indicator.spaces.isEmpty ? [DesktopSpace(id: "a", number: 1, current: true), DesktopSpace(id: "b", number: 2, current: false)]
                    : indicator.spaces, look: indicator.look, name: indicator.name)
            .colorInvert()
            .scaleEffect(size.width / 1728 * 1.6)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.white.opacity(0.18), in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, size.width * 0.002)
            .padding(.trailing, size.width * 0.2)
    }
}

/// The difference, side by side on the stage: macOS sliding from one desktop to the next
/// with Control-Arrow, and Atelier cutting there at once. Same moment, same two desktops.
struct SpacesSwitchPreview: View {
    let size: CGSize
    let measured: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let period = 3.6

    var body: some View {
        let laneW = size.width * 0.3, laneH = laneW * 0.6
        TimelineView(.animation(paused: reduceMotion)) { context in
            let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
            VStack(alignment: .leading, spacing: laneH * 0.14) {
                lane(progress: Self.slide(p), flash: 0, width: laneW, height: laneH,
                     title: "Control-Arrow", time: "about 1 s", lit: false)
                lane(progress: Self.cut(p), flash: Self.flash(p), width: laneW, height: laneH,
                     title: "Atelier", time: "\(Int(measured ?? 35)) ms", lit: true)
            }
            .padding(laneH * 0.16)
            .background(.black.opacity(0.42), in: .rect(cornerRadius: laneH * 0.12, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    // Desktop 1 until 1.0 s, desktop 2 until 2.8 s, then back: the two lanes switch together.
    static func slide(_ p: Double) -> Double {
        func ease(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
        switch p {
        case ..<1.0: return 0
        case ..<1.62: return ease((p - 1.0) / 0.62)
        case ..<2.8: return 1
        case ..<3.42: return 1 - ease((p - 2.8) / 0.62)
        default: return 0
        }
    }
    static func cut(_ p: Double) -> Double { p >= 1.0 && p < 2.8 ? 1 : 0 }
    /// A breath of light on the cut, so the eye catches that it happened.
    static func flash(_ p: Double) -> Double {
        for edge in [1.0, 2.8] where p >= edge && p < edge + 0.16 { return 1 - (p - edge) / 0.16 }
        return 0
    }

    private func lane(progress: Double, flash: Double, width: Double, height: Double, title: String, time: String, lit: Bool) -> some View {
        HStack(spacing: height * 0.16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: height * 0.13, weight: .semibold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6)
                Text(time).font(.system(size: height * 0.11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(lit ? DS.Ink.accent : .white.opacity(0.6))
            }
            .frame(width: width * 0.42, alignment: .leading)
            HStack(spacing: 0) {
                MiniDesktop(kind: 0, width: width, height: height)
                MiniDesktop(kind: 1, width: width, height: height)
            }
            .frame(width: width, height: height, alignment: .leading)
            .offset(x: -progress * width)
            .frame(width: width, height: height, alignment: .leading)
            .overlay(Color.white.opacity(0.22 * flash))
            .clipShape(RoundedRectangle(cornerRadius: height * 0.07, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: height * 0.07, style: .continuous)
                .strokeBorder(lit ? DS.Ink.accent.opacity(0.9) : .white.opacity(0.2), lineWidth: lit ? 1.5 : 0.75))
            .shadow(color: lit ? DS.Ink.accent.opacity(0.35) : .clear, radius: 10)
        }
    }
}

/// A desktop in miniature: its own colours and a couple of windows, so a slide reads as one.
private struct MiniDesktop: View {
    let kind: Int
    let width: Double
    let height: Double

    var body: some View {
        let colors: [Color] = kind == 0 ? [Color(red: 0.2, green: 0.36, blue: 0.78), Color(red: 0.06, green: 0.1, blue: 0.3)]
            : [Color(red: 0.92, green: 0.48, blue: 0.3), Color(red: 0.42, green: 0.12, blue: 0.3)]
        let frames: [CGRect] = kind == 0 ? [CGRect(x: 0.08, y: 0.16, width: 0.5, height: 0.58), CGRect(x: 0.46, y: 0.32, width: 0.44, height: 0.52)]
            : [CGRect(x: 0.2, y: 0.14, width: 0.6, height: 0.68)]
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            ForEach(frames.indices, id: \.self) { i in
                let f = frames[i]
                RoundedRectangle(cornerRadius: height * 0.03, style: .continuous)
                    .fill(.white.opacity(0.85))
                    .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.08)).frame(height: height * 0.05) }
                    .clipShape(RoundedRectangle(cornerRadius: height * 0.03, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: height * 0.03, y: height * 0.01)
                    .frame(width: f.width * width, height: f.height * height)
                    .offset(x: f.minX * width, y: f.minY * height)
            }
        }
        .frame(width: width, height: height)
    }
}
