import AppKit
import DockCore
import SwiftUI

// MARK: - Fan Control card
//
// The plate: one rotor per fan, spinning at a speed that follows the real rpm (scaled down so
// the blades read as motion, not as a strobe: 2,500 rpm is one visible turn a second), with a
// gauge of the fan's range around it, and the curve in force with a dot where the chip is now.
// The rotors run at the display's rate under the pointer or while Fan Control drives the fans,
// and are still under Reduce Motion. Speed changes spool like a real fan (0.5 s), never jump.
//
// The controls: the presets, the curve editor (drag a point; a preset's curve becomes Custom),
// the hard limit, and the helper's own row with Install and Remove. Drags are direct, with no
// animation; nothing eases in.

struct FanControlCard: View {
    @ObservedObject private var fans = FanControl.shared
    @ObservedObject private var sensors = Sensors.shared
    private let hue = DS.Spectrum.sensors

    private var availability: FeatureAvailability {
        if !sensors.available { return .unavailable("This Mac doesn’t share its fan sensors") }
        if sensors.capabilities != .unknown, !sensors.capabilities.fans { return .unavailable("This Mac has no fans") }
        return .available
    }

    private var readings: [FanReading] { sensors.latest?.fans ?? [] }

    var body: some View {
        HeroCard("Fan Control",
                 pitch: "Run the fans by your own curve, or at full speed now. macOS never lets you touch them.",
                 isOn: Binding(get: { fans.enabled }, set: { fans.setEnabled($0) }).displayCompatGated(availability),
                 hue: hue,
                 readout: sensors.fans.map { ThermalsFormat.rpm($0) },
                 readoutCaption: sensors.fans == nil ? "No fans" : "rpm now") {
            FanPlate(readings: readings, curve: fans.curve ?? FanPreset.balanced.curve!, temperature: fans.temperature ?? [sensors.cpu, sensors.gpu].compactMap { $0 }.max(),
                     level: fans.demand.level, hardLimit: fans.hardLimit, driving: fans.enabled && fans.helper == .running, hue: hue)
                .displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Segments(selection: Binding(get: { fans.enabled ? fans.preset : fans.lastPreset }, set: { fans.setPreset($0) }),
                         options: [FanPreset.silent, .balanced, .max, .custom].map { ($0, $0.title) })
                FanCurveEditor(curve: fans.curve ?? fans.customCurve, temperature: fans.temperature, level: fans.demand.level,
                               hardLimit: fans.hardLimit, hue: hue) { index, celsius, level in
                    fans.editCurve { $0.move(index, celsius: celsius, level: level) }
                }
                .frame(height: 150)
                RowGroup {
                    helperRow
                    SettingRow(title: "Safety limit", detail: "Above \(Int(fans.hardLimit))°C the fans run flat out until it cools 8°.",
                               symbol: "thermometer.high", density: .compact) {
                        LuxSlider(value: Binding(get: { fans.hardLimit }, set: { fans.hardLimit = $0.rounded() }),
                                  range: FanSafety.limitRange, label: "Safety limit", tint: hue)
                            .frame(width: 140)
                    }
                }
                Text(footnote)
                    .font(DS.caption).foregroundStyle(fans.lastError == nil ? DS.Ink.tertiary : Color(red: 1, green: 0.55, blue: 0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sensing(fast: true)
        .onAppear { fans.refreshHelper() }
    }

    @ViewBuilder private var helperRow: some View {
        if fans.working {
            // The administrator prompt runs off the main thread; this says what it waits on.
            SettingRow(title: "Fan helper", detail: "Waiting for the administrator password…", symbol: "lock.shield", density: .compact) {
                ProgressView().controlSize(.small)
            }
        } else if fans.helperOutdated {
            SettingRow(title: "Fan helper", detail: "An older helper is installed. Update it to match this Atelier.",
                       symbol: "arrow.triangle.2.circlepath", density: .compact) {
                HStack(spacing: 6) {
                    Button("Update helper…") { fans.installHelper() }.buttonStyle(FanPillStyle(prominent: true, hue: hue))
                    Button("Remove") { fans.removeHelper() }.buttonStyle(FanPillStyle(prominent: false, hue: hue))
                }
            }
        } else {
            switch fans.helper {
            case .absent:
                SettingRow(title: "Fan helper", detail: "Writing to the fans needs root. One administrator password, removable here.",
                           symbol: "lock.shield", density: .compact) {
                    Button("Install…") { fans.installHelper() }
                        .buttonStyle(FanPillStyle(prominent: true, hue: hue))
                }
            case .installed:
                SettingRow(title: "Fan helper", detail: "Installed, not answering yet.", symbol: "lock.shield", density: .compact) {
                    HStack(spacing: 6) {
                        Button("Reinstall…") { fans.installHelper() }.buttonStyle(FanPillStyle(prominent: false, hue: hue))
                        Button("Remove") { fans.removeHelper() }.buttonStyle(FanPillStyle(prominent: false, hue: hue))
                    }
                }
            case .running:
                SettingRow(title: "Fan helper", detail: helperDetail, symbol: "checkmark.shield", density: .compact) {
                    Button("Remove") { fans.removeHelper() }
                        .buttonStyle(FanPillStyle(prominent: false, hue: hue))
                }
            }
        }
    }

    private var helperDetail: String {
        guard let status = fans.status else { return "Running." }
        let state = switch status.state {
        case "manual": "Driving the fans"
        case "overheat": "Over the limit: full speed"
        default: "Fans on automatic"
        }
        let targets = status.fans.compactMap { $0.mode == 1 ? $0.target : nil }
        return targets.isEmpty ? state + "." : state + " · " + targets.map { ThermalsFormat.rpm($0) }.joined(separator: " / ") + " rpm."
    }

    private var footnote: String {
        if let error = fans.lastError { return error }
        if fans.helper == .absent { return "The curve is ready; nothing reaches the fans until the helper is installed." }
        return "Back to automatic if Atelier quits, stops answering for 10 s, or the Mac sleeps. Never below a fan’s minimum."
    }
}

/// A small capsule button: filled in the hue when prominent, a hairline otherwise.
private struct FanPillStyle: ButtonStyle {
    var prominent: Bool
    var hue: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : DS.Ink.primary)
            .padding(.horizontal, 12).frame(height: 26)
            .background(prominent ? AnyShapeStyle(hue) : AnyShapeStyle(DS.Ink.fill), in: .capsule)
            .overlay { Capsule().strokeBorder(prominent ? Color.white.opacity(0.2) : DS.Ink.edge, lineWidth: 0.5) }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(DS.Motion.touch, value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: Plate

private struct FanPlate: View {
    let readings: [FanReading]
    let curve: FanCurve
    let temperature: Double?
    let level: Double?
    let hardLimit: Double
    let driving: Bool
    let hue: Color

    var body: some View {
        HeroLife { hovering in
            HStack(spacing: 14) {
                ForEach(Array((readings.isEmpty ? [FanReading(rpm: 0, target: nil, min: 1, max: 2)] : readings).enumerated()), id: \.offset) { i, fan in
                    VStack(spacing: 4) {
                        FanRotor(rpm: fan.rpm, level: HeatScale.fan(fan.rpm, min: fan.min, max: fan.max), live: hovering || driving, hue: hue)
                            .frame(width: 78, height: 78)
                        Text(readings.count > 1 ? "Fan \(i + 1)" : "Fan")
                            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    }
                }
                FanCurveGraph(curve: curve, temperature: temperature, level: level, hardLimit: hardLimit, hue: hue, compact: true)
                    .frame(maxWidth: .infinity)
            }
            .environment(\.colorScheme, .dark)
            .padding(.leading, 16)
            .padding(.trailing, 112)
            .padding(.top, 36)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }
}

/// Keeps a rotor's angle between frames: integrated, so a speed change never jumps the blades.
@MainActor
private final class RotorSpin {
    var angle = 0.0
    var speed = 0.0
    var last: Double?

    /// Visible turns a second for an rpm: 2,500 rpm is one turn, far below any strobe.
    static func turns(_ rpm: Double) -> Double { max(rpm, 0) / 2500 }

    func advance(to time: Double, rpm: Double) -> Double {
        let dt = min(max(time - (last ?? time), 0), 0.1)
        last = time
        speed += (Self.turns(rpm) - speed) * (1 - exp(-dt / 0.5))
        angle = (angle + speed * dt * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        return angle
    }
}

private struct FanRotor: View {
    let rpm: Double
    /// Where the rpm sits in the fan's range, 0 to 1.
    let level: Double
    let live: Bool
    let hue: Color
    @State private var spin = RotorSpin()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120, paused: !live || reduceMotion)) { context in
            Canvas { g, size in
                let angle = spin.advance(to: context.date.timeIntervalSinceReferenceDate, rpm: reduceMotion ? 0 : rpm)
                draw(&g, size: size, angle: angle, speed: spin.speed)
            }
        }
    }

    private func draw(_ g: inout GraphicsContext, size: CGSize, angle: Double, speed: Double) {
        let r = min(size.width, size.height) / 2
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let ring = Path(ellipseIn: CGRect(x: c.x - r + 3, y: c.y - r + 3, width: 2 * r - 6, height: 2 * r - 6))
        // The housing, lit from inside by how hard the fan works.
        g.fill(ring, with: .radialGradient(Gradient(colors: [hue.opacity(0.1 + 0.35 * level), .clear]),
                                           center: c, startRadius: 0, endRadius: r))
        g.stroke(ring, with: .color(.white.opacity(0.12)), lineWidth: 1)
        // The range gauge: a thin arc from the bottom left, filled to the rpm.
        var track = Path()
        track.addArc(center: c, radius: r - 1.5, startAngle: .degrees(135), endAngle: .degrees(405), clockwise: false)
        g.stroke(track, with: .color(.white.opacity(0.08)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        var gauge = Path()
        gauge.addArc(center: c, radius: r - 1.5, startAngle: .degrees(135), endAngle: .degrees(135 + 270 * max(level, 0.001)), clockwise: false)
        g.stroke(gauge, with: .color(hue), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        // Blades, with two fainter copies trailing them once they move fast: motion blur
        // drawn, not filtered, so it costs nothing at 120 Hz.
        let blades = 9
        let inner = r * 0.24, outer = r * 0.84
        let trail = min(speed, 3) * 0.05
        for ghost in stride(from: 2, through: 0, by: -1) {
            let a0 = angle - Double(ghost) * trail
            let opacity = ghost == 0 ? 0.82 : 0.22 / Double(ghost) * min(speed, 1)
            guard opacity > 0.01 else { continue }
            var path = Path()
            for i in 0..<blades {
                let a = a0 + Double(i) / Double(blades) * 2 * .pi
                func p(_ radius: Double, _ da: Double) -> CGPoint {
                    CGPoint(x: c.x + radius * cos(a + da), y: c.y + radius * sin(a + da))
                }
                path.move(to: p(inner, -0.10))
                path.addQuadCurve(to: p(outer, 0.18), control: p(outer * 0.62, -0.22))
                path.addQuadCurve(to: p(outer * 0.96, 0.42), control: p(outer * 1.02, 0.32))
                path.addQuadCurve(to: p(inner, 0.22), control: p(outer * 0.55, 0.30))
                path.closeSubpath()
            }
            g.fill(path, with: .linearGradient(Gradient(colors: [.white.opacity(opacity), .white.opacity(opacity * 0.55)]),
                                               startPoint: CGPoint(x: c.x, y: c.y - r), endPoint: CGPoint(x: c.x, y: c.y + r)))
        }
        let hub = Path(ellipseIn: CGRect(x: c.x - inner, y: c.y - inner, width: 2 * inner, height: 2 * inner))
        g.fill(hub, with: .color(Color(red: 0.09, green: 0.095, blue: 0.11)))
        g.stroke(hub, with: .color(hue.opacity(0.5 + 0.5 * level)), lineWidth: 1)
    }
}

// MARK: Curve

/// The curve on the plot's scale: 30 to 105 °C across, the fan's range up.
private enum CurvePlot {
    static let range = FanCurve.temperatureRange
    static func x(_ celsius: Double, in rect: CGRect) -> Double {
        rect.minX + rect.width * min(max((celsius - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    }
    static func y(_ level: Double, in rect: CGRect) -> Double { rect.maxY - rect.height * min(max(level, 0), 1) }
    static func celsius(_ x: Double, in rect: CGRect) -> Double {
        range.lowerBound + (x - rect.minX) / max(rect.width, 1) * (range.upperBound - range.lowerBound)
    }
    static func level(_ y: Double, in rect: CGRect) -> Double { (rect.maxY - y) / max(rect.height, 1) }

    static func path(_ curve: FanCurve, in rect: CGRect) -> (line: Path, start: Double) {
        var line = Path()
        let first = curve.points.first ?? .init(range.lowerBound, 1)
        let startX = curve.systemBelowStart ? x(first.celsius, in: rect) : rect.minX
        line.move(to: CGPoint(x: startX, y: y(curve.systemBelowStart ? first.level : first.level, in: rect)))
        for point in curve.points { line.addLine(to: CGPoint(x: x(point.celsius, in: rect), y: y(point.level, in: rect))) }
        line.addLine(to: CGPoint(x: rect.maxX, y: y(curve.points.last?.level ?? 1, in: rect)))
        return (line, startX)
    }
}

private struct FanCurveGraph: View {
    let curve: FanCurve
    let temperature: Double?
    let level: Double?
    let hardLimit: Double
    let hue: Color
    var compact = false

    var body: some View {
        Canvas { g, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 4)
            // Quiet grid: every 10 degrees, and the half of the range.
            var grid = Path()
            for c in stride(from: 40.0, through: 100, by: 10) {
                let x = CurvePlot.x(c, in: rect)
                grid.move(to: CGPoint(x: x, y: rect.minY))
                grid.addLine(to: CGPoint(x: x, y: rect.maxY))
            }
            grid.move(to: CGPoint(x: rect.minX, y: CurvePlot.y(0.5, in: rect)))
            grid.addLine(to: CGPoint(x: rect.maxX, y: CurvePlot.y(0.5, in: rect)))
            g.stroke(grid, with: .color(.white.opacity(0.05)), lineWidth: 0.5)
            // Where macOS is in charge: a dotted floor.
            let (line, startX) = CurvePlot.path(curve, in: rect)
            if startX > rect.minX {
                var floor = Path()
                floor.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                floor.addLine(to: CGPoint(x: startX, y: rect.maxY))
                g.stroke(floor, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.2, dash: [2, 3]))
            }
            var fill = line
            fill.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            fill.addLine(to: CGPoint(x: startX, y: rect.maxY))
            fill.closeSubpath()
            g.fill(fill, with: .linearGradient(Gradient(colors: [hue.opacity(0.32), hue.opacity(0.02)]),
                                               startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
            g.stroke(line, with: .color(hue), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            // The hard limit.
            var limit = Path()
            let lx = CurvePlot.x(hardLimit, in: rect)
            limit.move(to: CGPoint(x: lx, y: rect.minY))
            limit.addLine(to: CGPoint(x: lx, y: rect.maxY))
            g.stroke(limit, with: .color(Color(red: 1, green: 0.3, blue: 0.33).opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            // Now: where the chip is, and the level the governor holds.
            if let temperature {
                let x = CurvePlot.x(temperature, in: rect)
                let y = CurvePlot.y(level ?? 0, in: rect)
                g.fill(Path(ellipseIn: CGRect(x: x - 7, y: y - 7, width: 14, height: 14)), with: .color(hue.opacity(0.25)))
                g.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)), with: .color(.white))
                if !compact {
                    g.draw(Text("\(Int(temperature.rounded()))°").font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85)), at: CGPoint(x: x, y: max(y - 14, rect.minY + 6)))
                }
            }
            if !compact {
                for c in stride(from: 60.0, through: 100, by: 20) {
                    g.draw(Text("\(Int(c))°").font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.white.opacity(0.45)),
                           at: CGPoint(x: CurvePlot.x(c, in: rect), y: rect.maxY - 6))
                }
                g.draw(Text("max").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)),
                       at: CGPoint(x: rect.minX + 12, y: rect.minY + 6))
                if startX > rect.minX + 30 {
                    g.draw(Text("macOS").font(.system(size: 9.5)).foregroundStyle(.white.opacity(0.45)),
                           at: CGPoint(x: (rect.minX + startX) / 2, y: rect.maxY - 18))
                }
            }
        }
    }
}

/// The curve, big, with a handle on each point. Dragging moves the point 1:1 under the pointer.
private struct FanCurveEditor: View {
    let curve: FanCurve
    let temperature: Double?
    let level: Double?
    let hardLimit: Double
    let hue: Color
    let onMove: (Int, Double, Double) -> Void
    @State private var dragging: Int?

    var body: some View {
        GeometryReader { geo in
            let rect = CGRect(origin: .zero, size: geo.size).insetBy(dx: 2, dy: 4)
            let editable = curve.points.count > 1 || curve.systemBelowStart
            ZStack(alignment: .topLeading) {
                FanCurveGraph(curve: curve, temperature: temperature, level: level, hardLimit: hardLimit, hue: hue)
                if editable {
                    ForEach(Array(curve.points.enumerated()), id: \.offset) { i, point in
                        Circle()
                            .fill(dragging == i ? Color.white : Color(red: 0.09, green: 0.095, blue: 0.11))
                            .overlay { Circle().strokeBorder(hue, lineWidth: 2) }
                            .frame(width: 14, height: 14)
                            .scaleEffect(dragging == i ? 1.25 : 1)
                            .animation(DS.Motion.touch, value: dragging)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                            .position(x: CurvePlot.x(point.celsius, in: rect), y: CurvePlot.y(point.level, in: rect))
                            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("fanCurve"))
                                .onChanged { drag in
                                    dragging = i
                                    onMove(i, CurvePlot.celsius(drag.location.x, in: rect).rounded(), CurvePlot.level(drag.location.y, in: rect))
                                }
                                .onEnded { _ in dragging = nil })
                            .help("\(Int(point.celsius))°C · \(Int((point.level * 100).rounded())) %")
                    }
                }
            }
            .coordinateSpace(name: "fanCurve")
        }
        .padding(DS.Space.s)
        .background(Color(red: 0.06, green: 0.065, blue: 0.08), in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5) }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fan curve")
        .accessibilityValue(curve.points.map { "\(Int($0.celsius)) degrees, \(Int(($0.level * 100).rounded())) percent" }.joined(separator: "; "))
    }
}

