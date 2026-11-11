import Foundation

// MARK: - Month grid
//
// The arithmetic behind the menu bar calendar, kept apart from AppKit so it can be tested.
// Everything takes a Calendar, never Calendar.current, because the grid must follow the
// owner's locale (which day starts the week) and time zone, and tests need fixed ones.

/// One day in the grid.
public struct MonthCell: Equatable, Sendable, Identifiable {
    /// The start of the day in the grid's calendar.
    public let date: Date
    /// The day of the month, as printed in the cell.
    public let day: Int
    /// False for the days of the previous and next month that fill out the first and last rows.
    public let inMonth: Bool
    public let isToday: Bool
    /// 1 is Sunday, as Calendar counts weekdays.
    public let weekday: Int
    public var id: Date { date }
}

/// One row of seven days, in the locale's order.
public struct MonthWeekRow: Equatable, Sendable, Identifiable {
    /// The ISO 8601 week the row belongs to.
    public let isoWeek: Int
    public let cells: [MonthCell]
    public var id: Date { cells[0].date }
}

public enum MonthGrid {
    /// Always six rows, so the popover keeps one height from month to month and does not jump
    /// under the pointer while paging with the arrows.
    public static let rows = 6

    /// The first day of the month that contains `date`.
    public static func firstOfMonth(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The first day of the month `months` away from the one containing `date`. Working from the
    /// first of the month means 31 January plus one month is February, not 3 March.
    public static func month(_ date: Date, offsetBy months: Int, calendar: Calendar) -> Date {
        let first = firstOfMonth(date, calendar: calendar)
        guard let moved = calendar.date(byAdding: .month, value: months, to: first) else { return first }
        return firstOfMonth(moved, calendar: calendar)
    }

    /// Weekday numbers (1 is Sunday) in the order the locale lays out a week.
    public static func weekdayOrder(calendar: Calendar) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    /// The column headings, one or two letters each, in the locale's order and language.
    public static func weekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return weekdayOrder(calendar: calendar).map { symbols[$0 - 1] }
    }

    /// The six rows that show the month containing `month`, padded with the neighbouring months' days.
    public static func weeks(for month: Date, today: Date, calendar: Calendar) -> [MonthWeekRow] {
        let first = firstOfMonth(month, calendar: calendar)
        let lead = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        let start = calendar.date(byAdding: .day, value: -lead, to: first) ?? first
        let shownMonth = calendar.component(.month, from: first)
        let todayStart = calendar.startOfDay(for: today)
        return (0..<rows).map { row in
            let cells = (0..<7).map { column -> MonthCell in
                let moment = calendar.date(byAdding: .day, value: row * 7 + column, to: start) ?? start
                let day = calendar.startOfDay(for: moment)
                return MonthCell(date: day, day: calendar.component(.day, from: day),
                                 inMonth: calendar.component(.month, from: day) == shownMonth,
                                 isToday: day == todayStart, weekday: calendar.component(.weekday, from: day))
            }
            // Every row holds exactly one Thursday, and ISO 8601 numbers a week by its Thursday,
            // so this gives the right number whichever day the locale starts its week on.
            let thursday = cells.first { $0.weekday == 5 } ?? cells[3]
            return MonthWeekRow(isoWeek: isoWeek(of: thursday.date, timeZone: calendar.timeZone), cells: cells)
        }
    }

    /// The ISO 8601 week number: weeks start on Monday and week 1 holds the year's first Thursday.
    public static func isoWeek(of date: Date, timeZone: TimeZone) -> Int {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = timeZone
        return iso.component(.weekOfYear, from: date)
    }

    /// The days an event touches, as starts of days. An event that ends exactly at midnight does
    /// not spill into the next day, which is how EventKit's all-day events end. An event with no
    /// length still marks the day it happens on.
    public static func days(from start: Date, to end: Date, calendar: Calendar, limit: Int = 62) -> [Date] {
        var day = calendar.startOfDay(for: start)
        var result = [day]
        while result.count < limit, let next = calendar.date(byAdding: .day, value: 1, to: day), next < end {
            day = calendar.startOfDay(for: next)
            result.append(day)
        }
        return result
    }

    /// What the menu bar shows in text: "Mon 9", or "Mon 9 Nov" with the month. The day and
    /// month names come from the locale; the order follows the menu bar clock's own date.
    public static func badgeText(_ date: Date, withMonth: Bool, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = withMonth ? "EEE d MMM" : "EEE d"
        return formatter.string(from: date)
    }

    /// The next midnight after `date`, when the menu bar has to show a new day.
    public static func nextMidnight(after date: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
    }
}
