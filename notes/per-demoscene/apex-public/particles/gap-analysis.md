# Particle System Documentation: Gap Analysis

This document inventories all known gaps in the Phoenix particle system documentation, categorized by severity. Each entry includes the source of the gap, its impact on understanding, resolution status, and recommendations.

## Methodology

Gaps were identified through:

1. **Cross-reference checking**: Comparing "To be written" and "Related Documents" links against actual files
2. **Source code audit**: Reading all particle-related source files and comparing against documentation coverage
3. **Pipeline tracing**: Following data flow from spawn through simulation to rendering, noting undocumented transitions
4. **Feature inventory**: Listing all compile-time features (`#ifdef PHX_HAS_*`) and checking documentation coverage

## Summary

| Severity | Count | Resolved | Remaining |
|----------|-------|----------|-----------|
| Critical | 3 | 3 | 0 |
| High | 4 | 3 | 1 |
| Medium | 5 | 2 | 3 |
| Low | 4 | 0 | 4 |
| **Total** | **16** | **8** | **8** |

## Critical Gaps (Blocked Understanding)

### GAP-001: Rendering Pipeline Document Missing [RESOLVED]

**Source**: `emitters.md:709` — "To be written: `particles/rendering.md` — Vertex buffer updates and billboard rendering"

**Impact**: The particle documentation traced the full lifecycle from spawn through simulation but stopped at GPU buffer upload. How particles become visible pixels was completely undocumented. This left a gap between `UpdateParticles()` output and final screen output.

**Resolution**: Created `particles/rendering.md` covering all three rendering modes (billboard, mesh, subscene), the spline texture system, geometry shader expansion, pixel shader alpha test dissolution, deferred pipeline integration, and material state assembly.

**Verification**: The document traces every step from `CreateRenderDataInstances()` (Scene.cpp:608) through `Draw()` (RenderLayer.cpp:99) to `PixelMain()` (default-particle.hlsl:203), with source line references.

### GAP-002: Spline Texture System Undocumented [RESOLVED]

**Source**: `emitters.md:91` — Mentions SplineTexture briefly ("1D texture, 2048 pixels wide") but doesn't explain creation, row mapping, or shader sampling.

**Impact**: The spline texture is the core mechanism connecting particle lifetime to visual appearance. Without documentation, it's impossible to understand how lifetime-driven color, size, and alpha test work.

**Resolution**: Documented in `rendering.md` (Spline Texture System section) and `particle-rendering.md` code trace (Steps 3, 12). Covers `UpdateSplineTexture()`, row-to-parameter mapping (11 rows), `SampleCurve()` / `SampleCurveWithChaos()` implementation, and the `Load()` vs `Sample()` design decision.

**Verification**: Row mapping validated by cross-referencing `UpdateSplineTexture()` loop ordering (Scene.cpp:745-757) with shader curve IDs (default-particle.hlsl:141-147). The 11 rows (5 base + 5 chaos + 1 alpha test) confirmed.

### GAP-003: Rendering Code Trace Missing [RESOLVED]

**Source**: `code-traces/particle-frame.md` — Ends at vertex buffer upload. No trace of the rendering pipeline.

**Impact**: The simulation code trace stops at `Unmap()`. No documentation covered the GPU-side execution: how the vertex data flows through the shader pipeline.

**Resolution**: Created `code-traces/particle-rendering.md` tracing from `CreateRenderDataInstances()` through all D3D11 calls in `Render()` and the VS→GS→PS shader execution.

## High Gaps (Significant Missing Information)

### GAP-004: Mesh Particle Draw Call Costs [RESOLVED]

**Source**: No existing documentation covered the per-particle draw call pattern for mesh particles.

**Impact**: Mesh particles generate one draw call per live particle per material pass. For 256 particles with 2 passes, that's 512 draw calls — a critical performance characteristic. Without documentation, users might choose mesh particles for high-count effects and experience poor performance.

**Resolution**: Documented in `rendering.md` (Mesh Particle Rendering section) with draw call count analysis, per-particle transform construction code, and comparison to billboard single-draw-call efficiency.

### GAP-005: Subscene Particle Recursion Depth [RESOLVED]

**Source**: Scene.cpp:708-711 — `SceneToEmit->UpdateSceneGraph()` called per particle with no recursion guard.

**Impact**: Subscene particles could theoretically contain particle emitters with their own subscene particles, creating exponential recursion. The documentation didn't address this risk.

**Resolution**: Documented in `rendering.md` (Subscene Particle Rendering section). Phoenix doesn't prevent recursion, but practical constraints (CPU cost) limit depth. In practice, demo artists use simple subscenes.

### GAP-006: Deferred Pipeline Interaction [RESOLVED]

**Source**: `rendering/deferred.md:322-344` — Mentions transparent objects render forward after lighting but doesn't specifically address particles.

**Impact**: Users need to understand that particles don't receive deferred lighting, rendering on the Transparent Layer after lit geometry. Without this, there's ambiguity about whether particles are affected by scene lights.

**Resolution**: Added to `rendering.md` (Deferred Pipeline Integration section) and added cross-reference in `rendering/deferred.md`. Particles render on Transparent Layer, read depth but don't write, and don't receive deferred lighting. They are purely emissive — color comes from lifetime curves, not scene lights.

### GAP-007: PARAM_PARTICLELIFEFLOAT vs PARAM_PARTICLELIFE Distinction [OPEN]

**Source**: Material.h:51, 62 — Two distinct enum values: `PARAM_PARTICLELIFEFLOAT` and `PARAM_PARTICLELIFE`. Both relate to particles but serve different purposes.

**Impact**: The distinction is unclear from the enum alone. `PARAM_PARTICLELIFEFLOAT` is used in `UpdateSplineTexture()` to identify splines that get baked into the curve texture. `PARAM_PARTICLELIFE` appears to be a separate parameter type, possibly for per-particle spline evaluation (as used in mesh particles). The documentation doesn't fully explain when each is used.

**Recommendation**: Trace all usages of both enum values through the codebase. Document the distinction in `rendering/materials.md` with concrete examples of when each applies.

## Medium Gaps (Missing Detail)

### GAP-008: Blend Mode Configuration for Particles [PARTIALLY RESOLVED]

**Source**: Material.h:69-99 — Blend mode defines. Project.cpp:1948-1952 — Packed byte encoding.

**Impact**: The blend mode is packed as a single byte (`SrcBlend` in low nibble, `DstBlend` in high nibble). This encoding is documented in materials.md but not connected to particle-specific usage patterns. Which blend modes are typical for particles? How do additive vs alpha blend affect particle sorting requirements?

**Resolution**: `rendering.md` explains additive, alpha, and premultiplied-alpha blend modes for particles and their sorting implications. The encoding mechanism itself was already documented in `materials.md`.

**Remaining**: No documentation of which blend modes are used in the Clean Slate project's actual particle effects.

### GAP-009: Particle Vertex Buffer Creation [OPEN]

**Source**: The vertex buffer is created somewhere during emitter initialization, but the allocation code isn't traced in any document.

**Impact**: We document the buffer fill (Scene.cpp:574-605) and the buffer read (RenderLayer.cpp), but not the buffer creation. Where is `ID3D11Buffer* VertexBuffer` allocated? What size? What usage flags?

**Recommendation**: Search for `CreateBuffer` calls in the emitter initialization path. Likely in the tool code that constructs `CphxObject_ParticleEmitter_CPU` instances. Document buffer size calculation: `(1 << BufferSize) * 32` bytes with `D3D11_USAGE_DYNAMIC` and `D3D11_CPU_ACCESS_WRITE`.

### GAP-010: MaterialState Array Allocation [OPEN]

**Source**: Scene.h:281 — `CphxMaterialPassConstantState **MaterialState` — pointer to array of pointers.

**Impact**: `MaterialState` is an array of per-pass constant state objects. Who allocates this array? How many entries? The rendering trace shows it being used (Scene.cpp:621, 624) but not created.

**Recommendation**: Trace initialization in the tool code (likely `apEx/` editor sources). The array size should equal the total pass count across all techniques in the particle material.

### GAP-011: Particle Sorting Algorithm Details [OPEN]

**Source**: Scene.cpp:570-571 — `qsort(DistanceBuffer, LiveCount, sizeof(PHXPARTICLEDISTANCE), ParticleSorter)`. The `particle-frame.md` code trace mentions sorting but doesn't analyze the comparator or distance calculation.

**Impact**: The sort order (back-to-front vs front-to-back) affects visual correctness for alpha-blended particles. The distance calculation method (view-space Z vs squared distance from camera) affects accuracy for wide-angle views.

**Recommendation**: Find and document `ParticleSorter` comparator function. Verify it sorts back-to-front (descending Z in view space). Note that sorting is a pre-rendering step that interacts with the rendering pipeline's blend mode — additive blending doesn't require sorting, while alpha blending does.

### GAP-012: Pointsprites Shader Usage Context [PARTIALLY RESOLVED]

**Source**: `pointsprites.hlsl` — A complete mesh-to-billboard shader exists alongside `default-particle.hlsl`.

**Impact**: It's unclear when and how `pointsprites.hlsl` is used versus `default-particle.hlsl`. Are they interchangeable? Does the user select between them in the editor?

**Resolution**: `rendering.md` documents the key differences (input topology, no lifetime curves, triangle centroid placement, normal offset). The pointsprites shader is for mesh-to-sprite conversion, not for the particle system's emitter-based particles.

**Remaining**: No trace of where/how the Clean Slate project uses pointsprites in practice.

## Low Gaps (Minor Missing Information)

### GAP-013: Texture Sampler Configuration [OPEN]

**Source**: default-particle.hlsl:36-37 — Two samplers registered (s0 = linear, s1 = point), but only the linear sampler is used in the pixel shader. The spline texture uses `Load()` which bypasses samplers entirely.

**Impact**: Minor. The point sampler (s1) appears unused in the default particle shader. It may be intended for effects that use point-filtered sprite textures, or it's inherited from a template.

**Recommendation**: Document sampler usage. The linear sampler (s0) filters the sprite texture. The point sampler (s1) is available for custom particle shaders but unused by default.

### GAP-014: Global Spline Texture Buffer Allocation [OPEN]

**Source**: Scene.cpp:727 — `float *texturedata = new float[2048 * 64]` — A global buffer allocated at file scope.

**Impact**: Minor. The buffer is allocated once and reused across all `UpdateSplineTexture()` calls (note the commented-out `delete[]` on line 773). The `64` height suggests a maximum of 64 parameter curves per emitter, though only 11 are documented.

**Recommendation**: Document the maximum curve count (64) and the memory footprint (512 KB global allocation, persistent for process lifetime).

### GAP-015: Particle World Matrix Usage [OPEN]

**Source**: Material.cpp:157-158 — `ri->Matrices[0] = phxWorldMatrix; ri->Matrices[1] = phxITWorldMatrix;`

**Impact**: Minor. For billboard particles, the world matrix is applied in the vertex shader (`mul(viewMatrix, input.position)` where `input.position` is already in world space). The constant buffer also contains `worldMatrix` in the material buffer. Whether the emitter's world matrix is baked into positions during `UpdateParticles()` or applied in the shader needs clarification.

**Recommendation**: Verify. The vertex buffer positions are in world space (transformed during spawning in `SpawnParticle()`). The `viewMatrix` in the shader cbuffer transforms from world to view space. The `worldMatrix` in the material cbuffer may be identity for particles, or it may apply an additional emitter transform.

### GAP-016: Commented-Out GPU Particle System Design Intent [OPEN]

**Source**: Scene.h:383-396 — Commented-out `CphxObject_ParticleEmitter` class.

**Impact**: Minor. The GPU particle system was never implemented. The commented code reveals the intended architecture (compute shaders, UAV, resolution-based sizing) but not the motivation for abandoning it. Was it code size? Debugging difficulty? Sufficient CPU performance? Feature gap (no mesh/subscene equivalent)?

**Recommendation**: Documented in `rendering.md` with architectural comparison and likely abandonment reasons. Further investigation would require access to version control history or developer commentary. The `rendering.md` document speculates on reasons but cannot confirm them.

## Cross-Reference Verification

The following cross-references were verified during this analysis:

| Source Document | Reference | Target | Status |
|----------------|-----------|--------|--------|
| emitters.md:708 | "To be written: rendering.md" | particles/rendering.md | Now exists |
| emitters.md:707 | "To be written: simulation.md" | particles/simulation.md | Already existed |
| overview.md:... | Related Documents section | All listed docs | Needs update (see below) |
| simulation.md:... | GPU buffer section end | rendering pipeline | Needs cross-ref |
| particle-frame.md | Ends at Unmap() | rendering trace | Now linked |
| deferred.md:322 | Transparency handling | Particle interaction | Needs subsection |

## Recommendations

### Immediate (Required for Documentation Completeness)

1. **Update overview.md**: Add `rendering.md` to the Related Documents section. Replace "To be written" markers.

2. **Update simulation.md**: Add cross-reference at the end of the GPU buffer upload section pointing to `rendering.md` and the rendering code trace.

3. **Update emitters.md**: Expand the Rendering State section (lines 74-93) to cross-reference `rendering.md` for the full rendering pipeline.

4. **Update deferred.md**: Add a subsection on particle/transparency layer interaction.

5. **Update materials.md**: Add `PARAM_PARTICLELIFEFLOAT` coverage explaining the particle material differences.

### Future Investigation

6. **Resolve GAP-007**: Trace `PARAM_PARTICLELIFE` usage to clarify its distinction from `PARAM_PARTICLELIFEFLOAT`.

7. **Resolve GAP-009**: Find vertex buffer creation code in the tool.

8. **Resolve GAP-011**: Document the `ParticleSorter` comparator.

9. **Practical usage analysis**: Examine the Clean Slate project's actual particle effects to document real-world blend modes, particle counts, and shader configurations.

## Related Documents

- **[rendering.md](rendering.md)** — The rendering pipeline document (resolves GAP-001, GAP-002)
- **[../code-traces/particle-rendering.md](../code-traces/particle-rendering.md)** — Rendering code trace (resolves GAP-003)
- **[overview.md](overview.md)** — System overview
- **[simulation.md](simulation.md)** — Simulation pipeline
- **[emitters.md](emitters.md)** — Spawn and emission
- **[../rendering/deferred.md](../rendering/deferred.md)** — Deferred pipeline
- **[../rendering/materials.md](../rendering/materials.md)** — Material system
