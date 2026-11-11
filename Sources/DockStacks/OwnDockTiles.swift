import AppKit
import IOKit.ps
import DockCore
import SwiftUI

// The tiles that are not files: Clock, Battery, Downloads, Clipboard, Orbit and spacers.
// Their data lives in one feed that only the glyphs observe, so a new minute or a new
// battery level redraws a tile, never the Studio. Each source runs only while its tile is
// on the dock and the dock is showing.

struct DockBattery: Equatable, Sendable {
    var level: Double
    var charging: Bool
    var plugged: Bool
    /// Minutes, when macOS has an estimate.
    var minutesLeft: Int?
}

struct DockDownloads: Equatable, Sendable {
    var count = 0
    /// 0 to 1 when known.
    var progress: Double?
    var names: [String] = []
}

@MainActor
final class OwnDockFeed: ObservableObject {
    static let shared = OwnDockFeed()

    @Published private(set) var now = Date()
    @Published private(set) var battery: DockBattery?
    @Published private(set) var downloads = DockDownloads()
    @Published private(set) var clip: String?

    /// A Clock tile shows seconds: the clock ticks every second instead of every minute.
    var seconds = false {
        didSet {
            guard seconds != oldValue, clockTimer != nil else { return }
            stopClock()
            startClock()
        }
    }

    /// Download progress the macOS Dock draws on a folder, by folder path. Set by the dock.
    var dockProgress: [String: Double] = [:] { didSet { if dockProgress != oldValue { scanDownloads() } } }

    private var clockTimer: Timer?
    private var downloadTimer: Timer?
    private var clipTimer: Timer?
    private var powerSource: CFRunLoopSource?
    private var clipChange = -1
    private var scanning = false
    private(set) var kinds: Set<OwnDockItem.Kind> = []

    nonisolated static let downloadsFolder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)

    /// Runs the sources these tiles need and stops the rest. An empty set stops everything.
    func run(_ wanted: Set<OwnDockItem.Kind>) {
        guard wanted != kinds else { return }
        kinds = wanted
        wanted.contains(.clock) ? startClock() : stopClock()
        wanted.contains(.battery) ? startBattery() : stopBattery()
        wanted.contains(.downloads) ? startDownloads() : stopDownloads()
        wanted.contains(.clipboard) ? startClipboard() : stopClipboard()
    }

    // MARK: Clock

    private func startClock() {
        guard clockTimer == nil else { return }
        now = Date()
        // Fire on the minute, then every minute; on the second when a clock shows seconds.
        let next: Date
        if seconds {
            next = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate + 1).rounded(.down))
        } else {
            next = Calendar.current.nextDate(after: Date(), matching: DateComponents(second: 0), matchingPolicy: .nextTime)
                ?? Date().addingTimeInterval(60)
        }
        let timer = Timer(fire: next, interval: seconds ? 1 : 60, repeats: true) { _ in
            MainActor.assumeIsolated { OwnDockFeed.shared.now = Date() }
        }
        timer.tolerance = seconds ? 0.05 : 0.5
        RunLoop.main.add(timer, forMode: .common)
        clockTimer = timer
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    // MARK: Battery

    private func startBattery() {
        guard powerSource == nil else { return }
        battery = Self.readBattery()
        // IOKit calls this when anything about power changes. No polling.
        guard let source = IOPSNotificationCreateRunLoopSource({ _ in
            MainActor.assumeIsolated { OwnDockFeed.shared.battery = OwnDockFeed.readBattery() }
        }, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    private func stopBattery() {
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
    }

    nonisolated static func readBattery() -> DockBattery? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = (charging ? description[kIOPSTimeToFullChargeKey] : description[kIOPSTimeToEmptyKey]) as? Int
            return DockBattery(level: Double(current) / Double(maximum), charging: charging, plugged: plugged,
                               minutesLeft: (minutes ?? -1) > 0 ? minutes : nil)
        }
        return nil
    }

    // MARK: Downloads

    private func startDownloads() {
        guard downloadTimer == nil else { return }
        scanDownloads()
        let timer = Timer(timeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated { OwnDockFeed.shared.scanDownloads() }
        }
        timer.tolerance = 0.4
        RunLoop.main.add(timer, forMode: .common)
        downloadTimer = timer
    }

    private func stopDownloads() {
        downloadTimer?.invalidate()
        downloadTimer = nil
    }

    private func scanDownloads() {
        guard downloadTimer != nil, !scanning else { return }
        scanning = true
        let fromDock = dockProgress[Self.downloadsFolder.resolvingSymlinksInPath().path]
        Task.detached(priority: .utility) {
            var state = Self.inProgress(in: Self.downloadsFolder)
            if let fromDock { state.progress = fromDock; state.count = max(state.count, 1) }
            await MainActor.run {
                let feed = OwnDockFeed.shared
                feed.scanning = false
                if feed.downloads != state { feed.downloads = state }
            }
        }
    }

    /// Unfinished downloads: Safari's `.download` bundles, which carry their own progress,
    /// and Chrome's `.crdownload` and Firefox's `.part` files, which do not.
    nonisolated static func inProgress(in folder: URL) -> DockDownloads {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return DockDownloads() }
        var state = DockDownloads()
        var done = 0.0, total = 0.0
        for name in names {
            let ext = (name as NSString).pathExtension.lowercased()
            guard ext == "download" || ext == "crdownload" || ext == "part" else { continue }
            state.count += 1
            state.names.append((name as NSString).deletingPathExtension)
            if ext == "download",
               let info = NSDictionary(contentsOf: folder.appendingPathComponent(name).appendingPathComponent("Info.plist")),
               let soFar = info["DownloadEntryProgressBytesSoFar"] as? Double,
               let whole = info["DownloadEntryProgressTotalToLoad"] as? Double, whole > 0 {
                done += soFar
                total += whole
            }
        }
        if total > 0 { state.progress = min(done / total, 1) }
        return state
    }

    // MARK: Clipboard

    private func startClipboard() {
        guard clipTimer == nil else { return }
        clipChange = -1
        readClipboard()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { OwnDockFeed.shared.readClipboard() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        clipTimer = timer
    }

    private func stopClipboard() {
        clipTimer?.invalidate()
        clipTimer = nil
    }

    /// The change count is one cheap call; the text is read only when it moves.
    private func readClipboard() {
        let board = NSPasteboard.general
        guard board.changeCount != clipChange else { return }
        clipChange = board.changeCount
        // Password managers mark secrets as concealed; those are never kept.
        guard board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) != true,
              let text = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        clip = String(text.prefix(2000))
    }

    /// Puts the kept text back on the clipboard.
    func copyClipAgain() {
        guard let clip else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(clip, forType: .string)
        clipChange = board.changeCount
    }

    func clearClip() { clip = nil }
}

// MARK: - Glyphs

/// The rounded square every Atelier tile sits on, so it reads as an icon among icons.
struct DockTileFace<Content: View>: View {
    let size: Double
    var colors: [Color] = [Color(red: 0.2, green: 0.22, blue: 0.28), Color(red: 0.09, green: 0.1, blue: 0.13)]
    /// A tile's chosen look replaces its own colours.
    var style = DockFace.Style.standard
    var accent = Color.white
    @ViewBuilder var content: Content

    static func colors(_ style: DockFace.Style, own: [Color], accent: Color) -> [Color] {
        switch style {
        case .standard: own
        case .glass: [.white.opacity(0.34), .white.opacity(0.12)]
        case .accent: [accent, accent.opacity(0.62)]
        case .dark: [Color(white: 0.16), Color(white: 0.04)]
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(LinearGradient(colors: Self.colors(style, own: colors, accent: accent), startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: max(size * 0.012, 0.5))
            content
        }
        .frame(width: size * 0.84, height: size * 0.84)
        .frame(width: size, height: size)
    }
}

struct DockClockGlyph: View {
    @ObservedObject var feed: OwnDockFeed
    let size: Double
    let accent: Color
    var face = DockFace()

    /// Light ink on a dark face, dark ink on the standard white one.
    private var ink: Color { face.style == .standard ? Color(white: 0.12) : .white }
    private var soft: Color { face.style == .standard ? Color(white: 0.4) : .white.opacity(0.7) }

    var body: some View {
        DockTileFace(size: size, colors: [Color(white: 0.98), Color(white: 0.86)], style: face.style, accent: accent) {
            if face.analog { analog } else { digital }
        }
    }

    private var digital: some View {
        VStack(spacing: size * 0.01) {
            Text(feed.now, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: size * 0.13, weight: .semibold)).textCase(.uppercase)
                .foregroundStyle(face.style == .standard ? Color(red: 0.92, green: 0.25, blue: 0.22) : .white.opacity(0.85))
            Text(DockClockText.time(feed.now, face))
                .font(.system(size: size * (face.seconds ? 0.19 : 0.25), weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(ink)
            if face.date {
                Text(feed.now, format: .dateTime.day().month(.abbreviated))
                    .font(.system(size: size * 0.11, weight: .medium))
                    .foregroundStyle(soft)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    private var analog: some View {
        let now = feed.now
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: now)
        let minutes = Double(parts.minute ?? 0) + (face.seconds ? Double(parts.second ?? 0) / 60 : 0)
        let hours = Double((parts.hour ?? 0) % 12) + minutes / 60
        let seconds = Double(parts.second ?? 0)
        let showSeconds = face.seconds
        let ink = ink
        return Canvas { context, box in
            let center = CGPoint(x: box.width / 2, y: box.height / 2)
            let radius = min(box.width, box.height) / 2 * 0.9
            for tick in 0..<12 {
                let angle = Double(tick) / 12 * 2 * .pi
                let outer = CGPoint(x: center.x + sin(angle) * radius, y: center.y - cos(angle) * radius)
                let inner = CGPoint(x: center.x + sin(angle) * radius * (tick % 3 == 0 ? 0.78 : 0.86),
                                    y: center.y - cos(angle) * radius * (tick % 3 == 0 ? 0.78 : 0.86))
                var path = Path()
                path.move(to: inner)
                path.addLine(to: outer)
                context.stroke(path, with: .color(ink.opacity(0.55)), lineWidth: max(radius * (tick % 3 == 0 ? 0.06 : 0.035), 0.6))
            }
            func hand(_ turns: Double, _ length: Double, _ width: Double, _ color: Color) {
                let angle = turns * 2 * .pi
                var path = Path()
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + sin(angle) * radius * length, y: center.y - cos(angle) * radius * length))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: max(radius * width, 0.8), lineCap: .round))
            }
            hand(hours / 12, 0.5, 0.1, ink)
            hand(minutes / 60, 0.74, 0.07, ink)
            if showSeconds { hand(seconds / 60, 0.8, 0.03, Color(red: 0.95, green: 0.3, blue: 0.25)) }
            context.fill(Path(ellipseIn: CGRect(x: center.x - radius * 0.07, y: center.y - radius * 0.07,
                                                width: radius * 0.14, height: radius * 0.14)), with: .color(ink))
        }
        .padding(size * 0.06)
        .accessibilityLabel(now.formatted(date: .omitted, time: .shortened))
    }
}

/// The clock's digits in the chosen hour cycle. Formatters are made once per pattern.
@MainActor
enum DockClockText {
    private static var formatters: [String: DateFormatter] = [:]

    static func time(_ date: Date, _ face: DockFace) -> String {
        let template: String = switch face.clock {
        case .system: face.seconds ? "jmmss" : "jmm"
        case .twelve: face.seconds ? "hmmss" : "hmm"
        case .twentyFour: face.seconds ? "HHmmss" : "HHmm"
        }
        let formatter: DateFormatter
        if let known = formatters[template] {
            formatter = known
        } else {
            formatter = DateFormatter()
            let pattern = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: .current) ?? "HH:mm"
            // The tile is small: the day period is left off, as the old clock did.
            formatter.dateFormat = pattern.replacingOccurrences(of: "a", with: "").replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            formatters[template] = formatter
        }
        return formatter.string(from: date)
    }
}

struct DockBatteryGlyph: View {
    @ObservedObject var feed: OwnDockFeed
    let size: Double
    var face = DockFace()
    var accent = Color.white

    private var timeText: String {
        guard let battery = feed.battery else { return "—" }
        if let minutes = battery.minutesLeft { return String(format: "%d:%02d", minutes / 60, minutes % 60) }
        if battery.level >= 0.995 { return "Full" }
        return battery.charging ? "…" : "\(Int((battery.level * 100).rounded()))%"
    }

    var body: some View {
        let level = feed.battery?.level ?? 0
        let color: Color = level < 0.15 && feed.battery?.charging != true ? Color(red: 1, green: 0.36, blue: 0.32)
            : feed.battery?.charging == true ? Color(red: 0.4, green: 0.9, blue: 0.5) : .white
        DockTileFace(size: size, style: face.style, accent: accent) {
            if face.battery == .ring {
                ZStack {
                    Circle().stroke(.white.opacity(0.2), lineWidth: size * 0.07)
                    Circle().trim(from: 0, to: max(level, 0.01))
                        .stroke(color, style: StrokeStyle(lineWidth: size * 0.07, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        if feed.battery?.charging == true || feed.battery?.plugged == true {
                            Image(systemName: "bolt.fill").font(.system(size: size * 0.1, weight: .bold)).foregroundStyle(color)
                        }
                        Text(feed.battery.map { "\(Int(($0.level * 100).rounded()))" } ?? "—")
                            .font(.system(size: size * 0.16, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white)
                    }
                }
                .padding(size * 0.16)
            } else {
                bar(level: level, color: color)
            }
        }
    }

    private func bar(level: Double, color: Color) -> some View {
        VStack(spacing: size * 0.05) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                        .strokeBorder(.white.opacity(0.75), lineWidth: max(size * 0.025, 1))
                    RoundedRectangle(cornerRadius: size * 0.035, style: .continuous)
                        .fill(color)
                        .frame(width: max((size * 0.46 - size * 0.08) * level, 1))
                        .padding(size * 0.04)
                    if feed.battery?.charging == true || feed.battery?.plugged == true {
                        Image(systemName: "bolt.fill").font(.system(size: size * 0.16, weight: .bold))
                            .foregroundStyle(.white).shadow(color: .black.opacity(0.5), radius: 1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: size * 0.46, height: size * 0.24)
                .overlay(alignment: .trailing) {
                    Capsule().fill(.white.opacity(0.75)).frame(width: size * 0.03, height: size * 0.09).offset(x: size * 0.035)
                }
                Text(face.battery == .time ? timeText : feed.battery.map { "\(Int(($0.level * 100).rounded()))%" } ?? "—")
                    .font(.system(size: size * 0.15, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
    }
}

struct DockDownloadsGlyph: View {
    @ObservedObject var feed: OwnDockFeed
    let size: Double
    let accent: Color
    var face = DockFace()

    var body: some View {
        let state = feed.downloads
        DockTileFace(size: size, colors: [Color(red: 0.25, green: 0.5, blue: 0.95), Color(red: 0.12, green: 0.28, blue: 0.7)],
                     style: face.style, accent: accent) {
            ZStack {
                if state.count > 1, face.count {
                    Text("\(state.count)")
                        .font(.system(size: size * 0.12, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(size * 0.08)
                }
                if state.count > 0, face.ring {
                    Circle().stroke(.white.opacity(0.22), lineWidth: size * 0.06).padding(size * 0.14)
                    if let progress = state.progress {
                        Circle().trim(from: 0, to: max(progress, 0.02))
                            .stroke(.white, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(size * 0.14)
                    } else {
                        // No size known: a still arc that says "working", without animating.
                        Circle().trim(from: 0, to: 0.3)
                            .stroke(.white.opacity(0.8), style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(size * 0.14)
                    }
                }
                Image(systemName: "arrow.down")
                    .font(.system(size: size * (state.count > 0 ? 0.22 : 0.3), weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct DockClipboardGlyph: View {
    @ObservedObject var feed: OwnDockFeed
    let size: Double
    var face = DockFace()
    var accent = Color.white

    var body: some View {
        DockTileFace(size: size, colors: [Color(red: 0.98, green: 0.84, blue: 0.42), Color(red: 0.93, green: 0.66, blue: 0.2)],
                     style: face.style, accent: accent) {
            VStack(alignment: .leading, spacing: size * 0.02) {
                Image(systemName: "doc.on.clipboard.fill").font(.system(size: size * 0.16, weight: .semibold))
                    .foregroundStyle(Color(white: 0.2))
                Text(feed.clip ?? "Nothing copied")
                    .font(.system(size: size * 0.1, weight: .medium))
                    .foregroundStyle(Color(white: 0.15).opacity(feed.clip == nil ? 0.5 : 1))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(size * 0.1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct DockOrbitGlyph: View {
    let size: Double
    let accent: Color
    var face = DockFace()

    var body: some View {
        DockTileFace(size: size, colors: [Color(red: 0.16, green: 0.12, blue: 0.3), Color(red: 0.05, green: 0.04, blue: 0.12)],
                     style: face.style == .accent ? .dark : face.style, accent: accent) {
            ZStack {
                Circle().stroke(accent.opacity(0.5), lineWidth: max(size * 0.02, 0.8)).padding(size * 0.12)
                Circle().stroke(accent.opacity(0.3), lineWidth: max(size * 0.02, 0.8)).padding(size * 0.25)
                Circle().fill(accent).frame(width: size * 0.12, height: size * 0.12)
                ForEach(0..<5, id: \.self) { index in
                    let angle = Double(index) / 5 * 2 * .pi - .pi / 2
                    Circle().fill(.white.opacity(0.85)).frame(width: size * 0.07, height: size * 0.07)
                        .offset(x: cos(angle) * size * 0.3, y: sin(angle) * size * 0.3)
                }
            }
        }
    }
}

/// A minimised window: a small window face with its title and its app's icon in the corner.
/// No screen capture, so no picture of the content.
struct DockWindowGlyph: View {
    let title: String
    let appPath: String
    let size: Double

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                HStack(spacing: size * 0.03) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.2),
                             Color(red: 0.16, green: 0.8, blue: 0.27)], id: \.self) { color in
                        Circle().fill(color).frame(width: size * 0.06, height: size * 0.06)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, size * 0.06)
                .frame(height: size * 0.13)
                .background(Color(white: 0.86))
                Text(title)
                    .font(.system(size: size * 0.115, weight: .medium))
                    .foregroundStyle(Color(white: 0.18))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .padding(size * 0.06)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color(white: 0.97))
            }
            .clipShape(.rect(cornerRadius: size * 0.08, style: .continuous))
            .frame(width: size * 0.86, height: size * 0.7)
            .frame(width: size, height: size)
            BitmapIcon(image: DockIcons.image(appPath))
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(x: size * 0.02, y: size * 0.04)
                .shadow(color: .black.opacity(0.3), radius: size * 0.03, y: size * 0.01)
        }
    }
}

/// A smart stack: its source's symbol on a tile face.
struct DockSmartGlyph: View {
    let symbol: String
    let size: Double
    let accent: Color
    var face = DockFace()

    var body: some View {
        DockTileFace(size: size, colors: [Color(red: 0.24, green: 0.2, blue: 0.36), Color(red: 0.1, green: 0.08, blue: 0.18)],
                     style: face.style, accent: accent) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(.white.opacity(0.14)).frame(width: size * 0.42, height: size * 0.3).offset(y: -size * 0.12)
                RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                    .fill(.white.opacity(0.22)).frame(width: size * 0.5, height: size * 0.32).offset(y: -size * 0.06)
                Image(systemName: symbol)
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .foregroundStyle(face.style == .accent ? .white : accent)
                    .offset(y: size * 0.06)
            }
        }
    }
}

/// A folder or stack shown as its newest items, fanned, the way the macOS Dock draws a
/// stack. The icons were made in the background; this only places them.
struct DockFannedGlyph: View {
    let paths: [String]
    let size: Double

    var body: some View {
        ZStack {
            ForEach(Array(paths.prefix(3).enumerated().reversed()), id: \.offset) { index, path in
                Group {
                    if let image = DockHubIcons.image(path) {
                        BitmapIcon(image: image)
                    } else {
                        RoundedRectangle(cornerRadius: size * 0.12, style: .continuous).fill(.white.opacity(0.25))
                    }
                }
                .frame(width: size * 0.78, height: size * 0.78)
                .rotationEffect(.degrees(Double(index) * -7))
                .offset(x: Double(index) * -size * 0.05, y: Double(index) * -size * 0.07)
                .shadow(color: .black.opacity(0.25), radius: size * 0.03, y: size * 0.01)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Where one of the user's sections begins: a line, a dot or a gap. Its name is drawn by
/// `OwnDockSectionName`, over the section's own tiles; the mark only names an empty
/// section while arranging, since it has no tiles to sit over.
struct OwnDockSectionMark: View {
    let tile: DockTile
    let edge: OwnDockEdge
    let bar: CGRect
    let accent: Color
    let arranging: Bool
    /// The section's name is drawn over its tiles.
    var named = false

    var body: some View {
        let horizontal = edge.horizontal
        ZStack {
            switch tile.slot.sectionStyle {
            case .line, .label:
                Capsule().fill(DS.Ink.fillStrong)
                    .frame(width: horizontal ? 1 : tile.base * 0.66, height: horizontal ? tile.base * 0.66 : 1)
                    .position(tile.center)
            case .dot:
                Circle().fill(.white.opacity(0.42)).frame(width: 5, height: 5).position(tile.center)
            case .gap:
                if arranging {
                    Capsule().strokeBorder(accent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: horizontal ? 3 : tile.base * 0.6, height: horizontal ? tile.base * 0.6 : 3)
                        .position(tile.center)
                }
            }
            if arranging, !named { emptyLabel }
        }
        .opacity(tile.alpha)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var emptyLabel: some View {
        let text = OwnDockSectionName.text(tile.slot.title).opacity(0.6)
        return Group {
            switch edge {
            case .bottom: text.fixedSize().position(x: tile.center.x, y: bar.minY - 9)
            case .top: text.fixedSize().position(x: tile.center.x, y: bar.maxY + 9)
            case .left: text.frame(width: 120, alignment: .leading).position(x: bar.maxX + 66, y: tile.center.y)
            case .right: text.frame(width: 120, alignment: .trailing).position(x: bar.minX - 66, y: tile.center.y)
            }
        }
    }
}

/// Section names from this frame's tiles. Pure and O(n): it runs inside the bar's own
/// per-frame body, so a name follows the magnification with nothing else redrawn.
enum OwnDockSectionNames {
    static func place(_ scene: DockScene) -> [SectionLabelLayout.Label] {
        let panel = scene.panel, bar = scene.bar
        // How far the bar itself reaches from the screen edge: names never sit inside it.
        let floor: Double = switch scene.edge {
        case .bottom: panel.height - bar.minY
        case .top: bar.maxY
        case .left: bar.maxX
        case .right: panel.width - bar.minX
        }
        var tiles: [SectionLabelLayout.Tile] = []
        tiles.reserveCapacity(scene.tiles.count)
        for tile in scene.tiles {
            let role: SectionLabelLayout.Tile.Role = switch tile.slot.kind {
            case .section: .section
            case .divider: .divider
            default: .tile
            }
            // The far side of the drawn icon, lift and squash included.
            let half = tile.slot.empty ? 0 : tile.icon * tile.scaleCross / 2
            let reach: Double = switch scene.edge {
            case .bottom: panel.height - (tile.center.y - half)
            case .top: tile.center.y + half
            case .left: tile.center.x + half
            case .right: panel.width - (tile.center.x - half)
            }
            tiles.append(SectionLabelLayout.Tile(role: role, span: tile.span, reach: tile.dragging ? floor : max(reach, floor)))
        }
        return SectionLabelLayout.place(tiles, gap: 5)
    }
}

/// A section's name in small caps, centred over its tiles on a horizontal bar and beside
/// them on a vertical one.
struct OwnDockSectionName: View {
    let title: String
    let label: SectionLabelLayout.Label
    let edge: OwnDockEdge
    let panel: CGSize
    let unit: Double

    static func text(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.white.opacity(0.82))
            .shadow(color: .black.opacity(0.6), radius: 2)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    var body: some View {
        // A short section may borrow half a tile on each side before the name truncates.
        let room = max(label.width + unit, 44)
        let text = Self.text(title)
        Group {
            switch edge {
            case .bottom:
                text.frame(maxWidth: room).fixedSize(horizontal: false, vertical: true)
                    .position(x: label.along, y: panel.height - label.cross - 6)
            case .top:
                text.frame(maxWidth: room).fixedSize(horizontal: false, vertical: true)
                    .position(x: label.along, y: label.cross + 6)
            case .left:
                text.frame(width: 120, alignment: .leading).position(x: label.cross + 60, y: label.along)
            case .right:
                text.frame(width: 120, alignment: .trailing).position(x: panel.width - label.cross - 60, y: label.along)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A spacer made visible while arranging, with its remove button under the pointer.
struct OwnDockSpacerMark: View {
    let size: Double
    let base: Double
    let edge: OwnDockEdge
    let armed: Bool

    var body: some View {
        let along = max(size * 0.86, 6), cross = base * 0.8
        RoundedRectangle(cornerRadius: min(along, cross) * 0.28, style: .continuous)
            .strokeBorder(.white.opacity(armed ? 0.75 : 0.4), style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
            .background(RoundedRectangle(cornerRadius: min(along, cross) * 0.28, style: .continuous).fill(.white.opacity(armed ? 0.12 : 0.05)))
            .frame(width: edge.horizontal ? along : cross, height: edge.horizontal ? cross : along)
            .overlay {
                if armed { DockRemoveBadge(size: min(base, 40)).transition(.scale(scale: 0.4).combined(with: .opacity)) }
            }
            .animation(DS.Motion.touch, value: armed)
            .allowsHitTesting(false)
            .accessibilityLabel("Spacer")
    }
}

/// The badge the macOS Dock shows, drawn the way it draws it.
struct DockBadge: View {
    let text: String
    let size: Double

    var body: some View {
        let height = max(size * 0.32, 12)
        Text(text)
            .font(.system(size: height * 0.62, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, height * 0.28)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(Capsule().fill(Color(red: 1, green: 0.23, blue: 0.19)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
            .fixedSize()
    }
}
