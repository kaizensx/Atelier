import CoreGraphics
import DockCore
import Testing

@Suite struct MenuBarGeometryTests {
    /// The values a 16-inch MacBook Pro reports on macOS 27 (read with NSScreen on the test machine).
    @Test func builtInDisplayWithNotch() {
        let g = MenuBarGeometry(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1084),
                                safeTop: 32,
                                leftArea: CGRect(x: 0, y: 1085, width: 771.5, height: 32),
                                rightArea: CGRect(x: 956.5, y: 1085, width: 771.5, height: 32))
        #expect(g.shown)
        // 33 points: the window server's own Menubar window is 33 tall. safeTop (32) would leave a line.
        #expect(g.bar == CGRect(x: 0, y: 1084, width: 1728, height: 33))
        #expect(g.notch == CGRect(x: 771.5, y: 1085, width: 185, height: 32))
        #expect(g.notchInBar() == CGRect(x: 771.5, y: 0, width: 185, height: 32))
        #expect(g.panelFrame(shadow: 8) == CGRect(x: 0, y: 1076, width: 1728, height: 41))
    }

    @Test func externalDisplayAboveAndRight() {
        // A second display placed up and to the right: its own menu bar, no notch.
        let g = MenuBarGeometry(frame: CGRect(x: 1728, y: 400, width: 2560, height: 1440),
                                visibleFrame: CGRect(x: 1728, y: 400, width: 2560, height: 1416),
                                safeTop: 0, leftArea: nil, rightArea: nil)
        #expect(g.bar == CGRect(x: 1728, y: 1816, width: 2560, height: 24))
        #expect(g.notch == nil)
    }

    @Test func dockOnTheLeftDoesNotMoveTheBar() {
        let g = MenuBarGeometry(frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                visibleFrame: CGRect(x: 70, y: 0, width: 1442, height: 949),
                                safeTop: 32, leftArea: nil, rightArea: nil)
        #expect(g.bar == CGRect(x: 0, y: 949, width: 1512, height: 33))
    }

    @Test func autoHiddenBarIsNotShown() {
        let g = MenuBarGeometry(frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
                                visibleFrame: CGRect(x: 0, y: 80, width: 1728, height: 1037),
                                safeTop: 32, leftArea: nil, rightArea: nil)
        #expect(!g.shown)
        #expect(g.bar.maxY == 1117)
        #expect(g.bar.height == 32)
    }

    @Test func floatingInset() {
        let r = MenuBarGeometry.floating(CGSize(width: 1728, height: 33))
        #expect(r.minX == 6 && r.maxX == 1722)
        #expect(r.height > 26 && r.height < 33)
    }
}

@Test func menuBarSkinSupportByRelease() {
    #expect(MenuBarSkinSupport.evaluate(major: 26, reduceTransparency: false, anyNotch: true, notchSkin: false) == .full)
    #expect(MenuBarSkinSupport.evaluate(major: 27, reduceTransparency: true, anyNotch: true, notchSkin: true) == .full)
    if case .covered = MenuBarSkinSupport.evaluate(major: 14, reduceTransparency: true, anyNotch: false, notchSkin: false) {} else {
        Issue.record("Reduce Transparency on macOS 14 covers the skin")
    }
    if case .softened = MenuBarSkinSupport.evaluate(major: 15, reduceTransparency: false, anyNotch: true, notchSkin: false) {} else {
        Issue.record("macOS 15 softens the skin")
    }
    #expect(MenuBarSkinSupport.evaluate(major: 26, reduceTransparency: false, anyNotch: false, notchSkin: true).note != nil)
}
