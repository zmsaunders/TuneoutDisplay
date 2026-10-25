"""
TuneoutDisplay v2 — display-only housing, slab layout (parametric, CadQuery).

The Pi stays mounted on the back of the display with the HAT stacked on it
(one 45 mm deep module). The housing is a tilted slab around that module,
sitting on a chin that holds the speaker firing forward.

Coordinates (assembled):
  X = width  (+X = viewer's right facing the screen)
  Y = depth  (0 = front of the chin, +Y toward the back)
  Z = height (0 = underside of the base)
Face-local coordinates (used to build the slab, then mapped by to_face):
  x = width, w = depth into the slab (0 = front of bezel), v = up the face (0 = slab bottom)

Parts (STLs are exported in print orientation):
  front — bezel + slab side walls + slab top. Print FACE DOWN.
  base  — chin: floor/foot, speaker grille wall, speaker cradle, tabs. Print floor down.
  rear  — slab back cover with vents + USB-C exit. Print flat.
  bar   — panel retainer bar (print 2). Print flat.
"""
import math
import cadquery as cq

# ── Parameters ───────────────────────────────────────────────────────────────
W = 176.0          # outer width
T = 2.4            # wall thickness
FLOOR = 3.0        # base floor thickness
THETA = 20.0       # screen tilt back from vertical (deg)
ZS = 56.0          # height of the chin's front wall (= bezel bottom edge)
DB = 85.0          # base footprint depth (stability against touches)

# Display panel (measured)
PW, PH, PT = 166.0, 100.0, 10.0
BEZ_L, BEZ_R, BEZ_B, BEZ_T = 3.0, 6.0, 10.0, 4.0     # black border, viewed from the front
C = 0.4
MB = MT = 6.0      # bezel margin below / above the panel

# Display + Pi + HAT module (measured)
STACK = 45.0       # glass front to tallest point on the HAT
STACK_CLR = 3.0
# Pi position on the panel back, measured looking at the BACK: 33 from left, 31 from top
PI_L, PI_W = 85.0, 56.0
PI_FROM_BACK_LEFT, PI_FROM_TOP = 33.0, 31.0
USBC_FROM_SD_END = 11.2   # USB-C centre from the Pi's SD/DSI end (right-hand end seen from the back)

# Speaker (measured enclosed box speaker)
SPK_W, SPK_H, SPK_D = 100.0, 45.0, 22.0
GASKET = 1.5

th = math.radians(THETA)
S = T + STACK + STACK_CLR + T                 # slab thickness (bezel front to back cover outer face)
LF = MB + PH + 2 * C + MT + T                 # slab length up the face (incl. top wall)
H = ZS + LF * math.cos(th)                    # height of the slab's top front edge
Y_SB = S * math.cos(th)                       # slab bottom-back corner
Z_SB = ZS - S * math.sin(th)

# Panel-relative positions (panel lower-left corner, front view, is at x=-PW/2, v=MB+C)
PANEL_V0 = MB + C
pi_x0 = -PW / 2 + (PW - PI_FROM_BACK_LEFT - PI_L)        # front-view left edge of the Pi board
pi_v1 = PANEL_V0 + PH - PI_FROM_TOP                      # top edge of the Pi board
pi_v0 = pi_v1 - PI_W
usbc_x = pi_x0 + USBC_FROM_SD_END                        # SD end is front-view LEFT
usbc_v = pi_v1 + 12.0                                    # right-angle plug body above the port


def to_face(shape):
    """Face-local (x, w→+Y, v→+Z) to assembled coordinates."""
    return shape.rotate((0, 0, 0), (1, 0, 0), -THETA).translate((0, 0, ZS))


def z_seam(y):
    """Slab bottom plane (perpendicular to the face) — the front/base split line."""
    return ZS - y * math.tan(th)


def lbox(x0, x1, w0, w1, v0, v1):
    """Axis-aligned box in face-local coordinates (not yet mapped)."""
    return (cq.Workplane("XY").box(x1 - x0, w1 - w0, v1 - v0, centered=False)
            .translate((x0, w0, v0)))


def lcyl_w(x, v, r, w0, w1):
    """Cylinder along w in face-local coordinates."""
    return (cq.Workplane("XZ").workplane(offset=-w0).center(x, v).circle(r).extrude(-(w1 - w0)))


TAB_YS = (20.0, 40.0)   # tabs must sit behind the panel (w > panel back) inside the slab
def screw_z(y):
    return z_seam(y) + 7.0


BOSS_X = W / 2 - T - 3.7   # slight overlap into the wall avoids tangent-face boolean failures
BOSS_VS = (22.0, LF - T - 8.0)
BOSS_W0 = T + PT + 1.0          # bosses start just behind the panel (cone 4 mm, then cylinder)


# ── FRONT (bezel + slab sides + slab top) ───────────────────────────────────
def make_front():
    f = lbox(-W / 2, W / 2, 0, T, 0, LF)                               # bezel plate
    f = f.union(lbox(-W / 2, -W / 2 + T, 0, S - T, 0, LF))             # left wall
    f = f.union(lbox(W / 2 - T, W / 2, 0, S - T, 0, LF))               # right wall
    f = f.union(lbox(-W / 2, W / 2, 0, S - T, LF - T, LF))             # top wall
    # window = visible screen area
    f = f.cut(lbox(-PW / 2 + BEZ_L, PW / 2 - BEZ_R, -1, T + 1,
                   PANEL_V0 + BEZ_B, PANEL_V0 + PH - BEZ_T))
    # panel locating rim
    ox, oz = PW / 2 + C, PH + 2 * C
    rim = (cq.Workplane("XZ").rect(2 * ox + 3.2, oz + 3.2).rect(2 * ox, oz)
           .extrude(-6.0).translate((0, T, MB + oz / 2)))
    f = f.union(rim)
    # retainer posts (bars clamp the panel's top & bottom edges)
    for v in (MB / 2, MB + oz + MT / 2):
        for x in (-48, 48):
            f = f.union(lcyl_w(x, v, 3.0, T, T + PT + 1.0)).cut(lcyl_w(x, v, 1.25, T, T + PT + 2.0))
    # back-cover bosses: 45° cone then cylinder, along w (vertical when printed face down)
    for v in BOSS_VS:
        for x in (-BOSS_X, BOSS_X):
            cone = (cq.Workplane("XZ").workplane(offset=-BOSS_W0).center(x, v).circle(0.3)
                    .workplane(offset=-4.0).circle(4.0).loft())
            f = f.union(cone).union(lcyl_w(x, v, 4.0, BOSS_W0 + 4.0, S - T))
            f = f.cut(lcyl_w(x, v, 2.0, S - T - 7.0, S - T + 0.1))     # heat-set insert
    f = to_face(f)
    # side screws into the base tabs (countersunk, horizontal along X)
    for y in TAB_YS:
        zc = screw_z(y)
        f = f.cut(cq.Workplane("YZ").center(y, zc).circle(1.7).extrude(W + 2).translate((-W / 2 - 1, 0, 0)))
        cs = (cq.Workplane("YZ").center(y, zc).circle(1.7).workplane(offset=1.6).circle(3.3).loft()
              .translate((W / 2 - 1.6, 0, 0)))
        f = f.cut(cs).cut(cs.mirror("YZ"))
    return f


# ── BASE (chin) ──────────────────────────────────────────────────────────────
def side_prism(width, pts):
    return (cq.Workplane("YZ").polyline(pts).close().extrude(width).translate((-width / 2, 0, 0)))


def make_base():
    b = cq.Workplane("XY").box(W, DB, FLOOR, centered=(True, False, False))
    walls_pts = [(0, FLOOR), (Y_SB, FLOOR), (Y_SB, Z_SB), (0, ZS)]
    for sgn in (-1, 1):
        b = b.union(side_prism(T, walls_pts).translate((sgn * (W / 2 - T / 2), 0, 0)))
    iw = W - 2 * T
    # front speaker wall with grille
    fw = cq.Workplane("XY").box(iw, T, ZS - FLOOR, centered=(True, False, False)).translate((0, 0, FLOOR))
    d, pitch = 3.0, 4.4
    gx, gz0, gz1 = SPK_W / 2 - 4, FLOOR + 4, FLOOR + SPK_H - 4
    pts, row, z = [], 0, gz0 + d / 2
    while z <= gz1 - d / 2:
        x = -gx + d / 2 + (pitch / 2 if row % 2 else 0.0)
        while x <= gx - d / 2:
            pts.append((x, z)); x += pitch
        z += pitch * math.sqrt(3) / 2; row += 1
    fw = fw.cut(cq.Workplane("XZ").pushPoints(pts).circle(d / 2).extrude(-T * 3).translate((0, -T, 0)))
    b = b.union(fw)
    # rear wall of the chin, up to the slab bottom, with intake slots
    rw = side_prism(iw, [(Y_SB - T, FLOOR), (Y_SB, FLOOR), (Y_SB, Z_SB), (Y_SB - T, z_seam(Y_SB - T))])
    slots = [(x, FLOOR + 6 + 12) for x in range(-70, 71, 7)]
    rw = rw.cut(cq.Workplane("XZ").pushPoints(slots).slot2D(22.0, 3.0, angle=90)
                .extrude(-T * 3).translate((0, Y_SB - 2 * T, 0)))
    b = b.union(rw)
    # trim everything above the slab-bottom plane (keeps the bezel's bottom edge clear)
    above = side_prism(W + 2, [(-5, ZS + 5 * math.tan(th)), (DB + 5, z_seam(DB + 5)), (DB + 5, 400), (-5, 400)])
    b = b.cut(above)
    # speaker cradle
    y0 = T + GASKET
    y1 = y0 + SPK_D + 0.5
    for sgn in (-1, 1):
        b = b.union(cq.Workplane("XY").box(2.0, y1 - T + 2.0, 14.0, centered=(True, False, False))
                    .translate((sgn * (SPK_W / 2 + 1.5), T, FLOOR)))
    b = b.union(cq.Workplane("XY").box(SPK_W + 7.0, 2.0, 14.0, centered=(True, False, False))
                .translate((0, y1, FLOOR)))
    # tabs rising above the seam inside the slab side walls (heat-set inserts along X)
    for y in TAB_YS:
        for sgn in (-1, 1):
            tab = (cq.Workplane("XY").box(7.0, 10.0, screw_z(y) + 5.0 - FLOOR, centered=(True, True, False))
                   .translate((sgn * (iw / 2 - 3.5 - 0.2), y, FLOOR)))
            hole = (cq.Workplane("YZ").center(y, screw_z(y)).circle(2.0).extrude(6.0)
                    .translate((sgn * (iw / 2 - 0.2) - (6.0 if sgn > 0 else 0.0), 0, 0)))
            b = b.union(tab).cut(hole)
    # foot recesses for 12 mm stick-on bumpers
    for x in (-W / 2 + 12, W / 2 - 12):
        for y in (10, DB - 10):
            b = b.cut(cq.Workplane("XY").center(x, y).circle(6.3).extrude(0.8))
    return b


# ── REAR (slab back cover) ───────────────────────────────────────────────────
def make_rear():
    iw = W - 2 * T - 0.4
    r = lbox(-iw / 2, iw / 2, S - T, S, 0.2, LF - T - 0.2)
    # exhaust vents over the Pi + HAT and above it (slots along v)
    xs = [x for x in range(-72, 73, 7)]
    v0, v1 = pi_v0 + 4, LF - T - 8
    slots = (cq.Workplane("XZ").pushPoints([(x, (v0 + v1) / 2) for x in xs])
             .slot2D(v1 - v0, 3.0, angle=90).extrude(-T * 3).translate((0, S - 2 * T, 0)))
    r = r.cut(slots)
    # USB-C exit for a right-angle (up/down-angled) cable
    r = r.cut(lbox(usbc_x - 8, usbc_x + 8, S - 2 * T, S + 1, usbc_v - 7, usbc_v + 7))
    for v in BOSS_VS:
        for x in (-BOSS_X, BOSS_X):
            r = r.cut(lcyl_w(x, v, 1.7, S - 2 * T, S + 1))
    return to_face(r)


# ── RETAINER BAR ─────────────────────────────────────────────────────────────
def make_bar():
    bar = cq.Workplane("XY").box(110.0, 13.0, 3.0, centered=(True, False, False))
    for x in (-48, 48):
        bar = bar.cut(cq.Workplane("XY").center(x, 3.0).circle(1.7).extrude(10).translate((0, 0, -2)))
    return bar


PRINT_ROT = {"front": 90.0 + THETA, "rear": -(90.0 - THETA)}

if __name__ == "__main__":
    import sys, os
    out = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(out, exist_ok=True)
    parts = {"front": make_front(), "base": make_base(), "rear": make_rear(), "bar": make_bar()}
    for n, p in parts.items():
        cq.exporters.export(p, f"{out}/display_only_{n}.step")
        q = p.rotate((0, 0, 0), (1, 0, 0), PRINT_ROT[n]) if n in PRINT_ROT else p
        bb = q.val().BoundingBox()
        q = q.translate((-(bb.xmin + bb.xmax) / 2, -(bb.ymin + bb.ymax) / 2, -bb.zmin))
        cq.exporters.export(q, f"{out}/display_only_{n}.stl", tolerance=0.05, angularTolerance=0.2)
    print(f"W={W} S={S:.1f} LF={LF:.1f} H={H:.1f} base depth={DB} slab bottom corner=({Y_SB:.1f},{Z_SB:.1f})")
    print(f"Pi board front-view x {pi_x0:.1f}..{pi_x0+PI_L:.1f}, v {pi_v0:.1f}..{pi_v1:.1f}; USB-C x={usbc_x:.1f}")
