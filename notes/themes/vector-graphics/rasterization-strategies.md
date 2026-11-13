# Theme: Rasterization Strategies

> Five answers to one question: who decides which pixels a curve covers?

## Key Insight

> **The core challenge:** Tessellation is one strategy, not the GPU's requirement. The fixed-function rasterizer wants triangles, but the triangles do not have to be the shape: they can be a fan that a stencil repairs, a quad that a shader carves with a distance function, or a strip of quads that carry coverage computed on the CPU.

---

## The Problem: Pixels Do Not Care About Your Bezier Curve

Fill a circle and you ask the machine for something it cannot do directly. A circle is a formula. A screen is a grid of squares. Every square on the edge of the circle is partly inside and partly outside, and somebody has to decide what color that square gets. That "somebody" is the subject of this note.

The [vector graphics README](README.md) and the [tessellation note](tessellation.md) describe the most common answer: flatten the curve, triangulate the interior, and let the GPU fill triangles. That answer works, but it quietly answers several other questions too. Six requirements pull against each other whenever a framework draws a path:

- **Coverage:** which pixels are inside, and by how much? A pixel an edge cuts in half should land at about 50 percent, not 0 or 100.
- **Anti-aliasing (AA):** how do the soft edges get produced, and what do they cost in memory and fill rate?
- **Self-overlap:** when a path crosses itself, or two translucent strokes overlap, does the result match the fill rule and avoid double-blending?
- **Zoom:** does the shape stay crisp when the user scales it up 40 times, or does it show facets?
- **Per-frame cost:** creative coding animates paths constantly. What does the CPU pay each frame to redraw a path that moved?
- **Hardware reach:** does the approach need a stencil buffer, MSAA targets, compute shaders, or only the lowest common denominator that a WebGL2 browser or a phone offers?

You might wonder why the study needs a whole note for this. Because the frameworks disagree, and the disagreement is where the design decisions live. Processing's two renderers answer the same sketch two ways. openrndr never triangulates a fill. Vello never produces a triangle mesh at all. The README's claim that "GPUs only understand triangles" is true of the hardware and misleading about the software: it describes what the rasterizer consumes, not what a framework has to compute.

---

## The Mental Model: Five Ways to Color Inside the Lines

Picture a line drawing of a leaf and five ways to color it in.

1. **Send it to a print shop.** You hand over the outline and get a finished page back. You do not know how they did it, and you cannot change the method.
2. **Cut triangular stickers.** You cut the interior into little triangles, stick them down, and soften the edge by taking more samples per pixel.
3. **Paint over the whole page, then wipe.** You scribble a rough fan of paint, keep a tally of how often each spot was covered, and wipe away spots where the tally says "outside". A thin feathered border hides the seam.
4. **Use a stencil that knows the formula.** For a circle, you hold a square card up and let each pixel ask "am I within the radius?". It needs no outline at all, but it only works for shapes with a formula.
5. **Lay a grid and measure.** You measure how much of each grid cell the outline covers. You write down numbers only for the cells the line crosses, and say "solid" for the long runs in between.

Each answer assigns the job of computing coverage to a different party. The diagram names them, and the rest of this note takes them one at a time.

```
 Strategy                         Who computes coverage?              Frameworks in this study
 ───────────────────────────────  ──────────────────────────────────  ──────────────────────────────
 1 Delegate to a platform         the platform rasterizer             p5.js 2D, Processing Java2D,
                                  (Canvas2D, Java2D, Quartz, Skia)    DrawBot, vvvv (Skia over ANGLE)
 2 CPU tessellation + MSAA        GPU rasterizer, by sample position  nannou/Lyon, Processing P2D,
                                                                      OpenFrameworks, Cinder, PixiJS
 3 Expansion + stencil + fringe   stencil unit (inside/outside) +     openrndr
                                  a faded border (edges)
 4 Analytic primitives            the fragment shader, via a          openrndr circles, Vello rects
                                  distance function                   (parametric shapes only)
 5 Coverage rendering             a CPU pass (strips) or GPU compute  Vello sparse strips; Vello
                                  (classic Vello)                     compute variant
```

Strategy 4 is the odd one out. It does not draw arbitrary paths, so it works as a fast lane next to the others, not as a competitor. The [primitive strategies note](../rendering/primitive-strategies.md) explains why: its Tier 1 and Tier 2 shapes fit "unit geometry times instance data", and its Tier 4 shapes (arbitrary paths) do not.

---

## Strategy 1: Hand the Curve to the Platform

**Who:** p5.js in 2D mode, Processing's default Java2D renderer, DrawBot on Quartz, and vvvv's VL.Skia.

**Coverage and AA.** The framework records a path and passes it on. The platform owns flattening, stroking and anti-aliasing. Processing's Java2D branch builds a `GeneralPath`, keeps Béziers as cubic segments, and calls `g2.fill` then `g2.draw`. The JDK's scanline rasterizer computes how much of each pixel a path covers, so edges are anti-aliased per path with no multisampling. The Processing note records this at `handleSmooth()`, where one rendering hint turns AA on. p5.js wraps `CanvasRenderingContext2D` the same way: `circle()` becomes `ctx.arc()` plus `ctx.fill()`. DrawBot sends every command to a Quartz `CGContext` (`CGContextFillPath`) and makes PDF the canonical intermediate.

**File:** `frameworks/processing/core/src/processing/awt/PGraphicsJava2D.java:1345` (`drawShape`)
**File:** `notes/per-framework/p5js/rendering-pipeline.md` ("The Renderer Abstraction: Why Two Backends?")
**File:** `notes/per-framework/drawbot/export-pipeline.md` ("PDF Pipeline (Direct Rendering)")

**vvvv takes the strategy one step further.** VL.Skia does not call a CPU rasterizer. It creates a GPU context for Skia over ANGLE, an OpenGL-ES layer that runs on top of Direct3D. `GRGlInterface.CreateAngle()` and `GRContext.CreateGl(...)` sit in `VL.Core.Skia/RenderContext.cs:154-157`. `SkiaRenderer` creates an `EglSkiaRenderer` at `VL.Skia/src/SkiaRenderer.cs:213`, and `OnPaint` calls `renderer.Render(...)` whose callback runs `Input?.Render(callerInfo)` on the layer tree (`:251-263`). What happens inside Skia's GPU backend is a black box here, and this note does not describe it. The README for the library notes that the ANGLE route is Windows-only.

**Per-frame CPU cost.** Low for the framework, because it only records path commands. The platform bears the real cost and you cannot see it. vvvv adds one cacheable layer: `DeferredLayer` records a subtree into an `SKPicture` with `SKPictureRecorder` and replays it (`VL.Skia/src/DeferredLayer.cs:13-66`). Whether a replay skips Skia's own path work is not something the study verified.

**GPU requirements.** None from the framework's side. Canvas2D and Java2D run without a GPU. Skia-over-ANGLE needs a D3D device, which makes it a desktop Windows answer.

**What breaks.**

- **You cannot reach below the platform.** Self-overlap rules, stroke joins and AA quality are whatever Canvas2D, Java2D or Quartz decided.
- **Behaviour differs per platform.** Processing's two renderers already disagree on joins and thin lines (see Strategy 2).
- **Portability stops at the platform's edge.** DrawBot's Quartz dependency ties it to Apple's stack, and the Skia route above is Windows-only. The study's own DrawBot note suggests wgpu rendering to a texture plus image encoders for a cross-platform framework.
- **Text rides along for free.** DrawBot draws text with `CTRunDraw`, p5.js with Canvas text, Processing with Java2D. This is a real benefit and the reason the strategy stays popular.

---

## Strategy 2: Cut Triangular Stickers

**Who:** nannou (Lyon), Processing P2D, OpenFrameworks (libtess2), Cinder (GLU), and PixiJS. three.js's `ShapeGeometry` also triangulates on the CPU, and this note mentions it only for completeness.

**Coverage and AA.** The CPU flattens curves into polylines, triangulates the interior (and strokes, which become triangle ribbons), and uploads vertex and index buffers. The GPU rasterizer then decides, per pixel, whether a triangle covers a sample position. That test is binary per sample, so edge quality depends on how many samples exist. Processing P2D takes this all the way: anti-aliasing is MSAA only, with `smooth(N)` mapped to N samples by `PGL.smoothToSamples`, and "no shader-level coverage AA exists" for either fills or CPU-built strokes. The sample count is fixed when the window opens.

**File:** `frameworks/processing/core/src/processing/opengl/PGL.java:468-477`
**File:** `frameworks/processing/core/src/processing/opengl/PGraphicsOpenGL.java:13473` (`tessellatePolygon`, GLU fill)
**File:** `frameworks/processing/core/src/processing/opengl/LinePath.java:3-26` (a JDK-derived stroker feeding the triangle pipeline)

**How the tessellators differ.** Processing P2D picks its fill path by shape kind, not by geometry. Fans, strips and quads get trivial index generation, and only `POLYGON` goes through GLU, convex or not. Curves flatten by forward differencing with a fixed `bezierDetail`, while ellipses size their fan from the on-screen diagonal. Strokes take a fast path (one quad per segment, no caps or joins) when the scaled weight falls below 2 px or the path reaches 5000 vertices, and otherwise run the JDK-derived `LinePath` stroker and then GLU on the outline (`PGL.java:116` and `:121` hold the thresholds). OpenFrameworks uses libtess2, a cleanup of the GLU tessellator. Cinder uses GLU. nannou implements Lyon's geometry-builder trait to receive triangles directly, and Lyon's tessellators persist across frames. The [tessellation note](tessellation.md) covers these libraries in detail. PixiJS records drawing instructions, then converts them to triangles in a graphics context system: circles become triangle fans and curves become polylines. A dirty flag defers that work to once per frame, however many times you mutate the context.

**File:** `notes/per-library/web/pixijs/graphics-api.md` ("From Instructions to Triangles: The Rendering Pipeline", "Dirty Flag Optimization")

**Per-frame CPU cost.** This is the strategy's main lever. If the shape does not change, the mesh is cacheable: Processing's retained `PShape` tessellates once and then transforms by matrix, and nannou and Lyon expect you to cache. If the path changes, the CPU re-flattens, re-triangulates and re-uploads every frame. Processing's immediate mode does exactly that on every `endShape`. Per-vertex allocation makes it worse: the P2D curve code copies a `double[]` template for each flattened point.

**GPU requirements.** Plain vertex and fragment shaders, so it works everywhere, WebGL2 included. MSAA targets cost framebuffer memory and resolve work. The Processing note observes that `smooth(8)` on a large P2D window costs real fill rate on integrated GPUs.

**What breaks.**

- **Self-overlap is the tessellator's job.** GLU and Lyon handle winding rules on the CPU. Processing's immediate mode always passes `solid = true`, so it only ever uses NONZERO; ODD is reachable only from retained `PShapeOpenGL` (`PGraphicsOpenGL.java:2221`).
- **MSAA does nothing for stroke self-overlap.** Overlapping stroke triangles blend twice when the stroke is translucent, because MSAA only improves edges. The fast-path quads in Processing show the clearest case: gaps or overlaps at corners, and nothing in the multisample count repairs them.
- **Zoom needs a re-flatten.** A mesh built at one tolerance shows facets when scaled up. Processing Béziers use a fixed `bezierDetail` regardless of size.
- **Text needs its own system.** Nothing in this strategy gives text for free. Processing's typography uses glyph atlases (`FontTexture`, per the glifo note); see the [typography theme](../typography/README.md).

---

## Strategy 3: Paint Over, Tally, and Wipe

**Who:** openrndr, which lifted the design from NanoVG (see Sources).

**Coverage and AA.** The CPU flattens each contour and builds two cheap pieces of geometry: a triangle fan from vertex 0 that is allowed to be wrong for concave shapes, and a ribbon of fringe geometry along the outline. The GPU stencil unit repairs the fan. Coverage splits in two halves. The stencil answers inside versus outside. The fringe, which a fragment shader fades across a one-pixel border, produces the soft edge. Fringe width is `1.0 / modelViewScaling`, so it tracks device pixels at any zoom, and `smooth = false` removes it.

**The passes.** A concave fill takes three passes:

| Pass | What it draws | Stencil test | Stencil update | Color writes |
|------|---------------|--------------|----------------|--------------|
| 1. Tally | The fan, front and back faces | Always | Increment-wrap (front), decrement-wrap (back) | Off |
| 2. Feather | The fringe strips | Pass where `== 0` | Unchanged | On |
| 3. Cover | One bounding-box quad | Pass where `!= 0` | Zero | On |

Strokes take three more: an opaque core (`strokeThr = 1 - 0.5/255`) that increments the stencil so overlapping segments and joins cannot double-blend, an anti-aliased feather where the stencil is still zero, and a reset pass. A convex contour skips the stencil. A turning-number test (`|Σ turn| = 2π`, not just a sign check) classifies convexity on the CPU, so one flag removes three of the six draws.

**File:** `frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/Drawer.kt:873-919`
**File:** `frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/ExpansionDrawer.kt:231-363` (fill passes), `:120-187` (stroke passes)

**The open question about pass 3.** Pass 3 sets `stencilTestMask = 0x1` after `stencilFunc(..., 0xff)` and never resets it (`ExpansionDrawer.kt:335`). That means the pass tests only the low bit, so a pixel whose wrapped winding count is 2 reads as outside. The behaviour looks like even-odd, not the non-zero rule that pass 1's increment and decrement suggest, and it differs from NanoVG's mask of 0xff. The study's [contour-to-pixels trace](../../per-framework/openrndr/code-traces/contour-to-pixels.md) flags this as untested at runtime. Do not rely on either fill rule from openrndr until a test settles it.

**Per-frame CPU cost.** Linear in flattened points, with no triangulation, but nothing is cached. Each `contour()` call flattens the contour twice (once for fill, once for stroke), and the code runs `prepare` and `calculateJoins` separately for each. That is a modest cost per path and a real cost per frame for thousands of animated paths.

**GPU requirements.** A depth-stencil attachment is mandatory. `contour()` and `shape()` throw when the active render target has no stencil buffer (`Drawer.kt:917` and `:854`). Nothing else exotic is needed. The code never needs compute, MSAA or WebGL2-specific features, although the study did not test the approach on WebGL. The trace's own advice for wgpu is to confirm that `Depth24PlusStencil8` or `Depth32FloatStencil8` is available, because the wrap ops depend on 8-bit stencil.

**What breaks.**

- **Pass count and state churn.** A concave filled and stroked contour costs about six draws and six stencil states, each a `setState` diff in a mutable `DrawStyle`.
- **8-bit stencil wrap** overflows at 256 overlapping layers. The trace says to document the limit.
- **Fills ignore your join style.** Fill expansion hard-codes bevel joins with miter limit 2.4.
- **Text is not covered.** openrndr's text path was not part of this trace. Treat that column as open.

---

## Strategy 4: A Stencil Card That Knows the Formula

**Who:** openrndr's circle drawer, Vello's rectangle fast path, and every Tier 1 and Tier 2 shape in the [primitive strategies note](../rendering/primitive-strategies.md).

**Coverage and AA.** The shape never becomes an outline. One unit quad per instance goes to the GPU, and the fragment shader computes a distance to the shape's edge and turns it into alpha. openrndr's circle shader measures `d = length(uv - 0.5) * 2`, then anti-aliases with `smoothstep(0, fwidth * smoothFactor, 1 - d)`, and the vertex shader grows the quad by `1.25 / contentScale` so the ramp is not clipped. Fill and stroke come from one draw. Vello's `fill_rect` fast path skips flatten, tile and strip entirely, and the fragment shader computes edge coverage analytically from fractional bits (`rect_coverage`).

**File:** `frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/CircleDrawer.kt:145-200`
**File:** `libraries/rust/vello/vello_gpu/src/draw.rs:228` (`push_rect`), `libraries/rust/vello/vello_common/src/strip_generator.rs:208` (`generate_filled_rect_fast`)

**Per-frame CPU cost.** The lowest of the five. The CPU writes 16 to 28 bytes per instance and issues one draw call per primitive type. The Tier 1 table in the primitive note lists the instance sizes.

**GPU requirements.** Instancing and `fwidth` derivatives. Nothing else. WebGL2 supports both.

**What breaks.** The shape must have a formula. A Bezier path has no closed-form distance function that is cheap to evaluate per pixel, which is why Tier 4 in the primitive note ("arbitrary paths") falls back to accumulated geometry. The quad also needs padding so the AA ramp is not clipped, which is why openrndr grows it by `1.25 / contentScale`. Strokes of parametric shapes work (rings, arcs), while strokes of arbitrary paths do not. Zoom is free for these shapes, since the formula has no resolution.

---

## Strategy 5: Lay a Grid and Measure

### Sparse strips: the CPU measures, the GPU draws quads

**Who:** `vello_gpu` and `vello_cpu` (the Sparse Strips renderers).

**Coverage and AA.** Vello flattens a path at a hardcoded 0.25 pixel tolerance, bins every line into 4x4 pixel tiles, sorts the tiles, and sweeps them to accumulate exact signed area. Only tiles that an edge crosses get alpha bytes: exactly 16 per edge tile, one per pixel. A flag called `fill_gap` on the following strip marks the span between two strips as solid, and that span carries no bytes at all. So coverage is analytic per edge pixel, and the alpha memory scales with the perimeter of the shape, not its area.

**File:** `libraries/rust/vello/vello_common/src/flatten.rs:15-19` (tolerance), `vello_common/src/tile.rs:263-266` (4x4 tiles)
**File:** `libraries/rust/vello/vello_common/src/strip.rs:17-27` (the `Strip` type), `:487-500` (16 alpha bytes per tile)

**Concrete example: one tile, one diagonal.** Take a single 4x4 tile cut corner to corner by one line. Pixels left of the diagonal get coverage 0. Pixels on the diagonal get 0.5, which becomes byte 128. Pixels right of the diagonal get 1.0, which becomes 255. Those 16 bytes are the whole payload. Everything farther right on that row is a `fill_gap` span. The [sparse strips note](../../per-library/rust/vello/sparse-strips.md) works this through step by step.

**What the GPU does.** It draws instanced quads: `draw(0..4, instances)` as a triangle strip, with one 24-byte `GpuStrip` per alpha segment or solid span. The fragment shader reads one byte from an `Rgba32Uint` alpha texture for edge pixels and takes `alpha = 1.0` for interior spans, so interior fragments never touch the texture (`libraries/rust/vello/vello_gpu_shaders/shaders/render.wesl:398-404`). Clips are CPU set operations on strip lists, so the GPU needs no stencil or mask state. Mask layers are not implemented and panic (`libraries/rust/vello/vello_gpu/src/scene.rs:686-688`).

**File:** `libraries/rust/vello/vello_gpu/src/render/wgpu/mod.rs:2085-2100` (`Rgba32Uint` alpha texture)
**File:** `libraries/rust/vello/vello_common/src/strip_generator.rs:287-297` (clip by strip intersection)

**Per-frame CPU cost.** The design pays here. Flatten, tile, sort and strip generation run on the CPU, with SIMD, for every path you record. `Scene::fill_path` does this work at call time, so a scene rebuilt every frame pays for every path every frame. That is the intended trade, and it is much cheaper per path than re-tessellating with a general polygon tessellator, because there is no triangulation step. A strip list is tied to the pixel grid, so a moved or rescaled path needs a rebuild. Nothing is cached across frames unless you keep the `Scene` and do not re-record.

**GPU requirements.** No required wgpu features: every in-repo example requests `Features::empty()`. A depth view (`Depth24Plus`) is optional and only reduces overdraw for opaque spans. A separate WebGL backend exists in `vello_gpu/src/render/webgl/`, and the wasm examples also run through wgpu with WebGL2 limits. No stencil, MSAA or compute is needed.

**File:** `notes/per-library/rust/vello/wgpu-integration.md` ("What Your Device Has to Offer")

**What breaks.**

- **A whole-buffer upload each frame.** The entire alpha buffer goes to the GPU as one chunk (`libraries/rust/vello/vello_gpu/src/render/wgpu/mod.rs:549-551` carries the upstream TODO). One texture holds all alphas, so a very large scene meets texture size limits first. The wgpu-integration note works out about 16.7 million edge tiles as the ceiling at a 4096 texture dimension, and less on devices with smaller limits.
- **The cost of text, by mode.** `glifo`'s default is path mode: every glyph becomes a `fill_path`, so zoom never blurs but every glyph pays flatten, tile and strip each frame. Atlas mode rasterizes glyphs once and draws image fills, which is fast but ties sharpness to the cached size, and upstream calls it "highly experimental" (`glifo/src/glyph.rs:353-354`). See the [glifo note](../../per-library/rust/vello/text-glifo.md).
- **Self-overlap and zoom work well.** Winding accumulates in the strip stage under NonZero or EvenOdd, and zoom re-flattens at the new transform to give exact edges again.
- **Strokes expand first.** `stroke` asks kurbo for an outline path and then runs the same fill.

### The compute variant: the GPU measures everything

**Who:** the original Vello renderer, now under `research/` in the same repository.

**How it differs.** Where strips put flatten, tile and strip on the CPU, the compute variant encodes the scene into tag streams and runs about twenty compute dispatches that flatten, bin, build per-tile command lists and rasterize on the GPU. The CPU's per-frame job shrinks to writing down the scene. It is the best fit for scenes that are fully dynamic and path-heavy.

**GPU requirements and what breaks.** Compute shaders are mandatory, so there is no WebGL2 path. The harder problem is memory: shaders claim output slots from bump counters in a fixed-size scratch buffer, and the CPU learns only afterwards whether the buffer was big enough. In this checkout, `render_encoding_full` is documented as not robust for complex scenes, and the study did not find a completed readback-and-retry loop. Upstream demoted this renderer to `research/` and describes it as having "different compatibility and memory trade-offs" (`ARCHITECTURE.md:59-60`).

**File:** `libraries/rust/vello/research/vello_research/src/render.rs:95-98`
**File:** `libraries/rust/vello/research/vello_encoding/src/config.rs:26-37` (`BumpAllocators`)
**File:** `notes/per-library/rust/vello/compute-renderer.md` ("The Bump Allocator and the Failure It Creates")

---

## Tracing One Self-Overlapping Star Through All Five

Let's trace what happens when you fill a five-pointed star drawn as one self-crossing path, with a translucent fill, under each strategy. The table shows where the decision lands.

| Strategy | Who handles the crossing | What the center pentagon looks like |
|----------|--------------------------|-------------------------------------|
| 1 Platform | The platform's fill rule | Whatever Canvas2D, Java2D or Quartz applies; one composite per path |
| 2 Tessellate | GLU or Lyon, on the CPU, per winding rule | Correct, with no double-blend, because the tessellator emits non-overlapping triangles |
| 3 Stencil | The tally in pass 1 | Filled once, at the stencil's decision; parity-versus-winding behaviour is the untested pass-3 mask question |
| 4 Analytic | Not applicable | A star has no cheap distance function in the fragment shader, so it falls to Tier 4 in the primitive note |
| 5 Coverage | The strip stage's winding accumulation | Filled once, with NonZero or EvenOdd chosen by the caller |

Add a translucent stroke and the picture changes. Strategy 2 can blend overlapping stroke triangles twice (the fast-path quads in Processing do), while Processing's full-stroke path builds one outline with `LinePath.createStrokedPath` and feeds it through GLU (whether that removes every interior overlap is not something the study checked). Strategy 3 prevents the double blend with its stroke core pass. Strategy 5 expands the stroke to an outline, fills it once, and so blends once.

---

## Comparison Matrix

Two tables follow, one for the pipeline mechanics and one for correctness and reach. Cells marked "(inferred)" come from reading the pipeline, not from a cited note.

**Table A: Mechanics**

| Strategy | Where coverage is computed | AA quality | Dynamic-path CPU cost per frame | Cacheable across frames | GPU feature needs |
|----------|----------------------------|------------|---------------------------------|-------------------------|-------------------|
| 1 Platform | Platform rasterizer | Analytic coverage for Java2D; Canvas2D and Quartz (inferred) | Low in the framework; hidden in the platform | vvvv records subtrees into `SKPicture` (`DeferredLayer.cs:13-66`); others none (inferred) | None for Canvas2D, Java2D; Skia over ANGLE needs D3D (Windows) |
| 2 Tessellate | GPU rasterizer, per sample | Sample-count bound (Processing: MSAA only) | High: flatten, triangulate, stroke, upload | Yes, as a mesh (`PShape`, Lyon meshes); no for immediate mode | Vertex and fragment only; MSAA targets; WebGL2 OK (inferred) |
| 3 Stencil + fringe | Stencil (inside) + fringe (edge) | Fringe ramp, one device pixel wide | Medium: linear flatten and expand, no triangulation; contour flattened twice | Not cached today; cacheable in principle (the trace suggests a `PathMesh`) | Depth-stencil attachment required; 8-bit wrap; WebGL2 untested |
| 4 Analytic | Fragment shader, SDF | Smooth, via `fwidth` | Lowest: per-instance data only | Yes, instance buffers (inferred) | Instancing and derivatives; WebGL2 OK (inferred) |
| 5a Strips | CPU, exact area, edge pixels only | Exact at 0.25 px flatten tolerance | Medium to high: flatten, tile, sort, strip per path | Only if you keep the `Scene` | None required; WebGL2 backend exists; optional depth |
| 5b Compute | GPU compute | Exact (area and MSAA fine variants) | Lowest: encode only | Encoding is cacheable (per the compute note) | Compute shaders required; no WebGL2 |

**Table B: Correctness and reach**

| Strategy | Self-overlap and transparency | Zoom independence | Text path | Implementation effort |
|----------|-------------------------------|-------------------|-----------|-----------------------|
| 1 Platform | The platform's rules | Vector until rasterized; PDF export stays vector (DrawBot) | Platform text (Quartz, Java2D, Canvas) | Lowest for you; no control |
| 2 Tessellate | Correct fills via the tessellator; MSAA does not fix stroke overlap | Re-flatten needed; Processing Béziers use fixed detail | Separate system: glyph atlas (`FontTexture`); outlines (inferred) | Low with Lyon; high if you write strokes yourself (Processing needed a JDK-derived stroker) |
| 3 Stencil + fringe | Fill rule depends on the stencil mask (open question); stroke core pass avoids double blend | Fringe and tolerance follow `modelViewScaling` | Not studied | Medium: six pass states plus join and cap code |
| 4 Analytic | Not applicable to arbitrary paths | Free | Not applicable (inferred) | Low per shape, one shader each |
| 5a Strips | NonZero and EvenOdd in the strip stage; clips as strip intersection | Re-flatten at the new transform; exact edges | `glifo`: path mode default, atlas mode experimental | High: SIMD tile pipeline, scheduler for layers |
| 5b Compute | Same pipeline handles fills, strokes, clips, blends | Re-run on GPU; no CPU geometry beyond encoding (per the compute note) | `glifo` is aimed at the strips renderers; compute text path not studied here | Highest: ~20 dispatches, memory sizing |

---

## Best Practices Extracted

1. **Route by shape type, not by one pipeline.** openrndr's circle drawer shows an instanced SDF quad beating its own contour path by about six draws to one. Keep analytic primitives (Strategy 4) as the front lane and send only arbitrary paths to the heavier strategy.
2. **Derive both flatten tolerance and AA width from the effective pixel size.** openrndr computes `distanceTolerance` and `fringeWidth` from `modelViewScaling`. Vello divides the stroke tolerance by the transform scale. Either way, zoom stays crisp without per-zoom caches.
3. **Test convexity with a turning-number check.** openrndr's comment lists two bugs a sign-only test produces (clockwise polygons read as non-convex, a pentagram reads as convex). A convex flag buys a stencil-free fast path.
4. **Represent edges and interiors separately.** Sparse strips store 16 bytes only where an edge crosses and a flag elsewhere. The same idea shows up as the stencil-plus-fringe split in openrndr.
5. **Resolve clips on the same representation as fills.** Intersecting strip lists keeps the GPU free of mask state. A stencil-based design pays instead with passes and state.
6. **Make retained shapes cheap and immediate shapes honest.** Processing's `PShape` tessellates once. Vello expects you to keep the `Scene`. Offer a retained handle for anything drawn repeatedly, and document what the immediate path costs.
7. **State the fill rule as an API option.** Processing hides it behind a `solid` flag, and openrndr's pass 3 leaves it ambiguous. A `FillRule` parameter removes the surprise.

## Anti-Patterns to Avoid

1. **Tessellating every frame with a general tessellator.** With Lyon or GLU, per-frame tessellation is the whole cost. Processing's immediate mode re-runs GLU and the stroker on every `endShape`. With sparse strips, per-frame CPU work is the design, and there is no triangulation step to repeat. The same habit has different prices in different strategies.
2. **Using stencil without budgeting for the attachment.** Stencil forces a depth-stencil attachment on every target that draws paths. openrndr turns a missing attachment into a runtime `error()` (`Drawer.kt:917`). A framework with offscreen targets must allocate it or fail loudly at construction.
3. **Believing MSAA fixes stroke overlap.** MSAA improves edge sampling. It does nothing for two translucent stroke triangles that overlap in the interior. Processing's fast stroke path shows the visible artifact at corners.
4. **Hidden mode switches that change the picture.** Processing's stroke fast path flips on weight and vertex count, and `clamp2D` snaps pixels only in immediate mode. Make thresholds explicit.
5. **A single whole-buffer upload per frame.** It is simple, and it caps scene size at the texture limit. The sparse strips note calls out chunking or a ring buffer as the fix.
6. **Mutable global style for multi-pass state.** openrndr edits `DrawStyle` in place across six passes and restores it by hand. A missed reset leaks into later draws. Prefer one immutable pipeline per pass.
7. **Relying on a bump-allocated scratch buffer without a retry loop.** The compute variant shows how a GPU-side size failure arrives after the fact. If a design needs it, build the readback-and-retry path first.

---

## Recommendations for Rust Framework

This section lays out options for Flux, which targets wgpu on desktop, mobile and web. It does not choose. The decision is recorded in [`insights/2d-rendering-strategy.md`](../../../insights/2d-rendering-strategy.md) and in ADR-005 in [`insights/architecture-decisions.md`](../../../insights/architecture-decisions.md).

### The Options

| Option | What Flux would build | Reach | Main cost |
|--------|-----------------------|-------|-----------|
| A. Tessellation (Lyon) with MSAA | Lyon meshes, cached, drawn with plain pipelines | Every wgpu target | Per-frame re-tessellation for animated paths; AA tied to sample count |
| B. Stencil and fringe | An openrndr-style fan, tally and feather | Needs a stencil format on every target | Pass count, state, the fill-rule question, 8-bit wrap |
| C. Sparse strips | Vello's CPU pipeline and instanced quads, either by depending on `vello_gpu` or by building the same representation | No required features; WebGL2 backend exists | CPU time per rebuilt path; whole-buffer alpha upload |
| D. Compute coverage | GPU flatten, bin and fine rasterization | Compute-capable GPUs only | No WebGL2; memory sizing hazard |
| E. Analytic primitives alongside any of the above | Instanced SDF quads for circles, rects, points | Every wgpu target | Only parametric shapes |

### Trade-offs to Weigh

- **Pro (A):** Lyon is mature, cacheable, and the study already documents it. **Con:** AA quality ties to MSAA sample count, and web and mobile have the most constrained MSAA support.
- **Pro (B):** CPU cost stays linear and AA tracks device pixels. **Con:** depth-stencil is a hard requirement, and the study has not settled the fill rule.
- **Pro (C):** exact AA, no GPU feature requirements, text and clips fit the same representation. **Con:** it needs CPU time for every rebuilt path. The wgpu-integration note also shows that `render` opens its own passes on your encoder and likely wants one `render` per submit, which constrains how it slots into a frame graph.
- **Pro (D):** the GPU does all geometry. **Con:** upstream itself demoted it for compatibility and memory reasons.
- **Pro (E):** the cheapest path for the shapes creative coders draw most often. **Con:** it covers only what has a formula, so it complements the others and replaces none.

### Open Questions

- How many animated, non-parametric paths per frame does a typical Flux sketch draw? The cost of A versus C turns on that number, and the study holds no measurement.
- Can Flux require a stencil format on every target, including WebGPU on mobile?
- Is a CPU-side clip (strips) or a GPU-side one (stencil, scissor) the right fit for the frame graph?
- Which text mode should be the default on each target, given path mode's per-frame cost and atlas mode's experimental status?

---

## Sources

Study notes read for this theme:

- [Sparse strips](../../per-library/rust/vello/sparse-strips.md), [fill-path trace](../../per-library/rust/vello/code-traces/fill-path.md), [wgpu integration](../../per-library/rust/vello/wgpu-integration.md), [text (glifo)](../../per-library/rust/vello/text-glifo.md), [compute renderer](../../per-library/rust/vello/compute-renderer.md)
- [openrndr contour-to-pixels trace](../../per-framework/openrndr/code-traces/contour-to-pixels.md), [openrndr rendering pipeline](../../per-framework/openrndr/rendering-pipeline.md)
- [Processing shape-to-pixels trace](../../per-framework/processing/code-traces/shape-to-pixels.md), [Processing rendering pipeline](../../per-framework/processing/rendering-pipeline.md)
- [p5.js rendering pipeline](../../per-framework/p5js/rendering-pipeline.md), [DrawBot export pipeline](../../per-framework/drawbot/export-pipeline.md), [PixiJS graphics API](../../per-library/web/pixijs/graphics-api.md), [VL.StandardLibs](../../per-library/vvvv-ecosystem/vl-standardlibs/README.md)
- [Vector graphics README](README.md), [Tessellation](tessellation.md), [Primitive strategies](../rendering/primitive-strategies.md)

Source files cited (read-only submodules):

- `libraries/rust/vello/ARCHITECTURE.md`
- `libraries/vvvv-ecosystem/VL.StandardLibs/`: `VL.Core.Skia/RenderContext.cs:154-157`, `VL.Skia/src/SkiaRenderer.cs:213` and `:251-263`, `VL.Skia/src/DeferredLayer.cs:13-66`, `VL.Core.Skia/Interfaces.cs:30-45`

External references:

- [Potato: a hybrid CPU/GPU 2D renderer design](https://docs.google.com/document/d/1gEqf7ehTzd89Djf_VpkL0B_Fb15e0w5fuv_UzyacAPU/edit)
- [Vello CPU thesis (ETH Zurich)](https://ethz.ch/content/dam/ethz/special-interest/infk/inst-pls/plf-dam/documents/StudentProjects/MasterTheses/2025-Laurenz-Thesis.pdf) (upstream notes that parts are outdated)
- [NanoVG](https://github.com/memononen/nanovg), the stencil-and-fringe design openrndr follows
- [Lyon](https://github.com/nical/lyon), the Rust tessellator nannou uses

---

*This document is part of the [Vector Graphics Theme](README.md) research.*
