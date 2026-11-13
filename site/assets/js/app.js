// Atelier website. Vanilla JS, no dependencies. Pages read site/data/*.json, built at deploy
// time by site/scripts/build-data.mjs; everything degrades to an empty state when data is missing.

const REPO = "kaizensx/Atelier";
const GH = `https://github.com/${REPO}`;
const MODS_REPO = "kaizensx/atelier-mods";
const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;

/* ---------- icons (1.5 px strokes) ---------- */
const P = (d, extra = "") => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${d}</svg>`;
export const icon = {
  arrow: P('<path d="M7 17 17 7M9 7h8v8"/>'),
  right: P('<path d="M5 12h14M13 6l6 6-6 6"/>'),
  down: P('<path d="M12 4v12M6 11l6 6 6-6M5 20h14"/>'),
  search: P('<circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/>'),
  info: P('<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>'),
  star: P('<path d="m12 3.5 2.6 5.3 5.9.9-4.3 4.1 1 5.8L12 16.9l-5.2 2.7 1-5.8L3.5 9.7l5.9-.9z"/>'),
  bell: P('<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 20a2 2 0 0 0 4 0"/>'),
  globe: P('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.5 3 2.5 15 0 18M12 3c-2.5 3-2.5 15 0 18"/>'),
  link: P('<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1"/>'),
  palette: P('<path d="M12 3a9 9 0 1 0 0 18c1.1 0 1.6-.9 1.2-1.8-.5-1.1.2-2.2 1.4-2.2H17a4 4 0 0 0 4-4c0-5.5-4-10-9-10z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10.5" cy="7.5" r="1"/><circle cx="15" cy="7.5" r="1"/>'),
  bug: P('<rect x="7" y="8" width="10" height="12" rx="5"/><path d="M12 8v12M7 13H3M21 13h-4M8 6l1.5 2M16 6l-1.5 2M5 8l2 2M19 8l-2 2M5 19l2-2M19 19l-2-2"/>'),
  bulb: P('<path d="M9 18h6M10 21h4M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3z"/>'),
  chat: P('<path d="M4 5h16v11H9l-5 4z"/>'),
  comment: P('<path d="M5 5h14v10H10l-4 3v-3H5z"/>'),
  shield: P('<path d="M12 3 19 6v6c0 4.5-3 7.5-7 9-4-1.5-7-4.5-7-9V6z"/><path d="m9 12 2 2 4-4"/>'),
  toggle: P('<rect x="3" y="7" width="18" height="10" rx="5"/><circle cx="8" cy="12" r="2.5"/>'),
  eye: P('<path d="M2.5 12S6 5.5 12 5.5 21.5 12 21.5 12 18 18.5 12 18.5 2.5 12 2.5 12z"/><circle cx="12" cy="12" r="2.5"/>'),
  key: P('<circle cx="8" cy="15" r="4"/><path d="m11 12 8-8M16 7l2 2M14 9l2 2"/>'),
  undo: P('<path d="M9 14 4 9l5-5"/><path d="M4 9h10a6 6 0 0 1 0 12h-3"/>'),
  github: '<svg viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0 0 16 8c0-4.42-3.58-8-8-8z"/></svg>',
  box: P('<path d="M3.5 7.5 12 3l8.5 4.5v9L12 21l-8.5-4.5z"/><path d="M3.5 7.5 12 12l8.5-4.5M12 12v9"/>'),
  plug: P('<path d="M9 3v5M15 3v5M6 8h12v3a6 6 0 0 1-12 0zM12 17v4"/>'),
  chip: P('<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>'),
  doc: P('<path d="M6 3h8l4 4v14H6z"/><path d="M14 3v4h4M9 12h6M9 16h6"/>'),
  tag: P('<path d="M3 12V4h8l9 9-8 8z"/><circle cx="7.5" cy="8.5" r="1.2"/>'),
  users: P('<circle cx="9" cy="8" r="3.5"/><path d="M2.5 20a6.5 6.5 0 0 1 13 0M16 4.5a3.5 3.5 0 0 1 0 7M18 14a6 6 0 0 1 3.5 6"/>'),
  thumb: P('<path d="M7 11v9H4v-9zM7 11l4-7c1.5 0 2.5 1 2.2 2.6L12.6 10H19a2 2 0 0 1 2 2.3l-1.2 6A2 2 0 0 1 17.8 20H7"/>'),
};

/* ---------- helpers ---------- */
export const $ = (s, r = document) => r.querySelector(s);
export const $$ = (s, r = document) => [...r.querySelectorAll(s)];
export const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const nf = new Intl.NumberFormat("en", { notation: "compact", maximumFractionDigits: 1 });
const nfull = new Intl.NumberFormat("en");
export const num = (n) => (n == null ? "" : n < 10000 ? nfull.format(n) : nf.format(n));
export const bytes = (b) => (b == null ? "" : b < 1024 ? `${b} B` : b < 1048576 ? `${(b / 1024).toFixed(0)} KB` : `${(b / 1048576).toFixed(1)} MB`);
const df = new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric" });
export const date = (iso) => (iso ? df.format(new Date(iso)) : "");
const rtf = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
export function ago(iso) {
  if (!iso) return "";
  const s = (new Date(iso) - Date.now()) / 1000;
  const units = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]];
  for (const [u, d] of units) if (Math.abs(s) >= d) return rtf.format(Math.round(s / d), u);
  return "just now";
}
const avatar = (login, size = 64) => `https://github.com/${encodeURIComponent(login)}.png?size=${size}`;
export const ver = (tag) => String(tag ?? "").replace(/^v/, "");

const cache = new Map();
export function data(name) {
  if (!cache.has(name)) {
    cache.set(name, fetch(`data/${name}`, { cache: "no-cache" }).then((r) => (r.ok ? (name.endsWith(".md") ? r.text() : r.json()) : null)).catch(() => null));
  }
  return cache.get(name);
}

/** Where the Mods catalog is published (the same signed index Atelier reads). */
const MODS_INDEX = "https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/index.json";
let catalogPromise;

/** The Mods catalog: the newer of the site's copy and the published index, read straight from
 *  GitHub so a new version shows without waiting for the site to rebuild. The bundled seed only
 *  when neither can be reached. */
export function catalog() {
  catalogPromise ??= (async () => {
    const usable = (c) => (c && Array.isArray(c.mods) ? c : null);
    const [copy, published] = await Promise.all([
      data("mods.json").then(usable),
      fetch(MODS_INDEX, { cache: "no-cache" }).then((r) => (r.ok ? r.json() : null)).then(usable).catch(() => null),
    ]);
    const newest = [copy, published].filter(Boolean).sort((a, b) => String(b.generated || "").localeCompare(String(a.generated || "")))[0];
    if (newest) return { ...newest, seed: false };
    const seed = await data("mods-seed.json");
    return seed ? { ...seed, seed: true } : { mods: [], featured: [], seed: true };
  })();
  return catalogPromise;
}

/** Repo stats, falling back once to the live API when the build had none. */
async function stats() {
  const built = await data("repo.json");
  if (built?.ok) return built;
  try {
    const key = "atelier-live-stats";
    const hit = JSON.parse(sessionStorage.getItem(key) || "null");
    if (hit && Date.now() - hit.t < 600000) return hit.v;
    const [repo, rels] = await Promise.all([
      fetch(`https://api.github.com/repos/${REPO}`).then((r) => (r.ok ? r.json() : null)),
      fetch(`https://api.github.com/repos/${REPO}/releases?per_page=30`).then((r) => (r.ok ? r.json() : [])),
    ]);
    if (!repo) return built;
    const list = rels.filter((r) => !r.draft);
    const stable = list.find((r) => !r.prerelease), beta = list.find((r) => r.prerelease);
    const v = {
      ok: true, live: true,
      repo: { stars: repo.stargazers_count, forks: repo.forks_count, url: repo.html_url },
      openIssues: null, contributors: null,
      downloads: list.length ? list.reduce((n, r) => n + r.assets.filter((a) => a.name.endsWith(".zip")).reduce((m, a) => m + a.download_count, 0), 0) : null,
      latestStable: stable && { tag: stable.tag_name, published: stable.published_at },
      latestBeta: beta && (!stable || beta.published_at > stable.published_at) ? { tag: beta.tag_name, published: beta.published_at } : null,
    };
    try { sessionStorage.setItem(key, JSON.stringify({ t: Date.now(), v })); } catch {}
    return v;
  } catch { return built; }
}

/* ---------- reveal on scroll ---------- */
let ioAlive = false;
const io = "IntersectionObserver" in window ? new IntersectionObserver((entries) => {
  ioAlive = true;
  for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
}, { rootMargin: "0px 0px -8% 0px", threshold: 0.08 }) : null;
export function reveal(root = document) {
  $$("[data-reveal]:not(.in)", root).forEach((el, i) => {
    if (!io) { el.classList.add("in"); return; }
    if (el.dataset.stagger != null) el.style.setProperty("--d", `${Math.min(i, 8) * 60}ms`);
    io.observe(el);
  });
  // Never leave content hidden if the observer cannot report (an embedded or throttled view).
  if (io) setTimeout(() => { if (!ioAlive) $$("[data-reveal]").forEach((el) => el.classList.add("in")); }, 2500);
}

/* ---------- shell: menu, copy buttons, current page ---------- */
function shell() {
  const body = document.body;
  const btn = $(".menu-btn");
  const set = (open) => { body.dataset.menu = open ? "open" : ""; btn?.setAttribute("aria-expanded", String(open)); document.documentElement.style.overflow = open ? "hidden" : ""; };
  btn?.addEventListener("click", () => set(body.dataset.menu !== "open"));
  $$(".sheet a").forEach((a) => a.addEventListener("click", () => set(false)));
  addEventListener("keydown", (e) => { if (e.key === "Escape" && body.dataset.menu === "open") { set(false); btn?.focus(); } });
  matchMedia("(min-width: 861px)").addEventListener("change", (e) => e.matches && set(false));

  document.addEventListener("click", async (e) => {
    const b = e.target.closest(".copy, [data-copy]");
    if (!b) return;
    const text = b.dataset.copy ?? b.parentElement.querySelector("code")?.textContent ?? "";
    try { await navigator.clipboard.writeText(text); const old = b.textContent; b.textContent = "Copied"; setTimeout(() => (b.textContent = old), 1400); } catch {}
  });
  const y = $("[data-year]"); if (y) y.textContent = new Date().getFullYear();
}

/* ---------- shared renderers ---------- */
const kindLabel = { plugin: "Plugin", theme: "Theme", native: "Native", icons: "Icons", sounds: "Sounds", shader: "Shader", layouts: "Layouts", effects: "Effects", look: "Look" };
/** "1.2k installs", the same rounding as Atelier: never above the real count. */
export function installs(n) {
  if (n == null) return "";
  const short = n < 1000 ? String(n) : n < 10000 ? `${(Math.floor(n / 100) / 10).toString()}k` : n < 1e6 ? `${Math.floor(n / 1000)}k` : `${(Math.floor(n / 1e5) / 10).toString()}M`;
  return n === 1 ? "1 install" : `${short} installs`;
}
const modStats = (m) => [
  m.downloads > 0 ? `<span class="mstat" title="Installs from the catalog">${icon.down}${esc(installs(m.downloads))}</span>` : "",
  m.likes > 0 ? `<span class="mstat" title="Likes on GitHub">${icon.thumb}${esc(installs(m.likes).replace(/ installs?$/, ""))}</span>` : "",
].join("");
const authorName = (m) => (m.author && typeof m.author === "object" ? m.author.name : m.author) || m.github || "";
const permInfo = {
  network: { name: "Network", text: "Reaches only the hosts it lists, over https.", icon: icon.globe },
  notifications: { name: "Notifications", text: "Posts notifications in Notification Center.", icon: icon.bell },
  openURL: { name: "Open links", text: "Opens https and mailto links.", icon: icon.link },
  appearance: { name: "Appearance", text: "Applies theme changes. Revert in Looks undoes them.", icon: icon.palette },
};
const imgURL = (s) => s?.url || "";

export function modCard(m, { featured = false } = {}) {
  const shot = m.screenshots?.[0];
  const perms = m.permissions?.length
    ? m.permissions.map((p) => `<span class="chip">${permInfo[p]?.icon ?? ""}${esc(permInfo[p]?.name ?? p)}</span>`).join("")
    : `<span class="chip none">No permissions</span>`;
  return `<a class="mod shell" href="mod.html?id=${encodeURIComponent(m.id)}" data-reveal data-stagger>
    <div class="core">
      <div class="pic">${shot ? `<img src="${esc(imgURL(shot))}" alt="${esc(shot.caption || m.name)}" width="${shot.width || 1280}" height="${shot.height || 800}" loading="lazy" decoding="async">` : ""}
        <div class="badges"><span class="badge ${esc(m.kind)}">${esc(kindLabel[m.kind] ?? m.kind)}</span>${featured ? '<span class="badge feat">Featured</span>' : ""}</div>
      </div>
      <div class="body">
        <h3>${esc(m.name)}</h3>
        <p class="sum">${esc(m.summary)}</p>
        <div class="chips">${perms}</div>
        <div class="foot">
          <span class="who">${m.github ? `<img class="avatar" src="${avatar(m.github, 44)}" alt="" width="22" height="22" loading="lazy">` : ""}<span>${esc(authorName(m))}</span></span>
          ${modStats(m)}
          <span class="v">v${esc(m.version)}</span>
        </div>
      </div>
    </div>
  </a>`;
}

export function empty(glyph, title, text, actions = "") {
  return `<div class="empty" data-reveal><div class="glyph">${glyph}</div><h3>${title}</h3><p>${text}</p>${actions ? `<div class="btns">${actions}</div>` : ""}</div>`;
}
const btn = (href, label, cls = "", ic = icon.arrow) => `<a class="btn ${cls}" href="${esc(href)}"${/^https?:/.test(href) ? ' rel="noopener"' : ""}>${label}<span class="ico">${ic}</span></a>`;

/* ---------- pages ---------- */
const pages = {};

pages.home = async () => {
  const s = await stats();
  const set = (k, v, sub) => {
    const el = $(`[data-stat="${k}"]`);
    if (!el) return;
    if (v == null || v === "") { el.textContent = sub ?? "Not yet"; el.classList.add("none"); }
    else { el.textContent = v; el.classList.remove("none"); }
  };
  set("stable", s?.latestStable ? ver(s.latestStable.tag) : null, "After beta");
  set("beta", s?.latestBeta ? ver(s.latestBeta.tag) : null, s?.latestStable ? "None newer" : "Soon");
  set("downloads", s?.downloads != null ? num(s.downloads) : null, "Soon");
  set("stars", s?.repo ? num(s.repo.stars) : null, "Star it");
  set("contributors", s?.contributors != null ? num(s.contributors) : null, "Join in");
  set("issues", s?.openIssues != null ? num(s.openIssues) : null, "None yet");
  const starN = $("[data-stars]"); if (starN && s?.repo) starN.textContent = num(s.repo.stars);

  const cat = await catalog();
  const box = $("[data-featured]");
  if (box) {
    const ids = cat.featured?.length ? cat.featured : cat.mods.map((m) => m.id);
    const list = ids.map((id) => cat.mods.find((m) => m.id === id)).filter(Boolean).slice(0, 3);
    box.innerHTML = list.length ? list.map((m) => modCard(m, { featured: true })).join("") : empty(icon.box, "The catalog is loading", "Plugins and themes from the community, shared on GitHub.");
    reveal(box);
  }
  const people = await data("contributors.json");
  const faces = $("[data-faces]");
  if (faces && people?.contributors?.length) {
    faces.innerHTML = people.contributors.slice(0, 18).map((c) => `<a href="${esc(c.url)}" title="${esc(c.login)}"><img src="${esc(c.avatar)}&s=80" alt="${esc(c.login)}" width="40" height="40" loading="lazy"></a>`).join("");
  }
};

pages.mods = async () => {
  const cat = await catalog();
  const grid = $("[data-grid]"), count = $("[data-count]"), input = $("#q");
  const params = new URLSearchParams(location.search);
  let kind = params.get("kind") || "all", q = params.get("q") || "";
  const author = (params.get("author") || "").toLowerCase();
  if (input) input.value = q;
  if (cat.seed) $("[data-seed]")?.removeAttribute("hidden");
  // An author's page: mods.html?author=<github handle>.
  const pool = author ? cat.mods.filter((m) => (m.github || "").toLowerCase() === author) : cat.mods;
  const head = $("[data-author]");
  if (author && head) {
    const listed = (cat.authors ?? []).find((a) => a.github.toLowerCase() === author);
    const handle = listed?.github ?? pool[0]?.github ?? author;
    const name = listed?.name ?? (pool[0] ? authorName(pool[0]) : handle);
    const total = pool.reduce((n, m) => n + (m.downloads ?? 0), 0);
    const site = listed?.url ?? pool.find((m) => m.authorURL)?.authorURL;
    document.title = `${name} · Atelier Mods`;
    head.innerHTML = `<img class="avatar" src="${avatar(handle, 112)}" alt="" width="56" height="56">
      <div style="display:grid;gap:4px;flex:1;min-width:0"><h2>${esc(name)}</h2><span class="faint small">@${esc(handle)} · ${pool.length} ${pool.length === 1 ? "mod" : "mods"}${total ? ` · ${esc(installs(total))}` : ""}</span></div>
      <div class="btns">${btn(`https://github.com/${encodeURIComponent(handle)}`, "GitHub", "ghost sm")}${site && /^https:/.test(site) ? btn(site, "Website", "ghost sm") : ""}${btn("mods.html", "All mods", "ghost sm", icon.right)}</div>`;
    head.removeAttribute("hidden");
  }
  const counts = { all: pool.length, plugin: 0, theme: 0, native: 0 };
  pool.forEach((m) => (counts[m.kind] = (counts[m.kind] ?? 0) + 1));
  $$(".seg button").forEach((b) => { const n = b.querySelector(".n"); if (n) n.textContent = counts[b.dataset.kind] ?? 0; });

  const draw = () => {
    $$(".seg button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.kind === kind)));
    const words = q.toLowerCase().split(/\s+/).filter(Boolean);
    const list = pool.filter((m) => (kind === "all" || m.kind === kind) &&
      words.every((w) => [m.name, m.summary, authorName(m), m.github, m.id, ...(m.tags ?? [])].join(" ").toLowerCase().includes(w)))
      .sort((a, b) => (cat.featured?.includes(b.id) - cat.featured?.includes(a.id)) || a.name.localeCompare(b.name));
    count.textContent = `${list.length} ${list.length === 1 ? "mod" : "mods"}`;
    // Featured this week and the collections, on the plain gallery only.
    const shelves = $("[data-shelves]");
    if (shelves) {
      const plain = !author && !q && kind === "all";
      const byId = (id) => cat.mods.find((m) => m.id === id);
      const featured = (cat.featured ?? []).map(byId).filter(Boolean);
      const shelf = (title, note, mods, feat = false) => mods.length ? `<div class="shelf-head" data-reveal><h2>${esc(title)}</h2>${note ? `<p>${esc(note)}</p>` : ""}</div><div class="shelf">${mods.map((m) => modCard(m, { featured: feat })).join("")}</div>` : "";
      shelves.innerHTML = plain
        ? shelf("Featured this week", cat.featuredNote, featured, true) + (cat.collections ?? []).map((c) => shelf(c.title, c.description, (c.mods ?? []).map(byId).filter(Boolean))).join("")
          + (featured.length || cat.collections?.length ? `<div class="shelf-head"><h2>All mods</h2></div>` : "")
        : "";
      reveal(shelves);
    }
    if (list.length) grid.innerHTML = list.map((m) => modCard(m, { featured: cat.featured?.includes(m.id) })).join("");
    else if (kind === "native" && !q) grid.innerHTML = empty(icon.chip, "No native mods yet", "Native mods run inside the Dock through the Dock Bridge. They are reviewed by a maintainer, source and all, before they are listed.", btn(`https://github.com/${MODS_REPO}/blob/main/native/README.md`, "How native mods work", "ghost"));
    else grid.innerHTML = empty(icon.search, "Nothing matches", q ? `No mod matches “${esc(q)}”. Try a shorter word, or another kind.` : "No mods of this kind yet. Yours could be the first.", btn("#submit", "Submit a mod", "ghost", icon.right));
    reveal(grid);
    const url = new URL(location.href);
    kind === "all" ? url.searchParams.delete("kind") : url.searchParams.set("kind", kind);
    q ? url.searchParams.set("q", q) : url.searchParams.delete("q");
    author ? url.searchParams.set("author", author) : url.searchParams.delete("author");
    history.replaceState(null, "", url);
  };
  $$(".seg button").forEach((b) => b.addEventListener("click", () => { kind = b.dataset.kind; draw(); }));
  input?.addEventListener("input", () => { q = input.value.trim(); draw(); });
  addEventListener("keydown", (e) => { if (e.key === "/" && document.activeElement !== input && !e.metaKey) { e.preventDefault(); input?.focus(); } });
  draw();
};

pages.mod = async () => {
  const { render } = await import("./md.js");
  const id = new URLSearchParams(location.search).get("id");
  const cat = await catalog();
  const m = cat.mods.find((x) => x.id === id);
  const root = $("[data-detail]");
  if (!m) {
    root.innerHTML = empty(icon.box, "This mod is not in the catalog", "It may have been renamed or removed. Every mod that is listed is in the gallery.", btn("mods.html", "Browse mods", "ghost", icon.right));
    reveal(root); return;
  }
  document.title = `${m.name} · Atelier Mods`;
  const shots = m.screenshots ?? [];
  const resolve = (u) => (u.startsWith("#") ? u : `https://github.com/${MODS_REPO}/blob/main/${m.kind === "native" ? "native" : "mods"}/${m.id}/${u.replace(/^\.\//, "")}`);
  const desc = render(String(m.description || m.summary).replace(/^\s*#\s+.*\n/, ""), { resolve, headingOffset: 1 });
  const install = `atelier://mods?install=${encodeURIComponent(m.id)}`;
  const perms = (m.permissions ?? []).map((p) => `<div class="permrow"><span class="ic">${permInfo[p]?.icon ?? icon.key}</span><div><b>${esc(permInfo[p]?.name ?? p)}</b><span>${esc(permInfo[p]?.text ?? "")}${p === "network" && m.hosts?.length ? ` ${m.hosts.map((h) => `<code>${esc(h)}</code>`).join(", ")}` : ""}</span></div></div>`).join("")
    || `<div class="permrow"><span class="ic">${icon.shield}</span><div><b>No permissions</b><span>${m.kind === "theme" ? "A theme is data: it changes how things look and runs no code." : "It runs in its own sandbox and asks for nothing."}</span></div></div>`;
  const versions = (m.versions ?? []).map((v) => `<li><div class="vh"><b>v${esc(v.version)}</b><span>${date(v.date)}</span></div>${v.notes ? `<p>${esc(v.notes)}</p>` : ""}</li>`).join("");

  root.innerHTML = `
    <nav class="crumbs" aria-label="Breadcrumb"><a href="mods.html">Mods</a><span aria-hidden="true">/</span><span>${esc(m.name)}</span></nav>
    <div class="detail">
      <div style="display:grid;gap:28px;min-width:0">
        <header style="display:grid;gap:16px" data-reveal>
          <div class="chips"><span class="badge ${esc(m.kind)}">${esc(kindLabel[m.kind] ?? m.kind)}</span>${cat.featured?.includes(m.id) ? '<span class="badge feat">Featured</span>' : ""}${(m.tags ?? []).map((t) => `<span class="chip">${esc(t)}</span>`).join("")}</div>
          <h1 class="h2">${esc(m.name)}</h1>
          <p class="lead">${esc(m.summary)}</p>
          <a class="btn m-only" href="${esc(install)}" style="justify-self:start">Open in Atelier<span class="ico">${icon.arrow}</span></a>
          <a class="who" href="mods.html?author=${encodeURIComponent(m.github)}"><img class="avatar" src="${avatar(m.github, 56)}" alt="" width="28" height="28" style="width:28px;height:28px"><span>${esc(authorName(m))} <span class="faint">@${esc(m.github)} · all their mods</span></span></a>
          ${m.downloads > 0 || m.likes > 0 ? `<div class="chips faint small" style="gap:14px">${modStats(m)}</div>` : ""}
        </header>
        ${shots.length ? `<figure class="gallery shell" style="margin:0" data-reveal><div class="core"><img class="main" src="${esc(imgURL(shots[0]))}" alt="${esc(shots[0].caption || m.name)}" width="${shots[0].width || 1280}" height="${shots[0].height || 800}"><figcaption>${esc(shots[0].caption || "")}</figcaption></div></figure>
          ${shots.length > 1 ? `<div class="thumbs">${shots.map((s, i) => `<button type="button" aria-pressed="${i === 0}" aria-label="Screenshot ${i + 1}" data-i="${i}"><img src="${esc(imgURL(s))}" alt="" loading="lazy"></button>`).join("")}</div>` : ""}` : ""}
        <article class="prose" data-reveal>${desc}</article>
      </div>
      <aside>
        <div class="shell" data-reveal><div class="core card" style="display:grid;gap:14px">
          <a class="btn" href="${esc(install)}" style="justify-content:space-between">Open in Atelier<span class="ico">${icon.arrow}</span></a>
          <p class="small faint">Atelier shows what the mod asks for and installs it only after you confirm. Open it from the Mods chapter.</p>
          <div class="btns">
            ${m.package?.url ? `<a class="btn ghost sm" href="${esc(m.package.url)}" rel="noopener">Download<span class="ico">${icon.down}</span></a>` : ""}
            ${m.homepage ? `<a class="btn ghost sm" href="${esc(m.homepage)}" rel="noopener">Source<span class="ico">${icon.arrow}</span></a>` : ""}
            ${m.discussion && /^https:\/\/github\.com\//.test(m.discussion) ? `<a class="btn ghost sm" href="${esc(m.discussion)}" rel="noopener">Discuss on GitHub<span class="ico">${icon.chat}</span></a>` : ""}
          </div>
        </div></div>
        <div class="shell" data-reveal><div class="core card"><h2 class="small faint" style="margin-bottom:6px;font-weight:600;letter-spacing:.1em;text-transform:uppercase">Asks for</h2>${perms}</div></div>
        <div class="shell" data-reveal><div class="core card">
          <dl class="kv">
            <dt>Version</dt><dd>v${esc(m.version)}</dd>
            <dt>Signed</dt><dd>${m.authorKey && m.packageSignature ? "By the author and the catalog" : "By the catalog"}</dd>
            ${m.downloads != null ? `<dt>Installs</dt><dd>${esc(num(m.downloads))}</dd>` : ""}
            ${m.likes != null ? `<dt>Likes</dt><dd>${esc(num(m.likes))}</dd>` : ""}
            <dt>Updated</dt><dd>${date(m.updated)}</dd>
            ${m.minAtelier ? `<dt>Needs</dt><dd>Atelier ${esc(m.minAtelier)}+</dd>` : ""}
            <dt>Licence</dt><dd>${esc(m.license || "")}</dd>
            <dt>Id</dt><dd><code class="hash">${esc(m.id)}</code></dd>
          </dl>
          ${m.package?.sha256 ? `<p class="hash" style="margin-top:14px">SHA-256 ${esc(m.package.sha256)}</p>` : ""}
        </div></div>
        ${versions ? `<div class="shell" data-reveal><div class="core card"><h2 class="small faint" style="font-weight:600;letter-spacing:.1em;text-transform:uppercase">Version history</h2><ul class="versions">${versions}</ul></div></div>` : ""}
      </aside>
    </div>`;
  $$(".thumbs button", root).forEach((b) => b.addEventListener("click", () => {
    const s = shots[+b.dataset.i], main = $(".gallery .main", root);
    main.src = imgURL(s); main.alt = s.caption || m.name; $(".gallery figcaption", root).textContent = s.caption || "";
    $$(".thumbs button", root).forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
  }));
  reveal(root);
};

pages.releases = async () => {
  const { render } = await import("./md.js");
  const d = await data("releases.json");
  const root = $("[data-releases]");
  const list = d?.releases ?? [];
  const resolve = (u) => (u.startsWith("#") ? u : `${GH}/blob/main/${u.replace(/^\.\//, "")}`);
  if (!list.length) {
    $("[data-channel]")?.setAttribute("hidden", "");
    const [log, v] = await Promise.all([data("docs/changelog.md"), data("version.json")]);
    const next = log ? (/^## \[[^\]]+\][\s\S]*?(?=^## \[|(?![\s\S]))/m.exec(log)?.[0] ?? "") : "";
    const title = /^## \[([^\]]+)\]/.exec(next)?.[1] ?? v?.version;
    root.innerHTML = empty(icon.tag, "The first release is on its way", "Releases appear here as soon as they are published on GitHub: notes, downloads, sizes and checksums.", btn(`${GH}/releases`, "Releases on GitHub", "ghost"))
      + (next ? `<div class="timeline" style="margin-top:24px"><article class="rel beta" data-reveal><span class="pin"></span><div class="shell"><div class="core card">
          <div class="rel-top"><h2>${esc(title)}</h2><span class="badge beta">Next up</span><time>From CHANGELOG.md</time></div>
          <div class="prose">${render(next.replace(/^## .*\n/, ""), { resolve, headingOffset: 2 })}</div></div></div></article></div>` : "");
    reveal(root); return;
  }
  let filter = "all";
  const draw = () => {
    $$(".seg button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.kind === filter)));
    const shown = list.filter((r) => filter === "all" || (filter === "beta") === r.prerelease);
    root.innerHTML = shown.length ? `<div class="timeline">${shown.map((r, i) => {
      const zip = r.assets.find((a) => a.name.endsWith(".zip"));
      const notes = render(r.body, { resolve, headingOffset: 2 });
      const rows = r.assets.map((a) => `<tr><td>${esc(a.name)}</td><td>${bytes(a.size)}</td><td>${num(a.downloads)}</td><td class="sha-cell">${a.sha256 ? `<span class="sha"><span title="${esc(a.sha256)}">${esc(a.sha256.slice(0, 12))}…</span><button type="button" data-copy="${esc(a.sha256)}">Copy</button></span>` : '<span class="faint">—</span>'}</td><td><a class="dl" href="${esc(a.url)}">Download</a></td></tr>`).join("");
      return `<article class="rel ${r.prerelease ? "beta" : "stable"}" id="${esc(r.tag)}" data-reveal><span class="pin"></span><div class="shell"><div class="core card">
        <div class="rel-top"><h2>${esc(ver(r.tag))}</h2><span class="badge ${r.prerelease ? "beta" : "stable"}">${r.prerelease ? "Beta" : "Stable"}</span><time datetime="${esc(r.published)}">${date(r.published)} · ${ago(r.published)}</time>
          <div class="btns">${zip ? `<a class="btn sm" href="${esc(zip.url)}">Download<span class="ico">${icon.down}</span></a>` : ""}<a class="btn ghost sm" href="${esc(r.url)}" rel="noopener">GitHub<span class="ico">${icon.arrow}</span></a></div></div>
        ${r.name && r.name !== r.tag ? `<p class="muted">${esc(r.name)}</p>` : ""}
        ${i === 0 ? `<div class="prose">${notes}</div>` : `<details class="more-notes"><summary>Release notes</summary><div class="prose" style="margin-top:14px">${notes}</div></details>`}
        ${rows ? `<table class="assets"><thead><tr><th>Asset</th><th>Size</th><th>Downloads</th><th>SHA-256</th><th></th></tr></thead><tbody>${rows}</tbody></table>` : ""}
      </div></div></article>`;
    }).join("")}</div>` : empty(icon.tag, filter === "beta" ? "No betas right now" : "No stable release yet", filter === "beta" ? "Every release starts as a beta. The next one will show up here." : "Stable follows once a beta has run well on real Macs. Until then, the beta is the newest Atelier.");
    reveal(root);
  };
  $$(".seg button").forEach((b) => b.addEventListener("click", () => { filter = b.dataset.kind; draw(); }));
  draw();
};

pages.community = async () => {
  const [iss, ppl, repo] = await Promise.all([data("issues.json"), data("contributors.json"), data("repo.json")]);
  const issues = iss?.issues ?? [];
  const has = (i, name) => i.labels.some((l) => l.name.toLowerCase() === name);
  const prio = (i) => i.labels.find((l) => /^p[0-3]$/i.test(l.name))?.name.toUpperCase();
  const areaOf = (i) => i.labels.find((l) => l.name.startsWith("area:"))?.name.slice(5).trim();
  const row = (i) => `<a class="issue" href="${esc(i.url)}" rel="noopener">
      <span class="no">#${i.number}</span><span class="t">${esc(i.title)}</span>
      <span class="side">${i.votes ? `${icon.star}<span>${i.votes}</span>` : ""}${i.comments ? `${icon.comment}<span>${i.comments}</span>` : ""}</span>
      <span class="m">${prio(i) ? `<span class="lbl ${prio(i).toLowerCase()}">${esc(prio(i))}</span>` : ""}${i.labels.filter((l) => !/^p[0-3]$/i.test(l.name)).slice(0, 3).map((l) => `<span class="lbl"><i style="--c:#${esc(l.color)}"></i>${esc(l.name.replace(/^area:\s*/, ""))}</span>`).join("")}<span>opened ${ago(i.created)}${i.user ? ` by ${esc(i.user.login)}` : ""}</span></span>
    </a>`;
  const list = (items, glyph, title, text) => items.length ? `<div class="shell" data-reveal><div class="core">${items.map(row).join("")}</div></div>` : `<div class="shell" data-reveal><div class="core">${empty(glyph, title, text)}</div></div>`;

  const set = (k, v) => { const el = $(`[data-stat="${k}"]`); if (el) { el.textContent = v ?? "—"; el.classList.toggle("none", v == null); } };
  set("issues", iss?.ok ? num(issues.length) : null);
  set("ideas", iss?.ok ? num(issues.filter((i) => has(i, "idea")).length) : null);
  set("gfi", iss?.ok ? num(issues.filter((i) => has(i, "good first issue")).length) : null);
  set("contributors", ppl?.contributors?.length ? num(ppl.contributors.length) : null);
  if (repo?.repo?.discussions) $("[data-discuss]")?.setAttribute("href", `${GH}/discussions`);

  const ideas = issues.filter((i) => has(i, "idea")).sort((a, b) => b.votes - a.votes || b.comments - a.comments).slice(0, 10);
  $("[data-roadmap]").innerHTML = list(ideas, icon.bulb, "No open ideas yet", "Suggest the thing you wish your Mac did. The most wanted ideas rise to the top here.");
  const gfi = issues.filter((i) => has(i, "good first issue")).slice(0, 8);
  $("[data-gfi]").innerHTML = list(gfi, icon.users, "No good first issues right now", "Issues that are a good way in get this label. Themes and plugins are an easy first contribution too.");

  const bugs = issues.filter((i) => !has(i, "idea"));
  const areas = [...new Set(bugs.map(areaOf).filter(Boolean))].sort();
  const seg = $("[data-areas]");
  let area = "all";
  const drawBugs = () => {
    seg.innerHTML = ["all", ...areas].map((a) => `<button type="button" data-a="${esc(a)}" aria-pressed="${a === area}">${a === "all" ? "All" : esc(a)}<span class="n">${a === "all" ? bugs.length : bugs.filter((b) => areaOf(b) === a).length}</span></button>`).join("");
    $$("button", seg).forEach((b) => b.addEventListener("click", () => { area = b.dataset.a; drawBugs(); }));
    const order = { P0: 0, P1: 1, P2: 2, P3: 3 };
    const shown = bugs.filter((b) => area === "all" || areaOf(b) === area).sort((a, b) => (order[prio(a)] ?? 9) - (order[prio(b)] ?? 9) || new Date(b.updated) - new Date(a.updated)).slice(0, 30);
    $("[data-issues]").innerHTML = list(shown, icon.shield, iss?.ok ? "No open issues" : "Issues appear here soon", iss?.ok ? "Nothing reported is waiting. Found something? Report it and it shows up here." : "Once the repository is public, open issues are listed here by area and priority.");
    reveal($("[data-issues]"));
  };
  seg.hidden = !bugs.length;
  drawBugs();

  const people = ppl?.contributors ?? [];
  $("[data-people]").innerHTML = people.length
    ? `<div class="people">${people.map((c) => `<a class="person" href="${esc(c.url)}" rel="noopener" data-reveal data-stagger><img src="${esc(c.avatar)}&s=80" alt="" width="40" height="40" loading="lazy"><div><b>${esc(c.login)}</b><span>${num(c.contributions)} ${c.contributions === 1 ? "commit" : "commits"}</span></div></a>`).join("")}</div>`
    : `<div class="shell" data-reveal><div class="core">${empty(icon.users, "Be the first contributor", "A fix, a theme, a translation of a confusing sentence: everything counts, and everyone who lands a change shows up here.", btn(`${GH}/blob/main/docs/CONTRIBUTING.md`, "How to contribute", "ghost"))}</div></div>`;
  reveal();
};

const DOCS = [
  { group: "Using Atelier", items: [["features", "Feature reference", "docs/FEATURES.md"], ["compatibility", "Compatibility", "COMPATIBILITY.md"], ["changelog", "Changelog", "CHANGELOG.md"]] },
  { group: "Making things", items: [["customising", "Themes and plugins", "docs/README.md"], ["themes", "Theme format", "docs/THEMES.md"], ["plugins", "Plugin API", "docs/PLUGINS.md"]] },
  { group: "Project", items: [["contributing", "Contributing", "docs/CONTRIBUTING.md"], ["releasing", "Releasing", "docs/RELEASING.md"], ["security", "Security", "SECURITY.md"]] },
];
pages.docs = async () => {
  const { render } = await import("./md.js");
  const all = DOCS.flatMap((g) => g.items);
  const byPath = new Map(all.map(([slug, , path]) => [path.toLowerCase(), slug]));
  const nav = $("[data-docnav]"), body = $("[data-doc]"), toc = $("[data-toc]");
  nav.innerHTML = DOCS.map((g) => `<div class="group">${esc(g.group)}</div>${g.items.map(([s, t]) => `<a href="docs.html?doc=${s}" data-s="${s}">${esc(t)}</a>`).join("")}`).join("");

  const load = async (slug, push) => {
    const entry = all.find((d) => d[0] === slug) ?? all[0];
    const [s, title, path] = entry;
    $$("a", nav).forEach((a) => (a.dataset.s === s ? a.setAttribute("aria-current", "page") : a.removeAttribute("aria-current")));
    document.title = `${title} · Atelier Docs`;
    body.innerHTML = `<div class="skel" style="height:44px;width:60%"></div><div class="skel" style="height:16px;margin-top:24px"></div><div class="skel" style="height:16px;margin-top:10px;width:90%"></div><div class="skel" style="height:16px;margin-top:10px;width:80%"></div>`;
    let md = await data(`docs/${s}.md`);
    if (md == null) md = await fetch(`https://raw.githubusercontent.com/${REPO}/main/${path}`).then((r) => (r.ok ? r.text() : null)).catch(() => null);
    if (md == null) {
      body.innerHTML = empty(icon.doc, "This page could not load", "The docs are copied in when the site is built. Read it on GitHub meanwhile.", btn(`${GH}/blob/main/${path}`, "Open on GitHub", "ghost"));
      toc.innerHTML = ""; return;
    }
    const dir = path.includes("/") ? path.slice(0, path.lastIndexOf("/") + 1) : "";
    const norm = (p) => { const out = []; for (const part of (dir + p).split("/")) { if (part === "..") out.pop(); else if (part && part !== ".") out.push(part); } return out.join("/"); };
    const resolve = (u) => {
      if (u.startsWith("#")) return u;
      const [p, hash] = u.split("#");
      const full = norm(p), doc = byPath.get(full.toLowerCase());
      if (doc) return `docs.html?doc=${doc}${hash ? `#${hash}` : ""}`;
      return `${GH}/blob/main/${full}${hash ? `#${hash}` : ""}`;
    };
    const resolveImage = (u) => `https://raw.githubusercontent.com/${REPO}/main/${norm(u)}`;
    const t = [];
    body.innerHTML = render(md, { resolve, resolveImage, toc: t });
    toc.innerHTML = t.length > 1 ? `<div class="group">On this page</div>${t.map((h) => `<a href="#${esc(h.id)}" class="l${h.level}">${esc(h.text)}</a>`).join("")}` : "";
    if (push) { history.pushState({ doc: s }, "", `docs.html?doc=${s}`); scrollTo({ top: 0, behavior: "instant" }); }
    if (location.hash) document.getElementById(decodeURIComponent(location.hash.slice(1)))?.scrollIntoView();
    spy();
  };
  let spyObs;
  const spy = () => {
    spyObs?.disconnect();
    const links = new Map($$("a", toc).map((a) => [a.getAttribute("href").slice(1), a]));
    spyObs = new IntersectionObserver((es) => {
      for (const e of es) if (e.isIntersecting) { links.forEach((a) => a.classList.remove("on")); links.get(e.target.id)?.classList.add("on"); }
    }, { rootMargin: "-90px 0px -70% 0px" });
    $$("h2[id], h3[id]", body).forEach((h) => spyObs.observe(h));
  };
  nav.addEventListener("click", (e) => { const a = e.target.closest("a[data-s]"); if (!a || e.metaKey || e.ctrlKey) return; e.preventDefault(); load(a.dataset.s, true); });
  body.addEventListener("click", (e) => {
    const a = e.target.closest('a[href^="docs.html?doc="]'); if (!a || e.metaKey || e.ctrlKey) return;
    e.preventDefault(); const u = new URL(a.href); load(u.searchParams.get("doc"), true).then(() => u.hash && document.getElementById(u.hash.slice(1))?.scrollIntoView());
  });
  addEventListener("popstate", () => load(new URLSearchParams(location.search).get("doc") || "features"));
  load(new URLSearchParams(location.search).get("doc") || "features");
};

/* ---------- boot ---------- */
shell();
reveal();
pages[document.body.dataset.page]?.().catch((e) => console.error(e));
