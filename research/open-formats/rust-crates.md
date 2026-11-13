# Rust Crate Map: What a wgpu Framework Can Read and Write Without C++

> For each open format, which Rust crate covers it, how mature it is, and whether it runs on `wasm32`?

Part of the [open formats research](./README.md). Scope and criteria are in the [research brief](../open-formats-research-brief.md). Companion to [`framework-support-matrix.md`](./framework-support-matrix.md), which records what the studied frameworks do with the same formats.

## Key Insight

> **The pure-Rust surface is wider than it was a year ago, and the gaps are specific.** Every image format Flux would want has a pure-Rust decoder, and most compile to the web (documented for `png`, `image`, `exr`, `tiff` and `usvg`); the exceptions are KTX2, where the crate parses the container but Basis transcoding is C++, and AVIF decode, which needs libdav1d. Both scene containers (glTF and, since 2026, USD with composition), OBJ, PLY, STL, 3MF, SVG in and out, PDF out and Lottie are pure Rust too, with `wasm32` inferred rather than documented for several. The material-definition and color-management corner is empty: MaterialX and Alembic have placeholder crates, OpenColorIO has C++ bindings, and OpenPBR as a data model, OpenTimelineIO, NanoVDB and ACES have nothing. The codec corner (Basis Universal, Draco, meshoptimizer) is bindings to C++ with one wasm-capable exception.

---

## How to Read the Tables

Every version, release date, license and download count below was fetched from the crates.io API on 2026-10-25 (`https://crates.io/api/v1/crates/<name>`); repository activity from the GitHub API the same day. "dl/90d" is crates.io's recent-downloads counter, a rough adoption signal. The "wasm32" column uses four values: **Yes** when the crate's own documentation claims the target; **Yes in practice** when a known project ships it to the web (Bevy, typst, resvg); **likely** when the crate is pure Rust with no obvious platform dependency but nobody has said so; **?** when the research did not check. Fields the research could not verify say so rather than guess.

The question each row answers is the one the [brief](../open-formats-research-brief.md) asks: if Flux adopts this format, does it carry a C++ toolchain on every platform, or not?

---

## Scene and Geometry

| Format | Crate | Version (date) | License | Pure Rust? | wasm32 | dl/90d | Notes |
|---|---|---|---|---|---|---|---|
| **OpenUSD** | [`openusd`](https://crates.io/crates/openusd) | 0.8.0 (2026-10-11) | MIT | Yes, "no C++ dependencies" | Not documented; CI covers Linux, macOS, Windows. Dependencies (`zip`, `lz4_flex`, `logos`, optional `memmap2`) have no native code, so likely | 18.9k | Reads and writes all three formats; full composition per its README; tested against the AOUSD Core Specification; pre-1.0. Detail in [USD in Rust](#usd-in-rust-where-it-stands) below. |
| OpenUSD | `openusd-rs` | 0.1.0 (2025-07-24) | MIT/Apache-2.0 | Yes | ? | 20 | Earlier attempt, reads flattened files only. Superseded. |
| **glTF 2.0** | [`gltf`](https://crates.io/crates/gltf) + `gltf-json` | 1.4.1 (2024-05-10) | MIT/Apache-2.0 | Yes | Yes in practice (Bevy ships it to web) | 2.64M | The reader everyone uses (rend3, Bevy). Feature flags: `KHR_lights_punctual`, `KHR_materials_{emissive_strength, ior, pbrSpecularGlossiness, specular, transmission, unlit, variants, volume}`, `KHR_texture_transform`. **No flags for clearcoat, sheen, iridescence, anisotropy, dispersion, texture_basisu, draco, meshopt or mesh_gpu_instancing**; those arrive as raw JSON through the `extensions` feature. Repo pushed 2026-05-11 with 90 open issues, but no release in 17 months. Writing is possible through `gltf-json` serde types. |
| OBJ / MTL | [`tobj`](https://crates.io/crates/tobj) | 4.0.5 (2026-08-02) | MIT | Yes | `async` feature aimed at wasm; buffer loading works | 731k | Loads OBJ and MTL. Its README recommends glTF for new work. |
| OBJ / MTL | `obj-rs` | 0.7.4 (2024-09-28) | Apache-2.0/MIT | Yes | likely | 36k | Alternative. |
| PLY | [`ply-rs-bw`](https://crates.io/crates/ply-rs-bw) | 4.0.1 (2026-07-24) | MIT | Yes | likely | 667k | The maintained fork. The original `ply-rs` is 0.1.3 from 2020-08-27 and still gets 202k downloads a quarter, so check which one a dependency pulls in. |
| STL | [`stl_io`](https://crates.io/crates/stl_io) | 0.11.0 (2026-03-15) | MIT | Yes | likely | 1.0M | ASCII and binary, read and write. |
| 3MF | [`threemf`](https://crates.io/crates/threemf) | 0.8.1 (2026-10-20) | 0BSD | Yes | likely | 6k | Small but active. |
| meshoptimizer | [`meshopt`](https://crates.io/crates/meshopt) | 0.7.0 (2026-10-17) | MIT/Apache-2.0 | **No**, FFI to the C++ library | needs a C++ toolchain for wasm | 249k | Needed to decode `EXT_meshopt_compression`. `meshopt-rs` 0.1.2 (2022-11-12) is an incomplete pure-Rust port. |
| Draco | `draco-rs` | 0.1.3 (2025-04-28) | MIT | **No**, bindings to Google's C++ | no | 256 | Negligible adoption. Decoding `KHR_draco_mesh_compression` in Rust means either this or the Draco WASM in the browser only. |
| LAS | `las` | 0.11.1 (2026-08-25) | MIT | Yes | likely | 228k | Point clouds. |
| E57 | `e57` | 0.11.13 (2026-06-17) | MIT | Yes | likely | 37k | Point clouds. |
| Alembic | `alembic` | 0.1.0 (2020-10-20) | BSD-3 | placeholder | | 18 | No implementation. |

---

## Materials and Shading

| Format | Crate | Status | Notes |
|---|---|---|---|
| glTF PBR core + `KHR_materials_*` | `gltf` | Typed access to the eight extensions listed above; raw JSON for the rest | Enough for a material model that stops at transmission and volume. Clearcoat, sheen, iridescence, anisotropy and dispersion need hand-written deserialization from the `extensions` map. |
| **MaterialX** | `materialx` | 0.0.0 (2021-01-03), 2 downloads | **No Rust implementation.** The reference is C++ with a Python layer; the node-definition library and shader generators would be a from-scratch port. |
| **OpenPBR** | none | | OpenPBR is a shading model published as a MaterialX node graph plus a specification document. There is no data-model crate. The realistic route is to implement the BSDF in WGSL from the spec and own the parameter struct. Babylon.js did exactly that in TypeScript ([framework-support-matrix.md](./framework-support-matrix.md#babylonjs)). |
| USD shading (`UsdShade`, `UsdPreviewSurface`) | `openusd-schemas` 0.8.0 | Typed `UsdShade` views, feature-gated | The one Rust path to a material graph in an open container. |

---

## Images and Textures

| Format | Crate | Version (date) | License | Pure Rust? | wasm32 | dl/90d | Notes |
|---|---|---|---|---|---|---|---|
| **PNG** | [`png`](https://crates.io/crates/png) | 0.18.1 (2026-02-14) | MIT/Apache-2.0 | Yes | Yes | 97M | image-rs project. APNG supported. |
| Multi-format | [`image`](https://crates.io/crates/image) | 0.25.10 (2026-03-10) | MIT/Apache-2.0 | Yes by default; AVIF *decode* needs libdav1d through `avif-native` | Yes; docs advise `default-features = false` to avoid thread pools | 68M | Default features: AVIF (encode), BMP, DDS, EXR, Farbfeld, GIF, HDR, ICO, JPEG, PNG, PNM, QOI, TGA, TIFF, WebP. 0.25.7 added CICP awareness via `moxcms`. |
| **OpenEXR** | [`exr`](https://crates.io/crates/exr) | 1.74.2 (2026-07-10) | BSD-3-Clause | Yes, 100% safe code | **Yes**, documented `wasm32-unknown-unknown` target with an npm package; slower without threads, read from byte buffers | 22M | Multipart and deep tiles read; deep scan lines "coded but untested"; DWA compression unsupported; the HTJ2K, LJ2K and ZSTD codecs added in OpenEXR 3.4 and 3.5 were not checked. Repo pushed 2026-10-21. Also exposed through `image`. ASWF announced C++ OpenEXR bindings for Rust in 2021; with `exr` they are unnecessary. |
| Radiance HDR | `image` (`hdr` feature) | as `image` | | Yes | Yes | | Decode, and since 0.25.2 encode (32-bit float RGB). |
| **KTX 2.0** | [`ktx2`](https://crates.io/crates/ktx2) | 0.5.0 (2026-04-19) | Apache-2.0 | Yes | Yes (parser only) | 1.5M | **Container parser only.** It reads levels and the data-format descriptor; it does not transcode Basis, decode zstd or write files. Used by rend3 and the wgpu skybox example for raw block formats. |
| Basis Universal | [`basisu_c_sys`](https://crates.io/crates/basisu_c_sys) | 0.9.1 (2026-09-21) | MIT/Apache-2.0 | **No**, FFI to BinomialLLC C++ | **Yes**: compiles the C++ transcoder to wasm against a vendored libc++ (`basisu_wasm_libcxx`) | 28k | Transcoder by default, encoder behind a feature (large). Optional `wgpu-types` high-level API. The only wasm-capable Basis route in Rust. |
| Basis Universal | `basis-universal` | 0.3.1 (2023-11-02) | MIT/Apache-2.0 | No, FFI | not documented | 134k | Older, more downloads, no release in three years. Bevy's choice. |
| DDS | [`ddsfile`](https://crates.io/crates/ddsfile) | 0.6.0 (2026-04-04) | MIT | Yes | likely | 176k | Container only; block formats are what the GPU takes. |
| TIFF | `tiff` | 0.11.3 (2026-02-10) | MIT | Yes | Yes | 43M | image-rs project. |
| AVIF encode | `ravif` | 0.13.0 (2026-01-19) | BSD-3 | Yes (rav1e) | ? | 19M | Decode still needs libdav1d. |
| JPEG XL | [`jxl-oxide`](https://crates.io/crates/jxl-oxide) | 0.12.6 (2026-05-29) | MIT/Apache-2.0 | Yes (decoder) | likely | 864k | Independent decoder; color management through `moxcms` (pure Rust) or `lcms2` (C). No pure-Rust encoder. Recommended over `jxl` below only because it has the longer release history and `image` integration; either works. |
| JPEG XL | [`jxl`](https://crates.io/crates/jxl) (repo `libjxl/jxl-rs`) | 0.8.0 (2026-10-19) | BSD-3-Clause | Yes (decoder) | likely | 190k | The libjxl project's own Rust decoder, which Chrome 155 and Firefox 158 ship. Younger on crates.io but browser-grade by adoption. |
| ICC / CICP color | `moxcms` | 0.9.1 (2026-09-15) | BSD-3/Apache-2.0 | Yes | likely | 55M | The pure-Rust CMS `image` and `jxl-oxide` lean on. |

---

## 2D Vector and Motion

| Format | Crate | Version (date) | License | Pure Rust? | wasm32 | dl/90d | Notes |
|---|---|---|---|---|---|---|---|
| **SVG parse** | [`usvg`](https://crates.io/crates/usvg) | 0.49.0 (2026-10-24) | Apache-2.0/MIT | Yes | Yes (resvg ships a wasm build) | 13M | The resvg family: parses and simplifies SVG into a flat tree of paths, groups, images and text. Used by typst, nannou's examples and vello. `vello_svg` 0.11 still pins 0.48, so pairing the two means one version behind or two copies in the tree. |
| SVG render (CPU) | [`resvg`](https://crates.io/crates/resvg) | 0.49.0 (2026-10-24) | Apache-2.0/MIT | Yes | Yes | 12M | Reference-quality rasterizer on tiny-skia. |
| **SVG to vello** | [`vello_svg`](https://crates.io/crates/vello_svg) | 0.11.0 (2026-09-10) | Apache-2.0/MIT | Yes | likely (has `wasm-bindgen-test` dev-dependency) | 25k | Pairs usvg 0.48 with **compute-centric `vello` 0.10**, not `vello_gpu`. Its `RenderSink` trait is backend-agnostic, so a Flux that uses `vello_gpu` per [ADR-005](../../insights/architecture-decisions.md) would implement the sink itself. Each release is pinned to a usvg and vello version pair. |
| SVG attribute parsing | `svgtypes` | 0.16.1 (2026-01-09) | Apache-2.0/MIT | Yes | Yes | 13.6M | Paths, transforms, colors, lengths. Enough to parse path data without usvg. |
| SVG write | [`svg`](https://crates.io/crates/svg) | 0.18.0 (2024-09-27) | Apache-2.0/MIT | Yes | Yes | 1.9M | Document builder. No release in two years, but the format does not move either. |
| **PDF write (high level)** | [`krilla`](https://crates.io/crates/krilla) | 0.8.2 (2026-06-04) | MIT/Apache-2.0 | Yes | Yes in practice | 2.0M | Typst's PDF layer: paths, images, gradients, masks, fonts, tagging. No text layout. The best candidate for vector export. |
| PDF write (low level) | `pdf-writer` | 0.15.0 (2026-05-27) | MIT/Apache-2.0 | Yes | Yes | 3.7M | What krilla is built on. |
| PDF write | `printpdf` | 0.12.8 (2026-09-05) | MIT | Yes | ? | 1.7M | Alternative, document-oriented. |
| **Lottie** | [`velato`](https://crates.io/crates/velato) | 0.12.0 (2026-09-10) | Apache-2.0/MIT | Yes | likely (has a wasm example) | 13k | Linebender's Lottie player on `vello` 0.10. Unsupported: text, image embedding, time remapping, and layer effects beyond blur, drop shadow, fill and tint (which need a custom sink). Same vello pairing caveat as `vello_svg`. |
| Lottie / dotLottie | `dotlottie-rs` | crates.io: 0.1.0-alpha.1 (2024-09-18); GitHub: v0.1.58 (2026-06-22) | MIT | Rust shell over a vendored C++ ThorVG, so a C++ toolchain is required | wasm-bindgen target; the web player uses it as its core | 111 | LottieFiles' official runtime; the crates.io publication is a stale alpha, so it is a git dependency if used at all. |
| Rive | `rive-rs` | **not on crates.io**; GitHub `rive-app/rive-rs`, MIT, 134 stars, last push 2025-07-04 | | FFI to rive-cpp with an optional vello backend | ? | | Dormant for over a year. |

---

## Color, Volumes, Timeline

| Format | Crate | Status | Notes |
|---|---|---|---|
| **OpenColorIO** | [`ocio-rs`](https://crates.io/crates/ocio-rs) 0.3.0 (2026-10-23), BSD-3 | FFI to OCIO 2.x C++ | Fresh and active, but a C++ dependency on every platform and not viable on wasm. The older `opencolorio` 0.1.0 is a placeholder. No pure-Rust config-and-LUT engine exists. `moxcms` covers ICC and CICP, which is a different problem (display profiles, not pipeline transforms). |
| ACES | none | | ACES is a set of transforms published as CTL and as OCIO configs; without OCIO it has to be hand-ported into WGSL (the ACES RRT+ODT fit that most realtime engines use is a few dozen lines). |
| **OpenVDB** | [`vdb-rs`](https://crates.io/crates/vdb-rs) 0.6.0 (2024-01-04), MIT | Pure Rust, **read only** | Loads most of the OpenVDB test corpus; fails on `PointDataGrid` files. No writing, no DDA tracing, no delay loading. Repo pushed 2026-10-01 but no release in almost three years. |
| NanoVDB | none | | The GPU-friendly sibling has no crate. The format is a flat buffer meant to be read in shaders, so a WGSL reader is the natural implementation. |
| OpenTimelineIO | none | | No crate. OTIO is JSON, so a serde model is a weekend's work if Flux ever needs it. |

---

## The Gap List

Formats with **no credible pure-Rust implementation**, which would force a C++ dependency, a from-scratch port or a feature cut:

1. **MaterialX** and **Alembic** (placeholder crates only, from 2020 and 2021).
2. **OpenPBR as a data model**, **OpenTimelineIO**, **NanoVDB**, **ACES** (no crate at all; the OpenPBR shading model itself is implementable in WGSL, and OTIO is JSON).
3. **OpenColorIO** (bindings only, no wasm).
4. **Draco** (bindings only, negligible adoption; browser builds can use Google's WASM directly).
5. **meshoptimizer** (bindings, needs a C++ toolchain for wasm; the pure-Rust port is incomplete).
6. **Rive** (dormant bindings, not published).

Formats that are **covered but with a specific hole**:

- **Basis Universal**: C++ in every case, but `basisu_c_sys` has a documented wasm build.
- **KTX2**: `ktx2` parses the container and stops. Flux would combine it with `basisu_c_sys` for supercompressed files, or restrict itself to raw block formats like rend3 does.
- **glTF extensions**: `gltf` has typed access to eight material extensions and raw JSON for the rest; no release since May 2024.
- **OpenVDB**: read only, no point grids.
- **Lottie**: `velato` skips text and most effects.
- **vello_svg and velato** target compute `vello` 0.10, not the sparse-strip `vello_gpu` that ADR-005 picked; both expose a sink trait so the geometry can be redirected. `vello_svg` 0.11 also pins `usvg` 0.48 while 0.49 is current.
- **AVIF decode** needs libdav1d.

---

## USD in Rust: Where It Stands

The brief asked for a careful status paragraph, because the USD stance depends on it.

Before 2026 the honest answer was "no". `openusd-rs` 0.1.0 (July 2025) read flattened files and stopped, and `openusd` (mxpv) had a 0.1.4 the same month. Then `openusd` began roughly monthly releases: 0.2.0 on 2026-04-06, 0.8.0 on 2026-10-11, with the repository still receiving commits on the day of this survey. When composition landed within that sequence was not checked; the 0.8.0 README claims it. Its README claims the full composition engine (sublayers, references, payloads, variants, inherits, specializes, LIVERPS strength ordering, list editing, instancing, relocates, variable expressions), time-sample resolution with layer offsets and value clips, authoring through layer and stage APIs, namespace editing, undo capture and diffs for live sync, asset resolver and file-format plugins, and a test suite checked against the AOUSD Core Specification 1.0.1 supplemental material. The schema crate generates typed views from Pixar's `schema.usda` files for geometry, lighting, materials, skeletons, physics, rendering, volumes and more.

What this research did not do is run it. The claims are the project's own, the API is pre-1.0 and marked unstable, 146 stars is a small community, and `wasm32` is not mentioned anywhere in its documentation or CI matrix (though its dependency list contains nothing that would obviously block it). No second Rust implementation exists to check it against.

So the three stances in the brief now have different costs than they would have had a year ago:

- **USD as import only** is cheap: open a stage, traverse composed prims, read `UsdGeom` meshes and `UsdShade` networks, convert to Flux buffers. One crate, no C++.
- **USD as interchange** adds writing, which the crate also claims; flattening a Flux scene to `.usdc` and zipping to `.usdz` is covered.
- **USD as the scene model** means betting Flux's project format on a single pre-1.0 crate's composition engine, with no second implementation to fall back to short of Pixar's C++ or three.js's JavaScript. That is the stance [`insights/open-formats.md`](../../insights/open-formats.md) argues against, for now.

**Where to go next.** The tier each crate lands in, and the USD stance, are in [`insights/open-formats.md`](../../insights/open-formats.md); what the studied frameworks did with the same formats is in [`framework-support-matrix.md`](./framework-support-matrix.md); the formats themselves are in the [landscape](./README.md).

---

## Sources

crates.io API (`https://crates.io/api/v1/crates/<name>`, fetched 2026-10-25) for every version, date, license and download figure. GitHub API (`https://api.github.com/repos/<owner>/<repo>`) for push dates, stars and issue counts. README excerpts fetched the same day from:

- https://github.com/mxpv/openusd (README: features, compliance, roadmap pointer)
- https://github.com/johannesvollmer/exrs (README: wasm section, feature checklist)
- https://github.com/BVE-Reborn/ktx2 (README: "Parser for the ktx2 texture container format")
- https://github.com/linebender/vello_svg (README: version compatibility table, custom backend)
- https://github.com/linebender/velato (README: unsupported features, layer effects, wasm example)
- https://github.com/Traverse-Research/vdb-rs (README: read-only status, failing point grids)
- https://docs.rs/crate/basisu_c_sys/latest (wasm build details, encoder feature)
- https://github.com/gltf-rs/gltf (README: supported extensions)
- https://github.com/rive-app/rive-rs
