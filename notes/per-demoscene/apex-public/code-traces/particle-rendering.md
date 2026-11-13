# Code Trace: Particle Rendering Pipeline

How does a bag of floats in a vertex buffer become glowing, dissolving, camera-facing sprites on screen? This trace follows the standard particle rendering path from `CreateRenderDataInstances()` through the GPU pipeline to final pixel output. We pick up where the simulation code trace (`particle-frame.md`) left off — the vertex buffer is filled, particles are sorted, and now the rendering system takes over.

The previous trace ended at `Scene.cpp:604` with `phxContext->Unmap(VertexBuffer, NULL)`. The vertex buffer contains `LiveCount` particles, each packed as 8 floats. This trace follows that data through material state assembly, render layer queuing, D3D11 draw call execution, and the full VS→GS→PS shader pipeline.

## Scenario

We trace an emitter with:

- **128 live particles** — `LiveCount = 128`
- **Standard billboard mode** — No `ObjectToEmit` or `SceneToEmit`
- **Single-pass material** — One technique, one pass, targeting Transparent Layer
- **Additive blend** — `SrcBlend=ONE, DstBlend=ONE` for fire/spark effect
- **Spline texture** — 11 rows (RGBA + size + 5 chaos + alpha test)
- **Sorting enabled** — Back-to-front depth ordering
- **Sprite texture** — Soft circle with noise alpha for dissolution

## Phase 1: Material State Assembly

### Step 1: Apply Material Splines

**Scene.cpp:610** — Evaluate material animation at current timeline position

```cpp
Clips[Clip]->MaterialSplines->ApplyToParameters(this);
```

The scene graph calls `CreateRenderDataInstances()` during its traversal. This is the first rendering-related call for this emitter in this frame. `ApplyToParameters()` iterates over all material splines that target parameters belonging to this emitter's grouping data, writing spline values into the material's parameter slots.

For our scenario, this updates animated parameters like overall tint color, blend mode, or any other material property driven by the timeline. Particle-specific lifetime curves are NOT evaluated here — those live in the spline texture, sampled per-pixel on the GPU.

**Result**: Material parameter values reflect current timeline position.

### Step 2: Collect Animated Data

**Scene.cpp:614-622** — Gather per-pass animated constants

```cpp
int passid = 0;
if (Material)
{
    for (int x = 0; x < Material->TechCount; x++)        // 1 technique
        for (int y = 0; y < Material->Techniques[x]->PassCount; y++)  // 1 pass
            Material->Techniques[x]->CollectAnimatedData(MaterialState[passid++], y);
}
```

**Material.cpp:168-179** — `CollectAnimatedData()` implementation

```cpp
void CphxMaterialTechnique::CollectAnimatedData(CphxMaterialPassConstantState *State, int Pass)
{
    CphxMaterialParameterBatch &techbatch = Parameters;
    int datasize = techbatch.CollectAnimatedData();

    CphxMaterialParameterBatch &passbatch = RenderPasses[Pass]->Parameters;
    int passdatasize = passbatch.CollectAnimatedData();

    memcpy(State->AnimatedData, techbatch.CollectedData, datasize * sizeof(float));
    memcpy(State->AnimatedData + datasize, passbatch.CollectedData,
           passdatasize * sizeof(float));
    State->AnimatedDataSize = (datasize + passdatasize) * sizeof(float);
}
```

This walks the technique-level and pass-level parameter batches, collecting all `PARAM_ANIMATED` values into a flat float array. These animated values are separate from constant values (which were baked at material creation time). The two arrays get concatenated into the material constant buffer during rendering.

For our particle material, animated data might include an overall brightness multiplier or a blend fade-in value.

**Result**: `MaterialState[0]->AnimatedData` contains the animated floats for pass 0.

### Step 3: Override Texture Slot 0

**Scene.cpp:624-625** — Force spline texture into slot 0

```cpp
for (int x = 0; x < passid; x++)
    MaterialState[x]->Textures[0] = SplineTextureView;
```

This is the critical connection between the particle system and the material system. Whatever texture the material originally assigned to slot 0 gets replaced with the emitter's spline texture — the 2048×11 R32_FLOAT texture containing all lifetime-driven curves.

The particle shader expects this layout:
- **t0 (register 0)**: Spline curve texture (11 rows of lifetime data)
- **t1 (register 1)**: Particle sprite texture (assigned by material PARAM_TEXTURE1)

**Result**: `MaterialState[0]->Textures[0]` points to the emitter's `SplineTextureView`.

### Step 4: Branch to Standard Particles

**Scene.cpp:628-642** — Select rendering path

```cpp
if (!ObjectToEmit && !SceneToEmit)
{
    Material->CreateRenderDataInstances(MaterialState, RootScene, VertexBuffer, LiveCount);
}
```

Neither `ObjectToEmit` nor `SceneToEmit` is set, so we take the standard billboard path. The call passes:
- `MaterialState`: Array of per-pass constant state (textures, blend states, animated data)
- `RootScene`: The scene that owns the render layers
- `VertexBuffer`: The D3D11 buffer filled during `UpdateParticles()`
- `LiveCount`: 128 (number of point primitives to draw)

### Step 5: Create Render Data Instance

**Material.cpp:204-209** — Particle-specific overload

```cpp
void CphxMaterial::CreateRenderDataInstances(
    CphxMaterialPassConstantState **State,
    CphxScene *RootScene,
    ID3D11Buffer *VxBuffer,
    int VertexCount)
{
    int passid = 0;
    for (int x = 0; x < TechCount; x++)
        Techniques[x]->CreateRenderDataInstances(
            State, passid, RootScene,
            VxBuffer, NULL, NULL,    // VB only, no IB, no wireframe
            VertexCount, 0,          // LiveCount, 0 wire indices
            NULL,                    // no tool data
            false);                  // Indexed = false
}
```

**Material.cpp:117-166** — Core render instance creation

```cpp
void CphxMaterialTechnique::CreateRenderDataInstances(
    CphxMaterialPassConstantState **MaterialState, int &passid,
    CphxScene *RootScene, ID3D11Buffer *VertexBuffer,
    ID3D11Buffer *IndexBuffer, ID3D11Buffer *WireBuffer,
    int VertexCount, int IndexCount, void *ToolData, bool Indexed)
{
    for (int x = 0; x < PassCount; x++)  // 1 pass
    {
        CphxRenderDataInstance *ri = new CphxRenderDataInstance();

        ri->VertexBuffer = VertexBuffer;   // particle VB
        ri->IndexBuffer = NULL;
        ri->WireBuffer = NULL;
        ri->TriIndexCount = VertexCount;   // 128 (LiveCount)
        ri->WireIndexCount = 0;
        ri->ToolData = NULL;
        ri->Indexed = false;               // KEY: triggers particle path

        ri->Wireframe = MaterialState[passid]->Wireframe;
        ri->RenderPriority = MaterialState[passid]->RenderPriority;  // 127

        // Copy shader pointers (VS, PS, GS, HS, DS) via memcpy
        memcpy(&ri->VS, &RenderPasses[x]->VS, sizeof(void*) * 5);

        // Copy render state (BlendState, RasterizerState, DepthStencilState,
        //                     Textures[0..7]) via memcpy
        memcpy(&ri->BlendState, &MaterialState[passid]->BlendState,
               sizeof(void*) * 11);

        // Copy constant + animated material data to inline float array
        int constdatasize = MaterialState[passid]->ConstantDataSize;
        int dyndatasize = MaterialState[passid]->AnimatedDataSize;
        memcpy(ri->MaterialData, MaterialState[passid]->ConstantData,
               constdatasize);
        memcpy(ri->MaterialData + constdatasize / sizeof(float),
               MaterialState[passid]->AnimatedData, dyndatasize);

        // Store world matrix and inverse-transpose world matrix
        ri->Matrices[0] = phxWorldMatrix;
        ri->Matrices[1] = phxITWorldMatrix;

        // Add to render layer queue
        RootScene->AddRenderDataInstance(TargetLayer, ri);

        passid++;
    }
}
```

This is where the render instance gets fully populated. Key observations:

1. **`Indexed = false`**: This single boolean controls the entire particle rendering path in `RenderLayer.cpp`. It switches input layout, topology, and draw call type.

2. **`TriIndexCount = 128`**: Despite the name, this holds `LiveCount` for particles. It becomes the vertex count argument to `Draw()`.

3. **Memcpy for shader/state assignment**: The code uses raw memcpy instead of individual assignments. The `WARNING!` comments in `RenderLayer.h` emphasize that field order must not change because of this.

4. **`TargetLayer`**: Points to the Transparent Layer descriptor, set at material technique creation time.

### Step 6: Queue in Render Layer

**Scene.cpp:205-213** — `AddRenderDataInstance()`

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

The render instance gets appended to the Transparent Layer's instance list. It will execute after the Shadow, Solid, and Lighting layers have completed.

**Result**: One `CphxRenderDataInstance` queued in the Transparent Layer with:
- Particle vertex buffer (128 particles × 32 bytes)
- `Indexed = false`
- `TriIndexCount = 128`
- Vertex/geometry/pixel shaders from default-particle.hlsl
- Additive blend state
- Textures: [0] = spline curves, [1] = sprite
- World matrix, material constants

## Phase 2: Draw Call Execution

When the Transparent Layer executes, it iterates over all queued render instances and calls `Render()` on each.

### Step 7: Configure Input Assembler

**RenderLayer.cpp:27-53** — `CphxRenderDataInstance::Render()`

```cpp
void CphxRenderDataInstance::Render()
{
    if (!VS || !PS) return;
    if (!VertexBuffer) return;

    unsigned int offset = 0;
    unsigned int stride = PHXVERTEXFORMATSIZE;  // default mesh stride

    // Particle branch: Indexed == false
    phxContext->IASetInputLayout(ParticleVertexFormat);  // vxdecl3
    stride = 4 * 2 * 4;  // 32 bytes

    phxContext->IASetVertexBuffers(0, 1, &VertexBuffer, &stride, &offset);
    phxContext->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_POINTLIST);
```

Three D3D11 calls configure the input assembler:

1. **Input layout** → `ParticleVertexFormat` (created from `vxdecl3` at init time):
   - Element 0: `POSITION0`, `R32G32B32A32_FLOAT`, offset 0 (bytes 0-15)
   - Element 1: `TEXCOORD0`, `R32G32B32A32_FLOAT`, offset 16 (bytes 16-31)

2. **Vertex buffer** bound with stride 32 (two float4s per vertex)

3. **Topology** → `POINTLIST` — each vertex is an independent point primitive

### Step 8: Set Shaders and State

**RenderLayer.cpp:55-62** — Bind pipeline state

```cpp
    phxContext->VSSetShader(VS, NULL, 0);      // default-particle.hlsl VertexMain
    phxContext->GSSetShader(GS, NULL, 0);      // default-particle.hlsl GeometryMain
    phxContext->HSSetShader(HS, NULL, 0);      // NULL (no tessellation)
    phxContext->DSSetShader(DS, NULL, 0);      // NULL (no tessellation)
    phxContext->PSSetShader(PS, NULL, 0);      // default-particle.hlsl PixelMain
    phxContext->RSSetState(RasterizerState);    // solid fill, back-cull
    phxContext->OMSetBlendState(BlendState, NULL, 0xffffffff);  // additive
    phxContext->OMSetDepthStencilState(DepthStencilState, 0);   // read, no write
```

The shader pipeline is fully set: VS → GS → PS (no tessellation). The GS is critical — it expands each point into a quad. Without it, particles would render as single-pixel dots.

### Step 9: Upload Matrices and Material Data

**RenderLayer.cpp:64-68** — Write per-object constant buffer

```cpp
    D3D11_MAPPED_SUBRESOURCE map;
    phxContext->Map(ObjectMatrixBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &map);
    memcpy(map.pData, Matrices, 16 * 2 * 4);  // 2 matrices × 64 bytes
    memcpy(((unsigned char*)map.pData) + sizeof(Matrices),
           MaterialData, MATERIALDATASIZE);     // material constants
    phxContext->Unmap(ObjectMatrixBuffer, 0);
```

The constant buffer (register b1) gets the world matrix, inverse-transpose world matrix, and material data. For the particle shader, this includes:
- `worldMatrix` — emitter's world transform (identity if emitter is at origin)
- `invTransWorldMatrix` — inverse transpose (unused for particles)
- `color` — overall tint color (from material PARAM_COLOR)
- `alphaTest` — global alpha threshold (from material PARAM_FLOAT, unused here since per-particle alpha test comes from the spline texture)

### Step 10: Bind Textures

**RenderLayer.cpp:83-86** — Set shader resource views

```cpp
    phxContext->VSSetShaderResources(0, 8, Textures);
    phxContext->GSSetShaderResources(0, 8, Textures);
    phxContext->PSSetShaderResources(0, 8, Textures);
```

All 8 texture slots are bound to all shader stages. For particles:
- **Slot 0 (t0)**: Spline curve texture (2048×11, R32_FLOAT) — used by VS for `SampleCurve()`
- **Slot 1 (t1)**: Sprite texture (256×256, RGBA8) — used by PS for sprite sampling
- **Slots 2-7**: Available for custom particle shaders

Note that textures are bound to VS, GS, and PS simultaneously. The VS reads the spline texture for curve sampling. The PS reads the sprite texture. The GS doesn't sample textures in the default shader, but binding them is harmless.

### Step 11: Execute Draw Call

**RenderLayer.cpp:99** — Non-indexed draw

```cpp
    phxContext->Draw(TriIndexCount, 0);  // Draw(128, 0)
```

This dispatches 128 point primitives through the pipeline. Each point invokes:
- 1 vertex shader execution
- 1 geometry shader execution (produces 4 vertices, 2 triangles)
- N pixel shader executions (depending on quad screen coverage)

Total GPU work for 128 particles:
- 128 VS invocations
- 128 GS invocations
- 128 × 4 = 512 output vertices
- 128 × 2 = 256 triangles
- ~128 × (average_particle_size²) pixel shader invocations

## Phase 3: Shader Execution

### Step 12: Vertex Shader — Curve Sampling

**default-particle.hlsl:128-150** — `VertexMain()`

For each of the 128 particles, the vertex shader executes:

```hlsl
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // Transform world position to view space
    // input.position = float4(px, py, pz, 1.0) from vertex buffer
    output.position = mul(viewMatrix, input.position);
    // Result: camera-relative position where Z = depth, X/Y = screen axes

    output.data = input.data;
    // Pass through: float4(lifetime, rotation, chaos, 0)

    float lifetime = input.data.x;  // e.g., 0.35 (35% through life)
    float seed = input.data.z;      // e.g., 0.72 (random per-particle)
```

**Curve sampling** (11 texture reads per vertex):

```hlsl
    // Base curve + chaos curve for each color channel
    output.color.r = SampleCurveWithChaos(0, 5, seed, lifetime);
    //   → SampleCurve(0, 0.35) + SampleCurve(5, 0.35) * GetNoise(0.72 + 5)
    //   → base_red + chaos_red * hash(5.72)

    output.color.g = SampleCurveWithChaos(1, 6, seed, lifetime);
    output.color.b = SampleCurveWithChaos(2, 7, seed, lifetime);
    output.color.a = SampleCurveWithChaos(3, 8, seed, lifetime);

    output.size = SampleCurveWithChaos(4, 9, seed, lifetime);
    //   → base_size + chaos_size * hash(9.72)

    output.alphaTest = SampleCurve(10, lifetime);
    //   → pure lookup, no chaos. Alpha test is deterministic per-lifetime.
```

Each `SampleCurve()` performs two `Load()` operations and a `lerp`:

```hlsl
float SampleCurve(int curveId, float lifetime)
{
    float t = 1 - lifetime;  // Reverse direction
    float a = curveTexture.Load(int3(trunc(t * 2048), curveId, 0)).x;
    float b = curveTexture.Load(int3(trunc(t * 2048) + 1, curveId, 0)).x;
    return lerp(a, b, frac(t * 2048));
}
```

For `SampleCurveWithChaos()`, two additional `Load()` operations and one `GetNoise()` (sin + frac).

**Total per vertex**: 22 texture loads + 11 lerps + 5 sin/frac operations for noise.

**Result**: View-space position, RGBA color (with per-particle chaos variation), size (with chaos), and alpha test threshold.

### Step 13: Geometry Shader — Quad Expansion

**default-particle.hlsl:158-198** — `GeometryMain()`

For each input point, the GS produces 4 vertices forming a triangle strip:

```hlsl
[maxvertexcount(4)]
void GeometryMain(point VertexOutput input[1],
                  inout TriangleStream<GeometryOutput> outputStream)
{
    float4 center = input[0].position;    // view-space position
    float4 scale = 0.1 * input[0].size.x; // world units (e.g., 0.1 * 2.5 = 0.25)
```

**Rotation axes** (2D rotation in screen plane):

```hlsl
    float rotation = 0.1 * input[0].data.y;  // scale rotation value
    float4 xAxis = float4(sin(rotation), cos(rotation), 0, 0);
    float4 yAxis = float4(-xAxis.y, xAxis.x, 0, 0);
```

If rotation = 0: xAxis = (0,1,0,0), yAxis = (-1,0,0,0) — upright quad.
If rotation = π/2: xAxis = (1,0,0,0), yAxis = (0,1,0,0) — 90° rotated.

**Corner positions** (view space → clip space):

```hlsl
    verts[0].position = mul(projectionMatrix, center + (-xAxis - yAxis) * scale);
    // Bottom-left: center shifted left and down, then projected

    verts[1].position = mul(projectionMatrix, center + (xAxis - yAxis) * scale);
    // Bottom-right: center shifted right and down, then projected

    verts[2].position = mul(projectionMatrix, center + (xAxis + yAxis) * scale);
    // Top-right: center shifted right and up, then projected

    verts[3].position = mul(projectionMatrix, center + (-xAxis + yAxis) * scale);
    // Top-left: center shifted left and up, then projected
```

**UV assignment** and data broadcast:

```hlsl
    verts[0].texCoord = float2(1, 1);  // bottom-left → UV bottom-right
    verts[1].texCoord = float2(1, 0);  // bottom-right → UV top-right
    verts[2].texCoord = float2(0, 0);  // top-right → UV top-left
    verts[3].texCoord = float2(0, 1);  // top-left → UV bottom-left

    for (int i = 0; i < 4; i++)
    {
        verts[i].data = input[0].data;       // same particle data for all 4
        verts[i].color = input[0].color;     // same RGBA for all 4
        verts[i].alphaTest = input[0].alphaTest; // same threshold for all 4
    }
```

**Triangle strip output** (Z pattern for proper winding):

```hlsl
    outputStream.Append(verts[3]);  // top-left
    outputStream.Append(verts[0]);  // bottom-left
    outputStream.Append(verts[2]);  // top-right
    outputStream.Append(verts[1]);  // bottom-right
    outputStream.RestartStrip();
```

This produces two triangles:
- Triangle 1: (top-left, bottom-left, top-right) — left half of quad
- Triangle 2: (bottom-left, top-right, bottom-right) — right half of quad

**Result**: 4 clip-space vertices with interpolated UV, color, and alpha test.

### Step 14: Rasterization

The rasterizer processes 256 triangles (128 particles × 2 triangles each):

1. **Clip**: Discard triangles fully outside the frustum. Clip triangles partially outside.
2. **Viewport transform**: Map clip-space coordinates to screen pixels.
3. **Face culling**: Back-face cull based on rasterizer state. Triangle strip winding ensures front faces.
4. **Fragment generation**: Generate one fragment per covered pixel.
5. **Attribute interpolation**: Linearly interpolate UV coordinates across each triangle. Color, data, and alphaTest are constant across the quad (same value at all 4 corners), so interpolation is free.

### Step 15: Pixel Shader — Texture and Dissolve

**default-particle.hlsl:203-212** — `PixelMain()`

For each rasterized fragment:

```hlsl
float4 PixelMain(GeometryOutput v) : SV_TARGET0
{
    // Sample sprite texture at interpolated UV
    float4 texColor = particleTexture.Sample(linearSampler, v.texCoord);
    // Result: RGBA from sprite (e.g., soft circle with noise alpha)

    // Dynamic alpha test: compare sprite alpha to lifetime threshold
    if (texColor.w < v.alphaTest)
        discard;
    // Young particle (alphaTest ≈ 0.0): almost all pixels pass
    // Old particle (alphaTest ≈ 0.9): only high-alpha pixels survive
    // Effect: particle erodes/dissolves as it ages

    // Multiply sprite color by lifetime-driven tint
    return v.color * texColor;
    // v.color = from VS curve sampling (fire orange, fading to dark red)
    // texColor = from sprite (white circle with alpha gradient)
    // Result: tinted, shaped particle fragment
}
```

**Discard behavior**: When `texColor.w < v.alphaTest`, the fragment is killed. The GPU skips the output merger entirely for this pixel. On some architectures, any shader using `discard` disables early-Z optimizations for the entire draw call. For particles with depth-write disabled, this doesn't matter.

**Result**: `SV_TARGET0` = `float4(r, g, b, a)` — the particle's final color at this pixel.

### Step 16: Output Merger — Blend and Depth

The output merger applies the configured blend and depth states:

**Depth test** (read only):
```
if (fragment.z < depthBuffer[pixel].z)
    pass; // particle is in front of solid geometry
else
    discard; // particle is behind solid geometry
```

**No depth write**: `DepthWriteMask = ZERO`. The depth buffer is not modified. Particles don't occlude each other through depth.

**Additive blend**:
```
RenderTarget[pixel] = RenderTarget[pixel] + fragment.rgba;
// SrcBlend = ONE, DestBlend = ONE
// Each particle adds to whatever was already in the framebuffer
```

For our fire effect: overlapping particles produce brighter regions. The edges glow where many particles overlap. The center burns white-hot. This is physically intuitive — more emitters = more light.

**Result**: The Main Render Target accumulates the particle's color additively over the lit scene from the deferred pipeline.

## Summary: Full Call Chain

```
CphxObject_ParticleEmitter_CPU::CreateRenderDataInstances()
  ├─ Scene.cpp:610    MaterialSplines->ApplyToParameters()
  ├─ Scene.cpp:619-621 CollectAnimatedData() → Material.cpp:168
  ├─ Scene.cpp:624-625 Textures[0] = SplineTextureView
  └─ Scene.cpp:641    Material->CreateRenderDataInstances()
       └─ Material.cpp:204-209 (particle overload)
            └─ Material.cpp:117-166 CreateRenderDataInstances(Indexed=false)
                 ├─ new CphxRenderDataInstance()
                 ├─ memcpy(shaders)  — VS, PS, GS, HS, DS
                 ├─ memcpy(states)   — blend, rasterizer, depth, textures
                 ├─ memcpy(data)     — matrices, material constants
                 └─ AddRenderDataInstance(TargetLayer, ri)
                      └─ Scene.cpp:207-210 RenderLayers[x]->Add(ri)

--- Later, during layer execution ---

CphxRenderDataInstance::Render()
  ├─ RenderLayer.cpp:42  IASetInputLayout(ParticleVertexFormat)
  ├─ RenderLayer.cpp:43  stride = 32
  ├─ RenderLayer.cpp:47  IASetVertexBuffers()
  ├─ RenderLayer.cpp:52  IASetPrimitiveTopology(POINTLIST)
  ├─ RenderLayer.cpp:55  VSSetShader(VertexMain)
  ├─ RenderLayer.cpp:56  GSSetShader(GeometryMain)
  ├─ RenderLayer.cpp:59  PSSetShader(PixelMain)
  ├─ RenderLayer.cpp:60  RSSetState()
  ├─ RenderLayer.cpp:61  OMSetBlendState(additive)
  ├─ RenderLayer.cpp:62  OMSetDepthStencilState(read, no write)
  ├─ RenderLayer.cpp:65  Map(ObjectMatrixBuffer)
  ├─ RenderLayer.cpp:66  memcpy(matrices)
  ├─ RenderLayer.cpp:67  memcpy(materialData)
  ├─ RenderLayer.cpp:68  Unmap()
  ├─ RenderLayer.cpp:83  VSSetShaderResources(textures[0..7])
  ├─ RenderLayer.cpp:84  GSSetShaderResources(textures[0..7])
  ├─ RenderLayer.cpp:85  PSSetShaderResources(textures[0..7])
  └─ RenderLayer.cpp:99  Draw(128, 0)

--- GPU pipeline ---

VertexMain (×128)
  ├─ mul(viewMatrix, position)      → view-space position
  ├─ SampleCurveWithChaos(0-4, 5-9) → RGBA + size (22 texture loads)
  └─ SampleCurve(10)                → alpha test threshold

GeometryMain (×128)
  ├─ Compute rotation axes          → sin/cos
  ├─ 4 × mul(projectionMatrix, ...) → 4 clip-space corners
  └─ Append triangle strip          → 4 vertices, 2 triangles

PixelMain (×N pixels)
  ├─ Sample(spriteTexture, UV)      → sprite color + alpha
  ├─ if (alpha < threshold) discard → dissolution
  └─ return color * texColor        → final RGBA

OutputMerger (×N pixels)
  ├─ Depth test (read)              → occlusion by solid geometry
  └─ Additive blend                 → accumulate into Main RT
```

## Timing Profile (Estimated)

For 128 particles at 1080p with average ~16×16 pixel quads:

| Stage | Work | Approx Cost |
|-------|------|-------------|
| CPU: CreateRenderDataInstances | 1 allocation, 3 memcpy | ~5 μs |
| CPU: Render() setup | 14 D3D11 calls | ~10 μs |
| GPU: VS | 128 × 22 texture loads | ~5 μs |
| GPU: GS | 128 × 4 projections | ~3 μs |
| GPU: Raster | 256 triangles | ~1 μs |
| GPU: PS | 128 × 256 pixels avg | ~8 μs |
| GPU: OM | 128 × 256 blends | ~2 μs |
| **Total** | | **~34 μs** |

The particle system is well within frame budget for 128 particles. At 2048 particles, the VS texture load cost dominates (~80 μs for 45,056 texture loads), but remains practical. The single draw call keeps CPU overhead constant regardless of particle count.

## Related Documents

- **[particle-frame.md](particle-frame.md)** — Simulation trace (picks up where this trace begins)
- **[../particles/rendering.md](../particles/rendering.md)** — Rendering concepts and architecture
- **[../particles/overview.md](../particles/overview.md)** — System overview
- **[../rendering/deferred.md](../rendering/deferred.md)** — Transparent layer in deferred pipeline
- **[pbr-pipeline.md](pbr-pipeline.md)** — Standard mesh rendering trace (compare with particle path)
