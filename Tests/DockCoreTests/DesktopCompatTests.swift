import Foundation
import Testing
@testable import DockCore

// MARK: Dock edge

@Test func dockEdgeReadsTheInsetThatHoldsTheDock() {
    let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    #expect(DesktopCompat.dockEdge(frame: frame, visible: CGRect(x: 0, y: 70, width: 1512, height: 875)) == .bottom)
    #expect(DesktopCompat.dockEdge(frame: frame, visible: CGRect(x: 64, y: 0, width: 1448, height: 945)) == .left)
    #expect(DesktopCompat.dockEdge(frame: frame, visible: CGRect(x: 0, y: 0, width: 1448, height: 945)) == .right)
    // Auto-hide leaves a few points at the edge; the menu bar insets only the top.
    #expect(DesktopCompat.dockEdge(frame: frame, visible: CGRect(x: 0, y: 4, width: 1512, height: 941)) == .hidden)
}

@Test func dockEdgeWorksOnASecondDisplayWithItsOwnOrigin() {
    // A display arranged to the left of and above the main one: negative x, positive y.
    let frame = CGRect(x: -2560, y: 400, width: 2560, height: 1440)
    let visible = CGRect(x: -2560, y: 480, width: 2560, height: 1335)
    #expect(DesktopCompat.dockEdge(frame: frame, visible: visible) == .bottom)
}

// MARK: Preferences

@Test func booleanPreferencesReadHoweverTheyWereWritten() {
    #expect(DesktopCompat.bool(false) == false)
    #expect(DesktopCompat.bool(NSNumber(value: 0)) == false)
    #expect(DesktopCompat.bool("FALSE") == false)
    #expect(DesktopCompat.bool("no") == false)
    #expect(DesktopCompat.bool("1") == true)
    #expect(DesktopCompat.bool(nil) == nil)
    #expect(DesktopCompat.bool("maybe") == nil)
}

@Test func desktopIconsFollowFinderAndDesktopAndDock() {
    #expect(DesktopCompat.finderShowsIcons(createDesktop: nil, standardHideDesktopIcons: nil, major: 14))
    #expect(!DesktopCompat.finderShowsIcons(createDesktop: "false", standardHideDesktopIcons: nil, major: 15))
    #expect(!DesktopCompat.finderShowsIcons(createDesktop: true, standardHideDesktopIcons: true, major: 26))
    #expect(DesktopCompat.finderShowsIcons(createDesktop: true, standardHideDesktopIcons: false, major: 27))
    // Before Sonoma the Window Manager key meant nothing to Finder.
    #expect(DesktopCompat.finderShowsIcons(createDesktop: nil, standardHideDesktopIcons: true, major: 13))
}

// MARK: Menu Bar Hider

@Test func onlyMacOS27NeedsTheDividerFitted() {
    #expect(!DesktopCompat.hiderNeedsMeasuring(major: 14))
    #expect(!DesktopCompat.hiderNeedsMeasuring(major: 15))
    #expect(!DesktopCompat.hiderNeedsMeasuring(major: 26))
    #expect(DesktopCompat.hiderNeedsMeasuring(major: 27))
    #expect(DesktopCompat.hiderNeedsMeasuring(major: 28))
}

@Test func beforeMacOS27TheDividerTakesTheMaximum() {
    #expect(DesktopCompat.hiderLength(major: 26, screenWidth: 1728, padding: 16) == 10_000)
    #expect(DesktopCompat.hiderLength(major: 15, screenWidth: 1512, padding: 16) == 10_000)
}

@Test func macOS27TheDividerStaysInsideHalfTheDisplay() {
    // Measured on a 1728 pt display: 620...840 hid every icon, 850 was dropped.
    let length = DesktopCompat.hiderLength(major: 27, screenWidth: 1728, padding: 16)
    #expect(length >= 620 && length <= 840)
    #expect(length + 16 < 1728 / 2)
    #expect(DesktopCompat.hiderLength(major: 27, screenWidth: 3008, padding: 16) == 1464)
}

@Test func aTinyDisplayStillGetsAUsableDivider() {
    #expect(DesktopCompat.hiderLength(major: 27, screenWidth: 40, padding: 16) == 10)
    #expect(DesktopCompat.hiderLength(major: 27, screenWidth: 1728, padding: -5) == 840)
}

@Test func theArrowSeedsRightOfTheDivider() {
    #expect(DesktopCompat.hiderToggleSlot > 0)
    #expect(DesktopCompat.hiderToggleSlot < DesktopCompat.hiderDividerSlot)
}

// MARK: Generated wallpapers

@Test func wallpaperPixelsFitTheLargestTexture() {
    let xdr = DesktopCompat.wallpaperPixels(width: 1728, height: 1117, scale: 2)
    #expect(xdr.width == 3456 && xdr.height == 2234)
    let huge = DesktopCompat.wallpaperPixels(width: 10_240, height: 4320, scale: 2)
    #expect(huge.width == 16_384)
    #expect(abs(Double(huge.height) - 16_384 * 4320 / 10_240) <= 1)
    let nonRetina = DesktopCompat.wallpaperPixels(width: 1920, height: 1080, scale: 1)
    #expect(nonRetina.width == 1920 && nonRetina.height == 1080)
}

@Test func heicOnlyWhereImageIOCanWriteIt() {
    #expect(DesktopCompat.wallpaperFormat(writable: ["public.png", "public.heic"]) == .heic)
    #expect(DesktopCompat.wallpaperFormat(writable: ["public.png", "public.jpeg"]) == .png)
}

@Test func originalWallpaperProblemsAreTold() {
    #expect(DesktopCompat.originalWallpaperProblem(foundFile: true, readable: true) == .none)
    #expect(DesktopCompat.originalWallpaperProblem(foundFile: true, readable: false) == .unreadable)
    #expect(DesktopCompat.originalWallpaperProblem(foundFile: false, readable: false) == .systemWallpaper)
}
