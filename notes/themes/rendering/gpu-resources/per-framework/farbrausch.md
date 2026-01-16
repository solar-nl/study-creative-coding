# Farbrausch: Demoscene Efficiency at 64 Kilobytes

> What happens when your entire executable—code, textures, meshes, music—must fit in 64KB?

---

## The Demoscene Constraint

Farbrausch created some of the most visually stunning demoscene productions in history. Their tools—Werkkzeug and later the Altona framework—pushed the boundaries of what was possible within brutal size constraints. A 64KB intro must generate all its content procedurally: textures from noise and gradients, meshes from mathematical functions, music from synthesis. Nothing is loaded; everything is computed.

This constraint demanded extreme efficiency. Every GPU resource pattern serves a purpose. No memory is wasted on redundancy. The result is a codebase that represents decades of optimization wisdom, distilled into patterns that remain relevant today.

The question guiding this exploration: *how did Farbrausch manage GPU resources under extreme constraints, and what can modern frameworks learn from their solutions?*

---

## Buffer Pooling: The GeoBuffer System

Farbrausch's Altona framework pools geometry buffers into large blocks:

```cpp
class sGeoBufferManager
{
  sDList2<sGeoBuffer11> Free;
  sDList2<sGeoBuffer11> Used;
  sGeoBuffer11 *Current;
  sInt BlockSize;

public:
  void Map(sGeoMapHandle &hnd, sDInt bytes);
  void Unmap(sGeoMapHandle &hnd);
  void Flush();
};
```

The manager maintains two lists: free buffers and used buffers. When you need geometry data uploaded, you request a region from the current buffer. If it fits, you get a pointer and an offset. If not, the system allocates a new block.

The block size is substantial—typically 2MB:

```cpp
class sGeoBuffer11
{
  struct ID3D11Buffer *DXBuffer;
  sDInt Alloc;   // Total allocated
  sDInt Used;    // Currently used
  sDInt Free;    // Remaining space

  sU8 *MapPtr;   // Mapped memory for writes
};
```

This pooling eliminates the overhead of creating individual buffers. A demo might render thousands of objects, each with its own geometry. Creating a D3D buffer for each would overwhelm the driver. Instead, all geometry lives in a handful of large buffers, suballocated efficiently.

The pattern extends to constant buffers with size-based binning:

```cpp
enum sCBufferManagerConsts
{
  sCBM_BinSize = 64,   // Each bin = 64 bytes (4 float4 registers)
  sCBM_BinCount = 32,  // 32 bins, up to 2KB
};

class sCBufferManager
{
  sDList2<sCBuffer11> Bins[sCBM_BinCount];  // Size classes
  sDList2<sCBuffer11> Mapped;
  sDList2<sCBuffer11> Used;
};
```

Constant buffers are binned by size. A 128-byte buffer goes in bin 2 (128/64). When you need a buffer, the manager checks the appropriate bin first. No fragmentation, no searching—just grab from the right bin.

---

## Mesh Charging: On-Demand GPU Upload

Farbrausch coined the term "charging" for on-demand GPU resource preparation. A mesh exists initially only as CPU data. When it's actually needed for rendering, it "charges"—uploads to GPU and optionally discards the CPU copy:

```cpp
// Calling this tells the system you only need vertex/index buffers,
// and don't need the fat vertices anymore.
// Please call when holding only ONE reference!

void Wz4Mesh::Charge()
{
  if(Doc->IsPlayer)
  {
    ChargeCount++;
    ChargeBBox();
    ChargeSolid(sRF_TARGET_ZONLY);
    ChargeSolid(sRF_TARGET_MAIN);

    // If this is the last reference, delete CPU data
    if(RefCount - ChargeCount == 1 && DontClearVertices == 0)
    {
      Vertices.Reset();
      Faces.Reset();
    }
  }
}
```

The pattern is elegant in its simplicity. `ChargeCount` tracks how many times the mesh has been charged. `RefCount` tracks total references. When charging equals references minus one (the one being the mesh itself), the CPU data has served its purpose—every user has their GPU copy—and can be freed.

This matters enormously for 64KB demos. Procedurally generated meshes might create complex geometry during loading. Once uploaded to GPU, that CPU data is dead weight. Charging frees it, keeping memory tight.

The charging happens lazily, during first render:

```cpp
void Wz4Mesh::Render(sInt flags, sInt index, const sMatrix34CM *mat,
                      sF32 time, const sFrustum &fr)
{
  switch(flags & sRF_TARGET_MASK)
  {
  case sRF_TARGET_MAIN:
    ChargeSolid(flags);  // Ensure GPU data exists
    // ... render ...
  }
}
```

If the GPU data doesn't exist, `ChargeSolid` creates it. If it does, the call is cheap. Lazy loading defers work until it's actually needed, avoiding upload of content that might never appear on screen.

---

## Render Phases: Prepare Then Render

Farbrausch separates rendering into distinct phases, each with its own traversal of the scene graph:

```cpp
class Wz4RenderNode : public Wz4BaseNode
{
public:
  virtual void Simulate(Wz4RenderContext *ctx);  // Animation, physics
  virtual void Transform(Wz4RenderContext *ctx, const sMatrix34 &);  // Build matrices
  virtual void Prepare(Wz4RenderContext *ctx);   // Upload to GPU
  virtual void Render(Wz4RenderContext *ctx);    // Issue draw calls

  void ClearRecFlagsR();      // Reset traversal flags
  void SimulateChilds(...);   // Recurse to children
  void TransformChilds(...);
  void PrepareChilds(...);
  void RenderChilds(...);
};
```

The phases are:

1. **ClearRecFlags**: Reset traversal markers to prevent double processing
2. **Simulate**: Update animation, physics, procedural content
3. **Transform**: Build model matrices, handle instancing
4. **Prepare**: Upload changed data to GPU, sort for rendering
5. **Render**: Issue draw calls with current GPU state

This separation enables batching. The Prepare phase can sort objects by material, merge compatible draws, and upload all data before any rendering begins. The Render phase then executes without GPU stalls—data is already resident.

```cpp
void Wz4RenderContext::RenderControl(Wz4RenderNode *root, sInt clearflags,
                                       sU32 clrcol, const sTargetSpec &spec)
{
  ClearRecFlags(root);      // Phase 0: reset
  root->Simulate(this);     // Phase 1: animation
  // ... transform phase ...
  root->Prepare(this);      // Phase 3: upload
  root->Render(this);       // Phase 4: draw
}
```

RecFlags prevent double traversal in graphs with shared nodes. If a node has already been processed this frame, it skips the work. This handles diamond dependencies in the scene graph efficiently.

---

## Procedural Textures: Operators as Graph Nodes

Werkkzeug represents textures as operator graphs. Each operator—Perlin noise, blur, color adjustment—is a node that computes pixels:

```cpp
class GenBitmap : public KObject
{
public:
  sU64 *Data;      // RGBA pixels (16-bit per channel)
  sInt XSize;
  sInt YSize;
  sInt Size;       // XSize * YSize, avoids multiplication
  sInt Texture;    // GPU handle once uploaded
};

GenBitmap * __stdcall Bitmap_Perlin(
  sInt xs, sInt ys,    // Dimensions
  sInt freq,           // Base frequency
  sInt oct,            // Octave count
  sF32 fadeoff,        // Octave falloff
  sInt seed,           // Random seed
  sInt mode,           // Algorithm variant
  sF32 amp, sF32 gamma,
  sU32 col0, sU32 col1 // Gradient colors
);
```

Each operator function takes inputs (other bitmaps, parameters) and produces a new bitmap. The graph is evaluated lazily; final textures are computed only when needed, then uploaded and cached.

The CPU bitmap data lives only during generation. Once `MakeTexture()` uploads to GPU, the CPU data can be freed—another application of the charging pattern.

This operator approach was revolutionary for its time. Today we recognize it as a data flow graph, the same pattern that drives node-based tools like Houdini, Substance Designer, and visual programming environments.

---

## The Werkkzeug 3 Buffer System

The earlier Werkkzeug 3 used a similar but more explicit buffer system:

```cpp
void sSystem_::CreateGeoBuffer(sInt i, sInt dyn, sInt index, sInt size)
{
  sInt usage = D3DUSAGE_WRITEONLY;
  D3DPOOL pool = D3DPOOL_MANAGED;

  if(dyn)
  {
    usage |= D3DUSAGE_DYNAMIC;
    pool = D3DPOOL_DEFAULT;
  }

  GeoBuffer[i].Type = 1 + index;  // 1=vertex, 2=index16, 3=index32
  GeoBuffer[i].Size = size;
  GeoBuffer[i].Used = 0;
  GeoBuffer[i].UserCount = 0;
}
```

Buffers are classified by type (vertex or index) and dynamism. Dynamic buffers use `D3DPOOL_DEFAULT` for GPU-only storage with CPU write access via mapping. Static buffers use `D3DPOOL_MANAGED` for automatic driver management.

The system preallocates a fixed number of buffers at startup, each with a specific purpose. This avoids runtime allocation overhead—critical for 60fps demos where any hitch is visible.

---

## Reference Counting with Cleanup Awareness

Resources track references with awareness of cleanup state:

```cpp
class Wz4BaseNode
{
  sInt RefCount;
public:
  void AddRef()  { if(this) RefCount++; }
  void Release() { if(this) { if(--RefCount <= 0) delete this; } }
};
```

The `if(this)` check is defensive—calling methods on null pointers is undefined behavior in C++, but Werkkzeug operated in environments where robustness mattered more than strict compliance.

For meshes, the combination of RefCount and ChargeCount enables smart cleanup:

```cpp
if(RefCount - ChargeCount == 1 && DontClearVertices == 0)
{
  Vertices.Reset();  // Free CPU data
  Faces.Reset();
}
```

The mesh keeps GPU data alive but sheds CPU weight. This is particularly important for animated meshes that might share skeleton data but have unique vertex positions—the GPU data persists while CPU data is freed.

---

## Material Permutations

Farbrausch's material system handles shader variants efficiently:

```cpp
enum Wz4RenderFlags
{
  wRF_RenderWire    = 0x0001,  // Wireframe only
  wRF_RenderMain    = 0x0002,  // Main color pass
  wRF_RenderZ       = 0x0004,  // Z-only pass
  wRF_RenderZLowres = 0x0008,  // Lowres Z buffer
  wRF_RenderShadows = 0x0010,  // Shadow cubemap
};
```

Each render pass uses different flags, selecting appropriate shader variants. The material system compiles permutations for each combination, then caches them by flag set.

When rendering:

```cpp
void Wz4Mesh::Render(sInt flags, ...)
{
  switch(flags & sRF_TARGET_MASK)
  {
  case sRF_TARGET_WIRE:
    ChargeWire(Wz4MtrlType->GetDefaultFormat(flags | sRF_MATRIX_ONE));
    Wz4MtrlType->SetDefaultShader(flags | sRF_MATRIX_ONE, mat, ...);
    break;
  case sRF_TARGET_ZONLY:
    ChargeSolid(flags);
    // Z-only shader, cheaper than full material
    break;
  case sRF_TARGET_MAIN:
    ChargeSolid(flags);
    // Full material shader
    break;
  }
}
```

The flags determine which geometry variant to charge (wireframe vs solid) and which shader to bind. This keeps permutation explosion manageable while supporting varied render passes.

---

## Lessons for Flux

Farbrausch's patterns suggest several approaches:

**Megabuffer pooling works.** Large preallocated buffers with suballocation eliminate per-resource overhead. The size-binned constant buffer approach prevents fragmentation. This pattern scales better than individual allocations.

**Lazy upload with reference tracking.** The "charging" concept—upload on demand, free CPU data when no longer needed—fits creative coding workflows. Procedural content generates during design; final playback needs only GPU data.

**Phase separation enables batching.** Clear separation between simulation, preparation, and rendering allows the framework to optimize each phase independently. Uploads complete before draws begin; no mid-frame stalls.

**Operator graphs are timeless.** The node-based procedural texture system anticipated modern visual programming. Flux's node graph can learn from this heritage—graphs that compute resources, then cache and reuse results.

**Reference + charge counting for smart cleanup.** Tracking both total references and GPU-ready references enables intelligent memory management. Resources shed weight as they transition from creation to rendering.

**Flag-based permutation selection.** Rather than complex inheritance or runtime branching, simple flag combinations select shader variants. O(1) lookup, predictable behavior, easy debugging.

The demoscene constraint—64KB for everything—forced elegance. Every pattern serves a purpose. Modern frameworks have more memory, but the discipline of efficiency remains valuable. Flux can adopt these patterns not from necessity but from their proven effectiveness.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `altona/main/base/graphics_dx11_private.hpp` | 43-82 | sGeoBuffer11, sGeoBufferManager classes |
| `altona/main/base/graphics_dx11.cpp` | 78-79 | Manager initialization |
| `wz4/wz4frlib/wz4_mesh.cpp` | 4931-4948 | Mesh::Charge() pattern |
| `wz4/wz4frlib/wz4_demo2.hpp` | 96-130 | Wz4RenderNode phase methods |
| `werkkzeug3/_start.cpp` | 3592-3628 | CreateGeoBuffer in Wz3 |
| `werkkzeug3/genbitmap.hpp` | 30-53 | GenBitmap procedural texture class |

---

## Related Documents

- [rend3.md](rend3.md) — Similar megabuffer approach in modern Rust
- [../allocation-strategies.md](../allocation-strategies.md) — Allocation pattern catalog
- [../command-batching.md](../command-batching.md) — Phase separation comparison
- [tixl.md](tixl.md) — Modern node-based tool with operator graph heritage
