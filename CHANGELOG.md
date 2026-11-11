# Changelog

Every version ships as a beta first (GitHub pre-release, Beta channel), and is promoted to a
stable release once it has been tested. The sections below are the release notes the updater
shows.

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
