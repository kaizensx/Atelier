// `atelier-mod pack` and `atelier-mod catalog-entry`.

import { writeFileSync, mkdirSync, existsSync, cpSync, rmSync, readFileSync } from "node:fs";
import { join, basename, resolve } from "node:path";
import { zipFolder, sha256 } from "../vendor/atelier-mods/scripts/lib.mjs";
import { readManifest, UsageError } from "./package.mjs";

/** Zips the package exactly as the catalog does: sorted entries, fixed timestamps, same bytes every time. */
export function pack(pkg, outDir = ".") {
  const zip = zipFolder(pkg.dir, basename(pkg.dir));
  mkdirSync(outDir, { recursive: true });
  const out = resolve(outDir, basename(pkg.dir) + ".zip");
  writeFileSync(out, zip);
  return { path: out, bytes: zip.length, sha256: sha256(zip) };
}

/**
 * Writes mods/<id>/ ready for a pull request to atelier-mods: mod.json from the manifest,
 * description.md, screenshots/, and a copy of the package. Existing mod.json, description and
 * screenshots are kept (only the package and the fields that must match it are refreshed).
 */
export function catalogEntry(pkg, { out = "catalog", github = "YOUR-GITHUB-HANDLE", license = "MIT" } = {}) {
  const { manifest, error } = readManifest(pkg);
  if (!manifest) throw new UsageError(error);
  const kind = pkg.kind.kind;
  const folder = resolve(out, kind === "native" ? "native" : "mods", manifest.id);
  mkdirSync(join(folder, "screenshots"), { recursive: true });
  const modPath = join(folder, "mod.json");
  const old = existsSync(modPath) ? JSON.parse(readFileSync(modPath, "utf8")) : {};
  const mod = {
    id: manifest.id,
    name: manifest.name,
    author: old.author ?? manifest.author ?? "Your Name",
    github: old.github ?? github,
    version: manifest.version,
    kind,
    summary: old.summary ?? (manifest.description && manifest.description.length >= 10 ? manifest.description.slice(0, 400) : "One or two sentences about what it does."),
    screenshots: old.screenshots ?? [{ file: "screenshots/1.png", caption: "What the picture shows." }],
    ...(kind === "plugin" ? { permissions: manifest.permissions ?? [] } : {}),
    ...(kind === "plugin" && manifest.network?.hosts?.length ? { hosts: manifest.network.hosts } : {}),
    minAtelier: old.minAtelier ?? "1.0.0",
    ...(old.homepage ?? manifest.homepage ? { homepage: old.homepage ?? manifest.homepage } : {}),
    license: old.license ?? license,
    tags: old.tags ?? [],
    changes: old.changes ?? "First release.",
  };
  writeFileSync(modPath, JSON.stringify(mod, null, 2) + "\n");
  const descPath = join(folder, "description.md");
  if (!existsSync(descPath)) {
    writeFileSync(descPath, `${manifest.description ?? "What it does, in a few sentences."}\n\n## How to use it\n\nWhere it shows up in Atelier, and what to click.\n`);
  }
  const target = join(folder, basename(pkg.dir));
  rmSync(target, { recursive: true, force: true });
  cpSync(pkg.dir, target, { recursive: true, filter: (src) => !basename(src).startsWith(".") });
  const missing = mod.screenshots.map((s) => (typeof s === "string" ? s : s.file)).filter((f) => !existsSync(join(folder, f)));
  return { folder, mod, missing };
}
