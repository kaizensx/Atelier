# Atelier Plugins

Plugins are small JavaScript programs that add things to Atelier: widgets on the desktop,
tiles in the Atelier Dock, commands in the Command palette, actions for hot corners, and
reactions to what happens on the Mac. Atelier draws everything natively; a plugin only
describes what to show.

Three complete examples are in [`examples/plugins/`](../examples/plugins):

| Example | Shows |
|---|---|
| `pomodoro.atelierplugin` | Dock tile with live text, progress and badge; widget; commands; corner action; timers; storage; notifications |
| `github-notifications.atelierplugin` | `network` permission, `atelier.http.get`, `atelier.prompt` for a secret, a list widget |
| `random-palette.atelierplugin` | `appearance` permission and `atelier.theme.apply` |

## Five-minute plugin

```
Hello.atelierplugin/
├── manifest.json
└── main.js
```

`manifest.json`:

```json
{
  "format": 1,
  "id": "com.example.hello",
  "name": "Hello",
  "version": "1.0.0",
  "author": "You",
  "description": "Says hello.",
  "icon": "hand.wave"
}
```

`main.js`:

```js
atelier.widget({
  id: "hello",
  title: "Hello",
  refresh: 60,
  view: () => atelier.ui.vstack([
    atelier.ui.text("Hello", { size: 22, weight: "bold" }),
    atelier.ui.text(new Date().toLocaleTimeString(), { color: "secondary" }),
  ]),
});

atelier.command({ title: "Say Hello", run: () => console.log("Hello!") });
```

Drop the folder on **Mods › Library** in Atelier (or use **Install Plugin…**), switch it on,
then add a **Plugin** widget to the board and pick "Hello". Once a plugin is on, its page in
Mods lists what it registered under **In Atelier** (Dock tiles, widgets, commands, corner actions)
with a button to each place. `console.log` output appears in the
chapter's Console.

## How plugins run

* **One engine each.** Every plugin gets its own JavaScriptCore virtual machine and context, on
  its own serial queue. Nothing a plugin does runs on the main thread, so a slow plugin cannot
  make Atelier or your Mac stutter. Results are marshalled to the main thread as plain data.
* **Time limits.** Each call into a plugin (loading the script, a timer, a click, a render) may
  run for at most 1 second; JavaScriptCore stops it after that. A plugin that hits the limit
  three times in a row is stopped. (The limit uses JavaScriptCore's execution time limit, which
  Atelier looks up at runtime; see Limits below.)
* **No ambient authority.** There is no `require`, `fetch`, `XMLHttpRequest`, file system,
  process, or DOM. The only way out is the `atelier` object, and everything it sends is
  validated before Atelier acts on it.
* **Plain data across the bridge.** Every call is turned into JSON and decoded by
  `PluginMessage` in `Sources/DockCore/PluginBridge.swift`. Views are a tree of plain objects,
  which Atelier draws with SwiftUI. A plugin can never run code inside Atelier's drawing.
* **Lifecycle.** A plugin's script runs top to bottom when it is switched on (and at every
  launch while it is on). It stays alive while it is on; timers and handlers keep firing. When
  it is switched off, removed or updated, its timers stop, its registrations disappear, and its
  storage is saved. **Restart** in the plugin's details reloads it from disk, which is handy
  while developing.

## Permissions

A plugin asks for permissions in its manifest; the owner grants each one separately when
switching the plugin on, and can change them later. Nothing is granted by default, and a grant
never covers more than the manifest asks for. Calling an API without its permission throws an
`Error` in the plugin.

| Permission | Allows | Notes |
|---|---|---|
| *(none)* | Drawing widgets and tiles, commands, corner actions, events, timers, `storage`, `prompt`, `console` | Always available |
| `network` | `atelier.http.get` | https only, standard port, only hosts listed in `network.hosts`, redirects may not leave them, 2 MB per response, 4 requests at once, 15 s timeout, no cookies or cache |
| `notifications` | `atelier.notify` | Notification Center; macOS asks once for Atelier itself |
| `openURL` | `atelier.openURL` | `https:` and `mailto:` links, and `atelier://studio` |
| `appearance` | `atelier.theme.apply` | Any theme key; validated like a theme; Revert in Looks undoes it |

An update that asks for more permissions than were granted is switched off until the owner
allows them.

## manifest.json

| Key | Type | Description |
|---|---|---|
| `format` **required** | integer, `1` | Manifest format. |
| `id` **required** | text | Reverse-DNS identifier, unique to the plugin: `com.example.pomodoro`. |
| `name` **required** | text (≤ 60) | Shown in Atelier. |
| `version` **required** | text | Semantic version: `1.0.0`. |
| `author` | text (≤ 80) | Who made it. |
| `description` | text (≤ 400) | What it does. |
| `entry` | bundle path to a `.js` | The script to run. Default `main.js`. At most 512 KB. |
| `icon` | SF Symbol name | Default `puzzlepiece.extension`. |
| `homepage` | https link | Where to learn more. |
| `permissions` | list of `network`, `notifications`, `openURL`, `appearance` | What it asks for. |
| `network.hosts` | list of ≤ 8 host names | Hosts `http.get` may reach. No schemes, paths, ports, wildcards, local or private addresses. Required with `network`. |

Plugins are installed in `~/Library/Application Support/Atelier/Plugins/<id>.atelierplugin`.
Their storage lives in `~/Library/Application Support/Atelier/PluginData/<id>.json`.

## API reference

Everything is on the global, frozen `atelier` object. `atelier.version` is the API version,
currently `"1.0"`.

Ids: every registration takes an `id` of letters, digits, `-`, `_` or `.` (up to 64). If you
leave it out, Atelier makes one from the `title` (`"Say Hello"` becomes `say-hello`).
Registering the same id again updates it. A plugin may register up to 24 things in all.

Functions you pass (`data`, `view`, `run`, `onClick`, handlers) may be `async` or return a
Promise. Errors they throw are caught and shown in the Console.

### `atelier.widget(spec)` → `{ id, refresh() }`

A widget for the board. Add it with the **Plugin** widget kind and choose it from the list.

| Key | Type | Default | |
|---|---|---|---|
| `id` | text | from `title` | |
| `title` | text | the id | Shown above the content and in the picker. |
| `size` | `"small"` `"medium"` `"large"` | `"small"` | The size it prefers. |
| `refresh` | seconds, 5…86400 | `60` | How often `data` and `view` run again. |
| `data` | `() => value` | none | Fetches or computes data. May be async. |
| `view` | `(data) => view` | none | Turns data into a view. If missing, `data`'s result is drawn as the view. |

`refresh()` redraws now, for example after a click elsewhere changed your state. Atelier also
redraws when the widget appears. If `data` or `view` throws, the widget shows the message.

### Views

A view is a plain object with a `type`, a string or number (drawn as text), or an array (drawn
as a vertical stack). `atelier.ui` has helpers that build the same objects.

| `type` | Keys | Helper |
|---|---|---|
| `text` | `text`, `size` (8…64, default 13), `weight` (`light` `regular` `medium` `semibold` `bold` `heavy`), `design` (`default` `rounded` `serif` `mono`), `color`, `lines` (1…8, default 2) | `ui.text(text, style)` |
| `symbol` | `name` (an SF Symbol), plus the text keys; `size` defaults to 18 | `ui.symbol(name, style)` |
| `ring` | `value` (0…1), `label`, `color`, `width` (2…14, default 6) | `ui.ring(value, style)` |
| `bar` | `value` (0…1), `label`, `color` | `ui.bar(value, style)` |
| `sparkline` | `values` (numbers; the last 240 are kept), `color`, `fill` (default `true`) | `ui.sparkline(values, style)` |
| `list` | `items`: up to 20 of `"text"` or `{ title, detail, symbol, color }` | `ui.list(items)` |
| `vstack` `hstack` `zstack` | `children`, `spacing` (0…40, default 6), `align` (`leading` `center` `trailing` `top` `bottom`) | `ui.vstack(children, style)` … |
| `spacer` | | `ui.spacer()` |

Colours are `#RRGGBB` hex or one of `primary` `secondary` `tertiary` `accent` `red` `orange`
`yellow` `green` `mint` `teal` `blue` `indigo` `purple` `pink` `gray`. `accent` follows the
widget style, so a plugin widget matches whatever theme is on. A view may hold at most 160
nodes, nest at most 8 deep, and texts are cut at 400 characters.

```js
view: (d) => atelier.ui.hstack([
  atelier.ui.ring(d.cpu, { label: Math.round(d.cpu * 100) + "%", color: "accent" }),
  atelier.ui.vstack([
    atelier.ui.text("CPU", { weight: "semibold" }),
    atelier.ui.sparkline(d.history, { color: "mint" }),
  ]),
], { spacing: 12 })
```

### `atelier.dockTile(spec)` → `{ id, update(changes) }`

A tile for the Atelier Dock.

| Key | Type | |
|---|---|---|
| `id`, `title` | text | `title` is the tile's name under the pointer. |
| `symbol` | SF Symbol name | The icon. |
| `text` | text, ≤ 12 characters | Drawn under or instead of the symbol: `"24:59"`. |
| `badge` | text or number, ≤ 4 characters; `null` hides it | A red badge. |
| `tint` | colour | The tile's colour. |
| `progress` | 0…1 | A ring around the tile. |
| `onClick` | `() => void` | Runs when the tile is clicked. |

`update(changes)` merges the changes into the tile and redraws it. Updating is cheap; a timer
that updates every second is fine.

### `atelier.command({ id?, title, subtitle?, shortcut?, run })` → id

An entry in Atelier's Command palette. `subtitle` defaults to the plugin's name. `shortcut`
is shown beside the entry, written like `"ctrl+opt+p"` or `"cmd+shift+k"` (at least one of
`cmd`, `ctrl`, `opt`; keys are a single character, `space`, `return`, `tab`, `escape` or
`f1`…`f20`). In this version the shortcut is shown in the palette, not bound globally.

### `atelier.cornerAction({ id?, title, symbol?, run })` → id

An action you can put on a hot corner or edge in Atelier's Corners chapter.

### `atelier.on(event, handler, options?)`

| Event | Payload | When |
|---|---|---|
| `appActivated` | `{ name, bundleID }` | Another app comes to the front. |
| `spaceChanged` | `{}` | The active Space changes. |
| `wallpaperChanged` | `{ live }` or `{ mesh }` | Atelier changes the live or mesh wallpaper. A wallpaper picked in System Settings is not seen. |
| `themeChanged` | `{ id, name }` | A theme or Look is applied, or reverted (`id` is `null`). |
| `timer` | `{ date }` (ms since 1970) | Every `options.interval` seconds, 5…86400, default 60. Up to 4 per plugin. |

### `atelier.notify(title, body?)` — needs `notifications`

Posts a notification. Also accepts `{ title, body }`. Titles are cut at 80 characters, bodies
at 240. Notifications need Atelier to run as an app bundle; from a development build they are
written to the system log instead.

### `atelier.openURL(url)` — needs `openURL`

Opens an `https:` or `mailto:` link in its default app, or an `atelier://studio?chapter=…` link.

### `atelier.http.get(url, { headers }?)` → Promise — needs `network`

Fetches a URL on a host listed in `network.hosts`. Resolves to a frozen response:

```js
{ status: 200, ok: true, text: "…", headers: { "content-type": "…" }, json() }
```

`ok` is true for status 200–299; other statuses still resolve, so check `ok`. Network
failures, refused hosts and oversized responses reject with an `Error`. You may set ordinary
headers such as `Authorization` and `Accept`; `Cookie`, `Host`, `Origin`, `Referer`,
`Content-Length` and `Connection` are dropped. The user agent is
`Atelier-Plugin/1.0 (<your id>)`.

### `atelier.prompt(title, { message?, placeholder?, secure? })` → Promise<string | null>

Asks the owner for one line of text in a small Atelier window, in front, with your plugin's
name on it.
`secure: true` hides what is typed: use it for tokens. Resolves to the text, or `null` if the
owner cancels. A plugin may ask at most once every 10 seconds.

### `atelier.storage`

A small key-value store of JSON values, private to the plugin and kept across launches.

| Function | |
|---|---|
| `get(key, fallback?)` | The value, or `fallback` (default `null`). |
| `set(key, value)` | Any JSON value. `null` or `undefined` removes the key. |
| `remove(key)` | Removes the key. |
| `keys()` | All keys, sorted. |

Keys are 1–128 characters; all values together may take at most 256 KB. Writes are saved
within a second and when the plugin stops.

### `atelier.theme.apply(patch)` — needs `appearance`

Applies part of a theme: any keys from [THEMES.md](THEMES.md), without `format`, `id`, `name`
or `version`. The patch is validated like a theme and refused whole if anything is wrong. The
first change from a plugin saves the owner's setup, so Revert in Looks undoes it.

```js
atelier.theme.apply({ colors: { accent: "#FF8A3D" }, wallpaper: { shader: "nebula", palette: "ember" } });
```

### Timers and console

`setTimeout`, `setInterval` (at least 1 s), `clearTimeout` and `clearInterval` work as in a
browser; a plugin may have up to 64 at once. `console.log`, `info`, `warn`, `error` and `debug`
write to the Console in Mods › Library.

## Limits

| | |
|---|---|
| Script size | 512 KB |
| Time per call | 1 s; three timeouts in a row stop the plugin |
| Registrations | 24 per plugin |
| View size | 160 nodes, 8 levels |
| Storage | 256 KB |
| Message size | 256 KB per call across the bridge |
| Network | 4 requests at once, 2 MB per response, 15 s |
| Timers | 64, plus 4 `timer` event subscriptions |

The per-call time limit uses `JSContextGroupSetExecutionTimeLimit`, which JavaScriptCore exports
but declares only in a private header. Atelier looks it up at runtime. If a future macOS removed
it, a plugin stuck in an endless loop would block only its own queue: Atelier would stay
responsive and the plugin could still be switched off, but its thread would stay busy until
Atelier quits.

## Developing

* Keep the plugin folder somewhere convenient and install it; install again to update it. Or
  edit the installed copy directly and press **Restart**.
* Watch the Console. Every error carries its line number, and every `http.get` is logged with
  its status and timing.
* Test with the owner's eye: plugin widgets follow the widget style, so try a light theme and
  a dark one.
* Keep work small per call. Do heavy lifting in `data`, which may be async, and keep `view`
  cheap.
* Atelier's own tests run each example through the real prelude with a recording bridge (see
  `Tests/DockCoreTests/PluginBridgeTests.swift`). You can copy that harness to test yours.

## Sharing in Atelier Mods

The **Mods** chapter is a catalog of community plugins and themes, kept in
[kaizensx/atelier-mods](https://github.com/kaizensx/atelier-mods). Open a pull request there with
your plugin folder, a `mod.json` and a screenshot; its CONTRIBUTING.md has the details. The
catalog checks that the permissions in your manifest are the ones your script uses, publishes a
signed index, and Atelier verifies every download against it. A plugin from the catalog still
asks for each permission when it is switched on, and an update that asks for more stays off
until the owner allows it.
