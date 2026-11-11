# Contributing to Atelier

Thank you for helping. Atelier is a macOS customisation app written in Swift 6 with SwiftUI and
AppKit, built with Swift Package Manager.

## Building and testing

```sh
swift build                # debug
swift build -c release     # what ships
swift test                 # unit tests (DockCore)
./build.sh                 # an app bundle, for running it yourself
```

Requirements: Xcode 27 or later (Swift 6.4) to build the app; `DockCore` and its tests also build with Xcode 26. Swift 6 strict
concurrency is on; new code must build without warnings in the files you touch.

## Layout

* `Sources/DockCore` is pure logic with no UI: geometry, validation, formats. Everything here
  should have unit tests in `Tests/DockCoreTests`.
* `Sources/DockStacks` is the app. Each feature lives in files that share a prefix
  (`OwnDock*`, `Widgets*`, `Theme*`, `Plugin*`, `Looks*`, …).
* `docs/` is user and developer documentation. `examples/` holds sample themes and plugins;
  the test suite loads every one of them.

## Contributing a theme or Look

1. Write it as a `.ateliertheme` (see [THEMES.md](THEMES.md)). Test it on a light and a dark
   setup, and with Reduce Motion on.
2. For a shared example, add it under `examples/themes/` with an id under `com.example.`.
   For a built-in Look, add its JSON to `LooksCatalog.swift` with an id under `atelier.look.`.
3. Run `swift test`: example themes must validate without warnings.

A good Look is coherent: one idea, carried through the Dock, widgets, wallpaper palette, icons
and clock. Prefer named values where they exist, keep text legible over the wallpaper (use
`wallpaper.dim` if needed), and write a one-sentence description that says what it feels like.

## Contributing a plugin

Follow [PLUGINS.md](PLUGINS.md). Example plugins must:

* ask for the fewest permissions that work, and list exact hosts for `network`;
* never contact a service at load time without the owner having set them up (the test suite
  runs every example's script with a recording bridge and no network);
* handle being offline, and show errors in the widget rather than failing silently.

## Changing the formats

The theme format is a table in `Sources/DockCore/ThemeSchema.swift`. When you add a key:

1. Add it to the table, with a range or the list of allowed values. Keep new keys optional.
2. Apply it in `ThemeApplier.apply` and read it back in `ThemeApplier.capture` (both in
   `Sources/DockStacks/ThemeApply.swift`), through the owning module's public properties.
3. Regenerate the schema with
   `ATELIER_WRITE_SCHEMA=1 swift test --filter jsonSchemaMatchesTheTable`, and replace the
   tables under "Reference" in `docs/THEMES.md` with the output of
   `ThemeSchemaExport.markdown()`. The test fails until both match the table.
4. If a value list mirrors an app enum, keep the two in step.

The plugin bridge is `PluginMessage` in `Sources/DockCore/PluginBridge.swift` plus the
JavaScript prelude in `PluginPrelude.swift`. New API must be plain data across the bridge,
validated in `PluginMessage.decode`, gated by a permission if it reaches beyond Atelier, and
covered by a test that runs real JavaScript through the prelude.

## Style

* Short, plain UI text in English. Say what a control does, not how it works.
* Animations use the springs in `DS.Motion`; nothing should drop a frame at 120 Hz. No work on
  the main thread that can happen elsewhere.
* Comments explain why, not what.
* Destructive actions move things to the Trash, and ask (or use a hold-to-confirm button).

## Security

Plugins run third-party code, so changes to the plugin runtime get extra review. Report a
vulnerability privately to the maintainers rather than in a public issue.
