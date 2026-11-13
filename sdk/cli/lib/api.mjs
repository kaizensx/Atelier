// The API description the CLI works from: sdk/cli/runtime/plugin-api.json, a copy of
// docs/plugin-api.json written by sdk/generate.mjs, so the CLI also works when installed alone.

import { readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const cliRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
export const sdkRoot = join(cliRoot, "..");

let cached;
export function loadAPI() {
  if (cached) return cached;
  // In the Atelier repository the docs copy is the source of truth; installed, the runtime copy.
  const candidates = [join(sdkRoot, "../docs/plugin-api.json"), join(cliRoot, "runtime/plugin-api.json")];
  const path = candidates.find((p) => existsSync(p));
  cached = JSON.parse(readFileSync(path, "utf8"));
  return cached;
}

export const limit = (key) => loadAPI().limits.find((l) => l.key === key)?.value;
export const kinds = () => loadAPI().kinds;
export const kindForExt = (ext) => kinds().find((k) => k.ext === ext);
export const kindNamed = (name) => kinds().find((k) => k.kind === name);
