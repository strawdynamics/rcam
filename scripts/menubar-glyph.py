#!/usr/bin/env python3
"""Generate the RCam menu bar glyph: outlined (idle) and filled (streaming).

Writes the two SF Symbols templates straight into RCam/Assets.xcassets. Run it
after changing any parameter below, then scripts/build.sh. Set PREVIEW_DIR to
also drop flat single-glyph SVGs somewhere for rasterising at menu bar sizes.

Glyph local space: y down, pins left, lens flaring right.

Holes are wound opposite to the silhouette rather than relying on
fill-rule="evenodd": Xcode's symbol compiler fills with nonzero winding and
drops the rule, which collapsed an earlier version to a solid blob.
"""
import math, os

H       = 100.0   # glyph height
BODY_W  = 108.0   # body width (the lens hangs off its right edge)
LENS_L  = 46.0    # lens length
W       = BODY_W + LENS_L
BODY_R  = 18.0    # body corner radius
SW      = 10.0    # stroke weight (also the pin bar thickness)
JOINT_H = 48.0    # lens height where it meets the body
TIP_H   = 76.0    # lens height at its outer end
TIP_R   = 7.0     # lens tip corner radius
TIP_R_I = 4.0     # ...on the inner offset path

PIN_N, PIN_X, PIN_L, PIN_T, PIN_G, PIN_R = 4, 18.0, 28.0, 10.0, 8.0, 2.0

CY = H / 2
jt, jb = CY - JOINT_H / 2, CY + JOINT_H / 2
tt, tb = CY - TIP_H / 2,  CY + TIP_H / 2

def f(v):
    return f"{v:.3f}".rstrip("0").rstrip(".")

def L(x, y):            return ("L", x, y)
def A(r, sweep, x, y):  return ("A", r, sweep, x, y)

def emit(start, segs, reverse=False):
    """Serialise a closed subpath, optionally reversing its winding."""
    if not reverse:
        out = [f"M {f(start[0])},{f(start[1])}"]
        for s in segs:
            out.append(f"L {f(s[1])},{f(s[2])}" if s[0] == "L"
                       else f"A {f(s[1])},{f(s[1])} 0 0 {s[2]} {f(s[3])},{f(s[4])}")
    else:
        pts = [start] + [(s[1], s[2]) if s[0] == "L" else (s[3], s[4]) for s in segs]
        out = [f"M {f(pts[-1][0])},{f(pts[-1][1])}"]
        for i in range(len(segs) - 1, -1, -1):
            tx, ty = pts[i]
            s = segs[i]
            out.append(f"L {f(tx)},{f(ty)}" if s[0] == "L"
                       else f"A {f(s[1])},{f(s[1])} 0 0 {1 - s[2]} {f(tx)},{f(ty)}")
    return " ".join(out) + " Z"

ux, uy = (lambda dx, dy: (dx / math.hypot(dx, dy), dy / math.hypot(dx, dy)))(LENS_L, tt - jt)

def outer():
    ax, ay = W - TIP_R * ux, tt - TIP_R * uy
    bx, by = W - TIP_R * ux, tb + TIP_R * uy
    return (BODY_R, 0.0), [
        L(BODY_W - BODY_R, 0.0),
        A(BODY_R, 1, BODY_W, BODY_R),
        L(BODY_W, jt), L(ax, ay),
        A(TIP_R, 1, W, tt + TIP_R),
        L(W, tb - TIP_R),
        A(TIP_R, 1, bx, by),
        L(BODY_W, jb), L(BODY_W, H - BODY_R),
        A(BODY_R, 1, BODY_W - BODY_R, H),
        L(BODY_R, H),
        A(BODY_R, 1, 0.0, H - BODY_R),
        L(0.0, BODY_R),
        A(BODY_R, 1, BODY_R, 0.0),
    ]

def inner():
    """The outer silhouette offset inward by SW: every edge is a line or an
    arc, so each is offset analytically and the corners re-intersected."""
    ir = BODY_R - SW
    ix1, iy0, iy1, ixt = BODY_W - SW, SW, H - SW, W - SW
    nx, ny = -uy, ux                                   # inward normal, top slant
    px, py = BODY_W + SW * nx, jt + SW * ny
    slant = lambda x: py + (x - px) / ux * uy
    ty_tip, ty_joint = slant(ixt), slant(ix1)
    by_tip, by_joint = H - ty_tip, H - ty_joint
    cax, cay = ixt - TIP_R_I * ux, ty_tip - TIP_R_I * uy
    cbx, cby = ixt - TIP_R_I * ux, by_tip + TIP_R_I * uy
    return (SW + ir, iy0), [
        L(ix1 - ir, iy0),
        A(ir, 1, ix1, iy0 + ir),
        L(ix1, ty_joint), L(cax, cay),
        A(TIP_R_I, 1, ixt, ty_tip + TIP_R_I),
        L(ixt, by_tip - TIP_R_I),
        A(TIP_R_I, 1, cbx, cby),
        L(ix1, by_joint), L(ix1, iy1 - ir),
        A(ir, 1, ix1 - ir, iy1),
        L(SW + ir, iy1),
        A(ir, 1, SW, iy1 - ir),
        L(SW, iy0 + ir),
        A(ir, 1, SW + ir, iy0),
    ]

def pin(y):
    x, l, t, r = PIN_X, PIN_L, PIN_T, PIN_R
    return (x + r, y), [
        L(x + l - r, y),
        A(r, 1, x + l, y + r),
        L(x + l, y + t - r),
        A(r, 1, x + l - r, y + t),
        L(x + r, y + t),
        A(r, 1, x, y + t - r),
        L(x, y + r),
        A(r, 1, x + r, y),
    ]

PIN_Y = [CY - (PIN_N * PIN_T + (PIN_N - 1) * PIN_G) / 2 + i * (PIN_T + PIN_G)
         for i in range(PIN_N)]

# Outlined: silhouette CW, interior CCW (a hole), pins CW (solid again).
# Filled:   silhouette CW, pins CCW (knocked out of the slab).
OUTLINE = " ".join([emit(*outer()), emit(*inner(), reverse=True)]
                   + [emit(*pin(y)) for y in PIN_Y])
FILLED  = " ".join([emit(*outer())]
                   + [emit(*pin(y), reverse=True) for y in PIN_Y])

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CATALOG = os.path.join(ROOT, "RCam", "Assets.xcassets")
PREVIEW_DIR = os.environ.get("PREVIEW_DIR")

for name, d in (("preview-outline.svg", OUTLINE), ("preview-fill.svg", FILLED)):
    if not PREVIEW_DIR:
        continue
    open(os.path.join(PREVIEW_DIR, name), "w").write(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {f(W)} {f(H)}" '
        f'width="{f(W)}" height="{f(H)}">'
        f'<path fill="currentColor" d="{d}"/></svg>')

WEIGHTS = ["Ultralight", "Thin", "Light", "Regular", "Medium",
           "Semibold", "Bold", "Heavy", "Black"]
SCALES  = [("S", 154.0), ("M", 176.0), ("L", 198.0)]   # cap height per scale
CANVAS_W, CANVAS_H = 3300.0, 2200.0
COL_W, ROW_H = CANVAS_W / len(WEIGHTS), CANVAS_H / len(SCALES)
BEARING = 8.0
# The glyph is drawn larger than the capline/baseline box. Correct SF Symbol
# metrics put it at the same height as stock video.fill, which reads small for
# a wide glyph sitting beside full-height neighbours.
GLYPH_SCALE = float(os.environ.get("GLYPH_SCALE", "1.30"))

def template(d):
    guides, syms = [], []
    for row, (scale, cap) in enumerate(SCALES):
        k = cap / H * GLYPH_SCALE
        cap_y = row * ROW_H + (ROW_H - cap) / 2
        art_y = cap_y - (H * k - cap) / 2      # centre the overshoot
        ref_cx = (WEIGHTS.index("Regular") + 0.5) * COL_W
        lm, rm = ref_cx - (W / 2 + BEARING) * k, ref_cx + (W / 2 + BEARING) * k
        guides += [
            f'<line id="Capline-{scale}" x1="0" y1="{f(cap_y)}" x2="{f(CANVAS_W)}" y2="{f(cap_y)}"/>',
            f'<line id="Baseline-{scale}" x1="0" y1="{f(cap_y + cap)}" x2="{f(CANVAS_W)}" y2="{f(cap_y + cap)}"/>',
            f'<line id="left-margin-{scale}" x1="{f(lm)}" y1="0" x2="{f(lm)}" y2="{f(CANVAS_H)}"/>',
            f'<line id="right-margin-{scale}" x1="{f(rm)}" y1="0" x2="{f(rm)}" y2="{f(CANVAS_H)}"/>',
        ]
        # Every cell carries the identical drawing: the menu bar renders one
        # weight, and identical cells make the symbol independent of however
        # the compiler picks its reference cell.
        for col, weight in enumerate(WEIGHTS):
            tx = (col + 0.5) * COL_W - (W / 2) * k
            syms.append(
                f'<g id="{weight}-{scale}" transform="translate({f(tx)},{f(art_y)}) scale({f(k)})">'
                f'<path d="{d}"/></g>')
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" version="1.1" '
            f'width="{f(CANVAS_W)}px" height="{f(CANVAS_H)}px" '
            f'viewBox="0 0 {f(CANVAS_W)} {f(CANVAS_H)}">\n<g id="Notes"/>\n'
            '<g id="Guides" fill="none" stroke="#00AEEF" stroke-width="0.5">\n  '
            + "\n  ".join(guides) + '\n</g>\n<g id="Symbols">\n  '
            + "\n  ".join(syms) + '\n</g>\n</svg>\n')

for name, d in (("rcam.connector", OUTLINE), ("rcam.connector.fill", FILLED)):
    path = os.path.join(CATALOG, name + ".symbolset", name + ".svg")
    open(path, "w").write(template(d))
    print("wrote", os.path.relpath(path, ROOT))
print(f"glyph {f(W)}x{f(H)} = {W/H:.2f}:1 at {GLYPH_SCALE}x cap height")
