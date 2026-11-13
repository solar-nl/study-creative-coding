# Mesh Handle Composition: One Value or Many?

> Every major 3D framework in this survey wraps mesh data in a composite handle — not because discrete buffers are wrong, but because the composite is the natural *unit of work* for the operators that produce and consume it.

---

## Why This Question Exists

CME's `Value` enum has a dormant variant:

```rust
// flux-core/src/value/mod.rs
Mesh(ResourceId),
```

No operator currently produces or consumes it. Today, `DrawIndexedOp` works with three separate values on three separate ports: `vertex_buffer` (BufferHandle), `index_buffer` (BufferHandle), and `index_count` (Int). That works fine — but it establishes a precedent that mesh data flows as three wires.

The design question is whether to *consolidate* into a real composite mesh resource (with `GpuResourceMap::register_mesh` / `get_mesh`, and a refactor of `DrawIndexedOp` to consume a `Value::Mesh`) or to *leave mesh data as discrete graph values*. The answer affects graph wiring ergonomics, future LoadMesh and mesh-modifier operators, and whether `Value::Mesh` will ever carry meaning.

This document surveys how frameworks handle the problem, then gives a concrete recommendation for CME.

---

## What Does a "Mesh" Actually Carry?

Before asking composite vs discrete, it helps to know what the composite would contain. This is not universal — it depends on how much metadata operators need to pass along with vertex/index bytes.

### The wgpu lower bound

wgpu's `Buffer` is entirely untyped bytes. A single `Buffer` can hold both vertex and index data at different offsets. There is no built-in "mesh" concept. The API gives you `set_vertex_buffer(slot, buffer_slice)` and `set_index_buffer(buffer_slice, index_format)` on a `RenderPass`. Two separate slices, explicitly typed at binding time.

This is the *floor*: the GPU API itself knows nothing about meshes. Everything above wgpu's `Buffer` level is a decision made by the application.

### rend3's `Mesh` struct (CPU-side, Rust)

rend3's CPU-side representation is a structure of arrays — each vertex attribute in its own `Vec`, indices separate:

```rust
pub struct Mesh {
    pub vertex_positions: Vec<Vec3>,
    pub vertex_normals: Vec<Vec3>,
    pub vertex_tangents: Vec<Vec3>,
    pub vertex_uv0: Vec<Vec2>,
    pub vertex_uv1: Vec<Vec2>,
    pub vertex_colors: Vec<[u8; 4]>,
    pub vertex_joint_indices: Vec<[u16; 4]>,
    pub vertex_joint_weights: Vec<Vec4>,
    pub indices: Vec<u32>,
}
```

When submitted to the renderer, this uploads into a 32MB megabuffer (see [`per-framework/rend3.md`](per-framework/rend3.md)), and rend3 hands back a `MeshHandle` (an integer index). Internally, that handle resolves to ranges within the megabuffer — a single integer that encodes vertex data + index data + layout metadata. The consumer never sees discrete buffer IDs; it sees a handle that says "mesh #47."

### Bevy's `Mesh` (CPU) + `GpuMesh` (GPU)

Bevy maintains a clean CPU/GPU split. The CPU `Mesh` stores named attributes (position, normal, UV, tangent, color, joint weights, skin indices), optional indices, primitive topology (TriangleList, TriangleStrip, etc.), and morph target data.

The GPU side — originally `GpuMesh`, later restructured with `MeshAllocator` — is a composite that carries:

- `vertex_buffer`: the wgpu `Buffer` with interleaved attribute data
- `vertex_count: u32`
- `buffer_info`: a `GpuBufferInfo` enum distinguishing *indexed* (`IndexedBufferInfo { index_buffer, index_count, index_format }`) from *non-indexed* (`NonIndexedBufferInfo`)
- `primitive_topology`: the wgpu `PrimitiveTopology`
- `layout`: `MeshVertexBufferLayout` (which attributes are present, their byte strides)

This is the most instructive design for CME, because it was an explicit engineering decision to package these together and it directly answers the "indexed vs non-indexed" shape question.

### Three.js `Mesh` + `BufferGeometry`

Three.js splits at a higher level. The scene object called `Mesh` is: `geometry` (a `BufferGeometry`) + `material` + transform (inherited from `Object3D`). The actual vertex/index container is `BufferGeometry`.

`BufferGeometry` carries:
- A map of named `BufferAttribute` objects (`position`, `normal`, `uv`, `color`, etc.)
- An optional `index` BufferAttribute (if absent, rendering is non-indexed)
- A `groups` array for multi-material sub-meshes

The `Mesh` scene object is the rendering composite; `BufferGeometry` is the geometry composite. In a node graph context, what passes between nodes is equivalent to `BufferGeometry` — geometry without material or transform.

### glTF 2.0 mesh primitive

The industry-standard interchange format defines the grouping clearly. A `mesh.primitive` object carries:

- `attributes`: a map of accessor references by name (`POSITION`, `NORMAL`, `TEXCOORD_0`, etc.)
- `indices`: optional accessor reference (if absent, non-indexed rendering)
- `mode`: topology (0 = points, 4 = triangles, etc.)
- `material`: optional material reference

glTF's primitive is the "unit of draw." It groups everything the GPU needs for one draw call: vertex data + optional index data + topology + material. Material is included because glTF describes assets, not just buffers. For a runtime graph system, you'd likely separate material from geometry — but the vertex+index+topology grouping is consistent with every other system surveyed.

### Unity Mesh

Unity's `Mesh` class is a composite with multiple sub-meshes. Each sub-mesh has its own index buffer and can have its own topology — so a single `Mesh` can contain triangle primitives and line primitives simultaneously. The top-level `Mesh` holds shared vertex arrays (positions, normals, tangents, UVs, colors, skin weights), and per-sub-mesh index arrays and topology settings.

For CME's v1 purposes, the multi-sub-mesh complexity is out of scope, but the lesson is: topology is per-primitive, not per-mesh-system.

### Summary of what a composite mesh handle should carry

Across all surveyed systems, the consistent minimum for a GPU-drawable composite is:

| Field | Always present | Notes |
|-------|---------------|-------|
| Vertex buffer reference | Yes | May be suballocated range in megabuffer |
| Vertex count | Yes | Needed for non-indexed draws |
| Index buffer reference | Optional | Absent for non-indexed meshes |
| Index count | If indexed | Needed for `draw_indexed` |
| Index format (u16/u32) | If indexed | wgpu requires this at bind time |
| Primitive topology | Yes | Triangle list, strip, line list, points |
| Vertex attribute layout | Recommended | Enables pipeline compatibility checks |

What is **not** in the geometric composite: material, transform, LOD, instance data. Those belong to higher-level abstractions (draw call, scene node, etc.).

---

## The Composite-vs-Discrete Spectrum

Let's be precise about what "composite" and "discrete" mean in the context of CME's value graph.

**Discrete (current CME approach):** Three separate graph ports carry three separate values: `vertex_buffer: BufferHandle`, `index_buffer: BufferHandle`, `index_count: Int`. Each is an independent `Value` variant. Three wires leave the "mesh producer" node; three wires enter `DrawIndexedOp`.

**Composite:** One port carries one `Value::Mesh(ResourceId)` where the ResourceId resolves (via `GpuResourceMap::get_mesh`) to a `MeshData` struct containing all three fields above, plus topology and vertex count.

There's a useful spectrum in between:

```
Fully discrete         Geometry composite      Full scene object
(3 separate wires)     (vertex+index+topology  (Mesh + Material +
                        as one Value::Mesh)      Transform)

wgpu RenderPass        Bevy GpuMesh             Three.js Mesh
                        rend3 MeshHandle         Unity Mesh (scene graph)
                        glTF primitive
```

CME's question is whether to stay at the left end or move to the middle. The fully-composite scene object (right end) is clearly out of scope for a GPU-operator graph where materials are separate operator outputs.

---

## Graph Wiring Implications

You might wonder: does the graph representation choice even matter? After all, `DrawIndexedOp` works today. Here are the forces that push toward consolidation.

### Force 1: Upstream mesh producers need to emit something

When `LoadMeshOp` arrives (loading a `.obj`, `.glb`, or procedurally generated mesh), it must emit a value. What type?

- **Discrete approach:** `LoadMeshOp` has three output ports: `vertex_buffer`, `index_buffer`, `index_count`. Three wires leave the node. The user must wire all three to `DrawIndexedOp`'s three corresponding inputs.
- **Composite approach:** `LoadMeshOp` has one output port: `mesh: Mesh`. One wire. `DrawIndexedOp` accepts `mesh: Mesh` and unpacks internally.

The discrete approach is wiring noise. Every mesh producer → draw call path requires three wires and forces the user to understand the GPU-level decomposition. The composite approach models the mental model correctly: "this is a mesh, use it."

### Force 2: Mesh modifier operators

Consider a future `TransformMeshOp` that applies a transformation matrix to vertex positions, or a `SubdivideMeshOp`. With discrete values:

- `TransformMeshOp` must accept three inputs and emit three outputs.
- Every intermediate mesh op doubles the wire count.

With a composite handle, each modifier accepts one `mesh` input and emits one `mesh` output — exactly the pattern that every surveyed visual programming system uses.

TouchDesigner's SOP family is the canonical example: every SOP produces exactly one geometry output, one wire. Add a Subdivide SOP, a Transform SOP, a Boolean SOP — each is a chain of single wires. This is not accidental; it reflects that mesh geometry is naturally a unit.

Blender's Geometry Nodes arrived at the same answer independently. The `Geometry` socket is a single wire that carries the entire geometry (which may contain mesh, curves, point clouds, volumes simultaneously). The Blender design notes explicitly state that nodes operating on multiple geometry types (like Transform) would need to exist multiple times or have dynamic inputs if separate sockets were used.

Houdini SOPs work identically: one geometry wire between nodes, which carries all attributes (point, vertex, primitive, detail) as a single entity.

### Force 3: The type system expresses intent

With `Value::Mesh(ResourceId)`, the type system says "this wire carries a mesh." With `Value::BufferHandle(ResourceId)`, it says "this wire carries a generic GPU buffer." The user (and the editor UI) cannot tell from the type alone whether a buffer is a vertex buffer, index buffer, or something else.

The four node graph frameworks in [`node-graph-architecture.md`](../../node-graphs/node-graph-architecture.md) uniformly use the type system to distinguish values: cables.gl has color-coded port types; vvvv gamma has type-colored links with compile-time checking; tixl uses C# generics (`Slot<Mesh>` vs `Slot<Buffer>`). All frameworks agree that a wire should have a semantic type, not just "bytes."

### Force 4: The topology problem

`DrawIndexedOp` today hardcodes `IndexFormat::Uint32` (from the source). When `LoadMeshOp` loads a model with 16-bit indices, either:
- The load op must convert to u32 (wasteful)
- Or index format must flow as a separate `Int` port (more wire noise)

With a composite `MeshHandle`, the index format is a field: the loader stores `IndexFormat::Uint16` or `Uint32` in the mesh resource, and `DrawIndexedOp` reads it when building `RenderCommand::SetIndexBuffer { format, ... }`. No extra wire.

---

## The Indexed-vs-Non-Indexed Shape Decision

This is the trickiest subproblem. Bevy's answer — a `GpuBufferInfo` enum with `Indexed` and `NonIndexed` variants — is directly applicable.

**Option A: `Value::Mesh` always means indexed.** Non-indexed geometry uses a separate type or is not supported.

- Pro: Simple. `DrawIndexedOp` always emits `draw_indexed`. No branching on mesh type.
- Con: Forces unnecessary indexing for procedurally generated non-indexed meshes. Loses future flexibility.

**Option B: `Value::Mesh` is either indexed or non-indexed.** The `MeshHandle` struct carries an enum distinguishing the two cases.

```rust
pub struct MeshHandle {
    pub vertex_buffer: BufferId,
    pub vertex_count: u32,
    pub topology: wgpu::PrimitiveTopology,
    pub layout: VertexBufferLayout,    // or VertexFormat enum
    pub index_info: MeshIndexInfo,
}

pub enum MeshIndexInfo {
    NonIndexed,
    Indexed {
        index_buffer: BufferId,
        index_count: u32,
        index_format: IndexFormat,
    },
}
```

`DrawIndexedOp` checks `mesh.index_info` to decide whether to emit `DrawIndexed` or `Draw`. This is more code but correctly models the design space.

- Pro: Mirrors the standard (Bevy, glTF, wgpu's own `draw` vs `draw_indexed`).
- Pro: Future mesh generators (point clouds, line meshes) are non-indexed by nature.
- Con: Operator implementations must handle two cases.

**Recommendation:** Option B. The extra complexity is localized to one field check in `DrawIndexedOp` (or a future `DrawMeshOp`). Getting this right now prevents an awkward "non-indexed mesh" gap later.

---

## Tradeoffs: Full Comparison

| Dimension | Discrete (3 wires) | Composite (Value::Mesh) |
|-----------|-------------------|------------------------|
| DrawIndexedOp today | Already works | Requires refactor |
| LoadMeshOp wiring | 3 output ports | 1 output port |
| Mesh modifier chains | Wire count × ops | 1 wire per hop |
| Type expressiveness | "BufferHandle" (generic) | "Mesh" (semantic) |
| Index format | Hardcoded or extra port | Field in MeshHandle |
| Topology | Hardcoded or extra port | Field in MeshHandle |
| Non-indexed support | Not natural | Clean via enum |
| GpuResourceMap surface | register_buffer × 2 | register_mesh × 1 |
| Indirection cost | 2 map lookups | 1 map lookup (composite) |
| Implementation risk | None (status quo) | One-time refactor |
| Alignment with industry | Uncommon above GPU layer | Universal (Bevy, TD, Blender, glTF, Unity, Three.js) |

The discrete approach has one genuine advantage: it works right now, with no refactoring. Every other dimension favors the composite.

The indirection cost deserves honest attention: `GpuResourceMap::get_mesh(rid)` returns a `MeshHandle` struct, which then has two more handle lookups (`get_buffer` for vertex, `get_buffer` for index). This is one extra indirection layer vs the current approach. For a creative coding workload with dozens of meshes, this overhead is irrelevant. At rend3-scale (thousands of meshes per frame), you'd want the megabuffer suballocation pattern anyway, which changes the math entirely. This is not a concern for CME's current scale or its near-term production target.

---

## Recommendation for the CME/flux Mesh Resource Model

### Short answer

**Consolidate: activate `Value::Mesh(ResourceId)` as a composite handle backed by a `MeshHandle` struct registered in `GpuResourceMap`.**

The discrete approach is a temporary convenience of the pre-`LoadMeshOp` era. Once any operator needs to produce a mesh (whether from a file, procedural generation, or a modifier), the composite is the only design that produces sane graph wiring.

### What `MeshHandle` should carry

```rust
/// Physical GPU mesh resource, resolved from Value::Mesh(ResourceId) via GpuResourceMap.
pub struct MeshHandle {
    /// Interleaved vertex attribute data.
    pub vertex_buffer: BufferId,
    /// Number of vertices (needed for non-indexed draws).
    pub vertex_count: u32,
    /// Primitive topology — per-mesh, not per-system.
    pub topology: wgpu::PrimitiveTopology,
    /// Index buffer and related metadata, or NonIndexed.
    pub index_info: MeshIndexInfo,
}

pub enum MeshIndexInfo {
    NonIndexed,
    Indexed {
        index_buffer: BufferId,
        index_count: u32,
        index_format: IndexFormat,  // Uint16 or Uint32
    },
}
```

The vertex attribute layout (`VertexBufferLayout`) is a natural addition when `CreateRenderPipelineOp` needs to validate layout compatibility, but it can be deferred to the pipeline-reflection phase. For v1 it is optional.

### `GpuResourceMap` API additions

Following the existing pattern in `resource_map.rs` (every resource type gets `register_X(handle) -> ResourceId` and `get_X(rid) -> Option<X>`):

```rust
// In GpuResourceMap:
pub fn register_mesh(&mut self, mesh: MeshHandle) -> ResourceId
pub fn get_mesh(&self, rid: ResourceId) -> Option<&MeshHandle>
```

The `MeshHandle` is stored by value in the map (it's just two `BufferId`s plus a few scalars — no heap allocation). `get_mesh` returns `Option<&MeshHandle>` rather than a copied struct because callers need to read multiple fields.

### Migration path for `DrawIndexedOp`

The existing three-port approach continues to work for graphs that assemble mesh data from raw buffers (e.g., compute shaders writing vertex data directly). The migration has two stages:

**Stage 1 (add, don't break):** Keep the existing `vertex_buffer` / `index_buffer` / `index_count` ports. Add an optional `mesh` port (`Value::Mesh`, default `ResourceId::NONE`). In `prepare()`, check `mesh` first; if present, unpack from `GpuResourceMap::get_mesh()`; otherwise fall back to discrete ports. This is backward-compatible — existing graphs keep working, new graphs wire one port.

**Stage 2 (clean up, when convenient):** Once no graphs use the discrete ports, remove them. Or keep them as an override / low-level escape hatch. In a pre-production codebase, Stage 2 can happen immediately with Stage 1 (just replace).

Given CME's "Replace, Don't Wrap" principle from the architecture guidelines, Stage 2 should happen at the same time as Stage 1, unless there are existing test graphs that need a transition window. There are currently no graphs that use the discrete ports in production — `DrawIndexedOp` was implemented but not yet wired into a graph beyond test fixtures.

### What to do about `Value::Mesh(ResourceId)` today

It exists as a type tag with no backing implementation. The activation path is:

1. Add `MeshHandle` and `MeshIndexInfo` to `flux-gpu-operators` (alongside `ReflectedShader`, in a new `mesh.rs` module).
2. Add `meshes: HashMap<ResourceId, MeshHandle>` to `GpuResourceMap`, with `register_mesh` / `get_mesh`.
3. Refactor `DrawIndexedOp` to accept `mesh: Value::Mesh` (removing or demoting the discrete ports).
4. Implement `LoadMeshOp` with a single `mesh: Value::Mesh` output — this is the operator that makes the composite pay off.

Steps 1–3 are a contained refactor. Step 4 is future work. The key insight is that steps 1–3 should happen *before* step 4, not after, so that `LoadMeshOp` has a clean port type from the start.

---

## References

- [`handle-designs.md`](handle-designs.md) — Arc vs index handle patterns; the principle "match handle complexity to resource volume" applies here (meshes are moderate-count resources → generation-indexed pool is appropriate)
- [`arc-vs-index-handles.md`](arc-vs-index-handles.md) — When to switch from Arc to indices; mesh data is in the "hundreds to low thousands" range where either works, but index handles are already established in `GpuResourceMap`
- [`resource-pool-design.md`](resource-pool-design.md) — Pool structure; a future `MeshPool` that owns `wgpu::Buffer` allocations behind `BufferId` handles follows the same deferred-operations pattern
- [`per-framework/rend3.md`](per-framework/rend3.md) — Megabuffer mesh management; the `STARTING_MESH_DATA = 32MB` constant cited there is a useful reference for production-scale mesh budget
- [`../../node-graphs/node-graph-architecture.md`](../../node-graphs/node-graph-architecture.md) — The four graph frameworks all use single-typed wires for composite values; tixl's `Slot<T>` generic is the closest analogue to CME's `Value::Mesh` typed port
- [`../../node-graphs/node-graph-rendering.md`](../../node-graphs/node-graph-rendering.md) — Werkkzeug4's reference stealing and tixl's Command abstraction both assume mesh data flows as a single handle between operators
- Bevy `GpuMesh` / `MeshAllocator` — `GpuBufferInfo` enum for indexed vs non-indexed is directly applicable to `MeshIndexInfo`
- rend3 `Mesh` struct — Structure-of-arrays format; confirms that vertex attributes and indices are logically separate inside the struct but exposed as a single handle externally
- Three.js `BufferGeometry` — Named attribute map + optional index; the "optional index = optional indexed rendering" pattern is universal
- glTF 2.0 mesh primitive schema — `indices` is optional; `mode` (topology) is per-primitive; the primitive is the atomic draw unit
- Unity `Mesh` — Sub-mesh array with per-sub-mesh topology; the multi-sub-mesh design is future-scope for CME but topology-per-draw-primitive is the right abstraction level
- Blender Geometry Nodes `GeometrySet` — Single socket for composite geometry; Blender design notes confirm that separate sockets per geometry component would require duplication of generic nodes
- TouchDesigner SOPs — Each SOP operator family outputs a single typed geometry wire; mesh data is never split across multiple concurrent wires in the SOP network
