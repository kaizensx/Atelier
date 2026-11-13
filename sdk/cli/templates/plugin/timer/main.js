// A focus timer: a Dock tile that counts down, a ring widget, a command and a corner action.
// Click the tile (or run the command) to start and pause.

const LENGTH = 25 * 60;
let left = atelier.storage.get("left", LENGTH);
let ticker = null;

const mmss = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;

const tile = atelier.dockTile({
  id: "focus",
  title: "Focus",
  symbol: "timer",
  text: mmss(left),
  tint: "#FF6B5A",
  onClick: () => toggle(),
});

const ring = atelier.widget({
  id: "focus",
  title: "Focus",
  refresh: 30,
  view: () => atelier.ui.vstack([
    atelier.ui.ring(1 - left / LENGTH, { label: mmss(left), color: "#FF6B5A", width: 7 }),
    atelier.ui.text(ticker ? "Focusing" : "Paused", { size: 12, weight: "semibold", color: "secondary" }),
  ], { align: "center" }),
});

function draw() {
  tile.update({ text: mmss(left), progress: 1 - left / LENGTH });
  ring.refresh();
}

function tick() {
  left -= 1;
  if (left <= 0) {
    left = LENGTH;
    toggle();
    console.info("Session done.");
  }
  atelier.storage.set("left", left);
  draw();
}

function toggle() {
  if (ticker) { clearInterval(ticker); ticker = null; }
  else ticker = setInterval(tick, 1000);
  draw();
}

atelier.command({ id: "toggle", title: "Start or Pause Focus", shortcut: "ctrl+opt+f", run: toggle });
atelier.cornerAction({ id: "toggle", title: "Start or Pause Focus", symbol: "timer", run: toggle });
