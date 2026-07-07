#!/usr/bin/env python3
"""Generate the Zurvan OS emblem: lion (gold, order/permanence) and snake
(teal, ephemerality) circling each other taijitu-style, Persian-flavored."""
import math

# ---------- palette ----------
BG_A, BG_B = "#161b2c", "#0a0d16"          # background radial gradient
GOLD_A, GOLD_B = "#f6c65b", "#b97b16"      # lion half
TEAL_A, TEAL_B = "#3ecfba", "#0d7a70"      # snake half
DARK = "#0c101c"                           # engraving color (near-bg)
GOLD_LINE = "#e8b84b"
TEAL_LINE = "#2bb5a3"

R = 340          # main disc radius
r = R / 2        # lobe radius

def pt(a_deg, rad, cx=0.0, cy=0.0):
    a = math.radians(a_deg)
    return (cx + rad * math.cos(a), cy + rad * math.sin(a))

def fmt(x):
    return f"{x:.2f}".rstrip("0").rstrip(".")

def P(x, y):
    return f"{fmt(x)} {fmt(y)}"

def path(d, fill=None, stroke=None, sw=None, cap="round", join="round", opacity=None, extra=""):
    s = f'<path d="{d}"'
    s += f' fill="{fill}"' if fill else ' fill="none"'
    if stroke:
        s += f' stroke="{stroke}" stroke-width="{sw}" stroke-linecap="{cap}" stroke-linejoin="{join}"'
    if opacity:
        s += f' opacity="{opacity}"'
    return s + (" " + extra if extra else "") + "/>"

out = []

# ---------- taijitu halves ----------
gold_half = (f"M 0 {-R} A {R} {R} 0 0 1 0 {R} "
             f"A {fmt(r)} {fmt(r)} 0 0 0 0 0 "
             f"A {fmt(r)} {fmt(r)} 0 0 1 0 {-R} Z")
teal_half = (f"M 0 {R} A {R} {R} 0 0 1 0 {-R} "
             f"A {fmt(r)} {fmt(r)} 0 0 0 0 0 "
             f"A {fmt(r)} {fmt(r)} 0 0 1 0 {R} Z")

# ---------- lion: sun-face with flame mane, center (0,-170) ----------
LCX, LCY = 0, -r
def flame_ray(a, base_r, tip_r, half_w):
    """One mane ray with gently concave sides (flame, not spike)."""
    b1 = pt(a - half_w, base_r)
    b2 = pt(a + half_w, base_r)
    tip = pt(a, tip_r)
    # control points pulled toward the ray axis for concave sides
    c1 = pt(a - half_w * 0.35, base_r + (tip_r - base_r) * 0.55)
    c2 = pt(a + half_w * 0.35, base_r + (tip_r - base_r) * 0.55)
    return (f"M {P(*b1)} Q {P(*c1)} {P(*tip)} Q {P(*c2)} {P(*b2)} Z")

def lion():
    g = [f'<g transform="translate({LCX},{LCY}) scale(0.96)">']
    # 12 bold flame rays (12 = the hours of boundless time)
    rays = [flame_ray(-90 + i * 30, 92, 152, 13.5) for i in range(12)]
    g.append(path(" ".join(rays), fill=DARK))
    # face disc
    g.append(f'<circle r="98" fill="{DARK}"/>')
    # fierce brows: straight bars, inner ends LOWER
    g.append(path("M -56 -44 L -16 -31 M 56 -44 L 16 -31", stroke=GOLD_LINE, sw=11))
    # eyes: pointed leaf shapes, outer corners tilted up, teal (the opposite seed)
    def eye(sx):
        # leaf from inner (near nose) to outer corner, tilted up outward
        x0, y0 = 14 * sx, -8          # inner corner
        x1, y1 = 52 * sx, -20         # outer corner (higher = fierce)
        cxu, cyu = 33 * sx, -26       # upper bulge
        cxl, cyl = 33 * sx, -2        # lower bulge
        return (f"M {P(x0,y0)} Q {P(cxu,cyu)} {P(x1,y1)} Q {P(cxl,cyl)} {P(x0,y0)} Z")
    g.append(path(eye(-1) + " " + eye(1), fill=TEAL_A))
    # nose: bold shield triangle + bridge lines from the brows
    g.append(path("M -17 18 L 17 18 L 0 44 Z", fill=GOLD_LINE))
    g.append(path("M -14 -28 L -13 16 M 14 -28 L 13 16", stroke=GOLD_LINE, sw=6))
    # muzzle: line down + feline W mouth
    g.append(path("M 0 44 L 0 56 M 0 56 C -8 66 -24 66 -32 56 M 0 56 C 8 66 24 66 32 56",
                  stroke=GOLD_LINE, sw=8))
    # chin: small beard diamond
    g.append(path("M 0 70 L 9 81 L 0 94 L -9 81 Z", fill=GOLD_LINE))
    g.append("</g>")
    return "\n".join(g)

# ---------- snake: ouroboros ring around a crescent moon ----------
# the lion is the sun; the snake is the moon. Fully contained in the teal lobe.
SCX, SCY = 0, r
def snake():
    g = [f'<g transform="translate({SCX},{SCY})">']
    RING, SW = 100, 27
    HEAD_A, TAIL_A = -64, -116          # gap at the top; head right end, tail left end
    # body: from the head end, the long way round (through the bottom) to the tail end
    steps = 120
    d = []
    sweep = 360 - (HEAD_A - TAIL_A)          # everything except the top gap
    for i in range(steps + 1):
        a = HEAD_A + sweep * (i / steps)     # increasing angle = clockwise on screen
        x, y = pt(a, RING)
        d.append(f"{'M' if i == 0 else 'L'} {P(x, y)}")
    g.append(path(" ".join(d), stroke=DARK, sw=SW))
    # tail: taper to a point past the tail end, curving into the gap
    t0o = pt(TAIL_A, RING + SW / 2); t0i = pt(TAIL_A, RING - SW / 2)
    tipa = TAIL_A + 26
    tip = pt(tipa, RING - 4)
    c_o = pt(TAIL_A + 14, RING + SW * 0.36)
    c_i = pt(TAIL_A + 14, RING - SW * 0.36)
    g.append(path(f"M {P(*t0o)} Q {P(*c_o)} {P(*tip)} Q {P(*c_i)} {P(*t0i)} Z", fill=DARK))
    # head at the head end, facing the tail across the gap (tangent, decreasing angle)
    hx, hy = pt(HEAD_A, RING)
    ha = math.radians(HEAD_A)
    ang = math.degrees(math.atan2(-math.cos(ha), math.sin(ha)))
    g.append(f'<g transform="translate({P(hx, hy).replace(" ", ",")}) rotate({fmt(ang)})">')
    g.append(path("M -8 -18 C 28 -20 48 -9 55 0 C 48 9 28 20 -8 18 Z", fill=DARK))
    g.append(f'<circle cx="26" cy="-6" r="7" fill="{GOLD_A}"/>')     # gold eye: the second seed
    g.append(path("M 55 0 L 68 0 M 68 0 L 77 -6 M 68 0 L 77 6", stroke=TEAL_LINE, sw=4.5))
    g.append("</g>")
    # the crescent moon inside the ring, opening toward the lion (up)
    g.append('<g transform="rotate(24)">'
             + path("M 15 -48 A 50 50 0 1 0 15 48 A 63 63 0 0 1 15 -48 Z", fill=DARK)
             + "</g>")
    # a small four-point star in the crescent's hollow
    g.append(path("M 30 -8 L 35 4 L 47 9 L 35 14 L 30 26 L 25 14 L 13 9 L 25 4 Z", fill=DARK))
    g.append("</g>")
    return "\n".join(g)

# ---------- outer ring + 12 time-ticks ----------
def ring():
    g = [f'<circle cx="0" cy="0" r="388" fill="none" stroke="{GOLD_LINE}" stroke-width="3" opacity="0.7"/>']
    for i in range(12):
        a = -90 + i * 30
        cx, cy = pt(a, 388)
        col = GOLD_A if i % 2 == 0 else TEAL_A
        g.append(f'<g transform="translate({fmt(cx)},{fmt(cy)}) rotate({a})">'
                 f'<path d="M 0 -8 L 5.5 0 L 0 8 L -5.5 0 Z" fill="{col}"/></g>')
    return "\n".join(g)

# ---------- shared pieces ----------
DEFS = f'''<defs>
  <radialGradient id="bg" cx="50%" cy="42%" r="75%">
    <stop offset="0%" stop-color="{BG_A}"/><stop offset="100%" stop-color="{BG_B}"/>
  </radialGradient>
  <linearGradient id="gold" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0%" stop-color="{GOLD_A}"/><stop offset="100%" stop-color="{GOLD_B}"/>
  </linearGradient>
  <linearGradient id="teal" x1="0" y1="1" x2="0" y2="0">
    <stop offset="0%" stop-color="{TEAL_A}"/><stop offset="100%" stop-color="{TEAL_B}"/>
  </linearGradient>
</defs>'''

def emblem():
    """The full emblem group, centered on (0,0), outer radius ~396."""
    return (f"{ring()}\n"
            f'<path d="{gold_half}" fill="url(#gold)"/>\n'
            f'<path d="{teal_half}" fill="url(#teal)"/>\n'
            f"{lion()}\n{snake()}")

# ---------- wordmark: hand-drawn monoline letters (no font dependency) ----------
# each letter lives in a 70x100 box, drawn as strokes
LETTERS = {
    "Z": "M 2 0 L 68 0 L 2 100 L 68 100",
    "U": "M 2 0 L 2 60 C 2 88 14 100 35 100 C 56 100 68 88 68 60 L 68 0",
    "R": "M 2 100 L 2 0 L 42 0 C 62 0 68 11 68 26 C 68 41 62 52 42 52 L 2 52 M 44 52 L 68 100",
    "V": "M 2 0 L 35 100 L 68 0",
    "A": "M 2 100 L 35 0 L 68 100 M 22 62 L 48 62",
    "N": "M 2 100 L 2 0 L 68 100 L 68 0",
    "O": "M 35 0 C 14 0 4 18 4 50 C 4 82 14 100 35 100 C 56 100 66 82 66 50 C 66 18 56 0 35 0 Z",
    "S": "M 62 16 C 52 2 22 -2 12 14 C 2 30 22 40 35 45 C 50 51 68 60 60 80 C 52 100 18 102 6 88",
}

def word(text, x, y, scale=1.0, color=GOLD_LINE, sw=13, advance=112):
    g = [f'<g transform="translate({fmt(x)},{fmt(y)}) scale({scale})">']
    cx = 0
    for ch in text:
        if ch == " ":
            cx += advance * 0.55
            continue
        g.append(f'<g transform="translate({fmt(cx)},0)">'
                 + path(LETTERS[ch], stroke=color, sw=sw) + "</g>")
        cx += advance
    g.append("</g>")
    return "\n".join(g)

def word_width(text, scale=1.0, advance=112):
    w = 0
    for ch in text:
        w += advance * (0.55 if ch == " " else 1)
    return (w - (advance - 70)) * scale   # last letter has no trailing gap

# ---------- deterministic starfield for the wallpaper ----------
def stars(w, h, cx, cy, keepout, n=170, seed=20260707):
    s = seed
    def rnd():
        nonlocal s
        s = (s * 1103515245 + 12345) & 0x7FFFFFFF
        return s / 0x7FFFFFFF
    g = []
    for _ in range(n):
        x, y = rnd() * w, rnd() * h
        if math.hypot(x - cx, y - cy) < keepout:
            continue
        rad = 0.8 + rnd() * 1.9
        o = 0.12 + rnd() * 0.5
        col = "#cfd8ea" if rnd() < 0.72 else (GOLD_A if rnd() < 0.6 else TEAL_A)
        g.append(f'<circle cx="{fmt(x)}" cy="{fmt(y)}" r="{fmt(rad)}" fill="{col}" opacity="{fmt(o)}"/>')
    return "\n".join(g)

# ---------- file 1: the emblem ----------
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
{DEFS}
<rect width="1024" height="1024" fill="url(#bg)"/>
<g transform="translate(512,512)">
{emblem()}
</g>
</svg>'''
with open("zurvan-logo.svg", "w") as f:
    f.write(svg)
print("wrote zurvan-logo.svg")

# ---------- file 2: vertical lockup with the wordmark ----------
name = "ZURVAN"
nw = word_width(name)
wm = word(name, 512 - nw / 2, 862)
osw = word_width("OS", scale=0.34)
os_wm = word("OS", 512 - osw / 2, 1000, scale=0.34, color=TEAL_LINE, sw=15)
rule_y, gap = 1017, 46
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1180" width="1024" height="1180">
{DEFS}
<rect width="1024" height="1180" fill="url(#bg)"/>
<g transform="translate(512,415) scale(0.82)">
{emblem()}
</g>
{wm}
{os_wm}
<path d="M {fmt(512 - osw/2 - gap - 130)} {rule_y} L {fmt(512 - osw/2 - gap)} {rule_y}" stroke="{GOLD_LINE}" stroke-width="3" opacity="0.6"/>
<path d="M {fmt(512 + osw/2 + gap)} {rule_y} L {fmt(512 + osw/2 + gap + 130)} {rule_y}" stroke="{GOLD_LINE}" stroke-width="3" opacity="0.6"/>
</svg>'''
with open("zurvan-wordmark.svg", "w") as f:
    f.write(svg)
print("wrote zurvan-wordmark.svg")

# ---------- file 3: desktop wallpaper 2560x1440 ----------
W, H = 2560, 1440
ecx, ecy = W / 2, 640
nw = word_width(name, scale=0.62)
wm = word(name, ecx - nw / 2, 1128, scale=0.62, sw=14)
osw = word_width("OS", scale=0.22)
os_wm = word("OS", ecx - osw / 2, 1218, scale=0.22, color=TEAL_LINE, sw=16)
orbits = "\n".join(
    f'<circle cx="{ecx}" cy="{ecy}" r="{rr}" fill="none" stroke="{col}" stroke-width="1.5" opacity="{op}"/>'
    for rr, col, op in [(520, GOLD_LINE, 0.10), (680, TEAL_LINE, 0.07), (880, GOLD_LINE, 0.05), (1120, TEAL_LINE, 0.035)]
)
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">
{DEFS}
<radialGradient id="wbg" cx="50%" cy="44%" r="85%">
  <stop offset="0%" stop-color="{BG_A}"/><stop offset="100%" stop-color="#070910"/>
</radialGradient>
<radialGradient id="vign" cx="50%" cy="46%" r="72%">
  <stop offset="62%" stop-color="#000000" stop-opacity="0"/>
  <stop offset="100%" stop-color="#000000" stop-opacity="0.45"/>
</radialGradient>
<rect width="{W}" height="{H}" fill="url(#wbg)"/>
{stars(W, H, ecx, ecy, 440)}
{orbits}
<g transform="translate({ecx},{ecy}) scale(0.92)">
{emblem()}
</g>
{wm}
{os_wm}
<rect width="{W}" height="{H}" fill="url(#vign)"/>
</svg>'''
with open("zurvan-wallpaper.svg", "w") as f:
    f.write(svg)
print("wrote zurvan-wallpaper.svg")
