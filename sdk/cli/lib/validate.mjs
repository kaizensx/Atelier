// `atelier-mod validate`: the checks a mod meets before Atelier loads it and before the catalog
// accepts it.
//
// The catalog's rules are not re-implemented here. The helpers (permission scan, file walk,
// binary sniffing, schema checker, zip writer, limits) are the atelier-mods repository's own
// scripts/lib.mjs, and a catalog folder (mods/<id>/ with mod.json) is checked by that
// repository's own validateMod from scripts/validate.mjs. Both are vendored byte for byte in
// ../vendor/atelier-mods/ by sdk/sync-catalog.mjs, which preflight runs with --check.

import { readFileSync, existsSync } from "node:fs";
import { join, extname, basename, dirname } from "node:path";
import {
  KINDS, ALLOWED, PERMISSIONS, PERMISSION_CALLS, isReverseDNS, parseVersion, walk, binaryKind, scanPermissions, checkSchema, zipFolder, readJSON,
} from "../vendor/atelier-mods/scripts/lib.mjs";
import { loadAPI, cliRoot, sdkRoot, limit } from "./api.mjs";
import { readManifest } from "./package.mjs";

const manifestSchema = () => {
  for (const p of [join(sdkRoot, "manifest.schema.json"), join(cliRoot, "runtime/manifest.schema.json")]) if (existsSync(p)) return readJSON(p);
  return null;
};

/** Returns { issues: [{ level, file, message }], zipBytes }. */
export async function validate(pkg) {
  const issues = [];
  const rel = basename(pkg.dir);
  const err = (message, file = rel) => issues.push({ level: "error", file, message });
  const warn = (message, file = rel) => issues.push({ level: "warning", file, message });
  const kind = pkg.kind.kind;
  const catalogKind = KINDS[kind];

  // Files: what the catalog allows, no binaries, no hidden files or links.
  const { files, problems } = walk(pkg.dir);
  problems.forEach((p) => err(p));
  const allowed = ALLOWED[kind] ?? pkg.kind.allowed ?? [];
  for (const f of files) {
    const ext = extname(f.path).toLowerCase();
    if (!allowed.includes(ext)) err(`${f.path}: ${ext || "files without an extension"} are not allowed in a ${kind}.`);
    const binary = binaryKind(readFileSync(f.full).subarray(0, 8));
    if (binary) err(`${f.path}: a ${binary} is not allowed outside the native tier.`);
  }
  let zipBytes = null;
  if (!problems.length) {
    zipBytes = zipFolder(pkg.dir, basename(pkg.dir)).length;
    const max = catalogKind?.maxZip ?? pkg.kind.maxZip;
    if (max && zipBytes > max) err(`The package zips to ${(zipBytes / 1048576).toFixed(1)} MB; a ${kind} may be at most ${max / 1048576} MB.`);
  }

  const { file, manifest, error } = readManifest(pkg);
  const mfile = `${rel}/${basename(file)}`;
  if (!manifest) { err(error, mfile); return { issues, zipBytes }; }
  if (!isReverseDNS(manifest.id)) err(`"${manifest.id}" is not a reverse-DNS identifier, like com.example.pomodoro.`, mfile);
  if (!parseVersion(manifest.version) || !/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(String(manifest.version))) err(`"${manifest.version}" is not a version like 1.0.0.`, mfile);
  if (typeof manifest.name !== "string" || !manifest.name.trim()) err("name: Required, but missing.", mfile);

  if (kind === "plugin") checkPlugin(pkg, manifest, files, err, warn, mfile);
  else if (kind === "theme") {
    const schema = join(cliRoot, "vendor/atelier-mods/schema/atelier-theme.schema.json");
    for (const problem of checkSchema(readJSON(schema), manifest)) err(problem, mfile);
  } else {
    // Packs: the catalog's own rules (scripts/packs.mjs), the same limits the app applies.
    const { validatePack } = await import("../vendor/atelier-mods/scripts/packs.mjs");
    const themeSchema = readJSON(join(cliRoot, "vendor/atelier-mods/schema/atelier-theme.schema.json"));
    for (const problem of validatePack(kind, pkg.dir, files, themeSchema).errors) err(problem);
  }

  if (pkg.catalog) issues.push(...await validateCatalogFolder(pkg.catalog));
  return { issues, zipBytes };
}

function checkPlugin(pkg, manifest, files, err, warn, mfile) {
  const schema = manifestSchema();
  if (schema) for (const problem of checkSchema(schema, manifest)) {
    (/unknown key/.test(problem) ? warn : err)(problem.replace(/unknown key\.$/, "Unknown key, ignored."), mfile);
  }
  const asked = new Set(manifest.permissions ?? []);
  for (const p of asked) if (!PERMISSIONS.includes(p) && !loadAPI().permissions.some((x) => x.name === p)) err(`"${p}" is not a permission. Use ${PERMISSIONS.join(", ")}.`, mfile);
  const hosts = manifest.network?.hosts ?? [];
  if (asked.has("network") && !hosts.length) err("network.hosts: The network permission needs at least one host.", mfile);
  if (hosts.length && !asked.has("network")) warn("network.hosts: Hosts are listed but the network permission is not asked for, so they are unused.", mfile);
  for (const host of hosts) {
    if (!/^[a-z0-9-]+(\.[a-z0-9-]+)+$/i.test(host) || /^(localhost|.*\.local|.*\.internal|\d+\.\d+\.\d+\.\d+)$/i.test(host)) {
      err(`network.hosts: "${host}" is not a public host name like api.github.com. No schemes, paths, ports or wildcards.`, mfile);
    }
  }
  const entry = manifest.entry ?? "main.js";
  const script = files.find((f) => f.path === entry);
  if (!script) err(`The entry script ${entry} is not in the package.`);
  else if (script.size > limit("scriptBytes")) err(`${entry} is larger than ${limit("scriptBytes") / 1024} KB.`);
  // Declared versus used, exactly as the catalog checks it.
  const used = new Set();
  let dynamic = false;
  for (const f of files.filter((f) => f.path.endsWith(".js"))) {
    const code = readFileSync(f.full, "utf8");
    const scan = scanPermissions(code);
    scan.used.forEach((p) => used.add(p));
    dynamic ||= scan.dynamicAccess;
    if (/\beval\s*\(|\bnew\s+Function\s*\(/.test(code)) warn(`${f.path}: eval or new Function makes review harder. Reviewers will look closely.`);
  }
  for (const p of used) if (!asked.has(p)) err(`The script calls ${PERMISSION_CALLS[p]} but does not ask for "${p}".`);
  for (const p of asked) if (!used.has(p)) (dynamic ? warn : err)(`It asks for "${p}" but the script never uses it. Ask only for what it needs.`);
  if (dynamic) warn("The script reaches atelier dynamically (atelier[...] or passes atelier around), so the permission scan cannot follow it.");
}

/** Runs the catalog's own validateMod on a mods/<id>/ folder and collects what it reports. */
async function validateCatalogFolder(dir) {
  const { validateMod } = await import("../vendor/atelier-mods/scripts/validate.mjs");
  const out = [];
  const original = console.log;
  console.log = (line) => {
    const m = /^(ERROR|WARNING)\s+(.+?): (.*)$/s.exec(String(line));
    if (m) out.push({ level: m[1] === "ERROR" ? "error" : "warning", file: m[2], message: m[3], catalog: true });
    else original(line);
  };
  try {
    const tier = basename(dirname(dir)) === "native" ? "native" : "mods";
    validateMod({ tier, id: basename(dir), dir });
  } finally {
    console.log = original;
  }
  return out;
}
