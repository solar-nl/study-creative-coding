# Phoenix Texgen Operators and Parameters

Operators are the building blocks of procedural textures. Each operator connects a shader filter to specific parameters and parent inputs, forming nodes in a texture generation graph. Understanding the operator data model is key to extending the system—or designing a similar architecture in a modern framework. The elegance lies in how Phoenix packs configuration into minimal binary structures without sacrificing expressiveness.

The challenge is balancing three competing demands. First, operators must serialize compactly—a 64k demo can't afford verbose data formats. Second, parameters must cover diverse semantic meanings: angles, colors, channel selectors, iteration counts, scales. Third, shaders must interpret byte-encoded parameters efficiently without branching overhead. Phoenix solves this through convention-based encoding: all parameters are bytes (0-255), but shaders interpret them differently based on context.

Think of operators like recipe cards in a cooking database. Each card specifies a technique (the filter), ingredients (parent operators), and precise measurements (parameters). The recipe for "brushed metal" might call for noise generation (technique 1) with frequency 0.6 and octaves 5 (measurements), mixing in directional blur (technique 7) along angle 45° (another measurement). The compact encoding means each recipe card fits in ~48 bytes, yet describes arbitrarily complex generation logic.

## PHXTEXTUREFILTER: The Filter Descriptor

The filter describes a shader's capabilities and requirements. It's a static template that multiple operators can instantiate with different parameter values. Each filter compiles once from HLSL source during engine initialization, creating a pixel shader and metadata descriptor.

```cpp
class PHXTEXTUREFILTER {
public:
  PHXFILTERDATADESCRIPTOR DataDescriptor;
  ID3D11PixelShader *PixelShader;

  void Render(CphxTexturePoolTexture *&Target,
              CphxTexturePoolTexture *&SwapBuffer,
              CphxTexturePoolTexture *Inputs[3],
              unsigned char RandSeed,
              unsigned char Parameters[16],
              void *ExtraData, int ExtraDataSize);

  virtual CphxTexturePoolTexture *GetLookupTexture(unsigned char Res,
                                                    void *ExtraData,
                                                    int ExtraDataSize);
};
```

The `PixelShader` pointer references the compiled GPU shader. The `DataDescriptor` packs filter metadata into a 16-bit bitfield. The `Render()` method orchestrates multi-pass execution. The `GetLookupTexture()` method generates auxiliary textures (image data, random noise, text rendering) based on the filter's needs.

### PHXFILTERDATADESCRIPTOR Bitfield Layout

The descriptor (Texgen.h:66-73) compresses all filter metadata into 16 bits:

```cpp
struct PHXFILTERDATADESCRIPTOR {
  unsigned int NeedsRandSeed : 1;     // Shader uses random seed?
  unsigned int InputCount : 2;        // Number of parent textures (0-3)
  unsigned int ParameterCount : 5;    // Number of byte parameters (0-31)
  unsigned int PassCount : 4;         // Multi-pass iteration count (1-15)
  unsigned int LookupType : 4;        // Lookup texture type (0-4)
};
```

**Bitfield breakdown**:

| Field | Bits | Range | Description |
|-------|------|-------|-------------|
| NeedsRandSeed | 1 | 0-1 | Filter behavior depends on random seed |
| InputCount | 2 | 0-3 | Number of parent textures required |
| ParameterCount | 5 | 0-31 | Number of byte parameters consumed |
| PassCount | 4 | 1-15 | Number of rendering passes (for iterative algorithms) |
| LookupType | 4 | 0-4 | Type of auxiliary texture (none/image/text/spline/hash) |

This packing enables compact serialization. Reading an operator from a binary stream involves checking the filter's descriptor to know how many parameter bytes and parent indices follow. A filter with `ParameterCount = 8` consumes 8 bytes from the stream. A filter with `InputCount = 2` expects two parent indices.

**NeedsRandSeed** flags filters that produce different outputs for different seeds. Noise generators, particle distributions, and dither patterns set this to 1. Deterministic filters (blur, colorize, gradients) set it to 0.

**InputCount** defines parent texture requirements. Generators like Perlin noise have `InputCount = 0`. Transforms like blur or colorize have `InputCount = 1`. Blend modes have `InputCount = 2`. Three-way blends have `InputCount = 3`.

**PassCount** enables iterative algorithms. A single-pass blur has `PassCount = 1`. A separable blur (horizontal then vertical) has `PassCount = 2`. A multi-octave noise accumulator might have `PassCount = 8`, adding one octave per pass.

**LookupType** triggers auxiliary texture generation:

| Type | Value | Purpose | Example Filter |
|------|-------|---------|----------------|
| None | 0 | No lookup needed | Gradient, solid color |
| Image | 1 | Load embedded image | Logo overlay, texture decal |
| Text | 2 | Render text via GDI | Dynamic text generation |
| Spline | 3 | Sample color curves | Color grading LUT |
| Hash | 4 | Generate random noise | Perlin noise basis |

The descriptor packs into 16 bits (2 bytes), making it trivially serializable. Filter metadata stores alongside compiled shader code in the filter registry.

## PHXTEXTUREOPERATOR: The Operator Instance

An operator instantiates a filter with specific configuration. It's a node in the operator graph, storing indices to parent nodes, parameter bytes, and runtime state (Texgen.h:105-124):

```cpp
struct PHXTEXTUREOPERATOR {
  unsigned char Resolution;         // Packed X/Y resolution (4 bits each)
  unsigned char Filter;             // Filter index (bit 7 = HDR flag)
  unsigned char RandSeed;           // Seed for reproducible randomness
  short Parents[3];                 // Parent operator indices (-1 = none)
  unsigned char Parameters[16];     // Filter parameters (0-255 each)

  bool NeedsRender;                 // Persist result after evaluation?
  CphxTexturePoolTexture *CachedResult;  // Memoization cache

  int minimportData2;               // Extra data size / text pointer
  void *minimportData;              // Extra data pointer

  CphxTexturePoolTexture *Generate(PHXTEXTUREFILTER *Filters,
                                    PHXTEXTUREOPERATOR *Operators);
};
```

### Resolution Encoding

The `Resolution` byte packs independent X and Y dimensions into high and low nibbles:

```cpp
#define GETXRES(x) (1 << (x >> 4))      // High nibble → width
#define GETYRES(y) (1 << (y & 0x0f))    // Low nibble → height
```

This encoding saves space while supporting non-square textures. Each nibble ranges from 0-15, representing dimensions from 1 pixel to 32768 pixels:

| Hex Value | Binary | X Resolution (bits 4-7) | Y Resolution (bits 0-3) | Texture Size |
|-----------|--------|-------------------------|-------------------------|--------------|
| `0x44` | `0100 0100` | 1 << 4 = 16 | 1 << 4 = 16 | 16×16 |
| `0x66` | `0110 0110` | 1 << 6 = 64 | 1 << 6 = 64 | 64×64 |
| `0x88` | `1000 1000` | 1 << 8 = 256 | 1 << 8 = 256 | 256×256 |
| `0xAA` | `1010 1010` | 1 << 10 = 1024 | 1 << 10 = 1024 | 1024×1024 |
| `0xA8` | `1010 1000` | 1 << 10 = 1024 | 1 << 8 = 256 | 1024×256 |
| `0x53` | `0101 0011` | 1 << 5 = 32 | 1 << 3 = 8 | 32×8 |

**Power-of-two restriction**: This scheme only supports power-of-two dimensions. You cannot represent 800×600 or 1280×720. For creative coding and demos, this is acceptable—GPU mipmapping works best with power-of-two textures, and most effects don't require arbitrary dimensions.

**Memory trade-off**: A 1280×720 video texture must round up to 2048×1024 (8MB instead of 3.5MB). This wastes VRAM but simplifies the system. In practice, demos use high resolutions only where needed (final composites) and lower resolutions for intermediate effects.

### Filter Index and HDR Flag

The `Filter` byte encodes two pieces of information:

```cpp
unsigned char Filter = 0x85;  // Example

int filterIndex = Filter & 0x7f;       // Lower 7 bits → index 5
bool isHDR = (Filter >> 7) != 0;       // Bit 7 → HDR flag (true)
```

**Filter index** (bits 0-6) references the global filter array. Value 0 maps to filter 0 (typically Perlin noise), value 1 to filter 1 (Voronoi cells), etc. The system supports up to 128 filters.

**HDR flag** (bit 7) controls texture format:
- `0` → `DXGI_FORMAT_R16G16B16A16_UNORM` (values clamped to [0,1])
- `1` → `DXGI_FORMAT_R16G16B16A16_FLOAT` (values support full float range)

HDR textures enable bloom effects (bright pixels exceed 1.0), tone mapping (wide dynamic range), and physical light units (lumens, candelas). Most operators use standard UNORM format.

### Parent Indices

The `Parents[3]` array stores indices into the global operator array:

```cpp
short Parents[3] = {2, 5, -1};
```

**Valid indices** point to operators that must evaluate before this one. In the example, this operator depends on operators 2 and 5.

**-1 sentinel** indicates "no parent in this slot." The example has 2 parents (indices 0 and 1 occupied) with slot 2 unused.

**Graph structure**: Parents form edges in a directed acyclic graph (DAG). An operator can depend on earlier operators, but those parents can't create cycles back to descendants. This guarantees a topological evaluation order exists.

### Random Seed

The `RandSeed` byte initializes the C standard library PRNG before filter rendering:

```cpp
srand(RandSeed);  // Seed the PRNG
float random1 = rand() / (float)RAND_MAX;  // Generate random values
```

Changing the seed produces different procedural variations of the same filter configuration. A Perlin noise operator with seed 42 generates different noise than seed 73, even with identical parameters.

**Determinism**: The same seed produces the same output every time. This enables reproducible generation—crucial for debugging and tweaking parameters without random variation.

### Parameters Array

The `Parameters[16]` array stores filter-specific configuration as unsigned bytes:

```cpp
unsigned char Parameters[16] = {
  128,  // Parameter 0
  64,   // Parameter 1
  255,  // Parameter 2
  0,    // Parameter 3
  // ... 12 more bytes
};
```

Each parameter normalizes to 0.0-1.0 in shaders by dividing by 255:

```cpp
float param0 = Parameters[0] / 255.0f;  // 128 / 255 ≈ 0.502
float param1 = Parameters[1] / 255.0f;  // 64 / 255 ≈ 0.251
```

This quantization trades precision for size. 256 levels of precision suffice for most visual parameters (opacity, frequency, hue shifts). The alternative—storing 16 floats—consumes 64 bytes instead of 16.

### NeedsRender Flag

The `NeedsRender` boolean controls memory management:

```cpp
bool NeedsRender = true;   // Keep result cached for scene rendering
bool NeedsRender = false;  // Release result after child operators consume it
```

**true**: This operator's output is referenced by materials or must persist for later use. The texture remains allocated in the pool.

**false**: This operator is an intermediate step. After downstream operators consume its result, the texture releases back to the pool for reuse.

Example: A blur operator (operator 10) blurs a noise texture (operator 5). If operator 10's result feeds into a material, `NeedsRender = true`. If operator 10 feeds only into operator 15 (colorize), and operator 15 has `NeedsRender = true`, then operator 10 can set `NeedsRender = false` to release its texture once operator 15 finishes.

### CachedResult Pointer

The `CachedResult` pointer implements memoization:

```cpp
CphxTexturePoolTexture *CachedResult = NULL;  // Not yet generated
CphxTexturePoolTexture *CachedResult = <ptr>; // Generated and cached
```

The `Generate()` method checks this pointer first:

```cpp
if (CachedResult) return CachedResult;  // Cache hit → return instantly
```

This prevents redundant computation. If operators 10 and 12 both depend on operator 5, the first call to `Generate(5)` computes the result and caches it. The second call returns the cached texture without re-executing the filter.

### Extra Data Pointers

The `minimportData` and `minimportData2` fields store auxiliary data for special filter types:

```cpp
void *minimportData;      // Pointer to image bytes, text string, or spline array
int minimportData2;       // Data size (images) or text pointer (text filters)
```

**Image loading** (`LookupType = 1`):
- `minimportData` → pointer to compressed image bytes (PNG/JPG/DDS)
- `minimportData2` → byte count

**Text rendering** (`LookupType = 2`):
- `minimportData` → pointer to `PHXTEXTDATA` struct (font, size, position)
- `minimportData2` → *actually used as a char pointer to the text string* (quirk)

**Spline sampling** (`LookupType = 3`):
- `minimportData` → array of 4 `CphxSpline_float16*` pointers (RGBA curves)
- `minimportData2` → unused

**Hash generation** (`LookupType = 4`):
- Both unused (hash generates from seed alone)

The text filter's use of `minimportData2` as a string pointer instead of size is a quirk of the implementation. See Texgen.cpp:276 where it casts `(char*)ExtraDataSize` to get the string.

## Parameter Encoding Conventions

Since all parameters are bytes (0-255), different semantic meanings emerge through shader-side interpretation. Phoenix uses several conventions consistently across filters.

### Normalized Float (0.0 - 1.0)

The most common convention: divide by 255 to get 0.0-1.0 range.

```hlsl
float persistence = data1.z;  // Direct use: already normalized
```

**Use cases**: Opacity, blend factors, normalized intensity, persistence values.

### Byte Value (0 - 255)

Multiply by 255/256 to preserve byte precision while mapping to float:

```hlsl
float minOctave = data1.x * 255.0;  // Maps 0-255 exactly
```

The `* 255 / 256` pattern appears when exact integer semantics matter. Dividing by 256 ensures the maximum value (255) doesn't wrap to 0.

**Use cases**: Octave counts, iteration limits, discrete levels.

### Angle (0 - 2π radians)

Map 0-255 to full circle rotation:

```hlsl
float angle = data1.x * 255.0 / 256.0 * 3.14159265 * 2.0;  // 0 to 2π
```

The `255/256` factor prevents the maximum byte value from wrapping to 0° (full circle back to start).

**Use cases**: Rotation angles, hue shifts (with different scaling), directional blur.

### Integer Count (0 - 255)

Cast to integer after scaling:

```hlsl
int mode = (int)(data1.w * 256);  // 0-255 integer
```

The `* 256` factor ensures byte value 255 maps to integer 255, not 254.

**Use cases**: Channel selection (0=R, 1=G, 2=B, 3=A), interpolation mode, blend mode index.

### Signed Range (-1.0 - +1.0)

Center at 0.5, then remap:

```hlsl
float signed = (data1.x - 0.5) * 2.0;  // Maps 0→-1, 128→0, 255→1
```

**Use cases**: Contrast adjustments, brightness offsets, bidirectional shifts.

### Scale Multiplier

Multiply by filter-specific constant:

```hlsl
float scale = data1.y * 4.0;  // Maps 0-255 to 0-1020
```

**Use cases**: Saturation multipliers (0-4×), blur radius (pixels), UV scale.

### Color Parameters (4 consecutive bytes)

Colors occupy 4 parameter slots (RGBA):

```hlsl
float4 Color1 : register(c1);  // Parameters 0-3 as RGBA
float4 Color2 : register(c2);  // Parameters 4-7 as RGBA
```

The constant buffer automatically packs 4 sequential bytes into a `float4` register. Each component normalizes to 0.0-1.0:

```cpp
// CPU side
Parameters[0] = 255;  // Red
Parameters[1] = 128;  // Green
Parameters[2] = 64;   // Blue
Parameters[3] = 255;  // Alpha

// GPU side
float4 Color1 = float4(1.0, 0.502, 0.251, 1.0);
```

**Use cases**: Colorize filter (gradient colors), solid color generator, tint colors.

### Practical Examples from Shaders

Let's trace how specific filters interpret parameters, grounding these conventions in real code.

#### Example 1: Perlin Noise (noise.hlsl)

From the annotated shader (lines 71-74):

```hlsl
float minOctave = texgenParams.x * 255 - 1;   // Byte value with offset
float maxOctave = texgenParams.y * 255;       // Byte value
float persistence = texgenParams.z;            // Normalized (0-1)
int mode = (int)(texgenParams.w * 256);        // Integer count
```

**Parameter mapping**:
- **Param 0** (`minOctave`): Byte value offset by -1. Value 0 → octave -1, value 5 → octave 4.
- **Param 1** (`maxOctave`): Byte value. Value 5 → 5 octaves.
- **Param 2** (`persistence`): Normalized. Value 128 → 0.5 (each octave half the amplitude).
- **Param 3** (`mode`): Integer. Value 0 → smoothstep interpolation, value 1 → linear.

**Why the offset?** Multi-octave noise often starts below octave 0 for very coarse features. The -1 offset enables octave -1 (extremely low frequency) as a base.

#### Example 2: Colorize (colorize.hlsl)

From the annotated shader (lines 32-34, 42-45):

```hlsl
float4 Color1 : register(c1);  // Parameters 0-3
float4 Color2 : register(c2);  // Parameters 4-7
float4 texgenParams : register(c3);

int controlChannel = (int)(texgenParams.x * 256);  // Parameters 8-11
float factor = inputTexture.Sample(linearSampler, texCoord)[controlChannel];
return lerp(Color1, Color2, factor);
```

**Parameter mapping**:
- **Params 0-3**: Color1 (RGBA) at input value 0
- **Params 4-7**: Color2 (RGBA) at input value 1
- **Param 8**: Channel selector (0=R, 1=G, 2=B, 3=A)

**Usage**: Set Color1 to blue (0, 0, 255, 255), Color2 to red (255, 0, 0, 255), channel to 0 (red channel). The filter maps input red values to a blue→red gradient.

#### Example 3: Rotozoom (rotozoom.hlsl)

From the annotated shader (lines 44-54):

```hlsl
float2 center = texgenParams.zw * 255.0 / 256.0;  // Center point (0-1 range)
float zoom = 0.25 / (texgenParams.y * 255.0 / 256.0);  // Inverse zoom
float angle = texgenParams.x * 255.0 / 256.0 * 3.14159265 * 2.0;  // Angle in radians
```

**Parameter mapping**:
- **Param 0**: Rotation angle (0-255 → 0-2π radians)
- **Param 1**: Zoom factor (0-255 → inverse scale)
- **Params 2-3**: Center point (0-255 → 0-1 UV coordinates)

**Zoom math**: The `0.25 /` creates an inverse relationship. Param value 255 → zoom 0.25/0.996 ≈ 0.25× (large). Param value 1 → zoom 0.25/0.004 ≈ 64× (small). This inverted encoding feels intuitive: larger param values = more zoom out.

#### Example 4: HSL Adjustment (hsl.hlsl)

From the annotated shader (lines 112, 121-137):

```hlsl
float4 params = texgenParams / 256 * 255;  // Normalize with precision

color.x += params.x * 6;  // Hue rotation (0-6 units = full color wheel)
color.y *= params.y * 4;  // Saturation multiplier (0-4×)

if (params.z < 0.5)
    color.z *= params.z * 2;  // Darken: 0 = black, 0.5 = unchanged
else
    color.z = lerp(color.z, 1, (params.z - 0.5) * 2);  // Brighten: 1 = white
```

**Parameter mapping**:
- **Param 0**: Hue shift (0-255 → 0-6 hue units, wrapping around color wheel)
- **Param 1**: Saturation multiplier (0-255 → 0-4×)
- **Param 2**: Lightness (0-127 darkens, 128 unchanged, 129-255 brightens)

**Split semantics**: Param 2 uses a midpoint split. Values below 0.5 darken by multiplying value. Values above 0.5 brighten by lerping toward 1. This dual behavior enables both darkening and brightening with a single parameter.

#### Example 5: Blur (blur.hlsl)

From the annotated shader (lines 42-49, 55-56):

```hlsl
float xMultiplier = 1;
float yMultiplier = 0;
if (passInfo.x + 0.5 >= 3)  // Pass 3 and beyond
{
    xMultiplier = 0;
    yMultiplier = 1;
}

float2 blurRadius = float2(texgenParams.x * xMultiplier, texgenParams.y * yMultiplier);
```

**Parameter mapping**:
- **Param 0**: X blur radius (0-255 → 0-1.0 UV space)
- **Param 1**: Y blur radius (0-255 → 0-1.0 UV space)

**Multi-pass strategy**: Passes 0-2 blur horizontally (xMultiplier=1, yMultiplier=0). Passes 3+ blur vertically (xMultiplier=0, yMultiplier=1). This separable approach requires 2 passes but reduces samples from N² to 2N.

**UV space blur**: The radius is in 0-1 UV coordinates, not pixels. A value of 0.1 blurs 10% of texture width/height. This scale-independent approach means the same parameter works across different resolutions.

## Channel Selection Parameters

Many filters operate on a single channel extracted from an RGBA texture:

```hlsl
int channel = (int)(Data1.x * 256);  // 0=R, 1=G, 2=B, 3=A
float value = texture.Sample(sampler, uv)[channel];
```

The array index operator `[channel]` extracts the component. Channel 0 is red, 1 is green, 2 is blue, 3 is alpha.

**Use cases**:
- **Colorize**: Map selected channel to color gradient
- **Channel swap**: Extract one channel, write to different output channel
- **Luminance**: Extract and process brightness (typically R or average of RGB)

Example from colorize.hlsl (line 42):

```hlsl
int controlChannel = (int)(texgenParams.x * 256);
float factor = inputTexture.Sample(linearSampler, texCoord)[controlChannel];
return lerp(Color1, Color2, factor);
```

If `controlChannel = 0`, the filter uses the input's red channel to drive the gradient interpolation.

## Filter Categories with Input/Output Specifications

Phoenix's ~37 filters span six functional categories. Understanding these categories helps predict parameter needs and input requirements.

| Category | Typical Inputs | Output Type | Examples |
|----------|----------------|-------------|----------|
| **Generators** | 0 | RGBA pattern | Perlin noise, Voronoi cells, gradient, tiles |
| **Transforms** | 1 | UV-remapped input | Rotozoom, mirror, pixelize, polar transform |
| **Color Ops** | 1 | Color-modified input | HSL adjust, colorize, curves, contrast |
| **Blending** | 2 | Combined inputs | Blend modes (add/multiply), mix, mixmap |
| **Filters** | 1 | Filtered input | Blur, sharpen, smoothstep, directional blur |
| **Normal Maps** | 1 | Normal vector RGB | Normal from height, glass (refraction normal) |

**Generators** create textures from mathematical formulas and random seeds. Parameters control frequency, amplitude, color stops, tile counts. Examples:
- Perlin noise: frequency, octaves, persistence, interpolation mode
- Gradient: angle, color stops, falloff

**Transforms** manipulate UV coordinates before sampling the input. Parameters control geometric transformations. Examples:
- Rotozoom: angle, zoom, center point
- Mirror: axis, offset
- Polar: center point, radius scale

**Color Ops** adjust or remap colors. Parameters control color space transformations and mapping curves. Examples:
- HSL: hue shift, saturation multiplier, lightness
- Colorize: two gradient colors, control channel
- Contrast: contrast factor, brightness offset

**Blending** combines multiple inputs using composition math. Parameters select blend modes and mixing ratios. Examples:
- Combine: blend mode (add, multiply, screen, overlay)
- Mix: blend factor (0=input1, 1=input2)
- Mixmap: blend mask (third input controls per-pixel blend)

**Filters** apply image processing kernels. Parameters control kernel size and direction. Examples:
- Blur: X radius, Y radius
- Directional blur: angle, distance
- Sharpen: intensity

**Normal Maps** convert height fields to surface normals for lighting. Parameters control strength and edge behavior. Examples:
- Normalmap: height scale, wrap mode
- Glass: refraction index, thickness

## Special Filter Constants

Four filter indices are reserved for special handling (Texgen.h:100-103):

```cpp
#define FILTER_SUBROUTINECALL  255
#define FILTER_IMAGELOAD       254
#define FILTER_TEXTDISPLAY     253
#define FILTER_SPLINE          252
```

These aren't shader filters but signal special execution paths:

**FILTER_SUBROUTINECALL (255)**: The operator invokes a subroutine (reusable operator subgraph). The `minimportData` pointer references a `PHXTEXTURESUBROUTINE` struct containing the embedded operator array.

**FILTER_IMAGELOAD (254)**: Load a pre-compressed image from `minimportData`. This bypasses the normal shader execution path, directly creating a texture from embedded PNG/JPG/DDS bytes.

**FILTER_TEXTDISPLAY (253)**: Render text to a texture using GDI. The `minimportData` points to `PHXTEXTDATA` (font, size, position), and `minimportData2` holds the text string pointer.

**FILTER_SPLINE (252)**: Sample a set of splines into a 1D lookup texture. The `minimportData` array contains 4 `CphxSpline_float16*` pointers for RGBA curves.

These constants enable the graph evaluation code to branch on filter type without needing virtual functions or runtime type information. A simple switch statement dispatches to the appropriate handler.

## State and Caching System

The operator's runtime state controls memory management and evaluation caching. Two key mechanisms work together: the `CachedResult` pointer and the `NeedsRender` flag.

### Caching Strategy

The `Generate()` method implements memoization:

```cpp
CphxTexturePoolTexture *PHXTEXTUREOPERATOR::Generate(
    PHXTEXTUREFILTER *Filters,
    PHXTEXTUREOPERATOR *Operators)
{
    // Cache hit: return instantly
    if (CachedResult != NULL)
        return CachedResult;

    // Cache miss: generate recursively
    // ... evaluate parents, allocate targets, render filter ...

    // Cache for reuse
    CachedResult = result;
    return result;
}
```

**First call**: `CachedResult` is NULL. The method evaluates parents, allocates render targets, executes the filter, and caches the result.

**Subsequent calls**: `CachedResult` is non-NULL. The method returns immediately without re-executing the filter. The cached texture pointer remains valid until the operator resets or the pool clears.

**Diamond dependencies**: If operators 10 and 12 both depend on operator 5, the first consumer's call to `Generate(5)` caches the result. The second consumer gets the cached texture without redundant computation.

### Release Strategy

After an operator finishes rendering, it checks whether parent results should persist:

```cpp
// Release parent results if no longer needed
for (int x = 0; x < TEXGEN_MAX_PARENTS; x++)
    if (ParentResults[x] && !Operators[Parents[x]].NeedsRender)
        ParentResults[x]->Used = false;
```

The `NeedsRender` flag controls lifetime:
- **true**: Texture persists for scene rendering (referenced by materials)
- **false**: Texture releases after child operators consume it

**Memory lifecycle example**:

```
Operator 0: Generate noise (NeedsRender=false)
  ↓ Allocates Texture A
Operator 1: Blur noise (NeedsRender=false)
  ↓ Allocates Texture B, reads A
  ↓ After render: A.Used = false (parent not needed)
Operator 2: Colorize blur (NeedsRender=true)
  ↓ Allocates Texture C, reads B
  ↓ After render: B.Used = false (parent not needed)
  ↓ C persists (referenced by material)
```

The pool created 3 textures but only C remains allocated. A and B released immediately after downstream operators consumed them. This minimizes peak VRAM usage.

### Texture Pool Integration

The `Used` flag on `CphxTexturePoolTexture` tracks allocation state:

```cpp
class CphxTexturePoolTexture {
public:
    bool Used;     // Currently allocated to an operator?
    bool Deleted;  // Marked for cleanup?
    // ...
};
```

When an operator calls `TexgenPool->GetTexture()`, the pool searches for a matching texture with `Used = false`. If found, it marks `Used = true` and returns the texture. If not found, it allocates a new texture.

When an operator releases a texture (`Used = false`), it returns to the pool for reuse by subsequent allocations.

## Constant Buffer Binding

Parameters reach the GPU through a constant buffer updated per render. The `Render()` method (Texgen.cpp:151-158) packs parameters into a float array:

```cpp
float ShaderData[TEXGEN_MAX_PARAMS + 4];

ShaderData[0] = (float)passIndex;                // Current pass number
ShaderData[1] = rand() / (float)RAND_MAX;        // Random X
ShaderData[2] = rand() / (float)RAND_MAX;        // Random Y
ShaderData[3] = rand() / (float)RAND_MAX;        // Random Z

for (int y = 0; y < TEXGEN_MAX_PARAMS; y++)
    ShaderData[y + 4] = Parameters[y] / 255.0f;  // Normalized parameters
```

This array maps to GPU constant buffer layout:

```
Byte Offset   Content                   HLSL Register   HLSL Access
-----------   ----------------------    -------------   -----------
0-15          Pass metadata             c0              PassData.xyzw
16-31         Parameters 0-3            c1              data1.xyzw
32-47         Parameters 4-7            c2              data2.xyzw
48-63         Parameters 8-11           c3              data3.xyzw
64-79         Parameters 12-15          c4              data4.xyzw
```

Shaders declare:

```hlsl
cbuffer ShaderData : register(b0) {
    float4 PassData;    // x=passIndex, yzw=random
    float4 data1;       // Parameters 0-3
    float4 data2;       // Parameters 4-7
    float4 data3;       // Parameters 8-11
    float4 data4;       // Parameters 12-15
};
```

**Pass index** (`PassData.x`) enables shaders to adjust behavior per iteration. Multi-octave noise uses this to scale frequency exponentially.

**Random values** (`PassData.yzw`) provide per-pass entropy seeded by `RandSeed`. Dithering or stochastic sampling can use these for variation.

**Parameter packing**: Every 4 consecutive parameters pack into one `float4` register. This aligns with GPU hardware—constant buffers organize in 16-byte (4-float) chunks.

## Subroutine Parameter Overrides

Subroutines (`PHXTEXTURESUBROUTINE`, Texgen.h:135-149) enable reusable operator graphs with dynamic configuration:

```cpp
struct PHXTEXTUREPARAMETEROVERRIDE {
  unsigned char TargetOperator;   // Which operator in subgraph
  unsigned char TargetParameter;  // Which parameter byte
};

struct PHXTEXTURESUBROUTINE {
  PHXTEXTUREOPERATOR Operators[256];  // Embedded operator graph
  unsigned char Output;               // Output operator index
  unsigned char Inputs[3];            // Input operator indices
  unsigned char DynamicParameterCount;
  PHXTEXTUREPARAMETEROVERRIDE DynamicParameters[16];
  // ...
};
```

**Calling convention**: When a caller invokes a subroutine, it passes parameters that override specific operator/parameter pairs in the embedded graph.

**Example**: A "brushed metal" subroutine might have:
- Operator 3: Directional blur
- Operator 5: Colorize

The caller wants to control blur angle and metal tint. It sets:

```cpp
DynamicParameters[0] = {TargetOperator: 3, TargetParameter: 0};  // Blur angle
DynamicParameters[1] = {TargetOperator: 5, TargetParameter: 0};  // Tint R
DynamicParameters[2] = {TargetOperator: 5, TargetParameter: 1};  // Tint G
```

When `PHXTEXTURESUBROUTINE::Generate()` executes (Texgen.cpp:513-514), it patches these values:

```cpp
for (int x = 0; x < DynamicParameterCount; x++)
    Operators[DynamicParameters[x].TargetOperator]
        .Parameters[DynamicParameters[x].TargetParameter] = Parameters[x];
```

This enables reusable abstractions. The tool defines complex effects once, then invokes them with varying parameters across multiple textures.

## Extra Data Handling

Some filters need data beyond parameters and parents. The `minimportData` and `minimportData2` fields provide this, with interpretation depending on `LookupType`:

### Image Loading (LookupType = 1)

`minimportData` points to compressed image bytes (PNG/JPG/DDS). `minimportData2` holds the byte count.

```cpp
if (D3DX11CreateTextureFromMemory(phxDev, ExtraData, ExtraDataSize,
                                   NULL, NULL, (ID3D11Resource**)&out->Texture,
                                   NULL) == S_OK)
{
    phxDev->CreateShaderResourceView(out->Texture, NULL, &out->View);
    return out;
}
```

The loader uses D3DX11 to decompress and upload the image. This enables embedding logos, decals, or reference images in the demo.

### Text Rendering (LookupType = 2)

`minimportData` points to `PHXTEXTDATA` struct (font, size, position). `minimportData2` is cast to a `char*` string pointer (quirk).

```cpp
PHXTEXTDATA *t = (PHXTEXTDATA*)ExtraData;
char *text = (char*)ExtraDataSize;  // Actually the string pointer

HFONT hf = CreateFontA((t->Size * XRes) >> 8, 0, 0, 0,
                       t->Bold ? FW_BOLD : FW_NORMAL, t->Italic,
                       FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                       CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY,
                       DEFAULT_PITCH, EngineFontList[t->Font]);

TextOut(mdc, 0, 0, text, len);
```

The code creates a GDI font, renders the text to a bitmap, and copies the bitmap to a GPU texture. This enables procedural text generation (titles, credits, UI).

### Spline Sampling (LookupType = 3)

`minimportData` is an array of 4 `CphxSpline_float16*` pointers (RGBA curves). The code samples each spline at 4096 points, creating a 4096×1 lookup texture:

```cpp
CphxSpline_float16 **splines = (CphxSpline_float16**)ExtraData;
for (int x = 0; x < 4096; x++) {
    float t = x / 4095.0f;
    for (int i = 0; i < 4; i++) {
        splines[i]->CalculateValue(t);
        ((unsigned short*)ImageData)[x * 4 + i] =
            (unsigned short)(clamp(splines[i]->Value[0], 0, 1) * 65535);
    }
}
```

Shaders sample this texture as a 1D color LUT for curves, tone mapping, or gradients.

### Hash Generation (LookupType = 4)

No extra data needed. The code generates a 256×256 texture filled with pseudorandom bytes using xorshf96 PRNG:

```cpp
rndx = rand();  // Seed from srand(RandSeed)
rndy = 362436069;
rndz = 521288629;
for (int x = 0; x < XRes * YRes * 4; x++)
    ImageData[x] = (unsigned char)xorshf96();
```

This creates a high-frequency random texture for Perlin noise gradients or dithering patterns.

## Practical Example: Noise Operator Configuration

Let's configure a complete operator for multi-octave Perlin noise:

```cpp
PHXTEXTUREOPERATOR noiseOp = {
    .Resolution = 0x88,        // 256×256 (nibbles: 8,8 → 1<<8 = 256)
    .Filter = 0x00,            // Filter 0 (noise.hlsl), standard UNORM
    .RandSeed = 42,            // Seed for reproducible noise
    .Parents = {-1, -1, -1},   // No inputs (generator)
    .Parameters = {
        0,    // Min octave: 0 * 255 - 1 = -1 → octave -1
        128,  // Max octave: 128 * 255 / 255 = 128 → ~5 octaves
        128,  // Persistence: 128 / 255 ≈ 0.5 (each octave half amplitude)
        0,    // Mode: 0 → smoothstep interpolation
        // Remaining 12 parameters unused by noise filter
    },
    .NeedsRender = true,       // Keep cached for material reference
    .CachedResult = NULL,      // Not yet generated
    .minimportData = NULL,     // Noise uses hash lookup (type 4)
    .minimportData2 = 0,
};
```

**Resolution 0x88**: High nibble 8 → width = 1<<8 = 256. Low nibble 8 → height = 1<<8 = 256. Square 256×256 texture.

**Filter 0x00**: Lower 7 bits = 0 (noise filter index), bit 7 = 0 (standard UNORM format).

**RandSeed 42**: Deterministic seed. Same seed → same noise pattern. Change to 73 → different pattern with same configuration.

**Parameters**:
- `[0] = 0` → Min octave -1 (very coarse)
- `[1] = 128` → Max octave 5 (moderately fine)
- `[2] = 128` → Persistence 0.5 (standard fractal brownian motion)
- `[3] = 0` → Smoothstep interpolation (eliminates grid artifacts)

**Expected shader behavior**:
1. Generate hash lookup texture (256×256 random values)
2. Execute 6 passes (octaves -1 through 4)
3. Each pass scales frequency by 2^passIndex
4. Each pass scales amplitude by 0.5^relativePass
5. Accumulate results with 0.5 bias (centered around 0.5)
6. Output: organic noise texture from 0.0 to 1.0

This 48-byte operator (plus minimal overhead) generates an 8MB texture (256×256×8 bytes) with full mipmap chain (~10.67MB total).

## Implications for Rust Framework

Phoenix's operator and parameter system offers valuable patterns for modern creative coding frameworks targeting procedural generation or size constraints.

### Adopt: Compact Byte-Encoded Parameters

Store parameters as `[u8; 16]` for serialization, normalize to `f32` in shaders. This balances disk/memory footprint with precision:

```rust
#[repr(C)]
#[derive(Copy, Clone, bytemuck::Pod, bytemuck::Zeroable)]
pub struct OperatorParams {
    bytes: [u8; 16],
}

impl OperatorParams {
    pub fn as_floats(&self) -> [f32; 16] {
        self.bytes.iter().map(|&b| b as f32 / 255.0).collect()
    }

    pub fn set_color(&mut self, index: usize, color: [u8; 4]) {
        self.bytes[index..index+4].copy_from_slice(&color);
    }
}
```

This approach saves 48 bytes per operator (16 bytes vs 64) while providing adequate precision for visual parameters.

### Adopt: Bitfield-Based Filter Descriptors (with Rust enums)

Phoenix's `PHXFILTERDATADESCRIPTOR` packs efficiently, but Rust can improve type safety:

```rust
pub struct FilterDescriptor {
    pub needs_rand_seed: bool,
    pub input_count: u8,       // 0-3
    pub parameter_count: u8,   // 0-31
    pub pass_count: u8,        // 1-15
    pub lookup_type: LookupType,
}

pub enum LookupType {
    None,
    Image,
    Text,
    Spline,
    Hash,
}

impl FilterDescriptor {
    pub fn to_packed(&self) -> u16 {
        let mut packed: u16 = 0;
        packed |= (self.needs_rand_seed as u16) << 0;
        packed |= (self.input_count as u16) << 1;
        packed |= (self.parameter_count as u16) << 3;
        packed |= (self.pass_count as u16) << 8;
        packed |= (self.lookup_type as u16) << 12;
        packed
    }

    pub fn from_packed(packed: u16) -> Self {
        FilterDescriptor {
            needs_rand_seed: (packed & 0x0001) != 0,
            input_count: ((packed >> 1) & 0x0003) as u8,
            parameter_count: ((packed >> 3) & 0x001F) as u8,
            pass_count: ((packed >> 8) & 0x000F) as u8,
            lookup_type: LookupType::from_bits((packed >> 12) & 0x000F),
        }
    }
}
```

This maintains serialization compatibility while providing type-safe access and clear documentation.

### Adopt: Resolution as Strongly-Typed Struct

Replace packed bytes with explicit struct:

```rust
#[derive(Copy, Clone, PartialEq, Eq, Debug)]
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

    pub fn to_packed(&self) -> Result<u8, String> {
        if !self.width.is_power_of_two() || !self.height.is_power_of_two() {
            return Err("Resolution must be power of two".into());
        }
        let w_exp = self.width.trailing_zeros() as u8;
        let h_exp = self.height.trailing_zeros() as u8;
        if w_exp > 15 || h_exp > 15 {
            return Err("Resolution exponent exceeds 4 bits".into());
        }
        Ok((w_exp << 4) | h_exp)
    }

    pub const fn square(exp: u8) -> Self {
        Resolution { width: 1 << exp, height: 1 << exp }
    }
}

// Predefined constants
impl Resolution {
    pub const RES_256: Resolution = Resolution::square(8);
    pub const RES_512: Resolution = Resolution::square(9);
    pub const RES_1024: Resolution = Resolution::square(10);
}
```

This provides type safety, clear semantics, validation, and convenient constants.

### Consider: Parameter Semantic Types

Instead of raw byte arrays, use newtypes for semantic clarity:

```rust
pub struct NormalizedParam(f32);   // 0.0 - 1.0
pub struct AngleParam(f32);        // 0.0 - 2π
pub struct ChannelParam(u8);       // 0-3 (RGBA)
pub struct ColorParam([u8; 4]);    // RGBA bytes

impl From<u8> for NormalizedParam {
    fn from(byte: u8) -> Self {
        NormalizedParam(byte as f32 / 255.0)
    }
}

impl From<u8> for AngleParam {
    fn from(byte: u8) -> Self {
        AngleParam(byte as f32 * 255.0 / 256.0 * std::f32::consts::TAU)
    }
}

pub struct NoiseParams {
    pub min_octave: i8,              // Offset byte value
    pub max_octave: u8,              // Direct byte value
    pub persistence: NormalizedParam,
    pub mode: u8,
}

impl NoiseParams {
    pub fn from_bytes(params: &[u8]) -> Self {
        NoiseParams {
            min_octave: params[0] as i8 - 1,
            max_octave: params[1],
            persistence: params[2].into(),
            mode: params[3],
        }
    }
}
```

This documents intent, prevents errors (can't accidentally use angle as color), and enables compile-time checks.

### Avoid: Manual Memory Management for Caching

Phoenix uses raw pointers (`CachedResult`) and manual `Used` flags. Rust should use safer patterns:

```rust
pub struct Operator {
    // ... configuration fields ...
    cached_result: Option<TextureHandle>,
}

pub struct TextureHandle(usize);  // Index into pool

pub struct TexturePool {
    textures: Vec<Option<wgpu::Texture>>,
}

impl TexturePool {
    pub fn get(&self, handle: TextureHandle) -> &wgpu::Texture {
        self.textures[handle.0].as_ref().expect("Invalid handle")
    }

    pub fn release(&mut self, handle: TextureHandle) {
        self.textures[handle.0] = None;  // Slot becomes available
    }
}
```

Handles are lightweight indices. The pool owns all textures. No raw pointers, no manual lifetime tracking.

## Related Documents

This operator document covers the data model and parameter encoding. For broader context and implementation details, see:

- **[overview.md](overview.md)** — Texgen system architecture, operator graph representation, mental models
- **[pipeline.md](pipeline.md)** — Complete data flow from operator graph to GPU rendering
- **shaders.md** — HLSL shader patterns, constant buffer conventions, texture sampling
- **generators.md** — Noise algorithms (Perlin, Voronoi), gradient generation, tile patterns
- **transforms.md** — UV manipulation (rotozoom, mirror, polar transforms)
- **color-blend.md** — Blend modes, colorize, HSL adjustment

For cross-system integration:

- **[../rendering/materials.md](../rendering/materials.md)** — How materials reference texgen operators
- **[../rendering/shaders.md](../rendering/shaders.md)** — Material shaders sampling procedural textures

## Source File Reference

All paths relative to `demoscene/apex-public/apEx/Phoenix/`:

| File | Purpose | Key Lines |
|------|---------|-----------|
| **Texgen.h** | Data structure definitions | PHXFILTERDATADESCRIPTOR (66-73), PHXTEXTUREFILTER (75-92), PHXTEXTUREOPERATOR (105-124), PHXTEXTURESUBROUTINE (135-149) |
| **Texgen.cpp** | Core implementation | PHXTEXTUREFILTER::Render (120-185), PHXTEXTUREOPERATOR::Generate (464-497), constant buffer setup (151-158), texture binding (162-169) |
| **Texgen.cpp** | Lookup texture generation | GetLookupTexture (205-346): image (221-237), text (240-299), spline (301-321), hash (323-333) |

**Shader examples** (all relative to `demoscene/apex-public/Projects/Clean Slate/extracted/shaders/annotated/texgen/`):

| Shader | Parameters | Key Techniques |
|--------|------------|----------------|
| **noise.hlsl** | Min/max octave, persistence, interpolation mode | Multi-pass accumulation (lines 78-89), smoothstep (109-114), bilinear interpolation (128-148) |
| **colorize.hlsl** | Two colors (RGBA), control channel | Channel selection (42), color lerp (48) |
| **rotozoom.hlsl** | Angle, zoom, center point | Rotation matrix (56-66), inverse zoom (48), UV transform (51-69) |
| **hsl.hlsl** | Hue, saturation, lightness | RGB↔HSV conversion (31-102), split semantics (130-137) |
| **blur.hlsl** | X radius, Y radius | Multi-pass direction (42-49), separable filtering (66-73) |
| **cells.hlsl** | Iterations, power, size, metric | Multi-pass minimum accumulation (121-133), distance metrics (46-60) |

Phoenix's operator and parameter system demonstrates how byte-encoded configuration can remain expressive through shader-side interpretation conventions. The architecture balances compact serialization (critical for 64k demos) with rich functionality (essential for production-quality visuals), offering patterns applicable to any framework targeting procedural asset generation under size constraints.
