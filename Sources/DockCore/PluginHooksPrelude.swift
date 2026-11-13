/// The JavaScript half of the hooks (PluginHooksBridge.swift). It runs inside the prelude's own
/// function, after `register` is defined, so it shares `call`, `callbacks`, `fn`, `describe`,
/// `register`, `requests` and `nextRequest`, and adds no globals of its own.
///
/// Functions a plugin puts in a menu or in a result row never cross the bridge: each becomes an
/// action key (`action:<owner>:<n>`) that Atelier calls back through `__atelier.dispatch`. When a
/// menu or a list is replaced, the keys of older ones are dropped.
public enum PluginHooksPrelude {
    public static let source = #"""
      // Hooks into Atelier (PluginHooksPrelude.swift).
      const hooks = (() => {
        const generations = Object.create(null);
        let nextAction = 1;
        const slug = (kind, spec) => {
          if (!spec || typeof spec !== "object") throw new TypeError("atelier." + kind + " takes an object");
          const id = String(spec.id || spec.title || "").trim().toLowerCase().replace(/[^a-z0-9._-]+/g, "-").slice(0, 64);
          if (!id) throw new TypeError("atelier." + kind + " needs an id or a title");
          return id;
        };
        const plain = (spec, skip) => {
          const out = {};
          for (const key of Object.keys(spec)) {
            if (typeof spec[key] !== "function" && !(skip && skip.indexOf(key) >= 0)) out[key] = spec[key];
          }
          return out;
        };
        const keep = (owner, keys, depth) => {
          const list = generations[owner] || (generations[owner] = []);
          list.push(keys);
          while (list.length > depth) for (const key of list.shift()) delete callbacks[key];
        };
        const action = (owner, value, keys) => {
          if (value === undefined || value === null) return undefined;
          fn(value, "action");
          const key = "action:" + owner + ":" + (nextAction++);
          callbacks[key] = value;
          keys.push(key);
          return key;
        };
        const menu = (items, owner, keys) => {
          if (items === undefined || items === null) return [];
          if (!Array.isArray(items)) throw new TypeError("menu must be an array");
          return items.map((item) => {
            if (item === "separator" || item === "-") return "separator";
            if (!item || typeof item !== "object") throw new TypeError("a menu item is an object or \"separator\"");
            const out = { title: String(item.title === undefined ? "" : item.title) };
            if (item.symbol !== undefined) out.symbol = item.symbol;
            if (item.checked !== undefined) out.checked = !!item.checked;
            if (item.enabled !== undefined) out.enabled = !!item.enabled;
            if (item.submenu !== undefined) out.submenu = menu(item.submenu, owner, keys);
            else out.action = action(owner, item.action, keys);
            return out;
          });
        };
        const send = (kind, payload, owner, keys) => {
          try { call(kind, payload); } catch (error) { for (const key of keys) delete callbacks[key]; throw error; }
          keep(owner, keys, 1);
        };
        const rows = (owner, list, limit) => {
          const keys = [];
          const out = (Array.isArray(list) ? list : []).slice(0, limit).map((row) => {
            if (!row || typeof row !== "object") return String(row);
            const item = plain(row);
            item.action = action(owner, row.action, keys);
            return item;
          });
          // A few lists stay callable: an older answer may still be on screen for a moment.
          keep(owner, keys, 4);
          return out;
        };
        const ask = (kind, payload, pick) => new Promise((resolve, reject) => {
          const request = nextRequest++;
          requests[request] = { resolve: (reply) => resolve(pick(reply)), reject };
          try { call(kind, Object.assign({ request }, payload)); } catch (error) { delete requests[request]; reject(error); }
        });
        const tile = (id, spec) => {
          if (spec.onDrop !== undefined) callbacks["tile:" + id + ":onDrop"] = fn(spec.onDrop, "dockTile.onDrop");
          if (spec.menu === undefined && spec.accepts === undefined) return;
          const owner = "tile:" + id, keys = [];
          send("tileHooks", { id, menu: menu(spec.menu, owner, keys), accepts: spec.accepts || [] }, owner, keys);
        };
        const api = {
          paletteProvider(spec) { return register("palette", spec, ["search"]); },
          menuBarItem(spec) {
            const id = slug("menuBarItem", spec);
            let current = Object.assign({}, spec);
            const update = () => {
              const owner = "menuBar:" + id, keys = [];
              send("menuBar", Object.assign(plain(current, ["menu"]), { id, menu: menu(current.menu, owner, keys) }), owner, keys);
            };
            update();
            return Object.freeze({
              id,
              update(changes) { current = Object.assign(current, changes || {}); update(); },
              remove() { call("menuBarRemove", { id }); },
            });
          },
          stackProvider(spec) {
            const id = register("stack", spec, ["items"]);
            return Object.freeze({ id, refresh() { call("stackChanged", { id }); } });
          },
          liveActivity(spec) {
            const id = register("activity", spec, ["onTap"]);
            let current = Object.assign({}, spec);
            return Object.freeze({
              id,
              update(changes) { current = Object.assign(current, changes || {}, { id }); call("activity", plain(current)); },
              end() { call("activityEnd", { id }); },
            });
          },
          panel(spec) {
            const id = register("panel", spec, ["onMessage"]);
            return Object.freeze({
              id,
              show() { call("panelShow", { id }); },
              hide() { call("panelHide", { id }); },
              post(message) { call("panelPost", { id, message: message === undefined ? null : message }); },
            });
          },
          scenes: Object.freeze({
            list: () => ask("scenes.list", {}, (reply) => reply.scenes || []),
            apply: (name) => ask("scenes.apply", { name: String(name) }, () => undefined),
          }),
        };
        // Atelier asks a palette provider or a stack provider; the answer goes back as rows.
        const answer = (key, request, payloadJSON) => {
          const handler = callbacks[key];
          const owner = key.slice(0, key.lastIndexOf(":"));
          const limit = key.indexOf("palette:") === 0 ? 20 : 60;
          const payload = payloadJSON ? JSON.parse(payloadJSON) : undefined;
          const reply = (body) => {
            try { call("hooks.reply", Object.assign({ request }, body)); } catch (error) { console.error(key + ": " + describe(error)); }
          };
          Promise.resolve()
            .then(() => { if (!handler) throw new Error("Nothing answers " + key); return handler(payload); })
            .then((list) => reply({ ok: true, value: rows(owner, list, limit) }))
            .catch((error) => reply({ ok: false, error: describe(error) }));
        };
        return Object.freeze({ api, tile, answer });
      })();
    """#
}
