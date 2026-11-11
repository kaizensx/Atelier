<p align="center">
  <picture>
    <img src="branding/banner.png" alt="Atelier: the Mac, made yours" width="100%">
  </picture>
</p>

<h3 align="center">The Mac, made yours.</h3>

<p align="center">
  A free, open-source studio for shaping every part of macOS: the light of the screen, the Dock,
  your windows, the sound, the menu bar. With a live replica of your Mac to try it all on first.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14%20%E2%80%93%2027-111111?logo=apple&logoColor=white" alt="macOS 14 to 27">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%2B%20Intel-universal-3b3b3b" alt="Apple silicon and Intel, universal">
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/licence-MIT-2f81f7" alt="MIT licence">
  <a href="https://github.com/kaizensx/Atelier/releases"><img src="https://img.shields.io/github/v/release/kaizensx/Atelier?include_prereleases&label=release&color=5fd3ff" alt="Latest release"></a>
  <a href="https://github.com/kaizensx/Atelier/releases"><img src="https://img.shields.io/github/downloads/kaizensx/Atelier/total?color=5fd3ff" alt="Downloads"></a>
</p>

<p align="center">
  <a href="#install"><b>Install</b></a> ·
  <a href="#what-it-does"><b>What it does</b></a> ·
  <a href="docs/FEATURES.md"><b>Full feature reference</b></a> ·
  <a href="#safety-and-reversibility"><b>Safety</b></a> ·
  <a href="#build-from-source"><b>Build</b></a> ·
  <a href="docs/README.md"><b>Themes & Plugins</b></a>
</p>

---

Most customisation apps flip switches that macOS already has, one menu deeper. Atelier's headline
features do things a stock Mac cannot do at all. The screen goes brighter than Apple's maximum,
darker than its minimum and warmer than Night Shift. Every app gets its own volume and its own
speakers. The fans follow your curve. Windows remember where they lived on every monitor setup.

Every one of these is reversible. Each feature starts off, and switching it off puts the Mac back
exactly as it was. Quitting does the same, and so does a crash. Nothing is faked: the readings
come from the hardware, the numbers in these docs were measured on a real Mac, and the motion
runs at the display's own rate, 120 Hz on ProMotion.

## A look inside

<table>
  <tr>
    <td width="50%"><img src="docs/media/studio-home.png" alt="Atelier Home: the live stage and the shelf of things a stock Mac cannot do"><br><sub><b>Home.</b> A live replica of your Mac on its stage, and a shelf of what a stock Mac cannot do.</sub></td>
    <td width="50%"><img src="docs/media/studio-dock.png" alt="The Dock chapter: Atelier Dock designs, gestures and Peek"><br><sub><b>Dock.</b> Ten designs, spring magnification, live tiles, gestures and window Peek.</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/media/studio-windows.png" alt="Window Engine: snap zones, layouts, radial menu and edge stash"><br><sub><b>Window Engine.</b> Snap, layouts, the radial menu, Edge Stash and Display Memory.</sub></td>
    <td width="50%"><img src="docs/media/studio-display.png" alt="Display and Appearance: XDR Boost, Below Black, Candlelight, Notch-Free"><br><sub><b>Display.</b> XDR Boost, Below Black, Candlelight, Notch-Free and HiDPI on any monitor.</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/media/studio-sounds.png" alt="Sound Mixer with per-app volume and a 10-band equaliser"><br><sub><b>Sounds.</b> Per-app volume up to 150 %, per-app output, and an EQ for everything.</sub></td>
    <td width="50%"><img src="docs/media/studio-menubar.png" alt="Menu bar: Thermals, Fan Control, Instant Spaces and the calendar"><br><sub><b>Menu Bar.</b> Temperatures, fans and watts, Instant Spaces, a calendar and skins.</sub></td>
  </tr>
</table>

## What it does

Atelier is laid out like its sidebar. Every place has a short intro, its headline features first,
and macOS's own settings after them, so you never need System Settings and Atelier side by side.
Rest the pointer on almost any control and the stage at the top previews it before you commit.

The tables below cover the highlights. [docs/FEATURES.md](docs/FEATURES.md) lists every card and
setting, the permission each one needs, and its `atelier://` test hook.

### Your Mac

Where you start, and where whole looks live.

| Feature | What it does | Stock macOS |
|---|---|---|
| **Home** | A live replica of your Mac, and a shelf of tiles for what a stock Mac cannot do. Hover a tile to play it on the stage. | No equivalent. |
| **Looks** | Curated themes in one click: Dock, menu bar, wallpaper, widgets and icon tint together. **Change with the Day** hands over from one Look to the next at the hour you set. Revert undoes the run. | No themes beyond Light, Dark and accent colour. |
| **Themes & Plugins** | A theme is one JSON file that restyles everything Atelier reaches. Plugins add widgets, Dock tiles, commands and corner actions in sandboxed JavaScript. See [docs/README.md](docs/README.md). | No theme or plugin system. |

### Desktop

What sits behind your windows.

| Feature | What it does | Stock macOS |
|---|---|---|
| **Generated Wallpaper** | Painted on the GPU at your display's exact size, and repainted as the light changes through the day. | Dynamic wallpapers only from Apple's set. |
| **Wallpaper Library** | Wikimedia Commons featured pictures, NASA's image library, Bing's daily image, and Unsplash with your own free key. A new one every day if you like. | No online sources. |
| **Live Wallpaper** | Eighteen Metal shaders, three of them made from your own picture. Runs at the display's rate and sleeps when nothing shows. Pause on battery. | Only Apple's video screen-saver wallpapers. |
| **Website Wallpaper** | Any web page as your desktop: a live map, a dashboard, an art piece. | Not possible. |
| **Widgets** | Twenty-seven kinds on a desktop board, from clocks, weather and vitals to reminders, habits and a launcher. Positions, sizes and styles are saved per display. | Fixed WidgetKit sizes, no system vitals. |
| **Effects** | Focus Light, Notch Shelf (drop files at the top of the screen), Menu Bar Hider, vignette, film grain, a scheduled night tint, edge glow, app pulse, pixel grid, ruler, colour picker and screen annotation. Every overlay is click-through. | None of these. |

### Dock & Launch

Your own dock, or Apple's with powers added.

| Feature | What it does | Stock macOS |
|---|---|---|
| **Atelier Dock** | A dock of its own in place of the macOS one: ten designs, spring-physics magnification, live tiles and rings, profiles that switch by desktop or time of day. Minimised windows fly into it. | One look, one dock. |
| **Dock Gestures & Live Peek** | Swipe up on a tile for that app's windows, down to minimise, pinch twice to quit. Window pictures with close and minimise buttons. | No gestures on Dock icons, no previews. |
| **Dock Peek** for the macOS Dock | Hover an app in Apple's Dock to see its windows. Swipe, pinch and scroll on its icons. No injection: SIP stays on. | No window previews. |
| **Stacks** | Folder bubbles and Smart Stacks that fill themselves from a search, in either dock. | Plain folder stacks only. |
| **Orbit** | Your apps in rings over any desktop, sorted by what each app does and searched by typing. | Launchpad, gone in macOS 26. |
| **Atelier Hot Corners** | Eight spots instead of four (corners and edge middles), each with its own action, modifier keys and wait. | Four corners, no modifiers per corner. |

### Menu Bar

Readings and shortcuts macOS keeps to itself.

| Feature | What it does | Stock macOS |
|---|---|---|
| **Thermals & Power** | CPU and GPU temperature, fan speed and the watts your Mac draws, with two minutes of sparklines a click away. Read only. | Measured every second, never shown. |
| **Fan Control** | Run the fans by your own curve, or flat out now. A small root helper does the writes; it hands the fans back to macOS if Atelier quits, hangs for 10 seconds, or the Mac sleeps. Opt-in, removable from the card. | No fan control at all. |
| **Instant Spaces** | Switch desktops with no slide, about 35 ms against a second for Control-Arrow. Send a window to another desktop from the keyboard, the menu bar or a drag. | Always animates; no "send to desktop" key. |
| **Spaces in the Menu Bar** | Which desktop you are on, as dots, numbers or your own names. Click to jump. | Not shown. |
| **Menu Bar Calendar** | Today's date, the month, week numbers and the day's events. Calendar access is asked for only when you turn events on. | Only a clock. |
| **Menu bar skins** | Gradients and materials painted behind the real menu bar, a night skin, and text kept readable. Plus a Day Line that fills as the day passes. | Not possible. |

### Windows

Windows that glide into place, on keys and edges you own.

| Feature | What it does | Stock macOS |
|---|---|---|
| **Snap, layouts and hot keys** | Snap zones on edges and corners, custom zones you draw, layouts on ⌃⌥ keys, Window Shuffle, and named workspaces you restore later. | Basic tiling from macOS 15, no custom zones or workspaces. |
| **Radial Menu** | Hold ⌃⌥ (or Hyper, Right ⌥, Right ⌘, fn, or the middle button), flick the pointer, and the window lands there. | Not possible. |
| **Title Bar Gestures** | Two fingers on a title bar: swipe to tile, up to maximise, down to restore, pinch to close. Diagonals take the quarters. | No trackpad gestures for windows. |
| **Edge Stash** | Hold ⌘ and fling a window against the left or right edge. It waits as a glowing tab; point at it to slide it back. ⌃⌥⌘← / ⌃⌥⌘→ stash the front window, ⌃⌥⌘↓ brings everything back. | Not possible. |
| **Display Memory** | Plug in, unplug, wake, change resolution: every window goes back to where it was on that setup. | macOS piles windows on whatever screen is left and never puts them back. |
| **Move & Resize Anywhere** | Hold a chord and drag anywhere in a window to move it; right-drag to resize. | Only by the title bar and edges. |
| **Window Switcher** | Every window, not just every app, on a key you choose. | ⌘Tab switches apps only. |
| **Borders, Dim and Focus** | A ring of light around the window you are in, a shade over everything behind it, Stage Glow, and focus follows mouse. | None of these. |
| **Beyond SIP** (opt-in) | Window opacity, always on top, sticky windows on every Space, picture in picture for any window, no shadows, and Spaces you create and reorder. Needs SIP partly off and the Dock Bridge; see [Safety](#safety-and-reversibility). | Reserved for the Dock itself. |
| **Windows & Spaces** | Mission Control, Spaces and Stage Manager settings, and the hidden switches behind them. | Spread across System Settings and `defaults`. |

### Finder & Files

| Feature | What it does | Stock macOS |
|---|---|---|
| **Finder** | Finder's own preferences by section, then the hidden switches macOS keeps out of its settings. | Many need Terminal. |
| **Folder & App Icons** | Folders in any colour with a symbol, emoji or picture, and app icons from macOSicons.com. Every custom icon can be put back. | Paste-an-icon only. |

### System

The display, input and sound, past where Apple stops.

| Feature | What it does | Stock macOS |
|---|---|---|
| **XDR Boost** | Brighter than Apple's maximum, in every app, not just HDR video. On recent XDR MacBook Pros it lifts the 600-nit SDR limit to about 1,440 nits at full brightness, using the headroom macOS keeps for HDR. | SDR tops out at 600 nits (500 on early XDR panels). |
| **Below Black** | Darker than the lowest brightness step, for a dark room at night. Screenshots stay as they are. | The lowest step is the floor. |
| **Candlelight** | Warmer than Night Shift can go, from 2,700 K down to 1,900 K. | Night Shift stops at 2,700 K. |
| **Notch-Free** | The built-in screen becomes 16:10 below the notch, with a true black band and the menu bar under it. Same size, same sharpness. | Only per-app "scale to fit below camera". |
| **Display Modes** | Every mode a display offers, hidden ones and every refresh rate included, with a 15-second "Keep this mode?" probation. | Hides most modes. |
| **HiDPI Anywhere & Virtual Screens** | Retina-sharp scaled sizes on monitors macOS calls low resolution, and headless virtual screens for sharing and recording. | HiDPI only on dense panels. |
| **External Monitors** | Real brightness, contrast, volume and input on your monitors over DDC/CI, on the keys, following the pointer. Software dimming for monitors that answer nothing. | No control over third-party monitors. |
| **Atelier HUD, Keyboard Light, Rounded Corners** | Your own volume and brightness overlay, the keyboard backlight with any idle time, and soft corners on every display. | Fixed overlay, short idle list, square corners. |
| **Trackpad Gestures & Haptics** | Three- and four-finger taps, top-corner taps, edge flicks and a firm press, each doing what you pick. Middle click with three fingers. A haptic click when a window snaps. | No setting for any of these. |
| **Hyper Key** | Caps Lock becomes ⌃⌥⇧⌘ when held and Escape when tapped. | Caps Lock can only become another single key. |
| **Mouse Precision, Wheel, Buttons** | Each mouse its own curve, linear included and faster than System Settings goes. A wheel that glides like a trackpad and can turn the other way. Side buttons for Back and Forward. | One speed and one scroll direction for everything. |
| **Sound Mixer** | Every app its own volume up to 150 %, mute and output device, and a 10-band EQ with its own curve per output. Apps left at 100 % on the default output are never touched. | One volume, one output, no EQ. |
| **Typing Sounds & Your Sounds** | A soft key sound made by Atelier (silent in password fields), and your own alert sounds. | Not possible. |
| **Hold ⌘Q to Quit** | A slip of ⌘Q does nothing. Keep it down until the ring fills. | Quits at once. |
| **Appearance** | Dark on your own hours, chosen apps kept light in Dark Mode, icon tint, and the hidden appearance switches. | Auto follows the sun only. |
| **Animations, Spotlight, Lock Screen, Accessibility Visuals, Every App, Quick Look** | macOS's own settings and hidden keys, each in one place, checked against what your macOS release reads. | Spread out or Terminal-only. |

### Tools

| Feature | What it does |
|---|---|
| **Toolbox** | Text Grab (OCR any text on screen, read on this Mac), Screen Recorder with clicks and keys, Clipboard Actions, Quick Look Anything, Batch Rename, Image Converter, Finder toolbar buttons, Timers & Alarms, Focus Island beside the notch, and Focus Sessions that hide distracting apps. |
| **Pin Window** | A live copy of any window that floats above everything. |
| **Capture** | Where screenshots go, their name and format, plus the hidden switches. |
| **Command** | ⌥Space searches Atelier, your apps and your clipboard history. |

### History

| Feature | What it does |
|---|---|
| **Scenes** | Save the whole Dock as a scene, apply it in one move, or let it switch at an hour. |
| **Timeline** | Every Dock change leaves a point to come back to. |

### Atelier

| Feature | What it does |
|---|---|
| **Settings** | Atelier's own look, shortcuts, Open at Login, **This Mac** (paste it into bug reports), **Updates**, and **Remove Everything**. |

### Permissions

Atelier asks for a permission only when you turn on a feature that needs it, and says why on the card.

| Permission | Asked for by |
|---|---|
| **Accessibility** | Anything that moves windows or sees keys first: Window Engine, Title Bar Gestures, Radial Menu, Edge Stash, Display Memory, Move & Resize, Window Switcher, Focus Follows Mouse, Hyper Key, Atelier HUD, Hold ⌘Q, Typing Sounds, Wheel, Mouse Buttons, Dock Peek, Instant Spaces shortcuts, some Trackpad Gesture and Hot Corner actions. |
| **Screen Recording** | Window pictures in Live Peek and Dock Peek, minimise into the Atelier Dock, Pin Window, the Screen Recorder. Without it, Peek lists window titles. |
| **System Audio Recording Only** | Sound Mixer (macOS 14.2 or later). |
| **Calendars, Reminders** | Calendar events in the menu bar and the event and reminder widgets, only when you turn them on. |
| **Administrator password** | Installing the Fan Control helper, and the Dock Bridge for Beyond SIP. Both are removable from their cards. |

## Install

1. Download `Atelier-<version>.zip` from the latest [GitHub Release](https://github.com/kaizensx/Atelier/releases).
2. Unzip it and move **Atelier.app** to `/Applications`.
3. Open it.

**The first launch needs one extra step.** Releases are code-signed but not notarized: notarization
needs a paid Apple Developer ID, and Atelier is a free project. macOS therefore asks once. Either:

- right-click Atelier.app in Finder, choose **Open**, then **Open** again; or
- try to open it, then go to **System Settings › Privacy & Security** and click **Open Anyway**.

If you prefer Terminal, this removes the download quarantine flag instead:

```sh
xattr -dr com.apple.quarantine /Applications/Atelier.app
```

You only do this once. Updates arrive through Atelier itself, keep the same signature, and keep the
permissions you granted.

## Updates

Atelier updates itself from GitHub Releases. Open **Settings › Updates**.

- **Automatic checks.** With the switch on, Atelier looks every few hours. When a new version is
  there, one click downloads it and a second installs it and relaunches.
- **Two channels.** **Stable** gets finished releases only. **Beta** gets every build first.
- **Beta first, always.** Every release ships as a beta, is tested on the maintainer's own Mac,
  and only then is the same code promoted to stable.
- **Verified before installing.** Each download is checked against an Ed25519 signature made with
  a key that never leaves the maintainer's Mac, then its code signature and version are checked.
  A download that fails any check is refused.
- **Roll Back.** The version you had is kept, and **Roll Back** puts it back in one click.
- **Quiet.** Requests carry a generic `Atelier-Updater` User-Agent and nothing about you.

## Build from source

Requirements: to build, Xcode 27 or later (Swift 6.4) and its Metal compiler. The app it builds runs
on macOS 14 or later. The logic and tests (`DockCore`) also build with Xcode 26.

```sh
git clone https://github.com/kaizensx/Atelier.git
cd Atelier
swift test                  # unit tests for DockCore, the pure logic
zsh build.sh                # build/Atelier.app, universal (arm64 + x86_64)
zsh build.sh --install      # build, then replace /Applications/Atelier.app
```

The layout is simple. `Sources/DockCore` holds pure logic with unit tests in
`Tests/DockCoreTests`. `Sources/DockStacks` is the app. `Native/` holds the Dock Bridge payload,
`Shaders/` the Metal wallpapers. A local build signs with an Apple Development identity if you
have one, else ad hoc; ad-hoc builds lose their permissions on every rebuild.

## Safety and reversibility

- **Off by default.** A fresh Atelier changes nothing. Each feature waits for you to turn it on.
- **Off means off.** Turning a feature off removes its event tap, overlay or observer and puts back
  what it changed. Display tables return to ColorSync's own; the fans go back to macOS; stashed
  windows come back; a virtual screen disappears. If Atelier crashes, a small guard agent brings
  the macOS Dock back and relaunches it.
- **SIP stays on.** Everything outside Beyond SIP works with System Integrity Protection fully on,
  using public APIs and documented system calls. Dock Peek reads Apple's Dock from outside, with
  no injection.
- **Beyond SIP is opt-in, and honest about the cost.** The Dock Bridge (a scripting addition ported
  from yabai) needs SIP partly off: `csrutil enable --without fs --without debug --without nvram`,
  from recoveryOS. No app can change SIP, and Atelier does not try. Its Recovery Assistant walks
  you through it, warns you that this lowers macOS protection, and removes the bridge with one
  click. `csrutil enable` turns SIP back on.
- **The fan helper is a choice.** It is installed only from the Fan Control card, with your
  administrator password, and removed the same way.
- **No telemetry, no accounts.** Atelier collects nothing. It goes online only for what you ask
  for: update checks, the weather city you pick, wallpaper and icon searches, themes you open by
  link, and plugins you allow the network. Requests use generic User-Agents.
- **One click to leave.** **Settings › Remove Everything** takes Atelier's stacks out of the Dock,
  deletes its data and quits.

## Compatibility

macOS 14 Sonoma, 15 Sequoia, 26 Tahoe and 27, on Apple silicon and Intel. Each feature checks what
your Mac can do before it shows its controls, and says why when it cannot ("Needs macOS 15",
"Needs a Force Touch trackpad", "This Mac has no fan"). The full matrix is in
[COMPATIBILITY.md](COMPATIBILITY.md). Reports from Macs other than the maintainer's are very welcome:
paste the **This Mac** block from Settings into your issue.

## Releasing

For maintainers: [docs/RELEASING.md](docs/RELEASING.md) explains `scripts/release.sh`, the
test → beta → stable flow, the signing keys and how to rotate them.

## Contributing

Themes, plugins, fixes and reports are all welcome. Start with
[docs/CONTRIBUTING.md](docs/CONTRIBUTING.md), then [docs/THEMES.md](docs/THEMES.md) or
[docs/PLUGINS.md](docs/PLUGINS.md). New logic belongs in `DockCore`, with tests.

## Licence

MIT. The Dock Bridge scripting addition is ported from [yabai](https://github.com/koekeishiya/yabai),
also MIT.

## Acknowledgements

Atelier stands on what open projects worked out and shared. Techniques and ideas were learned from,
or inspired by:

- [MonitorControl](https://github.com/MonitorControl/MonitorControl), [m1ddc](https://github.com/waydabber/m1ddc)
  and [Lunar](https://github.com/alin23/Lunar): DDC/CI on Apple silicon, and sub-zero dimming.
- [BetterDisplay](https://github.com/waydabber/BetterDisplay): HiDPI and virtual displays.
- [Loop](https://github.com/MrKai77/Loop): the radial window menu.
- [yabai](https://github.com/koekeishiya/yabai): the Dock scripting addition and Spaces.
- [Stats](https://github.com/exelban/stats): reading the SMC and the chip's sensors.
- [AltTab](https://github.com/lwouis/alt-tab-macos): switching windows, not apps.

None of these projects is affiliated with Atelier.

<br>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="branding/logo/atelier-lockup-dark.png">
    <source media="(prefers-color-scheme: light)" srcset="branding/logo/atelier-lockup-light.png">
    <img src="branding/logo/atelier-lockup-light.png" alt="Atelier" width="220">
  </picture>
</p>

<p align="center"><sub>The Mac, made yours.</sub></p>
