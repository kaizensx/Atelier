// GitHub Hub: one plugin, every hook into Atelier.
//  * Command palette: type "gh " and a word to search your repositories.
//  * Menu bar: unread notifications, with a menu.
//  * Dock tile: drop a github.com link on it to open it; right-click for a menu.
//  * Stack: your open pull requests, on the Atelier Dock (add it in Stacks › From Plugins).
//  * Panel: a small dashboard window. It has no network; the plugin sends it the data.
// The token is asked for once, kept in this plugin's own storage, and sent only to GitHub.

const API = "https://api.github.com";
let repos = null;          // fetched once, then searched locally
let reposFetched = 0;
let unread = 0;
let pulls = [];

async function token() {
  let value = atelier.storage.get("token");
  if (!value) {
    value = await atelier.prompt("GitHub personal access token", {
      message: "Create a token with the repo and notifications scopes at github.com/settings/tokens.",
      placeholder: "ghp_…",
      secure: true,
    });
    if (value) atelier.storage.set("token", value.trim());
  }
  return value;
}

async function get(path) {
  const auth = atelier.storage.get("token");
  if (!auth) throw new Error("No GitHub token yet. Choose “Set Token…” in the GitHub menu.");
  const response = await atelier.http.get(API + path, {
    headers: { Authorization: "Bearer " + auth, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" },
  });
  if (response.status === 401) {
    atelier.storage.remove("token");
    throw new Error("GitHub refused the token. Set it again from the GitHub menu.");
  }
  if (!response.ok) throw new Error("GitHub answered " + response.status);
  return response.json();
}

const isGitHub = (url) => /^https:\/\/(www\.)?github\.com\//i.test(url);
const open = (url) => { if (isGitHub(url)) atelier.openURL(url); };

// --- Command palette ------------------------------------------------------------------------

atelier.paletteProvider({
  id: "repos",
  title: "GitHub",
  prefix: "gh",
  search: async (query) => {
    // The list is cached for ten minutes, so typing never waits on the network twice.
    if (!repos || Date.now() - reposFetched > 10 * 60 * 1000) {
      repos = await get("/user/repos?per_page=100&sort=pushed");
      reposFetched = Date.now();
    }
    const words = query.toLowerCase().split(/\s+/).filter(Boolean);
    return repos
      .filter((r) => words.every((w) => r.full_name.toLowerCase().includes(w)))
      .slice(0, 20)
      .map((r) => ({
        title: r.full_name,
        subtitle: r.private ? "Private" : "★ " + r.stargazers_count,
        symbol: r.fork ? "tuningfork" : "book.closed",
        action: () => open(r.html_url),
      }));
  },
});

// --- Menu bar ---------------------------------------------------------------------------------

const menuBar = atelier.menuBarItem({
  id: "inbox",
  title: "GitHub",
  symbol: "bell",
  menu: menuItems(),
});

function menuItems() {
  return [
    { title: unread ? unread + " unread" : "No unread notifications", enabled: false },
    { title: "Open Notifications", symbol: "bell", action: () => open("https://github.com/notifications") },
    { title: "Open Pull Requests", symbol: "arrow.triangle.pull", action: () => open("https://github.com/pulls") },
    "separator",
    { title: "Dashboard", symbol: "rectangle.grid.2x2", action: () => dashboard.show() },
    { title: "Refresh", symbol: "arrow.clockwise", action: refresh },
    { title: "Settings", submenu: [
      { title: "Set Token…", symbol: "key", action: async () => { atelier.storage.remove("token"); await token(); refresh(); } },
      { title: "Forget Token", symbol: "trash", action: () => { atelier.storage.remove("token"); refresh(); } },
    ] },
  ];
}

// --- Dock tile --------------------------------------------------------------------------------

const tile = atelier.dockTile({
  id: "hub",
  title: "GitHub",
  symbol: "chevron.left.forwardslash.chevron.right",
  tint: "#6E7681",
  onClick: () => open("https://github.com"),
  accepts: ["url"],
  onDrop: ({ kind, value }) => {
    if (kind === "url" && isGitHub(value)) open(value);
    else console.warn("Not a GitHub link: " + value);
  },
  menu: [
    { title: "Notifications", symbol: "bell", action: () => open("https://github.com/notifications") },
    { title: "Dashboard", symbol: "rectangle.grid.2x2", action: () => dashboard.show() },
  ],
});

// --- Stack ------------------------------------------------------------------------------------

atelier.stackProvider({
  id: "pulls",
  title: "My Pull Requests",
  symbol: "arrow.triangle.pull",
  refresh: 120,
  items: async () => {
    const found = await get("/search/issues?q=" + encodeURIComponent("is:pr is:open author:@me") + "&per_page=60");
    pulls = found.items || [];
    return pulls.map((pr) => ({
      title: pr.title,
      subtitle: pr.repository_url.split("/").slice(-1)[0] + " #" + pr.number,
      symbol: pr.draft ? "circle.dashed" : "arrow.triangle.pull",
      action: () => open(pr.html_url),
    }));
  },
});

// --- Panel ------------------------------------------------------------------------------------

const dashboard = atelier.panel({
  id: "dashboard",
  title: "GitHub",
  width: 360,
  height: 260,
  html: `<!doctype html>
<html><head><style>
  :root { color-scheme: light dark; font: 13px -apple-system, system-ui; }
  body { margin: 16px; }
  h1 { font-size: 15px; margin: 0 0 12px; }
  .row { display: flex; justify-content: space-between; padding: 8px 0; border-bottom: 1px solid #8883; }
  .n { font-weight: 600; font-variant-numeric: tabular-nums; }
  button { margin-top: 14px; }
</style></head><body>
  <h1>GitHub</h1>
  <div class="row"><span>Unread notifications</span><span class="n" id="unread">–</span></div>
  <div class="row"><span>Open pull requests</span><span class="n" id="pulls">–</span></div>
  <button id="go">Open notifications</button>
  <script>
    atelier.onMessage((m) => {
      document.getElementById("unread").textContent = m.unread;
      document.getElementById("pulls").textContent = m.pulls;
    });
    document.getElementById("go").onclick = () => atelier.post({ open: "https://github.com/notifications" });
  </script>
</body></html>`,
});

atelier.on("panelMessage", ({ id, message }) => {
  if (id === "dashboard" && message && typeof message.open === "string") open(message.open);
});

// --- Refresh ----------------------------------------------------------------------------------

async function refresh() {
  try {
    const notes = await get("/notifications?per_page=50");
    unread = notes.length;
  } catch (error) {
    console.warn(error.message);
  }
  menuBar.update({ symbol: unread ? "bell.badge" : "bell", text: unread ? String(Math.min(unread, 99)) : undefined, menu: menuItems() });
  tile.update({ badge: unread ? String(Math.min(unread, 99)) : null });
  dashboard.post({ unread, pulls: pulls.length });
}

atelier.on("timer", refresh, { interval: 180 });

if (!atelier.storage.get("asked")) {
  atelier.storage.set("asked", "yes");
  token().then(refresh);
} else {
  refresh();
}
