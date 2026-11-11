import AppKit
import ImageIO
import IOKit
import IOKit.ps
import SwiftUI
import UniformTypeIdentifiers

private let english = Locale(identifier: "en_GB")

// MARK: - Shared sampling

/// One timer per meter, running only while at least one face that needs it is on screen.
@MainActor
final class Ticker {
    private let interval: TimeInterval
    private let action: @MainActor () -> Void
    private var users = 0
    private var timer: Timer?
    var started: (@MainActor () -> Void)?
    var stopped: (@MainActor () -> Void)?

    init(every interval: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.action = action
    }

    var running: Bool { timer != nil }

    func acquire() {
        users += 1
        guard users == 1 else { return }
        started?()
        action()
        let tick = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.action() }
        }
        tick.tolerance = interval * 0.2
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
    }

    func release() {
        guard users > 0 else { return }
        users -= 1
        guard users == 0 else { return }
        timer?.invalidate()
        timer = nil
        stopped?()
    }
}

private struct Metered: ViewModifier {
    let ticker: Ticker
    @State private var holding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !holding else { return }
                holding = true
                ticker.acquire()
            }
            .onDisappear {
                guard holding else { return }
                holding = false
                ticker.release()
            }
    }
}

extension View {
    /// Keeps the meter sampling for as long as this view is on screen.
    func metered(_ ticker: Ticker) -> some View { modifier(Metered(ticker: ticker)) }
}

/// A rolling window of samples that starts over after a pause, so a graph never joins two moments far apart.
private func push(_ value: Double, onto history: inout [Double], limit: Int) {
    history.append(value)
    if history.count > limit { history.removeFirst(history.count - limit) }
}

@MainActor
final class ActivityMeter: ObservableObject {
    static let shared = ActivityMeter()
    static let window = 60

    @Published private(set) var cpu = 0.0
    @Published private(set) var memory = 0.0
    @Published private(set) var memoryUsed = 0.0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var load: [Double] = []
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)
    let cores = ProcessInfo.processInfo.activeProcessorCount
    let booted: Date? = {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }()

    lazy var ticker = Ticker(every: 2) { [weak self] in self?.sample() }
    private var last: (busy: UInt64, total: UInt64)?
    private var lastSample: Date?

    private func sample() {
        let now = Date()
        if let lastSample, now.timeIntervalSince(lastSample) > 6 {
            last = nil
            cpuHistory = []
            memoryHistory = []
        }
        lastSample = now

        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
            let busy = user + system + nice, total = busy + idle
            if let last, total > last.total, busy >= last.busy {
                cpu = Double(busy - last.busy) / Double(total - last.total)
                push(cpu, onto: &cpuHistory, limit: Self.window)
            }
            last = (busy, total)
        }

        var stats = vm_statistics64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let vmStatus = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount)
            }
        }
        if vmStatus == KERN_SUCCESS, memoryTotal > 0 {
            // The same sum Activity Monitor calls Memory Used: app, wired and compressed.
            memoryUsed = Double(UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * Double(sysconf(_SC_PAGESIZE))
            memory = min(memoryUsed / memoryTotal, 1)
            push(memory, onto: &memoryHistory, limit: Self.window)
        }

        var averages = [Double](repeating: 0, count: 3)
        if getloadavg(&averages, 3) == 3 { load = averages }
    }
}

@MainActor
final class NetworkMeter: ObservableObject {
    static let shared = NetworkMeter()
    static let window = 60

    /// Bytes per second.
    @Published private(set) var down: Double?
    @Published private(set) var up: Double?
    @Published private(set) var downHistory: [Double] = []
    @Published private(set) var upHistory: [Double] = []

    lazy var ticker = Ticker(every: 2) { [weak self] in self?.sample() }
    private var counters: [String: (received: UInt32, sent: UInt32)] = [:]
    private var lastSample: Date?

    var peakDown: Double { downHistory.max() ?? 0 }
    var peakUp: Double { upHistory.max() ?? 0 }

    private func sample() {
        let now = Date()
        var current: [String: (received: UInt32, sent: UInt32)] = [:]
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            let flags = Int32(item.ifa_flags)
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let data = item.ifa_data else { continue }
            let name = String(cString: item.ifa_name)
            // Wi‑Fi, Ethernet and cellular. Tunnels and bridges would count the same bytes twice.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            let counts = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (counts.ifi_ibytes, counts.ifi_obytes)
        }
        defer {
            counters = current
            lastSample = now
        }
        guard let lastSample, case let elapsed = now.timeIntervalSince(lastSample), elapsed > 0.5, elapsed < 6 else {
            downHistory = []
            upHistory = []
            return
        }
        var received: UInt64 = 0, sent: UInt64 = 0
        for (name, value) in current {
            guard let old = counters[name] else { continue }
            // The kernel keeps 32-bit counters. Wrapping subtraction reads straight across a rollover.
            received += UInt64(value.received &- old.received)
            sent += UInt64(value.sent &- old.sent)
        }
        let downRate = Double(received) / elapsed, upRate = Double(sent) / elapsed
        down = downRate
        up = upRate
        push(downRate, onto: &downHistory, limit: Self.window)
        push(upRate, onto: &upHistory, limit: Self.window)
    }
}

struct PowerState: Equatable {
    var hasBattery = false
    var level = 0.0
    var charging = false
    var plugged = false
    var charged = false
    /// Minutes to empty on battery, or to full while charging. Nil while macOS is still estimating.
    var minutes: Int?
    /// Positive while charging, negative while drawing from the battery.
    var watts: Double?
    var cycles: Int?
    var health: Double?
    var adapterWatts: Int?
    var lowPower = false
}

@MainActor
final class BatteryMeter: ObservableObject {
    static let shared = BatteryMeter()
    @Published private(set) var state = PowerState()
    private var source: CFRunLoopSource?

    lazy var ticker: Ticker = {
        let ticker = Ticker(every: 30) { [weak self] in self?.sample() }
        ticker.started = { [weak self] in self?.listen(true) }
        ticker.stopped = { [weak self] in self?.listen(false) }
        return ticker
    }()

    /// macOS calls back the moment the adapter goes in or out, so the face never waits for the next tick.
    private func listen(_ on: Bool) {
        if on, source == nil {
            source = IOPSNotificationCreateRunLoopSource({ _ in
                MainActor.assumeIsolated { BatteryMeter.shared.sample() }
            }, nil)?.takeRetainedValue()
            if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        } else if !on, let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            CFRunLoopSourceInvalidate(source)
            self.source = nil
        }
    }

    /// Whether this Mac has a battery of its own, asked once: desktops never gain one. The
    /// battery-only settings (Pause on Battery) say so instead of offering a switch that does nothing.
    static let hasInternalBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return sources.contains { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    func sample() {
        var next = PowerState()
        next.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        // Either call can return NULL (a Mac mini or Mac Pro has no power sources to list); then
        // the state stays "no battery" rather than crashing on an unwrap.
        let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        let sources = info.flatMap { IOPSCopyPowerSourcesList($0)?.takeRetainedValue() as? [CFTypeRef] } ?? []
        for source in sources {
            guard let info, let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            next.hasBattery = true
            next.level = min(Double(current) / Double(maximum), 1)
            next.charging = description[kIOPSIsChargingKey] as? Bool ?? false
            next.charged = description[kIOPSIsChargedKey] as? Bool ?? false
            next.plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let key = next.charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
            if let minutes = description[key] as? Int, minutes > 0, !(next.plugged && !next.charging) { next.minutes = minutes }
            break
        }
        if next.hasBattery { readSmartBattery(into: &next) }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any],
           let watts = adapter[kIOPSPowerAdapterWattsKey] as? Int, watts > 0 {
            next.adapterWatts = watts
        }
        if next != state { state = next }
    }

    /// Cycle count, health and live power draw, read from the battery's own registry entry. No entitlement needed.
    private func readSmartBattery(into state: inout PowerState) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return }
        // Recent macOS keeps the capacities in a nested BatteryData dictionary, older ones at the top.
        let nested = values["BatteryData"] as? [String: Any] ?? [:]
        func number(_ key: String) -> NSNumber? { (values[key] ?? nested[key]) as? NSNumber }
        if let cycles = number("CycleCount")?.intValue, cycles >= 0 { state.cycles = cycles }
        // The battery's own running average beats the power source estimate, which can sit at a placeholder.
        let average = number(state.charging ? "AvgTimeToFull" : "AvgTimeToEmpty")?.intValue ?? 0
        if average > 0, average < 65_535, !(state.plugged && !state.charging) { state.minutes = average }
        if let raw = (number("AppleRawMaxCapacity") ?? number("FullChargeCapacity"))?.doubleValue,
           let design = number("DesignCapacity")?.doubleValue, design > 0, raw > 0 {
            state.health = min(raw / design, 1)
        }
        if let millivolts = number("Voltage")?.doubleValue,
           let milliamps = (number("InstantAmperage") ?? number("Amperage"))?.int64Value {
            // Amperage is signed, sometimes stored as its unsigned bit pattern. int64Value reads both right.
            let watts = millivolts * Double(milliamps) / 1_000_000
            if abs(watts) >= 0.1 { state.watts = watts }
        }
    }
}

@MainActor
final class DiskMeter: ObservableObject {
    static let shared = DiskMeter()
    @Published private(set) var used = 0.0
    @Published private(set) var free = 0.0
    @Published private(set) var total = 0.0

    /// The volume query costs ~15 ms, so it runs off the main thread, and disk use barely moves.
    lazy var ticker = Ticker(every: 120) { [weak self] in self?.sample() }

    private func sample() {
        Task {
            guard let reading = await Task.detached(priority: .utility, operation: { DiskMeter.read() }).value else { return }
            if reading.total != total { total = reading.total }
            if reading.free != free { free = reading.free }
            let fraction = min(max(1 - reading.free / reading.total, 0), 1)
            if fraction != used { used = fraction }
        }
    }

    nonisolated static func read() -> (total: Double, free: Double)? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? home.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeTotalCapacity, let available = values.volumeAvailableCapacityForImportantUsage, capacity > 0 else { return nil }
        return (Double(capacity), Double(available))
    }
}

enum Units {
    /// Decimal units, like Finder.
    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = max(value, 0), index = 0
        while amount >= 1000, index < units.count - 1 {
            amount /= 1000
            index += 1
        }
        let digits = index == 0 || amount >= 10 ? 0 : 1
        return amount.formatted(.number.precision(.fractionLength(digits)).locale(english)) + " " + units[index]
    }

    /// Memory reads in binary units, the way About This Mac counts it.
    static func memory(_ value: Double) -> String {
        let gigabytes = max(value, 0) / 1_073_741_824
        return gigabytes.formatted(.number.precision(.fractionLength(gigabytes >= 10 ? 0 : 1)).locale(english)) + " GB"
    }

    static func rate(_ value: Double?) -> String { value.map { bytes($0) + "/s" } ?? "—" }

    static func duration(minutes: Int) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    static func uptime(since boot: Date, now: Date) -> String {
        let minutes = max(Int(now.timeIntervalSince(boot) / 60), 0)
        let days = minutes / 1440, hours = minutes % 1440 / 60, rest = minutes % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(rest) min" }
        return "\(rest) min"
    }

    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }
}

// MARK: - Shared pieces

/// A line that scrolls in from the right, one sample per step.
struct Sparkline: Shape {
    var values: [Double]
    var ceiling: Double
    var capacity: Int
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, ceiling > 0 else { return path }
        let step = rect.width / Double(max(capacity - 1, 1))
        let points = values.enumerated().map { index, value in
            CGPoint(x: rect.maxX - Double(values.count - 1 - index) * step,
                    y: rect.maxY - min(max(value / ceiling, 0), 1) * rect.height)
        }
        path.move(to: points[0])
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            path.addQuadCurve(to: mid, control: a)
            if index == points.count - 1 { path.addLine(to: b) }
        }
        if closed, let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

struct SparkGraph: View {
    let values: [Double]
    let ceiling: Double
    let tint: Color
    var capacity = ActivityMeter.window
    var filled = true

    var body: some View {
        ZStack {
            if filled {
                Sparkline(values: values, ceiling: ceiling, capacity: capacity, closed: true)
                    .fill(LinearGradient(colors: [tint.opacity(0.34), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
            }
            Sparkline(values: values, ceiling: ceiling, capacity: capacity)
                .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct WidgetBar: View {
    let value: Double
    let tint: Color
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule().fill(tint).frame(width: max(geometry.size.height, geometry.size.width * min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
    }
}

struct WidgetPlaceholder: View {
    let symbol: String
    let text: String
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(theme.tertiary)
            Text(text).font(.system(size: 11.5)).foregroundStyle(theme.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Text {
    func widgetEyebrow(_ color: Color) -> some View {
        font(.system(size: 10.5, weight: .semibold)).tracking(1.1).foregroundStyle(color)
    }
}

// MARK: - Activity

struct ActivityWidget: View {
    @ObservedObject private var meter = ActivityMeter.shared
    @Environment(\.widgetTheme) private var theme

    private var memoryTint: Color { Color(red: 0.72, green: 0.52, blue: 1) }

    var body: some View {
        Group {
            if theme.small { small } else { medium }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .metered(meter.ticker)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("CPU").widgetEyebrow(theme.tertiary)
            Text(Units.percent(meter.cpu))
                .font(.system(size: 38, weight: .semibold)).monospacedDigit().tracking(-1)
                .contentTransition(.numericText())
            SparkGraph(values: meter.cpuHistory, ceiling: 1, tint: theme.accent)
                .frame(maxHeight: .infinity)
            HStack {
                Text("Memory").foregroundStyle(theme.secondary)
                Spacer()
                Text(Units.percent(meter.memory)).monospacedDigit()
            }
            .font(.system(size: 11.5, weight: .medium))
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 18) {
                column(title: "CPU", value: Units.percent(meter.cpu), detail: "\(meter.cores) cores",
                       history: meter.cpuHistory, tint: theme.accent)
                column(title: "Memory", value: Units.percent(meter.memory),
                       detail: "\(Units.memory(meter.memoryUsed)) of \(Units.memory(meter.memoryTotal))",
                       history: meter.memoryHistory, tint: memoryTint)
            }
            TimelineView(.everyMinute) { context in
                HStack {
                    if meter.load.count == 3 {
                        Text("Load " + meter.load.map { $0.formatted(.number.precision(.fractionLength(2)).locale(english)) }.joined(separator: "  "))
                    }
                    Spacer()
                    if let booted = meter.booted { Text("Up " + Units.uptime(since: booted, now: context.date)) }
                }
                .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.tertiary)
            }
        }
    }

    private func column(title: String, value: String, detail: String, history: [Double], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased()).widgetEyebrow(theme.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit().tracking(-0.8)
                    .contentTransition(.numericText())
                Text(detail).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            SparkGraph(values: history, ceiling: 1, tint: tint)
                .frame(maxHeight: .infinity)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) \(value), \(detail)")
    }
}

// MARK: - Network

struct NetworkWidget: View {
    @ObservedObject private var meter = NetworkMeter.shared
    @Environment(\.widgetTheme) private var theme

    /// The graph rescales to the busiest moment on screen, but never below 64 KB/s, so idle noise stays flat.
    private var ceiling: Double { max(meter.peakDown, meter.peakUp, 64_000) * 1.15 }

    var body: some View {
        Group {
            if theme.small { small } else { medium }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .metered(meter.ticker)
    }

    private var graph: some View {
        ZStack {
            SparkGraph(values: meter.downHistory, ceiling: ceiling, tint: theme.accent, capacity: NetworkMeter.window)
            SparkGraph(values: meter.upHistory, ceiling: ceiling, tint: theme.secondary, capacity: NetworkMeter.window, filled: false)
        }
    }

    private func rate(_ symbol: String, _ value: Double?, size: Double, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: size * 0.6, weight: .bold)).foregroundStyle(tint)
            Text(Units.rate(value)).font(.system(size: size, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("NETWORK").widgetEyebrow(theme.tertiary)
            rate("arrow.down", meter.down, size: 21, tint: theme.accent)
            rate("arrow.up", meter.up, size: 14, tint: theme.secondary)
            graph.frame(maxHeight: .infinity).padding(.top, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download \(Units.rate(meter.down)), upload \(Units.rate(meter.up))")
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("NETWORK").widgetEyebrow(theme.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    rate("arrow.down", meter.down, size: 22, tint: theme.accent)
                    Text("Peak \(Units.rate(meter.peakDown))").font(.system(size: 11)).foregroundStyle(theme.tertiary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    rate("arrow.up", meter.up, size: 16, tint: theme.secondary)
                    Text("Peak \(Units.rate(meter.peakUp))").font(.system(size: 11)).foregroundStyle(theme.tertiary)
                }
                Spacer(minLength: 0)
                Text("Last 2 minutes").font(.system(size: 10.5)).foregroundStyle(theme.tertiary)
            }
            .frame(width: 136, alignment: .leading)
            graph.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Download \(Units.rate(meter.down)), upload \(Units.rate(meter.up))")
    }
}

// MARK: - Battery

struct BatteryWidget: View {
    @ObservedObject private var meter = BatteryMeter.shared
    @Environment(\.widgetTheme) private var theme

    private var state: PowerState { meter.state }

    private var tint: Color {
        if state.charging || (state.plugged && state.charged) { return Color(red: 0.42, green: 0.88, blue: 0.5) }
        if state.level <= 0.2 && !state.plugged { return Color(red: 1, green: 0.42, blue: 0.4) }
        return theme.accent
    }

    private var status: String {
        if state.charging { return "Charging" }
        if state.plugged { return state.charged ? "Charged" : "On Power Adapter" }
        return state.lowPower ? "Low Power Mode" : "On Battery"
    }

    private var time: String {
        if let minutes = state.minutes {
            return state.charging ? "\(Units.duration(minutes: minutes)) to full" : "\(Units.duration(minutes: minutes)) left"
        }
        if state.plugged { return state.charging ? "Estimating time to full" : "Not charging" }
        return "Estimating time left"
    }

    var body: some View {
        Group {
            if !state.hasBattery {
                VStack(spacing: 8) {
                    Image(systemName: "powerplug.fill").font(.system(size: 26)).foregroundStyle(theme.accent)
                    Text("No Battery").font(.system(size: 14, weight: .semibold))
                    Text(state.adapterWatts.map { "Running on a \($0) W adapter" } ?? "Running on mains power")
                        .font(.system(size: 11.5)).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                }
                .padding(16)
            } else if theme.small {
                VStack(spacing: 10) {
                    gauge(diameter: 92)
                    VStack(spacing: 1) {
                        Text(status).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(time).font(.system(size: 11)).foregroundStyle(theme.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .padding(14)
            } else {
                HStack(spacing: 20) {
                    gauge(diameter: 120)
                    VStack(alignment: .leading, spacing: 9) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(status).font(.system(size: 17, weight: .semibold))
                            Text(time).font(.system(size: 12)).foregroundStyle(theme.secondary)
                        }
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                            if let watts = state.watts {
                                row(watts > 0 ? "Charging at" : "Drawing", "\(abs(watts).formatted(.number.precision(.fractionLength(1)).locale(english))) W")
                            }
                            if let health = state.health { row("Health", Units.percent(health)) }
                            if let cycles = state.cycles { row("Cycles", "\(cycles)") }
                            if state.plugged, let adapter = state.adapterWatts { row("Adapter", "\(adapter) W") }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 22)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .metered(meter.ticker)
        .accessibilityElement(children: .combine)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(theme.tertiary)
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium))
    }

    private func gauge(diameter: Double) -> some View {
        let line = diameter > 100 ? 10.0 : 8.0
        return ZStack {
            Circle().stroke(theme.track, lineWidth: line)
            Circle().trim(from: 0, to: state.level)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(DS.Motion.arrive, value: state.level)
            VStack(spacing: 0) {
                if state.charging || state.plugged {
                    Image(systemName: state.charging ? "bolt.fill" : "powerplug.fill")
                        .font(.system(size: diameter * 0.12, weight: .bold)).foregroundStyle(tint)
                }
                Text(Units.percent(state.level))
                    .font(.system(size: diameter * 0.22, weight: .semibold)).monospacedDigit().tracking(-0.5)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: diameter, height: diameter)
    }
}

// MARK: - Day progress

struct ProgressWidget: View {
    @Environment(\.widgetTheme) private var theme

    private struct Span {
        let title: String
        let fraction: Double
        let left: String
    }

    private func spans(_ now: Date) -> [Span] {
        let calendar = Calendar.current
        func span(_ title: String, _ unit: Calendar.Component) -> Span {
            guard let interval = calendar.dateInterval(of: unit, for: now), interval.duration > 0 else { return Span(title: title, fraction: 0, left: "") }
            let fraction = now.timeIntervalSince(interval.start) / interval.duration
            let remaining = interval.end.timeIntervalSince(now)
            let left: String
            if unit == .day {
                let minutes = Int(remaining / 60)
                left = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min left" : "\(minutes) min left"
            } else {
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: interval.end).day ?? 0
                left = days == 1 ? "Last day" : "\(days) days left"
            }
            return Span(title: title, fraction: min(max(fraction, 0), 1), left: left)
        }
        return [span("Day", .day), span("Week", .weekOfYear), span("Month", .month), span("Year", .year)]
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let list = spans(context.date)
            if theme.small { small(list) } else { medium(list) }
        }
    }

    private func small(_ list: [Span]) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().stroke(theme.track, lineWidth: 9)
                Circle().trim(from: 0, to: list[0].fraction)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(Units.percent(list[0].fraction)).font(.system(size: 24, weight: .semibold)).monospacedDigit()
                    Text("of today").font(.system(size: 10.5)).foregroundStyle(theme.tertiary)
                }
            }
            .frame(width: 100, height: 100)
            HStack(spacing: 14) {
                ForEach([list[1], list[3]], id: \.title) { span in
                    VStack(spacing: 0) {
                        Text(Units.percent(span.fraction)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        Text(span.title).font(.system(size: 10.5)).foregroundStyle(theme.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(list.map { "\($0.title) \(Units.percent($0.fraction))" }.joined(separator: ", "))
    }

    private func medium(_ list: [Span]) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            ForEach(list, id: \.title) { span in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(span.title).font(.system(size: 12.5, weight: .semibold))
                        Text(span.left).font(.system(size: 11)).foregroundStyle(theme.tertiary)
                        Spacer()
                        Text(Units.percent(span.fraction)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                    }
                    WidgetBar(value: span.fraction, tint: theme.accent)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Countdown

struct CountdownWidget: View {
    let options: WidgetOptions
    @Environment(\.widgetTheme) private var theme

    private var title: String {
        let title = options.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "Countdown" : title
    }

    var body: some View {
        if let target = options.date {
            TimelineView(.everyMinute) { context in
                let info = Self.describe(target: target, now: context.date)
                if theme.small { small(info, target) } else { medium(info, target, now: context.date) }
            }
        } else {
            WidgetPlaceholder(symbol: "hourglass", text: "Pick a date in Settings, Widgets.")
        }
    }

    struct Reading {
        /// The headline number and what it counts.
        let value: String
        let unit: String
        let past: Bool
        let parts: (days: Int, hours: Int, minutes: Int)
    }

    /// Whole calendar days for anything past tomorrow, hours and minutes for the last stretch.
    static func describe(target: Date, now: Date, calendar: Calendar = .current) -> Reading {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: target)).day ?? 0
        let parts = calendar.dateComponents([.day, .hour, .minute], from: now, to: max(target, now))
        let split = (parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        if target <= now {
            if days == 0 { return Reading(value: "Today", unit: "", past: true, parts: (0, 0, 0)) }
            let ago = -days
            return Reading(value: "\(ago)", unit: ago == 1 ? "day ago" : "days ago", past: true, parts: (0, 0, 0))
        }
        if days >= 2 || (days == 1 && target.timeIntervalSince(now) >= 86_400) {
            return Reading(value: "\(days)", unit: days == 1 ? "day to go" : "days to go", past: false, parts: split)
        }
        let minutes = Int(ceil(target.timeIntervalSince(now) / 60))
        if minutes < 60 { return Reading(value: "\(minutes)", unit: minutes == 1 ? "minute to go" : "minutes to go", past: false, parts: split) }
        let hours = minutes / 60
        return Reading(value: "\(hours)", unit: hours == 1 ? "hour to go" : "hours to go", past: false, parts: split)
    }

    private func small(_ info: Reading, _ target: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).widgetEyebrow(theme.accent).lineLimit(1)
            Spacer(minLength: 0)
            Text(info.value)
                .font(.system(size: info.value.count > 4 ? 40 : 60, weight: .semibold)).tracking(-2).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(info.unit).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.secondary)
            Spacer(minLength: 0)
            Text(target.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(english)))
                .font(.system(size: 11.5)).foregroundStyle(theme.tertiary)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func medium(_ info: Reading, _ target: Date, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                Text(target.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(english)))
                    .font(.system(size: 11.5)).foregroundStyle(theme.tertiary)
            }
            Spacer(minLength: 0)
            if info.past {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(info.value).font(.system(size: 40, weight: .semibold)).tracking(-1.5)
                    Text(info.unit).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.secondary)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 18) {
                    unit(info.parts.days, "days")
                    unit(info.parts.hours, "hours")
                    unit(info.parts.minutes, "minutes")
                }
            }
            Spacer(minLength: 0)
            if let start = options.start, start < target {
                WidgetBar(value: now.timeIntervalSince(start) / target.timeIntervalSince(start), tint: theme.accent)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(info.value) \(info.unit)")
    }

    private func unit(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)").font(.system(size: 36, weight: .semibold)).tracking(-1).monospacedDigit()
            Text(label).font(.system(size: 11)).foregroundStyle(theme.tertiary)
        }
    }
}

// MARK: - Moon

/// New and full moons from Meeus's lunation series (as in John Walker's moontool), good to a few minutes.
enum Lunar {
    static let synodic = 29.53058868

    static func julian(_ date: Date) -> Double { date.timeIntervalSince1970 / 86_400 + 2_440_587.5 }
    static func date(julian: Double) -> Date { Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86_400) }

    private static func sine(_ degrees: Double) -> Double { sin(degrees * .pi / 180) }

    /// Julian date of lunation `k` (counted from January 1900) at phase 0 (new) or 0.5 (full).
    static func truePhase(_ lunation: Double, _ phase: Double) -> Double {
        let k = lunation + phase
        let t = k / 1236.85, t2 = t * t, t3 = t2 * t
        var time = 2_415_020.75933 + synodic * k + 0.0001178 * t2 - 0.000000155 * t3
            + 0.00033 * sine(166.56 + 132.87 * t - 0.009173 * t2)
        let m = 359.2242 + 29.10535608 * k - 0.0000333 * t2 - 0.00000347 * t3
        let mp = 306.0253 + 385.81691806 * k + 0.0107306 * t2 + 0.00001236 * t3
        let f = 21.2964 + 390.67050646 * k - 0.0016528 * t2 - 0.00000239 * t3
        time += (0.1734 - 0.000393 * t) * sine(m) + 0.0021 * sine(2 * m)
            - 0.4068 * sine(mp) + 0.0161 * sine(2 * mp) - 0.0004 * sine(3 * mp)
            + 0.0104 * sine(2 * f) - 0.0051 * sine(m + mp) - 0.0074 * sine(m - mp)
            + 0.0004 * sine(2 * f + m) - 0.0004 * sine(2 * f - m)
            - 0.0006 * sine(2 * f + mp) + 0.0010 * sine(2 * f - mp) + 0.0005 * sine(m + 2 * mp)
        return time
    }

    struct Phase {
        /// 0 new, 0.5 full, back to 1.
        let fraction: Double
        let illumination: Double
        let age: Double
        let name: String
        let nextNew: Date
        let nextFull: Date
    }

    static func phase(at date: Date) -> Phase {
        let jd = julian(date)
        var k = floor((jd - 2_415_020.75933) / synodic)
        while truePhase(k, 0) > jd { k -= 1 }
        while truePhase(k + 1, 0) <= jd { k += 1 }
        let previous = truePhase(k, 0), next = truePhase(k + 1, 0)
        let full = truePhase(k, 0.5)
        let nextFull = full > jd ? full : truePhase(k + 1, 0.5)
        let age = jd - previous
        let fraction = age / (next - previous)
        let illumination = (1 - cos(2 * .pi * fraction)) / 2
        // Named phases last about a day either side of the exact moment.
        let name: String
        switch fraction {
        case ..<0.034, 0.966...: name = "New Moon"
        case ..<0.216: name = "Waxing Crescent"
        case ..<0.284: name = "First Quarter"
        case ..<0.466: name = "Waxing Gibbous"
        case ..<0.534: name = "Full Moon"
        case ..<0.716: name = "Waning Gibbous"
        case ..<0.784: name = "Last Quarter"
        default: name = "Waning Crescent"
        }
        return Phase(fraction: fraction, illumination: illumination, age: age, name: name,
                     nextNew: self.date(julian: next), nextFull: self.date(julian: nextFull))
    }
}

struct MoonDisk: View {
    let fraction: Double
    var southern = false
    @Environment(\.widgetTheme) private var theme

    /// The lit part, bounded by the limb on one side and the terminator, a half ellipse, on the other.
    static func lit(fraction: Double, in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2, cx = rect.midX, cy = rect.midY
        let c = cos(2 * .pi * fraction)
        let waxing = fraction < 0.5
        let steps = 72
        var right: [CGPoint] = [], left: [CGPoint] = []
        for i in 0...steps {
            let y = -r + 2 * r * Double(i) / Double(steps)
            let half = (max(r * r - y * y, 0)).squareRoot()
            if waxing {
                right.append(CGPoint(x: cx + half, y: cy + y))
                left.append(CGPoint(x: cx + c * half, y: cy + y))
            } else {
                left.append(CGPoint(x: cx - half, y: cy + y))
                right.append(CGPoint(x: cx - c * half, y: cy + y))
            }
        }
        var path = Path()
        path.addLines(right)
        path.addLines(left.reversed())
        path.closeSubpath()
        return path
    }

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            context.fill(Path(ellipseIn: rect), with: .color(theme.ink.opacity(theme.light ? 0.12 : 0.1)))
            context.fill(Self.lit(fraction: fraction, in: rect), with: .color(Color(red: 0.97, green: 0.95, blue: 0.88)))
            context.stroke(Path(ellipseIn: rect), with: .color(theme.ink.opacity(0.14)), lineWidth: 0.75)
        }
        .scaleEffect(x: southern ? -1 : 1)
        .shadow(color: .white.opacity(theme.light ? 0 : 0.18 * (1 - cos(2 * .pi * fraction)) / 2), radius: 14)
        .accessibilityHidden(true)
    }
}

struct MoonWidget: View {
    let southern: Bool
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1800)) { context in
            let phase = Lunar.phase(at: context.date)
            Group {
                if theme.small { small(phase) } else { medium(phase) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(phase.name), \(Units.percent(phase.illumination)) illuminated")
        }
    }

    private func small(_ phase: Lunar.Phase) -> some View {
        VStack(spacing: 12) {
            MoonDisk(fraction: phase.fraction, southern: southern).frame(width: 96, height: 96)
            VStack(spacing: 1) {
                Text(phase.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text("\(Units.percent(phase.illumination)) lit").font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func medium(_ phase: Lunar.Phase) -> some View {
        let events = [("Full Moon", phase.nextFull), ("New Moon", phase.nextNew)].sorted { $0.1 < $1.1 }
        return HStack(spacing: 22) {
            MoonDisk(fraction: phase.fraction, southern: southern).frame(width: 132, height: 132)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(phase.name).font(.system(size: 18, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text("\(Units.percent(phase.illumination)) lit · day \(Int(phase.age) + 1) of 29")
                        .font(.system(size: 11.5)).foregroundStyle(theme.secondary)
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(events, id: \.0) { event in
                        GridRow {
                            Text(event.0).foregroundStyle(theme.tertiary)
                            Text(event.1.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(english)))
                        }
                        .font(.system(size: 11.5, weight: .medium))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sticker

struct StickerWidget: View {
    let options: WidgetOptions
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        let text = options.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let by = options.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            WidgetPlaceholder(symbol: "quote.opening", text: "Write your text in Settings, Widgets.")
        } else {
            let size: Double = switch theme.size {
            case .small: 20
            case .medium: 25
            case .large: 32
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(text)
                    .font(.system(size: size, weight: .semibold)).tracking(-size * 0.012).lineSpacing(size * 0.08)
                    .minimumScaleFactor(0.3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: by.isEmpty ? .leading : .bottomLeading)
                if !by.isEmpty {
                    Text("— " + by).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.accent).lineLimit(1)
                }
            }
            .padding(theme.small ? 16 : 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Photo

struct PhotoWidget: View {
    let options: WidgetOptions
    let pixels: Double

    var body: some View {
        if let name = options.photo, let image = WidgetPhotos.image(name, pixels: pixels) {
            Color.clear
                .overlay { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    if let caption = options.title?.trimmingCharacters(in: .whitespacesAndNewlines), !caption.isEmpty {
                        Text(caption)
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(2)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                            .padding(.horizontal, 14).padding(.bottom, 14).padding(.top, 40)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black.opacity(0.18), location: 0.45),
                                                               .init(color: .black.opacity(0.5), location: 1)], startPoint: .top, endPoint: .bottom))
                    }
                }
                .accessibilityLabel(options.title ?? "Photo")
        } else {
            WidgetPlaceholder(symbol: "photo", text: options.photo == nil ? "Choose a photo in Settings, Widgets." : "This photo is gone. Choose another in Settings.")
                .background(Color.black.opacity(0.28))
        }
    }
}

/// Photos live in Atelier's own folder, downsized once, so the original can move or go.
@MainActor
enum WidgetPhotos {
    private static var cache: [String: NSImage] = [:]
    static let longestSide = 1600

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Atelier/Widget Photos", isDirectory: true)
    }

    private static func url(_ name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return folder.appendingPathComponent(name)
    }

    /// Writes a downsized copy and returns its file name, or nil when the file is not an image.
    static func importImage(from source: URL) -> String? {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { return nil }
        let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let type = alpha ? UTType.png : UTType.jpeg
        let name = UUID().uuidString + "." + (type.preferredFilenameExtension ?? "img")
        guard let target = url(name) else { return nil }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        guard let output = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            try? FileManager.default.removeItem(at: target)
            return nil
        }
        return name
    }

    static func delete(_ name: String) {
        cache = cache.filter { !$0.key.hasPrefix(name + "@") }
        guard let target = url(name) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// Decoded at the size it is drawn, then kept.
    static func image(_ name: String, pixels: Double) -> NSImage? {
        let side = Int(pixels.rounded(.up))
        let key = "\(name)@\(side)"
        if let hit = cache[key] { return hit }
        guard let file = url(name), let input = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(side, 64),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        cache[key] = result
        return result
    }
}

// MARK: - Style editor

struct WidgetStyleEditor: View {
    @Binding var style: WidgetStyle

    private enum Fill: Hashable { case material, gradient, image }

    private var fill: Binding<Fill> {
        Binding(get: { style.image != nil ? .image : style.gradient != nil ? .gradient : .material },
                set: { new in
                    withAnimation(DS.Motion.arrive) {
                        switch new {
                        case .material:
                            let old = style.image
                            style.gradient = nil
                            style.image = nil
                            WidgetBoard.shared.release(picture: old)
                        case .gradient:
                            let old = style.image
                            style.image = nil
                            if style.gradient == nil { style.gradient = WidgetGradient() }
                            WidgetBoard.shared.release(picture: old)
                        case .image:
                            choosePicture()
                        }
                    }
                })
    }

    private var gradient: Binding<WidgetGradient> {
        Binding(get: { style.gradient ?? WidgetGradient() }, set: { style.gradient = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            labeled("Material") {
                ChipPicker(selection: $style.material, options: WidgetMaterial.allCases.map { ($0, $0.title) }, minimum: 70)
            }
            if style.material == .tinted {
                labeled("Tint") { Swatches(selection: $style.tint) }
                    .transition(.opacity)
            }
            if style.material != .bare {
                labeled("Background") {
                    Segments(selection: fill, options: [(.material, "Material"), (.gradient, "Gradient"), (.image, "Picture")])
                }
                if style.gradient != nil && style.image == nil {
                    labeled("From") { Swatches(selection: gradient.from) }
                    labeled("To") { Swatches(selection: gradient.to) }
                    labeled("Direction", value: "\(Int(gradient.wrappedValue.angle.rounded()))°") {
                        LuxSlider(value: gradient.angle, range: 0...360)
                    }
                }
                if style.image != nil {
                    Button { choosePicture() } label: {
                        Text("Choose Another Picture…").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.accent)
                    }
                    .buttonStyle(.plain)
                }
                if style.image != nil || [.glass, .clear, .tinted, .frosted].contains(style.material) {
                    labeled(style.image != nil ? "Picture Blur" : "Backdrop Blur", value: style.blur < 0.02 ? "None" : Units.percent(style.blur)) {
                        LuxSlider(value: $style.blur, range: WidgetStyle.blurs)
                    }
                }
            }
            labeled("Accent") { Swatches(selection: $style.accent) }
            labeled("Font") {
                Segments(selection: $style.font, options: WidgetFont.allCases.map { ($0, $0.title) })
            }
            if style.material != .bare {
                labeled("Corner Radius", value: "\(Int(style.radius.rounded())) pt") {
                    LuxSlider(value: $style.radius, range: WidgetStyle.radii)
                }
            }
            labeled("Opacity", value: Units.percent(style.opacity)) {
                LuxSlider(value: $style.opacity, range: WidgetStyle.opacities)
            }
            labeled("Text Size", value: Units.percent(style.scale)) {
                LuxSlider(value: $style.scale, range: WidgetStyle.scales)
            }
            labeled("Padding", value: "\(Int(style.padding.rounded())) pt") {
                LuxSlider(value: $style.padding, range: WidgetStyle.paddings)
            }
            labeled("Shadow", value: style.shadow < 0.01 ? "None" : Units.percent(style.shadow)) {
                LuxSlider(value: $style.shadow, range: WidgetStyle.shadows)
            }
            if style.material != .bare {
                labeled("Border", value: style.border < 0.05 ? "None" : String(format: "%.1f pt", style.border)) {
                    LuxSlider(value: $style.border, range: WidgetStyle.borders)
                }
            }
            if style != WidgetStyle() {
                Button {
                    let old = style.image
                    withAnimation(DS.Motion.arrive) { style = WidgetStyle() }
                    WidgetBoard.shared.release(picture: old)
                } label: {
                    Text("Reset to Default").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Ink.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(DS.Motion.arrive, value: style.material)
    }

    /// A copy goes into Atelier's own folder, like a Photo Frame's, and the one it replaces is let go once unused.
    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Picture"
        guard panel.runModal() == .OK, let url = panel.url, let name = WidgetPhotos.importImage(from: url) else { return }
        let old = style.image
        style.image = name
        WidgetBoard.shared.release(picture: old)
    }

    private func labeled<Content: View>(_ title: String, value: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(DS.caption).foregroundStyle(DS.Ink.secondary)
                Spacer()
                if let value { Text(value).font(DS.caption).monospacedDigit().foregroundStyle(DS.Ink.tertiary) }
            }
            content()
        }
    }
}

struct Swatches: View {
    @Binding var selection: WidgetTint

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 24, maximum: 30), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(WidgetTint.allCases) { tint in
                Button {
                    withAnimation(DS.Motion.settle) { selection = tint }
                } label: {
                    Circle().fill(tint.color)
                        .frame(width: 20, height: 20)
                        .padding(3)
                        .overlay {
                            Circle().strokeBorder(.white.opacity(selection == tint ? 0.9 : 0), lineWidth: 1.5)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(Pressable(scale: 0.88))
                .accessibilityLabel(tint.title)
                .accessibilityAddTraits(selection == tint ? .isSelected : [])
            }
        }
    }
}
