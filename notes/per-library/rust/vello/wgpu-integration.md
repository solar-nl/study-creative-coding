# Vello GPU: Embedding a Renderer That Wants Its Own Passes

> `vello_gpu` will draw into your texture, on your encoder, on your device. It will not draw inside your render pass.

## Key Insight

> **The contract in one sentence:** the host owns the device, queue, encoder, target view and submit; vello owns every render pass it opens on that encoder, plus all the GPU state behind them, so it fits a frame graph as a node that consumes an encoder, not as a callback that receives a pass.

## The Problem: A Host With a Frame Graph Meets a Library With Opinions

Picture Flux mid-frame. It owns the `wgpu::Device`, the `Queue`, the surface and a frame graph that decides which passes run in what order. A 3D scene has just drawn into the swapchain texture, and now the app wants crisp vector UI on top: paths, strokes, gradients, text. The obvious move is to ask the vector library for a draw call you can drop into the pass you already have open.

Vello does not offer that. It flattens and tiles paths on the CPU (see [code-traces/fill-path.md](code-traces/fill-path.md)), then needs its own pipelines, its own bind groups, a couple of data textures and sometimes intermediate layer textures. Those pieces interact: a blended layer needs a different render target than the root, so the renderer has to start and stop passes itself. That is the price of embedding a renderer that owns its pipelines, and this note maps what it costs a host and what it does not.

Think of the host's `CommandEncoder` as a shared notebook. Vello can write whole new pages in it (passes), and it can read from or write to any texture you hand it. It cannot write a line inside a page you are halfway through filling in. If your frame graph treats "a pass" as the unit of work, vello is a node that appends several pages and returns the notebook.

The questions a host has to answer before embedding are concrete. What must I create and pass in? What does vello assume about my device? What formats does it force on me? How much data crosses to the GPU each frame? Where does it panic instead of returning an error? Let's go through them in that order.

All paths below are relative to the vello submodule root (`libraries/rust/vello/`) at commit `65338c25`. The render entry, scheduler and pass internals are already traced in steps 7, 10 and 11 of the [fill-path trace](code-traces/fill-path.md#7-render-entry-rendererrender-and-render_scene); this note does not repeat them.

## The Contract at a Glance

Construction is a two-step affair. You build a `Renderer` and a `Resources` bundle together, then call `render` once per frame. The table lists what each piece means for the host.

| Item | Signature or type | What the host must know |
|------|-------------------|-------------------------|
| Construct | `Renderer::new(&Device, &RenderTargetConfig) -> (Renderer, Resources)` (`vello_gpu/src/render/wgpu/mod.rs:252`) | `new_with` (:257) adds `RenderSettings` (SIMD level, memory settings, optional pipeline cache). Pipelines compile here for one target format. |
| Target config | `RenderTargetConfig { format, width: u16, height: u16 }` (:86) | `format` is the host's target format and feeds the root pipelines (:1397). |
| `scene` | `&Scene` | Pure CPU recording. Rendering only reads it. |
| `resources` | `&mut Resources` (`vello_gpu/src/resources.rs:17`) | Image cache and glyph state. Documented as usable only with the renderer that made it. |
| `device`, `queue` | `&Device`, `&Queue` | Yours. Vello creates buffers and textures on the device and stages uploads on the queue. |
| `encoder` | `&mut CommandEncoder` | Yours. Vello opens passes on it. |
| `render_size` | `&RenderSize { width: u16, height: u16 }` (`vello_gpu/src/render/common.rs:230`) | Size of the target in pixels. Must match depth view extents. |
| `view` | `&TextureView` | The color target. |
| `depth_view` | `Option<&TextureView>` | `None` skips the depth buffer. `Some` must be `Depth24Plus`, same size as `render_size`, one sample, `RENDER_ATTACHMENT` (doc :336-340). |
| `texture_bindings` | `&TextureBindings` | Map from `TextureId` to your own texture views. Pass `TextureBindings::new()` when the scene has none. |
| `target_init` | `TargetInit<ClearSettings>` | `SrcOver` keeps what is in the target. `Clear(..)` clears first (`vello_common/src/target.rs:8`, alias at `vello_gpu/src/render/common.rs:55`). |
| Result | `Result<(), RenderError>` | See below. |

The full `render` signature sits at `vello_gpu/src/render/wgpu/mod.rs:346`. The depth helper `Renderer::create_depth_texture_view(device, &RenderSize)` (:309) builds a view that satisfies the depth rules, so you do not need to hand-roll one.

### What `RenderError` Can Tell You

`RenderError` (`vello_gpu/src/lib.rs:154`) is `#[non_exhaustive]` and has six variants, all about resources you supplied or the scene demanded:

| Variant | Meaning |
|---------|---------|
| `AtlasError` | An image atlas allocation failed. |
| `MissingTextureBinding(TextureId)` | The scene references a `TextureId` that has no entry in `TextureBindings`. |
| `TextureFeedbackLoop(TextureId)` | A bound texture aliases the active render target. |
| `UnsupportedExternalTextureSampling(TextureId)` | An external texture was sampled with a mode it does not support (see the images section). |
| `MissingImage(ImageId)` | An image paint references an image never uploaded. |
| `IntermediateTexture(..)` | A layer needs a texture larger than `max_texture_size`, or more textures than `max_textures` allows (`TooLarge`, `LimitReached`, :180-205). |

That is a good set: every error is a host mistake or a configured budget, and none requires a device-lost recovery path. It is also incomplete, as the limits section shows. Several unsupported inputs panic instead of landing here.

## Who Opens Passes, and Who Submits

You might expect `render` to resemble `fn draw(&self, pass: &mut RenderPass)`. It does not. Vello calls `begin_render_pass` on your encoder in several places: the main strip pass (`vello_gpu/src/render/wgpu/mod.rs:2979`), a full-target clear (:2823), the blend-to-scratch pass (:3120) and the clear-rects pass (:3286). Each pass has its own attachments, its own load op and its own bind groups. A pass you already opened cannot take part, because wgpu only allows one open pass per encoder at a time, and because vello needs attachments you do not know about, such as its layer textures.

Submission works the other way. `render` never calls `queue.submit`. The one `submit` in this file sits in `render_to_atlas` (:433, `#[doc(hidden)]`), which creates its own encoder (:443) and submits at :481 so atlas content lands before the next `render`. That function is internal plumbing, but there is a catch for text users: `render` itself calls `resources.before_render` under `#[cfg(feature = "text")]` (:359-387), and its first closure calls `render_to_atlas`. The submit is conditional. `before_render` (`vello_gpu/src/text.rs:98-114`) only reaches that closure from `replay_pending_atlas_commands` (:75-96), which does nothing unless glyph resources exist and a glyph atlas page has pending commands. Each such page triggers one `render_to_atlas` call, so one submit. Frames where every glyph is already cached, and builds that never draw text, submit nothing. The follow-up glyph uploads (:118-125) go through `write_to_atlas` on your encoder and do not submit. In practice, with the `text` feature, a frame that rasterizes new glyphs may submit one or more small command buffers on your queue before `render` returns.

### The Load Op Is the Only Knob You Get

Because vello owns the pass, your only say over what happens to existing pixels is `TargetInit`. `init_root_clear` (:2796-2808) maps it as follows:

| `TargetInit` | Pass load op |
|--------------|--------------|
| `SrcOver` | `LoadOp::Load`. Vello composites over what is there. |
| `Clear(ClearSettings::Viewport { color })` | `LoadOp::Clear(color)` on the first root pass. |
| `Clear(ClearSettings::Rects { color, rects })` | A separate clear-rects pass, then `Load`. |

The `Clear` doc (`vello_common/src/target.rs:12-15`) adds a subtlety: the clear color is an isolated background. The scene composites on top of it, and it does not become the backdrop for blend modes inside the scene. If a scene draws nothing but you asked for `Clear`, `finish_root_clear` (:2810) still opens a pass just to clear.

For the 3D-plus-overlay case, `SrcOver` is the right choice. Your own 3D pass already cleared and drew into the target; vello's first root pass loads those pixels and blends over them.

### One `render` Per Submit

There is a sharper edge in the comment above `render_to_atlas` (:424-428): the shared GPU resources are "staged by `queue.write_*` and only applied on the next `queue.submit`". Vello writes the alpha texture, paint textures and the strips arena through `queue.write_texture` and `write_buffer_with` (:2595, :2762), and the arena cursor resets every frame (`begin_frame`, :1081-1083). I did not run it, but this implies that two `render` calls recorded on one encoder before a submit would overwrite each other's staged data: the second call's uploads land before the first call's passes execute. Plan on one `render` per submit, or one `Renderer` per overlay you want in the same submit.

## What Your Device Has to Offer

The pleasant surprise is how little vello asks for.

- **Features:** none required. The native examples request `Features::empty()` (`vello_gpu/examples/render_to_file.rs:56`, `vello_gpu/examples/winit/src/render_context.rs:204`), as do the web ones (`vello_gpu/examples/wgpu_webgpu/src/lib.rs:71`).
- **`EXTERNAL_TEXTURE` (optional):** the renderer probes `device.features().contains(Features::EXTERNAL_TEXTURE)` at runtime (:1236) and picks a different WGSL shader when it is on (:1304-1308). Only the video example asks for it (`vello_gpu/examples/wgpu_video/src/render_context.rs:101`). The probe is gated by the `wgpu_external_texture` cargo feature.
- **`PIPELINE_CACHE` (optional):** needed only if you call `RenderSettings::with_pipeline_cache` (`vello_gpu/src/scene.rs:145-150`). The cache goes into every pipeline descriptor (:1376).
- **Limits:** vello reads `max_texture_dimension_2d` at construction (:265-269) and derives a resource texture dimension of at most 4096 (`vello_gpu/src/render/common.rs:73-80`). The strip arena grows by doubling but caps at `device.limits().max_buffer_size` (:1086).
- **WebGL2:** the wgpu example requests `Limits::downlevel_webgl2_defaults()` with the adapter's texture and buffer maximums layered on (`vello_gpu/examples/wgpu_webgl/src/lib.rs:73-77`). Separately, `vello_gpu/src/render/webgl/` is a second backend that speaks WebGL directly instead of going through wgpu. It uses shaders from `vello_gpu_shaders` (`webgl/mod.rs:91`); the README records that those shaders ship as GLSL, which I did not open.

A host with a baseline device therefore runs vello unchanged. Flux can keep its feature negotiation minimal and treat video and pipeline caching as upgrades.

## Formats: One You Choose, Everything Else Is Fixed

Vello splits formats into the one you control and the ones it hard-codes.

| Texture | Format | Source |
|---------|--------|--------|
| Your target | Whatever you pass in `RenderTargetConfig::format` | Root pipelines (:1395-1414) |
| Layer pages and scratch | `Rgba8Unorm` | `:1935`, pipeline at :1388-1393 |
| Image atlases | `Rgba8Unorm` | `:2113` |
| Alpha coverage | `Rgba32Uint` | `:2085-2100` |
| Optional depth | `Depth24Plus` | `:1340`, doc :336-340 |

Three consequences follow. First, a `Renderer` is bound to one target format. If Flux renders the overlay to an `Rgba16Float` offscreen target on one frame and to `Bgra8UnormSrgb` on another, it needs two renderers. Second, layers composite in 8-bit: intermediates are `Rgba8Unorm` even when the root is HDR, so a blend-mode layer on an HDR target quantizes. Third, I did not verify how colors map onto sRGB-encoded target formats. The pipelines use `PREMULTIPLIED_ALPHA_BLENDING` and the shader writes premultiplied color, so confirm the gamma story with a test before you ship on an sRGB surface.

### What the Depth Buffer Buys, and When to Skip It

Depth is an overdraw optimization, not a correctness feature. With a depth view, solid opaque interior spans go to a separate opaque pass that runs first (`vello_gpu/src/schedule/execute.rs:91-98`) with depth writes on and blending off (:1409-1414). Alpha-blended strips then draw with depth testing against that buffer, writes off (:1402-1407). Covered fragments get rejected early. Edge strips, which carry alpha coverage, still blend normally.

The buffer is vello's own. The first depth-enabled pass in a `render` call clears it to 1.0 and later passes load it (`depth_cleared_this_frame`, reset at :515, used at :2956-2964), so you cannot reuse the depth buffer from your 3D pass. It also needs to match the target extents exactly. Skip depth when the overlay is mostly translucent or has little overlapping opaque fill: you save a texture of `width * height * 4` bytes or so, and one pass split, and you lose little. Use it for dense, layered, opaque UI such as dashboards or maps.

## What Crosses the Bus Every Frame

The CPU does the geometry, so the GPU needs the results. Think of it as a delivery truck that leaves once per frame with a fixed set of crates. Every crate has a known shape.

| Crate | Format and size | Uploaded when | Where |
|-------|-----------------|---------------|-------|
| Alpha bytes | `Rgba32Uint` texture, 16 bytes per edge tile | Every frame, the whole buffer (rows rounded up) | `upload_alpha_texture` :2577, TODO :549-551 |
| Encoded paints | 16-byte texels of gradient, image and similar data | Every frame when the scene has any | :2622 |
| Filter data | 16-byte texels | Every frame when filters exist | :2667 |
| Gradient LUTs | RGBA8 ramps | Only when the cache changed (`has_changed`) | :2342-2346, :2702 |
| Strip instances | 24 bytes per `GpuStrip` | Every pass, into the arena | `upload_strip_pair` :2745, arena :1057-1097 |

The alpha upload rounds the buffer to whole rows of the resource texture: `rows = ceil(len / row_bytes)` (:2585-2588). It pads the tail with zeros and truncates back afterwards (:2593, :2618). The texture grows when needed, but it asserts that the required height stays within the resource dimension (:2405-2408).

### Rough Numbers for N Edge Tiles and M Strips

Let N be the number of 4x4 tiles that straddle a path edge, and M the number of strip segments (alpha and solid-span instances combined). The per-frame payload is about:

```
bytes ≈ 16 * N   (alpha texture)
      + 24 * M   (strip instances)
      + paints, filters (16 B per texel, scene dependent)
```

A UI frame with 20,000 edge tiles and 8,000 segments moves roughly 320 KB plus 192 KB, about half a megabyte. A busy 1080p map with 100,000 edge tiles moves 1.6 MB of alpha, still modest. The ceiling is the alpha texture itself: 4096 x 4096 texels at 16 bytes is 256 MiB, which is 16.7 million edge tiles. Beyond that, the height assertion at :2405 fires. The upstream TODO about chunking the upload (:549-551) points at the same limit. On a device whose `max_texture_dimension_2d` is smaller, the ceiling drops accordingly (4096 is a cap, not a floor).

### The Four Bind Groups

All draws use one pipeline layout with four groups (:1325-1329). Knowing them tells you what the host must not collide with if it ever shares layouts.

| Group | Contents | Lines |
|-------|----------|-------|
| 0 | Alpha texture (`Uint`), config uniform, layer-input texture | :1198-1233 |
| 1 | External texture slot: texture, sampler, optional `ExternalTexture` | :1239-1271 |
| 2 | Encoded paints (`Uint` texture) | :1273-1286 |
| 3 | Gradient LUT (filterable float texture) | :1288-1301 |

None of these belong to the host. They are vello-internal, built in `Programs::new`, so your frame graph never sees them. They matter for two reasons: the pass binds four groups, so a hypothetical caller-supplied pass would need to leave groups 0-3 to vello, and the limit `max_bind_groups` of 4 is the wgpu default.

## Images and External Textures: Register, Don't Upload

Suppose Flux already has GPU textures: a rendered 3D thumbnail, a video frame, a spritesheet. Re-uploading pixels through the CPU would waste the bus the previous section just measured. Vello offers two routes.

1. **Bind at render time.** Pick a `TextureId`, build `ImageSource::external_texture(id, region, may_have_transparency)` (`vello_common/src/paint.rs:137`) for your paint, and call `TextureBindings::insert(id, view)` (`vello_gpu/src/render/wgpu/mod.rs:162`) each frame. Nothing is copied. The view must be a non-array 2D view of a filterable float texture such as `Rgba8Unorm`, with `TEXTURE_BINDING`, starting at mip 0, containing premultiplied RGBA (:157-160). If the bound texture is also the render target, you get `TextureFeedbackLoop`.
2. **Copy into the atlas once.** `Renderer::upload_image(resources, device, queue, encoder, &writer)` (:614) takes any `AtlasWriter`. For a `wgpu::Texture` writer that is a GPU-to-GPU copy (:3496-3522), and for a `Pixmap` it is a direct upload. It returns an `ImageId` you reference through `ImageSource::opaque_id`. The winit example shows both, including the "you already have a texture" case, in `vello_gpu/examples/winit/src/main.rs:437-459`.

For `wgpu::ExternalTexture` (video, YCbCr), use `TextureBindings::insert_wgpu_external_texture(id, texture, width, height)` (:189). It needs the device feature, panics on zero size, and accepts only a narrow sampling mode: full texture, `Extend::Pad`, low or medium quality, no tint except opacity (:174-178). Anything else returns `UnsupportedExternalTextureSampling`.

### One External Texture Per Run

Here is a limit that surprises people. A strip draw has exactly one external-texture slot (`EXTERNAL_TEXTURE_SLOT_COUNT = 1`, `vello_gpu/src/draw.rs:450`). The scene is split into runs, and each run sets bind group 1 and draws its own instance range (`vello_gpu/src/render/wgpu/mod.rs:3018-3032`). Two different bound textures used by interleaved paints force the scheduler to split runs, which costs extra draws. A host that wants a texture-heavy overlay should prefer the atlas route for small, long-lived images and the bound route for large or changing ones such as video.

## Known Limits and Where They Bite

| Limit | Behavior | Evidence |
|-------|----------|----------|
| Mask layers | `unimplemented!` panic | `vello_gpu/src/scene.rs:686-688` |
| Destructive blend modes via `set_blend_mode` | `assert!` panic. Use clip layers instead. | `scene.rs:786-790` |
| Pre-opened pass | Not accepted. Vello always opens its own. | `begin_render_pass` sites, :2979 and others |
| Intermediate format | `Rgba8Unorm` only, so no HDR layer compositing | :1935, :1388-1393 |
| Alpha buffer ceiling | Panic when required height exceeds the resource dimension | :2405-2408 |
| Thread sharing | `Scene` holds `RefCell<StripStorage>` (`scene.rs:260`), so it is `Send` at best, not `Sync` | `scene.rs:260` |
| External sampling | Only full-texture, pad extend, low or medium quality | :174-178 |
| Multiple `render`s per submit | Likely clobbers staged uploads (inference, see above) | :424-428, :1081-1083 |

The `Sync` row is an inference from the field type: `RefCell` is `!Sync`, so any struct holding it is `!Sync`. You can move a `Scene` between threads if its other fields allow it, but you cannot share a reference across threads, so parallel recording needs one `Scene` per thread.

Panics deserve attention in a framework. Mask layers, destructive blends, zero-size external textures and oversized alpha buffers all abort instead of returning `RenderError`. A creative-coding host that forwards user content to vello needs to guard those inputs before they reach the scene.

## Embedding Sketch: 3D Frame Plus Vector Overlay

Here is what one host frame looks like with Flux's pieces and vello as the final 2D node. It strings together what the winit example does (`vello_gpu/examples/winit/src/main.rs:353-411`) with a host-owned 3D pass in front. The Scene setter names (`set_paint`, `fill_path`) come from the [fill-path trace](code-traces/fill-path.md) and are indicative. `host_*` helpers are placeholders for Flux code.

```rust
// Once, at startup: the target format comes from the host's surface config.
let (mut vello, mut resources) = Renderer::new(
    &device,
    &RenderTargetConfig { format: surface_format, width: w, height: h },
);
let mut overlay = Scene::new(w, h);
let bindings = TextureBindings::new();          // no external textures in this overlay

// Every frame:
let frame = host_acquire_surface_texture(&surface);          // host code
let view = frame.texture.create_view(&Default::default());
let mut encoder = device.create_command_encoder(&Default::default());

host_run_3d_passes(&mut encoder, &view);        // host passes: they open and close their own

overlay.reset();                                // indicative: clear the previous recording
overlay.set_paint(Color::from_rgb8(30, 144, 255));            // indicative
overlay.fill_path(&path);                                     // indicative

vello.render(
    &overlay, &mut resources, &device, &queue, &mut encoder,
    &RenderSize { width: w, height: h },
    &view,
    None,                                       // no depth: the overlay is mostly translucent
    &bindings,
    TargetInit::SrcOver,                        // keep the 3D pixels, blend on top
)?;

queue.submit([encoder.finish()]);               // host submits, once
frame.present();
```

Check the order. The 3D passes finish before `render` opens vello's passes; the target keeps its content because of `SrcOver`; and nothing is submitted until the host does it. If the frame graph has a post-process pass after the overlay, it slots in after `render` the same way, as another pass on the same encoder.

## Implications for Flux

### Adopt
- **Caller-owned encoder and submit.** `render(&mut self, .., encoder: &mut CommandEncoder, view: &TextureView, ..)` composes with any frame graph and keeps submit policy out of the library. Flux's own 2D module should copy this shape.
- **Features-empty baseline.** Vello runs on `Features::empty()` and detects extras at runtime (:1236). Flux should do the same and expose video or pipeline caching as capability flags.
- **A typed error for host mistakes.** `RenderError` variants for missing bindings, feedback loops and layer budgets give the host something to handle. Keep that style.

### Modify
- **Allow a caller-supplied pass or target-format intermediates.** A flat overlay with no layers needs zero intermediate textures (`max_textures` docs, `vello_gpu/src/scene.rs:187-188`), so a `render_into_pass(&mut RenderPass)` entry for that case would let a frame graph merge it with neighboring passes and save attachment loads on tile-based mobile GPUs. For layered scenes, let intermediates follow the target format instead of fixed `Rgba8Unorm`, so HDR hosts keep precision.
- **Make one-render-per-submit explicit.** Give uploads a per-frame staging slot (for example a staging belt, which the upstream TODO at :2761 already names) so two overlays in one encoder cannot clobber each other.
- **Let the host share depth.** Accept a host depth attachment with a documented range instead of clearing a private buffer, so Flux's 3D depth can reject overlay fragments behind geometry.

### Avoid
- **Panics for unsupported layer kinds.** Return `Unsupported` for masks and destructive blends (`scene.rs:686-688`, :786), and for oversized alpha buffers. A framework that accepts user-authored scenes cannot afford aborts.
- **Mid-frame submits hidden behind a feature flag.** Glyph atlas work that calls `queue.submit` inside `render` when new glyphs are pending (:359-387, :481) surprises hosts that schedule submissions deliberately. Record atlas work on the caller's encoder.

## Sources

- `vello_gpu/src/render/wgpu/mod.rs` — `Renderer`, `render`, `TextureBindings`, `Programs::new`, uploads, `RendererContext`
- `vello_gpu/src/lib.rs` — `RenderError`, `IntermediateTextureError`, public re-exports
- `vello_gpu/src/render/common.rs` — `RenderSize`, `ClearSettings`, `DeviceLimits`
- `vello_common/src/target.rs`, `vello_common/src/paint.rs` — `TargetInit`, `ImageSource`
- `vello_gpu/src/scene.rs` — `RenderSettings`, `LayersConfig`, `Scene`, `push_layer`, `set_blend_mode`
- `vello_gpu/src/draw.rs`, `vello_gpu/src/schedule/execute.rs`, `vello_gpu/src/resources.rs`
- Examples: `vello_gpu/examples/{render_to_file.rs, winit/, wgpu_webgl/, wgpu_webgpu/, wgpu_video/}`
- Companion notes: [code-traces/fill-path.md](code-traces/fill-path.md), [README.md](README.md), [wgpu notes](../wgpu/README.md)

*Part of the [Vello study](README.md). Not opened: `render/webgl/` GLSL, `GpuStrip` layout (taken from the fill-path trace).*
