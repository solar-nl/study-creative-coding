# apEx Rendering Pipeline

> From Phoenix scene graph to DirectX 11 draw calls via CoRE2 abstraction

Every 64k intro needs to render compelling visuals in real-time while fitting all code, shaders, textures, meshes, and music into 65,536 bytes. Phoenix, the rendering engine behind apEx, faces a fascinating constraint: maximize visual sophistication while minimizing executable size. Most game engines optimize for performance, batching draw calls and caching GPU state. Phoenix optimizes for simplicity, accepting one draw call per material pass because the code to optimize would cost more bytes than it saves.

This trade-off reveals an important truth about creative coding frameworks. The "best" rendering pipeline isn't about squeezing every millisecond of GPU time. It's about matching your architecture to your constraints. For demomakers, that means predictable memory use, minimal branching, and straightforward data flow. For framework designers, it means understanding when to prioritize clarity over optimization.

The apEx pipeline transforms a hierarchical scene graph into GPU commands through a deliberate series of expansions. A scene containing animated objects becomes a flat array of render instances, each holding complete GPU state for a single draw call. Materials expand into multiple passes. Passes organize into render layers. Layers execute sequentially, building up the final image through multi-pass effects. By the time rendering starts, all decisions are made. The render loop just iterates and binds.

Think of this like an assembly line that does all its planning up front. During scene graph traversal, the engine evaluates animation curves, accumulates transformation matrices, expands materials into individual passes, and packages everything into self-contained render instances. Each instance is a complete work order: geometry buffers, shader handles, pipeline states, textures, matrices, and material parameters. The rendering phase becomes trivial because there's nothing left to decide.

Why trace this pipeline? Because it illuminates three critical patterns that every creative coding framework must address. First, when to expand abstractions into concrete commands: Phoenix does this early during traversal, trading memory for simplicity. Second, how to organize multi-pass rendering: the layer system decouples material definitions from effect composition. Third, where to draw the line on optimization: Phoenix deliberately avoids batching, instancing, and culling because the code overhead exceeds the runtime benefit in tightly authored demo content.

## The Challenge: Real-Time Demo Rendering

A typical game engine renders thousands of objects, batches by material, frustum culls invisible geometry, and manages level-of-detail streaming. But demos are different. Every frame is choreographed. Every object is placed intentionally. Nothing is off-screen by accident. The challenge isn't handling massive open worlds, it's generating stunning visuals with minimal executable bloat.

Phoenix's design reflects this reality. The scene graph is simple: objects have parents, children, and transformation matrices. No octrees. No spatial hashing. Materials expand into individual passes instead of batching shared state. Render layers enable sophisticated multi-pass effects without complicated orchestration logic. The entire system prioritizes code simplicity over runtime optimization.

This matters because in a 64k intro, every kilobyte counts. A sophisticated batching system might save 2ms per frame but cost 8KB of code. For demos, that's a terrible trade. Better to spend those bytes on more shaders, better procedural geometry, or richer animation data.

## CoRE2: The DirectX 11 Abstraction Layer

CoRE2 (likely "Core Rendering Engine 2") sits between Phoenix and DirectX 11, providing thin wrappers around GPU resources. Unlike heavyweight engines with complex resource managers, CoRE2's abstractions are almost transparent. An `ID3D11Buffer` pointer is just an `ID3D11Buffer` pointer. No handles, no indirection, no resource tables.

The abstraction provides platform-specific implementations for DirectX 9, DirectX 11, and potentially other APIs, but the Phoenix code only sees DirectX 11 interfaces. This keeps the graphics code straightforward while preserving portability to older hardware.

Key CoRE2 types include vertex buffers, index buffers, textures, shaders, and render states. Each wraps the corresponding DirectX object with minimal overhead. The device manages creation and destruction, but most rendering operations work directly with raw DirectX pointers. This design choice sacrifices type safety for executable size: wrapper methods would bloat the binary.

The global DirectX context pointer `phxContext` appears throughout Phoenix code. Every draw call, every state change, every resource bind goes through this raw `ID3D11DeviceContext` pointer. It's unconventional for modern engines but perfectly sensible when code size trumps encapsulation.

## Scene Graph to Render Queue

The journey begins when a timeline event fires. Demos are scripted: camera movements, scene transitions, post-processing effects all follow a precise timeline. At timestamp `t = 1.523` seconds, the timeline triggers a render scene event.

**Timeline.cpp:152** evaluates animation twice: once at the previous frame's timestamp, once at the current timestamp. This enables motion blur effects that need to know where objects were and where they are now. The scene graph updates twice, building two sets of transformation matrices, but only the final pass generates visible output.

After calculating camera view and projection matrices, the timeline calls `Scene->UpdateSceneGraph()` to traverse the hierarchy and collect render instances.

**Scene.cpp:51** clears all render layer queues, resets the light count, and initiates depth-first traversal. The identity matrix serves as the root transformation. Every child object multiplies its local transform against this accumulated parent matrix, propagating transformations down the hierarchy.

The clearing step is crucial. Unlike game engines that maintain persistent render queues and dirty flags, Phoenix regenerates the entire render list every frame. This seems wasteful until you remember that in a demo, everything animates continuously. There are no static objects to cache. Clearing and rebuilding is simpler than tracking changes.

After traversal completes, the scene calculates spotlight target directions for objects with target links. Then it collects up to 8 lights for shader lighting calculations. Finally, it sorts each layer's instances by render priority, ensuring transparent objects draw after opaque ones and sky domes render first.

## Hierarchy Traversal: Animation and Transformation

**Scene.cpp:229** walks the scene graph recursively. Each object evaluates its animation splines at the current timestamp, calculates its local transformation matrix, and multiplies against the parent's accumulated matrix.

Spline animation drives everything. Position, rotation, scale, color, material shininess, all come from spline curves. The `CalculateAnimation()` call evaluates these curves, storing results in a `SplineResults` array. The engine then constructs a transformation matrix from the position, rotation, and scale components.

Matrix accumulation happens through standard multiplication: `D3DXMatrixMultiply(&m, &prs, &CurrentMatrix)`. The local position-rotation-scale matrix (`prs`) multiplies against the parent's accumulated matrix (`CurrentMatrix`), producing the final world matrix (`m`). This world matrix flows down to child objects, accumulating transformations through the entire hierarchy.

The engine stores both the current and previous frame's matrices. Motion blur and velocity-based effects need temporal information. By maintaining both states, shaders can compute velocity vectors and apply temporal anti-aliasing or motion blur without additional passes.

After computing transformations, the object calls `CreateRenderDataInstances()`. This is a polymorphic dispatch: mesh objects create render instances with material expansion, light objects do nothing, particle emitters update simulation state. The type-specific behavior happens here, during traversal, not during rendering.

Finally, the object recurses to its children, passing the accumulated matrix. Each child multiplies its local transform and continues propagation. By the time traversal completes, every leaf object has its final world transformation.

## Model Processing: Mesh to Render Instance

**Model.cpp:25** handles mesh objects specifically. When a mesh creates render instances, it calculates transformation matrices and applies animated material parameters.

The mesh multiplies its local transformation matrix against the accumulated parent matrix to produce the world matrix. It also calculates the inverse-transpose matrix, which is essential for transforming normal vectors correctly. Normal vectors must remain perpendicular to surfaces even under non-uniform scaling, requiring the inverse-transpose rather than the standard world matrix.

Material splines are separate from object splines. An object might animate position while its material animates color or shininess. Both sets of splines evaluate at the same timestamp but control different parameters. This separation enables independent animation of geometry and appearance.

The mesh then collects animated material data for each pass. If a material has two techniques, and the first technique has two passes while the second has three, this generates five separate material states. Each state contains constant data set once during material creation plus animated data evaluated every frame from splines.

After collecting all material data, the mesh calls `Material->CreateRenderDataInstances()` to perform material expansion.

## Material Expansion: One Pass Becomes One Instance

**Material.cpp:117** is where the cookbook analogy becomes concrete. Each material technique contains multiple passes. A single chrome metal material might have three passes: base color, environment reflection, and specular highlight. Material expansion creates a separate render instance for each pass.

The expansion happens during scene traversal, not during rendering. This is a key design decision. By the time the render loop starts, every instance exists with all GPU state baked in. No lookups, no decisions, just iteration and binding.

Each `CphxRenderDataInstance` allocation receives:
- Vertex buffer, index buffer, and wireframe index buffer pointers
- Five shader stage pointers: vertex, pixel, geometry, hull, and domain shaders
- Three render state objects: blend state, rasterizer state, depth-stencil state
- Eight texture resource view pointers
- Two transformation matrices: world and inverse-transpose
- A block of material parameter data combining constants and animated values

The code uses `memcpy` to copy contiguous blocks of data. Five shader pointers copy in one operation. Eleven state and texture pointers copy in another. This optimization saves a few bytes of executable code while maintaining clarity. Comments warn against reordering struct members because this relies on exact memory layout.

The render instance is completely self-contained. It holds everything needed to issue a draw call. No shared state tables. No material lookups. No texture resolution. Everything is right there in the struct. This approach trades memory for simplicity: 300+ bytes per instance versus handles that might be 8 bytes. But for tightly authored demo content with a few hundred instances, the memory cost is acceptable.

After populating the instance, the material adds it to a render layer queue.

## Render Layers: Multi-Pass Organization

**Scene.cpp:205** adds each render instance to a specific render layer. Layers are how Phoenix implements multi-pass rendering effects without explicit pass management in material code.

A typical effect chain might look like this:
- Layer 0: Render scene geometry to a texture at full resolution
- Layer 1: Downsample and apply Gaussian blur for bloom
- Layer 2: Render depth-of-field blur using scene depth
- Layer 3: Combine bloomed and blurred results with color grading
- Layer 4: Apply film grain and output to screen

Each layer can target different render textures, clear buffers differently, and render at different resolutions. A motion blur effect might render velocity vectors to a half-resolution buffer in one layer, then sample that buffer in a later layer to blur the final image.

The layer descriptor is set in the material definition. When artists create materials, they specify which layer each technique targets. This decouples material design from effect implementation. The artist marks a material as "bloom glow" and assigns it to layer 1. The engine automatically renders it to the bloom texture without additional material code.

The layer system also solves the render order problem elegantly. Within each layer, instances sort by render priority. But across layers, execution order is fixed: layer 0, then layer 1, then layer 2. This guarantees that dependent effects execute in the correct sequence without manual dependency tracking.

## Render Execution: Iterating Layers and Instances

**Scene.cpp:136** processes each layer sequentially after scene graph traversal completes. For each layer, it uploads scene-level data to a constant buffer, then renders all instances in that layer.

The scene constant buffer contains shared data that all instances need: view matrix, projection matrix, inverse view matrix, inverse projection matrix, camera position, light count, light data array, and render target resolution with reciprocals. This two-tier uniform structure separates shared data from per-instance data, reducing redundant uploads.

The resolution reciprocals are a micro-optimization common in demoscene code. Instead of dividing by resolution in shaders (`uv / resolution`), multiply by the reciprocal (`uv * invResolution`). On older GPUs, division was slower than multiplication. Modern GPUs optimize this automatically, but the pattern persists.

The constant buffer uploads to slot 0 in all shader stages: vertex, geometry, and pixel. Slot 1 will receive object-specific data during instance rendering. This convention keeps shader code consistent across materials.

After binding scene data, the layer iterates through its render instances, calling `Render()` on each. After all instances complete, the layer generates mipmaps if its render targets need them. Render-to-texture effects often require mipmap chains for blurring or level-of-detail sampling in later passes.

## Draw Call Execution: Final GPU Submission

**RenderLayer.cpp:27** executes a single render instance. This is the final step where all preparation pays off. The function binds GPU state and issues the draw call.

First, it validates that the instance has a vertex shader, pixel shader, and vertex buffer. Invalid instances skip rendering to avoid driver crashes. This defensive check costs a few bytes but prevents mysterious failures during tool development.

The function sets the input assembler state: vertex format, vertex buffer with stride and offset, and primitive topology. Triangle lists for normal geometry, line lists for wireframe mode. The stride is hardcoded to `PHXVERTEXFORMATSIZE`, indicating a fixed vertex format across all Phoenix content.

Then it binds all five shader stages. Even if the material only uses vertex and pixel shaders, the code explicitly binds `NULL` to geometry, hull, and domain shader slots. This ensures clean state and costs nothing at runtime since the branching would cost more code bytes than unconditional binding.

Next come the three render state objects: rasterizer state, blend state, and depth-stencil state. These control polygon culling, alpha blending, and depth testing. Each material pass can specify independent state, enabling effects like double-sided rendering or additive blending.

The object constant buffer uploads to slot 1 using `D3D11_MAP_WRITE_DISCARD`, which tells DirectX to allocate fresh memory instead of waiting for the GPU to finish using old data. This avoids pipeline stalls. Every frame gets new constant buffer memory, discarding the old contents. The engine copies two 4x4 matrices (world and inverse-transpose) plus the material parameter data in one contiguous block.

Texture binding happens to all shader stages simultaneously. Eight texture slots bind to vertex, geometry, and pixel shaders. Even though most materials only use textures in the pixel shader, binding to all stages is simpler than tracking which stages need which textures. Unconditional binding saves code bytes and rarely impacts performance.

Finally, the function binds the index buffer (choosing between triangle indices and wireframe indices based on debug mode) and calls `DrawIndexed()` with the appropriate index count. One function call, one draw call submitted to the GPU.

That's it. No state diffing. No redundant bind elimination. No draw call sorting beyond render priority. The simplicity is deliberate. Every optimization adds code. In a 64k intro, those bytes matter more than microseconds.

## Data Flow Summary

The complete flow from timeline to pixels:

```
Timeline Event (t = 1.523 seconds)
    │
    ├─ Calculate camera view/projection matrices
    │  (Timeline.cpp:152)
    │
    ▼
UpdateSceneGraph (clear all render queues)
    │  (Scene.cpp:51)
    │
    ├─ For each root object
    │     │
    │     ▼
    │  TraverseSceneGraph (depth-first)
    │     │  (Scene.cpp:229)
    │     │
    │     ├─ Evaluate splines at time t → SplineResults[]
    │     ├─ Build position-rotation-scale matrix
    │     ├─ Multiply against parent matrix
    │     ├─ Store current and previous matrices
    │     │
    │     ▼
    │  CreateRenderDataInstances (polymorphic)
    │     │  (Model.cpp:25)
    │     │
    │     ├─ Calculate world matrix and inverse-transpose
    │     ├─ Apply material animation splines
    │     ├─ Collect animated data for each pass
    │     │
    │     ▼
    │  Material->CreateRenderDataInstances
    │     │  (Material.cpp:117)
    │     │
    │     ├─ For each material pass
    │     │    │
    │     │    ├─ Allocate CphxRenderDataInstance
    │     │    ├─ Copy geometry buffer pointers
    │     │    ├─ Copy 5 shader stage pointers
    │     │    ├─ Copy 3 state objects + 8 textures
    │     │    ├─ Copy matrices and material data
    │     │    │
    │     │    ▼
    │     └─ AddRenderDataInstance (to layer queue)
    │           (Scene.cpp:205)
    │
    ├─ Calculate spotlight target directions
    ├─ Collect lights (up to 8)
    └─ Sort each layer by render priority

Render (for each layer)
    │  (Scene.cpp:136)
    │
    ├─ SetEnvironment (bind render targets)
    ├─ Upload scene constant buffer
    │     (view/proj matrices, lights, camera pos)
    │
    ├─ For each render instance in layer
    │     │
    │     ▼
    │  RenderDataInstance->Render()
    │     │  (RenderLayer.cpp:27)
    │     │
    │     ├─ Bind vertex buffer and input layout
    │     ├─ Set primitive topology (triangles/lines)
    │     ├─ Bind 5 shader stages (VS/GS/HS/DS/PS)
    │     ├─ Bind 3 render states (raster/blend/depth)
    │     ├─ Upload object constant buffer (slot 1)
    │     │     (world matrix, inv-transpose, material data)
    │     ├─ Bind 8 textures to all stages
    │     ├─ Bind index buffer
    │     │
    │     ▼
    │  phxContext->DrawIndexed()
    │
    └─ GenerateMipmaps (if layer needs them)

Pixels on Screen
```

## Key Data Structures

Understanding the core types illuminates the design philosophy.

### CphxRenderDataInstance

**RenderLayer.h:10** defines the render instance structure. This is the fundamental unit of rendering: one instance equals one draw call.

```cpp
class CphxRenderDataInstance
{
public:
  int RenderPriority;           // Sort key for draw order
  bool Wireframe;               // Debug mode flag
  bool Indexed;                 // Triangle list vs point list

  // Geometry buffers
  ID3D11Buffer *VertexBuffer;
  ID3D11Buffer *IndexBuffer;
  ID3D11Buffer *WireBuffer;     // Debug wireframe indices
  int TriIndexCount;
  int WireIndexCount;

  // Shader pipeline (5 stages)
  ID3D11VertexShader *VS;       // WARNING: DO NOT REORDER
  ID3D11PixelShader *PS;        // These 5 pointers copy via memcpy
  ID3D11GeometryShader *GS;
  ID3D11HullShader *HS;
  ID3D11DomainShader *DS;

  // Pipeline states (11 pointers total)
  ID3D11BlendState *BlendState;           // WARNING: DO NOT REORDER
  ID3D11RasterizerState *RasterizerState; // These 11 pointers copy via memcpy
  ID3D11DepthStencilState *DepthStencilState;
  ID3D11ShaderResourceView *Textures[8];

  // Transform and material data
  D3DXMATRIX Matrices[2];      // World, inverse-transpose
  float MaterialData[...];      // Flattened material parameters

  void *ToolData;               // Editor metadata pointer

  void Render();
};
```

The warnings about not reordering are significant. The code relies on exact memory layout for bulk copying. This saves a few bytes by using `memcpy` instead of individual field assignments. It works, but it's fragile. Modern frameworks should prefer type-safe copying even at the cost of a few extra bytes.

### Scene Hierarchy

The scene graph is a straightforward parent-child tree:

```
CphxScene
├─ Objects[]
│  ├─ CphxObject (base class)
│  │  ├─ Parent pointer
│  │  ├─ Children[]
│  │  ├─ SplineResults[] (evaluated animation data)
│  │  ├─ currMatrix, prevMatrix (accumulated transforms)
│  │  └─ virtual CreateRenderDataInstances()
│  │
│  ├─ CphxModelObject_Mesh : CphxObject
│  │  ├─ Material pointer
│  │  ├─ MaterialState[] (per-pass constant data)
│  │  └─ CreateRenderDataInstances() override
│  │
│  └─ CphxObject_Light : CphxObject
│     └─ CreateRenderDataInstances() override (does nothing)
│
└─ RenderLayers[]
   ├─ CphxRenderLayer
   │  ├─ Descriptor (target textures, clear flags)
   │  └─ RenderInstances[] (sorted by priority)
   │
   └─ ...
```

Clean separation of concerns: objects hold animation state, materials hold rendering state, layers hold instance queues. The polymorphic `CreateRenderDataInstances()` method dispatches to type-specific behavior, keeping the traversal code generic.

## Key Observations

### 1. Material Expansion Creates One Instance Per Pass

This is the most surprising aspect for game engine developers. A scene with 100 meshes and materials averaging 2 passes generates 200 render instances and 200 draw calls. No batching. No instancing. No draw call merging.

For a 64k intro with carefully authored content, this is acceptable. Every object is visible. Every pass is necessary. The overhead of batching (state sorting, instance data uploads, multi-draw setup) would cost more executable bytes than it saves in GPU time.

A general-purpose engine would batch instances with identical materials, use hardware instancing for repeated geometry, or merge static meshes into uber-buffers. But those techniques add code complexity. Phoenix prioritizes simplicity.

### 2. Early Decision Making

By the time rendering starts, every decision freezes. Shader selection, blend mode, material parameters, transformation matrices all lock during scene traversal. The render loop has zero conditional logic beyond validation checks. It just iterates and binds.

This pattern trades memory for CPU efficiency. Storing complete GPU state for every instance uses more memory than indices into shared state objects. But it eliminates hash table lookups, state diffing, and redundant bind elimination. For a few hundred instances, the memory cost is negligible and the code simplicity is valuable.

### 3. No Frustum Culling

The scene graph traversal visits every object every frame. No bounding volume tests. No octree queries. No visibility determination.

This seems wasteful until you remember the content is tightly authored. In a demo, objects outside the view frustum rarely appear. The cost of culling checks would exceed the cost of drawing a few extra objects. The code to implement frustum culling would consume kilobytes. Drawing a few invisible triangles costs microseconds.

This wouldn't work for open-world games with thousands of objects spread across kilometers. But for a demo where every frame is choreographed, it's the right choice. Add culling when the content demands it, not preemptively.

### 4. Spline Animation Everywhere

Position, rotation, scale, color, material parameters, everything animates via splines. The `CalculateAnimation()` call evaluates potentially hundreds of spline curves every frame. This is expensive in CPU time, but demos are all about motion. Static content doesn't justify making a demo.

Spline data is remarkably compact. Instead of storing dense keyframe arrays, splines store a few control points and an interpolation mode. Catmull-Rom splines produce smooth motion from four control points per segment. This data compresses well in the final executable, making splines both beautiful and byte-efficient.

This ubiquity of spline-driven animation shapes how the rendering pipeline organizes multi-pass effects. Materials need per-instance parameter variation, layers need independent render targets, and the scene graph needs to rebuild state every frame because nothing stays static.

### 5. Render Layers Enable Effect Composition

Layers solve the multi-pass rendering problem elegantly without explicit orchestration code. Each layer has independent render targets, clear flags, and instance queues. Effects compose naturally by assigning materials to appropriate layers.

Want bloom? Render glowing objects to a separate layer, blur it, combine with the main scene. Want depth-of-field? Render depth to a layer, use it to blur the final image in another layer. Want motion blur? Render velocity vectors to a layer, sample them during final composition.

Material definitions specify target layers through simple indices. Artists tag materials with layer numbers. The engine handles sequencing automatically. No render pass management code. No manual dependency tracking. Just declare your intent and the engine figures out the rest.

### 6. Sorting by Priority

Render priority ensures correct draw order without manual management. Transparent objects get high priority values so they draw after opaque geometry. Sky domes get low priority to draw first. Background elements render before foreground.

The sorting happens once per layer after scene traversal using quicksort. Even with 200 instances, sorting takes microseconds. The memory access pattern during rendering benefits from sorted order because state changes cluster together: all opaque materials render, then all transparent materials.

Priority-based sorting is simpler than dependency graphs or explicit ordering constraints. Assign priorities during material creation, forget about ordering during rendering. The sort is stable, so materials with equal priority maintain their relative order from traversal.

## Implications for Rust Framework Design

This code trace reveals patterns worth adopting, modifying, or avoiding in a modern creative coding framework.

### Adopt: Render Layers for Effect Composition

The layer system is elegant and maps naturally to Rust. Instead of manually orchestrating render passes, materials declare their target layer and the engine handles sequencing.

```rust
pub struct RenderLayer {
    descriptor: LayerDescriptor,
    instances: Vec<RenderInstance>,
}

impl RenderLayer {
    pub fn add_instance(&mut self, instance: RenderInstance) {
        self.instances.push(instance);
    }

    pub fn render(&mut self, encoder: &mut wgpu::CommandEncoder) {
        self.descriptor.bind_targets(encoder);
        for instance in &self.instances {
            instance.render(encoder);
        }
        self.descriptor.generate_mipmaps(encoder);
    }
}
```

Layers encapsulate render-to-texture operations cleanly. Post-processing effects, shadow maps, reflection probes, deferred rendering all use the same mechanism. Users compose effects by assigning materials to layers without writing orchestration logic.

### Adopt: Spline Animation as First-Class Feature

Everything in Phoenix animates through splines. A Rust framework should make spline animation trivial through generic traits.

```rust
pub struct Spline<T> {
    control_points: Vec<(f32, T)>,
    interpolation: InterpolationMode,
}

impl<T: Interpolate> Spline<T> {
    pub fn evaluate(&self, t: f32) -> T {
        // Catmull-Rom, Bezier, or linear interpolation
    }
}

// Embed in objects
pub struct Transform {
    position: Spline<Vec3>,
    rotation: Spline<Quat>,
    scale: Spline<Vec3>,
}
```

Traits like `Interpolate` let users animate custom types. Provide spline types for common cases (linear, Catmull-Rom, Bezier) but enable extension. This pattern enables procedural motion without keyframe bloat.

### Adopt: Separate Scene and Object Constant Data

The two-tier constant buffer structure is smart. Scene data (camera, lights) uploads once per layer. Object data (matrices, material parameters) uploads per instance.

In wgpu terms, this becomes bind group 0 for scene uniforms and bind group 1 for object uniforms. Set bind group 0 once per layer, bind group 1 per instance. This minimizes redundant uploads while keeping shader code consistent.

```rust
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct SceneUniforms {
    view_matrix: Mat4,
    projection_matrix: Mat4,
    camera_pos: Vec4,
    light_count: u32,
    lights: [Light; 8],
}

#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
struct ObjectUniforms {
    world_matrix: Mat4,
    inv_transpose_matrix: Mat4,
    material_data: [f32; 64],
}
```

The pattern extends naturally to more bind groups for material-specific data, making it easy to batch instances with identical materials.

### Modify: Avoid One Instance Per Pass Expansion

Phoenix's material expansion is correct for 64k intros but wasteful for general use. A modern engine should batch instances with identical materials and use multi-draw indirect when available.

```rust
pub struct RenderBatch {
    material: MaterialHandle,
    instances: Vec<InstanceData>,
}

impl RenderBatch {
    pub fn render(&self, encoder: &mut wgpu::CommandEncoder) {
        // Bind material pipeline and textures once
        self.material.bind(encoder);

        // Multi-draw indirect for all instances
        encoder.multi_draw_indexed_indirect(&self.instance_buffer, ...);
    }
}
```

This batches instances with identical materials, issuing one GPU command instead of hundreds. The overhead of multi-draw setup amortizes across many instances. Users creating 64k intros can disable batching for simplicity. Users creating real-time tools benefit from optimization.

### Modify: Add Optional Frustum Culling

Phoenix skips culling because content is tightly authored. A general framework should make culling optional but available.

```rust
pub struct Scene {
    objects: Vec<Object>,
    spatial_index: Option<Octree>,
}

impl Scene {
    pub fn collect_visible(&self, frustum: &Frustum) -> Vec<&Object> {
        match &self.spatial_index {
            Some(octree) => octree.query_frustum(frustum),
            None => self.objects.iter().collect(),
        }
    }
}
```

Users creating open-world content enable the octree. Users creating tightly authored scenes disable it. Default to simplicity, opt into complexity. This matches the Phoenix philosophy while accommodating different use cases.

### Modify: Support Instancing for Repeated Geometry

Phoenix never uses hardware instancing. Every object is a separate draw call. But many creative coding scenes have repeated elements: particles, foliage, procedural patterns.

```rust
pub struct InstancedMesh {
    mesh: MeshHandle,
    material: MaterialHandle,
    transforms: Vec<Mat4>,
}

impl InstancedMesh {
    pub fn render(&self, encoder: &mut wgpu::RenderCommandEncoder) {
        // Upload instance transforms to buffer
        let instance_buffer = self.upload_instances(encoder);

        // Single draw call for all instances
        encoder.draw_indexed(
            mesh.index_range(),
            0,
            0..self.transforms.len() as u32,
        );
    }
}
```

This pattern accelerates scenes with repeated elements without forcing all content to use instancing. Provide both paths: simple one-object-one-draw-call for straightforward cases, instancing for repeated geometry.

### Avoid: Storing Complete GPU State in Instances

Phoenix's `CphxRenderDataInstance` holds eight texture handles, three state objects, five shader handles, two matrices, and material data. This is 300+ bytes per instance. For 10,000 instances, that's 3MB of redundant data.

A Rust framework should use handle-based lookups with material caching:

```rust
pub struct RenderInstance {
    mesh: MeshHandle,
    material: MaterialHandle,
    transform: Mat4,
    layer: LayerIndex,
}

// Materials cache pipelines and bind groups
pub struct Material {
    pipeline: wgpu::RenderPipeline,
    bind_groups: Vec<wgpu::BindGroup>,
}
```

Handles are 4-8 bytes. Instance data shrinks to 80 bytes. The material cache deduplicates pipelines and bind groups automatically. This trades memory for one level of indirection, which modern CPUs handle efficiently.

Rust's ownership system makes this natural. Materials own pipelines. Instances hold non-owning references through handles. The framework guarantees materials outlive instances without runtime overhead.

### Avoid: Allocating Instances Per Frame

Phoenix calls `new CphxRenderDataInstance()` hundreds of times per frame. Small allocations are fast with modern allocators, but not free. A Rust framework should use an arena allocator or reuse instances.

```rust
pub struct FrameArena {
    instances: Vec<RenderInstance>,
    index: usize,
}

impl FrameArena {
    pub fn allocate(&mut self) -> &mut RenderInstance {
        if self.index >= self.instances.len() {
            self.instances.push(RenderInstance::default());
        }
        let instance = &mut self.instances[self.index];
        self.index += 1;
        instance
    }

    pub fn reset(&mut self) {
        self.index = 0;  // Reuse allocations next frame
    }
}
```

Allocate once at startup, reuse every frame. This eliminates per-frame allocator churn and improves cache locality. The pattern is straightforward in Rust: grow a vec once, then slice into it every frame.

## Comparison with fr_public Werkkzeug4

The fr_public repository contains Werkkzeug4, another demoscene tool with a different architectural approach. Comparing reveals interesting trade-offs.

### Operator System vs Scene Graph

Werkkzeug4 uses an operator graph where nodes represent data transformations. Operators are defined declaratively in `.ops` files and compiled into C++. The graph evaluates lazily with caching: request output from a root operator, recursively evaluate inputs if dirty, execute operator code, cache result.

Phoenix uses a traditional scene graph with objects, parents, children, and transformation matrices. Evaluation is eager: every frame traverses the entire hierarchy, recalculates all transformations, and regenerates all render instances. No caching, no dirty tracking.

The operator system is more flexible for procedural content generation. Artists can build complex meshes through node chains: primitive → deform → multiply → merge. Phoenix requires explicit procedural mesh generation code or pre-generated assets.

But the scene graph is simpler for animated playback. Timeline events directly control object splines. No graph evaluation, no cache invalidation. For real-time demo playback, simplicity wins.

### Graphics Abstraction

Altona (the framework underlying Werkkzeug4) provides a complete abstraction over DirectX 9, DirectX 11, OpenGL 2.0, and OpenGL ES 2.0. Classes like `sGeometry`, `sTexture2D`, `sMaterial` wrap platform-specific implementations. The abstraction is thicker than CoRE2.

Phoenix's CoRE2 is thinner. Most code works directly with `ID3D11*` interfaces. The abstraction primarily handles device creation and resource management, not per-frame rendering calls.

Thicker abstraction supports more platforms but costs executable size. Thinner abstraction saves bytes but ties code to specific APIs. For 64k intros targeting Windows, Phoenix's choice is pragmatic.

### Material System

Werkkzeug4 materials are shader-based with parameter definitions in operator files. The tool generates UI controls automatically from parameter declarations. Material evaluation happens during operator graph execution.

Phoenix materials are shader-based with manual parameter management. Parameters come from splines evaluated during scene traversal. Material expansion into passes happens during traversal, creating render instances.

Both approaches work. Werkkzeug4's declarative parameters are more tool-friendly. Phoenix's manual approach is more byte-efficient. Different priorities for different projects.

### Render Pipeline Philosophy

Werkkzeug4 separates content creation (operators) from rendering (Altona). The operator graph produces data: meshes, textures, render trees. The rendering system consumes that data. Clean separation enables tool features like previewing intermediate results.

Phoenix blurs the boundary. The scene graph contains both data (meshes, materials) and rendering logic (render layers, instance creation). This coupling simplifies the runtime engine but makes tool features harder to implement cleanly.

For framework design, the lesson is: decide whether your abstraction serves content creation, runtime rendering, or both. Optimize for your primary use case. Don't try to be everything to everyone.

## References

- `apEx/Phoenix/Timeline.cpp:152` - Timeline event triggering scene render
- `apEx/Phoenix/Scene.cpp:51` - Scene graph update and queue clearing
- `apEx/Phoenix/Scene.cpp:229` - Object hierarchy traversal with animation
- `apEx/Phoenix/Scene.cpp:205` - Adding instances to render layer queues
- `apEx/Phoenix/Scene.cpp:136` - Layer iteration and rendering
- `apEx/Phoenix/Model.cpp:25` - Mesh object render instance creation
- `apEx/Phoenix/Material.cpp:117` - Material technique pass expansion
- `apEx/Phoenix/RenderLayer.cpp:27` - Final draw call execution
- `apEx/Phoenix/RenderLayer.h:10` - RenderDataInstance structure definition
- `notes/per-demoscene/apex-public/code-traces/scene-to-pixels.md` - Detailed code trace
