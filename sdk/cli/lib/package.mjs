// Finding a mod on disk: a package folder (.atelierplugin, .ateliertheme, …), a project folder
// that holds one (what `atelier-mod new` makes), or a catalog folder (mods/<id>/ with mod.json).

import { existsSync, readdirSync, lstatSync, readFileSync } from "node:fs";
import { join, extname, resolve, basename } from "node:path";
import { kinds, kindForExt } from "./api.mjs";

export class UsageError extends Error {}

const packagesIn = (dir) => readdirSync(dir).filter((n) => kindForExt(extname(n)) && lstatSync(join(dir, n)).isDirectory());

/** { dir, kind, catalog } where dir is the package folder; catalog is the mods/<id>/ folder when there is one. */
export function locate(input = ".") {
  const dir = resolve(input);
  if (!existsSync(dir) || !lstatSync(dir).isDirectory()) throw new UsageError(`${input} is not a folder.`);
  const own = kindForExt(extname(dir));
  if (own) return { dir, kind: own, catalog: existsSync(join(dir, "..", "mod.json")) ? resolve(dir, "..") : null };
  const found = packagesIn(dir);
  if (found.length === 1) {
    return { dir: join(dir, found[0]), kind: kindForExt(extname(found[0])), catalog: existsSync(join(dir, "mod.json")) ? dir : null };
  }
  const exts = kinds().map((k) => k.ext).join(", ");
  if (found.length > 1) throw new UsageError(`${input} holds more than one package (${found.join(", ")}). Name the one you mean.`);
  throw new UsageError(`No mod package in ${input}. Expected a folder ending in one of ${exts}.`);
}

export function readManifest(pkg) {
  const file = join(pkg.dir, pkg.kind.manifest);
  if (!existsSync(file)) return { file, manifest: null, error: `${pkg.kind.manifest} is missing.` };
  try { return { file, manifest: JSON.parse(readFileSync(file, "utf8")) }; }
  catch (e) { return { file, manifest: null, error: `${pkg.kind.manifest} is not valid JSON: ${e.message}` }; }
}

export const packageName = (pkg) => basename(pkg.dir);
