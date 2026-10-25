"""
TuneoutDisplay v2 — display-only housing, slab layout, softened (parametric, CadQuery).

The Pi stays mounted on the back of the display with the HAT stacked on it
(one 45 mm deep module). The housing is a tilted slab around that module on a
chin that holds the speaker firing forward.

Styling, chosen to stay support-free:
  * slab top corners: R10 rounds (vertical when the front prints face down)
  * bezel edges: "teardrop" rounds (45° at the bed, blending into a radius)
  * chin front curves back into the 20° screen face (R50 blend, no crease)
  * rear foot is a 45° ramp up to the back cover
  * back cover overlays the walls with a rounded outer edge

Coordinates (assembled):  X width (+X = viewer's right), Y depth (0 = chin front), Z up.
Face-local (slab build):   x width, w depth into slab (0 = bezel front), v up the face (0 = slab bottom).

Parts (STLs exported in print orientation):
  front — bezel + slab walls + top. Print FACE DOWN.
  base  — chin: floor, curved speaker grille wall, 45° rear ramp, tabs. Print floor down.
  rear  — back cover. Print OUTER FACE UP.
  bar   — panel retainer bar (print 2).
"""
import math
import cadquery as cq

# ── Parameters ───────────────────────────────────────────────────────────────
W = 176.0
T = 2.4
THETA = 20.0
ZS = 56.0          # height where the chin meets the screen face
RB = 50.0          # chin-to-screen blend radius
R_TOP = 10.0       # slab top corner radius
R_EDGE = 4.0       # bezel side edges (teardrop) and chin front edges (round)
R_TOPEDGE = 6.0    # bezel top edge (teardrop)
R_COVER = 2.0      # back cover outer edge

PW, PH, PT = 166.0, 100.0, 10.0
BEZ_L, BEZ_R, BEZ_B, BEZ_T = 3.0, 6.0, 10.0, 4.0
C = 0.4
MB = MT = 6.0

STACK, STACK_CLR = 45.0, 3.0
PI_L, PI_W = 85.0, 56.0
PI_FROM_BACK_LEFT, PI_FROM_TOP = 33.0, 31.0
USBC_FROM_SD_END = 11.2

SPK_W, SPK_H, SPK_D = 100.0, 45.0, 22.0
GASKET = 1.5

th = math.radians(THETA)
FLOOR = T
S = T + STACK + STACK_CLR + T
LF = MB + PH + 2 * C + MT + T
FY = RB * (1 - math.cos(th))                 # Y of the screen face's bottom edge
Z_B = ZS - RB * math.sin(th)                 # where the chin front stops being vertical
H = ZS + LF * math.cos(th)
SB = (FY + S * math.cos(th), ZS - S * math.sin(th))     # slab bottom-back corner
RE = (SB[0] + SB[1], 0.0)                               # end of the 45° ramp
DEPTH = RE[0]

PANEL_V0 = MB + C
pi_x0 = -PW / 2 + (PW - PI_FROM_BACK_LEFT - PI_L)
pi_v1 = PANEL_V0 + PH - PI_FROM_TOP
pi_v0 = pi_v1 - PI_W
usbc_x = pi_x0 + USBC_FROM_SD_END
usbc_v = pi_v1 + 12.0

C45 = math.cos(math.radians(45))
S225, C225 = math.sin(math.radians(22.5)), math.cos(math.radians(22.5))


def to_face(shape):
    return shape.rotate((0, 0, 0), (1, 0, 0), -THETA).translate((0, FY, ZS))


def z_seam(y):
    return ZS - (y - FY) * math.tan(th)


def lbox(x0, x1, w0, w1, v0, v1):
    return cq.Workplane("XY").box(x1 - x0, w1 - w0, v1 - v0, centered=False).translate((x0, w0, v0))


def lcyl_w(x, v, r, w0, w1):
    return cq.Workplane("XZ").workplane(offset=-w0).center(x, v).circle(r).extrude(-(w1 - w0))


def rounded_top_rect_xv(half_w, v0, v1, r, w0, w1):
    """x-v outline with the two top corners rounded, extruded along w (face-local)."""
    wp = (cq.Workplane("XZ").workplane(offset=-w0)
          .moveTo(-half_w, v0).lineTo(half_w, v0).lineTo(half_w, v1 - r)
          .threePointArc((half_w - r + r * C45, v1 - r + r * C45), (half_w - r, v1))
          .lineTo(-half_w + r, v1)
          .threePointArc((-half_w + r - r * C45, v1 - r + r * C45), (-half_w, v1 - r))
          .close())
    return wp.extrude(-(w1 - w0))


def teardrop_xw(half_w, w1, r, v0, v1):
    """x-w section, front corners teardrop (45° at w=0), extruded along v (face-local)."""
    a = r * (1 - C45)
    wp = (cq.Workplane("XY").workplane(offset=v0)
          .moveTo(-half_w + 2 * a, 0).lineTo(half_w - 2 * a, 0)
          .lineTo(half_w - a, a)
          .threePointArc((half_w - r + r * C225, r - r * S225), (half_w, r))
          .lineTo(half_w, w1).lineTo(-half_w, w1).lineTo(-half_w, r)
          .threePointArc((-half_w + r - r * C225, r - r * S225), (-half_w + a, a))
          .close())
    return wp.extrude(v1 - v0)


def teardrop_wv_top(w1, vtop, r, x_half):
    """w-v section with the (w=0, v=vtop) corner teardropped, extruded along x (face-local)."""
    a = r * (1 - C45)
    wp = (cq.Workplane("YZ").workplane(offset=-x_half)
          .moveTo(0, -5).lineTo(w1, -5).lineTo(w1, vtop).lineTo(r, vtop)
          .threePointArc((r - r * S225, vtop - r + r * C225), (a, vtop - a))
          .lineTo(0, vtop - 2 * a).close())
    return wp.extrude(2 * x_half)


TAB_YS = (FY + 20.0, FY + 40.0)
def screw_z(y):
    return z_seam(y) + 7.0


POST_V_BOT = 3.3                 # posts kept off the slab edges (no tangent faces)
POST_V_TOP = LF - T - 3.3
BOSS_X = W / 2 - T - 3.7
BOSS_VS = (22.0, LF - T - 8.0)
BOSS_W0 = T + PT + 1.0


# ── FRONT ────────────────────────────────────────────────────────────────────
def make_front():
    wb = S - T                                   # walls stop under the back cover
    outer = rounded_top_rect_xv(W / 2, 0, LF, R_TOP, 0, wb)
    outer = outer.intersect(teardrop_xw(W / 2, wb + 1, R_EDGE, -1, LF + 1))
    outer = outer.intersect(teardrop_wv_top(wb + 1, LF, R_TOPEDGE, W / 2 + 1))
    inner = rounded_top_rect_xv(W / 2 - T, -1, LF - T, R_TOP - T, T, S + 1)
    f = outer.cut(inner)
    f = f.cut(lbox(-PW / 2 + BEZ_L, PW / 2 - BEZ_R, -1, T + 1, PANEL_V0 + BEZ_B, PANEL_V0 + PH - BEZ_T))
    ox, oz = PW / 2 + C, PH + 2 * C
    rim = (cq.Workplane("XZ").rect(2 * ox + 3.2, oz + 3.2).rect(2 * ox, oz)
           .extrude(-6.0).translate((0, T, MB + oz / 2)))
    f = f.union(rim)
    for v in (POST_V_BOT, POST_V_TOP):
        for x in (-48, 48):
            f = f.union(lcyl_w(x, v, 3.0, T, T + PT + 1.0)).cut(lcyl_w(x, v, 1.25, T, T + PT + 2.0))
    for v in BOSS_VS:
        for x in (-BOSS_X, BOSS_X):
            cone = (cq.Workplane("XZ").workplane(offset=-BOSS_W0).center(x, v).circle(0.3)
                    .workplane(offset=-4.0).circle(4.0).loft())
            f = f.union(cone).union(lcyl_w(x, v, 4.0, BOSS_W0 + 4.0, wb))
            f = f.cut(lcyl_w(x, v, 2.0, wb - 7.0, wb + 0.1))
    f = to_face(f)
    for y in TAB_YS:
        zc = screw_z(y)
        f = f.cut(cq.Workplane("YZ").center(y, zc).circle(1.7).extrude(W + 2).translate((-W / 2 - 1, 0, 0)))
        cs = (cq.Workplane("YZ").center(y, zc).circle(1.7).workplane(offset=1.6).circle(3.3).loft()
              .translate((W / 2 - 1.6, 0, 0)))
        f = f.cut(cs).cut(cs.mirror("YZ"))
    return f


# ── BASE (chin) ──────────────────────────────────────────────────────────────
def chin_wire(wp):
    mid_a = math.radians(180 - THETA / 2)
    mid = (RB + RB * math.cos(mid_a), Z_B + RB * math.sin(mid_a))
    return (wp.moveTo(0, 0).lineTo(0, Z_B).threePointArc(mid, (FY, ZS))
            .lineTo(*SB).lineTo(*RE).close())


def make_base():
    outer = chin_wire(cq.Workplane("YZ")).extrude(W).translate((-W / 2, 0, 0))

    def pick(e):
        bb = e.BoundingBox()
        if abs(abs(bb.xmin) - W / 2) > 0.01 or abs(bb.xmax - bb.xmin) > 0.01:
            return False
        if bb.zmax < 0.01:
            return False                                         # floor edge (on the bed)
        c = e.Center()
        d = (c.y - FY) * math.sin(th) + (c.z - ZS) * math.cos(th)
        return abs(d) > 0.05                                     # not the seam edge
    sel = [e for e in outer.edges().vals() if pick(e)]
    outer = outer.newObject(sel).fillet(R_EDGE)

    inner_face = chin_wire(cq.Workplane("YZ")).offset2D(-T, kind="intersection")
    inner = inner_face.extrude(W - 2 * T).translate((-(W / 2 - T), 0, 0))
    b = outer.cut(inner)
    # open the seam wall into the slab (side walls stay)
    n_in = (math.cos(th), -math.sin(th))
    u = (math.sin(th), math.cos(th))
    def seam_pt(s, t):
        return (FY + s * n_in[0] - t * u[0], ZS + s * n_in[1] - t * u[1])
    def s_at_ramp(t):
        m = (C45, C45)
        p0 = seam_pt(0, t)
        return (-T - ((p0[0] - RE[0]) * m[0] + (p0[1] - RE[1]) * m[1])) / (n_in[0] * m[0] + n_in[1] * m[1])
    t0, t1 = -0.05, T + 0.05
    quad = [seam_pt(T, t0), seam_pt(s_at_ramp(t0), t0), seam_pt(s_at_ramp(t1), t1), seam_pt(T, t1)]
    b = b.cut(cq.Workplane("YZ").polyline(quad).close().extrude(W - 2 * T).translate((-(W / 2 - T), 0, 0)))

    # grille (horizontal holes; top rows pass through the curved blend)
    d, pitch = 3.0, 4.4
    gx, gz0, gz1 = SPK_W / 2 - 4, FLOOR + 4, FLOOR + SPK_H - 4
    pts, row, z = [], 0, gz0 + d / 2
    while z <= gz1 - d / 2:
        x = -gx + d / 2 + (pitch / 2 if row % 2 else 0.0)
        while x <= gx - d / 2:
            pts.append((x, z)); x += pitch
        z += pitch * math.sqrt(3) / 2; row += 1
    b = b.cut(cq.Workplane("XZ").pushPoints(pts).circle(d / 2).extrude(-10).translate((0, -2, 0)))

    # intake slots through the 45° ramp (vertical cuts running down the ramp)
    ys0, ys1 = SB[0] + 6, RE[0] - 10
    slots = [(x, (ys0 + ys1) / 2) for x in range(-70, 71, 7)]
    b = b.cut(cq.Workplane("XY").pushPoints(slots).slot2D(ys1 - ys0, 3.0, angle=90)
              .extrude(80).translate((0, 0, FLOOR + 0.6)))

    iw = W - 2 * T
    y0 = T + GASKET
    y1 = y0 + SPK_D + 0.5
    for sgn in (-1, 1):
        b = b.union(cq.Workplane("XY").box(2.0, y1 - T + 2.0, 14.0, centered=(True, False, False))
                    .translate((sgn * (SPK_W / 2 + 1.5), T, FLOOR)))
    b = b.union(cq.Workplane("XY").box(SPK_W + 7.0, 2.0, 14.0, centered=(True, False, False))
                .translate((0, y1, FLOOR)))
    for y in TAB_YS:
        for sgn in (-1, 1):
            tab = (cq.Workplane("XY").box(7.0, 10.0, screw_z(y) + 5.0 - FLOOR, centered=(True, True, False))
                   .translate((sgn * (iw / 2 - 3.5 - 0.2), y, FLOOR)))
            hole = (cq.Workplane("YZ").center(y, screw_z(y)).circle(2.0).extrude(6.0)
                    .translate((sgn * (iw / 2 - 0.2) - (6.0 if sgn > 0 else 0.0), 0, 0)))
            b = b.union(tab).cut(hole)
    for x in (-W / 2 + 14, W / 2 - 14):
        for y in (12, DEPTH - 14):
            b = b.cut(cq.Workplane("XY").center(x, y).circle(6.3).extrude(0.8))
    return b


# ── REAR (back cover) ────────────────────────────────────────────────────────
def make_rear():
    r = rounded_top_rect_xv(W / 2, 0, LF, R_TOP, S - T, S)
    r = r.edges(cq.selectors.BoxSelector((-W, S - 0.01, -10), (W, S + 0.01, LF + 10))).fillet(R_COVER)
    xs = [x for x in range(-72, 73, 7)]
    v0, v1 = pi_v0 + 4, LF - T - 10
    r = r.cut(cq.Workplane("XZ").pushPoints([(x, (v0 + v1) / 2) for x in xs])
              .slot2D(v1 - v0, 3.0, angle=90).extrude(-T * 3).translate((0, S - 2 * T, 0)))
    r = r.cut(lbox(usbc_x - 8, usbc_x + 8, S - 2 * T, S + 1, usbc_v - 7, usbc_v + 7))
    for v in BOSS_VS:
        for x in (-BOSS_X, BOSS_X):
            r = r.cut(lcyl_w(x, v, 1.7, S - 2 * T, S + 1))
    return to_face(r)


def make_bar():
    bar = cq.Workplane("XY").box(110.0, 13.0, 3.0, centered=(True, False, False))
    for x in (-48, 48):
        bar = bar.cut(cq.Workplane("XY").center(x, 3.3).circle(1.7).extrude(10).translate((0, 0, -2)))
    return bar


# rear prints outer face UP: its outward normal must map to +Z
PRINT_ROT = {"front": 90.0 + THETA, "rear": 90.0 + THETA}

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
    print(f"W={W} depth={DEPTH:.1f} H={H:.1f} S={S:.1f}")
