// Runs a plugin in Node the way Atelier runs it, without Atelier.
//
// The script runs in its own V8 context with nothing but JavaScript's built-ins (no require,
// fetch, process or file system), behind Atelier's real prelude (lifted from
// Sources/DockCore/PluginPrelude.swift into ../runtime/prelude.js by sdk/generate.mjs). The
// native side is a fake that checks every call like the app does (permissions, hosts, ids,
// view limits, from plugin-api.json) and records it instead of drawing anything. Time is
// virtual: timers fire when you call advance().
//
//   import { loadPlugin } from "atelier-mod/harness";
//   const p = await loadPlugin("hello.atelierplugin");
//   await p.runCommand("say-hello");
//   const { view } = await p.render("hello");

import vm from "node:vm";
import { readFileSync, existsSync, lstatSync } from "node:fs";
import { join } from "node:path";
import { loadAPI, limit, cliRoot } from "./api.mjs";
import { parseView, isSymbolName, isColor, ViewError } from "./views.mjs";

const prelude = () => readFileSync(join(cliRoot, "runtime/prelude.js"), "utf8");

export class PluginError extends Error {}

const ID = /^[A-Za-z0-9._-]{1,64}$/;
const MODS = ["cmd", "ctrl", "opt", "shift"];
const ALIASES = { command: "cmd", "⌘": "cmd", control: "ctrl", "⌃": "ctrl", option: "opt", alt: "opt", "⌥": "opt", "⇧": "shift" };
export function normaliseShortcut(text) {
  const parts = String(text).toLowerCase().split("+").map((s) => s.trim());
  const key = parts.at(-1);
  const keyOK = parts.length >= 2 && (key.length === 1 || ["space", "return", "tab", "escape"].includes(key) || (/^f\d+$/.test(key) && +key.slice(1) >= 1 && +key.slice(1) <= 20));
  if (!keyOK) return null;
  const mods = new Set(parts.slice(0, -1).map((m) => ALIASES[m] ?? m));
  if (![...mods].every((m) => MODS.includes(m)) || !["cmd", "ctrl", "opt"].some((m) => mods.has(m))) return null;
  return [...MODS.filter((m) => mods.has(m)), key].join("+");
}

const canOpen = (url) => {
  try {
    const u = new URL(url);
    if (u.protocol === "https:" || u.protocol === "mailto:") return url.length < 2048;
    return u.protocol === "atelier:" && u.host === "studio";
  } catch { return false; }
};

/**
 * Loads and starts a plugin. `folder` is a .atelierplugin folder.
 * options: grant (array of permissions; default: everything the manifest asks for),
 *          fixtures ({ http: { "GET https://…": { status, body | json, headers } }, prompts: { title: answer } }),
 *          network (true: real https requests to the manifest's hosts), storage (initial values),
 *          settings (values for manifest settings), now (ms since 1970 for the virtual clock),
 *          source (script text instead of the entry file).
 */
export async function loadPlugin(folder, options = {}) {
  const manifestPath = join(folder, "manifest.json");
  if (!existsSync(manifestPath)) throw new PluginError(`There is no manifest.json in ${folder}.`);
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const entry = manifest.entry ?? "main.js";
  const source = options.source ?? readFileSync(join(folder, entry), "utf8");
  const plugin = new Plugin(manifest, source, entry, { folder, ...options });
  await plugin.start();
  return plugin;
}

export class Plugin {
  constructor(manifest, source, entry, options) {
    const api = loadAPI();
    this.api = api;
    this.manifest = manifest;
    this.source = source;
    this.entry = entry;
    this.options = options;
    const asked = new Set(manifest.permissions ?? []);
    this.granted = new Set((options.grant ?? [...asked]).filter((p) => asked.has(p)));
    this.hosts = (manifest.network?.hosts ?? []).map((h) => h.toLowerCase());
    this.now = options.now ?? Date.UTC(2026, 0, 1, 9, 0, 0);
    this.widgets = new Map(); this.tiles = new Map(); this.commands = new Map(); this.corners = new Map();
    this.hooks = { palettes: new Map(), menuBars: new Map(), tiles: new Map(), stacks: new Map(), activities: new Map(), panels: new Map() };
    this.asks = new Map();    // hooks.reply answers awaited by request number
    this.values = new Map(Object.entries(options.settings ?? {}));  // settings the owner changed
    this.folder = options.folder;
    this.events = new Map();  // event -> interval or null
    this.logs = [];           // { level, text }
    this.effects = [];        // notifications, opened links, theme changes, prompts, requests
    this.problems = [];       // errors the app would show: thrown exceptions, refused calls
    this.registered = new Set();
    this.storage = { ...(options.storage ?? {}) };
    this.timers = new Map();  // id -> { due, every, kind, target }
    this.jobs = [];
    this.pending = new Set();
    this.timeouts = 0;
    this.stopped = false;
  }

  // --- Lifecycle ------------------------------------------------------------------------

  async start() {
    const sandbox = Object.create(null);
    this.context = vm.createContext(sandbox, { name: this.manifest.name ?? "plugin", codeGeneration: { strings: true, wasm: false }, microtaskMode: "afterEvaluate" });
    const native = (kind, payload) => this.native(kind, payload);
    Object.defineProperty(sandbox, "__atelierNative", { value: native, configurable: true, writable: true });
    this.evaluate(prelude(), "atelier://prelude.js");
    this.evaluate(this.source, this.entry);
    await this.idle();
  }

  stop() { this.stopped = true; this.timers.clear(); this.jobs = []; }

  /** Runs code in the plugin's context with Atelier's 1 s limit, like one call into JavaScriptCore. */
  evaluate(code, filename = "harness.js") {
    if (this.stopped) return;
    try {
      vm.runInContext(code, this.context, { filename, timeout: limit("callSeconds") * 1000, displayErrors: false });
      this.timeouts = 0;
    } catch (error) {
      const timedOut = /Script execution timed out/.test(String(error?.message));
      if (timedOut) {
        this.timeouts += 1;
        this.problem(`A call ran longer than ${limit("callSeconds")} s and was stopped.`);
        if (this.timeouts >= 3) { this.problem("Stopped after running too long three times in a row."); this.stop(); }
        return;
      }
      const where = /(?:^|\()([^()\s]+):(\d+):\d+\)?/m.exec(String(error?.stack ?? ""));
      const line = where && where[1] === this.entry ? ` (line ${where[2]})` : "";
      this.problem(`${error?.name && error.name !== "Error" ? error.name + ": " : ""}${error?.message ?? String(error)}${line}`);
    }
  }

  /** Calls __atelier.<method>(...args) inside the context. */
  enter(method, ...args) {
    this.context.__harnessArgs = args;
    this.evaluate(`__atelier.${method}(...globalThis.__harnessArgs)`);
    delete this.context.__harnessArgs;
  }

  /** Runs queued work (renders after registration, settled requests) until nothing is left. */
  drain() {
    for (let guard = 0; this.jobs.length && guard < 10000; guard++) this.jobs.shift()();
  }

  /** Waits for every pending request, then drains. */
  async idle() {
    this.drain();
    while (this.pending.size) {
      await Promise.allSettled([...this.pending]);
      this.drain();
    }
  }

  problem(text) { this.problems.push(text); this.logs.push({ level: "error", text }); }

  // --- The fake native side --------------------------------------------------------------

  native(kind, payloadJSON) {
    if (payloadJSON.length > limit("messageBytes")) return this.refuse(`A message from the plugin was larger than ${limit("messageBytes") / 1024} KB.`);
    let p;
    try { p = JSON.parse(payloadJSON); } catch { return this.refuse("A message from the plugin was not valid JSON."); }
    try {
      const reply = this.handle(kind, p ?? {});
      return reply === undefined ? "null" : JSON.stringify(reply);
    } catch (error) {
      if (error instanceof PluginError || error instanceof ViewError) return this.refuse(error.message);
      throw error;
    }
  }

  refuse(text) { return JSON.stringify({ __error: text }); }

  need(permission) {
    if (!(this.manifest.permissions ?? []).includes(permission) || !this.granted.has(permission)) {
      throw new PluginError(`This needs the "${permission}" permission, which is not granted.`);
    }
  }

  id(kind, p) {
    if (typeof p.id !== "string" || !ID.test(p.id)) throw new PluginError(`${kind}: an id of letters, digits, - _ or . is required, up to 64 characters.`);
    return p.id;
  }

  register(key) {
    if (this.registered.has(key)) return;
    if (this.registered.size >= limit("registrations")) {
      throw new PluginError(`A plugin may register at most ${limit("registrations")} widgets, tiles, commands and corner actions.`);
    }
    this.registered.add(key);
  }

  handle(kind, p) {
    const api = this.api;
    switch (kind) {
      case "log": {
        const level = api.console.levels.includes(p.level) ? p.level : "log";
        this.logs.push({ level, text: String(p.message ?? "").slice(0, 2000) });
        return null;
      }
      case "storage.get": return this.storage[String(p.key)] ?? null;
      case "storage.keys": return Object.keys(this.storage).sort();
      case "storage.set": {
        const key = String(p.key ?? "");
        if (key.startsWith("settings.") && (this.manifest.settings ?? []).some((s) => "settings." + s.key === key)) {
          throw new PluginError(`storage: ${key} is a setting. Use atelier.settings.set.`);
        }
        if (key.length < 1 || key.length > limit("storageKeyLength")) throw new PluginError(`storage: keys are 1 to ${limit("storageKeyLength")} characters.`);
        const next = { ...this.storage };
        if (p.value === null || p.value === undefined) delete next[key]; else next[key] = p.value;
        if (Buffer.byteLength(JSON.stringify(next)) > limit("storageBytes")) throw new PluginError(`storage: a plugin may keep at most ${limit("storageBytes") / 1024} KB.`);
        this.storage = next;
        return null;
      }
      case "widget": {
        const id = this.id(kind, p);
        this.register("widget:" + id);
        const spec = { id, title: String(p.title ?? id).slice(0, 60), size: ["small", "medium", "large"].includes(p.size) ? p.size : "small",
          refresh: Math.min(Math.max(typeof p.refresh === "number" ? p.refresh : 60, 5), 86400) };
        const existing = this.widgets.get(id);
        this.widgets.set(id, { ...existing, spec });
        this.schedule(`widget:${id}`, spec.refresh * 1000, spec.refresh * 1000, () => this.enter("render", id));
        this.jobs.push(() => this.enter("render", id));
        return null;
      }
      case "widgetView": {
        const id = this.id(kind, p);
        const view = parseView(p.view ?? null);
        const w = this.widgets.get(id);
        if (w) { w.view = view; w.error = undefined; w.raw = p.view; }
        return null;
      }
      case "widgetError": {
        const id = this.id(kind, p);
        const message = String(p.message ?? "Unknown error").slice(0, 300);
        const w = this.widgets.get(id);
        if (w) w.error = message;
        this.problem(`${id}: ${message}`);
        return null;
      }
      case "tile": {
        const id = this.id(kind, p);
        this.register("tile:" + id);
        const symbol = p.symbol ?? p.icon;
        if (symbol !== undefined && symbol !== null && !isSymbolName(symbol)) throw new PluginError(`tile: "${symbol}" is not an SF Symbol name.`);
        const spec = { id, title: String(p.title ?? id).slice(0, 60) };
        if (symbol) spec.symbol = symbol;
        if (p.text !== undefined && p.text !== null) spec.text = String(p.text).slice(0, 12);
        if (p.badge !== undefined && p.badge !== null) spec.badge = String(p.badge).slice(0, 4);
        if (isColor(p.tint)) spec.tint = p.tint;
        if (typeof p.progress === "number") spec.progress = Math.min(Math.max(p.progress, 0), 1);
        this.tiles.set(id, spec);
        return null;
      }
      case "command": {
        const id = this.id(kind, p);
        this.register("command:" + id);
        if (typeof p.title !== "string" || !p.title) throw new PluginError("command: a title is required.");
        let shortcut;
        if (typeof p.shortcut === "string") {
          shortcut = normaliseShortcut(p.shortcut);
          if (!shortcut) throw new PluginError(`command: "${p.shortcut}" is not a shortcut. Use something like "cmd+shift+p".`);
        }
        this.commands.set(id, { id, title: p.title.slice(0, 60), ...(p.subtitle ? { subtitle: String(p.subtitle).slice(0, 40) } : {}), ...(shortcut ? { shortcut } : {}) });
        return null;
      }
      case "corner": {
        const id = this.id(kind, p);
        this.register("corner:" + id);
        if (typeof p.title !== "string" || !p.title) throw new PluginError("cornerAction: a title is required.");
        this.corners.set(id, { id, title: p.title.slice(0, 40), symbol: isSymbolName(p.symbol) ? p.symbol : "puzzlepiece.extension" });
        return null;
      }
      case "on": {
        const names = api.events.map((e) => e.name);
        if (!names.includes(p.event)) throw new PluginError(`on: unknown event. Use ${names.join(", ")}.`);
        if (p.event === "timer") {
          const interval = Math.min(Math.max(typeof p.interval === "number" ? p.interval : 60, 5), 86400);
          const count = [...this.timers.values()].filter((t) => t.kind === "event").length;
          if (count < limit("timerEvents")) this.schedule(`event:${count}`, interval * 1000, interval * 1000, () => this.enter("emit", "timer", JSON.stringify({ date: this.now })), "event");
          this.events.set("timer", interval);
        } else this.events.set(p.event, null);
        return null;
      }
      case "notify": {
        this.need("notifications");
        if (typeof p.title !== "string" || !p.title) throw new PluginError("notify: a title is required.");
        this.effects.push({ kind: "notify", title: p.title.slice(0, 80), ...(p.body !== undefined ? { body: String(p.body).slice(0, 240) } : {}) });
        return null;
      }
      case "openURL": {
        this.need("openURL");
        if (typeof p.url !== "string" || !canOpen(p.url)) throw new PluginError("openURL: only https, mailto and atelier://studio links can be opened.");
        this.effects.push({ kind: "openURL", url: p.url });
        return null;
      }
      case "theme": {
        this.need("appearance");
        if (!p.patch || typeof p.patch !== "object" || Array.isArray(p.patch)) throw new PluginError("theme.apply: pass an object of theme keys.");
        this.effects.push({ kind: "theme", patch: p.patch });
        return null;
      }
      case "timer": {
        if (typeof p.id !== "number" || typeof p.ms !== "number") throw new PluginError("timer: bad arguments.");
        const ms = Math.min(Math.max(p.ms, 0), 86_400_000);
        const plain = [...this.timers.values()].filter((t) => t.kind === "timer").length;
        if (plain >= limit("timers")) { this.logs.push({ level: "warn", text: `More than ${limit("timers")} timers; this one was ignored.` }); return null; }
        this.schedule(`timer:${p.id}`, ms, p.repeat ? Math.max(1000, ms) : null, () => this.enter("fire", p.id), "timer");
        return null;
      }
      case "clearTimer": this.timers.delete(`timer:${p.id}`); return null;
      case "http": return this.http(p);
      case "prompt": {
        if (typeof p.title !== "string" || !p.title) throw new PluginError("prompt: a title is required.");
        const answers = this.options.fixtures?.prompts ?? {};
        const answer = p.title in answers ? answers[p.title] : this.options.answer ?? null;
        this.effects.push({ kind: "prompt", title: p.title.slice(0, 80), secure: Boolean(p.secure), answer: p.secure && answer ? "•••" : answer });
        this.jobs.push(() => this.enter("settle", p.request, true, JSON.stringify({ text: answer })));
        return null;
      }
      default: return this.generic(kind, p);
    }
  }

  /** The engine's and the hooks' calls (PluginEngine.swift, PluginHooksBridge.swift), then anything newer. */
  generic(kind, p) {
    if (kind === "httpSend") return this.http(p);
    if (kind.startsWith("settings.")) return this.settingsCall(kind, p);
    if (kind === "env.strings") return this.strings();
    if (kind === "env.asset") return this.asset(p.path);
    if (kind === "send") {
      if (typeof p.to !== "string" || !/^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9][A-Za-z0-9_-]*)+$/.test(p.to)) {
        throw new PluginError("send: the first argument is the other plugin's id, like com.example.timer.");
      }
      if (Buffer.byteLength(JSON.stringify(p.payload ?? null)) > limit("messagePayloadBytes")) throw new PluginError("send: a message may be at most 64 KB of JSON.");
      this.effects.push({ kind: "send", to: p.to, payload: p.payload ?? null });
      if (!(this.manifest.messages?.send ?? []).includes(p.to)) {
        this.logs.push({ level: "warn", text: `Message to ${p.to} not delivered: ${p.to} is not listed under messages.send.` });
      }
      return null;
    }
    if (HOOKS.has(kind)) return this.hook(kind, p);
    this.effects.push({ kind, payload: p });
    this.logs.push({ level: "debug", text: `atelier-mod test does not know the call "${kind}"; it was recorded.` });
    return null;
  }

  // --- Settings, strings, assets ---------------------------------------------------------

  setting(key) {
    const s = (this.manifest.settings ?? []).find((x) => x.key === key);
    if (!s) throw new PluginError(`settings: "${key}" is not declared under settings in manifest.json.`);
    return s;
  }
  settingValue(s) { return this.values.has(s.key) ? this.values.get(s.key) : (s.default ?? null); }
  settingsCall(kind, p) {
    if (kind === "settings.all") return Object.fromEntries((this.manifest.settings ?? []).map((s) => [s.key, this.settingValue(s)]));
    const s = this.setting(String(p.key ?? ""));
    if (kind === "settings.get") return this.settingValue(s);
    if (kind !== "settings.set") throw new PluginError("Unknown settings call.");
    const value = checkSetting(s, p.value ?? null);
    if (value === null) this.values.delete(s.key); else this.values.set(s.key, value);
    this.effects.push({ kind: "settings.set", key: s.key, value: s.type === "secret" ? "•••" : value });
    return null;
  }
  strings() {
    const tables = this.manifest.strings ?? {};
    const norm = Object.fromEntries(Object.entries(tables).map(([k, v]) => [k.toLowerCase().replace(/_/g, "-"), v]));
    const code = String(this.options.language ?? "en").toLowerCase().replace(/_/g, "-");
    const mine = norm[code] ?? norm[code.split("-")[0]] ?? {};
    return { ...(norm.en ?? {}), ...mine };
  }
  asset(path) {
    path = String(path ?? "");
    const ext = path.split(".").pop().toLowerCase();
    const safe = path && !path.startsWith("/") && !path.split("/").some((part) => part === ".." || part.startsWith(".") || !part);
    if (!safe || !["png", "jpg", "jpeg", "heic", "pdf"].includes(ext)) throw new PluginError(`asset: "${path}" is not a relative path to a png, jpg, jpeg, heic, pdf file.`);
    const full = join(this.folder ?? ".", path);
    if (!this.folder || !existsSync(full) || !lstatSync(full).isFile()) throw new PluginError(`asset: "${path}" is not in the plugin.`);
    if (lstatSync(full).size > limit("assetBytes")) throw new PluginError(`asset: "${path}" is larger than 2 MB.`);
    return path;
  }

  // --- Hooks ----------------------------------------------------------------------------

  hook(kind, p) {
    const permission = { menuBar: "menuBar", menuBarRemove: "menuBar", activity: "liveActivities", activityEnd: "liveActivities",
      panel: "panels", panelShow: "panels", panelHide: "panels", panelPost: "panels", "scenes.list": "scenes", "scenes.apply": "scenes" }[kind];
    const fail = (text) => { throw new PluginError(text); };
    const id = () => (typeof p.id === "string" && ID.test(p.id) ? p.id : fail(`${kind}: an id of letters, digits, - _ or . is required, up to 64 characters.`));
    const admit = (map, max, what) => { const key = id(); if (!map.has(key) && map.size >= max) fail(`A plugin may have at most ${max} ${what}.`); return key; };
    const symbol = (s, path) => { if (s === undefined || s === null) return undefined; if (!isSymbolName(s)) fail(`${path}: "${s}" is not an SF Symbol name.`); return s; };
    const title = (fallback) => String(p.title ?? "").slice(0, 60) || fallback;
    if (permission) this.need(permission);
    const h = this.hooks;
    switch (kind) {
      case "palette": {
        const key = id();
        let prefix;
        if (typeof p.prefix === "string" && p.prefix) {
          prefix = p.prefix.toLowerCase();
          if (prefix.length > 12 || !/^[a-z0-9\-_.:/!?#@]+$/.test(prefix)) fail("paletteProvider: a prefix is 1 to 12 letters or digits, like \"gh\".");
        }
        admit(h.palettes, limit("paletteProviders"), "palette providers");
        h.palettes.set(key, { id: key, title: title(key), ...(prefix ? { prefix } : {}) });
        return null;
      }
      case "menuBar": {
        const key = id();
        const s = symbol(p.symbol, "menuBarItem");
        const text = p.text === undefined || p.text === null || p.text === "" ? undefined : String(p.text).slice(0, 16);
        if (!s && !text) fail("menuBarItem: give it a symbol, a text or both.");
        const menu = checkMenu(p.menu, "menuBarItem.menu");
        admit(h.menuBars, limit("menuBarItems"), "menu bar items");
        h.menuBars.set(key, { id: key, title: title(key), ...(s ? { symbol: s } : {}), ...(text ? { text } : {}), menu });
        return null;
      }
      case "menuBarRemove": h.menuBars.delete(id()); this.effects.push({ kind, id: p.id }); return null;
      case "tileHooks": {
        const accepts = (p.accepts ?? []).map((a) => (a === "url" || a === "text" ? a : fail("dockTile: accepts is a list of \"url\" and \"text\". Files are never handed to plugins.")));
        h.tiles.set(id(), { id: p.id, menu: checkMenu(p.menu, "dockTile.menu"), accepts: [...new Set(accepts)] });
        return null;
      }
      case "stack": {
        const key = id();
        const stackSymbol = symbol(p.symbol, "stackProvider") ?? "square.stack.3d.up";
        admit(h.stacks, limit("stackProviders"), "stack providers");
        h.stacks.set(key, { id: key, title: title(key), symbol: stackSymbol,
          refresh: Math.min(Math.max(typeof p.refresh === "number" ? p.refresh : 0, 0), 86400) });
        return null;
      }
      case "activity": {
        const key = id();
        h.activities.set(key, { id: key, title: title(key), symbol: symbol(p.symbol, "liveActivity") ?? "bolt.fill",
          text: String(p.text ?? "").slice(0, 60), ...(typeof p.progress === "number" ? { progress: Math.min(Math.max(p.progress, 0), 1) } : {}),
          ...(isColor(p.tint) ? { tint: p.tint } : {}), ...(p.until !== undefined ? { until: p.until } : {}) });
        return null;
      }
      case "panel": {
        const key = id();
        if (typeof p.html !== "string") fail("panel: html is required, as a string.");
        if (Buffer.byteLength(p.html) > limit("panelHTMLBytes")) fail("panel: html may be at most 512 KB.");
        admit(h.panels, limit("panels"), "panels");
        h.panels.set(key, { id: key, title: title(key), width: Math.min(Math.max(p.width ?? 420, 200), 1200),
          height: Math.min(Math.max(p.height ?? 320, 120), 900), resizable: Boolean(p.resizable), htmlBytes: Buffer.byteLength(p.html) });
        return null;
      }
      case "panelPost":
        id();
        if (Buffer.byteLength(JSON.stringify(p.message ?? null)) > limit("panelMessageBytes")) fail("panel.post: a message may be at most 64 KB of JSON.");
        this.effects.push({ kind, id: p.id, message: p.message ?? null });
        return null;
      case "stackChanged": case "activityEnd": case "panelShow": case "panelHide":
        id();
        if (kind === "activityEnd") h.activities.delete(p.id);
        this.effects.push({ kind, id: p.id });
        return null;
      case "scenes.list": {
        const scenes = (this.options.fixtures?.scenes ?? []).map((s) => (typeof s === "string" ? { name: s } : s));
        this.effects.push({ kind });
        this.jobs.push(() => this.enter("settle", p.request, true, JSON.stringify({ scenes })));
        return null;
      }
      case "scenes.apply": {
        if (typeof p.name !== "string" || !p.name || p.name.length > 120) fail("scenes.apply: pass a Scene's name.");
        const known = (this.options.fixtures?.scenes ?? []).map((s) => (typeof s === "string" ? s : s.name));
        const ok = !known.length || known.includes(p.name);
        this.effects.push({ kind, name: p.name });
        this.jobs.push(() => this.enter("settle", p.request, ok, JSON.stringify(ok ? {} : { error: `There is no Scene called ${p.name}.` })));
        return null;
      }
      case "hooks.reply": {
        const waiting = this.asks.get(p.request);
        if (waiting) { this.asks.delete(p.request); waiting(p); }
        return null;
      }
    }
    return null;
  }

  http(p) {
    const verb = String(p.method ?? "GET").toLowerCase();
    if (p.method !== undefined && !["POST", "PUT", "PATCH", "DELETE"].includes(String(p.method).toUpperCase())) {
      throw new PluginError("http: the method must be one of POST, PUT, PATCH, DELETE.");
    }
    if (typeof p.request !== "number" || typeof p.url !== "string") throw new PluginError(`http.${verb}: pass a URL string.`);
    if (p.json === null && p.body !== null && p.body !== undefined && typeof p.body !== "string") {
      throw new PluginError(`http.${verb}: body must be a string. Pass objects as json.`);
    }
    this.need("network");
    let url;
    try { url = new URL(p.url); } catch { throw new PluginError("http.get: pass a URL string."); }
    if (url.protocol !== "https:") throw new PluginError("Only https is allowed.");
    const host = url.hostname.toLowerCase();
    if (!this.hosts.includes(host)) throw new PluginError(`${url.hostname || "That host"} is not listed in network.hosts.`);
    if (url.port && url.port !== "443") throw new PluginError("Only the standard https port is allowed.");
    if (url.username || url.password) throw new PluginError("Links with credentials are not allowed.");
    if (this.pending.size >= limit("concurrentRequests")) throw new PluginError(`At most ${limit("concurrentRequests")} requests at once.`);
    const method = String(p.method ?? "GET").toUpperCase();
    const headers = {};
    for (const [k, v] of Object.entries(p.headers ?? {})) {
      if (typeof v !== "string" || Object.keys(headers).length >= 16) continue;
      if (["cookie", "host", "origin", "referer", "content-length", "connection"].includes(k.toLowerCase()) || !/^[A-Za-z0-9-]+$/.test(k) || v.length >= 2048) continue;
      headers[k] = v;
    }
    let body = null;
    if (p.json !== undefined && p.json !== null) {
      body = JSON.stringify(p.json);
      if (!Object.keys(headers).some((k) => k.toLowerCase() === "content-type")) headers["Content-Type"] = "application/json";
    } else if (typeof p.body === "string") body = p.body;
    const record = { kind: "http", method, url: p.url, ...(body !== null ? { body } : {}) };
    this.effects.push(record);
    const settle = (ok, payload) => this.jobs.push(() => this.enter("settle", p.request, ok, JSON.stringify(payload)));
    const fixtures = this.options.fixtures?.http ?? {};
    const fixture = fixtures[`${method} ${p.url}`] ?? fixtures[p.url];
    if (fixture) {
      const text = fixture.json !== undefined ? JSON.stringify(fixture.json) : String(fixture.body ?? "");
      const status = fixture.status ?? 200;
      record.status = status; record.source = "fixture";
      if (fixture.error) settle(false, { error: fixture.error });
      else settle(true, { status, ok: status >= 200 && status < 300, text, headers: Object.fromEntries(Object.entries(fixture.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v])) });
      return null;
    }
    if (!this.options.network) {
      record.source = "offline";
      settle(false, { error: `No fixture for ${method} ${p.url}. Add one to test/fixtures.json, or run with --network.` });
      return null;
    }
    const job = (async () => {
      const started = Date.now();
      try {
        const response = await fetch(p.url, { method, headers, body: body ?? undefined, redirect: "follow", signal: AbortSignal.timeout(limit("requestSeconds") * 1000) });
        const finalHost = new URL(response.url).hostname.toLowerCase();
        if (!this.hosts.includes(finalHost)) return settle(false, { error: `Redirected to ${finalHost}, which is not listed in network.hosts.` });
        const buffer = Buffer.from(await response.arrayBuffer());
        if (buffer.length > limit("responseBytes")) return settle(false, { error: "The response was larger than 2 MB." });
        record.status = response.status; record.source = "network";
        this.logs.push({ level: "debug", text: `${method} ${p.url} → ${response.status} in ${Date.now() - started} ms` });
        settle(true, { status: response.status, ok: response.ok, text: buffer.toString("utf8"), headers: Object.fromEntries([...response.headers].map(([k, v]) => [k.toLowerCase(), v])) });
      } catch (error) {
        settle(false, { error: error?.message ?? String(error) });
      }
    })();
    this.pending.add(job);
    job.finally(() => this.pending.delete(job));
    return null;
  }

  // --- Virtual time --------------------------------------------------------------------

  schedule(key, afterMs, everyMs, fire, kind = "widget") {
    this.timers.set(key, { due: this.now + afterMs, every: everyMs, fire, kind });
  }

  /** Moves the clock forward, firing every timer, refresh and timer event that comes due, in order. */
  async advance(ms) {
    const end = this.now + ms;
    for (let guard = 0; guard < 100000; guard++) {
      let next = null;
      for (const [key, t] of this.timers) if (t.due <= end && (!next || t.due < next[1].due)) next = [key, t];
      if (!next || this.stopped) break;
      const [key, t] = next;
      this.now = t.due;
      if (t.every) t.due += t.every; else this.timers.delete(key);
      t.fire();
      await this.idle();
    }
    this.now = end;
  }

  // --- What an author calls --------------------------------------------------------------

  find(map, idOrTitle, what) {
    if (map.has(idOrTitle)) return map.get(idOrTitle);
    const lower = String(idOrTitle).toLowerCase();
    const hit = [...map.values()].find((x) => (x.spec?.title ?? x.title ?? "").toLowerCase() === lower);
    if (!hit) throw new PluginError(`No ${what} "${idOrTitle}". Registered: ${[...map.keys()].join(", ") || "none"}.`);
    return hit;
  }

  async invoke(key, payload) { this.enter("dispatch", key, payload === undefined ? "" : JSON.stringify(payload)); await this.idle(); }

  /** Runs a command by id or title. */
  async runCommand(idOrTitle) { const c = this.find(this.commands, idOrTitle, "command"); await this.invoke(`command:${c.id}:run`); }
  /** Clicks a Dock tile. */
  async click(idOrTitle) { const t = this.find(this.tiles, idOrTitle, "Dock tile"); await this.invoke(`tile:${t.id}:onClick`); }
  /** Fires a corner action. */
  async corner(idOrTitle) { const c = this.find(this.corners, idOrTitle, "corner action"); await this.invoke(`corner:${c.id}:run`); }
  /** Runs an action by id (atelier.action, or an inline one from a view), as a tap would. */
  async action(id, payload) { await this.invoke(`action:${id}`, payload); }

  /** Taps the button or toggle titled `label` in any drawn widget. A toggle flips. */
  async tap(label) {
    const lower = String(label).toLowerCase();
    for (const w of this.widgets.values()) {
      const hit = findNode(w.view, (n) => (n.type === "button" && n.title?.toLowerCase() === lower) || (n.type === "toggle" && n.label?.toLowerCase() === lower));
      if (hit) return this.action(hit.action, hit.type === "toggle" ? { on: !hit.on } : undefined);
    }
    throw new PluginError(`No button or toggle "${label}" in any widget.`);
  }

  /** Asks every palette provider for `query`, as the Command palette does. Returns their answers. */
  async palette(query) {
    const out = [];
    for (const provider of this.hooks.palettes.values()) {
      const asked = paletteQuery(provider, query);
      if (asked === null) continue;
      const answer = await this.ask(`palette:${provider.id}:search`, asked, limit("paletteRows"));
      out.push({ provider: provider.id, query: asked, ...answer });
    }
    this.effects.push({ kind: "palette", query, answers: out });
    return out;
  }

  /** Opens a stack from a stack provider, as clicking it on the Dock does. */
  async openStack(idOrTitle) {
    const stack = this.find(this.hooks.stacks, idOrTitle, "stack provider");
    const answer = await this.ask(`stack:${stack.id}:items`, null, limit("stackItems"));
    this.effects.push({ kind: "stack", id: stack.id, ...answer });
    return answer;
  }

  /** __atelier.ask, as PluginHooks.swift calls it; the answer comes back through hooks.reply. */
  async ask(key, payload, max) {
    const request = (this.nextAsk = (this.nextAsk ?? 1000000) + 1);
    let reply = null;
    this.asks.set(request, (r) => { reply = r; });
    this.enter("ask", key, request, payload === null ? "" : JSON.stringify(payload));
    await this.idle();
    this.asks.delete(request);
    if (!reply) return { ok: false, error: "No answer." };
    if (!reply.ok) { this.problem(`${key}: ${reply.error}`); return { ok: false, error: reply.error }; }
    const rows = (Array.isArray(reply.value) ? reply.value : []).map((r) => (typeof r === "string" ? { title: r } : r)).filter((r) => r && r.title).slice(0, max);
    return { ok: true, rows };
  }

  /** Chooses the item titled `title` in a menu bar item's or a tile's menu, or a palette or stack row. */
  async menu(title) {
    const lower = String(title).toLowerCase();
    const menus = [...this.hooks.menuBars.values(), ...this.hooks.tiles.values()].map((x) => x.menu);
    const rows = this.effects.filter((e) => e.kind === "palette" || e.kind === "stack")
      .flatMap((e) => (e.answers ? e.answers.flatMap((a) => a.rows ?? []) : e.rows ?? []));
    const item = menus.map((m) => findMenuItem(m, lower)).find(Boolean) ?? rows.find((r) => r.title.toLowerCase() === lower);
    if (!item) throw new PluginError(`No menu item or row "${title}".`);
    if (!item.action) throw new PluginError(`"${title}" has no action.`);
    await this.invoke(item.action);
  }

  /** Drops a link or text on a tile: "url:https://…" or "text:…", optionally "tileId@url:…". */
  async drop(spec) {
    const m = /^(?:([^@:]+)@)?(url|text):(.*)$/s.exec(String(spec));
    if (!m) throw new PluginError("--drop takes url:<link> or text:<text>, optionally <tile>@ first.");
    const [, tileId, kind, value] = m;
    const candidates = [...this.hooks.tiles.values()].filter((t) => (!tileId || t.id === tileId) && t.accepts.includes(kind));
    if (!candidates.length) throw new PluginError(`No tile${tileId ? ` "${tileId}"` : ""} accepts ${kind}.`);
    if (Buffer.byteLength(value) > limit("dropBytes")) throw new PluginError("A drop is at most 8 KB.");
    if (kind === "url" && !/^(https?|mailto):/i.test(value)) throw new PluginError("Only http, https and mailto links are dropped as url.");
    await this.invoke(`tile:${candidates[0].id}:onDrop`, { kind, value });
  }

  /** Clicks a live activity. */
  async tapActivity(id) { this.find(this.hooks.activities, id, "live activity"); await this.invoke(`activity:${id}:onTap`); }

  /** A panel's page posts a message: its onMessage runs and the panelMessage event fires. */
  async panelMessage(id, message) {
    this.find(this.hooks.panels, id, "panel");
    await this.invoke(`panel:${id}:onMessage`, message);
    await this.emit("panelMessage", { id, message });
  }
  /** Sends an event, as Atelier would. */
  async emit(event, payload = {}) { this.enter("emit", event, JSON.stringify(payload)); await this.idle(); }

  /** Runs a widget's data and view and returns { view, error }. view is normalised like Atelier's. */
  async render(idOrTitle) {
    const w = this.find(this.widgets, idOrTitle, "widget");
    this.enter("render", w.spec.id);
    await this.idle();
    return { view: w.view ?? null, error: w.error ?? null };
  }

  async renderAll() {
    const out = {};
    for (const id of this.widgets.keys()) out[id] = await this.render(id);
    return out;
  }

  /** Everything the plugin registered and did, as plain JSON. */
  report() {
    const hooks = Object.fromEntries(Object.entries(this.hooks).map(([k, m]) => [k, [...m.values()]]).filter(([, list]) => list.length));
    return {
      plugin: { id: this.manifest.id, name: this.manifest.name, version: this.manifest.version },
      permissions: { asked: this.manifest.permissions ?? [], granted: [...this.granted] },
      widgets: [...this.widgets.values()].map((w) => ({ ...w.spec, view: w.view ?? null, error: w.error ?? null })),
      tiles: [...this.tiles.values()],
      commands: [...this.commands.values()],
      cornerActions: [...this.corners.values()],
      events: Object.fromEntries(this.events),
      ...(Object.keys(hooks).length ? { hooks } : {}),
      ...((this.manifest.settings ?? []).length ? { settings: Object.fromEntries((this.manifest.settings ?? []).map((s) => [s.key, s.type === "secret" && this.values.has(s.key) ? "•••" : this.settingValue(s)])) } : {}),
      effects: this.effects,
      storage: this.storage,
      console: this.logs,
      problems: this.problems,
    };
  }
}

// --- Helpers mirroring the app's checks ----------------------------------------------------

const HOOKS = new Set(["palette", "menuBar", "menuBarRemove", "tileHooks", "stack", "stackChanged", "activity", "activityEnd",
  "panel", "panelShow", "panelHide", "panelPost", "scenes.list", "scenes.apply", "hooks.reply"]);

/** PluginMenuEntry.parse: 40 entries in all, one level of submenus, titles up to 80. */
function checkMenu(list, path) {
  if (list === undefined || list === null) return [];
  if (!Array.isArray(list)) throw new PluginError(`${path}: a menu is a list of items.`);
  let budget = limit("menuItems");
  const walk = (items, depth, where) => items.map((entry, i) => {
    if (--budget < 0) throw new PluginError(`${path}: a menu may hold at most ${limit("menuItems")} items in all.`);
    const here = `${where}[${i}]`;
    if (entry === "separator" || entry === "-") return "separator";
    if (!entry || typeof entry !== "object") throw new PluginError(`${here}: a menu item is an object or "separator".`);
    const title = String(entry.title ?? "").slice(0, 80);
    if (!title) throw new PluginError(`${here}: a menu item needs a title.`);
    if (entry.symbol !== undefined && entry.symbol !== null && !isSymbolName(entry.symbol)) throw new PluginError(`${here}: "${entry.symbol}" is not an SF Symbol name.`);
    if (entry.submenu !== undefined) {
      if (depth >= 2) throw new PluginError(`${here}: menus nest at most 2 deep.`);
      if (!Array.isArray(entry.submenu)) throw new PluginError(`${here}: submenu is a list of items.`);
      return { title, submenu: walk(entry.submenu, depth + 1, here + ".submenu") };
    }
    return { title, ...(entry.symbol ? { symbol: entry.symbol } : {}), ...(entry.action ? { action: entry.action } : {}),
      checked: Boolean(entry.checked), enabled: entry.enabled ?? true };
  });
  return walk(list, 1, path);
}

function findMenuItem(menu, lower) {
  for (const entry of menu ?? []) {
    if (typeof entry !== "object") continue;
    if (entry.title?.toLowerCase() === lower && !entry.submenu) return entry;
    const inner = entry.submenu && findMenuItem(entry.submenu, lower);
    if (inner) return inner;
  }
  return null;
}

function findNode(node, test) {
  if (!node || typeof node !== "object") return null;
  if (test(node)) return node;
  for (const child of node.children ?? []) { const hit = findNode(child, test); if (hit) return hit; }
  return null;
}

/** PluginPaletteSpec.query: without a prefix, any non-empty query; with one, "<prefix> rest" gives rest. */
function paletteQuery(provider, text) {
  const trimmed = String(text).trim();
  if (!provider.prefix) return trimmed || null;
  if (!trimmed.toLowerCase().startsWith(provider.prefix + " ")) return null;
  return trimmed.slice(provider.prefix.length).trim() || null;
}

/** PluginSetting.check: the value for a setting, normalised, or a thrown PluginError. null resets. */
export function checkSetting(s, value) {
  if (value === null) return null;
  const wrong = () => new PluginError(`settings: "${s.key}" is a ${s.type} setting; ${JSON.stringify(value)} does not fit.`);
  switch (s.type) {
    case "text": if (typeof value !== "string" || value.length > 1000) throw wrong(); return value;
    case "secret": if (typeof value !== "string" || value.length > 4096) throw wrong(); return value;
    case "number":
      if (typeof value !== "number" || !Number.isFinite(value)) throw wrong();
      if (typeof s.min === "number" && value < s.min) throw new PluginError(`settings: "${s.key}" is at least ${s.min}.`);
      if (typeof s.max === "number" && value > s.max) throw new PluginError(`settings: "${s.key}" is at most ${s.max}.`);
      return value;
    case "toggle": if (typeof value !== "boolean") throw wrong(); return value;
    case "choice": {
      const options = (s.options ?? []).map((o) => (typeof o === "string" ? o : o.value));
      if (!options.includes(value)) throw new PluginError(`settings: "${s.key}" is one of ${options.join(", ")}.`);
      return value;
    }
    case "color": if (typeof value !== "string" || !/^#?[0-9A-Fa-f]{6}$/.test(value)) throw wrong(); return (value.startsWith("#") ? value : "#" + value).toUpperCase();
    case "hotkeyHint": {
      if (typeof value !== "string") throw wrong();
      if (!value) return null;
      const normal = normaliseShortcut(value);
      if (!normal) throw new PluginError(`settings: "${value}" is not a shortcut. Use something like "cmd+shift+p".`);
      return normal;
    }
    default: throw wrong();
  }
}
