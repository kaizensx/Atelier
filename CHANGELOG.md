# Changelog

Every version ships as a beta first (GitHub pre-release, Beta channel), and is promoted to a
stable release once it has been tested. The sections below are the release notes the updater
shows.

## [1.0.0-beta.4]

The big mods release: plugins grow into small apps, six new kinds of mod, a kit for making them,
and a catalog you can trust.

**New: plugins**
- Widgets with buttons and switches, images, bar/line/area charts, grids, progress bars and
  dividers, with animated changes. Views may hold up to 240 elements.
- Settings declared in the manifest (text, numbers, switches, choices, colours, shortcut hints,
  secrets), drawn on the plugin's page. Secrets go to the Keychain.
- Hooks into Atelier: answers in the Command palette (with an optional prefix, like `gh`), menu
  bar items with menus, Dock tile menus and drops (links and text only, never files), stacks
  from plugins, live activities under the menu bar, Scenes, and small windows of the plugin's
  own HTML with no network and no files. New permissions: Menu Bar, Live Activities, Scenes,
  Windows.
- Plugin Dock tiles on the Atelier Dock (Dock › Tile › From Plugins, or Add to Dock on the
  plugin's page).
- Start on demand (a command, a widget on screen, a tile click, a hot corner, a timer, an event)
  and sleep after 10 idle minutes; their commands, widgets and tiles show while asleep.
- POST, PUT, PATCH and DELETE to the plugin's allowed sites; messages between plugins that list
  each other; translations; new events (update, settings changed, sleep and wake, screen locked
  and unlocked, displays changed, power source).
- Load Plugin Folder… runs a plugin from its folder and restarts it on every save. A plugin's
  details show its activity and network requests.
- Safe mode: after two crashed launches in a row with plugins running, Atelier starts with
  plugins off and says which were running.
- Examples: Pomodoro 1.1 (buttons, settings, a week chart) and GitHub Hub (every hook).

**New: packs (data only, nothing runs)**
- Icon packs, sound packs, shader packs (live wallpapers from Atelier's own shaders), snap
  layout packs, minimise effect packs, and Looks that wear a theme, wallpaper, Dock settings,
  icons and sounds at once (Revert puts all of it back). Every file is checked before use.
  Formats in docs/PACKS.md; one example of each in the catalog.

**New: making mods**
- Mods › Create: a playground with a code editor, templates, the live result beside the code
  and a console; Save as Plugin installs it.
- `atelier-mod`, a command-line kit (new, validate, test, pack, catalog-entry), editor types for
  the whole API, the Making mods guide and a Make a mod page on the website.

**New: catalog and trust**
- Authors can sign their own packages; a mod whose signing key changes waits for your OK.
- Roll back to the previous version, or install any version from the history.
- Updates that ask for new permissions or sites show the difference and ask first; Update All
  skips them.
- Featured this week, collections, author pages, install counts and likes (from GitHub's own
  counts; Atelier sends nothing), and Discuss on GitHub.
- Export Setup… and Import Setup… carry your mods, which plugins are on and your theme or Look
  to another Mac. Secrets are never included.

**Fixed**
- The website's Mods pages no longer show the offline-copy notice when the catalog loads, and
  show a new mod version without waiting for the site to rebuild.

## [1.0.0-beta.3]

**New**
- Mods: an installed plugin's page now has **In Atelier**, listing where it shows up (Dock tile,
  widgets, commands, hot corner actions) with a button to each. The author's description stays.

**Improved**
- Mods and Themes & Plugins are one place now: Mods › Library holds your themes and the theme
  designer.
- Installed mods: click a row to open its page; plugins have their on/off switch right in the row.

**Fixed**
- A plugin asking for text (like the GitHub token) now opens a clear Atelier window with its
  question, instead of an empty one.
- Installing a plugin from its page now asks for its permissions right away.
- "Open in Atelier" on the website opens that mod's page.
- GitHub Notifications 1.0.1 asks for the token once; later, use Set GitHub Token.
- Opening another place in the Studio starts at its top, not at the last place's scroll position.

## [1.0.0-beta.2]

**New**
- Mods: browse, install, update and remove community plugins and themes right inside Atelier.
  The catalog lives at github.com/kaizensx/atelier-mods; every index is signed and every
  package is checked before it is unpacked. Plugins still ask before they get any permission.
- Settings links now open on the exact setting, from the Dock's Vitals menu and elsewhere.

**Improved**
- Minimising into the Atelier Dock lands exactly on the window's own tile, which appears as the
  window starts to shrink, and restores from it. The hidden macOS Dock's own animation is hidden
  under a live strip, so nothing flickers behind.
- Taking Accessibility away is noticed within seconds; Caps Lock is handed back at once.
- Quitting Atelier from Terminal (`kill`) is now a clean quit that puts everything back.
- A stale or broken Dock Bridge can always be removed or updated.
- The attention bounce says plainly that macOS 27 does not offer it; badges still show.

## [1.0.0-beta.1]

The first public build of Atelier.

**New**
- A new identity: the Facet mark, a hand-drawn wordmark and an icon rendered at 8K.
- Updates from GitHub, built in: Settings → Updates, with Stable and Beta channels. Every
  download is checked against Atelier's Ed25519 signature before it is installed, and the
  previous version is kept for Roll Back.
- Radial Window Menu: hold ⌃⌥ and point to place the front window.
- Edge Stash: ⌘-drag a window to a screen edge to tuck it away; hover to bring it back.
- Display Memory: every combination of displays remembers where your windows were.
- External Monitors: hardware brightness, contrast, volume and input over DDC/CI.
- Fan Control: Silent, Balanced, Max or your own curve, through an opt-in helper that always
  hands the fans back to macOS if anything goes wrong.
- Gestures and Peek for the Atelier Dock.
- Minimise into the Atelier Dock with a real Genie that follows your macOS setting, or one of
  eight new effects: Magic Lamp, Fold, Dissolve, Portal, Liquid, Glass Shatter, Scale and Suck.
  Shift-click for slow motion.
- Sound Mixer with a per-app equaliser, Title Bar Gestures, Notch-Free mode, HiDPI virtual
  displays and every hidden display mode.

- A Permissions screen on first launch: what each permission unlocks, one button that puts Atelier
  in the right macOS list, live status, and a step-by-step fix when macOS keeps a stale entry.

**Fixed before launch** (from a full review and live tests in a macOS VM)
- Atelier Dock: only the right app bounces; minimised windows fly into the Atelier Dock; hover
  previews never stick; window previews are on by default and fall back to icons and titles
  without Screen Recording; separators are visible; side docks are fully visible, also on the stage.
- A richer Vitals tile: readings, style, colours, refresh rate and click action.
- Windows snap above the Atelier Dock, never under it.
- Features that need Accessibility or Screen Recording say so, with a Grant button, and start by
  themselves within seconds of the permission being given, no relaunch.
- Hold ⌘Q works with every keyboard layout. Below Black now only acts below 25% brightness;
  Below Black and Candlelight work while XDR Boost is on.
- Menu Bar Hider and Hide the Menu Bar work on macOS 27; Clean Desktop keeps the desktop reachable.
- Live Wallpaper thumbnails always show; theme and plugin examples ship with the app.
- Toolbox tools never freeze Atelier and can be cancelled; nine new typing sound packs.
- No more squeezed or cut text anywhere: settings rows rearrange themselves when space is short.
- Remove Everything now puts every macOS change back and quits; "Revert All macOS Changes" does
  the same and keeps Atelier. The calculator in Command can no longer crash the app.
- Duplicated settings now live in one place each.

**Improved**
- XDR Boost reaches 2.4× at full brightness, follows the brightness keys frame by frame, and
  waits out low battery instead of switching itself off.
