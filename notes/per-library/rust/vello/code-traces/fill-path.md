# Code Trace: Vello GPU `Scene::fill_path` to pixels

> Tracing `Scene::fill_path(&path)` from user code to pixels in `vello_gpu`.

## Overview

**Framework**: Vello (linebender/vello), `vello_gpu` 0.3.0 (sparse-strips renderer), commit 65338c25
**Operation**: Fill one `BezPath` with a solid color on a wgpu render target
**Files Touched**: 14 (`vello_gpu/src/scene.rs`, `vello_common/src/{strip_generator,flatten,tile,strip,record}.rs`, `vello_gpu/src/render/wgpu/mod.rs`, `vello_gpu/src/schedule/{mod,round,execute}.rs`, `vello_gpu/src/draw.rs`, `vello_gpu/src/render/common.rs`, `vello_gpu_shaders/shaders/render.wesl`). `vello_common/src/flatten_simd.rs` and `vello_gpu_shaders/shaders/helpers/{alpha,geometry}.wesl` are touched but not excerpted.

All paths are relative to the vello submodule root (`libraries/rust/vello/`). Line numbers refer to the commit recorded in `notes/SUBMODULE-PINS.md`.

The work is split into three phases:
- **Record (CPU, at call time):** steps 1-6. The path is flattened, tiled and turned into strips immediately, and the strips are stored.
- **Plan and encode (CPU, at render time):** steps 7-9. The scheduler turns the recording into per-pass instance buffers.
- **Execute (GPU):** steps 10-12. Instanced quads are drawn into render passes on the caller's encoder.

## User Code

```rust
use vello_gpu::{Scene, RenderSettings};
use vello_gpu::kurbo::{BezPath, Circle, Shape};
use vello_gpu::peniko::{Color, Fill};

let mut scene = Scene::new(800, 600);
scene.set_paint(Color::from_rgb8(30, 144, 255));   // solid paint
scene.set_fill_rule(Fill::NonZero);
let path: BezPath = Circle::new((400.0, 300.0), 120.0).to_path(0.1);
scene.fill_path(&path);                            // records only; nothing touches the GPU

// later, per frame (the caller owns encoder and submit):
renderer.render(&scene, &mut resources, &device, &queue, &mut encoder,
                &render_size, &target_view, None, &texture_bindings, target_init)?;
queue.submit([encoder.finish()]);
```

(Scene setter names are indicative; the exact signature of `Renderer::render` is quoted in step 7.)

## Call Stack

### 1. Entry point: `Scene::fill_path`
**File:** `vello_gpu/src/scene.rs:358`

```rust
pub fn fill_path(&mut self, path: &BezPath) {
    if !self.paint_has_area() {
        return;
    }

    self.with_optional_filter_or_blend_layer(|ctx| {
        let Some(paint) = ctx.encode_current_paint() else {
            return;
        };
        ctx.fill_path_with(
            path,
            ctx.effective_path_transform(),
            ctx.render_state.fill_rule,
            paint,
            ctx.aliasing_threshold,
        );
    });
}
```

**What happens**:
- **Early-out:** a singular paint transform returns immediately (`paint_has_area`, :353).
- **Paint encoding** (`encode_current_paint`, :328): solid colors become `Paint::Solid(PremulColor)` directly (:335). Gradients and images are appended to `self.encoded_paints` and referenced by index. Paint and path transforms are separate (`effective_paint_transform` :315 vs `effective_path_transform` :310).
- **Layer wrapping** (`with_optional_filter_or_blend_layer`, :879): a non-default blend mode or an active filter wraps the fill in `push_layer(None, blend, None, None, filter)` / `pop_layer()` (:887-891). The common case calls the closure directly (:893).
- **Hand-off:** `fill_path_with` (:378) calls `record_generated_path` with a closure that invokes `strip_generator.generate_filled_path(...)` (:386-395).

---

### 2. Generate and record: `record_generated_path`
**File:** `vello_gpu/src/scene.rs:528`

```rust
let strips = {
    let mut strip_storage = self.strip_storage.borrow_mut();
    let strip_start = strip_storage.strips.len();
    self.viewport_state
        .with_generator_and_clip(|strip_generator, clip_path| {
            generate(strip_generator, &mut strip_storage, clip_path);
        });
    strip_start..strip_storage.strips.len()
};
if strips.is_empty() { return; }
let draw = RecordedDraw::new_path(strips.clone(), paint);
let strip_storage = self.strip_storage.borrow();
self.recorder.push_draw(draw, &strip_storage.strips[strips]);   // :548
```

**What happens**:
- **Active clip:** the generator and the active clip come from `viewport_state`.
- **Append-only storage:** strip storage is created with `GenerationMode::Append` (:287), so every path appends to one scene-wide `strips` + `alphas` pair. The draw stores only an index range into it.
- **Draw record:** `RecordedDraw` (enum, :42) has `Path(RecordedPath)` (:44) and `Rect(RecordedRect)` (:46). `RecordedPath { strips: Range<usize>, paint: Paint }` is at :51. Fully clipped-out paths (empty range) record nothing.
- **Interior mutability:** `strip_storage` is a `RefCell<StripStorage>` (:287), which is why `Scene` can be read through `&Scene` at render time while the alphas are still borrowed mutably (step 7).

---

### 3. Strip generation: flatten, then tile, sort, render
**File:** `vello_common/src/strip_generator.rs:120`

```rust
pub fn generate_filled_path(&mut self, path: impl IntoIterator<Item = PathEl>, fill_rule: Fill,
    transform: Affine, aliasing_threshold: Option<u8>,
    strip_storage: &mut StripStorage, clip_path: Option<PathDataRef<'_>>) {
    let cull_bbox = clip_path.map(|c| c.bbox)
        .unwrap_or(RectU16::new(0, 0, self.width, self.height));
    flatten::fill(self.level, path, transform, &mut self.line_buf,
                  &mut self.flatten_ctx, cull_bbox);
    self.generate_with_clip(aliasing_threshold, strip_storage, fill_rule, clip_path);
}
```

`generate_with_clip` (:170, body :177-201):

```rust
self.tiles.make_tiles_analytic_aa(self.level, &self.line_buf, self.width, self.height);
self.tiles.sort_tiles();
...
render_with_clip(level, &mut self.temp_storage, strip_storage, clip_path,
    |strips, alphas| {
        strip::render(level, tiles, strips, alphas, fill_rule, aliasing_threshold, line_buf);
    });
```

**Flatten** (`vello_common/src/flatten.rs:178`, `fill`; `fill_impl` :193):

```rust
// The current tolerance is set to 0.25. ... hardcode the squared tolerance
pub(crate) const SQRT_TOL: f64 = 0.5;           // :17
pub(crate) const TOL: f64 = SQRT_TOL * SQRT_TOL; // :18  (= 0.25)
pub(crate) const TOL_2: f64 = TOL * TOL;         // :19
...
// A path that contains NaN is ill-defined, so ignore it.   // :211
if lb.is_nan {
    warn!("A path contains NaN, ignoring it.");
    line_buf.clear();
}                                                            // :212-216
```

**Clip intersection** (`strip_generator.rs:274`, `render_with_clip`):

```rust
if let Some(clip_path) = clip_path {
    temp_storage.clear();
    render_fn(&mut temp_storage.strips, &mut temp_storage.alphas);
    let path_data = PathDataRef { strips: &temp_storage.strips, alphas: &temp_storage.alphas,
                                  bbox: RectU16::new(0, 0, u16::MAX, u16::MAX) };
    intersect(level, clip_path, path_data, strip_storage);      // :287-297
} else {
    render_fn(&mut strip_storage.strips, &mut strip_storage.alphas);
}
```

**What happens**:
- **Flatten:** Béziers become `Line`s in `self.line_buf` at tolerance **0.25** (not 0.1). The actual flattening runs in `flatten_simd::flatten` (not excerpted), dispatched on a runtime SIMD `Level` via `fearless_simd`. Geometry outside `cull_bbox` is culled during flattening. A NaN anywhere discards the whole path with a `warn!`.
- **Tile, sort, render:** `make_tiles_analytic_aa` -> `sort_tiles` -> `strip::render` run in that order (:177-199).
- **Unclipped path:** strips are written straight into the scene storage.
- **Clipped path:** strips are rendered into `temp_storage` first, then `intersect()` combines them with the clip's strips and alphas into scene storage. Clips are therefore resolved on the CPU into strips, not into GPU stencil or mask state.
- **`GenerationMode`:** `Replace` and `ReplaceAfter(n)` exist for other users (:281-285). Only `Append` is used by `vello_gpu::Scene`.

---

### 4. Coarse binning into 4x4 tiles, then sort
**File:** `vello_common/src/tile.rs:514`

```rust
/// ... performs "coarse binning" to simply identify every tile a line segment traverses.
/// It encodes the line index and winding direction, delegating the precise calculation of pixel
/// coverage to `strip::render`.
pub fn make_tiles_analytic_aa(&mut self, level: Level, lines: &[Line],
                              width: u16, height: u16) -> bool {
    dispatch!(level, simd => self.make_tiles_analytic_aa_impl::<_>(simd, lines, width, height))
}
```

The tile layout (`Tile`, :220; constants :263-266):

```rust
pub struct Tile {            // #[repr(C)]
    pub packed_winding_line_idx: u32,
    // x: u16, y: u16 placed before/after depending on endianness (:227-258)
}
pub const WIDTH: u16 = 4;    // :263
pub const HEIGHT: u16 = 4;   // :266
// Bits 0-4: W|R|L|B|T flags (T=0b00001, B=0b00010, L=0b00100, R=0b01000, W=0b10000)  :239-244
// Bits 5-31: line_idx                                                                 :245
```

Sorting (`tile.rs:478`, `to_bits` :379):

```rust
pub fn sort_tiles(&mut self) {
    self.sorted = true;
    dispatch!(self.level, _ => self.tile_buf.sort_unstable());   // :481
}
// to_bits: ((y as u64) << 48) | ((x as u64) << 32) | packed_winding_line_idx as u64
```

**What happens**:
- **Binning:** `make_tiles_analytic_aa_impl` (:530) loops over every flattened line (up to `MAX_LINES_PER_PATH`, :558). It emits one `Tile` per 4x4 tile the line crosses, with the tile index, the line index and the edge-intersection and winding flags in one `u32`. The inner loop is SIMD-vectorized with `f32x4` constants (:553-556).
- **Sort key:** the field order of the `#[repr(C)]` struct is chosen so the in-memory value equals `(y, x, packed_winding_line_idx)` as a `u64`. `to_bits` therefore compiles to a no-op, and a plain `sort_unstable` sorts by row, then column, then line index.
- **Why line index is in the key:** the source comment (:380-383) says correctness only needs `(y, x)`. The line index is included only for memory locality in the next stage.
- **No coverage yet:** this stage only records which tiles each line touches, with no per-pixel math.

---

### 5. Analytic coverage and strip emission
**File:** `vello_common/src/strip.rs:331`

```rust
fn render_impl<S: Simd>(s: S, tiles: &Tiles, strip_buf: &mut Vec<Strip>,
    alpha_buf: &mut Vec<u8>, fill_rule: Fill, aliasing_threshold: Option<u8>, lines: &[Line]) {
    ...
    let should_fill = |winding: i32| match fill_rule {        // :362
        Fill::NonZero => winding != 0,
        Fill::EvenOdd => winding % 2 != 0,
    };
    ...
    let mut location_winding = [f32x4::splat(s, 0.0); Tile::WIDTH as usize];  // :404
```

Winding to alpha when moving to a new tile location (:451-500, NonZero branch shown):

```rust
for x in 0..Tile::WIDTH as usize {
    let area = location_winding[x];
    let coverage = area.abs();
    let mulled = coverage.mul_add(p2 /*255*/, p1 /*0.5*/);
    location_winding[x] = mulled.min(p2);                 // :459-466
}
...
let mut u8_vals = f32_to_u8(s.combine_f32x8(p1, p2));     // :490
...
alpha_buf.extend_from_slice(u8_vals.as_slice());          // :500  (16 bytes = one 4x4 tile)
```

Strip push (:508-515) and the `fill_gap` flag (:565-570):

```rust
if !prev_tile.same_loc(&tile) && !prev_tile.prev_loc(&tile) {
    strip_buf.push(strip);                                 // :515
    ...
    strip = Strip::new(tile.x * Tile::WIDTH, tile.y * Tile::HEIGHT,
        alpha_buf.len() as u32,
        should_fill(winding_delta) && !left_viewport);     // :565-570
}
```

Trapezoid area accumulation per tile, after the push (:576-623): `p0_y == p1_y` is skipped, then `sign = (p0_y - p1_y).signum()` (:582), and `winding_delta += sign as i32 * i32::from(tile.winding())` (:623).

The `Strip` data type (`strip.rs:17-28`):

```rust
pub struct Strip {
    pub x: u16,
    pub y: u16,
    /// bit 31: fill_gap; bits 0..=30: alpha_idx
    packed_alpha_idx_fill_gap: u32,
}
```

**What happens**:
- **Column accumulation:** tiles are consumed in sorted order. Each of the 4 columns of a tile is one `f32x4` (4 rows). The code relies on the 4-row tile height being exactly 128 bits (:402-403). A line's signed y-extent inside a pixel adds trapezoid area to that pixel and its right-hand neighbors, a signed-area scanline accumulation.
- **Alpha bytes:** when the location changes, accumulated area becomes alpha:
  - NonZero: `min(255, |area| * 255 + 0.5)`.
  - EvenOdd: a triangle-wave fold (:469-483).
  - If `aliasing_threshold` is set, alpha is thresholded to 0 or 255 (:492-498).
  - Exactly 16 bytes per tile are appended.
- **No width field:** a `Strip` has no width. A strip's pixel width is derived from the next strip's `alpha_idx` (`width_to`, :236-240: `(next.alpha_idx - self.alpha_idx) / 4`). The buffer therefore ends with a **sentinel strip** (`maybe_emit_sentinel_strip`, :348-353), and every consumer iterates `windows(2)`.
- **Fill-gap flag:** `fill_gap` on strip *N+1* means "the span between strip *N*'s right edge and my left edge is inside the shape", decided by `should_fill(winding_delta)`. Interior spans carry **no alpha bytes at all**; they are implied.
- **Consumer iterator** (`visit_strip_fill_segments`, :116): for each adjacent pair it calls `alpha_fill` with a `StripAlphaFillSegment { fill: StripFillSegment{tile_x0,tile_x1,tile_y}, alpha_idx }` (:32, :161-175). If `next_strip.fill_gap() && next_strip.y == strip.y` it calls `fill` with a plain `StripFillSegment` (:57, :178-193). Both are clipped to `tile_bounds`.

---

### 6. Recording: `CommandRecorder::push_draw`
**File:** `vello_common/src/record.rs:426`

```rust
pub fn push_draw(&mut self, draw: D, strips: &[Strip]) {
    if self.active_layer.is_none()
        && draw.blend_mode().is_some_and(|b| *b != BlendMode::default())
    {
        self.root_is_blend_target = true;
    }
    self.record_bbox(|| draw.bbox(strips));
    let draw_idx = self.draws.len() as u32;
    self.draws.push(draw);
    match self.active_node_mut() {
        Some(node) if node.layer.is_none() && node.draws.end == draw_idx => {
            node.draws.end += 1;                                   // :442-443
        }
        _ => { self.push_node(Node { draws: draw_idx..draw_idx + 1, layer: None }); }
    };
}
```

`Node` (:57): `{ draws: Range<u32>, layer: Option<u32> }`.

**What happens**:
- **Batching:** consecutive draws without an intervening layer merge into one `Node` (a contiguous run of draws). Layers add nodes with `layer: Some(idx)`, which forms the DAG the scheduler walks.
- **Bounds:** each push also grows tile-aligned bounding boxes via the `Drawable::bbox` trait (:46). These are used later to size intermediate textures.
- **Why record at all** (module doc :4-33): vello_gpu must render every layer separately. The scheduler therefore needs the full layer hierarchy and bounds up front to allocate intermediate textures and order passes. The same recorder is shared with vello_cpu.
- **Root blend target:** a non-default blend on a root-level draw sets `root_is_blend_target`, which later forces root rendering through an intermediate layer (step 8).

At this point the CPU has done geometry work and the GPU has seen nothing. `Scene` now holds `draws`, `nodes`, `strips`, `alphas` and `encoded_paints`.

---

### 7. Render entry: `Renderer::render` and `render_scene`
**File:** `vello_gpu/src/render/wgpu/mod.rs:346`

```rust
pub fn render(&mut self, scene: &Scene, resources: &mut Resources, device: &Device,
    queue: &Queue, encoder: &mut CommandEncoder, render_size: &RenderSize,
    view: &TextureView, depth_view: Option<&TextureView>,
    texture_bindings: &TextureBindings, target_init: TargetInit<'_>) -> Result<(), RenderError>
```

`render_scene` (:500), core lines:

```rust
self.prepare_gpu_encoded_paints(encoded_paints, image_cache, texture_bindings, view.texture())?; // :516
let required_texture_size = self.layers_config.required_intermediate_texture_size(&scene.recorder)?;
...
let schedule = Schedule::try_new(&mut self.schedule_storage, scene, root_output_target,
    depth_view.is_some(), paint_resolver, texture_size, current_allocations,
    self.layers_config.max_textures)?;                                   // :537
self.programs.prepare_intermediate_textures(device, &schedule);
self.programs.prepare(device, queue, &mut self.gradient_cache, &self.encoded_paints,
    &mut scene.strip_storage.borrow_mut().alphas, render_size, &self.paint_idxs,
    &self.schedule_storage.filter_context);                              // :552
self.programs.strips_arena.begin_frame(device, (strip_count * size_of::<GpuStrip>()) as u64);
...
crate::schedule::execute(&mut ctx, &mut self.schedule_storage, schedule, root_output_target)  // :590
```

**What happens**:
- **Paint prep** (:768): scene-side `EncodedPaint`s are converted to GPU layouts.
- **Schedule** (`Schedule::try_new`, :537): builds all `GpuStrip` instance data (steps 8-9).
- **Uploads** (`Programs::prepare`, :2321): resizes textures if needed, then calls `upload_alpha_texture` (:2577), `upload_encoded_paints_texture` (:2622), `upload_filter_texture` and `upload_gradient_texture` (:2702, only when the gradient cache changed).
- **Alpha texture:** it is `Rgba32Uint` (`create_alphas_texture`, :2085-2100). The **entire alpha buffer is uploaded as one chunk** (TODO at :549-551). Each texel is 16 bytes, so one texel is exactly one 4x4 tile of alpha.
- **Instance arena:** `strips_arena.begin_frame` reserves `strip_count * size_of::<GpuStrip>()` bytes.
- **Caller owns the encoder:** `render` takes `&mut CommandEncoder` and has no `queue.submit` (the only submit in `render/wgpu/mod.rs` is at :481, in the separate `render_to_atlas` method, whose doc says it creates its own encoder). **`Renderer::render` never submits.**
- **Backends:** `render/webgl/` is a parallel implementation (e.g. `render/webgl/mod.rs:936`). This trace follows the wgpu backend only.

---

### 8. Scheduling: layers and draws into rounds
**File:** `vello_gpu/src/schedule/mod.rs:344` (`schedule_root`), `push_draws` :570, `Rounds::build_draw` :929

```rust
fn push_draws<T: ScheduleTarget>(&mut self, draws: &Range<u32>,
    state: &mut TargetScheduleState<T>, rounds: &mut Rounds) {
    if draws.is_empty() { return; }
    rounds.build_draw(state, &mut self.storage.buffers.draw_buffers,
        None,                                         // normal draws don't depend on a child layer
        |builder| {
            for draw in &self.recorder.draws[draws.start as usize..draws.end as usize] {
                builder.push_draw(draw, self.strip_storage, self.paint_resolver);   // :587
            }
        });
}
```

```rust
// Rounds::build_draw (:929)
let round_bindings = state.draw_state.target.round_bindings().merge(sampled_layer_round_bindings)
    .expect("draw target and sampled layer must have compatible texture parities");
let mut draw_point = sampled_layer.map_or_else(|| state.next_draw(),
    |layer| state.next_draw_after(layer.ready));
draw_point = self.bind_at_or_after(draw_point, round_bindings);          // :954
...
let mut builder = DrawBuilder::new(target_draw, draw_buffers, &mut state.draw_state);
f(&mut builder);
```

**What happens**:
- **Traversal:** `schedule_root` (:344) walks the root's nodes. Each node's draw range goes through `push_draws`. Layer children are scheduled bottom-up first (module doc :26-47).
- **Texture parity:** even-depth layers go in the "even" texture group and odd-depth layers in the "odd" group (`layer_texture_parity`, :565). A parent only ever samples a child from the opposite group, so two pages ping-pong. Layers are allocated lazily to keep live allocations minimal (doc :49-77).
- **Rounds:** a round (`round.rs:4-25`) is the largest unit that can execute with one fixed pair of (even page, odd page) bindings. It contains one `LayerTexturePass` per page plus a root `Draw` and the clears to run afterward. `build_draw` computes the earliest `(round, stage)` where dependencies are satisfied, then `bind_at_or_after` (:954) advances to the first round whose bindings are compatible. The algorithm is monotonic: it never backtracks to an earlier round (doc :89-99).
- **Simple scene:** with one root fill and no layers, everything lands in round 0's root draw.
- **Blended root:** if `root_is_blend_target` (:354), the root is rendered into an intermediate layer, then blitted back with `push_layer_fill` (:364-371).

---

### 9. Draw encoding: segments to `GpuStrip` instances
**File:** `vello_gpu/src/draw.rs:168`

```rust
fn push_path(&mut self, path: &RecordedPath, strip_storage: &StripStorage,
             paint_resolver: PaintResolver<'_>) {
    let strips = &strip_storage.strips[path.strips.clone()];
    let paint = paint_resolver.pack(&path.paint);
    let depth_index = self.state.depth_counter.next(paint.opaque);
    let tile_bounds = self.state.target_bbox.to_tile_bounds();
    let geometry_shift = self.state.target.geometry_shift();
    visit_strip_fill_segments(strips, tile_bounds, self,
        |builder, segment| {                                     // alpha segment
            let shifted = segment.shift(geometry_shift);
            let strip = GpuStrip::from_fill_segment(shifted, Some(segment.col_idx()),
                paint.payload_at(segment.x0(), segment.y()), paint.paint, depth_index); // :191-201
            builder.draw.push(builder.strips, strip, paint.texture_source);
        },
        |builder, segment| {                                     // solid fill segment
            let strip = GpuStrip::from_fill_segment(shifted, None, /* ... */ depth_index); // :210
            if !paint.opaque || !builder.push_opaque(strip, paint.texture_source) {  // :219
                builder.draw.push(builder.strips, strip, paint.texture_source);
            }
        });
}
```

`from_fill_segment` (:397), where the alpha vs solid distinction is made:

```rust
let (dense_width_or_rect_height, col_idx_or_rect_frac) = if let Some(col_idx) = col_idx {
    (width, col_idx)
} else {
    (0, 0)                                                      // :405-409  solid span
};
```

`col_idx()` (:569-574) is `alpha_idx / Tile::HEIGHT`, i.e. the index of the first 4-row column in the alpha buffer.

```rust
#[repr(C)] pub struct GpuStrip {        // vello_gpu/src/render/common.rs:284
    pub x: u16, pub y: u16, pub width: u16, pub dense_width_or_rect_height: u16,
    pub col_idx_or_rect_frac: u32, pub payload: u32,
    pub paint_and_rect_flag: u32, pub depth_index: u32,
}   // 2+2+2+2 + 4+4+4+4 = 24 bytes
```

**What happens**:
- **Per-segment instances:** each alpha segment and each solid segment becomes one 24-byte instance. For a solid color, `payload` carries the packed premultiplied RGBA8 (the fragment shader does `unpack4x8unorm(payload)`). For gradients and images, `payload` carries the scene-space position used to compute sample coordinates.
- **Two-coordinate trick:** `geometry_shift` moves the strip to where it lands in an intermediate layer texture, but `payload_at` uses the **unshifted** coordinates so paints sample in scene space (comment at :194-197).
- **Solid vs alpha:** `dense_width == 0` marks "no alpha lookup" (:408). A solid segment's instance has no `col_idx`.
- **Opaque routing:** if the paint is opaque and depth is enabled, solid segments go to `OpaqueDraw` (:219) and are drawn in a front-to-back depth pass before everything else. Otherwise they join the normal alpha-blended strip list.
- **Rects:** `push_rect` (:228) uses the separate `GpuStrip::from_rect` (:423) with `RECT_STRIP_FLAG` (bit 31, :394). The shader computes edge coverage analytically from fractional bits. This is the fast path taken by `fill_rect`, which bypasses flatten/tile/strip entirely (`generate_filled_rect_fast`, `strip_generator.rs:208`).

---

### 10. Execution order: `Schedule::execute`
**File:** `vello_gpu/src/schedule/execute.rs:84`

```rust
if DrawPassTarget::Root(root_output_target).enable_opaque()
    && !buffers.draw_buffers.opaque.is_empty() {
    renderer.opaque_draw_pass(buffers.draw_buffers.opaque.strips(),
                              buffers.draw_buffers.opaque.external_texture_runs())?;   // :91-98
}
self.rounds.execute(renderer, root_output_target, buffers, filter_plan,
                    self.intermediate_textures.size)
```

`Rounds::execute` (:111):

```rust
for round in self.iter() {
    for layer_passes in round.layer_passes(buffers) {     // even page first, then odd
        if let Some(pass) = layer_passes.draw   { backend.draw_pass(pass.strips, pass.external_texture_runs, pass.bindings)?; }
        if let Some(pass) = layer_passes.filter { filter_plan.init(...); backend.filter_pass(filter_plan, pass.bindings)?; }
        if let Some(pass) = layer_passes.blend  { backend.blend_pass(pass.blends, pass.blend_strips, pass.bindings)?; }
    }                                                     // :131-150
    if let Some(pass) = round.root_draw_pass(buffers, root_output_target) {
        backend.draw_pass(pass.strips, pass.external_texture_runs, pass.bindings)?;       // :153
    }
    for props in round.clear_passes() { backend.clear_pass(props.target, props.rects)?; } // :158
}
```

**What happens**:
- **Backend trait:** the executor is generic over a `Backend` trait (`opaque_draw_pass`, `draw_pass`, `filter_pass`, `blend_pass`, `clear_pass`). The wgpu implementation is `RendererContext`. The schedule is pure data, so the same schedule drives the WebGL backend.
- **Ordering inside a round:** draw, then filter, then blend per layer texture; then the root draw; then clears of regions released in this round. The even page is processed before the odd one so that odd draws sampling even children see finished pixels (comment :127-129).
- **Simple scene:** one `draw_pass` to the root, plus an `opaque_draw_pass` first if a depth view was given and opaque solid spans exist.

---

### 11. GPU pass: `strip_pass_inner`
**File:** `vello_gpu/src/render/wgpu/mod.rs:2884`

```rust
let strips_range = self.programs.upload_strip_pair(self.queue, opaque_strips, alpha_strips);  // :2903
...
let mut render_pass = self.encoder.begin_render_pass(&RenderPassDescriptor {
    label: Some("Render to Texture Pass"),
    color_attachments: &[Some(RenderPassColorAttachment { view, depth_slice: None,
        resolve_target: None,
        ops: wgpu::Operations { load: color_load_op, store: wgpu::StoreOp::Store } })],
    depth_stencil_attachment, occlusion_query_set: None, timestamp_writes: None,
    multiview_mask: None,
});                                                                              // :2979-2994
render_pass.set_bind_group(0, bind_group, &[]);                                  // alphas, config, layer input
render_pass.set_bind_group(2, &self.programs.resources.encoded_paints_bind_group, &[]);
render_pass.set_bind_group(3, &self.programs.resources.gradient_bind_group, &[]);  // :2995-2997
render_pass.set_vertex_buffer(0, self.programs.strips_arena.buffer.slice(strips_range.clone()));
...
render_pass.draw(0..4, first_instance..first_instance + count);                  // :3013
```

Pipeline state (:1342-1378): vertex buffer `array_stride: size_of::<GpuStrip>()`, `step_mode: Instance`, `topology: TriangleStrip`, entry points `vs_main` / `fs_main`.

**What happens**:
- **One upload, one pass:** the pass's `GpuStrip`s are written into a shared arena vertex buffer (`upload_strip_pair`: opaque instances first, then alpha ones) via `queue.write_buffer`-style staging. A render pass is opened **on the caller's encoder** (`self.encoder`).
- **Load op:** the root target's load op comes from `take_root_load_op`, so the first root pass can clear and later ones `Load`. Layer targets always `Load`.
- **Depth:** if a depth view was supplied, depth is cleared once per frame (`depth_cleared_this_frame`, :2959-2963) and depth testing is `LessEqual` (:1380-1384).
- **Draw call:** `draw(0..4, instances)`. There is no index buffer and no per-vertex data: 4 vertices per instance as a triangle strip, with all geometry derived from the instance in the shader. The opaque instances are drawn first with the opaque pipeline (:3035-3043), then alpha-blended instances.
- **External textures:** when `external_texture_runs` is non-empty, the same buffer is drawn in several sub-ranges with different bind group 1 (:3021-3032).
- **Bind group caching:** keyed by `(StripTargetKind, Option<LayerTextureId>)` (:2927-2952).

---

### 12. Shaders: one instance becomes a quad, a quad becomes pixels
**File:** `vello_gpu_shaders/shaders/render.wesl:230` (`vs_main`), `:385` (`fs_main`)

Vertex stage:

```wgsl
let corner = quad_corner(in_vertex_index);           // helpers/geometry.wesl:24; 0->(0,0) 1->(1,0) 2->(0,1) 3->(1,1)
...
let is_rect = (instance.paint_and_rect_flag & RECT_STRIP_FLAG) != 0u;
var height = config.strip_height;                    // 4
if is_rect { ... } else {
    out.dense_end_or_rect_size = instance.col_idx_or_rect_frac + dense_width;  // :254
}
let pixel = vec2<f32>(f32(i32(x0) + config.strip_offset_x) + x * f32(width),
                      f32(i32(y0) + config.strip_offset_y) + y * f32(height)); // :259-262
let ndc = pixel_to_ndc(pixel, vec2<f32>(f32(config.width), f32(config.height))); // :265
...
let col_offset = select(f32(instance.col_idx_or_rect_frac), 0.0, is_rect);
out.tex_coord = vec2<f32>(col_offset + x * f32(width), y * f32(height));      // :364-365
let z = 1.0 - f32(instance.depth_index) / f32(1u << 24u);                     // :369
```

For `COLOR_SOURCE_PAYLOAD` (:267-358), the vertex stage switches on paint type to compute `sample_xy` (image transform, gradient position, etc.).

Fragment stage:

```wgsl
var alpha = 1.0;
let is_rect = (paint_and_rect_flag & RECT_STRIP_FLAG) != 0u;
if is_rect && rect_frac != 0u {
    alpha = rect_coverage(dense_end_or_rect_size, rect_frac, tex_coord);
} else if !is_rect && dense_end_or_rect_size != 0u {
    alpha = sample_strip_alpha(alphas_texture, config.alphas_tex_width_bits, tex_coord); // :398-404
}
...
case PAINT_TYPE_SOLID { final_color = unpack4x8unorm(payload); }                // :413
...
return alpha * final_color;                                                     // :487
```

`sample_strip_alpha` (`vello_gpu_shaders/shaders/helpers/alpha.wesl:9`):

```wgsl
let texel_index = alphas_index / 4u;      // alphas_index = floor(tex_coord.x) = column
let channel_index = alphas_index % 4u;    // one RGBA32Uint channel per 4-row column
...
let rgba_values = textureLoad(alphas_texture, vec2<u32>(tex_x, tex_y), 0);
return f32((alphas_u32 >> (y * 8u)) & 0xffu) * (1.0 / 255.0);
```

**What happens**:
- **Geometry in the vertex shader:** each instance is an axis-aligned quad `width x 4` pixels. Vertex position is computed from `(x0, y0, width)` and the corner. NDC conversion is done by hand using the uniform `Config { width, height, strip_offset_x/y, ... }`.
- **Alpha texture addressing:** `tex_coord.x` is `col_idx + local_x`, an absolute column in the alpha buffer, and `tex_coord.y` is the row within the 4-row strip. Each column is 4 packed bytes (one `u32` channel), four columns per texel. The pixel's byte is found by shift.
- **Coverage selection:** `alpha = 1.0` unless the strip is a rect with fractional edges (analytic `rect_coverage`) or a non-rect with `dense_end != 0` (alpha-textured). **Solid interior spans have `dense_width = 0`, so they never read the alpha texture.**
- **Output:** `alpha * final_color` with the color already premultiplied (`PremulColor` on the CPU, `unpack4x8unorm` here). The fixed-function blend state (set at pipeline creation) composites into the target.
- **Z:** `depth_index` gives painter's-order depth so opaque solid spans drawn first can early-Z-reject later covered fragments.

## Data Flow Diagram

```
User: scene.fill_path(&BezPath)
    |
    v
+--------------------------------+  scene.rs:358
|  paint_has_area / encode paint |  Paint::Solid(PremulColor) | encoded_paints[i]
|  optional blend/filter layer   |
+--------------------------------+
    |
    v
+--------------------------------+  scene.rs:528
|  record_generated_path         |  strips appended to scene StripStorage (Append)
+--------------------------------+
    |
    v
+--------------------------------+  strip_generator.rs:120
|  flatten::fill (tol 0.25)      |  BezPath -> Vec<Line> (SIMD, bbox-culled, NaN dropped)
+--------------------------------+
    |
    v
+--------------------------------+  tile.rs:514, :478
|  make_tiles_analytic_aa        |  Vec<Line> -> Vec<Tile>{x,y,line_idx|flags}
|  sort_tiles                    |  sorted by (y, x, line_idx) as one u64
+--------------------------------+
    |
    v
+--------------------------------+  strip.rs:331
|  strip::render                 |  Tiles -> Vec<Strip> + Vec<u8> alphas
|  (f32x4 trapezoid area)        |  16 alpha bytes per edge tile, fill_gap flag, sentinel strip
|  [+ clip intersect]            |  strip_generator.rs:287-297
+--------------------------------+
    |
    v
+--------------------------------+  record.rs:426
|  CommandRecorder::push_draw    |  RecordedDraw::Path{strips: Range, paint}; Node{draws: Range}
+--------------------------------+
    |        ... CPU recording ends, render() called per frame ...
    v
+--------------------------------+  render/wgpu/mod.rs:346, :500
|  Renderer::render -> render_scene
|  prepare paints, Schedule::try_new, Programs::prepare
|  alphas -> Rgba32Uint texture (one upload); paints/gradients -> textures
+--------------------------------+
    |
    v
+--------------------------------+  schedule/mod.rs:344, :570, :929
|  schedule_root -> push_draws   |  Node draws -> Rounds (even/odd page bindings)
|  Rounds::build_draw            |
+--------------------------------+
    |
    v
+--------------------------------+  draw.rs:168
|  DrawBuilder::push_path        |  visit_strip_fill_segments ->
|                                |  GpuStrip (24 B): alpha seg (col_idx) | solid seg (dense_width=0)
|                                |  opaque -> OpaqueDraw (depth) | else strips list
+--------------------------------+
    |
    v
+--------------------------------+  schedule/execute.rs:84, :111
|  Schedule::execute             |  opaque pass, then per round:
|                                |  draw -> filter -> blend, root draw, clears
+--------------------------------+
    |
    v
+--------------------------------+  render/wgpu/mod.rs:2884
|  strip_pass_inner              |  upload strips to arena; begin_render_pass on caller's encoder
|  draw(0..4, instances)         |  TriangleStrip, step_mode Instance
+--------------------------------+
    |
    v
+--------------------------------+  render.wesl:230 / :385
|  vs_main: instance -> quad     |  pixel -> NDC, tex_coord, z, paint sample_xy
|  fs_main: alpha * color        |  alpha = alphas_texture[tex_coord] | 1.0 | rect_coverage
+--------------------------------+
    |
    v
Premultiplied RGBA blended into caller's TextureView
(caller later calls queue.submit(encoder.finish()))
```

## Key Observations

1. **No triangulation anywhere.** Paths never become triangle meshes. They become flattened lines, then 4x4-tile bins, then horizontal strips (spans of tiles). The GPU draws one instanced quad per strip segment, and edge-pixel coverage is decoded from a texture of bytes computed on the CPU.
2. **CPU does geometry, GPU does compositing.** Flatten, tile, sort and coverage (steps 3-5) all run on the CPU with SIMD (`fearless_simd` `Level` dispatch). The GPU only draws quads and looks up alpha. This is the opposite split from compute-based Vello (classic); it avoids compute shaders and large GPU scratch buffers.
3. **Only edge tiles carry alpha bytes.** Exactly 16 bytes are written per 4x4 edge tile (`strip.rs:487-500`). Interior spans between edge strips are represented only by the `fill_gap` flag, then emitted as `dense_width = 0` instances (`draw.rs:408`). Fragments for those spans never read the alpha texture. Cost scales with the path perimeter for alpha storage and with its area only in fragment fill.
4. **The strip type has no width.** Width is `next.alpha_idx - this.alpha_idx` (`strip.rs:236`), so a sentinel strip is mandatory and consumers must use `windows(2)`. This saves a field per strip but makes slices non-self-describing, a footgun for any code that sub-slices strips.
5. **Sort key packing.** `Tile` field order is chosen so its memory is the sort key (`tile.rs:379`). The line index is in the key only for locality, not correctness (comment :380-383). This is a good example of layout-driven performance.
6. **Flatten tolerance is 0.25, not 0.1.** Defined as `SQRT_TOL = 0.5` (`flatten.rs:17`) with the derived constants. The `0.1` in the user code above is the `kurbo` `to_path` accuracy for the circle itself, which is a separate step.
7. **Record then plan then execute.** Draws are recorded eagerly (strips generated at call time) but nothing is bound to GPU resources until `render()`. The scheduler (`schedule/mod.rs`) only needs the layer DAG with bounds. This lets it minimize intermediate texture allocations: two parity groups (even/odd), lazy allocation and monotonic round batching (module doc :4-119).
8. **Caller owns the encoder and the submit.** `Renderer::render` takes `&mut CommandEncoder` and `&TextureView` and opens its own render passes on that encoder (`mod.rs:2979`). It never calls `submit` (only `render_to_atlas`, :481, does, with its own encoder). This is easy to embed in a host frame graph.
9. **No special wgpu features needed.** All in-repo examples request `required_features: Features::empty()` (`examples/render_to_file.rs:56`, `winit/src/render_context.rs:204`, wasm examples). The one exception is `wgpu_video`, which asks for `Features::EXTERNAL_TEXTURE` to sample video frames. Texture formats used are baseline: `Rgba32Uint` for alphas and paint data, `Depth24Plus` for the optional depth. A WebGL backend exists as a separate module (`render/webgl/`), so web works with both WebGPU and WebGL2.
10. **Masks are not implemented.** `Scene::push_layer` panics with `unimplemented!("mask layers are currently not supported")` if `mask.is_some()` (`scene.rs:686-688`). Clip paths, opacity, blend modes and filters are supported; masks are not.
11. **Clips are resolved on the CPU.** A clipped path is rendered into a temporary strip storage, then intersected with the clip's strips and alphas (`strip_generator.rs:287-297`). The GPU never sees a clip. Clip bboxes also cull flattening (`cull_bbox`).
12. **Fast paths bypass the pipeline.** Pixel-aligned rects skip flatten/tile/strip entirely (`generate_filled_rect_fast`) and rects with fast bounds use `RecordedDraw::Rect` and the analytic `rect_coverage` in the fragment shader.
13. **Whole-alpha-buffer upload.** The entire alpha `Vec<u8>` is uploaded as one texture write each frame (TODO at `mod.rs:549-551`). Large scenes can hit texture size limits; a bounded buffer with draw breaks is noted as future work.

## Implications for Rust Framework (Flux)

### Adopt
- **Edge-only alpha, interior as spans.** Store coverage bytes only for tiles that straddle an edge, and represent interior spans as a flag plus extent. This shrinks upload bandwidth and fragment texture reads.
- **Instanced triangle-strip quads with no vertex buffer data.** Use `draw(0..4, instances)` with `VertexStepMode::Instance` and a 24-byte POD instance (`bytemuck`). It maps cleanly to wgpu on all targets.
- **Caller-owned encoder.** A `render(&mut self, encoder: &mut CommandEncoder, view: &TextureView, ...)` API composes with the host's frame graph and keeps submit policy out of the library.
- **Features-empty baseline.** Aim for zero required wgpu features, and gate extras (external texture, video) behind optional capabilities.
- **Record then plan then execute.** Keep drawing cheap and deferred. Planning (scheduling layers into passes) is a pure-data stage that is unit-testable without a GPU, as vello_gpu's `Backend` trait demonstrates.
- **Sort-key-by-layout.** Choose struct field order so the sort key is the memory value.

### Modify
- **Strip type should carry width.** Flux can afford 2 extra bytes per strip to avoid sentinel-dependent slices and `windows(2)` coupling, or wrap `&[Strip]` in a newtype that guarantees the sentinel.
- **Chunked alpha upload.** Replace the single whole-buffer upload with a bounded, ring-buffered alpha store (the upstream TODO), especially for mobile and WebGL2 with small max texture sizes. Add a pass break when full.
- **Error handling.** `Result<(), RenderError>` at the boundary is good, but `unimplemented!`/panic for masks should be a typed `Unsupported` error in a public API.
- **Resolve interior mutability.** `RefCell<StripStorage>` inside `Scene` makes `Scene: !Sync`. Prefer `&mut` ownership during recording and an immutable `&SceneSnapshot` for rendering, or hand the alphas to the renderer by value.
- **Consider GPU-side flattening later.** The CPU does all geometry. That is a good fit for web and mobile (no compute), but a feature-gated compute path could scale to very complex paths.

### Avoid
- **Generic SIMD runtime dispatch complexity in the first cut.** `fearless_simd` `Level` dispatch is powerful, but start with scalar or `wide`/`std::simd` behind one trait and add dispatch after profiling.
- **A rounds scheduler for apps without layers.** The even/odd ping-pong and monotonic round batching are only needed for blend/filter/opacity layers. If Flux v1 draws only flat paths, a single root pass per frame suffices and the scheduler can be deferred.
- **Panics in the draw path** for NaN. Vello drops the path silently with a `warn!`; Flux should expose a `PathError` in checked entry points.

### API Sketch
```rust
/// Recording is pure CPU; nothing here touches wgpu.
pub struct Scene { /* strips: Vec<Strip>, alphas: Vec<u8>, recorder, paints */ }

impl Scene {
    pub fn new(width: u16, height: u16) -> Self;
    pub fn set_paint(&mut self, paint: impl Into<PaintType>);
    pub fn set_fill_rule(&mut self, rule: Fill);
    pub fn fill_path(&mut self, path: &BezPath);          // flatten -> tile -> strips -> record
    pub fn push_layer(&mut self, opts: LayerOpts) -> Result<(), Unsupported>;
    pub fn pop_layer(&mut self);
}

/// Rendering borrows the caller's encoder; it never submits.
pub struct Renderer { /* pipelines, alpha texture, strips arena, schedule storage */ }

impl Renderer {
    pub fn new(device: &wgpu::Device, opts: RendererOptions) -> Self;   // no required features
    pub fn render(
        &mut self,
        scene: &Scene,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        target: &wgpu::TextureView,
        depth: Option<&wgpu::TextureView>,
    ) -> Result<(), RenderError>;
}

/// 24-byte instance; one per fill segment.
#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub struct GpuStrip {
    pub x: u16, pub y: u16,
    pub width: u16, pub dense_width: u16,   // 0 => solid span, no alpha lookup
    pub col_idx: u32,                       // first alpha column
    pub payload: u32,                       // premul RGBA8 or paint xy
    pub paint_flag: u32,
    pub depth_index: u32,
}
```

## Related Documents

- [vello README](../README.md) — why Vello is studied and the document plan
- [Tessellation theme](../../../../themes/vector-graphics/tessellation.md) — the triangle-based alternative this trace contrasts with
- [Primitive strategies](../../../../themes/rendering/primitive-strategies.md) — instanced quads for simple shapes, the same draw mechanism used here for strips

---

*This document is part of the [Vello study](../README.md).*
