# rend3

A high-level rendering framework built on wgpu for Rust applications.

## Why Study This

rend3 occupies a unique position in the Rust graphics ecosystem: it provides a complete rendering pipeline on top of wgpu without being a full game engine. This makes it directly relevant to Flux's goal of providing creative coding capabilities with a wgpu backend.

The library demonstrates how to architect a scene graph, material system, and rendering pipeline in Rust. Unlike raw wgpu which requires managing buffers, bind groups, and pipelines manually, rend3 provides higher-level abstractions for meshes, materials, lights, and cameras. Understanding these abstractions can inform how Flux structures its own rendering layer.

rend3's approach to mesh handling is particularly relevant. It manages GPU resources (vertex buffers, index buffers) behind handles, similar to Flux's existing `MeshHandle` concept. Studying how rend3 handles mesh uploads, material binding, and draw call batching can provide patterns for Flux's geometry system GPU integration.

## Key Areas to Study

| Area | Relevance to Flux |
|------|-------------------|
| Mesh handling | How meshes are uploaded, stored, and rendered |
| Material system | PBR materials, shader binding, texture management |
| Scene graph | Object hierarchy, transforms, culling |
| Render pipeline | Frame graph, render passes, output composition |
| Camera system | Projection, view matrices, viewport handling |
| Resource management | Handle-based GPU resource lifecycle |

## Repository Structure

```
rend3/
├── rend3/           # Core rendering library
├── rend3-routine/   # Built-in render routines (PBR, tonemapping)
├── rend3-framework/ # Application framework utilities
├── rend3-gltf/      # glTF loading support
└── examples/        # Usage examples
```

## Documents to Create

- [ ] `architecture.md` — Overall structure, crate relationships
- [ ] `mesh-handling.md` — How meshes flow from CPU to GPU
- [ ] `material-system.md` — Material types, shader integration
- [ ] `render-pipeline.md` — Frame graph, render passes
- [ ] `patterns-for-flux.md` — Extracted patterns applicable to Flux

## References

- [rend3 GitHub](https://github.com/BVE-Reborn/rend3)
- [rend3 Documentation](https://docs.rs/rend3)
- [rend3 Examples](https://github.com/BVE-Reborn/rend3/tree/trunk/examples)
