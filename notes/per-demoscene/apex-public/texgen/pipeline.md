# Phoenix Texgen Pipeline

> From operator graph to GPU-generated textures via recursive evaluation and ping-pong rendering

Every 64k demo needs textures, but storing even a single 2048×2048 image consumes 16MB—250 times the entire executable budget. Pre-authored texture assets aren't an option. Yet Clean Slate features richly detailed surfaces: brushed metal, organic noise, procedural text, gradient overlays. The solution is procedural texture generation—compact operator graphs that expand into megabytes of texture data at runtime through GPU computation.

Phoenix's texgen pipeline transforms a declarative operator graph into GPU render passes. Each operator node specifies a filter (shader), resolution, parameters, and up to three parent dependencies. The pipeline recursively evaluates this graph, allocating render targets from a reusable pool, binding pixel shaders, uploading parameters, and executing fullscreen quad draws. Multi-pass operators ping-pong between two render targets, enabling iterative algorithms like Gaussian blur or fractal noise accumulation.

The architecture resembles a functional programming language with memoization. Operators are immutable expressions. Parents are function arguments. Filters are the primitive operations. The `Generate()` method is the interpreter. Caching prevents redundant computation—evaluate once, reuse everywhere. The texture pool is garbage collection—allocate aggressively, release intelligently.

Think of this like a spreadsheet calculating cells. Each operator is a cell with a formula (the filter), inputs (parent cells), and configuration (parameters). You request a cell's value. The spreadsheet recursively calculates dependencies first, caches results, and returns the computed value. If you request the same cell again, the cached value returns instantly. Parent cells release their memory once downstream consumers finish.

Why trace this pipeline? Because it illuminates three critical patterns for creative coding frameworks targeting size constraints. First, how to represent procedural assets as compact graphs rather than dense data. Second, how to implement lazy evaluation with caching to minimize redundant GPU work. Third, how to manage GPU memory through pooling and intelligent release strategies. These patterns apply beyond demos—to web deployment, mobile apps, or any environment where transmission bandwidth costs more than computation cycles.

## The Challenge: Procedural Texture Generation Under 64k

A typical game ships gigabytes of compressed texture assets, decompresses them into VRAM at load time, and streams additional textures as needed. Memory is cheap, bandwidth is abundant, and artists use Photoshop or Substance Designer to paint every detail.

Demos face opposite constraints. The entire executable—code, shaders, data, music synthesis, everything—must fit in 65,536 bytes. A single uncompressed 1024×1024 RGBA texture occupies 4MB. Compressed to PNG, it's still 500KB+. Even a tiny 128×128 texture costs 64KB uncompressed.

Phoenix's texgen inverts the trade-off. Instead of storing texture pixels, store operator graphs. A Perlin noise operator compresses to ~20 bytes: filter index (1 byte), resolution (1 byte), random seed (1 byte), parameters (16 bytes), parent indices (1 byte). The resulting 1024×1024 texture occupies 8MB in VRAM but zero bytes on disk. At runtime, the GPU generates pixels in milliseconds.

The challenge is organizing this procedural generation into a comprehensible, debuggable, reusable system. Artists need to build complex textures by composing simple operations. The engine needs to evaluate graphs efficiently without redundant computation. Memory management must handle dozens of textures without exhausting VRAM. All while keeping the codebase compact enough to fit the 64k budget.

## Operator Graph Representation

The texgen system represents texture generation as a directed acyclic graph (DAG) stored in a flat array. Each `PHXTEXTUREOPERATOR` struct (Texgen.h:105-124) forms a node in the graph:

```cpp
struct PHXTEXTUREOPERATOR {
    unsigned char Resolution;         // Packed X/Y resolution (4 bits each)
    unsigned char Filter;             // Filter index (bit 7 = HDR flag)
    unsigned char RandSeed;           // Random seed for procedural variation
    short Parents[3];                 // Parent operator indices (-1 = none)
    unsigned char Parameters[16];     // Filter-specific parameters (0-255)

    bool NeedsRender;                 // Keep result cached for scene?
    CphxTexturePoolTexture *CachedResult;  // Generated texture (NULL if not yet evaluated)

    int minimportData2;               // Size of extra data
    void *minimportData;              // Pointer to image/text/spline data

    CphxTexturePoolTexture *Generate(PHXTEXTUREFILTER *Filters,
                                      PHXTEXTUREOPERATOR *Operators);
};
```

**Parents as graph edges**: The `Parents[3]` array contains indices into the global operator array. A value of `-1` means "no parent in this slot." Valid indices point to operators that must evaluate before this one. For example, if operator 5 blends operator 2 and operator 3, then `Parents = {2, 3, -1}`.

**DAG properties**: Multiple operators can share a parent—this creates diamond dependencies. Operator 2 generates Perlin noise. Operators 3 and 4 both use operator 2 as a parent. Operator 5 blends operators 3 and 4. This forms a diamond: `2 → {3, 4} → 5`. The DAG structure guarantees a topological evaluation order exists.

**Flat array storage**: The graph stores as `PHXTEXTUREOPERATOR Operators[256]` in the global scope. No pointers, no heap allocations for the graph itself. Indices are the links. This serializes trivially—just write the array to a file. Deserialization is equally simple—read bytes directly into the struct array.

**Filter selection**: The `Filter` byte's lower 7 bits index into the global `PHXTEXTUREFILTER *TextureFilters` array. Bit 7 flags HDR rendering (RGBA16F format instead of RGBA16_UNORM). For example, `Filter = 0x85` means filter index 5 with HDR enabled.

## Evaluation Process: Five Phases

The journey from operator graph to final texture flows through five distinct phases. Understanding each phase reveals how the system balances simplicity, efficiency, and memory conservation.

```mermaid
graph LR
    A[1. Recursive Traversal] --> B[2. Render Target Allocation]
    B --> C[3. Prepare Render State]
    C --> D[4. Multi-Pass Rendering]
    D --> E[5. Caching and Cleanup]

    style A fill:#e1f5ff
    style B fill:#ffe1e1
    style C fill:#e1ffe1
    style D fill:#fff5e1
    style E fill:#f5e1ff
```

Each phase has a specific responsibility. Traversal determines evaluation order and recursively generates dependencies. Allocation claims GPU memory from the pool. Preparation sets up fixed pipeline state shared across all operators. Rendering executes the filter's shader logic across one or more passes. Cleanup releases temporary resources and caches the result for reuse.

The phases execute in strict sequence for each operator. No parallelism, no asynchronous execution. This simplicity keeps the codebase small. A demo's texture graph rarely exceeds 50-100 operators, and modern GPUs execute fullscreen quads in microseconds. The overhead of orchestrating parallel evaluation would exceed the runtime benefit and bloat the executable.

## Phase 1: Recursive Traversal

The entry point is `PHXTEXTUREOPERATOR::Generate()` (Texgen.cpp:464-497). When a material requests a texture, it calls `TextureOperators[index].Generate(Filters, Operators)`. This initiates recursive graph evaluation:

```cpp
CphxTexturePoolTexture *PHXTEXTUREOPERATOR::Generate(
    PHXTEXTUREFILTER *Filters,
    PHXTEXTUREOPERATOR *Operators)
{
    // Phase 1a: Check cache first
    if (CachedResult) return CachedResult;

    CphxTexturePoolTexture *ParentResults[TEXGEN_MAX_PARENTS];

    // Phase 1b: Recursively generate all parents
    for (int x = 0; x < TEXGEN_MAX_PARENTS; x++) {
        ParentResults[x] = NULL;
        if (Parents[x] >= 0) {
            ParentResults[x] = Operators[Parents[x]].Generate(Filters, Operators);
        }
    }

    // Phase 2 begins here...
}
```

**Cache check** (line 466): If `CachedResult` is non-NULL, this operator already executed. Return the cached texture immediately and skip all subsequent phases. This is the memoization—evaluate once, reuse everywhere.

**Parent recursion** (lines 471-479): For each parent slot, check if `Parents[x] >= 0` (valid index). If so, recursively call `Generate()` on that parent operator. The parent evaluates its own dependencies first, then returns its cached result. Collect all parent results into the `ParentResults[3]` array.

**Lazy evaluation**: Only the subgraph needed to produce this operator's result executes. If the operator graph contains 100 operators but only 15 are ancestors of the requested operator, only those 15 evaluate. Unreferenced branches never execute.

**Depth-first traversal**: The recursion naturally produces depth-first ordering. If operator 5 depends on operator 2, which depends on operator 1, the call stack looks like:
```
Generate(5) → Generate(2) → Generate(1) → render 1 → return
                          ← render 2 → return
            ← render 5 → return
```

**Diamond dependencies**: If operators 3 and 4 both depend on operator 2, the first call to `Generate(2)` executes the operator and caches the result. The second call returns the cached texture instantly. Operator 2 renders once despite two consumers.

## Phase 2: Render Target Allocation

After collecting parent results, the operator allocates two render targets from the texture pool (Texgen.cpp:482-483):

```cpp
// Allocate render targets from pool
CphxTexturePoolTexture *Result = TexgenPool->GetTexture(Resolution, (Filter >> 7) != 0);
CphxTexturePoolTexture *BackBuffer = TexgenPool->GetTexture(Resolution, (Filter >> 7) != 0);
```

**Why two textures?** Multi-pass operators need ping-pong rendering. Pass 0 writes to `Result`, reading from parent inputs. Pass 1 swaps targets: writes to `BackBuffer`, reads from `Result`. Pass 2 swaps again: writes to `Result`, reads from `BackBuffer`. This avoids read/write hazards where a shader simultaneously reads from and writes to the same texture.

**Resolution extraction**: The `Resolution` byte packs X and Y dimensions into high/low nibbles. `GETXRES(Resolution) = 1 << (Resolution >> 4)` extracts width. `GETYRES(Resolution) = 1 << (Resolution & 0x0f)` extracts height. A value of `0xAA` produces 1024×1024.

**HDR flag**: `(Filter >> 7) != 0` tests bit 7. If set, allocate RGBA16F textures (float format supporting values outside [0,1]). If clear, allocate RGBA16_UNORM textures (normalized unsigned 16-bit).

**Pool allocation strategy** (Texgen.cpp:67-87):

```cpp
CphxTexturePoolTexture *CphxTexturePool::GetTexture(unsigned char Resolution, bool hdr) {
    // Search for matching unused texture
    for (int x = 0; x < poolSize; x++) {
        CphxTexturePoolTexture* p = pool[x];
        if (p->Resolution == Resolution && p->hdr == hdr && !p->Used && !p->Deleted) {
            p->Used = true;
            return p;
        }
    }

    // No match found: create new texture
    CphxTexturePoolTexture *t = new CphxTexturePoolTexture;
    pool[poolSize++] = t;
    t->Resolution = Resolution;
    t->Create(Resolution, hdr);
    t->Used = true;
    return t;
}
```

The pool searches linearly for a texture matching `Resolution`, `hdr`, and `!Used`. If found, mark it `Used = true` and return. If no match exists, allocate a new `CphxTexturePoolTexture`, call `Create()` to allocate the D3D11 texture, and add it to the pool.

**Texture creation** (Texgen.cpp:18-64) allocates three D3D11 resources:
1. `ID3D11Texture2D *Texture` — The GPU texture storage
2. `ID3D11ShaderResourceView *View` — For binding as shader input
3. `ID3D11RenderTargetView *RTView` — For binding as render target

The texture descriptor specifies `D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET` and `D3D11_RESOURCE_MISC_GENERATE_MIPS`. This enables both rendering to the texture and sampling from it with automatic mipmap generation.

## Phase 3: Prepare Render State

Before the filter renders, `Prepare2dRender()` (Texgen.cpp:99-118) sets up fixed pipeline state shared across all texgen operators:

```cpp
void Prepare2dRender()
{
    phxContext->VSSetShader(TexgenVertexShader, NULL, 0);

    SetSamplers();

    phxContext->RSSetState(NULL);
    phxContext->OMSetBlendState(NULL, NULL, 0xffffffff);
    phxContext->OMSetDepthStencilState(NULL, 0);

    phxContext->IASetInputLayout(TexgenVertexFormat);
    unsigned int offset = 0;
    unsigned int stride = 6 * sizeof(float);
    phxContext->IASetVertexBuffers(0, 1, &TexgenVertexBuffer, &stride, &offset);
    phxContext->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    phxContext->GSSetShader(NULL, NULL, 0);
    phxContext->HSSetShader(NULL, NULL, 0);
    phxContext->DSSetShader(NULL, NULL, 0);
}
```

**Vertex shader**: `TexgenVertexShader` is a minimal shader that transforms a fullscreen quad from clip space [-1,1] to screen space and passes through UVs. Every filter uses the same vertex shader.

**Samplers** (Texgen.cpp:92-97):

```cpp
void SetSamplers()
{
    phxContext->PSSetSamplers(0, 1, &TexgenSampler);          // Wrap + Linear
    phxContext->PSSetSamplers(1, 1, &TexgenSampler_NoWrap);   // Clamp + Linear
    phxContext->PSSetSamplers(2, 1, &TexgenSampler_ShadowCompare);  // Shadow compare
}
```

Slot 0 uses wrap addressing for tiling textures and UV distortion. Slot 1 uses clamp addressing to prevent edge wrapping. Slot 2 is a shadow compare sampler inherited from the rendering pipeline but unused in texgen.

**Rasterizer state**: `NULL` means use default state (no culling, fill mode solid, no scissor test). Texgen renders fullscreen quads—no need for custom rasterization.

**Blend state**: `NULL` means disable blending. Each filter writes output directly without alpha compositing. If a filter needs blending (e.g., an "overlay" blend mode filter), it implements it in the shader by manually sampling inputs and computing the blend formula.

**Depth-stencil state**: `NULL` disables depth testing. Texgen is 2D—no depth buffer exists.

**Input assembly**: The vertex buffer contains 6 vertices forming two triangles covering the entire viewport:

```
(-1, 1)    (1, 1)
    +----------+
    |\         |
    |  \       |
    |    \     |
    |      \   |
    |        \ |
    +----------+
(-1,-1)    (1,-1)
```

Each vertex is 6 floats: `{x, y, z, u, v, w}` (position + UV). The stride is `6 * sizeof(float) = 24` bytes.

**Shader stages**: Explicitly bind `NULL` to geometry, hull, and domain shader slots. This ensures no lingering state from previous render operations.

## Phase 4: Multi-Pass Rendering

The core rendering logic lives in `PHXTEXTUREFILTER::Render()` (Texgen.cpp:120-185). This method orchestrates multi-pass execution, parameter upload, texture binding, and draw calls.

```cpp
void PHXTEXTUREFILTER::Render(
    CphxTexturePoolTexture *&Target,
    CphxTexturePoolTexture *&SwapBuffer,
    CphxTexturePoolTexture *Inputs[TEXGEN_MAX_PARENTS],
    unsigned char RandSeed,
    unsigned char Parameters[TEXGEN_MAX_PARAMS],
    void *ExtraData,
    int ExtraDataSize)
{
    srand(RandSeed);
    float ShaderData[TEXGEN_MAX_PARAMS + 4];

    phxContext->PSSetShader(PixelShader, NULL, 0);
    Prepare2dRender();
    phxContext->PSSetConstantBuffers(0, 1, &TexgenBufferPS);

    Target->SetViewport();

    // Multi-pass loop begins...
}
```

**Random seed initialization**: `srand(RandSeed)` seeds the C standard library RNG. Later calls to `rand()` produce deterministic values based on this seed. Changing the seed produces different procedural variations.

**Pixel shader binding**: Each filter has a unique `PixelShader` pointer compiled from HLSL source. This shader implements the filter's algorithm (noise generation, blur, colorize, etc.).

**Constant buffer binding**: `TexgenBufferPS` is a constant buffer holding `ShaderData[20]` (4 pass metadata floats + 16 parameter floats). Binding it to slot 0 makes it accessible in the shader as `cbuffer ShaderData : register(b0)`.

**Viewport setup**: `Target->SetViewport()` sets the D3D11 viewport to match the render target's resolution. A 1024×1024 texture gets a viewport of `{0, 0, 1024, 1024}`. This ensures the fullscreen quad rasterizes to every pixel.

### Multi-Pass Loop Structure

The render method iterates from pass 0 to `PassCount - 1`:

```cpp
D3D11_MAPPED_SUBRESOURCE map;
ID3D11ShaderResourceView *Textures[5];

for (unsigned int x = 0; x < DataDescriptor.PassCount; x++) {
    // Step A: Get lookup texture
    CphxTexturePoolTexture *Lookup = GetLookupTexture(Target->Resolution, ExtraData, ExtraDataSize);

    // Step B: Swap render targets
    CphxTexturePoolTexture *swapvar = SwapBuffer;
    SwapBuffer = Target;
    Target = swapvar;

    // Step C: Unbind shader resources
    Textures[0] = Textures[1] = Textures[2] = Textures[3] = Textures[4] = NULL;
    phxContext->PSSetShaderResources(0, 5, Textures);

    // Step D: Bind render target
    phxContext->OMSetRenderTargets(1, &Target->RTView, NULL);

    // Step E: Set shader data
    ShaderData[0] = (float)x;  // Pass index
    for (int y = 0; y < 3; y++)
        ShaderData[y + 1] = rand() / (float)RAND_MAX;  // Random values
    for (int y = 0; y < TEXGEN_MAX_PARAMS; y++)
        ShaderData[y + 4] = Parameters[y] / 255.0f;  // Normalized params

    // Step F: Upload constant buffer
    phxContext->Map(TexgenBufferPS, 0, D3D11_MAP_WRITE_DISCARD, 0, &map);
    memcpy(map.pData, ShaderData, SHADERDATALENGTH);
    phxContext->Unmap(TexgenBufferPS, 0);

    // Step G: Bind textures
    int scnt = 0;
    if (Inputs[0] || x)
        Textures[scnt++] = x ? SwapBuffer->View : Inputs[0]->View;
    if (Inputs[1])
        Textures[scnt++] = Inputs[1]->View;
    if (Inputs[2])
        Textures[scnt++] = Inputs[2]->View;
    if (Lookup)
        Textures[scnt++] = Lookup->View;
    if (Lookup)
        Textures[scnt++] = Lookup->View;  // Duplicate for multi-pass noise

    phxContext->PSSetShaderResources(0, 5, Textures);

    // Step H: Draw fullscreen quad
    phxContext->Draw(6, 0);

    // Step I: Generate mipmaps
    phxContext->GenerateMips(Target->View);

    // Step J: Cleanup lookup texture
    if (Lookup) {
        if (Lookup->View) Lookup->View->Release();
        if (Lookup->Texture) Lookup->Texture->Release();
        delete Lookup;
    }
}
```

Let's trace each step in detail.

### Step A: Get Lookup Texture

`GetLookupTexture()` (Texgen.cpp:205-346) generates auxiliary textures based on the filter's `LookupType`:

| LookupType | Value | Generated Content | Use Case |
|------------|-------|-------------------|----------|
| None | 0 | NULL (no lookup) | Pure math filters |
| Image | 1 | Load compressed image from `ExtraData` | Logos, decals, overlays |
| Text | 2 | Render text using GDI | Dynamic text generation |
| Spline | 3 | Sample 4 splines into 4096×1 texture | Color curves, gradients |
| Hash | 4 | Generate 256×256 random values via xorshf96 | Noise basis |

**Hash generation** (lines 323-333) is the most common type:

```cpp
case 4: // noise
{
    tex.Width = tex.Height = XRes = YRes = 256;
    data.SysMemPitch = XRes * 4;
    ImageData = new unsigned char[XRes * YRes * 4];
    rndx = rand();  // Seed from srand(RandSeed) earlier
    rndy = 362436069;
    rndz = 521288629;
    for (int x = 0; x < XRes * YRes * 4; x++)
        ImageData[x] = (unsigned char)xorshf96();
}
```

The `xorshf96()` function (lines 191-203) implements a fast pseudorandom number generator with a period of 2^96-1. Each byte in the 256×256 texture comes from successive PRNG calls, creating high-frequency random noise for Perlin noise gradients or dither patterns.

The lookup texture allocates fresh D3D11 resources each pass and deletes them at the end of the pass (step J). This seems wasteful, but lookup textures are typically 256×256 (256KB)—small enough that allocation overhead is negligible.

### Step B: Swap Render Targets

The ping-pong swap happens unconditionally every pass:

```cpp
CphxTexturePoolTexture *swapvar = SwapBuffer;
SwapBuffer = Target;
Target = swapvar;
```

After this swap:
- **Pass 0**: `Target` = original result allocation, `SwapBuffer` = original backbuffer
- **After swap**: `Target` = original backbuffer, `SwapBuffer` = original result

This means the **first pass** writes to what was initially the backbuffer. The **second pass** writes to what was initially the result. They alternate roles.

At the end of the loop, `Target` holds the final result. The `Generate()` method returns `Result`, not `Target`, but the local variables swap references—`Result` ends up pointing to whatever `Target` points to after the final swap.

Actually, looking more carefully at the code, the `Target` and `SwapBuffer` parameters are **references** (`*&`). This means changes to the pointer values persist outside the function. The swap modifies the caller's `Result` and `BackBuffer` pointers. After an odd number of passes, `Result` and `BackBuffer` have swapped identities. The `Generate()` method returns whatever `Result` points to after `Render()` completes.

### Step C: Unbind Shader Resources

Before binding the new render target, clear all shader resource slots:

```cpp
Textures[0] = Textures[1] = Textures[2] = Textures[3] = Textures[4] = NULL;
phxContext->PSSetShaderResources(0, 5, Textures);
```

This avoids a D3D11 error: "Resource is still bound as shader input while being set as render target." If the previous pass bound `Target` as a shader resource and the current pass binds it as a render target, DirectX will issue a warning and silently unbind the conflicting resource. Explicitly unbinding prevents this.

### Step D: Bind Render Target

```cpp
phxContext->OMSetRenderTargets(1, &Target->RTView, NULL);
```

Bind `Target` as the render target. No depth buffer (`NULL` as the second parameter). All pixel shader output writes to `Target`.

### Step E: Set Shader Data

The shader data array packs metadata and parameters:

```cpp
ShaderData[0] = (float)x;  // Pass index: 0.0, 1.0, 2.0, ...
ShaderData[1] = rand() / (float)RAND_MAX;  // Random value 0.0-1.0
ShaderData[2] = rand() / (float)RAND_MAX;  // Random value 0.0-1.0
ShaderData[3] = rand() / (float)RAND_MAX;  // Random value 0.0-1.0
ShaderData[4..19] = Parameters[0..15] / 255.0f;  // Normalized 0.0-1.0
```

Shaders access this as:

```hlsl
cbuffer ShaderData : register(b0) {
    float4 PassData;    // x = pass index, yzw = random values
    float4 Params[4];   // 16 parameters as 4×float4
};
```

The pass index enables shaders to adjust behavior per iteration. For example, a multi-octave noise shader might use `PassData.x` to scale frequency exponentially: `frequency = pow(2.0, PassData.x)`.

The random values provide per-pass entropy for stochastic algorithms. A dithering shader might use `PassData.yzw` to offset sample positions.

### Step F: Upload Constant Buffer

```cpp
phxContext->Map(TexgenBufferPS, 0, D3D11_MAP_WRITE_DISCARD, 0, &map);
memcpy(map.pData, ShaderData, SHADERDATALENGTH);
phxContext->Unmap(TexgenBufferPS, 0);
```

`D3D11_MAP_WRITE_DISCARD` tells DirectX to allocate new constant buffer memory instead of synchronizing with the GPU. This avoids pipeline stalls. The old buffer contents are discarded—the GPU may still be using them from a previous draw call, but the driver allocates fresh memory for this update.

`SHADERDATALENGTH` is `(4 + TEXGEN_MAX_PARAMS) * sizeof(float) = 20 * 4 = 80` bytes.

### Step G: Bind Textures

Texture binding assigns parent operator results and lookup textures to shader resource slots:

```cpp
int scnt = 0;
if (Inputs[0] || x)
    Textures[scnt++] = x ? SwapBuffer->View : Inputs[0]->View;
if (Inputs[1])
    Textures[scnt++] = Inputs[1]->View;
if (Inputs[2])
    Textures[scnt++] = Inputs[2]->View;
if (Lookup)
    Textures[scnt++] = Lookup->View;
if (Lookup)
    Textures[scnt++] = Lookup->View;  // Duplicate
```

**Slot 0 logic**: On **pass 0** (`x == 0`), if `Inputs[0]` exists, bind it. If no parent input exists, this filter generates from scratch (like a noise generator). On **pass 1+** (`x > 0`), bind `SwapBuffer` (the previous pass's output).

**Slot 1-2**: Bind remaining parent inputs if they exist. A blend filter has 2 parents. A gradient generator has 0.

**Slot 3-4**: Bind the lookup texture to both slots. The comment explains this is necessary for "multipass noise lookup filters." Some shaders need the lookup texture in multiple stages or prefer it in a known slot regardless of parent count.

Shaders access these as:

```hlsl
Texture2D texture0 : register(t0);  // Previous pass or Input 0
Texture2D texture1 : register(t1);  // Input 1
Texture2D texture2 : register(t2);  // Input 2
Texture2D texture3 : register(t3);  // Lookup texture
Texture2D texture4 : register(t4);  // Lookup texture (duplicate)
```

### Step H: Draw Fullscreen Quad

```cpp
phxContext->Draw(6, 0);
```

Issue a non-indexed draw call rendering 6 vertices starting at vertex 0. The vertex buffer contains two triangles forming a fullscreen quad. The vertex shader transforms positions from clip space to screen space and passes UVs to the pixel shader. The pixel shader executes for every pixel in the render target, sampling input textures and computing output colors.

This single draw call generates the entire texture for this pass.

### Step I: Generate Mipmaps

```cpp
phxContext->GenerateMips(Target->View);
```

D3D11's `GenerateMips()` automatically computes the mipmap chain for `Target` using box filtering. Each mip level is half the resolution of the previous level. A 1024×1024 texture gets mips at 512, 256, 128, 64, 32, 16, 8, 4, 2, 1.

Why generate mipmaps every pass? Because the next pass might sample this texture with anisotropic filtering or at reduced resolution. Without mipmaps, sampling artifacts appear. The cost is minimal—mipmap generation is a trivial GPU operation.

### Step J: Cleanup Lookup Texture

```cpp
if (Lookup) {
    if (Lookup->View) Lookup->View->Release();
    if (Lookup->Texture) Lookup->Texture->Release();
    delete Lookup;
}
```

Release the D3D11 resources and deallocate the temporary `CphxTexturePoolTexture` wrapper. The lookup texture was created fresh for this pass and won't be reused. This keeps memory usage tight—only active render targets persist.

### Multi-Pass Example: Gaussian Blur

A Gaussian blur filter uses 2 passes:
- **Pass 0**: Horizontal blur. Reads from `Inputs[0]` (the input texture), applies a horizontal blur kernel, writes to `Target`.
- **Pass 1**: Vertical blur. Reads from `SwapBuffer` (pass 0's output), applies a vertical blur kernel, writes to `Target`.

The shader uses `PassData.x` to select blur direction:

```hlsl
float4 p(float2 uv : TEXCOORD0) : SV_TARGET {
    float2 direction = PassData.x == 0.0 ? float2(1, 0) : float2(0, 1);
    float4 color = 0;
    for (int i = -4; i <= 4; i++) {
        float2 offset = direction * i * (1.0 / TextureSize);
        color += texture0.Sample(sampler0, uv + offset) * gaussianWeights[i + 4];
    }
    return color;
}
```

This separable approach (horizontal then vertical) is faster than a 2D blur kernel. A 9×9 kernel requires 81 samples per pixel. Separable filtering requires 9+9=18 samples.

## Phase 5: Caching and Cleanup

After the render loop completes, `Generate()` performs cleanup and caching (Texgen.cpp:488-496):

```cpp
// Release swap buffer (returns to pool)
BackBuffer->Used = false;

// Release parent results if no longer needed
for (int x = 0; x < TEXGEN_MAX_PARENTS; x++)
    if (ParentResults[x] && !Operators[Parents[x]].NeedsRender)
        ParentResults[x]->Used = false;

// Cache result for reuse
CachedResult = Result;

// Return result texture
return Result;
```

**BackBuffer release**: The backbuffer was only needed for ping-pong rendering during multi-pass execution. Mark it `Used = false` so the pool can reuse it for subsequent operators. The texture isn't deleted—it stays in the pool for the next `GetTexture()` call.

**Parent result release**: For each parent, check the `NeedsRender` flag. If `false`, this parent's output was only needed as an intermediate result. Mark its texture `Used = false` to return it to the pool. If `true`, the parent's texture is referenced by materials or other operators, so keep it allocated.

**Cache assignment**: Store `Result` in `CachedResult`. Future calls to `Generate()` return this pointer immediately without re-executing the filter.

**Return value**: The caller receives the `Result` texture pointer. Materials store this pointer to bind the texture during rendering.

### Memory Lifecycle Example

Consider a graph generating a wood grain texture:

1. **Operator 0** (Perlin noise): Allocates Texture A (512×512), renders noise, caches result, returns A. `NeedsRender = false` (intermediate).
2. **Operator 1** (Voronoi cells): Allocates Texture B (512×512), renders cells, caches result, returns B. `NeedsRender = false`.
3. **Operator 2** (Blend): Allocates Texture C + D (512×512 each for ping-pong), blends A and B, caches C, marks D as unused, checks parents:
   - Operator 0's `NeedsRender = false` → mark A as `Used = false`
   - Operator 1's `NeedsRender = false` → mark B as `Used = false`
   - Pool now has A, B, D available for reuse
4. **Operator 3** (Directional blur, 2 passes): Allocates targets, but the pool returns A and B (matching resolution, available), renders blur, caches result.

The pool created 4 textures (A, B, C, D) to evaluate 4 operators with multi-pass rendering. Without pooling, it would need 8 textures (2 per operator). The `NeedsRender` flag controls when intermediate results release.

## Subroutine Execution: Reusable Operator Graphs

Subroutines (`PHXTEXTURESUBROUTINE`, Texgen.h:135-149) encapsulate reusable operator subgraphs. They enable abstraction—define a complex effect once, invoke it with varying parameters and inputs.

The `Generate()` method (Texgen.cpp:502-527) wires the subroutine's internal graph to the caller's context:

```cpp
CphxTexturePoolTexture *PHXTEXTURESUBROUTINE::Generate(
    PHXTEXTUREFILTER *Filters,
    PHXTEXTUREOPERATOR *CallerOperators,
    unsigned short *Parents,
    unsigned char *Parameters,
    unsigned char Resolution)
{
    // Step 1: Inject parent textures into input operators
    for (unsigned int x = 0; x < DataDescriptor.InputCount; x++)
        Operators[Inputs[x]].CachedResult =
            CallerOperators[Parents[x]].Generate(Filters, CallerOperators);

    // Step 2: Override resolution for all embedded operators
    for (int x = 0; x < 256; x++)
        Operators[x].Resolution = Resolution;

    // Step 3: Apply dynamic parameter overrides
    for (int x = 0; x < DynamicParameterCount; x++)
        Operators[DynamicParameters[x].TargetOperator]
            .Parameters[DynamicParameters[x].TargetParameter] = Parameters[x];

    // Step 4: Execute embedded output operator
    CphxTexturePoolTexture *Result = Operators[Output].Generate(Filters, Operators);

    // Step 5: Release injected inputs
    for (unsigned int x = 0; x < DataDescriptor.InputCount; x++) {
        Operators[Inputs[x]].CachedResult->Used = false;
        Operators[Inputs[x]].CachedResult = NULL;
    }

    return Result;
}
```

**Input injection**: The caller specifies parent operators via the `Parents[]` array. The subroutine generates those parents (recursively) and injects the results into designated input operators by setting their `CachedResult` pointers. When the embedded graph evaluates, these input operators return the injected textures instead of generating new ones.

**Resolution propagation**: The caller specifies the target resolution. The subroutine overwrites the `Resolution` field of all 256 embedded operators. This enables the same subroutine to generate textures at 512×512, 1024×1024, or any other size.

**Parameter overrides**: The `DynamicParameters[]` array specifies which operator/parameter pairs to override. For example, `{TargetOperator: 5, TargetParameter: 2}` means "set operator 5's parameter 2 to `Parameters[0]`." This exposes internal parameters to the caller.

**Execution**: Call `Operators[Output].Generate()` using the embedded operator array. The graph evaluates recursively, using the injected inputs, overridden resolution, and dynamic parameters.

**Cleanup**: After execution, mark the injected input textures as `Used = false` to return them to the pool, and clear the `CachedResult` pointers so the input operators don't retain stale references.

### Subroutine Example: Brushed Metal

A "brushed metal" subroutine might contain:
- **Input 0** (operator 0): Receives base color from caller (or generates default gray if none)
- **Operator 1**: Generate anisotropic noise (stretched in one direction)
- **Operator 2**: Directional blur along brush angle (parameter 0 controls angle)
- **Operator 3**: Blend noise with base color
- **Operator 4**: Adjust brightness/contrast (parameters 1-2)
- **Operator 5**: Apply specular highlights (parameter 3 controls intensity)
- **Output**: Operator 5

The tool can invoke this subroutine with different brush angles, roughness values, and base colors to create varied metal textures without duplicating the 6-operator graph.

## Data Flow Summary

The complete pipeline from graph to pixels:

```
Material Requests Texture (index 42)
    │
    ▼
TextureOperators[42].Generate(Filters, Operators)
    │
    ├─ Check CachedResult (Phase 1)
    │  ├─ If cached: return immediately
    │  └─ If not cached: continue
    │
    ├─ Recursively Generate Parents (Phase 1)
    │  ├─ Generate(Parents[0])
    │  ├─ Generate(Parents[1])
    │  └─ Generate(Parents[2])
    │
    ├─ Allocate Render Targets (Phase 2)
    │  ├─ Result = TexgenPool->GetTexture(Resolution, HDR)
    │  └─ BackBuffer = TexgenPool->GetTexture(Resolution, HDR)
    │
    ├─ Render Filter (Phases 3-4)
    │  │
    │  ├─ Bind Pixel Shader
    │  ├─ Prepare2dRender() (Phase 3)
    │  │  ├─ Set vertex shader
    │  │  ├─ Set samplers (wrap/clamp/shadow)
    │  │  ├─ Disable blend/depth
    │  │  └─ Bind vertex buffer
    │  │
    │  └─ Multi-Pass Loop (Phase 4)
    │     │
    │     ├─ For each pass (0 to PassCount-1)
    │     │  │
    │     │  ├─ GetLookupTexture() (Step A)
    │     │  │  ├─ Type 1: Load image from memory
    │     │  │  ├─ Type 2: Render text via GDI
    │     │  │  ├─ Type 3: Sample 4 splines to 4096×1 texture
    │     │  │  └─ Type 4: Generate 256×256 hash via xorshf96
    │     │  │
    │     │  ├─ Swap(Target, SwapBuffer) (Step B)
    │     │  ├─ Unbind shader resources (Step C)
    │     │  ├─ Bind Target as render target (Step D)
    │     │  │
    │     │  ├─ Build ShaderData[] (Step E)
    │     │  │  ├─ ShaderData[0] = pass index
    │     │  │  ├─ ShaderData[1-3] = rand()
    │     │  │  └─ ShaderData[4-19] = Parameters[] / 255.0
    │     │  │
    │     │  ├─ Upload Constant Buffer (Step F)
    │     │  │  ├─ Map(TexgenBufferPS, WRITE_DISCARD)
    │     │  │  ├─ memcpy(ShaderData, 80 bytes)
    │     │  │  └─ Unmap()
    │     │  │
    │     │  ├─ Bind Textures (Step G)
    │     │  │  ├─ Slot 0: Pass 0 → Inputs[0], Pass 1+ → SwapBuffer
    │     │  │  ├─ Slot 1: Inputs[1]
    │     │  │  ├─ Slot 2: Inputs[2]
    │     │  │  └─ Slot 3-4: Lookup texture
    │     │  │
    │     │  ├─ Draw(6, 0) (Step H)
    │     │  ├─ GenerateMips(Target) (Step I)
    │     │  └─ Cleanup Lookup texture (Step J)
    │     │
    │     └─ End loop
    │
    └─ Cleanup and Cache (Phase 5)
       ├─ Mark BackBuffer as unused
       ├─ Release parent results if !NeedsRender
       ├─ Cache Result in CachedResult
       └─ Return Result
```

## Shader Data Flow

Understanding how data flows from CPU to GPU illuminates the constant buffer layout and texture slot conventions.

### Constant Buffer Layout

The pixel shader receives a constant buffer in slot 0 with 80 bytes of data:

```
Byte Offset   Content                   HLSL Access
-----------   ----------------------    ---------------------
0-3           Pass index (float)        PassData.x
4-7           Random value (float)      PassData.y
8-11          Random value (float)      PassData.z
12-15         Random value (float)      PassData.w
16-19         Parameter 0 (float)       Params[0].x
20-23         Parameter 1 (float)       Params[0].y
24-27         Parameter 2 (float)       Params[0].z
28-31         Parameter 3 (float)       Params[0].w
32-35         Parameter 4 (float)       Params[1].x
...           ...                       ...
72-75         Parameter 14 (float)      Params[3].z
76-79         Parameter 15 (float)      Params[3].w
```

Shaders declare:

```hlsl
cbuffer ShaderData : register(b0) {
    float4 PassData;     // Pass index + 3 random floats
    float4 Params[4];    // 16 parameters as 4×float4
};
```

This layout matches the CPU-side `ShaderData[]` array exactly. The `memcpy()` copies the entire array contiguously, and the GPU interprets it according to the `cbuffer` declaration.

### Texture Slot Usage

```
Slot   Content                        Sampler   HLSL Declaration
----   ---------------------------    -------   --------------------------------
t0     Previous pass / Input 0        s0/s1     Texture2D texture0 : register(t0);
t1     Input 1                        s0/s1     Texture2D texture1 : register(t1);
t2     Input 2                        s0/s1     Texture2D texture2 : register(t2);
t3     Lookup texture                 s0/s1     Texture2D texture3 : register(t3);
t4     Lookup texture (duplicate)     s0/s1     Texture2D texture4 : register(t4);
```

Shaders sample using:

```hlsl
SamplerState sampler0 : register(s0);  // Wrap + Linear
SamplerState sampler1 : register(s1);  // Clamp + Linear

float4 p(float2 uv : TEXCOORD0) : SV_TARGET {
    float4 prev = texture0.Sample(sampler0, uv);    // Previous pass result
    float4 inp1 = texture1.Sample(sampler1, uv);    // Parent input 1
    float noise = texture3.Sample(sampler0, uv).r;  // Lookup texture
    return mix(prev, inp1, noise);
}
```

## Sampler Configuration

The `SetSamplers()` function (Texgen.cpp:92-97) binds three sampler states to slots 0-2:

| Slot | Mode | Filter | Use Case |
|------|------|--------|----------|
| s0 | Wrap + Linear | Bilinear filtering with tiling | Tiling textures, seamless noise, UV distortion |
| s1 | Clamp + Linear | Bilinear filtering without wrap | Edge sampling, avoiding border artifacts |
| s2 | Shadow Compare | Comparison sampling | Unused in texgen (inherited from rendering pipeline) |

**Wrap mode** repeats UVs outside [0,1]. Sampling at `uv = (1.5, 0.3)` wraps to `(0.5, 0.3)`. This creates seamless tiling when generating patterns.

**Clamp mode** clamps UVs to [0,1]. Sampling at `uv = (1.5, 0.3)` clamps to `(1.0, 0.3)`. This prevents edge wrapping when sampling parent textures that shouldn't tile.

Shaders choose samplers based on intent. A noise generator uses `sampler0` for seamless repetition. A blur filter uses `sampler1` to avoid reading wrapped pixels at edges.

## Render Target Format

Texgen textures use one of two formats:

| Format | Type | Range | Bytes/Pixel | Use Case |
|--------|------|-------|-------------|----------|
| `DXGI_FORMAT_R16G16B16A16_UNORM` | Unsigned normalized 16-bit | [0, 1] | 8 | Standard color textures |
| `DXGI_FORMAT_R16G16B16A16_FLOAT` | Half-precision float | (-65504, +65504) | 8 | HDR textures (bloom, tone mapping) |

The HDR flag (`Filter >> 7`) selects the format. Most textures use UNORM. HDR textures support values outside [0,1], necessary for:
- **Bloom**: Bright pixels exceed 1.0 to trigger glow effects
- **Tone mapping**: Wide dynamic range before mapping to [0,1] display range
- **Physical light units**: Light intensity in candelas or lumens

Both formats consume 8 bytes per pixel. At 1024×1024, each texture occupies 8MB of VRAM. With mipmaps, the total is ~10.67MB (8MB + 2MB + 512KB + ... + 4 bytes).

## Memory Management Strategies

The texture pool implements a simple but effective memory management strategy that balances allocation overhead against memory consumption.

**Allocation policy**: Search linearly for a matching unused texture. If found, reuse. If not, allocate new. The pool grows but never shrinks. Once a texture allocates, it persists for the demo's lifetime.

**Release policy**: Mark textures as `Used = false` when no longer needed. The `NeedsRender` flag controls when intermediate results release versus when final results persist.

**Typical usage pattern**: A demo might generate 20-30 textures at startup (diffuse maps, normal maps, noise patterns). The pool allocates ~25 texture objects. During rendering, these textures reuse repeatedly as materials bind them. Additional operators evaluate lazily as materials activate, growing the pool modestly.

**Memory footprint**: A typical demo graph with 50 operators might have:
- 10 final textures (referenced by materials): 10 × 10.67MB = 107MB
- 5 simultaneous intermediate textures during evaluation: 5 × 10.67MB = 53MB
- **Peak usage**: ~160MB during texture generation
- **Runtime usage**: ~107MB (only final textures)

For modern GPUs with 4-8GB+ VRAM, this is trivial. The pool's simplicity (no complex tracking, no defragmentation, no LRU eviction) saves executable bytes while handling demos' modest memory needs.

**Pathological case**: If the graph has no shared parents, every operator allocates unique textures. A chain of 50 operators at 1024×1024 would consume 50 × 10.67MB = 533MB. In practice, graphs share extensively—noise generators, color ramps, and blend operators form common subgraphs reused across multiple textures.

## Performance Characteristics

The texgen pipeline prioritizes simplicity and small code size over runtime optimization. Several characteristics reflect this philosophy:

**One operator = one or more draw calls**: Each operator issues `PassCount` draw calls. A graph with 50 operators averaging 2 passes generates 100 draw calls. No batching, no instancing, no draw call merging.

**GPU-bound, not CPU-bound**: The CPU overhead of `Generate()` recursion and pool searches is negligible compared to GPU rendering time. Fullscreen quad draws saturate memory bandwidth. Complex shaders (Perlin noise, Voronoi cells) saturate ALUs.

**Lazy evaluation**: Only operators in the dependency subgraph execute. Unreferenced branches never evaluate. This matters for tool development—the editor can build a 100-operator palette, but the exported demo only evaluates the 30 operators actually used.

**Caching eliminates redundancy**: Diamond dependencies (A → B, A → C, B → D, C → D) evaluate A once despite two consumers. Without caching, A would evaluate twice, doubling GPU work.

**Mipmaps add GPU overhead**: Generating mipmaps after every pass adds cost. A 1024×1024 texture requires filling 512×512 (25% of original), 256×256 (6.25%), etc.—approximately 33% additional pixel processing. The benefit (correct filtering in downstream operators) outweighs the cost.

**Typical generation time**: On a mid-range GPU (e.g., GTX 1060), generating a complex texture graph with 30 operators at 1024×1024 takes 10-50ms. This happens once at demo startup or scene transition. Runtime rendering uses the cached textures without regeneration.

## Implications for Rust Framework

Phoenix's texgen architecture offers valuable lessons for a modern creative coding framework targeting procedural asset generation or size constraints.

### Adopt: Graph-Based Procedural Generation

Representing textures as operator DAGs compresses asset data dramatically. A Rust framework should embrace this pattern:

```rust
pub struct Operator {
    filter: FilterId,
    resolution: Resolution,
    parents: [Option<OperatorId>; 3],
    parameters: [u8; 16],
    random_seed: u8,
    cached_result: Option<TextureHandle>,
}

pub enum FilterId {
    PerlinNoise,
    VoronoiCells,
    GaussianBlur,
    Colorize,
    // ... 30+ filters
}
```

The `cached_result` field enables memoization. The `parents` array encodes the DAG structure. The `parameters` array stores filter-specific configuration compactly.

### Adopt: Lazy Evaluation with Caching

Phoenix's recursive `Generate()` with caching is elegant and maps naturally to Rust:

```rust
impl Operator {
    pub fn generate(
        &mut self,
        filters: &[Filter],
        operators: &mut [Operator],
        pool: &mut TexturePool,
    ) -> &Texture {
        // Return cached result if available
        if let Some(ref cached) = self.cached_result {
            return pool.get_texture(cached);
        }

        // Recursively generate parents
        let parents: Vec<TextureHandle> = self.parents.iter()
            .filter_map(|&p| p.map(|id| {
                operators[id as usize].generate(filters, operators, pool);
                operators[id as usize].cached_result.unwrap()
            }))
            .collect();

        // Allocate render targets
        let result = pool.allocate(self.resolution, self.is_hdr());
        let backbuffer = pool.allocate(self.resolution, self.is_hdr());

        // Render filter
        filters[self.filter as usize].render(
            result, backbuffer, &parents, &self.parameters, self.random_seed
        );

        // Cache and return
        pool.release(backbuffer);
        self.cached_result = Some(result);
        pool.get_texture(result)
    }
}
```

Rust's ownership system makes memory management safer than Phoenix's manual `Used` flags. The `TexturePool` owns all textures. Handles are indices. Dropping operators automatically releases textures.

### Adopt: Ping-Pong Multi-Pass Rendering

Expose `pass_count` in filter metadata. Allocate two render targets, swap each iteration:

```rust
pub struct Filter {
    pass_count: u8,
    shader: wgpu::ShaderModule,
    pipeline: wgpu::RenderPipeline,
}

impl Filter {
    pub fn render(
        &self,
        targets: &mut [Texture; 2],
        parents: &[&Texture],
        params: &[u8; 16],
    ) {
        for pass in 0..self.pass_count {
            targets.swap(0, 1);

            // Bind targets[0] as render target
            // Bind targets[1] as texture input (t0)
            // Bind parents as textures (t1-t3)
            // Upload pass index and params to constant buffer
            // Draw fullscreen quad
            // Generate mipmaps
        }
    }
}
```

This pattern accelerates iterative algorithms (blur, fractal noise, reaction-diffusion) without duplicating operator nodes.

### Adopt: Compact Parameter Encoding

Store parameters as `[u8; 16]` for serialization, normalize to `f32` in shaders:

```rust
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
pub struct ShaderParams {
    pass_data: [f32; 4],  // Pass index + 3 random values
    params: [[f32; 4]; 4], // 16 normalized parameters
}

impl ShaderParams {
    fn from_bytes(pass: u32, params: &[u8; 16]) -> Self {
        let mut shader_params = ShaderParams::default();
        shader_params.pass_data[0] = pass as f32;
        shader_params.pass_data[1..4].fill_with(|| rand::random());

        for (i, &byte) in params.iter().enumerate() {
            let row = i / 4;
            let col = i % 4;
            shader_params.params[row][col] = byte as f32 / 255.0;
        }

        shader_params
    }
}
```

This balances serialization size (16 bytes) with shader precision (enough for most visual parameters).

### Adopt: Texture Pooling with Handle-Based Lifetimes

Rust's type system enables safer pooling than Phoenix's manual flags:

```rust
pub struct TexturePool {
    textures: Vec<Option<wgpu::Texture>>,
}

#[derive(Copy, Clone)]
pub struct TextureHandle(usize);

impl TexturePool {
    pub fn allocate(&mut self, res: Resolution, hdr: bool) -> TextureHandle {
        // Search for matching unused slot
        for (i, slot) in self.textures.iter().enumerate() {
            if slot.is_none() {
                let texture = create_texture(res, hdr);
                self.textures[i] = Some(texture);
                return TextureHandle(i);
            }
        }

        // Allocate new slot
        let texture = create_texture(res, hdr);
        self.textures.push(Some(texture));
        TextureHandle(self.textures.len() - 1)
    }

    pub fn release(&mut self, handle: TextureHandle) {
        self.textures[handle.0] = None;
    }

    pub fn get_texture(&self, handle: TextureHandle) -> &wgpu::Texture {
        self.textures[handle.0].as_ref().unwrap()
    }
}
```

Handles are lightweight indices. The pool owns all textures. Releasing a handle sets the slot to `None`, making it available for reuse. No `Used` flags, no reference counting, no unsafe code.

### Modify: Use Compute Shaders for Some Filters

Phoenix uses fullscreen quad draws for all filters. A Rust framework should consider compute shaders for filters that don't need rasterization:

```rust
pub enum FilterExecution {
    Fragment {
        vertex_shader: wgpu::ShaderModule,
        fragment_shader: wgpu::ShaderModule,
    },
    Compute {
        compute_shader: wgpu::ShaderModule,
        workgroup_size: (u32, u32, u32),
    },
}
```

Noise generation, color adjustments, and mathematical transforms don't need vertex processing. Compute shaders dispatch directly to pixels, avoiding rasterization overhead. This matters more for large textures (2048×2048+) where memory bandwidth dominates.

### Modify: Support WGSL and SPIR-V

Phoenix uses HLSL compiled to D3D11 bytecode. A Rust framework targeting cross-platform should use WGSL (WebGPU Shading Language) or SPIR-V:

```rust
pub struct Filter {
    shader_source: ShaderSource,
    // ...
}

pub enum ShaderSource {
    Wgsl(&'static str),
    SpirV(&'static [u8]),
}
```

WGSL provides readable source code. SPIR-V provides compact binary representation for size-constrained builds. The framework can compile WGSL to SPIR-V at build time, embedding the binary in the executable.

### Modify: Strongly Typed Resolution

Instead of packed bytes, use a struct:

```rust
#[derive(Copy, Clone, PartialEq, Eq)]
pub struct Resolution {
    pub width: u32,
    pub height: u32,
}

impl Resolution {
    pub fn from_packed(byte: u8) -> Self {
        Resolution {
            width: 1 << (byte >> 4),
            height: 1 << (byte & 0x0f),
        }
    }

    pub fn to_packed(self) -> Option<u8> {
        if !self.width.is_power_of_two() || !self.height.is_power_of_two() {
            return None;
        }
        let w_exp = self.width.trailing_zeros() as u8;
        let h_exp = self.height.trailing_zeros() as u8;
        Some((w_exp << 4) | h_exp)
    }
}
```

This maintains compatibility with Phoenix's packed format while providing type safety and clear semantics.

### Avoid: Global Mutable State

Phoenix uses global `TextureOperators` and `TexgenPool` pointers. Rust should encapsulate state in owned structs:

```rust
pub struct TexgenContext {
    filters: Vec<Filter>,
    operators: Vec<Operator>,
    pool: TexturePool,
}

impl TexgenContext {
    pub fn generate(&mut self, operator_id: OperatorId) -> &Texture {
        let op_idx = operator_id as usize;
        self.operators[op_idx].generate(&self.filters, &mut self.operators, &mut self.pool)
    }
}
```

This enables multiple independent texgen contexts, simplifies testing (no global reset), and eliminates data races (each context owns its state).

### Avoid: Allocating Lookup Textures Every Pass

Phoenix creates and destroys lookup textures every pass. A Rust framework should cache lookup textures:

```rust
pub struct Filter {
    lookup_cache: Option<Texture>,
    // ...
}

impl Filter {
    fn get_lookup_texture(&mut self, res: Resolution, seed: u8) -> Option<&Texture> {
        if self.lookup_cache.is_none() {
            self.lookup_cache = Some(generate_lookup(res, seed));
        }
        self.lookup_cache.as_ref()
    }
}
```

This eliminates per-pass allocation overhead. The lookup texture persists across multiple operator evaluations if the filter is reused.

## Related Documents

This pipeline document covers the complete data flow from operator graph to GPU output. For detailed coverage of specific subsystems, see:

- **[overview.md](overview.md)** — Texgen system architecture, mental models, operator graph representation
- **operators.md** — Per-operator parameter layouts, filter assignments, resolution strategies
- **shaders.md** — HLSL shader patterns, constant buffer usage, texture sampling techniques
- **generators.md** — Noise algorithms (Perlin, Voronoi), gradient generation, tile patterns

For implementation traces with source references:

- **code-traces/noise-generation.md** — Perlin noise with hash lookup, multi-octave iteration
- **code-traces/operator-evaluation.md** — Full walkthrough of `Generate()` recursion and caching
- **code-traces/multi-pass-blur.md** — Separable Gaussian blur implementation

Cross-system integration:

- **[../rendering/materials.md](../rendering/materials.md)** — How materials reference texgen operators for albedo/normal/roughness maps
- **[../rendering/shaders.md](../rendering/shaders.md)** — Material shaders sampling procedural textures

## Source File Reference

All source paths are relative to `demoscene/apex-public/apEx/Phoenix/`.

| File | Lines | Key Functions | Purpose |
|------|-------|---------------|---------|
| **Texgen.h** | 157 | Struct definitions (66-149) | Data structures for operators, filters, subroutines, pool |
| **Texgen.cpp** | 528 | `Generate()` (464-497), `Render()` (120-185) | Core pipeline implementation |
| **Texgen.cpp** | 528 | `GetTexture()` (67-87), `Create()` (18-64) | Texture pool management |
| **Texgen.cpp** | 528 | `GetLookupTexture()` (205-346) | Auxiliary texture generation (image, text, spline, hash) |
| **Texgen.cpp** | 528 | `Subroutine::Generate()` (502-527) | Reusable subgraph execution |
| **Texgen.cpp** | 528 | `Prepare2dRender()` (99-118), `SetSamplers()` (92-97) | Fixed pipeline state setup |

**Key Line References**:
- **Phase 1 - Cache check**: Texgen.cpp:466
- **Phase 1 - Parent recursion**: Texgen.cpp:471-479
- **Phase 2 - Render target allocation**: Texgen.cpp:482-483
- **Phase 3 - Prepare render state**: Texgen.cpp:99-118
- **Phase 4 - Multi-pass loop start**: Texgen.cpp:134
- **Phase 4 - Target swap**: Texgen.cpp:139-141
- **Phase 4 - Shader data setup**: Texgen.cpp:151-153
- **Phase 4 - Constant buffer upload**: Texgen.cpp:156-158
- **Phase 4 - Texture binding**: Texgen.cpp:162-169
- **Phase 4 - Draw call**: Texgen.cpp:172
- **Phase 4 - Mipmap generation**: Texgen.cpp:174
- **Phase 5 - Cleanup and cache**: Texgen.cpp:488-496
- **Pool search**: Texgen.cpp:69-77
- **Pool allocation**: Texgen.cpp:80-86
- **Texture creation**: Texgen.cpp:18-64
- **Lookup texture generation**: Texgen.cpp:205-346
- **Subroutine input injection**: Texgen.cpp:505-506
- **Subroutine resolution override**: Texgen.cpp:509-510
- **Subroutine parameter override**: Texgen.cpp:513-514

Phoenix's texgen pipeline demonstrates how graph-based procedural generation compresses megabytes of texture data into kilobytes of operators and shader code while maintaining real-time GPU performance. The architecture balances compact serialization, lazy evaluation, efficient memory pooling, and multi-pass rendering to create a system that fits within 64k executable constraints while generating rich, complex textures at runtime.
