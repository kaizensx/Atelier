import Foundation

// MARK: - Apps

/// One of Apple's apps the catalogue has settings for. Its `name` is both the section
/// title in the `.apps` area and the process name the Relaunch button looks for.
public struct PersonalApp: Sendable, Identifiable, Equatable, Hashable {
    public let name: String
    public let bundleID: String
    /// Where the app is installed. Apple's own apps sit on the sealed system volume.
    public let path: String
    public let symbol: String
    public var id: String { bundleID }

    public init(_ name: String, _ bundleID: String, path: String, symbol: String) {
        self.name = name; self.bundleID = bundleID; self.path = path; self.symbol = symbol
    }
}

/// How the keys below were found. Every one is a literal in the binary that reads it.
/// - REA (Hopper) on TextEdit's binary: all 31 TextEdit keys matched.
/// - `strings` on each app's executables and embedded frameworks, where REA timed out or was
///   not needed. Exact-line matches only.
/// - The dyld shared cache, for Safari, whose code lives in Safari.framework there.
/// Values marked "set on this Mac" were read back with a read-only `defaults read`.
/// Sandboxed apps were sorted with `codesign -d --entitlements`: an app with a
/// shared-preference read-write exception for its own domain keeps it in ~/Library/Preferences
/// (Calendar, Freeform, Photo Booth, App Store); the rest keep it in their container.
extension PersonalCatalog {
    public static let apps: [PersonalApp] = [
        PersonalApp("Safari", "com.apple.Safari", path: "/Applications/Safari.app", symbol: "safari"),
        PersonalApp("Mail", "com.apple.mail", path: "/System/Applications/Mail.app", symbol: "envelope"),
        PersonalApp("Music", "com.apple.Music", path: "/System/Applications/Music.app", symbol: "music.note"),
        PersonalApp("TV", "com.apple.TV", path: "/System/Applications/TV.app", symbol: "tv"),
        PersonalApp("Photos", "com.apple.Photos", path: "/System/Applications/Photos.app", symbol: "photo.on.rectangle"),
        PersonalApp("Preview", "com.apple.Preview", path: "/System/Applications/Preview.app", symbol: "eye"),
        PersonalApp("QuickTime Player", "com.apple.QuickTimePlayerX", path: "/System/Applications/QuickTime Player.app",
                    symbol: "play.rectangle"),
        PersonalApp("TextEdit", "com.apple.TextEdit", path: "/System/Applications/TextEdit.app", symbol: "doc.text"),
        PersonalApp("Calendar", "com.apple.iCal", path: "/System/Applications/Calendar.app", symbol: "calendar"),
        PersonalApp("Contacts", "com.apple.AddressBook", path: "/System/Applications/Contacts.app", symbol: "person.crop.circle"),
        PersonalApp("Stickies", "com.apple.Stickies", path: "/System/Applications/Stickies.app", symbol: "note.text"),
        PersonalApp("Freeform", "com.apple.freeform", path: "/System/Applications/Freeform.app", symbol: "scribble.variable"),
        PersonalApp("Books", "com.apple.iBooksX", path: "/System/Applications/Books.app", symbol: "book"),
        PersonalApp("Maps", "com.apple.Maps", path: "/System/Applications/Maps.app", symbol: "map"),
        PersonalApp("Photo Booth", "com.apple.PhotoBooth", path: "/System/Applications/Photo Booth.app", symbol: "camera"),
        PersonalApp("App Store", "com.apple.AppStore", path: "/System/Applications/App Store.app", symbol: "bag"),
        PersonalApp("Tips", "com.apple.helpviewer", path: "/System/Applications/Tips.app", symbol: "questionmark.circle"),
        PersonalApp("Terminal", "com.apple.Terminal", path: "/System/Applications/Utilities/Terminal.app", symbol: "terminal"),
        PersonalApp("Activity Monitor", "com.apple.ActivityMonitor", path: "/System/Applications/Utilities/Activity Monitor.app",
                    symbol: "waveform.path.ecg"),
        PersonalApp("Disk Utility", "com.apple.DiskUtility", path: "/System/Applications/Utilities/Disk Utility.app",
                    symbol: "internaldrive"),
        PersonalApp("Script Editor", "com.apple.ScriptEditor2", path: "/System/Applications/Utilities/Script Editor.app",
                    symbol: "applescript"),
        PersonalApp("Keychain Access", "com.apple.keychainaccess",
                    path: "/System/Library/CoreServices/Applications/Keychain Access.app", symbol: "key"),
        PersonalApp("System Information", "com.apple.SystemProfiler",
                    path: "/System/Applications/Utilities/System Information.app", symbol: "info.circle"),
        PersonalApp("Archive Utility", "com.apple.archiveutility",
                    path: "/System/Library/CoreServices/Applications/Archive Utility.app", symbol: "archivebox"),
        PersonalApp("Xcode", "com.apple.dt.Xcode", path: "/Applications/Xcode.app", symbol: "hammer"),
    ]

    public static func app(named name: String) -> PersonalApp? { apps.first { $0.name == name } }

    /// The new per-app settings. The handful in `appSettings` stay where they were.
    static let appCatalogue: [PersonalSetting] = safariSettings + mailSettings + musicSettings + tvSettings
        + photosSettings + previewSettings + quickTimeSettings + textEditSettings + calendarSettings + contactsSettings
        + stickiesSettings + freeformSettings + booksSettings + mapsSettings + photoBoothSettings + appStoreSettings
        + tipsSettings + terminalSettings + activityMonitorSettings + diskUtilitySettings + scriptEditorSettings
        + keychainSettings + systemInformationSettings + archiveUtilitySettings + xcodeSettings

    // MARK: Building blocks

    fileprivate static let cache = "dyld shared cache string"
    fileprivate static func strings(_ app: String) -> String { "strings: \(app) binary" }
    fileprivate static let fda = "Sandboxed: needs Full Disk Access for Atelier."

    fileprivate static func toggle(_ on: Bool = true) -> PersonalControl { .toggle(on: .bool(on), off: .bool(!on)) }

    fileprivate static func choices(_ pairs: [(PersonalValue, String)]) -> PersonalControl {
        .choice(pairs.map { PersonalOption($0.0, $0.1) })
    }

    fileprivate static func experimentalNote(_ app: String) -> String {
        "Experimental: found in \(app)'s code, not in its settings. Apple may ignore it on public builds."
    }

    /// One app setting. Effect is always "read when the app opens", with a Relaunch button.
    fileprivate static func setting(_ app: String, _ domain: String, _ key: String, kind: PersonalKind = .bool,
                                    control: PersonalControl? = nil, storage: PersonalStorage, _ title: String,
                                    _ detail: String, fallback: PersonalValue? = nil, evidence: String,
                                    preview: String, experimental: Bool = false, caution: String? = nil) -> PersonalSetting {
        let warning = experimental ? [experimentalNote(app), caution].compactMap { $0 }.joined(separator: " ") : caution
        return PersonalSetting(.apps, app, domain: domain, key: key, kind: kind, control: control ?? toggle(),
                               title: title, detail: detail, effect: .relaunch(app), fallback: fallback,
                               evidence: evidence, preview: preview, caution: warning, storage: storage,
                               experimental: experimental)
    }

    // MARK: Safari

    private static func safari(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                               _ title: String, _ detail: String, fallback: PersonalValue? = nil, preview: String,
                               experimental: Bool = false, caution: String? = nil) -> PersonalSetting {
        setting("Safari", "com.apple.Safari", key, kind: kind, control: control, storage: .container("com.apple.Safari"),
                title, detail, fallback: fallback, evidence: cache + " (Safari.framework)", preview: preview,
                experimental: experimental, caution: caution)
    }

    static let safariSettings: [PersonalSetting] = [
        safari("IncludeDevelopMenu", "Develop Menu", "The Develop menu with the Web Inspector and user agents.",
               fallback: .bool(false), preview: "Safari's menu bar gaining Develop"),
        safari("WebKitDeveloperExtras", "Inspect Element", "\"Inspect Element\" in every page's right-click menu.",
               fallback: .bool(false), preview: "A context menu with Inspect Element"),
        safari("ShowFullURLInSmartSearchField", "Full Address", "The address field shows the whole URL, not just the site.",
               fallback: .bool(false), preview: "apple.com growing into https://www.apple.com/mac/"),
        safari("ShowOverlayStatusBar", "Status Bar", "Hovering a link shows where it goes at the window's bottom.",
               fallback: .bool(false), preview: "A link URL appearing in the bottom-left corner"),
        safari("ShowFavoritesBar-v2", "Favourites Bar", "The bar of bookmarks under the toolbar.",
               preview: "A row of bookmarks under the address field"),
        safari("ShowStandaloneTabBar", "Separate Tab Bar", "Tabs get their own row under the address field.",
               preview: "Tabs moving out of the toolbar into their own row"),
        safari("AutoOpenSafeDownloads", "Open Safe Downloads", "Opens pictures, PDFs and archives after they download.",
               fallback: .bool(true), preview: "A zip unpacking itself after download"),
        safari("CommandClickMakesTabs", "⌘-click Opens a Tab", "Off opens ⌘-clicked links in a new window.",
               fallback: .bool(true), preview: "A ⌘-clicked link landing in a new tab"),
        safari("OpenNewTabsInFront", "New Tabs in Front", "Switch to a tab as soon as it opens.", fallback: .bool(false),
               preview: "A new tab taking focus"),
        safari("AlwaysRestoreSessionAtLaunch", "Reopen Last Session", "Safari opens with every window from last time.",
               fallback: .bool(false), preview: "Safari reopening with yesterday's tabs"),
        safari("ExcludePrivateWindowWhenRestoringSessionAtLaunch", "Skip Private Windows",
               "Private windows are left out when the last session comes back.", preview: "A private window not coming back"),
        safari("UniversalSearchEnabled", "Safari Suggestions", "Suggestions from Apple as you type in the address field.",
               fallback: .bool(true), preview: "Suggestion rows under the address field"),
        safari("SuppressSearchSuggestions", "No Search Engine Suggestions", "Stop asking the search engine for suggestions.",
               fallback: .bool(false), preview: "The suggestion list emptying"),
        safari("PreloadTopHit", "Preload Top Hit", "Loads the best match in the background while you type.",
               fallback: .bool(true), preview: "A page loading before Return is pressed"),
        safari("WebsiteSpecificSearchEnabled", "Quick Website Search", "Type a site's name and a word to search that site.",
               fallback: .bool(true), preview: "\"wiki swift\" searching Wikipedia"),
        safari("ShowFavoritesUnderSmartSearchField", "Favourites Under Address Field",
               "Clicking the address field shows your favourites.", preview: "A grid of favourites under the field"),
        safari("ShowSidebarInNewWindows", "Sidebar in New Windows", "New windows open with the sidebar showing.",
               preview: "A new Safari window with its sidebar"),
        safari("WarnAboutFraudulentWebsites", "Fraudulent Site Warning", "Warn before opening a suspected phishing site.",
               fallback: .bool(true), preview: "The red deceptive website warning",
               caution: "Turning this off removes a safety check."),
        safari("HistoryAgeInDaysLimit", kind: .int,
               control: choices([(.int(1), "1 Day"), (.int(7), "1 Week"), (.int(14), "2 Weeks"), (.int(31), "1 Month"),
                                 (.int(365), "1 Year"), (.int(365_000), "Never")]),
               "Remove History After", "How long Safari keeps visited pages.", preview: "Old history days fading out"),
        safari("DownloadsClearingPolicy", kind: .int,
               control: choices([(.int(0), "Manually"), (.int(1), "When Safari Quits"), (.int(2), "When Downloaded"),
                                 (.int(3), "After a Day")]),
               "Clear Downloads List", "When finished downloads leave the list.", preview: "The downloads popover emptying"),
        safari("IncludeInternalDebugMenu", "Debug Menu",
               "Safari's hidden Debug menu: layout borders, caches, tab tools.", fallback: .bool(false),
               preview: "A Debug menu appearing after Help", experimental: true),
    ]

    // MARK: Mail

    private static func mail(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil, _ title: String,
                             _ detail: String, fallback: PersonalValue? = nil, preview: String) -> PersonalSetting {
        setting("Mail", "com.apple.mail", key, kind: kind, control: control, storage: .container("com.apple.mail"),
                title, detail, fallback: fallback, evidence: strings("Mail"), preview: preview)
    }

    static let mailSettings: [PersonalSetting] = [
        mail("DisableInlineAttachmentViewing", "Attachments as Icons", "Pictures and PDFs show as icons, not inside the message.",
             fallback: .bool(false), preview: "An inline photo shrinking to a file icon"),
        mail("ConversationViewSortDescending", "Newest Message First", "Conversations put the latest reply at the top.",
             fallback: .bool(false), preview: "A thread flipping its order"),
        mail("ShowCcHeader", "Cc Field", "New messages show the Cc field.", preview: "A compose window with a Cc line"),
        mail("ShowBccHeader", "Bcc Field", "New messages show the Bcc field.", preview: "A compose window with a Bcc line"),
        mail("ShowReplyToHeader", "Reply-To Field", "New messages show the Reply-To field.",
             preview: "A compose window with a Reply-To line"),
        mail("NumberOfSnippetLines", kind: .int,
             control: choices([(.int(0), "None"), (.int(1), "1 Line"), (.int(2), "2 Lines"), (.int(3), "3 Lines"),
                               (.int(4), "4 Lines"), (.int(5), "5 Lines")]),
             "Preview Lines", "Lines of each message shown in the list.", fallback: .int(2),
             preview: "Message list rows growing taller"),
        mail("AutoReplyFormat", "Reply in Original Format", "Replies use plain or rich text to match the message.",
             preview: "A reply switching to plain text"),
        mail("ShouldShowUnreadMessagesInBold", "Unread in Bold", "Unread messages stand out in the list.",
             preview: "Unread rows turning bold"),
    ]

    // MARK: Music and TV

    private static func music(_ key: String, _ title: String, _ detail: String, fallback: PersonalValue? = nil,
                              preview: String, caution: String? = nil) -> PersonalSetting {
        setting("Music", "com.apple.Music", key, storage: .standard, title, detail, fallback: fallback,
                evidence: strings("Music") + " (REA timed out on this binary)", preview: preview, caution: caution)
    }

    private static let restriction = "A restriction key from iTunes' parental controls. Music still reads it."

    static let musicSettings: [PersonalSetting] = [
        music("showStatusBar", "Status Bar", "Song count and total time under the list.", preview: "\"1,204 songs, 3.2 days\" under the list"),
        music("showStarRatings", "Star Ratings", "A rating column in song lists.", preview: "Stars appearing beside songs"),
        music("showComposer", "Composers", "Show composers in Songs and Albums.", preview: "A Composer column appearing"),
        music("showWorkAndMovement", "Work and Movement", "Classical tracks show their work and movement names.",
              preview: "A symphony grouping into movements"),
        music("disableAppleMusic", "Hide Apple Music", "Music becomes a player for your own library only.",
              fallback: .bool(false), preview: "The sidebar losing Home, New and Radio", caution: restriction),
        music("disableMusicStore", "Hide iTunes Store", "Removes the iTunes Store from the sidebar.", fallback: .bool(false),
              preview: "The iTunes Store sidebar row vanishing", caution: restriction),
        music("disableSharedMusic", "Turn Off Shared Libraries", "Libraries shared by other Macs stop showing.",
              fallback: .bool(false), preview: "A shared library row vanishing", caution: restriction),
        music("disableHomeSharing", "Turn Off Home Sharing", "Home Sharing is switched off in Music.", fallback: .bool(false),
              preview: "The Home Sharing house icon crossed out", caution: restriction),
    ]

    private static func tv(_ key: String, _ title: String, _ detail: String, fallback: PersonalValue? = nil,
                           preview: String) -> PersonalSetting {
        setting("TV", "com.apple.TV", key, storage: .standard, title, detail, fallback: fallback,
                evidence: strings("TV"), preview: preview)
    }

    static let tvSettings: [PersonalSetting] = [
        tv("showStatusBar", "Status Bar", "Item count and total time under the list.", preview: "A count under the TV library"),
        tv("userWantsPlaybackNotifications", "Playback Notifications", "A notification when the next episode starts.",
           preview: "An episode banner sliding in"),
        tv("showSubtitlesWhenMuted", "Subtitles When Muted", "Muting turns subtitles on.", preview: "Subtitles appearing on mute"),
        tv("showSubtitlesOnSkipBack", "Subtitles on Skip Back", "Skipping back shows subtitles for a moment.",
           preview: "Subtitles after a 10-second skip"),
        tv("automaticallyDeleteVideoAssetsAfterWatching", "Delete Watched Downloads",
           "Downloaded films and episodes go once watched.", preview: "A downloaded episode removing itself"),
        tv("useViewingHistory", "Use Viewing History", "Up Next and suggestions use what you watched.",
           preview: "Up Next refilling with suggestions"),
    ]

    // MARK: Photos

    static let photosSettings: [PersonalSetting] = [
        setting("Photos", "com.apple.Photos", "IPXDebugEnabled", storage: .container("com.apple.Photos"), "Debug Panel",
                "Photos' internal debug panel and inspector bricks.", fallback: .bool(false), evidence: strings("Photos"),
                preview: "A debug inspector beside a photo", experimental: true),
    ]

    // MARK: Preview

    private static func preview(_ key: String, _ title: String, _ detail: String, fallback: PersonalValue? = nil,
                                preview: String, experimental: Bool = false) -> PersonalSetting {
        setting("Preview", "com.apple.Preview", key, storage: .container("com.apple.Preview"), title, detail,
                fallback: fallback, evidence: strings("Preview"), preview: preview, experimental: experimental)
    }

    static let previewSettings: [PersonalSetting] = [
        preview("PVMarkupToolbarVisibleForImages", "Markup Bar for Images", "Images open with the Markup toolbar showing.",
                preview: "An image opening with its markup tools"),
        preview("PVMarkupToolbarVisibleForPDFs", "Markup Bar for PDFs", "PDFs open with the Markup toolbar showing.",
                preview: "A PDF opening with its markup tools"),
        preview("PVPDFSuppressSidebarOnOpening", "No Sidebar for PDFs", "PDFs open without the thumbnail sidebar.",
                preview: "A PDF opening edge to edge"),
        preview("PVImageOpensNewWindowPerDocument", "One Window per Image", "Several images open in separate windows.",
                preview: "Three images fanning out into three windows"),
        preview("PVShowImageBackground", "Image Background", "A backdrop behind transparent images.",
                preview: "A checkerboard behind a transparent PNG"),
        preview("kPVFullscreenAutohidesToolbarOption", "Hide Toolbar in Full Screen", "The toolbar slides away in full screen.",
                preview: "A full-screen PDF without its toolbar"),
        preview("kPVPDFRememberPageOption", "Remember Last Page", "PDFs reopen where you stopped reading.",
                preview: "A PDF reopening on page 42"),
        preview("PVPDFShowNotes", "Show Notes", "PDF note annotations stay visible.", preview: "Yellow notes on a PDF page"),
        preview("PVUseExactPhraseSearch", "Exact Phrase Search", "Search finds the whole phrase, not each word.",
                preview: "One search hit instead of twenty"),
        preview("PVDisableHDRBackgroundAppDimming", "Keep HDR Bright in Background",
                "HDR images stay bright when Preview is not in front.", preview: "An HDR photo staying vivid behind another window",
                experimental: true),
        preview("PVStayHDRWhenAnnotating", "Stay HDR While Marking Up", "Annotating an HDR image keeps it in HDR.",
                preview: "An HDR photo with an arrow drawn on it", experimental: true),
        preview("PVWindowDebugOverlay", "Window Debug Overlay", "Preview's internal overlay showing view frames.",
                fallback: .bool(false), preview: "Coloured frames over a Preview window", experimental: true),
    ]

    // MARK: QuickTime Player

    private static func quickTime(_ key: String, _ title: String, _ detail: String, preview: String,
                                  experimental: Bool = false) -> PersonalSetting {
        setting("QuickTime Player", "com.apple.QuickTimePlayerX", key, storage: .container("com.apple.QuickTimePlayerX"),
                title, detail, evidence: strings("QuickTime Player"), preview: preview, experimental: experimental)
    }

    static let quickTimeSettings: [PersonalSetting] = [
        quickTime("MGPrefersExportAsH264", "Export as H.264", "Exports pick H.264 over HEVC.", preview: "The export sheet set to H.264"),
        quickTime("MGInspectorWindowControllerShowWindowAtLaunch", "Movie Inspector at Launch",
                  "The Movie Inspector opens with QuickTime.", preview: "The inspector panel beside a movie"),
        quickTime("MGAudioWaveformRenderingUseRootMeanSquare", "Smoother Waveforms",
                  "Audio waveforms in the trim bar are drawn by loudness, not peaks.",
                  preview: "A spiky waveform turning smooth", experimental: true),
        quickTime("ShowDebugMenu", "Debug Menu", "QuickTime Player's hidden Debug menu.",
                  preview: "A Debug menu appearing after Help", experimental: true),
    ]

    // MARK: TextEdit

    private static func textEdit(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                                 _ title: String, _ detail: String, fallback: PersonalValue? = nil, preview: String,
                                 experimental: Bool = false) -> PersonalSetting {
        setting("TextEdit", "com.apple.TextEdit", key, kind: kind, control: control, storage: .container("com.apple.TextEdit"),
                title, detail, fallback: fallback, evidence: "REA (Hopper): TextEdit binary string", preview: preview,
                experimental: experimental)
    }

    static let textEditSettings: [PersonalSetting] = [
        textEdit("RichText", "New Documents Are Rich Text", "Off makes ⌘N open a plain-text document.", fallback: .bool(true),
                 preview: "A new document dropping its formatting bar"),
        textEdit("ShowRuler", "Ruler", "Rich documents show the ruler.", fallback: .bool(true), preview: "The ruler over a document"),
        textEdit("ShowPageBreaks", "Wrap to Page", "New documents show page edges, like Format › Wrap to Page.",
                 preview: "Text reflowing onto white pages"),
        textEdit("WidthInChars", kind: .int, control: .number(40...200, step: 5, unit: "chars"), "Window Width",
                 "New windows fit this many characters.", fallback: .int(75), preview: "A new window widening"),
        textEdit("HeightInChars", kind: .int, control: .number(10...100, step: 5, unit: "lines"), "Window Height",
                 "New windows fit this many lines.", fallback: .int(30), preview: "A new window growing taller"),
        textEdit("TabWidth", kind: .int, control: .number(1...16, step: 1, unit: "spaces"), "Tab Width",
                 "Tab stops in plain text.", fallback: .int(8), preview: "Indented code shifting"),
        textEdit("CheckSpellingWhileTyping", "Check Spelling", "Red underlines as you type.", fallback: .bool(true),
                 preview: "A misspelled word underlined"),
        textEdit("CorrectSpellingAutomatically", "Correct Spelling", "Fix misspellings as you type.",
                 preview: "teh becoming the"),
        textEdit("CheckGrammarWithSpelling", "Check Grammar", "Green underlines for grammar.", preview: "A phrase underlined in green"),
        textEdit("SmartQuotes", "Smart Quotes", "Straight quotes become curly in TextEdit.", preview: "Quotes curling"),
        textEdit("SmartDashes", "Smart Dashes", "Two hyphens become a dash in TextEdit.", preview: "-- turning into —"),
        textEdit("SmartLinks", "Smart Links", "Typed web addresses become links.", preview: "A URL turning blue"),
        textEdit("TextReplacement", "Text Replacement", "Your text shortcuts expand in TextEdit.", fallback: .bool(true),
                 preview: "omw expanding to On my way!"),
        textEdit("DataDetectors", "Data Detectors", "Dates, addresses and numbers become actionable.",
                 preview: "A date with a dotted underline"),
        textEdit("SmartSubstitutionsEnabledInRichTextOnly", "Smart Typing Only in Rich Text",
                 "Plain-text files keep straight quotes and dashes.", fallback: .bool(true),
                 preview: "A plain-text file keeping straight quotes"),
        textEdit("IgnoreHTML", "Show HTML as Code", "HTML files open as source, not as a page.",
                 preview: "A web page turning into its tags"),
        textEdit("IgnoreRichText", "Show RTF as Code", "RTF files open as their raw markup.", preview: "An RTF file showing \\rtf1"),
        textEdit("AddExtensionToNewPlainTextFiles", "Add .txt When Saving", "Plain-text files get the .txt extension.",
                 fallback: .bool(true), preview: "A Save sheet suggesting notes.txt"),
        textEdit("NumberPagesWhenPrinting", "Page Numbers When Printing", "Printouts get headers and page numbers.",
                 preview: "A printed page with a number"),
        textEdit("UsesTextLayoutManagerForRichDocuments", "TextKit 2 for Rich Text",
                 "Use the newer text engine for rich documents.", preview: "A rich document redrawing", experimental: true),
        textEdit("AlwaysLightBackground", "Always Light Pages", "Documents stay white in Dark Mode.",
                 preview: "A white page in a dark window", experimental: true),
        textEdit("AutosavingDelay", kind: .int, control: .number(5...120, step: 5, unit: "s"), "Autosave Delay",
                 "How long TextEdit waits before autosaving.", preview: "A save dot pulsing after the delay", experimental: true),
    ]

    // MARK: Calendar

    private static func calendar(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                                 _ title: String, _ detail: String, fallback: PersonalValue? = nil,
                                 preview: String) -> PersonalSetting {
        setting("Calendar", "com.apple.iCal", key, kind: kind, control: control, storage: .standard, title, detail,
                fallback: fallback, evidence: strings("Calendar") + "; Calendar's sandbox reads com.apple.iCal from ~/Library/Preferences",
                preview: preview)
    }

    private static let morning: [(PersonalValue, String)] = [(.int(360), "6:00"), (.int(420), "7:00"), (.int(480), "8:00"),
                                                             (.int(540), "9:00"), (.int(600), "10:00")]
    private static let evening: [(PersonalValue, String)] = [(.int(960), "16:00"), (.int(1020), "17:00"),
                                                             (.int(1080), "18:00"), (.int(1140), "19:00"), (.int(1200), "20:00")]

    static let calendarSettings: [PersonalSetting] = [
        calendar("Show Week Numbers", "Week Numbers", "Week numbers in week and month view.", fallback: .bool(false),
                 preview: "\"W45\" beside a week"),
        calendar("number of hours displayed", kind: .int, control: .number(6...24, step: 1, unit: "h"), "Hours on Screen",
                 "How many hours day and week view fit at once.", fallback: .int(12), preview: "Week view zooming its hours"),
        calendar("n days of week", kind: .int, control: choices([(.int(5), "5 Days"), (.int(7), "7 Days")]), "Week View Days",
                 "Week view shows the working week or the whole week.", fallback: .int(7), preview: "The weekend columns folding away"),
        calendar("first minute of work hours", kind: .int, control: choices(morning), "Day Starts At",
                 "The start of the shaded working day.", fallback: .int(480), preview: "The shaded day starting earlier"),
        calendar("last minute of work hours", kind: .int, control: choices(evening), "Day Ends At",
                 "The end of the shaded working day.", fallback: .int(1080), preview: "The shaded day ending later"),
        calendar("TimeZone support enabled", "Time Zone Support", "Events can have their own time zone.",
                 fallback: .bool(false), preview: "A time zone menu in the toolbar"),
        calendar("Show heat map in Year View", "Year View Heat Map", "Busy days glow in year view.", preview: "Year view tinted by busyness"),
        calendar("WarnBeforeSendingInvitations", "Warn Before Sending Invitations", "Ask before invitations go out.",
                 fallback: .bool(true), preview: "The Send invitation sheet"),
    ]

    // MARK: Smaller Apple apps

    static let contactsSettings: [PersonalSetting] = [
        setting("Contacts", "com.apple.AddressBook", "ABPhoneticFieldsVisible", storage: .guarded, "Phonetic Name Fields",
                "Cards show phonetic first and last name fields.", evidence: strings("Contacts"),
                preview: "A card with phonetic name lines"),
        setting("Contacts", "com.apple.AddressBook", "ABShowDebugMenu", storage: .guarded, "Debug Menu",
                "Contacts' hidden Debug menu.", fallback: .bool(false), evidence: strings("Contacts"),
                preview: "A Debug menu appearing after Help", experimental: true),
    ]

    static let stickiesSettings: [PersonalSetting] = [
        setting("Stickies", "com.apple.Stickies", "DefaultWindowFloating", storage: .container("com.apple.Stickies"),
                "New Notes Float", "New notes stay above other windows.", evidence: strings("Stickies"),
                preview: "A note hovering over a browser"),
        setting("Stickies", "com.apple.Stickies", "DefaultWindowTranslucent", storage: .container("com.apple.Stickies"),
                "New Notes Translucent", "New notes let the desktop show through.", evidence: strings("Stickies"),
                preview: "A see-through yellow note"),
    ]

    static let freeformSettings: [PersonalSetting] = [
        setting("Freeform", "com.apple.freeform", "CRLShowSizeAndPositionWhileMovingUserDefault", storage: .standard,
                "Size and Position While Moving", "Shows coordinates and size as you drag items.",
                evidence: strings("Freeform") + "; Freeform's sandbox reads com.apple.freeform from ~/Library/Preferences",
                preview: "A size badge following a dragged shape"),
        setting("Freeform", "com.apple.freeform", "TSCODebugMenu", storage: .standard, "Debug Menu",
                "Freeform's internal Debug menu.", fallback: .bool(false), evidence: strings("Freeform"),
                preview: "A Debug menu appearing after Help", experimental: true),
    ]

    static let booksSettings: [PersonalSetting] = [
        setting("Books", "com.apple.iBooksX", "BKShowDebugMenu", storage: .container("com.apple.iBooksX"), "Debug Menu",
                "Books' hidden Debug menu.", fallback: .bool(false), evidence: strings("Books"),
                preview: "A Debug menu appearing after Help", experimental: true),
    ]

    static let mapsSettings: [PersonalSetting] = [
        setting("Maps", "com.apple.Maps", "MapsEnableDebugMenu", storage: .container("com.apple.Maps"), "Debug Menu",
                "Maps' internal Debug menu.", fallback: .bool(false), evidence: strings("Maps"),
                preview: "A Debug menu appearing after Help", experimental: true),
    ]

    static let photoBoothSettings: [PersonalSetting] = [
        setting("Photo Booth", "com.apple.PhotoBooth", "EnableDebugMenu", storage: .standard, "Debug Menu",
                "Photo Booth's hidden Debug menu.", fallback: .bool(false),
                evidence: strings("Photo Booth") + "; its sandbox reads com.apple.PhotoBooth from ~/Library/Preferences",
                preview: "A Debug menu appearing after Help", experimental: true),
    ]

    static let appStoreSettings: [PersonalSetting] = [
        setting("App Store", "com.apple.AppStore", "AutoPlayVideoSetting", kind: .string,
                control: choices([(.string("on"), "On"), (.string("off"), "Off")]), storage: .standard, "Autoplay Videos",
                "App previews play by themselves.", evidence: strings("App Store") + "; \"on\" set on this Mac",
                preview: "An app preview video starting by itself",
                caution: "Automatic app updates live in a system-wide file that needs an administrator; change them in App Store settings."),
    ]

    static let tipsSettings: [PersonalSetting] = [
        setting("Tips", "com.apple.helpviewer", "DevMode", storage: .container("com.apple.helpviewer"), "Help Developer Mode",
                "Help windows stop floating above everything and gain developer extras.", fallback: .bool(false),
                evidence: cache + "; com.apple.helpviewer now belongs to Tips.app", preview: "A help window dropping behind others",
                experimental: true),
    ]

    // MARK: Utilities

    private static let terminalProfiles: [(PersonalValue, String)] = ["Basic", "Clear Dark", "Clear Light", "Grass",
        "Homebrew", "Man Page", "Novel", "Ocean", "Pro", "Red Sands", "Silver Aerogel", "Solid Colors"]
        .map { (.string($0), $0) }

    private static func terminal(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                                 _ title: String, _ detail: String, fallback: PersonalValue? = nil, evidence: String? = nil,
                                 preview: String, experimental: Bool = false) -> PersonalSetting {
        setting("Terminal", "com.apple.Terminal", key, kind: kind, control: control, storage: .standard, title, detail,
                fallback: fallback, evidence: evidence ?? strings("Terminal"), preview: preview, experimental: experimental)
    }

    static let terminalSettings: [PersonalSetting] = [
        terminal("Default Window Settings", kind: .string, control: choices(terminalProfiles), "Default Profile",
                 "The look of new windows.", evidence: strings("Terminal") + "; \"Clear Dark\" set on this Mac",
                 preview: "A new Terminal window in the chosen profile"),
        terminal("Startup Window Settings", kind: .string, control: choices(terminalProfiles), "Profile at Launch",
                 "The profile Terminal opens with.", evidence: strings("Terminal") + "; \"Clear Dark\" set on this Mac",
                 preview: "Terminal opening in the chosen profile"),
        terminal("AutoMarkPromptLines", "Mark Prompt Lines", "Each prompt is marked so ⌘↑ jumps between commands.",
                 fallback: .bool(true), preview: "Brackets beside each prompt"),
        terminal("ShowLineMarks", "Show Marks", "Draw the marks in the left margin.", fallback: .bool(true),
                 preview: "Small brackets in the margin"),
        terminal("WarnAboutQuarantinedSSHURLs", "Warn on Downloaded ssh Links", "Ask before opening an ssh:// link from the web.",
                 fallback: .bool(true), preview: "A warning before an ssh link opens"),
        terminal("EnableSmoothResizing", "Smooth Resizing", "Windows resize pixel by pixel instead of by character cell.",
                 preview: "A window edge gliding instead of snapping", experimental: true),
    ]

    static let activityMonitorSettings: [PersonalSetting] = [
        setting("Activity Monitor", "com.apple.ActivityMonitor", "ShowCategory", kind: .int,
                control: choices([(.int(100), "All Processes"), (.int(101), "All, Hierarchically"), (.int(102), "My Processes"),
                                  (.int(103), "System Processes"), (.int(104), "Other User Processes"),
                                  (.int(105), "Active Processes"), (.int(106), "Inactive Processes"),
                                  (.int(107), "Windowed Processes")]),
                storage: .standard, "Show", "Which processes the list starts with.", fallback: .int(100),
                evidence: strings("Activity Monitor") + "; values follow its View menu order", preview: "The process list filtering"),
        setting("Activity Monitor", "com.apple.ActivityMonitor", "OpenMainWindow", storage: .standard, "Open Main Window",
                "Off lets it start as just a Dock graph.", fallback: .bool(true), evidence: strings("Activity Monitor"),
                preview: "Activity Monitor opening without a window"),
        setting("Activity Monitor", "com.apple.ActivityMonitor", "ShowGPUTab", storage: .standard, "GPU Tab",
                "A GPU tab beside CPU, Memory and Energy.", evidence: strings("Activity Monitor"),
                preview: "A GPU tab in the toolbar", experimental: true),
    ]

    static let diskUtilitySettings: [PersonalSetting] = [
        setting("Disk Utility", "com.apple.DiskUtility", "WorkspaceShowAPFSSnapshots", storage: .standard, "APFS Snapshots",
                "Volumes list their snapshots, as View › Show APFS Snapshots.", evidence: strings("Disk Utility"),
                preview: "A snapshot list under a volume"),
        setting("Disk Utility", "com.apple.DiskUtility", "ShowPartitionID", storage: .standard, "Partition IDs",
                "Partition type identifiers in the info panel.", evidence: strings("Disk Utility"),
                preview: "A GUID beside a partition", experimental: true),
        setting("Disk Utility", "com.apple.DiskUtility", "ShowCreateSnapshot", storage: .standard, "Create Snapshot Command",
                "A menu command to take an APFS snapshot.", evidence: strings("Disk Utility"),
                preview: "A Create Snapshot item in the menu", experimental: true,
                caution: "Snapshots hold on to disk space until deleted."),
    ]

    static let scriptEditorSettings: [PersonalSetting] = [
        setting("Script Editor", "com.apple.ScriptEditor2", "UsesScriptAssistant", storage: .standard, "Script Assistant",
                "Code completion while you type AppleScript.", evidence: strings("Script Editor"),
                preview: "A completion list under a half-typed word"),
        setting("Script Editor", "com.apple.ScriptEditor2", "EditorUsesTabs", storage: .standard, "Indent With Tabs",
                "Indent with tabs instead of spaces.", evidence: strings("Script Editor"), preview: "Indentation switching to tabs"),
        setting("Script Editor", "com.apple.ScriptEditor2", "EnableEventLogHistory", storage: .standard, "Log History",
                "Keep a history of results and events.", evidence: strings("Script Editor"), preview: "The log history window"),
    ]

    static let keychainSettings: [PersonalSetting] = [
        setting("Keychain Access", "com.apple.keychainaccess", "Show Invisible Items", storage: .standard, "Invisible Items",
                "List items apps mark as hidden.", evidence: strings("Keychain Access"), preview: "Extra rows appearing in the list"),
        setting("Keychain Access", "com.apple.keychainaccess", "Show Expired Certificates", storage: .standard,
                "Expired Certificates", "Keep expired certificates in the list.", evidence: strings("Keychain Access"),
                preview: "A red-crossed certificate in the list"),
        setting("Keychain Access", "com.apple.keychainaccess", "DebugShowUserVisiblePasswordManagerItems", storage: .standard,
                "Show Passwords App Items", "List items that now belong to the Passwords app.", fallback: .bool(false),
                evidence: strings("Keychain Access"), preview: "Website passwords back in Keychain Access", experimental: true),
    ]

    static let systemInformationSettings: [PersonalSetting] = [
        setting("System Information", "com.apple.SystemProfiler", "SPShowDevelopMenu", storage: .standard, "Develop Menu",
                "System Information's hidden Develop menu.", fallback: .bool(false), evidence: strings("System Information"),
                preview: "A Develop menu appearing", experimental: true),
    ]

    private static func archive(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                                _ title: String, _ detail: String, fallback: PersonalValue? = nil,
                                preview: String) -> PersonalSetting {
        setting("Archive Utility", "com.apple.archiveutility", key, kind: kind, control: control,
                storage: .container("com.apple.archiveutility"), title, detail, fallback: fallback,
                evidence: strings("Archive Utility"), preview: preview)
    }

    static let archiveUtilitySettings: [PersonalSetting] = [
        archive("dearchive-reveal-after", "Reveal Expanded Items", "Show what an archive unpacked to in Finder.",
                fallback: .bool(true), preview: "A Finder window selecting the unpacked folder"),
        archive("dearchive-recursively", "Keep Expanding", "Archives inside archives are unpacked too.",
                preview: "A zip inside a zip opening all the way"),
        archive("dearchive-move-after", kind: .string,
                control: choices([(.string("."), "Leave Alone"), (.string("~/.Trash"), "Move to Trash")]),
                "After Expanding", "What happens to the archive itself.", fallback: .string("."),
                preview: "The zip flying into the Trash"),
        archive("archive-format", kind: .string,
                control: choices([(.string("zip"), "Zip"), (.string("cpgz"), "cpgz"), (.string("cpio"), "cpio")]),
                "Compress As", "The format of archives Archive Utility makes.", fallback: .string("zip"),
                preview: "A new archive's badge changing format"),
        archive("archive-reveal-after", "Reveal New Archives", "Show a new archive in Finder.", fallback: .bool(true),
                preview: "Finder selecting the new zip"),
    ]

    // MARK: Xcode

    private static func xcode(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                              _ title: String, _ detail: String, fallback: PersonalValue? = nil, preview: String,
                              experimental: Bool = false) -> PersonalSetting {
        setting("Xcode", "com.apple.dt.Xcode", key, kind: kind, control: control, storage: .standard, title, detail,
                fallback: fallback, evidence: "strings: Xcode's IDEKit, IDEFoundation, DVTKit and SourceEditor frameworks",
                preview: preview, experimental: experimental)
    }

    static let xcodeSettings: [PersonalSetting] = [
        xcode("ShowBuildOperationDuration", "Build Time in Toolbar", "The activity view says how long the build took.",
              fallback: .bool(false), preview: "\"Succeeded | 12.4s\" in the toolbar"),
        xcode("IDEIndexerActivityShowNumericProgress", "Indexing Progress Numbers", "Indexing shows a count, not just a bar.",
              fallback: .bool(false), preview: "\"Indexing 412 of 1,280\" in the toolbar"),
        xcode("IDEBuildOperationMaxNumberOfConcurrentCompileTasks", kind: .int, control: .number(1...32, step: 1, unit: "tasks"),
              "Parallel Compile Tasks", "How many files compile at once. Unset uses one per core.",
              preview: "More compile lanes in the build log"),
        xcode("DVTTextShowMinimap", "Minimap", "The code overview down the editor's right edge.", fallback: .bool(true),
              preview: "A minimap beside the code"),
        xcode("DVTTextShowPageGuide", "Page Guide", "A vertical line at the chosen column.", fallback: .bool(false),
              preview: "A faint line at column 120"),
        xcode("DVTTextPageGuideLocation", kind: .int, control: .number(40...200, step: 10, unit: "col"), "Page Guide Column",
              "Where the page guide sits.", fallback: .int(80), preview: "The guide line moving"),
        xcode("DVTTextEditorTrimWhitespaceOnlyLines", "Trim Blank Lines", "Lines with only spaces are emptied on save.",
              preview: "Invisible spaces disappearing"),
        xcode("DVTTextEditorWrapsLines", "Wrap Lines", "Long lines wrap to the editor width.", fallback: .bool(true),
              preview: "A long line folding onto two"),
        xcode("IDEShowPrebuildLogs", "Pre-build Logs", "Package resolution and other pre-build steps appear in the report.",
              preview: "Extra steps in the build report"),
        xcode("IDEDisableStateRestoration", "Don't Reopen Projects", "Xcode starts without the projects it had open.",
              fallback: .bool(false), preview: "Xcode opening to its welcome window"),
        xcode("ShowDVTDebugMenu", "Debug Menu", "Xcode's internal DVT debug menu.", fallback: .bool(false),
              preview: "A Debug menu appearing", experimental: true),
    ]

    // MARK: Finder extras

    /// Finder keys not in `finderSettings` or the tweak catalogue, from the same Finder binary.
    static let finderExtraSettings: [PersonalSetting] = [
        PersonalSetting(.finder, "Hidden Extras", domain: "com.apple.finder", key: "_FXSortFoldersFirstOnDesktop", kind: .bool,
                        control: toggle(), title: "Folders First on Desktop", detail: "Folders sort ahead of files on the desktop.",
                        effect: .restart("Finder"), fallback: .bool(false), evidence: "strings: Finder binary",
                        preview: "Desktop folders jumping ahead of files"),
        PersonalSetting(.finder, "Hidden Extras", domain: "com.apple.finder", key: "AnimateInfoPanes", kind: .bool,
                        control: toggle(), title: "Animate Get Info", detail: "Get Info sections slide open.",
                        effect: .restart("Finder"), fallback: .bool(true), evidence: "strings: Finder binary",
                        preview: "A Get Info section sliding open"),
        PersonalSetting(.finder, "Hidden Extras", domain: "com.apple.finder", key: "AnimateWindowZoom", kind: .bool,
                        control: toggle(), title: "Window Zoom Animation", detail: "Windows zoom out of the icon you open.",
                        effect: .restart("Finder"), fallback: .bool(true), evidence: "strings: Finder binary",
                        preview: "A window zooming out of a folder"),
        PersonalSetting(.finder, "Hidden Extras", domain: "com.apple.finder", key: "FXEnableSlowAnimation", kind: .bool,
                        control: toggle(), title: "Slow-motion Animations", detail: "Finder's own animations play slowly.",
                        effect: .restart("Finder"), fallback: .bool(false), evidence: "strings: Finder binary",
                        preview: "A folder opening in slow motion",
                        caution: "Experimental: found in Finder's code, not in its settings.", experimental: true),
    ]
}
