# Babylon.js Rendering Pipeline

> From scene.render() to GPU draw calls — tracing the journey of a frame

---

## The Problem: Ordering Chaos

You have a scene with hundreds of meshes, multiple materials, transparent and opaque objects, shadows, and post-processing effects. You call `scene.render()`. What happens next?

The challenge isn't just "draw everything." It's drawing things in the right order, with the right state, while minimizing GPU state changes. Draw a transparent object before the opaque object behind it? Wrong blending. Change shaders between every draw call? Terrible performance.

Babylon.js solves this with a multi-stage pipeline that collects, sorts, and batches draw calls. Understanding this pipeline reveals patterns applicable to any 3D engine.

---

## The Mental Model: A Restaurant Kitchen

Think of the rendering pipeline like a restaurant kitchen during dinner service.

**Taking orders (Mesh Collection):** Waiters (cameras) take orders from tables (the scene). But not every dish gets made — if a table is in a closed section (frustum culling), we skip it.

**Prep stations (Rendering Groups):** Orders go to different prep stations. Appetizers (opaque meshes) go first, then mains (alpha test), then desserts (transparent) — you can't serve dessert before the meal.

**Cooking (Material Binding):** Each dish needs specific ingredients (uniforms) and cooking methods (shaders). The kitchen groups similar dishes together to avoid switching pans constantly.

**Plating (Draw Calls):** Finally, dishes are plated and sent out (GPU draw commands).

The pipeline optimizes the entire flow, not just individual steps.

---

## Pipeline Overview

Here's the high-level flow when you call `scene.render()`:

```
scene.render()
    │
    ├── 1. PRE-RENDER
    │   ├── Update animations
    │   ├── Update camera matrices
    │   └── Fire beforeRender callbacks
    │
    ├── 2. MESH COLLECTION
    │   ├── Get mesh candidates
    │   ├── Frustum culling
    │   └── Dispatch to rendering groups
    │
    ├── 3. RENDER TARGETS
    │   ├── Shadow maps
    │   ├── Reflection probes
    │   └── Custom render targets
    │
    ├── 4. MAIN RENDER
    │   ├── For each rendering group (0-3):
    │   │   ├── Depth-only pass (optional)
    │   │   ├── Opaque meshes
    │   │   ├── Alpha test meshes
    │   │   ├── Sprites
    │   │   ├── Particles
    │   │   └── Transparent meshes (sorted)
    │   └── Post-processing
    │
    └── 5. POST-RENDER
        ├── Fire afterRender callbacks
        └── Present to screen
```

Let's trace each stage in detail.

---

## Stage 1: Pre-Render

Before any geometry is processed, the scene updates dynamic state.

**Entry point:** `Scene.render()` at line 5388 in `scene.ts`

### Animation Updates

The scene advances all registered animations:

```typescript
// scene.ts, line 5427
if (!ignoreAnimations) {
    this.animate();
}
```

This updates bone matrices for skeletal animation, morph target weights, and any custom animations.

### Camera Updates

Active cameras compute their view and projection matrices:

```typescript
// scene.ts, line 5437-5458
if (updateCameras) {
    for (let i = 0; i < this.activeCameras.length; i++) {
        this.activeCameras[i].update();
    }
}
```

The camera's `update()` method computes:
- View matrix (camera position and orientation)
- Projection matrix (perspective or orthographic)
- View-projection matrix (combined, used frequently)
- Frustum planes (for culling)

---

## Stage 2: Mesh Collection

The scene must determine which meshes are visible and group them for efficient rendering.

**Entry point:** `Scene._evaluateActiveMeshes()` at line 4641

### Getting Candidates

First, get all meshes that might be rendered:

```typescript
// scene.ts, line 4696
const meshes = this.getActiveMeshCandidates();
```

By default, this returns all meshes in the scene. But you can optimize with octrees or other spatial structures.

### Frustum Culling

Each mesh is tested against the camera frustum:

```typescript
// scene.ts, line 4745
if (mesh.isInFrustum(this._frustumPlanes)) {
    // Mesh is visible, process it
}
```

The frustum is six planes (left, right, top, bottom, near, far). A mesh is visible if its bounding box intersects all planes. This simple test eliminates most invisible meshes cheaply.

### Computing World Matrices

For visible meshes, ensure the world matrix is current:

```typescript
// scene.ts, line 4719
mesh.computeWorldMatrix();
```

This propagates transforms through the scene hierarchy. If a parent moved, all children must update.

### Dispatch to Rendering Manager

Each visible submesh is sent to the RenderingManager:

```typescript
// scene.ts, line 4821-4826
const subMeshes = this.getActiveSubMeshCandidates(mesh);
for (const subMesh of subMeshes) {
    this._evaluateSubMesh(subMesh, mesh, sourceMesh);
}
```

The rendering manager dispatches based on material properties:

```typescript
// renderingManager.ts, line 375
public dispatch(subMesh, mesh, material) {
    if (material.needAlphaBlendingForMesh(mesh)) {
        this._transparentSubMeshes.push(subMesh);
    } else if (material.needAlphaTestingForMesh(mesh)) {
        this._alphaTestSubMeshes.push(subMesh);
    } else {
        this._opaqueSubMeshes.push(subMesh);
    }
}
```

---

## Stage 3: Render Targets

Before the main view, Babylon renders auxiliary targets.

### Shadow Maps

Each shadow-casting light renders the scene from its perspective:

```typescript
// scene.ts, line 5474-5484
for (const renderTarget of this.customRenderTargets) {
    this._renderRenderTarget(renderTarget, activeCamera);
}
```

Shadow maps store depth values. During main rendering, these depths determine if a fragment is in shadow.

### Reflection Probes

Reflection probes render the scene into cubemaps for reflective surfaces. They typically update less frequently than every frame.

---

## Stage 4: Main Render

This is where the actual frame is drawn.

**Entry point:** `RenderingManager.render()` at line 197 in `renderingManager.ts`

### Rendering Groups

Babylon divides meshes into groups (0-3 by default). Each group renders completely before the next:

```typescript
// renderingManager.ts, line 197-266
for (let index = MIN_RENDERINGGROUPS; index < MAX_RENDERINGGROUPS; index++) {
    const renderingGroup = this._renderingGroups[index];

    // Clear depth if configured
    if (RenderingManager.AUTOCLEAR) {
        this._clearDepthStencilBuffer(autoClear.depth, autoClear.stencil);
    }

    renderingGroup.render(/* ... */);
}
```

This enables layered rendering. Group 0 might be background, group 1 main scene, group 2 UI, group 3 overlays.

### Within Each Group

The `RenderingGroup.render()` method (line 123 in `renderingGroup.ts`) follows a strict order:

```typescript
public render() {
    // 1. Depth-only pass for transparent objects (optional)
    if (renderDepthOnlyMeshes && this._depthOnlySubMeshes.length > 0) {
        engine.setColorWrite(false);
        this._renderAlphaTest(this._depthOnlySubMeshes);
        engine.setColorWrite(true);
    }

    // 2. Opaque meshes (any order is fine)
    if (this._opaqueSubMeshes.length > 0) {
        this._renderOpaque(this._opaqueSubMeshes);
    }

    // 3. Alpha test meshes (binary transparency)
    if (this._alphaTestSubMeshes.length > 0) {
        this._renderAlphaTest(this._alphaTestSubMeshes);
    }

    // 4. Sprites and particles
    this._renderSprites();
    this._renderParticles(activeMeshes);

    // 5. Transparent meshes (must be sorted back-to-front)
    if (this._transparentSubMeshes.length > 0) {
        this._renderTransparent(this._transparentSubMeshes);
    }
}
```

### Transparent Sorting

Transparent objects must be sorted by distance from camera:

```typescript
// renderingGroup.ts, line 260-271
for (const subMesh of subMeshes) {
    subMesh._distanceToCamera = Vector3.Distance(
        subMesh.getBoundingInfo().boundingSphere.centerWorld,
        cameraPosition
    );
}

sortedArray.sort(sortCompareFn);  // Back-to-front
```

This ensures correct alpha blending — far objects are drawn first, near objects blend on top.

---

## Stage 5: Submesh Rendering

Each submesh eventually calls `Mesh.render()`, which coordinates material binding and draw calls.

**Entry point:** `SubMesh.render()` at line 427 in `subMesh.ts`

### Material Readiness Check

Before drawing, verify the material is ready:

```typescript
// mesh.ts, line 2621-2649
const material = subMesh.getMaterial();
if (!material.isReadyForSubMesh(this, subMesh, hardwareInstancedRendering)) {
    return this;  // Skip this frame, try again next frame
}
```

A material might not be ready if:
- Shaders are still compiling
- Textures are still loading
- Defines changed and the effect needs rebuilding

### Material Binding

Once ready, bind the material's GPU state:

```typescript
// mesh.ts, line 2727-2731
const world = effectiveMesh.getWorldMatrix();
if (material._storeEffectOnSubMeshes) {
    material.bindForSubMesh(world, this, subMesh);
} else {
    material.bind(world, this);
}
```

This sets:
- Uniform values (matrices, colors, material properties)
- Texture bindings
- Blend state, depth state, cull mode

### Geometry Binding

The mesh's vertex and index buffers are bound:

```typescript
// mesh.ts, line 2713-2724
this._bind(subMesh, effect, fillMode, false);
```

This sets up the vertex attribute pointers and index buffer for the draw call.

### The Draw Call

Finally, the actual GPU command:

```typescript
// mesh.ts, line 2023-2050
public _draw(subMesh, fillMode, instancesCount) {
    const engine = scene.getEngine();

    if (this._unIndexed) {
        // Non-indexed: drawArrays
        engine.drawArraysType(fillMode, subMesh.verticesStart,
                              subMesh.verticesCount, instancesCount);
    } else {
        // Indexed: drawElements
        engine.drawElementsType(fillMode, subMesh.indexStart,
                               subMesh.indexCount, instancesCount);
    }
}
```

---

## Instanced Rendering

For many identical objects, Babylon uses hardware instancing to reduce draw calls.

### Instance Detection

During mesh collection, instances are grouped:

```typescript
// mesh.ts, line 2396-2402
if (hardwareInstancedRendering && mesh.hasThinInstances) {
    this._renderWithThinInstances(subMesh, fillMode, effect, engine);
    return this;
}
```

### Instance Data

Instance transforms are packed into a buffer:

```typescript
// Each instance: 16 floats (4x4 matrix)
instanceBuffer = [
    m00, m01, m02, m03,  // Instance 0, row 0
    m10, m11, m12, m13,  // Instance 0, row 1
    // ...
    // Instance 1, etc.
]
```

### Single Draw Call

All instances render with one `drawElementsInstanced`:

```typescript
engine.drawElementsType(fillMode, indexStart, indexCount, instanceCount);
```

A scene with 1000 identical trees becomes one draw call instead of 1000.

---

## The RenderItem Pattern

Babylon doesn't have an explicit "RenderItem" like Three.js, but the concept exists implicitly:

```typescript
// Conceptually, each submesh render is:
interface RenderItem {
    mesh: Mesh;
    subMesh: SubMesh;
    material: Material;
    distanceToCamera: number;  // For sorting
}
```

The RenderingManager's arrays (`_opaqueSubMeshes`, `_transparentSubMeshes`, etc.) serve this role.

---

## Frame Graph (Modern API)

Babylon.js 7.0 introduced FrameGraph, a declarative render pass system. Instead of imperative render() calls, you define passes and let the engine optimize:

```typescript
const frameGraph = new FrameGraph(scene);

const opaquePass = new FrameGraphRenderPass("opaque", frameGraph);
opaquePass.renderTarget = backbuffer;
opaquePass.renderList = opaqueObjects;

const transparentPass = new FrameGraphRenderPass("transparent", frameGraph);
transparentPass.renderTarget = backbuffer;
transparentPass.renderList = transparentObjects;
transparentPass.dependsOn(opaquePass);

frameGraph.execute();
```

This is conceptually similar to wgpu's render pass model and enables automatic pass merging and resource aliasing.

**Source:** `FrameGraph/` directory

---

## Performance Patterns

### Batching by Material

Babylon sorts opaque meshes by material to minimize state changes:

```typescript
// Conceptual sorting
opaqueSubMeshes.sort((a, b) => {
    return a.getMaterial().id - b.getMaterial().id;
});
```

Drawing all red cubes together, then all blue cubes, is faster than alternating.

### Lazy World Matrix

World matrices only update when transforms change:

```typescript
mesh._worldMatrixDeterminedByNestedMesh = false;
mesh._isDirty = true;
// Only recompute on next access
```

### Frustum Culling Hierarchy

For complex scenes, spatial structures (octrees, BVH) accelerate culling:

```typescript
scene.createOrUpdateSelectionOctree(maxCapacity, maxDepth);
```

The octree prunes entire regions before testing individual meshes.

---

## wgpu Mapping

The Babylon.js rendering pipeline maps to wgpu concepts:

| Babylon Concept | wgpu Equivalent |
|-----------------|-----------------|
| RenderingGroup | Render pass organization |
| Material.bind() | Bind group setup |
| Mesh._draw() | RenderPass::draw_indexed() |
| SubMesh | Draw call parameters |
| RenderTarget | wgpu::TextureView + RenderPass |
| FrameGraph pass | CommandEncoder + RenderPass |

A wgpu implementation would structure similarly:

```rust
// Collect visible meshes
let render_items = cull_and_sort(&scene, &camera);

// Create command encoder
let mut encoder = device.create_command_encoder(&desc);

// For each render pass
{
    let mut pass = encoder.begin_render_pass(&pass_desc);

    for item in &render_items.opaque {
        pass.set_pipeline(&item.pipeline);
        pass.set_bind_group(0, &item.bind_group, &[]);
        pass.set_vertex_buffer(0, item.vertex_buffer.slice(..));
        pass.set_index_buffer(item.index_buffer.slice(..), IndexFormat::Uint32);
        pass.draw_indexed(item.index_count, 1, 0, 0, 0);
    }
}

queue.submit(std::iter::once(encoder.finish()));
```

---

## Key Source Files

| Purpose | Path | Entry Point |
|---------|------|-------------|
| Main render entry | `scene.ts` | `render()` line 5388 |
| Mesh collection | `scene.ts` | `_evaluateActiveMeshes()` line 4641 |
| Rendering manager | `Rendering/renderingManager.ts` | `render()` line 197 |
| Rendering group | `Rendering/renderingGroup.ts` | `render()` line 123 |
| Submesh render | `Meshes/subMesh.ts` | `render()` line 427 |
| Mesh draw | `Meshes/mesh.ts` | `_draw()` line 2023 |
| Frame graph | `FrameGraph/frameGraph.ts` | Modern pass system |

All paths relative to: `packages/dev/core/src/`

---

## Next Steps

With the pipeline understood, dive deeper:

- **[WebGPU Engine](webgpu-engine.md)** — How draw calls become GPU commands
- **[Node Materials](node-materials.md)** — How materials compile shaders
