# 2D Rendering Strategy: How Flux Turns Paths into Pixels

Flux can draw a circle, a rectangle and a line, because each has a formula and a fragment shader can evaluate a formula per pixel. It cannot draw a Bézier blob, a glyph outline or an SVG import, because nothing in a shader says how much of a pixel a curve covers. Flux has not answered that yet.

This note scores the five strategies in [Rasterization Strategies](../notes/themes/vector-graphics/rasterization-strategies.md), which deliberately picks none, against Flux's constraints, and records the result as [ADR-005](./architecture-decisions.md).

**The short version:** Depend on `vello_gpu` (sparse-strip coverage, 0.3.0) as Flux's path and text rasterizer, behind a Flux-owned `PathRasterizer` trait so it can be swapped. Keep instanced analytic primitives for circles, rects and lines. Keep Lyon only where a triangle mesh is the product. Reject stencil-and-fringe and compute as defaults. The thinnest evidence is per-frame cost on phones, so the first prototype measures it.

---

## The Question: Who Decides How Much of a Pixel a Curve Covers?

A creative-coding framework that draws only circles and rectangles is a stamp collection. Real work needs outlines: type set from font curves, shapes imported from SVG, generative paths that wobble, grow and fold every frame. In the node-graph study, Flux's state is stated bluntly: "textures-only as 2D primitive. Vector paths as a port type would unlock print pipelines, parametric type, plotter output, motion-graphics strokes, PDF/SVG export" ([operator-families-vs-flux.md:186-188](../notes/themes/node-graphs/operator-families-vs-flux.md)). So the question is not academic. A path port type needs a renderer behind it, and that renderer must run on desktop, mobile and the browser from one codebase.

Think of a workshop that has to cut both straight boards and curved brackets. You could buy one machine that does both badly, or send straight cuts to the table saw and curves to the bandsaw. Flux already owns the table saw: instanced quads with a distance function handle every shape that has a formula, at 16 to 28 bytes per instance and one draw call per primitive type ([primitive-strategies.md](../notes/themes/rendering/primitive-strategies.md)). The question is which bandsaw to buy for everything else, and whether to build it or depend on a maker who already has one.

---

## Flux's Constraints

Eight constraints decide this. Seven come from decisions Flux already made, and the eighth describes how creative coders actually use paths.

- **wgpu only.** [ADR-002](./architecture-decisions.md) picks wgpu for desktop, mobile and web. No second graphics API sits behind it.
- **Immediate-mode API, batched internally.** [ADR-003](./architecture-decisions.md): users write `draw.ellipse()`, and Flux batches to wgpu. Whatever handles paths must accept "record now, draw later" without asking the user to manage retained objects.
- **Texture-first node graph.** A 2D node produces a texture that other nodes consume. The path renderer is a node that writes into a texture on the host's command encoder. It does not own the frame.
- **No required wgpu features.** Flux wants to run on a baseline device and negotiate extras at runtime. A strategy that needs compute, a stencil format on every target or an optional feature loses points.
- **WebGL2 reach.** wgpu's GL backend gives Flux older browsers and older phones. Compute shaders do not exist there.
- **Exact anti-aliasing.** Type and print-quality output need edge coverage that matches the geometry, not a sample count.
- **Vector paths as a future port type.** The same path data must feed the rasterizer, SVG export, PDF export and a plotter.
- **Dynamic generative scenes.** In a sketch, paths change every frame. A strategy that wins only when geometry is cached does not fit the typical case.

One more consequence follows from the first constraint. [`rust-specific.md`](./rust-specific.md) sketches a `Renderer` trait with a `Renderer2D` and a `RendererGL` implementation, which mirrors Processing's Java2D and P2D split ([Processing rendering pipeline](../notes/per-framework/processing/rendering-pipeline.md): "One API, two rasterizers"). Processing needed two backends because Java2D owned a CPU rasterizer and OpenGL owned triangles. Flux has one graphics backend. That sketch should be retired in favour of one wgpu backend with a `PathRasterizer` trait, which this note defines below. This note does not edit `rust-specific.md`.

---

## The Options, Scored Against Those Constraints

The table scores each option on the constraints that discriminate. "Pass" means the evidence supports it, "fail" means the evidence contradicts it, and "(inferred)" marks a judgment from reading the pipeline, not from a cited note. Rows A to E are the five strategies as the theme note labels them, and the last three rows are hybrids.

| Option | Features and WebGL2 | AA quality | Dynamic paths, per frame | Path export and text | Effort |
|--------|---------------------|-----------|--------------------------|----------------------|--------|
| **A** Lyon tessellation + MSAA | Pass: plain vertex and fragment shaders; MSAA targets cost memory | Fail: sample-count bound, MSAA only in Processing P2D (`frameworks/processing/core/src/processing/opengl/PGL.java:468-477`) | Fail: re-flatten, triangulate and upload every changed path | Paths yes; text needs a separate glyph system | Low with Lyon |
| **B** NanoVG-style stencil + fringe | Fail: depth-stencil attachment mandatory, and `contour()` throws without one (`frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/Drawer.kt:917`); WebGL2 untested | Pass: fringe ramp one device pixel wide | Medium: linear flatten and expand, but about six draws per concave filled and stroked contour | Text not studied | Medium |
| **C** Sparse strips via `vello_gpu` | Pass: `Features::empty()` (`libraries/rust/vello/vello_gpu/examples/render_to_file.rs:56`), WebGL2 limits (`vello_gpu/examples/wgpu_webgl/src/lib.rs:73-77`), a separate `render/webgl/` backend | Pass: exact analytic coverage at 0.25 px flatten tolerance | Medium to high: flatten, tile, sort and strip per recorded path, no triangulation | Paths yes; `glifo` text in path mode | Lowest: depend on it |
| **C'** Reimplement sparse strips in Flux | Pass, same as C | Pass, same as C | Same as C | Same as C | Highest of the viable options: SIMD tile pipeline plus a layer scheduler |
| **D** Compute-centric coverage | Fail: compute shaders mandatory, no WebGL2 | Pass: exact | Best: CPU only encodes the scene | `glifo` targets the strips renderers; compute text path not studied | Highest: about twenty dispatches and memory sizing |
| **E** Instanced analytic primitives | Pass: instancing and `fwidth` only | Pass: smooth via distance function | Best: per-instance data only | Parametric shapes only; no arbitrary paths or text | Low per shape |
| **A + E** | As A for paths | As A for paths | Fails the dynamic-path constraint for anything non-parametric | As A | Low |
| **B + E** | As B for paths | As B for paths | As B for paths | As B | Medium |
| **C + E** (recommended) | Pass | Pass | Cheap for parametric shapes; medium to high for arbitrary paths | Paths and text through one representation | Low |

Why each loser loses:

- **A fails on two constraints at once.** MSAA ties edge quality to a sample count, and the sample count is fixed when the target opens. Re-tessellating a changed path every frame also puts the whole triangulation cost on the CPU, which is the constraint-eight case.
- **B fails on a hard requirement.** The stencil attachment must exist on every target that draws paths, and a missing one is a runtime error. It also draws about six times per concave filled-and-stroked contour. The fill rule is unsettled: pass 3 sets `stencilTestMask = 0x1` and never resets it (`ExpansionDrawer.kt:335`), so even-odd versus non-zero behaviour is an untested open question in the study. Exact type cannot rest on an open question.
- **D fails on reach and on memory.** Compute is not available on WebGL2. Shaders claim slots from bump counters in a fixed-size scratch buffer, and the CPU learns only afterwards whether it was big enough (`libraries/rust/vello/research/vello_encoding/src/config.rs:26-37`). Upstream moved this renderer under `research/` and describes "different compatibility and memory trade-offs" (`libraries/rust/vello/ARCHITECTURE.md:8-9`).
- **C' loses on effort, not on merit.** It is the same design as C. Flux would write a SIMD tile pipeline and a layer scheduler to arrive where a dependency already stands.
- **E alone cannot draw a path.** It stays in the plan as the fast lane.

### A Concrete Case: One Wobbling Blob, 60 Times a Second

Let's trace what each option does when a user draws a closed path of 40 cubic segments whose control points move every frame, with a translucent fill and a stroke.

| Step | A: Lyon + MSAA | B: stencil + fringe | C: sparse strips |
|------|----------------|---------------------|------------------|
| CPU work | Flatten, triangulate fill, expand stroke to a ribbon, upload vertex and index buffers | Flatten twice (fill and stroke), build fan and fringe | Flatten at 0.25 px, bin into 4x4 tiles, sort, accumulate coverage |
| Bytes to the GPU | Vertices and indices, growing with triangle count | Small vertex buffer | 16 bytes per edge tile plus 24 bytes per strip instance |
| GPU draws | One mesh draw, resolved from an MSAA target | About six draws with stencil state changes | Instanced quads inside the node's passes |
| Translucent fill plus stroke | MSAA does not stop two overlapping stroke triangles from blending twice | Stroke core pass prevents the double blend | Stroke expands to an outline and fills once, so it blends once |
| Edge pixel | Binary per sample | Soft ramp, one pixel wide | Exact area coverage |

Every option redoes its CPU work each frame for this blob, because the shape changed. The difference is what that work buys. Option A buys a mesh whose edge quality depends on a sample count. Option C buys exact edges and spends no effort on triangulation. The same row-by-row reading explains why the study does not simply call the CPU cost of C a flaw: it is the cost of getting the edge right. Table A of the theme note rates A as high on this workload and B as medium, and C as medium to high, so the CPU ranking is not decisive. The edge quality is.

### Where the Evidence Is Thin

Be honest about one constraint. "Dynamic generative scenes" is the constraint with the least data behind it. The rasterization theme lists as an open question how many animated non-parametric paths a typical sketch draws, and says "the study holds no measurement". The CPU/GPU split note names the regime where this recommendation is weakest: "A scene where thousands of paths move every frame pays the full CPU cost for each, which is where tessellation caches or a GPU flattening path would start to look attractive."

That sentence is a reason to measure, not a reason to flip. My expectation (inferred, not measured) is that a sketch with tens to hundreds of animated paths stays comfortable, and parametric shapes bypass the cost entirely. The risk lives in the tail: particle-like swarms drawn as paths. Flux has a cheaper answer for most of those (instanced primitives, as the primitive-strategies note shows for 1,000 circles in one call), so the tail shrinks further. Prototype 1 below tests the tail directly.

---

## Recommendation: Depend on `vello_gpu` Behind a Flux Trait, Keep the Table Saw

**Adopt C + E.** Flux routes by shape, as [openrndr's circle drawer](../notes/themes/vector-graphics/rasterization-strategies.md) already does (instanced SDF quad versus its contour path, about one draw versus six). Shapes with a formula go to Flux's instanced analytic lane. Everything else goes to `vello_gpu`, behind a Flux-owned trait.

The argument rests on five facts from the evidence, each tied to a constraint.

1. **It asks nothing of the device.** Every in-repo example requests `Features::empty()` (`vello_gpu/examples/render_to_file.rs:56`), and the one optional feature the renderer probes, `EXTERNAL_TEXTURE`, is detected at runtime ([wgpu-integration.md](../notes/per-library/rust/vello/wgpu-integration.md)). That matches "no required features".
2. **It reaches WebGL2.** The wgpu example requests `Limits::downlevel_webgl2_defaults()` (`vello_gpu/examples/wgpu_webgl/src/lib.rs:73-77`), and a separate backend in `vello_gpu/src/render/webgl/` implements the same five-method `Backend` trait ([cpu-gpu-split.md](../notes/per-library/rust/vello/cpu-gpu-split.md)). Compute-based options cannot say this.
3. **It computes exact edge coverage.** The strip stage accumulates signed area per pixel and writes 16 bytes per 4x4 edge tile (`vello_common/src/strip.rs:487-500`) after flattening at a 0.25 px tolerance (`vello_common/src/flatten.rs:15-19`). Zoom re-flattens at the new transform, so edges stay exact. That is the property type and print output need, and neither MSAA nor a fringe provides it.
4. **It slots into a node graph.** `Renderer::render` takes the caller's `&mut CommandEncoder` and target view and never submits (`vello_gpu/src/render/wgpu/mod.rs:346`; the only `submit` is in the separate `render_to_atlas`, `:481`). A path-layer node can consume a host encoder the way any Flux pass does.
5. **One representation covers paths, strokes, clips and text.** Strokes expand to an outline through kurbo and then run the same fill (`vello_common/src/flatten.rs:221-250`). Clips are CPU set operations on strip lists, so the GPU needs no stencil or mask state. Text arrives as ordinary `fill_path` calls through `glifo`, whose default mode is path mode ([text-glifo.md](../notes/per-library/rust/vello/text-glifo.md)).

Rectangles show why the two lanes overlap harmlessly. Vello has its own rect fast path that skips flatten, tile and strip (`vello_gpu/src/draw.rs:228`), so a rect sent to either lane stays cheap. Flux's instanced lane stays the default for Tier 1 and Tier 2 shapes because it batches thousands into one draw call and needs no CPU geometry at all.

### What this supersedes

Three study notes say "use Lyon" for fill tessellation: [tessellation.md](../notes/themes/vector-graphics/tessellation.md) ("Recommendations for Rust"), the [vector-graphics README](../notes/themes/vector-graphics/README.md) ("Suggested Tessellation Strategy" and "Where to Go Next"), and Tier 4 of [primitive-strategies.md](../notes/themes/rendering/primitive-strategies.md) ("Tessellate on CPU (using Lyon, etc.)"). Those notes advised Lyon before the study had examined sparse strips. They describe how a tessellation pipeline works, and that description remains valid. Their recommendation does not survive the comparison above: it fails the exact-AA and dynamic-path constraints. ADR-005 supersedes that advice.

### What Lyon keeps

Lyon stays in Flux for jobs where the triangle mesh is the product. Examples: extruding a path into a 3D solid, feeding a custom vertex-shader effect that displaces triangles, or building a retained mesh for a path that never changes and sits under a changing 3D transform. A mesh cache survives a translation, and a strip list does not ([cpu-gpu-split.md](../notes/per-library/rust/vello/cpu-gpu-split.md)). For those cases the mesh is the right artifact, and Lyon is the right tool.

### The Routing Table: Which Shape Goes to Which Lane

Flux's draw API stays the same for users. Internally, a router sends each shape to the cheapest lane that draws it correctly. The table shows the split, and the last column names who pays.

| Shape | Lane | Why | Who pays per frame |
|-------|------|-----|--------------------|
| Circle, ellipse, rect, line segment | Instanced analytic (Tier 1) | One unit quad per instance, distance function in the fragment shader | 16 to 28 bytes per instance |
| Rounded rect, arc, ring | Instanced analytic (Tier 2) | Same mechanism, a heavier fragment shader | 24 to 28 bytes per instance |
| Arbitrary path, fill or stroke | `PathRasterizer` (`vello_gpu`) | No cheap closed-form distance function; exact coverage wanted | CPU flatten, tile, strip; alpha upload |
| Text | `PathRasterizer` via `glifo`, path mode | Zoom never blurs; gradients and strokes keep working | Same as paths, per glyph |
| Mesh for extrusion or vertex effects | Lyon, retained | The triangle mesh is the product | CPU only when the path changes |

The router has one rule worth stating plainly: send a shape to the instanced lane only when it is parametric, and send everything else to the rasterizer. Do not send a path to Lyon because "it is a path". That habit is the stale advice this note supersedes.

---

## Integration Sketch: Where `vello_gpu` Sits in a Flux Frame

Picture one frame. A 3D node has already drawn into a texture. A path-layer node now receives a list of paths from upstream, records them into a `vello_gpu::Scene`, and renders into its own output texture. Downstream nodes read that texture like any other. Let's trace it.

1. **Upstream emits paths.** The port carries kurbo `BezPath` values with Flux paint and transform data. `BezPath` is the type `Scene::fill_path(&BezPath)` takes and the type `glifo`'s `DrawSink` takes, so no conversion layer is needed ([fill-path trace](../notes/per-library/rust/vello/code-traces/fill-path.md), [text-glifo.md](../notes/per-library/rust/vello/text-glifo.md)).
2. **The node records.** It resets its `Scene` (`vello_gpu/src/scene.rs:906`), sets paint and fill rule, and calls `fill_path` per path. Flatten, tile and strip generation run here, on the CPU, at call time.
3. **The node renders on the host encoder.** It calls `Renderer::render` with `TargetInit::Clear` into the node's own output texture. Because that texture is a root target, any format Flux chooses works. Vello's fixed `Rgba8Unorm` only applies to intermediates, which appear when the scene uses layers.
4. **The host submits once.** The frame graph submits the encoder. The node never submits.

Three constraints from [wgpu-integration.md](../notes/per-library/rust/vello/wgpu-integration.md) shape the node. First, a `Renderer` is bound to one target format through `RenderTargetConfig::format`, so each path-layer node fixes its output format when it builds its renderer. Second, plan one `render` per submit. Uploads go through `queue.write_*` and apply on the next submit, and the strip arena cursor resets each frame (`:424-428`, `:1081-1083`), so two renders recorded on one encoder likely clobber each other's staged data. The study inferred this and did not run it. Give each path-layer node its own `Renderer`, or serialize the submits. Third, with the `text` feature, a frame that rasterizes new glyphs may submit extra small command buffers inside `render` (`:359-387`, `:481`).

The trait below is the seam. Flux code talks to `PathRasterizer`. The first implementation wraps `vello_gpu`. A fallback implementation can wrap Lyon plus MSAA if the prototype fails. The signatures are indicative, not final.

```rust
/// Flux-owned. Nothing outside this module names a vello type.
pub trait PathRasterizer {
    /// Pure CPU recording; nothing touches wgpu. Fill rule and paint are explicit
    /// arguments so no hidden mutable state decides what a path looks like.
    fn record(&mut self, path: &kurbo::BezPath, style: &PathStyle, transform: Affine)
        -> Result<(), Unsupported>;

    /// Draw everything recorded since `reset` into `target` on the host's encoder.
    /// Never submits. The caller owns the encoder and the submit.
    fn render(&mut self, gpu: &GpuContext, encoder: &mut wgpu::CommandEncoder,
              target: &wgpu::TextureView, size: PixelSize) -> Result<(), RenderError>;

    fn reset(&mut self);
}
```

The `Result` on `record` is deliberate. Vello panics on mask layers (`scene.rs:686-688`), destructive blend modes via `set_blend_mode` (`scene.rs:786-790`) and oversized alpha buffers (`mod.rs:2405-2408`). Flux guards those inputs in its wrapper so a user-authored graph cannot abort the process. A Lyon-backed fallback fits the same trait, which is what keeps the choice reversible.

Everything else stays where it is. Tier 1 and Tier 2 primitives keep their instanced path and draw into the same frame without touching the trait. Lyon stays reachable for mesh-producing nodes. Because the port type is `BezPath`, SVG export, PDF export and a plotter writer read the identical path data that the rasterizer consumed, and no second path model exists to drift out of sync.

### One Frame, End to End

The diagram shows where each lane's work lands. CPU work sits above the dashed line, and the host's encoder receives everything below it.

```
 upstream nodes                CPU (record)                       host encoder (GPU)
┌──────────────┐          ┌────────────────────┐
│ circles/rects│─────────▶│ instance buffers   │─────────────────▶ instanced draws  ─┐
└──────────────┘          └────────────────────┘                                      │
┌──────────────┐          ┌────────────────────┐   ┌─────────────────────────────┐   │
│ BezPath port │─────────▶│ PathRasterizer     │──▶│ Renderer::render            │   ├─▶ one texture
│ text (glifo) │          │  flatten, tile,    │   │  alpha upload, strip passes │   │   per node
└──────────────┘          │  strip (vello_gpu) │   └─────────────────────────────┘  ─┘
┌──────────────┐          ┌────────────────────┐
│ extrude/mesh │─────────▶│ Lyon (retained)    │─────────────────▶ indexed draws (3D)
└──────────────┘          └────────────────────┘
 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
 host submits the encoder once; downstream nodes sample the textures
```

Read the middle row as the new piece. The top row is what Flux has today, and the bottom row is what Flux keeps for 3D.

### The Path Port Type Feeds Export Too

Choosing kurbo's `BezPath` as the port type pays off beyond rendering. The rasterizer consumes `BezPath`. An SVG writer reads the same segments, a PDF writer reads the same segments, and a plotter writer flattens them to polylines at its own tolerance. DrawBot made PDF its canonical intermediate for this reason ([rasterization-strategies.md](../notes/themes/vector-graphics/rasterization-strategies.md), Strategy 1), and Flux gets the same single-source property without handing rendering to a platform.

Two cautions keep the port type honest. First, the rasterizer's flatten tolerance (0.25 px) is a screen-space number, so export code must flatten with its own tolerance and never reuse the rasterizer's lines. Second, a NaN in a path makes `vello_gpu` drop the whole path with a warning (`vello_common/src/flatten.rs:212-216`), so Flux should validate at the port boundary and report a `PathError` upstream of the rasterizer.

---

## Risks and Mitigations

| Risk | Why it matters | Mitigation |
|------|---------------|------------|
| **Per-frame CPU cost on mobile** | Flatten, tile, sort and strip run for every path recorded each frame; nothing caches across frames unless the caller keeps the `Scene` ([cpu-gpu-split.md](../notes/per-library/rust/vello/cpu-gpu-split.md)). Thousands of moving paths are where tessellation caches "start to look attractive". | Prototype 1 below. Retain the `Scene` for static layers. Route parametric shapes to the instanced lane. Add a `(path id, transform)` strip cache in Flux if the measurement demands it. |
| **vello 0.x API churn** | The family is at 0.3.0, and upstream calls the GPU renderer something that "is intended to become the primary renderer ... as it matures" ([architecture.md](../notes/per-library/rust/vello/architecture.md)). `glifo` atlas mode is "highly experimental" (`glifo/src/glyph.rs:353-354`). | The `PathRasterizer` trait confines vello types to one module. Pin the exact version. Use only path-mode text. Re-read the pin in [SUBMODULE-PINS.md](../notes/SUBMODULE-PINS.md) before each upgrade. |
| **No mask layers** | `push_layer` panics when given a mask (`scene.rs:686-688`). | Return `Unsupported` from the wrapper. Use clip paths and clip layers. Render a mask as its own texture and multiply in a Flux node, which the texture-first graph does naturally. |
| **`Rgba8Unorm` intermediates** | Layers composite in 8 bits even on an HDR root ([wgpu-integration.md](../notes/per-library/rust/vello/wgpu-integration.md)). | Avoid layers for HDR content. A flat path scene needs no intermediates. Let Flux nodes do HDR compositing between texture nodes. |
| **Encoder and submit semantics with text** | With the `text` feature and pending glyph-atlas pages, `render` can submit inside itself (`mod.rs:359-387`, `:481`), which surprises a frame graph that schedules submits deliberately. | Check the submit order in prototype 3. Pre-warm glyphs. Keep one renderer per path-layer node so an early submit cannot reorder another node's work. |
| **Gamma on sRGB targets** | The study did not verify how premultiplied output maps onto sRGB-encoded formats. | Test on an sRGB surface in prototype 3 before building anything on top. |
| **Stale "use Lyon" advice** | Three theme notes still recommend Lyon, and a future reader may follow them. | ADR-005 supersedes them by name. The session annotates the three notes. |

---

## What to Prototype First

Run three experiments before building the path port type. Each has a number that passes or fails, and none needs more than a few hundred lines.

1. **Dynamic path throughput.** Record 2,000 animated paths of about 50 segments each, rebuilding the `Scene` every frame, and render them into a 1080p texture. **Pass:** CPU record plus render stays under 8 ms per frame at 60 fps on a mid-range Android phone, and under 4 ms on a desktop. Measure CPU time and GPU time separately, and measure on a WebGL2 browser build too.
2. **Text at zoom.** Draw about 500 glyphs in path mode, animate a continuous zoom from 0.5x to 40x, and watch for blur and frame spikes. **Pass:** no visible blur at any zoom and the same 8 ms budget on the phone. Compare against a Lyon plus MSAA baseline of the same text to measure what exact edges cost.
3. **Graph integration and colour.** Render one path-layer texture, composite it in Flux's graph under a 3D node, onto an sRGB surface. **Pass:** premultiplied edges show no dark fringe, the output matches a CPU reference within one 8-bit step, and no unexpected submit appears in a captured frame.

Record the results in one table per device, so the decision can be audited later.

| Experiment | Metric | Pass line | Desktop | Mid-range Android | WebGL2 browser |
|------------|--------|-----------|---------|-------------------|----------------|
| 1 Dynamic paths | CPU record + render, ms | under 8 (phone), under 4 (desktop) | to measure | to measure | to measure |
| 1 Dynamic paths | Alpha bytes uploaded per frame | under the device's texture ceiling | to measure | to measure | to measure |
| 2 Text at zoom | Visible blur, 0.5x to 40x | none | to measure | to measure | to measure |
| 3 Graph integration | Max channel error vs CPU reference | within one 8-bit step | to measure | to measure | to measure |

If experiment 1 fails, try the cheap fixes first: retained scenes for static layers, the instanced lane for parametric shapes, and a strip cache. If the budget still fails with fixes, the data says the CPU geometry bet is wrong for Flux's target phones, and the fallback is **A + E**: Lyon meshes with MSAA behind the same trait, accepting weaker edges. If the API churns faster than a pin can absorb, the fallback is **C'**, built to the same trait.

---

## What Would Change the Recommendation

- **CPU cost measured too high on mobile** (experiment 1) after caching and routing fixes. Switch to A + E behind the trait, or add a feature-gated compute path for desktop only, which the [fill-path trace](../notes/per-library/rust/vello/code-traces/fill-path.md) already suggests.
- **vello's API instability** outruns a pinned version, or upstream abandons `vello_gpu`. Build C' against the trait. The strip representation is documented well enough to rebuild ([sparse-strips.md](../notes/per-library/rust/vello/sparse-strips.md)), and the cost is the SIMD pipeline and a scheduler.
- **Flux requires compute on every supported target.** Option D becomes viable, and its memory-sizing hazard needs a retry loop first.
- **Flux requires a stencil format everywhere for 3D anyway.** Option B loses its worst objection, though the fill-rule question still needs a runtime test.
- **The license changes upstream.** The vello workspace declares `Apache-2.0 OR MIT` (`libraries/rust/vello/Cargo.toml:52`), and `vello_gpu` inherits it with `license.workspace = true` (`vello_gpu/Cargo.toml:9`). That fits an open framework. Re-read both lines when the pin moves.
- **The alpha upload ceiling bites.** One texture holds all alphas, with a ceiling near 16.7 million edge tiles at a 4096 texture dimension and less on small devices (`mod.rs:549-551`). If real scenes reach it, Flux needs the chunked upload the upstream TODO describes.

---

## What to Build, in Order

If the prototypes pass, the build order follows the risk, not the feature list.

1. **The trait and a flat path node.** Define `PathRasterizer`, wrap `vello_gpu`, and ship one node that fills `BezPath` values into a texture. Skip layers, filters and masks. [cpu-gpu-split.md](../notes/per-library/rust/vello/cpu-gpu-split.md) advises exactly this: a flat-path Flux needs one root pass, and the rounds scheduler matters only once layers exist.
2. **The router.** Send parametric shapes to the instanced lane and everything else to the node, so existing sketches keep their speed.
3. **Strokes and clips.** Both already ride the same fill path, so they cost little to add.
4. **Text in path mode.** Add `glifo` after the flat node is stable, and expose the mode as a per-run choice with a visible fallback report, as [text-glifo.md](../notes/per-library/rust/vello/text-glifo.md) recommends.
5. **Export.** Write the SVG and PDF writers against `BezPath`, which proves the single-source claim before anyone depends on it.
6. **Retention and caches.** Add the `(path id, transform)` strip cache only if the measurements ask for it.

---

## Gaps in This Study

- **No measurements.** Every cost claim about sparse strips comes from reading the pipeline. The rasterization theme's open question, how many animated non-parametric paths a typical sketch draws, has no data behind it.
- **The license.** Verified from source: `Apache-2.0 OR MIT` at `libraries/rust/vello/Cargo.toml:52`, inherited by `vello_gpu/Cargo.toml:9`. The vello notes do not mention it. Dependencies of vello_gpu were not audited.
- **WebGL2 shaders.** The GLSL under `vello_gpu/src/render/webgl/` was not opened, and the WebGL2 claim rests on the example's limits and the existence of the backend.
- **Gamma on sRGB targets.** Flagged by [wgpu-integration.md](../notes/per-library/rust/vello/wgpu-integration.md) and unverified.
- **One render per submit.** An inference from staging comments, never run.
- **openrndr text and fill rule.** Text under stencil-and-fringe was not studied, and the pass-3 fill rule is untested.
- **Boolean path operations.** Union and difference of paths are outside this decision. The vector-graphics README points at kartifex, `geo` and `i_overlay`, and a kurbo-based port type may want its own answer.

## Sources

- [Rasterization Strategies](../notes/themes/vector-graphics/rasterization-strategies.md), [Tessellation](../notes/themes/vector-graphics/tessellation.md), [Vector Graphics README](../notes/themes/vector-graphics/README.md), [Primitive Strategies](../notes/themes/rendering/primitive-strategies.md)
- Vello notes: [sparse strips](../notes/per-library/rust/vello/sparse-strips.md), [wgpu integration](../notes/per-library/rust/vello/wgpu-integration.md), [CPU/GPU split](../notes/per-library/rust/vello/cpu-gpu-split.md), [text (glifo)](../notes/per-library/rust/vello/text-glifo.md), [paint and layers](../notes/per-library/rust/vello/paint-and-layers.md), [fill-path trace](../notes/per-library/rust/vello/code-traces/fill-path.md), [architecture](../notes/per-library/rust/vello/architecture.md)
- [openrndr rendering pipeline](../notes/per-framework/openrndr/rendering-pipeline.md), [Processing rendering pipeline](../notes/per-framework/processing/rendering-pipeline.md)
- [Operator families vs Flux](../notes/themes/node-graphs/operator-families-vs-flux.md) (lines 186-188)
- [ADR-002, ADR-003 and ADR-005](./architecture-decisions.md), [rust-specific.md](./rust-specific.md) (lines 40-62, the `Renderer2D`/`RendererGL` sketch)
- Source cited through those notes (submodules, read-only, at commit `65338c25` for vello): `libraries/rust/vello/vello_gpu/src/render/wgpu/mod.rs`, `vello_gpu/src/scene.rs`, `vello_gpu/src/draw.rs`, `vello_common/src/strip.rs`, `vello_common/src/flatten.rs`, `vello_gpu/examples/`, `libraries/rust/vello/ARCHITECTURE.md`, `libraries/rust/vello/research/vello_encoding/src/config.rs`; `frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/Drawer.kt`, `frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/internal/ExpansionDrawer.kt`; `frameworks/processing/core/src/processing/opengl/PGL.java`
- Commits as of the pins in [SUBMODULE-PINS.md](../notes/SUBMODULE-PINS.md)
