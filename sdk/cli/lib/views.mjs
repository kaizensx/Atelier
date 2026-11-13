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
        return { type: axis, spacing: clamp(v.spacing, 0, 40, 6), align, children: kids(v.children) };
      }
      case "spacer": return { type };
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
