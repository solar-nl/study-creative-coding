# HLSL to WGSL Translation Guide

This guide covers the key differences between HLSL (D3D11) and WGSL for translating the Phoenix shaders.

## Type Mappings

| HLSL | WGSL | Notes |
|------|------|-------|
| `float` | `f32` | |
| `float2` | `vec2<f32>` | |
| `float3` | `vec3<f32>` | |
| `float4` | `vec4<f32>` | |
| `int` | `i32` | |
| `int2` | `vec2<i32>` | |
| `uint` | `u32` | |
| `bool` | `bool` | |
| `float3x3` | `mat3x3<f32>` | Column-major in WGSL |
| `float4x4` | `mat4x4<f32>` | Column-major in WGSL |
| `half` | `f16` | Requires extension |

### Matrix Layout

WGSL uses column-major storage. To translate HLSL row-major matrices:

```hlsl
// HLSL (row-major by default)
float4x4 worldmat;
float4 result = mul(worldmat, float4(pos, 1));
```

```wgsl
// WGSL (column-major)
var worldmat: mat4x4<f32>;
let result = worldmat * vec4<f32>(pos, 1.0);
```

The `mul()` order reverses for column-major matrices.

## Intrinsic Function Mappings

| HLSL | WGSL | Notes |
|------|------|-------|
| `lerp(a, b, t)` | `mix(a, b, t)` | |
| `saturate(x)` | `saturate(x)` | Same |
| `clamp(x, a, b)` | `clamp(x, a, b)` | Same |
| `frac(x)` | `fract(x)` | |
| `rsqrt(x)` | `inverseSqrt(x)` | |
| `rcp(x)` | `1.0 / x` | No built-in |
| `ddx(x)` | `dpdx(x)` | Screen-space derivative |
| `ddy(x)` | `dpdy(x)` | Screen-space derivative |
| `atan2(y, x)` | `atan2(y, x)` | Same |
| `acos(x)` | `acos(x)` | Same |
| `normalize(v)` | `normalize(v)` | Same |
| `dot(a, b)` | `dot(a, b)` | Same |
| `cross(a, b)` | `cross(a, b)` | Same |
| `length(v)` | `length(v)` | Same |
| `reflect(i, n)` | `reflect(i, n)` | Same |
| `pow(x, y)` | `pow(x, y)` | Same |
| `sqrt(x)` | `sqrt(x)` | Same |
| `abs(x)` | `abs(x)` | Same |
| `max(a, b)` | `max(a, b)` | Same |
| `min(a, b)` | `min(a, b)` | Same |
| `floor(x)` | `floor(x)` | Same |
| `ceil(x)` | `ceil(x)` | Same |
| `any(v)` | `any(v)` | |
| `all(v)` | `all(v)` | |
| `isnan(x)` | `is_nan(x)` | Underscore |
| `step(edge, x)` | `step(edge, x)` | Same |
| `smoothstep(a, b, x)` | `smoothstep(a, b, x)` | Same |

### Select/Ternary

```hlsl
// HLSL
float result = condition ? a : b;
```

```wgsl
// WGSL
let result = select(b, a, condition);  // Note: order is (false_val, true_val, cond)
```

## Texture Sampling

| HLSL | WGSL |
|------|------|
| `tex.Sample(sampler, uv)` | `textureSample(tex, sampler, uv)` |
| `tex.SampleLevel(sampler, uv, lod)` | `textureSampleLevel(tex, sampler, uv, lod)` |
| `tex.Load(int3(xy, mip))` | `textureLoad(tex, xy, mip)` |
| `tex.SampleCmpLevelZero(cmpSampler, uv, ref)` | `textureSampleCompare(tex, cmpSampler, uv, ref)` |

### Texture Declaration

```hlsl
// HLSL
Texture2D t_0 : register(t0);
SamplerState Sampler : register(s0);
```

```wgsl
// WGSL
@group(0) @binding(0) var t_0: texture_2d<f32>;
@group(0) @binding(1) var Sampler: sampler;
```

## Constant Buffers / Uniforms

```hlsl
// HLSL
cbuffer SceneData : register(b0)
{
    float4x4 viewmat;
    float4 campos;
};
```

```wgsl
// WGSL
struct SceneData {
    viewmat: mat4x4<f32>,
    campos: vec4<f32>,
}

@group(0) @binding(0) var<uniform> scene: SceneData;
```

## Vertex Input/Output

```hlsl
// HLSL
struct VSIN
{
    float3 Position : POSITION0;
    float3 Normal : NORMAL0;
    float2 UV : TEXCOORD0;
};

struct VSOUT
{
    float4 Position : SV_POSITION;
    float3 Normal : TEXCOORD1;
    float2 uv : TEXCOORD0;
};
```

```wgsl
// WGSL
struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
}

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) normal: vec3<f32>,
}
```

## Semantic to Location Mapping

| HLSL Semantic | WGSL Attribute |
|---------------|----------------|
| `POSITION` | `@location(0)` |
| `NORMAL` | `@location(1)` |
| `TEXCOORD0` | `@location(2)` |
| `COLOR0` | `@location(3)` |
| `SV_POSITION` | `@builtin(position)` |
| `SV_TARGET0` | `@location(0)` |
| `SV_TARGET1` | `@location(1)` |
| `SV_VertexID` | `@builtin(vertex_index)` |
| `SV_InstanceID` | `@builtin(instance_index)` |

## Multiple Render Targets

```hlsl
// HLSL
struct PSOUT
{
    float4 color : SV_TARGET0;
    float4 albedo : SV_TARGET1;
    float4 normal : SV_TARGET2;
};
```

```wgsl
// WGSL
struct FragmentOutput {
    @location(0) color: vec4<f32>,
    @location(1) albedo: vec4<f32>,
    @location(2) normal: vec4<f32>,
}
```

## Control Flow

### Loops

```hlsl
// HLSL
for (int i = 0; i < count; i++) { ... }
```

```wgsl
// WGSL
for (var i: i32 = 0; i < count; i = i + 1) { ... }
```

### Discard

```hlsl
// HLSL
if (alpha < 0.5) discard;
```

```wgsl
// WGSL
if alpha < 0.5 {
    discard;
}
```

## Static/Const

```hlsl
// HLSL
static float3 points[64];
static const float PI = 3.14159265;
```

```wgsl
// WGSL
var<private> points: array<vec3<f32>, 64>;
const PI: f32 = 3.14159265;
```

## Coordinate System Differences

### Depth Range

| API | Depth Range | Notes |
|-----|-------------|-------|
| D3D11 | [0, 1] | Near = 0 |
| WGPU/Vulkan | [0, 1] | Near = 0 |
| OpenGL | [-1, 1] | Near = -1 |

WGPU matches D3D11 depth convention, so no transformation needed.

### UV Origin

| API | UV Origin |
|-----|-----------|
| D3D11 | Top-left (0,0) |
| WGPU | Top-left (0,0) |
| OpenGL | Bottom-left (0,0) |

WGPU matches D3D11, but framebuffer Y may need flipping in some contexts.

### Clip Space Y

| API | Y Direction |
|-----|-------------|
| D3D11 | Up = positive |
| WGPU/Vulkan | Down = positive |

For projection matrices, use `glam::Mat4::perspective_rh()` which produces WGPU-compatible output.

## Common Translation Patterns

### Matrix Multiplication

```hlsl
// HLSL
float4 clipPos = mul(projmat, mul(viewmat, float4(worldPos, 1)));
```

```wgsl
// WGSL
let clip_pos = scene.projection * scene.view * vec4<f32>(world_pos, 1.0);
```

### World Position Reconstruction

```hlsl
// HLSL
float4 a = mul(iviewmat, mul(iprojmat, float4(uv * 2 - 1, depth, 1)));
float3 worldPos = a.xyz / a.w;
```

```wgsl
// WGSL
let ndc = uv * 2.0 - 1.0;
let clip_pos = vec4<f32>(ndc, depth, 1.0);
let view_pos = scene.inverse_projection * clip_pos;
let world_pos = scene.inverse_view * view_pos;
let result = world_pos.xyz / world_pos.w;
```

### Tangent Frame Construction

```hlsl
// HLSL
float3x3 tangentFrame = float3x3(T * invmax, B * invmax, N);
float3 result = mul(map, tangentFrame);
```

```wgsl
// WGSL
let TBN = mat3x3<f32>(T * invmax, B * invmax, N);
let result = TBN * map;  // mat * vec in WGSL
```

## Precision Differences

WGSL defaults to 32-bit precision. Half-precision (`f16`) requires:

```wgsl
enable f16;

var x: f16 = 1.0h;
```

Most modern GPUs handle f32 efficiently, so f16 is rarely needed for these shaders.

## Reserved Words

WGSL reserves additional keywords. Common conflicts:

| HLSL | WGSL Alternative |
|------|------------------|
| `in` | `input` |
| `out` | `output` |
| `uniform` | N/A (use `var<uniform>`) |
| `texture` | N/A (use `texture_2d`) |
