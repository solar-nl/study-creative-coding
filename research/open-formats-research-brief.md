# Research Brief: Open Formats for 2D and 3D Assets and Content

## Context

Flux (the Rust creative-coding framework this repository informs) authors projects as data: `.rsym` / `.rgraph` / `.rproj` files that describe an operator graph. Everything the graph *consumes* arrives as an asset: a mesh, a texture, an environment map, a vector drawing, a material definition, an animation. Everything the graph *produces* that leaves the process is also a file: a rendered frame, an exported scene, a vector sheet for a plotter.

Every one of those files has a format, and the choice of formats is a design decision with long consequences. Pick a format with a proprietary SDK and the web build cannot read it. Pick one that only encodes triangles and the material pipeline starts from zero on every import. Pick one with no Rust implementation and the framework carries a C++ dependency on every platform.

This brief scopes a research pass on **open formats**: specifications with a published document, a permissive license, and at least one open-source reference implementation, so that Flux can read and write them on desktop, mobile and web without a vendor dependency. The prompt that triggered it named Universal Scene Description, OpenPBR, OpenEXR and SVG; the research should cover the whole asset surface those four imply.

This is outside the repository's usual lane (framework source under study), which is why the work products live in `research/open-formats/` rather than `notes/`. The one part that belongs to the repo's core purpose, which studied frameworks actually load and write which formats, gets the same `file:line` treatment as any other note.

## Openness criterion

A format is **in scope** when all three hold:

1. **A published specification** anyone can read without signing an agreement (ISO standards count even though the PDF costs money; the text is normative and public).
2. **A permissive license** on the specification and on the reference implementation (Apache-2.0, BSD, MIT, or a W3C/Khronos royalty-free policy).
3. **A stewarding body or open-source project** that accepts contributions: the Academy Software Foundation (ASWF), the Alliance for OpenUSD (AOUSD), the Khronos Group, the W3C, an ISO working group, or a foundation-hosted open-source repository.

Formats that fail one of the three but are unavoidable in practice (FBX, PSD, DDS) get a one-paragraph mention explaining the failure and what the open substitute is. They do not get a full entry. Borderline cases are recorded as found rather than forced into a bucket: Alembic is BSD-licensed but foundation-less (it was never an ASWF project), and OpenUSD's code license is Apache-2.0 with a stricter trademark clause while the AOUSD specification text is CC-BY-ND.

## Domains

| Domain | Formats to study in depth | One paragraph only |
|---|---|---|
| **Scene and geometry** | OpenUSD (`.usd`, `.usda`, `.usdc`, `.usdz`), glTF 2.0 (`.gltf`, `.glb`), OBJ, PLY, STL | Alembic, 3MF, FBX (closed), point-cloud formats (LAS, E57) |
| **Material and shading** | OpenPBR, MaterialX, glTF PBR core plus `KHR_materials_*` extensions | Autodesk Standard Surface, Disney Principled (lineage, not formats), OSL |
| **Images and textures** | OpenEXR, PNG (3rd edition), KTX 2.0 with Basis Universal, Radiance HDR | AVIF, WebP, JPEG XL, TIFF, DDS (closed container, open block formats) |
| **2D vector and motion** | SVG (link to `notes/themes/vector-graphics/svg-interop.md` rather than redo path parsing), Lottie, Rive (if the spec is open) | PDF (ISO 32000, as an export target), IconVG |
| **Color, volumes, timeline** | OpenColorIO, ACES, OpenVDB and NanoVDB, OpenTimelineIO | Each gets a paragraph; none a full entry |

Already covered elsewhere in this repo and linked rather than repeated: SVG path semantics (`svg-interop.md`), fonts and OpenType (`notes/themes/typography/`), color spaces and perceptual models (`notes/themes/core/color-systems.md`).

## What to capture per format

For every in-depth format:

1. **What it describes** in one sentence, and the problem it was created to solve (lead with the problem, per `STYLE_GUIDE.md`).
2. **Governance**: stewarding body, year it became open, license of the spec and of the reference implementation.
3. **Current version** with the URL of the page that states it and the date it was published. The research runs in late October 2026; several of these specs moved during 2026, so nothing comes from memory.
4. **Reference implementation** language and size (a C++ library with a Python layer is a different cost from a 2,000-line Rust crate).
5. **Rust ecosystem**: crate name, pure Rust or bindings, last release date, whether it compiles to `wasm32`.
6. **Studied-framework support**: which frameworks in this repo import or export it, through what mechanism (own parser, Assimp, Batik, the browser), cited as `file:line` at the current pin in `notes/SUBMODULE-PINS.md`.
7. **Flux relevance**: import candidate, export candidate, both, or neither, with the reason.

## Research strands

Three strands run in parallel and are synthesized afterwards.

**Landscape (web).** Per format, items 1 through 4 above. Organize by stewarding body first, because the foundation rosters give a bounded, authoritative list of what counts as open; then by domain. Every version, date and license claim carries a URL.

**Submodule survey (source grep).** Item 6 above. The loaders and exporters directories of three.js and Babylon.js, Filament's `gltfio` and KTX tooling, rend3's glTF path, `vello_svg`, openrndr's SVG loader and orx extensions, OpenFrameworks addons (ofxAssimpModelLoader, ofxSvg), Cinder's ObjLoader and SVG, Processing's PShape SVG/OBJ loaders and p5.js `loadModel`, tixl's and cables' asset operators, apEx and werkkzeug4's own containers.

**Rust crate map.** Item 5 above, in the format the `dependencies` agent already uses: category, crate, maturity, platform coverage.

## The question the recommendations must answer

Flux has a project format of its own. OpenUSD is not just a geometry container; it is a composition engine (layers, references, variants, overrides) that other tools have adopted as *their* scene model. So the USD section has to take a position on one of three stances and state the trade-off:

- **USD as import only**: flatten a stage to meshes, materials and transforms at load; Flux's own graph remains the scene model.
- **USD as interchange**: import and export flattened stages, so Flux can sit in a DCC pipeline without adopting composition.
- **USD as the scene model**: map `.rsym` / `.rgraph` concepts onto USD prims and layers, inheriting composition and the ecosystem at the cost of a C++ runtime dependency or an incomplete Rust reimplementation.

Evidence to gather: how tixl, cables and Filament treat scene files (as data they flatten, or as a model they adopt), and the state of pure-Rust USD readers.

## Work products

| File | Content |
|---|---|
| `research/open-formats-research-brief.md` | This document |
| `research/open-formats/README.md` | Landscape by stewarding body and domain, with the format ecosystem diagram |
| `research/open-formats/framework-support-matrix.md` | Submodule survey: which studied framework reads or writes which format, with citations |
| `research/open-formats/rust-crates.md` | Rust crate map per format |
| `insights/open-formats.md` | Flux tiering table (import tier 1, import tier 2, export, ignore) with one sentence of why per row, and the USD stance |

Registry updates: `insights/README.md`, `notes/themes/README.md` and `notes/themes/systems/asset-loading.md` (which is a stub and should point here), `CHANGELOG.md` dated 2026-10-25.

## Out of scope

Audio and video codecs (a separate study), fonts (covered), network and device protocols such as OSC and MIDI (covered under extension systems), shader languages as formats (SPIR-V, WGSL; covered under `notes/themes/rendering/shader-abstractions.md`).
