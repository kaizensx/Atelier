#!/usr/bin/env node
// atelier-mod: make, check, test and share mods for Atelier. Node 20 or later, no dependencies.
//
//   atelier-mod new <kind> <id> [--template hello|timer|feed] [--name "…"] [--author "…"] [--dir path]
//   atelier-mod validate [dir]
//   atelier-mod test [dir] [--run <command>] [--click <tile>] [--corner <id>] [--action <id>[=json]]
//                          [--emit <event>[=json]] [--advance <seconds>] [--grant all|none|a,b]
//                          [--fixtures file] [--answer text] [--network] [--json]
//   atelier-mod pack [dir] [--out folder]
//   atelier-mod catalog-entry [dir] [--out folder] [--github handle]
//   atelier-mod api [name]
//
// [dir] is a package (.atelierplugin, .ateliertheme, …), a project folder holding one, or a
// catalog folder (mods/<id>/). Default: the current folder.

import { readFileSync, existsSync } from "node:fs";
import { join, relative, resolve } from "node:path";
import { loadAPI, kinds } from "./lib/api.mjs";
import { locate, readManifest, UsageError } from "./lib/package.mjs";
import { validate } from "./lib/validate.mjs";
import { loadPlugin, PluginError } from "./lib/harness.mjs";
import { outline } from "./lib/views.mjs";
import { scaffold, pluginTemplates } from "./lib/scaffold.mjs";
import { pack, catalogEntry } from "./lib/catalog.mjs";

const tty = process.stdout.isTTY && !process.env.NO_COLOR;
const paint = (code) => (s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : String(s));
const bold = paint(1), dim = paint(2), red = paint(31), green = paint(32), yellow = paint(33), cyan = paint(36);
const here = (p) => relative(process.cwd(), p) || ".";

/** argv into { _: positionals, flags } with repeatable flags kept as arrays. */
export function parseArgs(argv) {
  const out = { _: [], flags: {} };
  const boolean = new Set(["json", "network", "force", "help", "version"]);
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-h") { out.flags.help = true; continue; }
    if (!a.startsWith("--")) { out._.push(a); continue; }
    let [key, value] = a.slice(2).split(/=(.*)/s);
    if (value === undefined && !boolean.has(key)) value = argv[++i];
    if (value === undefined) value = true;
    (out.flags[key] ??= []).push(value);
  }
  return out;
}
const flag = (args, name) => args.flags[name]?.at(-1);
const flags = (args, name) => args.flags[name] ?? [];

const HELP = `${bold("atelier-mod")}: make, check, test and share mods for Atelier.

  ${cyan("new")} <kind> <id>        Make a project: ${kinds().map((k) => k.kind).join(", ")}
                           --template ${pluginTemplates().map((t) => t.name).join("|")}  --name  --author  --dir
  ${cyan("validate")} [dir]         The checks Atelier and the catalog run
  ${cyan("test")} [dir]             Run a plugin here, with a recording stand-in for Atelier
                           --run <command>  --click <tile>  --corner <id>  --action <id>[=json]
                           --emit <event>[=json]  --advance <seconds>  --grant all|none|a,b
                           --fixtures <file>  --answer <text>  --network  --json
  ${cyan("pack")} [dir]             A zip, byte for byte as the catalog makes it   --out <folder>
  ${cyan("catalog-entry")} [dir]    mods/<id>/ ready for a pull request            --out  --github
  ${cyan("api")} [name]             Look something up in the API

  [dir] is a package, a project folder holding one, or a catalog folder. Default: here.
  Guide: https://kaizensx.github.io/Atelier/make.html`;

async function main(argv) {
  const args = parseArgs(argv);
  const [command, ...rest] = args._;
  if (flag(args, "version")) { console.log(JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")).version); return 0; }
  if (!command || flag(args, "help")) { console.log(HELP); return 0; }
  switch (command) {
    case "new": return cmdNew(rest, args);
    case "validate": return cmdValidate(rest, args);
    case "test": return cmdTest(rest, args);
    case "pack": return cmdPack(rest, args);
    case "catalog-entry": return cmdCatalog(rest, args);
    case "api": return cmdAPI(rest, args);
    default: throw new UsageError(`Unknown command "${command}". Run atelier-mod --help.`);
  }
}

function cmdNew([kind, id], args) {
  if (!kind || !id) throw new UsageError("Usage: atelier-mod new <kind> <id>, like atelier-mod new plugin io.github.you.hello");
  const { project, pkg } = scaffold({ kind, id, dir: flag(args, "dir"), name: flag(args, "name"), author: flag(args, "author"),
    template: flag(args, "template") ?? "hello", force: Boolean(flag(args, "force")) });
  console.log(`${green("✓")} Made ${bold(here(project))}/`);
  console.log(`  ${here(pkg)}/   the package Atelier installs`);
  if (kind === "plugin") {
    console.log(`  types/atelier.d.ts       completion and checks for atelier.* in main.js`);
    console.log(`  test/fixtures.json       network answers for atelier-mod test\n`);
    console.log(`Next:\n  cd ${here(project)}\n  atelier-mod test          run it here\n  atelier-mod validate      check it\n  Then drop ${here(pkg).split("/").pop()} on Mods › Library in Atelier, or paste main.js into Mods › Create.`);
  } else {
    console.log(`\nNext: edit the files in ${here(pkg)}, then atelier-mod validate and drop the folder on Mods › Library.`);
  }
  return 0;
}

async function cmdValidate([dir], args) {
  const pkg = locate(dir);
  const { issues, zipBytes } = await validate(pkg);
  if (flag(args, "json")) { console.log(JSON.stringify({ package: pkg.dir, kind: pkg.kind.kind, zipBytes, issues }, null, 2)); return issues.some((i) => i.level === "error") ? 1 : 0; }
  const { manifest } = readManifest(pkg);
  console.log(`${bold(manifest?.name ?? here(pkg.dir))} ${dim(manifest?.version ?? "")} ${dim(`(${pkg.kind.title.toLowerCase()}${pkg.catalog ? ", catalog folder" : ""})`)}`);
  for (const i of issues) console.log(`  ${i.level === "error" ? red("✗") : yellow("!")} ${dim(i.file + ":")} ${i.message}`);
  const errors = issues.filter((i) => i.level === "error").length, warnings = issues.length - errors;
  const size = zipBytes != null ? `, zips to ${(zipBytes / 1024).toFixed(1)} KB` : "";
  console.log(errors ? red(`${errors} error(s), ${warnings} warning(s)${size}.`) : green(`✓ Valid${warnings ? `, ${warnings} warning(s)` : ""}${size}.`));
  if (!pkg.catalog && !errors) console.log(dim("  Catalog checks for mod.json and screenshots run on the folder atelier-mod catalog-entry makes."));
  return errors ? 1 : 0;
}

const parsePayload = (text) => {
  if (text === undefined || text === true) return {};
  try { return JSON.parse(text); } catch { throw new UsageError(`Not JSON: ${text}`); }
};

async function cmdTest([dir], args) {
  const pkg = locate(dir);
  if (pkg.kind.kind !== "plugin") throw new UsageError("atelier-mod test runs plugins. For other kinds, use atelier-mod validate.");
  const { manifest } = readManifest(pkg);
  if (!manifest) throw new UsageError("manifest.json is missing or not valid JSON. Run atelier-mod validate.");
  const fixturesPath = flag(args, "fixtures") ?? [join(pkg.dir, "..", "test/fixtures.json"), join(pkg.dir, "test/fixtures.json")].find(existsSync);
  const fixtures = fixturesPath && existsSync(fixturesPath) ? JSON.parse(readFileSync(fixturesPath, "utf8")) : {};
  const grant = flag(args, "grant");
  const asked = manifest.permissions ?? [];
  const plugin = await loadPlugin(pkg.dir, {
    fixtures, network: Boolean(flag(args, "network")), answer: flag(args, "answer"),
    grant: grant === undefined || grant === "all" ? asked : grant === "none" ? [] : String(grant).split(",").map((s) => s.trim()),
  });

  // The steps, in the order given on the command line.
  const steps = [];
  for (let i = 0; i < argv.length; i++) {
    const m = /^--(run|click|corner|action|emit|advance)(?:=(.*))?$/s.exec(argv[i]);
    if (m) steps.push([m[1], m[2] ?? argv[++i]]);
  }
  const done = [];
  for (const [kind, value] of steps) {
    try {
      if (kind === "run") await plugin.runCommand(value);
      if (kind === "click") await plugin.click(value);
      if (kind === "corner") await plugin.corner(value);
      if (kind === "advance") await plugin.advance(Number(value) * 1000);
      if (kind === "emit" || kind === "action") {
        const [name, json] = String(value).split(/=(.*)/s);
        if (kind === "emit") await plugin.emit(name, parsePayload(json)); else await plugin.action(name, parsePayload(json));
      }
      done.push(`${kind} ${value}`);
    } catch (error) {
      if (error instanceof PluginError) plugin.problem(error.message); else throw error;
    }
  }
  await plugin.renderAll();
  const report = plugin.report();
  if (flag(args, "json")) { console.log(JSON.stringify(report, null, 2)); return report.problems.length ? 1 : 0; }

  console.log(`${bold(report.plugin.name)} ${dim(report.plugin.version)} ${dim(`(${report.plugin.id})`)}`);
  if (report.permissions.asked.length) {
    console.log(`  Permissions  ${report.permissions.asked.map((p) => (report.permissions.granted.includes(p) ? p : dim(p + " (not granted)"))).join(", ")}`);
  }
  const rows = [];
  for (const t of report.tiles) rows.push(["Dock tile", t.id, t.title, [t.symbol, t.text && `"${t.text}"`, t.badge && `badge ${t.badge}`, t.progress != null && `${Math.round(t.progress * 100)}%`].filter(Boolean).join(" · ")]);
  for (const w of report.widgets) rows.push(["Widget", w.id, w.title, `${w.size}, every ${w.refresh} s`]);
  for (const c of report.commands) rows.push(["Command", c.id, c.title, c.shortcut ?? ""]);
  for (const c of report.cornerActions) rows.push(["Corner", c.id, c.title, c.symbol]);
  for (const [kind, list] of Object.entries(report.other ?? {})) for (const x of list) rows.push([kind, x.id, x.title ?? "", ""]);
  if (rows.length) {
    console.log(`  Registered (${rows.length})`);
    const w = [0, 1, 2].map((i) => Math.max(...rows.map((r) => String(r[i]).length)));
    for (const r of rows) console.log(`    ${r[0].padEnd(w[0])}  ${cyan(String(r[1]).padEnd(w[1]))}  ${String(r[2]).padEnd(w[2])}  ${dim(r[3])}`);
  } else console.log(dim("  Registered nothing."));
  const events = Object.entries(report.events);
  if (events.length) console.log(`  Listens to   ${events.map(([e, i]) => (i ? `${e} (every ${i} s)` : e)).join(", ")}`);
  if (done.length) console.log(`  Ran          ${done.join(", ")}`);
  for (const w of report.widgets) {
    console.log(`\n  ${bold("Widget " + w.id)}`);
    if (w.error) console.log(`    ${red("✗")} ${w.error}`);
    else if (w.view) process.stdout.write(outline(w.view, "    "));
    else console.log(dim("    (nothing drawn)"));
  }
  if (report.effects.length) {
    console.log(`\n  ${bold("Did")}`);
    for (const e of report.effects) {
      const text = e.kind === "notify" ? `notify "${e.title}"${e.body ? ` · ${e.body}` : ""}`
        : e.kind === "openURL" ? `open ${e.url}`
        : e.kind === "theme" ? `theme.apply ${JSON.stringify(e.patch)}`
        : e.kind === "http" ? `${e.method} ${e.url} → ${e.status ?? "failed"} ${dim(`(${e.source})`)}`
        : e.kind === "prompt" ? `prompt "${e.title}" → ${JSON.stringify(e.answer)}`
        : `${e.kind} ${JSON.stringify(e.payload)}`;
      console.log(`    ${text}`);
    }
  }
  if (report.console.length) {
    console.log(`\n  ${bold("Console")}`);
    for (const l of report.console) {
      const tag = l.level === "error" ? red("ERROR") : l.level === "warn" ? yellow("WARN ") : dim(l.level.toUpperCase().padEnd(5));
      console.log(`    ${tag} ${l.text}`);
    }
  }
  if (Object.keys(report.storage).length) console.log(`\n  ${bold("Storage")}  ${dim(JSON.stringify(report.storage))}`);
  console.log("");
  if (report.problems.length) { console.log(red(`✗ ${report.problems.length} problem(s).`)); return 1; }
  console.log(green("✓ Ran without errors."));
  return 0;
}

function cmdPack([dir], args) {
  const pkg = locate(dir);
  const { path, bytes, sha256 } = pack(pkg, flag(args, "out") ?? ".");
  console.log(`${green("✓")} ${here(path)}  ${(bytes / 1024).toFixed(1)} KB  ${dim("sha256 " + sha256)}`);
  return 0;
}

async function cmdCatalog([dir], args) {
  const pkg = locate(dir);
  const { folder, missing } = catalogEntry(pkg, { out: flag(args, "out") ?? "catalog", github: flag(args, "github") });
  console.log(`${green("✓")} Wrote ${bold(here(folder))}/  mod.json, description.md, screenshots/, ${pkg.dir.split("/").pop()}/`);
  console.log(`\nBefore the pull request:\n  · fill in mod.json (github, summary, tags, homepage) and description.md`);
  if (missing.length) console.log(`  · add ${missing.join(", ")} (PNG or JPEG, at least 640 px wide)`);
  console.log(`  · copy ${here(folder)} into your fork of github.com/kaizensx/atelier-mods, under mods/\n  · atelier-mod validate ${here(folder)}`);
  return 0;
}

function cmdAPI([name]) {
  const api = loadAPI();
  if (!name) {
    console.log(`${bold("Atelier plugin API " + api.apiVersion)}  ${dim(api.docs)}\n`);
    for (const e of api.api) console.log(`  ${cyan(e.name.padEnd(26))} ${dim((e.since ? `[${e.since}] ` : "") + (e.description ?? "").split(". ")[0])}`);
    console.log(`\n  Views:  ${api.views.map((v) => v.type).join(", ")}\n  Events: ${api.events.map((e) => e.name).join(", ")}`);
    return 0;
  }
  const lower = name.toLowerCase().replace(/^atelier\./, "");
  const hit = api.api.find((e) => e.name.toLowerCase() === "atelier." + lower) ?? api.views.find((v) => v.type === lower)
    ?? api.events.find((e) => e.name.toLowerCase() === lower) ?? api.types.find((t) => t.name.toLowerCase() === lower);
  if (!hit) throw new UsageError(`Nothing called "${name}" in the API. Run atelier-mod api for the list.`);
  console.log(JSON.stringify(hit, null, 2));
  return 0;
}

const argv = process.argv.slice(2);
main(argv).then((code) => process.exit(code ?? 0), (error) => {
  if (error instanceof UsageError || error instanceof PluginError) { console.error(red("✗ ") + error.message); process.exit(2); }
  console.error(error); process.exit(2);
});
