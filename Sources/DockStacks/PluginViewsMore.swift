import AppKit
import Charts
import DockCore
import SwiftUI

// Interactive and richer plugin views: buttons, toggles, images, charts, grids, progress,
// dividers and animated stacks. Still nothing a plugin sends runs code here: a tap calls back
// into the plugin's own engine by id, through the registry.

/// Which plugin a view tree belongs to, so taps and images reach the right one.
struct PluginViewHost: Equatable {
    var plugin: String
    var folder: URL?
}

private struct PluginHostKey: EnvironmentKey { static let defaultValue: PluginViewHost? = nil }
extension EnvironmentValues {
    var pluginHost: PluginViewHost? {
        get { self[PluginHostKey.self] }
        set { self[PluginHostKey.self] = newValue }
    }
}

extension View {
    /// Sets the plugin a view tree belongs to, from the registry.
    @MainActor func pluginHost(_ plugin: String?) -> some View {
        environment(\.pluginHost, plugin.map { id in
            PluginViewHost(plugin: id, folder: PluginRegistry.shared.installed.first { $0.id == id }?.folder)
        })
    }
}

/// The views added after the first set. `PluginNodeView` hands these over.
struct PluginMoreNodeView: View {
    let node: PluginNode
    @Environment(\.pluginAccent) private var accent
    @Environment(\.pluginHost) private var host

    var body: some View {
        switch node {
        case .button(let button):
            Button {
                if let host { PluginRegistry.shared.action(host.plugin, button.action) }
            } label: {
                HStack(spacing: 5) {
                    if let symbol = button.symbol { Image(systemName: symbol).font(.system(size: 11.5, weight: .semibold)) }
                    if !button.title.isEmpty { Text(button.title).lineLimit(1) }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(button.style == .prominent ? Color.black.opacity(0.82) : DS.Ink.primary)
                .padding(.horizontal, 11).frame(minHeight: 26)
                .background(button.style == .prominent ? AnyShapeStyle(accent) : AnyShapeStyle(DS.Ink.fillStrong), in: .capsule)
                .contentShape(Capsule())
            }
            .buttonStyle(Pressable(scale: 0.95))
            .disabled(host == nil)
            .accessibilityLabel(button.title.isEmpty ? (button.symbol ?? "Button") : button.title)
        case .toggle(let label, let on, let action):
            PluginToggleView(label: label, on: on, action: action)
        case .image(let image):
            PluginImageView(image: image)
        case .chart(let chart):
            PluginChartView(chart: chart, accent: accent)
        case .grid(let columns, let children):
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .topLeading), count: columns),
                      alignment: .leading, spacing: 8) {
                ForEach(Array(children.enumerated()), id: \.offset) { _, child in AnyView(PluginNodeView(node: child)) }
            }
        case .progress(let value, let label, let color):
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    if let label { Text(label).font(DS.caption).foregroundStyle(DS.Ink.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    Text("\(Int((value * 100).rounded()))%").font(DS.caption).monospacedDigit().foregroundStyle(DS.Ink.tertiary)
                        .contentTransition(.numericText())
                }
                // Drawn here rather than with ProgressView, like `bar`, so it looks the same everywhere.
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.Ink.fillStrong)
                        Capsule().fill(color?.color(accent: accent) ?? accent).frame(width: max(4, geometry.size.width * value))
                    }
                }
                .frame(height: 5)
            }
        case .divider:
            Rectangle().fill(DS.Ink.hairline).frame(height: 1).frame(maxWidth: .infinity)
        case .transition(let transition, let inner):
            PluginTransitionStack(transition: transition, node: inner)
        default:
            EmptyView()
        }
    }
}

private struct PluginToggleView: View {
    let label: String
    let on: Bool
    let action: String
    @Environment(\.pluginHost) private var host
    @State private var shown: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.Ink.primary).lineLimit(1)
            Spacer(minLength: 6)
            LuxSwitch(isOn: Binding(get: { shown ?? on }, set: { value in
                shown = value
                if let host { PluginRegistry.shared.action(host.plugin, action, payload: .object(["on": .bool(value)])) }
            }), label: label)
            .disabled(host == nil)
        }
        // The plugin's next drawing is the truth; the switch only moves ahead of it.
        .onChange(of: on) { _, _ in shown = nil }
    }
}

private struct PluginImageView: View {
    let image: PluginImage
    @Environment(\.pluginHost) private var host
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded).resizable().aspectRatio(contentMode: image.fit == .fill ? .fill : .fit)
            } else {
                RoundedRectangle(cornerRadius: image.radius, style: .continuous).fill(DS.Ink.fill)
            }
        }
        .frame(width: image.width.map { CGFloat($0) }, height: image.height.map { CGFloat($0) })
        .clipShape(RoundedRectangle(cornerRadius: image.radius, style: .continuous))
        .task(id: TaskKey(source: image.source, host: host)) { loaded = await PluginImageLoader.shared.image(image.source, host: host) }
        .accessibilityHidden(true)
    }

    private struct TaskKey: Equatable { let source: PluginImage.Source; let host: PluginViewHost? }
}

/// Loads plugin images: assets from the plugin's own folder, and https images on the plugin's
/// listed hosts, with the same limits as `http.get`. Kept in memory once loaded.
@MainActor
final class PluginImageLoader {
    static let shared = PluginImageLoader()
    private let cache = NSCache<NSString, NSImage>()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    init() { cache.totalCostLimit = 64 * 1024 * 1024 }

    func image(_ source: PluginImage.Source, host: PluginViewHost?) async -> NSImage? {
        guard let host else { return nil }
        let registry = PluginRegistry.shared
        switch source {
        case .asset(let path):
            guard let folder = host.folder, case .success(let url) = PluginAssets.resolve(path, in: folder) else { return nil }
            let key = "\(host.plugin)|\(url.path)|\((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            guard let image = NSImage(contentsOf: url) else { return nil }
            cache.setObject(image, forKey: key, cost: PluginAssets.maxBytes)
            return image
        case .url(let url):
            guard let plugin = registry.installed.first(where: { $0.id == host.plugin }),
                  case .success = PluginNetwork.allows(url, manifest: plugin.manifest, granted: registry.grants[plugin.id] ?? []) else { return nil }
            let key = "\(host.plugin)|\(url.absoluteString)" as NSString
            if let hit = cache.object(forKey: key) { return hit }
            let began = Date()
            var request = URLRequest(url: url)
            request.setValue("Atelier-Plugin/\(PluginPrelude.apiVersion) (\(plugin.id))", forHTTPHeaderField: "User-Agent")
            let result = try? await session.data(for: request)
            let http = result?.1 as? HTTPURLResponse
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            registry.networkLog[plugin.id, default: []].append(PluginNetworkEntry(
                date: Date(), method: "GET", host: url.host() ?? "", path: url.path() + " (image)", status: http?.statusCode,
                milliseconds: ms, bytes: result?.0.count ?? 0))
            guard let (data, _) = result, data.count <= PluginRuntime.maxResponseBytes,
                  let http, (200..<300).contains(http.statusCode),
                  let final = http.url?.host()?.lowercased(), plugin.manifest.hosts.contains(final),
                  let image = NSImage(data: data) else { return nil }
            cache.setObject(image, forKey: key, cost: data.count)
            return image
        }
    }
}

private struct PluginChartView: View {
    let chart: PluginChart
    let accent: Color

    private struct Point: Identifiable {
        let id: String
        let series: String
        let index: Int
        let label: String
        let value: Double
        /// Unique per position, so repeated labels (two "T"s in a week) stay separate bars.
        var slot: String { String(index) }
    }

    private func label(_ slot: String) -> String {
        guard let index = Int(slot) else { return slot }
        return index < chart.labels.count ? chart.labels[index] : String(index + 1)
    }

    private var points: [Point] {
        chart.series.enumerated().flatMap { s, series in
            series.values.enumerated().map { i, value in
                Point(id: "\(s)-\(i)", series: series.label.isEmpty ? "Series \(s + 1)" : series.label, index: i,
                      label: i < chart.labels.count ? chart.labels[i] : String(i + 1), value: value)
            }
        }
    }

    private var colors: [Color] {
        let fallback: [Color] = [accent, .mint, .orange, .pink, .indigo, .teal, .yellow, .purple]
        return chart.series.enumerated().map { $1.color?.color(accent: accent) ?? fallback[$0 % fallback.count] }
    }

    var body: some View {
        let names = chart.series.enumerated().map { $1.label.isEmpty ? "Series \($0 + 1)" : $1.label }
        Chart(points) { point in
            switch chart.kind {
            case .bar:
                BarMark(x: .value("Index", point.slot), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .cornerRadius(3)
            case .line:
                LineMark(x: .value("Index", point.slot), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
            case .area:
                AreaMark(x: .value("Index", point.slot), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .interpolationMethod(.monotone)
                    .opacity(0.6)
            }
        }
        .chartForegroundStyleScale(domain: names, range: colors)
        .chartLegend(chart.series.count > 1 ? .visible : .hidden)
        .chartLegend(position: .bottom, alignment: .leading) {
            // Atelier's own inks: the system legend follows the light or dark scheme, not the widget.
            HStack(spacing: 10) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    HStack(spacing: 4) {
                        Circle().fill(colors[index]).frame(width: 7, height: 7)
                        Text(name).font(.system(size: 10)).foregroundStyle(DS.Ink.secondary)
                    }
                }
            }
        }
        .chartYScale(domain: 0...(chart.max ?? max(points.map(\.value).max() ?? 1, 1)))
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel { Text(label(value.as(String.self) ?? "")).font(.system(size: 9)).foregroundStyle(DS.Ink.tertiary) }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(DS.Ink.hairline)
                AxisValueLabel().font(.system(size: 9)).foregroundStyle(DS.Ink.tertiary)
            }
        }
        .frame(minHeight: 60)
    }
}

/// A stack whose children animate in and out. Children are told apart by what they show.
private struct PluginTransitionStack: View {
    let transition: PluginTransition
    let node: PluginNode

    private var kind: AnyTransition {
        switch transition {
        case .fade: .opacity
        case .slide: .move(edge: .leading).combined(with: .opacity)
        case .scale: .scale(scale: 0.85).combined(with: .opacity)
        }
    }

    var body: some View {
        Group {
            if case .stack(let axis, let spacing, let alignment, let children) = node {
                let keyed = keys(children)
                switch axis {
                case .vertical:
                    VStack(alignment: alignment == .trailing ? .trailing : alignment == .center ? .center : .leading, spacing: spacing) { items(keyed) }
                case .horizontal:
                    HStack(alignment: alignment == .top ? .top : alignment == .bottom ? .bottom : .center, spacing: spacing) { items(keyed) }
                case .overlay:
                    ZStack { items(keyed) }
                }
            } else {
                PluginNodeView(node: node)
            }
        }
        .animation(DS.Motion.arrive, value: node)
    }

    private func items(_ keyed: [(String, PluginNode)]) -> some View {
        ForEach(keyed, id: \.0) { _, child in AnyView(PluginNodeView(node: child)).transition(kind) }
    }

    private func keys(_ children: [PluginNode]) -> [(String, PluginNode)] {
        var seen: [String: Int] = [:]
        return children.map { child in
            let base = String(describing: child)
            let n = seen[base, default: 0]
            seen[base] = n + 1
            return ("\(base.hashValue)#\(n)", child)
        }
    }
}
