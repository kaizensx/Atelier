import AppKit
import DockCore
import SwiftUI

// The Atelier Dock's Vitals tile: which readings it shows (OwnDock.vitalMetrics, up to four),
// how it draws them, how often it samples, its colours and what a click does. It reads the
// dock's own `Vitals` sampler, which runs only while the tile is in the dock, and skips its
// samples while the dock cannot be seen. Never more than once a second.

enum DockVitalsStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case rings, bars, number, graph
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var note: String {
        switch self {
        case .rings: "One ring per reading, outermost first."
        case .bars: "Side by side, filling from the bottom."
        case .number: "The readings as figures. One is shown large."
        case .graph: "The last minute or so as a line per reading."
        }
    }
}

enum DockVitalsColour: String, Codable, CaseIterable, Identifiable, Sendable {
    /// The dock's own ring colours, which follow its design and accent.
    case dock
    /// Each reading in its own colour, as the Vitals widget draws it.
    case metric
    case accent, white
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dock: "Dock"
        case .metric: "Per Reading"
        case .accent: "Accent"
        case .white: "White"
        }
    }
}

enum DockVitalsClick: String, Codable, CaseIterable, Identifiable, Sendable {
    case activityMonitor, widgets, nothing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .activityMonitor: "Open Activity Monitor"
        case .widgets: "Open Vitals in Atelier"
        case .nothing: "Nothing"
        }
    }
}

struct DockVitalsOptions: Codable, Equatable, Sendable {
    var style = DockVitalsStyle.rings
    var colour = DockVitalsColour.dock
    /// Seconds between samples.
    var refresh = 3.0
    var click = DockVitalsClick.widgets
    /// The first reading's figure in the middle of the rings, over the bars or the graph.
    var valueInside = false
    /// A reading past its limit turns red: 90% full, a battery under 15%, serious thermal pressure.
    var warn = true
    /// A dark rounded plate behind the face, so it reads like an app icon on any bar.
    var plate = false

    static let refreshes: [Double] = [1, 2, 3, 5, 10]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = DockVitalsOptions()
        style = (try? c.decodeIfPresent(DockVitalsStyle.self, forKey: .style)) ?? base.style
        colour = (try? c.decodeIfPresent(DockVitalsColour.self, forKey: .colour)) ?? base.colour
        refresh = max((try? c.decodeIfPresent(Double.self, forKey: .refresh)) ?? base.refresh, 1)
        click = (try? c.decodeIfPresent(DockVitalsClick.self, forKey: .click)) ?? base.click
        valueInside = (try? c.decodeIfPresent(Bool.self, forKey: .valueInside)) ?? base.valueInside
        warn = (try? c.decodeIfPresent(Bool.self, forKey: .warn)) ?? base.warn
        plate = (try? c.decodeIfPresent(Bool.self, forKey: .plate)) ?? base.plate
    }

    /// Whether a fill is past the point worth a glance.
    static func alarming(_ metric: VitalMetric, _ fill: Double) -> Bool {
        switch metric {
        case .battery: fill < 0.15
        case .thermal: fill > 0.6
        case .uptime, .network, .fans: false
        default: fill >= 0.9
        }
    }
}

/// The tile's options, kept apart from `OwnDock` so changing them redraws only the tile.
@MainActor
final class DockVitalsSettings: ObservableObject {
    static let shared = DockVitalsSettings()
    private static let key = "ownDock.vitalsTile"

    @Published var options: DockVitalsOptions {
        didSet {
            guard options != oldValue else { return }
            if let data = try? JSONEncoder().encode(options) { UserDefaults.standard.set(data, forKey: Self.key) }
            apply(to: OwnDock.shared.vitals)
        }
    }

    private init() {
        options = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(DockVitalsOptions.self, from: $0) }
            ?? DockVitalsOptions()
    }

    /// Hands the sampler what the tile needs: its pace, its readings, and a gate that skips
    /// samples while the dock is out of sight (hidden, covered or the displays asleep).
    func apply(to vitals: Vitals) {
        vitals.interval = options.refresh
        vitals.wanted = Set(OwnDock.shared.vitalMetrics)
        vitals.gate = { OwnDock.shared.enabled && OwnDock.shared.stage.animating }
    }

    static func openActivityMonitor() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                           configuration: NSWorkspace.OpenConfiguration())
    }

    /// A click on the tile.
    func click() {
        switch options.click {
        case .activityMonitor: Self.openActivityMonitor()
        case .widgets: ManagerWindow.shared.show(chapter: Chapter.vitals.rawValue)
        case .nothing: break
        }
    }
}

// MARK: - The face

/// Now Vitals in one tile. Grows with the lens like any other icon.
struct DockVitalsGlyph: View {
    @ObservedObject var vitals: Vitals
    let theme: DockTheme
    let size: Double
    @ObservedObject private var settings = DockVitalsSettings.shared
    @ObservedObject private var dock = OwnDock.shared

    private var options: DockVitalsOptions { settings.options }

    /// The chosen readings this Mac can show, outermost or leftmost first.
    private var metrics: [VitalMetric] { Array(dock.vitalMetrics.filter { vitals.value($0) != nil }.prefix(4)) }

    private func color(_ metric: VitalMetric, _ index: Int) -> Color {
        if options.warn, let fill = vitals.value(metric), DockVitalsOptions.alarming(metric, fill) {
            return Color(red: 1, green: 0.36, blue: 0.33)
        }
        switch options.colour {
        case .dock: return theme.rings[index % max(theme.rings.count, 1)]
        case .metric: return metric.tint.color
        case .accent: return theme.accent
        case .white: return .white
        }
    }

    var body: some View {
        let shown = metrics
        ZStack {
            if options.plate {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .fill(Color.black.opacity(0.55))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: max(size * 0.012, 0.5))
                    }
                    .padding(size * 0.04)
            }
            if shown.isEmpty {
                Image(systemName: "gauge.with.dots.needle.33percent")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                switch options.style {
                case .rings: rings(shown)
                case .bars: bars(shown)
                case .number: numbers(shown)
                case .graph: graph(shown)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vitals")
        .accessibilityValue(shown.map { "\($0.title) \(vitals.text($0))" }.joined(separator: ", "))
    }

    // MARK: Styles

    private func rings(_ shown: [VitalMetric]) -> some View {
        let width = size * (shown.count > 3 ? 0.07 : 0.085), step = width * 1.42
        let margin = size * (options.plate ? 0.16 : 0.11)
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.element) { index, metric in
                let tint = color(metric, index)
                ZStack {
                    Circle().stroke(tint.opacity(0.2), lineWidth: width)
                    Circle().trim(from: 0, to: max(vitals.value(metric) ?? 0, 0.01))
                        .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(margin + step * Double(index))
            }
            // The innermost ring leaves this much room in the middle; too little to read, no figure.
            let room = size - 2 * (margin + step * Double(shown.count - 1) + width)
            if options.valueInside, let first = shown.first, room > size * 0.34 {
                figure(first, size: room * 0.36, color: .white)
                    .frame(width: room * 0.86)
            }
        }
    }

    private func bars(_ shown: [VitalMetric]) -> some View {
        let inset = size * (options.plate ? 0.2 : 0.14)
        let gap = size * 0.06
        let barWidth = min((size - inset * 2 - gap * Double(shown.count - 1)) / Double(shown.count), size * 0.2)
        let height = size - inset * 2 - (options.valueInside ? size * 0.16 : 0)
        return VStack(spacing: size * 0.03) {
            if options.valueInside, let first = shown.first {
                figure(first, size: size * 0.14, color: .white)
            }
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(shown.enumerated()), id: \.element) { index, metric in
                    let tint = color(metric, index)
                    ZStack(alignment: .bottom) {
                        Capsule().fill(tint.opacity(0.2))
                        Capsule().fill(tint)
                            .frame(height: max(height * min(max(vitals.value(metric) ?? 0, 0), 1), barWidth))
                    }
                    .frame(width: barWidth, height: height)
                }
            }
        }
        .animation(DS.Motion.arrive, value: shown.map { vitals.value($0) ?? 0 })
    }

    private func numbers(_ shown: [VitalMetric]) -> some View {
        let inset = size * (options.plate ? 0.16 : 0.1)
        return Group {
            if shown.count == 1, let metric = shown.first {
                VStack(spacing: size * 0.02) {
                    figure(metric, size: size * 0.3, color: color(metric, 0))
                    Text(metric.title).font(.system(size: size * 0.13, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1).minimumScaleFactor(0.5)
                }
            } else if shown.count == 2 {
                VStack(spacing: size * 0.04) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, metric in
                        figure(metric, size: size * 0.24, color: color(metric, index))
                    }
                }
            } else {
                // Three or four: two by two, each figure in its own quarter.
                let cell = (size - inset * 2) / 2
                VStack(spacing: 0) {
                    ForEach([0, 2], id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(row..<min(row + 2, shown.count), id: \.self) { index in
                                figure(shown[index], size: size * 0.16, color: color(shown[index], index))
                                    .padding(.horizontal, size * 0.02)
                                    .frame(width: cell, height: cell)
                            }
                        }
                        .frame(width: cell * 2, alignment: .leading)
                    }
                }
            }
        }
        .padding(inset)
    }

    private func graph(_ shown: [VitalMetric]) -> some View {
        let inset = size * (options.plate ? 0.17 : 0.1)
        return VStack(alignment: .leading, spacing: size * 0.02) {
            if options.valueInside, let first = shown.first {
                figure(first, size: size * 0.15, color: .white)
            }
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous).fill(Color.white.opacity(0.07))
                ForEach(Array(shown.enumerated()).reversed(), id: \.element) { index, metric in
                    let line = vitals.history[metric] ?? []
                    let tint = color(metric, index)
                    if index == 0 {
                        DockVitalsLine(values: line, closed: true).fill(tint.opacity(0.22))
                    }
                    DockVitalsLine(values: line, closed: false)
                        .stroke(tint, style: StrokeStyle(lineWidth: max(size * 0.03, 1), lineCap: .round, lineJoin: .round))
                }
            }
            .clipShape(.rect(cornerRadius: size * 0.08, style: .continuous))
        }
        .padding(inset)
    }

    private func figure(_ metric: VitalMetric, size points: Double, color: Color) -> some View {
        Text(vitals.text(metric))
            .font(.system(size: points, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.4)
            .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
    }
}

/// A reading's recent fills across the width, 0 at the bottom. Closed, it is the area under it.
struct DockVitalsLine: Shape {
    var values: [Double]
    var closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1 else {
            // One sample so far: a level line at that height.
            let y = rect.maxY - rect.height * min(max(values.first ?? 0, 0), 1)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
            return path
        }
        let step = rect.width / Double(Vitals.historyLength - 1)
        let start = rect.maxX - step * Double(values.count - 1)
        let room = rect.insetBy(dx: 0, dy: rect.height * 0.08)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: start + step * Double(index), y: room.maxY - room.height * min(max(value, 0), 1))
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: start, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// The figures under the Vitals tile's peek card: the readings it shows, in its colours.
struct DockVitalsPeekRow: View {
    @ObservedObject var vitals: Vitals
    let theme: DockTheme
    @ObservedObject private var dock = OwnDock.shared

    var body: some View {
        let shown = Array(dock.vitalMetrics.filter { vitals.value($0) != nil }.prefix(4))
        HStack(spacing: 14) {
            ForEach(Array(shown.enumerated()), id: \.element) { index, metric in
                VStack(alignment: .leading, spacing: 1) {
                    Text(vitals.text(metric))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(theme.rings[index % max(theme.rings.count, 1)])
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(metric.title).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Settings

/// The Vitals tile's options in the Dock chapter: what it shows, how, how often, and its click.
struct DockVitalsSettingsView: View {
    @ObservedObject private var dock = OwnDock.shared
    @ObservedObject private var settings = DockVitalsSettings.shared
    private let hue = DockHubHue.tint

    private var options: Binding<DockVitalsOptions> { $settings.options }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                DockVitalsGlyph(vitals: dock.vitals, theme: dock.currentTheme, size: 64)
                    .frame(width: 72, height: 72)
                    .background(Color(red: 0.06, green: 0.065, blue: 0.08), in: .rect(cornerRadius: DS.Radius.plate, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: DS.Radius.plate, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                    }
                    .accessibilityLabel("Preview of the Vitals tile")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Readings").font(DS.Typo.rowTitle).foregroundStyle(DS.Ink.primary)
                    Text("Up to four, in the order you pick them.")
                        .font(DS.caption).foregroundStyle(DS.Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            metricsPicker.padding(.bottom, 10)
            if dock.vitalMetrics.contains(where: \.isSensor) {
                Text("Temperatures, power and fans come from the Mac's sensors, read only while the tile shows.")
                    .font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }
            hairline
            DockHubWideRow("Style", detail: settings.options.style.note) {
                Segments(selection: options.style, options: DockVitalsStyle.allCases.map { ($0, $0.title) })
            }
            hairline
            DockHubWideRow("Colours") {
                Segments(selection: options.colour, options: DockVitalsColour.allCases.map { ($0, $0.title) })
            }
            hairline
            SettingRow(title: "Refresh", detail: "Paused while the dock is out of sight.", density: .compact) {
                DockMenuPill(selection: options.refresh, options: DockVitalsOptions.refreshes.map { ($0, $0 == 1 ? "Every second" : "Every \(Int($0)) s") })
            }
            .dockHubRow()
            hairline
            SettingRow(title: "Click", density: .compact) {
                DockMenuPill(selection: options.click, options: DockVitalsClick.allCases.map { ($0, $0.title) })
            }
            .dockHubRow()
            hairline
            if settings.options.style != .number {
                toggle("Figure Inside", detail: "The first reading's figure on the face.", options.valueInside)
                hairline
            }
            toggle("Warn in Red", detail: "Past 90%, a battery under 15%, or serious heat.", options.warn)
            hairline
            toggle("Plate", detail: "A dark tile behind it, like an app icon.", options.plate)
        }
        .onAppear { DockVitalsSettings.shared.apply(to: dock.vitals) }
        .onChange(of: dock.vitalMetrics) { DockVitalsSettings.shared.apply(to: dock.vitals) }
    }

    private var hairline: some View { Rectangle().fill(DS.Ink.hairline).frame(height: 0.5) }

    private func toggle(_ title: String, detail: String, _ value: Binding<Bool>) -> some View {
        SettingRow(title: title, detail: detail, density: .compact) {
            LuxSwitch(isOn: value, label: title, tint: hue)
        }
        .dockHubRow()
    }

    private var metricsPicker: some View {
        FlowRow {
            ForEach(VitalMetric.allCases) { metric in
                let index = dock.vitalMetrics.firstIndex(of: metric)
                let full = index == nil && dock.vitalMetrics.count >= 4
                Button {
                    withAnimation(DS.Motion.settle) {
                        if let index { dock.vitalMetrics.remove(at: index) }
                        else if dock.vitalMetrics.count < 4 { dock.vitalMetrics.append(metric) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if let index {
                            Text("\(index + 1)").font(.system(size: 10, weight: .bold)).monospacedDigit()
                                .frame(width: 16, height: 16).background(hue, in: .circle).foregroundStyle(.black.opacity(0.85))
                        } else {
                            Image(systemName: metric.symbol).font(.system(size: 11, weight: .semibold))
                        }
                        Text(metric.title).font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(index == nil ? DS.Ink.secondary : DS.Ink.primary)
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(index == nil ? DS.Ink.fill : DS.Ink.fillStrong, in: .capsule)
                }
                .buttonStyle(Pressable(scale: 0.95))
                // Four at most: a fifth waits for one to be taken off, and says so.
                .disabled(full)
                .opacity(full ? 0.45 : 1)
                .help(full ? "Four at most. Take one off first." : metric.detail)
                .accessibilityLabel(metric.title)
                .accessibilityValue(index.map { "Reading \($0 + 1)" } ?? "Off")
            }
        }
    }
}
