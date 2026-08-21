# RCam icon loop — progress

- 2026-08-20: Iteration 1 blocked — Blender MCP server (`mcp__blender__*`) never registered its tools; Blender was running and port 9876 listening, but the addon never answered `get_addon_info`. User reconnected via `/mcp`.
- 2026-08-21: Iteration 2 — milestones 1–3. Ortho camera looking along +Y from -Y; Cycles; view transform **Standard** (not AgX — the icon wants literal colour). Full-bleed gradient tile; clear rounded body (X -0.82..0.14, Z ±0.26, Y ±0.13, r=0.095) in water-clear polycarbonate (IOR 1.585, roughness 0.025); 8 gold pins.
- 2026-08-21: Iteration 2 cont. — milestones 4, 6, 5. Latch as a ramped wedge boolean-unioned into the body; lens frustum lofted from a narrow joint to a flared end, also unioned; 8 T568B wires as bevelled POLY curves (straight from the pins, smoothstep convergence into the body–lens junction, radius pinch so they disappear rather than end in visible caps, subtle residual twist, striped pairs via Wave→ColorRamp); internal crimp bar as a distinct dielectric (IOR 1.49→1.535).
- 2026-08-21: Iteration 2 cont. — milestones 8–9 (lighting, float/shadow, readability), then **milestone 10 complete**. Final render 2048² at 512 adaptive samples + OpenImageDenoise, run headlessly (`Blender --background docs/icon.blend --python finalrender.py`) so a multi-minute render could not stall the MCP connection; downsampled with `sips -z 1024 1024` to `docs/icon-1024.png`. Squint test passes: at 128px the body + wire bundle + flared lens read clearly; at 32px the camera-glyph silhouette still holds. Loop stopped, awaiting the user's approval of the look before anything is wired into the asset catalog.

## Techniques that mattered (keep these if rebuilding)

- **Cycles light linking.** Rig lights (Key/Sweep/RimR/RimTop/FillL/LensRim) have `light_linking.receiver_collection = IconParts`; a single SUN lights only `TileOnly`. Without this, any lighting bright enough to articulate the clear plastic washed the tile gradient to flat grey.
- **The tile's flat specular was the real bug.** With a near-head-on sun and a head-on camera, the sun sat almost exactly in the tile's mirror direction, so a broad specular lobe covered the whole tile at ~0.35 linear and completely swamped an authored albedo of 0.002–0.033. Fix: `Specular IOR Level` → 0.03 on the tile, and angle the sun off the camera's mirror direction. Diagnosed by sampling render pixels via `bpy.data.images.load(...).pixels`, not by eye.
- **Never backlight the solid glass.** Any area light behind the body/lens is seen *directly through* the glass (transmission rays ignore `visible_camera=False`) and clips to pure white — it turns the lens into a lightbox. The glass has to be read from edge highlights and refracted dark background instead.
- **A broad head-on fill makes clear plastic look frosted.** The `Sweep` light has to stay low (~24); at 55+ the housing goes milky and the wires lose contrast.
- **Shadow needs float.** With the tile close behind, the contact shadow hid entirely behind the silhouette. Tile pushed back to y=0.42 and the sun angled to (0.30, 1.8, -0.85) so the shadow clears the object downward.

## Known compromises

- The latch reads only as a faint outline. A moat (groove) was cut around the T footprint to give it walls that catch highlights, but clear-on-clear over the wires stays subtle, and widening it turned the middle of the body to mud. Accepted as-is.
- Lens bevel is the same width as the body's rather than "slightly softer" — both are produced by the single Bevel modifier after the boolean unions.
- No visible coloured caustics on the tile yet despite `caustics_refractive` + caster/receiver flags being set.
