// Random Wallpaper Palette. Uses the appearance permission to apply a small theme patch.
// Revert in Looks puts everything back.

const hex = (h, s, l) => {
  // HSL (0-360, 0-1, 0-1) to #RRGGBB.
  const k = (n) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return "#" + [f(0), f(8), f(4)].map((x) => Math.round(x * 255).toString(16).padStart(2, "0")).join("").toUpperCase();
};

function palette() {
  const hue = Math.floor(Math.random() * 360);
  const drift = 18 + Math.random() * 40;
  // Dark to light, each stop a little further round the wheel: deep, shadow, body, crest.
  return [
    hex(hue, 0.7, 0.04),
    hex((hue + drift * 0.5) % 360, 0.65, 0.18),
    hex((hue + drift) % 360, 0.75, 0.52),
    hex((hue + drift * 1.6) % 360, 0.9, 0.88),
  ];
}

function shuffle() {
  const stops = palette();
  atelier.theme.apply({
    colors: { accent: stops[2], secondary: stops[3] },
    wallpaper: { palette: stops },
    dock: { accent: stops[2] },
    widgets: { accent: stops[2] },
  });
  atelier.storage.set("last", stops);
  console.log("Palette:", stops.join(" "));
}

atelier.command({ id: "shuffle", title: "Random Wallpaper Palette", subtitle: "Palette", run: shuffle });
atelier.cornerAction({ id: "shuffle", title: "Random Palette", symbol: "dice", run: shuffle });
