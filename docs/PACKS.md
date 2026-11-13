# Packs: icons, sounds, shaders, layouts, effects and Looks

Packs are mods made of data only. Nothing in a pack runs: Atelier reads one JSON file and the
pictures or sounds it names, checks every part of it, and then uses the values the same way its
own controls would. There are six kinds:

| Kind | Folder extension | Manifest | What it changes |
| --- | --- | --- | --- |
| Icon pack | `.ateliericons` | `atelier-icons.json` | App icons in the Atelier Dock, Orbit, the Launcher and Command, plus folders, Downloads and the Trash |
| Sound pack | `.ateliersounds` | `atelier-sounds.json` | The Dock's sounds, the timer chime, the theme sound, and Typing Sounds |
| Shader pack | `.ateliershader` | `atelier-shader.json` | A Live Wallpaper: a built-in shader, recoloured and retuned |
| Layout pack | `.atelierlayouts` | `atelier-layouts.json` | Snap layouts for Window Engine (Shift-drag zones) |
| Effect pack | `.ateliereffects` | `atelier-effects.json` | Minimise effects for the Atelier Dock |
| Look | `.atelierlook` | `atelier-look.json` | A theme, a wallpaper, Dock settings, and an icon and sound pack, at once |

One small example of each is in [`examples/packs/`](../examples/packs). Drop any pack folder on
**Mods › Library**, open it from Finder, or install one from **Mods › Browse**. Installed packs
live in `~/Library/Application Support/Atelier/<Kind>/<id>.<extension>`, where `<Kind>` is
`IconPacks`, `SoundPacks`, `ShaderPacks`, `LayoutPacks`, `EffectPacks` or `LookPacks`. Installing
a pack with an id that is already installed replaces it; the old copy goes to the Trash.
Removing a pack moves it to the Trash and stops using it.

Atelier never changes a real app bundle or Apple's Dock for a pack. Icon packs draw only in
Atelier's own places; to change an app's icon everywhere, use Folder & App Icons.

## Common rules

Every manifest starts with the same fields:

```json
{
  "format": 1,
  "id": "com.example.my-pack",
  "name": "My Pack",
  "version": "1.0.0",
  "author": "You",
  "description": "One or two sentences."
}
```

* `format` is 1. `id` is reverse-DNS (letters, digits, hyphens between dots). `version` is
  major.minor.patch. `name` is 1 to 60 characters; `description` up to 400.
* Any other key the kind does not define is an **error**, except keys starting with `x-`, which
  are free for notes.
* Every path is relative to the pack folder, with no `..`, no leading `/` and no hidden parts.
* Every file is identified by its first bytes, not its name: a `.png` must really be a PNG, a
  `.wav` really a WAV. Links inside a pack are refused, and so is anything that is not a file.
* The manifest is at most 256 KB.

## Icon packs

```json
{
  "format": 1, "id": "com.example.mono-glyphs", "name": "Mono Glyphs", "version": "1.0.0",
  "icons": {
    "com.apple.Safari": "icons/safari.png",
    "com.apple.finder": "icons/finder.png",
    "folder": "icons/folder.png",
    "downloads": "icons/downloads.png",
    "trash": "icons/trash.png",
    "trash.full": "icons/trash-full.png"
  }
}
```

* Keys are app bundle identifiers, or one of `folder`, `downloads`, `trash`, `trash.full`.
* Pictures are PNG, HEIC or ICNS, at most 1 MB each and at least 256 pixels on the shorter side.
  At most 600 icons.
* Choose the pack in use with **Use** on its page or in Mods › Library. An icon picked for one app
  (Change Icon…) still wins over the pack. Click an icon in the pack's preview, or choose **Use
  Original Icon** on the app's Dock tile, to keep that app's own icon while the pack is in use.

## Sound packs

```json
{
  "format": 1, "id": "com.example.soft-chimes", "name": "Soft Chimes", "version": "1.0.0",
  "sounds": {
    "dock.launch": "sounds/launch.wav",
    "dock.drop": "sounds/drop.wav",
    "dock.trash": "sounds/trash.wav",
    "dock.minimize": "sounds/minimize.wav",
    "timer.done": "sounds/timer.wav",
    "theme.apply": "sounds/apply.wav"
  },
  "typing": {
    "key": ["typing/key1.wav", "typing/key2.wav"],
    "space": ["typing/space.wav"],
    "return": ["typing/return.wav"],
    "backspace": ["typing/key1.wav"],
    "modifier": ["typing/key2.wav"]
  }
}
```

The slots are the sounds Atelier plays:

| Slot | Played when |
| --- | --- |
| `dock.launch` | An app opens from the Atelier Dock (Dock › Sounds on) |
| `dock.drop` | Something is dropped on a Dock tile |
| `dock.trash` | Something is dropped on the Trash |
| `dock.minimize` | A window minimises into the Dock |
| `timer.done` | A timer, the Timer widget or a focus session ends |
| `theme.apply` | A theme is applied (a theme's own sound wins) |

* Files are CAF, M4A or WAV, at most 1 MB each. Slot sounds last at most 2 seconds.
* `typing` keeps the structure of the built-in voices: five key classes (`key`, `space`,
  `return`, `backspace`, `modifier`), each 1 to 8 variants of at most 1 second. `key` is required;
  the others fall back to it. Variants are never played twice in a row.
* Choose the pack in Dock › Sounds or in Typing Sounds; **Built-in** is the default. Typing Sounds
  plays the pack's keys only when **Play the pack's key sounds** is on.

## Shader packs

Shader packs do not carry Metal code, and Atelier never compiles anything from a pack. A pack
picks one of Atelier's own shaders and sets the same values the Live Wallpaper controls set:

```json
{
  "format": 1, "id": "com.example.aurora-drift", "name": "Aurora Drift", "version": "1.0.0",
  "base": "northernLights",
  "palette": ["#04121A", "#0E4D5C", "#3FC1B0", "#C7A6FF"],
  "speed": 0.7, "intensity": 0.6, "grain": 0.12, "scale": 1.15, "dim": 0.08,
  "cycle": "night", "pointer": true
}
```

| Key | Values | Default |
| --- | --- | --- |
| `base` | `liquidLight`, `nebula`, `auroraSilk`, `topography`, `glassRain`, `silkWaves`, `gradientMesh`, `starfield`, `retroHorizon`, `oceanCaustics`, `northernLights`, `lavaLamp`, `inkInWater`, `fireflies`, `liquidChrome` | required |
| `palette` | four colours, darkest first; the shader's colours are mapped onto them | the shader's own |
| `speed` | 0.2 to 2.5, the shader's clock | 1 |
| `intensity` | 0 to 1, contrast and colour | 0.5 |
| `grain` | 0 to 1, film grain | 0 |
| `scale` | 0.6 to 1.8, the size of the pattern (noise scale) | 1 |
| `dim` | 0 to 0.7, darkens for legibility | 0 |
| `cycle` | `clock` (follows the hour), `day`, `dusk`, `night` | `clock` |
| `pointer` | whether it answers the pointer | true |

The shaders that draw over your own wallpaper picture are not offered, so a pack looks the same
on every Mac. Installed shader packs show in **Live Wallpaper › From shader packs** with a moving
preview; click one to wear it. The shader's settings in Adjust then show the pack's values.

## Layout packs

```json
{
  "format": 1, "id": "com.example.studio-grids", "name": "Studio Grids", "version": "1.0.0",
  "layouts": [
    {"name": "Golden Split", "zones": [
      {"x": 0, "y": 0, "width": 0.618, "height": 1},
      {"x": 0.618, "y": 0, "width": 0.382, "height": 0.5},
      {"x": 0.618, "y": 0.5, "width": 0.382, "height": 0.5}]}
  ]
}
```

* Zones are rects on a unit screen, from the top left. Every value is 0 to 1, a zone stays on the
  screen (`x + width` and `y + height` at most 1), and each side is at least 0.05. A layout has 1
  to 12 zones, none repeated; a pack has at most 24 layouts with names of 1 to 40 characters.
* **Add to Layouts** puts them in Window Engine's custom layouts, where Shift-drag offers their
  zones. Adding again replaces them; **Remove Layouts** or removing the pack takes them out.

## Effect packs

An effect pack describes minimise effects as numbers on top of a built-in mesh:

```json
{
  "format": 1, "id": "com.example.soft-effects", "name": "Soft Effects", "version": "1.0.0",
  "effects": [
    {"id": "mist", "name": "Mist", "base": "scale", "duration": 0.45, "curve": "easeInOut",
     "opacity": [[0, 1], [0.6, 0.85], [1, 0]],
     "blur": [[0, 0], [1, 5]],
     "shade": [[0, 1], [1, 1.25]]},
    {"id": "swirl", "name": "Swirl", "base": "genie", "duration": 0.6, "curve": "easeIn",
     "scale": [[0, 1], [0.3, 1.04], [1, 0.9]], "twist": 90,
     "wave": {"amplitude": 0.04, "frequency": 2}}
  ]
}
```

| Key | Values |
| --- | --- |
| `id`, `name` | the effect's own id (letters, digits, hyphens) and name, 1 to 40 characters |
| `base` | `genie`, `scale`, `suck`, `lamp`, `fold`, `dissolve`, `portal`, `shatter`, `liquid` |
| `duration` | 0.15 to 1.2 seconds (required) |
| `curve` | `linear`, `easeIn`, `easeOut`, `easeInOut` (default), `spring` |
| `opacity` | keyframes, 0 to 1, must start at 1 |
| `scale` | keyframes, 0.05 to 3, must start at 1 |
| `blur` | keyframes, 0 to 8 (mipmap levels), must start at 0 |
| `shade` | keyframes, 0 to 2 (brightness), must start at 1 |
| `twist` | degrees turned by the end, −720 to 720 |
| `wave` | `amplitude` 0 to 0.2 (a share of the window) and `frequency` 0 to 8 |

Keyframes are `[t, value]` pairs: 2 to 16 of them, `t` from 0 to 1, increasing, starting at 0
and ending at 1; values between them are linear. The first frame is drawn over the real window,
which is why every track starts at its resting value. Restoring a window plays the same effect
backwards in time. Shift slows it down, Reduce Motion replaces it with a short Scale, as with the
built-in effects. A pack holds at most 12 effects. Its effects appear in **Dock › Window Minimise
Effect › From effect packs** and on the pack's page, each with a live preview.

## Looks

A Look is one folder with a theme and, optionally, a wallpaper, Dock settings and packs:

```
Dusk Studio.atelierlook/
  atelier-look.json
  theme.ateliertheme/atelier-theme.json
  sky.ateliershader/atelier-shader.json
```

```json
{
  "format": 1, "id": "com.example.dusk-studio", "name": "Dusk Studio", "version": "1.0.0",
  "theme": "theme.ateliertheme",
  "wallpaper": {"shader": "sky.ateliershader"},
  "dock": {"edge": "bottom", "tileSize": 52, "magnifiedSize": 92, "magnification": true, "autohide": false},
  "iconPack": "com.example.mono-glyphs",
  "soundPack": "sounds.ateliersounds"
}
```

* `theme` (required) names a `.ateliertheme` folder at the top of the Look, in the format of
  [THEMES.md](THEMES.md); it is validated like any theme.
* `wallpaper` is either `{"image": "wallpaper.heic"}` (PNG, HEIC or JPEG, at most 20 MB, large
  enough to fill a screen) or `{"shader": …}`.
* `wallpaper.shader`, `iconPack` and `soundPack` each name either a pack folder inside the Look
  (by its extension) or an installed pack by id. Packs inside the Look are validated with it and
  installed when it is first worn.
* `dock` sets only these: `edge` (`bottom`, `left`, `right`, `top`), `tileSize` (24 to 128),
  `magnifiedSize` (32 to 256, not below `tileSize`), `magnification` and `autohide`. Everything
  else about the Dock comes from the theme.
* **Wear** saves your setup first, the same point Themes use, together with what a theme cannot
  record: the icon and sound packs in use, the wallpaper picture and the Dock's edge, size,
  magnification and hiding. **Revert** in Looks puts all of it back.

## In the catalog

Packs are published through [kaizensx/atelier-mods](https://github.com/kaizensx/atelier-mods)
like themes, with `kind` set to `icons`, `sounds`, `shader`, `layouts`, `effects` or `look`. The
catalog's checks (`scripts/validate.mjs`) apply the same limits before a pack is signed, and
Atelier checks the downloaded pack again, by the rules above, before installing it. The largest
zipped package per kind: icons 60 MB, sounds 20 MB, Looks 80 MB, shaders 1 MB, layouts and
effects 256 KB.

To start one, `atelier-mod new icons io.github.you.my-icons` (or `sounds`, `shader`, `layouts`, `effects`,
`look`) makes a small working pack of that kind, and `atelier-mod validate` runs the same pack rules as
the catalog. See [MAKING-MODS.md](MAKING-MODS.md).
