# three.js Architecture

## Module Dependency Graph

```
Three.js (entry)
    │
    └── Three.Core.js
            │
            ├── core/
            │   ├── Object3D.js ─────────── scene graph base
            │   ├── BufferGeometry.js ───── geometry container
            │   ├── BufferAttribute.js ──── vertex data
            │   ├── EventDispatcher.js ──── event system
            │   ├── Raycaster.js ────────── picking
            │   └── Clock.js ────────────── timing
            │
            ├── scenes/
            │   ├── Scene.js ────────────── root container
            │   └── Fog.js ──────────────── fog effects
            │
            ├── cameras/
            │   ├── Camera.js ───────────── base camera
            │   ├── PerspectiveCamera.js ── perspective projection
            │   └── OrthographicCamera.js ─ orthographic projection
            │
            ├── renderers/
            │   ├── WebGLRenderer.js ────── main renderer
            │   └── webgl/ ──────────────── 33 implementation modules
            │
            ├── objects/
            │   ├── Mesh.js ─────────────── geometry + material
            │   ├── Line.js ─────────────── line rendering
            │   ├── Points.js ───────────── particle systems
            │   └── Sprite.js ───────────── billboards
            │
            ├── materials/ ── 22 material classes
            ├── geometries/ ─ 23 geometry classes
            ├── lights/ ───── 8 light types
            └── math/ ─────── Vector, Matrix, Quaternion, etc.
```

## Core Abstractions

### Object3D (`core/Object3D.js`)
Base class for everything in the scene:
- `position`, `rotation`, `scale`, `quaternion`
- `parent`, `children` (tree structure)
- `matrix`, `matrixWorld` (transforms)
- `visible`, `frustumCulled`, `renderOrder`

### BufferGeometry (`core/BufferGeometry.js`)
Container for vertex data:
- `attributes` — position, normal, uv, etc.
- `index` — element indices
- `groups` — multi-material support
- `boundingBox`, `boundingSphere`

### Material Hierarchy
```
Material (base)
    ├── MeshBasicMaterial
    ├── MeshStandardMaterial
    ├── MeshPhysicalMaterial
    ├── ShaderMaterial (custom)
    └── ... (22 total)
```

## Initialization Flow

```
1. Create Scene
2. Create Camera (PerspectiveCamera typically)
3. Create WebGLRenderer, attach to DOM
4. Create geometries, materials, meshes
5. Add meshes to scene
6. Animation loop:
   a. Update objects
   b. renderer.render(scene, camera)
```

## Render Architecture

### WebGLRenderer Subsystems
- `WebGLPrograms` — shader program cache
- `WebGLState` — GL state machine wrapper
- `WebGLTextures` — texture management
- `WebGLBindingStates` — VAO management
- `WebGLRenderLists` — draw call sorting
- `WebGLShadowMap` — shadow rendering

### Render Pipeline
1. Update world matrices (traversal)
2. Project/cull against frustum
3. Sort render lists (opaque front-to-back, transparent back-to-front)
4. Execute draw calls

## Extension Architecture

No formal plugin system. Extensions are:
- Separate modules in `/examples/jsm/`
- Loaders: GLTFLoader, FBXLoader, etc.
- Controls: OrbitControls, FlyControls
- Post-processing: EffectComposer, passes

## Key Files to Read

| Concept | File | Size |
|---------|------|------|
| Scene graph | `core/Object3D.js` | Large |
| Renderer | `renderers/WebGLRenderer.js` | 105 KB |
| Geometry | `core/BufferGeometry.js` | |
| Material base | `materials/Material.js` | 31 KB |
| Math | `math/Vector3.js`, `math/Matrix4.js` | |
