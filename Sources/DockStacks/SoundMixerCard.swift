import AppKit
import DockCore
import SwiftUI

// MARK: - Sound Mixer card
//
// The hero for SoundMixer: the EQ's real response drawn across the plate (it morphs when a
// preset changes and follows the pointer 1:1 while a band is dragged), the apps playing right
// now with a volume slider that goes to 150 %, a mute and an output picker each, then the EQ
// itself with its presets and an optional curve of its own for the current output.
//
// Motion: drags are direct (no animation at all), everything that settles is a critically
// damped spring, nothing eases in, and Reduce Motion turns movement into a short cross-fade.

// MARK: Animatable curve

/// Ten band gains as one animatable value, so a preset change morphs the drawn curve.
struct EQGains: VectorArithmetic, Sendable {
    var values: [Double]

    init(_ values: [Double]) {
        self.values = (0..<SoundEQ.bandCount).map { $0 < values.count ? values[$0] : 0 }
    }

    static var zero: EQGains { EQGains([]) }
    static func + (a: EQGains, b: EQGains) -> EQGains { EQGains(zip(a.values, b.values).map(+)) }
    static func - (a: EQGains, b: EQGains) -> EQGains { EQGains(zip(a.values, b.values).map(-)) }
    mutating func scale(by rhs: Double) { values = values.map { $0 * rhs } }
    var magnitudeSquared: Double { values.reduce(0) { $0 + $1 * $1 } }
}

/// The plot's scale: ±15 dB fills the height, so a full ±12 dB slider plus neighbours fits.
private enum EQPlot {
    static let span = 15.0
    static func y(_ db: Double, in rect: CGRect) -> Double {
        rect.midY - rect.height / 2 * min(max(db / span, -1.05), 1.05)
    }
    static func x(_ frequency: Double, in rect: CGRect) -> Double {
        rect.minX + rect.width * SoundEQ.logPosition(frequency)
    }
}

/// The cascade's response, 20 Hz to 20 kHz on a log axis. Optionally closed down to 0 dB, for
/// the fill.
private struct EQCurveShape: Shape {
    var gains: EQGains
    var closed = false

    var animatableData: EQGains {
        get { gains }
        set { gains = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let curve = SoundEQ.responseCurve(gains: gains.values, points: 96)
        for (i, point) in curve.enumerated() {
            let p = CGPoint(x: EQPlot.x(point.frequency, in: rect), y: EQPlot.y(point.db, in: rect))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
        return path
    }
}

/// Grid, the 0 dB line and the curve with its fill and glow. The glow is a wide faint stroke
/// under the line, never a shadow, so a morph never re-blurs.
private struct EQCurveGraph: View {
    let gains: [Double]
    let hue: Color
    var lit = true
    var grid = true

    var body: some View {
        ZStack {
            if grid {
                Canvas { context, size in
                    let rect = CGRect(origin: .zero, size: size)
                    for f in [100.0, 1000, 10000] {
                        let x = EQPlot.x(f, in: rect)
                        context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                       with: .color(DS.Ink.hairline), lineWidth: 0.5)
                    }
                    for db in [-12.0, -6, 6, 12] {
                        let y = EQPlot.y(db, in: rect)
                        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                       with: .color(DS.Ink.hairline.opacity(0.6)), lineWidth: 0.5)
                    }
                    let mid = size.height / 2
                    context.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                                   with: .color(.white.opacity(0.18)), style: StrokeStyle(lineWidth: 0.75, dash: [3, 4]))
                }
            }
            let g = EQGains(gains)
            EQCurveShape(gains: g, closed: true)
                .fill(LinearGradient(colors: [hue.opacity(lit ? 0.3 : 0.12), hue.opacity(0.03)], startPoint: .top, endPoint: .bottom))
            EQCurveShape(gains: g)
                .stroke(hue.opacity(lit ? 0.22 : 0.08), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            EQCurveShape(gains: g)
                .stroke(lit ? hue : hue.opacity(0.5), style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: The card

struct SoundMixerCard: View {
    @ObservedObject private var mixer = SoundMixer.shared
    private let hue = DS.Spectrum.sound

    var body: some View {
        let availability = SoundMixer.availability
        let playing = mixer.apps.filter(\.playing).count
        HeroCard("Sound Mixer",
                 pitch: availability.isUsable ? "Every app its own volume, up to 150 %, and its own speakers. An EQ for everything you hear."
                                              : "Per-app volume and a system-wide EQ need the audio taps macOS 14.2 added.",
                 isOn: $mixer.enabled.displayCompatGated(availability), hue: hue,
                 readout: playing == 0 ? "Quiet" : "\(playing) playing",
                 readoutCaption: mixer.settings.eqEnabled ? "EQ · " + mixer.eqProfile.preset.title : mixer.eqDeviceName) {
            MixerPlate(mixer: mixer, hue: hue).displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                MixerAppList(mixer: mixer, hue: hue)
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                MixerEQSection(mixer: mixer, hue: hue)
                footnote
            }
            .disabled(!availability.isUsable)
        }
        .onAppear { mixer.startWatching() }
        .onDisappear { mixer.stopWatching() }
    }

    @ViewBuilder private var footnote: some View {
        if let problem = mixer.problem {
            HStack(spacing: DS.Space.s) {
                AvailabilityNote(availability: .limited(problem))
                if mixer.permission == .denied { Chip("Open Settings") { mixer.openPrivacySettings() } }
            }
        } else {
            Text("Apps at 100 % on the default output are left alone: nothing is inserted, nothing is added to their latency.")
                .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Plate

/// The EQ's curve across the whole plate, and the icons of what is playing riding above it.
private struct MixerPlate: View {
    @ObservedObject var mixer: SoundMixer
    let hue: Color

    var body: some View {
        let gains = mixer.settings.eqEnabled ? mixer.eqProfile.gains : EQPreset.flat.gains!
        ZStack(alignment: .topLeading) {
            EQCurveGraph(gains: gains, hue: hue, lit: mixer.enabled && mixer.settings.eqEnabled)
                .padding(.top, 40).padding(.bottom, 26).padding(.horizontal, 16)
                .animation(DS.Motion.gentle(DS.Motion.arrive), value: gains)
            HStack(spacing: -6) {
                ForEach(mixer.apps.filter(\.playing).prefix(5)) { app in
                    PlateIcon(app: app, rule: mixer.rule(for: app.id), hue: hue)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .padding(.leading, 12).padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .animation(DS.Motion.gentle(DS.Motion.arrive), value: mixer.apps.map(\.id))
        }
    }
}

private struct PlateIcon: View {
    let app: MixerApp
    let rule: MixerAppRule
    let hue: Color

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let icon = app.icon { BitmapIcon(image: icon, pixels: 64) } else { Image(systemName: "app.fill").resizable() }
            }
            .frame(width: 22, height: 22)
            .opacity(rule.muted ? 0.4 : 1)
            if rule.muted || !SoundMixerGain.isUnity(rule.volume) {
                Circle().fill(rule.muted ? Color.orange : hue).frame(width: 6, height: 6)
                    .overlay { Circle().strokeBorder(.black.opacity(0.5), lineWidth: 1) }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Apps

private struct MixerAppList: View {
    @ObservedObject var mixer: SoundMixer
    let hue: Color

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack {
                Text("Apps").font(DS.Typo.section).foregroundStyle(DS.Ink.primary.opacity(0.92))
                Spacer(minLength: 0)
                if !mixer.settings.apps.isEmpty {
                    Button("Reset All") {
                        withAnimation(DS.Motion.gentle(DS.Motion.settle)) {
                            for id in mixer.settings.apps.keys { mixer.reset(id) }
                        }
                    }
                    .buttonStyle(.plain).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                }
            }
            if mixer.apps.isEmpty {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "speaker.zzz").foregroundStyle(DS.Ink.glyph)
                    Text("Nothing is playing. Apps appear here as soon as they make a sound.")
                        .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                }
                .padding(.vertical, DS.Space.s)
            } else {
                VStack(spacing: 0) {
                    ForEach(mixer.apps) { app in
                        MixerAppRow(mixer: mixer, app: app, hue: hue)
                        if app.id != mixer.apps.last?.id { Rectangle().fill(DS.Ink.hairline).frame(height: 0.5) }
                    }
                }
                .padding(.horizontal, DS.Space.m)
                .background { CardSurface(style: .standard, radius: DS.Radius.plate) }
                .animation(DS.Motion.gentle(DS.Motion.arrive), value: mixer.apps.map(\.id))
            }
        }
    }
}

/// One app: icon and name, where it plays, a volume slider with a notch at 100 %, its level,
/// mute and the output picker.
private struct MixerAppRow: View {
    @ObservedObject var mixer: SoundMixer
    let app: MixerApp
    let hue: Color
    var compact = false
    /// Above 100 %: the sound hue warmed towards orange, so a boost reads as a boost.
    static let boostHue = Color(red: 1.0, green: 0.55, blue: 0.5)

    var body: some View {
        let rule = mixer.rule(for: app.id)
        HStack(spacing: compact ? DS.Space.s : DS.Space.m) {
            icon.frame(width: compact ? 20 : 28, height: compact ? 20 : 28)
                .opacity(app.playing ? 1 : 0.55)
            if !compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    Text(caption(rule)).font(.system(size: 10.5)).foregroundStyle(DS.Ink.tertiary).lineLimit(1)
                }
                .frame(width: 118, alignment: .leading)
            }
            VolumeSlider(volume: Binding(get: { rule.volume }, set: { mixer.setVolume($0, for: app.id) }),
                         label: "\(app.name) volume", tint: rule.volume > 1.0001 ? Self.boostHue : hue)
                .opacity(rule.muted ? 0.4 : 1)
            Text(mixer.readout(for: app.id))
                .font(DS.Typo.value).foregroundStyle(rule.volume > 1.0001 && !rule.muted ? hue : DS.Ink.secondary)
                .contentTransition(.numericText())
                .frame(width: compact ? 40 : 46, alignment: .trailing)
            MuteButton(muted: rule.muted, hue: hue) { mixer.setMuted(!rule.muted, for: app.id) }
                .accessibilityLabel(rule.muted ? "Unmute \(app.name)" : "Mute \(app.name)")
            if !compact { OutputPicker(mixer: mixer, app: app, rule: rule, hue: hue) }
        }
        .padding(.vertical, compact ? 5 : DS.Space.s)
        .animation(DS.Motion.gentle(DS.Motion.settle), value: rule.muted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.name)
    }

    @ViewBuilder private var icon: some View {
        if let image = app.icon { BitmapIcon(image: image, pixels: 64) }
        else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(DS.Ink.glyph) }
    }

    private func caption(_ rule: MixerAppRule) -> String {
        let output = rule.deviceUID.flatMap { uid in mixer.outputs.first { $0.id == uid }?.name }
        if rule.deviceUID != nil && output == nil { return "Its speakers are away · default" }
        var parts: [String] = [output ?? "Default output"]
        if !app.playing { parts.append("not playing") }
        return parts.joined(separator: " · ")
    }
}

/// LuxSlider over 0…150 %, with a notch where 100 % is so "back to normal" is easy to find.
private struct VolumeSlider: View {
    @Binding var volume: Double
    let label: String
    let tint: Color

    var body: some View {
        LuxSlider(value: $volume, range: 0...SoundMixerGain.maxVolume, label: label, tint: tint)
            .background {
                GeometryReader { geometry in
                    let knob = 16.0
                    let x = 8 + (Double(geometry.size.width) - knob) * (1 / SoundMixerGain.maxVolume)
                    Capsule().fill(Color.white.opacity(0.35)).frame(width: 1.5, height: 12)
                        .position(x: x, y: geometry.size.height / 2)
                }
                .allowsHitTesting(false)
            }
            .frame(minWidth: 90)
    }
}

private struct MuteButton: View {
    let muted: Bool
    let hue: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(muted ? Color.orange : DS.Ink.secondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 26)
                .background(muted ? Color.orange.opacity(0.14) : DS.Ink.fill, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.9))
    }
}

private struct OutputPicker: View {
    @ObservedObject var mixer: SoundMixer
    let app: MixerApp
    let rule: MixerAppRule
    let hue: Color

    var body: some View {
        let chosen = rule.deviceUID.flatMap { uid in mixer.outputs.first { $0.id == uid } }
        let defaultOutput = mixer.outputs.first { $0.id == mixer.defaultOutputUID }
        Menu {
            Button {
                mixer.route(app.id, to: nil)
            } label: {
                Label("Default · " + (defaultOutput?.name ?? "System"), systemImage: rule.deviceUID == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(mixer.outputs) { output in
                Button {
                    mixer.route(app.id, to: output.id)
                } label: {
                    Label(output.name, systemImage: rule.deviceUID == output.id ? "checkmark" : output.symbol)
                }
            }
        } label: {
            Image(systemName: (chosen ?? defaultOutput)?.symbol ?? "speaker.wave.2")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(chosen != nil ? hue : DS.Ink.secondary)
                .frame(width: 26, height: 26)
                .background(chosen != nil ? hue.opacity(0.14) : DS.Ink.fill, in: .circle)
                .contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Play \(app.name) on…")
        .accessibilityLabel("Output for \(app.name)")
        .accessibilityValue(chosen?.name ?? "Default output")
    }
}

// MARK: EQ

private struct MixerEQSection: View {
    @ObservedObject var mixer: SoundMixer
    let hue: Color

    var body: some View {
        let profile = mixer.eqProfile
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Equalizer").font(DS.Typo.section).foregroundStyle(DS.Ink.primary.opacity(0.92))
                    Text(mixer.eqDeviceHasOwnCurve ? "Its own curve for \(mixer.eqDeviceName)" : "One curve for every output")
                        .font(.system(size: 10.5)).foregroundStyle(DS.Ink.tertiary)
                }
                Spacer(minLength: 0)
                PresetMenu(selection: profile.preset, hue: hue) { mixer.choose($0) }
                LuxSwitch(isOn: Binding(get: { mixer.settings.eqEnabled }, set: { mixer.eqEnabled = $0 }), label: "Equalizer", tint: hue)
            }
            EQEditor(gains: profile.gains, hue: hue, lit: mixer.settings.eqEnabled) { band, gain in
                mixer.setBand(band, gain: gain)
            }
            .frame(height: 150)
            .opacity(mixer.settings.eqEnabled ? 1 : 0.55)
            .animation(DS.Motion.gentle(DS.Motion.settle), value: mixer.settings.eqEnabled)
            HStack(spacing: DS.Space.s) {
                Image(systemName: mixer.outputs.first { $0.id == mixer.defaultOutputUID }?.symbol ?? "speaker.wave.2")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Ink.secondary)
                Text("Own curve for \(mixer.eqDeviceName)").font(DS.caption).foregroundStyle(DS.Ink.secondary)
                Spacer(minLength: 0)
                LuxSwitch(isOn: Binding(get: { mixer.eqDeviceHasOwnCurve }, set: { mixer.setOwnCurve($0) }),
                          label: "Own curve for \(mixer.eqDeviceName)", tint: hue)
                    .disabled(mixer.eqDeviceUID == nil)
            }
        }
    }
}

private struct PresetMenu: View {
    let selection: EQPreset
    let hue: Color
    let choose: (EQPreset) -> Void

    var body: some View {
        Menu {
            ForEach(EQPreset.allCases.filter { $0 != .custom }) { preset in
                Button {
                    withAnimation(DS.Motion.gentle(DS.Motion.arrive)) { choose(preset) }
                } label: {
                    Label(preset.title, systemImage: preset == selection ? "checkmark" : "")
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selection.title).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(DS.Ink.primary)
            .padding(.horizontal, 11).frame(height: 28)
            .background(DS.Ink.fillStrong, in: .capsule)
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Equalizer preset")
        .accessibilityValue(selection.title)
    }
}

/// The curve with a handle per band. Drag anywhere: the band nearest the pointer follows it
/// 1:1 (no animation while dragging); the curve redraws on every frame of the drag.
private struct EQEditor: View {
    let gains: [Double]
    let hue: Color
    let lit: Bool
    let set: (Int, Double) -> Void
    @State private var active: Int?
    @State private var hover: Int?

    var body: some View {
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 14, dy: 10)
            ZStack(alignment: .topLeading) {
                EQCurveGraph(gains: gains, hue: hue, lit: lit)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                ForEach(0..<SoundEQ.bandCount, id: \.self) { band in
                    handle(band, in: rect)
                }
                ForEach(0..<SoundEQ.bandCount, id: \.self) { band in
                    Text(SoundEQ.labels[band])
                        .font(.system(size: 9, weight: .medium)).monospacedDigit()
                        .foregroundStyle(active == band ? DS.Ink.primary : DS.Ink.tertiary)
                        .fixedSize()
                        .position(x: EQPlot.x(SoundEQ.frequencies[band], in: rect), y: geometry.size.height - 2)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let band = active ?? nearest(to: drag.startLocation.x, in: rect)
                    if active == nil { active = band }
                    let db = (rect.midY - Double(drag.location.y)) / (rect.height / 2) * EQPlot.span
                    set(band, min(max(db, SoundEQ.gainRange.lowerBound), SoundEQ.gainRange.upperBound))
                }
                .onEnded { _ in
                    withAnimation(DS.Motion.touch) { active = nil }
                })
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = nearest(to: point.x, in: rect)
                case .ended: hover = nil
                }
            }
        }
        .background { CardSurface(style: .quiet, radius: DS.Radius.plate) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Equalizer bands")
    }

    private func nearest(to x: Double, in rect: CGRect) -> Int {
        let position = (x - rect.minX) / max(rect.width, 1)
        return (0..<SoundEQ.bandCount).min { a, b in
            abs(SoundEQ.logPosition(SoundEQ.frequencies[a]) - position) < abs(SoundEQ.logPosition(SoundEQ.frequencies[b]) - position)
        } ?? 0
    }

    private func handle(_ band: Int, in rect: CGRect) -> some View {
        let gain = band < gains.count ? gains[band] : 0
        let x = EQPlot.x(SoundEQ.frequencies[band], in: rect)
        let y = EQPlot.y(gain, in: rect)
        let hot = active == band || hover == band
        return ZStack {
            if active == band {
                Text(String(format: "%+.1f dB", gain)).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(DS.Ink.primary)
                    .padding(.horizontal, 6).frame(height: 18)
                    .background(.black.opacity(0.55), in: .capsule)
                    .offset(y: gain > 6 ? 20 : -20)
                    .transition(.opacity)
            }
            Circle().fill(RadialGradient(colors: [hue.opacity(hot ? 0.5 : 0), .clear], center: .center, startRadius: 0, endRadius: 12))
                .frame(width: 24, height: 24)
            Circle().fill(abs(gain) < SoundEQ.flatTolerance ? Color.white.opacity(0.7) : .white)
                .frame(width: hot ? 11 : 8, height: hot ? 11 : 8)
                .overlay { Circle().strokeBorder(hue.opacity(0.9), lineWidth: abs(gain) < SoundEQ.flatTolerance ? 0 : 1.5) }
        }
        .position(x: x, y: y)
        .animation(DS.Motion.touch, value: hot)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("\(SoundEQ.labels[band]) hertz")
        .accessibilityValue(String(format: "%+.1f decibels", gain))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(band, gain + 1)
            case .decrement: set(band, gain - 1)
            @unknown default: break
            }
        }
    }
}

// MARK: Menu-bar popover

/// The mixer, compact, for a menu-bar item: what is playing with a slider and a mute each,
/// the EQ switch and preset, and the curve. 320 points wide; sizes itself in height.
struct SoundMixerPopover: View {
    @ObservedObject private var mixer = SoundMixer.shared
    private let hue = DS.Spectrum.sound

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "slider.vertical.3").font(.system(size: 13, weight: .semibold)).foregroundStyle(hue)
                Text("Sound Mixer").font(DS.title).foregroundStyle(DS.Ink.primary)
                Spacer(minLength: 0)
                LuxSwitch(isOn: $mixer.enabled.displayCompatGated(SoundMixer.availability), label: "Sound Mixer", tint: hue)
            }
            if !SoundMixer.availability.isUsable {
                AvailabilityNote(availability: SoundMixer.availability)
            } else {
                if mixer.apps.isEmpty {
                    Text("Nothing is playing.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, DS.Space.xs)
                } else {
                    VStack(spacing: 0) {
                        ForEach(mixer.apps.prefix(8)) { app in
                            MixerAppRow(mixer: mixer, app: app, hue: hue, compact: true)
                                .help(app.name)
                        }
                    }
                }
                Rectangle().fill(DS.Ink.hairline).frame(height: 0.5)
                HStack(spacing: DS.Space.s) {
                    Text("Equalizer").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    Spacer(minLength: 0)
                    PresetMenu(selection: mixer.eqProfile.preset, hue: hue) { mixer.choose($0) }
                    LuxSwitch(isOn: Binding(get: { mixer.settings.eqEnabled }, set: { mixer.eqEnabled = $0 }), label: "Equalizer", tint: hue)
                }
                EQCurveGraph(gains: mixer.settings.eqEnabled ? mixer.eqProfile.gains : EQPreset.flat.gains!, hue: hue,
                             lit: mixer.enabled && mixer.settings.eqEnabled, grid: false)
                    .frame(height: 44)
                    .animation(DS.Motion.gentle(DS.Motion.arrive), value: mixer.eqProfile.gains)
                if let problem = mixer.problem {
                    Text(problem).font(DS.caption).foregroundStyle(Color.orange.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Inset.card)
        .frame(width: 320)
        .onAppear { mixer.startWatching() }
        .onDisappear { mixer.stopWatching() }
    }
}
