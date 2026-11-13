# Atelier feature reference

Every place in Atelier's sidebar, every card on it, what each setting does, what it needs from
macOS, and how to drive it from the command line. Places appear here in sidebar order
(`Sources/DockStacks/NavRegistry.swift`).

Conventions used below:

- **Needs** is the permission or hardware a feature asks for. Nothing is asked for until you turn
  the feature on. "None" means it works with no permission at all.
- **Hook** is an `atelier://` URL that drives the feature without the UI, for testing a build.
  Run one with `open "atelier://…"`. Hooks that report write a text file to `$TMPDIR`.
- **Beyond macOS** marks a headline card: something a stock Mac cannot do. These cards open with a
  live plate; the plate itself is the switch.
- Every feature checks the Mac first (`FeatureAvailability`) and says why when it cannot run, for
  example "Needs macOS 15" or "This Mac has no fan". See [COMPATIBILITY.md](../COMPATIBILITY.md).

## General hooks

| Hook | What it does |
|---|---|
| `atelier://studio?chapter=<id>` | Opens Atelier at a place, for example `chapter=engine`. |
| `atelier://command` | Toggles the Command palette. |
| `atelier://grant` | Shows the Accessibility prompt. |
| `atelier://diag` | Writes permission state, frame timing and every engine's diagnostics line to `$TMPDIR/atelier-diag.txt`. |
| `atelier://statedump` | Writes every catalogue setting as Atelier reads it to `$TMPDIR/atelier-state.tsv`, to compare with `defaults read`. |
| `atelier://effect?<key>=<value>` | Sets desktop effects and a few other switches: `skin`, `clock`, `focus`, `shelf`, `rounded`, `living`, `pulse`, `ripples`, `line`, `glow`, `widgets`, `clockstyle`, `focusmin`, `focusstop`, `flash`, `dockedge`, `docksize`, `layout`, `shuffle`, `compare=before|after`, `photo`, `restorewallpaper`, `replace`, `owndock`, `orbit`, `board`, `widget`, `livewall`, `shader`, `look`. |
| `atelier://open?name=<stack>` | Opens a stack's bubble by title. |
| `atelier://theme?url=<https url>` | Asks, then downloads, validates and installs a shared theme (see [THEMES.md](THEMES.md)). |

---

## Your Mac

### Home

No panel of its own. The stage (a live replica of your Mac) stands at the top; under it, the
shelf: a counter of what Atelier has changed, then one tile per thing a stock Mac cannot do (XDR
Boost, Atelier HUD, Trackpad Gestures, Window Superpowers, Thermals, Instant Spaces and more).
Hovering a tile plays it on the stage; clicking it opens its place. Live readings sit at the
stage's top right, sampled only while Home is on screen.

- **Search:** ⌘F in the window searches every place and every catalogue setting, and jumps to the
  row with it lit.
- **Command:** ⌥Space (Settings › Shortcuts) searches Atelier, your apps and clipboard history.

### Looks

Curated themes, shown as miniature Macs. Rest on a card to try it on the stage; click to apply it
to the whole Mac; **Revert** undoes the run.

| Card | Settings | Needs |
|---|---|---|
| Looks gallery | Apply, Revert, Make your own. Icon styles (Clear, Tinted) apply on macOS 26 and later only. | None |
| Change with the Day *(Beyond macOS)* | Each Look takes over as its hour arrives. | None |

### Mods

Community plugins, themes and packs from the signed catalog at github.com/kaizensx/atelier-mods.

- **Browse:** search, filter by Plugins or Themes, or by a pack kind (Icon Packs, Sound Packs,
  Shaders, Layouts, Effects, Looks), open a mod's page (screenshots, description, permissions,
  version history) and install it. Plugins ask for their permissions right after.
- **Packs:** data-only mods, checked file by file before use ([PACKS.md](PACKS.md)). An installed
  pack's page previews it: an icon grid (click an icon to keep that app's own), play buttons for
  each sound, a moving shader, zone diagrams, a live minimise plate per effect, and what a Look
  sets. **Use**, **Wear** or **Add to Layouts** puts it to work.
- **Installed:** every mod on this Mac. Click a row to open its page; plugins have their on/off
  switch in the row; hold **Remove** to take one out.
- **Updates:** newer versions from the catalog, one at a time or all at once.
- **Settings:** on an installed plugin's page, above In Atelier, the settings the plugin declares
  (text, numbers, switches, choices, colours, shortcut hints and secrets). Secrets go to the
  Keychain and are never shown again.
- **In Atelier:** on an installed plugin's page, where it shows up: its Dock tile, widgets, commands
  (with Run) and hot corner actions, each with a button to its place. The author's description
  stays as written.
- **Safe mode:** after two launches in a row that ended in a crash while plugins ran, Atelier
  starts with plugins off and names them here, with a button to turn them back on.
- **In Atelier:** on an installed plugin's page, where it shows up: its Dock tile (with Add to
  Dock), widgets, commands (with Run), hot corner actions, palette searches, stacks, menu bar items
  and windows, each with a button to its place. The author's description stays as written.
- **Links:** "Open in Atelier" on the website opens the mod's page.

### Mods › Library (themes and plugins)

A theme restyles everything Atelier can reach from one `.ateliertheme` file. Plugins add widgets,
Dock tiles, commands and corner actions in JavaScript, each in its own sandboxed engine. Plugin
widgets can have buttons, switches, charts, images and grids; plugins can start only when used
and sleep when idle.
Dock tiles, commands and corner actions in JavaScript, each in its own sandboxed engine, and plug
into Atelier's own features: searches in the Command palette (`gh …`), menu bar items, Dock tile
menus and link drops, stacks for the Atelier Dock (Stacks › From Plugins), live activities under
the menu bar, Scenes, and small HTML windows with no network.

- **Make and share:** drop a `.ateliertheme` or `.atelierplugin` on the tiles; Create Theme from my
  Mac; Import Theme; Open Theme Link; export.
- **Load Plugin Folder…:** runs a plugin straight from its folder, marked Development, and
  restarts it on every save, keeping its storage.
- **Plugin details:** its settings, and its activity: calls and script time per minute and its
  recent network requests (method, host, path, status, time, size).
- **Your packs:** every installed pack by kind, with its action, an inline preview and Remove;
  **Add Pack…** installs a pack folder. Packs also open from Finder.
- **Where packs show up:** sound packs in Dock › Sounds and Typing Sounds (Built-in by default),
  shader packs in Live Wallpaper › From shader packs, effect packs in Window Minimise Effect,
  layout packs in Window Engine's custom layouts, icon packs on every app tile Atelier draws.
- **Formats:** [THEMES.md](THEMES.md), [PLUGINS.md](PLUGINS.md), [PACKS.md](PACKS.md), [atelier-theme.schema.json](atelier-theme.schema.json).
- **Needs:** none. Each plugin asks for its own permissions (`notifications`, `openURL`, `network`,
  `appearance`, `menuBar`, `liveActivities`, `scenes`, `panels`) on a sheet before it runs.

---

## Desktop

### Wallpaper

| Card | What it does | Settings | Needs |
|---|---|---|---|
| Generated Wallpaper *(Beyond macOS)* | Wallpapers painted by the GPU at the main display's exact pixel size from curated five-colour palettes, set as the real desktop picture. Repainted as the light changes through the day. | Palette, Light (follows the clock or held), From Your Wallpaper palette, restore the original wallpaper. | Metal (without it the cards preview but cannot paint). |
| Wallpaper Library | Photographs from Wikimedia Commons featured pictures, the NASA image library, Bing's daily image (last week), and Unsplash. Authors are credited. | Source, New Wallpaper Every Day, Use *source* for Daily. Unsplash needs your own free Access Key. | Network, only when used. |

### Live Wallpaper

| Card | What it does | Settings | Needs |
|---|---|---|---|
| Live Wallpaper *(Beyond macOS)* | Metal shaders on the desktop at the display's own rate; it sleeps when nothing shows. Eighteen shaders: Liquid Light, Nebula, Aurora Silk, Topography, Glass Rain, Silk Waves, Gradient Mesh, Starfield, Retro Horizon, Ocean Caustics, Northern Lights, Lava Lamp, Ink in Water, Fireflies, Liquid Chrome, and three that paint with your own wallpaper (Rain, Ripple, Depth). | Shader and its tuning, palette, Follow Pointer, Light, Pause on Battery, Time of Day, Change with the Day (By Day / By Night), Same on Every Display. | None |
| Still Background *(Beyond macOS)* | A gradient painted once and held above your wallpaper. Costs nothing while it shows. | Palette. | None |
| Website Wallpaper *(Beyond macOS)* | Any web page as the desktop, one web view per display at desktop level. Your wallpaper setting is never touched. | URL, Browse It (clicks reach the page), Reload interval. | Network |
| Original Wallpaper | The way back to the picture you had. | Restore. | None |

Hooks: `atelier://effect?livewall=1|0`, `atelier://effect?shader=<name>`, `atelier://effect?living=<hue>`.

### Widgets

A desktop board of widgets. Positions, sizes and styles are saved per display.

- **Kinds (27):** calendar, notes, rings, clocks, big clock, pomodoro, activity, network, battery,
  vitals, progress, countdown, moon, sticker, photo, slideshow, weather, events, reminders,
  checklist, habits, launcher, stopwatch, devices, clipboard, storage, stack.
- **Settings:** Widget Board switch, Interactive Widgets, Own Style per widget, Apply to Every
  Widget, saved layouts (Layouts card), colours in harmony with the Look (Harmony card), and
  per-widget options such as Fahrenheit, Southern Hemisphere, Rotate and Pomodoro.
- **Needs:** Calendars for events, Reminders for reminders (ticking one completes it in Reminders).
  Weather uses Open-Meteo: no key, no account, only the city you pick is sent.
- **Hooks:** `atelier://effect?board=1|0`, `atelier://effect?widget=…`, `atelier://effect?widgets=1|0`.

### Effects

"Things macOS does not do. Overlays are click-through, cost nothing while off, and go when you quit."

| Card | What it does | Needs |
|---|---|---|
| Focus Light *(Beyond macOS)* | Everything behind the front window steps back into shade. Setting: Shade. | Accessibility |
| Notch Shelf *(Beyond macOS)* | Drag files to the top of the screen and they wait there. Falls back to top centre without a notch. | None |
| Menu Bar Hider *(Beyond macOS)* | A divider and an arrow tuck menu bar icons out of sight. Public API only; some system items may not move. | None |
| Ambient: Edge Glow, App Pulse, Dock Glow, Day Line | A rim in the colour of the app you are in; a flash as you switch apps; light pooled under the real Dock; a hairline under the menu bar that fills as the day passes. | None |
| Screen: Rounded Screen, Vignette, Film Grain, Night Tint | Soft corners; a lens-like darkening; a still grain; a warm tint on a schedule that fades in over 45 minutes and works beside Night Shift. | None |
| Designer Tools: Pixel Grid, Ruler, Colour Picker, Annotate | Hairlines on whole points; a crosshair with coordinates (drag to measure, ⌘C copies); the system loupe with the hex value copied; draw on screen. Open from here, a shortcut or a hot corner. Escape leaves. | None |
| Show Keystrokes, Click Ripples | Shortcuts (or Every key) at the bottom of the screen, and a ripple wherever you click, for presenting. | Accessibility for keystrokes |
| Clean Desktop | Hides desktop icons with Finder's own setting; Put icons back when Atelier quits. | None |
| Caffeinate | Keeps the Mac awake for a while or until stopped. | None |

Hooks: `atelier://effect?focus=1`, `shelf=1`, `rounded=<radius>`, `pulse=1`, `ripples=1`, `line=1`, `glow=1`, `skin=<preset>`.

---

## Dock & Launch

### Dock

One place for the Atelier Dock and Apple's Dock.

| Card | What it does | Settings | Needs |
|---|---|---|---|
| Atelier Dock *(Beyond macOS)* | A dock of its own in place of the macOS one. If Atelier crashes, its guard agent brings the macOS Dock back. | Atelier Dock, Replace System Dock, Position, Auto-hide, Slide Speed, On Every Desktop, Over Full-Screen Apps, Display, Show On, Focus Mode, Badges, Attention Bounce, Click to Hide, Scroll for Windows. | None |
| Design | Ten designs: Liquid Glass, Floating Islands, Neon Rim, Frosted Ceramic, Aurora, Minimal Line, Holographic, Retro CRT, Paper, Dark Metal. Running indicators (classic, LED, Pixel, Ink, Beam). Effects: reflection, icon shadow, launch halo. | Design, glass finish, icon treatment, effects. | None |
| Magnification *(Beyond macOS)* | Spring physics: a fast sweep spreads the lens, a slow one tightens it. | On/off. | None |
| Items and tiles | Apps, folders, stacks, spacers and separators; Open Apps Only; live tiles and rings for your Mac's state (up to four rings). | Per tile. | None |
| Profiles | Save the dock as a named profile; Switch by Desktop; Switch by Time of Day (Day / Night). | — | None |
| Reserve Dock Space | Keeps zoomed and tiled windows clear of the Atelier Dock. | On/off. | Accessibility |
| Minimise into the Atelier Dock | The yellow button and ⌘M fly a picture of the window into the Atelier Dock. | On/off. | Accessibility, Screen Recording for the picture |
| Dock Gestures *(Beyond macOS)* | On Atelier Dock tiles: swipe up for that app's windows (or bring back a minimised one), swipe down to minimise (or hide), pinch to quit after a second pinch (off unless asked for). Live Peek window pictures with close and minimise buttons. | Swipe up, Swipe down, Pinch to quit, Scroll for Windows, Window previews, Close and minimise buttons. | Accessibility; Screen Recording for pictures (without it Peek lists icons and titles) |
| macOS Dock | Apple's own Dock settings: Magnification, Position, Auto-hide, Recent Apps, Full Width, Spacers. | — | None |
| Dock Peek *(Beyond macOS)* | Hover an app in the macOS Dock to see its windows; swipe, pinch and scroll on its icons. No injection: SIP stays on. | Window previews, delay, Scroll to hide and show, gestures. | Accessibility; Screen Recording for pictures |
| Dock Glow | Light pools under the real Dock. | On/off. | None |

Hooks:
- `atelier://dockgestures?…` — `on=1|0`, `up=expose|restore|none`, `down=minimize|hide|none`,
  `pinch=1|0`, `buttons=1|0`; `simulate=swipeUp|swipeDown|pinch&app=<id>` (`confirm=1` quits at
  once); `feed=up|down|left|right&app=<id>`; `show=<id>`, `hide`; `button=close|minimize&index=N`;
  `report` → `$TMPDIR/atelier-dockgestures.txt`.
- `atelier://dockpeek?…` — `on=1|0`, `previews=1|0`, `delay=0.5`, `gesture=minimize:0`;
  `simulate=minimize|restore|hide|show|quit&app=<name>`; `show=<name>`, `hide`; `report` →
  `$TMPDIR/atelier-dockpeek.txt`.
- `atelier://effect?owndock=1|0`, `replace=1|0`, `dockedge=left|bottom|right`, `docksize=64`.
- `atelier://mintest[?up]`, `atelier://icontest?id=<tile>[&reset]`, `atelier://previewtest?<design>`.

### Stacks

One list of every stack in either dock, plain or smart, each with a four-tab inspector (content,
icon, bubble, behaviour). Smart Stacks fill themselves from a source, such as a Spotlight search
(screenshots, for example) or a folder. Opens as a bubble with search, grouping and a running dot.
**Needs:** none.

### Orbit

Your apps in rings over any desktop, sorted by what each app does, searched by typing.

- **Theme:** the look, sky and motion together.
- **Layout and look:** Rings, Ring Lines, Labels, Label Type, Dark Labels, Running Indicators,
  Recent Apps, Tint Colour.
- **Sky:** Nebula, Nebula Colour, Starfield, Live Wallpaper Behind.
- **Motion:** Drift, Direction, Opening.
- **Apps:** Sort, Arrange Apps.
- **Search:** Type to Search, Fuzzy Matching, System Settings, Files, Wrap Around, ⌘1 to ⌘9.
- **Open it with:** Orbit Shortcut, Mouse Button, Display.
- **Needs:** none. Hook: `atelier://effect?orbit=1`.

### Hot Corners

| Card | What it does | Needs |
|---|---|---|
| Atelier Hot Corners *(Beyond macOS)* | Eight spots, not four: the corners and the middle of each edge, each with its own action, modifier keys and wait. Actions: Orbit, Command, Atelier Dock, Widgets, Focus Light, Show Desktop, Mission Control, App Exposé, Launchpad/Apps, Lock Screen, Sleep Display, Screen Saver, Screenshot, Window Layout, Shuffle, Quit Front App, Hide Others, Annotate, Find Cursor, Colour Picker, Open, Run Shortcut, a plugin's action. Settings: Pause in Full Screen, Pause While Dragging, Ripple. | Accessibility for window and key-sending actions |
| Apple's hot corners | macOS's own four corners. | None |

---

## Menu Bar

### Menu Bar

| Card | What it does | Settings | Needs |
|---|---|---|---|
| Thermals & Power *(Beyond macOS)* | CPU and GPU temperature, fan speed and system power in the menu bar; a click opens the last two minutes as sparklines. Read from the SMC and the chip's die sensors, never written. Fanless Macs hide fans; desktops hide battery. | — | None |
| Fan Control *(Beyond macOS)* | Fans by your own curve or at full speed. Presets: Automatic, Silent, Balanced, Max, Custom. Once a second the app reads the hotter of CPU and GPU and writes a target per fan; the helper hands the fans back to macOS when that heartbeat is 10 s old, on quit, on sleep and on removal. Never below a fan's minimum. | Preset, curve, Safety limit (above it the fans run flat out until it cools 8°), Fan helper install / remove. | Administrator password once, to install the `AtelierFans` root helper (a LaunchDaemon). A Mac with fans. |
| Instant Spaces *(Beyond macOS)* | Switch desktops with no slide (about 35 ms on macOS 27.3, against about a second for Control-Arrow). Send the focused window to another desktop from the keyboard, the menu bar or a drag. Falls back to Control-Arrow when the instant switch does not land. | Instant switching, Desktop Shortcuts. | Accessibility |
| Menu Bar Calendar *(Beyond macOS)* | Today's date in the menu bar; a click shows the month, week numbers and the day's events. | Week Numbers, Show Events. | Calendars, only with Show Events on |
| Spaces in the Menu Bar | Which desktop you are on, as dots, numbers or your own names. Click to jump. | Style, names. | None (jumping uses Instant Spaces) |
| Skin | Gradients and materials painted behind the real menu bar, one click-through panel per bar. | Skin, Floating Bar, Lower Edge, Notch Blend, Motion, Wallpaper Changed?, Keep Text Readable, Night Skin / At Night. | None |
| Day Line | A hairline under the menu bar that fills as the day passes. | On/off. | None |

Hooks:
- `atelier://fans?report | mode=silent|balanced|max|custom|system | on=0|1 | curve=55:0,68:0.3,80:0.7,90:1 | limit=95 | dryrun=40,60,80|ramp [&dt=1] | probe | helper=install|remove|status` → `$TMPDIR/atelier-fans.txt`.
- `atelier://spaces?go=N | send=N | instant=0|1 | refresh` (N is the 1-based desktop number).
- `atelier://calendar[?on=1|0 | close]`.

### Control Center

macOS's Control Center and menu bar items by section: battery percentage, Wi-Fi, Bluetooth, Sound,
Now Playing, Focus, the clock (24-hour, seconds), hiding the menu bar. **Needs:** none.

---

## Windows

### Window Engine

"Windows that glide into place, on keys and edges you own." Almost everything here moves other
apps' windows, so the chapter asks once for **Accessibility**; until it is granted the controls stay
off and the rest of Atelier works as usual.

**Window superpowers**

| Card | What it does | Settings |
|---|---|---|
| Window Borders *(Beyond macOS)* | A ring of light follows the window you are working in. Public pieces only: an Accessibility observer and a click-through panel. | Width, Glow, Corners, colour. |
| Move & Resize Anywhere *(Beyond macOS)* | Hold a chord and drag anywhere inside a window to move it; right-drag resizes from the nearest corner. | Chord, Raise When Grabbed. |
| Window Switcher *(Beyond macOS)* | Every window, not just every app: hold the modifier, tap the key, let go. Titles and shapes from Accessibility; nothing is captured. | Modifier, key. |
| Edge Stash *(Beyond macOS)* | Hold ⌘ (or ⌥ or ⌃) and drop or fling a window against the left or right edge. It slides out to a sliver with a glass tab; point at the tab to slide it back. Clicking the tab, ⌃⌥⌘↓, turning it off, quitting or a crash puts every window back exactly where it was. | Key, Return delay, Fling to Stash, Bring Forward on Peek, Keys (⌃⌥⌘← / ⌃⌥⌘→ / ⌃⌥⌘↓). |

**Snap and layouts**

| Card | What it does | Settings |
|---|---|---|
| Snap Zones | Drag a window to an edge or corner; glass shows where it will land. Escape cancels. Metrics follow macOS's own WindowManager. | On/off, gap. |
| Layouts | Halves, thirds, quarters and more, from a grid. | — |
| Radial Menu *(Beyond macOS)* | Hold the trigger and a ring of glass opens around the pointer; flick or use the arrow keys. Centre maximises, the inner ring holds halves and corners, the outer ring thirds. Escape cancels; Undo in Window Shuffle puts it back. Inspired by Loop. | Trigger (⌃⌥ by default; Hyper, Right ⌥, Right ⌘, fn), Middle Button, Thirds Ring, Haptic Tick. |

**Focus**

| Card | What it does | Settings |
|---|---|---|
| Dim Inactive Windows *(Beyond macOS)* | Everything behind your window sinks into shade; the Dock and menu bar are never touched. | Shade (10–80 %), colour (black or a hint of the wallpaper). |
| Focus Follows Mouse *(Beyond macOS)* | Rest the pointer on a window and it comes forward. Holds back over the menu bar, Dock, menus, sheets and full-screen spaces. | Delay, Hold ⌃ to Pause. |

**Display Memory**

| Card | What it does |
|---|---|
| Display Memory *(Beyond macOS)* | Remembers where every window was for each display configuration (which displays, where, at which size). When a setup returns after a plug, unplug, wake or resolution change, every window glides back. Full-screen windows are left alone and nothing is launched. Saved setups are listed and can be forgotten. |

**Keys and tools**

| Card | What it does |
|---|---|
| Hot Keys | Hold ⌃⌥, then press a key or an arrow, for a layout. |
| Window Shuffle | Every window on this display flows into a grid; press again to rotate them. Undo. |
| Workspaces | Name an arrangement and restore it later. Restoring moves windows of open apps; it never launches anything. |
| Stage Glow | A light behind the focused window, tinted by its app's icon. |
| Window tools | Global shortcuts you record yourself; Custom layouts (draw your own zones, Shift-drag a window into one); App Rules (always open an app in the same place); Pin Window. |

**Title Bar Gestures** (same chapter)

| Card | What it does | Settings |
|---|---|---|
| Title Bar Gestures *(Beyond macOS)* | Two fingers with the pointer on a title bar: swipe left or right to tile (again: next display), up to maximise (again: full screen), down to restore or centre (again: minimise), pinch in to close, pinch out for full screen. A glass slab follows the fingers. Anywhere else two fingers scroll as always. | Sensitivity, Title Bar band, Include Toolbars, Diagonal Swipes, Haptic Tick, bindings. |

Needs a trackpad. Reads the same finger stream as Trackpad Gestures.

Hooks:
- `atelier://titlebar?simulate=left|right|up|down|topLeft|topRight|bottomLeft|bottomRight|pinchIn|pinchOut [&dry=1]`, `on=0|1`, `sensitivity=`, `band=`, `reset=1`, `report=1` → `$TMPDIR/atelier-titlebar.txt`.
- `atelier://radial?on=0|1 trigger=hyper|controlOption|rightOption|rightCommand|function middle=0|1 thirds=0|1 haptics=0|1`; `simulate=<angle>&distance=<pt>`; `keys=left,left`; `show=1[&x=&y=][&angle=&distance=][&hold=s]`; `move=<angle>&distance=`; `commit=1`; `hide=1`; `apply=<layout>`; `place=x,y,w,h`; `report=1` → `$TMPDIR/atelier-radial.txt`.
- `atelier://stash?on=0|1`; `stash=front&edge=left|right[&app=<bundle id>]`; `peek=<n>|last`, `peek=0`; `unstash=all|<n>`; `report=1` → `$TMPDIR/atelier-stash.txt` (again after 1.2 s, with `settled=1`).
- `atelier://displaymemory?on=1|0 | snapshot=1 | restore=<key>|current | simulate=reconfig | forget=<key>|all | report=1` → `$TMPDIR/atelier-displaymemory.txt`.
- `atelier://effect?layout=<layout>`, `atelier://effect?shuffle=1`.

### Beyond SIP

Six window powers macOS keeps for the Dock, asked of the Dock through the **Dock Bridge**, a small
scripting addition ported from yabai. Every change is undone the moment you switch it off.

| Card | What it does |
|---|---|
| The Dock Bridge | Reads SIP, the boot argument, the installed bridge and the Dock. Steps: partly turn off SIP in recoveryOS (`csrutil enable --without fs --without debug --without nvram`), add the boot argument (Apple silicon), install the bridge to `/Library/ScriptingAdditions`, load it into the Dock (again after a Dock restart, login or macOS update). The Recovery Assistant gives a QR checklist for this Mac, the command to copy, and on Intel a restart into Recovery. Uninstall takes it out and every effect stops. |
| Window Opacity | See through windows you are not using, app by app (inactive only, or every window). |
| Always on Top | Keep one window above all others, from any app. |
| Sticky Windows | One window on every desktop. |
| Picture in Picture | Shrink any window into a corner and keep it playing; again to bring it back. |
| No Shadows | Flat windows everywhere; shadows return when switched off. |
| Spaces Studio | Create, remove and reorder Spaces. Off on macOS 27 until verified there. |

**Needs:** SIP partly off, an administrator password to install and load the bridge. Turning SIP
partly off lowers macOS security; the chapter says so before you start. To undo: remove the bridge,
`sudo nvram -d boot-args` while NVRAM is still unprotected, then `csrutil enable` in recoveryOS.

### Windows & Spaces

Mission Control, Spaces and Stage Manager settings in one place, then the hidden switches behind
them (resize, tiling, app switcher). Keys outside your macOS release are listed under "Not on this
macOS". **Needs:** none.

---

## Finder & Files

### Finder

Finder's own preferences by section (path bar, hidden files, sidebar, desktop icons), then
**Hidden switches** macOS keeps out of its settings. **Needs:** none; some actions may ask for Automation of Finder.

### Folder & App Icons

Folders recoloured from the system's own folder icon, with an SF Symbol, emoji or picture on top;
app icons searched on macOSicons.com (results cached for a month, credit kept). Every custom icon
Atelier sets is recorded and can be put back. **Needs:** none; network for icon search.

---

## System

### Display & Appearance

**Light** (one owner for every display's gamma table, so the three compose)

| Card | What it does | Settings | Needs |
|---|---|---|---|
| XDR Boost *(Beyond macOS)* | Brighter than Apple's maximum, in every app. A click-through window per display multiplies everything beneath it by an extended-range white, so SDR content uses the headroom macOS keeps for HDR. On a 600-nit XDR MacBook Pro, full brightness with full Boost lands at about 1,440 nits (panel peak 1,600, sustained full-screen 1,000). Engages only once EDR is on, never while the display sleeps or is locked, always as a glide, and keeps every brightness step a step. Readouts: Apple's maximum, panel peak, estimated nits now, headroom. | Boost amount. | An XDR panel (MacBook Pro 14/16 XDR, Pro Display XDR). Other HDR displays are limited; SDR displays cannot. |
| Below Black *(Beyond macOS)* | Darker than the lowest brightness step. Screenshots stay as they are. Took over from Extra Dim. | Amount. | None |
| Candlelight *(Beyond macOS)* | Warmer than Night Shift: a black body from 2,700 K down to 1,900 K. Warns when Night Shift is on too, because the two add up. | Colour temperature. | None |

Nothing here is permanent: macOS drops a process's gamma tables when it exits, even by crashing;
turning everything off restores ColorSync's own at once; a watchdog puts Atelier's tables back
after wake or display changes.

| Card | What it does | Settings | Needs |
|---|---|---|---|
| External Monitors *(Beyond macOS)* | Brightness, contrast, volume, mute and input on external monitors over DDC/CI (USB-C, Thunderbolt, DisplayPort, HDMI). The built-in panel is never addressed. Apple displays stay on macOS's own path. | Per monitor sliders, input, Brightness and volume keys (the monitor under the pointer, ⌥⇧ for quarter steps), Dim monitors without DDC (software, never to black), Put back each monitor's own settings. | None. Keys need Atelier HUD (Accessibility). |
| Atelier HUD *(Beyond macOS)* | Atelier's own volume, brightness and keyboard-light overlay in place of Apple's. Keys it cannot honour are passed to macOS unchanged. | Volume, Display Brightness, Keyboard Light, style (Pill, Island, Classic). | Accessibility |
| Keyboard Light *(Beyond macOS)* | The keyboard backlight's level, an idle time of any length, and a stay-on switch, read from and written to CoreBrightness. | Level, idle time, stay on, Adjust in Low Light. | A backlit keyboard |
| Rounded Screen Corners *(Beyond macOS)* | Soft corners on every display, above everything including full-screen apps. Clicks pass through. | Corner radius. | None |
| Display | Night Shift now (no schedule), Warmth, True Tone. | — | A display that supports them |
| Notch-Free *(Beyond macOS)* | Switches the built-in display to the 16:10 twin of its current size: a true black band hides the notch and the menu bar moves under it. Same size, same sharpness. Found from the mode list and safe area, not a model table. | On/off. | A notched MacBook |
| Display Modes | Every mode each display offers, hidden ones and every refresh rate, with a 15-second "Keep this mode?" probation. An unkept change reverts by itself, also after a crash. | Mode, refresh, Show low-resolution duplicates. | None |
| HiDPI Anywhere | A HiDPI virtual display at twice the wanted size, mirrored onto a monitor macOS calls low resolution, so text is Retina-sharp at any scaled size. | Per monitor, size. | An external monitor |
| Virtual Screens | Headless displays at any size and refresh, for sharing, recording or testing. Live while Atelier runs; quitting removes them and puts every monitor back. | Add, remove, size, refresh, HiDPI. | None |
| Dark on Your Hours | Dark from the evening hour you choose, light from the morning one. | Hours. | A release that still lets apps switch appearance |
| Light Apps in Dark Mode | Chosen apps stay light while the rest is dark. App Store apps keep their settings sealed, so they are not listed. | Apps. | None |
| Icon Studio | Icon tint and Clear / Tinted styles (macOS 26+), Atelier's own icon. | — | macOS 26 for styles |
| Appearance switches | Scroll bars, tabs and the other hidden appearance keys. | — | None |

Hooks:
- `atelier://light?simulate=lock|unlock|sleep|wake|saver|unsaver|reconfig`, `factor=<x>|off` (pins the Boost multiplier and lets screenshots see the overlay), `edr`, `noedr`.
- `atelier://notchfree?on=1|0 | mode=<ioDisplayModeID>[&display=<id>] | keep=1 | revert=1 | confirm=0 | scope=session|app|permanent | dump=1` (`dump` writes every mode to `$TMPDIR/atelier-modes.txt`).
- `atelier://virtual?add=1920x1080[@60]&hidpi=1|0 | remove=all|<uuid> | hidpi-on=<displayID>&size=1440x810 | hidpi-off=<displayID>`.
- `atelier://ddc?list` (default; `$TMPDIR/atelier-ddc.txt`), `read=0x10[&display=ID]`, `set=0x10&value=50[&display=ID]`, `brightness=0.4` / `contrast=` / `volume=`, `refresh`, `on=1|0`, `keys=1|0`, `software=1|0`, `restore=1`. Raw writes are refused outside the five allowed codes or with no external display.
- `atelier://hud?preview=volume|brightness|…`.

### Cursor & Input

| Card | What it does | Settings | Needs |
|---|---|---|---|
| Trackpad Gestures *(Beyond macOS)* | Three- and four-finger taps, two-finger taps in the top corners, one-finger swipes in from the side edges, and a firm three-finger press, each doing what you pick: Middle Click, Mission Control, App Exposé, Show Desktop, Apps, Screenshot, Lock Screen, Play / Pause, Open App, a shortcut. A live trackpad shows your fingers. macOS still sees every touch. | Action per gesture, Press firmness. | A trackpad (firm press needs Force Touch). Accessibility for Middle Click, Lock Screen, Play / Pause and shortcuts. |
| Hyper Key *(Beyond macOS)* | Caps Lock held is ⌃⌥⇧⌘; tapped alone, Escape. Uses Apple's `hidutil` remap to F18 and a keyboard tap; both undone when switched off. Pauses in password fields. | Tap for Escape. | Accessibility |
| Mouse Precision *(Beyond macOS)* | Each mouse its own acceleration and speed, linear included and faster than System Settings goes, set on the device's own HID service. | Per device curve and speed. | None |
| Wheel *(Beyond macOS)* | Flips only the wheel's direction, leaving the trackpad as macOS has it; Smooth Wheel glides each click out like a trackpad. | Reverse Mouse Wheel, Sideways Too, Smooth Wheel. | Accessibility |
| Haptics | A soft click from the trackpad itself when a window snaps or a gesture lands, played by the actuator so it works while other apps are in front. | Events. | A Force Touch trackpad |
| Mouse Buttons | Side buttons go Back and Forward, or open Mission Control. | Per button. | Accessibility; a mouse with extra buttons |
| macOS Settings | Pointer, keyboard, trackpad and typing settings, and Remap Keys. | — | None |

Hooks: `atelier://gesture?simulate=<gesture>` (`threeTap`, `fourTap`, `topLeftTap`, `topRightTap`, `swipeFromLeft`, `swipeFromRight`, `threeForce`), `atelier://gesture?haptic=light|medium|firm`.

### Sounds

| Card | What it does | Settings | Needs |
|---|---|---|---|
| Sound Mixer *(Beyond macOS)* | Every app its own volume (0–150 %), mute and output device, and a 10-band EQ for everything you hear, with its own curve per output device. Built on Core Audio process taps. Apps at 100 % on the default output are left alone: nothing inserted, no added latency. | Per-app volume, mute, output; EQ on, preset (Flat, Bass Boost, Bass Cut, Treble Boost, Vocal, Spoken Word, Loudness, Electronic, Acoustic, Classical, Rock, Late Night, Custom), bands, One curve for every output or Own curve per device. | macOS 14.2+, System Audio Recording Only (Privacy & Security › Screen & System Audio Recording) |
| Typing Sounds *(Beyond macOS)* | A soft key sound as you type, synthesised by Atelier. Password fields stay silent. | Sound, volume. | Accessibility |
| macOS Settings | Alert sound, volume feedback and the rest. | — | None |
| Your Sounds | Add your own short sounds to the alert list; removing one moves it to the Trash. | — | None |

Hook: `atelier://mixer?…` — accepts, applied in order: `on`, `app`, `volume`, `mute`, `device`, `eq`, `preset`, `band`, `gain`, `owncurve`, `reset`, `teardown`, `watch`, `dump`; then the system is read again.

### Animations · Spotlight · Lock Screen & Screen Saver · Accessibility Visuals · Quick Look

Catalogue places: macOS's own settings and hidden keys for each, by section, each checked against
the macOS releases that read it (317 keys across the catalogue). **Needs:** none.

### Every App

| Card | What it does | Needs |
|---|---|---|
| Hold ⌘Q to Quit *(Beyond macOS)* | A slip of ⌘Q does nothing; keep it down until the ring fills. Setting: Hold for. In a Secure Input field ⌘Q quits at once, as without Atelier. | Accessibility |
| macOS settings | Caret, cursor blink, font smoothing, highlight colour, scroll bars, App Nap. | None |
| All Apps | Reopen windows, keep changes, login items. | None |

---

## Tools

### Toolbox

| Card | What it does | Needs |
|---|---|---|
| Text Grab | Drag over any text on screen, even in a picture or video, with the system's own capture UI. Read on this Mac with Vision and copied; nothing kept. | macOS may ask for Screen Recording |
| Screen Recorder | The main display to Movies at 60 fps, with clicks and keys shown. Atelier stays out of the picture. | Screen Recording; Accessibility for keystrokes; macOS 15+ |
| Clipboard Actions | Rewrites the copied text as plain text and more. | None |
| Quick Look Anything | Drop files, or preview the clipboard. | None |
| Batch Rename | Tokens `{name} {n} {date} {ext}`; nothing changes until you press Rename. | None |
| Image Converter | Copies saved beside the originals. | None |
| Finder Toolbar Buttons | Small apps to ⌘-drag into a Finder toolbar. | None |
| Display Modes | Every mode, including hidden ones, with Restore. | None |
| Alerts Follow Output | Alert sounds move to the output device you use. | None |
| Timers & Alarms | A sound and a small card at the top of the screen. | None |
| Focus Island | A countdown beside the notch; the screen pulses when time is up. | None |
| Focus Session | Hides chosen apps as soon as they come forward. Quit Instead of Hiding. | None |

Pin Window lives in Window Engine's tools: a live ScreenCaptureKit copy of a window floating above
everything (needs Screen Recording).

### Capture

Where screenshots go, what they are called, their format, and the hidden switches. The recorder
lives in Toolbox; this place links to it. **Needs:** none.

---

## History

### Scenes

A scene saves the whole Dock. Hover one to see it on the stage; Apply switches the Dock in one
move; pick an hour and it switches by itself. **Needs:** none.

### Timeline

Every Dock change leaves a point. Step through earlier and later changes and **Go Back Here**.
**Needs:** none.

---

## Atelier

### Settings

| Card | What it does |
|---|---|
| Updates | Automatic checks (every few hours), Channel (Stable or Beta), Check Now, Download, Install and Relaunch, Release Notes, Roll Back to the previous version. Every download is checked against Atelier's Ed25519 key and its code signature before it is installed. See [RELEASING.md](RELEASING.md). |
| General | Studio look, Glass Mood (bubble glass follows your wallpaper), Clipboard History (text only, in memory, skips passwords). |
| Shortcuts | Command (⌥Space), stacks from the Shortcuts app. |
| Open at Login | — |
| This Mac | Model, chip, macOS, displays and what each feature can do here; "Copy for a bug report". |
| Remove Everything | Removes stacks from the Dock, deletes Atelier's data including the timeline, and quits. Hold to remove. |

Hook: `atelier://update?check=1 | channel=stable|beta | auto=0|1 | download=1 | install=1 | feed=<url of a releases.json>|default | rollback=1` → `$TMPDIR/atelier-update.txt`.
