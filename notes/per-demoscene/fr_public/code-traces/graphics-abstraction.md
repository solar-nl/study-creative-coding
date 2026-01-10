# Code Trace: Geometry Draw Call Through Multi-Backend Abstraction

> Tracing the path of `sGeometry::Draw()` from user code to GPU API calls across DX9, DX11, and OpenGL backends.

---

## Overview

**Framework**: Altona (fr_public/altona_wz4)
**Operation**: How a geometry draw call reaches the GPU through the multi-backend abstraction
**Files Touched**: 8 core files
**Author**: Farbrausch (Dierk Ohlerich)

Altona is a demoscene framework created by Farbrausch, known for producing legendary demos like fr-08 (.the" .product). The graphics abstraction layer is a clean example of compile-time backend selection with minimal runtime overhead.

---

## The Problem: One Codebase, Multiple Graphics APIs

Imagine you're shipping demos on Windows XP (DirectX 9), Windows Vista+ (DirectX 11), and Linux (OpenGL). Each API has completely different:
- Buffer creation and management
- Shader compilation and binding
- Render state management
- Draw call syntax

The naive approach is ifdef-spaghetti throughout the codebase. Altona solves this elegantly with a compile-time abstraction that presents a unified API while generating backend-specific code.

---

## User Code

Here's how a developer uses Altona to render a cube:

```cpp
// From: altona_wz4/altona/examples/_graphics/cube/main.cpp:26-101

MyApp::MyApp()
{
  // Create geometry with triangle list and 16-bit indices
  Geo = new sGeometry(sGF_TRILIST|sGF_INDEX16, sVertexFormatStandard);

  // Load vertex data
  sVertexStandard *vp = 0;
  Geo->BeginLoadVB(24, sGD_STATIC, &vp);

  vp->Init(-1, 1,-1,  0, 0,-1, 1,0); vp++; // position, normal, uv
  vp->Init( 1, 1,-1,  0, 0,-1, 1,1); vp++;
  // ... 22 more vertices ...
  Geo->EndLoadVB();

  // Load index data
  sU16 *ip = 0;
  Geo->BeginLoadIB(6*6, sGD_STATIC, &ip);
  for(sInt i=0; i<6; i++)
    sQuad(ip, i*4, 0,1,2,3);  // Generate 2 triangles per quad face
  Geo->EndLoadIB();

  // Create material with shaders and render states
  Mtrl = new sSimpleMaterial;
  Mtrl->Flags = sMTRL_ZON | sMTRL_CULLON;
  Mtrl->Texture[0] = Tex;
  Mtrl->Prepare(sVertexFormatStandard);
}

void MyApp::OnPaint3D()
{
  sSetTarget(sTargetPara(sST_CLEARALL, 0xff405060));

  // Set material (binds shaders, textures, render states)
  sCBuffer<sSimpleMaterialEnvPara> cb;
  cb.Data->Set(View, Env);
  Mtrl->Set(&cb);

  // Draw geometry
  Geo->Draw();
}
```

**What happens**: The user creates geometry, loads vertex/index data, prepares a material, then calls `Draw()`. The framework handles all backend-specific details.

---

## Call Stack

### 1. Backend Selection (Compile-Time)

**File**: `altona_wz4/altona/main/base/types.hpp:48-208`

```cpp
// sRENDERER = one of

#define sRENDER_BLANK     0       // blank screen, no rendering
#define sRENDER_DX9       1       // dx9 rendering
#define sRENDER_OGL2      2       // opengl 2.0 rendering
#define sRENDER_DX11      3       // dx11 rendering (vista required)
#define sRENDER_OGLES2    10      // ios

// ... later in the file ...

#ifdef sCONFIG_RENDER_DX11
#undef sCONFIG_RENDER_DX11
#define sCONFIG_RENDER_DX11 1
#define sRENDERER sRENDER_DX11
#define sCONFIG_QUADRICS 0
#else
#define sCONFIG_RENDER_DX11 0
#endif
```

**What happens**: The `sRENDERER` macro is set at compile time based on which `sCONFIG_RENDER_*` is defined in `altona_config.hpp`. This single macro controls which backend implementation is compiled.

---

### 2. Private Implementation Includes

**File**: `altona_wz4/altona/main/base/graphics.hpp:72-102`

```cpp
// the new way to insert platform specific members

#if sRENDERER==sRENDER_DX11
  #include "graphics_dx11_private.hpp"
#elif sRENDERER==sRENDER_DX9
  #include "graphics_dx9_private.hpp"
#elif sRENDERER==sRENDER_OGLES2
  #include "graphics_ogles2_private.hpp"
#else                                 // dummies for platforms that use the old way

  enum
  {
    sMTRL_MAXTEX = 16,                                  // max number of textures
    sMTRL_MAXPSTEX = 16,                                // max number of pixel shader samplers
    sMTRL_MAXVSTEX = 0,
  };

  class sGeometryPrivate {};
  struct sVertexFormatHandlePrivate {};
  class sTextureBasePrivate {};
  // ... other empty private classes ...
#endif
```

**What happens**: Each backend provides a `*_private.hpp` file with backend-specific data members that get mixed into the public classes via inheritance.

---

### 3. sGeometry Class Definition

**File**: `altona_wz4/altona/main/base/graphics.hpp:1491-1595`

```cpp
class sGeometry : public sGeometryPrivate    // the geometry itself
{
private:
  friend class sGeometryPrivate;

#if sRENDERER==sRENDER_DX9 || sRENDERER==sRENDER_OGL2 || sRENDERER==sRENDER_BLANK
  sGeoBufferPart VertexPart[sVF_STREAMMAX];
  sGeoBufferPart IndexPart;
#endif

  sInt Flags;                     // flags at creation
  sInt IndexSize;                 // 2 or 4, derived from flags
  sBool PrimMode;                 // this buffer is loaded in prim mode (Quad/Grid)
  sVertexFormatHandle *Format;

public:
  sGeometry();
  sGeometry(sInt flags, sVertexFormatHandle *);

  void Init(sInt flags, sVertexFormatHandle *);
  void Draw();
  void Draw(const sGeometryDrawInfo &di);

  // Buffer loading
  void BeginLoadVB(sInt vc, sGeometryDuration duration, void **vp, sInt stream=0);
  void BeginLoadIB(sInt ic, sGeometryDuration duration, void **ip);
  void EndLoadVB(sInt vc=-1, sInt stream=0);
  void EndLoadIB(sInt ic=-1);
};
```

**What happens**: `sGeometry` inherits from `sGeometryPrivate`, which is defined differently per backend. The public API is the same across all backends.

---

### 4. DX11 Private Implementation

**File**: `altona_wz4/altona/main/base/graphics_dx11_private.hpp:84-111`

```cpp
class sGeometryPrivate
{
protected:
  struct Buffer
  {
    sInt ElementCount;
    sInt ElementSize;

    sGeoMapHandle DynMap;
    void *LoadBuffer;             // for static loading
    struct ID3D11Buffer *DXBuffer;

    struct ID3D11Buffer *GetBuffer()
    { return DynMap.Buffer ? DynMap.Buffer->DXBuffer : DXBuffer; }

    sDInt GetOffset()
    { return DynMap.Offset; }

    sBool IsEmpty()
    { return ElementCount==0; }
  };

  Buffer VB[4];                   // Up to 4 vertex streams
  Buffer IB;                      // Index buffer
  sInt DXIndexFormat;             // DXGI_FORMAT_R16_UINT or R32
  sInt Topology;                  // D3D11_PRIMITIVE_TOPOLOGY_*
  sInt Mapped;
};
```

**What happens**: DX11's private implementation stores D3D11 buffer pointers and handles dynamic buffer mapping through a buffer manager.

---

### 5. Material::Set() - Binding Shaders and State

**File**: `altona_wz4/altona/main/base/graphics_dx11.cpp:3458-3519`

```cpp
void sMaterial::Set(sCBufferBase **cbuffers, sInt cbcount, sInt variant)
{
  SetStates(variant);
  GTC->DXCtx->VSSetShader(VertexShader->vs, 0, 0);
  GTC->DXCtx->DSSetShader(DomainShader ? DomainShader->ds : 0, 0, 0);
  GTC->DXCtx->HSSetShader(HullShader ? HullShader->hs : 0, 0, 0);
  GTC->DXCtx->GSSetShader(GeometryShader ? GeometryShader->gs : 0, 0, 0);
  GTC->DXCtx->PSSetShader(PixelShader->ps, 0, 0);
  sSetCBuffers(cbuffers, cbcount);
}

void sMaterial::SetStates(sInt var)
{
  sVERIFY(var >= 0 && var < StateVariants);

  // Set blend, depth, and raster states
  GTC->DXCtx->OMSetBlendState(Variants[var].BlendState,
                              &Variants[var].BlendFactor.x, 0xffffffff);
  GTC->DXCtx->OMSetDepthStencilState(Variants[var].DepthState,
                                      Variants[var].StencilRef);
  GTC->DXCtx->RSSetState(Variants[var].RasterState);

  // Bind textures and samplers
  ID3D11ShaderResourceView *tps[sMTRL_MAXPSTEX];
  ID3D11SamplerState *sps[sMTRL_MAXPSTEX];
  // ... populate arrays from Texture[] ...

  GTC->DXCtx->PSSetShaderResources(0, sMTRL_MAXPSTEX, tps);
  GTC->DXCtx->PSSetSamplers(0, sMTRL_MAXPSTEX, sps);
}
```

**What happens**: Before drawing, `Material::Set()` binds all shaders (vertex, pixel, geometry, hull, domain), sets render states via pre-compiled state objects, and binds textures to shader stages.

---

### 6. sGeometry::Draw() - DX11 Implementation

**File**: `altona_wz4/altona/main/base/graphics_dx11.cpp:2299-2430`

```cpp
void sGeometry::Draw()
{
  Draw(sGeometryDrawInfo());
}

void sGeometry::Draw(const sGeometryDrawInfo &di)
{
  ID3D11Buffer *buffer[sVF_STREAMMAX];
  UINT byteoffset[sVF_STREAMMAX];
  UINT strides[sVF_STREAMMAX];

  ID3D11DeviceContext *DXCtx = GTC->DXCtx;

  // Prepare vertex buffer bindings
  for(sInt i=0; i<sVF_STREAMMAX; i++)
  {
    buffer[i] = VB[i].GetBuffer();
    strides[i] = VB[i].ElementSize;
    byteoffset[i] = di.VertexOffset[i] * VB[i].ElementSize;
    byteoffset[i] += UINT(VB[i].GetOffset());
  }

  // Bind vertex buffers, topology, and input layout
  DXCtx->IASetVertexBuffers(0, sVF_STREAMMAX, buffer, strides, byteoffset);
  DXCtx->IASetPrimitiveTopology((D3D11_PRIMITIVE_TOPOLOGY)Topology);
  DXCtx->IASetInputLayout(Format->Layout);

  // Handle indexed vs non-indexed drawing
  if(IndexSize)
  {
    DXCtx->IASetIndexBuffer(IB.GetBuffer(), (DXGI_FORMAT)DXIndexFormat, IB.GetOffset());

    for(sInt i=0; i<irc; i++)
    {
      if(di.Indirect)
        DXCtx->DrawIndexedInstancedIndirect(di.Indirect->DXBuffer, 0);
      else if(instancecount > 0)
        DXCtx->DrawIndexedInstanced(ir[i].End - ir[i].Start, instancecount,
                                    ir[i].Start, 0, 0);
      else
        DXCtx->DrawIndexed(ir[i].End - ir[i].Start, ir[i].Start, 0);
    }
  }
  else
  {
    for(sInt i=0; i<irc; i++)
    {
      if(instancecount > 0)
        DXCtx->DrawInstanced(ir[i].End - ir[i].Start, instancecount, ir[i].Start, 0);
      else
        DXCtx->Draw(ir[i].End - ir[i].Start, ir[i].Start);
    }
  }
}
```

**What happens**: The DX11 backend sets up the Input Assembler stage (vertex buffers, index buffer, primitive topology, input layout), then issues the appropriate draw call variant (indexed, instanced, indirect, or simple).

---

### 7. sGeometry::Draw() - OpenGL 2 Implementation

**File**: `altona_wz4/altona/main/base/graphics_ogl2.cpp:325-410`

```cpp
void sGeometry::Draw(sDrawRange *ir, sInt irc, sInt instancecount, sVertexOffset *off)
{
  sVertexFormatHandle::OGLDecl *decl = Format->GetDecl();
  sInt stride = 0;
  sInt start = 0;
  sInt disablemask = 0;

  glEnableClientState(GL_VERTEX_ARRAY);

  // Set up vertex attributes from vertex format declaration
  while(decl->Mode != 0)
  {
    if(decl->Mode == 2)  // Stream switch
    {
      stride = Format->GetSize(decl->Index);
      start = VertexPart[decl->Index].Start;
      glBindBufferARB(GL_ARRAY_BUFFER_ARB, VertexPart[decl->Index].Buffer->GLName);
    }
    else  // Attribute binding
    {
      glVertexAttribPointerARB(
        decl->Index, decl->Size, decl->Type, decl->Normalized,
        stride, (const void *)(sDInt)(decl->Offset + start));
      glEnableVertexAttribArrayARB(decl->Index);
      disablemask |= (1 << decl->Index);
    }
    decl++;
  }

  // Map primitive type
  sInt primtype = 0;
  switch(Flags & sGF_PRIMMASK)
  {
  case sGF_TRILIST:  primtype = GL_TRIANGLES; break;
  case sGF_TRISTRIP: primtype = GL_TRIANGLE_STRIP; break;
  case sGF_LINELIST: primtype = GL_LINES; break;
  case sGF_QUADLIST: primtype = GL_QUADS; break;
  }

  // Issue draw call
  if(IndexPart.Buffer)
  {
    glBindBufferARB(GL_ELEMENT_ARRAY_BUFFER_ARB, IndexPart.Buffer->GLName);
    const sInt type = (Flags & sGF_INDEX32) ? GL_UNSIGNED_INT : GL_UNSIGNED_SHORT;
    glDrawRangeElements(primtype, 0, VertexPart[0].Count-1, IndexPart.Count,
                        type, (void*)sDInt(IndexPart.Start));
  }
  else
  {
    glDrawArrays(primtype, 0, VertexPart[0].Count);
  }

  // Cleanup - disable vertex attributes
  for(sInt i=0; i<16; i++)
    if(disablemask & (1<<i))
      glDisableVertexAttribArrayARB(i);
}
```

**What happens**: The OpenGL backend walks the vertex format declaration to bind attributes, selects the GL primitive type, binds buffers, and issues `glDrawRangeElements` or `glDrawArrays`.

---

### 8. sGeometry::Draw() - DirectX 9 Implementation

**File**: `altona_wz4/altona/main/base/graphics_dx9.cpp:3383-3480`

```cpp
void sGeometry::Draw(const sGeometryDrawInfo &di)
{
  D3DPRIMITIVETYPE type;
  sInt primcount, vertcount;

  sGeoBufferUnlockAll();  // Ensure all dynamic buffers are unlocked

  // Set vertex streams
  for(sInt i=0; i<streamsused; i++)
  {
    DXDev->SetStreamSource(i, VertexPart[i].Buffer->VB,
                           VertexPart[i].Start, Format->GetSize(i));
  }

  // Set vertex declaration and indices
  DXDev->SetVertexDeclaration(Format->Decl);
  DXDev->SetIndices(IndexPart.Buffer->IB);

  // Map primitive type
  switch(Flags & sGF_PRIMMASK)
  {
  case sGF_TRILIST:  type = D3DPT_TRIANGLELIST;  break;
  case sGF_TRISTRIP: type = D3DPT_TRIANGLESTRIP; break;
  case sGF_LINELIST: type = D3DPT_LINELIST;      break;
  case sGF_QUADLIST: quads = 1;                   break;
  }

  // Issue draw call
  for(sInt i=0; i<irc; i++)
  {
    start = ir[i].Start;
    primcount = (ir[i].End - ir[i].Start) / primfact;
    vertcount = VertexPart[0].Count;

    DXErr(DXDev->DrawIndexedPrimitive(type, vertexoffset, 0, vertcount,
                                       start, primcount));
  }
}
```

**What happens**: DX9 uses the older API with `SetStreamSource`, `SetVertexDeclaration`, `SetIndices`, and `DrawIndexedPrimitive`.

---

## Data Flow Diagram

```
User Code: Geo->Draw()
    |
    v
+----------------------------------+
|  sGeometry::Draw()               |
|  Platform-independent entry      |
+----------------------------------+
    |
    | sRENDERER == ?
    |
    +-------------+-------------+----------------+
    |             |             |                |
    v             v             v                v
+--------+   +--------+   +---------+      +---------+
| DX11   |   | DX9    |   | OGL2    |      | Blank   |
+--------+   +--------+   +---------+      +---------+
    |             |             |                |
    v             v             v                v
+--------+   +--------+   +---------+      +---------+
|IASet*  |   |SetStrm |   |glBind*  |      | (noop)  |
|Draw*() |   |DrawIdx |   |glDraw*  |      |         |
+--------+   +--------+   +---------+      +---------+
    |             |             |
    v             v             v
+--------------------------------------------------+
|                    GPU                           |
+--------------------------------------------------+
```

---

## State Flow for Complete Draw

```
                   sSetTarget()
                        |
                        v
            +------------------------+
            |  Clear / Set RT        |
            +------------------------+
                        |
                        v
                   Material::Set()
                        |
        +---------------+---------------+
        |               |               |
        v               v               v
   +---------+    +----------+    +----------+
   | Shaders |    |  States  |    | Textures |
   +---------+    +----------+    +----------+
        |               |               |
        v               v               v
   VSSetShader    OMSetBlend*     PSSetShader
   PSSetShader    RSSetState      Resources
                  OMSetDepth
                        |
                        v
                Geometry::Draw()
                        |
        +---------------+---------------+
        |               |               |
        v               v               v
   +---------+    +----------+    +----------+
   |  VB/IB  |    | Topology |    |  Layout  |
   +---------+    +----------+    +----------+
        |               |               |
        v               v               v
   IASetVertex    IASetPrim     IASetInput
   IASetIndex     Topology      Layout
                        |
                        v
                   DrawIndexed()
                        |
                        v
                      GPU
```

---

## Key Observations

### 1. Compile-Time Backend Selection

Altona uses `#if sRENDERER==sRENDER_*` throughout the codebase to include different implementations. This means:
- Zero runtime overhead for backend dispatch
- Each binary targets exactly one graphics API
- Dead code elimination removes unused backends

This is different from runtime abstraction layers (like BGFX or Sokol) where a single binary can switch backends.

### 2. Inheritance-Based Private Data

The pattern of inheriting from `*Private` classes is elegant:

```cpp
class sGeometry : public sGeometryPrivate { ... }
```

Each backend defines `sGeometryPrivate` with its own data members. The public interface in `sGeometry` is the same across all backends, but the inherited private data differs.

### 3. Pre-Compiled State Objects (DX11)

DX11's material system pre-compiles state into D3D11 state objects during `Prepare()`:

```cpp
Variants[var].BlendState     // Pre-created ID3D11BlendState
Variants[var].DepthState     // Pre-created ID3D11DepthStencilState
Variants[var].RasterState    // Pre-created ID3D11RasterizerState
```

At draw time, it just binds these pre-created objects - no state validation needed.

### 4. Buffer Management Strategy

The framework has three buffer durations:
- `sGD_STATIC` - GPU-only, immutable after creation
- `sGD_FRAME` - Ring buffer, recycled each frame
- `sGD_STREAM` - Immediate upload, discarded after draw

This maps well to modern GPU best practices for buffer management.

### 5. Vertex Format Abstraction

The `sVertexFormatHandle` abstracts vertex layout:
- On DX11: Stores `ID3D11InputLayout*`
- On DX9: Stores `IDirect3DVertexDeclaration9*`
- On OGL: Stores an array of `OGLDecl` structs describing each attribute

### 6. Multi-Stream Vertex Support

Both APIs support up to 4 vertex streams (`sVF_STREAMMAX = 4`), allowing instanced data in separate buffers:

```cpp
Buffer VB[4];  // DX11
sGeoBufferPart VertexPart[sVF_STREAMMAX];  // DX9/OGL
```

---

## Implications for Rust Framework

### Adopt

1. **Compile-time backend selection via features**
   ```rust
   #[cfg(feature = "wgpu")]
   mod backend_wgpu;

   #[cfg(feature = "vulkan")]
   mod backend_vulkan;
   ```
   Cargo features map cleanly to Altona's `sCONFIG_RENDER_*` approach.

2. **Pre-compiled pipeline states**
   [wgpu](https://github.com/gfx-rs/wgpu) already requires this - render pipelines must be created ahead of time, not at draw time.

3. **Buffer duration hints**
   ```rust
   enum BufferUsage {
       Static,     // GPU-only, immutable
       Dynamic,    // CPU-writable, persists across frames
       Streaming,  // Single-frame use, ring-buffered
   }
   ```

4. **Vertex format handles**
   Create vertex layout descriptors once and reuse:
   ```rust
   let vertex_layout = VertexLayout::builder()
       .add(VertexAttribute::Position, Format::Float32x3)
       .add(VertexAttribute::Normal, Format::Float32x3)
       .add(VertexAttribute::TexCoord0, Format::Float32x2)
       .build(&device);
   ```

### Modify

1. **Trait-based abstraction instead of inheritance**
   Rust doesn't have inheritance. Use traits + associated types:
   ```rust
   trait Backend {
       type Buffer;
       type Pipeline;
       type BindGroup;

       fn create_buffer(&self, desc: &BufferDescriptor) -> Self::Buffer;
       fn draw(&self, geo: &Geometry<Self>);
   }
   ```

2. **Builder pattern for materials**
   Instead of mutable struct fields:
   ```rust
   let material = Material::builder()
       .shader(shader)
       .blend(BlendMode::Alpha)
       .depth_test(DepthTest::LessEqual)
       .cull(CullMode::Back)
       .texture(0, &diffuse_tex)
       .build(&device)?;
   ```

3. **Explicit lifetime management**
   Altona uses reference counting. Rust can use:
   - `Arc<T>` for shared ownership
   - Explicit lifetimes for borrow-based approaches
   - `Handle<T>` indices into a central resource pool

### Avoid

1. **Global mutable state**
   Altona has globals like `GTC` (graphics thread context), `DXDev`, etc. Prefer passing context explicitly or using a resource pool pattern.

2. **Void pointer buffer loading**
   Altona's `BeginLoadVB(count, duration, &void_ptr)` is unsafe. Use typed slices:
   ```rust
   fn load_vertices<V: Vertex>(&mut self, vertices: &[V]);
   ```

3. **Runtime variant selection**
   Altona's material variants are indexed by integer. Use an enum for type safety:
   ```rust
   enum RenderPass {
       Color,
       Shadow,
       ZPrepass,
   }
   material.set(pass: RenderPass);
   ```

---

## API Sketch

```rust
/// Geometry resource holding vertex and index buffers
pub struct Geometry {
    vertex_buffer: Buffer,
    index_buffer: Option<Buffer>,
    vertex_layout: VertexLayout,
    primitive_topology: PrimitiveTopology,
}

impl Geometry {
    /// Create geometry from vertex and index data
    pub fn new<V: Vertex>(
        device: &Device,
        vertices: &[V],
        indices: Option<&[u16]>,
    ) -> Self { ... }

    /// Load new vertex data into existing geometry
    pub fn update_vertices<V: Vertex>(&mut self, queue: &Queue, vertices: &[V]) { ... }
}

/// Material holding shaders, textures, and render state
pub struct Material {
    pipeline: RenderPipeline,
    bind_group: BindGroup,
}

impl Material {
    /// Bind material for rendering
    pub fn bind<'a>(&'a self, pass: &mut RenderPass<'a>) {
        pass.set_pipeline(&self.pipeline);
        pass.set_bind_group(0, &self.bind_group, &[]);
    }
}

/// Extension trait for drawing geometry
pub trait DrawGeometry<'a> {
    fn draw_geometry(&mut self, geometry: &'a Geometry);
    fn draw_geometry_instanced(&mut self, geometry: &'a Geometry, instances: Range<u32>);
}

impl<'a> DrawGeometry<'a> for RenderPass<'a> {
    fn draw_geometry(&mut self, geometry: &'a Geometry) {
        self.set_vertex_buffer(0, geometry.vertex_buffer.slice(..));
        if let Some(ib) = &geometry.index_buffer {
            self.set_index_buffer(ib.slice(..), wgpu::IndexFormat::Uint16);
            self.draw_indexed(0..geometry.index_count, 0, 0..1);
        } else {
            self.draw(0..geometry.vertex_count, 0..1);
        }
    }
}
```

---

## Comparison with [wgpu](https://github.com/gfx-rs/wgpu)

| Aspect | Altona | [wgpu](https://github.com/gfx-rs/wgpu) |
|--------|--------|------|
| Backend Selection | Compile-time (`#if`) | Runtime (adapter selection) |
| Pipeline State | Pre-compiled per material | Pre-compiled `RenderPipeline` |
| Buffer Types | Static/Frame/Stream | Static (copy) / Mapped (direct) |
| Vertex Format | `sVertexFormatHandle` | `VertexBufferLayout` |
| Draw Calls | `sGeometry::Draw()` | `RenderPass::draw*()` |
| Shader Binding | `Material::Set()` | `RenderPass::set_pipeline()` |
| Resource Binding | Implicit via Material | Explicit `BindGroup` |
| Multi-Threading | Thread-local context (GTC) | Command encoders |

Altona's abstraction is thinner than [wgpu](https://github.com/gfx-rs/wgpu)'s - it maps more directly to the underlying APIs. [wgpu](https://github.com/gfx-rs/wgpu) adds an additional abstraction layer that unifies Vulkan, Metal, DX12, and WebGPU behind a single API that can switch at runtime.

---

## References

- Source: `demoscene/fr_public/altona_wz4/altona/main/base/graphics.hpp`
- DX11 Backend: `demoscene/fr_public/altona_wz4/altona/main/base/graphics_dx11.cpp`
- DX9 Backend: `demoscene/fr_public/altona_wz4/altona/main/base/graphics_dx9.cpp`
- OGL2 Backend: `demoscene/fr_public/altona_wz4/altona/main/base/graphics_ogl2.cpp`
- Example: `demoscene/fr_public/altona_wz4/altona/examples/_graphics/cube/main.cpp`
