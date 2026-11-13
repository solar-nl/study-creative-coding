# VL.StandardLibs

The standard node libraries of vvvv gamma, including VL.Skia, the 2D engine that wraps SkiaSharp as a tree of layers.

## Why Study This

vvvv gamma is the one node-based tool in this study whose 2D output is a general-purpose vector rasterizer rather than a texture pipeline. VL.Skia exposes Skia's imaging model (paths, text, images, blend modes, SVG and PDF export) as patchable nodes, and the node-graph theme counted it as the fullest 2D vector family among the references. Flux today has textures as its only 2D primitive, so VL.Skia is the closest existing answer to "what does a vector 2D layer look like inside a node graph".

The interesting part is not Skia itself, which is a black box here, but the thin C# layer that turns a canvas API into a graph. A layer is one object that both draws and handles input: `ILayer` combines `IRendering` and `IBehavior`, so the render tree doubles as the hit-test and event-dispatch tree. Context flows down the tree as an immutable `CallerInfo` record carrying the canvas, the GPU context, the current transform and the viewport. Wrapper nodes override one half of the interface and forward the rest. This is the same question the command-flow insights ask for Flux, answered in a shipping product.

The ecosystem placement mirrors orx for OPENRNDR and toxiclibs for Processing: a library set that defines what the host environment can do, studied alongside its documentation (the Gray Book).

## Repository State

Studied at commit `41aa0e507705` (2026-10-21, main). LGPL-3.0. The repository stores images and native DLLs in git-lfs; in this checkout they are pointer files, which is all the notes need. The nested submodule `VL.ImGui/dependencies/ImGui.NET-nativebuild` is deliberately left uninitialized. See `CLAUDE.md` for the checkout note.

## Key Areas to Study

| Area | Where | Relevance to Flux |
|------|-------|-------------------|
| Layer interface | `VL.Core.Skia/Interfaces.cs:32-79` (`ILayer : IRendering, IBehavior`; `Render(CallerInfo)` :38, `Notify(INotification, CallerInfo)` :45) | One node type for drawing and input; how a render tree becomes an event tree |
| Decorator layers | `VL.Core.Skia/LinkedLayerBase.cs:6-20`, `VL.Skia/src/Layers.cs` (`SetRender` :10, `SetNotify` :31, `SetBehavior` :48, `SetRendering` :71), `Group.cs` (`Group` :14, `SpectralGroup` :63) | How wrapper nodes override one half of a layer and forward the other |
| Context passing | `VL.Core.Skia/CallerInfo.cs:10-28` (record with `GRContext`, `SKSurface`, `SKCanvas`, `Transformation`, `ViewportBounds`, `Scaling`), `WithTransformation`/`WithCanvas` :65-75 | Immutable per-call context instead of global state; compare with Flux's command flow |
| GPU backend | `VL.Core.Skia/Egl/`, `VL.Core.Skia/RenderContext.cs:63-65, 86-138` (`EglDeviceProvider`, `EglDisplayProvider`, `EglContextProvider`, `RenderContext`) | Skia's GPU path runs through ANGLE (EGL over Direct3D), Windows-only; what "delegate to a platform rasterizer" costs |
| Output paths | `VL.Skia/src/SkiaRenderer.cs:31` (a WinForms window), `SkiaRendererNode.cs:29` (the node that owns it), `OffScreenRenderer.cs:80` (to `SKImage`), `PictureRecorder.cs:18` (to `SKPicture`) | Window, offscreen image, and recorded display list from the same layer tree |
| Deferred evaluation | `VL.Skia/src/DeferredLayer.cs:13` | Caching a subtree's rendering across frames |
| Patched nodes | `VL.Skia/VL.Skia.vl` (4.3 MB), `VL.Skia/help/` | Which operations are C# and which are patched on top; the help patches as API documentation |
| Related libraries | `VL.EditingFramework.Skia`, `VL.ImGui.Skia`, `VL.Stride.*` | Editor widgets drawn with the same layer model; the 3D engine beside it |

## Repository Structure

```
VL.StandardLibs/
├── VL.Core/                 # Runtime core (UniqueId, NodePath; see the-gray-book/node-identity.md)
├── VL.Core.Skia/            # Layer interfaces, CallerInfo, EGL/ANGLE render context
├── VL.Skia/                 # The 2D engine: renderer window, layer nodes, recorders, VL.Skia.vl, help patches
├── VL.CoreLib/              # Standard nodes (collections, math, IO)
├── VL.EditingFramework.Skia # Interaction widgets drawn with Skia
├── VL.ImGui*/               # Dear ImGui bindings, Skia and Stride backends
├── VL.Stride*/              # 3D engine integration (Stride)
└── VL.Video, VL.IO.*, VL.Serialization.*, ...
```

## Documents to Create

- [ ] `skia-layer-model.md` — `ILayer`, `CallerInfo`, decorator layers; how a draw call and a mouse event traverse the same tree
- [ ] `renderer-node.md` — `SkiaRendererNode` → `SkiaRenderer` → EGL context; frame timing, DPI, the three output paths
- [ ] `patched-vs-compiled.md` — what `VL.Skia.vl` adds on top of the C# layer

## References

- [VL.StandardLibs on GitHub](https://github.com/vvvv/VL.StandardLibs)
- [SkiaSharp](https://github.com/mono/SkiaSharp)
- [The Gray Book: introduction for creative coders](../../../../references/the-gray-book/reference/getting-started/cc/introduction-for-creative-coders.md) — names VL.Skia as the 2D and vector-export library
- [The Gray Book study notes](../../../per-reference/the-gray-book/) — the conceptual model VL.Skia is patched in
- [Node identity note](../../../per-reference/the-gray-book/node-identity.md) — already measured against `VL.Skia.vl`
- [Operator families vs Flux](../../../themes/node-graphs/operator-families-vs-flux.md) — where VL.Skia's 2D family is counted
