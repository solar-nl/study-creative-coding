# Open Formats for Flux: What to Read, What to Write, What to Leave Alone

Flux authors projects as `.rproj` / `.rgraph` / `.rsym` data and renders through wgpu on desktop, mobile and the web. Every asset an operator consumes and every file a render produces crosses a format boundary, and the choice of formats is one of the decisions that cannot be revisited cheaply. This note turns the [open formats research](../research/open-formats/README.md) into a tiering table and takes a position on the one question that could reshape Flux's project model: what to do about OpenUSD.

**The short version:** Read glTF 2.0 and OpenUSD as scene formats, OpenEXR, PNG, Radiance HDR and KTX 2.0 as image formats, and SVG as the vector format, all through pure-Rust crates with no native dependency (`wasm32` is documented for the image and SVG crates and inferred for `openusd` and `tobj`). Model materials on OpenPBR's parameter names so that glTF, MaterialX and USD inputs all map onto one struct. Write glTF, USDZ, EXR, PNG, SVG and PDF. Treat USD as interchange, not as the scene model: flatten on import, flatten on export, and keep the operator graph as Flux's own source of truth until a second independent Rust implementation of USD composition exists. Leave MaterialX, OpenColorIO and FBX out; they cost a C++ runtime for little creative-coding benefit.

Evidence is in three places: the [landscape](../research/open-formats/README.md) for what each format is and who governs it, the [framework support matrix](../research/open-formats/framework-support-matrix.md) for what the studied frameworks do, and the [Rust crate map](../research/open-formats/rust-crates.md) for what Flux can depend on. Recorded as [ADR-006](./architecture-decisions.md#adr-006-open-asset-formats).

---

## Flux's Constraints

Five constraints decide the tiers. Four come from decisions Flux already made and the fifth from the audience.

- **wgpu only, web included.** [ADR-002](./architecture-decisions.md) picks wgpu for every platform. A format whose only reader is C++ with no `wasm32` story is a format the web build cannot open.
- **Pure-data projects.** Operators are authored as `.rsym` / `.rgraph` files. Any asset reference in a project has to be reproducible on another machine, which rules out formats that need a vendor SDK installed.
- **Texture-first node graph with a `BezPath` path port type.** 2D nodes exchange textures today; [ADR-005](./architecture-decisions.md) decides kurbo `BezPath` as the path port type, `vello_gpu` as its rasterizer, and names SVG and PDF export as goals.
- **No required wgpu features.** Flux negotiates extras at runtime. A texture format Flux cannot transcode on a baseline device is a format that needs a fallback.
- **Creative coders, not VFX departments.** The audience exports a still, a video, a plotter file or a web build far more often than a shot for a compositing pipeline. Film-only formats earn a lower tier than their quality would otherwise justify.

---

## The Tiering Table

**Tier 1 import** is what Flux ships with by default. **Tier 2 import** is feature-gated, the way nannou forwards Bevy's codec features ([framework-support-matrix.md](../research/open-formats/framework-support-matrix.md#nannou)). **Export** is what Flux writes. **Ignore** means no code, and a one-sentence reason.

| Format | Tier | Crate | Why |
|---|---|---|---|
| **glTF 2.0 / GLB** | Import 1, Export | `gltf` + `gltf-json` | The runtime delivery format that every studied importer (Filament, three.js, Babylon, rend3, tixl, orx) reads and that engines and web viewers expect from Flux. |
| **OpenUSD** (.usda/.usdc/.usdz) | Import 1 (`wasm32` unverified), Export (usdz) | `openusd` + `openusd-schemas` | The DCC interchange format in 2026, with a pure-Rust reader that has shipped roughly monthly since April and claims full composition; flattened on import, stance below. |
| **OBJ / MTL** | Import 1, Export | `tobj`; own writer | Thirty years of tools emit it, it cannot change, and fabrication and plotter pipelines still ask for it on the way out. |
| **PLY** | Import 2 | `ply-rs-bw` | Scanner output and the Gaussian-splat container; cheap to add behind a feature. |
| **STL** | Export, Import 2 | `stl_io` | Fabrication's format; writing matters more than reading. |
| **3MF** | Export (later) | `threemf` | The STL successor with color and multiple objects; defer until someone asks. |
| **OpenPBR** | Material model | own struct + WGSL | Not a file Flux reads but the vocabulary its material struct should use, so glTF extensions, MaterialX graphs and `UsdShade` networks map onto one set of names (see the material model section). |
| **MaterialX** | Ignore (for now) | none | No Rust implementation exists and the C++17 reference drags its own shader generators; revisit if USD material networks turn out to need the node library. |
| **OpenEXR** | Import 1, Export | `exr` | Linear float frames in and out, pure Rust, `wasm32` tested; the only sane way to hand a frame to a compositor. |
| **Radiance HDR** | Import 1 | `image` (`hdr`) | Every environment map on the internet. |
| **PNG** | Import 1, Export | `png` / `image` | The default still; APNG comes free. |
| **JPEG, WebP, GIF, TIFF, QOI, BMP, TGA** | Import 1 (JPEG, WebP), Import 2 (rest) | `image` | One crate, feature flags, nothing to decide. |
| **AVIF, JPEG XL** | Import 2 | `image` (AVIF, needs libdav1d), `jxl-oxide` | Both became web formats in 2025 and 2026; AVIF decode is the one `image` feature that drags in C, so it stays optional. |
| **KTX 2.0 + Basis Universal** | Import 1 (raw blocks), Import 2 (Basis) | `ktx2`; `basisu_c_sys` | The GPU-ready texture container glTF uses; raw blocks need only the parser, but `KHR_texture_basisu` requires Basis payloads, so a default build without the Basis feature skips those textures with a warning. |
| **DDS** | Import 2 | `ddsfile` | Legacy container for the same blocks; tixl and rend3 read it, so Flux users will have them. |
| **SVG** | Import 1, Export | `usvg` → `vello_svg` sink; `svg` crate | ADR-005 already assumes it, and `vello_svg`'s `RenderSink` trait lets Flux redirect geometry to `vello_gpu` even though the crate itself targets compute `vello` and pins `usvg` 0.48. |
| **PDF** | Export | `krilla` | Print and plotter pipelines; `krilla` is typst's PDF layer and pure Rust. |
| **Lottie** | Import 2 | `velato` | A specification since 2024 and a Linebender player that skips text and most effects and, like `vello_svg`, needs a Flux sink over `vello_gpu`. |
| **Rive** | Ignore | none | MIT runtime, vendor-owned format, dormant Rust binding. |
| **OpenColorIO** | Ignore; port ACES by hand | none | FFI only with no wasm, while the ACES output transform every real-time engine ships is a few dozen lines of WGSL. |
| **OpenVDB / NanoVDB** | Ignore until volumes are a port type | `vdb-rs` (read) | Read-only crate exists; nothing to do until Flux has a volume operator family. |
| **OpenTimelineIO** | Ignore | none | Flux's timeline is its own; a serde model is a weekend if an NLE handoff is ever needed. |
| **Alembic** | Ignore | none | Replaced by USD for interchange, no Rust crate, and the major DCCs that write it now write USD too. |
| **FBX** | Ignore | none | No specification, a EULA that forbids reverse engineering and no wasm, so users export glTF or USD instead (`ufbx` exists if a C dependency is ever acceptable). |
| **Draco, meshopt** | Import 2 (meshopt), Ignore (Draco native) | `meshopt` (FFI) | `EXT_meshopt_compression` is worth a C++ build flag on native, while Draco on the web is Google's WASM rather than a Rust problem. |

---

## The OpenUSD Question

The brief asked for a stance among three options, with the trade-off stated. Here it is.

### What the evidence says

Three facts changed the calculus during 2026.

**A pure-Rust USD with composition now exists.** `openusd` 0.8.0 (2026-10-11) reads and writes all three file formats and claims the full composition engine, time samples, authoring and a test suite checked against the AOUSD Core Specification 1.0.1 ([rust-crates.md](../research/open-formats/rust-crates.md#usd-in-rust-where-it-stands)). It is pre-1.0 with no second implementation to check it against, and `wasm32` is undocumented. This research did not run it.

**Both web engines import USD, neither adopts it.** three.js wrote a JavaScript reader with a composer for references, payloads and variants; Babylon ships Pixar's C++ runtime as WASM. Both then convert the composed stage into their own scene graph and forget the layers ([framework-support-matrix.md](../research/open-formats/framework-support-matrix.md#threejs)). No studied framework, native or web, keeps USD composition alive at runtime.

**USD's own model is moving under it.** 26.08 bumped both file-format versions; 26.11 dropped default support for old crate files after a security issue; Core Specification 1.1 is announced but unpublished; the normative text is CC-BY-ND. A framework whose project format *is* USD inherits every one of those changes on the ecosystem's schedule.

### The three stances, costed

An analogy first. Importing USD is like opening a colleague's layered Photoshop file and pasting the flattened result into your own document. Exporting USD is sending them a flattened copy back. Making USD the scene model is deciding that your document *is* a Photoshop file: every tool that opens one now opens yours, and every change Adobe makes to the format is now your migration.

| Stance | What Flux does | Cost | What it buys |
|---|---|---|---|
| **Import only** | Open a stage with `openusd`, traverse composed prims, convert `UsdGeom` meshes and `UsdShade` networks to Flux buffers and materials. | One crate. Composition bugs in the crate show up as wrong imports, which users can see and report. Flux scenes never reach a DCC. | Every DCC export opens in Flux. |
| **Interchange** (recommended) | Import as above, plus write a flattened `.usdc` or `.usdz` from a Flux scene: one layer, no arcs, `UsdPreviewSurface` plus an OpenPBR-named material network. | The same crate's write path, plus a mapping from Flux's material struct to `UsdShade`. Export is lossy by design (operators become baked geometry), and nothing round-trips: a re-imported export is geometry, not operators. | Flux sits in a DCC pipeline in both directions, and AR Quick Look opens its output. |
| **Scene model** | Define `.rsym` / `.rgraph` concepts as USD prims and layers; use composition for subgraph instancing, variants for presets, sublayers for user overrides. | Flux's project format depends on a pre-1.0 crate's composition engine with no second Rust implementation to fall back to; Flux's undo, diff and live-sync must go through that crate's stage API; every USD format bump becomes a Flux migration. | Composition for free, lossless round-trips with every USD tool, and a project that any USD viewer can open without Flux installed. |

### Recommendation: interchange, and shape the project format so the third stance stays open

The cost column of the third row is the whole argument. [Node Instance Identity](./node-instance-identity.md) and the [command flow](./command-flow-implementation.md) notes already define how Flux identifies, edits and undoes operators; routing all of that through a composition engine Flux does not own would replace a design the study has worked through with one it has not.

The benefit deserves a fair hearing before it is rebutted. Composition would give the operator graph three real things: `variantSets` are a ready-made preset system (one `.rsym` with a "lowpoly" and "hero" variant), `subLayers` are a user-override mechanism (a performance layer over a shipped project without editing it), and native instancing is subgraph reuse with a shared prototype. Flux will need all three. But each is a feature of a *scene hierarchy of properties*, and an operator graph is not that: it needs typed ports, evaluation order, feedback loops and per-frame dirty tracking, none of which USD composition models. Variants and sublayers would end up layered on top of a USD representation of the graph, which is exactly the custom layer Flux would have written anyway, now with a composition engine underneath it. tixl, cables and werkkzeug4 each keep their own container and resolve scene files at the edge, tixl with a hierarchy-or-flat switch, the others by flattening ([framework-support-matrix.md](../research/open-formats/framework-support-matrix.md#what-this-means-for-flux)); the operator-graph tools that work at scale all made this choice.

Two design moves keep the door open without paying for it now:

1. **Give every Flux node a hierarchical path derived from its name path** (`/World/Rig/Spinner`) alongside its identity, so a later USD exporter can emit prims with meaningful names and a later importer can round-trip them. [Node Instance Identity](./node-instance-identity.md) argues for name-derived identity and notes the cost: a rename changes the ID, so the rename transaction ADR-004 requires must also rewrite any exported prim path or saved path mapping. Add "USD prim path mapping" to that transaction's rewrite inventory when the exporter exists.
2. **Keep the material struct OpenPBR-shaped.** `UsdShade` networks, `KHR_materials_*` extensions and MaterialX graphs all map onto OpenPBR's lobes; a Flux material that uses those names imports from all three and exports to `UsdPreviewSurface` and `KHR_materials_openpbr` without a translation table.

Revisit the stance when two things are true: `openusd` has reached 1.0 with published `wasm32` support, and a second independent implementation (another Rust crate, or Pixar's own WASM build becoming practical to embed) exists to check it against. Until then, flatten.

---

## The Material Model

OpenPBR is listed as a tier in the table, which needs a word, since it is a shading specification and not a container.

The study's survey found the glTF material model and OpenPBR converging: glTF's ratified extensions (clearcoat, sheen, iridescence, anisotropy, dispersion, transmission, volume, specular, ior, emissive_strength) cover the same physical lobes as OpenPBR's groups under different names, and the proposed `KHR_materials_coat`, `_fuzz`, `_diffuse_roughness` and `_scatter` extensions, open pull requests as of 2026-10-25 that Babylon already implements, are the glTF side's counterparts of OpenPBR lobes ([landscape](../research/open-formats/README.md#gltf-20-the-runtime-delivery-format)). MaterialX ships OpenPBR as a first-class shading model, and USD's `UsdPreviewSurface` parameters map onto a subset of OpenPBR's, with three exceptions that have no OpenPBR counterpart: `displacement`, `occlusion` and the specular-workflow toggle.

So Flux's material struct should carry OpenPBR's parameter groups and names (base, specular, transmission, subsurface, coat, fuzz, emission, thin film, geometry), implement the BSDF in WGSL from the specification's physical description, and provide three mappers: from glTF core plus extensions, from `UsdShade` (`UsdPreviewSurface` first, OpenPBR surface when present), and to both for export. Exporting `KHR_materials_openpbr` is a bet on a draft that has no public Khronos proposal; Babylon marks its writer experimental and Flux should do the same. Babylon's `OpenPBRMaterial` is the reference for which parameters a real-time implementation can skip at first: per its documentation the alpha covers base, specular, coat and thin film, although the class also declares fuzz and subsurface properties ([framework-support-matrix.md](../research/open-formats/framework-support-matrix.md#babylonjs)). The `gltf` crate's missing extension flags (clearcoat, sheen, iridescence, anisotropy, dispersion) are raw JSON in the `extensions` map and need a few serde structs of Flux's own.

---

## One Asset, Traced

To make the tiers concrete, here is what happens when a Blender-exported `scene.usdz` lands on a `LoadScene` operator under the recommended stance:

1. `openusd` detects the zip, reads the root layer and any referenced layers inside the archive, and composes a stage (sublayers, references, payloads, variant selections resolved; LIVERPS decides conflicts).
2. Flux traverses the composed prims. Each `UsdGeomMesh` becomes a Flux mesh buffer, each `Xform` a transform node, each `UsdShadeMaterial` a Flux material.
3. The material mapper reads `UsdPreviewSurface` inputs into the OpenPBR-shaped struct (`diffuseColor` to `base_color`, `metallic` to `base_metalness`, `roughness` to `specular_roughness`, `clearcoat` to `coat_weight`); `displacement` and `occlusion` are kept as side channels because OpenPBR has no slot for them.
4. Textures referenced from the archive (PNG, JPEG, EXR, AVIF) are decoded by `image` and `exr`; a KTX2 with Basis payloads would need the Basis feature, otherwise it is skipped with a warning.
5. The operator exposes the result either as a node hierarchy or, with a `CombineBuffer`-style switch copied from tixl, as one chunked buffer.
6. Nothing about layers, variants or references survives into the Flux project; it is baked geometry with a prim path per node, which is what a later `.usdz` export will emit back.

---

## What Was Not Verified

- `openusd` was read, not run. Composition correctness on production assets is the crate's claim.
- `wasm32` for `openusd`, `vello_svg`, `velato` and `tobj` is inferred from pure-Rust dependency trees, not from a documented build.
- The glTF 2.1 feature list is from the June 2026 announcement; the registry has not published the document.
- Babylon's OpenPBR coverage table is from its documentation page, not from re-reading the shader.

---

## Next Steps

1. Prototype the import path: `openusd` → Flux mesh buffers on one Kitchen Set-class asset, native and `wasm32`, and record what breaks.
2. Write the OpenPBR material struct and the glTF extension serde structs; test against the Khronos sample models for each `KHR_materials_*` extension.
3. Implement `vello_svg`'s `RenderSink` over `vello_gpu`'s scene API so SVG import lands on the ADR-005 rasterizer.
4. Move [ADR-006](./architecture-decisions.md#adr-006-open-asset-formats) from Proposed to Accepted once the prototype has run.
