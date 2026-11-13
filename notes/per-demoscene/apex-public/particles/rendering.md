# Particle Rendering: From Vertex Buffer to Pixels

> How a bag of floats becomes a million dancing sparks on screen

You've traced the particle lifecycle from spawn through simulation to GPU buffer upload. The vertex buffer sits in VRAM, packed with 8 floats per particle: position, lifetime, rotation, chaos. Now what? This document follows that data through three distinct rendering paths — billboard quads, instanced meshes, and recursive subscenes — revealing how Phoenix turns simulation output into final pixels within its deferred rendering pipeline.

The rendering side of particles operates in a fundamentally different space than simulation. Simulation is CPU-bound, deterministic, frame-rate-independent. Rendering is GPU-bound, creative, and deeply entangled with the material system, shader pipeline, and compositing strategy. The simulation doesn't know or care what the particles look like. It produces positions and lifetimes. The rendering system transforms those abstract quantities into visual properties: color gradients driven by lifetime curves, sizes that swell and shrink, rotation angles that spin sprites, alpha thresholds that dissolve dying particles into nothing.

This separation is what makes the system elegant. Change the material and the same explosion becomes fire, snow, or sparks. Change the spline curves and particles fade differently, shrink differently, color-shift differently. The simulation data — position, velocity, lifetime — is the skeleton. The rendering system is the skin, the clothes, the personality.

## The Three Rendering Modes

Phoenix supports three distinct particle rendering paths, selected per-emitter at scene setup time.

### Standard Particles (Billboard Quads)

The primary mode. Each particle becomes a camera-facing quad expanded from a point vertex by the geometry shader. This is the classic particle rendering approach: fill a vertex buffer with point positions, let the GS expand each point into a rotated quad, texture it with a sprite, and tint it with lifetime-driven colors.

**Activation**: When neither `ObjectToEmit` nor `SceneToEmit` is set. The emitter has a `Material` and `VertexBuffer`.

**Pipeline**: Point topology → Vertex Shader → Geometry Shader → Pixel Shader

**Draw call count**: One. All particles render in a single non-indexed `Draw()` call. This is the most efficient path.

### Mesh Particles

Each live particle spawns a mesh instance at its position with lifetime-driven scale and rotation. Instead of a flat billboard, you get full 3D geometry — cubes, spheres, custom models — rotating and scaling as particles age.

**Activation**: When `ObjectToEmit` is set (a `CphxModel` pointer).

**Pipeline**: Standard mesh rendering with per-particle transform matrices.

**Draw call count**: One per live particle per material pass. A 256-particle emitter with a two-pass material generates 512 draw calls. This is expensive.

### Subscene Particles

The most powerful and expensive mode. Each live particle evaluates an entire scene graph — with its own objects, materials, and animations — at the particle's position. Lifetime maps to the subscene's animation time, so a particle dying over 2 seconds plays 2 seconds of the subscene's timeline.

**Activation**: When `SceneToEmit` is set (a `CphxScene` pointer).

**Pipeline**: Full scene traversal per particle. Each subscene object generates its own render instances.

**Draw call count**: Per-particle × per-subscene-object × per-material-pass. Potentially thousands.

## Standard Particle Pipeline: Deep Dive

### Vertex Buffer Layout

The CPU fills a D3D11 dynamic vertex buffer with 8 floats per particle during `UpdateParticles()`.

**Scene.cpp:582-601**

```cpp
float *Data = (float*)ms.pData;
for (int y = 0; y < LiveCount; y++)
{
    int idx = DistanceBuffer[y].Idx;  // sorted order
    D3DXVECTOR3 v = Particles[idx].Position + Particles[idx].Velocity * Ticks;
    Data[0] = v.x;         // Position X
    Data[1] = v.y;         // Position Y
    Data[2] = v.z;         // Position Z
    Data[3] = 1;           // W (homogeneous)
    Data[4] = Aging ? (Particles[idx].LifeLeft - Ticks) / (float)Particles[idx].MaxLife : 1;
    Data[5] = Particles[idx].Rotation + Particles[idx].RotationSpeed * Ticks;
    Data[6] = Particles[idx].Chaos;
    Data[7] = 0;           // Padding (was particle index, commented out)
    Data += 8;
}
```

The buffer uses `D3D11_MAP_WRITE_DISCARD`, which tells the driver to give us a fresh memory block rather than waiting for the GPU to finish reading the old one. This is the standard double-buffering pattern for dynamic vertex data.

Position is interpolated between the current physics state and the next tick using `Velocity * Ticks`, where `Ticks` is the fractional remainder after integer timestep consumption. This creates smooth motion at 60fps even though physics runs at 25fps.

Lifetime is normalized to [0, 1] where 0 means just born and 1 means about to die. This normalization is critical — it becomes the U coordinate for spline texture sampling in the shader.

### Input Layout Declaration

The vertex buffer's memory layout must match the GPU's input assembler expectations. This contract is defined by `vxdecl3`.

**phxEngine.cpp:130-134**

```cpp
static const D3D11_INPUT_ELEMENT_DESC vxdecl3[2] =
{
    { "Position", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 0,
      D3D11_INPUT_PER_VERTEX_DATA, 0 },
    { "Texcoord", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, sizeof(float) * 4,
      D3D11_INPUT_PER_VERTEX_DATA, 0 }
};
```

Two float4 elements, totaling 32 bytes per vertex. The first four floats map to `POSITION0` (xyz position + w=1). The second four floats map to `TEXCOORD0` (lifetime, rotation, chaos, padding). This layout is deliberately minimal — just enough data for the shader to reconstruct full visual state from spline textures.

Compare with the standard mesh vertex layout `vxdecl2` (phxEngine.cpp:136-144), which has 6 elements: two position slots, normal, color, and two UV sets — 72 bytes per vertex. Particles use 32 bytes because they don't need normals (billboards face the camera), vertex colors (color comes from lifetime curves), or UV coordinates (the GS generates them).

### Input Assembler Configuration

When the render layer processes a particle render instance, `CphxRenderDataInstance::Render()` configures the input assembler differently for particles versus meshes.

**RenderLayer.cpp:27-53**

```cpp
void CphxRenderDataInstance::Render()
{
    unsigned int stride = PHXVERTEXFORMATSIZE;  // mesh default

    if (Indexed)
        phxContext->IASetInputLayout(RenderVertexFormat);
    else
    {
        phxContext->IASetInputLayout(ParticleVertexFormat);  // vxdecl3
        stride = 4 * 2 * 4;  // 32 bytes: two float4s
    }

    phxContext->IASetVertexBuffers(0, 1, &VertexBuffer, &stride, &offset);
    phxContext->IASetPrimitiveTopology(
        Wireframe ? D3D11_PRIMITIVE_TOPOLOGY_LINELIST
                  : D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

    if (!Indexed)
        phxContext->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_POINTLIST);
```

The `Indexed` flag is the discriminator. Standard meshes set `Indexed = true` and use triangle lists with an index buffer. Particles set `Indexed = false`, which triggers three changes:

1. **Input layout**: Switches from `RenderVertexFormat` (72-byte mesh vertices) to `ParticleVertexFormat` (32-byte particle vertices)
2. **Stride**: Changes from `PHXVERTEXFORMATSIZE` to 32 bytes
3. **Topology**: Overrides to `POINTLIST` — each vertex is a standalone point

The topology override is key. Triangle list expects vertices in groups of three. Point list treats each vertex independently. The geometry shader then expands each point into a quad.

### Draw Call Execution

**RenderLayer.cpp:90-100**

```cpp
if (Indexed)
{
    if (Wireframe ? WireIndexCount : TriIndexCount)
        phxContext->DrawIndexed(Wireframe ? WireIndexCount : TriIndexCount, 0, 0);
}
else
    phxContext->Draw(TriIndexCount, 0);  // particles: TriIndexCount = LiveCount
```

Particles use `Draw()` instead of `DrawIndexed()`. The `TriIndexCount` field is reused to hold `LiveCount` — the number of live particles. Despite the misleading field name, for particles it means "number of point primitives to draw." One draw call renders all particles. This is the efficiency advantage of billboard particles: the entire system is a single draw call regardless of particle count.

## Spline Texture System

The spline texture is one of Phoenix's most elegant compression tricks. Instead of uploading per-particle material parameters each frame, the system bakes all lifetime-driven curves into a 2D texture at material creation time. The shader samples this texture using particle lifetime as the lookup coordinate.

### Texture Creation

**Scene.cpp:726-775 (UpdateSplineTexture)**

```cpp
void CphxObject_ParticleEmitter_CPU::UpdateSplineTexture()
{
    // Count PARTICLELIFEFLOAT splines
    int splinecnt = 0;
    for (int x = 0; x < Clips[0]->MaterialSplines->SplineCount; x++)
    {
        CphxMaterialSpline *s = Clips[0]->MaterialSplines->Splines[x];
        if (s->Target->Type == PARAM_PARTICLELIFEFLOAT) splinecnt++;
    }

    // Sample each spline at 2048 points
    splinecnt = 0;
    for (int x = 0; x < Clips[0]->MaterialSplines->SplineCount; x++)
    {
        CphxMaterialSpline *s = Clips[0]->MaterialSplines->Splines[x];
        if (s->Target->Type == PARAM_PARTICLELIFEFLOAT)
        {
            for (int z = 0; z < 2048; z++)
            {
                s->Splines[0]->CalculateValue(z / 2048.0f);
                texturedata[z + splinecnt * 2048] = s->Splines[0]->Value[0];
            }
            splinecnt++;
        }
    }

    // Create R32_FLOAT texture: 2048 × splinecnt
    D3D11_TEXTURE2D_DESC tex = {
        2048, splinecnt, 1, 1,
        DXGI_FORMAT_R32_FLOAT,
        1, 0,
        D3D11_USAGE_DEFAULT,
        D3D11_BIND_SHADER_RESOURCE,
        0, 0
    };
    D3D11_SUBRESOURCE_DATA data = { texturedata, 2048 * 4, 0 };
    phxDev->CreateTexture2D(&tex, &data, &SplineTexture);
    phxDev->CreateShaderResourceView(SplineTexture, NULL, &SplineTextureView);
}
```

The texture is 2048 pixels wide (one pixel per lifetime sample) and N rows tall (one row per `PARAM_PARTICLELIFEFLOAT` parameter). The format is `R32_FLOAT` — single-channel 32-bit float — because each spline produces a single scalar value per sample point.

### Row-to-Parameter Mapping

The rows are ordered by their position in the material's spline list. Based on the shader's `SampleCurve()` and `SampleCurveWithChaos()` call patterns:

| Row | Parameter | Usage |
|-----|-----------|-------|
| 0 | Red channel | Base color R component |
| 1 | Green channel | Base color G component |
| 2 | Blue channel | Base color B component |
| 3 | Alpha channel | Base opacity |
| 4 | Size | Billboard quad scale |
| 5 | Red chaos | Per-particle R variation |
| 6 | Green chaos | Per-particle G variation |
| 7 | Blue chaos | Per-particle B variation |
| 8 | Alpha chaos | Per-particle opacity variation |
| 9 | Size chaos | Per-particle size variation |
| 10 | Alpha test | Dynamic dissolution threshold |

Eleven rows total, each 2048 texels. That's `2048 × 11 × 4 bytes = 90,112 bytes` — about 88 KB per emitter. This is far smaller than encoding per-particle colors and sizes individually.

### Why Load() Instead of Sample()?

The shader reads the spline texture using `Load()` (integer coordinate addressing) rather than `Sample()` (hardware-filtered texture sampling).

**default-particle.hlsl:94-103**

```hlsl
float SampleCurve(int curveId, float lifetime)
{
    float t = 1 - lifetime;  // Reverse: 0 at death, 1 at birth

    float a = curveTexture.Load(int3(trunc(t * 2048), curveId, 0)).x;
    float b = curveTexture.Load(int3(trunc(t * 2048) + 1, curveId, 0)).x;

    return lerp(a, b, frac(t * 2048));
}
```

Three reasons:

1. **Exact row addressing**: `Sample()` with linear filtering would bleed between rows (parameters). A particle at the boundary between row 0 (Red) and row 1 (Green) would get a nonsensical blended value. `Load()` guarantees exact integer row selection.

2. **Custom interpolation**: The shader implements its own linear interpolation using `lerp(a, b, frac())`. This gives identical results to hardware bilinear filtering along the X axis while maintaining exact integer addressing on Y. The code could use point filtering with `Sample()`, but `Load()` makes the integer-addressing intent explicit.

3. **Boundary safety**: At lifetime extremes (just born = 0, just dead = 1), hardware filtering might sample beyond the texture edges. `Load()` with explicit `trunc()` prevents out-of-bounds reads.

The `1 - lifetime` reversal is worth noting. The CPU writes lifetime as `LifeLeft / MaxLife`, where a fresh particle has lifetime near 1.0 and a dying particle has lifetime near 0.0. But the spline texture is sampled from left (birth) to right (death). The reversal maps particle lifetime to the correct curve position.

### Chaos Variation

**default-particle.hlsl:108-123**

```hlsl
float GetNoise(float seed)
{
    return frac(sin(seed * 54.37) * 17593.1317);
}

float SampleCurveWithChaos(int baseCurveId, int chaosCurveId, float seed, float lifetime)
{
    return SampleCurve(baseCurveId, lifetime) +
           SampleCurve(chaosCurveId, lifetime) * GetNoise(seed + chaosCurveId);
}
```

The chaos system adds per-particle variation to material parameters. Each particle carries a random `Chaos` value (0-1) assigned at spawn. The shader uses this as a seed for a hash function (`frac(sin(x * k1) * k2)`) that produces a deterministic pseudo-random number. This noise value scales the chaos curve, which is then added to the base curve.

The key insight is that `seed + chaosCurveId` varies the noise per parameter. Without the `chaosCurveId` offset, all chaos parameters (color R, G, B, alpha, size) would use the same random multiplier, and a particle with low red chaos would also have low green and blue chaos. Adding the curve ID decorrelates the randomness across parameters.

This is a classic demoscene trick: use a mathematical hash instead of a texture lookup or random number generator. The hash is deterministic (same seed always produces the same noise), stateless (no RNG state to maintain), and free (pure ALU, no memory access).

## Billboard Geometry Shader

The geometry shader is where a single point vertex becomes a visible quad on screen. This is the heart of standard particle rendering.

### Vertex Shader: Transform to View Space

**default-particle.hlsl:128-150**

```hlsl
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // Transform to view space (geometry shader will project)
    output.position = mul(viewMatrix, input.position);
    output.data = input.data;

    // Sample RGBA from curves with chaos variation
    float lifetime = input.data.x;
    float seed = input.data.z;

    output.color.r = SampleCurveWithChaos(0, 5, seed, lifetime);
    output.color.g = SampleCurveWithChaos(1, 6, seed, lifetime);
    output.color.b = SampleCurveWithChaos(2, 7, seed, lifetime);
    output.color.a = SampleCurveWithChaos(3, 8, seed, lifetime);

    output.size = SampleCurveWithChaos(4, 9, seed, lifetime);
    output.alphaTest = SampleCurve(10, lifetime);

    return output;
}
```

The vertex shader does two things:

1. **Position transform**: Multiplies world position by the view matrix, producing view-space coordinates. Note: it does NOT apply the projection matrix. This is deliberate — the geometry shader needs view-space positions for billboard construction.

2. **Curve sampling**: Evaluates all 11 spline curves for this particle's lifetime. The results (color RGBA, size, alpha test threshold) are passed to the geometry shader as interpolated outputs. This per-vertex work is unavoidable — each particle has unique lifetime and chaos values, so curves must be sampled individually.

### Why View-Space Expansion?

The geometry shader expands points in view space rather than world space. This is the critical architectural decision that makes billboard rendering simple.

In view space:
- The **X axis** points right on screen
- The **Y axis** points up on screen
- The **Z axis** points into the screen (toward the camera)

A camera-facing quad is defined by offsets along X and Y only. There's no need to compute a camera-right vector, a camera-up vector, or a billboard rotation matrix. The view transform already aligns the coordinate system with the screen. This eliminates an entire class of billboard math that plagues world-space implementations.

### Geometry Shader: Point to Quad

**default-particle.hlsl:158-198**

```hlsl
[maxvertexcount(4)]
void GeometryMain(point VertexOutput input[1],
                  inout TriangleStream<GeometryOutput> outputStream)
{
    float4 center = input[0].position;      // view-space center
    float4 scale = 0.1 * input[0].size.x;   // world-space size

    // Rotation from particle data
    float rotation = 0.1 * input[0].data.y;  // scale down rotation
    float4 xAxis = float4(sin(rotation), cos(rotation), 0, 0);
    float4 yAxis = float4(-xAxis.y, xAxis.x, 0, 0);

    // Generate four corners
    GeometryOutput verts[4];
    verts[0].position = mul(projectionMatrix, center + (-xAxis - yAxis) * scale);
    verts[0].texCoord = float2(1, 1);

    verts[1].position = mul(projectionMatrix, center + (xAxis - yAxis) * scale);
    verts[1].texCoord = float2(1, 0);

    verts[2].position = mul(projectionMatrix, center + (xAxis + yAxis) * scale);
    verts[2].texCoord = float2(0, 0);

    verts[3].position = mul(projectionMatrix, center + (-xAxis + yAxis) * scale);
    verts[3].texCoord = float2(0, 1);

    // Copy shared data to all vertices
    for (int i = 0; i < 4; i++)
    {
        verts[i].data = input[0].data;
        verts[i].color = input[0].color;
        verts[i].alphaTest = input[0].alphaTest;
    }

    // Output as triangle strip (3, 0, 2, 1 order)
    outputStream.Append(verts[3]);
    outputStream.Append(verts[0]);
    outputStream.Append(verts[2]);
    outputStream.Append(verts[1]);
    outputStream.RestartStrip();
}
```

#### The 0.1 Scale Factor

The `0.1` multiplier on both size and rotation converts from the authoring tool's units to rendering units. In the apEx editor, sizes are specified in a range that makes sense for the UI (1.0 = visible, 10.0 = large). Dividing by 10 maps these to world-space units where 0.1 = a small particle and 1.0 = a very large particle. The rotation angle also gets the 0.1 factor, converting from the emitter's degree-like values to radians-like values suitable for sin/cos.

#### Rotation Construction

The rotation creates a 2D rotation matrix applied to the billboard axes:

```
xAxis = (sin(θ), cos(θ), 0, 0)
yAxis = (-cos(θ), sin(θ), 0, 0)
```

This is the standard 2D rotation matrix `R(θ) = [[cos, -sin], [sin, cos]]` applied to the screen-aligned axes. Since we're in view space, rotating around the Z axis (into the screen) rotates the billboard in the plane of the screen. No quaternions needed. No axis-angle conversion. Just sin and cos.

#### Quad Corner Construction

Each corner is computed as `center + (±xAxis ± yAxis) * scale`. The four sign combinations produce:

```
v0: center + (-x - y) * s  → bottom-left
v1: center + (+x - y) * s  → bottom-right
v2: center + (+x + y) * s  → top-right
v3: center + (-x + y) * s  → top-left
```

Each corner position is then projected from view space to clip space by multiplying with the projection matrix. The projection must happen after quad expansion — projecting the center point first would produce incorrect results because projection is nonlinear (perspective division).

#### Triangle Strip Winding

The output order `3, 0, 2, 1` creates a valid triangle strip covering the quad:

```
Triangle 1: verts[3], verts[0], verts[2]  → top-left, bottom-left, top-right
Triangle 2: verts[0], verts[2], verts[1]  → bottom-left, top-right, bottom-right
```

This produces two triangles with consistent front-face winding, covering the entire quad. The Z-shaped strip pattern avoids the degenerate triangle that a simple sequential order (0, 1, 2, 3) would create.

#### UV Coordinate Assignment

UV coordinates map the sprite texture to the quad:

```
v0 (bottom-left):  UV = (1, 1)
v1 (bottom-right): UV = (1, 0)
v2 (top-right):    UV = (0, 0)
v3 (top-left):     UV = (0, 1)
```

The UV mapping is mirrored on the X axis compared to the typical convention. This doesn't matter for symmetric sprites (circles, stars) but would mirror asymmetric sprites. If this was intentional, it might accommodate a specific texture orientation in the apEx asset pipeline.

### Pixel Shader: Texture and Alpha Test

**default-particle.hlsl:203-212**

```hlsl
float4 PixelMain(GeometryOutput v) : SV_TARGET0
{
    float4 texColor = particleTexture.Sample(linearSampler, v.texCoord);

    // Dynamic alpha test based on particle lifetime
    if (texColor.w < v.alphaTest)
        discard;

    return v.color * texColor;
}
```

The pixel shader is deliberately simple. Three operations:

1. **Sample sprite texture**: Read the particle's sprite image (register t1) at the interpolated UV coordinate.

2. **Alpha test dissolution**: Compare the sprite's alpha channel against the lifetime-driven alpha test threshold (row 10 of the spline texture). When a particle is young, the threshold is low (near 0), so most pixels pass. As the particle ages, the threshold rises, and more pixels fail the test and get discarded. With a noise-based alpha texture, this creates a dissolve-to-death effect where the particle appears to erode away.

3. **Color multiplication**: Multiply the sprite color by the particle's tint color (from lifetime curves). This is a multiplicative blend — the sprite provides shape and texture detail, while the curve provides overall color and opacity animation.

#### The Dissolve Effect

The alpha test dissolution deserves special attention because it's one of the most visually interesting techniques in the particle system.

Consider a sprite texture that contains a soft circle — full opacity in the center, fading to zero at the edges. When `alphaTest = 0.0`, every pixel passes. The full circle renders. When `alphaTest = 0.5`, only the inner 50% of the circle passes. The particle shrinks visually. When `alphaTest = 0.99`, almost nothing passes. The particle has nearly vanished.

But if the sprite's alpha channel contains noise or a dissolve pattern instead of a smooth gradient, the dissolution becomes non-uniform. Pixels fail the alpha test in a noise-driven pattern, creating holes, cracks, and erosion effects. The particle doesn't just shrink — it disintegrates. This is computationally free (one comparison and conditional discard) yet produces effects that would otherwise require expensive erosion simulations.

The `discard` instruction has a performance implication: it disables early-Z testing for the entire draw call on some GPU architectures. This means the GPU can't skip pixel shader execution for pixels behind already-rendered geometry. For particles, this is usually acceptable because they're typically rendered with alpha blending on a transparent layer where depth writes are disabled anyway.

### Output and Blending

The pixel shader outputs a single `SV_TARGET0` value. The blend state, configured per-material, determines how this output combines with the existing framebuffer contents.

For typical particle effects:

- **Additive blending** (`SrcBlend=ONE, DstBlend=ONE`): Output adds to existing color. Bright particles get brighter where they overlap. Used for fire, sparks, magic effects. Depth writing is disabled; depth testing may be enabled for occlusion by solid geometry.

- **Alpha blending** (`SrcBlend=SRC_ALPHA, DstBlend=INV_SRC_ALPHA`): Standard transparency. Particles need back-to-front sorting for correct results. Used for smoke, fog, dust.

- **Premultiplied alpha** (`SrcBlend=ONE, DstBlend=INV_SRC_ALPHA`): A hybrid that handles both additive and alpha-blended content in a single blend state. Used for mixed effects where some particles glow (additive) and others occlude (alpha).

The blend mode is set through the material's `PARAM_BLENDMODE0` parameter, packed into a single byte with source blend in the low nibble and destination blend in the high nibble (Material.h:69-99, Project.cpp:1948-1952).

## Deferred Pipeline Integration

Particles exist in an awkward position within Phoenix's deferred rendering architecture. The deferred pipeline writes material properties (albedo, normal, roughness, metalness) to G-Buffer targets, then applies lighting in a separate full-screen pass. But particles can't participate in this pipeline meaningfully — they're flat billboards with no meaningful normals, no PBR material properties, and no stable surface for deferred lighting to evaluate.

### Render Layer Targeting

Phoenix's four render layers execute in order:

| Layer | Purpose | Particles? |
|-------|---------|-----------|
| Shadow Layer | Shadow map generation | No — billboards would produce wrong shadows |
| Solid Layer | G-Buffer generation | No — particles have no PBR properties |
| Lighting Layer | Deferred light accumulation | No — particles don't read G-Buffer |
| Transparent Layer | Alpha-blended geometry | **Yes** — this is where particles render |

Particles target the **Transparent Layer** through their material technique's `TargetLayer` field. The technique type is `TECH_PARTICLE` (Material.h:196), which operates identically to `TECH_MATERIAL` for rendering purposes — the distinction is in the editor tooling, where particle techniques show particle-specific UI (spline curve editors for lifetime parameters).

### Depth Interaction

On the Transparent Layer, particles typically:

- **Read depth**: Depth testing is enabled so particles are occluded by solid geometry rendered in the Solid Layer. A particle behind a wall doesn't show through it.
- **Don't write depth**: Depth writing is disabled so particles don't occlude each other through the depth buffer. Correct visual ordering comes from back-to-front sorting (the `Sort` flag and `ParticleSorter` qsort in UpdateParticles) and alpha blending.

This depth behavior is configured through the material's `PARAM_ZMODE` parameter (Project.cpp:1890-1891):

```cpp
DepthStencilDesc.DepthEnable = !(v.ZMode & 1);      // bit 0: disable depth test
DepthStencilDesc.DepthWriteMask = !((v.ZMode >> 1) & 1)
    ? D3D11_DEPTH_WRITE_MASK_ALL
    : D3D11_DEPTH_WRITE_MASK_ZERO;                    // bit 1: disable depth write
```

For particles, `ZMode = 0x02` (depth test on, depth write off) is the typical setting.

### No Deferred Lighting

Particles don't receive deferred lighting. They render on the Transparent Layer, which runs after the Lighting Layer has already composited all light contributions into the Main RT. Particle colors are purely emissive — defined entirely by the lifetime-driven spline curves and sprite texture, with no diffuse response to scene lights.

This is a deliberate simplification. In the demoscene context, particles represent effects like fire, sparks, and magic — things that emit light rather than reflecting it. Applying deferred lighting to a fire particle would darken it in shadow, which looks wrong. The additive/emissive approach is physically correct for most particle use cases.

For particles that should receive lighting (dust motes, debris, snow), a more complex approach would be needed: either sample the deferred lighting result at the particle's position, or use forward lighting in the particle shader. Phoenix doesn't implement either.

### Render Priority and Sort Order

Within the Transparent Layer, render instances are sorted by `RenderPriority` (Material.h:111). Default priority is 127 (Project.cpp:1862). Lower values render first; higher values render last (on top).

For particles, priority determines ordering relative to other transparent objects:

- Priority < 127: Particles render before other transparent objects
- Priority = 127: Default — intermixed with other transparent geometry
- Priority > 127: Particles render after (on top of) other transparent objects

This is a coarse sort, not a per-pixel depth sort. Within a single priority level, render instances execute in the order they were added to the layer's `RenderInstances` array. For correct alpha blending between particles and other transparent objects, the artist must set priorities appropriately.

## Material State Assembly

When the scene graph traverses particle emitters during `CreateRenderDataInstances()`, it assembles the complete rendering state that the GPU will use.

### The Assembly Process

**Scene.cpp:608-642**

```cpp
void CphxObject_ParticleEmitter_CPU::CreateRenderDataInstances(
    int Clip, const D3DXMATRIX &m, CphxScene *RootScene, void *SubSceneData)
{
    // Step 1: Evaluate material splines at current time
    Clips[Clip]->MaterialSplines->ApplyToParameters(this);

    // Step 2: Collect animated data for each pass
    int passid = 0;
    if (Material)
    {
        for (int x = 0; x < Material->TechCount; x++)
            for (int y = 0; y < Material->Techniques[x]->PassCount; y++)
                Material->Techniques[x]->CollectAnimatedData(MaterialState[passid++], y);
    }

    // Step 3: Override texture slot 0 with spline texture
    for (int x = 0; x < passid; x++)
        MaterialState[x]->Textures[0] = SplineTextureView;

    // Step 4: Create render instances (if standard particles)
    if (!ObjectToEmit && !SceneToEmit)
    {
        Material->CreateRenderDataInstances(MaterialState, RootScene,
                                             VertexBuffer, LiveCount);
    }
    // ... else mesh/subscene path
}
```

**Step 1**: `ApplyToParameters()` evaluates all material splines at the current timeline position and writes results to the material's parameter values. This updates colors, textures, blend states, and other properties that the artist animated on the timeline.

**Step 2**: `CollectAnimatedData()` gathers all `PARAM_ANIMATED` parameter values into a flat float array. These values get uploaded to the GPU constant buffer alongside per-object matrices.

**Step 3**: The spline texture override forces texture slot 0 to the emitter's lifetime curve texture, regardless of what the material's `PARAM_TEXTURE0` was set to. This is the mechanism that connects the material system to the particle lifetime system — the material might define TEXTURE0 as a noise texture in the editor, but at runtime it gets replaced with the particle curves.

**Step 4**: `Material::CreateRenderDataInstances()` calls through to `CphxMaterialTechnique::CreateRenderDataInstances()` (Material.cpp:117-166), which creates a `CphxRenderDataInstance` for each pass, populates it with shaders, blend states, textures, and matrices, and adds it to the appropriate render layer's queue.

### Render Instance Configuration for Particles

**Material.cpp:204-209**

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
            VxBuffer,           // particle vertex buffer
            NULL,               // no index buffer
            NULL,               // no wireframe buffer
            VertexCount,        // LiveCount (used as TriIndexCount)
            0,                  // no wire indices
            NULL,               // no tool data
            false);             // Indexed = false
}
```

The particle overload passes `Indexed = false`, which triggers the non-indexed rendering path in `RenderLayer.cpp`. The `VertexCount` parameter carries `LiveCount`, which becomes `TriIndexCount` in the render instance — the number of point primitives to draw.

### Texture Slot Assignments

The final texture slot state for standard particle rendering:

| Slot | Source | Content |
|------|--------|---------|
| t0 | SplineTextureView (forced) | Lifetime parameter curves (2048×N R32_FLOAT) |
| t1 | Material PARAM_TEXTURE1 | Particle sprite texture (RGBA8) |
| t2-t7 | Material PARAM_TEXTURE2-7 | Available for custom shaders |

The slot 0 override is non-negotiable — it happens unconditionally in `CreateRenderDataInstances()`. The sprite texture occupies slot 1 by convention, but this is determined by the shader code, not the engine. A custom particle shader could use any slot arrangement.

### TECH_PARTICLE vs TECH_MATERIAL

The `TECHNIQUETYPE` enum (Material.h:191-197) defines four technique types:

```cpp
enum TECHNIQUETYPE
{
    TECH_MATERIAL = 0,    // Standard mesh rendering
    TECH_POSTPROCESS = 1, // Full-screen post-processing
    TECH_SHADERTOY = 2,   // Procedural full-screen effect
    TECH_PARTICLE = 3,    // Particle system material
};
```

At runtime, `TECH_PARTICLE` and `TECH_MATERIAL` follow identical code paths. The distinction is purely for the apEx editor: particle techniques expose `PARAM_PARTICLELIFEFLOAT` parameters in the UI, enabling artists to draw lifetime-driven curves. Non-particle techniques don't offer these parameter types.

The implication is powerful: any shader that works as a mesh material can theoretically work as a particle material (and vice versa), as long as the vertex layout is compatible. The engine doesn't enforce technique-type restrictions during rendering.

## Mesh Particle Rendering

When `ObjectToEmit` is set, each live particle spawns a 3D mesh instance instead of a billboard quad. This path is fundamentally different: instead of one draw call for all particles, each particle generates its own render instances through the standard mesh rendering pipeline.

### Per-Particle Transform Construction

**Scene.cpp:648-706**

```cpp
for (int y = 0; y < particlecount; y++)
{
    if (Particles[y].LifeLeft > 0)
    {
        D3DXMATRIX m;
        D3DXQUATERNION q;

        if (!RotateToDirection)
        {
            // Standard rotation: around particle's random axis
            D3DXQuaternionRotationAxis(&q, &Particles[y].RotationAxis,
                (Particles[y].Rotation + Particles[y].RotationSpeed * Ticks)
                * 3.1415f / 180.0f);
        }
        else
        {
            // Velocity-aligned rotation
            D3DXVECTOR3 xd = Particles[y].Velocity;
            D3DXVec3Normalize(&xd, &xd);
            D3DXVECTOR3 up(0, 1, 0);
            D3DXVECTOR3 zd, yd;
            D3DXVec3Normalize(&zd, D3DXVec3Cross(&zd, &xd, &up));
            D3DXVec3Normalize(&yd, D3DXVec3Cross(&yd, &zd, &xd));
            D3DXMATRIX mx;
            D3DXMatrixIdentity(&mx);
            *(D3DXVECTOR3*)mx.m[0] = xd;
            *(D3DXVECTOR3*)mx.m[1] = yd;
            *(D3DXVECTOR3*)mx.m[2] = zd;
            D3DXQuaternionRotationMatrix(&q, &mx);
            D3DXQUATERNION q2;
            D3DXQuaternionRotationAxis(&q2, &D3DXVECTOR3(1, 0, 0),
                (Particles[y].Rotation + Particles[y].RotationSpeed * Ticks)
                * 3.1415f / 180.0f);
            D3DXQuaternionMultiply(&q, &q2, &q);
        }

        // Lifetime for spline evaluation
        float life = Aging ? (1 - (Particles[y].LifeLeft - Ticks)
                             / (float)Particles[y].MaxLife) : 0.0f;

        // Scale from lifetime-driven splines
        float scale = 1, scalex = 1, scaley = 1;
        for (int x = 0; x < Clips[Clip]->SplineCount; x++)
        {
            if (Clips[Clip]->Splines[x]->Type == Spline_Particle_Scale)
            {
                Clips[Clip]->Splines[x]->Spline->CalculateValue(life);
                scale = max(0, Particles[y].ScaleChaos)
                      * Clips[Clip]->Splines[x]->Spline->Value[0];
            }
            // ... similar for Stretch_X, Stretch_Y
        }

        D3DXVECTOR3 interpolatedPosition =
            Particles[y].Position + Particles[y].Velocity * Ticks;

        D3DXMatrixTransformation(&m, nullptr, nullptr,
            &D3DXVECTOR3(scale * scalex, scale * scaley, scale),
            nullptr, &q, &interpolatedPosition);
```

For each live particle, the system builds a full 4×4 transformation matrix combining:

1. **Translation**: Interpolated position (same formula as the vertex buffer, position + velocity × fractional ticks)
2. **Rotation**: Either arbitrary-axis rotation (per-particle random axis + accumulated angle) or velocity-aligned rotation with additional roll
3. **Scale**: Uniform scale from lifetime spline × per-particle chaos, plus per-axis stretch from Stretch_X and Stretch_Y splines

### RotateToDirection Mode

When `RotateToDirection` is enabled, the mesh aligns its X axis with the particle's velocity direction. This is essential for elongated particles like arrows, missiles, or debris that should "point" in their direction of travel.

The rotation construction:
1. Normalize velocity to get the forward direction (X axis)
2. Cross with world up (0,1,0) to get the right direction (Z axis)
3. Cross Z with X to get the corrected up direction (Y axis)
4. Build a rotation matrix from these three axes
5. Convert to quaternion
6. Multiply by an additional X-axis rotation for per-particle roll

The world-up assumption causes gimbal lock when velocity points straight up or down. The cross product with (0,1,0) produces a zero-length vector when velocity is parallel to up. Phoenix doesn't handle this edge case — for most effects, particles rarely move purely vertically, and the visual glitch (a brief flash as the mesh flips orientation) is acceptable.

### Draw Call Implications

Each live particle calls either `ObjectToEmit->CreateRenderDataInstances()` (mesh path) or `SceneToEmit->UpdateSceneGraph()` (subscene path).

For mesh particles, `CreateRenderDataInstances()` creates one `CphxRenderDataInstance` per material pass. A mesh with a two-pass material generates two render instances per particle. With 256 live particles, that's 512 render instances — each requiring its own draw call, constant buffer update, and state change.

This scales linearly with particle count × pass count. For a demo with carefully controlled particle counts (64-256 particles), the cost is manageable. For thousands of particles, it would be prohibitive. This is why mesh particles are used for hero effects (a few dozen debris pieces, a handful of orbiting objects) rather than volume fills.

### Material Animation per Particle

**Scene.cpp:716-717**

```cpp
Clips[Clip]->MaterialSplines->CalculateValues(life);
ObjectToEmit->CreateRenderDataInstances(Clips[Clip], m, RootScene, ...);
```

Before creating render instances for each mesh particle, the system evaluates the material splines at the particle's individual lifetime. This means each particle instance has its own animated material state — a young particle might be bright red, while an old particle might be dim blue, even though they share the same material definition.

This is the mesh particle equivalent of the billboard spline texture system. The difference is cost: billboard particles sample curves in the pixel shader (GPU), while mesh particles evaluate splines on the CPU per-particle per-frame. For hundreds of particles, this CPU cost is significant.

## Subscene Particle Rendering

**Scene.cpp:708-711**

```cpp
if (SceneToEmit)
{
    SceneToEmit->UpdateSceneGraph(0, life, m, RootScene, SubSceneData ? SubSceneData : ToolData);
}
```

Subscene particles are the most expressive and most expensive rendering mode. Each live particle triggers a complete scene graph evaluation for the subscene, with the particle's lifetime mapped to the subscene's animation time and the particle's transform applied as the subscene's root transform.

### How It Works

1. The emitter iterates over live particles (same loop as mesh particles)
2. For each particle, it builds a transform matrix (position + rotation + scale)
3. `UpdateSceneGraph()` traverses the subscene's object list, evaluating splines at the particle's lifetime
4. Each subscene object creates its own render instances, which get added to the root scene's render layers
5. The subscene objects render as if they were regular scene objects, but positioned at the particle's location

### Lifetime-to-Animation Mapping

The `life` parameter passed to `UpdateSceneGraph()` maps particle age to subscene animation time. A particle born 0.5 seconds ago with a 2-second lifetime has `life = 0.25`. The subscene evaluates its splines at time 0.25, which might position a mesh at frame 6 of a 25-frame animation. As the particle ages, the subscene animation progresses. When the particle dies, the subscene has played through its full timeline.

This enables complex particle effects: each "particle" could be an animated character, a rotating logo, or an exploding box. The subscene can contain multiple objects with their own materials, creating effects that would be impossible with simple billboard or mesh particles.

### Recursion Depth

A subscene could theoretically contain another particle emitter with subscene particles, creating recursive scene evaluation. Phoenix doesn't explicitly prevent this, but the computational cost grows exponentially with depth. In practice, demo artists use subscene particles for simple scenes (a few meshes with animated transforms) rather than complex hierarchies.

### Performance Cost

Subscene particles are the most expensive rendering path:

- **CPU cost**: Per-particle scene graph traversal, spline evaluation for all subscene objects, render instance creation for each subscene object × each material pass
- **GPU cost**: Each subscene object generates independent draw calls with full shader pipeline
- **Memory cost**: Render instance allocation per particle × subscene objects × passes

For 100 particles × 3 subscene objects × 2 passes = 600 render instances. At 64 particles or fewer, subscene particles are practical. Beyond that, the CPU overhead dominates.

## The Pointsprites Shader: Alternative Billboard Approach

Phoenix includes a second billboard shader, `pointsprites.hlsl`, that takes a different approach: instead of point-primitive input, it processes triangle-list meshes and replaces each triangle with a billboard sprite at its centroid.

### Use Case

Pointsprites is used for mesh-to-particle conversion. Given any triangle mesh, the shader places a sprite at every triangle center. This creates effects like foliage imposters (each triangle becomes a leaf sprite), point cloud visualization, or decal-on-surface effects.

### Key Differences from Default Particle Shader

| Aspect | default-particle.hlsl | pointsprites.hlsl |
|--------|----------------------|-------------------|
| Input topology | Point list | Triangle list |
| GS input | `point VertexOutput input[1]` | `triangle VertexOutput input[3]` |
| Position source | Vertex buffer (8 floats) | Triangle centroid |
| Rotation | Per-particle from data | None |
| Color source | Lifetime curve texture | Constant buffer tint |
| Alpha test | Dynamic from curve row 10 | None |
| Size source | Lifetime curve | Constant buffer scale |
| Normal offset | None | Along face normal |

The pointsprites shader is simpler — no lifetime curves, no chaos system, no alpha test dissolution. It's a general-purpose billboard generator, not a particle-system-specific shader.

### Normal Offset

**pointsprites.hlsl:93-98**

```hlsl
float3 edge1 = normalize(input[0].position.xyz - input[1].position.xyz);
float3 edge2 = normalize(input[2].position.xyz - input[1].position.xyz);
float3 faceNormal = cross(edge1, edge2);
center += float4(faceNormal, 0) * offset;
```

The face normal offset pushes the billboard along the triangle's surface normal, preventing z-fighting with the underlying mesh. This is essential when using pointsprites to add detail (foliage, decals) to existing geometry — without the offset, the billboard would coplanar with the triangle and produce flickering artifacts.

## Commented-Out GPU Particle System

**Scene.h:383-396**

```cpp
//class CphxObject_ParticleEmitter : public CphxObject
//{
//public:
//
//  bool Sort;
//  unsigned char Resolution;
//
//  ID3D11Resource *Particles;
//  ID3D11UnorderedAccessView *ParticleView;
//  ID3D11ComputeShader *UpdateShader;
//  ID3D11ComputeShader *SpawnShader;
//
//  //virtual void CreateRenderDataInstances(...);
//};
```

Phoenix contains a commented-out GPU particle system design that was never completed. The class reveals the intended architecture:

### CPU vs GPU Architecture Comparison

| Aspect | CPU System (Shipped) | GPU System (Planned) |
|--------|---------------------|---------------------|
| Particle storage | `PHXPARTICLE *Particles` (CPU array) | `ID3D11Resource *Particles` (GPU buffer) |
| Update logic | C++ loop in `UpdateParticles()` | `ID3D11ComputeShader *UpdateShader` |
| Spawn logic | C++ `SpawnParticle()` | `ID3D11ComputeShader *SpawnShader` |
| Access pattern | Direct array indexing | UAV random access |
| Sort | CPU qsort | Presumably GPU bitonic sort |
| Resolution | Buffer size (2^n count) | Resolution-based (texture-like sizing) |
| Read-back | Direct (CPU owns data) | Would need staging buffer for mesh/subscene |

### Why It Was Abandoned

Several factors likely contributed:

1. **Code size**: Compute shaders add HLSL code, dispatch logic, UAV management, and synchronization barriers. In a 64k demo, every byte matters. The CPU system fits in ~500 lines of C++.

2. **Flexibility**: CPU particles can interact with arbitrary C++ code — spawn from child objects, emit mesh instances, evaluate subscene hierarchies. GPU particles would need buffer readback for these features, negating the GPU performance advantage.

3. **Sufficient performance**: CPU particles at 25fps fixed timestep with 256-2048 particles are fast enough for demo purposes. GPU particles shine at 100k+ particles, which exceeds typical demo needs.

4. **Debugging**: CPU particles can be inspected with a debugger, printf'd, visualized in the tool. GPU particles require PIX/RenderDoc and are notoriously difficult to debug.

### Resolution Field

The `unsigned char Resolution` field suggests the GPU system would have used texture-like sizing (32×32, 64×64, etc.) for particle storage, treating the particle buffer as a 2D grid. This is a common GPU particle technique: store particle data in a texture, dispatch compute shaders on a 2D grid, and render using DrawInstancedIndirect with the texture as vertex input.

### Implications for Rust/wgpu

A modern GPU particle system for Rust would use wgpu compute shaders:

```rust
// Conceptual structure
struct GpuParticleSystem {
    particle_buffer: wgpu::Buffer,       // Storage buffer (UAV equivalent)
    update_pipeline: wgpu::ComputePipeline,
    spawn_pipeline: wgpu::ComputePipeline,
    sort_pipeline: wgpu::ComputePipeline, // Optional bitonic sort
    draw_indirect: wgpu::Buffer,         // DrawIndirect args
}
```

Key considerations:
- **Buffer vs texture**: wgpu storage buffers are more flexible than textures for particle data
- **Atomic operations**: Spawn/kill counters need atomics for thread-safe pool management
- **Indirect draw**: `DrawIndirect` avoids CPU readback of live particle count
- **Readback**: Only needed if CPU code needs to interact with GPU particles (e.g., subscene emission)

## Data Flow Summary

```
┌──────────────────────────────────────────────────────────────────┐
│                     Scene Graph Traversal                        │
│  For each particle emitter:                                      │
│    ├─ MaterialSplines->ApplyToParameters()                       │
│    ├─ CollectAnimatedData() per pass                              │
│    └─ Override Textures[0] = SplineTextureView                   │
└──────────────────┬───────────────────────────────────────────────┘
                   │
          ┌────────┼────────┐
          │        │        │
          ▼        ▼        ▼
    ┌──────────┐ ┌────────┐ ┌──────────────┐
    │ Standard │ │  Mesh  │ │   Subscene   │
    │ Particles│ │Particles│ │  Particles   │
    └────┬─────┘ └───┬────┘ └──────┬───────┘
         │           │             │
         │           │             │
         ▼           ▼             ▼
  ┌─────────────┐ ┌───────────┐ ┌──────────────┐
  │ 1 Draw Call │ │ N Draws   │ │ N×M Draws    │
  │ (all pts)   │ │ (per ptcl)│ │ (ptcl×obj)   │
  │             │ │           │ │              │
  │ VertexBuffer│ │ Per-ptcl  │ │ Per-ptcl     │
  │ (8 floats/  │ │ transform │ │ scene graph  │
  │  particle)  │ │ matrix    │ │ traversal    │
  │             │ │           │ │              │
  │ POINTLIST   │ │ Standard  │ │ Standard     │
  │ topology    │ │ mesh draw │ │ mesh draws   │
  └─────┬───────┘ └─────┬────┘ └──────┬───────┘
        │               │             │
        └───────────────┼─────────────┘
                        │
                        ▼
              ┌─────────────────┐
              │ Transparent     │
              │ Render Layer    │
              │                 │
              │ Sorted by       │
              │ RenderPriority  │
              │                 │
              │ Depth read,     │
              │ no depth write  │
              │                 │
              │ Additive or     │
              │ alpha blend     │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │ Main Render     │
              │ Target          │
              │ (composited     │
              │  over lit       │
              │  scene)         │
              └─────────────────┘
```

## Standard Particle Pipeline (Complete)

```
CPU: UpdateParticles()
  │
  ├─ Physics @ 25fps (position, velocity, rotation, lifetime)
  ├─ Sorting (optional back-to-front qsort)
  └─ Map VertexBuffer (WRITE_DISCARD)
       │
       └─ Per particle: 8 floats
            [pos.x, pos.y, pos.z, 1.0,
             lifetime, rotation, chaos, 0.0]
                       │
CPU: CreateRenderDataInstances()
  │
  ├─ Evaluate material splines at current time
  ├─ Override Textures[0] = SplineTextureView
  └─ Create CphxRenderDataInstance
       │
       ├─ VertexBuffer = particle VB
       ├─ Indexed = false → POINTLIST topology
       ├─ TriIndexCount = LiveCount
       ├─ VS/GS/PS from material passes
       ├─ BlendState/RasterizerState/DepthStencilState from material
       └─ Textures[0] = spline curves, [1] = sprite
                       │
GPU: Input Assembler
  │
  ├─ IASetInputLayout(ParticleVertexFormat)  // vxdecl3
  ├─ IASetPrimitiveTopology(POINTLIST)
  └─ Draw(LiveCount, 0)
                       │
GPU: Vertex Shader (VertexMain)
  │
  ├─ Transform position: view = viewMatrix × worldPos
  ├─ Sample lifetime curves (rows 0-4 + chaos rows 5-9)
  ├─ Sample alpha test curve (row 10)
  └─ Output: view-space pos, RGBA color, size, alphaTest
                       │
GPU: Geometry Shader (GeometryMain)
  │
  ├─ Compute rotated axes: sin/cos(rotation * 0.1)
  ├─ Expand point to 4-vertex quad in view space
  ├─ Project each corner: projection × (center ± axis × size × 0.1)
  ├─ Assign UV coordinates
  └─ Output triangle strip: 3, 0, 2, 1
                       │
GPU: Rasterizer
  │
  └─ Interpolate position, UV, color, alphaTest across quad
                       │
GPU: Pixel Shader (PixelMain)
  │
  ├─ Sample sprite texture at UV (register t1)
  ├─ Alpha test: if (sprite.a < alphaTest) discard
  └─ Output: color × sprite → SV_TARGET0
                       │
GPU: Output Merger
  │
  ├─ Depth test against solid geometry (read only)
  └─ Blend: additive or alpha (per material blend state)
                       │
       Final pixel in Main Render Target
```

## Performance Characteristics

### Standard Particles

| Metric | Value | Notes |
|--------|-------|-------|
| Draw calls | 1 per pass | Single non-indexed Draw() |
| CPU upload | 32 bytes × LiveCount | Map/Unmap WRITE_DISCARD |
| VS invocations | LiveCount | One per particle |
| GS expansion | 1→4 vertices per particle | 4× vertex amplification |
| PS invocations | ~LiveCount × quad_pixel_area | Depends on particle size |
| Texture reads | 11 curve samples per VS | SampleCurve()/SampleCurveWithChaos() |
| State changes | Minimal | All particles share material state |

### Mesh Particles

| Metric | Value | Notes |
|--------|-------|-------|
| Draw calls | LiveCount × passes | One per particle per pass |
| CPU cost | Transform matrix + spline eval per particle | O(LiveCount × SplineCount) |
| VS invocations | LiveCount × mesh vertices | Full mesh per particle |
| PS invocations | LiveCount × mesh pixel area | Full mesh rendering |
| State changes | Per-particle | Constant buffer update per draw |

### Subscene Particles

| Metric | Value | Notes |
|--------|-------|-------|
| Draw calls | LiveCount × objects × passes | Multiplicative |
| CPU cost | Full scene graph per particle | Spline eval × objects |
| VS invocations | LiveCount × total vertices | All subscene geometry |
| State changes | Per-object per-particle | Maximum churn |

## Implications for Rust Creative Coding Frameworks

### 1. Billboard Particles as the Default Path

Phoenix's billboard approach — POINTLIST topology → GS expansion → single draw call — maps directly to wgpu. In wgpu, the geometry shader would be replaced by a compute shader that generates quad vertices into a storage buffer, since WebGPU doesn't support geometry shaders. The compute-to-vertex pattern is more flexible anyway:

```rust
// Conceptual compute shader approach
@compute @workgroup_size(64)
fn expand_particles(
    @builtin(global_invocation_id) id: vec3<u32>,
) {
    let particle = particles[id.x];
    let base_idx = id.x * 4;  // 4 vertices per particle
    // Write 4 vertices to output buffer
    output_vertices[base_idx + 0] = make_corner(particle, vec2(-1, -1));
    output_vertices[base_idx + 1] = make_corner(particle, vec2( 1, -1));
    // ...
}
```

### 2. Spline Texture is a Reusable Pattern

The lifetime-to-texture-lookup pattern generalizes to any parameter animation system. Any property that varies over a normalized domain (0-1 lifetime, 0-1 animation progress, 0-1 distance) can be baked into a 1D texture. The GPU samples it per-pixel with zero CPU cost per frame.

In Rust/wgpu, this becomes a `TextureCurve` resource:

```rust
struct TextureCurve {
    texture: wgpu::Texture,
    view: wgpu::TextureView,
    rows: u32,  // number of parameters
}

impl TextureCurve {
    fn from_curves(device: &wgpu::Device, curves: &[Curve]) -> Self {
        // Sample each curve at 2048 points, create R32Float texture
    }
}
```

### 3. Alpha Test Dissolution is Free VFX

The dynamic alpha test requires zero additional GPU resources — just a comparison and discard in the fragment shader. It works with any sprite texture that has meaningful alpha gradients. Consider making this a built-in feature of any particle material:

```wgsl
if (texColor.a < alpha_threshold) {
    discard;
}
```

### 4. Mesh Particles Need Instancing

Phoenix's per-particle draw calls are the weakest part of the design. Modern APIs should use hardware instancing:

```rust
render_pass.draw_indexed(
    mesh.index_count,
    live_particle_count,  // instance count
    0, 0, 0,
);
```

Per-instance data (transform, lifetime, color) goes in a separate vertex buffer with `step_mode: VertexStepMode::Instance`. This reduces mesh particles from N draw calls to 1 draw call, making them competitive with billboard particles for moderate particle counts.

### 5. View-Space Billboard Construction

The view-space expansion trick (VS transforms to view space, GS/compute expands along screen-aligned axes) is elegant and should be adopted. It eliminates camera-vector extraction and billboard matrix construction. In a compute-shader expansion, this means:

```wgsl
let view_pos = view_matrix * vec4(particle.position, 1.0);
let right = vec4(1.0, 0.0, 0.0, 0.0) * size;
let up = vec4(0.0, 1.0, 0.0, 0.0) * size;
// Corners are just view_pos ± right ± up
```

### 6. Transparent Layer Architecture

The four-layer architecture (Shadow → Solid → Lighting → Transparent) is a proven pattern. Particles on the Transparent Layer with depth-read/no-depth-write is the standard approach. Consider order-independent transparency (OIT) as an upgrade path for Rust frameworks, using wgpu's storage buffer atomics for per-pixel linked lists.

## Related Documents

- **[overview.md](overview.md)** — Particle system architecture and design philosophy
- **[simulation.md](simulation.md)** — Fixed timestep physics and GPU buffer upload
- **[emitters.md](emitters.md)** — Spawn algorithms and emission parameters
- **[affectors.md](affectors.md)** — Force field types (drag, gravity, turbulence, vortex)
- **[gap-analysis.md](gap-analysis.md)** — Known documentation gaps and resolution status
- **[../rendering/deferred.md](../rendering/deferred.md)** — Deferred pipeline and transparency handling
- **[../rendering/materials.md](../rendering/materials.md)** — Material system and PARAM_PARTICLELIFEFLOAT
- **[../code-traces/particle-rendering.md](../code-traces/particle-rendering.md)** — Line-by-line rendering trace

## Source References

| File | Lines | Content |
|------|-------|---------|
| `Phoenix/Scene.cpp` | 574-605 | Vertex buffer upload (position, lifetime, rotation, chaos) |
| `Phoenix/Scene.cpp` | 608-723 | CreateRenderDataInstances (all 3 modes) |
| `Phoenix/Scene.cpp` | 726-775 | UpdateSplineTexture (curve baking) |
| `Phoenix/RenderLayer.cpp` | 27-101 | Draw call execution, particle/mesh branching |
| `Phoenix/Material.cpp` | 117-209 | Render instance creation, Indexed=false overload |
| `Phoenix/phxEngine.cpp` | 130-194 | Vertex layout declarations (vxdecl3) |
| `Phoenix/Project.cpp` | 1839-1952 | Blend/depth/rasterizer state creation |
| `Phoenix/Material.h` | 24-99 | Parameter types, blend mode defines |
| `Phoenix/Material.h` | 191-197 | TECHNIQUETYPE enum |
| `Phoenix/Scene.h` | 234-304 | Particle structs, emitter class |
| `Phoenix/Scene.h` | 383-396 | Commented-out GPU particle class |
| `default-particle.hlsl` | 1-213 | Complete billboard shader (VS→GS→PS) |
| `pointsprites.hlsl` | 1-135 | Mesh-to-billboard alternative shader |
