# Three.js Architecture

> Why everything in 3D graphics eventually becomes a tree

## Key Insight

> **Scene Graph's core idea:** Store transforms relative to parents so moving a parent automatically moves all its children—the tree structure makes complex hierarchies manageable.

---

## The Problem: Organizing a Universe of Objects

Picture this: you are building a solar system visualization. Earth orbits the Sun. The Moon orbits Earth. A satellite orbits the Moon. When Earth moves, the Moon and satellite should move with it automatically. When the Moon moves relative to Earth, the satellite should follow. How do you express these relationships without manually updating every object's position every frame?

This is the fundamental challenge Three.js's architecture solves. A 3D scene is not just a bag of objects floating in space. Objects have spatial relationships. A wheel belongs to a car. A car belongs to a street. A character's hand belongs to their arm, which belongs to their torso. When the torso turns, everything downstream should follow.

The naive approach would be to store absolute world positions for everything and manually update them when parent objects move. This is tedious, error-prone, and scales terribly. Move the car, and you must remember to update four wheels, two doors, six windows, and a hundred other parts.

Three.js solves this with a **scene graph** — a tree structure where each node stores its position relative to its parent. Move the car, and all children automatically inherit that movement. The scene graph is the backbone of the entire architecture, and understanding it unlocks everything else.

---

## The Mental Model: A Mobile Sculpture

Think of Three.js's scene graph like a hanging mobile sculpture — the kind you might see above a baby's crib.

The topmost hook is the **Scene**: the root from which everything hangs. From it dangle several wires, each holding another piece. Some pieces are simple shapes. Others are sub-mobiles with their own dangling pieces.

When you push the top of the mobile, everything below sways together. Push a middle piece, and only its children move — the pieces above stay still. This is exactly how the scene graph works: transformations (position, rotation, scale) cascade downward but not upward.

Each piece in the mobile corresponds to an **Object3D**: Three.js's universal base class for anything that exists in 3D space. A Mesh is an Object3D. A Camera is an Object3D. Even a Light is an Object3D. They all share the same transform properties and parent-child machinery.

```
Scene (root of the mobile)
    │
    ├── Sun (Object3D)
    │       │
    │       └── Earth (Mesh)
    │               │
    │               └── Moon (Mesh)
    │                       │
    │                       └── Satellite (Mesh)
    │
    └── Camera (PerspectiveCamera)
```

When Earth rotates around the Sun, the Moon and Satellite rotate with it. When the Moon rotates around Earth, only the Satellite follows. The scene graph expresses these relationships declaratively — you describe what belongs to what, and Three.js handles the math.

---

## The Core Abstractions

Three.js is built on a handful of fundamental abstractions. Each exists for a specific reason.

### Object3D: The Universal Base Class

Every object that can exist in 3D space inherits from `Object3D`. This is where the scene graph machinery lives. Understanding Object3D is essential — it is the foundation everything else builds upon.

**Transform properties** define where the object is:
- `position` — where, relative to parent
- `rotation` — which way it faces, relative to parent
- `scale` — how big, relative to parent
- `quaternion` — rotation in a different form (avoids gimbal lock)

**Hierarchy properties** define relationships:
- `parent` — who this object belongs to (or null for Scene)
- `children` — array of objects attached to this one

**Computed matrices** are the result of cascading transforms:
- `matrix` — local transform relative to parent
- `matrixWorld` — absolute transform in world space (parent's matrixWorld * local matrix)

**Rendering hints** control visibility:
- `visible` — should this be rendered?
- `frustumCulled` — should the renderer skip this if outside camera view?
- `renderOrder` — explicit draw order override

The key insight is that `matrixWorld` is computed, not stored directly. When you call `updateMatrixWorld()`, Three.js walks the tree: each node multiplies its local matrix by its parent's matrixWorld to produce its own matrixWorld. This cascade is what makes "move the car, children follow" work automatically.

### BufferGeometry: Vertex Data

With the scene graph handling *where* objects are, the next question is *what* they look like. Geometry answers the first part: "What shape is this object?"

In GPU terms, a shape is just arrays of numbers: vertex positions, normals (which way each point faces), UV coordinates (texture mapping), and possibly colors, tangents, and custom attributes.

`BufferGeometry` is the container for all this data:

- `attributes` — a dictionary of named vertex arrays (position, normal, uv, etc.)
- `index` — optional array that defines faces by referencing vertices
- `groups` — ranges within the geometry that use different materials

Why a generic container instead of specific shape classes? Because GPUs do not care about "cubes" or "spheres" — they only see vertex buffers. By standardizing on BufferGeometry, Three.js can send any shape to the GPU the same way.

The `boundingBox` and `boundingSphere` properties enable frustum culling. Before the expensive work of transforming and shading vertices, Three.js can check: "Is this object's bounding sphere even inside the camera's view?" If not, skip it entirely.

### Materials: Surface Appearance

Geometry defines shape, but a shape without appearance is invisible. Materials answer the second part: "What does this surface look like?" They define color, texture, shininess, transparency, and how light interacts with the surface.

Three.js provides a hierarchy of material types:

```
Material (base class — rarely used directly)
    │
    ├── MeshBasicMaterial ──── unlit, ignores lights, just shows color/texture
    ├── MeshLambertMaterial ── simple diffuse lighting
    ├── MeshPhongMaterial ──── adds specular highlights
    ├── MeshStandardMaterial ─ physically-based rendering (PBR)
    ├── MeshPhysicalMaterial ─ PBR with advanced features (clearcoat, transmission)
    └── ShaderMaterial ─────── custom shaders, full control
```

Why so many? Because lighting calculations are expensive. A distant background object might use MeshBasicMaterial (no lighting math at all). A hero character might use MeshPhysicalMaterial (full PBR with subsurface scattering). The hierarchy lets you pick the right complexity-to-quality tradeoff.

### Mesh: Geometry + Material

Now we have shapes (geometry) and appearances (materials). A `Mesh` combines them into something the renderer can actually draw. It is an Object3D (so it has position/rotation/scale and can have children) that also carries the data needed to actually draw something.

This separation is intentional. The same geometry can be reused with different materials (a wooden cube vs. a metal cube). The same material can be applied to different geometries (everything in a room made of brick).

### Cameras: The Viewpoint

We have objects in 3D space, but we view them on a 2D screen. Cameras define this projection — they are the virtual eye through which you see the scene. They are Object3Ds too — a camera has position and rotation in the scene graph.

**PerspectiveCamera** mimics human vision: far objects appear smaller. Defined by field of view, aspect ratio, and near/far clipping planes.

**OrthographicCamera** has no perspective: a 10-meter object is the same size whether near or far. Useful for 2D games, CAD, and some artistic effects.

Why are cameras part of the scene graph? Because sometimes you want a camera attached to something — a first-person view attached to a player's head, or a chase camera attached to a car. Making cameras Object3Ds lets them inherit transforms like anything else.

### WebGLRenderer: The Orchestrator

All the pieces above — scene graph, geometry, materials, cameras — come together in the renderer. It takes a Scene and a Camera and produces pixels on screen. It is where the scene graph meets the GPU.

The renderer's job is complex enough that it is decomposed into subsystems:

- `WebGLPrograms` — compiles and caches shader programs
- `WebGLState` — wraps the GL state machine, tracks what is already set
- `WebGLTextures` — uploads and caches textures
- `WebGLBindingStates` — manages Vertex Array Objects
- `WebGLRenderLists` — sorts objects for optimal draw order
- `WebGLShadowMap` — handles shadow rendering passes

For details on the rendering process, see [Rendering Pipeline](rendering-pipeline.md). For the WebGPU-specific backend, see [WebGPU Backend](webgpu-backend.md).

---

## How Data Flows: Frame-by-Frame

Understanding the architecture means understanding what happens each frame. Here's the sequence:

```
1. Application updates scene
   └── Move objects, change materials, animate properties

2. renderer.render(scene, camera)
   │
   ├── 3. Update matrices
   │       └── Walk scene graph, compute matrixWorld for each node
   │
   ├── 4. Project and cull
   │       └── Test each object's bounding sphere against camera frustum
   │
   ├── 5. Sort render lists
   │       ├── Opaque objects: front-to-back (for early depth rejection)
   │       └── Transparent objects: back-to-front (for correct blending)
   │
   └── 6. Execute draw calls
           └── For each object: set pipeline, bind resources, draw
```

### Concrete Example: A Spinning Cube

Let's trace exactly what happens when you render a single rotating cube.

**Setup:**
```javascript
const geometry = new THREE.BoxGeometry(1, 1, 1);
const material = new THREE.MeshStandardMaterial({ color: 0xff0000 });
const cube = new THREE.Mesh(geometry, material);
scene.add(cube);
```

**Each frame:**
```javascript
cube.rotation.y += 0.01;  // Application updates the scene
renderer.render(scene, camera);
```

**Inside `renderer.render()`:**

1. **Matrix update** — The renderer calls `scene.updateMatrixWorld()`. This walks every Object3D. For the cube:
   - `cube.matrix` is computed from position/rotation/scale
   - `cube.matrixWorld` = parent.matrixWorld * cube.matrix (since parent is Scene, it is just cube.matrix)

2. **Frustum culling** — The cube's bounding sphere (computed from geometry) is transformed by matrixWorld and tested against the camera's frustum. Assuming it passes, the cube goes into the render list.

3. **Sorting** — With only one opaque object, sorting is trivial. In a complex scene, objects would be sorted by material (to minimize state changes), then by depth.

4. **Drawing** — The renderer:
   - Looks up or creates the appropriate shader program
   - Sets uniforms (model matrix, view matrix, projection matrix, material properties)
   - Binds the geometry's vertex buffers
   - Issues `gl.drawElements()` or the WebGPU equivalent

The key insight is separation of concerns: the application manipulates high-level scene graph concepts (rotation, parent-child relationships). The renderer handles the translation to GPU commands. Neither needs to know the details of the other.

---

## The Extension Model

Three.js has no formal plugin system. Instead, extensions are separate modules that work with the core objects:

**Loaders** parse external formats and produce Three.js objects:
- `GLTFLoader` — loads glTF models
- `FBXLoader` — loads FBX models
- `TextureLoader` — loads image files as textures

**Controls** add interactivity:
- `OrbitControls` — click-drag to orbit around a point
- `FlyControls` — WASD flight simulator movement
- `PointerLockControls` — first-person mouse look

**Post-processing** applies full-screen effects:
- `EffectComposer` — chains multiple passes
- `RenderPass` — renders the scene to a texture
- `BloomPass`, `SSAOPass`, etc. — various effects

These extensions live in `/examples/jsm/` rather than the core. This keeps the core small while providing a rich ecosystem. The pattern is simple: extensions import Three.js core and create, manipulate, or render Object3Ds using the standard APIs.

---

## wgpu/Rust Equivalent Patterns

If you are building a similar architecture in Rust with wgpu, here is how these concepts map:

### Scene Graph

```rust
struct Transform {
    position: Vec3,
    rotation: Quat,
    scale: Vec3,
}

struct SceneNode {
    transform: Transform,
    children: Vec<SceneNode>,
    world_matrix: Mat4,  // Computed, not stored directly
}

impl SceneNode {
    fn update_world_matrix(&mut self, parent_world: &Mat4) {
        let local = self.transform.to_matrix();
        self.world_matrix = *parent_world * local;

        for child in &mut self.children {
            child.update_world_matrix(&self.world_matrix);
        }
    }
}
```

The key difference: Rust's ownership model means you cannot easily have circular references or arbitrary parent pointers. Common patterns include arena allocation (all nodes in a Vec, referenced by index) or ECS (Entity Component System) approaches.

### Geometry

```rust
struct Geometry {
    positions: Vec<[f32; 3]>,
    normals: Vec<[f32; 3]>,
    uvs: Vec<[f32; 2]>,
    indices: Option<Vec<u32>>,

    // GPU resources (created on demand)
    vertex_buffer: Option<wgpu::Buffer>,
    index_buffer: Option<wgpu::Buffer>,
}
```

### Material-like State

In wgpu, materials become pipeline configurations. The "material hierarchy" becomes a set of pipeline variants:

```rust
struct MaterialParams {
    base_color: [f32; 4],
    metallic: f32,
    roughness: f32,
    // ...
}

// Different "materials" = different pipeline configurations
fn create_pipeline(
    device: &wgpu::Device,
    shader: &wgpu::ShaderModule,
    blend_mode: BlendMode,
    depth_write: bool,
) -> wgpu::RenderPipeline {
    // Pipeline encodes what Three.js spreads across Material + Renderer
}
```

### Renderer

```rust
struct Renderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline_cache: HashMap<PipelineKey, wgpu::RenderPipeline>,
}

impl Renderer {
    fn render(&mut self, scene: &Scene, camera: &Camera) {
        // 1. Update world matrices
        scene.root.update_world_matrix(&Mat4::IDENTITY);

        // 2. Cull and sort
        let frustum = Frustum::from_camera(camera);
        let render_list = self.build_render_list(scene, &frustum);

        // 3. Create command encoder and render pass
        let mut encoder = self.device.create_command_encoder(&Default::default());
        let mut pass = encoder.begin_render_pass(&self.render_pass_descriptor);

        // 4. Draw each object
        for item in render_list {
            let pipeline = self.get_or_create_pipeline(&item);
            pass.set_pipeline(pipeline);
            // ... set bind groups, vertex buffers, draw
        }

        drop(pass);
        self.queue.submit(std::iter::once(encoder.finish()));
    }
}
```

The architecture translates quite directly. The main Rust-specific concerns are lifetime management (encoder and pass have strict scopes) and pipeline caching strategy (explicit keys rather than JavaScript's flexible objects).

---

## Key Files to Explore

| Concept | File | Why Read It |
|---------|------|-------------|
| Scene graph base | `src/core/Object3D.js` | Understand transform cascade and parent-child |
| Geometry container | `src/core/BufferGeometry.js` | See how vertex data is organized |
| Material base | `src/materials/Material.js` | Understand common material properties |
| Main renderer | `src/renderers/WebGLRenderer.js` | See how it all comes together |
| WebGPU backend | `src/renderers/webgpu/WebGPUBackend.js` | Modern GPU abstraction |

---

## Common Pitfalls

A few gotchas that catch most newcomers:

**Forgetting `updateMatrixWorld()`** — If you manually set an object's `matrix` or `matrixWorld`, you must call `updateMatrixWorld(true)` to propagate changes to children. The renderer calls this automatically, but if you read matrix values between updates (for raycasting, physics, etc.), stale matrices cause subtle bugs.

**Gimbal lock with Euler rotations** — When using `rotation` (Euler angles), certain orientations cause axes to align and "lock up," making further rotation unintuitive. For smooth, arbitrary rotations — especially interpolated animations — use `quaternion` directly.

**Circular references and memory leaks** — Three.js objects hold references to geometry, materials, and textures. When removing objects from a scene, call `.dispose()` on geometries, materials, and textures you no longer need. Simply removing from the scene does not free GPU memory.

**Parent transforms affecting children unexpectedly** — Scaling a parent scales all children. A child at position (1, 0, 0) with a parent scaled 2x ends up at world position (2, 0, 0). This is correct behavior, but surprises people who forget that all transforms are relative.

---

## Next Steps

- **[Rendering Pipeline](rendering-pipeline.md)** — How the scene graph becomes GPU draw calls
- **[WebGPU Backend](webgpu-backend.md)** — The modern backend architecture

---

## Sources

- `libraries/threejs/src/core/Object3D.js`
- `libraries/threejs/src/core/BufferGeometry.js`
- `libraries/threejs/src/materials/Material.js`
- `libraries/threejs/src/renderers/WebGLRenderer.js`
- [Three.js Documentation](https://threejs.org/docs/)
- [Three.js Fundamentals](https://threejs.org/manual/)
