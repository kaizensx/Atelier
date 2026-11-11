"""Atelier brand vectors: the Facet mark and the "atelier" wordmark, built on measured metrics.

Rules
- Wordmark: one stroke weight; x-height x; ascender 1.40x (l, the i's spark top);
  t top 1.18x. Spacing by side type: straight 0.150x, round 0.095x, open 0.060x per side.
- Every SVG is cropped to its ink with equal padding, so anything that places it can
  align on real edges. Wordmark SVGs: top edge = ascender, bottom edge = baseline + bowl overshoot.
- Lockup: wordmark (ascender..baseline) centred on the mark's height; ascender = 0.52 of the mark's height.
usage: python3 svg.py <out dir>"""
import json, math, os, sys

OUT = sys.argv[1]
INK, SILVER, STEEL = "#05080F", "#DCE4EF", "#7D8AA0"
ICE, ICE_DEEP, DEEP, DEEP_SHADE, LIGHT_SHADE = "#5FD3FF", "#2FA8E0", "#2A5BFF", "#1D3FB8", "#46526A"

# Mark, unit box, y up. Symmetric about x = 0.5.
APEX, BL, BR = (0.5, 0.88), (0.08, 0.10), (0.92, 0.10)
CA, CL, CR = (0.5, 0.52), (0.34, 0.10), (0.66, 0.10)
CAPY = 0.715
MARK_X0, MARK_X1, MARK_Y0, MARK_Y1 = 0.08, 0.92, 0.10, 0.88
MARK_W, MARK_H = MARK_X1 - MARK_X0, MARK_Y1 - MARK_Y0

def at_y(a, b, y):
    t = (y - a[1]) / (b[1] - a[1]); return (a[0] + (b[0] - a[0]) * t, y)

def mark_elems(ox, oy, s, light=False):
    """Mark with its ink box's top-left at (ox, oy); ink is MARK_W*s by MARK_H*s."""
    lc, rc, mid = at_y(APEX, BL, CAPY), at_y(APEX, BR, CAPY), (0.5, CAPY)
    polys = [([mid, lc, BL, CL, CA], INK if light else SILVER),
             ([mid, CA, CR, BR, rc], LIGHT_SHADE if light else STEEL),
             ([APEX, lc, mid], DEEP if light else ICE),
             ([APEX, mid, rc], DEEP_SHADE if light else ICE_DEEP)]
    out = []
    for poly, fill in polys:
        p = " ".join(f"{ox + (x - MARK_X0) * s:.3f},{oy + (MARK_Y1 - y) * s:.3f}" for x, y in poly)
        out.append(f'<polygon points="{p}" fill="{fill}"/>')
    return "".join(out)

SB = {"straight": 0.150, "round": 0.095, "open": 0.060}

def glyphs(x):
    s = x * 0.165
    r = (x - s) / 2
    asc, ttop = 1.40 * x, 1.18 * x
    G = {}
    def a(ox):
        cx = ox + r + s / 2
        return [("circle", cx, x / 2, r), ("line", (ox + 2 * r + s / 2, -s / 2 * 0), (ox + 2 * r + s / 2, x))]
    G["a"] = (a, 2 * r + s, "round", "straight")
    tl, tr = 0.20 * x, 0.25 * x
    def t(ox):
        c = ox + tl
        return [("line", (c, 0), (c, ttop)), ("line", (c - tl, x - s / 2), (c + tr, x - s / 2))]
    G["t"] = (t, tl + tr, "open", "open")
    def e(ox):
        cx = ox + r + s / 2
        h = s / 2
        return [("arc", cx, x / 2, r, -math.asin(h / (r + h)), 2 * math.pi - 0.66), ("line", (cx - r, x / 2), (cx + math.sqrt((r + h) ** 2 - h * h), x / 2))]
    G["e"] = (e, 2 * r + s, "round", "open")
    def l(ox):
        return [("line", (ox + s / 2, 0), (ox + s / 2, asc))]
    G["l"] = (l, s, "straight", "straight")
    d = s * 0.78
    def i(ox):
        c = ox + s / 2
        return [("line", (c, 0), (c, x)), ("diamond", c, asc - d, d)]
    G["i"] = (i, s, "straight", "straight")
    shoulder = 0.30 * math.pi
    def rr(ox):
        c = ox + s / 2
        return [("line", (c, 0), (c, x)), ("arc", c + r, x / 2, r, math.pi, shoulder)]
    G["r"] = (rr, s / 2 + r + r * math.cos(shoulder) + s / 2, "straight", "open")
    return G, s, asc

def wordmark(x, color, spark):
    """Returns (svg body, y-down, baseline at y = asc), width, ascender height, stroke)."""
    G, s, asc = glyphs(x)
    prims, pen, prev = [], 0.0, None
    for ch in "atelier":
        draw, w, lk, rk = G[ch]
        if prev: pen += (SB[prev] + SB[lk]) * x
        prims += draw(pen)
        pen += w
        prev = rk
    Y = lambda y: asc - y
    h = s / 2
    def arcpts(cx, cy, rad, a0, a1, n=240):
        return [(cx + rad * math.cos(a0 + (a1 - a0) * k / n), cy + rad * math.sin(a0 + (a1 - a0) * k / n)) for k in range(n + 1)]
    def area(c):
        return sum(c[i][0] * c[(i + 1) % len(c)][1] - c[(i + 1) % len(c)][0] * c[i][1] for i in range(len(c))) / 2
    def orient(c, positive=True):
        return c if (area(c) > 0) == positive else list(reversed(c))
    body, sparks = [], []      # contours (y-up); all solids positive, holes negative: one nonzero path = no seams
    for p in prims:
        if p[0] == "line":
            (x1, y1), (x2, y2) = p[1], p[2]
            dx, dy = x2 - x1, y2 - y1; L = math.hypot(dx, dy); nx, ny = -dy / L * h, dx / L * h
            body.append(orient([(x1 + nx, y1 + ny), (x2 + nx, y2 + ny), (x2 - nx, y2 - ny), (x1 - nx, y1 - ny)]))
        elif p[0] == "circle":
            _, cx, cy, rad = p
            body.append(orient(arcpts(cx, cy, rad + h, 0, 2 * math.pi)[:-1]))
            body.append(orient(arcpts(cx, cy, rad - h, 0, 2 * math.pi)[:-1], positive=False))
        elif p[0] == "arc":
            _, cx, cy, rad, a0, a1 = p
            body.append(orient(arcpts(cx, cy, rad + h, a0, a1) + list(reversed(arcpts(cx, cy, rad - h, a0, a1)))))
        elif p[0] == "diamond":
            _, cx, cy, d = p
            sparks.append(orient([(cx, cy + d), (cx + d, cy), (cx, cy - d), (cx - d, cy)]))
    def path(contours):
        return " ".join("M" + " L".join(f"{px:.3f},{Y(py):.3f}" for px, py in c) + " Z" for c in contours)
    out = [f'<path d="{path(body)}" fill="{color}" fill-rule="nonzero"/>', f'<path d="{path(sparks)}" fill="{spark}"/>']
    return "".join(out), pen, asc, s

def doc(w, h, body, vb=None):
    vb = vb or f"0 0 {w:.3f} {h:.3f}"
    return f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb}" width="{w:.0f}" height="{h:.0f}">{body}</svg>\n'

os.makedirs(OUT, exist_ok=True)
def write(name, text): open(os.path.join(OUT, name), "w").write(text)

# Mark alone: ink box centred in a square, equal padding.
S, pad = 1000, 60
mw, mh = MARK_W * S, MARK_H * S
side = max(mw, mh) + 2 * pad
for light, name in ((False, "atelier-mark.svg"), (True, "atelier-mark-light.svg")):
    write(name, doc(side, side, mark_elems((side - mw) / 2, (side - mh) / 2, S, light)))

# Wordmark alone, cropped to ink: top = ascender, bottom = baseline + half a stroke (bowl overshoot).
X = 200
meta = {}
for light, name in ((False, "atelier-wordmark-dark.svg"), (True, "atelier-wordmark-light.svg")):
    body, w, asc, s = wordmark(X, INK if light else SILVER, DEEP if light else ICE)
    write(name, doc(w, asc + s / 2, body))
    meta = {"width": w, "height": asc + s / 2, "baseline": asc, "x_height": X, "stroke": s}

# Lockup.
def lockup(light):
    S = 600
    mw, mh = MARK_W * S, MARK_H * S
    x = (0.52 * mh) / 1.40
    body, ww, asc, s = wordmark(x, INK if light else SILVER, DEEP if light else ICE)
    gap, pad = 0.30 * mh, 0.18 * mh
    W, H = pad + mw + gap + ww + pad, pad + mh + pad
    m = mark_elems(pad, pad, S, light)
    w = f'<g transform="translate({pad + mw + gap:.3f},{pad + mh / 2 - asc / 2:.3f})">{body}</g>'
    return doc(W, H, m + w)
write("atelier-lockup-dark.svg", lockup(False))
write("atelier-lockup-light.svg", lockup(True))
json.dump(meta, open(os.path.join(OUT, "wordmark-metrics.json"), "w"), indent=1)
print("written", OUT)
