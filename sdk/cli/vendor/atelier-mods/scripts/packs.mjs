// Data-only packs: icon packs, sound packs, shader packs, layout packs, effect packs and Looks.
// The same rules as Sources/DockCore/ModPacks.swift in the Atelier app (docs/PACKS.md there).
// Change both together. Nothing in a pack runs; every file is checked by its own bytes.

import { readFileSync } from "node:fs";
import { join } from "node:path";
import { checkSchema } from "./lib.mjs";

export const PACKS = {
  icons: { ext: ".ateliericons", manifest: "atelier-icons.json", maxZip: 60 * 1024 * 1024 },
  sounds: { ext: ".ateliersounds", manifest: "atelier-sounds.json", maxZip: 20 * 1024 * 1024 },
  shader: { ext: ".ateliershader", manifest: "atelier-shader.json", maxZip: 1024 * 1024 },
  layouts: { ext: ".atelierlayouts", manifest: "atelier-layouts.json", maxZip: 256 * 1024 },
  effects: { ext: ".ateliereffects", manifest: "atelier-effects.json", maxZip: 256 * 1024 },
  look: { ext: ".atelierlook", manifest: "atelier-look.json", maxZip: 80 * 1024 * 1024 },
};

export const PACK_LIMITS = {
  manifest: 256 * 1024, icons: 600, iconBytes: 1024 * 1024, iconPixels: 256, soundBytes: 1024 * 1024,
  uiSeconds: 2, typingSeconds: 1, typingVariants: 8, layouts: 24, zones: 12, zoneSide: 0.05,
  effects: 12, keyframes: 16, wallpaperBytes: 20 * 1024 * 1024, wallpaperPixels: 512,
};

export const SHADER_BASES = ["liquidLight", "nebula", "auroraSilk", "topography", "glassRain", "silkWaves", "gradientMesh",
  "starfield", "retroHorizon", "oceanCaustics", "northernLights", "lavaLamp", "inkInWater", "fireflies", "liquidChrome"];
export const SOUND_SLOTS = ["dock.launch", "dock.drop", "dock.trash", "dock.minimize", "timer.done", "theme.apply"];
export const TYPING_SLOTS = ["key", "space", "return", "backspace", "modifier"];
export const EFFECT_BASES = ["genie", "scale", "suck", "lamp", "fold", "dissolve", "portal", "shatter", "liquid"];
export const CURVES = ["linear", "easeIn", "easeOut", "easeInOut", "spring"];
const SPECIAL_ICONS = ["folder", "downloads", "trash", "trash.full"];

// --- Reading files by their bytes ---------------------------------------------------------

const ascii = (buf, a, b) => (buf.length >= b ? buf.subarray(a, b).toString("latin1") : "");

/** The real format of a file, from its first bytes. */
export function sniff(buf) {
  if (buf.length >= 4 && buf.readUInt32BE(0) === 0x89504e47) return "png";
  if (buf.length >= 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return "jpeg";
  if (ascii(buf, 0, 4) === "icns") return "icns";
  if (ascii(buf, 0, 4) === "caff") return "caf";
  if (ascii(buf, 0, 4) === "RIFF" && ascii(buf, 8, 12) === "WAVE") return "wav";
  if (ascii(buf, 4, 8) === "ftyp") {
    const brand = ascii(buf, 8, 12);
    if (["heic", "heix", "mif1", "msf1", "heim", "heis", "hevc", "hevx"].includes(brand)) return "heic";
    if (["M4A ", "M4B ", "mp42", "isom", "mp41"].includes(brand)) return "m4a";
  }
  const first = [...buf.subarray(0, 64)].find((b) => ![0x20, 0x09, 0x0a, 0x0d, 0xef, 0xbb, 0xbf].includes(b));
  if (first === 0x7b) return "json";
  return "other";
}

const EXTENSIONS = { png: [".png"], heic: [".heic", ".heif"], icns: [".icns"], jpeg: [".jpg", ".jpeg"], wav: [".wav"], caf: [".caf"], m4a: [".m4a"], json: [".json"] };

/** The shorter side of the largest picture in a PNG, JPEG, ICNS or HEIC. */
export function pixels(buf, format) {
  if (format === "png") return Math.min(buf.readUInt32BE(16), buf.readUInt32BE(20));
  if (format === "jpeg") {
    let i = 2;
    while (i + 9 < buf.length) {
      if (buf[i] !== 0xff) { i++; continue; }
      const marker = buf[i + 1], len = buf.readUInt16BE(i + 2);
      if (marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker)) return Math.min(buf.readUInt16BE(i + 5), buf.readUInt16BE(i + 7));
      i += 2 + len;
    }
    return null;
  }
  if (format === "icns") {
    // Each element: a 4-byte type and a 4-byte length. Sizes by type; PNG elements are read.
    const sizes = { ic07: 128, ic08: 256, ic09: 512, ic10: 1024, ic11: 32, ic12: 64, ic13: 256, ic14: 512, it32: 128, ih32: 48, il32: 32, is32: 16 };
    let best = 0, i = 8;
    while (i + 8 <= buf.length) {
      const type = ascii(buf, i, i + 4), len = buf.readUInt32BE(i + 4);
      if (len < 8) break;
      const body = buf.subarray(i + 8, i + len);
      const inner = body.length > 24 && body.readUInt32BE(0) === 0x89504e47 ? Math.min(body.readUInt32BE(16), body.readUInt32BE(20)) : sizes[type] ?? 0;
      best = Math.max(best, inner);
      i += len;
    }
    return best || null;
  }
  if (format === "heic") {
    // The largest 'ispe' (image spatial extents) property: version/flags, width, height.
    let best = 0, i = buf.indexOf("ispe", 0, "latin1");
    while (i >= 0 && i + 16 <= buf.length) {
      best = Math.max(best, Math.min(buf.readUInt32BE(i + 8), buf.readUInt32BE(i + 12)));
      i = buf.indexOf("ispe", i + 4, "latin1");
    }
    return best || null;
  }
  return null;
}

/** A sound's length in seconds, from its headers: WAV, CAF or M4A. */
export function seconds(buf, format) {
  if (format === "wav") {
    let i = 12, byteRate = 0;
    while (i + 8 <= buf.length) {
      const id = ascii(buf, i, i + 4), len = buf.readUInt32LE(i + 4);
      if (id === "fmt ") byteRate = buf.readUInt32LE(i + 16);
      if (id === "data") return byteRate ? len / byteRate : null;
      i += 8 + len + (len % 2);
    }
    return null;
  }
  if (format === "caf") {
    let i = 8, rate = 0, bytesPerPacket = 0, framesPerPacket = 0, frames = null;
    while (i + 12 <= buf.length) {
      const id = ascii(buf, i, i + 4), len = Number(buf.readBigInt64BE(i + 4));
      const body = i + 12;
      if (id === "desc") { rate = buf.readDoubleBE(body); bytesPerPacket = buf.readUInt32BE(body + 16); framesPerPacket = buf.readUInt32BE(body + 20); }
      if (id === "pakt") frames = Number(buf.readBigInt64BE(body + 8));
      if (id === "data") {
        const size = len === -1 ? buf.length - body - 4 : len - 4;
        if (frames === null && bytesPerPacket && framesPerPacket) frames = (size / bytesPerPacket) * framesPerPacket;
        break;
      }
      if (len < 0) break;
      i = body + len;
    }
    return rate && frames !== null ? frames / rate : null;
  }
  if (format === "m4a") {
    const i = buf.indexOf("mvhd", 0, "latin1");
    if (i < 0) return null;
    const version = buf[i + 4];
    if (version === 1) return Number(buf.readBigUInt64BE(i + 4 + 4 + 16 + 4)) / buf.readUInt32BE(i + 4 + 4 + 16);
    const timescale = buf.readUInt32BE(i + 4 + 4 + 8), duration = buf.readUInt32BE(i + 4 + 4 + 12);
    return timescale ? duration / timescale : null;
  }
  return null;
}

// --- The rules ----------------------------------------------------------------------------

const isReverseDNS = (id) => typeof id === "string" && id.length >= 3 && id.length <= 120 &&
  id.split(".").length >= 2 && id.split(".").every((p) => /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(p) && !p.endsWith("-"));
const isBundleID = (id) => typeof id === "string" && id.length >= 3 && id.length <= 155 &&
  id.split(".").length >= 2 && id.split(".").every((p) => /^[A-Za-z0-9_-]+$/.test(p));
const isSafePath = (p) => typeof p === "string" && p.length > 0 && p.length <= 200 && !p.startsWith("/") && !p.startsWith("~") &&
  !p.includes("\\") && !p.includes("\0") && p.split("/").every((x) => x && x !== "." && x !== ".." && !x.startsWith("."));
const num = (v) => typeof v === "number" && Number.isFinite(v);
const HEADER = ["format", "id", "name", "version", "author", "description"];

/**
 * Checks one pack folder. `files` are its regular files ({ path, full, size }) relative to it.
 * Returns { errors, header } where header is { id, name, version } when it could be read.
 */
export function validatePack(kind, dir, files, themeSchema) {
  const errors = [];
  const facts = new Map();
  for (const f of files) {
    const buf = readFileSync(f.full);
    const format = sniff(buf);
    const fact = { size: f.size, format };
    if (["png", "jpeg", "icns", "heic"].includes(format)) fact.pixels = pixels(buf, format);
    if (["wav", "caf", "m4a"].includes(format)) fact.seconds = seconds(buf, format);
    facts.set(f.path, fact);
  }
  const header = check(kind, "", facts, (p) => readFileSync(join(dir, p), "utf8"), errors, themeSchema);
  return { errors, header };
}

function check(kind, prefix, facts, read, errors, themeSchema) {
  const spec = PACKS[kind];
  const at = (p) => (prefix ? `${prefix}/${p}` : p);
  const err = (m) => errors.push(prefix ? `${prefix}: ${m}` : m);
  const fact = facts.get(at(spec.manifest));
  if (!fact) { err(`${spec.manifest} is missing.`); return null; }
  if (fact.size > PACK_LIMITS.manifest) { err(`${spec.manifest} is larger than 256 KB.`); return null; }
  let root;
  try { root = JSON.parse(read(at(spec.manifest))); } catch (e) { err(`${spec.manifest} is not valid JSON: ${e.message}`); return null; }
  if (!root || typeof root !== "object" || Array.isArray(root)) { err(`${spec.manifest} is not a JSON object.`); return null; }

  const allowed = { icons: ["icons"], sounds: ["sounds", "typing"], shader: ["base", "palette", "speed", "intensity", "grain", "scale", "dim", "cycle", "pointer"],
    layouts: ["layouts"], effects: ["effects"], look: ["theme", "wallpaper", "dock", "iconPack", "soundPack"] }[kind];
  for (const key of Object.keys(root)) if (!HEADER.includes(key) && !allowed.includes(key) && !key.startsWith("x-")) err(`${spec.manifest}: unknown key "${key}".`);
  if (root.format !== 1) err(`${spec.manifest} needs "format": 1.`);
  if (!isReverseDNS(root.id)) err(`${spec.manifest} needs a reverse-DNS "id".`);
  if (typeof root.version !== "string" || !/^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(root.version)) err(`${spec.manifest} needs a "version" like 1.0.0.`);
  if (typeof root.name !== "string" || !root.name.trim() || root.name.length > 60) err(`${spec.manifest} needs a "name" of 1 to 60 characters.`);
  if (root.description !== undefined && (typeof root.description !== "string" || root.description.length > 400)) err("description must be text of at most 400 characters.");

  const file = (path, label, formats) => {
    if (!isSafePath(path)) { err(`${label}: "${path}" is not a path inside the pack.`); return null; }
    const f = facts.get(at(path));
    if (!f) { err(`${label}: ${path} is not in the pack.`); return null; }
    const ext = path.slice(path.lastIndexOf(".")).toLowerCase();
    if (!(EXTENSIONS[f.format] ?? []).includes(ext)) { err(`${label}: ${path} is not really a ${ext} file.`); return null; }
    if (formats && !formats.includes(f.format)) { err(`${label}: ${path} must be ${formats.join(", ").toUpperCase()}.`); return null; }
    return f;
  };
  const range = (v, lo, hi, label) => {
    if (v === undefined) return;
    if (!num(v)) err(`${label} must be a number.`);
    else if (v < lo || v > hi) err(`${label} must be between ${lo} and ${hi}.`);
  };
  const sound = (path, label, limit) => {
    const f = file(path, label, ["wav", "caf", "m4a"]);
    if (!f) return;
    if (f.size > PACK_LIMITS.soundBytes) err(`${label}: ${path} is larger than 1 MB.`);
    else if (!(f.seconds > 0)) err(`${label}: ${path} could not be read as a sound.`);
    else if (f.seconds > limit + 0.01) err(`${label}: ${path} is ${f.seconds.toFixed(2)} s; the limit is ${limit} s.`);
  };

  if (kind === "icons") {
    const icons = root.icons;
    if (!icons || typeof icons !== "object" || Array.isArray(icons) || !Object.keys(icons).length) err("\"icons\" must map bundle identifiers to pictures.");
    else {
      if (Object.keys(icons).length > PACK_LIMITS.icons) err(`The pack has ${Object.keys(icons).length} icons; the limit is 600.`);
      for (const [key, path] of Object.entries(icons)) {
        if (!SPECIAL_ICONS.includes(key) && !isBundleID(key)) { err(`icons: "${key}" is not a bundle identifier or one of ${SPECIAL_ICONS.join(", ")}.`); continue; }
        const f = file(path, `icons.${key}`, ["png", "heic", "icns"]);
        if (!f) continue;
        if (f.size > PACK_LIMITS.iconBytes) err(`icons.${key}: ${path} is larger than 1 MB.`);
        if (!f.pixels) err(`icons.${key}: ${path} could not be read as a picture.`);
        else if (f.pixels < PACK_LIMITS.iconPixels) err(`icons.${key}: ${path} is ${f.pixels} px; icons need at least 256 px.`);
      }
    }
  }
  if (kind === "sounds") {
    let any = false;
    if (root.sounds !== undefined) {
      if (!root.sounds || typeof root.sounds !== "object" || Array.isArray(root.sounds)) err("\"sounds\" must be an object.");
      else for (const [slot, path] of Object.entries(root.sounds)) {
        any = true;
        if (!SOUND_SLOTS.includes(slot)) err(`sounds: "${slot}" is not a sound Atelier plays. Use ${SOUND_SLOTS.join(", ")}.`);
        else sound(path, `sounds.${slot}`, PACK_LIMITS.uiSeconds);
      }
    }
    if (root.typing !== undefined) {
      if (!root.typing || typeof root.typing !== "object" || Array.isArray(root.typing)) err("\"typing\" must be an object.");
      else {
        for (const [slot, list] of Object.entries(root.typing)) {
          any = true;
          if (!TYPING_SLOTS.includes(slot)) { err(`typing: "${slot}" is not a key class. Use ${TYPING_SLOTS.join(", ")}.`); continue; }
          if (!Array.isArray(list) || list.length < 1 || list.length > PACK_LIMITS.typingVariants) { err(`typing.${slot} must list 1 to 8 sounds.`); continue; }
          list.forEach((path, i) => sound(path, `typing.${slot}[${i}]`, PACK_LIMITS.typingSeconds));
        }
        if (!("key" in root.typing)) err("typing needs at least \"key\"; the other classes fall back to it.");
      }
    }
    if (!any) err("The pack has no sounds.");
  }
  if (kind === "shader") {
    if (!SHADER_BASES.includes(root.base)) err(`"base" must be one of ${SHADER_BASES.join(", ")}.`);
    if (root.palette !== undefined && !(Array.isArray(root.palette) && root.palette.length === 4 && root.palette.every((c) => /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(c)))) {
      err("\"palette\" must be four colours like \"#1B2A55\", darkest first.");
    }
    range(root.speed, 0.2, 2.5, "speed"); range(root.intensity, 0, 1, "intensity"); range(root.grain, 0, 1, "grain");
    range(root.scale, 0.6, 1.8, "scale"); range(root.dim, 0, 0.7, "dim");
    if (root.cycle !== undefined && !["clock", "day", "dusk", "night"].includes(root.cycle)) err("\"cycle\" must be one of clock, day, dusk, night.");
    if (root.pointer !== undefined && typeof root.pointer !== "boolean") err("\"pointer\" must be true or false.");
  }
  if (kind === "layouts") {
    const list = root.layouts;
    if (!Array.isArray(list) || !list.length) err("\"layouts\" must list at least one layout.");
    else {
      if (list.length > PACK_LIMITS.layouts) err(`The pack has ${list.length} layouts; the limit is 24.`);
      list.slice(0, PACK_LIMITS.layouts).forEach((l, i) => {
        if (!l || typeof l !== "object") return err(`layouts[${i}] must be an object.`);
        for (const key of Object.keys(l)) if (!["name", "zones"].includes(key)) err(`layouts[${i}]: unknown key "${key}".`);
        if (typeof l.name !== "string" || !l.name.trim() || l.name.length > 40) err(`layouts[${i}] needs a name of 1 to 40 characters.`);
        if (!Array.isArray(l.zones) || l.zones.length < 1 || l.zones.length > PACK_LIMITS.zones) return err(`layouts[${i}] needs 1 to 12 zones.`);
        const seen = new Set();
        l.zones.forEach((z, j) => {
          const label = `layouts[${i}].zones[${j}]`;
          if (!z || Object.keys(z).sort().join() !== "height,width,x,y" || ![z.x, z.y, z.width, z.height].every(num)) return err(`${label} must be {"x", "y", "width", "height"}.`);
          if (z.x < 0 || z.y < 0 || z.x > 1 || z.y > 1) return err(`${label} starts outside 0…1.`);
          if (z.width < PACK_LIMITS.zoneSide || z.height < PACK_LIMITS.zoneSide) return err(`${label} is narrower or shorter than 0.05.`);
          if (z.x + z.width > 1.0001 || z.y + z.height > 1.0001) return err(`${label} reaches past the edge of the screen.`);
          const key = `${z.x},${z.y},${z.width},${z.height}`;
          if (seen.has(key)) err(`${label} repeats another zone.`);
          seen.add(key);
        });
      });
    }
  }
  if (kind === "effects") {
    const list = root.effects;
    if (!Array.isArray(list) || !list.length) err("\"effects\" must list at least one effect.");
    else {
      if (list.length > PACK_LIMITS.effects) err(`The pack has ${list.length} effects; the limit is 12.`);
      const ids = new Set();
      list.slice(0, PACK_LIMITS.effects).forEach((e, i) => {
        const label = `effects[${i}]`;
        if (!e || typeof e !== "object") return err(`${label} must be an object.`);
        for (const key of Object.keys(e)) if (!["id", "name", "base", "duration", "curve", "opacity", "scale", "blur", "shade", "twist", "wave"].includes(key)) err(`${label}: unknown key "${key}".`);
        if (typeof e.id !== "string" || !/^[A-Za-z0-9-]{1,40}$/.test(e.id)) err(`${label} needs an "id" of letters, digits and hyphens.`);
        else if (ids.has(e.id)) err(`${label}: the id "${e.id}" is used twice.`);
        else ids.add(e.id);
        if (typeof e.name !== "string" || !e.name.trim() || e.name.length > 40) err(`${label} needs a name of 1 to 40 characters.`);
        if (!EFFECT_BASES.includes(e.base)) err(`${label}.base must be one of ${EFFECT_BASES.join(", ")}.`);
        if (e.duration === undefined) err(`${label}.duration is required, in seconds (0.15 to 1.2).`);
        else range(e.duration, 0.15, 1.2, `${label}.duration`);
        if (e.curve !== undefined && !CURVES.includes(e.curve)) err(`${label}.curve must be one of ${CURVES.join(", ")}.`);
        for (const [track, lo, hi, rest] of [["opacity", 0, 1, 1], ["scale", 0.05, 3, 1], ["blur", 0, 8, 0], ["shade", 0, 2, 1]]) {
          const frames = e[track];
          if (frames === undefined) continue;
          const t = `${label}.${track}`;
          if (!Array.isArray(frames) || frames.length < 2 || frames.length > PACK_LIMITS.keyframes) { err(`${t} must list 2 to 16 [t, value] pairs.`); continue; }
          let last = -1, bad = false;
          for (const [k, pair] of frames.entries()) {
            if (!Array.isArray(pair) || pair.length !== 2 || !pair.every(num)) { err(`${t}[${k}] must be [t, value].`); bad = true; break; }
            if (pair[0] < 0 || pair[0] > 1) { err(`${t}[${k}]: t must be between 0 and 1.`); bad = true; break; }
            if (pair[1] < lo || pair[1] > hi) { err(`${t}[${k}]: the value must be between ${lo} and ${hi}.`); bad = true; break; }
            if (pair[0] <= last) { err(`${t}: t must increase from one point to the next.`); bad = true; break; }
            last = pair[0];
          }
          if (bad) continue;
          if (frames[0][0] !== 0 || frames.at(-1)[0] !== 1) err(`${t} must start at t 0 and end at t 1.`);
          else if (frames[0][1] !== rest) err(`${t} must start at ${rest}, so the first frame is the window itself.`);
        }
        range(e.twist, -720, 720, `${label}.twist`);
        if (e.wave !== undefined) {
          if (!e.wave || typeof e.wave !== "object" || Object.keys(e.wave).some((k) => !["amplitude", "frequency"].includes(k))) err(`${label}.wave must be {"amplitude", "frequency"}.`);
          else { range(e.wave.amplitude, 0, 0.2, `${label}.wave.amplitude`); range(e.wave.frequency, 0, 8, `${label}.wave.frequency`); }
        }
      });
    }
  }
  if (kind === "look") {
    const theme = root.theme;
    if (typeof theme !== "string" || !theme.toLowerCase().endsWith(".ateliertheme") || theme.includes("/") || !isSafePath(theme)) {
      err("\"theme\" must name the .ateliertheme folder at the top of the Look.");
    } else if (!facts.has(at(`${theme}/atelier-theme.json`))) {
      err(`${theme} has no atelier-theme.json.`);
    } else if (themeSchema) {
      try {
        for (const problem of checkSchema(themeSchema, JSON.parse(read(at(`${theme}/atelier-theme.json`))))) err(`${theme}/atelier-theme.json ${problem}`);
      } catch (e) { err(`${theme}/atelier-theme.json is not valid JSON: ${e.message}`); }
    }
    const ref = (value, sub, label) => {
      if (value === undefined) return;
      if (typeof value !== "string") return err(`${label} must be a pack id or a ${PACKS[sub].ext} folder in the Look.`);
      if (value.toLowerCase().endsWith(PACKS[sub].ext)) {
        if (value.includes("/") || !isSafePath(value)) return err(`${label}: "${value}" must sit at the top of the Look.`);
        if (![...facts.keys()].some((p) => p.startsWith(at(value) + "/"))) return err(`${label}: ${value} is not in the Look.`);
        check(sub, at(value), facts, read, errors, themeSchema);
      } else if (!isReverseDNS(value)) {
        err(`${label}: "${value}" is neither a pack id nor a ${PACKS[sub].ext} folder.`);
      }
    };
    if (root.wallpaper !== undefined) {
      const w = root.wallpaper, keys = w && typeof w === "object" ? Object.keys(w) : [];
      if (keys.length !== 1 || !["image", "shader"].includes(keys[0])) err("\"wallpaper\" must be {\"image\": path} or {\"shader\": pack}.");
      else if (keys[0] === "image") {
        const f = file(w.image, "wallpaper.image", ["png", "heic", "jpeg"]);
        if (f && f.size > PACK_LIMITS.wallpaperBytes) err("wallpaper.image is larger than 20 MB.");
        if (f && (f.pixels ?? 0) < PACK_LIMITS.wallpaperPixels) err("wallpaper.image is too small to fill a screen.");
      } else ref(w.shader, "shader", "wallpaper.shader");
    }
    if (root.dock !== undefined) {
      const d = root.dock;
      if (!d || typeof d !== "object" || Array.isArray(d)) err("\"dock\" must be an object.");
      else {
        for (const key of Object.keys(d)) if (!["edge", "tileSize", "magnifiedSize", "magnification", "autohide"].includes(key)) err(`dock: unknown key "${key}".`);
        if (d.edge !== undefined && !["bottom", "left", "right", "top"].includes(d.edge)) err("dock.edge must be bottom, left, right or top.");
        range(d.tileSize, 24, 128, "dock.tileSize"); range(d.magnifiedSize, 32, 256, "dock.magnifiedSize");
        for (const key of ["magnification", "autohide"]) if (d[key] !== undefined && typeof d[key] !== "boolean") err(`dock.${key} must be true or false.`);
        if (num(d.tileSize) && num(d.magnifiedSize) && d.magnifiedSize < d.tileSize) err("dock.magnifiedSize must not be smaller than dock.tileSize.");
      }
    }
    ref(root.iconPack, "icons", "iconPack");
    ref(root.soundPack, "sounds", "soundPack");
  }
  return { id: root.id, name: root.name, version: root.version };
}

export const isPackKind = (kind) => Object.hasOwn(PACKS, kind);
