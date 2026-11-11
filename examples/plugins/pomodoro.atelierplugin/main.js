// Pomodoro: 25 minutes of focus, 5 of rest. Click the Dock tile to start or pause.
// Shows every kind of registration: a Dock tile, a widget, a command and a corner action.

const FOCUS = 25 * 60, REST = 5 * 60;
let state = atelier.storage.get("state", { phase: "focus", left: FOCUS, running: false });
let done = atelier.storage.get("done", 0);
let ticker = null;

const mmss = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
const total = () => (state.phase === "focus" ? FOCUS : REST);
const save = () => atelier.storage.set("state", state);

const tile = atelier.dockTile({
  id: "timer",
  title: "Pomodoro",
  symbol: "timer",
  text: mmss(state.left),
  tint: "#FF6B5A",
  onClick: () => toggle(),
});

const widget = atelier.widget({
  id: "focus",
  title: "Pomodoro",
  size: "small",
  refresh: 30,
  view: () =>
    atelier.ui.vstack([
      atelier.ui.ring(1 - state.left / total(), { label: mmss(state.left), color: state.phase === "focus" ? "#FF6B5A" : "mint", width: 7 }),
      atelier.ui.text(state.running ? (state.phase === "focus" ? "Focusing" : "Resting") : "Paused", { size: 12, weight: "semibold", color: "secondary" }),
      atelier.ui.text(`${done} today`, { size: 11, color: "tertiary" }),
    ], { align: "center", spacing: 6 }),
});

function render() {
  tile.update({
    text: mmss(state.left),
    progress: 1 - state.left / total(),
    badge: done > 0 ? String(done) : null,
    tint: state.phase === "focus" ? "#FF6B5A" : "#4FD1A5",
  });
  widget.refresh();
}

function tick() {
  state.left -= 1;
  if (state.left <= 0) {
    if (state.phase === "focus") {
      done += 1;
      atelier.storage.set("done", done);
      atelier.notify("Focus session done", "Take five. You have finished " + done + " today.");
      state = { phase: "rest", left: REST, running: true };
    } else {
      atelier.notify("Break over", "Back to it.");
      state = { phase: "focus", left: FOCUS, running: false };
      stop();
    }
  }
  save();
  render();
}

function start() {
  if (ticker) return;
  state.running = true;
  ticker = setInterval(tick, 1000);
  render();
}

function stop() {
  if (ticker) clearInterval(ticker);
  ticker = null;
  state.running = false;
  save();
  render();
}

function toggle() { state.running ? stop() : start(); }

atelier.command({ id: "toggle", title: "Start or Pause Pomodoro", shortcut: "ctrl+opt+p", run: toggle });
atelier.command({ id: "reset", title: "Reset Pomodoro", run: () => { stop(); state = { phase: "focus", left: FOCUS, running: false }; save(); render(); } });
atelier.cornerAction({ id: "toggle", title: "Start or Pause Pomodoro", symbol: "timer", run: toggle });

// A new day starts the count again.
atelier.on("timer", () => {
  const today = new Date().toDateString();
  if (atelier.storage.get("day") !== today) {
    atelier.storage.set("day", today);
    done = 0;
    atelier.storage.set("done", 0);
    render();
  }
}, { interval: 300 });

if (state.running) { state.running = false; start(); } else { render(); }
