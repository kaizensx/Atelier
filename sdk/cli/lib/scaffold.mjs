// `atelier-mod new <kind> <id>`: a project folder with the package, types and editor setup.
//
//   my-mod/
//   ├── jsconfig.json            checks main.js against types/atelier.d.ts (plugins)
//   ├── .vscode/settings.json    manifest.json completion from types/manifest.schema.json
//   ├── types/                   atelier.d.ts and manifest.schema.json
//   ├── test/fixtures.json       canned network answers for `atelier-mod test` (plugins)
//   └── my-mod.atelierplugin/    the package itself: what Atelier installs and the catalog ships

import { readFileSync, writeFileSync, mkdirSync, existsSync, readdirSync, copyFileSync } from "node:fs";
import { join } from "node:path";
import { cliRoot, sdkRoot, kinds, kindNamed } from "./api.mjs";
import { UsageError } from "./package.mjs";

const templates = join(cliRoot, "templates");

export function pluginTemplates() {
  const dir = join(templates, "plugin");
  return readdirSync(dir).filter((n) => existsSync(join(dir, n, "template.json"))).map((name) => ({
    name, ...JSON.parse(readFileSync(join(dir, name, "template.json"), "utf8")), source: readFileSync(join(dir, name, "main.js"), "utf8"),
  })).sort((a, b) => (a.order ?? 99) - (b.order ?? 99));
}

const titleFrom = (id) => id.split(".").at(-1).split(/[-_]/).filter(Boolean).map((w) => w[0].toUpperCase() + w.slice(1)).join(" ");
const slug = (id) => id.split(".").at(-1).toLowerCase().replace(/[^a-z0-9-]+/g, "-");
const fill = (text, vars) => text.replace(/\{\{(\w+)\}\}/g, (m, k) => (k in vars ? vars[k] : m));
const write = (path, content) => {
  mkdirSync(join(path, ".."), { recursive: true });
  writeFileSync(path, typeof content === "string" ? content : JSON.stringify(content, null, 2) + "\n");
};

/** Returns the project folder it made. */
export function scaffold({ kind: kindName, id, dir, name, author = "You", template = "hello", force = false }) {
  const kind = kindNamed(kindName);
  if (!kind) throw new UsageError(`Unknown kind "${kindName}". Use ${kinds().map((k) => k.kind).join(", ")}.`);
  if (!/^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$/.test(id ?? "")) {
    throw new UsageError(`"${id ?? ""}" is not a reverse-DNS id. Use one that is yours, like io.github.you.${kindName === "plugin" ? "hello" : "my-" + kindName}.`);
  }
  const project = dir ?? slug(id);
  if (existsSync(project) && readdirSync(project).length && !force) throw new UsageError(`${project} already exists and is not empty. Pass --force to write into it.`);
  const vars = { id, name: name ?? titleFrom(id), author };
  const pkg = join(project, slug(id) + kind.ext);
  mkdirSync(pkg, { recursive: true });

  // Types and editor setup, for every kind: manifest completion helps themes and packs too.
  mkdirSync(join(project, "types"), { recursive: true });
  copyFileSync(join(sdkRoot, "manifest.schema.json"), join(project, "types/manifest.schema.json"));
  const schemas = [{ fileMatch: ["*.atelierplugin/manifest.json"], url: "./types/manifest.schema.json" }];

  if (kind.kind === "plugin") {
    const all = pluginTemplates();
    const chosen = all.find((t) => t.name === template);
    if (!chosen) throw new UsageError(`Unknown template "${template}". Use ${all.map((t) => t.name).join(", ")}.`);
    copyFileSync(join(sdkRoot, "atelier.d.ts"), join(project, "types/atelier.d.ts"));
    const manifest = { format: 1, id, name: vars.name, version: "1.0.0", author, description: chosen.description, icon: chosen.icon ?? "puzzlepiece.extension", entry: "main.js" };
    if (chosen.permissions?.length) manifest.permissions = chosen.permissions;
    if (chosen.hosts?.length) manifest.network = { hosts: chosen.hosts };
    write(join(pkg, "manifest.json"), manifest);
    write(join(pkg, "main.js"), "// @ts-check\n" + chosen.source);
    write(join(project, "jsconfig.json"), {
      compilerOptions: { checkJs: true, target: "es2022", lib: ["es2022"], module: "none", strict: false, noEmit: true },
      include: [`${slug(id)}${kind.ext}/**/*.js`, "types/atelier.d.ts"],
    });
    write(join(project, "test/fixtures.json"), chosen.fixtures ?? { http: {}, prompts: {} });
  } else if (kind.kind === "theme") {
    write(join(pkg, "atelier-theme.json"), fill(readFileSync(join(templates, "theme/atelier-theme.json"), "utf8"), vars));
    const themeSchema = join(cliRoot, "vendor/atelier-mods/schema/atelier-theme.schema.json");
    copyFileSync(themeSchema, join(project, "types/atelier-theme.schema.json"));
    schemas.push({ fileMatch: ["*.ateliertheme/atelier-theme.json"], url: "./types/atelier-theme.schema.json" });
  } else {
    const file = join(templates, "data", kind.kind + ".json");
    const { files } = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : { files: { "manifest.json": { format: 1, kind: kind.kind, id: "{{id}}", name: "{{name}}", version: "1.0.0", author: "{{author}}" } } };
    for (const [path, content] of Object.entries(files)) {
      write(join(pkg, path), fill(typeof content === "string" ? content : JSON.stringify(content, null, 2) + "\n", vars));
    }
  }
  write(join(project, ".vscode/settings.json"), { "json.schemas": schemas, "js/ts.implicitProjectConfig.checkJs": true });
  return { project, pkg };
}
