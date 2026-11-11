import AppKit
import DockCore
import SwiftUI

// MARK: - External Monitors card
//
// Lives in Display & Appearance, right after the Light heroes (XDR Boost, Below Black,
// Candlelight): it is light too, only on the other screens. The plate draws each connected
// monitor lit to its real brightness, with the cable it is driven through; under the pointer a
// pulse runs down each cable, once per DDC write it stands for. The controls are one block per
// monitor (brightness, contrast, volume and mute, input), then the keys and the fallback.
//
// Motion: sliders are direct (no animation), the plate's levels settle with a critically
// damped spring, nothing eases in, Reduce Motion stills the plate.

struct ExternalMonitorsCard: View {
    @ObservedObject private var engine = ExternalMonitors.shared
    @ObservedObject private var hud = AtelierHUD.shared
    private let hue = DS.Spectrum.light

    private var readout: String {
        guard engine.enabled else { return "Off" }
        let count = engine.monitors.count
        return count == 0 ? "None" : count == 1 ? "1 monitor" : "\(count) monitors"
    }

    var body: some View {
        let availability = engine.availability
        HeroCard("External Monitors",
                 pitch: "Real brightness, contrast and volume on your monitors, sent down the cable. The keys follow the pointer.",
                 isOn: $engine.enabled, hue: hue,
                 readout: readout, readoutCaption: "DDC/CI",
                 preview: .overlay("display.ddc", "External Monitors", isOn: engine.enabled) { size in ExternalMonitorsPreview(size: size) }) {
            MonitorsPlate(monitors: engine.enabled ? engine.monitors : [], hue: hue).displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if engine.monitors.isEmpty {
                    Text("Connect a monitor over USB-C, Thunderbolt, DisplayPort or HDMI. The built-in display stays with macOS.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(engine.monitors) { monitor in
                        MonitorControls(monitor: monitor, engine: engine, hue: hue)
                        if monitor.id != engine.monitors.last?.id {
                            Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                        }
                    }
                }
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                settings
            }
        }
    }

    private var keysOwned: Bool { hud.brightness || hud.volume }

    @ViewBuilder private var settings: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SettingRow(title: "Brightness and volume keys",
                       detail: keysOwned ? "Move the monitor under the pointer, with Atelier's overlay. ⌥⇧ for quarter steps."
                                         : "Atelier HUD takes the keys from macOS first.",
                       symbol: "keyboard", density: .compact) {
                if keysOwned {
                    LuxSwitch(isOn: $engine.keysEnabled, label: "Brightness and volume keys", tint: hue)
                } else {
                    Button("Turn on") {
                        hud.brightness = true
                        hud.volume = true
                        engine.keysEnabled = true
                    }
                    .buttonStyle(MonitorPillStyle(hue: hue))
                }
            }
            SettingRow(title: "Dim monitors without DDC",
                       detail: "A monitor that answers nothing is dimmed in software, never to black.",
                       symbol: "circle.lefthalf.filled", density: .compact) {
                LuxSwitch(isOn: $engine.softwareFallback, label: "Dim monitors without DDC", tint: hue)
            }
            HStack(spacing: DS.Space.s) {
                Button("Put back each monitor's own settings") { engine.restoreMonitors() }
                    .buttonStyle(MonitorPillStyle(hue: hue, quiet: true))
                    .disabled(engine.monitors.isEmpty)
                Spacer(minLength: 0)
                if let note = engine.lastNote {
                    Text(note).font(DS.caption).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: One monitor

private struct MonitorControls: View {
    let monitor: ExternalMonitors.Monitor
    @ObservedObject var engine: ExternalMonitors
    let hue: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "display").font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                Text(monitor.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                RouteBadge(monitor: monitor, hue: hue)
                Spacer(minLength: 0)
                if monitor.probing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Asking the monitor")
                }
            }
            switch monitor.route {
            case .ddc, .software:
                LevelRow(symbol: "sun.max.fill", label: "Brightness", value: monitor.brightness, hue: hue) {
                    engine.set(.brightness, $0, on: monitor.id)
                }
                if let contrast = monitor.contrast {
                    LevelRow(symbol: "circle.righthalf.filled", label: "Contrast", value: contrast, hue: hue) {
                        engine.set(.contrast, $0, on: monitor.id)
                    }
                }
                if let volume = monitor.volume {
                    LevelRow(symbol: volumeSymbol(volume), label: "Volume", value: volume, hue: hue,
                             onSymbol: monitor.muted.map { muted in { engine.setMuted(!muted, on: monitor.id) } }) {
                        engine.set(.volume, $0, on: monitor.id)
                    }
                }
                if monitor.route == .ddc, let input = monitor.input { inputRow(input) }
            case .native:
                note("An Apple display: the brightness keys and Control Center already drive it.")
            case .none:
                note("Answers nothing over DDC. Turn on software dimming below to dim it anyway.")
            }
        }
    }

    private func volumeSymbol(_ volume: Double) -> String {
        if monitor.muted == true { return "speaker.slash.fill" }
        return volume < 0.01 ? "speaker.fill" : volume < 0.34 ? "speaker.wave.1.fill" : volume < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    private func note(_ text: String) -> some View {
        Text(text).font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func inputRow(_ input: UInt16) -> some View {
        let choices = DDCInput.common.contains(input) ? DDCInput.common : [input] + DDCInput.common
        return HStack(spacing: DS.Space.m) {
            Image(systemName: "cable.connector").font(.system(size: 12, weight: .medium))
                .foregroundStyle(DS.Ink.secondary).frame(width: 18)
            Text("Input").font(DS.caption).foregroundStyle(DS.Ink.secondary)
            Spacer(minLength: 0)
            Menu {
                ForEach(choices, id: \.self) { raw in
                    Button {
                        engine.setInput(raw, on: monitor.id)
                    } label: {
                        if raw == input { Label(DDCInput.name(raw), systemImage: "checkmark") } else { Text(DDCInput.name(raw)) }
                    }
                }
            } label: {
                Text(DDCInput.name(input)).font(DS.Typo.value)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Switching hands the monitor to whatever is on that port.")
        }
    }
}

private struct RouteBadge: View {
    let monitor: ExternalMonitors.Monitor
    let hue: Color

    var body: some View {
        let lit = monitor.route == .ddc
        Text(monitor.probing ? "Asking…" : monitor.routeLabel)
            .font(DS.Typo.badge).tracking(0.6)
            .foregroundStyle(lit ? Color.black.opacity(0.85) : DS.Ink.secondary)
            .padding(.horizontal, 7).frame(height: 18)
            .background(lit ? hue : DS.Ink.fill, in: .capsule)
            .contentTransition(.opacity)
            .animation(DS.Motion.settle, value: monitor.route)
    }
}

/// Glyph, slider, percentage. The glyph is a button when it has something to toggle (mute).
private struct LevelRow: View {
    let symbol: String
    let label: String
    let value: Double
    let hue: Color
    var onSymbol: (() -> Void)?
    let set: @MainActor @Sendable (Double) -> Void

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Group {
                if let onSymbol {
                    Button(action: onSymbol) { glyph }.buttonStyle(Pressable(scale: 0.9))
                        .accessibilityLabel("Mute")
                } else {
                    glyph.accessibilityHidden(true)
                }
            }
            .frame(width: 18)
            LuxSlider(value: Binding(get: { value }, set: set), range: 0...1, label: label, tint: hue)
            Text("\(Int((value * 100).rounded()))%").font(DS.Typo.value).foregroundStyle(DS.Ink.secondary)
                .frame(width: 40, alignment: .trailing)
                .contentTransition(.numericText())
        }
    }

    private var glyph: some View {
        Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.secondary)
    }
}

private struct MonitorPillStyle: ButtonStyle {
    var hue: Color
    var quiet = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(quiet ? DS.Ink.primary : Color.black.opacity(0.85))
            .padding(.horizontal, 12).frame(height: 26)
            .background(quiet ? DS.Ink.fill : hue, in: .capsule)
            .overlay { Capsule().strokeBorder(quiet ? DS.Ink.edge : .clear, lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
    }
}

// MARK: The plate

/// Each monitor as a lit screen on a stand, glowing at its real brightness, its cable running
/// down to the Mac. With none connected, one outlined ghost waits.
private struct MonitorsPlate: View {
    let monitors: [ExternalMonitors.Monitor]
    let hue: Color

    var body: some View {
        HeroLife { live in
            HeroClock(live: live) { t in
                Canvas { g, size in draw(&g, size: size, t: t, live: live) }
            }
        }
        .animation(DS.Motion.settle, value: monitors.map(\.brightness))
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, live: Bool) {
        let shown = Array(monitors.prefix(3))
        let count = max(shown.count, 1)
        let usable = size.width - 170
        let w = min(150, (usable - Double(count - 1) * 18) / Double(count))
        let h = w * 0.58
        let top = 30.0
        let hub = CGPoint(x: 24 + usable / 2, y: size.height - 14)
        for i in 0..<count {
            let x = 24 + (usable - (Double(count) * w + Double(count - 1) * 18)) / 2 + Double(i) * (w + 18)
            let screen = CGRect(x: x, y: top, width: w, height: h)
            let bezel = Path(roundedRect: screen.insetBy(dx: -3, dy: -3), cornerRadius: 6)
            let stand = CGPoint(x: screen.midX, y: screen.maxY + 3)
            guard i < shown.count else {
                g.stroke(bezel, with: .color(.white.opacity(0.28)), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                g.draw(Text("No monitor").font(.system(size: 11, weight: .medium)).foregroundColor(.white.opacity(0.5)),
                       at: CGPoint(x: screen.midX, y: screen.midY))
                continue
            }
            let monitor = shown[i]
            let level = monitor.route == .ddc || monitor.route == .software ? monitor.brightness : 0.55
            // Glow behind, in the family's light, as strong as the monitor is bright.
            g.fill(Path(ellipseIn: screen.insetBy(dx: -w * 0.25, dy: -h * 0.35)),
                   with: .radialGradient(Gradient(colors: [hue.opacity(0.32 * level), .clear]),
                                         center: CGPoint(x: screen.midX, y: screen.midY), startRadius: 0, endRadius: w * 0.75))
            g.fill(bezel, with: .color(Color(white: 0.11)))
            let lum = 0.06 + 0.84 * pow(level, 0.7)
            g.fill(Path(roundedRect: screen, cornerRadius: 3),
                   with: .linearGradient(Gradient(colors: [Color(white: lum), Color(white: lum * 0.78)]),
                                         startPoint: CGPoint(x: screen.minX, y: screen.minY), endPoint: CGPoint(x: screen.maxX, y: screen.maxY)))
            // Neck and foot.
            g.fill(Path(CGRect(x: stand.x - 4, y: stand.y, width: 8, height: 12)), with: .color(Color(white: 0.2)))
            g.fill(Path(roundedRect: CGRect(x: stand.x - 18, y: stand.y + 12, width: 36, height: 3), cornerRadius: 1.5), with: .color(Color(white: 0.24)))
            // The cable down to the Mac, solid for DDC, dotted for software.
            var cable = Path()
            let from = CGPoint(x: stand.x, y: stand.y + 15)
            cable.move(to: from)
            cable.addQuadCurve(to: hub, control: CGPoint(x: from.x, y: hub.y))
            let ddc = monitor.route == .ddc
            g.stroke(cable, with: .color((ddc ? hue : .white).opacity(ddc ? 0.6 : 0.22)),
                     style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: ddc ? [] : [2, 4]))
            if live && ddc {
                // One packet running down the cable.
                let p = (t * 0.9 + Double(i) * 0.33).truncatingRemainder(dividingBy: 1)
                let pt = quad(from, CGPoint(x: from.x, y: hub.y), hub, p)
                g.fill(Path(ellipseIn: CGRect(x: pt.x - 2.5, y: pt.y - 2.5, width: 5, height: 5)), with: .color(hue))
            }
            let percent = "\(Int((level * 100).rounded()))%"
            g.draw(Text(monitor.route == .native ? "Apple" : percent).font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(lum > 0.55 ? .black.opacity(0.7) : .white.opacity(0.85)),
                   at: CGPoint(x: screen.midX, y: screen.midY))
        }
        g.fill(Path(ellipseIn: CGRect(x: hub.x - 3, y: hub.y - 3, width: 6, height: 6)), with: .color(.white.opacity(0.5)))
    }

    private func quad(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }
}

/// The stage shows the built-in screen, which Atelier never touches over DDC: say so, honestly.
struct ExternalMonitorsPreview: View {
    let size: CGSize
    @ObservedObject private var engine = ExternalMonitors.shared

    var body: some View {
        VStack {
            Spacer()
            Label(engine.monitors.isEmpty ? "Acts on external monitors, not this screen"
                                          : "Brightness keys move the monitor under the pointer",
                  systemImage: "display.2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: .capsule)
                .overlay { Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5) }
                .padding(.bottom, 18)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
