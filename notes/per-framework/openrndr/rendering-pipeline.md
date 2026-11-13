# The openrndr Rendering Pipeline

> openrndr draws a pink, black-outlined Bézier blob with razor-smooth edges at any zoom, and it never builds a single triangulated mesh. The trick is a stencil buffer and a soft border.

## Key Insight

> **openrndr's core idea:** openrndr borrows NanoVG: expand paths on the CPU, cover concave fills with a stencil, and anti-alias with a fringe the shader fades. It never tessellates.

---

## The Problem: Print-Quality 2D on a Plain GL 3.3 Pipeline

Picture the job description. You maintain one OpenGL 3.3 drawer for a creative coding framework. Artists will call `drawer.contour(c)` with a self-intersecting Bézier loop, zoom into it 40x for a poster export, and expect the edge to look like vector art. You cannot turn on MSAA, because the same drawer must work on offscreen targets, on the WebGL backend, and in a loop that draws thousands of shapes per frame. You also have no triangulator you trust: ear clipping is slow, and a robust one that handles holes and self-intersections is a project of its own.

Those constraints rule out the three obvious answers. MSAA costs memory and still shows stair-steps at shallow angles. A CPU triangulator costs time on every frame and fails on messy input. GPU coverage rendering, the approach [Vello takes](../../per-library/rust/vello/sparse-strips.md), needs compute shaders, which GL 3.3 does not have.

openrndr's answer is older and humbler. It takes the design from NanoVG, a small C vector renderer, and applies it with almost no changes. The CPU does only cheap, linear work: it flattens curves into polylines, then offsets those polylines to build a fan and a ribbon. The GPU's stencil unit does the hard part, deciding which pixels lie inside a concave shape. A fragment shader fades the alpha across a one-pixel border to fake the anti-aliasing.

You might wonder where the "print quality" comes from, given how little geometry this produces. It comes from one number. Both the curve-flattening tolerance and the width of the soft border derive from the current model-view scale, so the border stays about one device pixel wide whatever the zoom.

---

## The Mental Model: A Stencil Cut from a Paper Fan, Then a Soft Border

Think of a sign painter working with masking paper.

1. **Cut a fan.** Pin one end of a paper strip to the first corner of the outline and sweep triangles around to every other corner. For a concave shape the fan overshoots: some triangles cover empty space, and some overlap. That is fine, because the fan is only a cutting guide.
2. **Count the layers.** Every time a triangle covers a spot, the painter makes a tally mark there. The marks do not paint anything. They only record how many triangles touched that spot, and in which direction each one faced.
3. **Paint through the cut-out.** The painter fills a rectangle that covers the whole shape, but only where the tally is non-zero. The overshoot cancels out, because front-facing and back-facing triangles cancel each other in the count.
4. **Add the soft border.** Finally the painter paints a thin ribbon around the outline, with alpha fading from solid to transparent across its width. The edge looks smooth because the ribbon blends into the background.

The tally is the stencil buffer. The fan is the "fill" expansion. The ribbon is the "fringe". That is the whole algorithm. The rest of this document traces where each piece lives in the code and what it costs.

---

## Tracing `drawer.contour()`: Eleven Stages From Call to Pixels

Let's follow one closed, filled, stroked, concave contour through the system. The [full trace](./code-traces/contour-to-pixels.md) holds the excerpts and line-by-line notes. This table maps each stage to its step in the trace so you can jump to the detail.

| # | Stage | Runs on | Input | Output | Location (trace step) |
|---|-------|---------|-------|--------|----------------------|
| 1 | Entry and scale | CPU | `ShapeContour`, current `DrawStyle` | `distanceTolerance`, `fringeWidth`; throws if no stencil | `openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/Drawer.kt:873-919` ([step 1](./code-traces/contour-to-pixels.md)) |
| 2 | Adaptive flatten | CPU | Line, quadratic and cubic segments | Points plus a "corner" flag per point | `openrndr-shape/src/commonMain/kotlin/org/openrndr/shape/ShapeContour.kt:255-278` ([step 2](./code-traces/contour-to-pixels.md)) |
| 3 | Build `Path` | CPU | Points and corner flags | Mutable `PathPoint` list with direction and length | `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/Expansion.kt:361-399` ([step 3](./code-traces/contour-to-pixels.md)) |
| 4 | Classify joins and convexity | CPU | `PathPoint` list | LEFT, BEVEL and INNER_BEVEL flags, plus `convex` | `Expansion.kt:402-486` ([step 4](./code-traces/contour-to-pixels.md)) |
| 5 | Expand stroke | CPU | Path, half-width, cap, join | Triangle strip, 5 floats per vertex | `Expansion.kt:522-641` ([step 5](./code-traces/contour-to-pixels.md)) |
| 6 | Expand fill | CPU | Path, fringe width | FILL outline and FRINGE strip | `Expansion.kt:643-781` ([step 6](./code-traces/contour-to-pixels.md)) |
| 7 | Drawer glue | CPU | Expansion parameters | Calls into the shared expansion renderer | `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/QualityPolygonDrawer.kt:28-43`, `QualityLineDrawer.kt:95-114` ([step 7](./code-traces/contour-to-pixels.md)) |
| 8 | Upload | CPU to GPU | Expansions | Fan as triangle list, strips with degenerate ends, one vertex buffer | `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/ExpansionDrawer.kt:365-419` ([step 8](./code-traces/contour-to-pixels.md)) |
| 9 | Pass sequencing | CPU commands, GPU state | Vertex buffer, stencil settings | Three fill passes, then three stroke passes | `ExpansionDrawer.kt:231-363` (fill), `:120-187` (stroke) ([step 9](./code-traces/contour-to-pixels.md)) |
| 10 | Shading | GPU | Vertices with `(u, v)` | Premultiplied color with faded alpha | `openrndr-gl-common/src/commonMain/kotlin/ShaderGeneratorsGLCommon.kt:587-683` ([step 10](./code-traces/contour-to-pixels.md)) |
| 11 | State and draw | CPU to GPU | `DrawStyle` | `glStencilFuncSeparate`, `glColorMask`, `glDrawArrays` | `openrndr-jvm/openrndr-gl3/src/commonJvmMain/kotlin/org/openrndr/internal/gl3/DriverGL3.kt:1484-1584`, `:1005-1047` ([step 11](./code-traces/contour-to-pixels.md)) |

Stages 1 to 8 happen on the CPU and are linear in the number of flattened points. Only stages 9 to 11 touch the GPU. Notice what is missing: there is no stage that splits the polygon into non-overlapping triangles. The fan emitted in stage 8 is allowed to be wrong, and the stencil in stage 9 repairs it.

The shape of the work also explains the scale trick. Stage 1 computes `fringeWidth` as `1.0 / modelViewScaling`, and stages 2, 5 and 6 consume it. When you zoom in, `modelViewScaling` grows, the tolerance shrinks, curves get more segments, and the fringe stays one pixel wide in device space. Nothing is cached across zoom levels because nothing needs to be.

The data model feeding stage 1 (`Shape`, `ShapeContour`, `Segment2D`) is covered in the [vector graphics theme](../../themes/vector-graphics/README.md) under "openrndr: The Boolean Operations Champion". This document starts after that model hands over a contour.

---

## The Six Passes: Stencil Buffers for People Who Have Never Used One

A stencil buffer is a second, hidden image the same size as your framebuffer, holding one small integer per pixel (8 bits here). Before each triangle is drawn, the GPU can test that pixel's integer ("only draw where it equals zero") and can update it afterward ("add one", "subtract one", "set to zero"). It is the painter's tally sheet from the mental model.

Here is where it gets interesting. The GPU decides "front-facing" or "back-facing" for each triangle from its winding order on screen. Take a fan over a concave outline. Triangles that sweep over the interior face one way. Overshoot triangles that sweep back over the same area face the other way. If you add one for front faces and subtract one for back faces, spots inside the shape end up non-zero and spots in the overshoot cancel to zero. The counter wraps around instead of clamping, so a spot covered once forward and once backward still returns to zero.

### The three fill passes

For a concave fill, `renderFillCommands` runs three passes ([trace step 9](./code-traces/contour-to-pixels.md)). The next excerpt, condensed from the source (named arguments dropped, the two `stencilFunc` calls omitted), shows the stencil settings that make pass 1 a pure tally pass: front faces increment with wrap, back faces decrement with wrap, and color writes are switched off.

**File:** `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/ExpansionDrawer.kt:272-285`

```kotlin
localStyle.frontStencil.stencilOp(KEEP, KEEP, INCREASE_WRAP)
localStyle.backStencil.stencilOp(KEEP, KEEP, DECREASE_WRAP)
localStyle.channelWriteMask = ChannelMask.NONE
```

| Pass | What it draws | Stencil test | Stencil update | Color writes |
|------|---------------|--------------|----------------|--------------|
| 1. Tally | The fill fan, as overlapping triangles | Always passes | Front faces `+1`, back faces `-1` (wrapping) | Off |
| 2. Feather | The fringe strips around the outline | Pass only where stencil `== 0` | Unchanged | On, shader fades alpha |
| 3. Cover | One bounding-box quad (6 vertices) | Pass where stencil `!= 0` | Set to zero | On, fill color |

Pass 2 runs before pass 3 for a reason. The fringe straddles the outline, so part of it lies inside the shape where the stencil is already non-zero. Testing `== 0` keeps the feather outside the shape, where it belongs, and stops it from double-blending over the fill. Pass 3 then paints the interior and zeros the stencil as it goes, so the next shape starts from a clean tally. This cleanup trick matters: the code never needs a separate "clear stencil" call for fills.

One observation deserves a flag. Pass 3 sets `stencilTestMask = 0x1` after setting the function with mask `0xff`, and nothing resets it before the draw (`ExpansionDrawer.kt:334-335`). `setState` forwards the mask straight to GL (`DriverGL3.kt:1538-1543`). If that reading is right, pass 3 tests only the lowest bit of the tally, which is an even-odd rule, while pass 1's wrapping increments suggest a non-zero rule. A pixel with a net count of 2 would count as outside. NanoVG uses `0xff` here. **This is untested.** The trace read the code and did not run a figure-eight or a doubly-wound star to see which rule the output follows. Do not rely on non-zero semantics until someone does.

### The convex fast path

Step 4 of the trace computes a `convex` flag with a turning-number check: all turns lean the same way and the total turning is exactly one full circle. A plain sign test misclassifies clockwise polygons (openrndr's default winding) and pentagrams. When `convex` holds, the fan cannot overshoot, so the tally is unnecessary. `renderConvexFillCommands` (`ExpansionDrawer.kt:189-229`) draws the fan and a half-width fringe in one pass with no stencil at all. That removes three draws and the stencil requirement for that shape. `expandFill` forces `convex = false` when a path has more than one contour (`Expansion.kt:655-657`), because holes always need the tally.

### The three stroke passes

Strokes use a different trio, again from NanoVG (`renderStrokeCommandsInterleaved`, `ExpansionDrawer.kt:120-187`). The problem here is not concavity but overlap: where a join or a self-crossing stroke overlaps itself, a semi-transparent stroke would blend twice and show a dark seam.

1. **Core.** Draw the opaque middle of the stroke only. The shader discards anything below `strokeThr = 1 - 0.5/255`, and the stencil increments, so a second layer cannot draw where the first one already did.
2. **Feather.** Draw the soft edges with `strokeThr = 0`, only where stencil is still zero.
3. **Reset.** Zero the stencil with color writes off.

All strokes in one call share a single command list and a single buffer, so the interleaved path issues each pass once for all contours rather than once per contour.

### What the shader does with all of this

One fragment shader serves every pass. It reads the interpolated `(u, v)` coordinates, computes `strokeMask`, mixes stroke and fill colors with `strokeFillFactor`, and discards fragments below `strokeThr`. Here is the heart of it ([trace step 10](./code-traces/contour-to-pixels.md)).

**File:** `openrndr-gl-common/src/commonMain/kotlin/ShaderGeneratorsGLCommon.kt:587-646`

```glsl
float strokeMask() {
    return min(1.0, (1.0-abs(v_ftcoord.x*2.0-1.0))*strokeMult) * min(1.0, v_ftcoord.y);
}
```

The CPU wrote `u` as 0 to 1 across the ribbon, so the mask peaks mid-ribbon and falls to zero at both edges. That falloff is the anti-aliasing. The passes differ only in which uniforms and stencil state they set.

---

## The Drawer Family: One Strategy per Kind of Thing

The expansion machinery is only one tool. `Drawer` owns a family of specialized drawers and picks one per call (`openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/Drawer.kt:63-74`). Each lives in `openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/`.

| Drawer | Used for | Technique | Anti-aliasing |
|--------|----------|-----------|---------------|
| `QualityPolygonDrawer` | Filled contours and shapes | CPU fan expansion, stencil passes, fringe | Geometric fringe |
| `QualityLineDrawer` | Strokes of 2D contours and polylines (`DrawQuality.QUALITY`) | CPU stroke expansion, three-pass stencil | Geometric fringe |
| `PerformanceLineDrawer` | Lines when `DrawQuality.PERFORMANCE` | `GL_LINES` primitives | None |
| `MeshLineDrawer` | Lines from 3D (`Vector3`) points | Triangle mesh built per segment, strip variant (`Drawer.kt:988`, `:1250`) | None seen: the fragment shader outputs a flat stroke color with no coverage fade (`ShaderGeneratorsGLCommon.kt:749-780`) |
| `CircleDrawer` | Circles | One instanced quad, distance field in the fragment shader | Shader-side, from `fwidth` |
| `RectangleDrawer` | Rectangles | One instanced quad, edges in the fragment shader | Shader-side |
| `PointDrawer` | Points | `POINTS` primitives sized by `gl_PointSize` | None seen: the fragment shader writes `x_fill` unmodified (`ShaderGeneratorsGLCommon.kt:260-292`) |
| `ImageDrawer` | `ColorBuffer` and array-texture images | Instanced textured quads | Texture filtering |
| `FontImageMapDrawer` | Text | Batched glyph quads from a font atlas | Atlas quality |
| `VertexBufferDrawer` | User-supplied `VertexBuffer`s | Passes your geometry straight to the driver | Yours |

Two switches choose among them. `DrawQuality` (QUALITY by default, `openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/DrawStyle.kt:411-442`) selects between the line drawers: the `drawer.lineSegment` and `drawer.lineStrip` families in `Drawer.kt` match on it at every call site (for example `:970-979` and `:986-989`). The overloads split by point type. `lineSegment(start: Vector2, end: Vector2)` (`:964`) sends QUALITY strokes to `QualityLineDrawer`, while `lineSegment(start: Vector3, end: Vector3)` (`:985`) sends them to `MeshLineDrawer`. The `lineSegments`, `lineLoop` and `lineStrip` families repeat that split. PERFORMANCE always sends them to `PerformanceLineDrawer`. Note that PERFORMANCE changes the stroke only. The fill in `contour()` still goes through `QualityPolygonDrawer`.

`drawStyle.smooth` works one level deeper. It does not switch drawers. It zeroes the fringe width inside the quality drawers (`fw = 0`, [trace step 7](./code-traces/contour-to-pixels.md)), which gives hard edges.

The family encodes a design rule worth stealing: use the cheap analytic path whenever the shape is simple enough to have a closed-form edge. Circles and rectangles skip the contour, the stencil and the CPU geometry entirely ([trace step 12](./code-traces/contour-to-pixels.md)). The expansion pipeline is the fallback for arbitrary paths, not the default for everything.

---

## The Price of the Tally: A Stencil Attachment Is Mandatory

Every stencil pass needs somewhere to store its tally. `Drawer.contour()` checks `RenderTarget.active.hasStencilBuffer` and throws if the answer is no (`Drawer.kt:880` guards the work, and the trace places the throw at `:917`). `shape()` does the same (`Drawer.kt:822`, throw at `:854`). Note that the check is not a convex special case: even a convex contour that would never touch the stencil still needs the attachment, because the guard sits above the fill branch.

For the window's default render target this costs nothing, since the application creates a depth and stencil buffer. The consequences land on offscreen work:

- **Offscreen `renderTarget {}` blocks need a stencil-capable depth buffer.** The builder's `depthBuffer()` defaults to `DepthFormat.DEPTH_STENCIL` (`openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/RenderTarget.kt:516`), so the common case works. A target built with only color buffers, or with a depth-only format, fails the moment you draw a contour into it.
- **Post-processing chains that draw vectors into intermediate targets** must attach a stencil each time. Each attachment adds memory per target, and ping-pong pairs double it.
- **Sharing a depth buffer between targets** also shares the stencil tally. That is safe only because pass 3 and the stroke reset zero it again. An exception between passes would plausibly leave residue for the next shape (reasoned from the code, not tested).

The failure mode is a thrown error at draw time, not a compile-time or creation-time mistake. The Rust section below suggests turning that into a type-level fact.

---

## State as a Mutable Value: `DrawStyle` Edited in Place

The three-pass algorithms need different stencil functions, ops, masks and color masks for each pass. openrndr does not build a style per pass. It takes the one `DrawStyle` in hand, flips fields on it, and calls the driver again. Think of a mixing desk: you push the same faders up and down between takes instead of buying a new desk for each song.

The trace records the aliasing: `localStyle = drawStyle` (`ExpansionDrawer.kt:133`, `:247`). `localStyle` is not a copy, so the edits are edits to the caller's style. The code restores `stencilTest = DISABLED` at the end of each routine (`:183`, `:361`). If a path forgot that reset, the next draw in the frame (an image, a circle, a rectangle) would run with stencil testing live, and it would silently pass or fail pixels according to leftover tally values. This is the main sharp edge of the design, and the reason an exception inside a pass is dangerous.

The driver softens the cost of the churn. `Driver.setState` compares the incoming style to a cached copy per context and issues GL calls only for changed groups: clip, color mask, depth, stencil, culling and blend (`DriverGL3.kt:1484`, [trace step 11](./code-traces/contour-to-pixels.md)). Two details matter when you read it:

- Pass 1 gives the front and back faces different ops, so the code compares `frontStencil !== backStencil` by object identity and takes the separate-face branch (`glStencilFuncSeparate(GL_FRONT, ...)` and `GL_BACK`). Passes 2 and 3 point both at the same object, which selects the `GL_FRONT_AND_BACK` branch.
- The stencil write mask is part of that cached state, so a changed mask triggers a GL call even if nothing else moved.

So the "mutable style" is cheap at the GL level (a diff, not a full reset) but fragile at the code level (the diff trusts that you restored what you changed).

---

## Immediate Versus Retained: Re-Expand Every Frame

openrndr is an immediate-mode drawer, like [p5.js](../p5js/rendering-pipeline.md). Call `drawer.contour(c)` in `extend {}` and the system flattens, joins, expands and uploads the geometry again, every frame, for every call. The `ShapeContour` object persists because you hold it, but nothing derived from it does. The trace confirms there is no cache of flattened or expanded geometry between frames ([Key Observation 6](./code-traces/contour-to-pixels.md)). A filled and stroked contour is even flattened twice in one call, once per branch.

Retained geometry exists in two places, and the drawing path uses neither:

- **`Shape.triangulation`** (`openrndr-shape/src/commonMain/kotlin/org/openrndr/shape/Shape.kt:108-116`) runs the triangulator in `Triangulator.kt:23` and caches the result on the shape. This is the only retained mesh path from the shape library. No drawer calls it.
- **`VertexBuffer`** (`openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/VertexBuffer.kt:69`) and the `vertexBuffer` helpers on `Drawer` (`Drawer.kt:1551`) let you upload geometry once and draw it many times through `VertexBufferDrawer`. If you want retained geometry for a heavy static shape, build the mesh yourself, perhaps from `Shape.triangulation`, and hand it over.

You might ask why the immediate path is acceptable. The answer is the cost model. Expansion is linear in the number of flattened points, and the scale-dependent tolerance means the flattening you do at zoom 1 is the right flattening for zoom 1. A retained mesh would go stale on every zoom change. For a few hundred shapes the CPU cost is small. For tens of thousands of static shapes, it is the first thing to profile.

---

## Rust and wgpu Considerations

The design maps well onto wgpu, with one structural shift: GL changes state between draws, and wgpu bakes state into pipelines. The [trace's Rust section](./code-traces/contour-to-pixels.md) has a longer sketch. These are the points that drive the decisions.

**Stencil becomes pipeline state.** Where GL calls `glStencilFuncSeparate`, wgpu puts a `StencilState` in the pipeline's `DepthStencilState`, with a `front` and a `back` `StencilFaceState`. Pass 1 uses `pass_op: IncrementWrap` for front faces and `DecrementWrap` for back faces. Passes 2 and 3 use `compare: Equal` and `compare: NotEqual` with a `read_mask` and a `write_mask`. The mask quirk from pass 3 therefore becomes an explicit, reviewable number in a pipeline descriptor instead of a field left over on a mutable style.

**The color mask is a pipeline property.** There is no draw-time `glColorMask`. Pass 1 needs a pipeline whose color target has `write_mask: ColorWrites::empty()`.

**One pipeline per pass.** The six passes become six cached pipelines, built once at startup. The runtime `setState` diff disappears, and so does the leaking-style bug class, because each pipeline is an immutable value. `set_stencil_reference` supplies the compare value per draw.

**Format availability.** The tally lives in the stencil aspect of a depth-stencil texture. `Depth24PlusStencil8` is the portable choice, and `Depth32FloatStencil8` needs a device feature on some backends. Check what the adapter offers on web and mobile before committing, because stencil precision is only 8 bits and the wrap ops depend on it. A path that winds more than 256 times over one pixel overflows the counter, so document the limit.

**Cache the expanded geometry.** openrndr re-expands every frame. In Rust you can key a `PathMesh` on contour identity, scale bucket and style, and reuse its buffers until one changes. Persistent buffers also remove the `fewVertices`/`manyVertices` rotation described below.

**The contrast with other approaches.** Stencil-and-fringe sits between two other designs in this repository. Lyon, which [nannou uses](../../themes/vector-graphics/tessellation.md), triangulates on the CPU into a static mesh and relies on MSAA for smooth edges. That is simple for static content but pays on every zoom change and fails on messy input. Vello's [sparse-strip approach](../../per-library/rust/vello/sparse-strips.md) computes per-pixel coverage near edges, which gives exact anti-aliasing and no stencil, but it needs compute shaders and a heavier pipeline. openrndr's route needs only a rasterizer, a stencil and a fragment shader, so it runs on the weakest targets. Its price is six draws per shape and an approximate (one-pixel fringe) edge.

---

## Performance Patterns and Gotchas

**Six draws for one concave, filled, stroked contour.** Three stencil passes for the fill and three for the stroke. A convex fill drops to a single pass (the fan and the fringe, with no stencil), which saves three of the six draws. The cost is per call, not per vertex, so thousands of tiny shapes hurt more than one large one.

**Double flattening.** Fill and stroke each call the adaptive flattener, then each run `prepare` and `calculateJoins`. For heavy curves this is the first duplication to remove in a port.

**Buffer rotation.** `toCommands` uploads all expansions of one call at once. Small uploads cycle through a few multi-buffered `fewVertices` buffers, so the GPU never reads a buffer the CPU is rewriting. Large ones go to a 4-million-vertex `manyVertices` buffer (`ExpansionDrawer.kt:428-454`). The rotation hides upload latency, but it is also hidden state: two drawers means two sets of buffers.

**Where batching happens.** Strokes batch. `renderStrokeCommandsInterleaved` puts every contour of one call into one buffer and issues each pass once for all of them, with degenerate vertices on both ends of each strip so strips do not connect. Fills do not batch: each fill expansion runs its own tally and cover sequence, because a shared stencil tally between unrelated shapes would mix their counts. Batching fills would need a cover quad per shape or a bounding-box scheme, which is why "batch many contours into one buffer per pass" is a recommendation in the trace and not something openrndr does today.

**Scale-dependent geometry.** Zooming 40x re-flattens everything. The cost is bounded (the tolerance tightens only as fast as pixels get bigger), but animating a zoom over a complex scene re-pays the full expansion each frame.

**Silent failures.** `addVertex` drops NaN vertices and `bevelJoin` returns early on NaN input. Bad geometry disappears instead of raising an error. Only `prepare` throws, and only for consecutive duplicate points.

---

## Related Documents

| Document | What you get |
|----------|--------------|
| **[code-traces/contour-to-pixels.md](./code-traces/contour-to-pixels.md)** | 12-step trace of `drawer.contour()` with excerpts, a data-flow diagram, and the full Rust adopt/modify/avoid list |
| [README.md](./README.md) | Framework overview and entry points |
| [architecture.md](./architecture.md) | Module layout, including `openrndr-draw` and the `Driver` abstraction |
| [Vector graphics theme](../../themes/vector-graphics/README.md) | The `Shape`/`ShapeContour`/`Segment2D` data model and boolean operations |
| [Tessellation approaches](../../themes/vector-graphics/tessellation.md) | Lyon and CPU triangulation, the road openrndr does not take |
| [Vello sparse strips](../../per-library/rust/vello/sparse-strips.md) | Coverage-based rasterization as the alternative to stencil-and-fringe |

---

## Summary

- **NanoVG by design.** The CPU expands paths into a fan and ribbons, the stencil sorts inside from outside, and the shader fades a one-pixel fringe. No triangulator runs in the draw path.
- **Zoom-proof.** `modelViewScaling` sets both flattening tolerance and fringe width, so edges stay about one device pixel soft at any scale, with no MSAA.
- **Six passes, with a fast path.** Concave fills and strokes cost three draws each. A turning-number convexity check skips the stencil for simple shapes. Pass 3's `stencilTestMask = 0x1` may make the fill rule even-odd, and no one has tested it.
- **Stencil is a hard requirement.** `contour()` and `shape()` throw on targets without a stencil buffer, and `DrawStyle` is edited in place, so a missed reset leaks into later draws.
- **Simple shapes skip all of it.** Circles, rectangles and points use instanced quads with analytic edges. In wgpu, the six passes become six cached pipelines, and the expanded geometry becomes cacheable.

---

## Not Covered Yet

- [ ] Frame lifecycle and `extend {}` blocks
- [ ] Shader compilation and caching
- [ ] Render targets and post-processing (only the stencil implications appear above)
- [ ] Draw call batching beyond paths (images, text, instanced circles and rectangles)

*Part of the [openrndr study](./README.md). Source commit: `00c47af75ddc`; line numbers refer to that commit.*
