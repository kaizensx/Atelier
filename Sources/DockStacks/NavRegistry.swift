import DockCore
import SwiftUI

// MARK: - How to add a place to the Studio
//
// Every place in the sidebar, the ⌘F search and the Command palette comes from `NavRegistry.items`.
// Adding one is one line in `NavRegistry.listed`, in the section it belongs to:
//
//   A PersonalCatalog area (a new `PersonalArea` case with its settings):
//       .personal(.spotlight, "Spotlight", symbol: "magnifyingglass", in: .system, keywords: ["search", "results"]),
//
//   Any other chapter, with its own view:
//       NavItem(Chapter("safari"), "Safari", symbol: "safari", in: .apps, keywords: ["browser"]) { _ in SafariChapter() },
//
// That is all: the sidebar row, the panel, search over the item's title and keywords, and search
// over every catalogue setting of the area (it jumps to the row and lights it up) follow from the
// entry. A `PersonalArea` with no entry still appears, under System with its raw name, so nothing
// is ever unreachable; give it an entry to place and name it properly.
//
// Optional, outside the registry: a camera in `Chapter.camera` (Stage.swift) when the stage should
// zoom somewhere for it, and `Chapter.hasPanel` for a place that lives on the stage only.
// One home per setting: if a control already lives in another place, link to it there instead.

/// The sidebar's sections, top to bottom.
enum NavSection: String, CaseIterable, Identifiable, Sendable {
    case mac = "Your Mac"
    case desktop = "Desktop"
    case dock = "Dock & Launch"
    case menuBar = "Menu Bar"
    case windows = "Windows"
    case files = "Finder & Files"
    case apps = "Apps"
    case system = "System"
    case tools = "Tools"
    case history = "History"
    case atelier = "Atelier"

    var id: String { rawValue }
}

/// One place in the Studio: a sidebar row and the panel it opens.
struct NavItem: Identifiable {
    let chapter: Chapter
    let title: String
    let symbol: String
    let section: NavSection
    /// Extra words search should find it by: what it is called elsewhere, what it contains.
    let keywords: [String]
    /// The PersonalCatalog area whose settings live in this panel, so search can jump to them.
    let area: PersonalArea?
    /// Only these sections of `area` (an item per app splits one area into several places).
    let areaSections: [String]?
    /// Whether this place can do anything on the running Mac. `.unavailable` dims its sidebar row
    /// and says why; the place still opens, because its cards explain what is missing and how to
    /// get it, and search must never lead to nothing. Default: every place works everywhere.
    let availability: @MainActor () -> FeatureAvailability
    let content: @MainActor (ManagerModel) -> AnyView

    var id: String { chapter.rawValue }

    init<Content: View>(_ chapter: Chapter, _ title: String, symbol: String, in section: NavSection,
                        keywords: [String] = [], area: PersonalArea? = nil, areaSections: [String]? = nil,
                        availability: @escaping @MainActor () -> FeatureAvailability = { .available },
                        @ViewBuilder content: @escaping @MainActor (ManagerModel) -> Content) {
        self.chapter = chapter
        self.title = title
        self.symbol = symbol
        self.section = section
        self.keywords = keywords
        self.area = area
        self.areaSections = areaSections
        self.availability = availability
        self.content = { AnyView(content($0)) }
    }

    /// A PersonalCatalog area as a place: its intro, its bespoke cards and its settings by section.
    static func personal(_ area: PersonalArea, _ title: String, symbol: String, in section: NavSection,
                         keywords: [String] = []) -> NavItem {
        NavItem(Chapter(area.rawValue), title, symbol: symbol, in: section, keywords: keywords, area: area) { model in
            PersonalChapter(area: area, model: model)
        }
    }
}

@MainActor
enum NavRegistry {
    /// Every place, in sidebar order within each section.
    static let items: [NavItem] = {
        var list = listed
        // An area nobody placed yet still shows, so a new catalogue is never unreachable.
        // The Windows area is empty: its rows are Mission Control's, inside Windows & Spaces.
        // Per-app settings are not offered: Atelier keeps to what applies everywhere, and
        // "All Apps" lives in Every App.
        let placed = Set(list.compactMap(\.area)).union([.windows, .apps])
        for area in PersonalArea.allCases where !placed.contains(area) {
            list.append(.personal(area, area.rawValue.capitalized, symbol: "slider.horizontal.3", in: .system))
        }
        // One home per place: a second entry with the same id would never open.
        assert(Set(list.map(\.id)).count == list.count, "NavRegistry: two places share an id")
        return list
    }()

    private static let listed: [NavItem] = [
        // Your Mac
        NavItem(.home, "Home", symbol: "house", in: .mac, keywords: ["overview", "start", "your mac"]) { _ in EmptyView() },
        NavItem(.looks, "Looks", symbol: "sparkles", in: .mac, keywords: ["preset", "style", "one click", "schedule", "day", "night"]) {
            LooksGalleryChapter(model: $0)
        },
        NavItem(Chapter("mods"), "Mods", symbol: "shippingbox", in: .mac,
                keywords: ["catalog", "marketplace", "community", "gallery", "browse", "download", "install", "plugins", "themes", "updates", "windhawk", "native",
                           "theme", "plugin", "import", "export", "json", "library", "create theme", "themes & plugins",
                           "plugin settings", "load plugin folder", "development", "safe mode",
                           "hooks", "palette provider", "menu bar item", "live activity", "plugin window",
                           "pack", "packs", "icon pack", "sound pack", "shader pack", "layout pack", "effect pack", "look pack",
                           "collections", "featured", "author", "rollback", "roll back", "version history", "setup", "ateliersetup",
                           "signed", "installs", "likes", "discussion"]) {
            ModsChapter(model: $0)
        },
        // Desktop
        NavItem(.wallpaper, "Wallpaper", symbol: "photo", in: .desktop, keywords: ["background", "picture", "living", "generated", "library"]) { model in
            // The hero (generated, painted by the GPU) first; real photographs after it.
            WallpaperStudioChapter(model: model)
            WallpaperLibraryCard()
        },
        NavItem(.livewall, "Live Wallpaper", symbol: "play.rectangle", in: .desktop, keywords: ["animated", "video", "moving", "rain", "shader"]) { _ in
            LiveWallpaperChapter()
        },
        NavItem(.widgets, "Widgets", symbol: "square.grid.2x2", in: .desktop,
                keywords: ["clock", "weather", "notes", "vitals", "memory", "battery", "disk", "launcher", "calendar", "reminders",
                           "checklist", "habits", "photo", "countdown", "pomodoro", "stopwatch", "clipboard"]) { _ in
            WidgetsChapter()
        },
        NavItem(.effects, "Effects", symbol: "wand.and.stars", in: .desktop,
                keywords: ["focus light", "vignette", "grain", "pixel grid", "keystrokes", "ripples", "notch shelf",
                           "clean desktop", "caffeinate", "keep awake", "menu bar hider", "ambient", "glow"]) { _ in
            DesktopPlusEffectsChapter()
        },
        // Dock & Launch
        NavItem(.dock, "Dock", symbol: "dock.rectangle", in: .dock,
                keywords: ["atelier dock", "macos dock", "size", "magnification", "auto-hide", "position", "spacer", "tiles",
                           "dock peek", "window previews", "hover", "thumbnails", "swipe", "pinch", "minimise", "quit", "dockdoor",
                           "bounce", "opening bounce", "launch bounce", "attention bounce", "launch effect", "vitals tile"]) { model in
            DockHubChapter(model: model)
            SystemDockPeekCard()
            DockGlowCard()
        },
        NavItem(.stacks, "Stacks", symbol: "square.stack.3d.up", in: .dock, keywords: ["folder", "bubble", "live stack", "smart", "plugin stack", "from plugins"]) {
            DockHubStacksChapter(model: $0)
        },
        NavItem(.orbit, "Orbit", symbol: "circle.hexagongrid", in: .dock, keywords: ["launcher", "launchpad", "apps", "ring"]) { _ in
            OrbitChapter()
        },
        NavItem(.corners, "Hot Corners", symbol: "rectangle.inset.topleft.filled", in: .dock,
                keywords: ["corners", "screen corner", "action"], area: .corners) {
            CornersChapter(model: $0)
        },
        // Menu Bar & Control Center
        NavItem(.menubar, "Menu Bar", symbol: "menubar.rectangle", in: .menuBar, keywords: ["skin", "clock", "status items", "day line", "spaces", "desktops", "calendar", "date", "itsycal", "week numbers", "instant spaces", "switch desktop", "send window", "move window to desktop", "temperature", "thermals", "fans", "fan speed", "watts", "power", "sensors", "stats", "istat", "fan control", "fan curve", "macs fan control", "max fans", "silent", "rpm"]) { model in
            // Three heroes first: what a stock menu bar cannot show or do.
            SectionHeader("Live in the menu bar", symbol: "menubar.rectangle",
                          detail: "Readings and shortcuts macOS keeps to itself.", hue: DS.Spectrum.surfaces)
            ThermalsCard()
            FanControlCard()
            InstantSpacesHero()
            MenuCalendarCard()
            SectionHeader("Spaces", symbol: "square.split.2x1", hue: DS.Spectrum.surfaces)
            SpacesCard()
            SectionHeader("Skin", symbol: "paintbrush", hue: DS.Spectrum.surfaces)
            MenuBarStudioChapter(model: model)
            DayLineCard()
        },
        // Windows
        .personal(.controlCenter, "Control Center", symbol: "switch.2", in: .menuBar,
                  keywords: ["battery percentage", "wifi", "bluetooth", "sound", "now playing", "focus", "clock", "24 hour", "hide menu bar"]),
        NavItem(.engine, "Window Engine", symbol: "rectangle.split.2x1", in: .windows,
                keywords: ["tiling", "snap", "layouts", "hot keys", "shuffle", "workspaces", "glow", "borders", "outline", "dim", "hazeover", "inactive", "shade", "focus", "move", "resize", "drag anywhere", "easy move", "modifier drag", "focus follows mouse", "autoraise", "window switcher", "alt tab", "option tab", "switch windows",
                           "swish", "title bar", "titlebar gestures", "two finger swipe", "swipe to tile", "pinch to close", "pinch window", "trackpad window"]) { _ in
            WindowEngineChapter()
            TitleBarGesturesCard()
        },
        // What only the Dock can do, through the Dock Bridge (needs SIP partly off).
        NavItem(Chapter("beyondsip"), "Beyond SIP", symbol: "lock.open.trianglebadge.exclamationmark", in: .windows,
                keywords: ["opacity", "transparent window", "always on top", "pin window", "sticky", "all spaces",
                           "picture in picture", "pip", "shadow", "create space", "yabai", "scripting addition",
                           "injection", "sip"]) { _ in
            BeyondSIPChapter()
        },
        // One place for windows, Spaces, Mission Control and Stage Manager.
        NavItem(.windows, "Windows & Spaces", symbol: "macwindow.on.rectangle", in: .windows,
                keywords: ["mission control", "spaces", "stage manager", "exposé", "resize", "tiling", "app switcher", "cmd tab"],
                area: .missionControl) { model in
            TweakList(model: model, tweaks: TweakCatalog.tweaks(for: .windows))
            SettingsCompatHiddenGroup(items: TweakCatalog.unsupported(for: .windows).map(\.compatHiddenItem))
            // One chapter: Mission Control, Spaces, the app switcher, Stage Manager and tiling.
            PersonalChapter(area: .missionControl, model: model)
        },
        // Finder & Files
        NavItem(.finder, "Finder", symbol: "folder", in: .files, keywords: ["path bar", "hidden files", "desktop icons", "sidebar"], area: .finder) { model in
            // Finder's own preferences by section first, its hidden switches after.
            PersonalChapter(area: .finder, model: model)
            SectionHeader("Hidden switches", symbol: "eye.slash",
                          detail: "Finder switches macOS keeps out of its settings.", hue: DS.Spectrum.input)
            TweakList(model: model, tweaks: TweakCatalog.tweaks(for: .finder))
            SettingsCompatHiddenGroup(items: TweakCatalog.unsupported(for: .finder).map(\.compatHiddenItem))
        },
        NavItem(.folders, "Folder & App Icons", symbol: "app.badge", in: .files,
                keywords: ["icon", "folder colour", "emoji", "macosicons", "custom icon"], area: .folders) {
            PersonalChapter(area: .folders, model: $0)
        },
        // System
        NavItem(.appearance, "Display & Appearance", symbol: "circle.lefthalf.filled", in: .system,
                keywords: ["night shift", "true tone", "warmth", "icon tint", "dark", "clear", "tinted", "scroll bars", "tabs", "schedule", "light apps", "rounded corners", "screen corners", "extra dim", "darker", "brightness", "night", "below black", "xdr", "boost", "brighter", "nits", "hdr", "candlelight", "candle", "warmer", "kelvin", "f.lux", "night tint", "warm schedule", "hud", "osd", "volume overlay", "notch", "island", "keyboard backlight", "key light", "idle", "notch-free", "hide notch", "16:10", "resolution", "display mode", "refresh rate", "hz", "120hz", "60hz", "scaled", "low resolution", "hidpi", "retina", "virtual display", "dummy", "headless", "betterdummy", "deskpad", "mirror", "ddc", "ddc/ci", "external monitor", "monitor brightness", "contrast", "monitor volume", "input source", "monitorcontrol", "lunar"]) { model in
            // Heroes first, by family: Light (amber), then Surfaces (sky). Stock switches follow.
            LightCards()
            // Night Tint moved here from Effects: every way to warm the screen in one place.
            NightTintCard()
            ExternalMonitorsCard()
            SectionHeader("Surfaces", symbol: "rectangle.on.rectangle",
                          detail: "What sits on top of the screen: the overlay, the key light, the corners.", hue: DS.Spectrum.surfaces)
            AtelierHUDCard()
            KeyboardLightCard()
            ScreenCornersCard()
            DisplayCards()
            DisplayModesCards()
            SectionHeader("Appearance", symbol: "circle.lefthalf.filled")
            AppearanceScheduleCard()
            LightAppsCard()
            IconStudio(model: model)
            TweakList(model: model, tweaks: TweakCatalog.tweaks(for: .appearance))
            SettingsCompatHiddenGroup(items: TweakCatalog.unsupported(for: .appearance).map(\.compatHiddenItem))
        },
        NavItem(Chapter(PersonalArea.input.rawValue), "Cursor & Input", symbol: "cursorarrow", in: .system,
                keywords: ["pointer", "keyboard", "trackpad", "typing", "remap", "mouse", "scroll direction", "wheel", "reverse", "natural", "smooth scrolling", "mos", "hyper", "caps lock", "escape", "acceleration", "linear", "pointer speed", "tracking speed", "linearmouse", "side buttons", "back button", "dpi", "gestures", "middle click", "three finger tap", "force touch", "haptic", "haptics", "edge swipe"],
                area: .input) { model in
            // What a stock Mac cannot do leads; macOS's own switches follow.
            TrackpadGesturesCard()
            HyperKeyCard()
            MousePrecisionCard()
            WheelDirectionCard()
            HapticsCard()
            MouseButtonsCard()
            // PersonalChapter opens with its own intro line, so the header carries no detail.
            SectionHeader("macOS Settings", symbol: "slider.horizontal.3", hue: DS.Ink.secondary)
            PersonalChapter(area: .input, model: model)
        },
        NavItem(Chapter(PersonalArea.sounds.rawValue), "Sounds", symbol: "speaker.wave.2", in: .system,
                keywords: ["alert", "beep", "volume feedback", "typing", "keyboard sound", "custom sound",
                           "mixer", "sound mixer", "per-app volume", "app volume", "volume boost", "mute app", "output device",
                           "audio routing", "airpods", "equalizer", "eq", "bass", "treble"], area: .sounds) { model in
            SoundMixerCard()
            TypingSoundsCard()
            SectionHeader("macOS Settings", symbol: "slider.horizontal.3", hue: DS.Ink.secondary)
            PersonalChapter(area: .sounds, model: model)
            UserSoundsCard()
        },
        .personal(.animations, "Animations", symbol: "slowmo", in: .system, keywords: ["motion", "speed", "genie", "minimise"]),
        .personal(.spotlight, "Spotlight", symbol: "magnifyingglass", in: .system, keywords: ["search", "results", "animation"]),
        .personal(.lockScreen, "Lock Screen & Screen Saver", symbol: "lock.display", in: .system, keywords: ["login", "screen saver", "clock", "avatar"]),
        .personal(.accessibility, "Accessibility Visuals", symbol: "accessibility", in: .system, keywords: ["reduce motion", "transparency", "contrast", "zoom", "focus ring"]),
        NavItem(Chapter("appKit"), "Every App", symbol: "macwindow", in: .system,
                keywords: ["caret", "cursor blink", "font smoothing", "highlight colour", "scroll bar", "text", "app nap",
                           "login items", "reopen windows", "open at login", "quit", "cmd q", "hold to quit"], area: .appKit) { model in
            QuitGuardCard()
            SectionHeader("macOS settings", symbol: "macwindow")
            PersonalChapter(area: .appKit, model: model)
            // What every app shares: reopening windows, keeping changes, what opens at login.
            PersonalChapter(area: .apps, model: model, sections: ["All Apps"], embedded: true)
        },
        .personal(.quickLook, "Quick Look", symbol: "eye", in: .system, keywords: ["preview", "spacebar"]),
        // Tools
        NavItem(.toolbox, "Toolbox", symbol: "wrench.and.screwdriver", in: .tools,
                keywords: ["text grab", "ocr", "clipboard", "quick look", "recorder", "rename", "convert", "timer", "focus"]) { _ in
            ToolboxChapter()
        },
        NavItem(.capture, "Capture", symbol: "camera.viewfinder", in: .tools, keywords: ["screenshot", "screen recording", "format"], area: .capture) { model in
            Text("Where screenshots go, what they are called and how they look.")
                .font(DS.body).foregroundStyle(DS.Ink.secondary).fixedSize(horizontal: false, vertical: true)
            // One home per tool: the recorder lives in Toolbox, this links to it.
            ToolsCaptureLink()
            PersonalChapter(area: .capture, model: model)
            SectionHeader("Hidden switches", symbol: "eye.slash", hue: DS.Spectrum.sensors)
            TweakList(model: model, tweaks: TweakCatalog.tweaks(for: .capture))
            SettingsCompatHiddenGroup(items: TweakCatalog.unsupported(for: .capture).map(\.compatHiddenItem))
        },
        // History
        NavItem(.scenes, "Scenes", symbol: "theatermasks", in: .history, keywords: ["profile", "save dock", "schedule"]) {
            ScenesChapter(model: $0)
        },
        NavItem(.time, "Timeline", symbol: "clock.arrow.circlepath", in: .history, keywords: ["time", "undo", "go back", "history", "snapshot"]) { _ in
            EmptyView()
        },
        // Atelier
        NavItem(.system, "Settings", symbol: "gearshape", in: .atelier,
                keywords: ["preferences", "permissions", "accessibility", "screen recording", "privacy", "full disk access",
                           "welcome", "studio look", "login", "clipboard history", "shortcuts", "uninstall", "remove everything",
                           "update", "updates", "version", "beta", "github", "release"]) {
            UpdatesCard()
            SystemChapter(model: $0)
        },
    ]

    /// Places that were folded into others, by the place that holds them now.
    private static let aliases: [Chapter: Chapter] = [
        .owndock: .dock, .unique: .effects, .lab: .home, .vitals: .widgets, .display: .appearance, .themes: Chapter("mods"),
    ]

    private static let byChapter: [Chapter: NavItem] = Dictionary(items.map { ($0.chapter, $0) }, uniquingKeysWith: { first, _ in first })

    static func item(for chapter: Chapter) -> NavItem? { byChapter[chapter] }

    /// The registered place an id opens: itself, the place it was folded into, or Home.
    static func resolve(_ chapter: Chapter) -> Chapter {
        if byChapter[chapter] != nil { return chapter }
        return aliases[chapter] ?? .home
    }

    static func items(in section: NavSection) -> [NavItem] { items.filter { $0.section == section } }

    /// The place a catalogue setting lives in.
    static func chapter(for setting: PersonalSetting) -> Chapter? {
        items.first { $0.area == setting.area && ($0.areaSections?.contains(setting.section) ?? true) }?.chapter
    }

    /// The place a tweak lives in: its PersonalCatalog area when it moved to one, else its own chapter.
    static func chapter(for tweak: Tweak) -> Chapter {
        if let personal = tweak.personal, let item = items.first(where: { $0.area == personal }) { return item.chapter }
        return resolve(tweak.area)
    }
}
