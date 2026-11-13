# Research Brief: Finding Missing Operator Families in an AAA-Class Realtime Graphics Node-Graph Framework

## Context

I'm building a realtime graphics framework (working title: *flux*) organized around an operator-graph model — vvvv/Tooll-style: nodes with typed input/output ports, projects authored as data (`.rsym`/`.rgraph`/`.rproj`), evaluation orchestrated by a runtime that walks the graph each frame and pushes work to wgpu.

**Target envelope: Decima-class.** Flux is meant to compete head-to-head with engines like Decima (Horizon Zero Dawn / Death Stranding) on three axes:

- **Scene scale** — hundreds to thousands of meshes, streaming, LOD, occlusion culling, instanced/indirect rendering.
- **Visual fidelity** — deferred renderer, PBR materials, GI, post-stack (bloom/tonemap/TAA/SSAO/SSR), shadow techniques.
- **Authoring at scale** — a single project will commonly contain **hundreds to thousands of operators across many `.rgraph` / `.rsym` files**, with deeply nested subgraphs and loops with hundreds-to-thousands of iterations.

The framework recently shipped:
- Asset substrate + `LoadTextureOp`
- 7 mesh-primitive operators (Box/Sphere/Plane/Cylinder/Torus/Capsule/InvertedBox)
- `CreateTextureViewOp`
- Compound animation (`TypedCurve` over Scalar/Vec2/Vec3/Vec4/Color)
- Camera/projection operators (`PerspectiveProjection` / `OrthographicProjection` / `LookAtView`)

A walkthrough exercise — *"can the current operator set author a rotating triangle in pure data, no Rust?"* — uncovered a gap I hadn't tracked: **no transform-operator family** (no Rotate/Translate/Scale/MultiplyMatrix nodes that take an animated scalar input and emit a `Matrix4`). Workaround: rotate the camera, not the geometry.

**This research is meant to surface other gaps I'm currently blind to, before they surface as blockers.**

## Reference selection (based on what's in this repo)

Different references serve different purposes. The brief expects depth in the node-paradigm refs and breadth in the code-first refs.

### Primary — node-paradigm references (closest to flux's evaluation model)

| Reference | Location | Why |
|---|---|---|
| **tixl / Tooll3** | `visual-programming/tixl/` | Strongest paradigm match in this repo: pure-data node graph, 3D, demoscene/production lineage from Werkkzeug. C#/.NET — modern node-based 3D creative coding. **Treat as the primary inventory source.** |
| **cables.gl** | `visual-programming/cables/` + `cables_ui/` | Pure-data node graph for WebGL. Different rendering target but same authoring paradigm. Web-deployed, large public op library. |
| **vvvv / VL** | `references/the-gray-book/` (docs only) | Most mature node-based creative-coding system. Source not in repo; use the Gray Book and the public [VL.StandardLibs](https://github.com/vvvv/VL.StandardLibs) catalog for the family inventory. |
| **Werkkzeug / fr_public** | `demoscene/fr_public/` | Historical AAA-scale-via-procedural: .kkrieger shipped a full FPS game in 96KB built entirely as a node graph. **The closest existing precedent for flux's "thousands of operators in a single project" target.** Inventory what node families their tools shipped. |

### Secondary — code-first references (operator-family inventory by analogy)

Code-first creative-coding frameworks aren't node graphs, but their **library / addon catalogs** are the best available inventory of "things creative-coding projects need." A family in three.js's `examples/jsm/` directory is a family flux probably needs an operator for.

| Reference | Location | What to extract |
|---|---|---|
| **openrndr + orx** | `frameworks/openrndr/` + `libraries/openrndr-ecosystem/orx/` | The orx extension catalog (orx-fx, orx-mesh, orx-shade-styles, orx-camera, orx-noise, etc.) is essentially a per-family checklist. Strongest direct analog because openrndr is the closest spiritual match to flux's design philosophy. |
| **three.js** | `libraries/web/threejs/` | `examples/jsm/` is the canonical "what does a 3D scene need" inventory — controls/, lights/, loaders/, postprocessing/, animation/, geometries/, helpers/, exporters/. Map each directory to an operator family. |
| **OpenFrameworks (addons)** | `frameworks/openframeworks/` | Addon ecosystem covers I/O families that node-based tools often punt on (ofxOSC, ofxMidi, ofxKinect, ofxAudioAnalyzer, ofxNetwork). |
| **Processing + toxiclibs** | `frameworks/processing/` + `libraries/processing-ecosystem/toxiclibs/` | toxiclibs has deep computational-geometry / physics inventory (volumetric, mesh modify, particle, color theory). |

### Excluded (deliberately)

- **Game-engine node systems** (Blueprint, ShaderGraph) — not pure-data graphs, paradigm mismatch.
- **p5.js / Processing / DrawBot / Cinder / nannou** — present in repo but immediate-mode 2D or general-purpose code-first; less informative as operator-family sources than openrndr+orx which serves the same role better.
- **Babylon.js / PixiJS** — present in repo but worth checking lightly (Babylon has good camera + post-FX families worth a 1-paragraph mention).

## Research goal

Identify, by systematic comparison across the above references, the **operator families** a pure-data node-graph realtime renderer needs to support **AAA-class workloads at the Decima target envelope** — and flag which of those families flux is likely missing or has only partial coverage of.

## Method

For each **primary node-paradigm reference**, build an op-family inventory by walking the node palette / operator catalog directly (Tooll3 op browser, cables.gl op library, VL.StandardLibs nuget categories, Werkkzeug's known node families from fr_public source + Farbrausch writeups).

For each **secondary code-first reference**, build a family inventory by walking the library/addon directory tree. **Each top-level directory or addon = one candidate family.**

For each family identified, capture:

1. **Name + 1-sentence description**
2. **2–4 representative nodes or symbols** from the most relevant reference (cite path: `tixl/Operators/Types/.../Translate.cs` or `orx/orx-camera/`)
3. **Why it matters** — which scenarios collapse without it
4. **Axis tags** — `[scene]` (scale & complexity), `[visual]` (AAA fidelity), `[authoring]` (1000-op ergonomics). Multiple tags fine.
5. **Cross-reference coverage** — appears in: tixl ✓, cables ✗, vvvv ✓, fr_public ?, orx ✓, three.js ✓
6. **Likelihood it's missing from flux** — confirmed missing / probably missing / partial / present

## Cross-paradigm gap check (AAA features even these refs may UNDER-call)

These references are all creative-coding lineage. They will likely **under-represent** features that AAA game engines need but VJ/installation/film-procedural workflows don't. After the per-reference inventory, add a section listing AAA-renderer families a Decima-class engine has that the references collectively don't cover. Best-guess from public sources (SIGGRAPH/GDC talks, public engine docs, Decima-specific presentations from Guerrilla); **clearly label speculation**.

Candidate categories to investigate:
- Streaming / asset hot-residency
- Spatial scene graph & culling (frustum, occlusion, portal)
- Level-of-detail selection (geometric + shading)
- Skeletal animation + animation state machines + blend trees
- Indirect / GPU-driven rendering (visibility buffer, mesh shaders, indirect draw)
- Virtual textures
- Global illumination (probes, voxel cone tracing, RTX-style, Lumen-like)
- Decals & screen-space techniques
- Multi-view rendering (cubemap, shadow cascades, stereo)

The Werkkzeug/.kkrieger precedent is particularly worth digging into here: it achieved "AAA-feeling" content at extreme scale-by-procedural — what node families made that possible?

## Prior art in this repo (consult before starting)

The repo already contains analysis that may answer some questions:

- `insights/api-recommendations.md`, `insights/architecture-decisions.md`, `insights/rust-specific.md`
- `insights/command-flow-briefing.md`, `insights/command-flow-implementation.md`
- `insights/ibl-environment-lighting.md`
- `notes/themes/` — cross-cutting analyses (color systems, rendering, etc.)
- `notes/per-framework/openrndr/`, `notes/per-framework/nannou/` — most mature per-framework studies

**Read these first.** If a family is already discussed in a theme document, link to it rather than re-deriving.

## Inventory of what flux has (as of 2026-05-21)

- **Geometry primitives**: Box/Sphere/Plane/Cylinder/Torus/Capsule/InvertedBox. **Missing:** triangle/line/point primitives, parametric surfaces, SDF primitives, mesh modify/edit ops, loaded meshes (glTF/OBJ — deferred).
- **Camera**: Perspective/Orthographic projection + LookAtView. **Missing:** orbit, first-person, dolly, jitter (TAA), shake, follow, smooth-damp.
- **Transform**: **NONE.** Matrix4 type exists with `translation` / `rotation_x|y|z` / `scale` constructors in Rust; no operator wraps them. Identified gap.
- **Sources**: Constant, Time, SineWave, Random / PerlinNoise (2D + 3D), LoadTextureOp, LoadShaderOp. **Missing:** audio in, MIDI in, OSC, webcam, video file, network, file watcher, env-var.
- **Animation**: keyframe curves on Scalar/Vec2/Vec3/Vec4/Color drive operator input defaults each frame.
- **GPU pipeline**: CreateRenderPipeline, CreateComputePipeline, CreateBindGroup (compute + render), CreateTexture, CreateBuffer, CreateSampler, CreateTextureView, Draw, DrawIndexed, ComputeDispatch, DispatchIndirect (compute), `Region::RenderPass` / `Region::Loop` / `Region::Accumulate`. **Missing:** DrawIndirect / DrawIndexedIndirect.
- **Sinks**: SaveImageOp (PNG via readback). **No display/window present** — Tier-1 blocker.
- **Compositing**: none (no blend/mask/over/multiply ops at the operator level — only what you author in WGSL).
- **Post-processing**: none (no bloom, tonemap, color grade, LUT, vignette, chromatic aberration, FXAA).
- **Lighting**: `PointLight` *type* exists on EvalContext; no lighting *operators* (no light-authoring node, no shadow op, no IBL).
- **Particles**: none.
- **Interaction**: none (no mouse / keyboard / touch / gamepad operators).
- **Control flow**: `Region::Loop` and subgraph instantiation exist; **no Condition / Switch / Trigger / Gate / Sample-and-hold operators.**
- **Spatial / scene**: no scene graph, no spatial index, no culling, no LOD, no streaming.
- **Skeletal**: none (no skinning, no animation graphs, no IK).

## Deliverable

A markdown file in this repo (suggested path: `notes/themes/operator-families-vs-flux.md` or similar — place wherever you think it fits best, this repo's organization is yours) with:

1. **Confirmed-missing families** — present in all 3 primary node-paradigm refs OR present in tixl + ≥2 secondary refs, absent from flux. Highest priority. Axis-tagged.
2. **Likely-missing families** — present in 2 primary or split-coverage. Worth investigating.
3. **Reference-specific families** — appear in only one ref. Note but don't prioritize.
4. **AAA-gap section** — from the cross-paradigm check. Includes deliberate speculation, labeled.
5. **Revised tier ranking** — use flux's existing gap-analysis tiers (Tier 1 visible output → Tier 5 production workflow). For new families surfaced here, propose tier placements with one-sentence justification.

**Optional but valuable:** a list of **operator-graph *patterns*** (not operators) — spreads (vvvv), channels (TouchDesigner CHOPs), type promotion, port adapters, cookable types, sub-graph caching, evaluation-order hints, frame budgets, scope conventions. At 1000-op scale these patterns determine whether the project stays editable.

## Anti-goals

- **Don't list every operator name.** Families and clusters, not catalogs.
- **Don't recommend specific implementation strategies.** The output is a gap list, not a design.
- **Don't recommend imitating any one framework wholesale.** Flux has its own opinions (operator-first, no implicit context extensions, headless-capable, Rust-typed values flowing through ports).
- **Don't speculate beyond the inventory.** The AAA-gap section is the only place speculation is welcome, and must be labeled as such.
- **Don't pad with features flux's target doesn't imply.** Decima-class means real-time AAA; we are not building an offline path tracer, a CAD modeler, or a node-based DAW.

## Style

Terse and inventory-flavored. The output is going to be consumed by a future self triaging build priorities, not by someone learning the field. Cite framework source with paths (e.g., `tixl/Operators/Types/Numbers/Float/Random.cs` or `threejs/examples/jsm/postprocessing/`) so claims are verifiable. Axis tags as section-header chips (`### Transform [scene] [authoring]`).
