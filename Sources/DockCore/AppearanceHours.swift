import Foundation

/// Whether a chosen pair of hours asks for dark at a given minute of the day. The dark hour can
/// fall before or after the light one: 19:00 to 07:30 runs through midnight, 01:00 to 06:00 does not.
public enum AppearanceHours {
    public static func wantsDark(minute: Int, darkAt: Int, lightAt: Int) -> Bool {
        guard darkAt != lightAt else { return false }
        return darkAt > lightAt ? (minute >= darkAt || minute < lightAt) : (minute >= darkAt && minute < lightAt)
    }
}
