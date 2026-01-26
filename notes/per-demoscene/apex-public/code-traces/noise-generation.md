# Code Trace: Multi-Octave Noise Generation

> Tracing the complete execution path for generating multi-octave Perlin noise in the Phoenix texgen system, from operator invocation through 8 GPU render passes.

Procedural textures are the lifeblood of 64k intros. Where a modern game might ship with gigabytes of compressed JPEGs and PNGs, demoscene productions generate every texture from mathematical functions executed on the GPU. The most fundamental of these is Perlin noise: the building block for clouds, terrain, marble, wood grain, and countless other organic patterns.

This trace follows a single noise operator through Phoenix's texgen pipeline, revealing how the C++ runtime orchestrates multiple GPU passes and how HLSL shaders accumulate frequency octaves. The system generates 8 octaves of noise at resolutions up to 2048x2048, producing smooth, tileable patterns with controllable detail levels.

The question this answers: How do you generate high-quality fractal noise on the GPU when you can't afford to ship lookup tables or pre-computed noise functions? The solution is a multi-pass architecture where each pass adds one octave of noise at increasing frequency, ping-ponging between two render targets to accumulate results.

Understanding this flow illuminates three critical design patterns: why the hash texture regenerates every pass (deterministic randomness from a single seed), why smoothstep interpolation eliminates visible grid artifacts, and why amplitude decay follows geometric progression (each octave contributes half the energy of the previous one).

The problem Phoenix solves: given a random seed and octave range, generate a continuous noise function that tiles seamlessly, interpolates smoothly between grid points, and accumulates multiple frequency layers without visible banding or aliasing.

## The Mental Model: Frequency Layers Like Audio Synthesis

Think of multi-octave noise like building a musical chord. Start with a low bass note (octave 0) that provides the fundamental structure, the broad rolling hills of your noise landscape. Then add the next octave up, a higher frequency that adds medium-scale detail, like individual boulders on those hills. Keep adding octaves, each doubling the frequency and halving the amplitude, until you reach the highest notes that define fine texture like pebbles and sand.

In audio synthesis, you'd mix these frequencies together in real-time. In texture generation, you literally paint them one at a time onto a render target. Each GPU pass generates one octave at a specific frequency and amplitude, reading the previous pass's result and adding its contribution. After 8 passes, you have a complete fractal noise function spanning 3 orders of magnitude in frequency.

The hash texture is your source of entropy, a 256x256 grid of pseudo-random values. Each octave samples this texture at increasing resolution, interpolating between grid points to create smooth gradients. Smoothstep interpolation creates C1 continuity (matching first derivatives at boundaries), eliminating the telltale grid pattern that plagues naive implementations.

## Entry Point: Operator Generate

**File**: `apEx/Phoenix/Texgen.cpp:464`

Texture generation begins when the engine calls `PHXTEXTUREOPERATOR::Generate()`. This function is the entry point for all texture operations, whether they're generators like noise or filters that combine multiple inputs.

```cpp
CphxTexturePoolTexture *PHXTEXTUREOPERATOR::Generate(
    PHXTEXTUREFILTER *Filters,
    PHXTEXTUREOPERATOR *Operators)
{
  if (CachedResult) return CachedResult;  // Line 466

  // Generate parent textures first (recursively)
  CphxTexturePoolTexture *ParentResults[TEXGEN_MAX_PARENTS];
  for (int x = 0; x < TEXGEN_MAX_PARENTS; x++) {
    ParentResults[x] = NULL;
    if (Parents[x] >= 0) {
      ParentResults[x] = Operators[Parents[x]].Generate(Filters, Operators);
    }
  }

  // Allocate render targets from pool (line 482-483)
  CphxTexturePoolTexture *Result = TexgenPool->GetTexture(Resolution, HDR);
  CphxTexturePoolTexture *BackBuffer = TexgenPool->GetTexture(Resolution, HDR);

  // Execute filter render (line 486)
  Filters[Filter & 0x7f].Render(Result, BackBuffer, ParentResults,
                                 RandSeed, Parameters, minimportData, minimportData2);

  // Return swap buffer to pool (line 488)
  BackBuffer->Used = false;

  // Release parent textures if they're not cached (line 491-493)
  for (int x = 0; x < TEXGEN_MAX_PARENTS; x++)
    if (ParentResults[x] && !Operators[Parents[x]].NeedsRender)
      ParentResults[x]->Used = false;

  return Result;  // Final texture with all octaves
}
```

For noise operators, the `Parents` array contains only `-1` values (no parent inputs), so the loop at line 471-479 does nothing. The function allocates two textures at the requested resolution: `Result` is the final output, `BackBuffer` is the swap target for ping-pong rendering.

The `Filter` field encodes both the filter index (lower 7 bits) and HDR flag (bit 7). Masking with `0x7f` extracts the filter index, which points to the compiled noise shader. The `RandSeed` provides deterministic randomness, while `Parameters` contains the encoded octave range and persistence values.

## Filter Render Setup

**File**: `apEx/Phoenix/Texgen.cpp:120-130`

The `PHXTEXTUREFILTER::Render()` function sets up GPU state for all texture operations, then enters a multi-pass loop determined by the filter's `PassCount`.

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
  srand(RandSeed);  // Line 122 - seed PRNG for deterministic randomness
  float ShaderData[TEXGEN_MAX_PARAMS + 4];  // Constant buffer data

  // Bind pixel shader (line 125)
  phxContext->PSSetShader(PixelShader, NULL, 0);

  // Set vertex shader, samplers, input layout (line 126)
  Prepare2dRender();

  // Bind constant buffer (line 127)
  phxContext->PSSetConstantBuffers(0, 1, &TexgenBufferPS);

  // Set viewport to match texture resolution (line 129)
  Target->SetViewport();

  // Multi-pass loop begins at line 134...
}
```

The `srand(RandSeed)` call is critical for reproducibility. Every time the demo runs, the same seed generates the same sequence of random numbers. This ensures textures look identical across runs, despite relying on pseudo-random values for hash table generation and pass randomization.

`Prepare2dRender()` (line 99-118) sets up state for fullscreen quad rendering: it binds the vertex shader, configures samplers (wrap mode, filtering), sets rasterizer and blend state, and configures the vertex buffer with two triangles covering clip space from (-1, -1) to (1, 1).

## Multi-Pass Loop: Ping-Pong Rendering

**File**: `apEx/Phoenix/Texgen.cpp:134-185`

For noise with octaves 0-7, `DataDescriptor.PassCount` equals 8. Each iteration renders one octave and swaps render targets to enable reading the previous result.

```cpp
for (unsigned int x = 0; x < DataDescriptor.PassCount; x++) {
  // Generate lookup texture (line 136)
  CphxTexturePoolTexture *Lookup = GetLookupTexture(Target->Resolution,
                                                      ExtraData, ExtraDataSize);

  // Swap render targets (lines 139-141)
  CphxTexturePoolTexture *swapvar = SwapBuffer;
  SwapBuffer = Target;
  Target = swapvar;

  // Clear shader resource bindings to avoid render target conflicts (lines 143-145)
  ID3D11ShaderResourceView *Textures[5] = {NULL, NULL, NULL, NULL, NULL};
  phxContext->PSSetShaderResources(0, 5, Textures);

  // Bind new render target (line 148)
  phxContext->OMSetRenderTargets(1, &Target->RTView, NULL);

  // Build constant buffer data (lines 151-153)
  ShaderData[0] = (float)x;  // Pass index (0-7)
  ShaderData[1] = rand() / (float)RAND_MAX;  // Random X offset
  ShaderData[2] = rand() / (float)RAND_MAX;  // Random Y offset
  ShaderData[3] = rand() / (float)RAND_MAX;  // Random Z offset

  // Normalize parameters from byte range to [0, 1] (line 153)
  for (int y = 0; y < TEXGEN_MAX_PARAMS; y++)
    ShaderData[y + 4] = Parameters[y] / 255.0f;

  // Upload constant buffer to GPU (lines 156-158)
  D3D11_MAPPED_SUBRESOURCE map;
  phxContext->Map(TexgenBufferPS, 0, D3D11_MAP_WRITE_DISCARD, 0, &map);
  memcpy(map.pData, ShaderData, SHADERDATALENGTH);
  phxContext->Unmap(TexgenBufferPS, 0);

  // Bind input textures (lines 162-169)
  int scnt = 0;
  if (Inputs[0] || x)
    Textures[scnt++] = x ? SwapBuffer->View : Inputs[0]->View;
  if (Inputs[1]) Textures[scnt++] = Inputs[1]->View;
  if (Inputs[2]) Textures[scnt++] = Inputs[2]->View;
  if (Lookup) Textures[scnt++] = Lookup->View;
  if (Lookup) Textures[scnt++] = Lookup->View;  // Duplicate for known sampler slot

  phxContext->PSSetShaderResources(0, 5, Textures);

  // Draw fullscreen quad (line 172)
  phxContext->Draw(6, 0);

  // Generate mipmaps for filtered sampling (line 174)
  phxContext->GenerateMips(Target->View);

  // Cleanup lookup texture (lines 176-183)
  if (Lookup) {
    if (Lookup->View) Lookup->View->Release();
    if (Lookup->Texture) Lookup->Texture->Release();
    delete Lookup;
  }
}
```

The swap at lines 139-141 is the heart of ping-pong rendering. After swapping, `SwapBuffer` holds the previous pass result, which gets bound to shader register `t0` at line 163. `Target` becomes the new render destination. This pattern enables accumulation without requiring a third buffer.

The `scnt` counter at line 162 handles texture slot assignment. For noise operators with no parents, `Inputs[0]` is NULL on the first pass (x=0), so the condition at line 163 checks `x` to determine whether to bind the swap buffer. Passes 1-7 always bind `SwapBuffer->View` to read the accumulated result.

Notice the duplicate lookup texture binding at line 167. The comment explains this is necessary to ensure the hash texture occupies a consistent shader register across different filter types. Some filters expect the lookup at `t3`, others at `t4`, so binding it twice guarantees availability.

## Hash Texture Generation

**File**: `apEx/Phoenix/Texgen.cpp:205-346`, case 4 at lines 323-334

Before each pass, `GetLookupTexture()` generates a 256x256 RGBA texture filled with pseudo-random values using the xorshift96 PRNG.

```cpp
CphxTexturePoolTexture *PHXTEXTUREFILTER::GetLookupTexture(
    unsigned char Res,
    void *ExtraData,
    int ExtraDataSize)
{
  if (!DataDescriptor.LookupType ||
      (!ExtraData && DataDescriptor.LookupType != 4))
    return NULL;

  // For noise, LookupType == 4
  // ... texture descriptor setup ...

  switch (DataDescriptor.LookupType) {
    case 4: {  // Noise hash texture (line 323)
      // Fixed 256x256 resolution for all noise operators
      tex.Width = tex.Height = XRes = YRes = 256;
      data.SysMemPitch = XRes * 4;
      ImageData = new unsigned char[XRes * YRes * 4];

      // Seed xorshift PRNG (line 329)
      rndx = rand();  // Uses srand(RandSeed) from line 122
      rndy = 362436069;
      rndz = 521288629;

      // Fill all RGBA channels with random bytes (line 332)
      for (int x = 0; x < XRes * YRes * 4; x++)
        ImageData[x] = (unsigned char)xorshf96();
      break;
    }
  }

  // Create D3D11 texture (lines 339-342)
  data.pSysMem = ImageData;
  phxDev->CreateTexture2D(&tex, &data, &out->Texture);
  phxDev->CreateShaderResourceView(out->Texture, NULL, &out->View);

  delete[] ImageData;
  return out;
}
```

The xorshift96 PRNG (lines 191-203) provides a period of 2^96-1 with minimal code:

```cpp
static unsigned long rndx = 123456789, rndy = 362436069, rndz = 521288629;

unsigned long xorshf96(void) {
  unsigned long t;
  rndx ^= rndx << 16;
  rndx ^= rndx >> 5;
  rndx ^= rndx << 1;

  t = rndx;
  rndx = rndy;
  rndy = rndz;
  rndz = t ^ rndx ^ rndy;

  return rndz;
}
```

Why regenerate the hash texture every pass instead of reusing it? The answer is determinism. Each pass needs different random values, but those values must be identical across demo runs. By seeding with `srand(RandSeed)` once, then calling `rand()` before each `xorshf96()` sequence, the system generates a unique but reproducible hash texture for each octave.

This has a performance cost (256×256×4 = 262,144 PRNG calls per pass, plus texture upload), but eliminates the need for storing hash textures in the 64k binary. Code size trumps runtime performance in demoscene productions.

## Shader Execution: First Octave

**File**: `Projects/Clean Slate/extracted/shaders/texgen/noise.hlsl` (annotated version)

The pixel shader executes once per pixel in the 256×256 (or higher resolution) target. For the first pass (index 0), it generates the base frequency octave.

```hlsl
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0 {
  // Decode octave range from normalized parameters (lines 71-74)
  // Parameters come from byte values (0-255), encoded as floats (0-1)
  float minOctave = texgenParams.x * 255 - 1;  // e.g., 0
  float maxOctave = texgenParams.y * 255;       // e.g., 7

  // Calculate relative pass index (line 78)
  // passInfo.x = 0 for first pass
  int relativePassIndex = passInfo.x + 0.5 - minOctave;  // = 0

  // Calculate grid cell size for this octave (line 83)
  // Octave 0: cellSize = 1 / 2^(0+2) = 1/4 (4×4 grid)
  float cellSize = 1.0 / pow(2.0, passInfo.x + 2);

  // Calculate amplitude using persistence (line 89)
  // First octave always has amplitude = 1.0
  float amplitude = relativePassIndex ?
                    pow(abs(texgenParams.z), relativePassIndex) : 1.0;
```

The `minOctave` calculation subtracts 1 because the byte parameter encoding starts at value 1 for octave 0 (byte value 0 represents "octave -1" which is skipped). This offset enables a parameter range of 0-255 to represent octaves -1 through 254.

Grid cell size follows a geometric progression: octave 0 divides the texture into a 4×4 grid (1/4), octave 1 into 8×8 (1/8), octave 2 into 16×16 (1/16), and so on. Higher octaves sample the hash texture at finer resolution, creating higher frequency detail.

```hlsl
  // Find grid cell containing this UV coordinate (lines 98-101)
  float2 uv = texCoord;  // Input UV in [0, 1]
  float2 fractionalPart = uv % cellSize;  // Position within cell
  uv -= fractionalPart;                    // Snap to bottom-left corner
  fractionalPart /= cellSize;              // Normalize to [0, 1] within cell

  // Apply smoothstep interpolation if mode == 0 (lines 109-114)
  if (texgenParams.w == 0) {
    // S(t) = t² × (3 - 2t) creates C1 continuity
    fractionalPart *= fractionalPart * (3 - 2 * fractionalPart);
  }
  // Mode 1 uses linear interpolation (no modification)
```

Smoothstep is critical for quality. Linear interpolation creates C0 continuity (values match at boundaries but derivatives don't), which produces visible grid lines when you zoom in. Smoothstep creates C1 continuity (both values and first derivatives match), resulting in perfectly smooth transitions.

The mathematical insight: at `t=0`, `S(0) = 0` and `S'(0) = 0`. At `t=1`, `S(1) = 1` and `S'(1) = 0`. Zero derivatives at boundaries mean the slope smoothly transitions from the previous cell through the boundary into the next cell, eliminating discontinuities.

```hlsl
  // Calculate opposite corner with wrapping (line 118)
  float2 oppositeCorner = frac(uv + cellSize);

  // Bilinear interpolation of four corner hash values (lines 129-148)
  // Grid layout:
  //   (uv.x, oppositeCorner.y) ----- (oppositeCorner)
  //           |                              |
  //           |       (fractionalPart)       |
  //           |                              |
  //        (uv) ------------------- (oppositeCorner.x, uv.y)

  float4 noiseX, noiseY;

  // Interpolate bottom edge along X (lines 132-136)
  noiseX = lerp(
    SampleHashTexture(uv),                           // Bottom-left
    SampleHashTexture(float2(oppositeCorner.x, uv.y)),  // Bottom-right
    fractionalPart.x
  );

  // Interpolate top edge along X (lines 138-143)
  noiseY = lerp(
    SampleHashTexture(float2(uv.x, oppositeCorner.y)),  // Top-left
    SampleHashTexture(oppositeCorner),                   // Top-right
    fractionalPart.x
  );

  // Final interpolation along Y (line 148)
  // Subtract 0.5 to center noise around 0, multiply by amplitude
  float4 noiseValue = (lerp(noiseX, noiseY, fractionalPart.y) - 0.5) * amplitude;
```

The hash texture sampling (line 47-57) scales coordinates by 256 to convert from UV space [0,1] to texel space [0,256), then uses `fmod(..., 256)` for tiling and `Load()` for point sampling without filtering:

```hlsl
float4 SampleHashTexture(float2 integerCoord) {
  // Scale by 256 and apply frequency multiplier (line 52)
  float2 scaledCoord = integerCoord * 256 * (max(1, passInfo.x) * (1 + passInfo.y));

  // Wrap to 256x256 tile and sample at mip level 0 (line 56)
  return hashTexture.Load(int3(fmod(scaledCoord, 256), 0));
}
```

The `passInfo.y` term is typically zero but allows sub-octave frequency offsets for specialized noise variants. The `max(1, passInfo.x)` prevents division by zero on the first pass.

```hlsl
  // First octave: add 0.5 bias to center in unsigned range (lines 153-163)
  if (relativePassIndex > 0) {
    // Subsequent passes: accumulate with previous result
    noiseValue += previousPassTexture.Sample(linearSampler, texCoord);
  } else {
    // First pass: start at 0.5 midpoint
    noiseValue += 0.5;
  }

  // Handle passes beyond maxOctave (lines 170-173)
  if (passInfo.x + 0.5 > maxOctave) {
    // Just pass through previous result unchanged
    noiseValue = previousPassTexture.Sample(linearSampler, texCoord);
  }

  return noiseValue;
}
```

The 0.5 bias on the first pass is necessary because texture formats store unsigned values. Noise oscillates around zero (ranging from -amplitude to +amplitude), but an UNORM texture can't represent negative numbers. Adding 0.5 shifts the range to [0, 1], where 0.5 represents zero noise.

## Shader Execution: Subsequent Octaves

Passes 1-7 follow the same code path but with different parameters:

**Pass 1 (Octave 1):**
- `relativePassIndex = 1`
- `cellSize = 1/8` (8×8 grid, twice the frequency of octave 0)
- `amplitude = pow(persistence, 1)` (typically 0.5 if persistence = 0.5)
- Reads previous result from `SwapBuffer`, adds new octave

**Pass 2 (Octave 2):**
- `relativePassIndex = 2`
- `cellSize = 1/16` (16×16 grid)
- `amplitude = pow(0.5, 2) = 0.25`
- Accumulates with passes 0-1

The pattern continues through pass 7, each time halving the cell size (doubling frequency) and reducing amplitude by the persistence factor. After 8 passes, the accumulated noise contains all octaves from 0-7.

Here's the complete frequency and amplitude progression for typical parameters (persistence = 0.5):

| Pass | Octave | Cell Size | Grid | Amplitude | Cumulative Range |
|------|--------|-----------|------|-----------|------------------|
| 0 | 0 | 1/4 | 4×4 | 1.0 | 0.5 ± 0.5 |
| 1 | 1 | 1/8 | 8×8 | 0.5 | 0.5 ± 0.75 |
| 2 | 2 | 1/16 | 16×16 | 0.25 | 0.5 ± 0.875 |
| 3 | 3 | 1/32 | 32×32 | 0.125 | 0.5 ± 0.9375 |
| 4 | 4 | 1/64 | 64×64 | 0.0625 | 0.5 ± 0.96875 |
| 5 | 5 | 1/128 | 128×128 | 0.03125 | 0.5 ± 0.984375 |
| 6 | 6 | 1/256 | 256×256 | 0.015625 | 0.5 ± 0.9921875 |
| 7 | 7 | 1/512 | 512×512 | 0.0078125 | 0.5 ± 0.99609375 |

The cumulative range approaches [0, 1] asymptotically. With infinite octaves and persistence = 0.5, the theoretical sum is:

```
sum(2^-n for n=0 to infinity) = 2
```

But since we add 0.5 and scale by 0.5 amplitude initially, the effective sum is 1.0 centered at 0.5, giving the range [0, 1] with a theoretical maximum deviation of ±1.0. In practice, 8 octaves provide a range of approximately [0.004, 0.996], nearly filling the available unsigned texture precision.

## Mipmap Generation

**File**: `apEx/Phoenix/Texgen.cpp:174`

After each draw call, the system generates mipmaps for the result texture:

```cpp
phxContext->GenerateMips(Target->View);
```

This is critical for two reasons. First, subsequent passes read the previous result using the linear sampler (bilinear filtering), which benefits from mipmaps when sampling at non-integer texel coordinates. Second, the final texture may be used at varying distances in the 3D scene, where mipmaps prevent aliasing.

D3D11's `GenerateMips()` uses a box filter to downsample each mip level from the previous one. The top mip (level 0) contains the full-resolution octave result. Level 1 is half resolution, level 2 is quarter resolution, and so on down to 1×1.

The cost is approximately 33% additional GPU time (1/4 + 1/16 + 1/64 + ... = 1/3 of the base level work), but this is negligible compared to the 8 fullscreen quad draws and hash texture uploads.

## Cleanup and Result

**File**: `apEx/Phoenix/Texgen.cpp:488-496`

After all 8 passes complete, the render function returns the final texture to the operator:

```cpp
// Return swap buffer to texture pool (line 488)
BackBuffer->Used = false;

// Noise has no parent textures, so this loop does nothing (lines 491-493)
for (int x = 0; x < TEXGEN_MAX_PARENTS; x++)
  if (ParentResults[x] && !Operators[Parents[x]].NeedsRender)
    ParentResults[x]->Used = false;

// Return final result (line 496)
return Result;
```

Setting `BackBuffer->Used = false` returns it to the texture pool for reuse by other operators. The pool allocates textures on-demand but reuses them aggressively to minimize GPU memory consumption. Since demos can generate dozens of textures, pooling is essential.

The parent cleanup loop (lines 491-493) releases textures that were only needed as inputs to this operator and aren't flagged for caching. For noise, there are no parents, so this has no effect. But for filter operators that combine multiple textures, this is where intermediate results get freed.

The `Result` texture persists until the scene finishes rendering and the texture pool clears. If the noise operator has `NeedsRender` set (meaning it should regenerate every frame), `CachedResult` remains NULL and the next call to `Generate()` repeats the entire process. If caching is enabled, `CachedResult` gets set to `Result` and subsequent calls return immediately at line 466.

## Performance Analysis

For a 256×256 noise texture with 8 octaves, the complete execution profile is:

**CPU overhead (per pass):**
- Hash generation: 256×256×4 = 262,144 xorshf96() calls ≈ 0.05ms
- Texture upload: 256KB system memory → GPU ≈ 0.02ms
- Constant buffer update: 68 bytes ≈ 0.001ms
- State changes (shader binding, target swap): ≈ 0.005ms
- **Total per pass**: ≈ 0.076ms
- **Total for 8 passes**: ≈ 0.6ms

**GPU workload (per pass):**
- Fullscreen quad: 256×256 = 65,536 pixels
- Per-pixel work: 4 hash texture loads + 3 lerps + 1 previous result sample
- Hash loads: 65,536 × 4 = 262,144 texture fetches (point sampling)
- Arithmetic: ~20 instructions per pixel = 1.3M instructions
- Mipmap generation: 65,536/3 additional pixels ≈ 22K pixels
- **Total per pass (assuming 1000 Mpixel/s fill rate)**: ≈ 0.087ms
- **Total for 8 passes**: ≈ 0.7ms

**Total execution time**: ≈ 1.3ms for 256×256 resolution

At 2048×2048 (the maximum common resolution for texture operators), the pixel count increases 64× to 4.2M pixels per pass, but modern GPUs can still process this in approximately 5ms per pass, or 40ms total for 8 octaves. This is acceptable for offline texture generation during scene load.

The bottleneck shifts between CPU and GPU depending on resolution. At 256×256, hash generation dominates. At 2048×2048, pixel processing dominates. The crossover point on a typical system (circa 2017 when Clean Slate was released) is around 512×512.

## Key Design Insights

**Why regenerate the hash texture every pass?**

Determinism. If hash textures were cached, they'd need to be stored in the 64k binary, consuming precious space. By regenerating from a single byte seed, each operator requires only 1 byte of storage (the `RandSeed`) instead of 256KB of texture data. Multiply this by dozens of noise operators and the savings become significant.

**Why use smoothstep instead of linear interpolation?**

Quality. Linear interpolation creates C0 continuity (values match but derivatives don't), producing visible grid artifacts when noise is used for displacement mapping or normal map generation. Smoothstep creates C1 continuity (both values and derivatives match), eliminating discontinuities. The cost is 2 additional multiplies and 1 additional add per axis (4 MAD operations total), negligible compared to texture fetch latency.

**Why accumulate octaves sequentially instead of in a single uber-shader?**

Flexibility and code size. A single shader that computes all octaves would need a compile-time constant for the octave count, requiring shader permutations for different octave ranges. The multi-pass approach uses one shader that adapts to any octave count via the pass index parameter. This reduces compiled shader size and enables runtime octave range adjustment without recompilation.

**Why use 16-bit UNORM format instead of 8-bit?**

Precision. With 8 octaves accumulating, the final result contains contributions ranging from amplitude 1.0 (octave 0) down to 0.0078 (octave 7). An 8-bit texture quantizes to 1/256 ≈ 0.004, so the finest octaves would be lost to quantization noise. A 16-bit texture quantizes to 1/65536 ≈ 0.000015, preserving all 8 octaves with minimal banding.

The HDR variant uses 16-bit FLOAT format (`R16G16B16A16_FLOAT`) instead of UNORM, enabling negative values and higher dynamic range for advanced use cases like signed displacement maps.

**Why ping-pong between two render targets instead of reading and writing the same texture?**

Hardware constraints. D3D11 forbids binding a texture simultaneously as a render target and a shader resource (reading from the same texture you're rendering to creates a feedback loop). The ping-pong pattern sidesteps this by rendering to texture A while reading from texture B, then swapping roles. This requires two textures but simplifies logic and avoids expensive resolve operations.

## Implications for Framework Design

This noise generation pipeline demonstrates several patterns relevant to creative coding frameworks:

**1. Multi-pass generators benefit from declarative pass counts.** Rather than hardcoding 8 passes, the system stores `PassCount` in `DataDescriptor`, enabling the same code path to handle noise (8 passes), turbulence (16 passes), and single-pass operations like color adjustment (1 pass).

**2. Ping-pong rendering needs built-in swap semantics.** Manually swapping pointers every iteration is error-prone. A high-level API should provide a `RenderGraph` or `PassChain` abstraction that handles swap logic automatically, presenting the previous result as a standard input texture.

**3. Texture pooling is essential for GPU memory efficiency.** Allocating and freeing textures every frame causes memory fragmentation and CPU overhead. A pooling strategy with size-based buckets (256×256, 512×512, 1024×1024, etc.) enables O(1) allocation and prevents leaks.

**4. Deterministic randomness requires seed propagation.** Exposing raw `rand()` calls to user code breaks reproducibility. Better to provide seeded PRNG instances (`Rng::from_seed(u32)`) that get passed through the call stack, ensuring identical output across runs.

**5. HLSL constant buffers map cleanly to Rust structs.** The `ShaderData` array at line 123 holds loosely typed float values copied via memcpy. A type-safe approach would define a `#[repr(C)]` struct matching the constant buffer layout, enabling structured access with compile-time field validation.

**6. Shader parameter encoding should preserve precision.** Encoding octave range as `(value * 255 - 1)` works but wastes precision for small ranges. Better to use the full byte range and decode with affine mappings (e.g., `mix(minRange, maxRange, value / 255.0)`).

## Related Systems

**Turbulence operator** (`texgen/turbulence.hlsl`) extends multi-octave noise with domain warping, where each octave samples coordinates offset by the previous octave's result. This creates more organic, fluid-like patterns than standard fractal noise.

**Cells operator** (`texgen/cells.hlsl`) implements Worley noise (cellular/Voronoi patterns) using a similar multi-pass architecture. Instead of hash texture interpolation, it searches neighboring cells for closest feature points.

**Subplasma operator** (`texgen/subplasma.hlsl`) generates plasma patterns via summed sine waves, demonstrating an alternative to hash-based noise for smooth, flowing textures.

All three share the ping-pong accumulation pattern, proving the multi-pass approach generalizes beyond Perlin noise to any frequency-additive texture generator.

## References

- Ken Perlin, "An Image Synthesizer", SIGGRAPH 1985
  https://dl.acm.org/doi/10.1145/325334.325247

- Ken Perlin, "Improving Noise", SIGGRAPH 2002
  https://mrl.cs.nyu.edu/~perlin/paper445.pdf

- Inigo Quilez, "Value Noise Derivatives"
  https://iquilezles.org/articles/morenoise/

- Stefan Gustavson, "Simplex Noise Demystified"
  http://staffwww.itn.liu.se/~stegu/simplexnoise/simplexnoise.pdf

- Texgen rendering pipeline: `notes/per-demoscene/apex-public/texgen/shaders.md`
- Texture operator architecture: `notes/per-demoscene/apex-public/texgen/generators.md`
- Hash function analysis: `notes/themes/procedural-generation.md`
