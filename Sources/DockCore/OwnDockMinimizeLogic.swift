import CoreGraphics
import Foundation

// MARK: - Minimise into the Atelier Dock without a window picture
//
// With Screen Recording, a picture of the window flies into the Atelier Dock. Without it there
// is no picture to fly, so the real window does the flight itself: Accessibility moves and
// shrinks it, a few frames, onto the Atelier Dock's slot, and only then is it minimised. The
// system's genie then starts from a small window already at the edge, not from the full
// window, and is over before it can be seen running to the hidden macOS Dock.

public enum OwnDockMinimizeShrink {
    /// The frames the window passes through, `from` to `to`, last one exactly `to`. Eased in, so
    /// it leaves gently and arrives fast, as the picture's flight does. Both rects in the same
    /// coordinates (Accessibility's, top-left based).
    public static func frames(from: CGRect, to: CGRect, steps: Int = 7) -> [CGRect] {
        let count = max(steps, 1)
        return (1...count).map { index in
            let t = Double(index) / Double(count)
            let e = t * t
            func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * e }
            return CGRect(x: mix(from.minX, to.minX), y: mix(from.minY, to.minY),
                          width: mix(from.width, to.width), height: mix(from.height, to.height))
        }
    }

    /// A small rect centred on the slot, where the window is aimed before it is parked.
    public static func aim(slot: CGRect, size: CGSize = CGSize(width: 80, height: 60)) -> CGRect {
        CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2, width: size.width, height: size.height)
    }
}
