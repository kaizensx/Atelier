import AppKit
import DockCore
import SwiftUI

// MARK: - Mouse Precision card
//
// One card for every pointing device: chips to pick the device, its acceleration curve drawn
// live (it morphs as presets change and a dot rides it while the mouse moves), a Pointer Speed
// slider that goes past System Settings, and the extra buttons. The stage plays a flick of the
// hand through macOS's curve and through the chosen one, side by side.

/// The graph's units: hand speed and pointer speed in the driver's counts per frame. A screen
/// speed in points per second maps onto the pointer axis by this factor.
private enum CurvePlot {
    static let xMax = 24.0
    static let yMax = 72.0
    static let pointsPerUnit = 55.0
    /// Linear draws as acceleration 0: Apple's first curve is exactly 1:1, so morphs between
    /// Linear and the other presets stay continuous instead of jumping.
    static func drawn(_ acceleration: Double) -> Double { max(acceleration, 0) }
}

/// One acceleration curve, animatable so a preset change morphs the line.
private struct CurveShape: Shape {
    var acceleration: Double
    var speed: Double
    var closed = false

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(acceleration, speed) }
        set { acceleration = newValue.first; speed = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 96
        for i in 0...steps {
            let x = CurvePlot.xMax * Double(i) / Double(steps)
            let y = min(MouseAccelTable.output(x, acceleration: acceleration, speed: speed), CurvePlot.yMax * 1.05)
            let point = CGPoint(x: rect.minX + rect.width * x / CurvePlot.xMax, y: rect.maxY - rect.height * y / CurvePlot.yMax)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The plot: grid, the 1:1 line, macOS's curve dashed for reference, the chosen curve filled.
private struct CurveGraph: View {
    let acceleration: Double
    let speed: Double
    var reference = 0.6875
    var live = true
    var hue: Color = DS.Ink.accent

    var body: some View {
        ZStack {
            Canvas { context, size in
                for i in 1..<4 {
                    let x = size.width * Double(i) / 4, y = size.height * Double(i) / 4
                    context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(DS.Ink.hairline), lineWidth: 0.5)
                    context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
                                   with: .color(DS.Ink.hairline), lineWidth: 0.5)
                }
            }
            CurveShape(acceleration: -1, speed: 1)
                .stroke(.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
            CurveShape(acceleration: reference, speed: 1)
                .stroke(.white.opacity(0.34), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
            CurveShape(acceleration: CurvePlot.drawn(acceleration), speed: speed, closed: true)
                .fill(LinearGradient(colors: [hue.opacity(0.32), hue.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            // The glow is a wide faint stroke under the line, not a shadow: the line morphs, and a
            // shadow would be re-blurred on every frame of it.
            CurveShape(acceleration: CurvePlot.drawn(acceleration), speed: speed)
                .stroke(hue.opacity(0.2), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            CurveShape(acceleration: CurvePlot.drawn(acceleration), speed: speed)
                .stroke(hue, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            if live { LiveDot(acceleration: acceleration, speed: speed, hue: hue) }
        }
        .animation(DS.Motion.gentle(DS.Motion.arrive), value: acceleration)
        .animation(DS.Motion.gentle(DS.Motion.arrive), value: speed)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("Acceleration curve")
        .accessibilityValue(acceleration < 0 ? "Linear" : String(format: "Acceleration %.2f, speed %.1f times", acceleration, speed))
    }
}

/// Where the mouse is on the curve right now, read off the pointer's speed on screen.
private struct LiveDot: View {
    @ObservedObject private var meter = PointerSpeedMeter.shared
    let acceleration: Double
    let speed: Double
    var hue: Color = DS.Ink.accent

    var body: some View {
        GeometryReader { geometry in
            let y = min(meter.speed / CurvePlot.pointsPerUnit, CurvePlot.yMax)
            let x = min(MouseAccelTable.input(forOutput: y, acceleration: CurvePlot.drawn(acceleration), speed: speed), CurvePlot.xMax)
            let point = CGPoint(x: geometry.size.width * x / CurvePlot.xMax, y: geometry.size.height * (1 - y / CurvePlot.yMax))
            ZStack {
                Circle().fill(RadialGradient(colors: [hue.opacity(0.55), .clear], center: .center, startRadius: 0, endRadius: 13))
                    .frame(width: 26, height: 26)
                Circle().fill(.white).frame(width: 8, height: 8)
            }
            .position(point)
            .opacity(meter.speed > 0 ? 1 : 0.35)
            .animation(.linear(duration: 1 / 60), value: meter.speed)
        }
        .allowsHitTesting(false)
    }
}

private struct SpeedReadout: View {
    @ObservedObject private var meter = PointerSpeedMeter.shared
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(meter.speed.formatted(.number.precision(.fractionLength(0)))).font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit().contentTransition(.numericText())
            Text("pt/s").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
        }
        .foregroundStyle(DS.Ink.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pointer speed")
    }
}

private struct DeviceChip: View {
    let device: MousePrecision.Device
    let selected: Bool
    let tuned: Bool
    var hue: Color = DS.Ink.accent
    let space: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: device.trackpad ? "rectangle.and.hand.point.up.left" : "computermouse")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(selected ? hue : DS.Ink.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(selected ? DS.Ink.primary : DS.Ink.secondary)
                    Text(device.vendorName).font(.system(size: 10.5)).foregroundStyle(DS.Ink.tertiary)
                }
                if tuned { Circle().fill(hue).frame(width: 5, height: 5) }
            }
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 11, style: .continuous).fill(DS.Ink.fillStrong)
                        .matchedGeometryEffect(id: "chip", in: space)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(selected ? hue.opacity(0.55) : DS.Ink.hairline, lineWidth: selected ? 1 : 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.96))
        .accessibilityLabel("\(device.name), \(device.vendorName)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct MousePrecisionCard: View {
    @ObservedObject private var model = MousePrecision.shared
    @Namespace private var chips
    private let hue = DS.Spectrum.input

    var body: some View {
        let device = model.selectedDevice
        let setting = device.map { model.setting(for: $0.id) } ?? .init()
        let shown = displayed(setting)
        HeroCard("Mouse Precision",
                 pitch: "Each mouse its own curve, including fully linear and faster than System Settings goes.",
                 isOn: $model.enabled, hue: hue,
                 readout: model.enabled ? setting.curve.title : "macOS",
                 readoutCaption: device.map { model.enabled ? String(format: "%@ · %.2g×", $0.name, setting.speed) : $0.name } ?? "no mouse found",
                 preview: .overlay("input.mousePrecision", "Mouse Precision", isOn: model.enabled) { size in
                     MousePrecisionPreview(size: size, acceleration: shown.acceleration, speed: shown.speed, name: setting.curve.title)
                 }) {
            CurvePlate(acceleration: shown.acceleration, speed: shown.speed, hue: hue)
        } controls: {
            VStack(alignment: .leading, spacing: 12) {
                if model.devices.isEmpty {
                    Text("No mouse or trackpad found.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(model.devices) { item in
                                DeviceChip(device: item, selected: item.id == device?.id,
                                           tuned: model.enabled && model.setting(for: item.id).touches, hue: hue, space: chips) {
                                    withAnimation(DS.Motion.settle) { model.selection = item.id }
                                }
                            }
                        }
                    }
                }
                if let device {
                    Segments(selection: Binding(get: { setting.curve }, set: { curve in choose(curve, for: device) }),
                             options: MouseCurve.allCases.map { ($0, $0.title) }, preview: { curve in
                                 .overlay("input.mousePrecision." + curve.rawValue, curve.title, isOn: model.enabled) { size in
                                     MousePrecisionPreview(size: size, acceleration: displayed(Self.with(setting, curve)).acceleration,
                                                           speed: setting.speed, name: curve.title)
                                 }
                             })
                    if setting.curve == .custom {
                        sliderRow("Acceleration", value: Binding(get: { setting.custom }, set: { v in model.update(device.id) { $0.custom = v } }),
                                  range: 0...5, text: String(format: "%.2f", setting.custom))
                    }
                    sliderRow("Speed", value: Binding(get: { setting.speed }, set: { v in
                        model.update(device.id) { $0.speed = (v * 20).rounded() / 20 }
                    }), range: PointerResolution.speedRange, text: String(format: "%.2g×", setting.speed))
                    if !device.speedHonoured {
                        AvailabilityNote(availability: .limited(MouseDeviceInfo.pointerSpeedLimitNote))
                    }
                    // The legend and the caption wrap rather than cut a device's name short.
                    WrapStack(spacing: 10, lineSpacing: 4) {
                        legend(color: hue, dashed: false, device.name)
                        legend(color: .white.opacity(0.4), dashed: true, "macOS")
                        Text(caption(setting)).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                    }
                    Text(note(device, setting)).font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private static func with(_ setting: MousePrecision.Setting, _ curve: MouseCurve) -> MousePrecision.Setting {
        var copy = setting
        copy.curve = curve
        return copy
    }

    /// What the graph draws: System and an off switch draw the system's own curve.
    private func displayed(_ setting: MousePrecision.Setting) -> (acceleration: Double, speed: Double) {
        guard model.enabled, setting.curve != .system else {
            return (model.systemAcceleration, model.enabled ? setting.speed : 1)
        }
        return (setting.acceleration ?? model.systemAcceleration, setting.speed)
    }

    /// Picking a curve is a clear wish to use it, so it turns the feature on.
    private func choose(_ curve: MouseCurve, for device: MousePrecision.Device) {
        withAnimation(DS.Motion.arrive) {
            model.update(device.id) { $0.curve = curve }
            if curve != .system && !model.enabled { model.enabled = true }
        }
    }

    private func caption(_ setting: MousePrecision.Setting) -> String {
        guard model.enabled, setting.touches else { return "As System Settings has it" }
        switch setting.curve {
        case .linear: return "No acceleration"
        case .system: return "System curve"
        default: return String(format: "Acceleration %.2f", setting.acceleration ?? 0)
        }
    }

    private func note(_ device: MousePrecision.Device, _ setting: MousePrecision.Setting) -> String {
        if setting.speed > 3 { return "Faster than System Settings’ fastest. Written to this device only; it comes back on reconnect." }
        if setting.curve == .linear {
            return device.linearScaling ? "Every inch of hand travel moves the pointer the same distance, at your Tracking Speed."
                                        : "Every inch of hand travel moves the pointer the same distance."
        }
        return "Applies to this device only. Others keep their own curve."
    }

    private func legend(color: Color, dashed: Bool, _ text: String) -> some View {
        HStack(spacing: 5) {
            Capsule().fill(dashed ? .clear : color).frame(width: 14, height: 2.4)
                .overlay { if dashed { Capsule().stroke(color, style: StrokeStyle(lineWidth: 1.2, dash: [3, 2])) } }
            Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(DS.Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary).frame(width: 78, alignment: .leading)
            LuxSlider(value: value, range: range, label: title, tint: hue)
            Text(text).font(DS.Typo.value).foregroundStyle(DS.Ink.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Plate

/// The hero's plate: the curve across the whole plate, macOS's dashed beneath it. It rests as
/// drawn; with the pointer over it, the meter wakes and a bead rides the curve at your real hand
/// speed, so moving the mouse across the plate is the demo.
private struct CurvePlate: View {
    let acceleration: Double
    let speed: Double
    let hue: Color
    @State private var hover = false

    var body: some View {
        CurveGraph(acceleration: acceleration, speed: speed, live: hover, hue: hue)
            .padding(.top, 38).padding(.bottom, 14).padding(.horizontal, 16)
            .overlay(alignment: .topTrailing) {
                if hover { SpeedReadout().padding(.top, 10).padding(.trailing, 14).transition(.opacity) }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                withAnimation(DS.Motion.hover) { hover = inside }
                if inside { PointerSpeedMeter.shared.start() } else { PointerSpeedMeter.shared.stop() }
            }
            .onDisappear { if hover { hover = false; PointerSpeedMeter.shared.stop() } }
    }
}

// MARK: - Buttons

/// The extra buttons, a plain card after the heroes: useful, but not something a Mac lacks.
struct MouseButtonsCard: View {
    var body: some View {
        Card { MouseButtonsSection() }
    }
}

private struct MouseButtonsSection: View {
    @ObservedObject private var model = MousePrecision.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Mouse Buttons",
                       detail: "Side buttons go Back and Forward, or open Mission Control. For mice with extra buttons; Apple’s have none.") {
                LuxSwitch(isOn: $model.buttons, label: "Mouse Buttons")
            }
            .stagePreview(.overlay("input.mouseButtons", "Mouse Buttons", isOn: model.buttons) { size in MouseButtonsPreview(size: size) })
            ForEach(MouseButtonMap.remappable, id: \.self) { button in
                ButtonRow(button: button)
            }
            .disabled(!model.buttons)
            .opacity(model.buttons ? 1 : 0.4)
            if model.buttons && !AXIsProcessTrusted() {
                Text("Needs Accessibility, to see the buttons before apps do.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            } else if !model.hasButtonMouse {
                Text("No mouse with extra buttons is connected right now.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
            }
        }
    }
}

private struct ButtonRow: View {
    let button: Int
    @ObservedObject private var model = MousePrecision.shared
    @StateObject private var recorder = RecorderModel()

    private static let choices: [MouseButtonAction] = [.passThrough, .back, .forward, .missionControl, .appExpose, .showDesktop]

    var body: some View {
        let action = model.buttonMap.action(for: button)
        HStack(spacing: 10) {
            Image(systemName: button == 2 ? "computermouse" : button == 3 ? "chevron.backward.circle" : "chevron.forward.circle")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(DS.Ink.secondary).frame(width: 18)
            Text(MouseButtonMap.name(of: button)).font(DS.body).foregroundStyle(DS.Ink.primary)
            Spacer(minLength: 8)
            Menu {
                ForEach(Self.choices, id: \.self) { choice in
                    Button(choice.title) { set(choice) }
                }
                Divider()
                Button("Record Shortcut…") {
                    recorder.begin { combo in
                        if let combo { set(.shortcut(keyCode: Int(combo.keyCode), carbonModifiers: Int(combo.modifiers))) }
                    }
                }
            } label: {
                Text(recorder.recording ? (recorder.rejected ? "Add ⌘, ⌥ or ⌃" : "Type shortcut…") : label(action))
                    .font(.system(size: 12, weight: .medium)).monospacedDigit()
                    .foregroundStyle(action == .passThrough && !recorder.recording ? DS.Ink.secondary : DS.Ink.primary)
                    .frame(minWidth: 120).frame(height: 28).padding(.horizontal, 8)
                    .background(recorder.recording ? AnyShapeStyle(DS.Ink.accent.opacity(0.55)) : AnyShapeStyle(DS.Ink.fillStrong),
                                in: .rect(cornerRadius: 8, style: .continuous))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(MouseButtonMap.name(of: button))
            .accessibilityValue(label(action))
        }
        .animation(DS.Motion.settle, value: recorder.recording)
        .onDisappear { recorder.end() }
    }

    private func set(_ action: MouseButtonAction) {
        var map = model.buttonMap
        map.actions[button] = action
        model.buttonMap = map
    }

    private func label(_ action: MouseButtonAction) -> String {
        switch action {
        case .back: "Back  ⌘["
        case .forward: "Forward  ⌘]"
        case let .shortcut(code, mods): KeyCombo(keyCode: code, modifiers: mods).display
        default: action.title
        }
    }
}

// MARK: - Stage

/// A flick of the hand, played through macOS's curve and the chosen one. Both pointers start
/// together; how far each one travels is the area under its curve. The curve beside them
/// shows where on it the hand is at each moment.
struct MousePrecisionPreview: View {
    let size: CGSize
    let acceleration: Double
    let speed: Double
    let name: String

    private static let flick = 1.1, cycle = 2.6, peak = 19.0

    /// Hand speed during the flick: a smooth rise and fall, as a real flick has.
    private static func hand(_ t: Double) -> Double {
        t < 0 || t > flick ? 0 : peak * pow(sin(.pi * t / flick), 2)
    }

    /// Pointer distance travelled by time t through a curve.
    private static func travelled(_ t: Double, acceleration: Double, speed: Double) -> Double {
        let steps = 48, end = min(t, flick)
        guard end > 0 else { return 0 }
        let dt = end / Double(steps)
        return (0..<steps).reduce(0.0) { sum, i in
            sum + MouseAccelTable.output(hand((Double(i) + 0.5) * dt), acceleration: acceleration, speed: speed) * dt
        }
    }

    var body: some View {
        let w = size.width * 0.62
        let drawn = CurvePlot.drawn(acceleration)
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.cycle)
            let reference = Self.travelled(Self.flick, acceleration: 0.6875, speed: 1)
            let scale = 0.62 / reference
            let mine = Self.travelled(t, acceleration: drawn, speed: speed) * scale
            let theirs = Self.travelled(t, acceleration: 0.6875, speed: 1) * scale
            let fade = t > Self.cycle - 0.35 ? (Self.cycle - t) / 0.35 : 1
            VStack(spacing: w * 0.035) {
                ZStack {
                    CurveGraph(acceleration: acceleration, speed: speed, live: false)
                    GeometryReader { geometry in
                        let x = Self.hand(t)
                        let y = min(MouseAccelTable.output(x, acceleration: drawn, speed: speed), CurvePlot.yMax)
                        Circle().fill(.white).frame(width: 9, height: 9).shadow(color: DS.Ink.accent, radius: 6)
                            .position(x: geometry.size.width * x / CurvePlot.xMax, y: geometry.size.height * (1 - y / CurvePlot.yMax))
                            .opacity(x > 0.2 ? 1 : 0.3)
                    }
                }
                .frame(width: w * 0.5, height: w * 0.3)
                .background(.black.opacity(0.4), in: .rect(cornerRadius: 12, style: .continuous))
                VStack(spacing: w * 0.025) {
                    lane("macOS", progress: theirs, width: w, accent: false)
                    lane(name, progress: mine, width: w, accent: true)
                }
                .opacity(fade)
            }
            .padding(w * 0.04)
            .background(.ultraThinMaterial.opacity(0.6), in: .rect(cornerRadius: 18, style: .continuous))
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    private func lane(_ title: String, progress: Double, width w: Double, accent: Bool) -> some View {
        let track = w * 0.8
        let p = min(progress, 1)
        return HStack(spacing: w * 0.025) {
            Text(title).font(.system(size: w * 0.024, weight: .semibold)).foregroundStyle(.white.opacity(accent ? 1 : 0.65))
                .frame(width: w * 0.11, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.1)).frame(height: 2)
                Capsule().fill(accent ? DS.Ink.accent : .white.opacity(0.45)).frame(width: max(track * p, 1), height: 2)
                Image(systemName: "cursorarrow")
                    .font(.system(size: w * 0.032, weight: .regular))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .offset(x: track * p - w * 0.008, y: -sin(.pi * p) * w * 0.018 - w * 0.012)
                if progress > 1 {
                    Text("off screen").font(.system(size: w * 0.018, weight: .medium)).foregroundStyle(.white.opacity(0.6))
                        .offset(x: track - w * 0.07, y: w * 0.02)
                }
            }
            .frame(width: track, height: w * 0.05)
        }
    }
}

/// The side buttons and what they now do, lit in turn.
struct MouseButtonsPreview: View {
    @ObservedObject private var model = MousePrecision.shared
    let size: CGSize

    var body: some View {
        let s = size.width * 0.03
        TimelineView(.animation(minimumInterval: 1 / 60)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.6)
            let lit = Int(t / 1.2)
            HStack(spacing: s * 0.8) {
                ForEach(Array(MouseButtonMap.remappable.enumerated()), id: \.offset) { index, button in
                    let action = model.buttonMap.action(for: button)
                    VStack(spacing: s * 0.25) {
                        Text(MouseButtonMap.name(of: button)).font(.system(size: s * 0.45, weight: .medium)).opacity(0.7)
                        Text(action == .passThrough ? "Click" : action.title).font(.system(size: s * 0.6, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, s * 0.7).padding(.vertical, s * 0.4)
                    .background(index == lit ? AnyShapeStyle(DS.Ink.accent.opacity(0.7)) : AnyShapeStyle(.black.opacity(0.45)),
                                in: .rect(cornerRadius: s * 0.5, style: .continuous))
                    .scaleEffect(index == lit ? 1.06 : 1)
                    .animation(DS.Motion.settle, value: lit)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
