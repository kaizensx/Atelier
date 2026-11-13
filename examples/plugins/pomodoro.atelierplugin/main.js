// Pomodoro: focus, then a break. Click the Dock tile or the widget's button to start or pause.
// Shows every kind of registration (a Dock tile, a widget, commands and a corner action), plus
// settings Atelier draws from the manifest, buttons in a widget, a chart and localized text.

const minutes = (key, fallback) => Math.max(1, Number(atelier.settings.get(key)) || fallback);
const focusLength = () => minutes("focus", 25) * 60;
const breakLength = () => minutes("break", 5) * 60;

let state = atelier.storage.get("state", { phase: "focus", left: focusLength(), running: false });
let ticker = null;

const today = () => new Date().toISOString().slice(0, 10);
const mmss = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
const total = () => (state.phase === "focus" ? focusLength() : breakLength());
const save = () => atelier.storage.set("state", state);

// Finished focus sessions per day, the last seven kept.
const history = () => atelier.storage.get("history", {});
const doneToday = () => history()[today()] || 0;
function countSession() {
  const days = history();
  days[today()] = (days[today()] || 0) + 1;
  const keep = Object.keys(days).sort().slice(-7);
  atelier.storage.set("history", Object.fromEntries(keep.map((day) => [day, days[day]])));
}
function lastWeek() {
  const days = history(), labels = [], values = [];
  for (let back = 6; back >= 0; back--) {
    const date = new Date(Date.now() - back * 86400000);
    labels.push(date.toLocaleDateString(undefined, { weekday: "narrow" }));
    values.push(days[date.toISOString().slice(0, 10)] || 0);
  }
  return { labels, values };
}

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
  size: "medium",
  refresh: 30,
  view: () => {
    const week = lastWeek();
    return atelier.ui.hstack([
      atelier.ui.vstack([
        atelier.ui.ring(1 - state.left / total(), { label: mmss(state.left), color: state.phase === "focus" ? "#FF6B5A" : "mint", width: 7 }),
        atelier.ui.hstack([
          atelier.ui.button(state.running ? atelier.t("pause") : atelier.t("start"), () => toggle(),
                            { symbol: state.running ? "pause.fill" : "play.fill" }),
          atelier.ui.button("", () => reset(), { symbol: "arrow.counterclockwise", style: "plain" }),
        ], { spacing: 6 }),
      ], { align: "center", spacing: 8 }),
      atelier.ui.vstack([
        atelier.ui.text(state.running ? atelier.t(state.phase === "focus" ? "focusing" : "resting") : atelier.t("paused"),
                        { size: 12, weight: "semibold", color: "secondary" }),
        atelier.ui.text(atelier.t("today", { n: doneToday() }), { size: 11, color: "tertiary" }),
        atelier.ui.chart(week.values, { kind: "bar", labels: week.labels, color: "#FF6B5A" }),
      ], { spacing: 6, transition: "fade" }),
    ], { spacing: 14 });
  },
});

function render() {
  const done = doneToday();
  tile.update({
    text: mmss(state.left),
    progress: 1 - state.left / total(),
    badge: done > 0 ? String(done) : null,
    tint: state.phase === "focus" ? "#FF6B5A" : "#4FD1A5",
  });
  widget.refresh();
}

function finish(title, body) {
  if (atelier.settings.get("notify") !== false) atelier.notify(title, body);
}

function tick() {
  state.left -= 1;
  if (state.left <= 0) {
    if (state.phase === "focus") {
      countSession();
      finish(atelier.t("focusDone"), atelier.t("focusDoneBody", { n: doneToday() }));
      state = { phase: "rest", left: breakLength(), running: true };
    } else {
      finish(atelier.t("breakOver"), atelier.t("breakOverBody"));
      state = { phase: "focus", left: focusLength(), running: false };
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

function reset() {
  stop();
  state = { phase: "focus", left: focusLength(), running: false };
  save();
  render();
}

function toggle() { state.running ? stop() : start(); }

atelier.command({ id: "toggle", title: "Start or Pause Pomodoro", shortcut: "ctrl+opt+p", run: toggle });
atelier.command({ id: "reset", title: "Reset Pomodoro", run: reset });
atelier.cornerAction({ id: "toggle", title: "Start or Pause Pomodoro", symbol: "timer", run: toggle });

// New lengths apply to the next session, or now when the timer is not running.
atelier.on("settingsChanged", ({ key }) => {
  if ((key === "focus" || key === "break") && !state.running) reset();
});

// Version 1.0 kept one count for today; carry it into the history once.
atelier.on("update", ({ from }) => {
  const old = atelier.storage.get("done");
  if (from.startsWith("1.0") && old && atelier.storage.get("day") === new Date().toDateString()) {
    atelier.storage.set("history", Object.assign(history(), { [today()]: old }));
  }
  atelier.storage.remove("done");
  atelier.storage.remove("day");
  render();
});

// A new day: the badge and the count start again.
atelier.on("timer", () => render(), { interval: 300 });

if (state.running) { state.running = false; start(); } else { render(); }
