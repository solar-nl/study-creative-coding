# Vello Text: How `glifo` Gets Glyphs to Pixels

> One crate turns a string of positioned glyph IDs into either thousands of tiny vector fills or a handful of cached image draws, and the renderer never has to know which.

## Key Insight

> **The core idea:** `glifo` does not live inside the renderer. It drives the renderer through a small sink trait (`DrawSink`, `GlyphRenderer`), so one text library emits outlines, color layers and underlines as ordinary scene calls. A per-run switch then chooses between "draw every glyph as a path every frame" (resolution-independent, default) and "rasterize once into an atlas, draw images afterwards" (fast, but tied to the cached size).

This note covers the Sparse Strips renderers (`vello_cpu`, `vello_gpu`) at commit `65338c25`, with `glifo` 0.4.0. It assumes you know glyph atlases and SDF text from other frameworks; the study's [typography theme](../../../themes/typography/README.md) frames the three layers (font parsing, shaping, rendering). `glifo` sits squarely in Layer 3: it takes glyphs that a shaper has already positioned and renders them. For what happens once a glyph has become a path, read [code-traces/fill-path.md](code-traces/fill-path.md). All paths below are relative to `libraries/rust/vello/`.

---

## The Problem: Thousands of Small Paths, Every Frame

A page of text is a few thousand tiny vector shapes. Each "e" is a closed outline of a dozen Bezier segments, repeated hundreds of times with only the position changing. A renderer that treats every glyph as a fresh path is correct: it hints, scales and anti-aliases each outline exactly for the current zoom. It is also wasteful. Flattening, tiling and strip generation run again for a shape that has not changed since the last frame.

The classic fix is a glyph atlas. Rasterize each glyph once into a texture, then draw textured quads. You know the cost from Processing's `FontTexture` and Cinder's `TextureFont` in the typography theme: the atlas freezes the resolution at whatever size you rasterized. Zoom in and the text blurs. Rotate it and the sampling smears. SDF and MSDF text stretch that limit but give up hinting and exact curves.

`glifo` refuses to pick a side. It offers both strategies behind one builder, selected per glyph run, and it expresses both through the same small interface to the renderer. You can think of it as a print shop with two ways to produce a flyer. One is a hand-drawn original for every copy: perfect at any size, slow for a thousand copies. The other is a photocopier: fast, but the copy is only as sharp as the master you fed it. `glifo` runs both machines and decides per run which one to use.

Here is the shape of the whole system before we look at any code.

```
 user: scene.glyph_run(&mut resources, &font).font_size(16.0).fill_glyphs(glyphs)
            │
            ▼
   GlyphRunBuilder  ──▶  GpuGlyphRunBackend { scene, resources, atlas_cache_enabled }
            │                         │
            ▼                         ▼
   GlyphRunRenderer (glifo)     AtlasCacher::Disabled | Enabled(GlyphAtlas, ImageCache)
            │
   per glyph: COLR > bitmap > outline
            │
   ┌────────┴─────────────────────────────────────────────┐
   │ path mode: renderer.fill_path(outline)               │
   │ atlas mode: hit  -> fill_rect with image paint       │
   │             miss -> record AtlasCommands, then draw  │
   └────────┬─────────────────────────────────────────────┘
            ▼
   trait DrawSink / GlyphRenderer  ──▶  impl for vello_gpu::Scene
```

---

## The Interface: Text Drives the Renderer, Not the Other Way Round

Most frameworks wire text into the renderer: the renderer knows about fonts, owns an atlas and exposes `drawText`. `glifo` inverts that. The text crate defines what it needs from a renderer as two traits, and any renderer that implements them can draw glyphs. This is dependency inversion in the plain sense: the high-level policy (how to draw glyphs) owns the interface, and the low-level machinery (how to fill a path) plugs in.

`DrawSink` is the low-level half. It is a list of things any 2D renderer can already do: set a transform and paint, fill a path or rectangle, push and pop clip and blend layers, report the surface size. A comment in the source calls the trait temporary, pending a better unifying imaging API.

**File:** `glifo/src/interface.rs:15`

```rust
pub trait DrawSink {
    fn set_transform(&mut self, t: Affine);
    fn set_paint(&mut self, paint: AtlasPaint);
    fn set_paint_transform(&mut self, t: Affine);
    fn fill_path(&mut self, path: &BezPath);
    fn fill_rect(&mut self, rect: &Rect);
    fn push_clip_layer(&mut self, clip: &BezPath);
    fn push_blend_layer(&mut self, blend_mode: BlendMode);
    fn pop_layer(&mut self);
    fn width(&self) -> u16;
    fn height(&self) -> u16;
    // push_clip_path, push_clip_rect, pop_clip_path have default bodies
}
```

This excerpt drops the doc comments and the three methods that default to the layer versions. Those defaults are a hint about the design: a renderer may override `push_clip_path` with something cheaper than an isolated layer, but it does not have to.

`GlyphRenderer` extends the sink with what glyph drawing needs beyond raw geometry. It can save and restore state, stroke a path, set an image paint and a tint, report the current paint (COLR glyphs need a "context color"), and translate a cached atlas slot into an image source and a paint transform.

**File:** `glifo/src/interface.rs:63`

```rust
pub trait GlyphRenderer: DrawSink {
    type SavedState;
    fn save_state(&mut self) -> Self::SavedState;
    fn restore_state(&mut self, state: Self::SavedState);
    fn stroke_path(&mut self, path: &BezPath);
    fn set_paint_image(&mut self, image: Image);
    fn set_tint(&mut self, tint: Option<Tint>);
    fn get_context_color(&self) -> AlphaColor<Srgb>;
    fn current_paint(&self) -> &PaintType;
    fn atlas_image_source(&self, atlas_slot: &AtlasSlot) -> ImageSource;
    fn atlas_paint_transform(&self, atlas_slot: &AtlasSlot) -> Affine;
}
```

The last two methods carry a source comment saying they should disappear someday (`interface.rs:89`). They exist because the renderer, not `glifo`, owns the image handles.

`vello_gpu` implements both traits for its ordinary `Scene`. Almost every `DrawSink` method is a one-line forward to the `Scene` method of the same name, and the `GlyphRenderer` impl is a thin adapter too.

**File:** `vello_gpu/src/text.rs:150` and `vello_gpu/src/text.rs:320`

The two adapter details worth noticing are `get_context_color`, which returns the solid paint's color or falls back to black for gradients (`text.rs:349`), and `atlas_paint_transform`, which shifts by the one-pixel glyph padding (`text.rs:368`). Everything else is delegation.

The payoff of the inversion: a glyph is not a special object inside `Scene`. COLR layers, bitmap glyphs, underlines and plain outlines all become `fill_path`, `fill_rect` and `push_clip_*` calls. They flow through the same strip pipeline as any other shape. `vello_cpu` can implement the same traits and share `glifo` unchanged. This also explains the repo layout: `glifo` is a sibling crate of the renderers, not a module inside them.

---

## The Entry Point: A Builder Bound to a Scene and Its Resources

Users reach text through `Scene::glyph_run`, available behind the `text` feature. It takes the `Resources` (more on those later) and a `FontData`, and returns a builder pre-bound to a backend.

**File:** `vello_gpu/src/scene.rs:656`

```rust
pub fn glyph_run<'a>(&'a mut self, resources: &'a mut Resources, font: &FontData)
    -> GlyphRunBuilder<'a>
```

The body hands `glifo::GlyphRunBuilder::new` the scene transform, the paint transform and a `GpuGlyphRunBackend { scene, resources, atlas_cache_enabled: false }` (`scene.rs:661-670`). That `false` is the whole default: out of the box you get path mode.

The builder itself, `GlyphRunBuilder` in `glifo/src/glyph.rs:960`, is generic over the backend. It collects run attributes: `font_size` (default 16.0 pixels per em), `font_embolden`, a per-glyph transform (a horizontal skew fakes italics), `hint` (default on), and `normalized_coords` for variable fonts (`glyph.rs:967-1016`). Nothing draws until you call `fill_glyphs` or `stroke_glyphs`; the builder is `#[must_use]` to remind you.

The backend contract is the `GlyphRunBackend` trait (`glifo/src/glyph.rs:350`). It has four methods: `atlas_cache(bool)`, `fill_glyphs`, `stroke_glyphs` and `render_decoration`. Its docs call atlas caching "highly experimental and not recommended for external use" (`glyph.rs:353-354`). Read that as a maturity warning for everything in the atlas half of this note.

`GpuGlyphRunBackend` (`vello_gpu/src/text.rs:219`) implements the trait. Its private `render_glyphs` helper does the real assembly. It builds an `AtlasCacher`, which is either `Disabled` or `Enabled(&mut GlyphAtlas, &mut ImageCache)` (`glyph.rs:325-331`), then calls `run.build` with the shared prep cache to get a `GlyphRunRenderer` (`glyph.rs:393`), and finally runs the closure against the `Scene`.

**File:** `vello_gpu/src/text.rs:226-256`

The crate root re-exports the pieces under a module map: `atlas`, `colr`, `glyph`, `interface`, `renderer`, `util` (`glifo/src/lib.rs:50-66`). The `AtlasCacher` enum is the compile-time-cheap way to say "this run uses the atlas or it does not". Every cache lookup in the hot loop goes through `AtlasCacher::get`, which returns `None` immediately when disabled (`glyph.rs:341-346`).

---

## Path Mode: Every Glyph Is a `fill_path`

Path mode is what you get by default. Per glyph, `GlyphRunRenderer::draw_glyphs` picks a representation with a priority cascade: COLR, then bitmap, then outline (`glyph.rs:424-430`). For the overwhelmingly common outline case, glifo fetches the outline, builds a `BezPath` and calls `fill_uncached_outline_glyph`. That function saves state, sets the transform and paint transform, calls `renderer.fill_path(path)` and restores state.

**File:** `glifo/src/renderer.rs:205-217`

So a glyph in path mode is indistinguishable from a path you drew yourself. It is flattened, tiled and turned into strips, then scheduled with every other shape. Anti-aliasing is exact coverage and there is no separate text pipeline. You can also fill text with a gradient or an image paint and rotate it freely, because the paint model is the scene's own.

Resolution independence needs a precise statement here. Before drawing, `prepare_glyph_run` inspects the full transform. If it is a uniform positive scale (and, for hinting, has no vertical skew or rotation), glifo *absorbs* the scale into the font size and draws with a near-identity transform plus translation. Hinting, which is vertical-only, runs at that absorbed size through a `HintCache` instance (`glyph.rs:1674-1730`). Otherwise it falls back to a `Direct` mode: no hinting and the transform applied as-is.

Two consequences follow:

1. Zooming never blurs. The outline is regenerated (or fetched from the `OutlineCache`, keyed by size) at the new effective size, and the strip generator re-rasterizes it.
2. Hinting is crisp at integer sizes but disappears under rotation or non-uniform scale. Hinting is a property of the size glifo sees, not a global setting.

What it costs per frame: for every glyph, every frame, the CPU runs a transform and a lookup in the outline cache, then flatten, tile and strip generation for that glyph's path. Strips are stored in the scene recording, so the GPU receives instance data for every glyph's strips again. Nothing amortizes across frames except the outline and hint caches in `GlyphPrepCache`. For a hundred labels that cost is invisible. For a screen of body text under animation, it is exactly the repeated work an atlas exists to avoid. I did not benchmark this; the claim follows from the pipeline in the fill-path trace, not from measurements.

---

## Atlas Mode: Rasterize Once, Draw Images Afterwards

Atlas mode is opt-in per run. `atlas_cache(true)` on the builder forwards to the backend, which asserts that the `full_image_support` feature is on, since cached glyphs are drawn as image paints.

**File:** `vello_gpu/src/text.rs:260-268`

With the cache enabled, the loop in `draw_glyphs` changes at the very top. A glyph first tries a cache hit. The key (`GlyphCacheKey`) includes font ID and index, glyph ID, font size bits, a hinted flag, a **sub-pixel x bucket**, embolden settings and variation coordinates (`glyph.rs:506-517`). The sub-pixel bucket count is 4 (`atlas/key.rs:24`), so glyphs positioned at different fractional x offsets reuse one of four rasterizations, not one per pixel. COLR and bitmap glyphs use sentinel bucket values so they cannot collide with outline entries (`key.rs:33-36`).

Not every glyph qualifies. The conditions are all visible in the loop:

- The font size must be at most `max_cached_font_size`, 128 ppem by default (`atlas/cache.rs:58-69`; `glyph.rs:463-466`). Larger glyphs fall back to direct drawing, because they eat disproportionate atlas space.
- Outlines are only cached for fills with a solid paint. Stroked outlines are never cached, and complex paints cannot be applied as a tint (`glyph.rs:467-474`).
- The transform must have no rotation or skew, with positive x scale and the flipped-y convention (`supports_atlas_caching`, `renderer.rs:653-665`; bitmap glyphs get a relaxed check). Otherwise `insert_and_render_outline` returns `UnsupportedTransform` and the caller draws the path directly.
- The atlas must have room. If the allocator cannot fit the glyph, the result is `AtlasFull` and the same direct-drawing fallback applies (`renderer.rs:27-39`).

So atlas mode degrades into path mode per glyph, not per run. That is the design's safety net, and it is also why the mode switch is safe to flip on and off.

### The miss: record, don't draw

Here is where the architecture gets interesting. On a miss, glifo does not rasterize anything on the spot. `insert_and_render_outline` asks the `GlyphAtlas` for a slot and a recorder, then writes *commands* into the recorder describing how to draw this outline at the slot's position. It immediately draws the glyph from the atlas slot as an image fill, even though the pixels do not exist yet.

**File:** `glifo/src/renderer.rs:396-430`

The atlas lives in `glifo/src/atlas/`. Its module docs list the design: rasterize once, pack with guillotiere, stable keys, multiple pages, simple age-based eviction (`atlas/mod.rs:4-14`). I opened `mod.rs` and `cache.rs`; `commands.rs` and `region.rs` I only know by their exports (`AtlasCommand`, `AtlasCommandRecorder`, `AtlasPaint`, `AtlasSlot`, `RasterMetrics`).

Think of it as a kitchen ticket rail. The text layer does not cook; it clips order tickets (`AtlasCommand`s) to a rail while it keeps drawing the scene against plates that will be filled later. Before the scene renders, the kitchen reads the rail and cooks everything.

### The replay: `before_render`

When you call `Renderer::render`, the first thing it does under the `text` feature is call `resources.before_render` with two closures: one to render commands into an atlas page, one to upload bitmap glyphs.

**File:** `vello_gpu/src/render/wgpu/mod.rs:359-388`

For each page with pending commands, `Resources::replay_pending_atlas_commands` resets a dedicated `glyph_renderer: Scene`, replays the recorded commands into it through the `DrawSink` trait (`replay_atlas_commands`, `glifo/src/renderer.rs:633`), and hands the finished scene to the backend. The GPU backend renders it into the atlas layer with `render_to_atlas`, which creates its own encoder and submits immediately so the atlas content is committed before the main scene draws (`vello_gpu/src/render/wgpu/mod.rs:414-433`).

**File:** `vello_gpu/src/text.rs:75-96` and `vello_gpu/src/text.rs:98-129`

The `glyph_renderer` scene is the same `Scene` type, sized to the atlas page, living in `GlyphAtlasResources` (`text.rs:31-35`). The sink inversion pays off a second time: the atlas is filled by the same strip pipeline that renders the main scene. There is no separate rasterizer for glyphs. Bitmap glyphs (for example PNG strikes) are decoded into `Pixmap`s and take a different route: `drain_pending_uploads` hands them to `write_to_atlas` at the allocated offset, shifted by the glyph padding (`text.rs:116-126`).

After the main scene renders, `after_render` runs `glyph_prep_cache.maintain()`, `GlyphAtlas::maintain` and any pending clear rectangles for evicted slots (`text.rs:131-146`; `mod.rs:405-410`).

The cached glyph then draws as an image fill. `render_outline_glyph_from_atlas` snaps translation to whole pixels with `floor` (the sub-pixel part lives in the bucketed rasterization), builds a rectangle of the slot size, and calls `render_from_atlas`. That function sets a tint, transform and image paint with `Extend::Pad` and low-quality sampling, then calls `fill_rect`. Outlines use `TintMode::AlphaMask` with the context color, so a single atlas entry serves any solid color.

**File:** `glifo/src/renderer.rs:310-339` and `glifo/src/renderer.rs:519-544`

### The trade, and eviction

The atlas copy is a raster at the size in the key. Draw it at the same pixel size and it is cheap and sharp. Zoom animation is the stress case: each new size is a new key, a new rasterization and a new slot, while old sizes age out. Above 128 ppem you are back in path mode by policy, so the cache never holds very large glyphs.

Eviction is age-based. The default config has `max_entry_age: 64` frames, evaluated every `eviction_frequency: 64` frames (`atlas/cache.rs:53-69`). Entries unused for longer than the age get deallocated from the atlas and queue a clear rectangle for `after_render`. `vello_gpu` currently builds the glyph resources with `GlyphCacheConfig::default()`, with a TODO to let users provide a config (`text.rs:58-63`). So today you cannot tune the cache from the public API. The module docs say "LRU eviction" (`cache.rs:4`), but the eviction loop is a plain age threshold. `maintain` bumps a frame counter and, every `eviction_frequency` frames, `evict_old_entries` drops any entry whose `serial` trails the current frame by more than `max_entry_age` (`cache.rs:343-390`). There is no recency ordering and no capacity-driven eviction. "LRU" is loose shorthand for "entries not used recently", and this note calls the policy age-based.

---

## Color Glyphs, Bitmaps and Decorations

`glifo` handles three kinds of non-trivial glyph, all through the same sink traits.

**COLR (color vector fonts).** `glifo/src/colr.rs` implements skrifa's `ColorPainter` on a `ColrPainter` that holds a `&mut dyn DrawSink`. COLR paint operations (fills with solid or gradient brushes, transforms, clip glyphs, composite modes) translate into `set_paint` plus `fill_rect`, clip layers and blend layers. It even converts COLR composite modes into the scene's `BlendMode` (`colr.rs:551`). A COLR glyph is therefore a small scene graph drawn into the same renderer. With the atlas on, the finished glyph caches as an image keyed by size and context color (`glyph.rs:548-563`).

**Bitmap glyphs.** The loop asks skrifa for a bitmap strike at the run size. Only PNG data is supported, and only with the `png` feature; BGRA and mask strikes are reported as skipped (`glyph.rs:618-640`). A strike has a fixed `ppem`, so the cache key uses the strike's size and not the run's (`glyph.rs:645-662`). Apple Color Emoji gets a special-case transform (`glyph.rs:441-444`).

**Decorations.** Underlines and strikethroughs are not glyph work at all. `render_decoration` computes horizontal spans, cutting gaps around glyph descenders for skip-ink behavior, and emits each span with `renderer.fill_rect`. The skip-ink pass currently ignores color and bitmap glyphs (the `TODO` in the loop at `glyph.rs:874`).

**File:** `glifo/src/glyph.rs:796-809`

Glyphs that cannot be drawn do not abort the run. `draw_glyphs` collects the first skipped glyph and a count, draws the rest, and returns a `GlyphRenderError` (`glyph.rs:767-773`). That is a good policy for text in a live-coding environment.

---

## Why `Resources` Lives Outside the `Scene`

`Resources` bundles the state that must survive between frames: the `image_cache`, the `glyph_prep_cache` and a lazily created `glyph_resources`.

**File:** `vello_gpu/src/resources.rs:17`

```rust
pub struct Resources {
    pub(crate) image_cache: ImageCache,
    pub(crate) glyph_prep_cache: GlyphPrepCache,                    // `text` feature
    pub(crate) glyph_resources: Option<GlyphAtlasResources>,        // `text` feature, lazy
}
```

That is a simplified view of the real struct. The real fields carry `#[cfg(feature = "text")]` attributes, and the doc comment demands that a set of resources be used only with the renderer instance associated with it.

The reason it lives beside the `Scene`, not inside it, is lifetime. A `Scene` is a recording: you reset and refill it each frame. The caches are the opposite: their value comes from outliving frames. If outlines, hinting instances and atlas pages lived in the scene, clearing the scene would throw away the cache. Keeping them in `Resources` also lets several scenes share one atlas, and it matches how `Renderer::render` already takes both a scene and resources (see the fill-path trace).

Laziness matters for the default path. `ensure_glyph_resources` creates the glyph atlas and the atlas-sized `glyph_renderer` scene only when a run first enables atlas caching (`text.rs:55-65`, `text.rs:235-248`). Path-mode users pay for the prep cache and nothing else. The `GlyphCaches` struct (`glyph.rs:1840`) bundles outline, hint and atlas caches for renderers such as the CPU one, and the doc comment says to call `maintain` once per scene rendering (`glyph.rs:1860-1870`). I read these two bundles but not the internals of `OutlineCache` or `HintCache` (`glyph.rs:1932`, `glyph.rs:2181`).

---

## Four Ways to Draw Text, Compared

The table places glifo's two modes beside the two approaches most readers already know. The MSDF and CPU-atlas columns describe the usual technique in general, with cables' MSDF font (listed in the [operator-families comparison](../../../themes/node-graphs/operator-families-vs-flux.md)) as the concrete example; they are not claims about glifo's code.

| Dimension | glifo path mode | glifo atlas mode | MSDF text (e.g. cables) | CPU-rasterized atlas (typical) |
|-----------|-----------------|------------------|-------------------------|--------------------------------|
| Resolution independence | Full; re-hinted and re-rasterized at the effective size | Per cached size; fallback to path mode above 128 ppem or under rotation/skew | Good across a wide size range; corners soften at extreme zoom | None; fixed at the rasterized size |
| Per-frame CPU cost | Highest: flatten, tile and strip every glyph | Low on hits (key lookup plus one image fill per glyph); spike on misses | Low: one quad per glyph | Low: one quad per glyph |
| GPU memory | None beyond strips | Atlas pages sized by `AtlasConfig`; shared with the image cache | One small atlas per font | One atlas per font and size |
| Zoom and animation | Smooth; cost scales with glyph count | Each new size is a miss; old sizes evicted after about 64 frames | Smooth | Blurs, or re-rasterizes in a pause |
| Hinting | Vertical-only, uniform scale | Cached at the key's size | None | Depends on the rasterizer |
| Color fonts | COLR, PNG bitmaps | COLR and bitmaps cached as images | Not supported natively | Bitmap only, usually |
| Arbitrary paints and strokes | Yes | Solid-color fills only; strokes drawn directly | Shader-defined | Usually solid tint |

---

## Edge Cases and Gotchas

- **Atlas mode is experimental upstream.** The trait docs say so (`glyph.rs:353-354`, `glyph.rs:1049-1050`). Treat the API as unstable, and treat the `full_image_support` assertion as a runtime panic you will hit if the feature is off (`text.rs:261-264`).
- **Silent per-glyph fallback.** A run with `atlas_cache(true)` can draw some glyphs as paths (big sizes, rotation, gradient fills, full atlas). Profiling must look at hit rates, which the source lists as a TODO (`glyph.rs:1838`).
- **Pixel snapping.** Cached outlines floor the translation to whole pixels and rely on four x-buckets for sub-pixel placement. Vertical position has no sub-pixel bucket in the key I read. Smooth vertical animation of cached text therefore moves in whole pixels (inferred from `renderer.rs:527-531` and the key fields).
- **Atlas replay is a hidden submit.** `render_to_atlas` submits its own encoder, so atlas work lands before your encoder's commands. If you manage submission order yourself, this matters (`mod.rs:424-427`).
- **Upload errors drop pending work.** TODOs note that an upload or clear error discards the remaining queue (`text.rs:119`, `text.rs:139`).
- **No shaping here.** `glifo` takes `Glyph` values (ID plus position). Shaping and layout live upstream, in Parley, whose authors are credited in the source headers. Our typography theme's "shaping gap" is therefore someone else's crate in this ecosystem.

---

## Implications for Flux

- **Adopt: the sink-trait inversion.** Let the text layer own a narrow trait (transform, paint, fill path, fill rect, layers) and let each renderer implement it. Flux gets a renderer-agnostic text crate, free COLR and decoration support through ordinary draw calls, and a way to test text against a recording sink without a GPU.
- **Adopt: path mode as the default.** Text as ordinary paths keeps gradients, strokes, rotation and per-glyph animation working with no special cases. That matches what creative coders do with text in the typography theme ("treat text as graphic material").
- **Modify: expose the mode choice per run, and make fallback visible.** `atlas_cache(bool)` per run is the right granularity. Flux should add a hit/miss report instead of silent fallback, and let the user tune max size and age (glifo hard-codes the default today).
- **Modify: record-then-replay for atlas fills.** Deferring rasterization to a pre-render step keeps recording cheap and lets the atlas use the renderer's own pipeline. In Flux's node graph, the replay maps naturally to a pre-pass operator ahead of the frame's draw commands. Keep the submit-ordering explicit.
- **Avoid: tying atlas resolution to a single scale.** glifo keys on font size and absorbs scale into it, which fails under zoom animation. Flux should consider quantizing sizes into buckets, or fall back to path mode while a size is changing continuously.
- **Avoid: gating cached text to solid fills only.** Tint-based caching is an elegant trick (one entry, any color) but excludes gradients and strokes. Keep path mode on the same builder so those cases degrade, not fail.

---

## Sources

Read for this note (all under `libraries/rust/vello/`):

- `glifo/src/interface.rs` (whole file), `glifo/src/lib.rs` (lines 1-66)
- `glifo/src/glyph.rs` (lines 270-470 and 466-875 for the draw loop and decorations; 950-1069 builder; 1656-1735 `prepare_glyph_run`; 1836-1876 `GlyphCaches`)
- `glifo/src/renderer.rs` (lines 1-145, 200-235, 285-355, 394-454, 515-555, 653-665)
- `glifo/src/atlas/mod.rs` (lines 1-30), `glifo/src/atlas/cache.rs` (lines 1-75, 343-390 eviction), `glifo/src/atlas/key.rs` (lines 24-36)
- `glifo/src/colr.rs` (lines 1-60 and the grep outline of the file)
- `vello_gpu/src/text.rs` (whole file), `vello_gpu/src/resources.rs` (whole file)
- `vello_gpu/src/scene.rs` (lines 630-700), `vello_gpu/src/render/wgpu/mod.rs` (lines 350-460)

Not opened, so not described: `glifo/src/atlas/commands.rs`, `region.rs`, `OutlineCache` and `HintCache` internals, `replay_atlas_commands` body, and the CPU renderer's side of `glifo`.

Related notes:

- [Vello README](README.md)
- [code-traces/fill-path.md](code-traces/fill-path.md) — what `fill_path` does with a glyph outline
- [Typography theme](../../../themes/typography/README.md) — the three layers of text, and the other frameworks' approaches
- [Operator families vs Flux](../../../themes/node-graphs/operator-families-vs-flux.md) — text row, including cables' MSDF font
