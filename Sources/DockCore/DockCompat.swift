import CoreGraphics
import Foundation

// Decisions about the Dock that depend on the macOS version or on where things are on screen.
// They take the version, the screens and the edges as plain values, so every branch can be
// tested on one Mac without the OS or the hardware it describes.

public enum DockCompat {
    // MARK: The app launcher

    /// macOS 26 replaced Launchpad with the Apps app (`/System/Applications/Apps.app`, checked
    /// on macOS 27.3). Earlier versions ship `/System/Applications/Launchpad.app`.
    public static func launcherPath(major: Int, exists: (String) -> Bool) -> String {
        let apps = "/System/Applications/Apps.app", launchpad = "/System/Applications/Launchpad.app"
        let preferred = major >= 26 ? apps : launchpad
        let other = major >= 26 ? launchpad : apps
        // A point release could still move it: take whichever is really there.
        if exists(preferred) { return preferred }
        return exists(other) ? other : preferred
    }

    /// What the launcher is called on this version, for menus and settings.
    public static func launcherTitle(major: Int) -> String { major >= 26 ? "Apps" : "Launchpad" }

    // MARK: Snapshots across versions

    /// Keys the Dock keeps for itself and migrates when macOS is updated. A snapshot taken on
    /// an older macOS must not put back an older `version`, or the Dock may run its migration
    /// again on the next start; the running system's value is kept instead.
    public static let bookkeepingKeys = ["version"]

    /// `target`, with the current system's bookkeeping values in place of the snapshot's.
    public static func carryingBookkeeping(current: [String: Any], target: [String: Any]) -> [String: Any] {
        var result = target
        for key in bookkeepingKeys {
            if let value = current[key] { result[key] = value } else { result[key] = nil }
        }
        return result
    }

    // MARK: Minimise into the Atelier Dock

    /// The edge the macOS Dock sits on, from its `orientation` preference. Anything unknown,
    /// or absent, is the bottom, as the Dock itself reads it.
    public enum Edge: String, Sendable { case bottom, left, right }

    public static func edge(orientation: String?) -> Edge { orientation.flatMap(Edge.init(rawValue:)) ?? .bottom }

    /// Where a window is parked, in Accessibility coordinates (top-left origin, y down), just
    /// before it is minimised: as small as an app allows and against the edge of `screen` the
    /// hidden macOS Dock lives on, level with `target`. The system's own genie then runs a
    /// few pixels to that edge instead of across the screen.
    /// `screen` is the screen of `target`, both in Accessibility coordinates.
    public static func parkRect(target: CGRect, screen: CGRect, edge: Edge, size: CGSize = CGSize(width: 80, height: 60)) -> CGRect {
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double { min(max(value, low), max(low, high)) }
        switch edge {
        case .bottom:
            let x = clamp(target.midX - size.width / 2, screen.minX, screen.maxX - size.width)
            return CGRect(x: x, y: screen.maxY - 2, width: size.width, height: size.height)
        case .left:
            let y = clamp(target.midY - size.height / 2, screen.minY, screen.maxY - size.height)
            return CGRect(x: screen.minX - size.width + 2, y: y, width: size.width, height: size.height)
        case .right:
            let y = clamp(target.midY - size.height / 2, screen.minY, screen.maxY - size.height)
            return CGRect(x: screen.maxX - 2, y: y, width: size.width, height: size.height)
        }
    }

    /// The band of `screen` the system's genie crosses on its way to the hidden macOS Dock, in
    /// Cocoa coordinates (bottom-left origin, y up), as `target` is. A still picture covers it
    /// while the genie runs. At least `minimum` deep, and always reaching past the target.
    public static func coverBand(target: CGRect, screen: CGRect, edge: Edge, minimum: Double = 380) -> CGRect {
        switch edge {
        case .bottom:
            let depth = min(max(target.maxY - screen.minY + 40, minimum), screen.height)
            return CGRect(x: screen.minX, y: screen.minY, width: screen.width, height: depth)
        case .left:
            let depth = min(max(target.maxX - screen.minX + 40, minimum), screen.width)
            return CGRect(x: screen.minX, y: screen.minY, width: depth, height: screen.height)
        case .right:
            let depth = min(max(screen.maxX - target.minX + 40, minimum), screen.width)
            return CGRect(x: screen.maxX - depth, y: screen.minY, width: depth, height: screen.height)
        }
    }

    /// Whether a key-down is the Minimize command, ⌘M. The letter is matched by the character
    /// the layout types, so AZERTY and other Latin layouts that put M on another key work.
    /// A layout that types no Latin letter (Cyrillic, Greek…) gets its menu shortcuts from the
    /// key's ANSI position, as macOS does, so there the ANSI key code of M (46) decides.
    public static func isMinimizeKey(characters: String?, keyCode: Int64, commandOnly: Bool, autorepeat: Bool) -> Bool {
        guard commandOnly, !autorepeat else { return false }
        let typed = characters?.lowercased() ?? ""
        // No character came with the event: the key's position is all there is.
        guard let scalar = typed.unicodeScalars.first, typed.unicodeScalars.count == 1 else { return keyCode == 46 }
        if ("a"..."z").contains(scalar) { return scalar == "m" }
        // A letter of another script: the shortcut goes by position. Punctuation never is M.
        return CharacterSet.letters.contains(scalar) && keyCode == 46
    }

    /// What to say next to Minimise into the Atelier Dock, or nil when nothing is limited.
    /// From macOS 15 the system asks again from time to time whether an app may keep
    /// recording the screen, which the window picture needs (macOS Sequoia 15.0 and 15.1).
    public static func minimizeNote(major: Int) -> String? {
        major >= 15 ? "Uses Screen Recording for the window picture. macOS asks again from time to time to keep allowing it." : nil
    }
}
