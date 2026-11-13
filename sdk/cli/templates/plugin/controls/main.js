// A counter with buttons, a toggle and settings. The settings ("Step", "Goal", "Colour") are
// declared in manifest.json; Atelier draws them on the plugin's page in Mods.

let count = atelier.storage.get("count", 0);
let paused = false;

const counter = atelier.widget({
  id: "counter",
  title: atelier.t("title"),
  view: () => atelier.ui.vstack([
    atelier.ui.text(atelier.t("count", { n: count }), { size: 22, weight: "bold", color: atelier.settings.get("color") }),
    atelier.ui.progress(Math.min(count / atelier.settings.get("goal"), 1), { label: atelier.t("goal") }),
    atelier.ui.hstack([
      // A function as the action: the prelude gives it an id for this render.
      atelier.ui.button("Add", () => bump(), { symbol: "plus" }),
      // An id registered with atelier.action, below.
      atelier.ui.button("Reset", "reset", { style: "plain" }),
    ]),
    atelier.ui.toggle("Paused", paused, ({ on }) => { paused = on; counter.refresh(); }),
  ]),
});

function bump() {
  if (paused) return;
  count += atelier.settings.get("step");
  atelier.storage.set("count", count);
  counter.refresh();
}

atelier.action("reset", () => {
  count = 0;
  atelier.storage.set("count", count);
  counter.refresh();
});

atelier.on("settingsChanged", () => counter.refresh());
atelier.command({ id: "add", title: "Add to Counter", run: bump });
