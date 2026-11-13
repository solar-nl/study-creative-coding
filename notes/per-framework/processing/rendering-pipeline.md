# The Processing Rendering Pipeline

> You write `beginShape()` once. Depending on one string in `size()`, either the JDK or your own CPU turns it into pixels, and the two results are not identical.

## Key Insight

> **Processing's core idea:** One API, two rasterizers: Java2D owns geometry and anti-aliasing; P2D/P3D build exact triangles on the CPU and lean on MSAA.

---

## The Problem: A 2001 API Meets the GPU

Processing launched in 2001 with a simple promise: call `ellipse()`, `line()` or `beginShape()`, and something appears. The first implementation sat on top of Java's software 2D rasterizer. That rasterizer already knew how to fill a path, stroke it with a pen of any width, and smooth the edges. Processing only had to describe shapes and hand them over.

Years later, sketches needed more: thousands of shapes per frame, textures, shaders, 3D. Software rasterization could not keep up, and OpenGL could. The catch is that OpenGL has no concept of a "path" or a "pen". It draws triangles, points and lines. Processing had millions of lines of user code, tutorials and books written against the old API, so the new backend had to accept the same calls and produce the same drawings without any user edits.

That constraint shaped everything below. The OpenGL renderer had to rebuild, on the CPU, the services Java2D used to provide for free: curve flattening, polygon filling, stroke outlines. You can see the cost of that choice in the details of the pipeline, and you can still observe it on screen when you switch renderers.

## The Mental Model: One Script, Two Translators

Imagine you hand the same screenplay to two translators. The first (Java2D) translates it into a *vector description*: "move here, line there, cubic curve through these control points, close." She trusts the reader (the JDK rasterizer) to know how to act it out. The second (P2D) translates it into a *triangle list*: a flat inventory of every triangle the GPU must paint, with all curves already chopped into straight segments and all pen widths already turned into geometry. His reader (the GPU) is fast but literal, and understands only triangles.

Both translators read the same script, so the plot matches. The wording differs, though, and so do the details: how a corner looks, how thin a line renders, how smooth a curve appears. This document traces one script through both translators and then explains why Processing keeps both.

---

## Tracing a Drawing Call: `beginShape` to Pixels, Twice

The full 15-step walkthrough, with line numbers and code, lives in [code-traces/shape-to-pixels.md](./code-traces/shape-to-pixels.md). Here we follow the same sketch (a polygon with one cubic Bézier, `strokeWeight(6)`, round joins, `smooth(4)`) and compress it into a state table. The step numbers point back into the trace.

### Before the branch: choosing and fronting the renderer

Three steps happen before the two paths diverge.

**Selection by string.** `size(w, h, renderer)` only stores a class name. `PConstants` defines `JAVA2D` as `"processing.awt.PGraphicsJava2D"`, `P2D` as `"processing.opengl.PGraphics2D"` and `P3D` as `"processing.opengl.PGraphics3D"`. Nothing is instantiated yet (trace step 1).

**Reflection.** `makeGraphics()` loads that class by name and calls its no-arg constructor, then calls `setParent` and `setPrimary` (trace step 2). Every renderer is a `PGraphics` subclass, so the sketch only ever sees the base type.

**Template-method front end.** `ellipse()` and `rect()` resolve `ellipseMode`/`rectMode` and negative extents, then call a protected `ellipseImpl`/`rectImpl` with canonical arguments (trace step 3). This is like a recipe with blanks: the base class writes the steps, and each backend fills in the geometry. `rectImpl` defaults to `quad()`, so a backend that overrides nothing still draws rectangles. `beginShape`/`vertex`/`endShape` are open-ended and each backend overrides them directly.

### The state table

Read each row as "what exists after this stage". The left column is Java2D, the right is P2D.

| Stage | Java2D output | P2D output |
|-------|---------------|------------|
| `beginShape()` (steps 4, 8) | `gpath = null`; no vertex yet | `inGeo.clear()`; empty input geometry |
| `vertex()` | `GeneralPath.moveTo`, then `lineTo` | Position appended to `inGeo` with a `VERTEX` code |
| `bezierVertex()` (steps 5, 11) | `gpath.curveTo(...)`: the cubic stays a cubic | `BEZIER_VERTEX` code and control points stored; nothing flattened yet |
| `endShape(CLOSE)` (steps 6, 8) | `closePath()`, then `drawShape(gpath)` right now | `tessellate(mode)` into `tessGeo`; draw only if flush mode says so |
| Fill (steps 7, 9, 11) | `g2.fill(path)`: JDK scanline fill | `POLYGON` goes through GLU (NONZERO); curve flattened with fixed `bezierDetail` |
| Stroke (steps 7, 12) | `g2.draw(path)` with `BasicStroke(weight, cap, join)` | CPU triangles: quads (fast) or a stroked outline run through GLU (accurate) |
| Batching (steps 8, 14) | None; every call paints immediately | Triangles accumulate in `tessGeo` until the buffer fills or something forces a flush |
| GPU hand-off (step 14) | None | `flush()` swaps in an identity modelview, then `glDrawElements(TRIANGLES)` per `IndexCache` range |
| Anti-aliasing (steps 7, 14) | Rendering hint; analytic coverage per path | MSAA sample count from `smooth()`; no shader-level AA |
| Result | `BufferedImage` shown in the window | GL framebuffer, resolved from the multisample buffer |

Three rows deserve a closer look, because they carry most of the surprises.

### Fill: the choice is by shape kind, not by geometry

Inside `tessellate`, P2D copies draw state (including the current `modelview`, so vertices get transformed on the CPU) into a `Tessellator` and picks an algorithm by shape kind (trace step 9). Triangles, fans, strips and quads use trivial index generation. Only `POLYGON` goes through the GLU tessellator, and it does so even when the polygon is convex.

For the winding rule, `tessellatePolygon` takes a `solid` flag: `true` means NONZERO, `false` means ODD (trace step 11). The immediate-mode call always passes `solid = true`, so `beginShape/endShape` polygons are always NONZERO. ODD is only reachable from a retained `PShapeOpenGL`. If you hoped to punch holes with even-odd in a plain sketch, you cannot.

### Curves: adaptive for ellipses, fixed for Béziers

`ellipseImpl` builds a triangle fan whose vertex count follows the ellipse's *on-screen* diagonal, clamped between a minimum and a maximum (trace step 10). A small circle gets few segments and a large one gets many. Béziers behave differently: `addBezierVertex` steps through the curve with forward differencing for exactly `bezierDetail` points, whatever the size on screen (trace step 11). Zoom a Bézier shape up by scaling, and the facets show.

### Strokes: geometry, not a pen

In P2D a stroke is more triangles. `tessellateEdges2D` chooses between a fast path (one quad per segment, no caps or joins) and an accurate path (build a `LinePath`, stroke it into an outline, tessellate that outline with GLU). The decision sits in `noCapsJoins`, and the thresholds are 2 px of effective weight (`PGL.MIN_CAPS_JOINS_WEIGHT`, `core/src/processing/opengl/PGL.java:116`) and 5000 vertices (`PGL.MAX_CAPS_JOINS_LENGTH`, `PGL.java:121`).

**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:12956-12978` (inside `noCapsJoins`)

```java
return tess.renderMode == IMMEDIATE &&
       transformScale() * strokeWeight < PGL.MIN_CAPS_JOINS_WEIGHT;
```

This is the heart of the shortcut: only immediate mode may skip caps and joins, and only when the scaled weight falls below 2 px. A retained shape always takes the accurate path. Our weight-6 sketch takes the accurate path. The stroker inside `LinePath`/`LineStroker` is JDK-derived (per headers): the file headers carry Sun and Oracle notices, so Processing reimplemented a Java2D-style stroker to feed its triangle pipeline (trace step 12).

### The last hop: identity modelview and one draw call

Because the CPU has already applied the modelview to every vertex, `flush()` must stop the GPU from applying it again.

The swap happens only in `FLUSH_WHEN_FULL` mode (the default, see "State" below).

**File:** `core/src/processing/opengl/PGraphicsOpenGL.java:2267-2276`

```java
modelview0 = modelview;
modelviewInv0 = modelviewInv;
modelview = modelviewInv = identity;
```

After this swap, `flushPolys` uploads the buffers, binds the poly shader and walks the `IndexCache` ranges, issuing a `drawElements(TRIANGLES, ...)` for each. The call chain is three thin hops (`PShaderOpenGL.draw`, `PGL.drawElements`, `PJOGL.drawElementsImpl`), and the abstract `PGL` is what keeps the backend (JOGL) replaceable (trace step 14). The mode is always `TRIANGLES`.

Anti-aliasing is whatever the sample count gives. `PGL.smoothToSamples` maps `smooth(1)` to 2x, `smooth(0)` to 1x, and any other N to N samples, and `PSurfaceJOGL` requests that many from the window system when it builds the GL capabilities for the main window (`PSurfaceJOGL.java:248-249`, `PGL.java:468-477`). Both polygon edges and the CPU-built stroke outline rely on it.

---

## Why Two Backends? What Each Rasterizer Is Good At

You might wonder why Processing did not simply replace Java2D with OpenGL. The answer is that each side wins on something the other cannot offer.

### What Java2D gives

- **Analytic coverage anti-aliasing.** The JDK scanline rasterizer computes how much of each pixel a path covers. Edges look smooth without multisampling.
- **Exact strokes.** `BasicStroke` handles any weight, cap and join correctly, from a hairline to a 200 px pen.
- **No GPU needed.** It runs anywhere Java runs, including machines with poor drivers. (Headless use is plausible, since Java2D can draw into a `BufferedImage`, but we did not verify that Processing's sketch startup works without a display; `PGraphicsJava2D` and `ShimAWT` do query `GraphicsEnvironment`.)
- **Curves stay curves.** The path keeps the cubic until the last moment, so scaling never shows facets.

### What P2D and P3D give

- **Speed for large scenes.** Thousands of shapes batch into a few draw calls instead of thousands of CPU-rasterized paths.
- **Shaders.** The poly pipeline has a shader entry point (`PShaderOpenGL`), so custom GLSL is possible.
- **Textures and image operations** on the GPU.
- **3D.** P3D shares the pipeline and adds depth, lights and perspective.

### What you can observe when you switch

The same sketch looks different. These are the visible seams, each traceable to a step above.

| What you see | Java2D | P2D |
|--------------|--------|-----|
| Stroke joins | Exact miter, round or bevel | Exact on the accurate path; gaps or overlaps at corners under the 2 px fast path |
| Thin lines | Anti-aliased hairlines by coverage | Quads per segment, smoothed only by MSAA samples |
| Curve smoothness | Smooth at any scale | Béziers use fixed `bezierDetail`; ellipses adapt to screen size |
| What `smooth()` means | Turns the JDK rendering hint on or off | Sets the MSAA sample count, fixed when the window opens |
| Contours (holes) in `beginShape` | Contour path appended to the main path (`auxPath`) and filled by the JDK | GLU with NONZERO only in immediate mode |

The last row of the earlier state table matters here: `smooth(4)` in a Java2D sketch is a toggle, while in P2D it chooses 4x multisampling and changes how much GPU memory and fill rate you spend. The same word carries two meanings.

---

## State: One Global Brush

Like p5.js (see the [p5.js rendering pipeline](../p5js/rendering-pipeline.md)), Processing keeps draw state as fields on the renderer. `fill`, `stroke`, `strokeWeight`, `strokeJoin`, `strokeCap`, `ellipseMode`, `rectMode`, the current `modelview` and the rest are all members of `PGraphics`, and every draw call reads them. The `Tessellator` setup in step 9 is the clearest evidence: it copies these fields one by one at the start of every `tessellate`.

`pushMatrix()`/`popMatrix()` save and restore the transform. The base `PGraphics` versions (`PGraphics.java:5341,5359`) are stubs that only show a "not available" warning; each renderer supplies the real stack (`PGraphicsJava2D.java:2159,2170`, `PGraphicsOpenGL.java:3683,3696`). `pushStyle()`/`popStyle()` are implemented in the base class and save and restore the style fields through a `PStyle[]` stack (`PGraphics.java:6268,6292`). Transform and style are separate stacks, which differs from p5.js, where `push()`/`pop()` do both. In Processing 4 you can still call `pushMatrix()` and `pushStyle()` independently, and forgetting one half is a classic bug.

Three pieces of state change how the pipeline behaves, not only how it looks.

**`flushMode`.** The default is `FLUSH_WHEN_FULL` (`PGraphicsOpenGL.java:107`), meaning many shapes batch into one draw. `FLUSH_CONTINUOUSLY` (`:97`) flushes at every `endShape`. The first is faster, and the second keeps draw order exact against external GL calls.

**The 2D stroke rule.** In 2D, strokes are written into the poly buffers, so `flush()` only calls `flushLines` and `flushPoints` when `is3D()` (trace step 13). One shader and one index list handle fills and strokes, and painter's order follows emission order.

**`hint()` flags.** Some hints rewire the pipeline. `hint(DISABLE_OPTIMIZED_STROKE)` would force `FLUSH_CONTINUOUSLY`, which is why P2D refuses it with "Optimized strokes can only be disabled in 3D" (`PGraphicsOpenGL.java:1835-1840`). Hints in P2D are therefore not a free-for-all: some are accepted, some warned about, some refused.

---

## Immediate vs. Retained: Pay Per Frame or Pay Once

Processing's immediate mode re-tessellates on every `endShape`. An animated sketch that draws the same polygon each frame reruns GLU, curve flattening and stroking each frame. That is the price of "draw it and forget it", the same trade p5.js makes.

`PShape` (data model in the [vector graphics theme](../../themes/vector-graphics/README.md#processing-the-retained-mode-pioneer)) changes the economics. Think of it as the difference between hand-lettering a sign every morning and printing it once, then hanging it up each day. `PShapeOpenGL.draw` calls `updateTessellation`, which tessellates the root only when `!root.tessellated`. `markForTessellation` clears that flag, so edits trigger a rebuild and plain redraws do not. Buffers go up to the GPU once as VBOs, and later frames only render from them (trace step 15). Transforms on a retained shape update its matrix instead of re-tessellating, because `tessellateImpl` runs the same `Tessellator` with the shape's own matrix instead of the frame's modelview.

Two coupling details keep the two modes consistent:

- **`shape()` flushes first.** `PGraphics.shape()` calls `flush()` before drawing the retained shape, so pending immediate triangles reach the GPU before the shape's own. Without that, depth and draw order would break.
- **`clamp2D` is immediate-only.** Pixel snapping applies only when the renderer is 2D, in `IMMEDIATE` mode, and the transform has no rotation or skew (`PGraphicsOpenGL.java:12261-12263`). A shape drawn through `shape()` does not snap, so the same geometry can sit half a pixel apart depending on which path drew it.

---

## Rust/wgpu Considerations

The Processing split maps onto our Rust framework in a way that simplifies some things and sharpens one hard question. The companion section of the trace ([Implications for Rust Framework](./code-traces/shape-to-pixels.md#implications-for-rust-framework-flux)) holds the full adopt/modify/avoid list. Here are the points that matter for the pipeline's shape.

**One backend, but the same ownership question.** wgpu replaces Java2D and OpenGL with a single GPU path, so a "software fallback" backend is not needed for most targets. The question Processing answered twice is still open: who owns coverage? With MSAA, as in P2D, geometry must be exact triangles and edges depend on sample count. With analytic coverage, as in Java2D, the rasterizer owns the edges. The [vello sparse strips](../../per-library/rust/vello/sparse-strips.md) note shows a GPU-era approach to analytic coverage, and [tessellation](../../themes/vector-graphics/tessellation.md) compares triangulation strategies. Our framework should pick one on purpose and expose the sample count as an explicit setting, not as an implicit "smooth".

**Trait-based selection instead of reflection.** Processing's string-and-reflection selection allows third-party renderers, at the cost of compile-time checks and a two-phase constructor. [insights/rust-specific.md](../../../insights/rust-specific.md) (lines 46-59) sketches a `Renderer` trait with `Renderer2D` and `RendererGL` implementors, and that sketch mirrors Processing's split directly. A trait object or enum chosen at startup gives the same extensibility with static types and a normal constructor.

**Batching with an index-range list.** Processing's `IndexCache` is the right idea: accumulate triangles, record ranges, and break a draw only when texture or shader changes. In Rust that is a vertex `Vec`, an index `Vec`, and a `Vec<DrawRange>`:

```rust
// Pre-transformed 2D vertices plus ortho: one batch, many shapes.
struct Batch { vertices: Vec<Vertex>, indices: Vec<u32>, ranges: Vec<DrawRange> }
```

**Pre-transformed vertices plus ortho.** Applying the transform on the CPU, as Processing does, lets many shapes share one draw. But pass the transform explicitly with each batch instead of swapping a hidden identity into global state, as `flush()` does.

**Retained handles.** Offer a `RetainedShape` that tessellates when marked dirty, uploads once, and draws with a matrix. That is `PShapeOpenGL`'s lesson, minus the dependency on root and child bookkeeping.

---

## Performance Patterns and Gotchas

**Per-vertex allocation in Béziers.** `addBezierVertex` copies a `double[]` attribute template for every flattened point (`Arrays.copyOf`, trace step 11). A shape with many curves allocates many short-lived arrays each frame. In Rust, reuse a scratch buffer.

**GLU on every polygon.** Because the fill algorithm is chosen by shape kind, a convex `POLYGON` pays for GLU like a concave one. If you know a polygon is convex, drawing it as a `TRIANGLE_FAN` skips GLU entirely.

**Hidden thresholds change output.** Stroke quality switches at 2 px and at 5000 vertices, and only in immediate mode. A long polyline can silently lose caps and joins. If a stroke looks wrong in P2D, check these limits first.

**MSAA cost.** Multisampling multiplies framebuffer memory and resolve work. `smooth(8)` on a large P2D window costs real fill rate on integrated GPUs. Because the CPU-built stroke outlines are antialiased only by MSAA, lowering the sample count degrades strokes and fills together.

**`loaded = false` invalidates pixel arrays.** When `endShape` batches instead of flushing, it sets `loaded = false` (`PGraphicsOpenGL.java:1938`) to mark the cached `pixels[]` stale. The next pixel access must therefore refresh that array from the framebuffer. Treat per-frame pixel access in P2D as a synchronization point that undoes batching (the mechanics of `loadPixels` are in "Not Covered Yet").

**Retained does not mean free.** Marking a `PShape` for tessellation after every edit gives you immediate-mode costs plus bookkeeping. Edit rarely, and transform with matrices.

---

## Related Documents

| Document | Lines | Covers |
|----------|-------|--------|
| **[code-traces/shape-to-pixels.md](./code-traces/shape-to-pixels.md)** | 769 | 15-step trace of `beginShape/vertex/bezierVertex/endShape` through Java2D and P2D: reflection, path vs `inGeo`, GLU, CPU strokes, flush, MSAA, retained `PShape` |
| **[README.md](./README.md)** | 51 | Processing overview, philosophy, key entry points |
| **[architecture.md](./architecture.md)** | 17 | Module structure and entry points |
| **[p5.js rendering pipeline](../p5js/rendering-pipeline.md)** | 537 | Processing's descendant: Canvas 2D vs WebGL, the same immediate-mode model |
| **[Vector graphics theme](../../themes/vector-graphics/README.md)** | 782 | `PShape` families and how Processing compares with other path models |

---

## Summary

- **One API, two rasterizers.** Java2D keeps paths and lets the JDK flatten, stroke and anti-alias; P2D/P3D build triangles on the CPU and rely on MSAA.
- **The front end is shared, the geometry is not.** Mode handling lives in `PGraphics` template methods; `beginShape/endShape` are overridden per backend, which is where the two outputs diverge.
- **Strokes and curves are CPU work in P2D.** Fixed-detail Béziers, adaptive ellipses, a 2 px / 5000-vertex stroke threshold and GLU for every polygon explain most visual differences and costs.
- **State is global, and some of it changes the pipeline.** `flushMode`, `hint()` flags and the 2D stroke-in-poly-buffer rule decide how many draws you get and in what order.
- **Immediate pays per `endShape`, retained pays once.** `PShapeOpenGL` tessellates into root VBOs, rebuilds when marked and moves by matrix; for Rust, pick a coverage model deliberately, batch with ranges, and give users retained handles.

---

## Not Covered Yet

- Frame lifecycle (`setup`/`draw`/`redraw`, end-of-frame flush)
- `loadPixels`/`updatePixels` and pixel array access in detail
- P3D lighting and camera
- FX2D (the JavaFX renderer)
- Offscreen `PGraphics` buffer management

---

*This document is part of the [Processing study](./README.md).*
