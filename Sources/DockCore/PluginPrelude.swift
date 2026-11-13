/// The JavaScript every plugin runs before its own script. It builds the `atelier` object on
/// top of a single native function, `__atelierNative(kind, json)`, so everything crossing the
/// bridge is a JSON string that `PluginMessage` decodes and checks.
///
/// Native code calls back in through `__atelier.dispatch`, `__atelier.render`, `__atelier.emit`,
/// `__atelier.fire` and `__atelier.settle`.
public enum PluginPrelude {
    public static let apiVersion = "1.1"

    public static let source = #"""
    (function (global) {
      "use strict";
      const native = global.__atelierNative;
      delete global.__atelierNative;
      const call = (kind, payload) => {
        const reply = native(kind, JSON.stringify(payload === undefined ? null : payload));
        const value = reply === undefined || reply === "" ? null : JSON.parse(reply);
        if (value && typeof value === "object" && value.__error) throw new Error(value.__error);
        return value;
      };
      const callbacks = Object.create(null);
      const widgets = Object.create(null);
      const listeners = Object.create(null);
      const timers = Object.create(null);
      const requests = Object.create(null);
      let nextTimer = 1, nextRequest = 1;

      const describe = (value) => {
        if (value instanceof Error) return value.message;
        if (typeof value === "string") return value;
        try { return JSON.stringify(value); } catch (e) { return String(value); }
      };
      const log = (level) => (...parts) => call("log", { level, message: parts.map(describe).join(" ") });
      global.console = { log: log("log"), info: log("info"), warn: log("warn"), error: log("error"), debug: log("debug") };

      const fn = (value, name) => {
        if (typeof value !== "function") throw new TypeError(name + " must be a function");
        return value;
      };
      const settle = (value) => (value && typeof value.then === "function") ? value : Promise.resolve(value);

      global.setTimeout = (handler, ms, ...args) => {
        const id = nextTimer++;
        timers[id] = { handler: fn(handler, "setTimeout handler"), args, repeat: false };
        call("timer", { id, ms: Number(ms) || 0, repeat: false });
        return id;
      };
      global.setInterval = (handler, ms, ...args) => {
        const id = nextTimer++;
        timers[id] = { handler: fn(handler, "setInterval handler"), args, repeat: true };
        call("timer", { id, ms: Math.max(1000, Number(ms) || 0), repeat: true });
        return id;
      };
      global.clearTimeout = global.clearInterval = (id) => {
        if (timers[id]) { delete timers[id]; call("clearTimer", { id }); }
      };

      const storage = Object.freeze({
        get: (key, fallback) => { const v = call("storage.get", { key: String(key) }); return v === null ? (fallback === undefined ? null : fallback) : v; },
        set: (key, value) => { call("storage.set", { key: String(key), value: value === undefined ? null : value }); },
        remove: (key) => { call("storage.set", { key: String(key), value: null }); },
        keys: () => call("storage.keys", {}),
      });

      const send = (method) => (url, options) => new Promise((resolve, reject) => {
        const request = nextRequest++;
        requests[request] = { resolve, reject };
        const o = options || {};
        try {
          call("httpSend", { request, method, url: String(url), headers: o.headers || {},
                             body: o.body === undefined ? null : o.body, json: o.json === undefined ? null : o.json });
        } catch (e) { delete requests[request]; reject(e); }
      });
      const http = Object.freeze({
        get: (url, options) => new Promise((resolve, reject) => {
          const request = nextRequest++;
          requests[request] = { resolve, reject };
          try {
            call("http", { request, url: String(url), headers: (options && options.headers) || {} });
          } catch (e) { delete requests[request]; reject(e); }
        }),
        post: send("POST"),
        put: send("PUT"),
        patch: send("PATCH"),
        delete: send("DELETE"),
      });

      const settings = Object.freeze({
        get: (key) => call("settings.get", { key: String(key) }),
        set: (key, value) => { call("settings.set", { key: String(key), value: value === undefined ? null : value }); },
        all: () => call("settings.all", {}),
      });

      // Taps on buttons and toggles call back by id. Inline functions in a view get an id per
      // widget, replaced on each render.
      const inline = Object.create(null);
      const actionKey = (id) => "action:" + id;
      const bindActions = (owner, tree) => {
        for (const id of inline[owner] || []) delete callbacks[actionKey(id)];
        const made = [];
        let n = 0;
        const walk = (node, depth) => {
          if (!node || typeof node !== "object" || depth > 12) return;
          if (Array.isArray(node)) { node.forEach((child) => walk(child, depth + 1)); return; }
          if (typeof node.action === "function") {
            const id = "_" + owner + "." + (n++);
            callbacks[actionKey(id)] = node.action;
            node.action = id;
            made.push(id);
          }
          if (Array.isArray(node.children)) node.children.forEach((child) => walk(child, depth + 1));
        };
        walk(tree, 0);
        inline[owner] = made;
        return tree;
      };

      let strings = null;
      const translate = (key, vars) => {
        if (strings === null) { try { strings = call("env.strings", {}) || {}; } catch (e) { strings = {}; } }
        let text = Object.prototype.hasOwnProperty.call(strings, key) ? String(strings[key]) : String(key);
        if (vars && typeof vars === "object") {
          for (const name of Object.keys(vars)) text = text.split("{" + name + "}").join(String(vars[name]));
        }
        return text;
      };

      const register = (kind, spec, functions) => {
        if (!spec || typeof spec !== "object") throw new TypeError("atelier." + kind + " takes an object");
        const id = String(spec.id || spec.title || "").trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").slice(0, 64);
        if (!id) throw new TypeError("atelier." + kind + " needs an id or a title");
        for (const name of functions) {
          if (spec[name] !== undefined) callbacks[kind + ":" + id + ":" + name] = fn(spec[name], kind + "." + name);
        }
        const plain = {};
        for (const key of Object.keys(spec)) if (typeof spec[key] !== "function") plain[key] = spec[key];
        plain.id = id;
        call(kind, plain);
        return id;
      };

      const atelier = {
        version: "\#(apiVersion)",
        widget(spec) {
          const id = register("widget", spec, ["data", "view"]);
          widgets[id] = true;
          return Object.freeze({ id, refresh: () => render(id) });
        },
        dockTile(spec) {
          const id = register("tile", spec, ["onClick"]);
          let current = Object.assign({}, spec);
          return Object.freeze({
            id,
            update(changes) {
              current = Object.assign(current, changes || {}, { id });
              const plain = {};
              for (const key of Object.keys(current)) if (typeof current[key] !== "function") plain[key] = current[key];
              call("tile", plain);
            },
          });
        },
        command(spec) { return register("command", spec, ["run"]); },
        cornerAction(spec) { return register("corner", spec, ["run"]); },
        action(id, handler) {
          const key = String(id || "").trim();
          if (!/^[A-Za-z0-9._-]{1,64}$/.test(key)) throw new TypeError("atelier.action needs an id of letters, digits, - _ or .");
          callbacks[actionKey(key)] = fn(handler, "atelier.action handler");
          return key;
        },
        send(to, payload) { call("send", { to: String(to), payload: payload === undefined ? null : payload }); },
        asset(path) { return call("env.asset", { path: String(path) }); },
        t: translate,
        settings,
        on(event, handler, options) {
          (listeners[event] = listeners[event] || []).push(fn(handler, "atelier.on handler"));
          call("on", { event: String(event), interval: options && options.interval });
        },
        notify(title, body) { call("notify", typeof title === "object" ? title : { title: String(title), body: body === undefined ? undefined : String(body) }); },
        openURL(url) { call("openURL", { url: String(url) }); },
        prompt(title, options) {
          return new Promise((resolve, reject) => {
            const request = nextRequest++;
            requests[request] = { resolve: (reply) => resolve(reply.text === undefined ? null : reply.text), reject };
            try {
              call("prompt", Object.assign({ request, title: String(title) }, options || {}));
            } catch (e) { delete requests[request]; reject(e); }
          });
        },
        storage,
        http,
        theme: Object.freeze({
          apply(patch) { call("theme", { patch }); },
        }),
        ui: Object.freeze({
          text: (text, style) => Object.assign({ type: "text", text: String(text) }, style || {}),
          symbol: (name, style) => Object.assign({ type: "symbol", name }, style || {}),
          ring: (value, style) => Object.assign({ type: "ring", value }, style || {}),
          bar: (value, style) => Object.assign({ type: "bar", value }, style || {}),
          sparkline: (values, style) => Object.assign({ type: "sparkline", values }, style || {}),
          list: (items, style) => Object.assign({ type: "list", items }, style || {}),
          vstack: (children, style) => Object.assign({ type: "vstack", children }, style || {}),
          hstack: (children, style) => Object.assign({ type: "hstack", children }, style || {}),
          zstack: (children, style) => Object.assign({ type: "zstack", children }, style || {}),
          spacer: () => ({ type: "spacer" }),
          button: (title, action, style) => Object.assign({ type: "button", title: String(title), action }, style || {}),
          toggle: (label, on, action, style) => Object.assign({ type: "toggle", label: String(label), on: !!on, action }, style || {}),
          image: (source, style) => Object.assign({ type: "image" }, String(source).startsWith("https://") ? { url: String(source) } : { asset: String(source) }, style || {}),
          chart: (data, style) => Object.assign({ type: "chart" }, Array.isArray(data) && data.length && typeof data[0] === "object" ? { series: data } : { values: data }, style || {}),
          grid: (children, style) => Object.assign({ type: "grid", children }, style || {}),
          progress: (value, style) => Object.assign({ type: "progress", value }, style || {}),
          divider: () => ({ type: "divider" }),
        }),
      };

      const render = (id) => {
        const data = callbacks["widget:" + id + ":data"];
        const view = callbacks["widget:" + id + ":view"];
        return Promise.resolve()
          .then(() => data ? data() : undefined)
          .then((value) => view ? view(value) : value)
          .then((tree) => call("widgetView", { id, view: tree === undefined ? null : bindActions(id, tree) }))
          .catch((error) => call("widgetError", { id, message: describe(error) }));
      };

      Object.defineProperty(global, "__atelier", { value: Object.freeze({
        dispatch(key, payloadJSON) {
          const handler = callbacks[key];
          if (!handler) return;
          const payload = payloadJSON ? JSON.parse(payloadJSON) : undefined;
          Promise.resolve().then(() => handler(payload)).catch((error) => console.error(key + ": " + describe(error)));
        },
        render,
        emit(event, payloadJSON) {
          const payload = payloadJSON ? JSON.parse(payloadJSON) : undefined;
          for (const handler of listeners[event] || []) {
            try { settle(handler(payload)).catch((error) => console.error(event + ": " + describe(error))); }
            catch (error) { console.error(event + ": " + describe(error)); }
          }
        },
        fire(id) {
          const timer = timers[id];
          if (!timer) return;
          if (!timer.repeat) delete timers[id];
          try { timer.handler(...timer.args); } catch (error) { console.error("timer: " + describe(error)); }
        },
        settle(request, ok, payloadJSON) {
          const pending = requests[request];
          if (!pending) return;
          delete requests[request];
          const payload = JSON.parse(payloadJSON);
          if (!ok) { pending.reject(new Error(payload.error || "Request failed")); return; }
          if (typeof payload.text === "string" && payload.status !== undefined) {
            payload.json = function () { return JSON.parse(this.text); };
          }
          pending.resolve(Object.freeze(payload));
        },
      }) });

      Object.defineProperty(global, "atelier", { value: Object.freeze(atelier), enumerable: true });
    })(this);
    """#
}
