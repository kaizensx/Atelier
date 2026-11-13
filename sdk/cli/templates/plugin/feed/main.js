// Atelier's latest releases from GitHub, as a list widget with a Dock badge.
// Needs the network permission for api.github.com, listed in manifest.json.

const RELEASES = "https://api.github.com/repos/kaizensx/Atelier/releases?per_page=5";

const tile = atelier.dockTile({ id: "releases", title: "Atelier Releases", symbol: "shippingbox" });

atelier.widget({
  id: "releases",
  title: "Atelier Releases",
  size: "medium",
  refresh: 3600,
  data: async () => {
    const response = await atelier.http.get(RELEASES, { headers: { Accept: "application/vnd.github+json" } });
    if (!response.ok) throw new Error("GitHub answered " + response.status);
    return response.json();
  },
  view: (releases) => {
    const fresh = releases.filter((r) => Date.now() - Date.parse(r.published_at) < 7 * 86400000).length;
    tile.update({ badge: fresh || null });
    return atelier.ui.list(releases.map((r) => ({
      title: r.name || r.tag_name,
      detail: new Date(r.published_at).toLocaleDateString(),
      symbol: r.prerelease ? "flask" : "checkmark.seal",
      color: r.prerelease ? "orange" : "green",
    })));
  },
});
