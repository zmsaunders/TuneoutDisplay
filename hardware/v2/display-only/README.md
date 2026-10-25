# Display-only housing (v2, slab layout, softened, not yet printed)

Parametric CadQuery model: `display_only.py`. Edit the parameters at the top and run
`python3 display_only.py out/` to regenerate.

The Pi stays mounted on the back of the display with the HAT stacked on it, as one module
45 mm deep. The housing is a slab 53 mm thick around that module, tilted back 20°, sitting
on a chin that holds the speaker firing forward.

Overall: **176 W × 91 D × 164 H mm** (plus feet).

### Styling (all support-free)

- Slab top corners: R10 rounds. They stand vertical when the front prints face down.
- Bezel side and top edges: teardrop rounds (R4 / R6). 45° where they touch the bed, curving into a radius.
- Chin: the front wall curves back (R50) to meet the 20° screen face with no crease. Front and ramp
  edges are rounded R4.
- Rear: a 45° ramp from the back cover down to the floor replaces the flat foot plate. The intake slots are in the ramp.
- Back cover: sits over the walls' back edges, with a rounded outer edge.

## Parts

**The STLs are already rotated to their print position. Load them as-is with supports off.**
The STEP files are in assembled orientation, for editing in CAD.

| File | Qty | Print orientation | Notes |
|---|---|---|---|
| `display_only_front.stl` | 1 | Face down | Bezel, slab side walls and top. 50 mm tall on the bed |
| `display_only_base.stl` | 1 | Floor down | Chin: curved grille wall, 45° rear ramp with intake slots, tabs |
| `display_only_rear.stl` | 1 | Flat, outer face up | Back cover: exhaust vents over the Pi/HAT, USB-C exit |
| `display_only_bar.stl` | 2 | Flat | Panel retainer bars |

## Hardware

- 8 × M3 heat-set inserts (≈4 mm OD): 4 in the base tabs, 4 in the back-cover bosses
- 4 × M3×8 countersunk screws (slab sides into base tabs), 4 × M3×8 screws (back cover)
- 4 × M3×10 self-tapping screws (retainer bars)
- 4 × 12 mm stick-on bumpers
- 1–1.5 mm foam tape: speaker face to grille, and under the retainer bars
- **Right-angle USB-C cable** (plug angled so the cable leaves straight out the back). The Pi's USB-C
  port faces the top edge of the display. The back cover has a 16 × 14 mm exit right behind it.
- Low-profile heatsink (≤5 mm) on the Pi's SoC, under the HAT

## Assembly

1. Base: press the inserts into the 4 tabs. Seat the speaker in the cradle with foam tape against the grille.
2. Front: lower the display + Pi + HAT module into the bezel rim, face down. Lay foam on the panel's
   top and bottom edges and screw the two retainer bars onto the posts.
   **Fold the DSI ribbon flat so it stays within the panel outline.** There is only ~2.5 mm of side clearance.
3. Plug the speaker into the HAT. Lower the front onto the base along the seam (the tabs slide up inside
   the slab walls) and fit the 4 countersunk side screws.
4. Fit the right-angle USB-C cable through the back cover, then fit the back cover.

## Cooling

Air comes in through the slots in the rear ramp, rises up the slab past the Pi and HAT, and leaves
through the back-cover vents directly over them. The HAT sits over the Pi's SoC, so fit a low-profile
heatsink and run `vcgencmd measure_temp` with a dashboard open for 30 minutes. Under 70 °C is fine.
