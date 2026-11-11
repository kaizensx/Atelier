import AppKit
import EventKit
import IOKit
import IOKit.ps
import SwiftUI

private let english = Locale(identifier: "en_GB")

// MARK: - Weather

struct WeatherReport: Codable, Equatable, Sendable {
    struct Hour: Codable, Equatable, Sendable {
        let time: Date
        let temperature: Double
        let code: Int
        let day: Bool
    }

    struct Day: Codable, Equatable, Sendable {
        let date: Date
        let high: Double
        let low: Double
        let code: Int
        let sunrise: Date?
        let sunset: Date?
    }

    var fetched: Date
    var temperature: Double
    var apparent: Double?
    var code: Int
    var day: Bool
    var hours: [Hour]
    var days: [Day]
    var timeZone: String?

    var high: Double? { days.first?.high }
    var low: Double? { days.first?.low }
    var zone: TimeZone { timeZone.flatMap(TimeZone.init(identifier:)) ?? .current }

    /// The next hours from now, the first labelled Now.
    func upcoming(_ count: Int, now: Date = Date()) -> [Hour] {
        Array(hours.filter { $0.time > now.addingTimeInterval(-3600) }.prefix(count))
    }
}

/// WMO weather codes, as Open-Meteo reports them, to SF Symbols and words.
enum WeatherCode {
    static func describe(_ code: Int, day: Bool) -> (symbol: String, text: String) {
        switch code {
        case 0: (day ? "sun.max.fill" : "moon.stars.fill", "Clear")
        case 1: (day ? "sun.max.fill" : "moon.fill", "Mainly Clear")
        case 2: (day ? "cloud.sun.fill" : "cloud.moon.fill", "Partly Cloudy")
        case 3: ("cloud.fill", "Cloudy")
        case 45, 48: ("cloud.fog.fill", "Fog")
        case 51, 53, 55: ("cloud.drizzle.fill", "Drizzle")
        case 56, 57: ("cloud.sleet.fill", "Freezing Drizzle")
        case 61, 63: ("cloud.rain.fill", code == 61 ? "Light Rain" : "Rain")
        case 65: ("cloud.heavyrain.fill", "Heavy Rain")
        case 66, 67: ("cloud.sleet.fill", "Freezing Rain")
        case 71, 73: ("cloud.snow.fill", code == 71 ? "Light Snow" : "Snow")
        case 75: ("snowflake", "Heavy Snow")
        case 77: ("cloud.snow.fill", "Snow Grains")
        case 80, 81: (day ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill", "Showers")
        case 82: ("cloud.heavyrain.fill", "Heavy Showers")
        case 85, 86: ("cloud.snow.fill", "Snow Showers")
        case 95: ("cloud.bolt.fill", "Thunderstorm")
        case 96, 99: ("cloud.bolt.rain.fill", "Thunderstorm, Hail")
        default: ("cloud.fill", "—")
        }
    }
}

/// Open-Meteo: free, no key, no account. Only the city the owner picks is sent.
enum WeatherAPI {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    struct Failure: Error {}

    private struct Forecast: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double?
            let apparent_temperature: Double?
            let weather_code: Int?
            let is_day: Int?
        }
        struct Hourly: Decodable {
            let time: [Double]
            let temperature_2m: [Double?]
            let weather_code: [Int?]
            let is_day: [Int?]
        }
        struct Daily: Decodable {
            let time: [Double]
            let weather_code: [Int?]
            let temperature_2m_max: [Double?]
            let temperature_2m_min: [Double?]
            let sunrise: [Double?]?
            let sunset: [Double?]?
        }
        let timezone: String?
        let current: Current
        let hourly: Hourly
        let daily: Daily
    }

    static func forecastURL(_ place: WeatherPlace) -> URL? {
        var parts = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        parts?.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code,is_day"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "forecast_days", value: "7"),
        ]
        return parts?.url
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> WeatherReport {
        let raw = try JSONDecoder().decode(Forecast.self, from: data)
        guard let temperature = raw.current.temperature_2m else { throw Failure() }
        var hours: [WeatherReport.Hour] = []
        for (index, time) in raw.hourly.time.enumerated() {
            guard index < raw.hourly.temperature_2m.count, let value = raw.hourly.temperature_2m[index] else { continue }
            let code = index < raw.hourly.weather_code.count ? raw.hourly.weather_code[index] ?? 3 : 3
            let day = index < raw.hourly.is_day.count ? raw.hourly.is_day[index] == 1 : true
            hours.append(.init(time: Date(timeIntervalSince1970: time), temperature: value, code: code, day: day))
        }
        var days: [WeatherReport.Day] = []
        for (index, time) in raw.daily.time.enumerated() {
            guard index < raw.daily.temperature_2m_max.count, index < raw.daily.temperature_2m_min.count,
                  let high = raw.daily.temperature_2m_max[index], let low = raw.daily.temperature_2m_min[index] else { continue }
            let code = index < raw.daily.weather_code.count ? raw.daily.weather_code[index] ?? 3 : 3
            let rise = raw.daily.sunrise.flatMap { index < $0.count ? $0[index] : nil }.map(Date.init(timeIntervalSince1970:))
            let set = raw.daily.sunset.flatMap { index < $0.count ? $0[index] : nil }.map(Date.init(timeIntervalSince1970:))
            days.append(.init(date: Date(timeIntervalSince1970: time), high: high, low: low, code: code, sunrise: rise, sunset: set))
        }
        return WeatherReport(fetched: now, temperature: temperature, apparent: raw.current.apparent_temperature,
                             code: raw.current.weather_code ?? 3, day: raw.current.is_day.map { $0 == 1 } ?? true,
                             hours: hours, days: days, timeZone: raw.timezone)
    }

    static func forecast(_ place: WeatherPlace) async throws -> WeatherReport {
        guard let url = forecastURL(place) else { throw Failure() }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure() }
        return try parse(data)
    }

    private struct Search: Decodable {
        struct Result: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
            let country: String?
            let admin1: String?
        }
        let results: [Result]?
    }

    static func search(_ query: String) async throws -> [WeatherPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }
        var parts = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        parts?.queryItems = [URLQueryItem(name: "name", value: trimmed), URLQueryItem(name: "count", value: "6"),
                             URLQueryItem(name: "language", value: "en"), URLQueryItem(name: "format", value: "json")]
        guard let url = parts?.url else { return [] }
        let (data, _) = try await session.data(from: url)
        let found = try JSONDecoder().decode(Search.self, from: data).results ?? []
        return found.map { result in
            let region = [result.admin1, result.country].compactMap { $0 }.filter { !$0.isEmpty && $0 != result.name }
            return WeatherPlace(name: result.name, region: region.isEmpty ? nil : region.joined(separator: ", "),
                                latitude: result.latitude, longitude: result.longitude)
        }
    }
}

/// The last forecast for each place, kept in Caches so the widget has something to show offline.
enum WeatherCache {
    nonisolated(unsafe) static var directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Atelier/Weather", isDirectory: true)

    static func read(_ place: WeatherPlace) -> WeatherReport? {
        guard let file = directory?.appendingPathComponent(place.key + ".json"), let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WeatherReport.self, from: data)
    }

    static func write(_ report: WeatherReport, for place: WeatherPlace) {
        guard let directory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(report) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent(place.key + ".json"), options: .atomic)
    }
}

/// One forecast per place, refreshed every 30 minutes while a face shows it.
@MainActor
final class WeatherFeed: ObservableObject {
    let place: WeatherPlace
    @Published private(set) var report: WeatherReport?
    @Published private(set) var offline = false
    @Published private(set) var loading = false
    private var retry: Task<Void, Never>?

    lazy var ticker = Ticker(every: 1800) { [weak self] in self?.refresh(force: false) }

    init(place: WeatherPlace) {
        self.place = place
        report = WeatherCache.read(place)
    }

    var stale: Bool { report.map { Date().timeIntervalSince($0.fetched) > 1500 } ?? true }

    func refresh(force: Bool) {
        guard force || stale, !loading else { return }
        loading = true
        retry?.cancel()
        let place = place
        Task { [weak self] in
            guard let self else { return }
            do {
                let fresh = try await WeatherAPI.forecast(place)
                report = fresh
                offline = false
                WeatherCache.write(fresh, for: place)
            } catch {
                offline = true
                // Try again in five minutes while the face is still up, instead of waiting half an hour.
                retry = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard !Task.isCancelled, let feed = self, feed.ticker.running else { return }
                    feed.refresh(force: true)
                }
            }
            loading = false
        }
    }
}

@MainActor
enum WeatherService {
    private static var feeds: [String: WeatherFeed] = [:]
    private static var watching = false

    static func feed(for place: WeatherPlace) -> WeatherFeed {
        if !watching {
            watching = true
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                // The network takes a moment to come back after sleep.
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    MainActor.assumeIsolated { WeatherService.wake() }
                }
            }
        }
        if let feed = feeds[place.key] { return feed }
        let feed = WeatherFeed(place: place)
        feeds[place.key] = feed
        return feed
    }

    private static func wake() {
        for feed in feeds.values where feed.ticker.running { feed.refresh(force: false) }
    }
}

struct WeatherWidget: View {
    let options: WidgetOptions

    var body: some View {
        if let place = options.place {
            WeatherFace(feed: WeatherService.feed(for: place), fahrenheit: options.fahrenheit ?? (Locale.current.measurementSystem == .us))
                .id(place.key)
        } else {
            WidgetPlaceholder(symbol: "cloud.sun", text: "Choose a city in Settings, Widgets.")
        }
    }
}

struct WeatherFace: View {
    @ObservedObject var feed: WeatherFeed
    let fahrenheit: Bool
    @Environment(\.widgetTheme) private var theme

    private func degrees(_ celsius: Double) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    var body: some View {
        Group {
            if let report = feed.report {
                TimelineView(.everyMinute) { context in
                    switch theme.size {
                    case .small: small(report, now: context.date)
                    case .medium: medium(report, now: context.date)
                    case .large: large(report, now: context.date)
                    }
                }
            } else {
                WidgetPlaceholder(symbol: feed.offline ? "wifi.slash" : "cloud.sun",
                                  text: feed.offline ? "Can’t reach Open-Meteo. Trying again soon." : "Getting the forecast…")
            }
        }
        .metered(feed.ticker)
        .accessibilityElement(children: .combine)
    }

    private func symbol(_ code: Int, day: Bool, size: Double) -> some View {
        Image(systemName: WeatherCode.describe(code, day: day).symbol)
            .symbolRenderingMode(.multicolor)
            .font(.system(size: size))
            .frame(height: size * 1.1)
    }

    private func note(_ report: WeatherReport, now: Date) -> String? {
        let age = now.timeIntervalSince(report.fetched)
        guard age > 3600 || feed.offline else { return nil }
        let minutes = Int(age / 60)
        return minutes < 60 ? "Updated \(minutes) min ago" : "Updated \(minutes / 60) h ago"
    }

    private func headline(_ report: WeatherReport, now: Date, big: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(feed.place.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                if feed.offline { Image(systemName: "wifi.slash").font(.system(size: 9, weight: .bold)).foregroundStyle(theme.tertiary) }
            }
            Text(degrees(report.temperature))
                .font(.system(size: big, weight: .regular)).tracking(-big * 0.03).monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    private func range(_ report: WeatherReport) -> String {
        guard let high = report.high, let low = report.low else { return "" }
        return "H:\(degrees(high)) L:\(degrees(low))"
    }

    private func small(_ report: WeatherReport, now: Date) -> some View {
        let condition = WeatherCode.describe(report.code, day: report.day)
        return VStack(alignment: .leading, spacing: 0) {
            headline(report, now: now, big: 44)
            Spacer(minLength: 0)
            symbol(report.code, day: report.day, size: 20).padding(.bottom, 3)
            Text(condition.text).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            Text(note(report, now: now) ?? range(report)).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.secondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func top(_ report: WeatherReport, now: Date) -> some View {
        let condition = WeatherCode.describe(report.code, day: report.day)
        return HStack(alignment: .top) {
            headline(report, now: now, big: 40)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                symbol(report.code, day: report.day, size: 20)
                Text(condition.text).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(note(report, now: now) ?? range(report)).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.secondary)
            }
        }
    }

    private func hourly(_ report: WeatherReport, now: Date) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = report.zone
        let hours = report.upcoming(6, now: now)
        return HStack(spacing: 0) {
            ForEach(Array(hours.enumerated()), id: \.offset) { index, hour in
                VStack(spacing: 5) {
                    Text(index == 0 ? "Now" : String(format: "%02d", calendar.component(.hour, from: hour.time)))
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.secondary)
                    symbol(hour.code, day: hour.day, size: 15)
                    Text(degrees(index == 0 ? report.temperature : hour.temperature))
                        .font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func medium(_ report: WeatherReport, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            top(report, now: now)
            Spacer(minLength: 6)
            hourly(report, now: now)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func large(_ report: WeatherReport, now: Date) -> some View {
        let days = Array(report.days.prefix(6))
        let lowest = days.map(\.low).min() ?? 0, highest = days.map(\.high).max() ?? 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = report.zone
        return VStack(alignment: .leading, spacing: 12) {
            top(report, now: now)
            hourly(report, now: now)
            Rectangle().fill(theme.track).frame(height: 0.5)
            VStack(spacing: 7) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    HStack(spacing: 10) {
                        Text(index == 0 ? "Today" : day.date.formatted(Date.FormatStyle(locale: english, timeZone: report.zone).weekday(.abbreviated)))
                            .font(.system(size: 12.5, weight: .semibold)).frame(width: 46, alignment: .leading)
                        symbol(day.code, day: true, size: 14).frame(width: 24)
                        Text(degrees(day.low)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(theme.secondary).frame(width: 34, alignment: .trailing)
                        TemperatureRange(low: day.low, high: day.high, lowest: lowest, highest: highest,
                                         now: index == 0 ? report.temperature : nil)
                        Text(degrees(day.high)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The capsule Weather uses for a day's range against the whole week's.
private struct TemperatureRange: View {
    let low: Double
    let high: Double
    let lowest: Double
    let highest: Double
    let now: Double?
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let span = max(highest - lowest, 1), width = geometry.size.width
            let start = (low - lowest) / span * width, end = (high - lowest) / span * width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.track)
                Capsule()
                    .fill(LinearGradient(colors: [Color(red: 0.45, green: 0.8, blue: 1), Color(red: 1, green: 0.78, blue: 0.3)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(end - start, 5))
                    .offset(x: start)
                if let now {
                    Circle().fill(.white).frame(width: 6, height: 6)
                        .overlay { Circle().stroke(.black.opacity(0.25), lineWidth: 1) }
                        .offset(x: min(max((now - lowest) / span * width - 3, 0), width - 6))
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Calendar and Reminders

struct AgendaEvent: Equatable, Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
    let location: String?
}

struct AgendaReminder: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
    let due: Date?
    let dueHasTime: Bool
    let color: Color
}

/// Calendar and Reminders, read through EventKit once the owner allows it. Nothing is asked for until they press the button.
@MainActor
final class Agenda: ObservableObject {
    static let shared = Agenda()
    @Published private(set) var events: [AgendaEvent] = []
    @Published private(set) var reminders: [AgendaReminder] = []
    @Published private(set) var eventStatus = EKEventStore.authorizationStatus(for: .event)
    @Published private(set) var reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
    private var storage: EKEventStore?
    private var observer: NSObjectProtocol?

    /// Made only when first needed, so a board without these widgets never touches EventKit.
    private var store: EKEventStore {
        if let storage { return storage }
        let store = EKEventStore()
        storage = store
        return store
    }

    lazy var eventTicker: Ticker = {
        let ticker = Ticker(every: 300) { [weak self] in self?.loadEvents() }
        ticker.started = { [weak self] in self?.watch() }
        return ticker
    }()

    lazy var reminderTicker: Ticker = {
        let ticker = Ticker(every: 300) { [weak self] in self?.loadReminders() }
        ticker.started = { [weak self] in self?.watch() }
        return ticker
    }()

    var eventsAllowed: Bool { eventStatus == .fullAccess }
    var remindersAllowed: Bool { reminderStatus == .fullAccess }

    private func watch() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let agenda = Agenda.shared
                if agenda.eventTicker.running { agenda.loadEvents() }
                if agenda.reminderTicker.running { agenda.loadReminders() }
            }
        }
    }

    func requestEvents() {
        store.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                Agenda.shared.eventStatus = EKEventStore.authorizationStatus(for: .event)
                Agenda.shared.loadEvents()
            }
        }
    }

    func requestReminders() {
        store.requestFullAccessToReminders { _, _ in
            Task { @MainActor in
                Agenda.shared.reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
                Agenda.shared.loadReminders()
            }
        }
    }

    func loadEvents() {
        eventStatus = EKEventStore.authorizationStatus(for: .event)
        guard eventsAllowed else { events = []; return }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 7, to: Calendar.current.startOfDay(for: now)) ?? now.addingTimeInterval(7 * 86_400)
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .sorted { Calendar.current.startOfDay(for: $0.startDate) < Calendar.current.startOfDay(for: $1.startDate) }
            .prefix(24)
            .map { event in
                AgendaEvent(id: (event.eventIdentifier ?? UUID().uuidString) + "\(event.startDate.timeIntervalSince1970)",
                            title: event.title ?? "Untitled", start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                            color: event.calendar.map { Color(cgColor: $0.cgColor) } ?? .accentColor,
                            location: event.location?.split(separator: "\n").first.map(String.init))
            }
        let list = Array(found)
        if list != events { events = list }
    }

    func loadReminders() {
        reminderStatus = EKEventStore.authorizationStatus(for: .reminder)
        guard remindersAllowed else { reminders = []; return }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { found in
            // EventKit answers on its own queue. Copy out plain values there, then hop home.
            let calendar = Calendar.current
            let list = (found ?? []).map { reminder -> AgendaReminder in
                let parts = reminder.dueDateComponents
                let due = parts.flatMap { calendar.date(from: $0) }
                return AgendaReminder(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Untitled", due: due,
                                      dueHasTime: parts?.hour != nil,
                                      color: reminder.calendar.map { Color(cgColor: $0.cgColor) } ?? .orange)
            }
            .sorted { a, b in
                switch (a.due, b.due) {
                case let (x?, y?): x < y
                case (.some, nil): true
                case (nil, .some): false
                case (nil, nil): a.title.localizedStandardCompare(b.title) == .orderedAscending
                }
            }
            let top = Array(list.prefix(30))
            Task { @MainActor in
                if Agenda.shared.reminders != top { Agenda.shared.reminders = top }
            }
        }
    }

    /// Ticks a reminder off in Reminders itself.
    func complete(_ id: String) {
        guard remindersAllowed, let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        do {
            try store.save(reminder, commit: true)
            withAnimation(DS.Motion.arrive) { reminders.removeAll { $0.id == id } }
        } catch {
            NSSound.beep()
        }
    }
}

struct EventsWidget: View {
    @ObservedObject private var agenda = Agenda.shared
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        Group {
            if !agenda.eventsAllowed {
                WidgetPlaceholder(symbol: "calendar.badge.exclamationmark",
                                  text: agenda.eventStatus == .notDetermined ? "Allow Calendar access in Settings, Widgets." : "Calendar access is off. Turn it on in System Settings, Privacy.")
            } else {
                TimelineView(.everyMinute) { context in list(context.date) }
            }
        }
        .metered(agenda.eventTicker)
    }

    private var rows: Int {
        switch theme.size {
        case .small: 2
        case .medium: 3
        case .large: 8
        }
    }

    private func when(_ event: AgendaEvent, now: Date) -> String {
        if event.allDay { return "All day" }
        if event.start <= now { return "Now · until " + event.end.formatted(.dateTime.hour().minute().locale(english)) }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return "In \(max(minutes, 1)) min" }
        return event.start.formatted(.dateTime.hour().minute().locale(english)) + "–" + event.end.formatted(.dateTime.hour().minute().locale(english))
    }

    private func dayTitle(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return "TOMORROW" }
        return date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).locale(english)).uppercased()
    }

    private func list(_ now: Date) -> some View {
        let shown = agenda.events.filter { $0.end > now }.prefix(rows)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(now.formatted(.dateTime.weekday(.wide).locale(english)).uppercased()).widgetEyebrow(theme.accent)
                Spacer()
                Text(now.formatted(.dateTime.day().locale(english))).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            }
            if shown.isEmpty {
                Spacer(minLength: 0)
                Text("Nothing in the next 7 days.").font(.system(size: 12.5)).foregroundStyle(theme.secondary)
                Spacer(minLength: 0)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, event in
                let calendar = Calendar.current
                if theme.size == .large, index == 0 || !calendar.isDate(event.start, inSameDayAs: shown[shown.index(shown.startIndex, offsetBy: index - 1)].start) {
                    Text(dayTitle(event.start, now: now)).widgetEyebrow(theme.tertiary).padding(.top, index == 0 ? 0 : 4)
                }
                HStack(spacing: 8) {
                    Capsule().fill(event.color).frame(width: 3.5)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(event.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(theme.size != .large && !calendar.isDate(event.start, inSameDayAs: now) && !(event.start <= now)
                             ? dayTitle(event.start, now: now).capitalized + " · " + when(event, now: now) : when(event, now: now))
                            .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(theme.secondary).lineLimit(1)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct RemindersWidget: View {
    @ObservedObject private var agenda = Agenda.shared
    @State private var ticking: Set<String> = []
    @Environment(\.widgetTheme) private var theme
    @Environment(\.widgetInteractive) private var interactive

    private var rows: Int {
        switch theme.size {
        case .small: 4
        case .medium: 8
        case .large: 12
        }
    }

    var body: some View {
        Group {
            if !agenda.remindersAllowed {
                WidgetPlaceholder(symbol: "checklist",
                                  text: agenda.reminderStatus == .notDetermined ? "Allow Reminders access in Settings, Widgets." : "Reminders access is off. Turn it on in System Settings, Privacy.")
            } else {
                TimelineView(.everyMinute) { context in list(context.date) }
            }
        }
        .metered(agenda.reminderTicker)
    }

    private func due(_ reminder: AgendaReminder, now: Date) -> (String, Bool)? {
        guard let date = reminder.due else { return nil }
        let calendar = Calendar.current
        let overdue = reminder.dueHasTime ? date < now : calendar.startOfDay(for: date) < calendar.startOfDay(for: now)
        let time = reminder.dueHasTime ? " " + date.formatted(.dateTime.hour().minute().locale(english)) : ""
        if calendar.isDate(date, inSameDayAs: now) { return ("Today" + time, overdue) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) { return ("Tomorrow" + time, false) }
        return (date.formatted(.dateTime.day().month(.abbreviated).locale(english)) + time, overdue)
    }

    private func tick(_ id: String) {
        withAnimation(DS.Motion.settle) { _ = ticking.insert(id) }
        // A beat to see the tick land, the way Reminders does, then it goes.
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            agenda.complete(id)
            ticking.remove(id)
        }
    }

    private func list(_ now: Date) -> some View {
        let shown = agenda.reminders.prefix(rows)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text("Reminders").font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(agenda.reminders.count)").font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(theme.accent).contentTransition(.numericText())
            }
            if shown.isEmpty {
                Spacer(minLength: 0)
                Text("All done.").font(.system(size: 12.5)).foregroundStyle(theme.secondary)
                Spacer(minLength: 0)
            }
            ForEach(shown) { reminder in
                let done = ticking.contains(reminder.id)
                HStack(spacing: 8) {
                    Button { tick(reminder.id) } label: {
                        Image(systemName: done ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(done ? reminder.color : theme.tertiary)
                            .contentTransition(.symbolEffect(.replace))
                            .contentShape(Circle())
                    }
                    .buttonStyle(Pressable(scale: 0.85))
                    .allowsHitTesting(interactive && !done)
                    .accessibilityLabel("Complete \(reminder.title)")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(reminder.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            .foregroundStyle(done ? theme.tertiary : theme.ink)
                        if !theme.small, let due = due(reminder, now: now) {
                            Text(due.0).font(.system(size: 11)).foregroundStyle(due.1 ? Color(red: 1, green: 0.45, blue: 0.4) : theme.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Device batteries

struct DeviceBattery: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let level: Double
    var symbol: String {
        let name = name.lowercased()
        if name.contains("keyboard") { return "keyboard.fill" }
        if name.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if name.contains("mouse") { return "magicmouse.fill" }
        if name.contains("airpods") { return "airpods" }
        if name.contains("beats") || name.contains("headphone") || name.contains("buds") { return "headphones" }
        if name.contains("controller") || name.contains("gamepad") { return "gamecontroller.fill" }
        if name.contains("pencil") { return "pencil" }
        return "dot.radiowaves.left.and.right"
    }
}

/// Batteries that devices themselves report: Apple keyboards, mice and trackpads publish theirs in the I/O Registry,
/// some others as accessory power sources. AirPods keep theirs private, so they only appear if macOS lists them as a power source.
@MainActor
final class DevicesMeter: ObservableObject {
    static let shared = DevicesMeter()
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var sampled = false

    lazy var ticker = Ticker(every: 120) { [weak self] in self?.sample() }

    private func sample() {
        Task {
            let found = await Task.detached(priority: .utility) { DevicesMeter.read() }.value
            if found != devices { devices = found }
            sampled = true
        }
    }

    nonisolated static func read() -> [DeviceBattery] {
        var found: [String: DeviceBattery] = [:]
        for name in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(name), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                func value(_ key: String) -> Any? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                }
                guard let percent = (value("BatteryPercent") as? NSNumber)?.doubleValue, percent > 0, percent <= 100,
                      let product = value("Product") as? String, !product.isEmpty else { continue }
                let address = (value("DeviceAddress") as? String) ?? (value("SerialNumber") as? String) ?? product
                found[address] = DeviceBattery(id: address, name: product, level: percent / 100)
            }
        }
        // Accessory power sources: some headsets and UPS units appear here.
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      description[kIOPSTypeKey] as? String != kIOPSInternalBatteryType,
                      let name = description[kIOPSNameKey] as? String,
                      let current = description[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                if found.values.contains(where: { $0.name == name }) { continue }
                found["ps:" + name] = DeviceBattery(id: "ps:" + name, name: name, level: min(Double(current) / Double(maximum), 1))
            }
        }
        return found.values.sorted { $0.name < $1.name }
    }
}

struct DevicesWidget: View {
    @ObservedObject private var meter = DevicesMeter.shared
    @ObservedObject private var power = BatteryMeter.shared
    @Environment(\.widgetTheme) private var theme

    private var all: [(name: String, symbol: String, level: Double, charging: Bool)] {
        var list: [(String, String, Double, Bool)] = []
        if power.state.hasBattery { list.append(("This Mac", "laptopcomputer", power.state.level, power.state.charging)) }
        list += meter.devices.map { ($0.name, $0.symbol, $0.level, false) }
        return list.map { (name: $0.0, symbol: $0.1, level: $0.2, charging: $0.3) }
    }

    var body: some View {
        let list = Array(all.prefix(4))
        Group {
            if list.isEmpty {
                WidgetPlaceholder(symbol: "keyboard", text: meter.sampled ? "No connected device reports its battery." : "Looking for devices…")
            } else if theme.small {
                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow { ForEach(0..<min(2, list.count), id: \.self) { ring(list[$0], diameter: 62) } }
                    if list.count > 2 { GridRow { ForEach(2..<list.count, id: \.self) { ring(list[$0], diameter: 62) } } }
                }
                .padding(14)
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<list.count, id: \.self) { index in
                        VStack(spacing: 8) {
                            ring(list[index], diameter: 70)
                            Text(list[index].name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.secondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .metered(meter.ticker)
        .metered(power.ticker)
    }

    private func ring(_ item: (name: String, symbol: String, level: Double, charging: Bool), diameter: Double) -> some View {
        let low = item.level <= 0.2 && !item.charging
        let tint = item.charging ? Color(red: 0.42, green: 0.88, blue: 0.5) : low ? Color(red: 1, green: 0.42, blue: 0.4) : theme.accent
        return VStack(spacing: 4) {
            ZStack {
                Circle().stroke(theme.track, lineWidth: 5)
                Circle().trim(from: 0, to: item.level)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(DS.Motion.arrive, value: item.level)
                Image(systemName: item.charging ? "bolt.fill" : item.symbol)
                    .font(.system(size: diameter * 0.3, weight: .medium))
                    .foregroundStyle(item.charging ? tint : theme.ink)
            }
            .frame(width: diameter, height: diameter)
            Text(Units.percent(item.level)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(Units.percent(item.level))")
    }
}

// MARK: - Clipboard

struct ClipItem: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let date: Date
}

/// Text copied while the widget is up, held in memory only. Reads the pasteboard only when its change count moves.
@MainActor
final class ClipboardMeter: ObservableObject {
    static let shared = ClipboardMeter()
    static let limit = 8
    @Published private(set) var items: [ClipItem] = []
    @Published private(set) var copied: UUID?
    var pasteboard = NSPasteboard.general
    private var lastChange: Int?

    lazy var ticker = Ticker(every: 1) { [weak self] in self?.poll() }

    /// Password managers and system tools mark what should never be kept.
    private static let skipped: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"), .init("org.nspasteboard.AutoGeneratedType"),
        .init("com.agilebits.onepassword"),
    ]

    func poll() {
        let count = pasteboard.changeCount
        guard count != lastChange else { return }
        lastChange = count
        guard let types = pasteboard.types, Self.skipped.isDisjoint(with: types),
              let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        var list = items.filter { $0.text != text }
        list.insert(ClipItem(text: String(text.prefix(2000)), date: Date()), at: 0)
        items = Array(list.prefix(Self.limit))
    }

    func copy(_ item: ClipItem) {
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        lastChange = pasteboard.changeCount
        withAnimation(DS.Motion.settle) {
            items.removeAll { $0.id == item.id }
            let moved = ClipItem(text: item.text, date: Date())
            items.insert(moved, at: 0)
            copied = moved.id
        }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(DS.Motion.arrive) { if self.copied != nil { self.copied = nil } }
        }
    }
}

struct ClipboardWidget: View {
    @ObservedObject private var meter = ClipboardMeter.shared
    @Environment(\.widgetTheme) private var theme
    @Environment(\.widgetInteractive) private var interactive

    private var rows: Int {
        switch theme.size {
        case .small: 2
        case .medium: 3
        case .large: 8
        }
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("CLIPBOARD").widgetEyebrow(theme.tertiary)
                    Spacer()
                    if meter.copied != nil {
                        Label("Copied", systemImage: "checkmark").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(theme.accent)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                if meter.items.isEmpty {
                    Spacer(minLength: 0)
                    Text("Copy some text and it shows up here.").font(.system(size: 12)).foregroundStyle(theme.secondary)
                    Spacer(minLength: 0)
                }
                ForEach(meter.items.prefix(rows)) { item in
                    Button { meter.copy(item) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(item.text.replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 12.5, weight: .medium)).lineLimit(theme.size == .large ? 2 : 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(age(item.date, now: context.date)).font(.system(size: 10.5)).monospacedDigit().foregroundStyle(theme.tertiary)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(item.id == meter.copied ? theme.accent.opacity(0.2) : theme.track.opacity(0.6),
                                    in: .rect(cornerRadius: 9, style: .continuous))
                        .contentShape(.rect(cornerRadius: 9))
                    }
                    .buttonStyle(Pressable(scale: 0.97))
                    .allowsHitTesting(interactive)
                    .accessibilityLabel("Copy \(item.text.prefix(60))")
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .metered(meter.ticker)
    }

    private func age(_ date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }
}

// MARK: - Storage

struct VolumeInfo: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let total: Double
    let available: Double
    let root: Bool
    let removable: Bool
    var used: Double { total > 0 ? min(max(1 - available / total, 0), 1) : 0 }
}

/// Every mounted volume Finder would show. Read off the main thread: the query can take tens of milliseconds.
@MainActor
final class StorageMeter: ObservableObject {
    static let shared = StorageMeter()
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var awake: Date?
    private var observers: [NSObjectProtocol] = []

    lazy var ticker: Ticker = {
        let ticker = Ticker(every: 120) { [weak self] in self?.sample() }
        ticker.started = { [weak self] in self?.watch(true) }
        ticker.stopped = { [weak self] in self?.watch(false) }
        return ticker
    }()

    private func watch(_ on: Bool) {
        let center = NSWorkspace.shared.notificationCenter
        if on, observers.isEmpty {
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
                observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { StorageMeter.shared.sample() }
                })
            }
        } else if !on {
            observers.forEach(center.removeObserver)
            observers = []
        }
    }

    private func sample() {
        Task {
            let found = await Task.detached(priority: .utility) { StorageMeter.read() }.value
            if found != volumes { volumes = found }
            let wake = Self.wakeTime()
            if wake != awake { awake = wake }
        }
    }

    nonisolated static func read() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeIsRootFileSystemKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var seen = Set<String>()
        return urls.compactMap { url -> VolumeInfo? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsBrowsable != false,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            let root = values.volumeIsRootFileSystem == true
            // Important-usage space counts what macOS would purge for you, like Finder does. It is only there for APFS.
            let available = root ? (values.volumeAvailableCapacityForImportantUsage.map(Double.init) ?? Double(values.volumeAvailableCapacity ?? 0))
                                 : Double(values.volumeAvailableCapacity ?? 0)
            let name = values.volumeName ?? url.lastPathComponent
            guard seen.insert(name + "\(total)").inserted else { return nil }
            return VolumeInfo(id: url.path, name: name, total: Double(total), available: available, root: root,
                              removable: values.volumeIsRemovable == true || values.volumeIsEjectable == true)
        }
        .sorted { ($0.root ? 0 : 1, $0.name) < ($1.root ? 0 : 1, $1.name) }
    }

    /// When the Mac last woke from sleep, or nil if it has not slept since it started.
    nonisolated static func wakeTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.waketime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
    }
}

struct StorageWidget: View {
    @ObservedObject private var meter = StorageMeter.shared
    @Environment(\.widgetTheme) private var theme

    var body: some View {
        Group {
            if let first = meter.volumes.first {
                TimelineView(.everyMinute) { context in
                    if theme.small { small(first, now: context.date) } else { medium(now: context.date) }
                }
            } else {
                WidgetPlaceholder(symbol: "internaldrive", text: "Reading volumes…")
            }
        }
        .metered(meter.ticker)
    }

    private func small(_ volume: VolumeInfo, now: Date) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(theme.track, lineWidth: 9)
                Circle().trim(from: 0, to: volume.used)
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(DS.Motion.arrive, value: volume.used)
                VStack(spacing: 0) {
                    Text(Units.bytes(volume.available)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("free").font(.system(size: 10.5)).foregroundStyle(theme.tertiary)
                }
                .padding(.horizontal, 12)
            }
            .frame(width: 100, height: 100)
            Text(volume.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            if let booted = ActivityMeter.shared.booted {
                Text("Up " + Units.uptime(since: booted, now: now)).font(.system(size: 11)).foregroundStyle(theme.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// One volume gets the room to itself: the free space large, the bar, what is used.
    private func single(_ volume: VolumeInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: volume.root ? "internaldrive.fill" : "externaldrive.fill").font(.system(size: 11)).foregroundStyle(theme.secondary)
                Text(volume.name.uppercased()).widgetEyebrow(theme.tertiary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Units.bytes(volume.available)).font(.system(size: 30, weight: .semibold)).monospacedDigit().tracking(-0.8)
                Text("free of \(Units.bytes(volume.total))").font(.system(size: 12)).foregroundStyle(theme.secondary)
                Spacer()
                Text("\(Units.percent(volume.used)) used").font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(theme.secondary)
            }
            WidgetBar(value: volume.used, tint: volume.used > 0.9 ? Color(red: 1, green: 0.45, blue: 0.4) : theme.accent)
        }
        .accessibilityElement(children: .combine)
    }

    private func medium(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if meter.volumes.count == 1, let only = meter.volumes.first { single(only) }
            ForEach(meter.volumes.count == 1 ? [] : Array(meter.volumes.prefix(3))) { volume in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: volume.root ? "internaldrive.fill" : volume.removable ? "externaldrive.fill" : "externaldrive")
                            .font(.system(size: 11)).foregroundStyle(theme.secondary)
                        Text(volume.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        Spacer()
                        Text("\(Units.bytes(volume.available)) free of \(Units.bytes(volume.total))")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.secondary)
                    }
                    WidgetBar(value: volume.used, tint: volume.used > 0.9 ? Color(red: 1, green: 0.45, blue: 0.4) : theme.accent)
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: 0)
            HStack {
                if let booted = ActivityMeter.shared.booted { Text("Up " + Units.uptime(since: booted, now: now)) }
                Spacer()
                if let awake = meter.awake { Text("Awake since " + awake.formatted(.dateTime.hour().minute().locale(english))) }
            }
            .font(.system(size: 11)).monospacedDigit().foregroundStyle(theme.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
