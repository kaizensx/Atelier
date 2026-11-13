// The harness against the engine's and the hooks' calls (API 1.1). node --test sdk/test/

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, mkdirSync, existsSync, readdirSync, lstatSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { loadPlugin } from "../cli/lib/harness.mjs";
import { parseView } from "../cli/lib/views.mjs";
import { scaffold } from "../cli/lib/scaffold.mjs";
import { kinds } from "../cli/lib/api.mjs";

const sdk = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(sdk, "..");
const cli = join(sdk, "cli/atelier-mod.mjs");

function plugin(manifest, source, files = {}) {
  const pkg = join(mkdtempSync(join(tmpdir(), "atelier-mod-")), "t.atelierplugin");
  mkdirSync(pkg, { recursive: true });
  writeFileSync(join(pkg, "manifest.json"), JSON.stringify({ format: 1, id: "io.github.you.t", name: "T", version: "1.0.0", ...manifest }));
  writeFileSync(join(pkg, "main.js"), source);
  for (const [path, content] of Object.entries(files)) { mkdirSync(dirname(join(pkg, path)), { recursive: true }); writeFileSync(join(pkg, path), content); }
  return pkg;
}

test("settings: defaults from the manifest, checked writes, settings.<key> kept out of storage", async () => {
  const p = await loadPlugin(plugin({ settings: [
    { key: "step", type: "number", title: "Step", default: 2, min: 1, max: 5 },
    { key: "mode", type: "choice", title: "Mode", options: ["a", "b"], default: "a" },
  ] }, `
    console.log(atelier.settings.get("step"), atelier.settings.get("mode"));
    try { atelier.settings.set("step", 9); } catch (e) { console.log(e.message); }
    atelier.settings.set("mode", "b");
    console.log(JSON.stringify(atelier.settings.all()));
    try { atelier.settings.get("nope"); } catch (e) { console.log(e.message); }
    try { atelier.storage.set("settings.step", 1); } catch (e) { console.log(e.message); }`));
  assert.deepEqual(p.logs.map((l) => l.text), [
    "2 a", 'settings: "step" is at most 5.', '{"step":2,"mode":"b"}',
    'settings: "nope" is not declared under settings in manifest.json.', "storage: settings.step is a setting. Use atelier.settings.set.",
  ]);
  assert.deepEqual(p.report().settings, { step: 2, mode: "b" });
});

test("buttons and toggles: inline and named actions, tapped by title", async () => {
  const p = await loadPlugin(plugin({}, `
    let n = 0, on = false;
    const w = atelier.widget({ id: "w", view: () => [
      atelier.ui.text(String(n)),
      atelier.ui.button("Add", () => { n++; w.refresh(); }),
      atelier.ui.button("Reset", "reset", { style: "plain" }),
      atelier.ui.toggle("On", on, ({ on: next }) => { on = next; w.refresh(); }),
    ] });
    atelier.action("reset", () => { n = 0; w.refresh(); });`));
  await p.renderAll();
  await p.tap("Add"); await p.tap("Add");
  assert.equal(p.widgets.get("w").view.children[0].text, "2");
  await p.tap("On");
  assert.equal(p.widgets.get("w").view.children[3].on, true);
  await p.action("reset");
  assert.equal(p.widgets.get("w").view.children[0].text, "0");
  assert.match(p.widgets.get("w").view.children[1].action, /^_w\.\d+$/);
});

test("t() picks the language, then English, then the key; asset() checks the folder", async () => {
  const strings = { en: { hi: "Hello {name}", only: "English" }, pt: { hi: "Olá {name}" } };
  const source = `console.log(atelier.t("hi", { name: "Ana" }), atelier.t("only"), atelier.t("missing"));
    console.log(atelier.asset("img/logo.png"));
    try { atelier.asset("../x.png"); } catch (e) { console.log(e.message); }
    try { atelier.asset("img/none.png"); } catch (e) { console.log(e.message); }`;
  const pkg = plugin({ strings }, source, { "img/logo.png": "png" });
  const pt = await loadPlugin(pkg, { language: "pt-BR" });
  assert.deepEqual(pt.logs.map((l) => l.text), [
    "Olá Ana English missing", "img/logo.png",
    'asset: "../x.png" is not a relative path to a png, jpg, jpeg, heic, pdf file.', 'asset: "img/none.png" is not in the plugin.',
  ]);
  assert.equal((await loadPlugin(pkg)).logs[0].text, "Hello Ana English missing");
});

test("send is recorded, and noted when the manifest does not list the receiver", async () => {
  const p = await loadPlugin(plugin({ messages: { send: ["com.example.timer"] } }, `
    atelier.send("com.example.timer", { start: 25 }); atelier.send("com.example.other", 1);
    atelier.on("message", ({ from, payload }) => console.log(from + " " + JSON.stringify(payload)));`));
  assert.deepEqual(p.effects.filter((e) => e.kind === "send").map((e) => e.to), ["com.example.timer", "com.example.other"]);
  assert.match(p.logs[0].text, /com.example.other not delivered/);
  await p.emit("message", { from: "com.example.timer", payload: { done: true } });
  assert.equal(p.logs.at(-1).text, 'com.example.timer {"done":true}');
});

test("http.post, put, patch and delete send their body and are answered from fixtures", async () => {
  const p = await loadPlugin(plugin({ permissions: ["network"], network: { hosts: ["api.example.com"] } }, `
    (async () => {
      const a = await atelier.http.post("https://api.example.com/items", { json: { title: "x" } });
      const b = await atelier.http.delete("https://api.example.com/items/1");
      console.log(a.status, a.json().id, b.status);
      try { await atelier.http.put("https://api.example.com/items/1", { body: { no: 1 } }); } catch (e) { console.log(e.message); }
    })();`), { fixtures: { http: { "POST https://api.example.com/items": { status: 201, json: { id: 7 } }, "DELETE https://api.example.com/items/1": { status: 204 } } } });
  assert.deepEqual(p.logs.map((l) => l.text), ["201 7 204", "http.put: body must be a string. Pass objects as json."]);
  assert.equal(p.effects.find((e) => e.method === "POST").body, '{"title":"x"}');
});

test("hooks: palette, menus, drops, stacks, live activities, scenes and panels", async () => {
  const p = await loadPlugin(plugin({ permissions: ["menuBar", "liveActivities", "scenes", "panels"] }, `
    atelier.paletteProvider({ id: "fruit", title: "Fruit", prefix: "fr", search: (q) =>
      ["apple", "banana"].filter((f) => f.includes(q)).map((f) => ({ title: f, action: () => console.log("chose " + f) })) });
    const item = atelier.menuBarItem({ id: "bar", symbol: "star", text: "1", menu: [
      { title: "Hello", action: () => console.log("hello") }, "separator", { title: "More", submenu: [{ title: "Deep", action: () => console.log("deep") }] }] });
    atelier.dockTile({ id: "t", title: "T", accepts: ["url"], onDrop: ({ kind, value }) => console.log(kind + " " + value),
      menu: [{ title: "Tile item", action: () => console.log("tile") }] });
    atelier.stackProvider({ id: "s", title: "S", items: async () => [{ title: "One", action: () => console.log("one") }, "Two"] });
    const a = atelier.liveActivity({ id: "up", title: "Up", text: "x", onTap: () => { console.log("tapped"); a.end(); } });
    const panel = atelier.panel({ id: "p", title: "P", html: "<p>hi</p>", onMessage: (m) => console.log("panel " + m.n) });
    atelier.on("panelMessage", ({ id, message }) => console.log("event " + id + " " + message.n));
    atelier.scenes.list().then((s) => console.log(s.map((x) => x.name).join(",")));
    panel.show();`), { fixtures: { scenes: ["Work", "Home"] } });
  const answers = await p.palette("fr ban");
  assert.deepEqual(answers.map((a) => [a.provider, a.query, a.rows.map((r) => r.title)]), [["fruit", "ban", ["banana"]]]);
  assert.deepEqual(await p.palette("banana"), []); // the prefix keeps it out
  await p.menu("banana"); await p.menu("Hello"); await p.menu("Deep"); await p.menu("Tile item");
  await p.drop("url:https://example.com");
  await assert.rejects(p.drop("text:hi"), /No tile accepts text/);
  const stack = await p.openStack("s");
  assert.deepEqual(stack.rows.map((r) => r.title), ["One", "Two"]);
  await p.tapActivity("up");
  await p.panelMessage("p", { n: 3 });
  const logs = p.logs.map((l) => l.text);
  for (const line of ["Work,Home", "chose banana", "hello", "deep", "tile", "url https://example.com", "tapped", "panel 3", "event p 3"]) assert.ok(logs.includes(line), line);
  const report = p.report();
  assert.deepEqual(Object.keys(report.hooks).sort(), ["menuBars", "palettes", "panels", "stacks", "tiles"]);
  assert.ok(report.effects.some((e) => e.kind === "panelShow") && report.effects.some((e) => e.kind === "activityEnd"));
  assert.deepEqual(p.problems, []);
});

test("hooks need their permissions and keep their limits", async () => {
  const p = await loadPlugin(plugin({ permissions: ["menuBar"] }, `
    for (const id of ["a", "b", "c"]) try { atelier.menuBarItem({ id, symbol: "star" }); } catch (e) { console.log(e.message); }
    try { atelier.panel({ id: "p", html: "" }); } catch (e) { console.log(e.message); }
    try { atelier.menuBarItem({ id: "d" }); } catch (e) { console.log(e.message); }`), { grant: ["menuBar"] });
  assert.deepEqual(p.logs.map((l) => l.text), [
    "A plugin may have at most 2 menu bar items.", 'This needs the "panels" permission, which is not granted.',
    "menuBarItem: give it a symbol, a text or both.",
  ]);
});

test("the new views are checked like Atelier checks them", () => {
  assert.equal(parseView({ type: "button", title: "Go", action: "go" }).style, "prominent");
  assert.throws(() => parseView({ type: "button", title: "Go" }), /a button needs an action/);
  assert.throws(() => parseView({ type: "image" }), /an image needs an asset/);
  assert.throws(() => parseView({ type: "chart", series: Array(9).fill({ values: [1] }) }), /at most 8 series/);
  assert.equal(parseView({ type: "grid", columns: 9, children: [] }).columns, 6);
  assert.equal(parseView({ type: "vstack", transition: "fade", children: [] }).transition, "fade");
});

test("the controls template runs: settings, buttons, toggle and strings", async () => {
  const dir = mkdtempSync(join(tmpdir(), "atelier-mod-"));
  const { pkg } = scaffold({ kind: "plugin", id: "io.github.you.counter", dir: join(dir, "c"), template: "controls" });
  const p = await loadPlugin(pkg, { settings: { step: 3 } });
  await p.renderAll();
  await p.tap("Add");
  assert.equal(p.widgets.get("counter").view.children[0].text, "3 so far");
  assert.equal(p.widgets.get("counter").spec.title, "Counter");
  await p.tap("Paused"); await p.tap("Add");
  assert.equal(p.widgets.get("counter").view.children[0].text, "3 so far");
  await p.tap("Reset");
  assert.equal(p.widgets.get("counter").view.children[0].text, "0 so far");
  assert.deepEqual(p.problems, []);
});

test("the CLI drives hooks from the command line", () => {
  const out = spawnSync(process.execPath, [cli, "test", join(repo, "examples/plugins/github-hub.atelierplugin"), "--answer", "token",
    "--fixtures", join(sdk, "test/fixtures/github-hub.json"), "--palette", "gh mods", "--menu", "kaizensx/atelier-mods", "--stack", "pulls",
    "--drop", "url:https://github.com/kaizensx/Atelier", "--json"], { encoding: "utf8" });
  const report = JSON.parse(out.stdout);
  const palette = report.effects.find((e) => e.kind === "palette");
  assert.deepEqual(palette.answers[0].rows.map((r) => r.title), ["kaizensx/atelier-mods"]);
  assert.ok(report.effects.some((e) => e.kind === "openURL" && e.url === "https://github.com/kaizensx/atelier-mods"));
  assert.deepEqual(report.problems, []);
});

// Packs: both validators, the app's (through the Swift tests, PluginAPIDescriptionTests) and the
// catalog's own scripts/packs.mjs from a checkout of atelier-mods when there is one.
test("every pack kind scaffolds into a pack the catalog's own validatePack accepts", async () => {
  const checkout = process.env.ATELIER_MODS || join(repo, "../atelier-mods");
  const packsScript = join(checkout, "scripts/packs.mjs");
  const vendored = join(sdk, "cli/vendor/atelier-mods/scripts/packs.mjs");
  for (const script of [vendored, packsScript].filter(existsSync)) {
    const { validatePack } = await import(script);
    const { walk, readJSON } = await import(join(dirname(script), "lib.mjs"));
    const themeSchema = readJSON(join(dirname(script), "../schema/atelier-theme.schema.json"));
    for (const k of kinds().filter((k) => !["plugin", "theme"].includes(k.kind))) {
      const dir = mkdtempSync(join(tmpdir(), "atelier-mod-"));
      const { pkg } = scaffold({ kind: k.kind, id: `io.github.someone.cool-${k.kind}`, dir: join(dir, "p"), name: "Cool" });
      const { errors, header } = validatePack(k.kind, pkg, walk(pkg).files, themeSchema);
      assert.deepEqual(errors, [], `${k.kind} (${relative(repo, script)})`);
      assert.equal(header.id, `io.github.someone.cool-${k.kind}`);
    }
  }
});
