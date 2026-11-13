# Vello Paints and Layers: What a Shape Is Filled With, and How Shapes Stack

> One instanced draw call paints solid colors, gradients, images and video frames. A second, separate mechanism decides which of your shapes get their own texture.

## Key Insight

> **The core idea:** `vello_gpu` splits "what is this shape filled with" from "how do shapes combine." Paints are tiny records. Every strip instance carries a type tag plus an index into one shared paint texture, so a single pipeline paints everything. Layers are the expensive escape hatch, and vello avoids them whenever a clip, a transform or a plain fill can do the job on the CPU for free.

This document picks up where [code-traces/fill-path.md](code-traces/fill-path.md) stops. That trace follows one solid-colored path to pixels and mentions the paint and layer machinery in passing. Here we open both boxes. For how the scheduler orders layer passes into rounds, see [cpu-gpu-split.md](cpu-gpu-split.md).

## The Problem: Many Kinds of Fill, One Draw Call, No Texture Per Layer

Consider what a 2D renderer must support. A rectangle might be filled with `#1e90ff`. The next shape might use a three-stop radial gradient. After that comes a photo, then a frame from a video decoder that lives in a texture the renderer does not own. The shapes interleave in painter's order, and the renderer wants to draw as many of them as possible in one instanced call (see the instancing in the fill-path trace).

The naive design switches pipelines per paint type: one shader for solid, one for linear gradient, one for images. Every switch breaks the batch, flushes state and costs a draw call. A scene with alternating gradients and images degrades into thousands of tiny passes.

Compositing creates a second, separate problem. Designers expect clips, group opacity, blend modes like multiply, and filters like blur or drop shadow. Group opacity is the classic trap: you cannot multiply each child's alpha by 0.5 and get the right answer, because overlapping children would show through each other. The group must render to its own surface first, then composite once. The naive design allocates a texture per group. A UI with hundreds of translucent panels then burns memory and bandwidth, and mobile GPUs suffer most.

Vello answers both problems with the same trick: push decisions to where they are cheapest. Paint choice becomes data in a texture, so the shader branches per fragment instead of the CPU switching pipelines. Compositing becomes a scheduling problem over a small number of recycled textures, and many cases need no texture at all.

## The Mental Model: A Swatch Book and Tracing Paper

Think of a print shop. The shop owns a **swatch book**: one big bound volume where each page holds a recipe (a flat color, a gradient ramp, a photo crop). A worker stamping shapes onto a poster never carries recipes around. Each stamp only says "use page 37." That is the paint model. Every strip instance holds a page number and the type of page, and the fragment shader opens the book.

Compositing works like tracing paper and masking tape. **Masking tape** (a clip) covers part of the poster before you paint. It costs nothing extra, because you simply never paint under the tape. **Tracing paper** (a layer) is a separate sheet. You paint on it, then lay it over the poster with some transparency. Sheets cost real material, so a sensible shop uses tape whenever tape is enough and keeps a few reusable sheets for the jobs that truly need them.

The rest of this document traces that model through the code: the paint API, the encoding step, the shader, images, then layers, blends and filters.

## How the API Models "What to Fill With"

`Scene` keeps all drawing style in one `RenderState`, so every draw call reads it instead of taking paint arguments. This is the same global-state style Processing and p5.js use, which keeps the call site short.

**File:** `vello_common/src/render_state.rs:14`

The state holds the paint, stroke, fill rule, blend mode, an optional tint and the transforms. The defaults at `:29` are a black solid paint, a 1px bevel-joined butt-capped stroke, non-zero fill, `Mix::Normal` with `Compose::SrcOver`, and no tint (`:30-44`). Out of the box, `fill_path` draws opaque black with normal blending, and nothing allocates a layer.

The `Scene` setters in `vello_gpu/src/scene.rs` mutate that state:

| Setter | Line | Effect |
|--------|------|--------|
| `set_paint` | :816 | Replaces the paint (solid, gradient or image); asserts the paint and tint combination is supported |
| `set_tint` / `reset_tint` | :825 / :832 | Optional tint for image paints |
| `set_paint_transform` | :845 | Moves the paint without moving the shape |
| `set_transform` | :860 | Moves the shape (and, by default, its paint) |
| `set_fill_rule` | :855 | Non-zero or even-odd |
| `set_stroke` | :796 | Stroke width, joins, caps |
| `set_blend_mode` | :786 | Blend mode for later draws (destructive modes panic) |

### Two Kinds of Paint on the Recorded Draw

What the draw record stores is deliberately minimal. A recorded draw does not hold a gradient or an image. It holds one of two values.

**File:** `vello_common/src/paint.rs:44`

```rust
pub enum Paint {
    Solid(PremulColor),          // inline, nothing to look up
    Indexed(IndexedPaint),       // IndexedPaint(u32): a slot in Scene::encoded_paints
}
```

Solid colors stay inline because they are the common case and need no lookup. `PremulColor` (`paint.rs:245`) stores the color twice, once as premultiplied `u8` RGBA and once as premultiplied `f32`, so the CPU renderer and the GPU path each get their preferred format without converting per draw. Premultiplied means the RGB channels are already multiplied by alpha. Blending then becomes `src + dst * (1 - src_alpha)`, with no per-pixel divide, and interpolation between translucent colors stays well behaved. (The color theme note at [color-systems.md](../../../themes/core/color-systems.md) covers color spaces and blend modes but not premultiplication; this document is where the study first records it.) `PremulColor` also answers `is_opaque()` (`:275`), which the draw encoder uses to route opaque spans into the depth pass.

`IndexedPaint` (`paint.rs:21`) is a `u32` wrapped in a struct. The source comment explains why: the team may add flags later and does not want to break the API (`:16-19`).

### Where Paints Come From, and What Else the Image Variant Carries

A user-facing `PaintType` is `peniko::Brush<Image, Gradient>` (`paint.rs:319`), so you set a solid color, a gradient or an image through the same `set_paint` call. Images use `ImageSource` (`paint.rs:89`), which has three variants.

| Variant | Meaning | Who owns the pixels |
|---------|---------|--------------------|
| `Pixmap(Arc<Pixmap>)` | Pixels travel with the scene | Scene (CPU renderer only; the GPU renderer panics on it, see below) |
| `OpaqueId { id: ImageId, .. }` | Handle to an image registered earlier (`ImageId`, `:59`) | Renderer's image atlas |
| `ExternalTexture { id: TextureId, source_region, .. }` (`:100`) | A texture the host supplies at render time | Host application |

`TextureRegion` (`:80`) says whether to sample the whole external texture (`Full`) or a rectangle (`Rect`). The doc comment tells you to prefer `Full`, because it takes a faster shader path (`:74-79`). Each variant also carries a `may_have_transparency` hint. An image known to be opaque can join the depth-tested opaque pass. When in doubt, `ImageSource::opaque_id` assumes transparency (`:116-121`).

Image paints also accept a `Tint` (`paint.rs:311`) with a `TintMode` (`:288`). `AlphaMask` fills the tint color wherever the image has alpha, which is how monochrome glyph images get colored. `Multiply` multiplies every channel and suits full-color images.

## Why the Paint Transform Is Separate From the Path Transform

Here is a design choice that looks small and pays off in practice. The scene keeps two transforms, and the formulas sit in `vello_common/src/transforms.rs`.

**File:** `vello_common/src/transforms.rs:109`

```rust
fn effective_path_transform(&self, t: &Transforms) -> Affine {
    self.root_transform() * t.transform                       // shape geometry
}
fn effective_paint_transform(&self, t: &Transforms) -> Affine {
    self.effective_path_transform(t) * t.paint_transform      // :114
}
```

`Scene::effective_path_transform` (`scene.rs:310`) and `effective_paint_transform` (`:315`) wrap these two. The paint transform starts from the path transform and then applies one more affine on top. By default the paint follows the shape: rotate a rectangle and its gradient rotates with it. That matches what you expect from a vector editor.

The extra `paint_transform` lets you decouple them. Animate a rotating star while its gradient stays pinned to the screen, or scroll a texture across a stationary shape, or keep a hatch pattern at a fixed angle while the shape spins. In a renderer where paint is baked into geometry coordinates, you must counter-rotate the paint yourself and hope the math is right. Here you call `set_paint_transform` (`scene.rs:845`) and the encoder folds it in.

Note the asymmetry that the source comment calls out (`transforms.rs:71-73`): clip paths use `clip_path_transform`, which skips the root transform, because clipping handles root viewport shifts separately.

## Encoding: Turning a Gradient or Image Into One Index

Solid paints skip this section entirely. For everything else, the scene encodes the paint at draw time.

**File:** `vello_gpu/src/scene.rs:328`

`encode_current_paint` reads the effective paint transform and branches on the paint type. A solid becomes `Paint::Solid(PremulColor::from_alpha_color(..))` immediately (`:335`). A gradient or image calls `encode_into` (`:336-339`), which appends an `EncodedPaint` to `Scene::encoded_paints` (`:258`) and returns `Paint::Indexed` pointing at it.

Every encodable type implements the `EncodeExt` trait (`vello_common/src/encode.rs:55`). Its contract is worth reading closely.

**File:** `vello_common/src/encode.rs:55-67`

`encode_into(paints, transform, tint) -> Option<Paint>` returns `None` when the transform is not invertible. A singular matrix squashes the paint onto a line or a point, so it can cover no pixels. `fill_path` checks `paint_has_area()` first (`scene.rs:353`) and exits early, so a skipped draw never leaves behind an empty blend layer (`:343-347`). Returning `Option` instead of panicking is a good pattern for Flux.

An encoded paint has three shapes (`encode.rs:540`):

| Variant | Carries |
|---------|---------|
| `Gradient(EncodedGradient)` (`:804`) | A kind (`EncodedKind`, `:783`: linear, radial, sweep), the inverse transform, per-pixel advances, color ranges, extend mode, a cache key |
| `Image(EncodedImage)` (`:584`) | Source, sampler, the transform, and x/y advance vectors |
| `BlurredRoundedRect(..)` | An analytic shadow primitive, covered at the end of this document |

The **advance vectors** (`x_advance`, `y_advance`) record how far paint space moves when you step one pixel right or down. The CPU renderer uses them to walk across a scanline incrementally. They are the reason the encoder precomputes the inverse transform once instead of per pixel.

### The Gradient Ramp: Evaluate Once, Look Up Forever

A gradient with three stops, an interpolation color space and a hue direction could be evaluated per fragment, but the work is expensive and repeats for every pixel. Vello evaluates it once, into a lookup table (LUT), and then each fragment only needs a position `t`.

`EncodedGradient` carries a `cache_key` built from the color-affecting properties only (`GradientCacheKey`, `encode.rs:845`): the stops, the interpolation color space, the alpha space and the hue direction. Geometry is deliberately absent from the key. Two gradients with identical colors but different positions share one ramp. `GradientLut` (`encode.rs:1068`) stores the sampled colors and a scale factor. Its size grows with stop count, following the Blend2D scheme noted in the source (256 entries for two stops, 512 for three, 1024 for four or more, `:1181-1184`), capped by `MAX_GRADIENT_LUT_SIZE = 4096` (`:1176`).

On the GPU side, `GradientRampCache` (`vello_gpu/src/gradient_cache.rs:56`) turns that into one shared texture.

**File:** `vello_gpu/src/gradient_cache.rs:75`

`get_or_create_ramp` takes an `EncodedGradient` and returns `(start, width)`. If the key is already cached, it bumps an epoch counter for LRU tracking and returns the existing location (`:79-82`). Otherwise it appends a new LUT to one packed byte vector, marks the cache as changed so the texture is re-uploaded, and records the position (`:85-93`). The packing is `Rgba8Unorm`, four bytes per texel (`:12-15`). A `maintain` call evicts least-recently-used entries beyond `retained_count` and compacts the vector (`:97-103`, `:136`).

So a thousand shapes with the same gradient cost one ramp. A gradient whose stops animate every frame produces a fresh ramp every frame, which is the cost to watch for.

## From Encoded Paint to GPU Table

At render time `Renderer::prepare_gpu_encoded_paints` converts each scene-side `EncodedPaint` into a `GpuEncodedPaint`.

**File:** `vello_gpu/src/render/wgpu/mod.rs:768`

For each paint it runs a `match` (`:782-833`). Image paints with `OpaqueId` look up the atlas location in the `ImageCache` (`:784-787`). External textures look up their binding and fail with `RenderError::MissingTextureBinding` if the host forgot to register it, or `TextureFeedbackLoop` if the host passed the render target itself as a source (`:791-802`). Gradients call `get_or_create_ramp` (`:826-828`). The loop also records each paint's starting texel in `paint_idxs`, accumulating `size_texels()` (`:835`).

Notice what the code does with the CPU-only variant: `ImageSource::Pixmap` panics with "pixmap image sources are not supported by Vello GPU" (`:821-823`). The GPU renderer requires images to be registered first, which fits its "hand the GPU handles, not pixels" design.

The GPU-side enum is `GpuEncodedPaint` (`vello_gpu/src/render/common.rs:307`): `Image`, `NativeImage`, `WgpuExternalTexture`, `LinearGradient`, `RadialGradient`, `SweepGradient`, `BlurredRoundedRect`. A `const fn texels::<T>()` asserts at compile time that every struct is a whole number of 16-byte texels (`common.rs:325-332`). That constraint exists because the paints upload into a single `Rgba32Uint` texture (`upload_encoded_paints_texture`, `mod.rs:2622`): it computes how many rows are used, serializes the structs into a byte buffer and calls `queue.write_texture`. One texture, one upload, and every paint type fits in it.

This is the swatch book from the mental model. Each page occupies one or a few texels. The strip instance only needs the starting texel, which fits in 24 bits.

## What the Shader Sees

The paint type and index ride along in the 32-bit `paint_and_rect_flag` field of every `StripInstance`. The shader source documents the layout in a comment block.

**File:** `vello_gpu_shaders/shaders/render.wesl:115-131`

Bit 31 marks rect strips, bits 29-30 pick the **color source** (payload or layer texture), and for payload sources bits 26-28 hold the paint type while bits 0-23 hold `paint_texture_idx`. The type constants are at `:60-67`: solid, image, linear, radial, sweep, blurred rounded rect, native image and wgpu external texture. A layer-sourced instance repurposes the low bits as an 8-bit opacity.

Let's trace how a radial-gradient strip becomes pixels.

1. **CPU:** `encode_current_paint` appends an `EncodedGradient` and returns `Paint::Indexed(i)`.
2. **Render time:** `get_or_create_ramp` finds the LUT at texel `start`, and the gradient's struct (transform, extend mode, LUT start and width) lands in the paint texture at texel `paint_idxs[i]`.
3. **Draw encoding:** `GpuStrip` is created with paint type 3 and index `paint_idxs[i]` in `paint_and_rect_flag`, and `payload` set to the strip's scene-space position (see step 9 of the fill-path trace).
4. **Vertex stage:** `get_gradient_sample_xy` reads the transform from the paint texture and maps the quad's corner positions into gradient space. The result goes out as `sample_xy` (`render.wesl:325-335`).
5. **Fragment stage:** the interpolated `sample_xy` feeds `sample_radial_gradient` (`:450-458`), which turns the position into a `t` value, applies the extend mode and does one `textureLoad` into the ramp texture (`helpers/gradient.wesl:155-174`).
6. **Output:** `alpha * final_color` (`:487`), where `alpha` is the strip's coverage.

The vertex stage does the heavy affine math, and the fragment stage mostly interpolates and looks up. Because `sample_xy` is linearly interpolated across a quad, this works for affine transforms. The fragment stage then takes over the non-linear parts, like the radial square root.

**File:** `vello_gpu_shaders/shaders/render.wesl:405-487`

The fragment shader is one `switch` on `paint_type`. Solid is `unpack4x8unorm(payload)` (`:413`). Native images sample the host texture through a hardware sampler (`:414-421`). Linear, radial and sweep gradients call their sampler helpers. A layer source evaluates `layer_opacity * textureLoad(layer_input_texture, vec2<i32>(sample_xy), 0)` (`:480-482`), which is how a finished child layer returns to its parent as ordinary strips. Anything unrecognized falls through to `default {}`, and a bad color source outputs transparent black (`:483-485`).

You might wonder whether a branch per fragment is slow. The branch condition is `flat` interpolated, meaning identical for every pixel of a strip, so GPU warps take the same path and divergence stays minimal. This is the payoff of keeping paint type in the instance instead of the pixel.

Two details deserve a flag. First, `sample_gradient_lut` fetches one texel with `textureLoad` and no filtering (`gradient.wesl:165-172`), so a coarse LUT shows as banding. That explains the 256-to-1024 sizing. Second, the shader returns the LUT or image color unchanged and multiplies by coverage. For the output to be right the sampled colors must already be premultiplied, which holds for solids (stated in the fill-path trace) and, by that same contract, must hold for the LUTs and atlas pixels. I did not open `generate_gradient_lut_impl` to confirm the gradient case.

### Compile-Time Feature Gates

The shader source marks optional cases with `@if(feature)`: `gradient_sweep` (`:336`, `:459`), `full_image_support` (`:296`, `:431`), `blurred_rounded_rect` (`:348`, `:469`) and `texture_external` for wgpu external textures (`:422`). WESL strips disabled branches before WGSL generation. The payoff is smaller shaders and faster compile times on constrained targets. `vello_gpu/README.md` lists the Cargo features (`:48-65`). Notably, with `full_image_support` off, only external textures sampled with `TextureRegion::Full` plus nearest or bilinear filtering and opacity work. Turning it on adds uploaded images, glyph atlas caching, bicubic sampling, cropped external textures and tints. The fast path `PAINT_TYPE_NATIVE_IMAGE` stays available either way, and it skips the paint-table reads for transform decoding that the full path needs.

## Images and External Frames

Images arrive by two routes: uploaded into atlases, or borrowed from the host.

**Atlas route.** `ImageCache` (`vello_common/src/image_cache.rs:46`) keeps a `slots: Vec<Option<ImageResource>>` and a free list, backed by a `MultiAtlasManager`. An `ImageResource` (`:17`) records width, height, atlas id, offset and padding. The padding is transparent pixels around each image so bilinear and bicubic sampling at the edge do not bleed into neighbors; the shader reads it back from `image_padding` (`mod.rs:864`). Many small images share a few big atlas textures, so drawing different sprites rarely changes a bind group. `Resources` (`vello_gpu/src/resources.rs:17`) owns the `ImageCache`, plus glyph caches behind the `text` feature, and lives across frames so uploads persist. I skimmed `multi_atlas.rs` only for its role.

**External route.** A host that already has a texture (a video frame, a render-to-texture result) calls `TextureBindings::insert` (`render/wgpu/mod.rs:162`) with a `TextureView`. The view must be a non-array, filterable 2D view with `TEXTURE_BINDING` usage, and only mip level 0 is read (`:157-160`). For hardware video formats, `insert_wgpu_external_texture` (`:189`) takes a `wgpu::ExternalTexture`, so wgpu applies the YCbCr conversion and sample transform. That requires `Features::EXTERNAL_TEXTURE`, panics on a zero size, and supports only full-texture pad-extend sampling with low or medium quality (`:169-185`). Anything else returns `RenderError::UnsupportedExternalTextureSampling`.

**One slot per run.** Here is the gotcha for scene authors. The renderer binds at most one external texture per strip draw: `EXTERNAL_TEXTURE_SLOT_COUNT` is `1` (`vello_gpu/src/draw.rs:450`), and `get_or_insert` returns `None` when the single slot already holds a different source (`:466-479`). A scene that alternates two video frames therefore splits into runs, each drawn with its own bind group (the sub-range draws at `mod.rs:3021-3032` in the fill-path trace). The more often your paint sources interleave, the more draws you get. Group same-source shapes when you can.

## Clips Versus Layers: Tape Versus Tracing Paper

Now the second problem. Vello offers two ways to restrict drawing to a region, and choosing between them is the most important performance decision in the compositing API.

### Non-Layer Clips: Strips on the CPU

**File:** `vello_gpu/src/scene.rs:402`

`push_clip_path` converts the path with `clip_path_transform` and hands it to `viewport_state` (`:403-409`). `push_clip_rect` tries a fast axis-aligned path first and falls back to a path clip (`:413-421`). `pop_clip` pops (`:427`). The doc comment adds that unlike layers you may leave clips open when you finish (`:423-426`).

Nothing here touches the GPU. When a later draw generates its strips, `render_with_clip` renders them to temporary storage and calls `intersect` (`vello_common/src/clip.rs:393`), as the fill-path trace shows. `intersect` walks both strip lists in lock step. Two filled spans give a filled span, a strip and a fill copy the strip's alpha, and two strips combine their alpha masks (`clip.rs:402-410`). The output is again a list of strips, so the GPU draws a clipped shape exactly like an unclipped one. That is the masking tape: the clip costs CPU time proportional to the strips involved and zero extra GPU passes, textures or bandwidth.

The limit is semantic. A clip applies per draw. It cannot make a group of overlapping shapes behave as one unit, so it cannot express group opacity, a blend mode over a group, or a filter.

### Layers: Tracing Paper

**File:** `vello_gpu/src/scene.rs:678`

`push_layer(clip_path, blend_mode, opacity, mask, filter)` opens an isolated group that is composited as a whole when you call `pop_layer` (`:773`). Everything drawn in between renders into an intermediate texture, and the scheduler later composites it into the parent. Walking the body:

- **Mask:** if `mask.is_some()` the function hits `unimplemented!("mask layers are currently not supported")` (`:686-688`). Mask layers are not implemented in this commit.
- **Filter:** a filter creates `FilterData` from the layer transform and pushes a relative root transform plus a root viewport, so the layer renders into a tight bounding box (`:692-703`).
- **Clip path:** the layer's clip is generated into strips once, intersected with any existing clip, and stored as a `LayerClip` with a bbox and strip range (`:705-727`). A layer clip is not applied per draw. It applies once, when the finished layer composites back.
- **Record:** `LayerProps { blend_mode, opacity, mask: None, clip_path }` goes to the recorder (`:729-737`). Nothing renders yet.

Convenience wrappers make the common cases readable: `push_clip_layer` (`:744`), `push_blend_layer` (`:749`), `push_opacity_layer` (`:754`), `push_mask_layer` (`:763`, always panics) and `push_filter_layer` (`:768`).

### Choosing Between Them

| Need | Mechanism | GPU cost |
|------|-----------|----------|
| Cut shapes to a region | `push_clip_path` / `push_clip_rect` | None extra; CPU strip intersection |
| One translucent shape | Solid paint with alpha | None |
| Overlapping shapes fading together | `push_opacity_layer` | Intermediate texture and a composite |
| Destructive or group blend mode | `push_blend_layer` / `push_clip_layer` | Intermediate texture and a blend pass |
| Blur, shadow, offset, flood | `push_filter_layer` | Atlas region plus several filter passes |
| Single fill with non-default blend | `set_blend_mode` | An automatic one-shape layer (next section) |

### The Hidden Layer: A Blend Mode Set on the State

Setting a non-default blend mode and then calling `fill_path` looks like a plain draw, but it is not. `with_optional_filter_or_blend_layer` (`scene.rs:879`) checks the state before every fill, stroke and blurred rect.

**File:** `vello_gpu/src/scene.rs:879`

```rust
let blend_mode = (blend_mode != BlendMode::default()).then_some(blend_mode);
let filter = self.filter.clone();
if blend_mode.is_some() || filter.is_some() {
    self.push_layer(None, blend_mode, None, None, filter);   // wrap this one draw
    let result = f(self);
    self.pop_layer();
    result
} else { f(self) }                                           // common case: no layer
```

So `set_blend_mode(multiply)` followed by 500 fills creates 500 one-shape layers. That is correct, but expensive. If many shapes share a blend mode, push one `push_blend_layer` around them instead, so you pay for one intermediate texture. `set_filter_effect` (`:870`) behaves the same way: it wraps each following draw in its own filtered layer.

The rule of thumb: **state setters are convenient and per-draw; layer calls are explicit and per-group.** Prefer the layer for groups.

`set_blend_mode` also asserts that the mode is not destructive (`:786-793`), because a destructive mode like `Clear` or `Src` on a non-isolated draw would erase what lies beneath. The panic message tells you to use clip layers instead.

## Blend and Filter on the GPU, Compactly

The scheduling of layer passes lives in [cpu-gpu-split.md](cpu-gpu-split.md). This section covers only what the blend and filter shaders compute.

### Blend: Two Textures In, One Composite Out

**File:** `vello_gpu_shaders/shaders/blend.wesl:14`

A `BlendInstance` (`:14-23`, CPU mirror `GpuBlendInstance` at `vello_gpu/src/blend.rs:17`) describes one quad: where it sits in the parent texture, where the child layer sits in the child texture, and a packed `blend_config` word. The shader binds two layer textures and the alpha texture (`:37-42`). Fixed-function blending cannot read the destination, and mixed modes like multiply or overlay need the backdrop in a shader, so the fragment stage loads both textures itself.

**File:** `vello_gpu_shaders/shaders/blend.wesl:80-131`

The config word packs compose mode in bits 0-7, mix mode in 8-15, an 8-bit opacity in 16-23, the parent and child texture parity in bits 24-25, and a `BLEND_HAS_ALPHA` flag at bit 26 (`:12`, `:91-97`). The fragment loads the backdrop, loads the child and multiplies it by opacity (but only inside the child's rectangle, since layers live in an atlas, `:120-126`), and calls `blend_mix_compose(backdrop, child, compose, mix_mode)` (`:128`). The final line is the layer clip:

```wgsl
return mix(backdrop, composed, clip_coverage);   // :130
```

`clip_coverage` is 1.0 unless `BLEND_HAS_ALPHA` is set, in which case the shader reads the clip strip's alpha from the shared alpha texture (`:102-115`). A clip on a layer therefore costs one extra texture read per blended pixel, and the clip strips drive the geometry of the blend quads. The shape of the clip decides which pixels run the shader at all.

### Filters: Planned Passes in an Atlas

**Files:** `vello_gpu_shaders/shaders/filter.wesl:35-51`, `vello_gpu/src/filter.rs:28`

`filter.wesl` defines four filter types (offset, flood, Gaussian blur, drop shadow, `:35-38`) and nine pass kinds (copy, flood, offset, downscale, horizontal blur, vertical blur, upscale, composite drop shadow, colorize, `:40-48`). A blur is not one pass. It runs decimation (downscale), a separable horizontal and vertical convolution, then upscale, which keeps large radii affordable. Filter parameters pack into 48-byte records stored in their own `Rgba32Uint` texture (`filter.rs:34-58`, `filter.wesl:31-33`).

Filtered layers render into an atlas with `FILTER_ATLAS_PADDING = 6` transparent texels around them (`filter.wesl:51`; the Rust side derives it from `MAX_KERNEL_SIZE / 2`, `filter.rs:28`). The padding lets every filter shader assume transparent borders instead of special-casing edges. The effect API follows the W3C Filter Effects spec, but only a slice works: blur, flood, drop shadow and offset, each used alone. Filter graphs that chain primitives, color matrices and the CSS functions like `Brightness` are listed as not yet implemented (`vello_common/src/filter_effects.rs:12-50`).

### The Analytic Shortcut: Blurred Rounded Rectangles

A box shadow is the most common blur in UI work, and a full blur layer is heavy for it. `fill_blurred_rounded_rect` (`scene.rs:588`) skips the layer. It encodes a `BlurredRoundedRectangle` (`vello_common/src/blurred_rounded_rect.rs:10`: rect, color, radius, standard deviation, an `invert` flag for inset shadows) as an `EncodedPaint::BlurredRoundedRect`, then draws a rect inflated by `2.5 * std_dev` (`scene.rs:617-618`) with that paint. The fragment shader evaluates the blurred coverage in closed form (`PAINT_TYPE_BLURRED_ROUNDED_RECT`, `render.wesl:469-477`). One draw, no intermediate texture, no passes. The costs are the restrictions: it only uses a solid color (other paints fall back to black, `:585-586`, `:605-608`) and the feature flag must be on, or the call panics (`:595-597`).

This is the same lesson as the clip: when the shape of the effect is known, replace a general mechanism with a formula.

## Comparing Paint and Layer Models

Here is how vello's design sits against the models the repo already documents. The openrndr cells were checked against `DrawStyle.kt` and the [contour-to-pixels trace](../../../per-framework/openrndr/code-traces/contour-to-pixels.md). The Processing, p5.js and PixiJS cells rest on a light check of their source and existing notes, not a full study of each compositing path. "Not checked" marks a cell nobody verified.

| | **Vello (`vello_gpu`)** | **PixiJS** | **openrndr** | **Processing** | **p5.js (Canvas 2D)** |
|---|---|---|---|---|---|
| **Fill model** | `RenderState.paint`: solid, gradient or image, set before drawing | Fill style on `Graphics`: color, texture or gradient, packaged with the path (`graphics-api.md:122`) | `drawStyle.fill` and `stroke` are `ColorRGBa?` (`DrawStyle.kt:430`, `:433`); richer fills via `shadeStyle` (`:453`) | `fill()` sets a color for subsequent shapes (`PGraphics.java:6789`) | `fill()` assigns the 2D context's `fillStyle` (`p5.Renderer2D.js:148`) |
| **How paint reaches pixels** | Tag plus index in each strip instance, read from one paint texture | Per-vertex texture ids to batch (`batching.md`) | Shader generated per `ShadeStructure`; user `ShadeStyle` code is spliced in (contour-to-pixels, step on fragment shader) | Not checked (the shape-to-pixels trace shows `g2.fill` on the Java2D path) | Browser rasterizes; no app control |
| **Paint vs shape transform** | Separate (`set_paint_transform`) | Not checked | Not checked | Not checked | Not checked |
| **Clip and mask** | Strip-intersection clips (CPU, free on GPU); layer clips; masks unimplemented | Masks and filters break batching (`batching.md:59`) | `drawStyle.clip` is a `Rectangle?` (`DrawStyle.kt:427`); stencil state in `drawStyle.stencil` (`:458`) | `clip()` and `noClip()` exist (`PGraphics.java:2029`, `:2073`); not studied further | `ctx.clip()` (`p5.Renderer2D.js:221`) |
| **Blend and group opacity** | `set_blend_mode` per draw (auto layer) or explicit layers | A blend-mode change breaks a batch (`batching.md:97-102`) | `drawStyle.blendMode` (`:446`); `drawer.isolated` scopes transforms and styles, and `isolatedWithTarget` also binds a render target (`Drawer.kt:1737`, `:1781`) | `blendMode()` (`PGraphics.java:2122`) per draw | `globalCompositeOperation` (`:380`) per draw |
| **Filters** | Layer plus passes: offset, flood, blur, drop shadow | Filters break batching (`batching.md:59`) | Not checked | `filter(PShader)` (`PGraphics.java:2005`) | `filter()` uses a helper graphics layer (`p5.Renderer2D.js:23-51`); not studied further |

Two contrasts matter. First, Canvas 2D, Processing and p5.js treat paint and compositing as pieces of mutable state, and the renderer resolves them immediately. Vello also exposes mutable state, but it *records* a draw with a paint index and defers the expensive decisions to a scheduler that can see the whole layer tree. Second, PixiJS and vello share the problem that masks and filters interrupt batching, but vello makes the cost visible in the API (`push_layer`), while PixiJS hides it behind container properties.

## Edge Cases and Gotchas

- **Masks are unimplemented.** `push_layer` and `push_mask_layer` panic if you pass a mask (`scene.rs:686-688`, `:763`). Use a clip path or a clip layer.
- **Destructive blend modes panic on `set_blend_mode`** (`:786-793`). They are only valid on isolated layers.
- **Singular transforms skip the draw silently.** The paint transform check returns early with no error (`scene.rs:353-361`).
- **Pixmap images panic on the GPU renderer** (`mod.rs:821-823`). Register images and use `ImageSource::OpaqueId`.
- **Feedback loops are detected.** Binding the render target as an external texture returns `TextureFeedbackLoop` (`mod.rs:800-801`).
- **One external texture per draw run** (`draw.rs:450`). Interleaving sources multiplies draw calls.
- **Gradient churn.** Animated stops create a new LUT each frame, while animated gradient geometry costs nothing extra because the key excludes it.
- **Per-draw hidden layers.** `set_blend_mode` and `set_filter_effect` wrap each draw in its own layer (`:879-895`).
- **Filter graphs are single-primitive.** Chained primitives and most CSS filter functions are not implemented (`filter_effects.rs:26-50`).

## Implications for Flux

**Adopt**

- **Separate paint and path transforms.** Store one affine for geometry and one extra affine for paint, composed as `path * paint`. It costs one matrix, and it enables pinned gradients, scrolling textures and stable hatch patterns without hacks.
- **Pre-encoded paints indexed from one texture.** A 3-bit "kind" tag plus a 24-bit index in the instance, with all non-solid paints serialized into a single `Rgba32Uint` texture, keeps every paint type in one pipeline. Assert at compile time that each struct occupies whole texels, as `texels::<T>()` does.
- **Content-keyed gradient ramp cache.** Key on colors and interpolation settings only, pack ramps into one texture, evict by LRU. It is cheap and shares work across thousands of shapes.
- **Clips as geometry, not layers.** If Flux paints with coverage spans, intersect clip coverage on the CPU and keep layers for group semantics.

**Modify**

- **Support masks from the start, even if slowly.** Vello's `Mask` parameter exists in the signature but panics. A first implementation can render the mask as a layer and multiply its luminance or alpha during the blend pass, reusing the `BLEND_HAS_ALPHA` slot in the blend instance.
- **Make hidden layers visible.** Flux should either log or expose a cost hint when a state setter forces a per-draw layer, or offer only the explicit group API. Per-draw implicit layers are the easiest performance trap in this design.
- **Allow more than one external texture slot** where the platform permits, or offer a helper that sorts draws by texture, because video-heavy creative scenes interleave sources.

**Avoid**

- **Panics for unsupported features.** `unimplemented!` for masks, `assert!` for destructive blends and `panic!` for pixmaps all become `Result<(), Unsupported>` in a public API. The returned `Option<Paint>` from `encode_into` shows the better model.
- **Per-fragment gradient evaluation of multi-stop colors.** Sampling a pre-baked ramp is cheaper and, with a high-enough LUT size, indistinguishable. Add filtering or a larger LUT if banding matters, since vello's `textureLoad` has no interpolation.

## Sources

All paths are relative to the vello submodule root (`libraries/rust/vello/`). Line numbers refer to commit `65338c25`.

Files opened for this document:

- `vello_common/src/paint.rs`, `render_state.rs`, `encode.rs`, `transforms.rs`, `clip.rs`, `filter_effects.rs`, `blurred_rounded_rect.rs`, `image_cache.rs`
- `vello_gpu/src/scene.rs`, `gradient_cache.rs`, `draw.rs`, `resources.rs`, `blend.rs`, `filter.rs`, `render/common.rs`, `render/wgpu/mod.rs`
- `vello_gpu_shaders/shaders/render.wesl`, `blend.wesl`, `filter.wesl`, `helpers/gradient.wesl`
- `vello_gpu/README.md`

Related notes in this study:

- [code-traces/fill-path.md](code-traces/fill-path.md), the single-fill path that this document extends
- [README.md](README.md), the plan for the vello study
- [cpu-gpu-split.md](cpu-gpu-split.md), layer scheduling, rounds and uploads
- [Color systems theme](../../../themes/core/color-systems.md), color spaces and blend modes in the other frameworks
- [PixiJS batching](../../web/pixijs/batching.md) and [graphics API](../../web/pixijs/graphics-api.md), for the comparison table

---

*This document is part of the [Vello study](README.md).*
