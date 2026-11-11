// A small Markdown renderer for docs, release notes and mod pages.
// Safe by construction: every character of the source is escaped, and only the HTML this file
// writes reaches the page. Links are limited to http(s), mailto, anchors and relative paths.

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

export function slug(text) {
  return String(text).toLowerCase().replace(/<[^>]+>/g, "").replace(/[`*_~]/g, "")
    .replace(/[^\p{L}\p{N}\s-]/gu, "").trim().replace(/\s/g, "-");
}

function safeURL(url, resolve) {
  const u = String(url).trim();
  if (/^(https?:|mailto:)/i.test(u)) return u;
  if (/^[a-z][a-z0-9+.-]*:/i.test(u)) return null; // javascript:, data: and the rest
  return resolve ? resolve(u) : u;
}

function inline(src, opt) {
  const codes = [];
  let s = src.replace(/(`+)([\s\S]*?[^`])\1(?!`)/g, (_, __, code) => { codes.push(code.trim()); return `\u0000${codes.length - 1}\u0000`; });
  s = esc(s);
  // images, then links: [text](url "title")
  s = s.replace(/!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (m, alt, url) => {
    const u = safeURL(url.replace(/&amp;/g, "&"), opt.resolveImage || opt.resolve);
    return u ? `<img src="${esc(u)}" alt="${alt}" loading="lazy" decoding="async">` : alt;
  });
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^&]*&quot;)?\)/g, (m, text, url) => {
    const u = safeURL(url.replace(/&amp;/g, "&"), opt.resolve);
    if (!u) return text;
    const ext = /^https?:/i.test(u);
    return `<a href="${esc(u)}"${ext ? ' rel="noopener"' : ""}>${text}</a>`;
  });
  s = s.replace(/&lt;(https?:\/\/[^\s&]+)&gt;/g, (m, u) => `<a href="${u}" rel="noopener">${u}</a>`);
  s = s.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>").replace(/__([^_]+)__/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*\w])\*([^*\s][^*]*?)\*(?!\*)/g, "$1<em>$2</em>").replace(/(^|[^_\w])_([^_\s][^_]*?)_(?![_\w])/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~]+)~~/g, "<del>$1</del>");
  s = s.replace(/&lt;br\s*\/?&gt;/gi, "<br>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(codes[+i])}</code>`);
}

function splitRow(line) {
  let l = line.trim();
  if (l.startsWith("|")) l = l.slice(1);
  if (l.endsWith("|") && !l.endsWith("\\|")) l = l.slice(0, -1);
  const cells = []; let cur = "", tick = false;
  for (let i = 0; i < l.length; i++) {
    const c = l[i];
    if (c === "`") tick = !tick;
    if (c === "\\" && l[i + 1] === "|") { cur += "|"; i++; continue; }
    if (c === "|" && !tick) { cells.push(cur.trim()); cur = ""; continue; }
    cur += c;
  }
  cells.push(cur.trim());
  return cells;
}

/**
 * render(markdown, { resolve(url) → url, resolveImage, headingOffset, toc: [] })
 * Fills opt.toc with { level, text, id } for h2 and h3.
 */
export function render(md, opt = {}) {
  const lines = String(md ?? "").replace(/\r\n?/g, "\n").split("\n");
  const out = [], used = new Map(), off = opt.headingOffset ?? 0;
  let i = 0;
  const id = (text) => { let b = slug(text) || "section"; const n = used.get(b) ?? 0; used.set(b, n + 1); return n ? `${b}-${n}` : b; };
  const isBlockStart = (l) => /^(#{1,6})\s/.test(l) || /^```/.test(l) || /^\s*([-*+]|\d+[.)])\s+/.test(l) || /^>\s?/.test(l) || /^(\s*[-*_]){3,}\s*$/.test(l) || /^\s*\|/.test(l);

  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim()) { i++; continue; }

    let m;
    if ((m = /^```\s*([\w+-]*)/.exec(line))) {
      const lang = m[1], buf = []; i++;
      while (i < lines.length && !/^```/.test(lines[i])) buf.push(lines[i++]);
      i++;
      out.push(`<div class="code"><pre${lang ? ` data-lang="${esc(lang)}"` : ""}><code>${esc(buf.join("\n"))}</code></pre><button class="copy" type="button" aria-label="Copy code">Copy</button></div>`);
      continue;
    }
    if ((m = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(line))) {
      const level = Math.min(6, m[1].length + off), text = m[2], hid = id(text.replace(/\[([^\]]+)\]\([^)]*\)/g, "$1"));
      if (opt.toc && (level === 2 || level === 3)) opt.toc.push({ level, text: text.replace(/[`*]/g, "").replace(/\[([^\]]+)\]\([^)]*\)/g, "$1"), id: hid });
      out.push(`<h${level} id="${hid}"><a class="anchor" href="#${hid}" aria-hidden="true" tabindex="-1">#</a>${inline(text, opt)}</h${level}>`);
      i++; continue;
    }
    if (/^(\s*[-*_]){3,}\s*$/.test(line)) { out.push("<hr>"); i++; continue; }
    if (/^\s*\|/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      const head = splitRow(line), aligns = splitRow(lines[i + 1]).map((c) => (/^:-+:$/.test(c) ? "center" : /-+:$/.test(c) ? "right" : ""));
      i += 2;
      const rows = [];
      while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(splitRow(lines[i++]));
      const al = (k) => (aligns[k] ? ` style="text-align:${aligns[k]}"` : "");
      out.push(`<div class="table"><table><thead><tr>${head.map((c, k) => `<th${al(k)}>${inline(c, opt)}</th>`).join("")}</tr></thead><tbody>${rows.map((r) => `<tr>${head.map((_, k) => `<td${al(k)}>${inline(r[k] ?? "", opt)}</td>`).join("")}</tr>`).join("")}</tbody></table></div>`);
      continue;
    }
    if (/^>\s?/.test(line)) {
      const buf = [];
      while (i < lines.length && /^>\s?/.test(lines[i])) buf.push(lines[i++].replace(/^>\s?/, ""));
      out.push(`<blockquote>${render(buf.join("\n"), { ...opt, toc: null })}</blockquote>`);
      continue;
    }
    if (/^\s*([-*+]|\d+[.)])\s+/.test(line)) {
      // Lists, nested by indentation.
      const stack = [];
      const open = (indent, ordered) => { stack.push({ indent, ordered }); out.push(ordered ? "<ol>" : "<ul>"); };
      const close = () => { const s = stack.pop(); out.push("</li>", s.ordered ? "</ol>" : "</ul>"); };
      let first = true;
      while (i < lines.length) {
        const l = lines[i];
        const lm = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/.exec(l);
        if (!lm) {
          if (l.trim() && /^\s{2,}/.test(l) && stack.length) { out.push(" " + inline(l.trim(), opt)); i++; continue; }
          if (!l.trim() && i + 1 < lines.length && /^(\s*)([-*+]|\d+[.)])\s+/.test(lines[i + 1])) { i++; continue; }
          break;
        }
        const indent = lm[1].length, ordered = /\d/.test(lm[2]);
        if (first || indent > stack[stack.length - 1].indent) { open(indent, ordered); first = false; }
        else {
          while (stack.length > 1 && indent < stack[stack.length - 1].indent) close();
          out.push("</li>");
        }
        let text = lm[3];
        const task = /^\[([ xX])\]\s+/.exec(text);
        if (task) text = text.slice(task[0].length);
        out.push(`<li${task ? ' class="task"' : ""}>${task ? `<span class="check${task[1] !== " " ? " on" : ""}" aria-hidden="true"></span>` : ""}${inline(text, opt)}`);
        i++;
      }
      while (stack.length) close();
      continue;
    }
    const buf = [];
    while (i < lines.length && lines[i].trim() && !(buf.length && isBlockStart(lines[i]))) buf.push(lines[i++].trim());
    out.push(`<p>${inline(buf.join(" "), opt)}</p>`);
  }
  return out.join("");
}

export { esc };
