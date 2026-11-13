#!/usr/bin/env node
// Builds the mod SDK from the one description of the API, docs/plugin-api.json:
//
//   sdk/atelier.d.ts              TypeScript types with JSDoc, for `// @ts-check` in main.js
//   sdk/manifest.schema.json      JSON Schema for a plugin's manifest.json
//   sdk/cli/runtime/plugin-api.json   a copy the CLI reads when installed from npm
//   sdk/cli/runtime/prelude.js    the app's real plugin prelude, lifted out of
//                                 Sources/DockCore/PluginPrelude.swift, so `atelier-mod test`
//                                 runs plugins through the same JavaScript Atelier does
//
//   node sdk/generate.mjs           write them
//   node sdk/generate.mjs --check   fail when any of them is out of date (preflight runs this)
//
// No dependencies; Node 20 or later.

import { readFileSync, writeFileSync, existsSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const sdk = dirname(fileURLToPath(import.meta.url));
const root = join(sdk, "..");
const check = process.argv.includes("--check");
const api = JSON.parse(readFileSync(join(root, "docs/plugin-api.json"), "utf8"));

// ---------------------------------------------------------------------------------------------
// JSDoc

const clean = (text) => String(text ?? "").replace(/\*\//g, "*\\/");
function jsdoc(indent, { description, params = [], returns, since, permission, example, defaultValue, deprecated } = {}) {
  const lines = [];
  if (description) lines.push(...clean(description).split("\n"));
  if (permission) lines.push(`Needs the \`${permission}\` permission in the manifest, granted by the owner.`);
  for (const p of params) {
    const name = p.name.replace(/^\.\.\./, "");
    lines.push(`@param ${p.optional ? `[${name}]` : name}${p.description ? " " + clean(p.description) : ""}`);
  }
  if (returns?.description) lines.push(`@returns ${clean(returns.description)}`);
  if (defaultValue !== undefined) lines.push(`@default ${defaultValue}`);
  if (since) lines.push(`@since Atelier ${since}`);
  if (deprecated) lines.push(`@deprecated ${clean(deprecated)}`);
  if (example) lines.push("@example", ...clean(example).split("\n"));
  if (!lines.length) return "";
  if (lines.length === 1) return `${indent}/** ${lines[0]} */\n`;
  return `${indent}/**\n${lines.map((l) => `${indent} *${l ? " " + l : ""}`).join("\n")}\n${indent} */\n`;
}

const paramList = (params = []) => params.map((p) =>
  p.name.startsWith("...") ? `${p.name}: ${p.type}` : `${p.name}${p.optional ? "?" : ""}: ${p.type}`).join(", ");

// ---------------------------------------------------------------------------------------------
// atelier.d.ts

function property(p, indent) {
  const doc = jsdoc(indent, { description: p.description, since: p.since, defaultValue: p.default });
  return `${doc}${indent}${p.readonly ? "readonly " : ""}${p.name}${p.optional ? "?" : ""}: ${p.type};\n`;
}

function viewInterfaceName(type) { return type[0].toUpperCase() + type.slice(1) + "View"; }

function typesBlock() {
  let out = "";
  for (const t of api.types) {
    const generic = t.generic ? `<${t.generic}>` : "";
    out += jsdoc("  ", { description: t.description, since: t.since });
    if (t.properties) {
      out += `  interface ${t.name}${generic} {\n`;
      for (const p of t.properties) out += property(p, "    ");
      out += "  }\n\n";
    } else {
      out += `  type ${t.name}${generic} = ${t.type};\n\n`;
    }
  }
  out += jsdoc("  ", { description: "A row in a list view." });
  out += "  interface ListRow {\n" + api.listRow.map((p) => property(p, "    ")).join("") + "  }\n\n";
  for (const v of api.views) {
    out += jsdoc("  ", { description: v.description, since: v.since, example: v.example });
    out += `  interface ${viewInterfaceName(v.type)} {\n    type: "${v.type}";\n`;
    for (const p of v.props) out += property(p, "    ");
    out += "  }\n\n";
  }
  out += jsdoc("  ", { description: "What a widget, panel or menu shows: a view object, a string or number (drawn as text), or an array (drawn as a vertical stack). Atelier draws it natively; a view never runs code." });
  out += `  type View = string | number | boolean | null | undefined | View[] |\n    ${api.views.map((v) => viewInterfaceName(v.type)).join(" | ")};\n\n`;
  out += jsdoc("  ", { description: "Every event atelier.on can listen for, with its payload." });
  out += "  interface EventMap {\n";
  for (const e of api.events) out += `${jsdoc("    ", { description: e.description, since: e.since })}    ${e.name}: ${e.payload};\n`;
  out += "  }\n\n";
  return out;
}

function uiBlock(indent) {
  let out = "";
  for (const v of api.views) {
    const name = viewInterfaceName(v.type);
    const omit = ["type", v.main, v.second].filter(Boolean).map((k) => `"${k}"`).join(" | ");
    const params = [];
    if (v.main) params.push({ name: v.main, type: v.mainType, description: v.props.find((p) => p.name === v.main)?.description });
    if (v.second) params.push({ name: v.second, type: v.secondType, description: v.props.find((p) => p.name === v.second)?.description });
    const hasStyle = v.props.some((p) => p.name !== v.main && p.name !== v.second);
    if (hasStyle) params.push({ name: "style", type: `Partial<Omit<${name}, ${omit}>>`, optional: true, description: "The view's other keys." });
    out += jsdoc(indent, { description: `Builds a ${v.type} view. ${v.description}`, params, since: v.since, example: v.example });
    out += `${indent}${v.helper}(${paramList(params)}): ${name};\n`;
  }
  return out;
}

/** The atelier object, built from the dotted names in api.api. */
function apiBlock() {
  const tree = { children: new Map(), entry: null };
  for (const entry of api.api) {
    const path = entry.name.split(".").slice(1);
    let node = tree;
    for (const part of path) {
      if (!node.children.has(part)) node.children.set(part, { children: new Map(), entry: null });
      node = node.children.get(part);
    }
    node.entry = entry;
  }
  const member = (name, node, indent) => {
    const e = node.entry ?? {};
    if (e.kind === "property") {
      return jsdoc(indent, { description: e.description, since: e.since }) + `${indent}readonly ${name}: ${e.type};\n`;
    }
    if (e.kind === "function") {
      const generic = e.generic ? `<${e.generic}>` : "";
      const sigs = e.overloads ?? [{ params: e.params ?? [] }];
      return sigs.map((sig) => jsdoc(indent, { description: e.description, params: sig.params, returns: e.returns, since: e.since, permission: e.permission, example: e.example })
        + `${indent}${name}${generic}(${paramList(sig.params)}): ${(sig.returns ?? e.returns)?.type ?? "void"};\n`).join("");
    }
    // A namespace: its members, plus ui's helpers from the views.
    let body = "";
    for (const [childName, child] of node.children) body += member(childName, child, indent + "  ");
    if (name === "ui") body += uiBlock(indent + "  ");
    return jsdoc(indent, { description: e.description, since: e.since, permission: e.permission }) + `${indent}readonly ${name}: {\n${body}${indent}};\n`;
  };
  let out = jsdoc("  ", { description: "The global, frozen atelier object: everything a plugin can do. There is no require, fetch, file system, process or DOM." });
  out += "  interface Api {\n";
  for (const [name, node] of tree.children) out += member(name, node, "    ");
  out += "  }\n";
  return out;
}

function globalsBlock() {
  let out = "";
  for (const g of api.globals) {
    out += jsdoc("", { description: g.description, params: g.params, returns: g.returns, since: g.since });
    out += `declare function ${g.name}(${paramList(g.params)}): ${g.returns.type};\n`;
  }
  // Same name and type as lib.dom's, so this file also works next to the DOM library.
  out += `\n${jsdoc("", { description: api.console.description })}interface Console {\n`;
  for (const level of api.console.levels) out += `  ${level}(...data: any[]): void;\n`;
  out += "}\ndeclare var console: Console;\n";
  return out;
}

function dts() {
  return `// Atelier plugin API ${api.apiVersion}, as of Atelier ${api.release}.
// Generated by sdk/generate.mjs from docs/plugin-api.json. Do not edit by hand.
//
// In a plugin's main.js:   // @ts-check
// with a jsconfig.json that includes this file (atelier-mod new writes one), or:
//   /// <reference path="./atelier.d.ts" />

declare namespace Atelier {
${typesBlock()}${apiBlock()}}

${jsdoc("", { description: "Everything a plugin can do. See " + api.docs })}declare const atelier: Atelier.Api;

${globalsBlock()}`;
}

// ---------------------------------------------------------------------------------------------
// manifest.schema.json

function manifestSchema() {
  const permissions = api.permissions.map((p) => p.name);
  const fill = (schema) => JSON.parse(JSON.stringify(schema), (key, value) => (value === "$permissions" ? permissions : value));
  const properties = { $schema: { type: "string" } };
  for (const field of api.manifest) {
    properties[field.key] = { ...fill(field.schema), description: field.description + (field.since ? ` (Atelier ${field.since})` : "") };
    if (field.default !== undefined) properties[field.key].default = field.default;
  }
  return {
    $schema: "https://json-schema.org/draft/2020-12/schema",
    $id: "urn:atelier:plugin-manifest:1",
    title: "Atelier plugin manifest",
    description: `manifest.json inside a .atelierplugin folder. Generated from docs/plugin-api.json (API ${api.apiVersion}).`,
    type: "object",
    required: api.manifest.filter((f) => f.required).map((f) => f.key),
    additionalProperties: false,
    patternProperties: { "^(\\$|x-)": {} },
    properties,
  };
}

// ---------------------------------------------------------------------------------------------
// The prelude, lifted from the app

function prelude() {
  const swift = join(root, "Sources/DockCore/PluginPrelude.swift");
  if (!existsSync(swift)) return null;
  const text = readFileSync(swift, "utf8");
  const version = /apiVersion\s*=\s*"([^"]+)"/.exec(text)?.[1];
  const start = text.indexOf('#"""'), end = text.lastIndexOf('"""#');
  if (start < 0 || end < 0 || !version) throw new Error("PluginPrelude.swift: could not find the prelude source.");
  // Swift raw string: drop the delimiter lines and the common indentation, fill \#(apiVersion).
  const lines = text.slice(start + 4, end).split("\n").slice(1, -1);
  const indent = Math.min(...lines.filter((l) => l.trim()).map((l) => l.length - l.trimStart().length));
  const body = lines.map((l) => l.slice(indent)).join("\n").replace(/\\#\(apiVersion\)/g, version);
  if (/\\#\(/.test(body)) throw new Error("PluginPrelude.swift: the prelude interpolates something generate.mjs does not know.");
  return `// Atelier's plugin prelude, API ${version}. Lifted from Sources/DockCore/PluginPrelude.swift by\n// sdk/generate.mjs. Do not edit by hand.\n${body}\n`;
}

// ---------------------------------------------------------------------------------------------

const outputs = [
  [join(sdk, "atelier.d.ts"), dts()],
  [join(sdk, "manifest.schema.json"), JSON.stringify(manifestSchema(), null, 2) + "\n"],
  [join(sdk, "cli/runtime/plugin-api.json"), JSON.stringify(api, null, 2) + "\n"],
];
const lifted = prelude();
if (lifted) outputs.push([join(sdk, "cli/runtime/prelude.js"), lifted]);

let stale = 0;
for (const [path, content] of outputs) {
  const current = existsSync(path) ? readFileSync(path, "utf8") : null;
  const rel = path.slice(root.length + 1);
  if (current === content) { if (!check) console.log(`unchanged ${rel}`); continue; }
  if (check) { console.log(`out of date: ${rel}. Run node sdk/generate.mjs.`); stale++; continue; }
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, content);
  console.log(`wrote ${rel}`);
}
if (check) {
  if (stale) process.exit(1);
  console.log("SDK is up to date with docs/plugin-api.json and the prelude.");
}
