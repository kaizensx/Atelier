import AppKit
import DockCore
import SwiftUI

// MARK: - Gestures & Peek for the Atelier Dock: settings
//
// Shown in place of the Dock Peek card (`SystemDockPeekCard`) while the Atelier Dock replaces the
// macOS Dock, when Dock Peek for Apple's Dock would only be resting.

struct OwnDockGesturesCard: View {
    @ObservedObject private var model = OwnDockGestures.shared
    @ObservedObject private var dock = OwnDock.shared
    private let hue = DS.Spectrum.surfaces

    var body: some View {
        HeroCard("Dock Gestures",
                 pitch: "Swipe and pinch on the Atelier Dock's icons. Close or minimise windows right from Live Peek.",
                 isOn: $model.enabled, hue: hue,
                 readout: model.settings.up.title, readoutCaption: "swipe up") {
            OwnDockGesturesPlate(hue: hue, up: model.settings.up, down: model.settings.down)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                ForEach(Array(model.notes.enumerated()), id: \.offset) { _, note in
                    AvailabilityNote(availability: note)
                }
                SectionHeader("Gestures on app icons", symbol: "hand.draw",
                              detail: "Only over a running app's icon; everywhere else scrolling is untouched.", hue: hue)
                RowGroup {
                    SettingRow(title: "Swipe up", detail: "Two fingers up on an icon.", symbol: "arrow.up", density: .compact) {
                        Segments(selection: $model.settings.up,
                                 options: OwnDockGestureSettings.upChoices.map { ($0, $0 == .none ? "Off" : $0 == .expose ? "Exposé" : "Restore") })
                            .frame(width: 230)
                    }
                    SettingRow(title: "Swipe down", detail: "Two fingers down on an icon.", symbol: "arrow.down", density: .compact) {
                        Segments(selection: $model.settings.down,
                                 options: OwnDockGestureSettings.downChoices.map { ($0, $0 == .none ? "Off" : $0 == .minimize ? "Minimise" : "Hide") })
                            .frame(width: 230)
                    }
                    SettingRow(title: "Pinch to quit", detail: "Pinch in, then again within two seconds, to quit the app.",
                               symbol: "hand.pinch", density: .compact) {
                        LuxSwitch(isOn: $model.settings.pinch, label: "Pinch to quit", tint: hue)
                    }
                    SettingRow(title: "Scroll for Windows",
                               detail: model.settings.swipes ? "Scroll sideways, or turn the mouse wheel, to step through an app's windows."
                                   : "Scroll on an icon to step through its windows.",
                               symbol: "rectangle.stack", density: .compact) {
                        LuxSwitch(isOn: $dock.appearance.scrollWindows, label: "Scroll for Windows", tint: hue)
                    }
                }
                SectionHeader("Live Peek", symbol: "rectangle.on.rectangle",
                              detail: "Rest the pointer on a running app to see its windows, minimised ones too.", hue: hue)
                RowGroup {
                    SettingRow(title: "Window previews",
                               detail: DockWindowShots.shared.allowed ? "A picture of each window; click one to bring it forward."
                                   : "Each window's icon and title; click one to bring it forward.",
                               symbol: "macwindow.on.rectangle", density: .compact) {
                        LuxSwitch(isOn: $dock.hub.windowPreviews, label: "Window previews", tint: hue)
                    }
                    SettingRow(title: "Close and minimise buttons", detail: "On the window under the pointer.",
                               symbol: "xmark.circle", density: .compact) {
                        LuxSwitch(isOn: $model.buttons, label: "Close and minimise buttons", tint: hue)
                    }
                }
            }
        }
    }
}

/// The plate: the Atelier Dock with one icon lifted, its window card over it, and the two swipes
/// drawn as arrows. With the pointer over the plate the icon rises, the card's hot window lights
/// its close button, and the arrows travel; Reduce Motion keeps them still.
private struct OwnDockGesturesPlate: View {
    let hue: Color
    let up: OwnDockGestureAction
    let down: OwnDockGestureAction
    @State private var hover = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let tile = 22.0, gap = 7.0, count = 7, lifted = 3
            let bar = CGSize(width: Double(count) * tile + Double(count + 1) * gap, height: tile + gap * 2)
            let barY = height - bar.height / 2 - 12
            let liftedX = width / 2 - bar.width / 2 + gap + Double(lifted) * (tile + gap) + tile / 2
            let travel = hover && !reduceMotion ? 6.0 : 0
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
                miniCard
                    .position(x: liftedX, y: barY - bar.height / 2 - 40)
                    .offset(y: hover ? -4 : 0)
                if up != .none {
                    arrow("chevron.up", up.title)
                        .position(x: liftedX + 86, y: barY - 50 - travel)
                }
                if down != .none {
                    arrow("chevron.down", down.title)
                        .position(x: liftedX + 86, y: barY - 18 + travel)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in withAnimation(DS.Motion.gentle(DS.Motion.settle)) { hover = inside } }
        .accessibilityHidden(true)
    }

    private func arrow(_ symbol: String, _ title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(title).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(hover ? 0.95 : 0.7))
        .padding(.horizontal, 7)
        .frame(height: 18)
        .background(.black.opacity(0.35), in: .capsule)
        .overlay { Capsule().strokeBorder(hover ? hue.opacity(0.8) : .white.opacity(0.12), lineWidth: 0.5) }
        .fixedSize()
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
                    .overlay(alignment: .topTrailing) {
                        if index == 1 && hover {
                            Circle().fill(WindowButtonFace.closeTint).frame(width: 7, height: 7).padding(3)
                                .transition(.opacity.combined(with: .scale(scale: 0.6)))
                        }
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
