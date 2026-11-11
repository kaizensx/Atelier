import AppKit
import Combine
import DockCore
import SwiftUI

// MARK: - Thermals & Power in the menu bar
//
// CPU and GPU temperature, fan speed and what the Mac draws from the wall, in the menu bar,
// in the spirit of Stats and iStat Menus. macOS measures all of it every second and shows none
// of it: Activity Monitor has no temperatures, and System Settings no watts. A click opens a
// popover with the last two minutes as live sparklines that shift from cool to hot.
//
// The item is an ordinary status item drawn as a template image, so the menu bar tints it.
// While it is on, the sensors are read once a second; while the popover is open, four times.
// Turning it off removes the item and, unless something else shows a reading, stops the
// sensors entirely. Nothing is ever written to the hardware.

enum ThermalsReadout: String, CaseIterable, Identifiable {
    case temperature, watts, fans, all
    var id: String { rawValue }

    /// Whether this Mac has the reading: a fanless MacBook Air cannot show fans, and an Intel
    /// Mac without a system power key cannot show watts. "All" shows whatever there is.
    func shown(_ caps: SensorCapabilities) -> Bool {
        switch self {
        case .temperature: caps.temperature
        case .watts: caps.power
        case .fans: caps.fans
        case .all: caps.any
        }
    }

    /// The readout to draw: the chosen one if this Mac has it, else temperature.
    func resolved(_ caps: SensorCapabilities) -> ThermalsReadout { shown(caps) ? self : .temperature }

    var title: String {
        switch self {
        case .temperature: "Temperature"
        case .watts: "Watts"
        case .fans: "Fans"
        case .all: "All"
        }
    }
}

/// Number formats shared by the menu bar, the popover, the card and the Vitals rings.
enum ThermalsFormat {
    static func degrees(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))°" } ?? "–°" }
    static func watts(_ value: Double?) -> String {
        guard let value else { return "– W" }
        return value < 10 ? String(format: "%.1f W", value) : "\(Int(value.rounded())) W"
    }
    static func rpm(_ value: Double?) -> String { value.map { "\(Int($0.rounded()))" } ?? "–" }
}

/// Cool to hot: ice blue, mint, amber, orange, red. Interpolated in sRGB, which is smooth enough
/// across stops this close together.
enum HeatPalette {
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.00, (0.36, 0.78, 1.00)),
        (0.30, (0.38, 0.90, 0.70)),
        (0.55, (1.00, 0.80, 0.30)),
        (0.78, (1.00, 0.52, 0.24)),
        (1.00, (1.00, 0.27, 0.33)),
    ]

    /// `deep` darkens the colour for light backgrounds, where the bright stops wash out.
    static func color(_ heat: Double, deep: Bool = false) -> Color {
        let h = HeatScale.clamp(heat)
        guard let upper = stops.firstIndex(where: { $0.0 >= h }), upper > 0 else { return rgb(stops[0].1, deep) }
        let (a, b) = (stops[upper - 1], stops[upper])
        let k = (h - a.0) / (b.0 - a.0)
        return rgb((a.1.0 + (b.1.0 - a.1.0) * k, a.1.1 + (b.1.1 - a.1.1) * k, a.1.2 + (b.1.2 - a.1.2) * k), deep)
    }

    private static func rgb(_ c: (Double, Double, Double), _ deep: Bool) -> Color {
        let k = deep ? 0.72 : 1
        return Color(red: c.0 * k, green: c.1 * k, blue: c.2 * k)
    }
}

/// One of the four traces the popover draws.
enum ThermalTrace: String, CaseIterable, Identifiable {
    case cpu, gpu, power, fans
    var id: String { rawValue }

    /// Whether this Mac has the trace at all, so a row that could only ever show a dash is left out.
    func shown(_ caps: SensorCapabilities) -> Bool {
        switch self {
        case .cpu: caps.temperature
        case .gpu: caps.gpu
        case .power: caps.power
        case .fans: caps.fans
        }
    }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .power: "Power"
        case .fans: "Fans"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .gpu: "rectangle.3.group"
        case .power: "bolt.fill"
        case .fans: "fan.fill"
        }
    }

    /// The smallest span the graph stretches to, so a steady reading draws as a calm line
    /// rather than noise blown up to full height.
    var minimumSpan: Double {
        switch self {
        case .cpu, .gpu: 6
        case .power: 4
        case .fans: 300
        }
    }

    @MainActor func history(_ sensors: Sensors) -> SampleRing {
        switch self {
        case .cpu: sensors.cpuHistory
        case .gpu: sensors.gpuHistory
        case .power: sensors.wattsHistory
        case .fans: sensors.fanHistory
        }
    }

    @MainActor func current(_ sensors: Sensors) -> Double? {
        switch self {
        case .cpu: sensors.cpu
        case .gpu: sensors.gpu
        case .power: sensors.watts
        case .fans: sensors.fans
        }
    }

    func text(_ value: Double?) -> String {
        switch self {
        case .cpu, .gpu: ThermalsFormat.degrees(value)
        case .power: ThermalsFormat.watts(value)
        case .fans: value.map { ThermalsFormat.rpm($0) + " rpm" } ?? "–"
        }
    }

    /// Without the unit, for the low–high line under the value.
    func bare(_ value: Double) -> String {
        switch self {
        case .cpu, .gpu: ThermalsFormat.degrees(value)
        case .power: ThermalsFormat.watts(value)
        case .fans: ThermalsFormat.rpm(value)
        }
    }

    @MainActor func heat(_ value: Double, sensors: Sensors) -> Double {
        switch self {
        case .cpu, .gpu: return HeatScale.temperature(value)
        case .power: return HeatScale.watts(value)
        case .fans:
            let fan = sensors.latest?.fans.first
            return HeatScale.fan(value, min: fan?.min ?? 0, max: fan?.max ?? 6000)
        }
    }
}

// MARK: Controller

@MainActor
final class ThermalsMenu: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = ThermalsMenu()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "thermals.enabled"); apply() } }
    @Published var readout: ThermalsReadout { didSet { store.set(readout.rawValue, forKey: "thermals.readout"); render(force: true) } }

    private let store = UserDefaults.standard
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var lastClosed = Date.distantPast
    private var holding = false
    private var watching: AnyCancellable?
    private var shown = ""

    private override init() {
        enabled = UserDefaults.standard.bool(forKey: "thermals.enabled")
        readout = ThermalsReadout(rawValue: UserDefaults.standard.string(forKey: "thermals.readout") ?? "") ?? .temperature
        super.init()
    }

    func resume() { if enabled { apply() } }

    /// For tests and atelier://diag: the sensors' latest reading and the item's state.
    var diagnostics: String {
        Sensors.shared.diagnostics + " thermOn=\(enabled) thermReadout=\(readout.rawValue) " +
            "thermPopover=\(popover?.isShown == true ? "open" : "closed") thermShown=\(shown.isEmpty ? "-" : shown.replacingOccurrences(of: " ", with: "_"))"
    }

    private func apply() {
        if enabled {
            if item == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.target = self
                item.button?.action = #selector(clicked)
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item.button?.setAccessibilityLabel("Thermals and Power")
                self.item = item
            }
            if !holding {
                holding = true
                Sensors.shared.acquire()
            }
            // objectWillChange fires before the new values land, so the drawing waits a turn.
            watching = Sensors.shared.objectWillChange.sink { _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { ThermalsMenu.shared.render() } }
            }
            render(force: true)
        } else {
            closePopover()
            popover = nil
            watching = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            shown = ""
            if holding {
                holding = false
                Sensors.shared.release()
            }
        }
    }

    /// Redraws the item only when its text changes: at most once a second, usually less.
    private func render(force: Bool = false) {
        guard let button = item?.button else { return }
        let sensors = Sensors.shared
        let values = ThermalsBadge.Values(cpu: sensors.cpu, watts: sensors.watts, fans: sensors.fans, caps: sensors.capabilities)
        let readout = readout.resolved(sensors.capabilities)
        let text = ThermalsBadge.text(readout, values)
        guard force || text != shown else { return }
        shown = text
        let renderer = ImageRenderer(content: ThermalsBadge(readout: readout, values: values, color: .black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        if let image = renderer.nsImage {
            image.isTemplate = true
            button.image = image
        }
        let caps = sensors.capabilities
        button.toolTip = (["CPU \(ThermalsFormat.degrees(sensors.cpu))"]
            + (caps.gpu ? ["GPU \(ThermalsFormat.degrees(sensors.gpu))"] : [])
            + (caps.power ? [ThermalsFormat.watts(sensors.watts)] : [])
            + (caps.fans ? ["fans \(ThermalsFormat.rpm(sensors.fans)) rpm"] : ["no fans"])).joined(separator: ", ")
        button.setAccessibilityValue(button.toolTip)
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let settings = NSMenuItem(title: "Thermals Settings…", action: #selector(openSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
            item?.menu = menu
            item?.button?.performClick(nil)
            item?.menu = nil
        } else {
            togglePopover()
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "atelier://studio?chapter=menubar")!)
    }

    func togglePopover() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else if Date().timeIntervalSince(lastClosed) > 0.25 {
            // The click that closed a transient popover also lands on the item; don't reopen it.
            openPopover()
        }
    }

    func openPopover() {
        guard enabled, let button = item?.button else { return }
        let popover = self.popover ?? {
            let made = NSPopover()
            made.behavior = .transient
            made.animates = true
            made.delegate = self
            let host = NSHostingController(rootView: ThermalsPanel())
            host.sizingOptions = .preferredContentSize
            made.contentViewController = host
            return made
        }()
        self.popover = popover
        Sensors.shared.acquire(fast: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
    }

    func closePopover() {
        if popover?.isShown == true { popover?.performClose(nil) }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            lastClosed = Date()
            item?.button?.highlight(false)
            Sensors.shared.release(fast: true)
        }
    }
}

// MARK: Badge

/// What the menu bar shows. Each number sits in a slot as wide as its widest likely value, so
/// the item keeps its width as digits change and the status items beside it never shuffle.
struct ThermalsBadge: View {
    struct Values: Equatable {
        var cpu: Double?
        var watts: Double?
        var fans: Double?
        var caps = SensorCapabilities.unknown
    }

    let readout: ThermalsReadout
    let values: Values
    let color: Color
    var fontSize = 12.5

    static func text(_ readout: ThermalsReadout, _ v: Values) -> String {
        switch readout {
        case .temperature: ThermalsFormat.degrees(v.cpu)
        case .watts: ThermalsFormat.watts(v.watts)
        case .fans: ThermalsFormat.rpm(v.fans)
        case .all: ([ThermalsFormat.degrees(v.cpu)] + (v.caps.power ? [ThermalsFormat.watts(v.watts)] : [])
                    + (v.caps.fans ? [ThermalsFormat.rpm(v.fans)] : [])).joined(separator: " ")
        }
    }

    var body: some View {
        HStack(spacing: fontSize * 0.6) {
            switch readout {
            case .temperature: part("thermometer.medium", ThermalsFormat.degrees(values.cpu), widest: "99°")
            case .watts: part("bolt.fill", ThermalsFormat.watts(values.watts), widest: "99 W")
            case .fans: part("fan.fill", ThermalsFormat.rpm(values.fans), widest: "8888")
            case .all:
                part("thermometer.medium", ThermalsFormat.degrees(values.cpu), widest: "99°")
                if values.caps.power { part("bolt.fill", ThermalsFormat.watts(values.watts), widest: "99 W") }
                if values.caps.fans { part("fan.fill", ThermalsFormat.rpm(values.fans), widest: "8888") }
            }
        }
        .foregroundStyle(color)
        .padding(.horizontal, 2)
        .frame(height: fontSize * 1.44)
        .fixedSize()
    }

    private func part(_ symbol: String, _ text: String, widest: String) -> some View {
        HStack(spacing: fontSize * 0.22) {
            Image(systemName: symbol).font(.system(size: fontSize * 0.82, weight: .semibold))
            ZStack(alignment: .leading) {
                Text(widest).hidden()
                Text(text)
            }
            .font(.system(size: fontSize, weight: .medium).monospacedDigit())
        }
    }
}

// MARK: Popover

/// The popover's contents, and the stage's copy of it. `live` keeps the sparklines scrolling.
struct ThermalsPanel: View {
    @ObservedObject private var sensors = Sensors.shared
    var live = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if sensors.available {
                ForEach(ThermalTrace.allCases.filter { $0.shown(sensors.capabilities) }) { trace in
                    ThermalRow(trace: trace, live: live)
                }
                footer
            } else {
                Text("This Mac doesn’t share its temperature sensors.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .padding(14)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thermals & Power").font(.system(size: 13.5, weight: .semibold))
                Text("Last two minutes").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let lid = sensors.latest?.lid {
                Label("\(Int(lid.rounded()))°", systemImage: "laptopcomputer")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.primary.opacity(0.07), in: .capsule)
                    .help("Lid angle")
                    .contentTransition(.numericText())
            }
        }
    }

    private var footer: some View {
        let s = sensors.latest
        let caps = sensors.capabilities
        // Desktops have no battery and no palm rest; those stats are left out rather than dashed.
        return HStack(spacing: 0) {
            if caps.battery { stat("Battery", ThermalsFormat.degrees(s?.battery)) }
            if s?.skin != nil { stat("Palm Rest", ThermalsFormat.degrees(s?.skin)) }
            if caps.charger { stat("Charger", s?.chargerWatts.map { ThermalsFormat.watts($0) } ?? "–") }
            if !caps.fans { stat("Cooling", "Fanless") }
            stat("Hottest Die", ThermalsFormat.degrees(s?.die ?? s?.cpu?.max))
        }
        .padding(.top, 2)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// One trace: the name, the value now in its heat colour, the window's low and high, the graph.
private struct ThermalRow: View {
    @ObservedObject private var sensors = Sensors.shared
    @Environment(\.colorScheme) private var scheme
    let trace: ThermalTrace
    let live: Bool

    var body: some View {
        let now = trace.current(sensors)
        let range = trace.history(sensors).range(Sensors.span, now: Sensors.clock())
        let tint = now.map { HeatPalette.color(trace.heat($0, sensors: sensors), deep: scheme == .light) } ?? .secondary
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label(trace.title, systemImage: trace.symbol)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(trace.text(now))
                    .font(.system(size: 21, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                    .animation(.smooth(duration: 0.3), value: trace.text(now))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(range.map { "\(trace.bare($0.lowerBound)) – \(trace.bare($0.upperBound))" } ?? " ")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 100, alignment: .leading)
            ThermalSparkline(trace: trace, live: live)
                .frame(height: 46)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trace.title), \(trace.text(now))")
    }
}

/// The last two minutes, scrolling smoothly at the display's rate: points are placed by their
/// time, so the line glides left between samples instead of jumping once a second.
struct ThermalSparkline: View {
    @ObservedObject private var sensors = Sensors.shared
    @Environment(\.colorScheme) private var scheme
    let trace: ThermalTrace
    var live = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 120, paused: !live)) { context in
            let now = Sensors.clock(context.date)
            let samples = trace.history(sensors).window(Sensors.span, now: now)
            Canvas { g, size in draw(samples, now: now, in: &g, size: size) }
        }
    }

    private func draw(_ samples: [SampleRing.Sample], now: Double, in g: inout GraphicsContext, size: CGSize) {
        // Two faint guides, a third and two thirds up.
        for f in [0.33, 0.66] {
            var guide = Path()
            guide.move(to: CGPoint(x: 0, y: size.height * f))
            guide.addLine(to: CGPoint(x: size.width, y: size.height * f))
            g.stroke(guide, with: .color(.primary.opacity(0.06)), style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
        }
        guard samples.count >= 2, let low = samples.map(\.value).min(), let high = samples.map(\.value).max() else { return }
        let ys = SparkScale.normalise(samples.map(\.value), minimumSpan: trace.minimumSpan)
        let start = now - Sensors.span
        // Room on the right for the newest reading's halo.
        let width = size.width - 6
        var points: [CGPoint] = []
        for (sample, y) in zip(samples, ys) {
            points.append(CGPoint(x: (sample.time - start) / Sensors.span * width, y: (1 - y) * size.height))
        }
        let deep = scheme == .light
        // Through the midpoints, so corners round off without overshooting the readings.
        var line = Path()
        line.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            line.addQuadCurve(to: mid, control: points[i - 1])
        }
        line.addLine(to: points[points.count - 1])

        let cool = HeatPalette.color(trace.heat(low, sensors: sensors), deep: deep)
        let hot = HeatPalette.color(trace.heat(high, sensors: sensors), deep: deep)
        let top = points.map(\.y).min() ?? 0, bottom = points.map(\.y).max() ?? size.height
        let vertical = Gradient(colors: [hot, cool])

        var area = line
        area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
        area.addLine(to: CGPoint(x: points[0].x, y: size.height))
        area.closeSubpath()
        g.fill(area, with: .linearGradient(Gradient(colors: [hot.opacity(0.32), cool.opacity(0)]),
                                           startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: size.height)))
        g.stroke(line, with: .linearGradient(vertical, startPoint: CGPoint(x: 0, y: top), endPoint: CGPoint(x: 0, y: max(bottom, top + 1))),
                 style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

        // The newest reading, with a soft halo in its own colour.
        let last = points[points.count - 1]
        let lastColor = HeatPalette.color(trace.heat(samples[samples.count - 1].value, sensors: sensors), deep: deep)
        g.fill(Path(ellipseIn: CGRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)), with: .color(lastColor.opacity(0.25)))
        g.fill(Path(ellipseIn: CGRect(x: last.x - 2.4, y: last.y - 2.4, width: 4.8, height: 4.8)), with: .color(lastColor))
    }
}

// MARK: - Chapter card

struct ThermalsCard: View {
    @ObservedObject private var menu = ThermalsMenu.shared
    @ObservedObject private var sensors = Sensors.shared

    private var readout: String {
        guard sensors.available, let cpu = sensors.cpu else { return "—" }
        return "\(Int(cpu.rounded()))°C"
    }

    /// Fanless MacBook Airs and Intel Macs without a power key still show what they have.
    private var availability: FeatureAvailability {
        let caps = sensors.capabilities
        if !sensors.available { return .unavailable("This Mac doesn’t share its temperature sensors") }
        if !caps.fans && !caps.power { return .limited("No fans and no power reading on this Mac") }
        if !caps.fans { return .limited("No fans on this Mac, so no fan speed") }
        if !caps.power { return .limited("This Mac reports no system power") }
        return .available
    }

    var body: some View {
        HeroCard("Thermals & Power",
                 pitch: sensors.capabilities.fans
                     ? "Temperatures, fan speed and watts in the menu bar. Your Mac measures them every second and never shows them."
                     : "Temperatures and watts in the menu bar. Your Mac measures them every second and never shows them.",
                 isOn: $menu.enabled.displayCompatGated(availability), hue: DS.Spectrum.sensors,
                 readout: readout, readoutCaption: sensors.available ? "CPU now" : "No sensors",
                 preview: .overlay("thermals.menu", "Thermals in the Menu Bar", isOn: menu.enabled) { size in
                     ThermalsPreview(size: size)
                 }) {
            ThermalsPlate(available: sensors.available).displayCompatNote(availability)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Segments(selection: $menu.readout,
                         options: ThermalsReadout.allCases.filter { $0.shown(sensors.capabilities) }.map { ($0, $0.title) },
                         preview: { readout in
                    .overlay("thermals.readout." + readout.rawValue, readout.title, isOn: menu.enabled) { size in
                        ThermalsPreview(size: size, readout: readout)
                    }
                })
                if sensors.available {
                    HStack(spacing: 8) {
                        ForEach(ThermalTrace.allCases.filter { $0.shown(sensors.capabilities) }) { tile($0) }
                    }
                }
                Text(sensors.available
                     ? (sensors.capabilities.fans
                        ? "Read from the SMC and the chip's own die sensors. Only ever read: fans and charging are left alone."
                        : "Read from the SMC and the chip's own die sensors. This Mac has no fans, so there is no fan speed to show.")
                     : "This Mac doesn’t share its temperature sensors.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sensing()
    }

    private func tile(_ trace: ThermalTrace) -> some View {
        let value = trace.current(sensors)
        return VStack(spacing: 2) {
            Text(trace == .fans ? ThermalsFormat.rpm(value) : trace.text(value))
                .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(value.map { HeatPalette.color(trace.heat($0, sensors: sensors)) } ?? DS.Ink.tertiary)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.3), value: value.map { Int($0) })
            Text(trace == .fans ? "Fans, rpm" : trace.title).font(.system(size: 10.5)).foregroundStyle(DS.Ink.secondary)
        }
        .frame(maxWidth: .infinity).frame(height: 52)
        .background(DS.Ink.fill, in: .rect(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The popover's sparklines in miniature: CPU, GPU and power over the last two minutes. They
/// redraw once a second as readings land, and glide at the display's rate only under the pointer.
private struct ThermalsPlate: View {
    @ObservedObject private var sensors = Sensors.shared
    let available: Bool

    var body: some View {
        HeroLife { live in
            HStack(spacing: 14) {
                ForEach([ThermalTrace.cpu, .gpu, .power].filter { $0.shown(sensors.capabilities) }) { trace in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: trace.symbol).font(.system(size: 9.5, weight: .semibold))
                            Text(trace.title).font(.system(size: 10.5, weight: .semibold))
                            Spacer(minLength: 0)
                            Text(trace.text(trace.current(sensors))).font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                                .foregroundStyle(.white.opacity(0.7))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        ThermalSparkline(trace: trace, live: live)
                            .frame(height: 50)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .environment(\.colorScheme, .dark)
            .opacity(available ? 1 : 0.35)
            .padding(.leading, 16)
            .padding(.trailing, 128)
            .padding(.top, 40)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Stage preview

/// The item in the replica's menu bar, left of the other status items, with the popover dropped
/// below it and its sparklines running live. Both are the real views, scaled to the stage.
struct ThermalsPreview: View {
    @ObservedObject private var menu = ThermalsMenu.shared
    @ObservedObject private var sensors = Sensors.shared
    @ObservedObject private var skin = MenuBarSkin.shared
    let size: CGSize
    var readout: ThermalsReadout?

    var body: some View {
        // The stage draws its menu bar 1.27 times larger than a 1728-point screen would.
        let unit = size.width / 1728 * 1.27
        let barHeight = size.width * MacStage.menuBarFraction
        let ink = skin.textIsLight ? Color.white.opacity(0.9) : Color.black.opacity(0.85)
        let trailing = size.width * 0.15
        ThermalsBadge(readout: (readout ?? menu.readout).resolved(sensors.capabilities),
                      values: .init(cpu: sensors.cpu, watts: sensors.watts, fans: sensors.fans, caps: sensors.capabilities),
                      color: ink, fontSize: size.width * 0.0095)
            .padding(.horizontal, 6 * unit)
            .frame(height: barHeight * 0.82)
            .background(ink.opacity(0.2), in: .capsule)
            .fixedSize()
            .overlay(alignment: .top) {
                ThermalsPanel()
                    .atelierGlass(.regular, in: .rect(cornerRadius: 16, style: .continuous))
                    .environment(\.colorScheme, Appearance.isDark ? .dark : .light)
                    .fixedSize()
                    .scaleEffect(unit, anchor: .top)
                    .offset(y: barHeight * 0.82 + 6 * unit)
                    .frame(width: 0)
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, trailing)
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)
            .sensing(fast: true)
    }
}
