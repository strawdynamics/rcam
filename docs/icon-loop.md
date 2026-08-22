# RCam app icon — Blender build loop

Instructions for an agent iterating on the RCam macOS app icon via the Blender MCP tools
(`mcp__blender__*`). Each loop iteration: assess current state, advance ONE milestone,
verify visually, record progress. Do not ask the user questions — every decision below is
already settled and must not be re-litigated.

## Concept (settled — do not change)

The classic video-call camera glyph made physical: the camera **body is a transparent RJ45
ethernet plug**, the **lens is a clear glass wedge**. RCam turns RTSP/IP camera streams into
a virtual camera; the icon is "ethernet plug as camera."

## Agreed spec (settled — do not change)

- **View:** Dead straight-on orthographic-feeling framing (long lens or ortho camera).
  The connector lies flat with its **latch side toward the viewer**: the latch T-tab is seen
  face-on in the middle of the body, the 8 gold pins show as a strip row on the **left**
  edge, and all 8 wires are visible side-by-side through the clear housing.
- **Body:** Water-clear polycarbonate (no tint), roughly 2:1 wide-to-tall like the sketch,
  icon-friendly rounded corners (rounder than a real plug). Modeled detail: 8 pin
  slots/comb at the left, an internal crimp/strain-relief bar near the right, gentle body
  bevels. NO mold seams, part numbers, or sprue marks. Very low roughness so edges catch
  highlights instead of vanishing.
- **Pins:** 8 shiny gold contacts, clearly visible as parallel strips at the left edge.
- **Wires:** All 8 conductors in true **T568B order** (top to bottom: orange/white, orange,
  green/white, blue, blue/white, green, brown/white, brown). Striped pairs actually striped: a white base with a
  **helical** colored candy-stripe that screws down the wire like a barber pole — **not**
  rings/bands wrapping perpendicular to the axis. Driven off the curve's generated UVs
  (U along the length, V around the profile) as `sin(2π·(V + turns·U))`, ~7 turns per wire,
  thresholded through a CONSTANT color ramp so the stripe edge stays hard and the V seam
  stays invisible. Routing: straight in their channels
  from the pins for ~2/3 of the body length, passing under the crimp bar, then **gently
  converging and disappearing into the body–lens junction**. Subtle residual waviness/twist
  near the right end (untwisted twisted-pair look) — skip the waviness only if it becomes a
  time sink.
- **Lens:** A clear glass frustum (trapezoid in silhouette) attached to the body's right
  edge, narrow at the joint, flaring wider to the right, rounded corners, edge bevels
  slightly softer than the body's. Same water-clear material family. **No lens-element
  disc** at the joint face (deliberately omitted for now — do not add one).
- **Emitted light:** An RGB light **frustum** leaving the lens, mirroring the 8 wires feeding in.
  It begins at the **body–lens junction** (x=0.10, where the conductors converge) at the lens's
  own joint width — a frustum, **never a cone tapering to a point** — and flares at the **same
  angle as the lens** (tan 0.2647, 29.7° full), continuing past the lens mouth and **bleeding off
  the right edge of the frame**. The plug does not move to make room. Produced by **volume
  emission only**: a smooth gradient. **No filaments, strands or wavy streaks** — those read as
  spaghetti and were removed. Three plateaued bands (red top, green centre, blue bottom) with
  short, slightly darkened transitions so it reads as three colour channels, not a prismatic
  rainbow. Visible **inside the glass** for its first 0.34 units, refracted by the lens walls.
  Restrained — a supporting element, not a hero. Peak emission must stay below the clip point.
- **Tile:** Full-bleed plain **square** slab behind the object (macOS applies the squircle
  mask itself — do not round the tile). Dark graphite→navy vertical gradient. The
  connector-camera floats slightly above the tile so it casts soft contact shadows and
  colored refraction/caustics from the wires onto it.
- **Lighting:** Studio area-light rig (e.g. large softbox up-left as key, rim/fill to
  articulate the clear plastic edges and gold pins). Dark surroundings so the gradient tile
  reads as intended.
- **Tile spill:** three tinted area lights linked to `TileOnly` wash the right of the tile with
  soft RGB and tint the contact shadow. The tile gradient is fragile — verify it by **sampling
  render pixels**, never by eye.
- **Glare:** a compositor Fog Glow pass, threshold set above the gold pins' highlights so the
  light blooms and the plug's detail stays crisp.
- **Render:** Cycles. Final output 2048×2048, downsampled to a **1024×1024 master PNG**.
  Deliverable is that single PNG only — do NOT wire it into the Xcode asset catalog; the
  user will approve the look first.

## Reference

Original sketch: rounded-square tile containing a rounded-rect body with pin teeth on the
left edge, the latch T-shape face-on in the center, and the lens trapezoid flaring to the
right. Follow the sketch's proportions and layout.

## Loop procedure (each iteration)

1. **Assess:** Call `mcp__blender__get_scene_info` (and `get_viewport_screenshot`) to see
   what exists. The file may still contain the default cube (delete it) or partial work from
   a previous iteration — build on it, never start over unless the scene is unsalvageable.
2. **Advance one milestone** (in order, skipping completed ones):
   1. Scene setup: remove default cube; add ortho/long-lens camera framing a square; add
      the gradient tile slab.
   2. Body housing: rounded, beveled clear block per spec (proportions from the sketch).
   3. Pins: 8 gold contact strips + pin slot comb at the left edge.
   4. Latch: face-on T-tab on the viewer-facing side.
   5. Wires: 8 T568B conductors with striped-pair materials, channel run + convergence,
      crimp bar.
   6. Lens frustum on the right edge.
   7. Materials pass: clear polycarbonate, gold, wire insulation; tile gradient.
   8. Lighting rig + float/shadow setup.
   9. RGB light frustum: elliptical frustum built on the lens's own profile, volume emission,
      band ramp, tile spill lights, compositor Fog Glow.
   10. Test renders at low samples; fix readability (silhouette must read as a video-camera
      glyph when squinting/small).
   11. Final render 2048², downsample to 1024 PNG.
3. **Verify:** After every milestone, take a viewport screenshot (and later, low-sample
   renders) and self-critique against the spec above. Fix regressions before moving on.
4. **Record:** Append a one-line dated status to `docs/icon-loop-progress.md` (create if
   missing): what was done, what's next, any blockers.

## Working constraints

- Execute Blender Python via `mcp__blender__execute_blender_code` in **small chunks** —
  large scripts time out. Save the .blend file after each successful milestone
  (`bpy.ops.wm.save_mainfile`, path: `/Users/paulstraw/dev/rcam/docs/icon.blend` if unsaved).
- If a Blender MCP call errors with a communication/JSON error, retry once, then note it in
  the progress file and end the iteration — do not thrash.
- Run the **final** 2048² render headlessly (`Blender --background docs/icon.blend --python
  finalrender.py`) so a multi-minute render cannot stall the MCP connection.
- Final PNG output path: `/Users/paulstraw/dev/rcam/docs/icon-1024.png` (render to a temp
  path, downsample with `sips -z 1024 1024`). Send it to the user with SendUserFile when
  first produced and after visually significant changes.
- **Done condition:** the 1024 master PNG exists, matches the spec, and reads as a camera
  glyph at small sizes. When done, stop the loop (ScheduleWakeup `stop: true` if in dynamic
  mode) and tell the user it's ready for review.
