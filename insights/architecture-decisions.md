# Architecture Decisions

Architecture Decision Records (ADRs) for your Rust framework.

## Template

```markdown
## ADR-XXX: Title

**Status**: Proposed | Accepted | Deprecated | Superseded

**Context**: What is the issue?

**Decision**: What is the change?

**Consequences**: What are the results?
```

---

## ADR-001: Workspace Organization

**Status**: Proposed

**Context**:
Framework code needs to be modular for:
- Different feature sets (2D only, 3D, audio)
- Cross-platform targets
- Optional dependencies

**Decision**:
Organize as a Cargo workspace with separate crates:
- `framework_core` — No-std compatible core (math, color, geom)
- `framework_graphics` — 2D/3D drawing (requires wgpu)
- `framework_audio` — Audio processing
- `framework` — Main crate that re-exports

**Consequences**:
- Clear separation of concerns
- Users can depend on only what they need
- Follows nannou's proven pattern

---

## ADR-002: Graphics Backend

**Status**: Proposed

**Context**:
Need cross-platform graphics for desktop, mobile, web.

**Decision**:
Use wgpu as the graphics backend.

**Consequences**:
- Native performance via Vulkan/Metal/DX12
- Web support via WebGPU
- Well-maintained Rust ecosystem
- Learning curve for contributors

---

## ADR-003: Drawing API Paradigm

**Status**: Proposed

**Context**:
Creative coding benefits from immediate-mode drawing, but GPUs work best with retained-mode batching.

**Decision**:
Provide immediate-mode API that internally batches to wgpu.

**Consequences**:
- Simple user code (`draw.ellipse()`)
- Internal complexity to batch efficiently
- Balance between convenience and performance

---

## ADR-004: Node Instance Identity

**Status**: Proposed

**Context**:
Node-graph systems split into name-as-identity (werkkzeug4) and random persisted IDs (tixl, cables, apEx, three.js). Flux derives authored child IDs deterministically from the name path so that generator-built projects reproduce their IDs and saves diff cleanly, which makes a rename an ID change. See [Node Instance Identity](./node-instance-identity.md).

**Decision**:
Keep name-derived IDs for the authored tier only; live and runtime IDs stay reminted. Implement rename as a single document-set transaction (validate, compute old→new map, rewrite every reference kind, re-validate, record for undo), with the reference kinds as an exhaustive enum.

**Consequences**:
- Generated projects stay reproducible without reading previous files
- Rename is only as safe as the reference inventory is complete
- References the transaction cannot reach (cross-project, read-only library internals) would require switching to persisted "born from name, then frozen" IDs

---

## ADR-005: 2D Path Rasterization

**Status**: Proposed

**Context**:
ADR-003 gives Flux an immediate-mode API that batches internally, and Flux's instanced analytic primitives (circles, rects, lines, rounded rects) already cover shapes that have a formula. Arbitrary paths and text have no formula, and Flux needs one rasterizer for them that works on wgpu across desktop, mobile and web with no required features, WebGL2 reach, exact anti-aliasing and paths that change every frame. The study's theme notes recommended Lyon tessellation before sparse-strip coverage had been compared; Lyon with MSAA ties edge quality to sample count and re-tessellates every changed path. See [2D Rendering Strategy](./2d-rendering-strategy.md).

**Decision**:
Extends ADR-003. Depend on `vello_gpu` (sparse-strip coverage) as the path and text rasterizer, behind a Flux-owned `PathRasterizer` trait so the implementation can be swapped. Keep instanced analytic primitives for circles, rects, lines and rounded rects. Keep Lyon only for uses that need a triangle mesh, such as extrusion into 3D or custom vertex effects. Use kurbo `BezPath` as the path port type so rendering, SVG, PDF and plotter export read the same data. Do not adopt stencil-and-fringe or the compute renderer as the default. This supersedes the "use Lyon for fill tessellation" recommendations in `notes/themes/vector-graphics/tessellation.md`, `notes/themes/vector-graphics/README.md` and Tier 4 of `notes/themes/rendering/primitive-strategies.md`. It also retires the `Renderer2D`/`RendererGL` sketch in `insights/rust-specific.md` in favour of one wgpu backend.

**Consequences**:
- Exact edge coverage for type and print-quality output, with no stencil attachment, compute shader or MSAA target required
- WebGL2 stays reachable through vello's WebGL backend
- Every recorded path costs CPU time each frame it changes; mobile cost is unmeasured, so the first prototype sets a pass/fail budget and a failure switches to Lyon with MSAA behind the same trait
- Exposure to `vello_gpu` 0.x API changes, contained by the trait and a pinned version
- Mask layers, destructive blends and oversized scenes panic upstream, so Flux must guard them before user content reaches the scene
- The license fits an open framework: the vello workspace declares `Apache-2.0 OR MIT` (`libraries/rust/vello/Cargo.toml:52`), which `vello_gpu` inherits (`vello_gpu/Cargo.toml:9`)

---

## ADR-006: Open Asset Formats

**Status**: Proposed (pending the import prototype in [open-formats.md](./open-formats.md#next-steps))

**Context**:
Every asset a Flux operator consumes and every file a render produces crosses a format boundary, and the choice decides what information survives (materials or just triangles), what code must exist on every platform including `wasm32`, and who controls the format. The study surveyed open formats by stewarding body, what the frameworks under study read and write, and the Rust crate for each; see [Open Formats for Flux](./open-formats.md) and [`research/open-formats/`](../research/open-formats/README.md). The one question with structural consequences is OpenUSD: a pure-Rust reader with composition (`openusd` 0.8.0) appeared in 2026, and no studied framework keeps USD composition alive at runtime; all flatten on import.

**Decision**:
Tier 1 import: glTF 2.0, OpenUSD (flattened), OBJ, OpenEXR, Radiance HDR, PNG, JPEG, WebP, KTX 2.0 raw blocks, SVG. Feature-gated import: PLY, STL, DDS, AVIF, JPEG XL, Basis Universal transcoding, Lottie, meshopt. Export: glTF, USDZ (flattened, one layer), OBJ, STL, EXR, PNG, SVG, PDF; 3MF later. Model materials on OpenPBR's parameter groups and names, implemented in WGSL, with mappers from glTF core plus extensions and from `UsdShade`. Treat USD as interchange, not as the scene model: Flux's operator graph stays the source of truth, every node carries a hierarchical path derived from its name path (stable except across a rename, which ADR-004's transaction must also rewrite in any exported USD) so a later exporter can emit meaningful prims, and the stance is revisited when `openusd` reaches 1.0 with `wasm32` support and a second independent implementation exists. Ignore MaterialX, OpenColorIO (port the ACES output transform by hand), Rive, Alembic, FBX and OpenTimelineIO.

**Consequences**:
- Every Tier 1 format has a pure-Rust crate with no native dependency; `wasm32` is documented for `png`, `image`, `exr`, `ktx2` and `usvg` and inferred for `openusd` and `tobj`, to be confirmed by the first prototype
- USD import is one crate with no C++ dependency; composition correctness is the crate's claim and the first prototype has to test it on a production-class asset
- USD export is lossy by design: operators become baked geometry, which matches how cables, Babylon and werkkzeug4 resolve scene files at the edge (tixl lets the user choose hierarchy or flat, but even its hierarchy is its own `SceneSetup`)
- The `gltf` crate lacks typed access to clearcoat, sheen, iridescence, anisotropy and dispersion, so Flux owns a few serde structs for those
- Basis transcoding and meshopt decoding are the two places a C++ toolchain enters, both behind features; without the Basis feature, glTF assets using `KHR_texture_basisu` load with those textures skipped and a warning, since that extension requires Basis payloads
- `vello_svg` targets compute `vello`, not `vello_gpu`, so SVG import needs a Flux `RenderSink` implementation over the ADR-005 rasterizer

---

*Add more ADRs as decisions are made.*
