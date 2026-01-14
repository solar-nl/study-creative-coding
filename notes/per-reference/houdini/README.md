# Houdini Documentation Study

> Extracting procedural thinking and node-graph patterns from SideFX Houdini for real-time creative coding

---

## Why Study Houdini?

Houdini is the industry standard for procedural content creation in film VFX. While not a real-time engine, its concepts are foundational:

1. **VEX Language** — A shader-like language with concepts that transfer directly to GLSL/WGSL
2. **Procedural Geometry** — The SOP (Surface Operators) paradigm pioneered thinking in operations rather than objects
3. **Node Graph Design** — The most mature visual programming system in the industry
4. **USD Workflow** — Solaris brings USD, now adopted by real-time engines (Unity, Unreal, Godot)

**Key insight:** Houdini's documentation teaches *how to think procedurally*, not just how to use tools.

---

## Documentation Reference

All references link to the official SideFX documentation at [sidefx.com/docs/houdini](https://www.sidefx.com/docs/houdini/).

### Primary Study Areas (VEX + SOPs)

| Topic | URL | Why Study |
|-------|-----|-----------|
| **VEX Language** | [vex/](https://www.sidefx.com/docs/houdini/vex/index.html) | Shader-like language, GLSL/WGSL patterns |
| **VEX Functions** | [vex/functions/](https://www.sidefx.com/docs/houdini/vex/functions/index.html) | 1,073 functions, many map to shader intrinsics |
| **SOP Nodes** | [nodes/sop/](https://www.sidefx.com/docs/houdini/nodes/sop/index.html) | 1,227 procedural geometry operations |
| **VOP Nodes** | [nodes/vop/](https://www.sidefx.com/docs/houdini/nodes/vop/index.html) | Visual shader programming (1,014 nodes) |

### Secondary Study Areas

| Topic | URL | Why Study |
|-------|-----|-----------|
| **HOM API** | [hom/](https://www.sidefx.com/docs/houdini/hom/index.html) | Python API design patterns |
| **Solaris/USD** | [solaris/](https://www.sidefx.com/docs/houdini/solaris/index.html) | USD workflow, adopted by real-time engines |
| **Copernicus** | [copernicus/](https://www.sidefx.com/docs/houdini/copernicus/index.html) | GPU-accelerated compositing |
| **Unity Integration** | [unity/](https://www.sidefx.com/docs/houdini/unity/index.html) | Real-time engine bridge |
| **Unreal Integration** | [unreal/](https://www.sidefx.com/docs/houdini/unreal/index.html) | Real-time engine bridge |

### Reference Areas (for deeper dives)

| Topic | URL | Notes |
|-------|-----|-------|
| **CHOP Nodes** | [nodes/chop/](https://www.sidefx.com/docs/houdini/nodes/chop/index.html) | Motion/channel concepts |
| **Heightfields** | [heightfields/](https://www.sidefx.com/docs/houdini/heightfields/index.html) | Terrain generation |
| **Network Editor** | [network/](https://www.sidefx.com/docs/houdini/network/index.html) | Node graph UX patterns |

---

## Study Approach

### Dual Focus: VEX + SOPs

Study VEX and SOPs in parallel—they are two views of the same operations:

```
VEX function: noise()     ↔  SOP node: Attribute Noise
VEX function: lerp()      ↔  SOP node: Blend Shapes
VEX function: transform() ↔  SOP node: Transform
```

Understanding both reveals *why* the API is designed this way.

### Concepts to Extract

| Concept | Houdini Example | Rust Framework Application |
|---------|-----------------|----------------------------|
| Attribute flow | Point attributes propagate through network | Vertex/instance data flow |
| Lazy evaluation | Nodes compute only when needed | On-demand rendering |
| Wrangler pattern | "Point Wrangle" = inline VEX | Custom shader snippets |
| Group selection | Geometry groups for selective operations | Entity component selection |

---

## Documents to Create

- [ ] `vex-language.md` — VEX concepts → shader patterns
- [ ] `procedural-modeling.md` — SOP paradigm → procedural generation
- [ ] `node-graph-design.md` — Network patterns → visual programming
- [ ] `visual-shaders.md` — VOP patterns → node-based materials
- [ ] `api-design.md` — HOM patterns → API ergonomics

---

## URL Index

A curated index of 5,030 URLs (filtered from 10,417 total) is maintained at:
`houdini-docs-scraper/output/houdini-curated-index.json`

This maps local study paths to their original sidefx.com URLs.

---

## Related Themes

- `notes/themes/node-graphs.md` — Cross-framework node graph comparison
- `notes/themes/procedural-systems.md` — Procedural generation patterns (planned)
