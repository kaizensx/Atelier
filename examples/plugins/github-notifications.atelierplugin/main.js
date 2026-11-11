// GitHub Notifications. Uses the network permission for api.github.com only.
// The token is asked for once, kept in this plugin's own storage, and sent only to GitHub.

const API = "https://api.github.com/notifications?per_page=20";
let unread = [];

const tile = atelier.dockTile({
  id: "inbox",
  title: "GitHub",
  symbol: "bell",
  tint: "#6E7681",
  onClick: () => atelier.openURL("https://github.com/notifications"),
});

async function token() {
  let value = atelier.storage.get("token");
  if (!value) {
    value = await atelier.prompt("GitHub personal access token", {
      message: "Create a classic token with the notifications scope at github.com/settings/tokens.",
      placeholder: "ghp_…",
      secure: true,
    });
    if (value) atelier.storage.set("token", value.trim());
  }
  return value;
}

async function fetchUnread() {
  const auth = atelier.storage.get("token");
  if (!auth) return null;
  const response = await atelier.http.get(API, {
    headers: { Authorization: "Bearer " + auth, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28" },
  });
  if (response.status === 401) {
    atelier.storage.remove("token");
    throw new Error("GitHub refused the token. Run “Set GitHub Token” again.");
  }
  if (!response.ok) throw new Error("GitHub answered " + response.status);
  unread = response.json();
  tile.update({ badge: unread.length ? String(Math.min(unread.length, 99)) : null, symbol: unread.length ? "bell.badge" : "bell" });
  return unread;
}

atelier.widget({
  id: "unread",
  title: "GitHub",
  size: "medium",
  refresh: 180,
  data: fetchUnread,
  view: (items) => {
    if (items === null) return atelier.ui.text("Run “Set GitHub Token” from Command.", { color: "secondary" });
    if (items.length === 0) return atelier.ui.vstack([
      atelier.ui.symbol("checkmark.seal", { size: 22, color: "green" }),
      atelier.ui.text("Inbox zero", { weight: "semibold" }),
    ], { align: "center" });
    return atelier.ui.list(items.slice(0, 6).map((n) => ({
      title: n.subject.title,
      detail: n.repository.name,
      symbol: n.subject.type === "PullRequest" ? "arrow.triangle.pull" : n.subject.type === "Issue" ? "exclamationmark.circle" : "bell",
      color: n.reason === "review_requested" ? "orange" : "accent",
    })));
  },
});

atelier.command({ id: "token", title: "Set GitHub Token", run: async () => { atelier.storage.remove("token"); await token(); } });
atelier.command({ id: "open", title: "Open GitHub Notifications", run: () => atelier.openURL("https://github.com/notifications") });

token();
