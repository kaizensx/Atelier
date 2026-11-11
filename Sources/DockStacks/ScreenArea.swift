import AppKit
import DockCore

/// Where windows may be placed on a screen: its visible frame less the Atelier Dock's band.
/// `NSScreen.visibleFrame` knows nothing of Atelier's own dock, and while that dock stands in
/// for the macOS Dock it keeps only a few points for the hidden system one, so every placement
/// path (snap zones, layouts and hot keys, the radial menu, title-bar gestures, workspaces,
/// Display Memory, Edge Stash) asks here instead.
///
/// The band follows Reserve Dock Space: none when the owner chose Overlap the Dock, or while
/// the dock auto-hides unless they asked to keep the room then too.
@MainActor
enum ScreenArea {
    /// The dock's band on `screen`, or nil when the dock is not on it or keeps no room.
    static func band(for screen: NSScreen) -> UsableArea.Band? {
        let dock = OwnDock.shared
        let prefs = dock.reserve
        guard dock.enabled, prefs.mode == .reserve, !dock.autoHide || prefs.whileHidden,
              let dockScreen = dock.currentScreen, dockScreen.frame == screen.frame,
              let edge = UsableArea.Edge(rawValue: dock.placedEdge.rawValue) else { return nil }
        let bar = dock.stage.scene.bar
        let cross = dock.placedEdge.horizontal ? bar.height : bar.width
        let thickness = UsableArea.thickness(
            edge: edge, full: screen.frame, visible: screen.visibleFrame, replacing: dock.replacesSystemDock,
            gap: dock.appearance.gap, bar: cross > 1 ? cross : dock.tile * (1 + 2 * dock.appearance.padding),
            margin: prefs.margin)
        return UsableArea.Band(edge: edge, thickness: thickness)
    }

    /// The usable rect in AppKit coordinates, the drop-in for `screen.visibleFrame`.
    static func usable(_ screen: NSScreen) -> CGRect {
        UsableArea.rect(full: screen.frame, visible: screen.visibleFrame, band: band(for: screen))
    }

    /// The usable rect in Accessibility coordinates for the screen whose Accessibility frame is
    /// `frame`; `fallback` when no screen matches (a display that just went away).
    static func usableAX(frame: CGRect, fallback: CGRect) -> CGRect {
        let height = Double(NSScreen.screens.first?.frame.height ?? 0)
        guard let screen = NSScreen.screens.first(where: {
            WindowGeometry.flipped($0.frame, primaryHeight: height) == frame
        }) else { return fallback }
        return WindowGeometry.flipped(usable(screen), primaryHeight: height)
    }
}
