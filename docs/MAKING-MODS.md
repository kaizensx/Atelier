# Making mods

Everything you need to make a plugin, a theme or a data pack for Atelier, try it, test it and
share it with everyone through the Mods catalog. You do not need Xcode, and you do not need to
know Swift. A plugin is one JavaScript file and a small `manifest.json`.

There are two ways in, and they meet in the middle:

* **Mods › Create** in Atelier: a playground. Write a script, press Run, and see the widgets,
  Dock tiles and commands it adds, drawn by Atelier itself. Nothing to install.
* **`atelier-mod`**, the command-line kit: a project with types for your editor, the same checks
  the catalog runs, a test runner, and the folder for your pull request.

The API itself is in [PLUGINS.md](PLUGINS.md) and, searchable with examples, on the
[website](https://kaizensx.github.io/Atelier/make.html). The theme format is in
[THEMES.md](THEMES.md).

## Quick start: the playground

1. Open Atelier and go to **Mods › Create** (or search for "playground").
2. Pick a starting point from **Templates**: Hello, Focus Timer, Web Feed or Controls (buttons,
   a toggle, settings and translated text).
3. Press **Run** (⌘R). On the right you see what the script registered: its widgets drawn as on
   the board (their buttons and toggles work), its Dock tiles (click them), its commands and corner actions (click to run them), and
   the events it listens for (send one to try it). `console.log` and every error, with its line
   number, show in the console below.
4. Change the code and press **Run Again**.
5. **Save as Plugin…** writes a `.atelierplugin` folder where you choose and installs it. Switch it
   on in **Mods › Installed**.

The playground runs your script exactly as an installed plugin runs: its own JavaScript engine,
off the main thread, one second per call. It starts with **no permissions**. Tick the ones your
script needs in the Permissions row (for Network, list the hosts); Atelier asks on the usual
permission sheet before it runs. What the script registers stays in the playground: nothing
reaches your board, Dock or Command palette until you save and switch it on.

## Quick start: the command line

You need [Node.js](https://nodejs.org) 20 or later. The kit has no dependencies.

```sh
# from a checkout of Atelier
node sdk/cli/atelier-mod.mjs new plugin io.github.you.hello
# or, once it is on npm
npx atelier-mod new plugin io.github.you.hello
```

That makes a project:

```
hello/
├── hello.atelierplugin/     the package: what Atelier installs and the catalog ships
│   ├── manifest.json
│   └── main.js
├── jsconfig.json            checks main.js against the types
├── types/atelier.d.ts       completion and documentation for atelier.* in VS Code
├── types/manifest.schema.json
├── .vscode/settings.json    manifest.json completion
└── test/fixtures.json       canned network answers for tests
```

Open the folder in VS Code (or any editor that speaks TypeScript): typing `atelier.` lists
everything with its documentation, and mistakes such as an unknown event name or a misspelt
option are underlined. `main.js` starts with `// @ts-check`; remove it to turn the checks off.

`new` takes a kind and an id. Kinds: `plugin`, `theme`, and the data packs `icons`, `sounds`,
`shader`, `layouts`, `effects` and `look`. For plugins, `--template hello|timer|feed|controls` picks the
starting point (the same ones the playground offers). `--name` and `--author` fill the manifest.
A pack starts as a small working example of its kind, which passes both Atelier's and the
catalog's checks as it is; the formats are in [PACKS.md](PACKS.md).

## Trying it in Atelier

Drop the `.atelierplugin` (or `.ateliertheme`, …) folder on **Mods › Library**, or use **Install
Plugin…** there. Switch it on and allow what it asks for. After you change it, install it again,
or edit the installed copy and press **Restart** in its details. Its console is at the bottom of
Mods › Library. Try it with a light theme and a dark one: plugin views follow the widget style.

## Testing without Atelier

```sh
atelier-mod test                                 # in the project folder
atelier-mod test --run "Say Hello" --run say-hello
atelier-mod test --click focus --advance 60      # click a Dock tile, then let a minute pass
atelier-mod test --emit appActivated='{"name":"Safari","bundleID":"com.apple.Safari"}'
atelier-mod test --grant none                    # as if the owner allowed nothing
atelier-mod test --tap Add --tap Paused          # tap a button, flip a toggle, in any widget
atelier-mod test --action reset                  # run an atelier.action by id
atelier-mod test --setting step=3 --language pt  # the owner's settings and language
atelier-mod test --palette "gh atelier" --menu "kaizensx/Atelier"   # ask the palette, choose a row
atelier-mod test --stack pulls --activity upload # open a stack, click a live activity
atelier-mod test --drop url:https://github.com   # drop a link on a tile that accepts it
atelier-mod test --panel-post dashboard='{"open":1}'   # a panel's page posts a message
atelier-mod test --json                          # everything, as JSON
```

`test` runs your script in Node behind **Atelier's real prelude** (the JavaScript that builds the
`atelier` object in the app, lifted out of it word for word), with a stand-in for the native side
that checks every call the way Atelier does: ids, permissions, hosts, shortcuts, view limits,
storage size, settings against their types, menus, drops, the hooks' own limits and permissions,
the one-second time limit. It prints what the script registered (widgets, tiles, commands, corner
actions, palette providers, menu bar items, tile menus, stacks, live activities, panels), draws
every widget as an outline, lists what it did (notifications, links, theme changes, requests,
prompts, messages to other plugins, settings it changed, panel messages) and its console,
settings and storage. It exits with 1 when anything went wrong, so it fits in CI.

Time is virtual: timers, widget refreshes and `timer` events fire when you `--advance`. The
network is off: requests are answered from `test/fixtures.json`

```json
{ "http": { "GET https://api.example.com/items": { "status": 200, "json": [{ "title": "One" }] },
            "POST https://api.example.com/items": { "status": 201, "json": { "id": 7 } } },
  "prompts": { "API token": "test-token" },
  "scenes": ["Work", "Home"] }
```

or, with `--network`, really sent (still only to the hosts in your manifest).

For your own tests, use the same harness from JavaScript:

```js
import { loadPlugin } from "atelier-mod/harness";   // or sdk/cli/lib/harness.mjs in a checkout
const p = await loadPlugin("hello.atelierplugin", { fixtures });
await p.runCommand("say-hello");
const { view } = await p.render("hello");
assert.equal(view.children[0].text, "Hello");
```

What the stand-in cannot show: how your views look (use the playground or Atelier), real
notifications, links, Scenes and panel pages (a panel's HTML is not run; `--panel-post` plays its
side), and calls added to the API after your copy of the kit (they are recorded and listed, not
checked).

## Checking it

```sh
atelier-mod validate
```

runs the checks Atelier makes when it loads a mod and the ones the catalog makes when you open a
pull request: the manifest against its schema, a reverse-DNS id and a version, only allowed files
(no binaries, hidden files or links), the size limits, and **permissions that tell the truth**:
the script is scanned for `atelier.http`, `atelier.notify`, `atelier.openURL`, `atelier.theme`,
`atelier.menuBarItem`, `atelier.liveActivity`, `atelier.scenes` and `atelier.panel`, and using one
without asking for its permission fails, as does asking for one you never use. Packs are checked
by the catalog's own pack rules: every file by its bytes, sizes, pixels, sound lengths, and each
kind's keys and ranges.

These are not a copy of the rules but the catalog's own code: `atelier-mod` carries the
atelier-mods repository's `scripts/lib.mjs`, `scripts/packs.mjs` and `scripts/validate.mjs`, byte for byte, and runs
the catalog's `validateMod` on a catalog folder. `node sdk/sync-catalog.mjs` refreshes them from
a checkout of atelier-mods, and Atelier's preflight fails a release while they differ.

## Packing

```sh
atelier-mod pack --out dist
```

zips the package exactly as the catalog does (sorted entries, fixed dates), so the same files
always give the same bytes and the same SHA-256. Share the zip, or the folder, directly.

## Publishing to the catalog

```sh
atelier-mod catalog-entry --github your-handle
```

writes `catalog/mods/<id>/` the way the catalog wants it: `mod.json` filled from your manifest
(id, name, version, permissions and hosts always match it), a `description.md` to fill in, a
`screenshots/` folder and a copy of the package. Then:

1. Fill in `mod.json` (summary, tags, homepage, licence) and `description.md`.
2. Add at least one screenshot, PNG or JPEG, at least 640 px wide (16:10 fills the card).
3. Run `atelier-mod validate catalog/mods/<id>` until it is clean.
4. Fork [kaizensx/atelier-mods](https://github.com/kaizensx/atelier-mods), copy the folder into
   `mods/`, and open a pull request. One mod per pull request.

The **Validate mods** check runs on it; a maintainer reads the code, tries it, and merges. Within a
few minutes it is in everyone's Mods chapter. To update it later, raise `version` in the manifest,
run `catalog-entry` again (it keeps your description, screenshots and notes), say what changed in
`changes`, and open another pull request. An update that asks for a new permission stays off on
every Mac until its owner allows it, so ask only for what you need.

## The review checklist

What a maintainer looks at before merging. Check it yourself first.

- [ ] `atelier-mod validate` is clean on the catalog folder.
- [ ] `atelier-mod test` runs without problems, with and without the permissions granted
      (`--grant none`): a plugin should say what it needs instead of failing silently.
- [ ] It asks only for the permissions it uses, and `network.hosts` lists only the hosts it calls.
- [ ] Nothing is sent anywhere the description does not mention. Secrets (tokens) are asked for
      with `secure: true` and sent only to the service they belong to.
- [ ] No `eval`, `new Function` or reaching `atelier` indirectly (`atelier[name]`): reviewers
      cannot follow those, and the permission scan cannot either.
- [ ] Work per call is small: heavy lifting in `data` (which may be async), `view` kept cheap,
      timers no more often than needed.
- [ ] It looks right on a light theme and a dark one, and in a small widget.
- [ ] Texts are short and plain; errors tell the owner what to do.
- [ ] The id is yours (`io.github.<you>.…` or a domain you own) and will never change.
- [ ] The screenshots show the mod in Atelier, and the description says where it shows up.

## How the kit is built

Everything comes from one file, [`docs/plugin-api.json`](plugin-api.json): every function, option,
view, event, permission, limit and manifest key, with descriptions and the release that added
it. `node sdk/generate.mjs` turns it into `sdk/atelier.d.ts` and `sdk/manifest.schema.json`, and
lifts the prelude out of `Sources/DockCore/PluginPrelude.swift` for the test runner. The website's
API page reads the same file. Atelier's own tests fail when the app has a permission, event, view,
manifest key or limit the description does not list, and preflight fails while the generated
files are stale, so the types, the docs and the app stay in step.
