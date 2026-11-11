import Foundation

// System UI: Control Center and the menu bar, Spotlight, Mission Control and Stage Manager,
// the lock screen. Every key below was found as a literal in the process that reads it, or
// decoded by REA from that process's code, or read from this Mac's own defaults. `evidence`
// says which, and says "effect not verified" unless the change was seen on screen.

extension PersonalSetting {
    /// Hidden debug or internal switches. Their cautions start with "Experimental".
    public var isExperimental: Bool { caution?.hasPrefix("Experimental") == true }
}

extension PersonalCatalog {
    /// Every setting from the system-UI catalogue, in display order.
    public static let systemSettings: [PersonalSetting] = controlCenterSettings + spotlightSettings
        + missionControlSettings + lockScreenSettings + accessibilitySettings + appKitSettings
        + quickLookSettings + hapticSettings + hiddenDockMotionSettings

    private static let unverified = "; effect not verified"

    /// With no override, clocks follow the region: what the "j" skeleton turns into for it.
    static var localeUses24Hours: Bool {
        !(DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a").contains("a")
    }

    static func sysToggle(_ on: Bool = true) -> PersonalControl { .toggle(on: .bool(on), off: .bool(!on)) }

    // MARK: Control Center and the menu bar

    private static let controlCenterProc = PersonalEffect.restart("ControlCenter")

    /// What System Settings writes for a menu bar module: a ByHost int under the module's name in
    /// com.apple.controlcenter (18 always, 2 when active, 8 never; seen on this Mac). Modules
    /// that never had a choice made fall back to AppKit's "NSStatusItem VisibleCC <id>" flag,
    /// which `PersonalPrefs.read` folds into the same three values.
    public static let menuModuleOptions = [PersonalOption(.int(18), "Always"), PersonalOption(.int(2), "When Active"),
                                           PersonalOption(.int(8), "Never"),
                                           // Seen on this Mac for User Switcher, with its VisibleCC flag 0.
                                           PersonalOption(.int(24), "Not in Menu Bar")]

    private static func menuItem(_ id: String, _ title: String, seenHere: Bool, preview: String) -> PersonalSetting {
        PersonalSetting(.controlCenter, "Menu Bar Items", domain: "com.apple.controlcenter", key: id,
                        kind: .int, currentHost: true, control: .choice(menuModuleOptions), title: title,
                        detail: "When the \(title.lowercased()) item shows in the menu bar.", effect: controlCenterProc,
                        evidence: "ControlCenter __cstring module names; ByHost com.apple.controlcenter values 18/2/8 read from this Mac's defaults"
                            + (seenHere ? "; present on this Mac" : unverified),
                        preview: preview)
    }

    static let controlCenterSettings: [PersonalSetting] = [
        menuItem("Battery", "Battery", seenHere: true, preview: "The battery glyph appearing in the menu bar"),
        menuItem("WiFi", "Wi-Fi", seenHere: true, preview: "The Wi-Fi fan appearing in the menu bar"),
        menuItem("Bluetooth", "Bluetooth", seenHere: false, preview: "The Bluetooth rune appearing in the menu bar"),
        menuItem("Sound", "Sound", seenHere: false, preview: "A speaker glyph appearing in the menu bar"),
        menuItem("NowPlaying", "Now Playing", seenHere: false, preview: "A play button appearing in the menu bar"),
        menuItem("FocusModes", "Focus", seenHere: false, preview: "A crescent moon appearing in the menu bar"),
        menuItem("Display", "Display", seenHere: false, preview: "A display glyph appearing in the menu bar"),
        menuItem("ScreenMirroring", "Screen Mirroring", seenHere: false, preview: "Two overlapping screens in the menu bar"),
        menuItem("AirDrop", "AirDrop", seenHere: false, preview: "The AirDrop rings in the menu bar"),
        menuItem("KeyboardBrightness", "Keyboard Brightness", seenHere: false, preview: "A keyboard sun in the menu bar"),
        menuItem("Hearing", "Hearing", seenHere: false, preview: "An ear glyph in the menu bar"),
        menuItem("AccessibilityShortcuts", "Accessibility Shortcuts", seenHere: false, preview: "The accessibility figure in the menu bar"),
        menuItem("MusicRecognition", "Music Recognition", seenHere: false, preview: "The Shazam glyph in the menu bar"),
        menuItem("UserSwitcher", "User Switcher", seenHere: true, preview: "Your name appearing in the menu bar"),
        PersonalSetting(.controlCenter, "Menu Bar Items", domain: "com.apple.Spotlight", key: "NSStatusItem VisibleCC Item-0",
                        kind: .bool, control: sysToggle(), title: "Spotlight",
                        detail: "The magnifying glass in the menu bar.", effect: .restart("Spotlight"), fallback: .bool(true),
                        evidence: "AppKit __cstring \"NSStatusItem %@ %@\"; key present in this Mac's com.apple.Spotlight defaults" + unverified,
                        preview: "The magnifying glass leaving the menu bar"),
        PersonalSetting(.controlCenter, "Menu Bar Items", domain: "com.apple.Siri", key: "StatusMenuVisible", kind: .bool,
                        control: sysToggle(), title: "Siri", detail: "The Siri orb in the menu bar.", effect: controlCenterProc,
                        evidence: "dyld shared cache string StatusMenuVisible; key present in this Mac's com.apple.Siri" + unverified,
                        preview: "The Siri orb appearing in the menu bar",
                        caution: "Siri draws this item itself. If it does not change, open Siri once."),
        PersonalSetting(.controlCenter, "Menu Bar Items", domain: "com.apple.airplay", key: "showInMenuBarIfPresent", kind: .bool,
                        control: sysToggle(), title: "AirPlay When Available",
                        detail: "Show AirPlay when there is something to play to.", effect: controlCenterProc,
                        evidence: "ControlCenter __cstring showInMenuBarIfPresent (ControlCenter.AirPlayPreferences)" + unverified,
                        preview: "The AirPlay triangle appearing"),

        PersonalSetting(.controlCenter, "Battery", domain: "com.apple.controlcenter", key: "BatteryShowPercentage", kind: .bool,
                        currentHost: true, control: sysToggle(), title: "Battery Percentage",
                        detail: "The number next to the battery glyph.", effect: controlCenterProc,
                        evidence: "ControlCenter __cstring BatteryShowPercentage; ByHost value on this Mac",
                        preview: "The battery glyph gaining “87%”"),
        PersonalSetting(.controlCenter, "Battery", domain: "com.apple.controlcenter", key: "BatteryShowEnergyMode", kind: .bool,
                        currentHost: true, control: sysToggle(), title: "Energy Mode in Battery Menu",
                        detail: "Low Power and High Power modes in the battery menu.", effect: controlCenterProc,
                        evidence: "ControlCenter __cstring BatteryShowEnergyMode; ByHost value on this Mac",
                        preview: "The battery menu showing the energy mode row"),

        PersonalSetting(.controlCenter, "Clock", domain: "com.apple.menuextra.clock", key: "ShowDate", kind: .int,
                        control: .choice([.init(.int(0), "When Space Allows"), .init(.int(1), "Always"), .init(.int(2), "Never")]),
                        title: "Show the Date", detail: "The date beside the time.", effect: controlCenterProc, fallback: .int(0),
                        evidence: "ControlCenter log \"Reload clock preferences … showDate\"; key present in this Mac's defaults",
                        preview: "The clock gaining and losing the date"),
        PersonalSetting(.controlCenter, "Clock", domain: "com.apple.menuextra.clock", key: "ShowDayOfWeek", kind: .bool,
                        control: sysToggle(), title: "Day of the Week", detail: "“Sun” before the date.", effect: controlCenterProc,
                        fallback: .bool(true),
                        evidence: "ControlCenter log \"… showDayOfWeek\"; key present in this Mac's defaults",
                        preview: "The clock gaining “Sun”"),
        PersonalSetting(.controlCenter, "Clock", domain: "com.apple.menuextra.clock", key: "ShowAMPM", kind: .bool,
                        control: sysToggle(), title: "AM/PM", detail: "The suffix on a 12-hour clock.", effect: controlCenterProc,
                        fallback: .bool(true),
                        evidence: "ControlCenter log \"… showAMPM\"; key present in this Mac's defaults",
                        preview: "The clock dropping “PM”"),
        PersonalSetting(.controlCenter, "Clock", domain: "NSGlobalDomain", key: "AppleICUForce24HourTime", kind: .bool,
                        control: sysToggle(), title: "24-Hour Time", detail: "Every clock on the Mac, the menu bar's too.",
                        effect: .relaunchApps, fallback: .bool(localeUses24Hours),
                        evidence: "CoreFoundation and LoginUIKit __cstring AppleICUForce24HourTime",
                        preview: "3:41 PM turning into 15:41",
                        caution: "The menu bar clock follows after ControlCenter restarts; other apps when reopened."),

        PersonalSetting(.controlCenter, "Menu Bar", domain: "NSGlobalDomain", key: "_HIHideMenuBar", kind: .bool,
                        control: sysToggle(), title: "Hide the Menu Bar",
                        detail: "It slides down when the pointer reaches the top.", effect: .relaunchApps, fallback: .bool(false),
                        evidence: "AppKit, HIToolbox and SkyLight __cstring _HIHideMenuBar" + unverified,
                        preview: "The menu bar sliding away",
                        caution: "Apps already open keep their menu bar until reopened, or until you log out."),
        PersonalSetting(.controlCenter, "Menu Bar", domain: "NSGlobalDomain", key: "AppleMenuBarVisibleInFullscreen", kind: .bool,
                        control: sysToggle(), title: "Menu Bar in Full Screen",
                        detail: "Keep the menu bar visible over full-screen apps.", effect: .relaunchApps, fallback: .bool(false),
                        evidence: "AppKit __cstring AppleMenuBarVisibleInFullscreen; Control Center settings writes it" + unverified,
                        preview: "A full-screen window with the menu bar kept"),
        PersonalSetting(.controlCenter, "Menu Bar", domain: "NSGlobalDomain", key: "userMenuExtraStyle", kind: .int,
                        control: .choice([.init(.int(0), "Full Name"), .init(.int(1), "Account Name"), .init(.int(2), "Icon")]),
                        title: "User Switcher Shows", detail: "What the fast user switching item displays.",
                        effect: controlCenterProc,
                        evidence: "ControlCenter __cstring userMenuExtraStyle (UserSwitcherUserPreferences)" + unverified,
                        preview: "The user item turning from a name into a silhouette",
                        caution: "Read from the global domain, as older macOS did. If nothing changes, the reader looks elsewhere."),
    ]

    // MARK: Spotlight

    private static let spotlightProc = PersonalEffect.restart("Spotlight")

    private static func spotlight(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                                  _ title: String, _ detail: String, image: String, preview: String,
                                  fallback: PersonalValue? = nil, experimental: String? = nil) -> PersonalSetting {
        PersonalSetting(.spotlight, "Spotlight", domain: "com.apple.Spotlight", key: key, kind: kind,
                        control: control ?? sysToggle(), title: title, detail: detail, effect: spotlightProc, fallback: fallback,
                        evidence: "\(image) __cstring \(key); Spotlight.app is not sandboxed and keeps its UI keys in com.apple.Spotlight"
                            + unverified,
                        preview: preview,
                        caution: experimental.map { "Experimental. " + $0 })
    }

    static let spotlightSettings: [PersonalSetting] = [
        spotlight("SUIDisableInvocationAnimation", "No Opening Animation", "Spotlight appears at once.",
                  image: "SpotlightUIShared", preview: "The search bar popping in with no grow",
                  experimental: "An internal switch with no setting in System Settings."),
        spotlight("SUIDisableExpansionAnimation", "No Expansion Animation", "Results appear without the window growing.",
                  image: "SpotlightUIShared", preview: "Results snapping open",
                  experimental: "An internal switch with no setting in System Settings."),
        spotlight("SUIDisableBrowseButtonAnimation", "Still Browse Buttons", "The category buttons stop animating.",
                  image: "SpotlightUIShared", preview: "The Apps, Files and Actions buttons sitting still",
                  experimental: "An internal switch with no setting in System Settings."),
        spotlight("SUIWindowSizeAnimationSpeed", kind: .float,
                  control: .choice([.init(.float(0.5), "Slower"), .init(.float(1), "Normal"), .init(.float(2), "Faster"),
                                    .init(.float(4), "Fastest")]),
                  "Resize Speed", "How fast the window grows to fit results.", image: "SpotlightUIShared",
                  preview: "The Spotlight window resizing at the chosen pace",
                  experimental: "The scale of this number is not documented. Revert if Spotlight looks wrong."),
        spotlight("SUIWiderFilesBrowseViewEnabled", "Wider Files View", "A wider layout when browsing files.",
                  image: "SpotlightUIShared", preview: "The Files browser widening",
                  experimental: "An internal layout flag."),
        spotlight("SearchFieldClearTimeoutSeconds", kind: .float, control: .number(0...600, step: 5, unit: "s"),
                  "Forget Last Search After", "How long Spotlight keeps your last query.", image: "SpotlightUIInternal",
                  preview: "The search field reopening with the last query, then empty",
                  experimental: "Read by Spotlight's window controller. The default is not known."),
        spotlight("trackpadAppBrowseEnabled", "Trackpad App Browsing", "Swipe through apps with the trackpad in Spotlight.",
                  image: "SpotlightUIInternal", preview: "Fingers swiping through an app grid",
                  experimental: "Name suggests a gesture; not seen on screen."),
        spotlight("singleScreenClamp", "Keep on One Screen", "Spotlight stays on the screen it opened on.",
                  image: "SpotlightUIInternal", preview: "Spotlight pinned to one display",
                  experimental: "Read with the window position keys; not seen on screen."),
        spotlight("shouldShowTopResultAboveFilterBar", "Top Hit Above Filters", "The best match sits above the filter chips.",
                  image: "SpotlightUIShared", preview: "The top result moving above the filter row",
                  experimental: "An internal layout flag."),
    ]

    // MARK: Mission Control, Spaces, Stage Manager, tiling, app switcher

    private static let dockProcess = PersonalEffect.restart("Dock")
    private static let windowManagerProc = PersonalEffect.restart("WindowManager")

    private static func wm(_ section: String, _ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                           _ title: String, _ detail: String, seenHere: Bool, fallback: PersonalValue? = nil,
                           preview: String) -> PersonalSetting {
        PersonalSetting(.missionControl, section, domain: "com.apple.WindowManager", key: key, kind: kind,
                        control: control ?? sysToggle(), title: title, detail: detail, effect: windowManagerProc, fallback: fallback,
                        evidence: "dyld shared cache string \(key); Desktop & Dock settings writes it"
                            + (seenHere ? "; key present in this Mac's defaults" : "") + unverified,
                        preview: preview)
    }

    static let missionControlSettings: [PersonalSetting] = [
        PersonalSetting(.missionControl, "Mission Control", domain: "com.apple.dock", key: "mcx-expose-disabled", kind: .bool,
                        control: sysToggle(), title: "Turn Off Mission Control",
                        detail: "The key, gesture and hot corner stop opening it.", effect: dockProcess, fallback: .bool(false),
                        evidence: "REA: Dock string mcx-expose-disabled" + unverified,
                        preview: "Mission Control refusing to open",
                        caution: "This is the switch device management uses. Revert brings Mission Control back."),
        PersonalSetting(.missionControl, "Mission Control", domain: "com.apple.dock", key: "showMissionControlGestureEnabled",
                        kind: .bool, control: sysToggle(), title: "Mission Control Gesture",
                        detail: "Swipe up with three or four fingers.", effect: dockProcess, fallback: .bool(true),
                        evidence: "REA: Dock strings showMissionControlGestureEnabled(Pref)" + unverified,
                        preview: "Fingers swiping up into Mission Control"),
        PersonalSetting(.missionControl, "Mission Control", domain: "com.apple.dock", key: "showDesktopGestureEnabled",
                        kind: .bool, control: sysToggle(), title: "Show Desktop Gesture",
                        detail: "Spread thumb and three fingers.", effect: dockProcess, fallback: .bool(true),
                        evidence: "REA: Dock strings showDesktopGestureEnabled(Pref)" + unverified,
                        preview: "Windows flying to the edges"),
        PersonalSetting(.missionControl, "Mission Control", domain: "com.apple.dock", key: "expose-sticky-time", kind: .float,
                        control: .number(0.1...2, step: 0.05, unit: "s"), title: "Hold Threshold",
                        detail: "Hold the Mission Control key longer than this and releasing it closes Mission Control.",
                        effect: dockProcess,
                        evidence: "REA: Dock reads expose-sticky-time as a float of seconds while installing its hot keys" + unverified,
                        preview: "Mission Control springing shut when the key is let go",
                        caution: "Experimental. Hidden Dock timing; the default is not known."),
        PersonalSetting(.missionControl, "Mission Control", domain: "com.apple.dock", key: "workspaces-maximize-to-current-space",
                        kind: .bool, control: sysToggle(), title: "Restore Minimised Windows Here",
                        detail: "A window you bring back from the Dock comes to the Space you are in.", effect: dockProcess,
                        fallback: .bool(false),
                        evidence: "REA: Dock reads workspaces-maximize-to-current-space (default NO) when un-minimising a window"
                            + unverified,
                        preview: "A minimised window landing in the current Space",
                        caution: "Experimental. Hidden Dock switch."),
        PersonalSetting(.missionControl, "Mission Control", domain: "com.apple.dock", key: "clip-windows", kind: .bool,
                        control: sysToggle(), title: "Clip Windows to Their Space",
                        detail: "Dock's internal switch for clipping windows to their Space.", effect: dockProcess,
                        fallback: .bool(true),
                        evidence: "REA: DockGlobals init reads clip-windows (inline Swift string) as Bool, default YES" + unverified,
                        preview: "Windows clipped at the edge of a sliding Space",
                        caution: "Experimental. What this changes on screen was not seen."),

        PersonalSetting(.missionControl, "Spaces", domain: "com.apple.spaces", key: "spans-displays", kind: .bool,
                        control: sysToggle(), title: "One Set of Spaces for All Displays",
                        detail: "Turn off “Displays have separate Spaces”.", effect: .logout, fallback: .bool(false),
                        evidence: "SkyLight __cstring spans-displays" + unverified,
                        preview: "Two displays switching Space together"),
        PersonalSetting(.missionControl, "Spaces", domain: "com.apple.dock", key: "allow-display-switching", kind: .bool,
                        control: sysToggle(), title: "Dock Moves Between Displays",
                        detail: "Off pins the Dock to one display.", effect: dockProcess, fallback: .bool(true),
                        evidence: "REA: DockGlobals init reads allow-display-switching as Bool, default YES" + unverified,
                        preview: "The Dock staying put when the pointer rests on the other screen",
                        caution: "Experimental. Hidden Dock switch."),

        PersonalSetting(.missionControl, "App Switcher", domain: "com.apple.dock", key: "appswitcher-dock-display", kind: .bool,
                        control: sysToggle(), title: "Switcher on the Dock's Display",
                        detail: "⌘-Tab appears on the display that has the Dock.", effect: dockProcess, fallback: .bool(false),
                        evidence: "REA: DockGlobals init reads appswitcher-dock-display as Bool (appSwitcherOnDockDisplay)"
                            + unverified,
                        preview: "The ⌘-Tab strip following the Dock to another screen",
                        caution: "Experimental. Hidden Dock switch."),

        wm("Stage Manager", "GloballyEnabled", "Stage Manager", "Turn Stage Manager on.", seenHere: true, fallback: .bool(false),
           preview: "Windows gathering into the side strip"),
        wm("Stage Manager", "AppWindowGroupingBehavior", kind: .int,
           control: .choice([.init(.int(0), "All at Once"), .init(.int(1), "One at a Time")]),
           "Show an App's Windows", "Choosing an app brings all its windows, or only the latest.", seenHere: true,
           preview: "An app's windows arriving together or one by one"),
        wm("Stage Manager", "HideDesktop", "Hide Desktop Items in Stage Manager", "Desktop icons stay hidden while it is on.",
           seenHere: true, preview: "Desktop icons fading under Stage Manager"),
        wm("Stage Manager", "StageManagerHideWidgets", "Hide Widgets in Stage Manager", "Desktop widgets stay hidden while it is on.",
           seenHere: true, preview: "Widgets fading under Stage Manager"),
        wm("Desktop", "StandardHideWidgets", "Hide Widgets on the Desktop", "Widgets hide when Stage Manager is off.",
           seenHere: true, preview: "Widgets fading from the desktop"),
        wm("Tiling", "EnableTilingByEdgeDrag", "Tile by Dragging to Edges", "Drop a window on a screen edge to tile it.",
           seenHere: false, fallback: .bool(true), preview: "A window snapping to the left half"),
        wm("Tiling", "EnableTopTilingByEdgeDrag", "Fill by Dragging to the Top", "Drop a window on the menu bar to fill the screen.",
           seenHere: false, fallback: .bool(true), preview: "A window filling the screen from the top edge"),
        wm("Tiling", "EnableTilingOptionAccelerator", "Tile Instantly with Option", "Hold Option while dragging to tile at once.",
           seenHere: false, fallback: .bool(true), preview: "Tile outlines appearing as Option is held"),
    ]

    // MARK: Lock Screen and screen saver

    static let lockScreenSettings: [PersonalSetting] = [
        PersonalSetting(.lockScreen, "Screen Saver", domain: "com.apple.screensaver", key: "idleTime", kind: .int, currentHost: true,
                        control: .choice([.init(.int(0), "Never"), .init(.int(60), "1 min"), .init(.int(120), "2 min"),
                                          .init(.int(300), "5 min"), .init(.int(600), "10 min"), .init(.int(1200), "20 min"),
                                          .init(.int(1800), "30 min"), .init(.int(3600), "1 hour")]),
                        title: "Start Screen Saver After", detail: "Idle time before the screen saver starts.", effect: .logout,
                        evidence: "ScreenSaver.framework and loginwindow __cstring idleTime (ByHost com.apple.screensaver)"
                            + unverified,
                        preview: "A countdown ring, then the screen saver"),
        PersonalSetting(.lockScreen, "Screen Saver", domain: "com.apple.screensaver", key: "showClock", kind: .bool, currentHost: true,
                        control: sysToggle(), title: "Clock Over Screen Saver", detail: "The time floats over the screen saver.",
                        effect: .relaunchApps,
                        evidence: "ScreenSaver.framework __cstring showClock; ByHost value on this Mac",
                        preview: "A clock drifting over the screen saver"),
        PersonalSetting(.lockScreen, "Screen Saver", domain: "com.apple.screensaver", key: "mainScreenOnly", kind: .bool,
                        currentHost: true, control: sysToggle(), title: "Main Display Only",
                        detail: "Other displays go black instead.", effect: .relaunchApps,
                        evidence: "ScreenSaver.framework __cstring mainScreenOnly" + unverified,
                        preview: "One screen with the saver, the other dark"),
        PersonalSetting(.lockScreen, "Lock Screen", domain: "com.apple.loginwindow", key: "ClockFontWeight", kind: .float,
                        control: .number(100...900, step: 10, unit: ""), title: "Clock Weight",
                        detail: "How bold the big lock screen clock is.", effect: .logout,
                        evidence: "LoginUIKit __cstring ClockFontWeight; this Mac stores 234.77 in com.apple.loginwindow",
                        preview: "The lock screen clock going from hairline to heavy",
                        caution: "The range is a guess from the stored value. Seen next time the screen locks, or after logging out."),
        PersonalSetting(.lockScreen, "Lock Screen", domain: "com.apple.loginwindow", key: "HideUserAvatarAndName", kind: .bool,
                        control: sysToggle(), title: "Hide Picture and Name",
                        detail: "The lock screen shows no avatar or name.", effect: .logout,
                        evidence: "LoginUIKit and loginwindow __cstring HideUserAvatarAndName" + unverified,
                        preview: "The lock screen with only the clock and password field",
                        caution: "Experimental. loginwindow may only honour this from managed preferences."),
        PersonalSetting(.lockScreen, "Logging Out", domain: "com.apple.loginwindow", key: "TALLogoutSavesState", kind: .bool,
                        control: sysToggle(), title: "Reopen Windows After Logging In",
                        detail: "The tick box in the log out and restart dialog starts ticked.", effect: .immediate,
                        evidence: "loginwindow __cstring TALLogoutSavesState; key present in this Mac's defaults",
                        preview: "The restart dialog with its box ticked"),
    ]
}
