# RCam icon loop — progress

- 2026-08-20: Iteration 1 blocked — Blender MCP server (`mcp__blender__*`) never registered its tools; Blender was running and port 9876 listening, but the addon never answered `get_addon_info`. User reconnected via `/mcp`.
- 2026-08-21: Iteration 2 — milestones 1–3. Ortho camera looking along +Y from -Y; Cycles; view transform **Standard** (not AgX — the icon wants literal colour). Full-bleed gradient tile; clear rounded body (X -0.82..0.14, Z ±0.26, Y ±0.13, r=0.095) in water-clear polycarbonate (IOR 1.585, roughness 0.025); 8 gold pins.
- 2026-08-21: Iteration 2 cont. — milestones 4, 6, 5. Latch as a ramped wedge boolean-unioned into the body; lens frustum lofted from a narrow joint to a flared end, also unioned; 8 T568B wires as bevelled POLY curves (straight from the pins, smoothstep convergence into the body–lens junction, radius pinch so they disappear rather than end in visible caps, subtle residual twist, striped pairs via Wave→ColorRamp); internal crimp bar as a distinct dielectric (IOR 1.49→1.535).
- 2026-08-21: Iteration 2 cont. — milestones 8–9 (lighting, float/shadow, readability), then **milestone 10 complete**. Final render 2048² at 512 adaptive samples + OpenImageDenoise, run headlessly (`Blender --background docs/icon.blend --python finalrender.py`) so a multi-minute render could not stall the MCP connection; downsampled with `sips -z 1024 1024` to `docs/icon-1024.png`. Squint test passes: at 128px the body + wire bundle + flared lens read clearly; at 32px the camera-glyph silhouette still holds. Loop stopped, awaiting the user's approval of the look before anything is wired into the asset catalog.
- 2026-08-21: Iteration 3 — **RGB light frustum added**, milestones 9–11 redone. Light leaves the lens as an elliptical frustum built on the lens's *own* profile (z_half 0.125→0.215 over x 0.10→0.44, tan 0.2647, 29.7° full), inset 3% so it never shares a surface with the glass. Volume emission only, three plateaued R/G/B bands. Wire conductors now ramp up emission into the convergence point so the signal visibly becomes light. Three tinted area lights on `TileOnly` for the spill; compositor Fog Glow above the pin threshold. Final 2048² → `docs/icon-1024.png`. Squint test passes at 128px and 32px.
- 2026-08-21: Iteration 4 — **wire stripes rebuilt as helices**. The Wave→ColorRamp stripes were bands along object-space X, i.e. rings wrapping perpendicular to the wire, not candy-cane. Replaced with a barber-pole helix driven off the curves' generated UVs (U along the length, V around the profile, verified by sampling the evaluated mesh): `fac = 0.5 + 0.5·sin(2π·(V + 7·U))` into the existing CONSTANT ramp, threshold 0.6545 for a 40% stripe duty. Sine rather than fract so the V=0/V=1 seam is continuous and no seam line shows. Wave Texture nodes removed from all four `W_*White` materials; fade/emission nodes untouched. Re-rendered 2048² → `docs/icon-1024.png`.

## Techniques that mattered (iteration 3 — the light frustum)

- **`primitive_cone_add(rotation=...)` sets the OBJECT's rotation, not the mesh's.** The mesh
  still ran along local Z while the follow-up `data.transform()` shifted it along local X. The
  object *looked* roughly right in the viewport, but every `Texture Coordinate → Object` value
  the density shader depended on was meaningless, so the volume rendered as nothing. Cost
  several iterations of chasing shader maths that was already correct. Build volume meshes
  **directly in local space along the axis you intend to sample**, and assert the local
  coordinate range afterwards.
- **Blender 5.x compositing is a node group** (`scene.compositing_node_group`, a
  `CompositorNodeTree`) — `scene.node_tree` no longer exists. Feeding it from a **Group Input**
  node yields a **pure white frame**; it must be fed by an explicit `CompositorNodeRLayers`
  node inside the group. The Glare node's settings are now **input sockets**, not properties,
  and the enum values are display strings (`'Fog Glow'`, `'High'`), not identifiers.
- **Sample the render where you think you are.** With ortho_scale 1.46 and the camera at
  x=-0.15 the frame spans world x -0.88..0.58, so image fx=0.80 is world x=0.29 — still inside
  the plug. Several "the haze isn't rendering" conclusions were just probes landing on the
  body, and one "the colour bands are inverted" conclusion was a probe landing on a filament.
  Convert fx/fy to world coordinates before drawing any conclusion from a pixel.
- **A radial falloff plus horizontal colour bands makes the centre band dominate.** Density
  peaked on the axis, which is exactly where green sits, so red and blue washed out. Split it:
  one falloff on the frustum's **depth** (|ny|) to control density, and a separate, much later
  falloff on **height** (|nz|, from 0.72) purely to soften the top and bottom lip.
- **Soft colour bleed between R, G and B produces a rainbow.** EASE interpolation across three
  saturated stops passes through bright yellow and cyan and reads as prismatic dispersion —
  the look that was explicitly rejected. Plateau each band and keep the transitions short and
  slightly darkened.
- **Filaments read as spaghetti.** Discrete emissive strands threaded through the haze — even
  thin, translucent and only subtly wavy — look like wet noodles, not light. The volume
  gradient alone carries it. Removed entirely.
- **The frustum must not taper to a point.** Starting it at the lens's joint width (a frustum)
  rather than at an apex is what makes it read as light *leaving an aperture* instead of a
  cone with a vertex floating inside the glass.
- **Gradient regression check.** Tile top-left held at (0.247, 0.298, 0.388) against a
  pre-change baseline of (0.243, 0.298, 0.388); bottom-right moved 0.259 → 0.286 in blue,
  which is the intended spill. Frame-wide fully-white pixels went 0.67% → ~1.0%, almost all of
  it the wires' pre-existing white stripes.

## Techniques that mattered (keep these if rebuilding)

- **Helical stripes come from the curve's generated UVs, not from object coordinates.** A beveled curve gets a
  `UVMap` where **U runs along the length** and **V runs around the profile** (16 segments, V=0 and V=1 the same
  point). Any axis-aligned texture on Object coords can only ever make rings. Confirm the U/V roles by evaluating
  the depsgraph and grouping loop UVs against vertex positions — the first-20-loops print is misleading because
  the end caps carry their own UVs.
- **Use sin(), not fract(), for the stripe phase.** `fract(V + n·U)` wraps discontinuously inside the face that
  straddles V=1, which a CONSTANT ramp turns into a visible seam line down the wire. A sine is exactly periodic
  in V, so the stripe closes on itself; put the duty cycle in the ramp threshold instead
  (`0.5 + 0.5·cos(π·duty)`).
- **Headless renders need Metal re-enabled.** `--factory-startup` (needed because the BlenderMCP/blendkit addons
  hang a `--background` render at ~0% CPU) also drops the Cycles device preference, so the render silently falls
  back to CPU — 1024²/128 took 55s on CPU versus 3min for the full 2048²/512 on GPU. Set
  `prefs.compute_device_type = 'METAL'`, `prefs.get_devices()`, enable the METAL devices and
  `scene.cycles.device = 'GPU'` at the top of the render script.

- **Cycles light linking.** Rig lights (Key/Sweep/RimR/RimTop/FillL/LensRim) have `light_linking.receiver_collection = IconParts`; a single SUN lights only `TileOnly`. Without this, any lighting bright enough to articulate the clear plastic washed the tile gradient to flat grey.
- **The tile's flat specular was the real bug.** With a near-head-on sun and a head-on camera, the sun sat almost exactly in the tile's mirror direction, so a broad specular lobe covered the whole tile at ~0.35 linear and completely swamped an authored albedo of 0.002–0.033. Fix: `Specular IOR Level` → 0.03 on the tile, and angle the sun off the camera's mirror direction. Diagnosed by sampling render pixels via `bpy.data.images.load(...).pixels`, not by eye.
- **Never backlight the solid glass.** Any area light behind the body/lens is seen *directly through* the glass (transmission rays ignore `visible_camera=False`) and clips to pure white — it turns the lens into a lightbox. The glass has to be read from edge highlights and refracted dark background instead.
- **A broad head-on fill makes clear plastic look frosted.** The `Sweep` light has to stay low (~24); at 55+ the housing goes milky and the wires lose contrast.
- **Shadow needs float.** With the tile close behind, the contact shadow hid entirely behind the silhouette. Tile pushed back to y=0.42 and the sun angled to (0.30, 1.8, -0.85) so the shadow clears the object downward.

## Known compromises

- The latch reads only as a faint outline. A moat (groove) was cut around the T footprint to give it walls that catch highlights, but clear-on-clear over the wires stays subtle, and widening it turned the middle of the body to mud. Accepted as-is.
- Lens bevel is the same width as the body's rather than "slightly softer" — both are produced by the single Bevel modifier after the boolean unions.
- No visible coloured caustics on the tile yet despite `caustics_refractive` + caster/receiver flags being set.
- The tile spill is three area lights rather than the emissive frustum itself lighting the tile.
  Volume-emission indirect light is far too noisy at usable sample counts; the lights give the
  same wash noise-free, at the cost of the spill not tracking the frustum automatically.
- The frustum is a smooth gradient with no internal structure. The "hazy cone plus a few bright
  streaks" idea was built and rejected — see the spaghetti note above.
