# tixl — Rendering Pipeline

## Key Insight

> **Command pattern rendering's core idea:** Graph evaluation produces Command objects that encapsulate GPU state changes and draw calls, enabling deferred execution, render-to-texture workflows, and composable rendering hierarchies.

## Overview

tixl uses **DirectX 11** via SharpDX for GPU rendering, with a focus on real-time performance for motion graphics and VJ applications. The rendering pipeline is documented across eleven deep-dive documents organized by subsystem.

```
┌──────────────────────────────────────────────────────────────────┐
│                      Operator Graph                               │
│  (Evaluation produces Command objects)                            │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                    Command Execution                              │
│  (Commands set GPU state, issue draw calls)                       │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                     DirectX 11 (SharpDX)                         │
│  (Vertex/Pixel/Geometry/Compute shaders, render targets)          │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                        GPU Output                                 │
│  (Window, texture, NDI stream, Spout)                            │
└──────────────────────────────────────────────────────────────────┘
```

## Deep-Dive Documents

### Architecture & State Management

| Document | Lines | Covers |
|----------|-------|--------|
| **[rendering/overview.md](rendering/overview.md)** | 535 | DX11 device lifecycle, command pattern (PrepareAction/RestoreAction), EvaluationContext rendering state, pull-based lazy evaluation, comparison with immediate-mode and retained-mode |
| **[rendering/render-targets.md](rendering/render-targets.md)** | 546 | RenderTarget operator, multi-buffer pattern, MSAA support, state save/restore, resolution propagation, texture formats, render-to-texture workflows |
| **[rendering/command-nodes.md](rendering/command-nodes.md)** | 340 | Primitive GPU command nodes (Draw, SetShaderStage, OutputMerger, Rasterizer, InputAssembler), Execute vs Group composition primitives, compound operator structure (.t3 sub-graphs), user-facing editor workflow |

### Lighting & Shading

| Document | Lines | Covers |
|----------|-------|--------|
| **[rendering/pbr-pipeline.md](rendering/pbr-pipeline.md)** | 588 | Cook-Torrance BRDF (GGX NDF, Schlick geometry, Fresnel), ComputePbr() 8-light loop, IBL split-sum, mesh-Draw.hlsl VS/PS, cbuffer layout (b0–b5), metalness workflow, template injection |
| **[rendering/shadows.md](rendering/shadows.md)** | 317 | Shadow map generation, 3×3 PCF kernel, normal offset bias, configurable shadow color, spotlight cone masking, particle shadow maps, integration with PBR |

### Post-Processing & Utilities

| Document | Lines | Covers |
|----------|-------|--------|
| **[rendering/post-processing.md](rendering/post-processing.md)** | 521 | Bloom (multi-stage pyramid), tone mapping (ACES/Reinhard/Filmic/AgX), ColorGrade with OkLab, FXAA, 100+ image operator catalog, post-processing chain architecture |
| **[rendering/shared-hlsl-library.md](rendering/shared-hlsl-library.md)** | 860 | All 12 shared HLSL files: BRDF, lighting, color spaces (OkLab/OkLCh), noise (simplex/Perlin/curl), hash functions, quaternion math, blend modes, bias functions |

### Graph Engine & Operator Interface

| Document | Lines | Covers |
|----------|-------|--------|
| **[rendering/graph-evaluation-engine.md](rendering/graph-evaluation-engine.md)** | 1047 | 9-question deep dive: two-phase evaluation loop (invalidate → pull), DirtyFlag counter system (Reference/Target), Slot/InputSlot/MultiInputSlot hierarchy, ConnectedUpdate vs GetValue call chain, EvaluationContext (full field inventory, shared mutable, manual save/restore), dirty propagation across compound boundaries, command/value slot interaction, connection storage (GUID quadruplets → direct slot pointers), fan-out/fan-in rules |
| **[rendering/operator-gpu-interface.md](rendering/operator-gpu-interface.md)** | 591 | 8-question deep dive: operator self-description ([Input]/[Output] attributes, reflection registry), shader binding (file-path reference, file-watched hot-reload), parameter storage (3-layer: type default → instance override → animation), manual cbuffer packing ([StructLayout] → HLSL), positional SRV binding (connection order = register), bufferless vertex fetch (StructuredBuffer + SV_VertexID), pipeline state as typed inputs, multi-pass composition (compound + C# executor), GUID-only serialization |

### Design Analysis

| Document | Lines | Covers |
|----------|-------|--------|
| **[rendering/graph-for-rendering.md](rendering/graph-for-rendering.md)** | 290 | Why tixl's command-flow graph works for rendering where pure dataflow fails — shared mutable targets, imperative draw calls, command timing, conditional passes, resource lifetimes |
| **[rendering/compound-mechanics.md](rendering/compound-mechanics.md)** | 410 | 12-question deep dive: Symbol loading phases, port bridging (direct slot pointers), Execute three-phase lifecycle, Group transform propagation, RenderTarget command→value bridge, multi-pass patterns (Bloom/shadows), shader compilation, ICompoundWithUpdate |

### End-to-End Trace

| Document | Lines | Covers |
|----------|-------|--------|
| **[code-traces/rendering-frame.md](code-traces/rendering-frame.md)** | 835 | 13-step frame trace from main loop → DirtyFlag propagation → Camera → RenderTarget → DrawMesh → VS/PS → ComputePbr → MSAA resolve → SwapChain.Present |

## Particle & Point Rendering

tixl's point/particle rendering is documented separately as part of the particle system study:

- **[particles/rendering.md](particles/rendering.md)** — 16 draw modes, VS expansion via SV_VertexID, gradient textures, FxTexture modulation
- **[code-traces/particle-frame.md](code-traces/particle-frame.md)** — End-to-end particle rendering trace

## Key Source Files

| File | Purpose |
|------|---------|
| `Operators/Lib/Assets/shaders/shared/pbr.hlsl` | BRDF functions, PbrVertex, FragmentMaterial |
| `Operators/Lib/Assets/shaders/shared/pbr-render.hlsl` | ComputePbr(), IBL split-sum, fog |
| `Operators/Lib/Assets/shaders/shared/point-light.hlsl` | PointLight struct (48 bytes) |
| `Operators/Lib/Assets/shaders/shared/color-functions.hlsl` | OkLab/OkLCh conversions |
| `Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl` | Full PBR draw shader |
| `Operators/Lib/render/_/RenderTarget.cs` | Framebuffer operator |
| `Operators/Lib/Symbols/render/camera/Camera.cs` | Camera operator |
| `Core/Resource/ResourceManager.cs` | DX11 device lifecycle |
| `Core/Operator/EvaluationContext.cs` | Rendering state context |
| `Core/Rendering/Material/PbrMaterial.cs` | C# material struct |
