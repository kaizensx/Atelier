# Customising Atelier: Themes and Plugins

Atelier is built to be restyled and extended by anyone. There are three ways in.

**Themes** change how everything looks, from a single JSON file: the Atelier Dock, widgets,
menu bar, live wallpaper and its palette, Atelier's own window, macOS icon tint, the desktop
clock and sounds. No code. → [THEMES.md](THEMES.md) · [JSON Schema](atelier-theme.schema.json)

**Plugins** add new things, in JavaScript: widgets, Dock tiles, Command palette entries and
searches, hot-corner actions, menu bar items, stacks, live activities, small windows, and
reactions to what happens on your Mac. Each runs sandboxed in its own
engine, off the main thread, with nothing but what you allow. → [PLUGINS.md](PLUGINS.md)

**Packs** are data only, checked file by file: icon packs, sound packs, shader packs (live
wallpapers as numbers, never code), snap layout packs, minimise effect packs, and Looks that
bundle a theme with a wallpaper, Dock settings and packs. → [PACKS.md](PACKS.md)

## Try it

1. Open Atelier and go to **Mods › Library**.
2. Drag `examples/themes/sunset-neon.ateliertheme` onto the chapter. Rest the pointer on its
   card to preview it on the stage; click to apply; **Revert** to go back.
3. Drag `examples/plugins/pomodoro.atelierplugin` onto the chapter, allow notifications, and
   watch its tile appear in the Atelier Dock.

## Where things live

| | |
|---|---|
| Installed themes | `~/Library/Application Support/Atelier/Themes/` |
| Installed plugins | `~/Library/Application Support/Atelier/Plugins/` |
| Plugin storage | `~/Library/Application Support/Atelier/PluginData/` |
| Format code | `Sources/DockCore/Theme*.swift`, `Sources/DockCore/Plugin*.swift` (pure Swift, unit tested) |
| Apply and runtime | `Sources/DockStacks/Theme*.swift`, `Plugin*.swift`, `Looks*.swift` |
| Built-in Looks | `Sources/DockStacks/LooksCatalog.swift`, in the theme format |
| Examples | `examples/themes/`, `examples/plugins/` |

## Sharing

Zip a `.ateliertheme`, host it over https, and share
`atelier://theme?url=https://example.com/My%20Theme.ateliertheme.zip`. Atelier asks before
downloading, validates the theme and installs it without applying it.

Plugins are shared as folders or zips; install them from Mods › Library, or share them through the Mods catalog. Read a plugin's
`main.js` before you switch it on, the same way you would read a script from the internet:
the sandbox limits what it can reach, and the permissions sheet tells you what it asks for.

To contribute a theme, plugin or change to Atelier itself, see [CONTRIBUTING.md](CONTRIBUTING.md).
