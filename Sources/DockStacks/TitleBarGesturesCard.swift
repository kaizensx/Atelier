import AppKit
import DockCore
import SwiftUI

// MARK: - Title Bar Gestures card
//
// The plate plays the idea in miniature: two fingertips on a window's title bar swipe, the glass
// slab grows towards where the window will go, and the window follows. One loop walks through
// left half, right half, maximise and restore. Each gesture row carries its own small
// illustration, the two dots doing that gesture over a title bar, animated while hovered.

struct TitleBarGesturesCard: View {
    @ObservedObject private var model = TitleBarGestures.shared
    private let hue = DS.Spectrum.windows

    var body: some View {
        let assigned = TitleBarGesture.allCases.filter { model.binding($0).first != .none }.count
        HeroCard("Title Bar Gestures",
                 pitch: "Two fingers on a title bar: swipe to tile, up to maximise, pinch to close.",
                 isOn: $model.enabled, hue: hue,
                 readout: "\(assigned)", readoutCaption: "of \(TitleBarGesture.allCases.count) set") {
            LivePlate { size, since in TitleBarPlate(size: size, since: since, hue: hue) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                AvailabilityNote(availability: model.availability)
                NeedsAccessRow(reason: "To move other apps’ windows.")
                group("Swipes", [.left, .right, .up, .down])
                group("Corners", [.topLeft, .topRight, .bottomLeft, .bottomRight])
                    .disabled(!model.diagonals)
                    .opacity(model.diagonals ? 1 : 0.45)
                group("Pinches", [.pinchIn, .pinchOut])
                VStack(spacing: 10) {
                    HeroSlider(title: "Sensitivity", value: $model.sensitivity, range: 0.5...2, hue: hue) {
                        String(format: "%.1f×", $0)
                    }
                    HeroSlider(title: "Title Bar", value: $model.band, range: 24...80, hue: hue) {
                        "\(Int($0.rounded())) pt"
                    }
                }
                .padding(.top, DS.Space.xs)
                VStack(spacing: 2) {
                    SettingRow(title: "Include Toolbars", detail: "A toolbar under the title bar counts too: Finder, Safari, Mail.",
                               density: .compact) {
                        LuxSwitch(isOn: $model.includeToolbar, label: "Include Toolbars", tint: hue)
                    }
                    SettingRow(title: "Diagonal Swipes", detail: "Swipe towards a corner for that quarter of the screen.",
                               density: .compact) {
                        LuxSwitch(isOn: $model.diagonals, label: "Diagonal Swipes", tint: hue)
                    }
                    SettingRow(title: "Haptic Tick", detail: "The trackpad clicks once as the window lands.", density: .compact) {
                        LuxSwitch(isOn: $model.haptics, label: "Haptic Tick", tint: hue)
                    }
                }
                footnote
            }
        }
        .disabled(!model.availability.isUsable && !model.enabled)
        .onAppear { model.refreshTrust() }
    }

    private func group(_ title: String, _ gestures: [TitleBarGesture]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).font(DS.eyebrow).tracking(0.6).foregroundStyle(DS.Ink.tertiary)
                .padding(.bottom, 2)
            ForEach(gestures) { gesture in TitleBarGestureRow(gesture: gesture, hue: hue) }
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Only with the pointer on a title bar. Anywhere else two fingers scroll as always, and while a gesture is on its way the window’s content stays still.")
            if let last = model.lastFired {
                Label("\(last.gesture.title) → \(last.plan)", systemImage: last.gesture.symbol)
                    .foregroundStyle(DS.Ink.secondary)
                    .contentTransition(.opacity)
            }
            Button("Restore Defaults") { model.resetBindings() }
                .buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.Ink.secondary)
            if let error = model.lastError { Text(error).foregroundStyle(.orange.opacity(0.9)) }
        }
        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
        .fixedSize(horizontal: false, vertical: true)
        .animation(DS.Motion.touch, value: model.lastFired?.at)
    }
}

// MARK: - Rows

private struct TitleBarGestureRow: View {
    let gesture: TitleBarGesture
    var hue: Color
    @ObservedObject private var model = TitleBarGestures.shared
    @State private var hover = false

    /// Stacked: the gesture's name over its two menus, which wrap under each other when the
    /// card is narrow. Side by side, the name and its explanation were squeezed to a few
    /// letters a line between the glyph and two wide menus.
    var body: some View {
        let binding = model.binding(gesture)
        let fired = model.lastFired?.gesture == gesture ? model.lastFired?.at : nil
        HStack(alignment: .top, spacing: 12) {
            TitleBarGestureGlyph(gesture: gesture, playing: hover, hue: hue, flash: fired)
                .frame(width: 46, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(gesture.rowTitle).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) { menus(binding) }
                    VStack(alignment: .leading, spacing: 4) { menus(binding) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    @ViewBuilder private func menus(_ binding: TitleBarBinding) -> some View {
        TitleBarActionMenu(selection: binding.first, label: "\(gesture.title) action") { action in
            var changed = binding
            changed.first = action
            model.set(changed, for: gesture)
        }
        if binding.first != .none {
            TitleBarActionMenu(selection: binding.again, label: "\(gesture.title) again", prefix: "Again") { action in
                var changed = binding
                changed.again = action
                model.set(changed, for: gesture)
            }
        }
    }
}

private extension TitleBarGesture {
    /// The row's name: the group header already says Swipes, Corners or Pinches.
    var rowTitle: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        case .topLeft: "Up Left"
        case .topRight: "Up Right"
        case .bottomLeft: "Down Left"
        case .bottomRight: "Down Right"
        case .pinchIn: "Pinch In"
        case .pinchOut: "Pinch Out"
        }
    }
}

private extension TitleBarAction {
    /// The menu button's label, short enough for two buttons on a line. The menu itself
    /// lists the full names.
    var shortTitle: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .displayLeft: "Left Display"
        case .displayRight: "Right Display"
        case .close: "Close"
        default: title
        }
    }
}

private struct TitleBarActionMenu: View {
    let selection: TitleBarAction
    let label: String
    var prefix: String?
    let choose: (TitleBarAction) -> Void

    var body: some View {
        Menu {
            Button { choose(.none) } label: { Label(TitleBarAction.none.title, systemImage: TitleBarAction.none.symbol) }
            section(TitleBarAction.tiles)
            section(TitleBarAction.sizes)
            section(TitleBarAction.displaysGroup)
            section(TitleBarAction.window)
        } label: {
            HStack(spacing: 5) {
                if let prefix { Text(prefix).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(DS.Ink.tertiary) }
                Image(systemName: selection.symbol).font(.system(size: 11, weight: .semibold))
                Text(selection.shortTitle).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(DS.Ink.tertiary)
            }
            .foregroundStyle(selection == .none ? DS.Ink.secondary : DS.Ink.primary)
            .padding(.horizontal, 9).frame(height: 28)
            .background(selection == .none ? DS.Ink.fill : DS.Ink.fillStrong, in: .rect(cornerRadius: 8, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(Pressable(scale: 0.97))
        .menuIndicator(.hidden)
        .fixedSize()
        .help(prefix.map { "\($0): \(selection.title)" } ?? selection.title)
        .accessibilityLabel(label)
        .accessibilityValue(selection.title)
    }

    @ViewBuilder private func section(_ actions: [TitleBarAction]) -> some View {
        Divider()
        ForEach(actions) { action in
            Button { choose(action) } label: { Label(action.title, systemImage: action.symbol) }
        }
    }
}

// MARK: - Illustrations

/// A small window, its title bar lit, and two fingertips doing the gesture on it. Still at rest
/// (the fingers mid-gesture, so the picture reads), animated while hovered or just fired.
struct TitleBarGestureGlyph: View {
    let gesture: TitleBarGesture
    var playing: Bool
    var hue: Color = DS.Spectrum.windows
    var flash: Date?

    var body: some View {
        let live = playing || (flash.map { Date.now.timeIntervalSince($0) < 1.2 } ?? false)
        TimelineView(.animation(minimumInterval: 1 / 60, paused: !live)) { context in
            let t = live ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 : 0.55
            Canvas { ctx, size in Self.draw(gesture, t: t, in: ctx, size: size, hue: hue) }
        }
        .accessibilityHidden(true)
    }

    /// One loop: fingers land (0–0.15), move (0.15–0.7), lift and fade (0.7–1).
    static func draw(_ gesture: TitleBarGesture, t: Double, in ctx: GraphicsContext, size: CGSize, hue: Color) {
        let window = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
        let shape = Path(roundedRect: window, cornerRadius: 5, style: .continuous)
        ctx.fill(shape, with: .linearGradient(Gradient(colors: [Color(white: 0.22), Color(white: 0.13)]),
                                             startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
        let bar = CGRect(x: window.minX, y: window.minY, width: window.width, height: window.height * 0.3)
        ctx.fill(Path(roundedRect: bar, cornerRadius: 5, style: .continuous), with: .color(hue.opacity(0.28)))
        ctx.stroke(shape, with: .color(.white.opacity(0.22)), lineWidth: 0.6)
        for (i, light) in [Color.red, .yellow, .green].enumerated() {
            let r = 1.6
            ctx.fill(Path(ellipseIn: CGRect(x: window.minX + 4 + Double(i) * 4.5, y: bar.midY - r, width: r * 2, height: r * 2)),
                     with: .color(light.opacity(0.75)))
        }
        // Motion.
        let move = min(max((t - 0.15) / 0.55, 0), 1)
        let eased = move * move * (3 - 2 * move)
        let alpha = t < 0.12 ? t / 0.12 : (t > 0.75 ? max(0, 1 - (t - 0.75) / 0.2) : 1)
        let center = CGPoint(x: bar.midX, y: bar.midY + 1)
        var spacing = size.width * 0.18
        var offset = CGSize.zero
        if gesture.isPinch {
            let from = gesture == .pinchIn ? 0.36 : 0.12, to = gesture == .pinchIn ? 0.1 : 0.4
            spacing = size.width * (from + (to - from) * eased)
        } else {
            let v = gesture.vector
            let reach = size.width * 0.22
            offset = CGSize(width: v.dx * reach * eased, height: -v.dy * reach * 0.6 * eased)
        }
        // A trail behind the swipe.
        if !gesture.isPinch && eased > 0.05 {
            var trail = Path()
            trail.move(to: center)
            trail.addLine(to: CGPoint(x: center.x + offset.width, y: center.y + offset.height))
            ctx.stroke(trail, with: .color(hue.opacity(0.5 * alpha)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        for side in [-1.0, 1.0] {
            let p = CGPoint(x: center.x + side * spacing / 2 + offset.width, y: center.y + offset.height)
            let r = 3.2
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r * 2, y: p.y - r * 2, width: r * 4, height: r * 4)),
                     with: .radialGradient(Gradient(colors: [hue.opacity(0.45 * alpha), .clear]), center: p, startRadius: 0, endRadius: r * 2))
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(alpha)))
        }
    }
}

/// The hero plate: a desktop with one window. Two fingertips swipe on its title bar, the slab
/// grows towards the target, then the window springs there. Left, right, up, down: 6.4 s a loop.
struct TitleBarPlate: View {
    let size: CGSize
    let since: Date?
    var hue: Color = DS.Spectrum.windows

    private static let steps: [(TitleBarGesture, CGRect)] = [
        (.left, CGRect(x: 0, y: 0, width: 0.5, height: 1)),
        (.right, CGRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        (.up, CGRect(x: 0, y: 0, width: 1, height: 1)),
        (.down, CGRect(x: 0.24, y: 0.18, width: 0.52, height: 0.64)),
    ]
    private static let home = CGRect(x: 0.24, y: 0.18, width: 0.52, height: 0.64)
    private static let phase = 1.6

    var body: some View {
        // At rest: the first swipe half-way, slab showing, so the still picture explains itself.
        PlateClock(since: since, rest: 0.42) { time in scene(time) }
    }

    private func scene(_ time: Double) -> some View {
        let loop = Self.phase * Double(Self.steps.count)
        let local = time.truncatingRemainder(dividingBy: loop)
        let index = Int(local / Self.phase)
        let t = (local - Double(index) * Self.phase) / Self.phase
        let (gesture, target) = Self.steps[index]
        let from = index == 0 ? Self.home : Self.steps[index - 1].1
        let screen = CGRect(origin: .zero, size: size).insetBy(dx: 18, dy: 14)
        func place(_ unit: CGRect) -> CGRect {
            let gap = 3.0
            return CGRect(x: screen.minX + unit.minX * screen.width + gap, y: screen.minY + unit.minY * screen.height + gap,
                          width: unit.width * screen.width - gap * 2, height: unit.height * screen.height - gap * 2)
        }
        // 0–0.45 fingers move and the slab grows; 0.45–0.7 the window springs; then rest.
        let swipe = min(t / 0.45, 1)
        let settle = min(max((t - 0.45) / 0.25, 0), 1)
        let spring = 1 - pow(1 - settle, 3) * cos(settle * 2.2)
        let windowRect = TitleBarGeometry.preview(from: place(from), to: place(target), progress: spring)
        let slab = TitleBarGeometry.preview(from: place(from), to: place(target), progress: swipe)
        let slabAlpha = t < 0.45 ? 1 : max(0, 1 - (t - 0.45) / 0.2)
        let fingers = t < 0.5
        let bar = CGRect(x: windowRect.minX, y: windowRect.minY, width: windowRect.width, height: 16)
        let v = gesture.vector
        let reach = min(size.width * 0.08, 46) * (1 - pow(1 - swipe, 2))
        let tip = CGPoint(x: bar.midX + v.dx * reach, y: bar.midY - v.dy * reach * 0.6)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [hue.opacity(0.16), .black.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: screen.width, height: screen.height)
                .offset(x: screen.minX, y: screen.minY)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hue.opacity(0.18))
                .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.5), lineWidth: 1) }
                .frame(width: slab.width, height: slab.height)
                .offset(x: slab.minX, y: slab.minY)
                .opacity(slabAlpha * (swipe > 0.05 ? 1 : 0))
            PlateWindow(tint: hue, focused: true, corner: 7)
                .frame(width: windowRect.width, height: windowRect.height)
                .offset(x: windowRect.minX, y: windowRect.minY)
            if fingers {
                ForEach([-1.0, 1.0], id: \.self) { side in
                    Circle()
                        .fill(RadialGradient(colors: [.white, hue.opacity(0.9)], center: .topLeading, startRadius: 0, endRadius: 9))
                        .frame(width: 11, height: 11)
                        .shadow(color: hue.opacity(0.6), radius: 5)
                        .offset(x: tip.x + side * 9 - 5.5, y: tip.y - 5.5)
                }
                .transition(.opacity)
            }
            HStack(spacing: 5) {
                Image(systemName: gesture.symbol).font(.system(size: 10, weight: .bold))
                Text(TitleBarBinding.standard(gesture).first.title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.black.opacity(0.4), in: .capsule)
            .frame(width: size.width, height: size.height, alignment: .bottom)
            .padding(.bottom, 4)
            .opacity(t < 0.75 ? 1 : max(0, 1 - (t - 0.75) / 0.2))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}
