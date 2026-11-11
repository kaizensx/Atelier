import AppKit
import DockCore
import SwiftUI

// MARK: - Dock Peek for the macOS Dock: what you see
//
// The peek card itself is the Atelier Dock's Live Peek card (`DockThumbCard`), the same glass,
// notch and pictures, with a thin layer on top that the system Dock version needs: hover and
// click targets for each picture, and close and minimise buttons on the one under the pointer.
// After it, the settings hero for the Dock chapter.

/// What the card's controls ask the engine to do. Indices are into the card's pictures.
struct SystemDockPeekActions {
    var hover: @MainActor (Bool) -> Void
    var hot: @MainActor (Int?) -> Void
    var open: @MainActor (Int) -> Void
    var close: @MainActor (Int) -> Void
    var minimize: @MainActor (Int) -> Void
    var quit: @MainActor () -> Void
}

/// The panel's content: the card, or the quit confirm alone when there is no card.
struct SystemDockPeekRoot: View {
    @ObservedObject var stage: SystemDockPeekStage
    let actions: SystemDockPeekActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let peek = stage.peek {
                card(peek)
            } else if let name = stage.quitPrompt {
                SystemDockPeekPill(name: name, quit: actions.quit)
                    .onHover { actions.hover($0) }
            }
        }
        .padding(stage.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(stage.visible ? 1 : 0)
        .scaleEffect(stage.visible || reduceMotion ? 1 : 0.96, anchor: anchor)
        .offset(stage.visible || reduceMotion ? .zero : drift)
        .environment(\.colorScheme, .dark)
    }

    /// The card grows out of the Dock side.
    private var anchor: UnitPoint {
        switch stage.edge {
        case .bottom: .bottom
        case .top: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    private var drift: CGSize {
        switch stage.edge {
        case .bottom: CGSize(width: 0, height: 6)
        case .top: CGSize(width: 0, height: -6)
        case .left: CGSize(width: -6, height: 0)
        case .right: CGSize(width: 6, height: 0)
        }
    }

    private func card(_ peek: DockPeek) -> some View {
        let shown = Array(peek.thumbs.prefix(DockPeekLayout.most))
        let size = DockPeekLayout.size(count: shown.count, edge: stage.edge)
        return DockThumbCard(peek: peek, theme: DockTheme(), edge: stage.edge, hot: stage.hot, notch: stage.notch)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, thumb in
                        let frame = DockPeekLayout.cellFrame(index, count: shown.count, edge: stage.edge)
                        SystemDockPeekCell(thumb: thumb, hot: stage.hot == index,
                                           hover: { inside in
                                               if inside { actions.hot(index) } else if stage.hot == index { actions.hot(nil) }
                                           },
                                           open: { actions.open(index) },
                                           close: { actions.close(index) },
                                           minimize: { actions.minimize(index) })
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
            }
            .overlay(alignment: .top) {
                if let name = stage.quitPrompt {
                    SystemDockPeekPill(name: name, quit: actions.quit)
                        .offset(y: -SystemDockPeekPill.size.height / 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .contentShape(.rect(cornerRadius: DS.Radius.card))
            .onHover { actions.hover($0) }
            .animation(DS.Motion.gentle(DS.Motion.arrive), value: peek.thumbs.count)
            .animation(DS.Motion.gentle(DS.Motion.settle), value: stage.quitPrompt)
    }
}

/// One picture's targets: the whole cell opens the window; the hovered one shows its buttons.
private struct SystemDockPeekCell: View {
    let thumb: DockThumb
    let hot: Bool
    let hover: (Bool) -> Void
    let open: () -> Void
    let close: () -> Void
    let minimize: () -> Void

    var body: some View {
        Color.clear
            .contentShape(.rect(cornerRadius: 9))
            .onHover(perform: hover)
            .onTapGesture(perform: open)
            .overlay(alignment: .topTrailing) {
                if hot {
                    HStack(spacing: 5) {
                        if !thumb.minimized {
                            WindowButton(symbol: "minus", label: "Minimise \(thumb.title)", tint: WindowButtonFace.minimizeTint, action: minimize)
                        }
                        WindowButton(symbol: "xmark", label: "Close \(thumb.title)", tint: WindowButtonFace.closeTint, action: close)
                    }
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .topTrailing)))
                }
            }
            .animation(DS.Motion.touch, value: hot)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(thumb.minimized ? "\(thumb.title), minimised" : thumb.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Bring to Front", open)
    }
}

/// A small traffic-light style button: glass at rest, its colour under the pointer.
private struct WindowButton: View {
    let symbol: String
    let label: String
    let tint: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            WindowButtonFace(symbol: symbol, tint: tint, lit: hover)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.88))
        .onHover { hover = $0 }
        .animation(DS.Motion.hover, value: hover)
        .accessibilityLabel(label)
    }
}

/// The look of a window button, also drawn by the Atelier Dock's card (`OwnDockPeekButtonsOverlay`),
/// where the dock's input view does the hit testing.
struct WindowButtonFace: View {
    static let closeTint = Color(red: 1, green: 0.36, blue: 0.34)
    static let minimizeTint = Color(red: 1, green: 0.74, blue: 0.18)
    let symbol: String
    let tint: Color
    let lit: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(lit ? .black.opacity(0.75) : .white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(lit ? tint : Color.black.opacity(0.5)))
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

/// "Pinch again to quit": the short confirm after a first pinch-in on an icon.
struct SystemDockPeekPill: View {
    static let size = CGSize(width: 290, height: 44)
    let name: String
    let quit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.pinch").font(.system(size: 14, weight: .semibold)).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 0) {
                Text("Pinch again to quit").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                Text(name).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Quit", action: quit)
                .font(.system(size: 12, weight: .semibold))
                .atelierGlassButton()
                .tint(.orange)
        }
        .padding(.horizontal, 14)
        .frame(width: Self.size.width, height: Self.size.height)
        .atelierGlass(.regular, in: .capsule)
        .overlay { Capsule().strokeBorder(DS.Ink.hairline, lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pinch again to quit \(name)")
    }
}

// MARK: - Settings

/// The hero in the Dock chapter: Live Peek and gestures for Apple's own Dock.
struct SystemDockPeekCard: View {
    @ObservedObject private var model = SystemDockPeek.shared
    @ObservedObject private var dock = OwnDock.shared
    private let hue = DS.Spectrum.surfaces

    var body: some View {
        // While the Atelier Dock stands in for the macOS Dock, its own gestures and peek take over.
        if dock.replacesSystemDock {
            OwnDockGesturesCard()
        } else {
            systemCard
        }
    }

    private var systemCard: some View {
        HeroCard("Dock Peek",
                 pitch: "Hover an app in the macOS Dock to see its windows. Swipe, pinch and scroll on icons to manage them.",
                 isOn: $model.enabled, hue: hue,
                 readout: model.previews ? "\(Int((model.hoverDelay * 1000).rounded())) ms" : "Gestures",
                 readoutCaption: model.previews ? "hover delay" : "previews off") {
            SystemDockPeekPlate(hue: hue, previews: model.previews)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                    AvailabilityNote(availability: note)
                }
                RowGroup {
                    SettingRow(title: "Window previews", detail: "Click a picture to bring that window forward, minimised ones too.",
                               symbol: "rectangle.on.rectangle", density: .compact) {
                        LuxSwitch(isOn: $model.previews, label: "Window previews", tint: hue)
                    }
                    if model.previews {
                        HStack(spacing: 12) {
                            Text("Hover delay").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 78, alignment: .leading)
                            LuxSlider(value: Binding(get: { model.hoverDelay }, set: { model.hoverDelay = ($0 * 20).rounded() / 20 }),
                                      range: 0...1, label: "Hover delay", tint: hue)
                            Text(String(format: "%.2f s", model.hoverDelay)).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                        .frame(minHeight: 36)
                    }
                }
                SectionHeader("Gestures on Dock icons", symbol: "hand.draw", detail: "Only over an app's icon; everywhere else scrolling is untouched.", hue: hue)
                RowGroup {
                    gestureRow(.minimize, "Swipe down to minimise", "Two fingers down on an icon tucks away its front window.", "arrow.down.to.line")
                    gestureRow(.restore, "Swipe up to restore", "Two fingers up brings a minimised window back.", "arrow.up.to.line")
                    gestureRow(.quit, "Pinch to quit", "Pinch in, then again within two seconds, to quit the app.", "hand.pinch")
                    SettingRow(title: "Scroll to hide and show", detail: "Mouse wheel up hides the app, down shows it again.",
                               symbol: "computermouse", density: .compact) {
                        LuxSwitch(isOn: Binding(get: { model.isOn(.hide) || model.isOn(.show) },
                                                set: { on in model.set(.hide, on: on); model.set(.show, on: on) }),
                                  label: "Scroll to hide and show", tint: hue)
                    }
                }
            }
        }
    }

    private func gestureRow(_ gesture: SystemDockGesture, _ title: String, _ detail: String, _ symbol: String) -> some View {
        SettingRow(title: title, detail: detail, symbol: symbol, density: .compact) {
            LuxSwitch(isOn: Binding(get: { model.isOn(gesture) }, set: { model.set(gesture, on: $0) }), label: title, tint: hue)
        }
    }
}

/// The plate: a macOS Dock with one icon lifted and its card of windows floating over it. With the
/// pointer over the plate, the card rises the way the real one does; Reduce Motion fades it.
private struct SystemDockPeekPlate: View {
    let hue: Color
    let previews: Bool
    @State private var hover = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let tile = 22.0, gap = 7.0, count = 7
            let bar = CGSize(width: Double(count) * tile + Double(count + 1) * gap, height: tile + gap * 2)
            let barY = height - bar.height / 2 - 12
            let lifted = 3
            let liftedX = width / 2 - bar.width / 2 + gap + Double(lifted) * (tile + gap) + tile / 2
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5) }
                    .frame(width: bar.width, height: bar.height)
                    .position(x: width / 2, y: barY)
                ForEach(0..<count, id: \.self) { index in
                    let x = width / 2 - bar.width / 2 + gap + Double(index) * (tile + gap) + tile / 2
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(index == lifted ? AnyShapeStyle(hue.gradient) : AnyShapeStyle(Color.white.opacity(0.18 + 0.03 * Double(index % 3))))
                        .frame(width: tile, height: tile)
                        .position(x: x, y: barY - (index == lifted && hover ? 3 : 0))
                }
                if previews {
                    miniCard
                        .position(x: liftedX, y: barY - bar.height / 2 - 40)
                        .opacity(hover ? 1 : 0.85)
                        .offset(y: hover ? -4 : 0)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(DS.Motion.gentle(DS.Motion.settle)) { hover = inside } }
        .accessibilityHidden(true)
    }

    private var miniCard: some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(LinearGradient(colors: [Color.white.opacity(index == 1 && hover ? 0.42 : 0.26), Color.white.opacity(0.1)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 40, height: 27)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(index == 1 && hover ? hue : Color.white.opacity(0.12), lineWidth: index == 1 && hover ? 1.2 : 0.5)
                    }
                    .opacity(index == 2 ? 0.6 : 1)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1)))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
    }
}
