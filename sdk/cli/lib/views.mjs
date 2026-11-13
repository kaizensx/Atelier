// Checks and normalises a view tree the way Atelier does (PluginNode.parse in
// Sources/DockCore/PluginBridge.swift): the same limits, the same clamping, the same errors.
// View types come from plugin-api.json, so new ones need no change here.

import { loadAPI, limit } from "./api.mjs";

const clamp = (v, lo, hi, fallback) => {
  const n = typeof v === "number" && Number.isFinite(v) ? v : fallback;
  return Math.min(Math.max(n, lo), hi);
};
const format = (n) => (!Number.isFinite(n) ? "–" : Number.isInteger(n) && Math.abs(n) < 1e15 ? String(n) : n.toFixed(2));
const asText = (v) => (typeof v === "string" ? v : typeof v === "number" ? format(v) : typeof v === "boolean" ? String(v) : "");
export const isSymbolName = (name) => typeof name === "string" && name.length >= 1 && name.length <= 80 && /^[a-z0-9.]+$/.test(name);
export const isColor = (c) => typeof c === "string" && (/^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$/.test(c) || loadAPI().colors.named.includes(c));

export class ViewError extends Error {}

/** Returns the normalised tree, or throws a ViewError with the same message Atelier gives. */
export function parseView(value) {
  const api = loadAPI();
  const maxNodes = limit("viewNodes"), maxDepth = limit("viewDepth"), maxText = limit("textLength");
  const maxPoints = limit("sparklinePoints"), maxRows = limit("listRows");
  const types = new Set(api.views.map((v) => v.type).concat("stack"));
  const clip = (t) => (t.length > maxText ? t.slice(0, maxText) + "…" : t);
  let budget = maxNodes;

  const style = (o, base = {}) => {
    const s = { size: 13, weight: "regular", design: "default", lines: 2, ...base };
    if (typeof o.size === "number") s.size = clamp(o.size, 8, 64, 13);
    if (["regular", "medium", "semibold", "bold", "heavy", "light"].includes(o.weight)) s.weight = o.weight;
    if (["default", "rounded", "serif", "mono"].includes(o.design)) s.design = o.design;
    if (isColor(o.color)) s.color = o.color;
    if (typeof o.lines === "number") s.lines = Math.trunc(clamp(o.lines, 1, 8, 2));
    return s;
  };

  const walk = (v, depth, path) => {
    budget -= 1;
    if (budget < 0) throw new ViewError(`${path}: more than ${maxNodes} views. Show less at once.`);
    if (depth > maxDepth) throw new ViewError(`${path}: views nest more than ${maxDepth} deep.`);
    if (v === null || v === undefined) return { type: "spacer" };
    if (typeof v === "string") return { type: "text", text: clip(v), ...style({}) };
    if (typeof v === "number") return { type: "text", text: format(v), ...style({}) };
    if (typeof v === "boolean") return { type: "text", text: String(v), ...style({}) };
    const kids = (items) => (Array.isArray(items) ? items : []).map((c, i) => walk(c, depth + 1, `${path}.children[${i}]`));
    if (Array.isArray(v)) return { type: "vstack", spacing: 6, align: "leading", children: kids(v) };
    if (typeof v !== "object") return { type: "spacer" };
    const type = typeof v.type === "string" ? v.type : "text";
    if (!types.has(type)) {
      const list = api.views.map((x) => x.type);
      throw new ViewError(`${path}: unknown view type "${type}". Use ${list.slice(0, -1).join(", ")} or ${list.at(-1)}.`);
    }
    switch (type) {
      case "text": return { type, text: clip(asText(v.text ?? v.value)), ...style(v) };
      case "symbol": {
        const name = v.name ?? v.symbol;
        if (!isSymbolName(name)) throw new ViewError(`${path}: a symbol needs a name, like "timer".`);
        return { type, name, ...style(v, { size: 18 }), ...(typeof v.size === "number" ? {} : { size: 18 }) };
      }
      case "ring": return { type, value: clamp(v.value, 0, 1, 0), ...(v.label !== undefined ? { label: clip(asText(v.label)) } : {}), ...(isColor(v.color) ? { color: v.color } : {}), width: clamp(v.width, 2, 14, 6) };
      case "bar": return { type, value: clamp(v.value, 0, 1, 0), ...(v.label !== undefined ? { label: clip(asText(v.label)) } : {}), ...(isColor(v.color) ? { color: v.color } : {}) };
      case "sparkline": {
        const pts = (Array.isArray(v.values) ? v.values : Array.isArray(v.points) ? v.points : []).filter((n) => typeof n === "number" && Number.isFinite(n));
        return { type, values: pts.slice(-maxPoints), ...(isColor(v.color) ? { color: v.color } : {}), fill: typeof v.fill === "boolean" ? v.fill : true };
      }
      case "list": {
        const rows = (Array.isArray(v.items) ? v.items : []).slice(0, maxRows).map((item) => {
          if (typeof item === "string") return { title: clip(item) };
          const row = { title: clip(asText(item?.title)) };
          if (item?.detail !== undefined) row.detail = clip(asText(item.detail));
          if (isSymbolName(item?.symbol)) row.symbol = item.symbol;
          if (isColor(item?.color)) row.color = item.color;
          return row;
        });
        return { type, items: rows };
      }
      case "vstack": case "hstack": case "zstack": case "stack": {
        const axis = type === "stack" ? "vstack" : type;
        const align = ["leading", "center", "trailing", "top", "bottom"].includes(v.align) ? v.align : axis === "hstack" ? "center" : "leading";
        const stack = { type: axis, spacing: clamp(v.spacing, 0, 40, 6), align, children: kids(v.children) };
        if (["fade", "slide", "scale"].includes(v.transition)) stack.transition = v.transition;
        return stack;
      }
      case "spacer": return { type };
      // Interactive and richer views (parseMore in Sources/DockCore/PluginEngine.swift).
      case "button": case "toggle": {
        const action = typeof v.action === "string" && /^[A-Za-z0-9\-_.:]{1,128}$/.test(v.action) ? v.action : null;
        if (type === "button") {
          const title = clip(asText(v.title ?? v.label));
          if (v.symbol !== undefined && !isSymbolName(v.symbol)) throw new ViewError(`${path}: "${v.symbol}" is not an SF Symbol name.`);
          if (!title && v.symbol === undefined) throw new ViewError(`${path}: a button needs a title or a symbol.`);
          if (!action) throw new ViewError(`${path}: a button needs an action: a function, or an id registered with atelier.action.`);
          return { type, title, ...(v.symbol ? { symbol: v.symbol } : {}), style: v.style === "plain" ? "plain" : "prominent", action };
        }
        if (!action) throw new ViewError(`${path}: a toggle needs an action: a function, or an id registered with atelier.action.`);
        return { type, label: clip(asText(v.label ?? v.title)), on: v.on === true, action };
      }
      case "image": {
        const size = (n) => (typeof n === "number" ? clamp(n, 4, 600, 4) : undefined);
        const common = { width: size(v.width), height: size(v.height), fit: v.fit === "fill" ? "fill" : "fit", radius: clamp(v.radius, 0, 60, 0) };
        if (typeof v.asset === "string") {
          const ext = v.asset.split(".").pop().toLowerCase();
          if (v.asset.startsWith("/") || v.asset.split("/").some((p) => p === ".." || p.startsWith(".") || !p) || !["png", "jpg", "jpeg", "heic", "pdf"].includes(ext)) {
            throw new ViewError(`${path}: "${v.asset}" is not an image in the plugin's folder. Use a relative path to a png, jpg, jpeg, heic, pdf file.`);
          }
          return { type, asset: v.asset, ...common };
        }
        if (typeof v.url === "string" && /^https:\/\/[^/]+/.test(v.url)) return { type, url: v.url, ...common };
        throw new ViewError(`${path}: an image needs an asset (a file in the plugin) or an https url.`);
      }
      case "chart": {
        const nums = (x) => (Array.isArray(x) ? x : []).filter((n) => typeof n === "number" && Number.isFinite(n)).slice(-limit("chartValues"));
        let series;
        if (Array.isArray(v.series)) {
          if (v.series.length > limit("chartSeries")) throw new ViewError(`${path}: a chart shows at most ${limit("chartSeries")} series.`);
          series = v.series.map((s) => ({ label: asText(s?.label).slice(0, 40), values: nums(s?.values), ...(isColor(s?.color) ? { color: s.color } : {}) }));
        } else series = [{ label: "", values: nums(v.values), ...(isColor(v.color) ? { color: v.color } : {}) }];
        return { type, kind: ["bar", "line", "area"].includes(v.kind) ? v.kind : "bar", series,
          labels: (Array.isArray(v.labels) ? v.labels : []).slice(0, limit("chartValues")).map((l) => asText(l).slice(0, 24)),
          ...(typeof v.max === "number" && Number.isFinite(v.max) && v.max > 0 ? { max: v.max } : {}) };
      }
      case "grid": return { type, columns: Math.trunc(clamp(v.columns, 1, 6, 2)), children: kids(v.children) };
      case "progress": return { type, value: clamp(v.value, 0, 1, 0), ...(v.label !== undefined ? { label: clip(asText(v.label)) } : {}), ...(isColor(v.color) ? { color: v.color } : {}) };
      case "divider": return { type };
      default: {
        // Views added after this checker was written: keep their keys, walk their children.
        const out = { type };
        for (const [k, x] of Object.entries(v)) if (k !== "children" && k !== "type") out[k] = typeof x === "string" ? clip(x) : x;
        if (Array.isArray(v.children)) out.children = kids(v.children);
        return out;
      }
    }
  };
  return walk(value, 0, "view");
}

/** An indented outline of a normalised tree, for the terminal. */
export function outline(node, indent = "") {
  const q = (s) => JSON.stringify(s);
  const line = (() => {
    switch (node.type) {
      case "text": return `text ${q(node.text)}${node.color ? ` ${node.color}` : ""}${node.size !== 13 ? ` ${node.size}pt` : ""}${node.weight !== "regular" ? ` ${node.weight}` : ""}`;
      case "symbol": return `symbol ${node.name}${node.color ? ` ${node.color}` : ""}`;
      case "ring": case "bar": return `${node.type} ${format(node.value)}${node.label !== undefined ? ` ${q(node.label)}` : ""}${node.color ? ` ${node.color}` : ""}`;
      case "sparkline": return `sparkline ${node.values.length} points${node.color ? ` ${node.color}` : ""}`;
      case "list": return `list ${node.items.length} rows`;
      case "vstack": case "hstack": case "zstack": return `${node.type} (${node.children.length})`;
      default: {
        const keys = Object.entries(node).filter(([k]) => k !== "type" && k !== "children").map(([k, v]) => `${k}=${typeof v === "string" ? q(v) : JSON.stringify(v)}`);
        return `${node.type}${keys.length ? " " + keys.join(" ") : ""}`;
      }
    }
  })();
  let out = indent + line + "\n";
  if (node.type === "list") for (const r of node.items) out += `${indent}  · ${r.title}${r.detail ? `  ${r.detail}` : ""}\n`;
  for (const c of node.children ?? []) out += outline(c, indent + "  ");
  return out;
}
