import DockCore
import Foundation
import Testing

@Suite struct MonthGridTests {
    private func calendar(_ locale: String, firstWeekday: Int? = nil) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        if let firstWeekday { calendar.firstWeekday = firstWeekday }
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    @Test func sundayStartFollowsAmericanLocale() {
        let cal = calendar("en_US")
        #expect(cal.firstWeekday == 1)
        #expect(MonthGrid.weekdaySymbols(calendar: cal) == ["S", "M", "T", "W", "T", "F", "S"])
        // 1 November 2026 is a Sunday, so the month starts in the first cell.
        let weeks = MonthGrid.weeks(for: date(2026, 11, 20, in: cal), today: date(2026, 11, 9, 15, in: cal), calendar: cal)
        #expect(weeks.count == 6)
        #expect(weeks.allSatisfy { $0.cells.count == 7 })
        #expect(weeks[0].cells[0].date == date(2026, 11, 1, in: cal))
        #expect(weeks[0].cells[0].inMonth)
        #expect(weeks[5].cells[6].date == date(2026, 12, 12, in: cal))
        #expect(!weeks[5].cells[6].inMonth)
        #expect(weeks.flatMap(\.cells).filter(\.inMonth).count == 30)
    }

    @Test func mondayStartFollowsBritishLocale() {
        let cal = calendar("en_GB")
        #expect(cal.firstWeekday == 2)
        #expect(MonthGrid.weekdaySymbols(calendar: cal).first == "M")
        let weeks = MonthGrid.weeks(for: date(2026, 11, 1, in: cal), today: date(2026, 11, 9, in: cal), calendar: cal)
        // The Monday before 1 November leads, dimmed.
        #expect(weeks[0].cells[0].date == date(2026, 10, 26, in: cal))
        #expect(!weeks[0].cells[0].inMonth)
        #expect(weeks[0].cells[6].day == 1)
        #expect(weeks[0].cells.map(\.weekday) == [2, 3, 4, 5, 6, 7, 1])
    }

    @Test func saturdayStartIsHonoured() {
        let cal = calendar("en_US", firstWeekday: 7)
        #expect(MonthGrid.weekdayOrder(calendar: cal) == [7, 1, 2, 3, 4, 5, 6])
        let weeks = MonthGrid.weeks(for: date(2026, 11, 1, in: cal), today: date(2026, 11, 9, in: cal), calendar: cal)
        #expect(weeks[0].cells[0].date == date(2026, 10, 31, in: cal))
        #expect(weeks[0].cells[1].day == 1)
    }

    @Test func todayIsMarkedOnce() {
        let cal = calendar("en_US")
        let weeks = MonthGrid.weeks(for: date(2026, 11, 1, in: cal), today: date(2026, 11, 9, 23, in: cal), calendar: cal)
        let today = weeks.flatMap(\.cells).filter(\.isToday)
        #expect(today.count == 1)
        #expect(today.first?.day == 9)
        // Another month shows no today at all.
        let december = MonthGrid.weeks(for: date(2027, 2, 1, in: cal), today: date(2026, 11, 9, in: cal), calendar: cal)
        #expect(december.flatMap(\.cells).filter(\.isToday).isEmpty)
    }

    @Test func isoWeekNumbers() {
        let cal = calendar("en_GB")
        #expect(MonthGrid.isoWeek(of: date(2026, 11, 9, in: cal), timeZone: cal.timeZone) == 46)
        // 2026 starts on a Thursday, so it has a week 53, which runs into January 2027.
        let january = MonthGrid.weeks(for: date(2027, 1, 1, in: cal), today: date(2026, 11, 9, in: cal), calendar: cal)
        #expect(january[0].cells[0].date == date(2026, 12, 28, in: cal))
        #expect(january[0].isoWeek == 53)
        #expect(january[1].isoWeek == 1)
    }

    @Test func isoWeekNumbersWithSundayStart() {
        // A row from Sunday to Saturday takes the number of the ISO week holding its Thursday.
        let cal = calendar("en_US")
        let january = MonthGrid.weeks(for: date(2027, 1, 1, in: cal), today: date(2026, 11, 9, in: cal), calendar: cal)
        #expect(january[0].cells[0].date == date(2026, 12, 27, in: cal))
        #expect(january[0].isoWeek == 53)
        #expect(january[1].isoWeek == 1)
        let november = MonthGrid.weeks(for: date(2026, 11, 1, in: cal), today: date(2026, 11, 9, in: cal), calendar: cal)
        #expect(november[1].cells[0].day == 8)
        #expect(november[1].isoWeek == 46)
    }

    @Test func pagingMonthsFromTheEndOfAMonth() {
        let cal = calendar("en_US")
        #expect(MonthGrid.month(date(2027, 1, 31, 12, in: cal), offsetBy: 1, calendar: cal) == date(2027, 2, 1, in: cal))
        #expect(MonthGrid.month(date(2027, 1, 15, in: cal), offsetBy: -1, calendar: cal) == date(2026, 12, 1, in: cal))
        #expect(MonthGrid.month(date(2026, 11, 9, in: cal), offsetBy: 0, calendar: cal) == date(2026, 11, 1, in: cal))
    }

    @Test func daysAnEventTouches() {
        let cal = calendar("en_US")
        let nov9 = date(2026, 11, 9, in: cal), nov10 = date(2026, 11, 10, in: cal), nov11 = date(2026, 11, 11, in: cal)
        // A meeting within one day.
        #expect(MonthGrid.days(from: date(2026, 11, 9, 10, in: cal), to: date(2026, 11, 9, 11, in: cal), calendar: cal) == [nov9])
        // An all-day event over two days ends at midnight and does not mark the third.
        #expect(MonthGrid.days(from: nov9, to: nov11, calendar: cal) == [nov9, nov10])
        // Late evening into the next morning marks both.
        #expect(MonthGrid.days(from: date(2026, 11, 9, 22, in: cal), to: date(2026, 11, 10, 2, in: cal), calendar: cal) == [nov9, nov10])
        // No length at all still marks its day.
        #expect(MonthGrid.days(from: nov10, to: nov10, calendar: cal) == [nov10])
        #expect(MonthGrid.days(from: nov9, to: date(2027, 11, 9, in: cal), calendar: cal, limit: 10).count == 10)
    }

    @Test func menuBarText() {
        let posix = Locale(identifier: "en_US_POSIX"), utc = TimeZone(identifier: "UTC")!
        let monday = date(2026, 11, 9, 14, in: calendar("en_US"))
        #expect(MonthGrid.badgeText(monday, withMonth: false, locale: posix, timeZone: utc) == "Mon 9")
        #expect(MonthGrid.badgeText(monday, withMonth: true, locale: posix, timeZone: utc) == "Mon 9 Nov")
        #expect(MonthGrid.badgeText(monday, withMonth: true, locale: Locale(identifier: "fr_FR"), timeZone: utc).hasPrefix("lun"))
    }

    @Test func nextMidnight() {
        let cal = calendar("en_US")
        #expect(MonthGrid.nextMidnight(after: date(2026, 11, 9, 23, in: cal), calendar: cal) == date(2026, 11, 10, in: cal))
        #expect(MonthGrid.nextMidnight(after: date(2026, 12, 31, 0, in: cal), calendar: cal) == date(2027, 1, 1, in: cal))
    }
}
