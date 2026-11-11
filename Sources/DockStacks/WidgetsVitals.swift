import AppKit
import DockCore
import SwiftUI

// MARK: - Vitals options

enum VitalMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, disk, battery, network, thermal, uptime
    /// Read from the hardware sensors (Sensors.swift): degrees, watts and rpm, which macOS never shows.
    case cpuTemp, gpuTemp, power, fans
    var id: String { rawValue }

    /// Comes from the SMC rather than the kernel's counters. The Dock's own Vitals tile leaves these out.
    var isSensor: Bool { [.cpuTemp, .gpuTemp, .power, .fans].contains(self) }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .battery: "Battery"
        case .network: "Network"
        case .thermal: "Thermal"
        case .uptime: "Uptime"
        case .cpuTemp: "CPU °C"
        case .gpuTemp: "GPU °C"
        case .power: "Power"
        case .fans: "Fans"
        }
    }

    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .battery: "battery.75percent"
        case .network: "arrow.down.circle"
        case .thermal: "thermometer.medium"
        case .uptime: "clock.arrow.circlepath"
        case .cpuTemp: "thermometer.medium"
        case .gpuTemp: "thermometer.variable"
        case .power: "bolt.fill"
        case .fans: "fan.fill"
        }
    }

    var tint: WidgetTint {
        switch self {
        case .cpu: .blue
        case .memory: .purple
        case .disk: .teal
        case .battery: .green
        case .network: .orange
        case .thermal: .red
        case .uptime: .amber
        case .cpuTemp: .orange
        case .gpuTemp: .pink
        case .power: .amber
        case .fans: .mint
        }
    }

    /// What it means, for Settings. Thermal is macOS's own thermal pressure, not a temperature: Apple offers no
    /// public way to read a sensor in degrees.
    var detail: String {
        switch self {
        case .cpu: "All cores together."
        case .memory: "App, wired and compressed memory, as Activity Monitor counts it."
        case .disk: "How full your startup disk is."
        case .battery: "Charge. Hidden on a Mac without a battery."
        case .network: "Download speed across Wi‑Fi and Ethernet."
        case .thermal: "Thermal pressure as macOS reports it: Normal, Fair, Serious or Critical. Not degrees."
        case .uptime: "Time since this Mac started."
        case .cpuTemp: "The CPU cores’ temperature, in degrees. The ring fills from 35° to 100°."
        case .gpuTemp: "The graphics cores’ temperature, in degrees."
        case .power: "What the whole Mac draws right now, in watts."
        case .fans: "Fan speed in rpm. The ring fills from the fans’ slowest speed to their fastest."
        }
    }
}

enum VitalsDisplay: String, Codable, CaseIterable, Identifiable {
    /// The old Desktop Vitals, exactly: a row of white rings with the value inside and the name below.
    case classic
    case rings, bars, gauges, numbers
    var id: String { rawValue }
    var title: String { self == .classic ? "Desktop" : rawValue.capitalized }
}

/// New Vitals start as the old Desktop Vitals looked: memory, disk and battery, in white rings.
struct VitalsOptions: Codable, Equatable {
    var metrics: [VitalMetric] = [.memory, .disk, .battery]
    var display = VitalsDisplay.classic
    /// Colours chosen per metric. A missing one uses the metric's own.
    var tints: [String: WidgetTint] = [:]
    /// One colour for every metric: the widget's ink. The old Desktop Vitals looked like this.
    var mono = true
    /// Line width of rings, bars and gauges, in points at the medium size. The Desktop style reads it
    /// against its 112 point ring, where the old Desktop Vitals drew 11.
    var thickness = 11.0
    var labels = true
    /// Large shows a line of detail under each value.
    var large = false

    static let thicknesses = 2.0...18.0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = VitalsOptions()
        let raw = (try? c.decodeIfPresent([String].self, forKey: .metrics)) ?? base.metrics.map(\.rawValue)
        var seen = Set<VitalMetric>()
        metrics = raw.compactMap(VitalMetric.init(rawValue:)).filter { seen.insert($0).inserted }
        display = (try? c.decodeIfPresent(VitalsDisplay.self, forKey: .display)) ?? base.display
        let names = (try? c.decodeIfPresent([String: String].self, forKey: .tints)) ?? [:]
        tints = names.compactMapValues(WidgetTint.init(rawValue:))
        mono = (try? c.decodeIfPresent(Bool.self, forKey: .mono)) ?? base.mono
        thickness = min(max((try? c.decodeIfPresent(Double.self, forKey: .thickness)) ?? base.thickness, Self.thicknesses.lowerBound), Self.thicknesses.upperBound)
        labels = (try? c.decodeIfPresent(Bool.self, forKey: .labels)) ?? base.labels
        large = (try? c.decodeIfPresent(Bool.self, forKey: .large)) ?? base.large
    }

    func tint(_ metric: VitalMetric) -> WidgetTint { tints[metric.rawValue] ?? metric.tint }

    /// The old Desktop Vitals: memory, disk and battery in white rings. The same as a new widget now.
    static var legacy: VitalsOptions { VitalsOptions() }
}

// MARK: - Readings

/// A metric's value now: a fraction for the ring or bar, the text in its middle, and a line of detail.
struct VitalReading: Equatable {
    var fraction: Double
    var value: String
    var detail: String?
}

// MARK: - Vitals widget

struct VitalsWidget: View {
    let options: VitalsOptions
    let size: CGSize
    @ObservedObject private var power = BatteryMeter.shared

    /// Battery drops out on a Mac without one, rather than showing an empty ring.
    private var shown: [VitalMetric] {
        options.metrics.filter { $0 != .battery || power.state.hasBattery || !power.ticker.running }
    }

    var body: some View {
        let metrics = shown
        Group {
            if metrics.isEmpty {
                WidgetPlaceholder(symbol: "gauge.with.dots.needle.67percent", text: "Choose what to show in Settings, Widgets.")
            } else {
                switch options.display {
                case .classic: classic(metrics)
                case .bars: bars(metrics)
                case .numbers, .rings, .gauges: grid(metrics)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        // Battery keeps sampling while chosen even on a Mac without one, so the widget knows to leave it out.
        .modifier(MeteredWhen(ticker: BatteryMeter.shared.ticker, on: options.metrics.contains(.battery)))
    }

    private var pad: Double { min(size.width, size.height) < 120 ? 8 : 14 }

    /// Columns and rows that give each cell the most room.
    private func layout(_ count: Int) -> (columns: Int, rows: Int, cell: CGSize) {
        let room = CGSize(width: size.width - pad * 2, height: size.height - pad * 2)
        var best = (columns: count, rows: 1, cell: CGSize.zero, side: 0.0)
        for columns in 1...max(count, 1) {
            let rows = Int((Double(count) / Double(columns)).rounded(.up))
            let cell = CGSize(width: room.width / Double(columns), height: room.height / Double(rows))
            let side = min(cell.width, cell.height * (options.labels ? 0.82 : 1))
            if side > best.side { best = (columns, rows, cell, side) }
        }
        return (best.columns, best.rows, best.cell)
    }

    private func grid(_ metrics: [VitalMetric]) -> some View {
        let plan = layout(metrics.count)
        let rows = stride(from: 0, to: metrics.count, by: plan.columns).map { Array(metrics[$0..<min($0 + plan.columns, metrics.count)]) }
        return VStack(spacing: 0) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(row) { metric in
                        VitalCell(metric: metric, options: options, cell: plan.cell)
                            .frame(width: plan.cell.width, height: plan.cell.height)
                    }
                }
            }
        }
        .padding(pad)
    }

    /// The old Desktop Vitals at its own measurements: 112 point rings 22 apart, an 11 point line,
    /// 21 point values and 11.5 point names, then scaled as a whole to the tile, as it was to the screen.
    private func classic(_ metrics: [VitalMetric]) -> some View {
        let count = Double(metrics.count)
        let natural = CGSize(width: count * 112 + (count - 1) * 22, height: 112 + 10 + 15)
        // The old one sat at 0.8 of its size with room around it; a Medium tile gives it the same.
        let k = max(min((size.width - pad * 2) / natural.width, (size.height - pad * 2) / natural.height) * 0.86, 0.1)
        return HStack(spacing: 22) {
            ForEach(metrics) { metric in
                ClassicVital(metric: metric, options: options)
            }
        }
        .fixedSize()
        .scaleEffect(k)
        .frame(width: size.width, height: size.height)
    }

    private func bars(_ metrics: [VitalMetric]) -> some View {
        let wide = size.width > 520 && metrics.count > 3
        let columns = wide ? 2 : 1
        let rows = Int((Double(metrics.count) / Double(columns)).rounded(.up))
        let cell = CGSize(width: (size.width - pad * 2) / Double(columns), height: (size.height - pad * 2) / Double(max(rows, 1)))
        let lists = stride(from: 0, to: metrics.count, by: rows).map { Array(metrics[$0..<min($0 + rows, metrics.count)]) }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(lists, id: \.self) { list in
                VStack(spacing: 0) {
                    ForEach(list) { metric in
                        VitalBar(metric: metric, options: options, cell: cell)
                            .frame(width: cell.width, height: cell.height)
                    }
                }
            }
        }
        .padding(pad)
    }
}

/// Reads one metric from the shared meters. Each cell holds its own meter, so only what is shown is sampled.
private struct VitalSource: ViewModifier {
    let metric: VitalMetric

    func body(content: Content) -> some View {
        switch metric {
        case .cpu, .memory, .thermal, .uptime: content.metered(ActivityMeter.shared.ticker)
        case .disk: content.metered(DiskMeter.shared.ticker)
        case .battery: content.metered(BatteryMeter.shared.ticker)
        case .network: content.metered(NetworkMeter.shared.ticker)
        case .cpuTemp, .gpuTemp, .power, .fans: content.sensing()
        }
    }
}

/// Samples a meter while this view is on screen and `on` holds.
private struct MeteredWhen: ViewModifier {
    let ticker: Ticker
    let on: Bool
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear { set(on) }
            .onDisappear { set(false) }
            .onChange(of: on) { _, new in set(new) }
    }

    private func set(_ wanted: Bool) {
        guard wanted != holding else { return }
        holding = wanted
        wanted ? ticker.acquire() : ticker.release()
    }
}

/// Watches one model and hands it to its content.
private struct Observing<Model: ObservableObject, Content: View>: View {
    @ObservedObject var model: Model
    let content: (Model) -> Content
    var body: some View { content(model) }
}

/// Observes only the meter a metric needs, so a sample from another meter never redraws it.
private struct VitalValue<Content: View>: View {
    let metric: VitalMetric
    let content: (VitalReading) -> Content

    init(metric: VitalMetric, @ViewBuilder content: @escaping (VitalReading) -> Content) {
        self.metric = metric
        self.content = content
    }

    var body: some View {
        Group {
            switch metric {
            case .cpu, .memory, .thermal, .uptime:
                Observing(model: ActivityMeter.shared) { content(Self.reading(metric, activity: $0)) }
            case .disk:
                Observing(model: DiskMeter.shared) { content(Self.reading(disk: $0)) }
            case .battery:
                Observing(model: BatteryMeter.shared) { content(Self.reading(power: $0)) }
            case .network:
                Observing(model: NetworkMeter.shared) { content(Self.reading(network: $0)) }
            case .cpuTemp, .gpuTemp, .power, .fans:
                Observing(model: Sensors.shared) { content(Self.reading(metric, sensors: $0)) }
            }
        }
        .modifier(VitalSource(metric: metric))
    }

    static func reading(disk: DiskMeter) -> VitalReading {
        VitalReading(fraction: disk.used, value: Units.percent(disk.used), detail: disk.total > 0 ? "\(Units.bytes(disk.free)) free" : nil)
    }

    static func reading(power: BatteryMeter) -> VitalReading {
        let state = power.state
        let status = state.charging ? "Charging" : state.plugged ? "On power" : state.minutes.map { Units.duration(minutes: $0) + " left" }
        return VitalReading(fraction: state.level, value: Units.percent(state.level), detail: status)
    }

    static func reading(network: NetworkMeter) -> VitalReading {
        let down = network.down ?? 0
        // A log scale: 1 KB/s barely moves the ring, 100 MB/s fills it.
        let fraction = min(max(log10(max(down, 1)) - 3, 0) / 5, 1)
        return VitalReading(fraction: fraction, value: Units.rate(network.down), detail: "↑ " + Units.rate(network.up))
    }

    /// Degrees, watts and rpm from the sensors, smoothed so the ring eases rather than twitches.
    static func reading(_ metric: VitalMetric, sensors: Sensors) -> VitalReading {
        let latest = sensors.latest
        switch metric {
        case .cpuTemp:
            return VitalReading(fraction: sensors.cpu.map { HeatScale.temperature($0) } ?? 0, value: ThermalsFormat.degrees(sensors.cpu),
                                detail: (latest?.cpu?.max ?? latest?.die).map { "Hottest " + ThermalsFormat.degrees($0) })
        case .gpuTemp:
            return VitalReading(fraction: sensors.gpu.map { HeatScale.temperature($0) } ?? 0, value: ThermalsFormat.degrees(sensors.gpu),
                                detail: latest?.gpu.map { "Hottest " + ThermalsFormat.degrees($0.max) })
        case .power:
            let charger = latest?.chargerWatts.flatMap { $0 > 0.5 ? $0 : nil }
            return VitalReading(fraction: sensors.watts.map { HeatScale.watts($0) } ?? 0, value: ThermalsFormat.watts(sensors.watts),
                                detail: charger.map { "Charger " + ThermalsFormat.watts($0) } ?? "On battery")
        default:
            let fan = latest?.fans.first
            let fraction = sensors.fans.map { HeatScale.fan($0, min: fan?.min ?? 0, max: fan?.max ?? 6000) } ?? 0
            let count = latest?.fans.count ?? 0
            return VitalReading(fraction: fraction, value: ThermalsFormat.rpm(sensors.fans),
                                detail: count > 0 ? "rpm, \(count) fan\(count == 1 ? "" : "s")" : nil)
        }
    }

    static func reading(_ metric: VitalMetric, activity: ActivityMeter) -> VitalReading {
        switch metric {
        case .memory:
            return VitalReading(fraction: activity.memory, value: Units.percent(activity.memory),
                                detail: "\(Units.memory(activity.memoryUsed)) of \(Units.memory(activity.memoryTotal))")
        case .thermal:
            // Re-read on each activity sample: macOS's thermal pressure, not a temperature.
            let (fraction, text): (Double, String) = switch ProcessInfo.processInfo.thermalState {
            case .nominal: (0.15, "Normal")
            case .fair: (0.45, "Fair")
            case .serious: (0.75, "Serious")
            case .critical: (1, "Critical")
            @unknown default: (0, "—")
            }
            return VitalReading(fraction: fraction, value: text, detail: "Thermal pressure")
        case .uptime:
            guard let booted = activity.booted else { return VitalReading(fraction: 0, value: "—", detail: nil) }
            let now = Date()
            return VitalReading(fraction: min(now.timeIntervalSince(booted) / 86_400 / 7, 1), value: Units.uptime(since: booted, now: now), detail: "Since start-up")
        default:
            return VitalReading(fraction: activity.cpu, value: Units.percent(activity.cpu),
                                detail: activity.load.first.map { "Load " + $0.formatted(.number.precision(.fractionLength(2))) })
        }
    }
}

private struct VitalCell: View {
    let metric: VitalMetric
    let options: VitalsOptions
    let cell: CGSize
    @Environment(\.widgetTheme) private var theme

    private var color: Color {
        options.mono ? theme.ink : (theme.light ? options.tint(metric).deep : options.tint(metric).color)
    }

    var body: some View {
        VitalValue(metric: metric) { reading in
            let labelRoom = options.labels ? min(cell.height * 0.2, 28) : 0
            let side = max(min(cell.width * 0.86, cell.height - labelRoom - 6), 18)
            let k = side / 68
            VStack(spacing: max(4 * k, 2)) {
                switch options.display {
                case .rings:
                    VitalRing(fraction: reading.fraction, value: reading.value, color: color, track: theme.track,
                              line: options.thickness * k, diameter: side, gauge: false)
                case .gauges:
                    VitalRing(fraction: reading.fraction, value: reading.value, color: color, track: theme.track,
                              line: options.thickness * k, diameter: side, gauge: true)
                default:
                    VitalNumber(reading: reading, color: color, height: side, large: options.large)
                        .frame(width: cell.width * 0.94)
                }
                if options.labels {
                    VStack(spacing: 0) {
                        Text(metric.title)
                            .font(.system(size: min(max(11 * k, 9), 22), weight: .medium))
                            .foregroundStyle(theme.secondary)
                        if options.large, options.display != .numbers, let detail = reading.detail {
                            Text(detail).font(.system(size: min(max(9.5 * k, 8.5), 18))).foregroundStyle(theme.tertiary)
                        }
                    }
                    .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
            .frame(width: cell.width, height: cell.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(metric.title), \(reading.value)")
        }
    }
}

private struct VitalBar: View {
    let metric: VitalMetric
    let options: VitalsOptions
    let cell: CGSize
    @Environment(\.widgetTheme) private var theme

    private var color: Color {
        options.mono ? theme.ink : (theme.light ? options.tint(metric).deep : options.tint(metric).color)
    }

    var body: some View {
        VitalValue(metric: metric) { reading in
            let k = min(max(cell.height / 40, 0.7), 3)
            VStack(alignment: .leading, spacing: 5 * k) {
                HStack(alignment: .firstTextBaseline) {
                    if options.labels {
                        Label(metric.title, systemImage: metric.symbol)
                            .font(.system(size: 11.5 * k, weight: .medium))
                            .foregroundStyle(theme.secondary)
                    }
                    Spacer(minLength: 4)
                    if options.large, let detail = reading.detail {
                        Text(detail).font(.system(size: 10.5 * k)).foregroundStyle(theme.tertiary)
                    }
                    Text(reading.value).font(.system(size: 12.5 * k, weight: .semibold)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                .lineLimit(1).minimumScaleFactor(0.6)
                VitalTrack(fraction: reading.fraction, color: color, track: theme.track, height: max(options.thickness * k * 0.8, 2))
            }
            .padding(.horizontal, 4)
            .frame(width: cell.width, height: cell.height)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(metric.title), \(reading.value)")
        }
    }
}

/// One ring of the old Desktop Vitals, at its old size. Colours follow the widget's ink, white on the wallpaper.
private struct ClassicVital: View {
    let metric: VitalMetric
    let options: VitalsOptions
    @Environment(\.widgetTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = 0.0

    private var color: Color {
        options.mono ? theme.ink : (theme.light ? options.tint(metric).deep : options.tint(metric).color)
    }

    var body: some View {
        VitalValue(metric: metric) { reading in
            VStack(spacing: 10) {
                ZStack {
                    Circle().stroke(theme.track, lineWidth: options.thickness)
                    Circle().trim(from: 0, to: shown)
                        .stroke(color, style: StrokeStyle(lineWidth: options.thickness, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(reading.value)
                        .font(.system(size: reading.value.count > 5 ? 16 : 21, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.horizontal, options.thickness + 4)
                        .foregroundStyle(theme.ink)
                        .contentTransition(.numericText())
                }
                .frame(width: 112, height: 112)
                if options.labels {
                    Text(metric.title).font(.system(size: 11.5)).foregroundStyle(theme.secondary)
                }
            }
            .onAppear {
                if reduceMotion { shown = reading.fraction } else { withAnimation(.spring(response: 1.1, dampingFraction: 1)) { shown = reading.fraction } }
            }
            .onChange(of: reading.fraction) { _, new in
                if reduceMotion { shown = new } else { withAnimation(DS.Motion.arrive) { shown = new } }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(metric.title), \(reading.value)")
        }
    }
}

/// A ring, or a 270 degree gauge, that eases to each new value.
private struct VitalRing: View {
    let fraction: Double
    let value: String
    let color: Color
    let track: Color
    let line: Double
    let diameter: Double
    let gauge: Bool
    @State private var shown = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let span = gauge ? 0.75 : 1.0
        let width = min(line, diameter * 0.2)
        ZStack {
            Circle().trim(from: 0, to: span)
                .stroke(track, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(gauge ? 135 : -90))
            Circle().trim(from: 0, to: max(shown, 0.001) * span)
                .stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(gauge ? 135 : -90))
            Text(value)
                .font(.system(size: diameter * (value.count > 5 ? 0.17 : 0.22), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
                .padding(.horizontal, width + 2)
                .contentTransition(.numericText())
                .offset(y: gauge ? diameter * 0.04 : 0)
        }
        .padding(width / 2)
        .frame(width: diameter, height: diameter)
        .onAppear {
            if reduceMotion { shown = fraction } else { withAnimation(.spring(response: 1.1, dampingFraction: 1)) { shown = fraction } }
        }
        .onChange(of: fraction) { _, new in
            if reduceMotion { shown = new } else { withAnimation(DS.Motion.arrive) { shown = new } }
        }
    }
}

private struct VitalTrack: View {
    let fraction: Double
    let color: Color
    let track: Color
    let height: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: max(height, geometry.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
        .animation(DS.Motion.arrive, value: fraction)
    }
}

private struct VitalNumber: View {
    let reading: VitalReading
    let color: Color
    let height: Double
    let large: Bool
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        VStack(spacing: height * 0.04) {
            Text(reading.value)
                .font(.system(size: height * 0.42, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.3)
                .contentTransition(.numericText())
                .animation(.smooth, value: reading.value)
            if large, let detail = reading.detail {
                Text(detail).font(.system(size: max(height * 0.12, 9))).foregroundStyle(theme.tertiary).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: height)
    }
}
