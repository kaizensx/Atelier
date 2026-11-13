#!/usr/bin/env node
// Validates the mods in the catalog. Runs on every pull request, and again before publishing.
//
//   node scripts/validate.mjs [--root .] [--only id,id] [--published index.json]
//                             [--author <github login>] [--labels a,b] [--removed id,id] [--pr]
//
// --published  the live index (from the dist branch): versions may only go up, and the same
//              version may not change its contents.
// --author     the pull request's author: a new mod's "github" must be them; only the owner of an
//              existing mod (or a maintainer) may change it.
// --labels     the pull request's labels. Native mods need "native-reviewed".
// --pr         pull-request mode: ownership and review labels are enforced.

import { readFileSync, existsSync, statSync, realpathSync } from "node:fs";
import { join, extname, basename, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import {
  KINDS, LIMITS, PERMISSIONS, ALLOWED, isReverseDNS, parseVersion, compareVersions, walk, contentHash,
  binaryKind, isMachO, imageSize, scanPermissions, checkSchema, zipFolder, listMods, findPackage, readJSON,
} from "./lib.mjs";

const args = Object.fromEntries(process.argv.slice(2).reduce((acc, a, i, all) => {
  if (a.startsWith("--")) acc.push([a.slice(2), all[i + 1] && !all[i + 1].startsWith("--") ? all[i + 1] : true]);
  return acc;
}, []));

const here = dirname(fileURLToPath(import.meta.url));
const root = args.root ?? join(here, "..");
// The rules (maintainers, schemas) come from beside this script, never from the tree being
// checked: on a pull request the workflow runs the base branch's copy against the PR's files.
const tooling = join(here, "..");
const config = readJSON(join(tooling, "catalog.json"));
const modSchema = readJSON(join(tooling, "schema/mod.schema.json"));
const themeSchema = readJSON(join(tooling, "schema/atelier-theme.schema.json"));
const published = args.published && existsSync(args.published) && statSync(args.published).size > 0 ? readJSON(args.published) : null;
const only = typeof args.only === "string" ? new Set(args.only.split(",").map((s) => s.trim()).filter(Boolean)) : null;
const labels = new Set(typeof args.labels === "string" ? args.labels.split(",").map((s) => s.trim()) : []);
const author = typeof args.author === "string" ? args.author : null;
const removed = typeof args.removed === "string" ? args.removed.split(",").map((s) => s.trim()).filter(Boolean) : [];
const prMode = Boolean(args.pr);
const maintainers = new Set((config.maintainers ?? []).map((m) => m.toLowerCase()));
const isMaintainer = author && maintainers.has(author.toLowerCase());

let errors = 0, warnings = 0, checked = 0;
const report = (level, file, message) => {
  if (level === "error") errors++; else warnings++;
  const tag = process.env.GITHUB_ACTIONS ? `::${level} file=${file}::` : `${level.toUpperCase()}  ${file}: `;
  console.log(tag + message);
};

/** Checks one mod folder; returns the facts the index builder needs. */
export function validateMod({ tier, id: folderName, dir }) {
  const rel = `${tier}/${folderName}`;
  const err = (m, f = rel) => report("error", f, m);
  const warn = (m, f = rel) => report("warning", f, m);

  const modPath = join(dir, "mod.json");
  if (!existsSync(modPath)) return err("mod.json is missing.");
  if (statSync(modPath).size > LIMITS.modJSON) return err(`mod.json is larger than ${LIMITS.modJSON / 1024} KB.`);
  let mod;
  try { mod = readJSON(modPath); } catch (e) { return err(`mod.json is not valid JSON: ${e.message}`, `${rel}/mod.json`); }
  for (const problem of checkSchema(modSchema, mod)) err(problem, `${rel}/mod.json`);
  if (typeof mod !== "object" || !mod) return;

  if (mod.id !== folderName) err(`The folder must be named after the id: ${tier}/${mod.id}/.`);
  if (!isReverseDNS(mod.id)) err(`"${mod.id}" is not a reverse-DNS id like io.github.you.my-mod.`);
  if (!parseVersion(mod.version)) err(`"${mod.version}" is not a version like 1.0.0.`);
  const kind = mod.kind;
  if (!KINDS[kind]) return;
  if (KINDS[kind].folder !== tier) err(kind === "native" ? "Native mods live in native/<id>/." : "Plugins and themes live in mods/<id>/.");

  const descriptionFile = join(dir, "description.md");
  const description = existsSync(descriptionFile) ? readFileSync(descriptionFile, "utf8") : mod.description ?? "";
  if (!description.trim()) err("Add a description: description.md beside mod.json, or a \"description\" in mod.json.");
  if (description.length > LIMITS.description) err(`The description is longer than ${LIMITS.description} characters.`);

  // The package.
  const pkg = findPackage(dir, kind);
  if (!pkg) return err(`Put the package in this folder: one ${KINDS[kind].ext} folder.`);
  if (Array.isArray(pkg)) return err(`Only one ${KINDS[kind].ext} folder per mod, found ${pkg.join(", ")}.`);
  const pkgRel = `${rel}/${basename(pkg)}`;
  const { files, problems } = walk(pkg);
  problems.forEach((p) => err(p, pkgRel));
  for (const f of files) {
    const ext = extname(f.path).toLowerCase();
    if (!ALLOWED[kind].includes(ext)) err(`${f.path}: ${ext || "files without an extension"} are not allowed in a ${kind}.`, pkgRel);
    const head = readFileSync(f.full).subarray(0, 8);
    const binary = binaryKind(head);
    if (kind !== "native" && binary) err(`${f.path}: a ${binary} is not allowed outside the native tier.`, pkgRel);
    if (kind === "native" && ext === ".dylib" && !isMachO(head)) err(`${f.path}: not a Mach-O library.`, pkgRel);
    if (kind === "native" && ext !== ".dylib" && binary) err(`${f.path}: a ${binary} is only allowed as a .dylib payload.`, pkgRel);
  }
  // Zipped only when the folder is clean; the other checks still run, so one pass lists everything.
  const zip = problems.length ? null : zipFolder(pkg, basename(pkg));
  if (zip && zip.length > KINDS[kind].maxZip) err(`The package zips to ${(zip.length / 1048576).toFixed(1)} MB; a ${kind} may be at most ${KINDS[kind].maxZip / 1048576} MB.`, pkgRel);

  const same = (field, value, file) => { if (value !== mod[field]) err(`${field} is "${value}" in ${file} but "${mod[field]}" in mod.json.`, pkgRel); };
  const declared = new Set(mod.permissions ?? []);
  if (kind === "plugin") {
    const manifestPath = join(pkg, "manifest.json");
    if (!existsSync(manifestPath)) return err("manifest.json is missing.", pkgRel);
    let manifest;
    try { manifest = readJSON(manifestPath); } catch (e) { return err(`manifest.json is not valid JSON: ${e.message}`, pkgRel); }
    if (manifest.format !== 1) err("manifest.json needs \"format\": 1.", pkgRel);
    same("id", manifest.id, "manifest.json"); same("name", manifest.name, "manifest.json"); same("version", manifest.version, "manifest.json");
    const asked = new Set(manifest.permissions ?? []);
    for (const p of asked) if (!PERMISSIONS.includes(p)) err(`manifest.json asks for "${p}", which is not a permission.`, pkgRel);
    const a = [...asked].sort().join(","), d = [...declared].sort().join(",");
    if (a !== d) err(`mod.json lists permissions [${d}] but manifest.json asks for [${a}]. They must match.`);
    const hosts = (manifest.network?.hosts ?? []).map((h) => h.toLowerCase()).sort().join(",");
    if (hosts !== (mod.hosts ?? []).map((h) => h.toLowerCase()).sort().join(",")) err("mod.json \"hosts\" must equal manifest.json network.hosts.");
    const entry = manifest.entry ?? "main.js";
    const script = files.find((f) => f.path === entry);
    if (!script) err(`The entry script ${entry} is not in the package.`, pkgRel);
    else if (script.size > LIMITS.pluginScript) err(`${entry} is larger than 512 KB.`, pkgRel);
    // Declared versus used: the chips on the card must tell the truth.
    const used = new Set();
    let dynamic = false;
    for (const f of files.filter((f) => f.path.endsWith(".js"))) {
      const scan = scanPermissions(readFileSync(f.full, "utf8"));
      scan.used.forEach((p) => used.add(p));
      dynamic ||= scan.dynamicAccess;
      const code = readFileSync(f.full, "utf8");
      if (/\beval\s*\(|\bnew\s+Function\s*\(/.test(code)) warn(`${f.path}: eval or new Function makes review harder. Reviewers will look closely.`, pkgRel);
    }
    for (const p of used) if (!asked.has(p)) err(`The script calls atelier.${{ network: "http", notifications: "notify", openURL: "openURL", appearance: "theme" }[p]} but does not ask for "${p}".`, pkgRel);
    for (const p of asked) if (!used.has(p)) {
      (dynamic ? warn : err)(`It asks for "${p}" but the script never uses it. Ask only for what it needs.`, pkgRel);
    }
    if (dynamic) warn("The script reaches atelier dynamically (atelier[...] or passes atelier around), so the permission scan cannot follow it.", pkgRel);
  } else {
    if (declared.size || (mod.hosts ?? []).length) err("Only plugins have permissions and hosts.");
  }
  if (kind === "theme") {
    const themePath = join(pkg, "atelier-theme.json");
    if (!existsSync(themePath)) return err("atelier-theme.json is missing.", pkgRel);
    if (statSync(themePath).size > 256 * 1024) err("atelier-theme.json is larger than 256 KB.", pkgRel);
    let theme;
    try { theme = readJSON(themePath); } catch (e) { return err(`atelier-theme.json is not valid JSON: ${e.message}`, pkgRel); }
    for (const problem of checkSchema(themeSchema, theme)) err(`atelier-theme.json ${problem}`, pkgRel);
    same("id", theme.id, "atelier-theme.json"); same("name", theme.name, "atelier-theme.json"); same("version", theme.version, "atelier-theme.json");
    for (const path of [theme.preview, theme.wallpaper?.image, ...Object.values(theme.sounds ?? {})]) {
      if (typeof path === "string" && path.includes(".") && /\.[a-z0-9]{3,4}$/i.test(path) && !files.some((f) => f.path === path)) {
        if (path.includes("/") || path === theme.preview) err(`atelier-theme.json names ${path}, which is not in the package.`, pkgRel);
      }
    }
  }
  if (kind === "native") {
    const manifestPath = join(pkg, "atelier-mod.json");
    if (!existsSync(manifestPath)) return err("atelier-mod.json is missing.", pkgRel);
    let manifest;
    try { manifest = readJSON(manifestPath); } catch (e) { return err(`atelier-mod.json is not valid JSON: ${e.message}`, pkgRel); }
    if (manifest.format !== 1) err("atelier-mod.json needs \"format\": 1.", pkgRel);
    same("id", manifest.id, "atelier-mod.json"); same("version", manifest.version, "atelier-mod.json");
    const payload = manifest.payload ?? "payload.dylib";
    if (!files.some((f) => f.path === payload)) err(`The payload ${payload} is not in the package.`, pkgRel);
    const archs = manifest.architectures ?? [];
    if (!archs.length || !archs.every((a) => ["arm64e", "x86_64"].includes(a))) err("atelier-mod.json must list architectures: arm64e, x86_64.", pkgRel);
    if (!homepageIsSource(mod.homepage)) err("Native mods must link their source code as homepage (https://github.com/...).");
    if (prMode && !labels.has("native-reviewed")) err("Native mods need a maintainer's review. A maintainer adds the native-reviewed label after reading the source.");
  }

  // Screenshots.
  const shots = [];
  for (const item of mod.screenshots ?? []) {
    const file = typeof item === "string" ? item : item?.file;
    if (typeof file !== "string") continue;
    const full = join(dir, file);
    if (!existsSync(full)) { err(`${file} is missing.`); continue; }
    const buf = readFileSync(full);
    if (buf.length > LIMITS.screenshotBytes) err(`${file} is larger than 1.5 MB.`);
    const size = imageSize(buf);
    if (!size) { err(`${file} is not a PNG or JPEG.`); continue; }
    if (size.width < LIMITS.screenshotMinWidth) err(`${file} is ${size.width} px wide; screenshots need at least ${LIMITS.screenshotMinWidth}.`);
    shots.push({ file, full, buf, ...size, caption: typeof item === "object" ? item.caption : undefined });
  }
  if (!shots.length) err("Add at least one screenshot in screenshots/.");

  if (mod.minAtelier && !parseVersion(mod.minAtelier)) err(`minAtelier "${mod.minAtelier}" is not a version.`);

  // Against what is live.
  const live = published?.mods?.find((m) => m.id === mod.id);
  const hash = contentHash(pkg);
  if (live && parseVersion(mod.version) && parseVersion(live.version)) {
    const order = compareVersions(mod.version, live.version);
    if (order < 0) err(`Version ${mod.version} is older than the published ${live.version}.`);
    if (order === 0 && live.contentHash && live.contentHash !== hash) err(`The package changed but the version is still ${mod.version}. Bump the version in mod.json and the package.`);
  }
  if (prMode && author && !isMaintainer) {
    if (live && live.github?.toLowerCase() !== author.toLowerCase() && !labels.has("maintainer-approved")) {
      err(`${mod.id} belongs to @${live.github}. Only they or a maintainer may change it.`);
    }
    if (live && mod.github?.toLowerCase() !== live.github?.toLowerCase()) err("The github owner of a published mod cannot change in a pull request. Ask a maintainer.");
    if (!live && mod.github?.toLowerCase() !== author.toLowerCase()) err(`"github" must be your own handle (@${author}).`);
  }
  return zip ? { mod, kind, tier, dir, pkg, zip, hash, description, shots } : undefined;
}

function homepageIsSource(url) {
  return typeof url === "string" && /^https:\/\/(github\.com|gitlab\.com|codeberg\.org)\//.test(url);
}

export function validateAll() {
  const results = [];
  const seen = new Map();
  for (const entry of listMods(root)) {
    if (seen.has(entry.id)) report("error", `${entry.tier}/${entry.id}`, `The id ${entry.id} is also used in ${seen.get(entry.id)}/.`);
    seen.set(entry.id, entry.tier);
    if (only && !only.has(entry.id)) continue;
    checked++;
    const r = validateMod(entry);
    if (r) results.push(r);
  }
  for (const id of config.featured ?? []) if (!seen.has(id)) report("warning", "catalog.json", `Featured mod ${id} is not in the catalog.`);
  // Taking a mod down: only its owner or a maintainer.
  for (const id of removed) {
    if (seen.has(id)) continue;
    const live = published?.mods?.find((m) => m.id === id);
    if (prMode && live && !isMaintainer && live.github?.toLowerCase() !== author?.toLowerCase()) {
      report("error", id, `Only @${live.github} or a maintainer may remove ${id}.`);
    }
  }
  return results;
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const results = validateAll();
  console.log(`\n${checked} mod(s) checked: ${errors} error(s), ${warnings} warning(s).`);
  process.exit(errors ? 1 : 0);
}

export const counts = () => ({ errors, warnings });
