// node --test sdk/test/   (Node 20+, no dependencies)

import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync, readFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync, spawnSync } from "node:child_process";
import { loadPlugin } from "../cli/lib/harness.mjs";
import { parseView } from "../cli/lib/views.mjs";
import { validate } from "../cli/lib/validate.mjs";
import { locate } from "../cli/lib/package.mjs";
import { scaffold, pluginTemplates } from "../cli/lib/scaffold.mjs";
import { pack, catalogEntry } from "../cli/lib/catalog.mjs";
import { loadAPI, kinds } from "../cli/lib/api.mjs";

const sdk = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(sdk, "..");
const cli = join(sdk, "cli/atelier-mod.mjs");
const temp = () => mkdtempSync(join(tmpdir(), "atelier-mod-"));

function plugin(dir, manifest, source) {
  const pkg = join(dir, "t.atelierplugin");
  mkdirSync(pkg, { recursive: true });
  writeFileSync(join(pkg, "manifest.json"), JSON.stringify({ format: 1, id: "io.github.you.t", name: "T", version: "1.0.0", ...manifest }));
  writeFileSync(join(pkg, "main.js"), source);
  return pkg;
}

test("the generated SDK is up to date with docs/plugin-api.json and the prelude", () => {
  const r = spawnSync(process.execPath, [join(sdk, "generate.mjs"), "--check"], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test("the API description is consistent", () => {
  const api = loadAPI();
  const names = new Set(api.types.map((t) => t.name));
  for (const e of api.api) if (e.permission) assert.ok(api.permissions.some((p) => p.name === e.permission), e.name);
  for (const p of api.permissions) for (const fn of p.apis) assert.ok(api.api.some((e) => e.name === fn), `${p.name}: ${fn}`);
  for (const v of api.views) if (v.main) assert.ok(v.props.some((p) => p.name === v.main), v.type);
  for (const k of ["WidgetSpec", "TileSpec", "CommandSpec", "CornerActionSpec", "HttpResponse"]) assert.ok(names.has(k), k);
  assert.equal(new Set(api.events.map((e) => e.name)).size, api.events.length);
});

test("every template runs, registers something and draws without errors", async () => {
  for (const t of pluginTemplates()) {
    const dir = temp();
    const { pkg } = scaffold({ kind: "plugin", id: `io.github.you.${t.name}`, dir: join(dir, t.name), template: t.name });
    const p = await loadPlugin(pkg, { fixtures: t.fixtures });
    const rendered = await p.renderAll();
    assert.deepEqual(p.problems, [], `${t.name}: ${p.problems.join("; ")}`);
    assert.ok(p.widgets.size + p.tiles.size + p.commands.size > 0, t.name);
    for (const [id, r] of Object.entries(rendered)) assert.ok(r.view && !r.error, `${t.name}/${id}`);
  }
});

test("the shipped examples load through the real prelude", async () => {
  const pomodoro = await loadPlugin(join(repo, "examples/plugins/pomodoro.atelierplugin"));
  assert.ok(pomodoro.tiles.has("timer") && pomodoro.widgets.has("focus") && pomodoro.commands.has("toggle") && pomodoro.corners.has("toggle"));
  await pomodoro.click("timer");
  await pomodoro.advance(3000);
  assert.equal(pomodoro.tiles.get("timer").text, "24:57");
  assert.deepEqual(pomodoro.problems, []);
});

test("commands, storage and refresh round-trip", async () => {
  const dir = temp();
  const pkg = plugin(dir, {}, `
    let n = atelier.storage.get("n", 0);
    const w = atelier.widget({ id: "w", view: () => "n=" + n });
    atelier.command({ title: "Bump", run: () => { n += 1; atelier.storage.set("n", n); w.refresh(); } });`);
  const p = await loadPlugin(pkg);
  await p.runCommand("Bump");
  await p.runCommand("bump");
  assert.equal((await p.render("w")).view.text, "n=2");
  assert.deepEqual(p.storage, { n: 2 });
});

test("calls without a granted permission throw in the plugin, as in Atelier", async () => {
  const dir = temp();
  const pkg = plugin(dir, { permissions: ["notifications"] }, `
    try { atelier.notify("Hi"); console.log("sent"); } catch (e) { console.log("refused: " + e.message); }
    try { atelier.openURL("https://example.com"); } catch (e) { console.log("refused: " + e.message); }`);
  const granted = await loadPlugin(pkg);
  assert.equal(granted.effects[0].kind, "notify");
  assert.match(granted.logs[1].text, /openURL.*not granted/);
  const none = await loadPlugin(pkg, { grant: [] });
  assert.match(none.logs[0].text, /refused: This needs the "notifications" permission/);
});

test("network is limited to listed https hosts and answered from fixtures", async () => {
  const dir = temp();
  const pkg = plugin(dir, { permissions: ["network"], network: { hosts: ["api.example.com"] } }, `
    atelier.http.get("https://api.example.com/x").then((r) => console.log("ok " + r.json().a), (e) => console.log("no " + e.message));
    atelier.http.get("http://api.example.com/x").catch((e) => console.log("no " + e.message));
    atelier.http.get("https://evil.example.org/").catch((e) => console.log("no " + e.message));`);
  const p = await loadPlugin(pkg, { fixtures: { http: { "https://api.example.com/x": { json: { a: 7 } } } } });
  const lines = p.logs.map((l) => l.text).sort();
  assert.deepEqual(lines, ["no Only https is allowed.", "no evil.example.org is not listed in network.hosts.", "ok 7"]);
});

test("views are checked like Atelier checks them", () => {
  assert.equal(parseView("Hi").type, "text");
  assert.equal(parseView([1, 2]).children.length, 2);
  assert.equal(parseView({ type: "ring", value: 4 }).value, 1);
  assert.throws(() => parseView({ type: "canvas" }), /unknown view type "canvas"/);
  assert.throws(() => parseView({ type: "symbol", name: "Not A Symbol" }), /a symbol needs a name/);
  let deep = "x";
  for (let i = 0; i < 10; i++) deep = [deep];
  assert.throws(() => parseView(deep), /nest more than 8 deep/);
  assert.throws(() => parseView(Array.from({ length: 300 }, () => "x")), /more than 240 views/);
});

test("a widget whose view is wrong reports the error, not a crash", async () => {
  const dir = temp();
  const p = await loadPlugin(plugin(dir, {}, `atelier.widget({ id: "w", view: () => ({ type: "nope" }) });`));
  assert.match(p.widgets.get("w").error, /unknown view type "nope"/);
});

test("registrations stop at the limit, and a script that loops is stopped", async () => {
  const dir = temp();
  const many = await loadPlugin(plugin(dir, {}, `for (let i = 0; i < 30; i++) atelier.command({ title: "C" + i, run() {} });`));
  assert.equal(many.commands.size, 24);
  assert.match(many.problems[0], /at most 24/);
  // In a child process: V8's timeout inside node:test's async hooks trips a Node assertion.
  const loop = plugin(temp(), {}, `atelier.command({ title: "Spin", run: () => { for (;;) {} } });`);
  const r = spawnSync(process.execPath, [cli, "test", loop, "--run", "Spin", "--json"], { encoding: "utf8", timeout: 20000 });
  assert.match(JSON.parse(r.stdout).problems[0], /longer than 1 s/);
});

test("the sandbox has no ambient authority", async () => {
  const p = await loadPlugin(plugin(temp(), {}, `console.log([typeof require, typeof process, typeof fetch, typeof __atelierNative].join(","));`));
  assert.equal(p.logs[0].text, "undefined,undefined,undefined,undefined");
});

test("validate catches undeclared and unused permissions, hidden files and binaries", async () => {
  const dir = temp();
  const pkg = plugin(dir, { permissions: ["appearance"] }, `atelier.notify("x");`);
  writeFileSync(join(pkg, ".DS_Store"), "x");
  writeFileSync(join(pkg, "tool.js"), Buffer.from([0xcf, 0xfa, 0xed, 0xfe, 0, 0, 0, 0]));
  const { issues } = await validate(locate(pkg));
  const text = issues.map((i) => i.message).join("\n");
  assert.match(text, /calls atelier.notify but does not ask for "notifications"/);
  assert.match(text, /asks for "appearance" but the script never uses it/);
  assert.match(text, /hidden files are not allowed/);
  assert.match(text, /Mach-O/);
});

test("every kind scaffolds into a package that validates", async () => {
  for (const k of kinds()) {
    const dir = temp();
    const { pkg } = scaffold({ kind: k.kind, id: `io.github.you.my-${k.kind}`, dir: join(dir, "p") });
    const { issues } = await validate(locate(pkg));
    assert.deepEqual(issues.filter((i) => i.level === "error"), [], k.kind);
  }
});

test("pack is deterministic and catalog-entry writes a folder the catalog's own check reads", async () => {
  const dir = temp();
  const { pkg, project } = scaffold({ kind: "plugin", id: "io.github.you.hello", dir: join(dir, "hello") });
  const a = pack(locate(project), join(dir, "a")), b = pack(locate(project), join(dir, "b"));
  assert.equal(a.sha256, b.sha256);
  const { folder, missing } = catalogEntry(locate(pkg), { out: join(dir, "catalog"), github: "you" });
  assert.deepEqual(missing, ["screenshots/1.png"]);
  const mod = JSON.parse(readFileSync(join(folder, "mod.json"), "utf8"));
  assert.equal(mod.id, "io.github.you.hello");
  const { issues } = await validate(locate(folder));
  const catalog = issues.filter((i) => i.catalog).map((i) => i.message);
  assert.deepEqual(catalog, ["screenshots/1.png is missing.", "Add at least one screenshot in screenshots/."]);
});

test("the CLI runs end to end", () => {
  const dir = temp();
  execFileSync(process.execPath, [cli, "new", "plugin", "io.github.you.cli", "--template", "timer", "--dir", join(dir, "cli")]);
  const out = execFileSync(process.execPath, [cli, "test", join(dir, "cli"), "--run", "toggle", "--advance", "2", "--json"], { encoding: "utf8" });
  const report = JSON.parse(out);
  assert.equal(report.tiles[0].text, "24:58");
  const bad = spawnSync(process.execPath, [cli, "new", "plugin", "not-an-id"], { encoding: "utf8" });
  assert.equal(bad.status, 2);
  assert.match(bad.stderr, /not a reverse-DNS id/);
});

test("the vendored catalog rules match a local atelier-mods checkout, when there is one", () => {
  const r = spawnSync(process.execPath, [join(sdk, "sync-catalog.mjs"), "--check"], { encoding: "utf8" });
  assert.equal(r.status, 0, r.stdout);
});
