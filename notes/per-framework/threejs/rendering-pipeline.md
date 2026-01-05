# three.js Rendering Pipeline

## Overview

three.js uses a **retained-mode** rendering model with a scene graph.

## From User Code to Pixels

```
User calls renderer.render(scene, camera)
        │
        ▼
WebGLRenderer.render() in renderers/WebGLRenderer.js
        │
        ▼
Update world matrices (scene.updateMatrixWorld())
        │
        ▼
Project scene against camera frustum
        │
        ▼
Build render lists (WebGLRenderLists)
  - Opaque objects (front-to-back)
  - Transparent objects (back-to-front)
        │
        ▼
For each render item:
  - Bind material/program
  - Set uniforms
  - Bind geometry attributes
  - Execute draw call
        │
        ▼
GPU executes shaders → framebuffer
```

## Renderer Abstraction

### WebGLRenderer
- Wraps WebGL2 context
- Manages GL state via `WebGLState`
- Caches shader programs via `WebGLPrograms`
- Handles automatic texture uploads

### WebGPURenderer (experimental)
- Uses new WebGPU API
- Node-based material system
- Compute shader support

## State Management

### GL State (`WebGLState`)
- Caches current GL state to avoid redundant calls
- Manages: blend mode, depth test, stencil, culling
- Provides: `setMaterial()`, `setFlipSided()`, etc.

### Program Cache (`WebGLPrograms`)
- Compiles and caches shader programs
- Keys by material type + defines
- Handles uniform locations

## Render Sorting

### Opaque Objects
- Sorted front-to-back (by `z` distance)
- Early depth rejection optimization

### Transparent Objects
- Sorted back-to-front
- Rendered after opaques
- Order-dependent blending

## Shadow Rendering

1. For each shadow-casting light:
   a. Render scene to shadow map (depth only)
   b. Store in light.shadow.map
2. During main render:
   a. Sample shadow maps in material shaders
   b. Apply shadow attenuation

## Performance Considerations

- Geometry merging reduces draw calls
- Instancing via `InstancedMesh`
- `BatchedMesh` for dynamic batching
- Frustum culling is automatic
- LOD (Level of Detail) for distant objects

## Study Questions

- [ ] How does `WebGLPrograms` decide when to recompile?
- [ ] How does the uniform system work?
- [ ] How does `WebGLRenderLists` sort objects?
- [ ] How does post-processing integrate (EffectComposer)?
- [ ] How does the node-based material system generate shaders?
