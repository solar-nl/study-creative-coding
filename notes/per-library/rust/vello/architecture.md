# Vello Architecture

> One repository, three renderers, and a quiet admission: the fastest design on paper was not the one most people could run.

## Key Insight

> **Vello's core idea:** Do the sequential, branchy geometry work once on the CPU in a shared crate (`vello_common`), reduce every path to sparse horizontal strips that carry coverage only at the edges, and let either a CPU rasterizer or an ordinary vertex/fragment GPU pipeline consume those strips. The original compute-shader renderer, which did all of this on the GPU, still exists, but it now lives under `research/`.

## The Problem: A Great Renderer That Only Some Machines Can Run

Picture the Vello project in 2020. Raph Levien wants a 2D renderer that beats Skia and Cairo, so he moves nearly the whole pipeline into GPU compute shaders. Flattening, binning, clipping and compositing all run in parallel, stitched together with prefix sums. On a modern desktop GPU it is spectacular.

Then someone tries to ship it. A web app wants WebGL2, which has no compute shaders. An older laptop has a driver that chokes on the resource-binding tricks. A kiosk has no GPU worth the name. A renderer built entirely out of compute shaders cannot serve any of them. The project's own research renderer says so in one sentence: "This means that Vello needs a GPU with support for compute shaders to run" (`research/vello_research/README.md:76`).

The 2020 vision document saw this coming and chose to accept it. It calls the project "a research project" in which "certain elements, especially dealing with compatibility, are a lower priority" (`research/doc/vision.md:148`). Five years later, the repository reflects the opposite priority. The production direction is a design that keeps the GPU's job small enough that any GPU, or no GPU at all, can do it. This document explains how the workspace is organized around that decision.

## The Mental Model: A Kitchen With Shared Prep and Two Serving Lines

Think of a restaurant kitchen. The prep cooks chop, season and portion everything before service. That work is delicate and sequential, and it is identical no matter how the food leaves the kitchen. Then there are two ways to serve it: a cook plates each dish by hand at the pass (the CPU renderer), or the portions go onto trays for runners who deliver them in bulk to the dining room (the GPU renderer).

`vello_common` is the prep kitchen. `vello_cpu` and `vello_gpu` are the two serving lines. The old compute renderer is a different restaurant altogether, an automated conveyor belt that does the prep and the serving with specialized machinery. It is faster when the machinery is installed and useless when it is not.

The "portion" in this analogy is a **strip**: a horizontal run of 4x4-pixel tiles where a path's edge passes through, with coverage bytes stored only for those edge tiles. Interior spans between edges carry no coverage data at all. The [fill-path trace](code-traces/fill-path.md) follows one strip from `Scene::fill_path` to pixels, so this document stays at the level of crates and responsibilities.

## Three Renderers, Two Families

The root `README.md` opens by saying the project "contains three renderer implementations with different hardware requirements and maturity profiles" (`README.md:14-16`). `ARCHITECTURE.md:3-9` groups them into two families, and this table summarizes what each one claims about itself.

| Renderer | Crate (version) | Family | Project's own status |
|----------|-----------------|--------|----------------------|
| CPU | `vello_cpu` 0.3.0 | Sparse Strips | "The most mature choice" when you need predictable CPU rendering, software rendering, or devices without a suitable GPU (`README.md:22-25`) |
| GPU | `vello_gpu` 0.3.0 | Sparse Strips | "Intended to become the primary renderer for production GPU use cases as it matures; Vello CPU is currently overall more mature" (`README.md:31-33`) |
| Compute | `vello` 0.11.0 | Compute-centric | "Remains an experimental implementation for compute-capable GPUs" (`README.md:38-40`) |

Two supporting crates complete the picture. `vello_common` 0.3.0 is the shared foundation. `glifo` 0.4.0 provides text and glyph runs for both Sparse Strips renderers (`Cargo.toml:144-148`, `ARCHITECTURE.md:41-42`).

Notice the version numbers. The three crates in the new family move together at 0.3.0, while the compute renderer sits at 0.11.0 because it has a longer release history. The workspace comment says the `[workspace.package]` version "is also used by other packages which want to mimic Vello's version", meaning `vello_encoding` and `vello_shaders` (`Cargo.toml:39-46`). The numbers tell the story of which line is old and which is new.

### The 2025 restructuring

You might remember Vello as a single compute-shader crate at the repository root. That layout is gone. The compute renderer moved into `research/`, and the Sparse Strips crates took over the root. `vello_gpu` was previously named `vello_hybrid`; its crate docs say new code should use `vello_gpu`, and no compatibility re-export exists in the repository (`vello_gpu/src/lib.rs:90-96`).

The workspace `members` list shows the new shape. Research packages are listed first (`research/vello_research`, `research/vello_encoding`, `research/vello_shaders`, `research/vello_research_tests`, `research/xtask` and the research examples), followed by the root-level Sparse Strips crates (`vello_cpu`, `vello_gpu`, `vello_common`, `vello_gpu_shaders`, `glifo`) and their tests and benchmarks (`Cargo.toml:4-37`). Web articles written before this move describe a different layout, so check dates before trusting a path.

### Why the compute-only design narrowed the audience

The compute renderer's advantage is also its constraint. `research/vello_research/README.md:68-76` explains that traditional renderers handle sorting and clipping on the CPU or through intermediate textures. Vello avoids both by using prefix sums to parallelize sequential work, "so that work can be offloaded to the GPU with minimal use of temporary buffers." The cost is the sentence quoted earlier: it needs compute shaders.

That requirement removes WebGL2 from the list of targets, because WebGL2 has no compute stage. (This is general graphics knowledge, not a claim from the repository; the research README says only that compute support is required and that WebGPU is the web path, `research/vello_research/README.md:194`.) The 2020 vision also notes that the design relied on descriptor indexing to address multiple images during fine rasterization, and that older CPU generations lack Vulkan entirely (`research/doc/vision.md:48,62`).

Sparse Strips attacks the same problem from the other side. The CPU does the work that needs flexible control flow, and the GPU receives only instanced quads and a texture of coverage bytes. The `vello_gpu` README states the payoff directly: it "supports a native WebGL2 backend and a wgpu backend without requiring compute shaders" (`README.md:28-31`). `ARCHITECTURE.md:35-37` repeats that the wgpu and WebGL2 backends "use vertex and fragment rendering rather than requiring compute shaders."

The `vello_gpu` crate docs are honest about the trade. It "does not match the compute-centric `vello` renderer's raw performance on dynamic and vector-heavy workloads", yet it performs well on images, gradients and filters, and the authors consider it slightly less mature than `vello_cpu` (`vello_gpu/src/lib.rs:64-71`).

## What `vello_common` Shares

`vello_common` describes itself as "common geometry representations, tiling logic, and other fundamental components used by both Vello CPU and Vello GPU" and warns that it "should not be used on its own" (`vello_common/src/lib.rs:7-12`). It also notes that the compute renderer "is a separate architecture and does not use this crate." The module list (`vello_common/src/lib.rs:63-93`) shows what the two renderers have in common. The next paragraphs cover the ones that matter for architecture.

**Flatten.** `flatten.rs` turns Bézier curves into straight `Line` segments. The actual flattening runs through a SIMD-dispatched implementation in `flatten_simd.rs`, which is `pub(crate)` and private to the crate (`vello_common/src/lib.rs:68-69`). The trace covers the tolerance and the NaN handling in step 3.

**Tile.** `tile.rs` ("primitives for creating tiles", `vello_common/src/tile.rs:4`) bins each line into the 4x4 tiles it crosses and sorts those tiles by row, column and line index. No pixel math happens here, only bookkeeping about which tiles each line touches. See trace step 4.

**Strip.** `strip.rs` walks the sorted tiles and computes analytic coverage, emitting `Strip` records plus a byte buffer of alphas. Edge tiles get 16 bytes each and interior spans get a flag. See trace step 5.

**Strip generator.** `strip_generator.rs` ("abstraction for generating strips from paths", `vello_common/src/strip_generator.rs:4`) is the front door that chains flatten, tile and strip. It also owns `StripStorage`, a pair of `strips` and `alphas` vectors (`vello_common/src/strip_generator.rs:18-26`), and it applies clip intersection. Both renderers call it.

**Clip and mask.** `clip.rs` manages clipping state (`vello_common/src/clip.rs:4`) and `mask.rs` implements alpha and luminance masks (`vello_common/src/mask.rs:4`). Clips resolve into strips on the CPU, so neither backend needs stencil tricks. A caveat from the trace: `vello_gpu` panics on mask layers today.

**Paint and encode.** `paint.rs` defines the paint types ("types for paints", `vello_common/src/paint.rs:4`) and `encode.rs` ("paints for drawing shapes", `vello_common/src/encode.rs:4`) converts them into a form the renderers can sample. The GPU renderer repacks the encoded paints into textures at render time.

**Record.** `record.rs` is the least obvious shared piece and the most architecturally interesting. Its module docs say that "Vello CPU and Vello GPU share a recording stage before their pipelines diverge" (`vello_common/src/record.rs:6-7`). Every draw and layer operation goes into a scene-graph-like structure first. Then each renderer turns the complete recording into its own plan: the CPU buckets commands by strip row, and the GPU schedules draws across intermediate textures and render passes (`vello_common/src/record.rs:9-13`). The doc comment sums up the design: the recording "allows each renderer to 'do their own thing' while providing a common intermediate representation" (`vello_common/src/record.rs:31-33`).

Other shared modules include `filter` and `filter_effects`, `pixmap`, `image_cache` and `multi_atlas`, `simd` (re-exporting `fearless_simd`) and `viewport`. They matter for feature work but not for understanding the layout.

## Same Strips, Different Last Mile

Both renderers feed the same strips into different back halves. The CPU renderer's docs describe it as "a 2D graphics rendering engine written in Rust for devices with no or underpowered GPUs" (`vello_cpu/src/lib.rs:8-9`). The GPU renderer's docs say the CPU "processes paths, tiles, and schedules sparse strips" while the GPU "rasterizes those strips and performs compositing" (`vello_gpu/src/lib.rs:13-15`).

| Stage | `vello_cpu` | `vello_gpu` |
|-------|-------------|-------------|
| Flatten, tile, strip | CPU, shared code | CPU, shared code |
| Plan | Buckets commands by strip row | Schedules layers into rounds of render passes |
| Rasterize and composite | CPU "fine" stage into a `Pixmap`, in `u8` or `f32` precision | GPU: instanced quads, alpha sampled from a texture |
| Parallelism | SIMD (`fearless_simd`), optional threads (`multithreading` feature) | GPU, plus SIMD on the CPU-side preprocessing |
| Output | `Pixmap` you own (`vello_cpu/src/render.rs:806`) | A `TextureView` on your `CommandEncoder` |
| Backends | One | wgpu and WebGL2 |

On the CPU side, `Scene` becomes `RenderContext` in the API, and `render` writes into a `PixmapMut` target (`vello_cpu/src/render.rs:806-845`). The fine stage "processes tiles at the pixel level" and supports a low-precision `u8` path and a high-precision `f32` path (`vello_cpu/src/fine/mod.rs:4-8`). The `u8_pipeline` is on by default for speed, while `f32_pipeline` is for accuracy and snapshot testing (`vello_cpu/src/lib.rs:84-93`).

On the GPU side, the compact strip representation "limits data transfer between" CPU and GPU (`vello_gpu/src/lib.rs:15`). `vello_gpu` splits its API the same way: `Scene` handles recording and path processing, while `Renderer` (wgpu) or `WebGlRenderer` handles GPU resources and draws (`vello_gpu/src/lib.rs:57-59`). The trace walks through that handoff.

### One schedule, several backends

The GPU side hides a design detail worth copying. The scheduler produces a pure-data plan of rounds, and a small trait executes it. Here is the trait's head, which names the pass types the executor can request:

```rust
/// A backend for executing GPU render passes.
pub(crate) trait Backend {
    type Error;
    fn opaque_draw_pass(&mut self, strips: &[GpuStrip], external_texture_runs: &[ExternalTextureRun]) -> Result<(), Self::Error>;
    fn draw_pass(&mut self, strips: RangedSlice<'_, GpuStrip>, external_texture_runs: &[ExternalTextureRun], bindings: DrawPassBindings) -> Result<(), Self::Error>;
    fn clear_pass(&mut self, target: LayerTextureId, rects: &[RectU16]) -> Result<(), Self::Error>;
    fn blend_pass(&mut self, blends: RangedSlice<'_, BlendOp>, blend_strips: &[BlendStrip], bindings: BlendPassBindings) -> Result<(), Self::Error>;
    // ... filter_pass follows
}
```

**File:** `vello_gpu/src/schedule/execute.rs:19`

(Signatures condensed onto fewer lines; see the file for the full text.) The scheduler knows nothing about wgpu or WebGL. A wgpu context and a WebGL context each implement the five operations, so the same planning code drives both. That is how one crate supports two graphics APIs without duplicating the layer-scheduling logic.

## Shader Tooling: Two Ways to Add Modularity to WGSL

WGSL has no `#include`, no conditional compilation and no real module system. Both GPU renderers needed all three, and they solved the problem differently.

### Sparse Strips: WESL, linked at build time

`vello_gpu_shaders` authors shaders in WESL, a superset of WGSL with imports and conditional compilation. Its `build.rs` states the contract: "Every top-level file in `shaders` is treated as a root module. WESL links each root with its imports" (`vello_gpu_shaders/build.rs:4-7`). The crate's description says it provides "WESL shaders linked to WGSL and GLSL for the `vello_gpu` backends" (`vello_gpu_shaders/Cargo.toml:5`).

The `shaders/` directory has root modules (`render`, `blend`, `clear`, `copy`, `filter`), plus `filters/` (`blur`, `drop_shadow`, `scale`) and `helpers/` (`alpha`, `blend`, `blurred_rounded_rect`, `extend`, `external_texture`, `geometry`, `gradient`, `image`, `math`, `paint`, `texture`, `util`). Roots import helpers with `import package::helpers::...;`.

Feature gating happens inside the imports. Here is the top of `render.wesl`, where optional capabilities decide which helper code even exists in the linked output:

```wesl
import package::helpers::alpha::sample_strip_alpha;
@if(blurred_rounded_rect)
import package::helpers::blurred_rounded_rect::{ get_blurred_rounded_rect_sample_xy, sample_blurred_rounded_rect };
@if(full_image_support)
import package::helpers::external_texture::sample_image_paint;
...
@if(gradient_sweep)
import package::helpers::gradient::sample_sweep_gradient;
```

**File:** `vello_gpu_shaders/shaders/render.wesl:26-43`

(Excerpt trimmed; `texture_external` gates `sample_wgpu_external_texture_paint` at line 35.) Each `@if(name)` is a compile-time switch, so a disabled feature removes code instead of branching around it at runtime.

The build script wires Cargo features to those switches. It calls `compiler.set_feature("gradient_sweep", cfg!(feature = "gradient_sweep"))` and similarly for `blurred_rounded_rect` and `full_image_support` (`vello_gpu_shaders/build.rs:86-91`). Then it post-processes the linked WGSL. By default the build parses the output into Naga IR, shortens declaration names and strips comments, while an `unminified` feature keeps the readable source (`vello_gpu_shaders/build.rs:4-10`, `vello_gpu_shaders/Cargo.toml:43`). With the `glsl` feature, it also uses Naga to generate vertex and fragment GLSL plus reflection metadata for WebGL2 (`vello_gpu_shaders/build.rs:193-212`).

```
                                     |-> [default] renamed/minified WGSL -|
 shaders/*.wesl -> linked WGSL ------|                                    |-> WGSL constants
                                     |-> [unminified] linked WGSL --------|
                                                                          |-> [glsl] GLSL + reflection
```

(The original diagram is in `vello_gpu_shaders/build.rs:20-28`.) One WESL source tree therefore yields a WGSL module for wgpu and GLSL for WebGL2. Authors write the shader once and let the toolchain translate it.

### Research renderer: a tiny preprocessor over plain WGSL

The compute renderer predates WESL. `ARCHITECTURE.md:98-107` explains: "Because WGSL has no built-in metaprogramming, these shaders use a small preprocessor" with two features. `#import` pulls shared code from `shader/shared`, and `#ifdef`, `#ifndef`, `#else` and `#endif` respond to definitions supplied from outside the shader. The format stays compatible with `wgsl-analyzer`.

The implementation lives in `research/vello_shaders/src/compile/preprocess.rs`. In the source, directives start with `#` (`#import`, `#ifdef`) and are handled line by line. `get_imports` reads every `.wgsl` file in `shader/shared` into a name-to-text map (`preprocess.rs:8-30`). `preprocess` keeps a stack of active-branch flags for `#ifdef`/`#ifndef`/`#else`/`#endif` (`preprocess.rs:37-125`), and splices import text in at `#import` (`preprocess.rs:126-153`). The `shader/shared/` directory holds the common modules (`bbox`, `blend`, `bump`, `clip`, `config`, `cubic`, `drawtag`, `pathtag`, `ptcl`, `segment`, `tile`, `transform`, `util`).

### Comparing the two

| Question | WESL (`vello_gpu_shaders`) | Preprocessor (`vello_shaders`) |
|----------|---------------------------|--------------------------------|
| Modularity | Named imports of individual functions, `package::` paths | Whole-file text splice by name |
| Conditionals | `@if(feature)` on imports and declarations, driven by Cargo features | `#ifdef` on definitions passed at build/run time |
| Output | Minified WGSL plus GLSL and reflection for WebGL2 | WGSL only |
| Editor story | WESL tooling | Plain WGSL, compatible with `wgsl-analyzer`, but new imports need a `.vscode/settings.json` entry (`ARCHITECTURE.md:106-107`) |
| Cost | Build-time dependency on `wesl`, pinned exactly (`vello_gpu_shaders/Cargo.toml:24-30`) | A few hundred lines of project-owned code |

The preprocessor is closer to C's `#include`: simple, easy to audit, and blind to the language. WESL is closer to a real module system: it understands names, so it can drop unused code, and that makes the WebGL2 translation possible. Sparse Strips needed that second path, and the compute renderer never did.

## Feature Flags of `vello_gpu`

Feature flags are where the GPU crate's trade-offs become explicit. The defaults come from one line: `default = ["wgpu", "wgpu_default", "text", "all_shader_features"]` (`vello_gpu/Cargo.toml:52`), and `all_shader_features` expands to the four shader features (`vello_gpu/Cargo.toml:54-59`). Each feature also forwards to a same-named switch in `vello_gpu_shaders` (`vello_gpu/Cargo.toml:60-63`).

| Feature | Default | What it buys | What it costs |
|---------|---------|--------------|---------------|
| `wgpu` | yes | The wgpu backend (`Renderer`) and the shader crate (`vello_gpu/Cargo.toml:66`) | A `wgpu` dependency |
| `wgpu_default` | yes | wgpu's default hardware backends (Vulkan, Metal, DX12) | Prevents custom wgpu feature sets; disable it, keep `wgpu`, and depend on `wgpu` yourself (`vello_gpu/Cargo.toml:67-70`) |
| `webgl` | no | A native WebGL2 backend (`WebGlRenderer`) using generated GLSL (`vello_gpu/Cargo.toml:74-80`) | `web-sys` and `wasm-bindgen` dependencies, plus the Naga GLSL build step |
| `text` | yes | `Scene::glyph_run` through `glifo` | Another crate in the tree |
| `full_image_support` | yes | Uploaded images, glyph atlas caching, bicubic sampling, cropped external textures, tints (`vello_gpu/src/lib.rs:34-38`) | Bigger shader; without it only full external textures with nearest or bilinear sampling and opacity work |
| `gradient_sweep` | yes | Sweep (conic) gradients (`vello_gpu/src/lib.rs:39`) | One more paint branch in the fragment shader |
| `blurred_rounded_rect` | yes | Analytic blurred rounded rectangles (`vello_gpu/src/lib.rs:32-33`) | Extra helper code |
| `wgpu_external_texture` | yes | A second WGSL variant of `render` with a `texture_external` binding, for video frames (`vello_gpu/src/lib.rs:40-44`) | Needs the device feature `wgpu::Features::EXTERNAL_TEXTURE` at runtime; doubles the `render` WGSL output |

The external texture feature shows how the build script keeps variants honest. When the feature is on, `TEXTURE_EXTERNAL_SHADERS` lists `render` (`vello_gpu_shaders/build.rs:36-38`), and the build links that root a second time with the `texture_external` feature set to true, storing it as an extra `RENDER_TEXTURE_EXTERNAL` constant (`vello_gpu_shaders/build.rs:103-112`, `:230-241`). GLSL always comes from the default link (`vello_gpu_shaders/build.rs:16-18`). The crate docs say the binding appears only when the device has `wgpu::Features::EXTERNAL_TEXTURE` enabled (`vello_gpu/src/lib.rs:40-44`). I did not trace the code that selects between the two WGSL constants.

You might wonder why these features exist at all, when one shader could branch on paint type at runtime. Two reasons. Web builds care about download size, and mobile GPUs care about shader complexity and compile time. A feature flag turns "do I need sweep gradients?" into a decision made once, at build time.

## The Research Renderer in One Section

Everything under `research/` belongs to the compute-centric family. `research/README.md:11-20` names the three published packages: `vello_research` (published as `vello`), `vello_encoding` and `vello_shaders`. The rest is tests, examples, `xtask` maintenance tools and `doc/`.

### How it works

A scene is encoded into compact path, draw, transform and resource buffers. Those buffers resolve into a `Recording` of GPU operations, and `WgpuEngine` uploads resources and dispatches the compute pipeline, with prefix scans parallelizing the work that traditional renderers do sequentially (`ARCHITECTURE.md:52-56`). `vello_encoding` holds the scene encoding (`encoding.rs`, `path.rs`, `draw.rs`, `clip.rs`, `resolve.rs`, plus caches for glyphs, images and gradient ramps).

`pathseg.md` explains the encoding's clever core. Path data splits into a stream of tag bytes and a packed stream of coordinates, and "an exclusive prefix sum gives the start offset of the packed encoding for each element" (`research/doc/pathseg.md:3-11`). The CPU encodes cheaply and the GPU unpacks in parallel.

### The pipeline in shader slots

`FullShaders` in `research/vello_research/src/shaders.rs:19-45` lists the compute stages the pipeline loads. Counting the struct fields gives **22** `ShaderId` slots, not the 17 you may see quoted elsewhere: 19 mandatory stages plus three optional fine-rasterization variants. Grouped by job:

| Group | Slots (`shaders.rs:20-41`) |
|-------|-----------------------------|
| Path tag prefix sums | `pathtag_reduce`, `pathtag_reduce2`, `pathtag_scan1`, `pathtag_scan`, `pathtag_scan_large` |
| Bounds and flattening | `bbox_clear`, `flatten` |
| Draw and clip trees | `draw_reduce`, `draw_leaf`, `clip_reduce`, `clip_leaf` |
| Binning and tiles | `binning`, `tile_alloc`, `backdrop`, `path_count_setup`, `path_count`, `coarse`, `path_tiling_setup`, `path_tiling` |
| Fine rasterization (optional) | `fine_area`, `fine_msaa8`, `fine_msaa16` |

The `reduce`/`scan` pairs are the prefix-sum tree: reduce summarizes blocks, scan distributes offsets. Three `pathtag` variants exist so large inputs get a deeper tree (`shaders.rs:42-44` comments that two-level dispatch is enough for the CPU path). Notice that flattening is one stage among many here, whereas in Sparse Strips it is CPU code in `vello_common`. Same job, opposite end of the bus.

### What it still offers

Per `research/doc/vision.md:22-28`, the central bet was that most steps could run in compute shaders. That lets the GPU ingest "a straightforward binary encoding of the scene," keeps the CPU side "simple and efficient," and composites inside the compute shader using vector registers rather than texture buffers. The vision also describes retained scene fragments: because the affine transform is not baked into the path encoding, one encoded path can be instanced with different transforms and the GPU applies them early in the pipeline (`research/doc/vision.md:38`).

In practice that gives you:

- **Fully dynamic scenes.** Rebuilding every frame costs an encode, not a geometry pass.
- **No per-frame CPU geometry work.** Flattening, tiling and coverage happen on the GPU.
- **Deep clip and blend nesting.** The 2023 roadmap lists "blends with almost arbitrarily deep nesting" and clip stack processing on the GPU as completed work (`research/doc/roadmap_2023.md:3`).

The `vello_gpu` docs concede the point: the compute renderer's "raw performance on dynamic and vector-heavy workloads" is higher (`vello_gpu/src/lib.rs:66-68`).

### Why it stepped back

The cost shows up in three places. First, hardware: no compute shaders, no Vello. Second, the research README still labels the crate alpha, with blur and filters, conflation artifacts, GPU memory allocation and glyph caching listed as unfinished (`research/vello_research/README.md:46-54`). Third, understandability: the 2023 roadmap admits "we often hear that the Vello design is intimidating, that it seems too much like rocket science and that it is hard to contribute to the code" (`research/doc/roadmap_2023.md:78`).

That same roadmap planned a CPU fallback "to improve testing and debuggability" and for machines without a competent GPU (`research/doc/roadmap_2023.md:48-52`). `ARCHITECTURE.md:63-65` closes the loop: CPU implementations of parts of the compute pipeline exist in `research/vello_shaders/src/cpu`, but "they do not provide a complete standalone CPU renderer. Use `vello_cpu` for that." The CPU fallback the compute design needed turned into its own renderer, and that renderer's architecture became the main line.

The `research/doc/` directory is the history: `vision.md` (the 2020 piet-gpu vision), `roadmap_2023.md`, `pathseg.md` and `blogs.md`, a reading list of Raph Levien's articles on sort-middle architecture, prefix sums and clipping (`research/doc/blogs.md:5-18`). Note that `vision.md` says it "represented the vision as of the end of 2020" (`research/doc/vision.md:3-6`).

## How the Crates Depend on Each Other

This diagram shows the Cargo dependencies that matter. Solid arrows are required, dashed ones are optional features. The workspace dependency table supplies the version numbers (`Cargo.toml:108-148`), and each crate's own `Cargo.toml` supplies the edges.

```
                    +--------------------+
                    |  glifo 0.4.0       |  text / glyph runs
                    +---------+----------+
                              |  (uses vello_common)
                              v
 +------------------------------------------------------+
 |  vello_common 0.3.0                                  |
 |  flatten -> tile -> strip -> strip_generator         |
 |  clip, mask, paint, encode, record, pixmap, simd     |
 +---------------+---------------------+----------------+
                 ^                     ^
        text?    |                     |    text?
      +----------+--------+   +--------+-----------+
      |  vello_cpu 0.3.0  |   |  vello_gpu 0.3.0   |
      |  fine raster ->   |   |  scene, schedule,  |
      |  Pixmap           |   |  Renderer /        |
      |  (SIMD, threads)  |   |  WebGlRenderer     |
      +-------------------+   +----+----------+----+
                                   |  wgpu?   |  webgl?
                                   v          v
                      +-----------------+  +-------------+
                      | wgpu            |  | web-sys     |
                      +-----------------+  +-------------+

      vello_gpu also depends (optionally, via wgpu / webgl) on:
                             +----------------------+
                             | vello_gpu_shaders    |
                             | 0.3.0                |
                             | WESL -> WGSL (+GLSL) |
                             +----------------------+
      and (optionally, via text) on glifo.

 ----------------------- research/ (separate family) -----------------------
 +--------------------+     +-----------------+     +-----------------+
 | vello 0.11.0       |---->| vello_encoding  |     | vello_shaders   |
 | (vello_research)   |---->| 0.11.0          |     | 0.11.0 (WGSL +  |
 | WgpuEngine         |---------------------------->| preprocessor +  |
 +--------------------+     +-----------------+     | CPU kernels)    |
                                                     +-----------------+
```

Dependencies stop at the box edges: nothing in `research/` touches `vello_common`. The shared base of the root-level family stays small, and each renderer's backend code stays out of it. `vello_gpu` depends on `vello_common` always, and on `glifo`, `wgpu`, `vello_gpu_shaders` and the web crates only when the feature that needs them is on (`vello_gpu/Cargo.toml:17-43`). `vello_cpu` depends on `vello_common` and `fearless_simd`, with threading crates (`rayon`, `crossbeam-channel`, `ordered-channel`, `thread_local`) only under `multithreading` (`vello_cpu/Cargo.toml:18-30,45-52`).

## Gotchas When You Read the Repository

- **Old maps mislead.** Articles and notes from before the restructuring put the compute renderer at the root and call the hybrid crate `vello_hybrid`. Trust the `README.md` and `ARCHITECTURE.md` in the checkout.
- **Maturity is not what the names suggest.** `vello_gpu` is the intended production GPU renderer, yet the docs call `vello_cpu` the more mature of the two (`README.md:31-33`).
- **Both Sparse Strips renderers still panic in places.** `vello_cpu` panics on complex filter graphs (`vello_cpu/src/lib.rs:107-108`), and `vello_gpu` on mask layers, complex filter graphs and some non-isolated blend modes (`vello_gpu/src/lib.rs:75-77`). Experimental features, such as glyph caching, are labeled as such in method docs.
- **Line numbers belong to one commit.** All `file:line` references here refer to `65338c25`; see `notes/SUBMODULE-PINS.md`.

## What Flux Can Take From This Layout

**Adopt**
- **A shared CPU core with swappable backends.** One crate computes strips, and thin renderers consume them. Flux can start with a single GPU consumer and keep the door open for a software one used in tests and headless export.
- **A backend-agnostic `Backend` trait for execution.** Plan the work as pure data and hand it to a small trait (`vello_gpu/src/schedule/execute.rs:19`). It makes planning testable without a GPU and keeps WebGL2 reachable later.
- **Feature-gated shader variants.** Compile-time switches such as `@if(gradient_sweep)` shrink shaders for web and mobile builds (`vello_gpu_shaders/shaders/render.wesl:27-43`).

**Modify**
- **Share a recording stage, not just geometry.** Vello's `record.rs` lets both renderers plan their own way from one graph. Flux should do the same, but keep the recording format small and documented from day one.
- **Pick one shader toolchain early.** WESL gives real imports and a GLSL path, at the price of pinned build dependencies (`vello_gpu_shaders/Cargo.toml:24-30`). A tiny preprocessor is cheaper but cannot serve WebGL2 on its own.

**Avoid**
- **Putting the experimental renderer in the main line.** Vello moved the compute renderer under `research/` once it stopped being the recommendation. If Flux explores GPU-side flattening, keep it behind a flag or in a separate crate so the default path stays reachable on WebGL2 and older GPUs.

## Where to Read Next

- [code-traces/fill-path.md](code-traces/fill-path.md): one `Scene::fill_path` call followed through all three phases, with `file:line` references.
- [README.md](README.md): the study plan and the document index. The documents that build directly on this layout are `sparse-strips.md` (flatten, tile, strip internals), `cpu-gpu-split.md` (scheduling rounds and the upload format), `paint-and-layers.md`, `text-glifo.md`, `wgpu-integration.md` and `compute-renderer.md` (the research pipeline in depth).
- [Tessellation theme](../../../themes/vector-graphics/tessellation.md): the triangle-mesh alternative that Vello avoids entirely.
- In the submodule: `ARCHITECTURE.md`, `research/doc/`, and each crate's `Cargo.toml` for feature definitions.

## References

- [Vello on GitHub](https://github.com/linebender/vello), commit `65338c25`
- `README.md`, `ARCHITECTURE.md`, `research/README.md` (all relative to `libraries/rust/vello/`)
- [Potato: a hybrid CPU/GPU 2D renderer design](https://docs.google.com/document/d/1gEqf7ehTzd89Djf_VpkL0B_Fb15e0w5fuv_UzyacAPU/edit), the design Sparse Strips grew from
- [Vello CPU master thesis (ETH Zürich, 2025)](https://ethz.ch/content/dam/ethz/special-interest/infk/inst-pls/plf-dam/documents/StudentProjects/MasterTheses/2025-Laurenz-Thesis.pdf), partly outdated per upstream
- [Linebender Zulip, #vello](https://xi.zulipchat.com/#narrow/channel/197075-vello)

---

*This document is part of the [Vello study](README.md).*
