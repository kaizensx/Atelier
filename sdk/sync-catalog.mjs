#!/usr/bin/env node
// Keeps the CLI's catalog rules identical to the catalog's own. `atelier-mod validate` runs the
// atelier-mods repository's scripts/validate.mjs and scripts/lib.mjs, vendored byte for byte in
// sdk/cli/vendor/atelier-mods/ with the schemas and catalog.json they read.
//
//   node sdk/sync-catalog.mjs [--from <atelier-mods checkout>]   copy them in
//   node sdk/sync-catalog.mjs --check [--from …]                 fail when they differ
//
// The checkout defaults to $ATELIER_MODS, then ../atelier-mods beside this repository.
// When no checkout is found, --check says so and passes: the vendored copy stays as it is.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { execFileSync } from "node:child_process";

const sdk = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const check = args.includes("--check");
const fromIndex = args.indexOf("--from");
const from = resolve(fromIndex >= 0 ? args[fromIndex + 1] : process.env.ATELIER_MODS || join(sdk, "../../atelier-mods"));
const vendor = join(sdk, "cli/vendor/atelier-mods");
const FILES = ["scripts/lib.mjs", "scripts/packs.mjs", "scripts/validate.mjs", "schema/mod.schema.json", "schema/atelier-theme.schema.json", "schema/collections.schema.json", "catalog.json"];

if (!existsSync(join(from, "scripts/validate.mjs"))) {
  console.log(`No atelier-mods checkout at ${from}; the vendored rules were not compared. Pass --from <path>.`);
  process.exit(0);
}

let differ = 0;
for (const file of FILES) {
  const source = join(from, file), target = join(vendor, file);
  if (!existsSync(source)) { console.log(`missing in the catalog: ${file}`); differ++; continue; }
  const want = readFileSync(source);
  const have = existsSync(target) ? readFileSync(target) : null;
  if (have && Buffer.compare(want, have) === 0) continue;
  differ++;
  if (check) { console.log(`differs from the catalog: ${file}`); continue; }
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, want);
  console.log(`copied ${file}`);
}

if (!check) {
  let commit = null;
  try { commit = execFileSync("git", ["-C", from, "rev-parse", "HEAD"], { encoding: "utf8" }).trim(); } catch {}
  const source = { repository: "https://github.com/kaizensx/atelier-mods", commit, files: FILES };
  const path = join(vendor, "SOURCE.json");
  const text = JSON.stringify(source, null, 2) + "\n";
  if (!existsSync(path) || readFileSync(path, "utf8") !== text) writeFileSync(path, text);
  console.log(differ ? `Synced ${differ} file(s) from ${from}${commit ? ` at ${commit.slice(0, 7)}` : ""}.` : "Already in sync.");
} else if (differ) {
  console.log("Run node sdk/sync-catalog.mjs to copy the catalog's current rules.");
  process.exit(1);
} else {
  console.log("The CLI's catalog rules match the catalog.");
}
