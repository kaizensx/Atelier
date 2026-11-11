import DockCore
import Foundation

struct Tweak: Identifiable {
    enum Proof: String { case proved = "Seen working", reversible = "Reversed cleanly in a bulk test, effect not confirmed" }
    let area: Chapter
    let domain: String
    let process: String?
    let key: String
    let type: String
    let value: String
    let title: String
    let detail: String
    var proof = Proof.reversible
    /// Set when the tweak now lives in a PersonalCatalog chapter (Animations), so it shows
    /// there once and not in its old chapter too.
    var personal: PersonalArea?
    var id: String { domain + "." + key }

    /// The macOS releases that read this key, from the same audited table as the catalogue.
    var availability: PersonalOSRange { PersonalAvailability.range(domain: domain, key: key) }
    var isAvailableHere: Bool { availability.contains(major: PersonalAvailability.runningMajor) }
}

enum TweakCatalog {
    private static func dock(_ area: Chapter, _ key: String, _ type: String, _ value: String, _ title: String, _ detail: String, _ proof: Tweak.Proof = .reversible) -> Tweak {
        Tweak(area: area, domain: "com.apple.dock", process: "Dock", key: key, type: type, value: value, title: title, detail: detail, proof: proof)
    }

    private static func finder(_ key: String, _ title: String, _ detail: String, value: String = "true", proof: Tweak.Proof = .reversible) -> Tweak {
        Tweak(area: .finder, domain: "com.apple.finder", process: "Finder", key: key, type: "bool", value: value, title: title, detail: detail, proof: proof)
    }

    private static func window(_ key: String, _ title: String, _ detail: String) -> Tweak {
        Tweak(area: .windows, domain: "com.apple.WindowManager", process: nil, key: key, type: "bool", value: "true", title: title, detail: detail)
    }

    private static func global(_ area: Chapter, _ key: String, _ type: String, _ value: String, _ title: String, _ detail: String) -> Tweak {
        Tweak(area: area, domain: "NSGlobalDomain", process: nil, key: key, type: type, value: value, title: title, detail: detail + " Apps pick it up when reopened.")
    }

    private static let listed: [Tweak] = [
        // Dock
        dock(.dock, "genie-speed", "float", "0.25", "Genie Tempo", "Changes the speed of the minimise effect."),
        dock(.dock, "slow-motion-allowed", "bool", "true", "Slow Motion", "Hold Shift while minimising to slow it down."),
        dock(.dock, "autohide-delay", "float", "0", "Instant Dock", "No delay when the Dock reveals."),
        dock(.dock, "autohide-time-modifier", "float", "0.2", "Fast Hide", "Shortens the hide animation."),
        dock(.dock, "launchanim", "bool", "false", "No Opening Bounce", "Apps open without bouncing in the Dock."),
        dock(.dock, "no-bouncing", "bool", "true", "No Attention Bounce", "Apps stop bouncing to ask for you."),
        dock(.dock, "show-process-indicators", "bool", "false", "No Dots", "Hides the open app indicators.", .proved),
        dock(.dock, "scroll-to-open", "bool", "true", "Scroll to Open", "Scrolling on an item opens it."),
        dock(.dock, "show-recent-count", "int", "3", "Three Recents", "Limits recent apps to three."),
        dock(.dock, "mouse-over-hilite-stack", "bool", "true", "Stack Highlight", "Highlights the item under the pointer."),
        dock(.dock, "enable-spring-load-actions-on-all-items", "bool", "true", "Spring on All", "Dragging over any item opens it."),
        dock(.dock, "adaptive-glass", "bool", "true", "Adaptive Glass", "Internal Dock glass switch."),
        dock(.windows, "spring-to-expose", "bool", "false", "No Spring to Exposé", "Dragging no longer jumps to Exposé."),
        dock(.windows, "hilite-windows-in-expose", "bool", "false", "Plain Exposé", "Removes the window highlight."),
        dock(.windows, "show-space-bindings", "bool", "true", "Show Space Bindings", "Shows which Space an app belongs to."),
        // Windows
        window("EnableTiledWindowMargins", "Tiling Margins", "Adds gaps between tiled windows."),
        window("EnableStandardClickToShowDesktop", "Click Wallpaper for Desktop", "Clicking the wallpaper reveals the desktop."),
        window("StandardHideDesktopIcons", "Hide Desktop Icons", "Keeps the desktop clean outside Stage Manager."),
        window("AutoHide", "Hide Stage Strip", "Stage Manager's side strip hides itself."),
        Tweak(area: .windows, domain: "com.apple.WindowManager", process: nil, key: "TiledWindowSpacing", type: "float", value: "24",
              title: "Wide Tile Gaps", detail: "A bigger gap between tiled windows. Settings has no control for this."),
        window("EnableStageManagerHotKey", "Stage Manager Hotkey", "Control-Escape toggles Stage Manager."),
        Tweak(area: .windows, domain: "com.apple.WindowManager", process: nil, key: "HiddenStripPeekWidth", type: "float", value: "12",
              title: "Peeking Strip", detail: "A hidden Stage Manager strip stays slightly visible."),
        Tweak(area: .windows, domain: "com.apple.WindowManager", process: nil, key: "AnimationSpeed", type: "float", value: "1.6",
              title: "Faster Window Manager", detail: "Speeds up Stage Manager transitions."),
        global(.windows, "AppleEdgeResizeExteriorSize", "float", "10", "Easy Edge Resize", "A wider grab zone around window edges."),
        global(.windows, "AppleEdgeResizeCornerSize", "float", "20", "Easy Corner Resize", "A bigger grab zone at window corners."),
        global(.windows, "NSWindowShouldDragOnGesture", "bool", "true", "Drag from Anywhere", "Superseded by Move & Resize Anywhere in Windows, on the same keys. Turn this off."),
        global(.windows, "NSWindowResizeTime", "float", "0.05", "Instant Sheets", "Sheets and resizes finish faster."),
        global(.windows, "NSAutomaticWindowAnimationsEnabled", "bool", "false", "No Window Animations", "Removes open and close animations."),
        global(.windows, "AppleSpacesSwitchOnActivate", "bool", "false", "Stay in This Space", "Switching apps no longer jumps Spaces."),
        // Menu bar
        global(.menubar, "NSStatusItemSpacing", "float", "6", "Tight Menu Bar", "Packs menu bar icons closer. Takes effect after logging out."),
        global(.menubar, "NSStatusItemSelectionPadding", "float", "4", "Slim Highlights", "Narrower menu bar highlights. Takes effect after logging out."),
        Tweak(area: .menubar, domain: "com.apple.menuextra.clock", process: "ControlCenter", key: "ShowSeconds", type: "bool", value: "true",
              title: "Seconds on the Clock", detail: "The menu bar clock shows seconds."),
        Tweak(area: .menubar, domain: "com.apple.menuextra.clock", process: "ControlCenter", key: "IsAnalog", type: "bool", value: "true",
              title: "Analog Clock", detail: "A small analog face in the menu bar."),
        Tweak(area: .menubar, domain: "com.apple.menuextra.clock", process: "ControlCenter", key: "FlashDateSeparators", type: "bool", value: "true",
              title: "Blinking Colon", detail: "The time separators flash."),
        // Finder
        finder("ShowStatusBar", "Status Bar", "Shows item count and free space.", proof: .reversible),
        finder("ShowPathbar", "Path Bar", "Shows the path at the bottom."),
        finder("ShowPreviewPane", "Preview Pane", "Shows the preview pane."),
        finder("_FXShowPosixPathInTitle", "Full Path in Title", "The title shows the whole path.", proof: .reversible),
        finder("_FXSortFoldersFirst", "Folders First", "Folders on top when sorting by name.", proof: .reversible),
        finder("FXEnableExtensionChangeWarning", "No Extension Warning", "Rename extensions without confirming.", value: "false", proof: .reversible),
        finder("AppleShowAllFiles", "Show Hidden Files", "Shows dotfiles everywhere."),
        finder("QuitMenuItem", "Quit Finder", "Adds Quit to the Finder menu."),
        finder("DisableAllAnimations", "No Finder Animations", "Finder stops animating."),
        finder("ShowRecentTags", "Hide Recent Tags", "Removes tags from the sidebar.", value: "false"),
        // Capture
        Tweak(area: .capture, domain: "com.apple.screencapture", process: "SystemUIServer", key: "disable-shadow", type: "bool", value: "true",
              title: "No Window Shadow", detail: "Window captures come out without a shadow.", proof: .reversible),
        Tweak(area: .capture, domain: "com.apple.screencapture", process: "SystemUIServer", key: "show-thumbnail", type: "bool", value: "false",
              title: "No Floating Thumbnail", detail: "Screenshots save immediately."),
        Tweak(area: .capture, domain: "com.apple.screencapture", process: "SystemUIServer", key: "include-date", type: "bool", value: "false",
              title: "No Date in Name", detail: "Shorter screenshot file names."),
        // Input
        global(.input, "NSScrollAnimationEnabled", "bool", "false", "Direct Scrolling", "Removes smooth scrolling."),
        global(.input, "NSUseAnimatedFocusRing", "bool", "false", "Plain Focus Ring", "Focus rings stop animating."),
        global(.input, "NSToolbarTitleViewRolloverDelay", "float", "0", "Instant Toolbar Titles", "Title hover responds at once."),
        global(.input, "QLPanelAnimationDuration", "float", "0", "Instant Quick Look", "Quick Look opens with no animation."),
        global(.input, "NSNavPanelExpandedStateForSaveMode", "bool", "true", "Expanded Save Panels", "Save panels open expanded."),
        global(.input, "NSDocumentSaveNewDocumentsToCloud", "bool", "false", "Save to Disk", "New documents default to this Mac."),
        // Appearance
        global(.appearance, "AppleReduceDesktopTinting", "bool", "true", "No Desktop Tinting", "Windows stop picking up wallpaper colour."),
        global(.appearance, "AppleShowScrollBars", "string", "Always", "Always Show Scroll Bars", "Scroll bars never hide."),
        global(.appearance, "AppleWindowTabbingMode", "string", "always", "Always Use Tabs", "New documents open as tabs."),
        global(.appearance, "AppleActionOnDoubleClick", "string", "None", "Inert Title Bars", "Double-clicking a title bar does nothing."),
    ]

    /// Keys that moved to the Animations chapter. One home each, never two.
    private static let animationKeys: Set<String> = ["NSAutomaticWindowAnimationsEnabled", "NSWindowResizeTime", "NSScrollAnimationEnabled", "NSUseAnimatedFocusRing", "NSToolbarTitleViewRolloverDelay", "QLPanelAnimationDuration", "DisableAllAnimations"]

    /// Move & Resize Anywhere (Windows) owns the ⌃⌘ drag. macOS's own version stays listed only
    /// while it is set, so whoever turned it on can turn it off; it is never offered anew.
    private static let retiredUnlessSet: Set<String> = ["NSWindowShouldDragOnGesture"]

    static let all: [Tweak] = listed.filter { tweak in
        guard retiredUnlessSet.contains(tweak.key) else { return true }
        return CFPreferencesCopyAppValue(tweak.key as CFString, kCFPreferencesAnyApplication) as? Bool == true
    }.map { tweak in
        var tweak = tweak
        if animationKeys.contains(tweak.key) { tweak.personal = .animations }
        return tweak
    }

    /// The tweaks the running macOS reads. A key outside its release range is never offered,
    /// so it is never written: `unsupported(for:)` lists those for the "Not on this macOS" group.
    static func tweaks(for area: Chapter) -> [Tweak] { all.filter { $0.area == area && $0.personal == nil && $0.isAvailableHere } }

    static func tweaks(personal area: PersonalArea) -> [Tweak] { all.filter { $0.personal == area && $0.isAvailableHere } }

    static func unsupported(for area: Chapter) -> [Tweak] { all.filter { $0.area == area && $0.personal == nil && !$0.isAvailableHere } }

    static func unsupported(personal area: PersonalArea) -> [Tweak] { all.filter { $0.personal == area && !$0.isAvailableHere } }
}
