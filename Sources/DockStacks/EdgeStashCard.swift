import AppKit
import DockCore
import SwiftUI

// MARK: - Edge Stash card
//
// Lives in Window Engine › Window superpowers, after Window Switcher. The plate plays the idea
// in miniature: a window is flung to the left edge and slides out, leaving a glowing tab; the
// pointer touches the tab, the window springs back in, the pointer leaves and it slides out
// again. Below the controls, every window stashed right now, each with its own Bring Back.

struct EdgeStashCard: View {
    @ObservedObject private var stash = EdgeStash.shared
    /// False only from offline renders; live, the row below follows the permission itself.
    var trusted = true
    private let hue = DS.Spectrum.windows

    var body: some View {
        HeroCard("Edge Stash",
                 pitch: "Fling a window against the left or right edge with \(stash.key.symbol) held. It waits there as a glowing tab; point at it to slide it back.",
                 isOn: $stash.enabled, hue: hue,
                 readout: "\(stash.items.count)", readoutCaption: "Stashed") {
            LivePlate { size, since in EdgeStashPlate(size: size, since: since, hue: hue) }
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                NeedsAccessRow(reason: "To move the window you fling.", previewTrusted: trusted ? nil : false)
                HStack(spacing: 12) {
                    Text("Hold").font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 60, alignment: .leading)
                    Segments(selection: $stash.key, options: EdgeStashKey.allCases.map { ($0, $0.symbol) })
                }
                HeroSlider(title: "Return", value: $stash.returnDelay, range: 0.15...1.5, hue: hue) {
                    String(format: "%.2f s", $0)
                }
                VStack(spacing: 2) {
                    SettingRow(title: "Fling to Stash", detail: "A quick throw towards an edge counts, not only a drop against it.",
                               density: .compact) {
                        LuxSwitch(isOn: $stash.fling, label: "Fling to Stash", tint: hue)
                    }
                    SettingRow(title: "Bring Forward on Peek", detail: "The window takes the keyboard while it is out, then hands it back.",
                               density: .compact) {
                        LuxSwitch(isOn: $stash.bringForward, label: "Bring Forward on Peek", tint: hue)
                    }
                    SettingRow(title: "Keys", detail: "⌃⌥⌘← and ⌃⌥⌘→ stash the front window, or show and hide the last stash. ⌃⌥⌘↓ brings everything back.",
                               density: .compact) {
                        LuxSwitch(isOn: $stash.hotKeysEnabled, label: "Edge Stash keys", tint: hue)
                    }
                }
                if !stash.hotKeyConflicts.isEmpty {
                    Text("Taken by another app: \(stash.hotKeyConflicts.joined(separator: ", ")).")
                        .font(DS.caption).foregroundStyle(.orange.opacity(0.9))
                }
                if !stash.items.isEmpty { stashedList }
                Text("Click a tab to bring its window back for good. Turning this off, quitting Atelier, or a crash puts every window back exactly where it was.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = stash.status {
                    Text(status).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
            }
        }
    }

    private var stashedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("STASHED").font(DS.eyebrow).tracking(0.6).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Button("Bring All Back") { stash.unstashAll() }
                    .buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.Ink.secondary)
            }
            ForEach(stash.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: item.record.edge == .left ? "rectangle.lefthalf.inset.filled.arrow.left"
                                                                : "rectangle.righthalf.inset.filled.arrow.right")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(hue)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.record.appName).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                        Text(item.record.title.isEmpty ? "Untitled" : item.record.title)
                            .font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Chip("Bring Back") { stash.unstash(item) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
            }
        }
    }
}

/// The plate: a window carried to the left edge slides out, a tab lights up where it went, the
/// pointer touches the tab and the window springs back in, then leaves again. Five seconds a
/// loop. At rest it shows the stashed state: the tab glowing and the sliver at the edge.
struct EdgeStashPlate: View {
    let size: CGSize
    let since: Date?
    var hue: Color

    var body: some View {
        PlateClock(since: since, rest: 1.6) { time in scene(time.truncatingRemainder(dividingBy: 5)) }
    }

    /// A critically damped approach from 0 to 1 over roughly `duration`.
    private func settle(_ t: Double, _ duration: Double) -> Double {
        guard t > 0 else { return 0 }
        let x = min(t / duration, 1) * 5
        return 1 - (1 + x) * exp(-x)
    }

    /// A lightly underdamped approach, for the peek coming in with a little life.
    private func spring(_ t: Double, _ duration: Double) -> Double {
        guard t > 0 else { return 0 }
        let x = t / duration * 6
        return 1 - exp(-x * 0.8) * cos(x * 1.25)
    }

    private func scene(_ t: Double) -> some View {
        let w = min(size.width * 0.32, 190), h = min(size.height * 0.56, 82)
        let home = size.width * 0.42 - w / 2
        let out = -w + 3
        let peekX = 10.0
        // 0–0.9 carried towards the edge, 0.9–1.4 out, 2.0–2.6 peek in, 3.6–4.1 out again, 4.6 fades home.
        let x: Double
        if t < 0.9 { x = home + (out + w * 0.55 - home) * settle(t, 0.9) * 0.62 }
        else if t < 2.0 { let from = home + (out + w * 0.55 - home) * 0.62; x = from + (out - from) * settle(t - 0.9, 0.45) }
        else if t < 3.6 { x = out + (peekX - out) * spring(t - 2.0, 0.55) }
        else if t < 4.6 { x = peekX + (out - peekX) * settle(t - 3.6, 0.4) }
        else { x = out + (home - out) * settle(t - 4.6, 0.4) }
        let stashed = t >= 1.2 && t < 4.7
        let peeking = t >= 2.0 && t < 3.7
        let pointer = CGPoint(x: t < 1.9 ? 30 + (1 - settle(t - 1.2, 0.6)) * 60 : (t < 3.3 ? 6 : 6 + settle(t - 3.3, 0.5) * 140),
                              y: size.height * 0.5 + (t < 3.3 ? 0 : settle(t - 3.3, 0.5) * 20))
        let y = size.height * 0.5 - h / 2
        return ZStack(alignment: .topLeading) {
            // The screen's left edge, a hairline of bezel.
            Rectangle().fill(.white.opacity(0.12)).frame(width: 1, height: size.height)
            PlateWindow(tint: hue, focused: true, corner: 7)
                .frame(width: w, height: h)
                .offset(x: x, y: y)
            // The tab: glass, lit rim, a dot of app icon.
            UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 8, topTrailing: 8),
                                   style: .continuous)
                .fill(hue.opacity(peeking ? 0.55 : 0.35))
                .overlay {
                    UnevenRoundedRectangle(cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 8, topTrailing: 8),
                                           style: .continuous)
                        .strokeBorder(.white.opacity(peeking ? 0.7 : 0.4), lineWidth: 0.75)
                }
                .overlay { Circle().fill(.white.opacity(0.85)).frame(width: 6, height: 6) }
                .frame(width: 13, height: 34)
                .shadow(color: hue.opacity(peeking ? 0.9 : 0.6), radius: peeking ? 7 : 4)
                .scaleEffect(x: stashed ? 1 : 0.2, y: stashed ? 1 : 0.6, anchor: .leading)
                .opacity(stashed ? 1 : 0)
                .animation(DS.Motion.settle, value: stashed)
                .animation(DS.Motion.hover, value: peeking)
                .offset(x: 0, y: size.height * 0.5 - 17)
            Image(systemName: "cursorarrow")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                .opacity(t > 1.2 && t < 4.3 ? 1 : 0)
                .offset(x: pointer.x, y: pointer.y - 6)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
    }
}
