# Vello

GPU-accelerated 2D vector rendering in Rust, from the Linebender project.

## Why Study This

Vello is the most serious attempt in the Rust ecosystem at a Skia-class 2D renderer: shapes, strokes, gradients, images, clips, blend modes, filters and text under a PostScript-style imaging model, with GPU acceleration. It sits exactly where a creative coding framework's 2D layer sits, which makes it the main reference point for how Flux should render paths on the GPU.

The repository is more interesting than "a 2D renderer" because it contains three renderers that answer the same question differently. The compute-centric `vello` crate (now under `research/`) encodes the whole scene into buffers and runs flattening, binning, coverage and compositing in compute shaders, parallelised with prefix scans. The newer **Sparse Strips** renderers, `vello_cpu` and `vello_gpu`, flatten and tile paths on the CPU, keep coverage only where it matters around path boundaries, and either composite on the CPU with SIMD or hand the strips to ordinary vertex/fragment pipelines. The project itself now says Sparse Strips is the production direction and the compute renderer is experimental. That shift is a design lesson in its own right: compute-only rendering is powerful but narrows the hardware you can ship on, and a CPU-preprocessing split keeps WebGL2 and older GPUs reachable.

For Flux the central contrast is with triangle tessellation. The study's [tessellation theme](../../../themes/vector-graphics/tessellation.md) assumes paths become triangle meshes (Lyon in nannou). Vello never triangulates: both renderer families compute per-pixel coverage from flattened lines. Understanding what that buys (exact anti-aliasing, cheap dynamic paths, no mesh caching) and what it costs (a CPU stage per frame, custom shaders, a renderer that owns its own frame) is the question this submodule exists to answer.

## Repository State

Studied at commit `65338c258f09` (2026-10-21): `vello_cpu`, `vello_gpu` and `vello_common` 0.3.0, `glifo` 0.4.0, compute-centric `vello` 0.11.0. This is after the restructuring that moved the compute renderer under `research/`. Web summaries written before that move describe a different layout. The git-lfs note in `CLAUDE.md` applies to this submodule: snapshot PNGs are LFS pointers in this checkout, source is complete.

## Key Areas to Study

| Area | Where | Relevance to Flux |
|------|-------|-------------------|
| Sparse strip coverage representation | `vello_common/src/{flatten,tile,strip,strip_generator}.rs` | The alternative to tessellation: what a strip is, how coverage is stored, what fully covered regions cost |
| CPU/GPU split | `vello_gpu/src/scene.rs`, `vello_gpu/src/schedule/` | What is computed per frame on the CPU, what crosses the bus, how work is scheduled into rounds |
| GPU rasterization without compute | `vello_gpu/src/render/wgpu/`, `vello_gpu_shaders/shaders/render.wesl` | Vertex/fragment-only strip rendering on wgpu and WebGL2 |
| Paint model | `vello_common/src/paint.rs`, `vello_gpu/src/gradient_cache.rs`, `vello_gpu/src/paint.rs` | Solid, gradient (linear/radial/sweep), image and external-texture paints; how paints are encoded for the GPU |
| Clip, mask, blend, filter stack | `vello_common/src/{clip,mask,filter_effects}.rs`, `vello_gpu/src/{blend,filter}.rs` | Layer semantics (push/pop with blend mode and opacity), blur and drop shadow |
| Text | `glifo/`, `vello_gpu/src/text.rs` | Glyph runs, atlas caching, hinting; shared by CPU and GPU renderers |
| wgpu integration surface | `vello_gpu/src/{resources,target}.rs`, `vello_gpu/src/render/wgpu/` | How a renderer that owns its pipelines embeds into a host's wgpu device, queue and render target |
| Feature-flag granularity | `vello_gpu/Cargo.toml` | Shader features (`gradient_sweep`, `blurred_rounded_rect`, `full_image_support`) toggled at build time |
| Compute-centric pipeline | `research/vello_research/`, `research/vello_encoding/`, `research/vello_shaders/shader/` | Scene encoding, `Recording` of GPU ops, prefix-scan stages; the design history in `research/doc/` |
| Shader tooling | `vello_gpu_shaders/` (WESL to WGSL/GLSL), `research/vello_shaders/` (WGSL with `import`/`ifdef` preprocessor) | Two approaches to shader modularity on top of WGSL |

## Repository Structure

```
vello/
├── vello_common/        # Shared flatten → tile → strip pipeline, paint, clip, mask, filters
├── vello_cpu/           # CPU renderer (SIMD, multithreaded), the most mature
├── vello_gpu/           # GPU renderer: CPU preprocessing + vertex/fragment rasterization (wgpu, WebGL2)
├── vello_gpu_shaders/   # WESL shader sources, generated WGSL/GLSL and reflection data
├── glifo/               # Glyph-run and text decoration rendering shared by both Sparse Strips renderers
├── vello_tests/         # Shared scenes, snapshots (LFS), browser tooling
├── vello_bench/         # Sparse Strips benchmarks
└── research/            # Compute-centric renderer: vello_research, vello_encoding, vello_shaders, doc/
```

## Documents

| Document | Covers |
|----------|--------|
| [architecture.md](architecture.md) | Crate map, the three renderers and the 2025 restructuring, WESL vs WGSL-preprocessor shader tooling, feature flags, crate dependency diagram |
| [sparse-strips.md](sparse-strips.md) | Flatten, tile, strip; the `Strip` layout and `fill_gap`; analytic coverage; clip intersection; a worked 4x4 tile; comparison with tessellation and stencil fills |
| [cpu-gpu-split.md](cpu-gpu-split.md) | Record, plan, encode, execute; even/odd layer pages and rounds; what crosses the bus per frame and where CPU time goes |
| [wgpu-integration.md](wgpu-integration.md) | The host contract: `Renderer::new/render`, caller-owned encoder, required features (none), formats, per-frame uploads, external textures, known limits, embedding sketch |
| [paint-and-layers.md](paint-and-layers.md) | Paint model and encoded paints, gradient LUT cache, images, clips vs layers, blend and filter passes |
| [text-glifo.md](text-glifo.md) | glifo's sink-trait inversion, path mode vs atlas mode, COLR and decorations, `Resources` |
| [compute-renderer.md](compute-renderer.md) | The research renderer: scene encoding, the compute stages, the recording model and bump allocator, why it stepped back |
| [code-traces/fill-path.md](code-traces/fill-path.md) | `Scene::fill_path` to pixels in vello_gpu: flatten, tile, strip, record, schedule, instanced quads, shaders; 12 stops with `file:line` |

## Documents to Create

- [x] `architecture.md` — Crate relationships, the three renderers, why Sparse Strips became the main line
- [x] `sparse-strips.md` — Flatten, tile, strip generation; coverage storage; how a strip is rasterized
- [x] `cpu-gpu-split.md` — Per-frame CPU work, scheduling rounds, upload format, what the GPU does
- [x] `paint-and-layers.md` — Paint encoding, gradients and images, clip/mask/blend/filter layers
- [x] `text-glifo.md` — Glyph runs, atlas management, hinting path
- [x] `wgpu-integration.md` — Embedding `vello_gpu::Renderer` into a host application's wgpu frame
- [x] `compute-renderer.md` — The research pipeline and what it still offers over Sparse Strips
- [x] `code-traces/fill-path.md` — From `Scene::fill_path` (`vello_gpu/src/scene.rs:358`) to pixels, with `file:line` references
- [x] Theme follow-up in `notes/themes/vector-graphics/` comparing coverage rendering with tessellation — see [rasterization-strategies.md](../../../themes/vector-graphics/rasterization-strategies.md)

## References

- [Vello GitHub](https://github.com/linebender/vello)
- [vello_gpu on docs.rs](https://docs.rs/vello_gpu), [vello_cpu on docs.rs](https://docs.rs/vello_cpu)
- [Potato: a hybrid CPU/GPU 2D renderer design](https://docs.google.com/document/d/1gEqf7ehTzd89Djf_VpkL0B_Fb15e0w5fuv_UzyacAPU/edit) — the design the Sparse Strips renderers grew from
- [Vello CPU master thesis (ETH Zürich, 2025)](https://ethz.ch/content/dam/ethz/special-interest/infk/inst-pls/plf-dam/documents/StudentProjects/MasterTheses/2025-Laurenz-Thesis.pdf) — detailed pipeline description, partly outdated per upstream
- `research/doc/` inside the submodule — compute-renderer design history, roadmap, path segment encoding
- [Linebender Zulip, #vello](https://xi.zulipchat.com/#narrow/channel/197075-vello) — design discussion, readable without login
