#!/usr/bin/env node
// Builds site/data/*.json for the website from GitHub, so visitors never hit the API's
// 60-requests-an-hour limit. Runs in the Pages workflow; no dependencies, Node 20 or later.
//
//   GITHUB_TOKEN=… node site/scripts/build-data.mjs
//
// Every source is optional. A request that fails leaves that file out (or empty), and the
// pages show an empty state instead. Nothing here ever fails the deploy.

import { mkdirSync, writeFileSync, readFileSync, existsSync, copyFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const site = join(here, "..");
const root = join(site, "..");
const out = join(site, "data");
const REPO = process.env.ATELIER_REPO || "kaizensx/Atelier";
const MODS_INDEX = process.env.ATELIER_MODS_INDEX || "https://raw.githubusercontent.com/kaizensx/atelier-mods/dist/index.json";
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN || "";
const now = new Date().toISOString().replace(/\.\d+Z$/, "Z");

mkdirSync(join(out, "docs"), { recursive: true });
const write = (name, data) => { writeFileSync(join(out, name), JSON.stringify(data, null, 1) + "\n"); console.log(`wrote data/${name}`); };

async function gh(path, { raw = false, accept } = {}) {
  const url = path.startsWith("http") ? path : `https://api.github.com${path}`;
  const headers = { "User-Agent": "atelier-site-builder", "X-GitHub-Api-Version": "2022-11-28", Accept: accept || "application/vnd.github+json" };
  if (token && url.startsWith("https://api.github.com")) headers.Authorization = `Bearer ${token}`;
  const res = await fetch(url, { headers, redirect: "follow" });
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return raw ? res.text() : res.json();
}

async function all(path, max = 10) {
  const items = [];
  for (let page = 1; page <= max; page++) {
    const sep = path.includes("?") ? "&" : "?";
    const batch = await gh(`${path}${sep}per_page=100&page=${page}`);
    items.push(...batch);
    if (batch.length < 100) break;
  }
  return items;
}

const soft = async (label, fn) => { try { return await fn(); } catch (e) { console.warn(`skip ${label}: ${e.message}`); return null; } };

// Repository
const repo = await soft("repo", () => gh(`/repos/${REPO}`));

// Releases, with each asset's SHA-256 (GitHub's digest, or the .sha256 file beside the zip)
const releasesRaw = (await soft("releases", () => all(`/repos/${REPO}/releases`, 5))) ?? [];
const releases = [];
for (const r of releasesRaw.filter((r) => !r.draft)) {
  const sums = new Map();
  for (const a of r.assets.filter((a) => a.name.endsWith(".sha256"))) {
    const text = await soft(a.name, () => gh(a.url, { raw: true, accept: "application/octet-stream" }));
    const hex = text && /[a-f0-9]{64}/i.exec(text);
    if (hex) sums.set(a.name.replace(/\.sha256$/, ""), hex[0].toLowerCase());
  }
  releases.push({
    tag: r.tag_name,
    name: r.name || r.tag_name,
    prerelease: r.prerelease,
    published: r.published_at,
    url: r.html_url,
    body: r.body || "",
    assets: r.assets.map((a) => ({
      name: a.name,
      size: a.size,
      downloads: a.download_count,
      url: a.browser_download_url,
      sha256: (a.digest && a.digest.startsWith("sha256:") ? a.digest.slice(7) : sums.get(a.name)) || null,
    })),
  });
}
const downloads = releases.reduce((n, r) => n + r.assets.filter((a) => a.name.endsWith(".zip")).reduce((m, a) => m + a.downloads, 0), 0);
const latestStable = releases.find((r) => !r.prerelease) ?? null;
const latestBeta = releases.find((r) => r.prerelease) ?? null;

// Issues (pull requests left out), contributors
const issuesRaw = (await soft("issues", () => all(`/repos/${REPO}/issues?state=open&sort=updated`, 5))) ?? [];
const issues = issuesRaw.filter((i) => !i.pull_request).map((i) => ({
  number: i.number,
  title: i.title,
  url: i.html_url,
  labels: i.labels.map((l) => ({ name: l.name, color: l.color })),
  comments: i.comments,
  votes: i.reactions ? (i.reactions["+1"] ?? 0) + (i.reactions.heart ?? 0) + (i.reactions.hooray ?? 0) : 0,
  created: i.created_at,
  updated: i.updated_at,
  user: i.user ? { login: i.user.login, avatar: i.user.avatar_url } : null,
}));
const contributorsRaw = (await soft("contributors", () => all(`/repos/${REPO}/contributors`, 3))) ?? [];
const contributors = contributorsRaw.filter((c) => c.type !== "Bot").map((c) => ({ login: c.login, avatar: c.avatar_url, url: c.html_url, contributions: c.contributions }));

write("repo.json", {
  generated: now,
  ok: !!repo,
  repo: repo ? {
    name: repo.full_name, url: repo.html_url, description: repo.description, stars: repo.stargazers_count,
    forks: repo.forks_count, watchers: repo.subscribers_count, pushed: repo.pushed_at, discussions: repo.has_discussions,
    topics: repo.topics ?? [], private: repo.private,
  } : null,
  openIssues: repo ? issues.length : null,
  contributors: contributors.length || null,
  downloads: releases.length ? downloads : null,
  latestStable: latestStable && { tag: latestStable.tag, published: latestStable.published },
  latestBeta: latestBeta && (!latestStable || latestBeta.published > latestStable.published) ? { tag: latestBeta.tag, published: latestBeta.published } : null,
});
write("releases.json", { generated: now, ok: !!repo, releases });
write("issues.json", { generated: now, ok: !!repo, issues });
write("contributors.json", { generated: now, ok: !!repo, contributors });

// The Mods catalog. Atelier verifies the index's signature before it installs anything; the site
// only shows it. When the catalog is not published yet, the pages fall back to mods-seed.json.
const mods = await soft("mods index", async () => {
  const index = JSON.parse(await gh(MODS_INDEX, { raw: true }));
  if (index.format !== 1 || !Array.isArray(index.mods)) throw new Error("unexpected index format");
  return index;
});
if (mods) write("mods.json", mods);

// Docs and the changelog, copied as Markdown for the Docs and Releases pages.
const docs = {
  features: "docs/FEATURES.md", themes: "docs/THEMES.md", plugins: "docs/PLUGINS.md", customising: "docs/README.md",
  contributing: "docs/CONTRIBUTING.md", releasing: "docs/RELEASING.md", compatibility: "COMPATIBILITY.md", security: "SECURITY.md",
  changelog: "CHANGELOG.md",
};
for (const [name, path] of Object.entries(docs)) {
  if (existsSync(join(root, path))) { copyFileSync(join(root, path), join(out, "docs", `${name}.md`)); console.log(`copied ${path}`); }
}
if (existsSync(join(root, "VERSION"))) write("version.json", { version: readFileSync(join(root, "VERSION"), "utf8").trim() });
