import Foundation

// AppKit-wide behaviour, accessibility visuals, Quick Look, haptics and hidden Dock motion.
// AppKit keys live in the dyld shared cache: `dyld_info -section __TEXT __cstring` on the
// framework gives the image and the address of each literal, which `evidence` quotes.

extension PersonalCatalog {
    private static let tail = "; effect not verified"

    private static func appKit(in area: PersonalArea = .appKit, _ section: String, _ key: String, kind: PersonalKind = .bool,
                               control: PersonalControl? = nil, _ title: String, _ detail: String,
                               image: String = "AppKit", fallback: PersonalValue? = nil, preview: String,
                               effect: PersonalEffect = .relaunchApps, caution: String? = nil) -> PersonalSetting {
        PersonalSetting(area, section, domain: "NSGlobalDomain", key: key, kind: kind, control: control ?? sysToggle(),
                        title: title, detail: detail, effect: effect, fallback: fallback,
                        evidence: "\(image) __cstring \(key) (dyld shared cache)" + tail, preview: preview, caution: caution)
    }

    private static func experiment(_ text: String = "A hidden AppKit default with no setting in System Settings.") -> String {
        "Experimental. " + text
    }

    // MARK: Accessibility

    private static let protectedDomain = "macOS protects this domain: the write can be refused, and Atelier will say so. "
        + "System Settings applies it at once; from here it waits for you to log out."

    private static func access(_ section: String, _ key: String, _ title: String, _ detail: String, image: String,
                               on: Bool = true, fallback: Bool? = false, preview: String) -> PersonalSetting {
        PersonalSetting(.accessibility, section, domain: "com.apple.universalaccess", key: key, kind: .bool,
                        control: sysToggle(on), title: title, detail: detail, effect: .logout,
                        fallback: fallback.map(PersonalValue.bool),
                        evidence: "\(image) string \(key)" + tail, preview: preview, caution: protectedDomain)
    }

    static let accessibilitySettings: [PersonalSetting] = [
        access("Display", "reduceMotion", "Reduce Motion", "Fades instead of slides and zooms.",
               image: "Dock and dyld shared cache", preview: "A Space switch turning into a cross-fade"),
        access("Display", "reduceTransparency", "Reduce Transparency", "Solid backgrounds instead of glass.",
               image: "SkyLight", preview: "The menu bar and sidebars turning opaque"),
        access("Display", "increaseContrast", "Increase Contrast", "Stronger borders and darker text.",
               image: "Dock and dyld shared cache", preview: "Controls gaining dark outlines"),
        access("Display", "differentiateWithoutColor", "Differentiate Without Colour", "Shapes as well as colours mark state.",
               image: "SkyLight", preview: "Status dots gaining shapes"),
        access("Display", "showWindowTitlebarIcons", "Title Bar Icons", "A document icon next to window titles.",
               image: "dyld shared cache", preview: "A proxy icon appearing beside a window title"),
        access("Display", "showToolbarButtonShapes", "Toolbar Button Shapes", "Toolbar buttons get visible outlines.",
               image: "dyld shared cache", preview: "Toolbar glyphs gaining pill backgrounds"),
        access("Zoom", "closeViewScrollWheelToggle", "Zoom with Scroll and Modifier", "Hold Control and scroll to zoom the screen.",
               image: "UniversalAccessCore and libUAPreferences", preview: "The screen magnifying under the pointer"),
        access("Zoom", "closeViewSmoothImages", "Smooth Zoomed Images", "Zoomed pixels are smoothed.",
               image: "UniversalAccessCore and Zoom.framework", fallback: true, preview: "Jagged pixels becoming soft"),
        access("Zoom", "closeViewZoomFollowsFocus", "Zoom Follows Keyboard Focus", "The zoomed view tracks the focused control.",
               image: "UniversalAccessCore and Zoom.framework", preview: "The zoom window following a Tab press"),
        access("Hover", "hoverTextEnabled", "Hover Text", "Hold Command over text to see it large.",
               image: "libUAPreferences", preview: "A large bubble of text above the pointer"),
        access("Hover", "hoverTypingEnabled", "Hover Typing", "A large copy of what you type.",
               image: "libUAPreferences", preview: "Typed letters echoed in a big banner"),
        access("Keyboard Focus", "keyboardAccessLargeFocusRingEnabled", "Large Focus Ring",
               "A thicker ring around the focused control.", image: "libUAPreferences", preview: "A bold focus ring"),
        access("Keyboard Focus", "keyboardAccessFocusRingHighContrastEnabled", "High-Contrast Focus Ring",
               "The focus ring in a stronger colour.", image: "libUAPreferences", preview: "A focus ring in high contrast"),
        appKit(in: .accessibility, "Pointer", "CGDisableCursorLocationMagnification", control: sysToggle(false),
               "Shake to Find the Pointer", "Shaking the mouse makes the pointer big for a moment.", image: "SkyLight",
               fallback: .bool(false), preview: "The pointer ballooning after a shake", effect: .logout),
    ]

    // MARK: AppKit everywhere

    static let appKitSettings: [PersonalSetting] = [
        appKit("Text", "NSTextInsertionPointBlinkPeriodOn", kind: .int, control: .number(100...3000, step: 50, unit: "ms"),
               "Caret On Time", "How long the text cursor stays lit in each blink.",
               preview: "The caret blinking slowly or fast"),
        appKit("Text", "NSTextInsertionPointBlinkPeriodOff", kind: .int, control: .number(0...3000, step: 50, unit: "ms"),
               "Caret Off Time", "How long it stays dark. Zero with a long on time makes it nearly steady.",
               preview: "A caret that barely blinks"),
        appKit("Text", "NSDragAndDropTextDelay", kind: .int, control: .number(0...1500, step: 50, unit: "ms"),
               "Text Drag Delay", "How long you hold selected text before it can be dragged.",
               preview: "Selected words lifting off at once"),
        appKit("Text", "NSAutomaticTextCompletionEnabled", "Inline Word Completion", "Suggestions as you type, in apps that support it.",
               preview: "A grey word completion after the caret"),
        appKit("Text", "NSSpellCheckerAutomaticallyIdentifiesLanguages", "Detect Spelling Language",
               "Spell-check in whatever language you write.", fallback: .bool(true),
               preview: "A Portuguese sentence no longer underlined"),
        appKit("Text", "NSTextShowsControlCharacters", "Show Control Characters",
               "Tabs and line breaks show as symbols in text views.", image: "dyld shared cache",
               preview: "Text sprouting ¶ and → marks", caution: experiment()),
        appKit("Text", "NSTextKillRingSize", kind: .int, control: .number(1...20, step: 1, unit: ""),
               "Kill Ring Size", "⌃K cuts collect in a ring of this size; ⌃Y yanks them back like Emacs.",
               preview: "Several cut lines cycling back in", caution: experiment()),

        appKit("Scrolling", "AppleScrollerPagingBehavior", "Click Scroll Bar to Jump",
               "Clicking the scroll track jumps to that spot instead of a page.", fallback: .bool(false),
               preview: "A scroll knob leaping to the click"),
        appKit("Scrolling", "NSOverlayScrollerHideDelay", kind: .float, control: .number(0...5, step: 0.25, unit: "s"),
               "Scroll Bars Linger", "How long overlay scroll bars stay after scrolling stops.",
               preview: "A scroll bar fading out late", caution: experiment()),

        appKit("Windows", "NSRecentDocumentsLimit", kind: .int, control: .number(0...50, step: 1, unit: ""),
               "Open Recent Length", "How many items File › Open Recent remembers.", fallback: .int(10),
               preview: "A long Open Recent menu"),
        appKit("Windows", "NSDisableAutomaticTermination", "Never Quit Idle Apps",
               "Apps with no windows are not quietly quit by macOS.", preview: "An idle app staying in the Dock"),
        appKit("Windows", "NSAppSleepDisabled", "Turn Off App Nap", "Hidden apps keep running at full speed.",
               image: "CoreFoundation", preview: "A hidden app's timer still ticking",
               caution: "Uses more battery: App Nap is what keeps background apps light."),
        appKit("Windows", "NSToolTipAutoWrappingDisabled", "Long Tooltips on One Line", "Tooltips no longer wrap.",
               preview: "A long tooltip stretched on one line", caution: experiment()),
        appKit("Windows", "NSFullScreenTransitionDuration", kind: .float, control: .number(0...2, step: 0.05, unit: "s"),
               "Full Screen Transition", "How long a window takes to enter full screen.",
               preview: "A window growing into full screen at the chosen pace", caution: experiment()),
        // Version Browser Zoom is one switch, under Animations (NSDocumentRevisionsWindowTransformAnimation).
        appKit("Windows", "NSSplitViewItemFullscreenEdgeRevealDelay", kind: .float,
               control: .number(0...2, step: 0.05, unit: "s"), "Full-Screen Sidebar Reveal",
               "How long the pointer waits at the edge before a hidden sidebar slides in.",
               preview: "A sidebar sliding in at a full-screen window's edge", caution: experiment()),
        appKit("Controls", "NSSwitchDefaultAnimationDuration", kind: .float, control: .number(0...1, step: 0.05, unit: "s"),
               "Switch Flip Time", "How long an on/off switch takes to slide.",
               preview: "A switch knob snapping across", caution: experiment()),
        appKit("Controls", "AppleHighlightColor", kind: .string,
               control: .choice([
                   .init(.string("0.698039 0.843137 1.000000 Blue"), "Blue"),
                   .init(.string("0.968627 0.831373 1.000000 Purple"), "Purple"),
                   .init(.string("1.000000 0.749020 0.823529 Pink"), "Pink"),
                   .init(.string("1.000000 0.733333 0.721569 Red"), "Red"),
                   .init(.string("1.000000 0.874510 0.701961 Orange"), "Orange"),
                   .init(.string("1.000000 0.937255 0.690196 Yellow"), "Yellow"),
                   .init(.string("0.752941 0.964706 0.678431 Green"), "Green"),
                   .init(.string("0.847059 0.847059 0.862745 Graphite"), "Graphite"),
               ]),
               "Text Highlight Colour", "The colour behind selected text.", image: "AppKit and HIToolbox",
               preview: "Selected text turning pink",
               caution: "Choosing an accent colour in System Settings writes this again."),
        appKit("Fonts", "AppleFontSmoothing", kind: .int,
               control: .choice([.init(.int(0), "Off"), .init(.int(1), "Light"), .init(.int(2), "Medium"), .init(.int(3), "Strong")]),
               "Font Smoothing", "Stroke thickening on text. Off gives thinner, crisper text.", image: "CoreFoundation",
               preview: "The same paragraph thin and thick",
               caution: "On Retina displays macOS may only tell Off from on."),
    ]

    // MARK: Quick Look (the panel runs inside each app, so it reads the global domain)

    private static func quickLook(_ key: String, kind: PersonalKind = .bool, control: PersonalControl? = nil,
                                  _ title: String, _ detail: String, fallback: PersonalValue? = nil, preview: String,
                                  experimental: Bool = false) -> PersonalSetting {
        appKit(in: .quickLook, "Quick Look", key, kind: kind, control: control, title, detail, image: "QuickLookUI",
               fallback: fallback, preview: preview,
               caution: experimental ? experiment("A Quick Look panel default with no setting anywhere.") : nil)
    }

    static let quickLookSettings: [PersonalSetting] = [
        quickLook("QLHidePanelOnDeactivate", "Hide When Switching Apps", "The preview closes when its app goes to the back.",
                  fallback: .bool(true), preview: "The Quick Look panel vanishing on ⌘-Tab"),
        quickLook("QLEnableSwipeWithScroll", "Swipe Between Items", "Two-finger swipes move to the next file.",
                  preview: "Previews sliding left and right"),
        quickLook("QLMarkupEnabled", "Markup Button", "The pen button in the preview toolbar.",
                  preview: "The markup pen in the panel's toolbar"),
        quickLook("QLEnableSelectionCycling", "Wrap Around Items", "Going past the last file returns to the first.",
                  preview: "The last preview looping to the first", experimental: true),
        quickLook("QLPreviewKeepConstantWidth", "Keep Panel Width", "The panel keeps its width from file to file.",
                  preview: "Previews of different sizes in one fixed-width panel", experimental: true),
        quickLook("QLPanelMaxSizeMargin", kind: .float, control: .number(0...200, step: 10, unit: "pt"),
                  "Screen Margin", "Space kept between a large preview and the screen edge.",
                  preview: "A big preview stopping short of the screen edges", experimental: true),
        quickLook("QLPreviewPanelAutoResetLocationDelay", kind: .float, control: .number(0...120, step: 5, unit: "s"),
                  "Forget Panel Position After", "How long before the panel goes back to its default place.",
                  preview: "The panel reappearing where you left it", experimental: true),
    ]

    // MARK: Haptics and Force Touch (next to the trackpad settings)

    private static let trackpadDomain = "com.apple.AppleMultitouchTrackpad"
    private static let bluetoothPad = ["com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    private static let padCaution = "The trackpad driver reads this at login. System Settings may show the old value until then."

    static let hapticSettings: [PersonalSetting] = [
        PersonalSetting(.input, "Haptics", domain: trackpadDomain, key: "ActuationStrength", kind: .int,
                        control: .choice([.init(.int(0), "Silent"), .init(.int(1), "Normal")]), title: "Click Sound",
                        detail: "Silent clicking makes the haptic click nearly inaudible.", effect: .logout, fallback: .int(1),
                        evidence: "dyld shared cache string ActuationStrength" + tail, preview: "A click with no tick",
                        mirrors: bluetoothPad, caution: padCaution),
        PersonalSetting(.input, "Haptics", domain: trackpadDomain, key: "ActuateDetents", kind: .int,
                        control: .toggle(on: .int(1), off: .int(0)), title: "Force Click Bumps",
                        detail: "A haptic tick as you press through a Force Click.", effect: .logout, fallback: .int(1),
                        evidence: "dyld shared cache string ActuateDetents" + tail, preview: "A pulse under a pressing finger",
                        mirrors: bluetoothPad, caution: padCaution),
        PersonalSetting(.input, "Haptics", domain: trackpadDomain, key: "SecondClickThreshold", kind: .int,
                        control: .choice([.init(.int(0), "Light"), .init(.int(1), "Medium"), .init(.int(2), "Firm")]),
                        title: "Force Click Pressure", detail: "How hard the deeper press must be.", effect: .logout,
                        fallback: .int(1), evidence: "dyld shared cache string SecondClickThreshold" + tail,
                        preview: "A pressure gauge filling deeper", mirrors: bluetoothPad, caution: padCaution),
        appKit(in: .input, "Haptics", "com.apple.trackpad.forceClick", "Force Click", "Press harder for look-up and previews.",
               image: "AppKit and CoreFoundation", fallback: .bool(true), preview: "A word's definition popping up under a hard press",
               effect: .logout),
    ]

    // MARK: Hidden Dock motion, decoded by REA from DockGlobals' initialiser

    private static func dockMotion(_ key: String, _ title: String, _ detail: String, range: ClosedRange<Double>,
                                   fallback: Int, preview: String) -> PersonalSetting {
        PersonalSetting(.animations, "Dock (Hidden)", domain: "com.apple.dock", key: key, kind: .int,
                        control: .number(range, step: 1, unit: ""), title: title, detail: detail, effect: .restart("Dock"),
                        fallback: .int(fallback),
                        evidence: "REA: DockGlobals init reads \(key) as Int, default \(fallback)" + tail, preview: preview,
                        caution: "Experimental. The unit is Dock's own; start near the default.")
    }

    static let hiddenDockMotionSettings: [PersonalSetting] = [
        dockMotion("bounce-duration", "Launch Bounce Length", "How long an opening app bounces.", range: 0...240, fallback: 60,
                   preview: "A Dock icon bouncing longer or shorter"),
        dockMotion("bounce-secondary-duration", "Attention Bounces", "How many times an app bounces when it wants you.",
                   range: 0...20, fallback: 3, preview: "An icon bouncing for attention"),
        dockMotion("bounce-secondary-interval", "Attention Repeat", "The pause before an app asks for attention again.",
                   range: 1...600, fallback: 60, preview: "An icon bouncing again after a pause"),
        PersonalSetting(.animations, "Dock (Hidden)", domain: "com.apple.dock", key: "popup-delay", kind: .float,
                        control: .number(0.05...2, step: 0.05, unit: "s"), title: "Hold for Menu",
                        detail: "How long a held click on a Dock item waits before its menu opens.", effect: .restart("Dock"),
                        fallback: .float(0.5),
                        evidence: "REA: Dock reads popup-delay as a float; 0 or less falls back to 0.5" + tail,
                        preview: "A Dock menu opening under a held click",
                        caution: "Experimental. What the delay governs is inferred from its name."),
    ]
}
