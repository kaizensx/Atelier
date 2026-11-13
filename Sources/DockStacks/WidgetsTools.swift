import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

private let english = Locale(identifier: "en_GB")

/// A row control on a face. It only takes clicks where clicks reach the widget, and looks the same either way.
private struct FaceButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder var label: Label
    @Environment(\.widgetInteractive) private var interactive

    var body: some View {
        Button(action: action) { label.contentShape(Rectangle()) }
            .buttonStyle(Pressable(scale: 0.96))
            .allowsHitTesting(interactive)
    }
}

/// A round control on a face, for timers.
private struct RoundControl: View {
    let symbol: String
    let label: String
    var prominent = false
    let action: () -> Void
    @Environment(\.widgetTheme) private var theme
    @Environment(\.widgetInteractive) private var interactive

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(prominent ? theme.onAccent : theme.ink)
                .frame(width: 38, height: 38)
                .background(prominent ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.track), in: .circle)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .buttonStyle(Pressable(scale: 0.9))
        .allowsHitTesting(interactive)
        .accessibilityLabel(label)
    }
}

// MARK: - Checklist

struct ChecklistWidget: View {
    @ObservedObject var board: WidgetBoard
    let uid: String
    let options: WidgetOptions
    @Environment(\.widgetTheme) private var theme

    private var rows: Int {
        switch theme.size {
        case .small: 4
        case .medium: 9
        case .large: 13
        }
    }

    private func toggle(_ id: String) {
        withAnimation(DS.Motion.settle) {
            board.update(uid) { placement in
                guard let index = placement.options.items?.firstIndex(where: { $0.id == id }) else { return }
                placement.options.items?[index].done.toggle()
            }
        }
    }

    var body: some View {
        let items = options.items ?? []
        let done = items.filter(\.done).count
        let title = options.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Checklist"
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: theme.small ? 15 : 17, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 6)
                if !items.isEmpty {
                    Text("\(done)/\(items.count)").font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(done == items.count ? theme.accent : theme.tertiary)
                        .contentTransition(.numericText())
                }
            }
            .padding(.bottom, 2)
            if items.isEmpty {
                Text("Add items in Settings, Widgets.").font(.system(size: 12)).foregroundStyle(theme.tertiary)
            }
            ForEach(items.prefix(items.count > rows ? rows - 1 : rows)) { item in
                FaceButton(action: { toggle(item.id) }) {
                    HStack(spacing: 8) {
                        Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(item.done ? theme.accent : theme.tertiary)
                            .contentTransition(.symbolEffect(.replace))
                        Text(item.text)
                            .font(.system(size: 13, weight: .medium))
                            .strikethrough(item.done, color: theme.tertiary)
                            .foregroundStyle(item.done ? theme.tertiary : theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 19)
                }
                .accessibilityLabel(item.text)
                .accessibilityValue(item.done ? "Done" : "Not done")
            }
            if items.count > rows {
                Text("\(items.count - rows + 1) more").font(.system(size: 11.5)).foregroundStyle(theme.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Habits

enum HabitDay {
    static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Days in a row ending today, or ending yesterday while today is still open.
    static func streak(_ marks: [String], today: Date, calendar: Calendar = .current) -> Int {
        let set = Set(marks)
        var day = calendar.startOfDay(for: today)
        if !set.contains(key(day, calendar: calendar)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }
        var count = 0
        while set.contains(key(day, calendar: calendar)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

struct HabitsWidget: View {
    @ObservedObject var board: WidgetBoard
    let uid: String
    let options: WidgetOptions
    @Environment(\.widgetTheme) private var theme

    private func toggle(_ id: String, today: Date) {
        let key = HabitDay.key(today)
        withAnimation(DS.Motion.settle) {
            board.update(uid) { placement in
                guard let index = placement.options.habits?.firstIndex(where: { $0.id == id }) else { return }
                var marks = placement.options.habits?[index].marks ?? []
                if marks.contains(key) { marks.removeAll { $0 == key } } else { marks.append(key) }
                // Only the last year matters to a streak worth showing.
                placement.options.habits?[index].marks = Array(marks.sorted().suffix(400))
            }
        }
    }

    var body: some View {
        let habits = options.habits ?? []
        TimelineView(.everyMinute) { context in
            if habits.isEmpty {
                WidgetPlaceholder(symbol: "flame", text: "Add habits in Settings, Widgets.")
            } else {
                VStack(alignment: .leading, spacing: theme.small ? 9 : 10) {
                    ForEach(habits.prefix(3)) { habit in row(habit, today: context.date) }
                    Spacer(minLength: 0)
                }
                .padding(theme.small ? 14 : 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func row(_ habit: Habit, today: Date) -> some View {
        let calendar = Calendar.current
        let marked = Set(habit.marks)
        let done = marked.contains(HabitDay.key(today))
        let streak = HabitDay.streak(habit.marks, today: today)
        return HStack(spacing: 10) {
            FaceButton(action: { toggle(habit.id, today: today) }) {
                Image(systemName: done ? "checkmark" : habit.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(done ? theme.onAccent : theme.accent)
                    .frame(width: 34, height: 34)
                    .background(done ? AnyShapeStyle(theme.accent) : AnyShapeStyle(theme.accent.opacity(0.16)), in: .circle)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(habit.name)
            .accessibilityValue(done ? "Done today" : "Not done today")
            VStack(alignment: .leading, spacing: 1) {
                Text(habit.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(streak == 0 ? "No streak yet" : streak == 1 ? "1 day" : "\(streak) days")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(streak > 0 ? theme.secondary : theme.tertiary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 4)
            if !theme.small {
                HStack(spacing: 5) {
                    ForEach((0..<7).reversed(), id: \.self) { back in
                        let day = calendar.date(byAdding: .day, value: -back, to: today) ?? today
                        let on = marked.contains(HabitDay.key(day))
                        VStack(spacing: 3) {
                            Circle().fill(on ? theme.accent : theme.track).frame(width: 12, height: 12)
                            Text(day.formatted(.dateTime.weekday(.narrow).locale(english)))
                                .font(.system(size: 9, weight: back == 0 ? .bold : .medium))
                                .foregroundStyle(back == 0 ? theme.secondary : theme.tertiary)
                        }
                    }
                }
                .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Launcher

@MainActor
enum LaunchIcons {
    private static var cache: [String: NSImage] = [:]

    /// The icon chosen for it in Atelier first (any kind, links too), then the file's own.
    static func icon(for link: LaunchLink) -> NSImage? {
        if let custom = AtelierIcons.shared.custom(link.target) { return custom }
        guard link.kind != .url else { return nil }
        if let hit = cache[link.target] { return hit }
        guard FileManager.default.fileExists(atPath: link.target) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: link.target)
        cache[link.target] = image
        return image
    }

    static func open(_ link: LaunchLink) {
        switch link.kind {
        case .app:
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: link.target), configuration: NSWorkspace.OpenConfiguration())
        case .folder:
            NSWorkspace.shared.open(URL(fileURLWithPath: link.target))
        case .url:
            if let url = LaunchLink.url(from: link.target) { NSWorkspace.shared.open(url) }
        }
    }
}

extension LaunchLink {
    /// What the owner typed, with https added when there is no scheme.
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty, url.host != nil || scheme == "mailto" { return url }
        return URL(string: "https://" + trimmed).flatMap { $0.host?.contains(".") == true ? $0 : nil }
    }
}

struct LauncherWidget: View {
    let options: WidgetOptions
    @Environment(\.widgetTheme) private var theme

    private var layout: (columns: Int, rows: Int, icon: Double, labels: Bool) {
        switch theme.size {
        case .small: (2, 2, 54, false)
        case .medium: (4, 2, 50, true)
        case .large: (4, 4, 56, true)
        }
    }

    var body: some View {
        let links = options.links ?? []
        if links.isEmpty {
            WidgetPlaceholder(symbol: "square.grid.2x2", text: "Add apps, folders or links in Settings, Widgets.")
        } else {
            let layout = layout
            Grid(horizontalSpacing: 6, verticalSpacing: layout.labels ? 8 : 10) {
                ForEach(0..<layout.rows, id: \.self) { row in
                    GridRow {
                        ForEach(0..<layout.columns, id: \.self) { column in
                            let index = row * layout.columns + column
                            if index < links.count {
                                LaunchCell(link: links[index], icon: layout.icon, label: layout.labels)
                            } else {
                                Color.clear.frame(width: layout.icon, height: layout.icon)
                            }
                        }
                    }
                }
            }
            .padding(theme.small ? 14 : 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct LaunchCell: View {
    let link: LaunchLink
    let icon: Double
    let label: Bool
    @State private var hovering = false
    /// Redraws the cell when its icon is changed in the Launcher's editor.
    @ObservedObject private var icons = AtelierIcons.shared
    @Environment(\.widgetTheme) private var theme
    @Environment(\.widgetInteractive) private var interactive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { LaunchIcons.open(link) } label: {
            VStack(spacing: 5) {
                Group {
                    if let image = LaunchIcons.icon(for: link) {
                        Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    } else {
                        Image(systemName: link.kind == .url ? "globe" : "questionmark.app.dashed")
                            .font(.system(size: icon * 0.42, weight: .medium))
                            .foregroundStyle(theme.onAccent)
                            .frame(width: icon * 0.84, height: icon * 0.84)
                            .background(LinearGradient(colors: [theme.accent, theme.accent.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                                        in: .rect(cornerRadius: icon * 0.22, style: .continuous))
                    }
                }
                .frame(width: icon, height: icon)
                .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
                .shadow(color: .black.opacity(hovering ? 0.25 : 0), radius: 6, y: 3)
                if label {
                    Text(link.name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.secondary)
                        .lineLimit(1).frame(maxWidth: icon + 22)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable(scale: 0.92))
        .allowsHitTesting(interactive)
        .onHover { inside in withAnimation(DS.Motion.touch) { hovering = inside && interactive } }
        .accessibilityLabel("Open \(link.name)")
    }
}

// MARK: - Stopwatch and timer

/// The running clock behind one stopwatch widget. Kept outside the view, so it survives the widget moving windows.
@MainActor
final class ChronoModel: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var started: Date?
    @Published private(set) var banked: TimeInterval = 0
    @Published private(set) var laps: [TimeInterval] = []
    /// The timer has run out and is waiting to be reset.
    @Published private(set) var rang = false
    private var alarm: Timer?

    func elapsed(at now: Date) -> TimeInterval { banked + (started.map { now.timeIntervalSince($0) } ?? 0) }

    func toggle(timer length: TimeInterval?) {
        if running {
            banked = elapsed(at: Date())
            started = nil
            running = false
            alarm?.invalidate()
            alarm = nil
            return
        }
        if let length, banked >= length { reset() }
        started = Date()
        running = true
        rang = false
        if let length {
            // One timer for the moment it runs out. Nothing ticks in between but the digits on screen.
            let fire = Timer(timeInterval: max(length - banked, 0), repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.ring(length) }
            }
            RunLoop.main.add(fire, forMode: .common)
            alarm = fire
        }
    }

    private func ring(_ length: TimeInterval) {
        banked = length
        started = nil
        running = false
        rang = true
        alarm = nil
        SoundPackRuntime.timerDone()
    }

    func lap() {
        guard running else { return }
        laps.insert(elapsed(at: Date()), at: 0)
        laps = Array(laps.prefix(20))
    }

    func reset() {
        alarm?.invalidate()
        alarm = nil
        started = nil
        running = false
        banked = 0
        laps = []
        rang = false
    }
}

@MainActor
enum Chrono {
    private static var models: [String: ChronoModel] = [:]
    static func model(_ uid: String) -> ChronoModel {
        if let model = models[uid] { return model }
        let model = ChronoModel()
        models[uid] = model
        return model
    }

    static func text(_ seconds: TimeInterval, tenths: Bool) -> String {
        let total = max(seconds, 0)
        let whole = Int(tenths ? total.rounded(.down) : total.rounded(.up))
        let h = whole / 3600, m = whole % 3600 / 60, s = whole % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if tenths { return String(format: "%02d:%02d.%d", m, s, Int((total * 10).rounded(.down)) % 10) }
        return String(format: "%02d:%02d", m, s)
    }
}

struct ChronoWidget: View {
    @ObservedObject var model: ChronoModel
    let options: WidgetOptions
    @Environment(\.widgetTheme) private var theme
    @Environment(\.widgetInteractive) private var interactive

    private var timerLength: TimeInterval? { options.timer == true ? max(options.minutes ?? 5, 0.5) * 60 : nil }

    var body: some View {
        // Ten frames a second while running, and nothing at all while stopped.
        Group {
            if model.running {
                TimelineView(.periodic(from: .now, by: 0.1)) { context in face(model.elapsed(at: context.date)) }
            } else {
                face(model.elapsed(at: Date()))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func face(_ elapsed: TimeInterval) -> some View {
        if theme.small { small(elapsed) } else { medium(elapsed) }
    }

    private func reading(_ elapsed: TimeInterval) -> (text: String, progress: Double?) {
        if let length = timerLength {
            let left = max(length - elapsed, 0)
            return (Chrono.text(left, tenths: false), left / length)
        }
        return (Chrono.text(elapsed, tenths: true), nil)
    }

    private var status: String {
        if model.rang { return "Time’s up" }
        if model.running { return timerLength == nil ? "Running" : "Counting down" }
        return model.banked > 0 ? "Paused" : (timerLength == nil ? "Stopwatch" : "Timer · \(Int((timerLength ?? 0) / 60)) min")
    }

    private var controls: some View {
        HStack(spacing: 10) {
            RoundControl(symbol: timerLength == nil && model.running ? "flag.fill" : "arrow.counterclockwise",
                         label: timerLength == nil && model.running ? "Lap" : "Reset") {
                if timerLength == nil && model.running { model.lap() } else { model.reset() }
            }
            .opacity(model.running || model.banked > 0 ? 1 : 0.45)
            RoundControl(symbol: model.running ? "pause.fill" : "play.fill", label: model.running ? "Pause" : "Start", prominent: true) {
                model.toggle(timer: timerLength)
            }
        }
    }

    private func dial(_ elapsed: TimeInterval, diameter: Double, size: Double) -> some View {
        let value = reading(elapsed)
        return ZStack {
            if let progress = value.progress {
                Circle().stroke(theme.track, lineWidth: 6)
                Circle().trim(from: 0, to: progress)
                    .stroke(model.rang ? Color(red: 1, green: 0.45, blue: 0.4) : theme.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.1), value: progress)
            }
            Text(value.text)
                .font(.system(size: size, weight: .semibold)).monospacedDigit().tracking(-0.5)
                .lineLimit(1).minimumScaleFactor(0.6)
                .padding(.horizontal, value.progress == nil ? 0 : 12)
        }
        .frame(width: value.progress == nil ? nil : diameter, height: value.progress == nil ? nil : diameter)
    }

    private func small(_ elapsed: TimeInterval) -> some View {
        VStack(spacing: 8) {
            if timerLength == nil {
                Text(status.uppercased()).widgetEyebrow(model.running ? theme.accent : theme.tertiary)
                Spacer(minLength: 0)
                dial(elapsed, diameter: 0, size: 32)
                Spacer(minLength: 0)
            } else {
                dial(elapsed, diameter: interactive ? 104 : 124, size: 24)
                if !interactive { Text(status).font(.system(size: 11.5)).foregroundStyle(theme.secondary) }
            }
            if interactive { controls }
        }
        .padding(14)
    }

    @ViewBuilder private func medium(_ elapsed: TimeInterval) -> some View {
        if let length = timerLength {
            // The dial on the left, what it is and its controls beside it.
            HStack(spacing: 20) {
                dial(elapsed, diameter: 150, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.uppercased()).widgetEyebrow(model.rang ? Color(red: 1, green: 0.45, blue: 0.4) : model.running ? theme.accent : theme.tertiary)
                    Text("\(Int(length / 60)) minute timer").font(.system(size: 13, weight: .semibold))
                    if model.running {
                        Text("Ends " + Date().addingTimeInterval(max(length - elapsed, 0)).formatted(.dateTime.hour().minute().locale(english)))
                            .font(.system(size: 11.5)).foregroundStyle(theme.secondary)
                    }
                    Spacer(minLength: 0)
                    if interactive { controls }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(18)
        } else {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.uppercased()).widgetEyebrow(model.running ? theme.accent : theme.tertiary)
                    Spacer(minLength: 0)
                    dial(elapsed, diameter: 0, size: 40)
                    Spacer(minLength: 0)
                    if interactive { controls }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAPS").widgetEyebrow(theme.tertiary)
                    if model.laps.isEmpty {
                        Text(interactive ? "Press the flag while running." : "None yet").font(.system(size: 11.5)).foregroundStyle(theme.tertiary)
                    }
                    ForEach(Array(model.laps.prefix(5).enumerated()), id: \.offset) { index, lap in
                        HStack {
                            Text("Lap \(model.laps.count - index)").foregroundStyle(theme.tertiary)
                            Spacer()
                            Text(Chrono.text(lap, tenths: true)).monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 140)
            }
            .padding(16)
        }
    }
}

// MARK: - Slideshow

struct SlideshowWidget: View {
    let options: WidgetOptions
    let pixels: Double
    @State private var image: NSImage?
    @State private var index = 0
    @State private var empty = false

    private struct Run: Equatable {
        let folder: String?
        let minutes: Double
        let pixels: Int
    }

    final class Decoded: @unchecked Sendable {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    var body: some View {
        ZStack {
            if let image {
                Color.clear
                    .overlay { Image(nsImage: image).resizable().interpolation(.high).scaledToFill() }
                    .clipped()
                    .id(index)
                    .transition(.opacity)
            } else {
                WidgetPlaceholder(symbol: "photo.stack",
                                  text: options.folder == nil ? "Choose a folder in Settings, Widgets." : empty ? "No pictures in this folder." : "Loading…")
                    .background(Color.black.opacity(0.28))
            }
        }
        .task(id: Run(folder: options.folder, minutes: max(options.minutes ?? 5, 0.25), pixels: Int(pixels))) {
            await play(folder: options.folder, minutes: max(options.minutes ?? 5, 0.25))
        }
        .accessibilityLabel("Slideshow")
    }

    private func play(folder: String?, minutes: Double) async {
        guard let folder else { image = nil; return }
        let files = await Task.detached(priority: .utility) { Self.scan(folder) }.value
        empty = files.isEmpty
        guard !files.isEmpty else { image = nil; return }
        let interval = minutes * 60
        // The position follows the clock, so every slideshow on this folder agrees, even after a relaunch.
        var position = Int(Date().timeIntervalSince1970 / interval)
        let side = Int(pixels)
        while !Task.isCancelled {
            let url = files[position % files.count]
            // Decoded off the main thread, so a crossfade never waits on a big JPEG.
            if let decoded = await Task.detached(priority: .utility, operation: { Self.decode(url, side: side) }).value {
                let next = NSImage(cgImage: decoded.image, size: NSSize(width: decoded.image.width, height: decoded.image.height))
                withAnimation(image == nil ? nil : .easeInOut(duration: 1.2)) {
                    image = next
                    index = position
                }
            }
            let wait = interval - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: interval)
            try? await Task.sleep(for: .seconds(max(wait, 1)))
            position += 1
        }
    }

    nonisolated static func scan(_ folder: String) -> [URL] {
        let base = URL(fileURLWithPath: folder, isDirectory: true)
        let keys: [URLResourceKey] = [.contentTypeKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return entries.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return false }
            return values.contentType?.conforms(to: .image) == true
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        .prefix(2000).map { $0 }
    }

    nonisolated static func decode(_ url: URL, side: Int) -> Decoded? {
        guard let input = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(side, 64),
        ]
        return CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary).map(Decoded.init)
    }
}

// MARK: - Smart Stack

struct StackWidget: View {
    @ObservedObject var board: WidgetBoard
    let placement: WidgetPlacement
    let size: CGSize
    @State private var page: String?
    @State private var hovering = false
    /// Redraws the cell when its icon is changed in the Launcher's editor.
    @ObservedObject private var icons = AtelierIcons.shared
    @Environment(\.widgetTheme) private var theme
    @Environment(\.widgetInteractive) private var interactive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var items: [WidgetPlacement] { placement.options.stack ?? [] }
    private var current: String? { page ?? items.first?.uid }

    var body: some View {
        let items = items
        Group {
            if items.isEmpty {
                WidgetPlaceholder(symbol: "square.stack", text: "Add widgets to this stack in Settings, Widgets.")
            } else if interactive {
                // Clicks reach the stack: scroll or swipe through it, page by page, like a Smart Stack.
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { inner in
                            page(inner).id(inner.uid)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollIndicators(.never)
                .scrollPosition(id: $page)
            } else if let shown = items.first(where: { $0.uid == current }) ?? items.first {
                page(shown)
                    .id(shown.uid)
                    .transition(reduceMotion ? .opacity : .push(from: .bottom))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay(alignment: .trailing) {
            if items.count > 1 { dots(items) }
        }
        .onHover { hovering = $0 }
        .task(id: placement.options.rotate == true && items.count > 1) {
            guard placement.options.rotate == true else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled, !hovering else { continue }
                let list = self.items
                guard list.count > 1 else { continue }
                let index = list.firstIndex { $0.uid == current } ?? 0
                withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.6)) { page = list[(index + 1) % list.count].uid }
            }
        }
    }

    private func page(_ inner: WidgetPlacement) -> some View {
        WidgetContent(kind: inner.kind, placement: inner, board: board, size: size)
            .frame(width: size.width, height: size.height)
    }

    private func dots(_ items: [WidgetPlacement]) -> some View {
        VStack(spacing: 4) {
            ForEach(items) { inner in
                Capsule()
                    .fill(inner.uid == current ? theme.ink.opacity(0.8) : theme.ink.opacity(0.25))
                    .frame(width: 4, height: inner.uid == current ? 12 : 4)
            }
        }
        .animation(DS.Motion.settle, value: current)
        .padding(.trailing, 6)
        .accessibilityHidden(true)
    }
}
