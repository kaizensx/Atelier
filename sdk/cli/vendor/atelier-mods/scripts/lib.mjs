// Shared rules for the Atelier Mods catalog. No dependencies: everything here runs on a stock
// Node 20+, so the workflow that holds the signing key installs nothing from npm.
//
// The limits mirror Sources/DockCore/ModCatalog.swift in the Atelier app. Change both together.

import { createHash } from "node:crypto";
import { readFileSync, readdirSync, lstatSync, existsSync } from "node:fs";
import { join, extname, relative, sep } from "node:path";
import { deflateRawSync, crc32 as zlibCrc32 } from "node:zlib";

export const KINDS = {
  plugin: { ext: ".atelierplugin", maxZip: 2 * 1024 * 1024, folder: "mods" },
  theme: { ext: ".ateliertheme", maxZip: 40 * 1024 * 1024, folder: "mods" },
  native: { ext: ".ateliermod", maxZip: 20 * 1024 * 1024, folder: "native" },
};

export const LIMITS = {
  modJSON: 64 * 1024,
  name: 60,
  summary: 400,
  description: 20000,
  screenshots: 6,
  screenshotBytes: 1_500_000,
  screenshotMinWidth: 640,
  pluginScript: 512 * 1024,
};

export const PERMISSIONS = ["network", "notifications", "openURL", "appearance"];

// Files a package may hold, by kind. Anything else is refused: no executables, no archives.
export const ALLOWED = {
  plugin: [".js", ".json", ".md", ".txt", ".png", ".jpg", ".jpeg"],
  theme: [".json", ".md", ".txt", ".png", ".jpg", ".jpeg", ".heic", ".tiff", ".aiff", ".aif", ".wav", ".caf", ".m4a", ".mp3"],
  native: [".json", ".md", ".txt", ".png", ".jpg", ".jpeg", ".dylib"],
};

export const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

export function isReverseDNS(id) {
  if (typeof id !== "string" || id.length < 3 || id.length > 120) return false;
  const parts = id.split(".");
  return parts.length >= 2 && parts.every((p) => /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(p) && !p.endsWith("-"));
}

export function parseVersion(text) {
  const m = /^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+.*)?$/.exec(String(text ?? "").trim());
  if (!m) return null;
  const pre = m[4] ? m[4].split(".") : [];
  if (pre.some((p) => p === "")) return null;
  return { major: +m[1], minor: +(m[2] ?? 0), patch: +(m[3] ?? 0), pre };
}

/** Semver order: negative when a < b. Same rules as AppVersion in the app. */
export function compareVersions(a, b) {
  const x = parseVersion(a), y = parseVersion(b);
  if (!x || !y) throw new Error(`not a version: ${!x ? a : b}`);
  for (const k of ["major", "minor", "patch"]) if (x[k] !== y[k]) return x[k] - y[k];
  if (!x.pre.length && !y.pre.length) return 0;
  if (!x.pre.length) return 1;
  if (!y.pre.length) return -1;
  for (let i = 0; i < Math.min(x.pre.length, y.pre.length); i++) {
    const p = x.pre[i], q = y.pre[i];
    if (p === q) continue;
    const np = /^\d+$/.test(p), nq = /^\d+$/.test(q);
    if (np && nq) return +p - +q;
    if (np) return -1;
    if (nq) return 1;
    return p < q ? -1 : 1;
  }
  return x.pre.length - y.pre.length;
}

/** Every regular file under `dir`, as sorted relative paths. Links and hidden files are reported. */
export function walk(dir) {
  const files = [], problems = [];
  const visit = (d) => {
    for (const name of readdirSync(d).sort()) {
      const full = join(d, name), rel = relative(dir, full).split(sep).join("/");
      const st = lstatSync(full);
      if (name.startsWith(".")) { problems.push(`${rel}: hidden files are not allowed.`); continue; }
      if (st.isSymbolicLink()) { problems.push(`${rel}: symbolic links are not allowed.`); continue; }
      if (st.isDirectory()) visit(full);
      else if (st.isFile()) files.push({ path: rel, full, size: st.size });
      else problems.push(`${rel}: not a regular file.`);
    }
  };
  visit(dir);
  return { files, problems };
}

/** A hash of a package's contents (paths and bytes), independent of how it is zipped. */
export function contentHash(dir) {
  const h = createHash("sha256");
  for (const f of walk(dir).files) {
    h.update(f.path + "\0" + sha256(readFileSync(f.full)) + "\n");
  }
  return h.digest("hex");
}

const MAGIC = [
  ["Mach-O", [0xfe, 0xed, 0xfa, 0xce]], ["Mach-O", [0xfe, 0xed, 0xfa, 0xcf]],
  ["Mach-O", [0xce, 0xfa, 0xed, 0xfe]], ["Mach-O", [0xcf, 0xfa, 0xed, 0xfe]],
  ["Mach-O universal", [0xca, 0xfe, 0xba, 0xbe]], ["Mach-O universal", [0xbe, 0xba, 0xfe, 0xca]],
  ["ELF", [0x7f, 0x45, 0x4c, 0x46]], ["Windows executable", [0x4d, 0x5a]],
  ["WebAssembly", [0x00, 0x61, 0x73, 0x6d]], ["zip archive", [0x50, 0x4b, 0x03, 0x04]],
  ["script with a #! line", [0x23, 0x21]],
];

/** What kind of binary a file is, by its first bytes, or null for none. */
export function binaryKind(buf) {
  for (const [name, bytes] of MAGIC) {
    if (buf.length >= bytes.length && bytes.every((b, i) => buf[i] === b)) return name;
  }
  return null;
}

export function isMachO(buf) {
  const k = binaryKind(buf);
  return k === "Mach-O" || k === "Mach-O universal";
}

/** Width and height of a PNG or JPEG, or null. */
export function imageSize(buf) {
  if (buf.length > 24 && buf.readUInt32BE(0) === 0x89504e47) {
    return { type: "png", width: buf.readUInt32BE(16), height: buf.readUInt32BE(20) };
  }
  if (buf.length > 4 && buf[0] === 0xff && buf[1] === 0xd8) {
    let i = 2;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) { i++; continue; }
      const marker = buf[i + 1], len = buf.readUInt16BE(i + 2);
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) {
        return { type: "jpeg", width: buf.readUInt16BE(i + 7), height: buf.readUInt16BE(i + 5) };
      }
      i += 2 + len;
    }
  }
  return null;
}

// --- The permission scan (same patterns as ModScan in the app) -----------------------------

export function stripComments(src) {
  let out = "", i = 0, quote = null;
  while (i < src.length) {
    const c = src[i], n = src[i + 1];
    if (quote) {
      out += c;
      if (c === "\\" && n !== undefined) { out += n; i += 2; continue; }
      if (c === quote) quote = null;
      i++; continue;
    }
    if (c === '"' || c === "'" || c === "`") { quote = c; out += c; i++; continue; }
    if (c === "/" && n === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && n === "*") {
      i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) i++;
      i += 2; out += " "; continue;
    }
    out += c; i++;
  }
  return out;
}

const SCAN = [
  ["network", /\batelier\s*\.\s*http\b/],
  ["notifications", /\batelier\s*\.\s*notify\b/],
  ["openURL", /\batelier\s*\.\s*openURL\b/],
  ["appearance", /\batelier\s*\.\s*theme\b/],
];

export function scanPermissions(src) {
  const code = stripComments(src);
  const used = new Set(SCAN.filter(([, re]) => re.test(code)).map(([p]) => p));
  const dynamicAccess = /\batelier\s*\[/.test(code) || /(=|\(|,|:)\s*atelier\s*(;|\)|,|$)/m.test(code);
  return { used, dynamicAccess };
}

// --- A minimal JSON Schema checker: the keywords the Atelier schemas use --------------------

export function checkSchema(schema, value, path = "", root = schema, out = []) {
  if (schema.$ref) {
    const target = schema.$ref.replace(/^#\//, "").split("/").reduce((o, k) => o?.[k], root);
    return checkSchema(target ?? {}, value, path, root, out);
  }
  const where = path || "(root)";
  const type = Array.isArray(value) ? "array" : value === null ? "null" : Number.isInteger(value) ? "integer" : typeof value;
  if (schema.anyOf) {
    const ok = schema.anyOf.some((s) => checkSchema(s, value, path, root, []).length === 0);
    if (!ok) out.push(`${where}: does not match any allowed form.`);
    return out;
  }
  if (schema.type) {
    const allowed = Array.isArray(schema.type) ? schema.type : [schema.type];
    const fits = allowed.some((t) => t === type || (t === "number" && type === "integer"));
    if (!fits) { out.push(`${where}: expected ${allowed.join(" or ")}, got ${type}.`); return out; }
  }
  if (schema.enum && !schema.enum.some((e) => JSON.stringify(e) === JSON.stringify(value))) {
    out.push(`${where}: ${JSON.stringify(value)} is not one of ${schema.enum.join(", ")}.`);
  }
  if (typeof value === "number") {
    if (schema.minimum !== undefined && value < schema.minimum) out.push(`${where}: ${value} is below ${schema.minimum}.`);
    if (schema.maximum !== undefined && value > schema.maximum) out.push(`${where}: ${value} is above ${schema.maximum}.`);
  }
  if (typeof value === "string") {
    if (schema.maxLength !== undefined && value.length > schema.maxLength) out.push(`${where}: longer than ${schema.maxLength} characters.`);
    if (schema.minLength !== undefined && value.length < schema.minLength) out.push(`${where}: shorter than ${schema.minLength} characters.`);
    if (schema.pattern && !new RegExp(schema.pattern).test(value)) out.push(`${where}: "${value}" does not have the expected form.`);
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) out.push(`${where}: needs at least ${schema.minItems} items.`);
    if (schema.maxItems !== undefined && value.length > schema.maxItems) out.push(`${where}: at most ${schema.maxItems} items.`);
    if (schema.items) value.forEach((v, i) => checkSchema(schema.items, v, `${path}[${i}]`, root, out));
  }
  if (type === "object") {
    for (const key of schema.required ?? []) if (!(key in value)) out.push(`${path ? path + "." : ""}${key}: required.`);
    for (const [key, v] of Object.entries(value)) {
      const sub = schema.properties?.[key];
      const child = path ? `${path}.${key}` : key;
      if (sub) { checkSchema(sub, v, child, root, out); continue; }
      const patterned = Object.entries(schema.patternProperties ?? {}).find(([re]) => new RegExp(re).test(key));
      if (patterned) { checkSchema(patterned[1], v, child, root, out); continue; }
      if (schema.additionalProperties === false) out.push(`${child}: unknown key.`);
    }
  }
  return out;
}

// --- A deterministic zip writer: same files in, same bytes out ------------------------------

const crc32 = zlibCrc32 ?? ((buf) => {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
});

/**
 * Zips `dir` with its folder name as the single top-level entry. Timestamps are fixed
 * (1 Jan 2020) and entries sorted, so a package always zips to the same bytes.
 */
export function zipFolder(dir, topName) {
  const { files, problems } = walk(dir);
  if (problems.length) throw new Error(problems.join("\n"));
  const local = [], central = [];
  let offset = 0;
  const DOS_TIME = 0, DOS_DATE = ((2020 - 1980) << 9) | (1 << 5) | 1;
  const entries = [{ name: topName + "/", data: null }, ...files.map((f) => ({ name: `${topName}/${f.path}`, data: readFileSync(f.full) }))];
  // Folder entries for every intermediate directory, so unzip tools recreate them in order.
  const dirs = new Set();
  for (const f of files) {
    const parts = f.path.split("/");
    for (let i = 1; i < parts.length; i++) dirs.add(`${topName}/${parts.slice(0, i).join("/")}/`);
  }
  const all = [...entries.slice(0, 1), ...[...dirs].sort().map((name) => ({ name, data: null })), ...entries.slice(1)];
  for (const e of all) {
    const name = Buffer.from(e.name, "utf8");
    const isDir = e.data === null;
    const raw = isDir ? Buffer.alloc(0) : e.data;
    const deflated = isDir ? Buffer.alloc(0) : deflateRawSync(raw, { level: 9 });
    const store = isDir || deflated.length >= raw.length;
    const body = store ? raw : deflated;
    const crc = isDir ? 0 : crc32(raw) >>> 0;
    const head = Buffer.alloc(30);
    head.writeUInt32LE(0x04034b50, 0); head.writeUInt16LE(20, 4); head.writeUInt16LE(0x0800, 6);
    head.writeUInt16LE(store ? 0 : 8, 8); head.writeUInt16LE(DOS_TIME, 10); head.writeUInt16LE(DOS_DATE, 12);
    head.writeUInt32LE(crc, 14); head.writeUInt32LE(body.length, 18); head.writeUInt32LE(raw.length, 22);
    head.writeUInt16LE(name.length, 26); head.writeUInt16LE(0, 28);
    local.push(head, name, body);
    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0); cd.writeUInt16LE(0x0314, 4); cd.writeUInt16LE(20, 6); cd.writeUInt16LE(0x0800, 8);
    cd.writeUInt16LE(store ? 0 : 8, 10); cd.writeUInt16LE(DOS_TIME, 12); cd.writeUInt16LE(DOS_DATE, 14);
    cd.writeUInt32LE(crc, 16); cd.writeUInt32LE(body.length, 20); cd.writeUInt32LE(raw.length, 24);
    cd.writeUInt16LE(name.length, 28); cd.writeUInt16LE(0, 30); cd.writeUInt16LE(0, 32); cd.writeUInt16LE(0, 34);
    cd.writeUInt16LE(0, 36); cd.writeUInt32LE(((isDir ? 0o40755 : 0o100644) << 16) >>> 0, 38); cd.writeUInt32LE(offset, 42);
    central.push(cd, name);
    offset += head.length + name.length + body.length;
  }
  const cdBuf = Buffer.concat(central);
  const end = Buffer.alloc(22);
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(all.length, 8); end.writeUInt16LE(all.length, 10);
  end.writeUInt32LE(cdBuf.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...local, cdBuf, end]);
}

// --- Finding mods -------------------------------------------------------------------------

/** Every mod folder in the catalog: mods/<id>/ and native/<id>/. */
export function listMods(root) {
  const out = [];
  for (const tier of ["mods", "native"]) {
    const dir = join(root, tier);
    if (!existsSync(dir)) continue;
    for (const name of readdirSync(dir).sort()) {
      const full = join(dir, name);
      if (name.startsWith(".") || !lstatSync(full).isDirectory()) continue;
      out.push({ tier, id: name, dir: full });
    }
  }
  return out;
}

/** The package folder inside a mod folder: the one entry with the kind's extension. */
export function findPackage(dir, kind) {
  const ext = KINDS[kind]?.ext;
  if (!ext) return null;
  const found = readdirSync(dir).filter((n) => extname(n) === ext && lstatSync(join(dir, n)).isDirectory());
  return found.length === 1 ? join(dir, found[0]) : found.length ? found : null;
}

export const readJSON = (path) => JSON.parse(readFileSync(path, "utf8"));
