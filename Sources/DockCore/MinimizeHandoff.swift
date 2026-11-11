import CoreGraphics
import Foundation

// MARK: - Handing a window to the hidden macOS Dock, unseen
//
// While the Atelier Dock replaces the macOS one, Atelier plays the minimise effect itself, but
// the window still has to be minimised for real, and macOS animates that to its own Dock,
// hidden at the screen's edge. Measured on macOS 26.6 (VM, recordings at 60 fps):
//
//   - With the Dock's Genie, a window parked at the edge is drawn rising ~170 pt above the edge
//     on its way down; with Scale, the same window only slides along the edge, at most a title
//     bar high, for about 0.2 s. So the hidden Dock is set to Scale while replaced.
//   - A window can never be moved fully off screen: apps keep its title bar (about 32 pt) on.
//     Kept at its full size, it only has to move back on restore, never resize.
//   - The system's animation is drawn at the window's own level (0): a picture of the edge
//     just under the Atelier Dock's level covers it, while the Atelier Dock stays live above.
//
// The pure parts of that are here.

public enum MinimizeHandoff {
    /// The minimise effect the hidden macOS Dock uses while the Atelier Dock replaces it.
    public static let hiddenDockEffect = "scale"

    /// How deep the strip along the hidden Dock's edge is: a parked title bar (about 32 pt),
    /// the part of its shadow above it, and some room for apps that keep a little more on.
    public static let veilDepth = 72.0

    /// How long after asking for the minimise (or the restore) the system's own animation may
    /// still be running. Scale takes about 0.2 s; the rest is margin for a busy window server.
    public static let systemAnimation = 0.36

    /// How long after a restore is asked for the window has surely arrived where it was parked
    /// (Scale brings it back in about 0.2 s). Moving it before that could catch it mid-flight.
    public static let systemArrival = 0.26

    /// The Veil fades out over a few frames, never popping off. It comes on at once: its
    /// picture, taken just before, matches what it lies on.
    public static let veilFade = 0.05

    /// Milliseconds between showing the Veil and moving the window under it: one frame or so,
    /// so the window server has drawn the Veil first.
    public static let veilSettle = 20

    /// The minimise effect "Follow macOS" follows. While the Dock is replaced its own setting
    /// holds Scale, written by Atelier, so the value saved before that write is the owner's.
    /// `replaced` is whether a backup of the owner's values is pending; `saved` is the value
    /// that backup holds for `mineffect` (nil when the key was absent: macOS's Genie).
    public static func followedEffect(current: String?, replaced: Bool, saved: String?) -> String? {
        guard replaced, current == hiddenDockEffect else { return current }
        return saved
    }

    /// Where a window waits while minimised, in Accessibility coordinates (top-left origin):
    /// at its own size, pushed past the edge the hidden macOS Dock is on, level with `target`.
    /// The app pulls it back until its title bar shows; that sliver is all the system animates.
    public static func parkRect(window: CGSize, target: CGRect, screen: CGRect, edge: DockCompat.Edge) -> CGRect {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), max(low, high)) }
        let w = max(window.width, 1), h = max(window.height, 1)
        switch edge {
        case .bottom:
            let x = clamp(target.midX - w / 2, screen.minX, screen.maxX - w)
            return CGRect(x: x, y: screen.maxY, width: w, height: h)
        case .left:
            let y = clamp(target.midY - h / 2, screen.minY, screen.maxY - h)
            return CGRect(x: screen.minX - w, y: y, width: w, height: h)
        case .right:
            let y = clamp(target.midY - h / 2, screen.minY, screen.maxY - h)
            return CGRect(x: screen.maxX, y: y, width: w, height: h)
        }
    }

    /// The strip along the hidden Dock's edge the system's animation of a parked window runs
    /// in, in Cocoa coordinates (bottom-left origin), as `screen` is. Only this is ever covered.
    public static func veilStrip(screen: CGRect, edge: DockCompat.Edge, depth: Double = veilDepth) -> CGRect {
        switch edge {
        case .bottom: return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: min(depth, screen.height))
        case .left: return CGRect(x: screen.minX, y: screen.minY, width: min(depth, screen.width), height: screen.height)
        case .right:
            let d = min(depth, screen.width)
            return CGRect(x: screen.maxX - d, y: screen.minY, width: d, height: screen.height)
        }
    }

    /// Whether a window is left out of the Veil's picture. Only what is drawn above the Veil
    /// anyway (the Atelier Dock, the effect) and the window being minimised: everything under
    /// it, Atelier's own wallpapers, dimming and borders included, must be in the picture, or
    /// it would vanish from the strip while the Veil is up and blink back after.
    /// Atelier's own panels that belong to the window going away (its border, which follows it
    /// to the edge) go too: `frame` and `minimising` are the panel's and the window's frames, in
    /// the same coordinates; a panel is the window's when it hugs it.
    public static func leftOutOfVeil(own: Bool, layer: Int, veilLevel: Int, isMinimising: Bool,
                                     frame: CGRect = .null, minimising: CGRect = .null) -> Bool {
        if isMinimising { return true }
        guard own else { return false }
        return layer >= veilLevel || hugs(frame, minimising)
    }

    /// A panel drawn around a window: inside the window's frame grown by `margin`, and at
    /// least half its size. A wallpaper or a dimming panel over another window is not.
    public static func hugs(_ panel: CGRect, _ window: CGRect, margin: Double = 30) -> Bool {
        guard !panel.isNull, !window.isNull, window.width > 0, window.height > 0 else { return false }
        return window.insetBy(dx: -margin, dy: -margin).contains(panel)
            && panel.width >= window.width / 2 && panel.height >= window.height / 2
    }

    /// The Atelier Dock's tile for a minimised window, by its process and window key.
    public static func tileID(pid: Int32, key: UInt) -> String { "min:\(pid):\(key)" }

    /// Where the effect aims this frame: the tile as the Dock draws it now, or, while the Dock
    /// has no rect for it (laid out but not drawn yet, or gone), the last one it had.
    public static func aim(live: CGRect?, last: CGRect) -> CGRect {
        guard let live, live.width > 0, live.height > 0 else { return last }
        return live
    }

    /// How long the Veil stays up after the effect ended: until the system's own animation,
    /// asked for `since` seconds ago, is surely over; never less than one frame.
    public static func veilHold(since: Double) -> Double { max(systemAnimation - since, 0.017) }

    /// When, into a restore effect of `duration` seconds, the window is brought back for real.
    /// It waits parked and minimised until the system's animation can just finish before the
    /// effect's last frame, so the Veil is up for that animation only, even in slow motion.
    public static func restoreCall(duration: Double) -> Double { max(duration - systemAnimation - 0.04, 0) }
}
