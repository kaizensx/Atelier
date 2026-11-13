# atelier-mod

Make, check, test and share mods for [Atelier](https://github.com/kaizensx/Atelier). Node 20 or
later, no dependencies.

```sh
atelier-mod new plugin io.github.you.hello   # a project with types, editor setup and fixtures
atelier-mod test                             # run it here, behind Atelier's real prelude
atelier-mod validate                         # the checks Atelier and the catalog run
atelier-mod pack                             # a zip, byte for byte as the catalog makes it
atelier-mod catalog-entry --github you       # mods/<id>/ ready for a pull request
```

The guide is [docs/MAKING-MODS.md](../docs/MAKING-MODS.md); the API reference is on the
[website](https://kaizensx.github.io/Atelier/make.html).

## What is in here

| | |
|---|---|
| `atelier.d.ts`, `manifest.schema.json` | Generated from [docs/plugin-api.json](../docs/plugin-api.json) by `generate.mjs`. |
| `cli/atelier-mod.mjs` | The command. `cli/lib/harness.mjs` is the test runner, also importable as `atelier-mod/harness`. |
| `cli/runtime/` | Generated: a copy of plugin-api.json and the prelude lifted from `Sources/DockCore/PluginPrelude.swift`. |
| `cli/templates/` | The starting points `new` and Atelier's Mods › Create playground share. |
| `cli/vendor/atelier-mods/` | The catalog's own `scripts/lib.mjs` and `scripts/validate.mjs`, byte for byte. |

## Keeping it in step

* Change the API in the app, then describe it in `docs/plugin-api.json` and run
  `node sdk/generate.mjs`. `Tests/DockCoreTests/PluginAPIDescriptionTests.swift` fails while the
  description misses something the app has; `node sdk/generate.mjs --check` (run by
  `scripts/preflight.sh`) fails while the generated files are stale.
* Change the catalog's rules in atelier-mods, then run `node sdk/sync-catalog.mjs --from
  <atelier-mods checkout>`. Preflight runs it with `--check` against a checkout beside this one.
* `node --test sdk/test/` runs the kit's own tests.
