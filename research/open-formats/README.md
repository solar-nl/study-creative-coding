# Open Formats for 2D and 3D Assets: The Landscape

> Which open formats exist for scenes, materials, images, vector art and motion, who governs them, and what state are they in as of October 2026?

This directory holds the work products of the [open formats research brief](../open-formats-research-brief.md):

- **This document** — the landscape, organized by stewarding body and then by domain, with the facts a format decision needs: what it describes, who owns it, what version is current, what the reference implementation costs.
- [`framework-support-matrix.md`](./framework-support-matrix.md) — which of the frameworks under study read or write each format, cited to source.
- [`rust-crates.md`](./rust-crates.md) — the Rust crate for each format, with maturity and `wasm32` status.
- [`insights/open-formats.md`](../../insights/open-formats.md) — the tiering table and the OpenUSD stance for Flux.

I read every version, date and license here from a page fetched on 2026-10-25; the URLs are at the end. Where two official sources disagree, both are recorded.

## Key Insight

> **Openness is not one property.** The formats that matter fall into four governance shapes, and the shape predicts how stable each one is. *Foundation* formats (ASWF's OpenEXR, MaterialX, OpenColorIO and OpenVDB; Khronos's glTF and KTX; W3C's PNG and SVG) have a spec, a permissive license and a body that takes contributions. *Consortium or single-vendor* standards (AVIF, WebP, JPEG XL, Lottie, 3MF) have a spec and a license but one organization's roadmap. *De-facto* formats (OBJ, PLY, STL, Radiance HDR) have a thirty-year-old text file and no owner, which is a different kind of stable. And a fourth group looks open from a distance but is not: FBX has an SDK and no spec, DDS has a spec and no license, Rive has an MIT runtime and a vendor-owned format. OpenUSD straddles the first and fourth: Apache-style code, a foundation, and a normative text that is CC-BY-ND. The verdict table below applies the brief's three criteria format by format.

---

## The Problem: Every Asset Is a Contract

A creative-coding framework spends most of its life moving data across a boundary. A mesh comes in from Blender, a texture from Substance, an environment map from a photographer, an icon from Figma. A frame goes out to a video encoder, a plotter, a print shop or a game engine. Each crossing is governed by a file format, and the format decides three things the framework cannot change later: what information survives the crossing (does the material come through, or just the triangles?), what code has to exist on every platform to read it (a 2,000-line Rust crate or a 50 MB C++ runtime), and who can change the rules (a foundation with a public process, or one vendor).

The diagram below is the ecosystem as it looks from a Flux project file. Everything on the left is an open format that could arrive as an asset; everything on the right is an open format Flux could emit.

```
   DESIGN & DCC TOOLS                 FLUX                        OUTPUTS
   ──────────────────           ┌──────────────┐           ────────────────
   Blender, Houdini,            │  .rproj      │           glTF/GLB ─▶ engines, web
   Maya, Substance   ─ USD ────▶│  .rgraph     │─ USDZ ──▶ DCC, AR Quick Look
                     ─ glTF ───▶│  .rsym       │─ PNG ───▶ stills, APNG
   Figma, Illustrator─ SVG ────▶│              │─ EXR ───▶ comp, HDR frames
   After Effects     ─ Lottie ─▶│  operators   │─ SVG ───▶ web, plotters, laser
   Photographers     ─ EXR/HDR ▶│  consume     │─ PDF ───▶ print
   Texture tools     ─ KTX2 ───▶│  assets      │─ OBJ/STL▶ fabrication
   Scanners          ─ PLY/LAS ▶│              │
                                └──────────────┘
   material definitions: OpenPBR (via MaterialX or USD) ──▶ Flux material model
   color pipeline:       OpenColorIO configs, ACES ────────▶ Flux color management
```

The sections below walk the formats by who governs them, because that decides how stable each one is. First, the brief's three criteria (a published spec, a permissive license on spec and reference implementation, a stewarding body or open project) applied to every in-depth format:

| Format | Steward | Spec license | Code license | Verdict |
|---|---|---|---|---|
| OpenEXR | ASWF | BSD-3 (spec lives in the repo) | BSD-3 | pass |
| MaterialX | ASWF | Apache-2.0 | Apache-2.0 | pass |
| OpenPBR | ASWF-hosted repo, Autodesk and Adobe | Apache-2.0 (badge inconsistent) | MaterialX graph, Apache-2.0 | pass |
| OpenColorIO | ASWF | BSD-3 | BSD-3 | pass |
| OpenVDB | ASWF | Apache-2.0 | Apache-2.0 | pass |
| OpenUSD | AOUSD (spec), Pixar (code) | **CC-BY-ND-4.0** | Apache-2.0 with trademark clause | **partial**: readable and implementable, spec not modifiable |
| glTF 2.0 | Khronos | CC-BY-4.0 sources; Khronos conditional copyright on the published text | Apache-2.0 tooling | pass |
| KTX 2.0 | Khronos | Khronos conditional copyright | Apache-2.0 (one excludable Ericsson file) | pass |
| PNG | W3C | W3C Software and Document License | libpng license | pass |
| SVG | W3C | W3C Software and Document License | n/a | pass (SVG 2 still CR) |
| WebP, AVIF, JPEG XL | Google, AOM, ISO | RFC / AOM / ISO | BSD-3 | pass, single-roadmap |
| Lottie | Lottie Animation Community (JDF) | Community Specification License 1.0 | MIT players | pass |
| 3MF | 3MF Consortium (JDF), ISO | BSD-2 | BSD-2 | pass |
| OBJ, PLY, STL, Radiance HDR | none | none (de facto text) | various | pass by convention, nobody to change them |
| Alembic | none (Lucasfilm and Sony copyright) | BSD-3 | BSD-3 | **partial**: no steward |
| TIFF | Adobe | unpublished tag registry | libtiff license | **partial** |
| DDS | Microsoft | no license on the format | n/a | **fail** on criterion 2 |
| Rive | Rive Inc. | no license, not called a spec | MIT runtimes | **fail** on criteria 1 and 3 |
| FBX | Autodesk | none; SDK under EULA | EULA | **fail** on all three |

---

## Academy Software Foundation (ASWF)

Founded in August 2018 by the Academy of Motion Picture Arts and Sciences to host the open-source projects the film industry depends on. Projects move through Sandbox, Incubating and Graduated stages. The roster as of 2026-10-25, from the ASWF landscape file:

| Stage | Projects |
|---|---|
| Graduated | Digital Production Example Library, **MaterialX**, **OpenColorIO**, OpenCue, **OpenEXR**, OpenImageIO, Open Shading Language, **OpenVDB** |
| Incubating | **ACES**, OpenFX, **OpenTimelineIO**, rawtoaces, Rez |
| Sandbox | Dailies Notes Assistant, MoonRay, OpenAPV, OpenAssetIO, Open Path Guiding Library, OpenQMC, Open RV, xStudio |
| Working groups | Open Review Initiative, Zero Trust; long-term: Continuous Integration, Diversity & Inclusion, **Universal Scene Description** |

Three projects people assume are ASWF-hosted are not. **OpenPBR** is a repository under the ASWF GitHub organization but not a roster project; Autodesk and Adobe develop it and MaterialX ships its reference graph. **Alembic** is not an ASWF project at all; it appears in the landscape only as an ecosystem entry, and its repository still carries Lucasfilm's copyright. **OpenUSD** is governed by AOUSD and Pixar; ASWF only runs the working group listed above.

Also on the roster but deliberately skipped here: Open Shading Language (a shader language, covered by the rendering theme rather than an asset format) and OpenImageIO (a library that reads the image formats below, not a format). The brief's "lineage, not formats" items, Autodesk Standard Surface and Disney Principled, appear only where OpenPBR cites them. PSD is closed (Adobe publishes the format under terms that forbid reverse engineering) and Flux has no reason to read it.

### OpenEXR: the image format for anything that is not 8-bit

**The problem it solved.** Film compositing needs scene-linear pixels with headroom above white and precision below black. 8-bit integer formats clip and band. ILM wrote OpenEXR in 1999 for exactly that, with a 16-bit float "half" type as the default pixel format, and released it as open source in 2003.

**Governance.** Adopted by ASWF on 2019-05-01, now Graduated. BSD-3-Clause.

**Current version.** v3.5.2, published 2026-10-03. The 3.5 line (3.5.0 on 2026-09-22) added lossless Zstandard compression, including for deep data, and a lossy HTJ2K-based codec called LJ2K; 3.5.2 fixed an LJ2K transfer-function lookup, and files written with LJ2K by 3.5.0 or 3.5.1 should be regenerated. 3.4.0 (2025-09-05) introduced lossless HTJ2K and the `colorInteropID` attribute. A 3.2.x, 3.3.x and 3.4.x patch stream runs alongside.

**What it describes.** Scanline or tiled images with arbitrary named channels in HALF, FLOAT or UINT; multi-part files (several images in one container, each with its own header) and deep data (a variable-length list of samples per pixel), both since OpenEXR 2.0 in April 2013. Fourteen compression modes from RLE and ZIP through PIZ, B44, DWAA/DWAB, HTJ2K, LJ2K and ZSTD.

**Reference implementation.** C and C++ (about 11 MB of source) with Python bindings; depends on Imath, libdeflate, zstd and OpenJPH. The pure-Rust `exr` crate reads multipart files and deep tiles, lacks deep scanlines and DWA compression, and compiles to `wasm32`; whether it reads the HTJ2K, LJ2K and ZSTD codecs added in 3.4 and 3.5 was not checked ([rust-crates.md](./rust-crates.md#images-and-textures)).

### MaterialX: a node graph for looks

**The problem it solved.** Every renderer and DCC had its own material description, so a look authored in one tool could not be reproduced in another. ILM started MaterialX in 2012 as a renderer-neutral node-graph format with a standard node library and shader generators that compile the graph to each renderer's shading language. Think of it as a shader graph that belongs to no renderer: the graph is the asset, and each renderer compiles its own shader from it.

**Governance.** Open-sourced in 2017; the seventh ASWF hosted project in 2021, Graduated. Apache-2.0.

**Current version.** Specification v1.39, dated 2025-03-15. Library v1.39.5, released 2026-05-22, which rewrote the node specifications as structured tables, updated OpenPBR Surface to v1.1.1, extended the Standard Surface to glTF PBR translation graph, added Slang as a shader-generation target, and moved Metal output to native MSL.

**What it describes.** Documents containing node definitions (`nodedef`), node graphs, materials and looks. Three shading models ship as node graphs: Autodesk Standard Surface (versioned nodedefs with inheritance), glTF PBR (since v1.38.4) and OpenPBR Surface. Shader generators emit GLSL, ESSL, MSL, OSL, MDL and Slang.

**Reference implementation.** C++17 (about 3.2 MB), with optional Python and JavaScript/WebAssembly bindings, a viewer and a graph editor. No Rust implementation exists beyond a placeholder crate.

### OpenPBR: the uber-shader with a specification

**The problem it solved.** Autodesk Standard Surface and Adobe Standard Material were two physically-based uber-shaders defined by their implementations. OpenPBR Surface was written as a synthesis of both, and it defines the model by physical structure (slabs of media bounded by interfaces, combined by layering and mixing) rather than by a particular implementation, so that any renderer can reproduce it from the text.

**Governance.** Autodesk and Adobe develop it with industry input; the ASWF GitHub organization hosts the repository; MaterialX ships the reference graph and tracks its versions. First public pre-release v0.2 on 2023-10-23; v1.0 on 2024-06-04. The repository LICENSE is Apache-2.0; the README badge is inconsistent (alt text says CC BY-SA 4.0, URL says Apache 2.0).

**Current version.** v1.1.1, 2026-04-17. It is the only release since v1.1 (2024-06-28); it adds an implementation-flexibility section, more examples and MaterialX hints, and fixes edge-tint and thin-walled issues in the reference graph. v1.1 enabled Zeltner sheen and changed the thin-film IOR default; v1.0 enabled diffuse energy compensation and added `coat_darkening`.

**The parameter set, v1.1.1.** This list is what a Flux material struct would mirror:

| Group | Parameters |
|---|---|
| Base | `base_weight`, `base_color`, `base_metalness`, `base_diffuse_roughness` |
| Specular | `specular_weight`, `specular_color`, `specular_roughness`, `specular_roughness_anisotropy`, `specular_ior` |
| Transmission | `transmission_weight`, `transmission_color`, `transmission_depth`, `transmission_scatter`, `transmission_scatter_anisotropy`, `transmission_dispersion_scale`, `transmission_dispersion_abbe_number` |
| Subsurface | `subsurface_weight`, `subsurface_color`, `subsurface_radius`, `subsurface_radius_scale`, `subsurface_scatter_anisotropy` |
| Coat | `coat_weight`, `coat_color`, `coat_roughness`, `coat_roughness_anisotropy`, `coat_ior` (1.6), `coat_darkening` (1) |
| Fuzz | `fuzz_weight`, `fuzz_color`, `fuzz_roughness` (0.5) |
| Emission | `emission_luminance` (cd/m², 0), `emission_color` |
| Thin film | `thin_film_weight`, `thin_film_thickness` (0.5 µm), `thin_film_ior` (1.4) |
| Geometry | `geometry_opacity`, `geometry_thin_walled`, `geometry_normal`, `geometry_coat_normal`, `geometry_tangent`, `geometry_coat_tangent` |

**Reference implementation.** A MaterialX node graph, `reference/open_pbr_surface.mtlx`, derived from the Standard Surface implementation. There is no standalone library. Real-time support in 2026: Babylon.js 9.0 (2026-04-02) ships an alpha `OpenPBRMaterial` contributed by Adobe, covering base, specular, coat and thin-film and leaving transmission, subsurface, fuzz and emission "to be evaluated"; Unreal Engine supports it with Substrate enabled; Chaos Vantage 3.4 (2026-09-29) added it as a V-Ray material mode; three.js maps `open_pbr_surface` through its MaterialX and USD loaders ([framework-support-matrix.md](./framework-support-matrix.md#threejs)). An Autodesk paper from December 2025 ("OpenPBR: Novel Features and Implementation Details", arXiv 2512.23696) still lists real-time implementation as further work.

### OpenColorIO and ACES

Two tools that both claim to convert "sRGB to linear" and do it with different code produce different pixels, and on a film that difference travels through every department. **OpenColorIO** moves the transform out of code into a runtime-read `.ocio` configuration that every tool in a pipeline loads, so the math is shared rather than reimplemented. Sony Pictures Imageworks started it in 2003 and open-sourced it; it became ASWF's second hosted project in February 2019, now Graduated; Autodesk has led 2.x development since 2017. BSD-3-Clause. Current release v2.6.0, 2026-10-01, the base version for the CY2027 VFX Reference Platform, adding SMPTE ST 2136-1 CLF read and write and ACES 2.0 built-in configs; v2.5.0 (2025-10-01) brought full ACES 2.0 support. C++ (about 10 MB) with Python bindings. Rust has only FFI bindings (`ocio-rs`), so OCIO means a C++ dependency on every platform and no web build.

**ACES** (the Academy Color Encoding System) is the workflow standard OCIO configs most often encode: input, working, look and output transforms. ACES 2 redesigned the rendering transforms with a gentler tone curve, better gamut mapping and faster inverses; the `aces-aswf/aces` repository tags v2.0.0 on 2025-04-04. AMPAS moved ACES into ASWF as an Incubating project on 2025-08-06. Transforms are Apache-2.0; documentation CC-BY-4.0. Without OCIO, a real-time engine ports the ACES output transform by hand into its shader language, which is what most engines already do.

### OpenVDB and NanoVDB

A dense 3D grid of a cloud is almost entirely empty voxels, and storing them is what made volumes impractical. **OpenVDB** is a hierarchical sparse-grid data structure and file format that stores only the occupied blocks of a volume (smoke, clouds, level sets), developed at DreamWorks and open-sourced in August 2012; it was the first project to move its governance into ASWF in August 2018, now Graduated. Re-licensed from MPL-2.0 to Apache-2.0. Current release v13.1.0, 2026-09-16, with a new SIMD framework, NanoVDB CUDA improvements and TBB 2023 support; v13.0.0 (2025-11-04) still requires Boost 1.82 and TBB, so the dependency footprint has not shrunk as much as the website suggests. About 20 MB of C++ plus CUDA. **NanoVDB**, contributed by NVIDIA in 2020, is a static-topology, flat-buffer version of the same tree that runs on GPUs and can be built without OpenVDB. Rust has a read-only `vdb-rs` for OpenVDB and nothing for NanoVDB.

### OpenTimelineIO

Editorial cuts used to travel between editing systems as EDL text files that lost everything but in and out points. **OpenTimelineIO** is an interchange format and API for editorial cut information: a modern edit decision list with a schema, so tracks, clips, transitions and markers survive the trip. Created at Pixar, accepted as ASWF's fifth hosted project on 2019-07-29, still Incubating. Apache-2.0. Native `.otio` files are JSON with a per-object `OTIO_SCHEMA` type-and-version key, so any language can read them. C++ core with Python, Swift and C bridges. Every release is still flagged Beta; latest v0.18.1, 2025-11-09. No Rust crate, but a serde model would be short work.

### Alembic (not ASWF)

If USD is the project file, Alembic is the rendered video of the scene: it stores baked geometry sampled over time, not the procedural graph that produced it, which makes it a cache rather than a scene model. Created by Sony Pictures Imageworks and ILM, announced at SIGGRAPH 2011. BSD-3-Clause, but with no foundation behind it; the ASWF landscape lists it only as an ecosystem entry. Current release 1.8.12, 2026-07-02, a bug-fix release. C++11 with Imath, optional HDF5. USD has largely replaced it for interchange; Rust has a placeholder crate only.

---

## Alliance for OpenUSD (AOUSD)

Announced 2023-08-01 by Pixar, Adobe, Apple, Autodesk and NVIDIA as a Joint Development Foundation project under the Linux Foundation, chosen because that structure opens a route to ISO standardization. By the end of 2025 it had 50 General Members and 88 Contributor Members; 2026 additions include Qualcomm (March), ByteDance, Huawei, Physicl and Unity (July). Working groups: Core Specification, Materials, Geometry, Physics, Marketing.

**Two bodies own the two halves, and a third watches.** Pixar holds the code (`PixarAnimationStudios/OpenUSD`, three to four releases a year, changelog). AOUSD holds the normative specification (`aousd/specifications-public`). ASWF runs a working group and hosts neither. The licenses follow the split: the code is under the "Tomorrow Open Source Technology License 1.0", which is Apache-2.0 with a stricter trademark clause (GitHub reports it as "Other"); the specification text is **CC-BY-ND-4.0**, so it may be redistributed but not modified; only the Python sample implementations in `core-spec-supplemental-public` are Apache-2.0.

### OpenUSD: a scene description with a composition engine

**The problem it solved.** On a feature film, dozens of departments and vendors contribute opinions about the same scene: modeling places the geometry, layout moves it, shading assigns materials, lighting overrides a few. A single scene file would be overwritten constantly. USD lets each contribution live in its own *layer* and composes them non-destructively at load time, the way a Photoshop document keeps adjustment layers separate from the pixels beneath them, or the way CSS lets several stylesheets apply to one page with a strength rule deciding conflicts. Pixar open-sourced it on 2016-07-26.

**Current version.** 26.11.1, tagged 2026-10-21 (the changelog lists 26.11.0 on 2026-10-20 and 26.11.1 the next day; only 26.11.1 has a tag). Three to four releases a year; the 2026 ones:

| Release | Date | What changed |
|---|---|---|
| 26.05 | 2026-04-24 | `usdzip` ported to C++; **Wasm and Wasm64 added to the GitHub build workflow**; iOS and visionOS simulators |
| 26.08 | 2026-07-20 | `.usda` format bumped to 1.3 and crate (`.usdc`) format to 0.15.0; MaterialX 1.39.5; Apple Framework builds |
| 26.11 | 2026-10-20 / 21 | VFX 2025 reference platform; oneTBB by default; Python 3.9 and 3.10 dropped; **default support for `.usdc` files older than crate version 0.4.0 removed** after a security issue with maliciously crafted files (0.4.0 to 0.8.0 still read with a warning) |

**The composition model.** The vocabulary a Flux design has to engage with:

- A **layer** is the atomic persistent container of scene description (one `.usda` or `.usdc` file). A **layer stack** is a layer plus its recursively gathered **sublayers**.
- A **stage** is the composed view; a **prim** is the container object in it; an **opinion** is one layer's value for one property, the unit that value resolution picks between.
- Six **composition arcs** pull other scene description into a prim: subLayers, inherits, variantSets, references, payloads, specializes. References compose smaller units into larger aggregates; payloads are references that can be deferred (not loaded until asked); variant sets package switchable alternatives; inherits broadcast changes to every prim that inherits a class; specializes refine a base prim.
- Strength order is spelled **LIVERPS**: Local, Inherits, VariantSets, Relocates, References, Payload, Specializes. A local opinion beats one from a reference, which beats one from a payload.
- **Flattening** bakes the composition down to a single layer with no arcs, via `UsdStage::Flatten` or `usdcat --flatten`, the way exporting a layered PSD to a PNG keeps the picture and discards the layers. A flattened stage is self-contained and portable, and it is what every realtime consumer in the [support matrix](./framework-support-matrix.md) actually works with.

**The runtime cost.** Pixar's implementation is about 44 MB of C++, 9 MB of C and 8 MB of Python. Python is optional (`--no-python`), Boost has been gone since v24.11, but Intel TBB or oneTBB is required, and the WebAssembly build requires oneTBB. Imaging (Hydra), the tools and every format plugin (OpenEXR, OpenImageIO, OpenColorIO, OSL, Alembic, MaterialX, OpenVDB) are switchable. Babylon.js ships this runtime as a WASM bundle from its CDN; three.js wrote its own JavaScript reader with composition instead. Rust gained a pure implementation with composition in 2026 (`openusd` 0.8.0; see [rust-crates.md](./rust-crates.md#usd-in-rust-where-it-stands)).

**usdz.** A zero-compression, unencrypted zip archive with every file aligned to 64 bytes; the first file must be a USD layer; allowed contents are usd/usda/usdc/usdz, png/jpeg/exr/avif (AVIF added in usdz 1.3) and m4a/mp3/wav. Apple introduced it with Pixar in June 2018 for AR Quick Look, and Apple is an AOUSD founder. The 26.11 spec revision clarifies that nesting usdz archives is allowed.

**The Core Specification.** AOUSD announced OpenUSD Core Specification 1.0 on 2025-12-17 as the first step toward ISO standardization, covering grammar and data types, the document data model, the composition algorithm, stage population and value resolution, the three file formats and a compliance framework. The public repository (created 2026-06-02) holds v1.0.1 as PDF and Markdown with a release date of 2025-12-12, five days before the announcement; the repository was published after the fact and the tag date is the document's, not the announcement's. Core Specification 1.1 (animation splines, variable and path expressions, built-in applied schemas, compliance rubric) was announced in July 2026 as the release in which AOUSD begins the ISO certification process, but as of 2026-10-25 the public repository still lists only 1.0.1.

---

## Khronos Group

Khronos publishes specifications under a conditional copyright: anyone may use and reproduce the unmodified text; patent protection and trademark use require becoming an Adopter. Ratified `KHR_` extensions are covered by the Khronos IP framework; `EXT_` multi-vendor extensions normally are not, except the three listed in the ratified table below.

### glTF 2.0: the runtime delivery format

**The problem it solved.** glTF 1.0 described materials as GLSL shaders, which could not be ported to Direct3D or Metal. glTF 2.0 (finalized 2017-06-05) replaced that with a parameterized PBR material and a JSON scene graph (nodes, meshes, skins, animations, cameras) over binary buffers, so that one asset renders consistently on every API. It is ISO/IEC 12113:2022.

**Current version.** Revision 2.0.1, 2021-10-11, the only 2.x document in the registry. **glTF 2.1** was announced 2026-06-11 as a backward-compatible revision: external assets and packaging, implicit shapes, bounding-volume hierarchies, a unified `files` array, a 64-bit GLB version 3, thumbnails, promotion of `EXT_texture_webp`, `KHR_materials_emissive_strength`, `KHR_mesh_quantization` and `KHR_node_visibility` into core, and deprecation of multiple scenes. As of 2026-10-25 it is a preview under active development, not a registry document, despite a press headline to the contrary. There is no "glTF 3" effort.

**Licensing.** The repository's LICENSE file puts the AsciiDoc spec sources under CC-BY-4.0, which permits modification, while the Khronos policy quoted above covers the published text and permits only unmodified reproduction; both are recorded here because they differ. Tooling is Apache-2.0; ratified extension text is under the Khronos specification copyright. No single reference library: Khronos ships the glTF Sample Viewer (JavaScript, Apache-2.0, the BRDF reference named in Appendix B of the spec) and the glTF-Validator (Dart). Compression depends on Google's Draco (C++/JS, Apache-2.0, 1.5.9 on 2026-10-16) and meshoptimizer (C++, MIT, v1.3 on 2026-09-25).

**The extension registry as of 2026-10-25.** Ratified KHR: animation_pointer, draco_mesh_compression, gaussian_splatting, interactivity, lights_punctual, materials_anisotropy, materials_clearcoat, materials_dispersion, materials_emissive_strength, materials_ior, materials_iridescence, materials_sheen, materials_specular, materials_transmission, materials_unlit, materials_variants, materials_volume, mesh_quantization, node_hoverability, node_selectability, node_visibility, texture_basisu, texture_transform, xmp_json_ld. Multi-vendor extensions in the ratified table: EXT_mesh_gpu_instancing, EXT_meshopt_compression, EXT_texture_webp. In progress: materials_diffuse_transmission (Release Candidate), materials_subsurface (Initial Draft), physics_rigid_bodies and collision_shapes (Review Draft), texture_procedurals (Initial Draft), accessor_float64 (Review Draft). Four extensions ratified in 2026 show up only in registry commits (interactivity, hoverability and selectability on 2026-08-30; gaussian_splatting on 2026-09-03) while the Khronos press releases still say "submitted for ratification".

**The material model, for comparison with OpenPBR.** This matters because a Flux material struct has to accept both. The core is a Burley-style mix: `material = mix(dielectric_brdf, metal_brdf, metallic)`, both lobes sharing `baseColor` and `roughness`, GGX distribution with Smith masking, α = roughness², a fixed dielectric IOR of 1.5 (F0 = 0.04).

Each extension adds one lobe or changes one term, and each is off by default:

| Extension | What it adds |
|---|---|
| `ior` | replaces the fixed 1.5 |
| `specular` | weights and tints F0 |
| `transmission` | blends the diffuse lobe with a specular BTDF |
| `volume` | Beer-Lambert absorption; must pair with transmission |
| `dispersion` | 20 / Abbe number; needs volume and ior |
| `iridescence` | replaces Fresnel with a thin-film term |
| `anisotropy` | stretches the GGX lobe along the tangent |
| `sheen` | a Charlie-distribution lobe over the base |
| `clearcoat` | a fixed-IOR-1.5 Fresnel coat that also attenuates emission |
| `emissive_strength` | lifts emission above 1.0 |

A maintainer explained on the 2.1 tracking issue that this is why PBR extensions stay out of core. Read against the OpenPBR table above, the two models now cover the same lobes under different names (`coat_*` vs `clearcoat*`, `fuzz_*` vs `sheen*`, `thin_film_*` vs `iridescence*`). The gap is closing from the glTF side too, but not yet in the registry: `KHR_materials_coat` (PR 2534), `KHR_materials_fuzz` (PR 2538), `KHR_materials_diffuse_roughness` (PR 2481) and `KHR_materials_scatter` (PR 2579, replacing `volume_scatter`) are open pull requests on the glTF repository as of 2026-10-25, not ratified and not in the registry's in-progress list, and `KHR_materials_openpbr` has no public Khronos proposal at all. Babylon.js implements all of them ahead of ratification and marks the OpenPBR one experimental ([framework-support-matrix.md](./framework-support-matrix.md#babylonjs)).

### KTX 2.0 and Basis Universal: GPU-ready textures

**The problem it solved.** PNG and JPEG carry one image at one size. A GPU wants mip chains, cube and array layouts and block-compressed payloads, and no single block format runs on every GPU (desktop wants BC7, mobile wants ASTC or ETC2, the web wants whichever the device has). KTX 2.0 is a container keyed by Vulkan `VkFormat` plus a data-format descriptor, with per-level supercompression and Basis Universal payloads that transcode at load time to whatever the GPU supports.

**Governance and version.** Ratified 2020-08-14; current document is KTX File Format Specification 2.0.4, 2025-02-20. Supercompression schemes: none, BasisLZ (for ETC1S), Zstandard, ZLIB. `KHR_texture_basisu` requires dimensions that are multiples of 4, ETC1S with BasisLZ or UASTC raw or Zstd, and a full mip chain if minification is used.

**Reference implementation.** KTX-Software's `libktx` in C/C++ with WebAssembly, Java and Python wrappers; Apache-2.0 except one Ericsson-licensed ETC decoder that can be excluded at build time. Latest stable v4.4.2, 2025-10-04; v5.0.0 release candidates (2026-05-01 and 2026-08-17) add UASTC HDR and wait on an unpublished spec revision. Basis Universal itself is Binomial's, Apache-2.0, C++17 with a single-file transcoder that compiles to WebAssembly; v2.50 on 2026-08-03 adds UASTC HDR and ASTC HDR modes. The Khronos Data Format Specification v1.4.0 (February 2025) that defines the block layouts is, by its own front matter, not a ratified specification and may not be redistributed.

---

## W3C and the Web Image Formats

### SVG

Vector art needed one text format that design tools, browsers and plotters all agree on, and SVG has been that since 2001; the path grammar and the arc problem are covered in [`notes/themes/vector-graphics/svg-interop.md`](../../notes/themes/vector-graphics/svg-interop.md), so this section is governance only. Both editions are under the W3C Software and Document License. SVG 1.1 Second Edition has been a W3C Recommendation since 2011-08-16. **SVG 2 is still a Candidate Recommendation**, with the latest snapshot dated 2026-10-06 (comments due 2026-12-01), a corrections-and-interoperability revision. What SVG 2 added relative to 1.1: `href` without the `xlink` prefix, `paint-order`, `context-fill` and `context-stroke`, `auto-start-reverse` markers, `vector-effect`, `inline-size`, `tabindex` and ARIA. What it removed: SVG Fonts, `tref`, `xml:base`, `baseProfile` and `version`; filters, masking and color moved to CSS. **Mesh gradients, hatches and `z-index` were deferred to a future version**, and the 2026 snapshot dropped `miter-clip` and `arcs` from `stroke-linejoin`. The draft working-group charter lists SVG 2's completion as undetermined, maintenance and testing only. For a framework, the practical target is SVG 1.1 plus the SVG 2 features browsers implement, which is also what the `usvg` crate parses.

### PNG Third Edition

**The problem it solved.** PNG 2003 had no animation, no HDR signalling and no EXIF, so those travelled as vendor chunks. The Third Edition, a W3C Recommendation of 2025-06-24, folds in APNG, `cICP` (coding-independent code points for primaries and transfer function, including PQ and HLG), `mDCV` (mastering display color volume), `cLLI` (content light level) and `eXIf`, and registers `image/apng`. A Fourth Edition exists only as an editor's draft, scoped as a smaller HDR/SDR interoperability update; no Working Draft has been published. libpng 1.6.59 (2026-09-30) reads `cICP`, `mDCV` and `cLLI`; APNG waits for libpng 2.0. The Rust `png` crate already handles APNG.

### WebP, AVIF, JPEG XL

Each of the three newer web image formats answers the same question, how to beat JPEG and PNG on size at equal quality, with a different owner. **WebP** is Google's: RIFF container with VP8 lossy and VP8L lossless streams, alpha and animation, written up as RFC 9649 (November 2024, Informational, not Standards Track). libwebp is C, BSD-3-Clause with a patent grant, at v1.6.0 (release date not fetched). No standards body.

**AVIF** is the Alliance for Open Media's: AV1 still images in the HEIF container with alpha, HDR and layered progressive decoding. AV1 Image File Format 1.2.0, 2025-10-16. Software is BSD-3-Clause-Clear plus the AOM Patent License 1.0 (royalty-free, defensive termination). libavif is C99, v1.4.2 on 2026-05-26, and needs an AV1 codec (libaom, dav1d, rav1e or SVT-AV1), which is the real footprint; in Rust, decode still needs libdav1d.

**JPEG XL** is ISO/IEC 18181 in four parts (codestream, file format, conformance, reference software); lossless JPEG recapture, HDR, animation, progressive. Part 1 edition 2 is from July 2024. libjxl is C++, BSD-3-Clause with a patent grant, v0.12.0 on 2026-07-01. The Rust `jxl-rs` decoder (BSD-3-Clause) states it is the decoder used by Chrome and Firefox; Firefox 158 (2026-10-13) and Chrome 155 enabled JPEG XL by default, Safari has had partial support since 17, Edge has not enabled it. This is the year JPEG XL became a web format.

---

## ISO and De-Facto Formats

**PDF (ISO 32000-2:2020)** is an export target only. The PDF Association has distributed the 2020 revision and its amendment at no cost since April 2023. Rust has two strong writers (`krilla`, `pdf-writer`).

**OBJ and MTL** have no steward. OBJ is an appendix of Wavefront's Advanced Visualizer manual (format release 3.0): `v`, `vt`, `vn`, `f`, `l`, groups, free-form curves and surfaces almost nobody implements. MTL is from Alias|Wavefront "File Formats 4.2", October 1995: `Ka`, `Kd`, `Ks`, `Ns`, `Ni`, `d`, eleven `illum` models, `map_*` and `bump`. **There is no roughness or metallic in MTL**; the PBR keys seen in the wild (`Pr`, `Pm`, `Ke`) are unspecified vendor additions. OBJ remains the lowest-common-denominator mesh exchange precisely because nothing about it can change.

**PLY** was designed at Stanford and UNC for research models: a header declaring elements and typed properties, then ASCII or binary (either endianness) data. No license on Greg Turk's reader. Its current life is as the container for Gaussian splats, which is why three.js and Babylon have splat-specific PLY loaders.

**STL** is 3D Systems' stereolithography format from October 1989: facets with normals, ASCII or 50-byte binary, no units, no color in the base spec. Fabrication's lingua franca and nothing else.

**3MF** is the 3MF Consortium's (a Joint Development Foundation project under the Linux Foundation; members pledge patents royalty-free). Core Specification v1.4.0, 2025-02-11; adopted as ISO/IEC 25422:2025 at v1.3.0. Extensions for materials, beam lattices, production, secure content, booleans, toolpaths (1.0.0, 2026-09-17) and volumetrics (0.8.0). lib3mf is C++, BSD-2-Clause, v2.5.0 (2026-02-24); Rust has `threemf`. The modern replacement for STL when color, materials or multiple objects matter.

**Radiance HDR (RGBE)** comes from LBNL's Radiance: an ASCII header, a resolution line, then 4-byte pixels with three mantissas and a shared exponent, run-length encoded. Radiance Software License 2.0 (BSD-style). No versioning, no body, and still the most common environment-map interchange because every tool reads it.

**TIFF** is a borderline case: the 6.0 specification (1992) is held by Adobe, which does not publish its tag registry; the wrapper is documented and patent-free (LZW expired in 2004). libtiff 4.7.2 (release date not fetched) is C under a BSD/MIT-style license. Open implementation, no open steward.

**DDS** is Microsoft's Direct3D container: documented (`DDS_HEADER`, optional `DXT10` header with a `DXGI_FORMAT`, mips, cubes, arrays) but with no published license for the format. The BC1 to BC7 block layouts inside it are specified in Khronos Data Format 1.4, which is itself non-ratified and non-redistributable. Open substitute: KTX 2.0, which carries the same blocks.

**FBX fails all three criteria.** There is no published specification; access is through Autodesk's C++ FBX SDK 2020.3.11 (the current download as of 2026-10-25) under a EULA that forbids reverse engineering and modification and has no WebAssembly target. Clean-room readers exist outside the EULA: ufbx (single-file C, MIT or Unlicense, binary and ASCII from version 3000) and OpenFBX (MIT). three.js and Babylon both wrote their own parsers. The open substitute is glTF for runtime delivery and USD for DCC interchange.

**LAS and E57 (point clouds).** LAS is maintained by the ASPRS working group on GitHub (LAS 1.5 R00, 2025-08-26) with an ASPRS copyright and no license on the text. E57 is ASTM E2807-11(2019), a paid document; libE57Format is C++14 under the Boost license. Both are readable, neither has a permissive spec license. Rust has `las` and `e57`.

---

## 2D Vector and Motion

### Lottie: a specification at last

**The problem it solved.** Bodymovin's After Effects export had no specification, so every player (lottie-web, rlottie, Skottie, ThorVG) implemented a different subset. The Lottie Animation Community, formed 2024-01-31 as a Joint Development Foundation project, wrote one. Governed under the Community Specification License 1.0.

**Versions.** v1.0 on 2024-09-17, covering "all well known, commonly implemented, documentable features"; v1.0.1 on 2025-04-15 (pucker/bloat, gradient and dash clarifications). IANA registered `.lot` and `video/lottie+json` on 2025-02-24. No 2026 release; the "latest" page is still marked work in progress.

**dotLottie** is LottieFiles' `.lottie` zip bundle (JSON plus assets, themes and state machines), spec v2.0, MIT. Its reference runtime `dotlottie-rs` (v0.1.58, 2026-06-22) is Rust over a vendored C++ ThorVG, with a wasm-bindgen target. The pure-Rust player is Linebender's `velato`, which skips text and most effects.

### Rive: open runtime, vendor format

The Rive runtimes are MIT: `rive-runtime` is the C++ core with Metal, Vulkan, D3D, OpenGL and WebGL backends, tagged runtime-v0.1.629 and pushed 2026-10-24. The `.riv` binary format is documented (header, version, a table of property keys, a skip-unknown rule, major version 7) but the page attaches no license to the format, does not call it a specification, and does not invite third-party readers. The editor is proprietary and there is no stewarding body. Readable under MIT, not governed; the Rust binding `rive-rs` has been dormant since July 2025. Against the brief's criterion, Rive is not open.

### IconVG

Nigel Tao's compact binary vector format for icons, Apache-2.0, with C and Go decoders. The README warns the format is experimental and subject to incompatible changes; it moved from `google/iconvg` to a personal repository in February 2026. Not a candidate.

---

## Reading the Landscape

Three patterns are worth carrying into the [recommendations](../../insights/open-formats.md).

**The 2026 moves are all toward convergence.** glTF 2.1 promotes four extensions into core and adds external-asset packaging, a role usdz already plays for USD. MaterialX ships OpenPBR as a first-class shading model and translates Standard Surface to glTF PBR. OpenUSD 26.08 pins MaterialX 1.39.5 and usdz 1.3 admits AVIF. Babylon writes a draft `KHR_materials_openpbr` ahead of any Khronos proposal. The scene, material and texture formats are growing toward each other, and a framework that picks the shared vocabulary (OpenPBR's lobe names, KTX2's block formats, USD's prim paths) will fit all of them.

**Pure-Rust coverage follows the audience, not the steward.** Formats with a large community outside film (PNG, SVG, glTF, EXR, KTX2, PDF, and since 2026 USD) have pure-Rust crates. Formats whose users are film pipelines (MaterialX, OpenColorIO, OpenVDB writing, OpenTimelineIO, Alembic) do not, even when the format is plain XML or JSON. The codec corner (Basis, Draco, meshopt) is C++ bindings everywhere. See [rust-crates.md](./rust-crates.md#the-gap-list).

**"Open" needs a footnote per format**, which is what the verdict table at the top records. USD's spec is no-derivatives. Khronos's data-format spec is non-redistributable. KTX's reference library has one Ericsson-licensed file. Rive's runtime is MIT and its format is not. None of these blocks Flux from reading or writing the format, but each is the kind of detail that decides whether a Flux fork could ever ship a modified reader, and the brief's criterion exists to catch exactly that. The four governance shapes in the Key Insight are the short form of that table.

**Where to go next.** [`insights/open-formats.md`](../../insights/open-formats.md) turns this landscape into a tier per format and a stance on USD; [`framework-support-matrix.md`](./framework-support-matrix.md) shows what the studied frameworks did with each format; [`rust-crates.md`](./rust-crates.md) is the dependency list.

---

## Sources

Fetched 2026-10-25. GitHub release dates, tags and license identifiers were read from `api.github.com` `repos/<owner>/<repo>`, `/releases` and `/tags`.

**ASWF roster and projects:** https://raw.githubusercontent.com/AcademySoftwareFoundation/aswf-landscape/main/landscape.yml · https://www.aswf.io/about/ · https://www.aswf.io/news/openexr-and-opencue-join-aswf/ · https://www.aswf.io/news/ocio-joins-aswf/ · https://www.linuxfoundation.org/press/press-release/opentimelineio-joins-aswf · https://www.cgchannel.com/2026/04/aswf-adopts-openpgl-after-intel-ends-development/

**OpenEXR:** https://github.com/AcademySoftwareFoundation/openexr · https://github.com/AcademySoftwareFoundation/openexr/releases/tag/v3.5.0 · https://openexr.com/en/latest/news.html · https://openexr.com/en/latest/TechnicalIntroduction.html · https://www.aswf.io/news/aswf-deep-dive-openexr-origin-story-part-1/

**MaterialX:** https://materialx.org/ · https://github.com/AcademySoftwareFoundation/MaterialX/releases/tag/v1.39.5 · https://raw.githubusercontent.com/AcademySoftwareFoundation/MaterialX/main/documents/Specification/MaterialX.Specification.md · https://raw.githubusercontent.com/AcademySoftwareFoundation/MaterialX/main/CHANGELOG.md

**OpenPBR:** https://academysoftwarefoundation.github.io/OpenPBR/ · https://github.com/AcademySoftwareFoundation/OpenPBR/releases · https://arxiv.org/html/2512.23696 · https://blogs.windows.com/windowsdeveloper/2026/04/02/part-3-babylon-js-9-0-openpbr-and-additional-engine-updates/ · https://doc.babylonjs.com/features/featuresDeepDive/materials/using/OpenPBR/ · https://dev.epicgames.com/documentation/en-us/unreal-engine/materialx-support-in-unreal-engine · https://www.cgchannel.com/2026/09/chaos-releases-vantage-3-4/

**OpenColorIO, ACES:** https://opencolorio.org/ · https://github.com/AcademySoftwareFoundation/OpenColorIO/releases/tag/v2.6.0 · https://opencolorio.readthedocs.io/en/latest/concepts/overview/overview.html · https://acescentral.com/aces-enters-a-new-chapter-of-open-collaboration/ · https://docs.acescentral.com/background/about-aces-2/

**OpenVDB, OpenTimelineIO, Alembic:** https://www.openvdb.org/about/ · https://github.com/AcademySoftwareFoundation/openvdb/releases/tag/v13.1.0 · https://github.com/AcademySoftwareFoundation/OpenTimelineIO/releases · https://opentimelineio.readthedocs.io/en/stable/tutorials/otio-file-format-specification.html · https://github.com/alembic/alembic/releases · https://github.com/alembic/alembic/blob/master/LICENSE.txt

**AOUSD and OpenUSD:** https://aousd.org/ · https://www.linuxfoundation.org/press/announcing-alliance-for-open-usd-aousd · https://aousd.org/news/core-spec-announcement/ · https://forum.aousd.org/t/core-spec-1-0-is-here/2796 · https://aousd.org/blog/aousd-year-in-review-a-landmark-year-for-openusd-standardization-and-growth-in-2025/ · https://aousd.org/news/alliance-for-openusd-drives-global-3d-data-interoperability-and-agentic-ai-workflows-with-new-core-specification-milestones-and-members/ · https://github.com/aousd/specifications-public · https://github.com/aousd/core-spec-supplemental-public · https://aousd.org/blog/new-release-of-openusd-v24-11/ · https://forum.aousd.org/t/openusd-26-11-disables-support-for-binary-usd-files-older-than-version-0-4-0/3057 · https://openusd.org/release/press_opensource_release.html · https://openusd.org/release/glossary.html · https://openusd.org/release/spec_usdz.html · https://github.com/PixarAnimationStudios/OpenUSD/releases/tag/v26.11.1 · https://raw.githubusercontent.com/PixarAnimationStudios/OpenUSD/release/CHANGELOG.md · https://raw.githubusercontent.com/PixarAnimationStudios/OpenUSD/release/README.md · https://github.com/PixarAnimationStudios/OpenUSD/blob/release/BUILDING.md · https://raw.githubusercontent.com/PixarAnimationStudios/OpenUSD/release/VERSIONS.md · https://github.com/PixarAnimationStudios/OpenUSD/blob/release/LICENSE.txt · https://www.apple.com/newsroom/2018/06/apple-unveils-arkit-2/

**Khronos:** https://registry.khronos.org/glTF/ · https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html · https://github.com/KhronosGroup/glTF/blob/main/extensions/README.md · https://www.khronos.org/news/press/khronos-releases-gltf-2.0-specification · https://www.khronos.org/gltf/ · https://www.khronos.org/blog/introducing-gltf-2.1-with-complex-scenes · https://github.com/KhronosGroup/glTF/issues/2585 · https://www.khronos.org/blog/khronos-at-siggraph-2026 · https://www.khronos.org/news/press/gltf-interactivity-extension-submitted-for-ratification · https://www.khronos.org/news/press/gltf-gaussian-splatting-press-release · https://github.com/KhronosGroup/glTF-Sample-Viewer · https://github.com/google/draco · https://github.com/zeux/meshoptimizer · https://registry.khronos.org/KTX/specs/2.0/ktxspec.v2.html · https://github.com/KhronosGroup/KTX-Software/blob/main/LICENSE.md · https://github.com/KhronosGroup/KTX-Software/releases · https://github.com/BinomialLLC/basis_universal · https://www.khronos.org/ktx/ · https://registry.khronos.org/DataFormat/specs/1.4/dataformat.1.4.html

**W3C and web images:** https://www.w3.org/TR/SVG11/ · https://www.w3.org/TR/SVG2/ · https://www.w3.org/TR/SVG2/changes.html · https://www.w3.org/news/2026/updated-candidate-recommendation-scalable-vector-graphics-svg-2/ · https://w3c.github.io/charter-drafts/2026/svg-wg.html · https://www.w3.org/TR/png-3/ · https://w3c.github.io/png/ · https://w3c.github.io/charter-drafts/2025/png-wg.html · https://www.w3.org/groups/wg/png/publications/ · http://www.libpng.org/pub/png/libpng.html · https://raw.githubusercontent.com/pnggroup/libpng/libpng16/CHANGES · https://datatracker.ietf.org/doc/rfc9649/ · https://github.com/webmproject/libwebp · https://aomediacodec.github.io/av1-avif/ · https://aomedia.org/license/patent-license/ · https://github.com/AOMediaCodec/libavif · https://jpeg.org/jpegxl/ · https://github.com/libjxl/libjxl · https://github.com/libjxl/jxl-rs · https://caniuse.com/jpegxl · https://www.firefox.com/en-US/firefox/158.0/releasenotes/

**ISO and de facto:** https://www.loc.gov/preservation/digital/formats/fdd/fdd000474.shtml · https://paulbourke.net/dataformats/obj/ · https://paulbourke.net/dataformats/mtl/ · https://paulbourke.net/dataformats/ply/ · https://sites.cc.gatech.edu/projects/large_models/ply.html · https://www.fabbers.com/tech/STL_Format · https://3mf.io/spec/ · https://3mf.io/news/2025/07/3mf-an-iso-standard-for-the-future-of-additive-manufacturing/ · https://github.com/3MFConsortium/spec_core · https://github.com/3MFConsortium/lib3mf · https://radsite.lbl.gov/radiance/refer/Notes/picture_format.html · https://github.com/LBNL-ETA/Radiance/blob/master/License.txt · https://www.loc.gov/preservation/digital/formats/fdd/fdd000022.shtml · https://libtiff.gitlab.io/libtiff/ · https://learn.microsoft.com/en-us/windows/win32/direct3ddds/dx-graphics-dds-pguide · https://aps.autodesk.com/developer/overview/fbx-sdk · https://unity.com/legal/autodesk-fbx · https://github.com/ufbx/ufbx · https://github.com/nem0/OpenFBX · https://github.com/ASPRSorg/LAS · https://www.astm.org/e2807-11r19.html · https://github.com/asmaloney/libE57Format

**2D vector and motion:** https://lottie.github.io/news/ · https://lottie.github.io/news/announcing-lottie-specification-1.0.1/ · https://lottie.github.io/lottie-spec/latest/governance/Notices/ · https://www.linuxfoundation.org/press/lottie-animation-community-announces-lottie-v1.0-specification · https://dotlottie.io/ · https://github.com/LottieFiles/dotlottie-rs · https://rive.app/docs/runtimes/getting-started · https://rive.app/docs/runtimes/advanced-topic/format · https://github.com/rive-app/rive-runtime · https://github.com/rive-app/rive-rs · https://github.com/nigeltao/iconvg
