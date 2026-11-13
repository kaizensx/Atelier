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
import { readFileSync, existsSync } from "node:fs";
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
  const plugin = new Plugin(manifest, source, entry, options);
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
    this.other = new Map();   // registrations of kinds this harness has no special case for
    this.events = new Map();  // event -> interval or null
    this.logs = [];           // { level, text }
    this.effects = [];        // notifications, opened links, theme changes, prompts, requests
    this.problems = [];       // errors the app would show: thrown exceptions, refused calls
    this.registered = new Set();
    this.storage = { ...(options.storage ?? {}) };
    this.settings = Object.fromEntries((manifest.settings ?? []).map((s) => [s.key, s.default ?? null]));
    Object.assign(this.settings, options.settings ?? {});
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
        for (const extra of ["menu", "accepts"]) if (p[extra] !== undefined) spec[extra] = p[extra];
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

  /** Kinds added to the API after this harness: registrations by their bridge name, else a recorded call. */
  generic(kind, p) {
    const entry = this.api.api.find((e) => e.bridge === kind);
    if (kind === "settings.get") return p && typeof p.key === "string" ? (this.settings[p.key] ?? null) : this.settings;
    if (kind === "t") {
      const strings = this.manifest.strings ?? {};
      const text = strings[this.options.language ?? "en"]?.[p.key] ?? strings.en?.[p.key] ?? String(p.key ?? "");
      return text.replace(/\{(\w+)\}/g, (m, k) => (p.values && k in p.values ? String(p.values[k]) : m));
    }
    if (kind === "asset") return `asset:${String(p.path ?? "")}`;
    if (entry?.permission) this.need(entry.permission);
    if (entry?.registers) {
      const id = this.id(kind, p);
      this.register(`${kind}:${id}`);
      if (!this.other.has(kind)) this.other.set(kind, new Map());
      this.other.get(kind).set(id, p);
      return null;
    }
    this.effects.push({ kind, payload: p });
    if (!entry) this.logs.push({ level: "debug", text: `atelier-mod test does not know the call "${kind}"; it was recorded.` });
    return null;
  }

  http(p) {
    if (typeof p.request !== "number" || typeof p.url !== "string") throw new PluginError("http.get: pass a URL string.");
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
    const record = { kind: "http", method, url: p.url };
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
        const response = await fetch(p.url, { method, headers, body: p.body, redirect: "follow", signal: AbortSignal.timeout(limit("requestSeconds") * 1000) });
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
  /** Runs a named action (atelier.action), as a button or toggle would. */
  async action(id, payload = {}) { await this.invoke(`action:${id}:run`, payload); }
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
    const other = Object.fromEntries([...this.other].map(([k, m]) => [k, [...m.values()]]));
    return {
      plugin: { id: this.manifest.id, name: this.manifest.name, version: this.manifest.version },
      permissions: { asked: this.manifest.permissions ?? [], granted: [...this.granted] },
      widgets: [...this.widgets.values()].map((w) => ({ ...w.spec, view: w.view ?? null, error: w.error ?? null })),
      tiles: [...this.tiles.values()],
      commands: [...this.commands.values()],
      cornerActions: [...this.corners.values()],
      events: Object.fromEntries(this.events),
      ...(Object.keys(other).length ? { other } : {}),
      effects: this.effects,
      storage: this.storage,
      console: this.logs,
      problems: this.problems,
    };
  }
}
