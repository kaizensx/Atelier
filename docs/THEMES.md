# Atelier Themes

A theme restyles everything Atelier can reach, from one file you can share: the Atelier Dock,
the widget board, the menu bar skin, the live wallpaper and its colours, Atelier's own window,
macOS icon tinting, the desktop clock, desktop effects and sounds.

The twelve Looks in Atelier's Looks chapter are themes in exactly this format. Their source is
in `Sources/DockStacks/LooksCatalog.swift`, and three more live in `examples/themes/`.

## The bundle

```
Midnight Glass.ateliertheme/        a folder; Finder shows it as one file once Atelier is installed
├── atelier-theme.json              required, at most 256 KB
├── preview.png                     optional, shown on the gallery card
├── images/wall.heic                optional, for "wallpaper": { "mode": "image" }
└── sounds/apply.aiff               optional, for "sounds"
```

* The whole bundle may be at most 40 MB.
* Every path in the JSON is relative to the bundle. Paths may not start with `/` or `~`,
  contain `..`, or name hidden files. Symbolic links inside a bundle are ignored.
* A bare `atelier-theme.json` can be imported too; Atelier wraps it in a bundle.
* `shaders/` is reserved. Format 1 can only name Atelier's built-in live wallpapers.

## A complete example

```json
{
  "$schema": "atelier-theme.schema.json",
  "format": 1,
  "id": "com.example.midnight-glass",
  "name": "Midnight Glass",
  "version": "1.0.0",
  "author": "You",
  "description": "Ink-blue glass over a slow nebula.",
  "colors":   { "accent": "#8FB8FF", "secondary": "#B49CFF", "glassTint": "#1B2A55" },
  "dock":     { "style": "glass", "accent": "#8FB8FF", "indicator": "dot", "roundness": 0.75 },
  "widgets":  { "material": "glass", "tint": "indigo", "radius": 26, "shadow": 0.35 },
  "menuBar":  { "skin": "notchless" },
  "wallpaper": {
    "mode": "live", "shader": "nebula",
    "palette": ["#03040C", "#101A45", "#3B5FD9", "#D6E2FF"],
    "speed": 0.7, "cycle": "night"
  },
  "studio":   { "backdrop": "midnight", "accent": "#8FB8FF" },
  "icons":    { "style": "clear", "mode": "dark" },
  "clock":    { "show": true, "face": "thin" },
  "effects":  { "dockGlow": false },
  "sounds":   { "apply": "Glass" }
}
```

## Rules

* **Everything but `format`, `id`, `name` and `version` is optional.** A key that is absent
  leaves that setting exactly as it is, so a theme can be as small as one colour.
* **Colours** are `#RGB`, `#RRGGBB` or `#RRGGBBAA`, in sRGB. Where a module only has named
  choices (the Dock's six accents, the eleven widget tints, the six Studio accents), a colour
  is snapped to the nearest named one. The Studio accent is the exception: it is used exactly.
* **Fallbacks.** `dock.accent`, `widgets.accent` and `studio.accent` fall back to
  `colors.accent`; `widgets.tint` falls back to `colors.glassTint`; a tinted icon style falls
  back to `colors.accent` for its tint.
* **Unknown keys** produce a warning, not an error, so themes written for a newer Atelier still
  open. Keys starting with `$` or `x-` are ignored silently: use `x-yourname` for your own data.
* **Newer formats** are refused with a clear message instead of being half-applied.
* **Gradients.** A theme that sets `widgets.material` but no `widgets.gradient` means a plain
  surface, so it clears a gradient left by a previous theme.

## Applying, previewing and reverting

* **Preview.** Resting the pointer on a theme in Looks or Mods › Library shows it on the stage
  without changing anything.
* **Apply.** Clicking applies each section through the module's own settings, exactly as if
  you had changed each control yourself. Icon styles restart the Dock, but only when the icon
  settings actually change.
* **Revert.** Before the first theme is applied, Atelier saves your setup. Revert puts it back,
  however many themes you tried in between. The saved setup survives relaunching Atelier.
* **Schedule.** Looks → Change with the Day applies up to four themes as their hours arrive.
  The schedule only acts when a slot begins, so a Look you pick by hand holds until the next.

## Sharing

* **Create Theme from my Mac** (Mods › Library) saves your current setup as a theme.
* **Save as Theme File…** (right-click a card) writes any theme as a `.ateliertheme` folder.
* To share by link, zip the bundle, host it over https and share
  `atelier://theme?url=https://example.com/Midnight%20Glass.ateliertheme.zip`
  (or link straight to an `atelier-theme.json`). Atelier asks before downloading, only follows
  https, refuses local and private addresses, validates the theme, and installs it without
  applying it. Zips are expanded with `ditto`, which refuses paths that escape the folder.

To share with everyone, submit the theme to Atelier Mods
([kaizensx/atelier-mods](https://github.com/kaizensx/atelier-mods)): it appears in the **Mods**
chapter, signed and checked, and people get your updates there.

A theme can also travel inside a **Look** (`.atelierlook`), together with a wallpaper, a few Dock
settings and icon and sound packs; see [PACKS.md](PACKS.md). Live wallpapers recoloured and
retuned as **shader packs** are described there too.

Installed themes live in `~/Library/Application Support/Atelier/Themes/<id>.ateliertheme`.
Installing a theme with an id that is already installed replaces it; the old copy goes to the
Trash. Removing a theme moves it to the Trash.

## Validation messages

Every problem names the key it is about, for example:

```
dock.style: "glas" is not one of glass, tinted, midnight, frost, neon, wallpaper. Did you mean "glass"?
dock.roundness: 1.5 is outside 0…1.
wallpaper.palette: Expected 4 colours, got 3.
wallpaper.image: "images/wall.heic" is not in the bundle.
dokc: Unknown key, ignored. Did you mean "dock"?
```

Editors that understand JSON Schema can check themes as you type: point `$schema` at
[`atelier-theme.schema.json`](atelier-theme.schema.json). The schema is generated from the same
table the validator uses, and a unit test fails if the two ever disagree.

## Reference

Every key, its type and what it does. Ranges are inclusive.

| Key | Type | Description |
|---|---|---|
| `format` **required** | integer 1…1 | Format version. Always 1 for this release. |
| `id` **required** | text (≤ 120) | Reverse-DNS identifier, unique to this theme: `com.example.midnight-glass`. |
| `name` **required** | text (≤ 60) | Name shown in the gallery. |
| `version` **required** | text (≤ 20) | Semantic version of the theme: `1.2.0`. |
| `author` | text (≤ 80) | Who made it. |
| `description` | text (≤ 400) | One or two sentences for the gallery. |
| `homepage` | https link | An https link for more about the theme. |
| `preview` | bundle path (png, jpg, jpeg, heic, tiff) | A picture for the gallery card, inside the bundle. |
| `tags` | list of ≤ 8 texts (≤ 24) | Words the gallery can filter by. |
| `appearance` | `dark` `light` | Whether the theme is designed for a dark or a light setup. Informational. |
| `colors` | object | The palette everything else can borrow from. See below. |
| `dock` | object | The Atelier Dock. See below. |
| `widgets` | object | The widget board's style. See below. |
| `menuBar` | object | The menu bar. See below. |
| `wallpaper` | object | The desktop. See below. |
| `studio` | object | Atelier's own window. See below. |
| `icons` | object | macOS icon appearance. See below. |
| `clock` | object | The desktop clock. See below. |
| `effects` | object | Atelier's desktop effects. See below. |
| `sounds` | object | Sounds. See below. |

#### `colors`

| Key | Type | Description |
|---|---|---|
| `colors.accent` | colour | The theme's main colour. Feeds the Dock, widgets and Studio when they have no colour of their own. |
| `colors.secondary` | colour | A second colour, used for rings and gradients. |
| `colors.glassTint` | colour | The tint for Liquid Glass widget surfaces when `widgets.tint` is absent (snapped to the nearest widget tint). |

#### `dock`

| Key | Type | Description |
|---|---|---|
| `dock.style` | `glass` `tinted` `midnight` `frost` `neon` `wallpaper` | Atelier Dock design. |
| `dock.accent` | colour, or `blue` `purple` `pink` `orange` `green` `graphite` | Dock accent: a named accent or a colour (snapped to the nearest named accent). |
| `dock.indicator` | `dot` `bar` `glow` `none` | What marks an open app. |
| `dock.hover` | `peek` `label` `none` | What resting on a tile shows. |
| `dock.roundness` | number 0…1 | 0 is nearly square, 1 a capsule. |
| `dock.padding` | number 0.04…0.3 | Glass around the icons, as a fraction of the icon size. |
| `dock.spacing` | number 0…0.5 | Room between icons, as a fraction of the icon size. |
| `dock.gap` | number 0…32 | Points between the bar and the screen edge. |
| `dock.curve` | `gentle` `classic` `fisheye` `wave` | Magnification curve. |
| `dock.launch` | `bounce` `pulse` `glow` | What an app does while it opens. |
| `dock.labelPosition` | `lens` `icon` | Where tile names appear. |
| `dock.hoverLift` | true / false | Icons rise under the pointer instead of growing. |
| `dock.iconShadow` | true / false | Soft shadow under icons. |
| `dock.reflection` | true / false | A reflection under the bar. |
| `dock.divider` | true / false | A divider before folders and Trash. |
| `dock.followTheme` | true / false | The Dock takes its tint from the menu bar skin or mesh wallpaper instead of `dock.accent` (Atelier Dock's Follow Look setting). Turned off when the theme sets `dock.accent` and leaves this out. |

#### `widgets`

| Key | Type | Description |
|---|---|---|
| `widgets.material` | `glass` `clear` `tinted` `dark` `frosted` `outline` `bare` | Surface of every widget that follows the board style. |
| `widgets.tint` | colour, or `blue` `indigo` `purple` `pink` `red` `orange` `amber` `green` `mint` `teal` `graphite` | Surface tint. |
| `widgets.accent` | colour, or `blue` `indigo` `purple` `pink` `red` `orange` `amber` `green` `mint` `teal` `graphite` | Accent for rings, bars and highlights. |
| `widgets.radius` | number 10…40 | Corner radius in points. |
| `widgets.opacity` | number 0.35…1 | Surface opacity. |
| `widgets.font` | `system` `rounded` `serif` `mono` | Type family. |
| `widgets.shadow` | number 0…1 | 0 flat, 1 a deep soft shadow. |
| `widgets.border` | number 0…2 | Extra rim in points. |
| `widgets.padding` | number 0…14 | Extra room inside the edge in points. |
| `widgets.scale` | number 0.85…1.2 | Text scale. |
| `widgets.blur` | number 0…1 | Background blur. |
| `widgets.gradient` | object | A gradient under the content. Omit for none. See below. |
| `widgets.iconHarmony` | `off` `halo` `cutout` `fade` | How desktop icons make room for widgets. |

#### `widgets.gradient`

| Key | Type | Description |
|---|---|---|
| `widgets.gradient.from` | colour, or `blue` `indigo` `purple` `pink` `red` `orange` `amber` `green` `mint` `teal` `graphite` | Start colour. |
| `widgets.gradient.to` | colour, or `blue` `indigo` `purple` `pink` `red` `orange` `amber` `green` `mint` `teal` `graphite` | End colour. |
| `widgets.gradient.angle` | number 0…360 | Degrees; 0 runs left to right. |

#### `menuBar`

| Key | Type | Description |
|---|---|---|
| `menuBar.skin` | `none` `notchless` `sunset` `ocean` `aurora` `graphite` | A menu bar skin. `none` removes it. |

#### `wallpaper`

| Key | Type | Description |
|---|---|---|
| `wallpaper.mode` | `keep` `live` `mesh` `image` `off` | `live` a Metal live wallpaper, `mesh` a still mesh that follows the hour, `image` a picture from the bundle, `off` turns Atelier's wallpapers off, `keep` (default) leaves it alone. |
| `wallpaper.shader` | `liquidLight` `nebula` `auroraSilk` `topography` `glassRain` `silkWaves` `gradientMesh` `starfield` `retroHorizon` | Live wallpaper, for `live`. |
| `wallpaper.palette` | `natural` `wallpaper` `midnight` `ember` `lagoon` `orchid` `glacier` `forest` `dune` `graphite`, or a list of 4 colours | Live wallpaper colours: a preset or four colours from dark to light. |
| `wallpaper.speed` | number 0.2…2.5 | Live wallpaper speed. 1 is as designed. |
| `wallpaper.intensity` | number 0…1 | Contrast and colour. 0.5 is as designed. |
| `wallpaper.grain` | number 0…1 | Film grain. |
| `wallpaper.scale` | number 0.6…1.8 | Pattern scale. |
| `wallpaper.dim` | number 0…0.7 | Darkening, for legibility. |
| `wallpaper.cycle` | `clock` `day` `dusk` `night` | Follow the clock, or hold day, dusk or night. |
| `wallpaper.mesh` | `aurora` `dusk` `ocean` `ember` `mono` | Mesh colours, for `mesh`. |
| `wallpaper.image` | bundle path (png, jpg, jpeg, heic, tiff) | A picture inside the bundle, for `image`. |

#### `studio`

| Key | Type | Description |
|---|---|---|
| `studio.backdrop` | `light` `wallpaper` `live` `midnight` `aurora` `ember` `graphite` `paper` | The room around Atelier's stage. |
| `studio.accent` | colour, or `sky` `violet` `mint` `rose` `amber` `silver` | Accent of Atelier's own controls. A colour is used exactly. |
| `studio.glow` | number 0…1 | How much of the room's colour shows. |
| `studio.tilt` | true / false | The stage leans toward the pointer. |
| `studio.reflection` | true / false | A glossy floor under the stage. |

#### `icons`

| Key | Type | Description |
|---|---|---|
| `icons.style` | `default` `clear` `tinted` | macOS app icon style. Needs a Dock restart, which Atelier does. |
| `icons.mode` | `dark` `light` | Light or dark icons, for `clear` and `tinted`. |
| `icons.tint` | colour, or `Blue` `Purple` `Pink` `Orange` `Yellow` `Green` `Graphite` | Icon tint, for `tinted`. |

#### `clock`

| Key | Type | Description |
|---|---|---|
| `clock.show` | true / false | A Big Clock on the desktop. |
| `clock.face` | `thin` `bold` `rounded` `serif` `mono` `words` `analog` `flip` `stacked` `dot` | Its face. |

#### `effects`

| Key | Type | Description |
|---|---|---|
| `effects.dockGlow` | true / false | Light pools under the Dock. |
| `effects.dayLine` | true / false | A hairline under the menu bar fills as the day passes. |

#### `sounds`

| Key | Type | Description |
|---|---|---|
| `sounds.apply` | text (≤ 120) | Played when the theme is applied: a system sound name (`Glass`) or a file in the bundle. |
| `sounds.focusEnd` | text (≤ 120) | Played when a Focus Island countdown ends. |
| `sounds.cornerFire` | text (≤ 120) | Played when a hot corner fires. |

### Value notes

* **`dock.style`**: `glass` is Liquid Glass; `tinted` lays the accent into the glass;
  `midnight` is near-black glass; `frost` is bright frosted glass; `neon` draws a glowing rim
  in the accent; `wallpaper` borrows the colour behind the Dock.
* **`wallpaper.shader`**: `liquidLight`, `nebula`, `auroraSilk`, `topography`, `glassRain`,
  `silkWaves`, `gradientMesh`, `starfield`, `retroHorizon`. All run on Metal, pause on battery
  if the owner asked, and hold a still frame under Reduce Motion.
* **`wallpaper.palette`** as four colours runs from the darkest stop to the brightest:
  deep, shadow, body, crest. Atelier maps the shader's light onto them.
* **`wallpaper.cycle`**: `clock` follows the real hour; `day`, `dusk` and `night` hold one.
* **`icons.style`** writes macOS's own icon appearance setting. `default` removes Atelier's
  override; `clear` and `tinted` use `icons.mode` for light or dark icons.
* **`clock.face`**: `thin`, `bold`, `rounded`, `serif`, `mono`, `words` (the time in words),
  `analog`, `flip`, `stacked`, `dot`.
* **`sounds.*`** take a system sound name (`Basso`, `Blow`, `Bottle`, `Frog`, `Funk`, `Glass`,
  `Hero`, `Morse`, `Ping`, `Pop`, `Purr`, `Sosumi`, `Submarine`, `Tink`) or a file in the bundle.

## Versioning

`format` is the version of this file format, not of your theme. Format 1 will only ever gain
optional keys; anything that changes the meaning of an existing key will be format 2, and
Atelier will keep reading format 1. Use `version` for your own releases.
