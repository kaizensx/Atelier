import Foundation

// MARK: - Permissions, as pure logic
//
// What the Permissions sheet shows for each macOS privacy permission, worked out from what the
// app can read (granted, missing, or unknowable) and what the person has done (asked, opened the
// pane, said "it's on but not working"). No AppKit here: PermissionCenter in the app reads the
// system and feeds this; the tests drive it with fixed clocks.
//
// Input Monitoring is not on the list on purpose: every event tap in Atelier is an active
// `.defaultTap` on the session, and every global key monitor is NSEvent's. Both are covered by
// Accessibility, and neither asks for Input Monitoring.

public enum PermissionKind: String, CaseIterable, Sendable, Identifiable {
    case accessibility, screenRecording, systemAudio, fullDiskAccess, appManagement

    public var id: String { rawValue }

    /// Needed by most of Atelier. Missing ones bring Home's reminder and the 2 s poll.
    public var essential: Bool { self == .accessibility || self == .screenRecording }

    public var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        case .systemAudio: "System Audio Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .appManagement: "App Management"
        }
    }

    /// What it unlocks, in one plain sentence.
    public var unlocks: String {
        switch self {
        case .accessibility: "Moves and snaps windows, runs the Atelier Dock, and powers keyboard shortcuts like Hyper Key."
        case .screenRecording: "Shows window pictures in the Dock and switcher, and runs Text Grab and the screen recorder."
        case .systemAudio: "Lets the Sound Mixer set each app's volume and EQ."
        case .fullDiskAccess: "Lets Atelier change the Accessibility display settings that macOS keeps private."
        case .appManagement: "Lets Atelier give other apps a custom icon."
        }
    }

    /// The list's name in System Settings › Privacy & Security, word for word.
    public var listName: String {
        switch self {
        case .accessibility: "Accessibility"
        case .screenRecording, .systemAudio: "Screen & System Audio Recording"
        case .fullDiskAccess: "Full Disk Access"
        case .appManagement: "App Management"
        }
    }

    /// The anchor of its pane: `x-apple.systempreferences:com.apple.preference.security?<anchor>`.
    public var settingsAnchor: String {
        switch self {
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        case .systemAudio: "Privacy_AudioCapture"
        case .fullDiskAccess: "Privacy_AllFiles"
        case .appManagement: "Privacy_AppBundles"
        }
    }

    /// Has a system call that puts Atelier in the list (and may show a prompt) before the pane opens.
    public var addsItselfToList: Bool { self == .accessibility || self == .screenRecording }

    /// Can be left behind by a re-sign: the switch looks on, the app is not trusted.
    public var canGoStale: Bool { self == .accessibility || self == .screenRecording }

    /// The process must start again before the grant fully takes effect.
    public var mayNeedRelaunch: Bool { self == .screenRecording }
}

/// What the app can read about one permission.
public enum PermissionReading: Sendable, Equatable {
    case granted, missing
    /// macOS has no way to ask (App Management), or the check is not available.
    case unknown
}

/// What the person has done about one permission this session.
public struct PermissionTrack: Sendable, Equatable {
    /// The button was pressed (prompt shown or pane opened).
    public var requestedAt: Date?
    /// System Settings was opened at this permission's pane.
    public var paneOpenedAt: Date?
    /// "It's on but not working".
    public var userSaysOn = false
    /// Read when Atelier started. A grant that lands later may need a relaunch.
    public var grantedAtLaunch: Bool

    public init(grantedAtLaunch: Bool, requestedAt: Date? = nil, paneOpenedAt: Date? = nil, userSaysOn: Bool = false) {
        self.grantedAtLaunch = grantedAtLaunch
        self.requestedAt = requestedAt
        self.paneOpenedAt = paneOpenedAt
        self.userSaysOn = userSaysOn
    }
}

/// What a row shows.
public enum PermissionPhase: Sendable, Equatable {
    case granted
    /// Granted while Atelier ran: it works for some features, all of them after a relaunch.
    case grantedRelaunchSuggested
    /// Not granted and not asked yet.
    case missing
    /// Asked; the pane is open and the person is on it.
    case waiting
    /// Asked, said to be on, or the pane has been open a while with no trust: a stale entry.
    case stale
    /// Nothing to read (App Management).
    case unknown

    public var isGranted: Bool { self == .granted || self == .grantedRelaunchSuggested }
}

/// The one button a row shows.
public enum PermissionAction: Sendable, Equatable {
    /// Put Atelier in the list with the system call, then open the pane.
    case requestThenOpen
    case openSettings
    case relaunch
    case none
}

public enum PermissionFlow {
    /// How long the pane may stay open without trust before the stale-entry fix shows by itself.
    public static let staleAfter: TimeInterval = 20
    /// Poll while the sheet is open or an essential permission is missing.
    public static let activeInterval: TimeInterval = 2
    /// Otherwise: just enough to notice a revoke.
    public static let idleInterval: TimeInterval = 10

    public static func phase(_ kind: PermissionKind, reading: PermissionReading, track: PermissionTrack,
                             now: Date) -> PermissionPhase {
        switch reading {
        case .unknown:
            return .unknown
        case .granted:
            if kind.mayNeedRelaunch, !track.grantedAtLaunch { return .grantedRelaunchSuggested }
            if kind.mayNeedRelaunch, track.userSaysOn { return .grantedRelaunchSuggested }
            return .granted
        case .missing:
            guard kind.canGoStale else { return track.paneOpenedAt == nil ? .missing : .waiting }
            if track.userSaysOn { return .stale }
            if let opened = track.paneOpenedAt {
                return now.timeIntervalSince(opened) >= staleAfter ? .stale : .waiting
            }
            return track.requestedAt == nil ? .missing : .waiting
        }
    }

    /// The row's button.
    public static func action(_ kind: PermissionKind, phase: PermissionPhase, track: PermissionTrack) -> PermissionAction {
        switch phase {
        case .granted: return .none
        case .grantedRelaunchSuggested: return .relaunch
        case .missing, .waiting:
            // The system call goes first only once a session: after that macOS shows no prompt,
            // and the pane is what helps.
            return kind.addsItselfToList && track.requestedAt == nil ? .requestThenOpen : .openSettings
        case .stale, .unknown: return .openSettings
        }
    }

    /// The button's words.
    public static func actionTitle(_ action: PermissionAction) -> String? {
        switch action {
        case .requestThenOpen: "Allow…"
        case .openSettings: "Open Settings…"
        case .relaunch: "Relaunch Atelier"
        case .none: nil
        }
    }

    /// When the next stale check is due, so a view can wake for it without polling faster.
    public static func staleDeadline(track: PermissionTrack) -> Date? {
        track.paneOpenedAt.map { $0.addingTimeInterval(staleAfter) }
    }

    /// The essential permissions still missing, in list order.
    public static func essentialMissing(_ readings: [PermissionKind: PermissionReading]) -> [PermissionKind] {
        PermissionKind.allCases.filter { $0.essential && readings[$0] == .missing }
    }

    public static func pollInterval(sheetOpen: Bool, readings: [PermissionKind: PermissionReading]) -> TimeInterval {
        sheetOpen || !essentialMissing(readings).isEmpty ? activeInterval : idleInterval
    }

    /// The first-launch Welcome: once, unless a relaunch for a permission brought Atelier back
    /// (then the sheet reopens at the permissions, not the welcome).
    public static func launchSheet(welcomed: Bool, reopenAfterRelaunch: Bool) -> LaunchSheet {
        if reopenAfterRelaunch { return .permissions }
        return welcomed ? .none : .welcome
    }

    public enum LaunchSheet: Sendable, Equatable { case none, welcome, permissions }

    /// Home's reminder, in a few words, or nil when nothing essential is missing.
    public static func homeReminder(_ readings: [PermissionKind: PermissionReading]) -> String? {
        let missing = essentialMissing(readings)
        switch missing.count {
        case 0: return nil
        case 1: return "Needs \(missing[0].title)"
        default: return "Needs \(missing.count) permissions"
        }
    }

    /// The numbered steps that clear a stale entry. `folder` is where Atelier is installed
    /// ("Applications" for a normal install).
    public static func fixSteps(_ kind: PermissionKind, folder: String) -> [String] {
        var steps = ["Select Atelier in the list.",
                     "Press − to remove it.",
                     "Press +, then choose Atelier in \(folder).",
                     "Turn Atelier on."]
        if kind == .screenRecording { steps.append("Relaunch Atelier.") }
        return steps
    }

    /// The warning about the list that looks right but is not, or nil.
    public static func listWarning(_ kind: PermissionKind) -> String? {
        switch kind {
        case .screenRecording:
            "Use the top list, Screen & System Audio Recording. Not System Audio Recording Only."
        default: nil
        }
    }
}
