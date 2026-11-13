# Vello GPU: Record, Plan, Execute

> A GPU renderer that insists on seeing the whole frame before it touches the GPU, and what that buys.

## Key Insight

> **The core idea:** `vello_gpu` splits a frame into three stages with hard boundaries. It *records* draws and layers into a plain data structure (doing the expensive geometry work immediately), *plans* the whole frame into rounds of render passes as pure data, and only then *executes* that plan through a five-method `Backend` trait. The GPU receives a few flat buffers of 24-byte instances and 16-byte alpha texels, never a mesh.

This document explains why the stages exist, how each one works, and what actually crosses the CPU-to-GPU bus every frame. It builds on the [fill-path code trace](code-traces/fill-path.md), which follows one solid-color path from `Scene::fill_path` to pixels. That trace already excerpts recording (step 6), scheduling (step 8), draw encoding (step 9) and execution (steps 10-11), so this note links to those steps and spends its words on the *why* and on the multi-layer case the trace skips.

All paths are relative to the vello submodule root (`libraries/rust/vello/`) at commit `65338c25`.

## The Problem: Layers Are Offscreen Textures, and Offscreen Textures Are Expensive

If you have written wgpu render passes, you know the cost model. Beginning a pass is not free, switching render targets forces a flush of tile memory on mobile GPUs, and every extra texture is memory you have to allocate, bind and eventually clear. A flat scene of filled paths is the happy case: one pass, one pipeline, one big instanced draw.

Vector graphics APIs do not stay flat. A PostScript-style imaging model has *layers*: push a group, draw into it, pop it with an opacity, a clip, a blend mode or a filter applied to the group as a whole. You cannot fake a group opacity by lowering the alpha of each child, because overlapping children would show through each other. The group has to be rendered somewhere separate and composited afterward. A blur is worse, because it samples neighbouring pixels and so needs the finished group before it can start.

The naive renderer answers this literally. Each `push_layer` allocates a texture, each draw becomes its own pass, and each `pop_layer` runs a composite pass back into the parent. For a scene with a few hundred nested groups, that drowns in state changes and allocations. The alternative is to wait. A renderer that has seen the *entire* frame can ask better questions: how big is each layer really, which layers never overlap in time and can share a texture, which draws can go in the same pass? That is the problem the record, plan and execute split solves.

## The Mental Model: A Stage Manager Who Reads the Whole Script

Think of the way a theatre runs a show. The actors (your draw calls) do not walk onto stage as the playwright thinks of them. A stage manager reads the whole script first, decides that Act 2's forest set can reuse the Act 1 castle's turntable once the castle is struck, and groups scene changes so the crew moves furniture once instead of four times. Only then does the show run.

`vello_gpu` works the same way. Recording is the script. Planning is the stage manager's annotated prompt book: which set (texture page) each scene uses, in which order, and when each set is struck (cleared). Execution is the performance, and the crew (the `Backend`) follows the book without any improvising.

```
 user calls            CPU, at call time          CPU, at render time        GPU
┌─────────────┐      ┌───────────────────┐      ┌────────────────────┐    ┌──────────────┐
│ fill_path   │─────▶│ RECORD            │─────▶│ PLAN               │───▶│ EXECUTE      │
│ push_layer  │      │ strips + alphas   │      │ Schedule { rounds, │    │ Backend:     │
│ pop_layer   │      │ Nodes, Layers     │      │  intermediate tex }│    │ 5 pass kinds │
└─────────────┘      │ (geometry done)   │      │ + GpuStrip buffers │    └──────────────┘
                     └───────────────────┘      └────────────────────┘
                       data, no GPU handles       data, no GPU handles      wgpu / WebGL
```

The two middle boxes hold no GPU handles at all. That is what makes the plan testable, a point we return to in the execute section.

## Stage 1: Record, Geometry Now, Plan Later

The module doc at the top of `vello_common/src/record.rs` states the design reason in one sentence: `vello_gpu` "needs to render *every* layer separately", so its scheduler "needs the complete layer hierarchy and bounds before it can allocate intermediate textures and order draws, filters, and composition operations."

**File:** `vello_common/src/record.rs:4-33`

The same doc explains why `vello_cpu` records too, even though it can inline most layers into the parent command stream: filter layers still have to render separately, and filter layers can be larger than the viewport (a large blur needs shapes that normal culling would discard, :27-29). One recorder serves both renderers, and each does "their own thing" with the result.

The recorded structure is small. Four types carry it:

- **`Drawable`** (:46) is the trait a draw command implements. It reports a tile-aligned bounding box and an optional blend mode, which is all the recorder needs.
- **`Node { draws, layer }`** (:57) is a contiguous batch of draws, indexing into one flat `Vec`, followed by an optional layer composition.
- **`RecordedLayer`** (:73) holds a layer's `LayerProps` (blend mode, opacity, mask, clip), its child `Node`s, its nesting `depth` and its tile-aligned `bbox`.
- **`RecordedLayerKind`** (:128) is `Regular` or `Filter { filter_data, placement }`. A filter layer's placement can only be decided once its contents are known, so `pop_layer` fills it in.

`LayerProps` (:104) carries `clip_path: Option<LayerClip>`, and `LayerClip` (:117) holds a *strip range*, not a path. A clip is already rasterized into strips by the time the layer exists. `Scene::push_layer` does that work at call time (`vello_gpu/src/scene.rs:705-727`).

**File:** `vello_common/src/record.rs:172` (`CommandRecorder`)

You might wonder how a flat list of draws becomes a tree. `push_layer` (:262) records the new layer's metadata and attaches it to the *current* node as that node's trailing `layer` (:384-396). `pop_layer` (:309) closes the layer: it clamps the bounding box to the clip's bounds, updates `largest_layer_size`, and unions the result into the parent's bbox. `push_draw` (:426) appends the draw and extends the current node's range if no layer has been attached yet:

```rust
match self.active_node_mut() {
    Some(node) if node.layer.is_none() && node.draws.end == draw_idx => {
        node.draws.end += 1;                       // :442-443  merge into the open batch
    }
    _ => self.push_node(Node { draws: draw_idx..draw_idx + 1, layer: None }),
}
```

This is the merge shown in [fill-path step 6](code-traces/fill-path.md#6-recording-commandrecorderpush_draw). A run of ten fills with no layer between them becomes one `Node`, and later one draw call.

The easy misreading is that "deferred" means "lazy". It does not. The strips are generated eagerly, at `fill_path` time, with the flatten, tile and strip work from steps 3-5 of the trace. Only the *plan* is deferred. Recording a draw stores an index range into scene-wide storage plus a paint, nothing more.

## Stage 2: Plan, a Pure-Data Schedule

The scheduler consumes the recording and a fixed intermediate texture page size, and produces a `Schedule`.

**File:** `vello_gpu/src/schedule/mod.rs:158`

```rust
pub(crate) struct Schedule {
    rounds: Rounds,                                   // work, in execution order
    intermediate_textures: IntermediateTextureRequirements,  // pages the backend must have
}
```

Here is how the schedule gets built. `Schedule::try_new` (:166) runs the `Scheduler`, then checks the result against a texture budget (`max_textures`) and returns an error instead of over-allocating (:200-203). The module doc (:4-119) lists three properties: it finds a valid schedule for any scene whose individual layers fit one page; it prefers fewer texture allocations even if that costs extra passes; and it batches opportunistically when resources are already allocated. The design chooses memory over pass count, which matters on phones.

### Bottom-up, with two texture groups

The doc's first principle is bottom-up scheduling: "The scheduler descends into a child layer before scheduling the part of its parent that composes it." (:28-29). A layer's depth decides its texture group: "even-depth layers use the even group and odd-depth layers use the odd group" (:29-30). `layer_texture_parity` (:565) implements it as `TextureParity::from_parity(depth + root_is_blend_target)`.

**File:** `vello_gpu/src/schedule/mod.rs:565`

Because a child's depth is always its parent's plus one, a parent only ever samples a child from the *opposite* group. The module doc's five-layer chain (:33-47) shows what this buys: `L4` renders into an odd page, `L3` into an even page and composes `L4`, then `L4`'s space is released and `L2` reuses it. A chain of any depth needs "at most two adjacent layer allocations live at once" (:46).

Think of two whiteboards. You draw the innermost diagram on board A, copy it onto board B as part of a bigger diagram, wipe A, and reuse A for the next level out. You never need a third board for a straight chain, however deep it goes.

### Lazy allocation, rounds, and the monotonic cursor

Two-board reuse only works if you do not grab boards early. So the scheduler allocates a layer's target lazily: "when the layer first has draws or a completed child to receive" (:52-53). In `schedule_layer` (:400), the child is scheduled first (:411), and only then does `ensure_layer_target` run (:415). Allocating on entry would let the outer layers squat on both pages before the inner ones could use them (:54-56). Branching trees can need more than two live allocations, but never more than the maximum layer depth (:74-77).

Intermediate textures are atlases, so independent layers can share a page. `Atlases` (`schedule/allocate.rs:24`) keeps a list of pages per parity, and `allocate_layer` (:51) is first-fit: it walks pages in index order and takes the first with room (:64-71). Filter layers request extra padding, `FILTER_ATLAS_PADDING` (:117-123), because some filters use bilinear sampling and need transparent borders.

Work then lands in *rounds*. The doc for `round.rs` (:4-25) defines a `Round` as "the largest unit of scheduled work that can execute with one fixed pair of layer texture pages: one page from the even texture group and one from the odd texture group." The struct (`round.rs:139`) holds exactly that:

**File:** `vello_gpu/src/schedule/round.rs:139`

```rust
pub(super) struct Round {
    pub(super) texture_binding: RoundBindings,        // which even page + which odd page
    layer_texture_passes: [LayerTexturePass; 2],      // per parity: draw, filter, blend
    root_draw: Draw,                                  // draws into the user's target
    layer_texture_clears: [Vec<RectU16>; 2],          // regions to wipe afterward
}
```

Every operation asks for the earliest round where its dependencies are satisfied *and* its page requirements fit the round's current bindings. `Rounds::bind_at_or_after` (`round.rs:91`) does the search: if the round's binding can merge with the requirement, fold in; otherwise try the next round (:115-122). `Rounds::build_draw` (`schedule/mod.rs:929`) calls it (:954) before it hands a `DrawBuilder` the target draw. The cursor never moves backwards. The doc admits this openly (:89-94) and gives a 30x30 page example (:96-99): a 5x5 region at round 0, then a 30x30 region that forces round 1, then another 5x5 that goes to round 1 even though it would have fit beside the first.

### Filters and blends

A filter layer follows the same bottom-up path, with an extra allocation of equal size from the opposite group; filter passes ping-pong between the two and the result ends in the layer's own region (:103-110). Default source-over needs no blend pass at all, because "the parent draw samples the completed child layer directly" (:112-113). Non-default blends must read both child and parent, so they wait for both, bind both pages, write into a shared scratch texture and copy back (:114-117). A non-default blend onto the root first redirects the root into an intermediate layer, because the user's target cannot be sampled (:117-119). That is the `root_is_blend_target` branch in `schedule_root` (:354-374).

## A Worked Example: Root Draw, Opacity Layer, Clip Layer

Let us trace a small scene. The user records:

1. Draw `A` at the root.
2. `push_opacity_layer(0.5)`, call this `L0`. Draw `B` inside it.
3. Inside `L0`, `push_clip_layer(path)`, call this `L1`. Draw `C` inside it.
4. Pop both layers.

Recording produces (`scene.rs:744` and `:754` both route through `push_layer`):

| Structure | Contents |
|-----------|----------|
| Root `nodes` | `Node { draws: [A], layer: L0 }` |
| `L0` (depth 1) | opacity 0.5, no clip; one node `Node { draws: [B], layer: L1 }` |
| `L1` (depth 2) | opacity 1.0, `clip_path: Some(strips)`; one node `Node { draws: [C], layer: None }` |

The scheduler (`schedule_root`, :344) then works as follows. Parity comes from `layer_texture_parity` (:565) with `root_is_blend_target` false, so `L0` (depth 1) is odd and `L1` (depth 2) is even.

1. **Root node.** `push_draws` (:570) sends `A` to the root draw in round 0 (:382). The root is already allocated, so drawing first is safe (:379-382).
2. **Descend into `L0`.** `schedule_child_layer` (:485) opens `L0`, and `schedule_layer` (:400) runs its node. The child comes first.
3. **Descend into `L1`.** Its only node has no child, so `ensure_layer_target` allocates an **even page 0** region sized to `L1`'s bbox, intersected with the clip bounds (:514-520). `C` goes into that page's draw in round 0.
4. **Back in `L0`.** `ensure_layer_target` now allocates **odd page 0**. `push_draws` appends `B`. Then `compose_layer` (:594) takes the default-blend shortcut to `compose_simple_layer` (:732), which calls `build_draw` with `L1` as the sampled layer. Because the clip is a set of strips, `push_layer_fill` (`draw.rs:270`) emits one instance per clip strip segment (:284-308), each sampling `L1`'s even page. A layer without a clip would emit a single rect blit instead (:309-331). `L1`'s region is cleared and released after round 0.
5. **Compose `L0` into the root.** `compose_simple_layer` again: a root draw samples the odd page at opacity 0.5. It lands in round 0 as well, after `A` in painter's order.

Result: **1 round**, one even page and one odd page, and `L0`'s region is cleared at the end of round 0. The repo's own test `nested_parity` (`vello_gpu/src/schedule/schedule_tests.rs:429-449`) asserts that shape for a two-deep chain: one round, `page_counts == [1, 1]`, the odd draw flagged `has_child_layer`, the root draw flagged `has_child_layer`, and one clear per parity. The test's two-deep shape matches the layer nesting here, which supports the round count and the even 0 / odd 0 pages. I did not run the test, and my scene adds a root draw `A` and a clip that the test lacks, so the clip's effect on the page size and the extra root draw remain my reading of the scheduler, not a captured result.

Adding a third level would flip things. `odd_child` (`schedule_tests.rs:461-469`) asserts that a depth-3 chain needs two rounds, with the innermost odd draw in round 0 and the even-layer composition in round 1. I read that as the page-binding rule at work (a round binds one even and one odd page, and the compositions need a different pairing), but I did not trace the allocator to confirm the exact cause.

## Stage 3: Encode, Segments Become 24-Byte Instances

Encoding happens inside planning. `build_draw` hands the target draw to a `DrawBuilder` (`vello_gpu/src/draw.rs:120`), and `push_draws` loops over the recorded draws, calling the builder for each. The code trace excerpts `push_path` in [step 9](code-traces/fill-path.md#9-draw-encoding-segments-to-gpustrip-instances), so here are only the points that matter for the split.

**File:** `vello_gpu/src/draw.rs:168`

`push_path` walks the stored strips with `visit_strip_fill_segments`. Each alpha segment and each solid segment becomes one `GpuStrip`. Planning decides the *geometry shift*: where this strip lands inside an intermediate page. The paint payload still uses the unshifted coordinates (:194-198), so a gradient samples in scene space no matter which page the layer got.

`push_rect` (:228) is the fast path for rectangles. It calls `split_rect` (`vello_gpu/src/rect.rs:50`) and may emit up to five parts: a main interior and antialiased edge strips (top, bottom, left, right, `draw.rs:244-250`). Small rects skip the split, because five instances cost more than one anti-aliased fragment shader (`rect.rs:70-77`, the threshold is `LARGE_RECT_SPLIT_THRESHOLD = 32`, :11).

`GpuStrip::from_fill_segment` (:397) and `from_rect` (:423) pack the same struct two ways: alpha and solid segments use `dense_width_or_rect_height` and `col_idx_or_rect_frac` as a width and an alpha column, while rects use them as a height and four packed 8-bit edge fractions, flagged by `RECT_STRIP_FLAG` (:394). Reusing fields keeps the instance at 24 bytes.

Opaque solid spans have a special route. `push_opaque` (:159) sends them to an `OpaqueDraw` when a depth buffer is enabled. After scheduling finishes, `Scheduler::build` calls `OpaqueDraw::reverse` (`draw.rs:85`, call site `schedule/mod.rs:325`) so the opaque instances draw front-to-back and early-Z rejects the covered fragments behind them.

Two structs fix the wire format. Here is `GpuStrip`, which the vertex shader reads one per instance.

**File:** `vello_gpu/src/render/common.rs:284`

```rust
#[repr(C)] pub struct GpuStrip {
    pub x: u16, pub y: u16,                          // 4 B  top-left in target pixels
    pub width: u16, pub dense_width_or_rect_height: u16, // 4 B
    pub col_idx_or_rect_frac: u32,                   // 4 B  alpha column, or rect edge fractions
    pub payload: u32,                                // 4 B  premul RGBA8, or paint sample position
    pub paint_and_rect_flag: u32,                    // 4 B  paint kind + RECT_STRIP_FLAG
    pub depth_index: u32,                            // 4 B  painter's order, for early-Z
}                                                    // = 24 B
```

`Config` (:240) is the uniform: width and height, `strip_height`, two log2 texture widths (precomputed on the CPU "since downlevel targets do not support `firstTrailingBit`", :249-252), strip offsets and a `negate_ndc` flag. That is eight 4-byte fields, 32 bytes. `GpuEncodedPaint` (:307) is the enum of non-solid paints (image, gradients, blurred rounded rect). Each variant must occupy whole 16-byte texels, which the `texels::<T>()` assertion enforces (:325-332), so paints can live in an `Rgba32Uint` texture.

## Stage 4: Execute, a Five-Method Trait

With the plan complete, execution becomes a loop with no decisions in it. The `Backend` trait (`vello_gpu/src/schedule/execute.rs:19`) has five methods: `opaque_draw_pass`, `draw_pass`, `clear_pass`, `blend_pass`, `filter_pass`.

**File:** `vello_gpu/src/schedule/execute.rs:84` (`Schedule::execute`), `:111` (`Rounds::execute`)

`Schedule::execute` runs the opaque depth pass first, at most once (:91-98). The trait's own doc promises "it's called before any of the other ones and only once" (:23-24). `Rounds::execute` then loops over rounds. The code trace quotes the loop at [step 10](code-traces/fill-path.md#10-execution-order-scheduleexecute), so the ordering rules are what count here:

- Per round, **even before odd**, and within each parity: draw, then filter, then blend (:131-150).
- Then the **root draw** (:153).
- Then the **clears** of every region released this round (:158).

Even goes first because "only odd-texture draws sample the even texture (never the reverse within a round)" (:127-129), so the even pixels are final before the odd draw reads them.

The trait boundary pays off in two ways. First, the plan is testable without a GPU. The test module in `execute.rs` defines a `Recorder` backend (:222-282) that pushes a `Call` enum into a `Vec`, and asserts the exact sequence of passes. `round_order` (:342-372) shows the real shape for a scene with a filtered, multiply-blended layer: round 1 runs `Opaque, EvenDraw, EvenFilter, OddDraw, OddFilter, OddBlend, RootDraw, EvenClear, OddClear`, and round 2 runs `EvenBlend, OddDraw, RootDraw, EvenClear, OddClear`. Second, the same plan drives two real backends. `impl Backend for RendererContext` (`render/wgpu/mod.rs:3311`) opens wgpu passes, and `impl Backend for WebGlRendererContext` (`render/webgl/mod.rs:3363`) does the equivalent on WebGL. All scheduling bugs get fixed once.

## What Crosses the Bus Every Frame

Recording and planning stay on the CPU. Here is the complete list of what `Programs::prepare` and the pass loop send across.

**File:** `vello_gpu/src/render/wgpu/mod.rs:2321` (`prepare`)

| Resource | Format and size | Uploaded when | Source |
|----------|-----------------|---------------|--------|
| Alphas | `Rgba32Uint` texture, 16 B per texel (one texel = one 4x4 tile) | Every frame, whole buffer in one write | `create_alphas_texture` :2085, `upload_alpha_texture` :2577; TODO :549-551 |
| Encoded paints | `Rgba32Uint` texture, whole 16 B texels per paint | Every frame, if any non-solid paint exists | `upload_encoded_paints_texture` :2622 |
| Filter data | `Rgba32Uint` texture | Every frame, if any filter exists | `upload_filter_texture` :2667 |
| Gradient LUTs | `RGBA8` texture | Only when the cache changed (`has_changed`, :2342) | `upload_gradient_texture` :2702 |
| Strips | 24 B `GpuStrip` per segment, in a vertex-buffer arena | Per pass, via `upload_strip_pair` :2745 | `StripBufferArena` :1057-1097 |
| `Config` | 32 B uniform | Only when the render size changes (:2510) | `maybe_update_config_buffer` :2504 |

A few details change how you read that table. The alphas path pads the last row with zeros, writes once, then truncates the CPU vector back (:2590-2618). The TODO at :549-551 is explicit about the cost: the entire alpha buffer goes up as one chunk, and a future "bounded alpha buffer" would break draws when it fills. `StripBufferArena::begin_frame` grows the arena to the frame's strip bytes (:1081-1090), and `alloc` hands out 4-byte-aligned slices (:1092-1096). `upload_strip_pair` writes opaque instances first, then alpha ones, through `write_buffer_with`, and carries its own TODO about a staging belt (:2761).

### Estimating the bytes

Edge tiles cost 16 B each (the alpha bytes of a 4x4 tile). Each strip segment costs 24 B. Paints cost 16 B times their texel count, and solid colors cost nothing extra, because the color rides in `payload`. For a frame with N edge tiles, M strip segments and P non-solid paints of `t` texels each:

```
bytes ≈ 16·N  +  24·M  +  16·t·P   (+ filter data, + gradient LUTs when changed)
```

Take a rough scene of 1,000 circles of radius 20 px, solid color. A circle's perimeter is about 126 px, which crosses roughly 40 to 60 tiles of 4x4, so N is about 50 per circle. The interior spans between edges add maybe 20 more segments, so M is about 70 per circle. That is `16·50 + 24·70` = 2,480 B per circle, or about 2.5 MB for the scene. These numbers are my back-of-envelope estimates, not measurements.

A tessellated mesh of the same circle at 0.25 px tolerance would need on the order of 30 to 60 vertices. At a typical 20 B per vertex (position, color) plus indices, that is perhaps 1 to 2 KB. For small shapes the two approaches move comparable bytes. The difference shows up elsewhere:

- Mesh bytes grow with the *perimeter in vertices* for each tessellation tolerance. Strip bytes grow with perimeter in *tiles*, and a huge shape with a vast interior adds only a few solid spans, since interior spans carry no alpha bytes.
- Mesh quality depends on the tessellation tolerance at upload time, with anti-aliasing added by extra geometry or MSAA. Strip alpha is exact analytic coverage computed on the CPU.
- Both approaches resend the data every frame if the content changes. Neither approach uploads *less* when only a transform changes, unless the caller caches. A mesh cache survives a translation. A strip cache would not, as we discuss below.

## Where the CPU Time Goes, and Why the Design Accepts It

The expensive per-path work is flatten, tile, sort and strip generation. It runs at record time, per path, with SIMD dispatch chosen at runtime through `fearless_simd` (`vello_common/Cargo.toml:22` pulls the dependency; `scene.rs:17` imports `Level`). The code trace walks these steps at [steps 3-5](code-traces/fill-path.md#3-strip-generation-flatten-then-tile-sort-render).

I found no cross-frame geometry cache inside the renderer. `Renderer::render` takes `&Scene`, and the strips live in the `Scene`'s `StripStorage`. So the cost model depends on who owns the `Scene`:

- **Caller rebuilds the scene each frame.** `Scene::reset` (`scene.rs:906`) clears the strip storage and the recorder, and every path pays flatten, tile and strip again. This is the immediate-mode pattern most creative coding sketches use.
- **Caller retains the scene.** If nothing changed, `render` skips all geometry work and pays only for scheduling, encoding and upload. Planning, `GpuStrip` encoding and uploads do repeat on every `render`.

The design accepts the per-frame geometry cost for three reasons. First, it removes the GPU compute stage, which keeps WebGL2 and older mobile GPUs reachable (see the [README](README.md)). Second, the work is data-parallel SIMD over flat arrays, which CPUs do well. Third, dynamic paths are the common case in a 2D UI or sketch, where a mesh cache would invalidate constantly anyway.

For mobile, the trade is real. CPU geometry spends battery and a core's time every frame, but saves GPU memory, because there are no scratch buffers and no compute pass, and the arena-and-texture upload model fits tile-based GPUs. For a scene with thousands of *static* paths, the retained `Scene` is the right model, and it re-pays only the schedule. A scene where thousands of paths move every frame pays the full CPU cost for each, which is where tessellation caches or a GPU flattening path would start to look attractive.

## Gotchas Worth Knowing

- **Deferred is not lazy.** Strips, including clip strips (`scene.rs:705-727`), are generated at call time. Only the plan waits.
- **Layer recursion is not flattened yet.** The scheduler carries a TODO about stack overflow for deep layers (`schedule/mod.rs:410`).
- **Masks are unimplemented** and panic at `push_layer` (`scene.rs:686-688`).
- **Rounds never backtrack.** A schedule can use more passes than a global optimum would (`schedule/mod.rs:89-94`). The goal is bounded memory, not minimum passes.
- **Layer data uploads per round.** A TODO in `Rounds::execute` (`execute.rs:121-123`) says layer data uploads when each round executes and might move to a single upfront upload.
- **A deadlock guard exists.** `bind_at_or_after` panics after 40,000 rounds (`round.rs:99-107`), a sanity check rather than a design limit.

## Implications for Flux

### Adopt
- **A pure-data plan stage behind a small `Backend` trait.** Five methods and a `Recorder` test backend give you deterministic tests of pass order, page bindings and clears with no GPU, and one plan can serve wgpu and any future target.
- **Record into flat storage with index ranges.** `Node { draws: Range }` plus append-only strip storage keeps recording allocation-light and makes batching a range extension.
- **A fixed, tiny instance format.** A 24-byte `GpuStrip`, reused field-by-field for paths and rects, plus a 32-byte uniform, makes the per-frame upload auditable in a single table.

### Modify
- **Add cross-frame strip caching keyed by path identity plus transform.** Vello leaves this to the caller. Flux can cache `(path id, transform)` to strips and only regenerate on change. Note the limit: a translation changes the tile grid alignment, so a pure translate by a multiple of the tile size could reuse strips while arbitrary translation cannot.
- **Bound the alpha upload.** The TODO at `render/wgpu/mod.rs:549-551` points at the same fix the fill-path trace recommended: a bounded alpha store with draw breaks, especially for WebGL2 and small `max_texture_dimension_2d`.
- **Return errors, not panics, at the plan boundary.** `try_new` already returns `Result` for texture budget overruns (`schedule/mod.rs:200-203`). Extend that approach to the `unimplemented!` and `panic!` sites.

### Avoid
- **A rounds scheduler until layers exist.** The even/odd parity, atlas allocation and monotonic cursor all serve layers, filters and blends. A flat-path-only Flux v1 needs one root pass. Build the `Backend` trait and the record/encode split first, and treat the scheduler as the piece you add when the first `push_layer` lands.
- **Filters in the first cut.** Filters need neighbouring pixels and extra-sized targets (`record.rs:27-29`), and the scheduler spends a whole section of its doc on them (`schedule/mod.rs:101-110`). Defer filters, and the scheduler stays small.

## Sources

- `vello_common/src/record.rs`: recorder, module doc (:4-33), `Node` (:57), `RecordedLayer` (:73), `LayerProps` (:104), `LayerClip` (:117), `CommandRecorder` (:172), `push_layer` (:262), `pop_layer` (:309), `push_draw` (:426)
- `vello_gpu/src/schedule/mod.rs`: module doc (:4-119), `Schedule` (:158), `try_new` (:166), `schedule_root` (:344), `schedule_layer` (:400), `layer_texture_parity` (:565), `push_draws` (:570), `compose_layer` (:594), `compose_simple_layer` (:732), `Rounds::build_draw` (:929)
- `vello_gpu/src/schedule/round.rs`: module doc (:4-25), `bind_at_or_after` (:91), `Round` (:139)
- `vello_gpu/src/schedule/allocate.rs`: `Atlases` (:24), `allocate_layer` (:51), `FILTER_ATLAS_PADDING` use (:117-123)
- `vello_gpu/src/schedule/execute.rs`: `Backend` (:19), `Schedule::execute` (:84), `Rounds::execute` (:111), test `Recorder` (:222), `round_order` (:342)
- `vello_gpu/src/schedule/schedule_tests.rs`: `nested_parity` (:429), `odd_child` (:461)
- `vello_gpu/src/draw.rs`: `OpaqueDraw::reverse` (:85), `push_path` (:168), `push_rect` (:228), `push_layer_fill` (:270), `GpuStrip::from_fill_segment` (:397), `from_rect` (:423)
- `vello_gpu/src/rect.rs`: `split_rect` (:50)
- `vello_gpu/src/render/common.rs`: `Config` (:240), `GpuStrip` (:284), `GpuEncodedPaint` (:307)
- `vello_gpu/src/render/wgpu/mod.rs`: `StripBufferArena` (:1057), `create_alphas_texture` (:2085), `prepare` (:2321), `upload_alpha_texture` (:2577), `upload_encoded_paints_texture` (:2622), `upload_filter_texture` (:2667), `upload_gradient_texture` (:2702), `upload_strip_pair` (:2745), `impl Backend` (:3311)
- `vello_gpu/src/scene.rs`: `push_layer` (:678), `push_clip_layer` (:744), `push_opacity_layer` (:754), `reset` (:906)

Related notes: [fill-path code trace](code-traces/fill-path.md) (steps 6-11 excerpt the code this note summarizes), [paint and layers](paint-and-layers.md) (the paint and layer model this scheduler serves), [wgpu integration](wgpu-integration.md) (the wgpu side of the `Backend`), [Vello README](README.md), [tessellation theme](../../../themes/vector-graphics/tessellation.md).
