# apEx Material System

Materials in Phoenix are more than shader assignments—they're complete rendering recipes. A single material defines which shaders to use, what textures to bind, how to blend with the framebuffer, which render layer to target, and how parameters animate over time. This complexity arises from the 64k constraint: materials must be data-driven and compact, yet expressive enough for production-quality visuals.

The material system operates on three levels. At the base, `CphxMaterialParameter` structures define individual inputs—a float, a color, a texture reference. These parameters group into `CphxMaterialParameterBatch` containers for techniques and passes. At the top, `CphxMaterialTechnique` and `CphxMaterial` structures organize multi-pass rendering with layer targeting. Animation weaves through all levels via `CphxMaterialSpline` curves that modulate parameters over time.

Understanding materials requires thinking in passes. A chrome sphere might render in three passes: a base pass writing the G-Buffer, a reflection pass sampling an environment map, and an emission pass adding glow. Each pass has its own shader, blend state, and parameter values. The material system orchestrates this complexity while keeping the data representation compact enough for 64k executables.

## Material Parameter System

### Parameter Types

The `MATERIALPARAMTYPE` enum (Material.h:24) defines all possible parameter inputs. Each type maps to specific GPU resources or shader constants.

```cpp
enum MATERIALPARAMTYPE
{
    PARAM_FLOAT = 0,        // Single float constant
    PARAM_COLOR,            // RGBA color (4 floats)
    PARAM_ZMODE,            // Depth test mode
    PARAM_ZFUNCTION,        // Depth comparison function
    PARAM_FILLMODE,         // Solid/wireframe
    PARAM_CULLMODE,         // Front/back/none culling
    PARAM_RENDERPRIORITY,   // Draw order within layer
    PARAM_TEXTURE0,         // Texture slot 0 (albedo)
    PARAM_TEXTURE1,         // Texture slot 1 (normal)
    PARAM_TEXTURE2,         // Texture slot 2-7
    PARAM_TEXTURE3,
    PARAM_TEXTURE4,
    PARAM_TEXTURE5,
    PARAM_TEXTURE6,
    PARAM_TEXTURE7,
    PARAM_BLENDMODE0,       // Blend state for RT0
    PARAM_BLENDMODE1,       // Blend states for RT1-7
    // ...
    PARAM_RENDERTARGET,     // Target for post-process
    PARAM_PARTICLELIFEFLOAT,// Particle system lifetime
    PARAM_DEPTHTEXTURE7,    // Depth buffer as texture
    PARAM_3DTEXTURE6,       // 3D volume texture
    PARAM_MESHDATA0,        // Mesh attribute binding
    // ...
    PARAM_PARTICLELIFE,     // Particle lifetime curve
    PARAM_LTC1,             // LTC matrix lookup table
    PARAM_LTC2,             // LTC magnitude/Fresnel table
    PARAM_COUNT,
};
```

**Numeric parameters** (FLOAT, COLOR) pack into the object constant buffer for shader access. Floats occupy one slot; colors occupy four consecutive slots.

**Texture parameters** (TEXTURE0-7) bind shader resource views to texture slots. The binding happens during render instance execution, not during material definition. Textures can reference procedural render targets, imported images, or special resources like shadow maps.

**State parameters** (ZMODE, ZFUNCTION, FILLMODE, CULLMODE, BLENDMODE) configure the fixed-function pipeline. These compile into DirectX state objects (blend state, rasterizer state, depth-stencil state) at material creation time.

**Special parameters** (LTC1, LTC2, DEPTHTEXTURE7) bind engine-global resources. LTC textures are created once during engine initialization and shared across all materials needing area lights.

### Parameter Scope

The `MATERIALPARAMSCOPE` enum (Material.h:5) determines when parameters update.

```cpp
enum MATERIALPARAMSCOPE
{
    PARAM_CONSTANT = 0,   // Fixed at material creation
    PARAM_VARIABLE = 1,   // Can change per-instance
    PARAM_ANIMATED = 2,   // Driven by timeline splines
};
```

**CONSTANT** parameters bake into the material definition. A roughness value of 0.3 stays 0.3 for all instances. This is the most compact representation—no per-frame updates needed.

**VARIABLE** parameters can differ between material instances. Two meshes using the same material might have different tint colors. The value stores in per-instance material state rather than the material definition.

**ANIMATED** parameters connect to spline curves evaluated each frame. A pulsing glow effect animates emissive intensity from 0 to 1 over time. The timeline system evaluates splines and writes results to material state.

### Parameter Value Storage

The `MATERIALVALUE` union (Material.h:102) holds any parameter type's data.

```cpp
union MATERIALVALUE
{
    float Float;
    float Color[4];
    unsigned char ZMode;
    unsigned char BlendMode;
    D3D11_COMPARISON_FUNC ZFunction;
    bool Wireframe;
    D3D11_CULL_MODE CullMode;
    int RenderPriority;
    ID3D11ShaderResourceView *TextureView;
    CphxRenderTarget *RenderTarget;
};
```

The union approach saves memory—a parameter occupies only the space of its largest member. For a texture parameter, only the `TextureView` pointer matters. For a float, only the `Float` value matters. The `Type` field in `CphxMaterialParameter` determines which union member to access.

### Parameter Collection

`CphxMaterialParameterBatch` (Material.h:123) groups parameters for a technique or pass.

```cpp
struct CphxMaterialParameterBatch
{
    int ParamCount;
    CphxMaterialParameter **Parameters;
    float CollectedData[MATERIALDATASIZE / 4];

    int CollectAnimatedData();
};
```

The `CollectedData` array flattens numeric parameters into a contiguous buffer for GPU upload. `CollectAnimatedData()` walks the parameter list, copying FLOAT and COLOR values into this array. The result uploads to the object constant buffer alongside transformation matrices.

This collection step separates parameter definition from GPU binding. Parameters can be sparse and type-varied during authoring. At render time, only the numeric data matters—textures bind separately, states bind separately.

## Material Structure

### Render Passes

`CphxMaterialRenderPass` (Material.h:160) defines a single draw call's shader configuration.

```cpp
struct CphxMaterialRenderPass
{
    CphxMaterialParameterBatch Parameters;

    // Shader stages (order matters for memcpy!)
    ID3D11VertexShader *VS;
    ID3D11PixelShader *PS;
    ID3D11GeometryShader *GS;
    ID3D11HullShader *HS;
    ID3D11DomainShader *DS;

#ifdef _DEBUG
    char* shaderText;  // Source code for debugging
#endif
};
```

Each pass holds compiled shader handles for all five stages. Most materials only use VS and PS; geometry and tessellation shaders are NULL for standard rendering. The shader handles are raw DirectX pointers created during material compilation.

The comment about memcpy order is crucial. `CreateRenderDataInstances()` copies all five shader pointers in a single `memcpy()` call, relying on exact memory layout. Reordering these fields would break the copy.

### Techniques

`CphxMaterialTechnique` (Material.h:203) groups passes with shared state and layer targeting.

```cpp
struct CphxMaterialTechnique
{
    CphxMaterialParameterBatch Parameters;

    TECHNIQUETYPE Type;
    CphxRenderLayerDescriptor *TargetLayer;

    int PassCount;
    CphxMaterialRenderPass **RenderPasses;

    void CreateRenderDataInstances(...);
    void CollectAnimatedData(CphxMaterialPassConstantState *State, int Pass);
};
```

**Type** distinguishes material usage:
- `TECH_MATERIAL` — Standard mesh rendering
- `TECH_POSTPROCESS` — Full-screen post-processing
- `TECH_SHADERTOY` — Shadertoy-style procedural effects
- `TECH_PARTICLE` — Particle system rendering

**TargetLayer** specifies which render layer receives this technique's output. A G-Buffer technique targets the Solid Layer. A lighting technique targets the Lighting Layer. This decouples material definition from render pipeline orchestration.

**RenderPasses** contains the actual draw call configurations. Multiple passes enable effects like two-sided rendering (one pass for front faces, one for back) or multi-layer blending.

### Material Container

`CphxMaterial` (Material.h:221) is the top-level container.

```cpp
struct CphxMaterial
{
    int TechCount;
    CphxMaterialTechnique **Techniques;

    int PassCount;  // Calculated summary for minimal engine

    void CreateRenderDataInstances(CphxModelObject_Mesh *Model,
                                   CphxScene *RootScene,
                                   void *ToolData);
};
```

A material can have multiple techniques for different render contexts. A PBR material might have:
- Technique 0: Shadow pass (depth-only, targets Shadow Layer)
- Technique 1: G-Buffer pass (writes albedo/normal/roughness, targets Solid Layer)
- Technique 2: Transparency pass (forward rendering, targets Transparent Layer)

The scene traversal calls `CreateRenderDataInstances()` once per mesh. This iterates all techniques, creating render instances for each pass. The `PassCount` summary helps the minimal engine allocate instance storage.

## Blend Modes

Blend modes configure how fragment shader output combines with framebuffer contents. Phoenix uses a packed byte format for compact storage.

```cpp
#define phxSrcBlend_ZERO            0x00
#define phxSrcBlend_ONE             0x01
#define phxSrcBlend_SRCCOLOR        0x02
#define phxSrcBlend_INVSRCCOLOR     0x03
#define phxSrcBlend_SRCALPHA        0x04
#define phxSrcBlend_INVSRCALPHA     0x05
// ... more source factors

#define phxDstBlend_ZERO            0x00
#define phxDstBlend_ONE             0x10
#define phxDstBlend_SRCCOLOR        0x20
// ... more dest factors (upper nibble)
```

The lower nibble encodes source blend factor; the upper nibble encodes destination factor. This packs two factors into a single byte. Common modes:

| Mode | Value | Effect |
|------|-------|--------|
| Opaque | 0x01 | `ONE, ZERO` — Replace framebuffer |
| Alpha Blend | 0x54 | `SRCALPHA, INVSRCALPHA` — Standard transparency |
| Additive | 0x11 | `ONE, ONE` — Light accumulation |
| Multiplicative | 0x80 | `ZERO, SRCCOLOR` — Darken/multiply |

The blend mode converts to a `D3D11_BLEND_DESC` at material creation. Different render targets can have different blend modes using BLENDMODE0 through BLENDMODE7.

## Depth and Rasterizer State

Depth testing and rasterization configure via parameter types.

**ZMODE** controls depth buffer behavior:
- Write and test depth (standard opaque)
- Test only, no write (transparency)
- Disabled (post-processing, UI)

**ZFUNCTION** sets the comparison function:
```cpp
enum COMPARISONFUNCTION
{
    COMPARE_LESSEQUAL = 0,    // Standard depth test
    COMPARE_NEVER = 1,        // Always fail
    COMPARE_LESS = 2,         // Strict less-than
    COMPARE_EQUAL = 3,        // Exact match
    COMPARE_GREATER = 4,      // Reverse depth
    COMPARE_NOTEQUAL = 5,
    COMPARE_GREATEREQUAL = 6,
    COMPARE_ALWAYS = 7,       // Always pass
};
```

**CULLMODE** controls triangle culling:
- `D3D11_CULL_BACK` — Standard, cull back faces
- `D3D11_CULL_FRONT` — Render only back faces
- `D3D11_CULL_NONE` — Double-sided rendering

**FILLMODE** toggles wireframe:
- `D3D11_FILL_SOLID` — Normal rendering
- `D3D11_FILL_WIREFRAME` — Wireframe debug view

These settings compile into `D3D11_RASTERIZER_DESC` and `D3D11_DEPTH_STENCIL_DESC` state objects cached on the material. State objects are immutable after creation, avoiding per-frame state generation overhead.

## Material Animation

### Spline System

`CphxMaterialSpline` (Material.h:131) connects material parameters to timeline curves.

```cpp
struct CphxMaterialSpline
{
    CphxMaterialParameter *Target;
    void *GroupingData;
    class CphxSpline_float16 *Splines[4];

    MATERIALVALUE GetValue();
    void CalculateValue(float t);
};
```

**Target** points to the parameter being animated. A roughness animation targets the PARAM_FLOAT parameter for roughness.

**Splines[4]** holds up to four spline curves for multi-component values. A COLOR parameter needs four splines (R, G, B, A). A FLOAT parameter uses only Splines[0].

**GroupingData** distinguishes parameter instances. Multiple objects using the same material might have different animation curves. The grouping data (typically the mesh pointer) identifies which instance's curves to evaluate.

### Spline Batch

`CphxMaterialSplineBatch` (Material.h:140) manages all splines for a material instance.

```cpp
struct CphxMaterialSplineBatch
{
    int SplineCount;
    CphxMaterialSpline **Splines;

    void CalculateValues(float t);
    void ApplyToParameters(void *GroupingData);
};
```

During scene traversal, `CalculateValues(t)` evaluates all splines at the current timeline position. `ApplyToParameters()` writes the evaluated values back to the target parameters, but only for matching GroupingData. This ensures each mesh instance gets its own animated values.

The spline data uses 16-bit floats (`CphxSpline_float16`) for compact storage. Half-precision is sufficient for animation curves where exact values matter less than smooth transitions.

### Animation Flow

Material animation happens during scene graph traversal, before render instance creation.

```
Timeline Event (t = 1.523)
    │
    ├─ UpdateSceneGraph begins
    │     │
    │     ▼
    │  For each mesh object:
    │     │
    │     ├─ Clip->MaterialSplines->CalculateValues(t)
    │     │   Evaluate all material splines at current time
    │     │
    │     ├─ Clip->MaterialSplines->ApplyToParameters(this)
    │     │   Write spline values to material parameters
    │     │
    │     └─ Material->Techniques[x]->CollectAnimatedData(...)
    │         Pack animated floats/colors into GPU buffer
    │
    └─ CreateRenderDataInstances
        Includes packed animated data in each instance
```

This flow ensures animated values are ready when render instances are created. The GPU constant buffer receives current-frame parameter values without additional per-frame work during rendering.

## Material Expansion

### The Expansion Pattern

When a mesh creates render instances, each material pass becomes a separate `CphxRenderDataInstance`. This "expansion" pattern is central to Phoenix's simplicity.

```cpp
// Material.cpp:117 (conceptual)
void CphxMaterialTechnique::CreateRenderDataInstances(...)
{
    for (int x = 0; x < PassCount; x++)
    {
        CphxRenderDataInstance *ri = new CphxRenderDataInstance();

        // Copy geometry references
        ri->VertexBuffer = VertexBuffer;
        ri->IndexBuffer = IndexBuffer;
        ri->TriIndexCount = IndexCount;

        // Copy shader handles (5 pointers via memcpy)
        memcpy(&ri->VS, &RenderPasses[x]->VS, sizeof(void*) * 5);

        // Copy state objects and textures (11 pointers)
        memcpy(&ri->BlendState, &MaterialState[passid]->BlendState,
               sizeof(void*) * 11);

        // Copy transformation matrices
        ri->Matrices[0] = phxWorldMatrix;
        ri->Matrices[1] = phxITWorldMatrix;

        // Copy packed material data
        memcpy(ri->MaterialData, MaterialState[passid]->ConstantData,
               constdatasize);
        memcpy(ri->MaterialData + constdatasize/sizeof(float),
               MaterialState[passid]->AnimatedData, animdatasize);

        // Add to render layer queue
        RootScene->AddRenderDataInstance(TargetLayer, ri);
        passid++;
    }
}
```

Each instance is completely self-contained. No lookups during rendering. No shared state resolution. The trade-off is memory—each instance duplicates texture handles and state pointers. But for demo-scale content, this is acceptable.

### Layer Assignment

Render instances go to specific layers based on technique configuration.

```cpp
void CphxScene::AddRenderDataInstance(CphxRenderLayerDescriptor *Layer,
                                       CphxRenderDataInstance *RDI)
{
    for (int x = 0; x < LayerCount; x++)
        if (RenderLayers[x]->Descriptor == Layer)
        {
            RenderLayers[x]->RenderInstances.Add(RDI);
            return;
        }
}
```

The layer descriptor (set in the material's technique) determines queue placement. A G-Buffer material targets the Solid Layer. A light material targets the Lighting Layer. The scene processes layers in order, ensuring correct render sequencing.

## Constant State

### Per-Pass State

`CphxMaterialPassConstantState` caches per-instance material state for each pass.

```cpp
struct CphxMaterialPassConstantState
{
    bool Wireframe;
    int RenderPriority;

    ID3D11BlendState *BlendState;
    ID3D11RasterizerState *RasterizerState;
    ID3D11DepthStencilState *DepthStencilState;
    ID3D11ShaderResourceView *Textures[8];

    unsigned char *ConstantData;
    int ConstantDataSize;

    unsigned char *AnimatedData;
    int AnimatedDataSize;
};
```

**State objects** (BlendState, RasterizerState, DepthStencilState) are DirectX cached states created from material parameters. Creating state objects is expensive; caching them avoids per-frame overhead.

**Textures[8]** holds shader resource views for all texture slots. Procedural textures resolve to their generated SRVs. Render target textures reference their texture views.

**ConstantData** contains non-animated parameter values (floats, colors) packed for GPU upload. This data is fixed after material creation.

**AnimatedData** receives spline-evaluated values each frame. The collection step writes here before render instance creation.

### State Object Creation

Blend, rasterizer, and depth-stencil states create once during material initialization.

```cpp
// Conceptual flow during material creation
D3D11_BLEND_DESC blendDesc = {};
blendDesc.RenderTarget[0].BlendEnable = (blendMode != 0x01);
blendDesc.RenderTarget[0].SrcBlend = GetSrcBlend(blendMode);
blendDesc.RenderTarget[0].DestBlend = GetDstBlend(blendMode);
// ... configure blend equation

phxDev->CreateBlendState(&blendDesc, &state->BlendState);
```

The packed blend mode byte expands to full D3D11 blend descriptors. Similar expansion happens for rasterizer and depth-stencil parameters. The resulting state objects are immutable and reusable across frames.

## 64k Optimization Techniques

### Parameter Quantization

Most material parameters quantize to bytes for compact storage.

```cpp
// Example: roughness modifier
float modifier = Data[0] / 255.0f;  // Byte → 0-1 range

// Example: UV scale
float2 scale = float2(Data[1], Data[2]) / 16.0f;  // Bytes → 0-16 range
```

Quantization trades precision for size. 256 levels of roughness is visually sufficient. UV scales rarely need sub-0.1 precision. The demotool converts artist-friendly floats to byte representations during export.

### Compile-Time Feature Selection

Unused material features exclude from the final executable.

```cpp
// PhoenixConfig.h
#define PHX_MATERIAL_LTC      // Include LTC area light support
// #define PHX_MATERIAL_SUBSURFACE  // Exclude subsurface scattering

// Material.cpp
#ifdef PHX_MATERIAL_LTC
    case PARAM_LTC1:
        ri->Textures[6] = ltc1View;
        break;
#endif
```

Each `#ifdef` removes code paths and data for unused features. A demo without area lights excludes LTC entirely—no texture creation, no parameter handling, no shader includes.

### Shader Minification

HLSL shaders minify using modified Unreal Engine AST code. Variable names shorten (`worldmat` → `w`), whitespace strips, dead code eliminates. The minified shader compiles identically but occupies fewer bytes in the compressed executable.

### Technique Consolidation

Materials consolidate related passes into minimal techniques. Instead of separate materials for "opaque," "shadow," and "transparent" variants, one material contains all three as techniques. This reduces material-switching overhead and simplifies scene authoring.

## Material Categories

Phoenix materials fall into functional categories based on their technique organization.

### PBR Materials

Standard physically-based materials for meshes. Typically two techniques:
1. **G-Buffer pass**: Writes albedo, metalness, normal, roughness to MRT
2. **Shadow pass**: Depth-only for shadow map generation

Pixel shader reads albedo texture (slot 0), normal texture (slot 1), applies modifiers, outputs to G-Buffer.

### Lighting Materials

Full-screen quad materials for deferred lighting. One technique targeting the Lighting Layer:
1. **Light pass**: Reads G-Buffer, calculates illumination, outputs to Main RT

Additive blend mode accumulates light contributions. No depth testing—every pixel evaluates.

### Post-Process Materials

Full-screen effects after lighting. Technique targets a post-processing layer:
1. **Effect pass**: Reads previous RT, applies effect, outputs to next RT

Examples: bloom blur, color grading, vignette, film grain.

### Transparent Materials

Forward-rendered materials for alpha-blended geometry. Technique targets Transparent Layer:
1. **Forward pass**: Standard VS/PS, alpha blend, depth test but no write

Renders after all deferred lighting completes. Limited to a small number of transparent objects due to sorting requirements.

## Implications for Rust Framework

The Phoenix material system reveals patterns applicable to modern Rust frameworks.

**Separate definition from binding**. Material definitions specify abstract parameters (roughness, albedo). Binding resolves these to GPU resources (textures, constant data). This separation enables caching and reduces per-frame work.

**Pack parameters for GPU upload**. Don't pass parameters one-by-one. Collect floats and colors into contiguous arrays, then upload the block. Rust's `bytemuck` crate handles this elegantly with `Pod` and `Zeroable` traits.

**Cache state objects**. Pipeline states, bind groups, and samplers are expensive to create. Build them once per material variant, store handles, bind during rendering. wgpu's pipeline caching works similarly.

**Support animation as a first-class concern**. Materials shouldn't be static. Design parameter storage to accommodate per-frame updates from animation systems. Consider ECS patterns where animated materials have update components.

**Use layer targeting for render passes**. Let materials declare their target phase (shadow, G-Buffer, lighting, transparency) rather than hardcoding render order. This enables flexible pipeline composition without material changes.

## Related Documents

- **[overview.md](overview.md)** — PBR system architecture and mental model
- **[shaders.md](shaders.md)** — HLSL patterns and constant buffer layout
- **[pipeline.md](pipeline.md)** — Scene graph to GPU draw calls
- **[../code-traces/scene-to-pixels.md](../code-traces/scene-to-pixels.md)** — Material expansion trace

## Source File Reference

| File | Purpose | Key Lines |
|------|---------|-----------|
| Material.h | Type definitions | MATERIALPARAMTYPE (24), CphxMaterialParameter (116), CphxMaterialTechnique (203) |
| Material.cpp | Instance creation | CreateRenderDataInstances (117), CollectAnimatedData |
| Scene.h | Material splines | CphxMaterialSpline (131), CphxMaterialSplineBatch (140) |
| RenderLayer.h | Render instances | CphxRenderDataInstance (10) |
| RenderLayer.cpp | Binding and draw | Render (27) |

All paths relative to `demoscene/apex-public/apEx/Phoenix/`.
