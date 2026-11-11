import Testing
@testable import DockCore

@Test func darkHoursRunThroughMidnight() {
    let dark = 19 * 60, light = 7 * 60 + 30
    #expect(AppearanceHours.wantsDark(minute: 19 * 60, darkAt: dark, lightAt: light))
    #expect(AppearanceHours.wantsDark(minute: 23 * 60 + 59, darkAt: dark, lightAt: light))
    #expect(AppearanceHours.wantsDark(minute: 0, darkAt: dark, lightAt: light))
    #expect(AppearanceHours.wantsDark(minute: 7 * 60 + 29, darkAt: dark, lightAt: light))
    #expect(!AppearanceHours.wantsDark(minute: 7 * 60 + 30, darkAt: dark, lightAt: light))
    #expect(!AppearanceHours.wantsDark(minute: 12 * 60, darkAt: dark, lightAt: light))
    #expect(!AppearanceHours.wantsDark(minute: 18 * 60 + 59, darkAt: dark, lightAt: light))
}

@Test func darkHoursWithinOneDay() {
    #expect(AppearanceHours.wantsDark(minute: 3 * 60, darkAt: 60, lightAt: 6 * 60))
    #expect(!AppearanceHours.wantsDark(minute: 7 * 60, darkAt: 60, lightAt: 6 * 60))
    #expect(!AppearanceHours.wantsDark(minute: 0, darkAt: 60, lightAt: 6 * 60))
}

@Test func sameHourForBothNeverForcesDark() {
    #expect(!AppearanceHours.wantsDark(minute: 600, darkAt: 600, lightAt: 600))
}
