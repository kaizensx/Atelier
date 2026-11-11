import Foundation

// MARK: - Windows: what differs between macOS releases
//
// Plain decisions, taking the release as a parameter, so they can be tested for every
// release without running on it. The callers read the live preferences and pass them in.

/// macOS's own window tiling, which arrived in macOS 15 Sequoia. Its switches live in
/// `com.apple.WindowManager`; a key that is missing means the shipped default, which is on.
public enum WindowsCompatTiling {
    /// "Drag windows to screen edges to tile".
    public static let edgeDragKey = "EnableTilingByEdgeDrag"
    /// "Drag windows to menu bar to fill screen".
    public static let topEdgeDragKey = "EnableTopTilingByEdgeDrag"
    /// Stage Manager, which has its own domain key since macOS 13.
    public static let stageManagerKey = "GloballyEnabled"

    /// Whether dragging a window to an edge also makes macOS tile it, so Snap Zones and macOS
    /// would both react to one drag. Before 15 there is no such tiling, whatever the keys say.
    public static func appleTilingReacts(major: Int, edgeDrag: Bool?, topEdgeDrag: Bool?) -> Bool {
        guard major >= 15 else { return false }
        return (edgeDrag ?? true) || (topEdgeDrag ?? true)
    }

    /// Whether Stage Manager is on. Missing means off, as it ships.
    public static func stageManagerOn(_ value: Bool?) -> Bool { value ?? false }
}

/// The ring Window Borders draws should follow the window's own corners.
public enum WindowsCompatCorners {
    /// The corner radius of an ordinary document window, in points. macOS 26 rounded windows
    /// much more than earlier releases (about 10 pt on 14 and 15); 16 is what Atelier was
    /// tuned to on 26 and 27.
    public static func windowRadius(major: Int) -> Double { major >= 26 ? 16 : 10 }
}
