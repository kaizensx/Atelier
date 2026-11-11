import AppKit
import DockCore
import EventKit
import SwiftUI

// MARK: - Calendar in the menu bar
//
// Today's date in the menu bar and the month a click away, in the spirit of Itsycal. The item
// is an ordinary status item; the month is an NSPopover holding a SwiftUI view, the same view
// the stage draws. Events are optional: EventKit is not touched, and no permission is asked
// for, until the owner turns Show Events on. Turning the feature off removes the status item,
// the popover and every observer, so nothing of it is left running.

enum CalendarStyle: String, CaseIterable, Identifiable {
    case dayIcon, short, long
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dayIcon: "Day Icon"
        case .short: "Short"
        case .long: "Long"
        }
    }
}

/// One event, copied out of EventKit as plain values so views never hold EKEvent objects.
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
}

@MainActor
final class MenuCalendar: NSObject, ObservableObject, NSPopoverDelegate {
    static let shared = MenuCalendar()

    @Published var enabled: Bool { didSet { store.set(enabled, forKey: "calendar.enabled"); apply() } }
    @Published var style: CalendarStyle { didSet { store.set(style.rawValue, forKey: "calendar.style"); render() } }
    @Published var weekNumbers: Bool { didSet { store.set(weekNumbers, forKey: "calendar.weekNumbers") } }
    @Published var showEvents: Bool {
        didSet {
            store.set(showEvents, forKey: "calendar.showEvents")
            if showEvents { requestEvents() } else { forgetEvents() }
        }
    }

    /// The start of today. Kept here rather than read each time, so the views redraw when the day turns.
    @Published private(set) var today: Date
    /// The first day of the month on show.
    @Published private(set) var month: Date
    /// The day whose events are listed under the month.
    @Published private(set) var selected: Date
    /// Events by the start of each day they touch, for the six weeks on show.
    @Published private(set) var events: [Date: [CalendarEvent]] = [:]
    @Published private(set) var eventStatus = EKEventStore.authorizationStatus(for: .event)

    /// Follows the owner's locale and time zone as they change, without a relaunch.
    var calendar: Calendar { Calendar.autoupdatingCurrent }

    private let store = UserDefaults.standard
    private var item: NSStatusItem?
    private var popover: NSPopover?
    private var lastClosed = Date.distantPast
    private var keyMonitor: Any?
    private var midnight: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var storeObserver: NSObjectProtocol?
    private var storage: EKEventStore?

    /// Made only when events are wanted, so a calendar without them never touches EventKit.
    private var eventStore: EKEventStore {
        if let storage { return storage }
        let made = EKEventStore()
        storage = made
        return made
    }

    private override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: "calendar.enabled")
        style = CalendarStyle(rawValue: defaults.string(forKey: "calendar.style") ?? "") ?? .dayIcon
        weekNumbers = defaults.bool(forKey: "calendar.weekNumbers")
        showEvents = defaults.bool(forKey: "calendar.showEvents")
        let start = Calendar.autoupdatingCurrent.startOfDay(for: Date())
        today = start
        selected = start
        month = MonthGrid.firstOfMonth(start, calendar: .autoupdatingCurrent)
        super.init()
    }

    func resume() { if enabled { apply() } }

    var eventsAllowed: Bool { eventStatus == .fullAccess }

    /// For tests and atelier://diag.
    var diagnostics: String {
        "calOn=\(enabled) calStyle=\(style.rawValue) calPopover=\(popover?.isShown == true ? "open" : "closed") " +
        "calEventsAccess=\(Self.name(of: eventStatus))"
    }

    private static func name(of status: EKAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .fullAccess: "fullAccess"
        case .writeOnly: "writeOnly"
        @unknown default: "unknown"
        }
    }

    // MARK: Status item

    private func apply() {
        if enabled {
            if item == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.button?.target = self
                item.button?.action = #selector(clicked)
                // Right-click and Control-click bring up a short menu instead of the month.
                item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
                item.button?.setAccessibilityLabel("Calendar")
                self.item = item
            }
            watchClock()
            refreshToday()
            if showEvents { loadEvents() }
        } else {
            closePopover()
            popover = nil
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            stopWatching()
        }
    }

    private func render() {
        guard let button = item?.button else { return }
        let now = Date()
        switch style {
        case .dayIcon:
            button.title = ""
            button.image = Self.dayIcon(calendar.component(.day, from: now))
            button.imagePosition = .imageOnly
            // A fixed width hugs the page glyph; a variable one leaves title padding around it.
            item?.length = Self.dayIconWidth
        case .short, .long:
            item?.length = NSStatusItem.variableLength
            button.image = nil
            button.imagePosition = .noImage
            button.title = MonthGrid.badgeText(now, withMonth: style == .long, locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
        }
        button.toolTip = now.formatted(date: .complete, time: .omitted)
        button.setAccessibilityValue(button.toolTip)
    }

    /// The status item's width in Day Icon style: the page glyph plus even margins, never more.
    static let dayIconWidth = 30.0

    /// A small calendar page with today's number, drawn as a template so the menu bar tints it.
    static func dayIcon(_ day: Int) -> NSImage? {
        let renderer = ImageRenderer(content: CalendarDayIcon(day: day, color: .black))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        image?.isTemplate = true
        return image
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Calendar", action: #selector(openCalendarApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Calendar Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    @objc private func openSettings() {
        NSWorkspace.shared.open(URL(string: "atelier://studio?chapter=menubar")!)
    }

    // MARK: Popover

    func togglePopover() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else if Date().timeIntervalSince(lastClosed) > 0.25 {
            // A transient popover closes on mouse-down outside it, and that includes the status
            // item itself. Without this pause the same click would close the month and open it again.
            openPopover()
        }
    }

    /// Opens the month under the status item, on today. Does nothing while the feature is off.
    func openPopover() {
        guard enabled, let button = item?.button else { return }
        refreshToday()
        goToToday()
        let popover = self.popover ?? makePopover()
        self.popover = popover
        // The popover can only take Escape and the arrow keys once Atelier is the active app.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                MainActor.assumeIsolated { MenuCalendar.shared.handleKey(event) } ? nil : event
            }
        }
    }

    func closePopover() {
        if popover?.isShown == true { popover?.performClose(nil) }
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // A popover's own material is thin enough for busy windows behind it to show through
        // the dates; a tinted layer under the month keeps every number crisp. 0.72 holds 4.5:1
        // for the dimmest text (other months' days) over a white window in light mode.
        let host = NSHostingController(rootView: MonthCalendarView(model: self)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72)))
        // The popover follows the view's size, which grows and shrinks with the event list.
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        return popover
    }

    /// Escape closes the month; the arrow keys page through months; T goes back to today.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard popover?.isShown == true else { return false }
        switch event.keyCode {
        case 53: closePopover()
        case 123: page(by: -1)
        case 124: page(by: 1)
        case 17 where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty: goToToday()
        default: return false
        }
        return true
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            lastClosed = Date()
            item?.button?.highlight(false)
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    // MARK: Navigating

    func goToToday() {
        month = MonthGrid.firstOfMonth(today, calendar: calendar)
        selected = today
        loadEvents()
    }

    func page(by months: Int) {
        month = MonthGrid.month(month, offsetBy: months, calendar: calendar)
        loadEvents()
    }

    /// Choosing a dimmed day from a neighbouring month also turns to that month.
    func select(_ day: Date) {
        selected = day
        let first = MonthGrid.firstOfMonth(day, calendar: calendar)
        if first != month {
            month = first
            loadEvents()
        }
    }

    // MARK: Keeping up with the clock

    private func watchClock() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        // The day can turn at midnight, when the clock is set, when the time zone changes or
        // while the Mac sleeps; the locale decides the weekday names and the week's first day.
        let names: [Notification.Name] = [.NSCalendarDayChanged, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
                                          NSLocale.currentLocaleDidChangeNotification]
        for name in names {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuCalendar.shared.refreshToday() }
            }))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MenuCalendar.shared.refreshToday() }
        }))
    }

    private func stopWatching() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        midnight?.invalidate()
        midnight = nil
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
    }

    /// A timer for just after midnight, as a backstop to NSCalendarDayChanged. It is set again
    /// every time the day is checked, so a changed clock or time zone moves it too.
    private func scheduleMidnight() {
        midnight?.invalidate()
        let fire = MonthGrid.nextMidnight(after: Date(), calendar: calendar).addingTimeInterval(1)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { MenuCalendar.shared.refreshToday() }
        }
        RunLoop.main.add(timer, forMode: .common)
        midnight = timer
    }

    func refreshToday() {
        guard enabled else { return }
        let start = calendar.startOfDay(for: Date())
        if start != today {
            let wasOnToday = selected == today
            today = start
            // Someone looking at another month keeps their place; otherwise the month follows the day.
            if popover?.isShown != true || wasOnToday { goToToday() }
        }
        render()
        scheduleMidnight()
        if showEvents { loadEvents() }
    }

    // MARK: Events

    /// Asks for full access the first time it is needed, then loads.
    func requestEvents() {
        eventStatus = EKEventStore.authorizationStatus(for: .event)
        guard eventStatus == .notDetermined else { loadEvents(); return }
        eventStore.requestFullAccessToEvents { _, _ in
            Task { @MainActor in
                MenuCalendar.shared.eventStatus = EKEventStore.authorizationStatus(for: .event)
                MenuCalendar.shared.loadEvents()
            }
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func forgetEvents() {
        events = [:]
        if let storeObserver { NotificationCenter.default.removeObserver(storeObserver) }
        storeObserver = nil
    }

    /// Reads the six weeks on show. Called on every page turn, so only that range is ever read.
    func loadEvents() {
        eventStatus = EKEventStore.authorizationStatus(for: .event)
        guard enabled, showEvents, eventsAllowed else {
            if !events.isEmpty { events = [:] }
            return
        }
        if storeObserver == nil {
            storeObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuCalendar.shared.loadEvents() }
            }
        }
        let calendar = self.calendar
        let weeks = MonthGrid.weeks(for: month, today: today, calendar: calendar)
        guard let first = weeks.first?.cells.first?.date, let last = weeks.last?.cells.last?.date,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else { return }
        let predicate = eventStore.predicateForEvents(withStart: first, end: end, calendars: nil)
        var found: [Date: [CalendarEvent]] = [:]
        for event in eventStore.events(matching: predicate) where event.status != .canceled {
            guard let start = event.startDate, let finish = event.endDate else { continue }
            let entry = CalendarEvent(id: (event.eventIdentifier ?? UUID().uuidString) + "\(start.timeIntervalSince1970)",
                                      title: event.title ?? "Untitled", start: start, end: finish, allDay: event.isAllDay,
                                      color: event.calendar.map { Color(cgColor: $0.cgColor) } ?? .accentColor)
            for day in MonthGrid.days(from: start, to: finish, calendar: calendar) where day >= first && day < end {
                found[day, default: []].append(entry)
            }
        }
        for day in found.keys {
            found[day]?.sort { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
        }
        if found != events { events = found }
    }
}

// MARK: - Views

/// The menu bar's calendar page: a band across the top and today's number below.
struct CalendarDayIcon: View {
    let day: Int
    var color: Color = .black

    var body: some View {
        let page = RoundedRectangle(cornerRadius: 3.4, style: .continuous)
        VStack(spacing: 0) {
            Rectangle().fill(color).frame(height: 3.6)
            Text("\(day)")
                .font(.system(size: 10, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(color)
                .frame(maxHeight: .infinity)
                .offset(y: 0.3)
        }
        .clipShape(page)
        .overlay(page.strokeBorder(color, lineWidth: 1.3))
        .frame(width: 19, height: 16)
        .padding(.horizontal, 1)
        .frame(height: 18)
    }
}

/// The month, as the popover shows it and as the stage draws it.
struct MonthCalendarView: View {
    @ObservedObject var model: MenuCalendar
    /// False on the stage, where the month is a picture and must not take clicks.
    var interactive = true
    /// Lets a hover preview show week numbers before they are turned on.
    var weekNumbers: Bool?

    private let column = 34.0
    private let weekColumn = 24.0
    private var showsWeeks: Bool { weekNumbers ?? model.weekNumbers }

    var body: some View {
        let weeks = MonthGrid.weeks(for: model.month, today: model.today, calendar: model.calendar)
        VStack(alignment: .leading, spacing: 8) {
            header
            VStack(spacing: 0) {
                weekdayRow
                ForEach(weeks) { week in row(week) }
            }
            if model.showEvents {
                Divider().padding(.vertical, 2)
                EventList(model: model, interactive: interactive)
            }
        }
        .padding(12)
        .frame(width: column * 7 + (showsWeeks ? weekColumn : 0) + 24, alignment: .leading)
        .animation(DS.Motion.arrive, value: showsWeeks)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button { model.goToToday() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.month.formatted(.dateTime.month(.wide))).font(DS.title).tracking(-0.2)
                    Text(model.month.formatted(.dateTime.year())).font(DS.title.weight(.regular)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to Today")
            .accessibilityHint("Goes back to today")
            Spacer(minLength: 4)
            HStack(spacing: 0) {
                arrow("chevron.left", "Previous Month", by: -1)
                Button { model.goToToday() } label: {
                    Circle().fill(.secondary).frame(width: 6, height: 6).frame(width: 22, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Today")
                .accessibilityLabel("Today")
                arrow("chevron.right", "Next Month", by: 1)
            }
            .padding(.horizontal, 2)
            .atelierGlass(.regular.interactive(), in: .capsule)
        }
        .padding(.leading, showsWeeks ? weekColumn + 6 : 6)
        .padding(.bottom, 2)
        .allowsHitTesting(interactive)
    }

    private func arrow(_ symbol: String, _ label: String, by months: Int) -> some View {
        Button { withAnimation(DS.Motion.touch) { model.page(by: months) } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private var weekdayRow: some View {
        HStack(spacing: 0) {
            if showsWeeks { Color.clear.frame(width: weekColumn, height: 1) }
            ForEach(Array(MonthGrid.weekdaySymbols(calendar: model.calendar).enumerated()), id: \.offset) { _, symbol in
                Text(symbol.uppercased()).font(DS.Typo.badge).tracking(0.4).foregroundStyle(.secondary)
                    .frame(width: column, height: 20)
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ week: MonthWeekRow) -> some View {
        HStack(spacing: 0) {
            if showsWeeks {
                Text("\(week.isoWeek)").font(DS.Typo.badge.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .frame(width: weekColumn, height: 34)
                    .accessibilityLabel("Week \(week.isoWeek)")
            }
            ForEach(week.cells) { cell in DayCell(model: model, cell: cell, interactive: interactive).frame(width: column, height: 34) }
        }
    }
}

private struct DayCell: View {
    @ObservedObject var model: MenuCalendar
    let cell: MonthCell
    let interactive: Bool

    var body: some View {
        let selected = cell.date == model.selected
        let found = model.events[cell.date] ?? []
        // One dot per calendar, up to three, so a busy day reads as busy without a crowd of dots.
        var colors: [Color] = []
        for event in found where !colors.contains(event.color) && colors.count < 3 { colors.append(event.color) }
        return Button { model.select(cell.date) } label: {
            VStack(spacing: 1.5) {
                Text("\(cell.day)")
                    .font(.system(size: 13, weight: cell.isToday ? .semibold : .medium)).monospacedDigit()
                    .foregroundStyle(cell.isToday ? Color.accentColor : Color.primary)
                    .frame(width: 26, height: 26)
                    .background {
                        if selected {
                            Circle().fill(cell.isToday ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.1))
                        }
                    }
                    .overlay { if cell.isToday { Circle().strokeBorder(Color.accentColor, lineWidth: 1.5) } }
                HStack(spacing: 2) {
                    ForEach(colors.indices, id: \.self) { index in
                        Circle().fill(colors[index]).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .opacity(cell.inMonth ? 1 : 0.32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(interactive)
        .accessibilityLabel(cell.date.formatted(date: .complete, time: .omitted))
        .accessibilityValue([cell.isToday ? "Today" : nil, found.isEmpty ? nil : (found.count == 1 ? "1 event" : "\(found.count) events")]
            .compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The chosen day's events, or what is needed to see them.
private struct EventList: View {
    @ObservedObject var model: MenuCalendar
    let interactive: Bool
    private let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(dayTitle).font(DS.Typo.section).foregroundStyle(.secondary)
            switch model.eventStatus {
            case .fullAccess:
                let list = model.events[model.selected] ?? []
                if list.isEmpty {
                    Text("No Events").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    ForEach(list.prefix(shown)) { event in row(event) }
                    if list.count > shown {
                        Text("\(list.count - shown) More").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            case .notDetermined:
                Button("Allow Calendar Access…") { model.requestEvents() }
                    .controlSize(.small)
                    .allowsHitTesting(interactive)
            default:
                Text("Atelier can’t read your calendars. Turn on access in System Settings.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { model.openPrivacySettings() }
                    .controlSize(.small)
                    .allowsHitTesting(interactive)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dayTitle: String {
        let calendar = model.calendar
        if calendar.isDateInToday(model.selected) { return "Today" }
        if calendar.isDateInTomorrow(model.selected) { return "Tomorrow" }
        if calendar.isDateInYesterday(model.selected) { return "Yesterday" }
        return model.selected.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func row(_ event: CalendarEvent) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Capsule().fill(event.color).frame(width: 3.5, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(DS.Typo.rowTitle).lineLimit(1)
                Text(time(event)).font(DS.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The time as it applies to the chosen day: an event running across midnight reads
    /// "Until 02:00" on its second day rather than repeating a start that is not that day.
    private func time(_ event: CalendarEvent) -> String {
        let calendar = model.calendar
        let dayStart = model.selected
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let began = event.start < dayStart, continues = event.end > dayEnd
        if event.allDay || (began && continues) { return "All Day" }
        let start = event.start.formatted(date: .omitted, time: .shortened)
        let end = event.end.formatted(date: .omitted, time: .shortened)
        if began { return "Until \(end)" }
        if continues { return "From \(start)" }
        return event.start == event.end ? start : "\(start) – \(end)"
    }
}

// MARK: - Chapter card

struct MenuCalendarCard: View {
    @ObservedObject private var model = MenuCalendar.shared

    private var week: Int { model.calendar.component(.weekOfYear, from: model.today) }

    var body: some View {
        HeroCard("Menu Bar Calendar",
                 pitch: "Today’s date in the menu bar. Click it for the month, week numbers and the day’s events.",
                 isOn: $model.enabled, hue: DS.Spectrum.surfaces,
                 readout: "W\(isoWeek)", readoutCaption: "This week",
                 preview: .overlay("calendar.menu", "Calendar in the Menu Bar", isOn: model.enabled) { size in
                     MenuCalendarPreview(size: size)
                 }) {
            MiniMonthPlate(model: model)
        } controls: {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Segments(selection: $model.style, options: CalendarStyle.allCases.map { ($0, $0.title) }, preview: { style in
                    .overlay("calendar.style." + style.rawValue, style.title, isOn: model.enabled) { size in
                        MenuCalendarPreview(size: size, style: style)
                    }
                })
                SettingRow(title: "Week Numbers", detail: "ISO week numbers beside each row of the month.", density: .compact) {
                    LuxSwitch(isOn: $model.weekNumbers, label: "Week Numbers", tint: DS.Spectrum.surfaces)
                }
                .stagePreview(.overlay("calendar.weeks", "Week Numbers", isOn: model.weekNumbers) { size in
                    MenuCalendarPreview(size: size, weekNumbers: true)
                })
                SettingRow(title: "Show Events", detail: "Dots under busy days, the day’s events below. Only read, never changed.",
                           density: .compact) {
                    LuxSwitch(isOn: $model.showEvents, label: "Show Events", tint: DS.Spectrum.surfaces)
                }
                if model.showEvents { access }
            }
        }
    }

    /// The ISO week, the same number the month shows beside today's row.
    private var isoWeek: Int {
        MonthGrid.weeks(for: model.today, today: model.today, calendar: model.calendar)
            .first { $0.cells.contains { $0.isToday } }?.isoWeek ?? week
    }

    @ViewBuilder private var access: some View {
        switch model.eventStatus {
        case .fullAccess:
            EmptyView()
        case .notDetermined:
            HStack {
                Text("Atelier needs access to your calendars to show events.").font(DS.caption).foregroundStyle(DS.Ink.tertiary)
                Spacer()
                Chip("Allow Access…") { model.requestEvents() }
            }
        default:
            HStack {
                Text("Calendar access is off. Turn it on for Atelier in System Settings, Privacy & Security, Calendars.")
                    .font(DS.caption).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Chip("Open Privacy Settings") { model.openPrivacySettings() }
            }
        }
    }
}

/// The month in miniature under a sliver of menu bar with the date in it, today ringed in the
/// family's light. A still picture: it changes only when the day does.
private struct MiniMonthPlate: View {
    @ObservedObject var model: MenuCalendar

    var body: some View {
        let weeks = MonthGrid.weeks(for: model.today, today: model.today, calendar: model.calendar)
        let symbols = MonthGrid.weekdaySymbols(calendar: model.calendar)
        let cell = 17.0
        let showsWeeks = model.weekNumbers
        HStack(alignment: .top, spacing: 12) {
            badge.padding(.top, 2)
            month(weeks: weeks, symbols: symbols, cell: cell, showsWeeks: showsWeeks)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
    }

    private func month(weeks: [MonthWeekRow], symbols: [String], cell: Double, showsWeeks: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(model.today.formatted(.dateTime.month(.wide))).font(.system(size: 11, weight: .semibold))
                Text(model.today.formatted(.dateTime.year())).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
            .padding(.leading, showsWeeks ? cell + 3 : 3)
            .padding(.bottom, 1)
            HStack(spacing: 0) {
                if showsWeeks { Color.clear.frame(width: cell, height: 10) }
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol.prefix(1)).font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                        .frame(width: cell, height: 10)
                }
            }
            ForEach(weeks) { week in
                HStack(spacing: 0) {
                    // A row is 12 points: six of them, the header and the margins fit the 148-point plate.
                    if showsWeeks {
                        Text("\(week.isoWeek)").font(.system(size: 7.5, weight: .medium)).monospacedDigit()
                            .foregroundStyle(.white.opacity(0.4)).frame(width: cell, height: 12)
                    }
                    ForEach(week.cells) { day in
                        Text("\(day.day)")
                            .font(.system(size: 9, weight: day.isToday ? .bold : .medium)).monospacedDigit()
                            .foregroundStyle(day.isToday ? Color.black : .white.opacity(day.inMonth ? 0.88 : 0.3))
                            .frame(width: cell, height: 12)
                            .background {
                                if day.isToday { Circle().fill(DS.Spectrum.surfaces).frame(width: 13, height: 13) }
                            }
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color(white: 0.13).opacity(0.95), in: .rect(cornerRadius: 9, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5) }
    }

    /// The status item as it reads in the menu bar, in the chosen style.
    @ViewBuilder private var badge: some View {
        if model.style == .dayIcon {
            CalendarDayIcon(day: model.calendar.component(.day, from: model.today), color: .white)
        } else {
            Text(MonthGrid.badgeText(model.today, withMonth: model.style == .long, locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent))
                .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 7).frame(height: 18)
                .background(.white.opacity(0.16), in: .capsule)
        }
    }
}

// MARK: - Stage preview

/// The item in the replica's menu bar, just left of the clock, with the month dropped below
/// it as an open popover would be. Both are the real views, scaled to the stage.
struct MenuCalendarPreview: View {
    @ObservedObject private var model = MenuCalendar.shared
    @ObservedObject private var skin = MenuBarSkin.shared
    let size: CGSize
    var style: CalendarStyle?
    var weekNumbers: Bool?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            content(context.date)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func content(_ now: Date) -> some View {
        // The stage draws its menu bar 1.27 times larger than a 1728-point screen would.
        let unit = size.width / 1728 * 1.27
        let fontSize = size.width * 0.0095
        let barHeight = size.width * MacStage.menuBarFraction
        let ink = skin.textIsLight ? Color.white.opacity(0.9) : Color.black.opacity(0.85)
        let shownStyle = style ?? model.style
        let text = MonthGrid.badgeText(now, withMonth: shownStyle == .long, locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent)
        let pad = 5 * unit
        let badgeWidth = (shownStyle == .dayIcon ? 21 * unit : Self.width(of: text, size: fontSize)) + pad * 2
        // The stage's row: its own padding, then the clock, then 14 points before the status items.
        let trailing = size.width * 0.012 + clockWidth(now, fontSize: fontSize) + 14 - pad
        let popoverWidth = (34 * 7 + ((weekNumbers ?? model.weekNumbers) ? 24 : 0) + 24) * unit
        // Like a real popover, the month slides left rather than run off the screen's edge.
        let room = trailing + badgeWidth / 2 - 6 * unit
        let shift = max(0, popoverWidth / 2 - room)

        return badge(shownStyle, text: text, unit: unit, fontSize: fontSize, ink: ink)
            .padding(.horizontal, pad)
            .frame(width: badgeWidth, height: barHeight * 0.82)
            .background(ink.opacity(0.2), in: .capsule)
            .overlay(alignment: .top) {
                MonthCalendarView(model: model, interactive: false, weekNumbers: weekNumbers)
                    .atelierGlass(.regular, in: .rect(cornerRadius: 16, style: .continuous))
                    .environment(\.colorScheme, Appearance.isDark ? .dark : .light)
                    .fixedSize()
                    .scaleEffect(unit, anchor: .top)
                    .offset(x: -shift, y: barHeight * 0.82 + 6 * unit)
            }
            .frame(height: barHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.trailing, trailing)
    }

    @ViewBuilder private func badge(_ style: CalendarStyle, text: String, unit: Double, fontSize: Double, ink: Color) -> some View {
        if style == .dayIcon {
            CalendarDayIcon(day: model.calendar.component(.day, from: Date()), color: ink)
                .scaleEffect(unit)
                .frame(width: 21 * unit, height: 18 * unit)
        } else {
            Text(text).font(.system(size: fontSize)).foregroundStyle(ink).fixedSize()
        }
    }

    /// The width the stage's clock takes, measured the way it is drawn.
    private func clockWidth(_ now: Date, fontSize: Double) -> Double {
        let clock = UserDefaults(suiteName: "com.apple.menuextra.clock")
        if clock?.bool(forKey: "IsAnalog") == true { return size.width * 0.0105 }
        let text = LiveStatusItems.clockText(now, seconds: clock?.bool(forKey: "ShowSeconds") == true)
        return Self.width(of: text, size: fontSize, monospaced: true)
    }

    private static func width(of text: String, size: Double, monospaced: Bool = false) -> Double {
        let font = monospaced ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
