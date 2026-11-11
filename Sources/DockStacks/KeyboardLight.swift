import AppKit
import Combine
import DockCore
import SwiftUI

// MARK: - Keyboard Light
//
// Apple silicon MacBooks lost their key-light keys, and System Settings keeps only an
// auto-brightness switch and a short list of idle times. CoreBrightness still has the whole
// control: a level, an idle time of any length, and a switch that keeps the light on however
// long the keyboard rests. Atelier reads all of it at launch and changes nothing until asked.
// Intel MacBooks (all T2 models on macOS 14+) use the same client and keep their F5/F6 keys;
// desktops have no backlight, and the card says so.

@MainActor
final class KeyboardLight: ObservableObject {
    static let shared = KeyboardLight()

    /// 0 to 1, as CoreBrightness has it now.
    @Published private(set) var level = 0.0
    /// Seconds of rest before the light goes out, as CoreBrightness has it.
    @Published private(set) var idle = 300.0
    /// The light stays on however long the keyboard rests. CoreBrightness forgets this at
    /// logout, so Atelier keeps it and sets it again at launch.
    @Published private(set) var neverDim: Bool
    @Published private(set) var auto = false

    let backlight = KeyboardBacklight()
    var available: Bool { backlight != nil }
    var ambientAvailable: Bool { backlight?.ambientAvailable ?? false }
    /// Whether this macOS lets the rest time be set; checked by method type, not assumed.
    var idleAdjustable: Bool { (backlight?.canSetIdle ?? false) && (backlight?.canSuspendIdle ?? false) }

    var availability: FeatureAvailability {
        guard available else { return .unavailable("No backlit keyboard on this Mac") }
        if !idleAdjustable { return .limited("This macOS doesn’t let Atelier change the rest time") }
        return .available
    }

    private let store = UserDefaults.standard

    private init() {
        neverDim = UserDefaults.standard.bool(forKey: "kbd.neverDim")
        refresh()
        // The first idle time Atelier ever saw is what Restore puts back.
        if available, store.object(forKey: "kbd.originalIdle") == nil {
            store.set(idle, forKey: "kbd.originalIdle")
        }
    }

    func resume() {
        if neverDim { backlight?.suspendIdleDimming(true) }
    }

    /// Reads the real values again: the light changes under ambient light and from Control Center.
    func refresh() {
        guard let backlight else { return }
        level = backlight.brightness
        idle = backlight.idleDimTime
        auto = backlight.autoBrightness
    }

    /// Sets the level; `commit: false` while a slider is still moving, so CoreBrightness saves
    /// only where it comes to rest.
    func setLevel(_ value: Double, commit: Bool) {
        guard let backlight else { return }
        level = min(max(value, 0), 1)
        backlight.setBrightness(level, commit: commit)
    }

    /// One key press' worth, from the light as it is now. Nil when there is no backlight, so
    /// the key goes through untouched.
    func step(up: Bool, fine: Bool) -> Double? {
        guard let backlight else { return nil }
        let next = HUDStep.step(backlight.brightness, up: up, fine: fine)
        setLevel(next, commit: true)
        return next
    }

    func setIdle(_ seconds: Double) {
        guard let backlight, idleAdjustable else { return }
        if seconds <= 0 {
            neverDim = true
            backlight.suspendIdleDimming(true)
        } else {
            neverDim = false
            backlight.suspendIdleDimming(false)
            backlight.setIdleDimTime(seconds)
            idle = seconds
        }
        store.set(neverDim, forKey: "kbd.neverDim")
    }

    func setAuto(_ on: Bool) {
        backlight?.setAutoBrightness(on)
        auto = on
    }

    /// Auto-brightness on, idle dimming back, and the idle time this Mac had before Atelier.
    func restoreDefaults() {
        setAuto(true)
        setIdle(store.object(forKey: "kbd.originalIdle") as? Double ?? 300)
        refresh()
    }

    var isDefault: Bool {
        auto && !neverDim && idle == (store.object(forKey: "kbd.originalIdle") as? Double ?? 300)
    }
}

struct KeyboardLightCard: View {
    @ObservedObject private var light = KeyboardLight.shared
    /// The card follows the light while it is on screen: ambient light and Control Center move it too.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var dragging = false
    /// Where the light was before the hero's switch put it out, so switching on brings it back.
    @State private var lastLit = 0.5

    /// On is simply "the keys are lit"; switching on restores the last level.
    private var lit: Binding<Bool> {
        Binding(get: { light.level > 0.004 || dragging }, set: { on in
            if on {
                light.setLevel(max(lastLit, 0.25), commit: true)
            } else {
                lastLit = max(light.level, 0.25)
                light.setLevel(0, commit: true)
            }
        })
    }

    private var idleText: String { light.neverDim ? "Stays on" : "Off after \(KeyboardIdle.label(light.idle))" }

    var body: some View {
        HeroCard("Keyboard Light",
                 pitch: !light.available ? "No backlit keyboard found on this Mac."
                     : MacPlatform.appleSilicon ? "The controls Apple silicon keyboards lost: a level, and rest times System Settings stops short of."
                     : "Every control the key light has: a level, and rest times System Settings stops short of.",
                 isOn: lit.displayCompatGated(light.availability), hue: DS.Spectrum.surfaces,
                 readout: light.available ? "\(HUDStep.percent(light.level))%" : "—",
                 readoutCaption: light.available ? idleText : "No backlight",
                 preview: .overlay("keyboardLight", "Keyboard Light", isOn: true) { size in
                     KeyboardLightPreview(size: size, level: max(light.level, 0.6), idle: light.neverDim ? 0 : light.idle)
                 }) {
            KeysPlate(level: light.level).displayCompatNote(light.availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: 12) {
                    Image(systemName: HUDSymbol.name(.keyboard, level: light.level))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 22)
                    LuxSlider(value: Binding(get: { light.level }, set: { dragging = true; light.setLevel($0, commit: false) }),
                              range: 0...1, label: "Keyboard brightness", tint: DS.Spectrum.surfaces) {
                        dragging = false
                        light.setLevel(light.level, commit: true)
                    }
                    Text("\(HUDStep.percent(light.level))%").font(DS.Typo.value)
                        .foregroundStyle(DS.Ink.secondary).frame(width: 40, alignment: .trailing)
                }
                SettingRow(title: "Adjust in Low Light",
                           detail: light.ambientAvailable ? "Follows the room, as macOS does. The slider sets where it starts."
                                                          : "This keyboard has no light sensor to follow.",
                           density: .compact) {
                    LuxSwitch(isOn: Binding(get: { light.auto }, set: { light.setAuto($0) }),
                              label: "Adjust keyboard brightness in low light", tint: DS.Spectrum.surfaces)
                }
                if light.idleAdjustable {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Turn Off After").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    Text("From 5 seconds to half an hour, or never. System Settings stops at 5 minutes.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    Segments(selection: Binding(get: { selectedIdle }, set: { light.setIdle($0) }),
                             options: KeyboardIdle.choices.map { ($0, KeyboardIdle.label($0)) }) { seconds in
                        .overlay("keyboardLight.idle.\(Int(seconds))", "Turn Off After", isOn: true) { size in
                            KeyboardLightPreview(size: size, level: max(light.level, 0.6), idle: seconds)
                        }
                    }
                }
                }
                HStack {
                    Text(light.isDefault ? "As macOS had it." : "Changed by Atelier.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    Spacer()
                    Button("Restore Defaults") { withAnimation(DS.Motion.settle) { light.restoreDefaults() } }
                        .buttonStyle(Pressable(scale: 0.96))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.primary)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(DS.Ink.fill, in: .rect(cornerRadius: DS.Radius.control, style: .continuous))
                        .disabled(light.isDefault)
                        .opacity(light.isDefault ? 0.4 : 1)
                        .accessibilityHint("Turns low-light adjustment back on and puts back the original idle time")
                }
            }
        }
        .disabled(!light.available)
        .onAppear { light.refresh(); if light.level > 0.004 { lastLit = light.level } }
        .onReceive(tick) { _ in if !dragging { light.refresh() } }
    }

    /// The segment for what CoreBrightness has now, even when it was set to a time not offered.
    private var selectedIdle: Double { light.neverDim ? KeyboardIdle.never : KeyboardIdle.nearest(light.idle) }
}

/// Four rows of keycaps whose legends glow at the keyboard's level, with the light spilling
/// out underneath as a gradient. Under the pointer a key is pressed now and then, as typing.
private struct KeysPlate: View {
    let level: Double

    var body: some View {
        HeroLife { live in
            HeroClock(live: live, rest: -1) { t in
                Canvas { g, size in draw(&g, size: size, t: t, live: live) }
            }
        }
        .animation(DS.Motion.settle, value: level)
        .accessibilityHidden(true)
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, t: Double, live: Bool) {
        let columns = 12, rows = 4
        let key = 17.0, gap = 3.0
        let width = Double(columns) * key + Double(columns - 1) * gap
        let height = Double(rows) * key + Double(rows - 1) * gap
        let origin = CGPoint(x: (size.width - width) / 2 - 30, y: (size.height - height) / 2 + 10)
        let glow = min(max(level, 0), 1)
        // The light under the keys, rising through the gaps.
        let center = CGPoint(x: origin.x + width / 2, y: origin.y + height / 2)
        g.fill(Path(ellipseIn: CGRect(x: center.x - width * 0.75, y: center.y - height, width: width * 1.5, height: height * 2)),
               with: .radialGradient(Gradient(colors: [.white.opacity(0.16 * glow), .clear]), center: center, startRadius: 0, endRadius: width * 0.75))
        let deck = CGRect(x: origin.x - 7, y: origin.y - 7, width: width + 14, height: height + 14)
        g.fill(Path(roundedRect: deck, cornerRadius: 9, style: .continuous), with: .color(Color(white: 0.17)))
        let pressed = live ? Int(t * 7) * 7 % (columns * rows) : -1
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                let down = index == pressed
                let inset = down ? 1.0 : 0
                let rect = CGRect(x: origin.x + Double(column) * (key + gap) + inset, y: origin.y + Double(row) * (key + gap) + inset,
                                  width: key - 2 * inset, height: key - 2 * inset)
                g.fill(Path(roundedRect: rect, cornerRadius: 3.5, style: .continuous), with: .color(Color(white: 0.08)))
                // The legend, lit from beneath.
                let legend = CGRect(x: rect.midX - 2.5, y: rect.midY - 2.5, width: 5, height: 5)
                let shine = 0.14 + 0.86 * glow + (down ? 0.2 : 0)
                g.fill(Path(roundedRect: legend, cornerRadius: 1.2), with: .color(.white.opacity(min(shine, 1))))
                if glow > 0.05 {
                    g.fill(Path(ellipseIn: legend.insetBy(dx: -5, dy: -5)),
                           with: .radialGradient(Gradient(colors: [.white.opacity(0.22 * glow), .clear]),
                                                 center: CGPoint(x: legend.midX, y: legend.midY), startRadius: 0, endRadius: 7.5))
                }
            }
        }
    }
}

/// A backlit keyboard on the stage: typing, then resting until the light goes out after the
/// chosen time (shortened to fit the loop), or staying lit for Never.
struct KeyboardLightPreview: View {
    let size: CGSize
    let level: Double
    let idle: Double

    var body: some View {
        let w = size.width * 0.46
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 4.5)
            let typing = t < 1.4
            // The real time, squeezed into the loop's 3 s of rest: 5 s → 0.35 s, 30 min → 2.6 s.
            let rest = idle <= 0 ? .infinity : 0.3 + 2.3 * log10(idle / 5 + 1) / log10(361)
            let fade = typing ? 1 : max(0, min(1, 1 - (t - 1.4 - rest) / 0.4))
            let glow = level * fade
            let pressed = typing ? Int(t * 9) % 40 : -1
            VStack(spacing: w * 0.03) {
                keys(width: w, glow: glow, pressed: pressed)
                Text(idle <= 0 ? "Stays on" : "Off after \(KeyboardIdle.label(idle))")
                    .font(.system(size: w * 0.035, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, w * 0.035).padding(.vertical, w * 0.012)
                    .background(.black.opacity(0.45), in: .capsule)
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
    }

    private func keys(width w: Double, glow: Double, pressed: Int) -> some View {
        let key = w / 11.5
        return VStack(spacing: key * 0.14) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: key * 0.14) {
                    ForEach(0..<10, id: \.self) { column in
                        let lit = row * 10 + column == (pressed * 7) % 40
                        RoundedRectangle(cornerRadius: key * 0.18, style: .continuous)
                            .fill(Color(white: 0.09))
                            .overlay {
                                // The legend glows through the keycap, as the real light does.
                                RoundedRectangle(cornerRadius: key * 0.06)
                                    .fill(.white.opacity(0.15 + 0.85 * glow))
                                    .frame(width: key * 0.22, height: key * 0.22)
                                    .shadow(color: .white.opacity(glow * 0.9), radius: key * 0.18) // fixed radius: only the opacity follows the light
                            }
                            .scaleEffect(lit ? 0.9 : 1)
                            .frame(width: key, height: key)
                    }
                }
            }
        }
        .padding(key * 0.4)
        .background(Color(white: 0.2), in: .rect(cornerRadius: key * 0.4, style: .continuous))
        .shadow(color: .white.opacity(glow * 0.12), radius: key * 0.8)
    }
}
