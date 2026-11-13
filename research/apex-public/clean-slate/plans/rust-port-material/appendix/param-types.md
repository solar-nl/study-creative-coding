# Parameter Types Reference

Complete documentation of all Phoenix material parameter types.

## Type Categories

| Category | Types | Usage |
|----------|-------|-------|
| **Numeric** | Float, Color | Shader uniforms |
| **State** | ZMode, ZFunction, FillMode, CullMode, BlendMode | Pipeline configuration |
| **Texture** | Texture0-7, DepthTexture, 3DTexture | Bind group resources |
| **Special** | RenderPriority, RenderTarget, ParticleLife | System integration |

---

## Numeric Parameters

### PARAM_FLOAT (0)

Single floating-point value.

```rust
MaterialValue::Float(f32)
```

**Binary encoding**: 4 bytes little-endian f32
**Default**: 0.0
**Common uses**: Roughness modifier, metalness modifier, UV scale

### PARAM_COLOR (1)

RGBA color with 4 floating-point components.

```rust
MaterialValue::Color { r: f32, g: f32, b: f32, a: f32 }
```

**Binary encoding**: 16 bytes (4 × f32 little-endian)
**Default**: (1.0, 1.0, 1.0, 1.0)
**Common uses**: Tint color, emissive color, ambient color

---

## Pipeline State Parameters

### PARAM_ZMODE (2)

Depth buffer read/write configuration.

```rust
enum ZMode {
    Disabled = 0,   // No depth testing
    ReadWrite = 1,  // Normal (opaque)
    ReadOnly = 2,   // Test but don't write (transparent)
}
```

**Binary encoding**: 1 byte
**Default**: ReadWrite
**wgpu mapping**:
- `Disabled`: `depth_write_enabled = false`, `depth_compare = Always`
- `ReadWrite`: `depth_write_enabled = true`, `depth_compare = LessEqual`
- `ReadOnly`: `depth_write_enabled = false`, `depth_compare = LessEqual`

### PARAM_ZFUNCTION (3)

Depth comparison function.

```rust
enum ZFunction {
    LessEqual = 0,
    Never = 1,
    Less = 2,
    Equal = 3,
    Greater = 4,
    NotEqual = 5,
    GreaterEqual = 6,
    Always = 7,
}
```

**Binary encoding**: 1 byte
**Default**: LessEqual
**wgpu mapping**: Direct mapping to `wgpu::CompareFunction`

### PARAM_FILLMODE (4)

Polygon fill mode.

```rust
MaterialValue::FillMode { wireframe: bool }
```

**Binary encoding**: 1 byte (0 = solid, non-zero = wireframe)
**Default**: Solid (false)
**wgpu mapping**:
- `false`: `wgpu::PolygonMode::Fill`
- `true`: `wgpu::PolygonMode::Line`

### PARAM_CULLMODE (5)

Face culling mode.

```rust
enum CullMode {
    None = 1,   // Two-sided
    Front = 2,  // Cull front faces
    Back = 3,   // Cull back faces (default)
}
```

**Binary encoding**: 1 byte (D3D11 values)
**Default**: Back
**wgpu mapping**:
- `None`: `cull_mode = None`
- `Front`: `cull_mode = Some(Face::Front)`
- `Back`: `cull_mode = Some(Face::Back)`

### PARAM_BLENDMODE0-7 (15-22)

Blend state for render targets 0-7.

```rust
struct BlendMode(u8);
// Lower nibble = src factor
// Upper nibble = dst factor
```

**Binary encoding**: 1 byte packed
**Default**: 0x01 (Opaque: ONE, ZERO)

**Blend factor encoding**:
| Nibble | Factor |
|--------|--------|
| 0x0 | Zero |
| 0x1 | One |
| 0x2 | SrcColor |
| 0x3 | OneMinusSrcColor |
| 0x4 | SrcAlpha |
| 0x5 | OneMinusSrcAlpha |
| 0x6 | DstAlpha |
| 0x7 | OneMinusDstAlpha |
| 0x8 | DstColor |
| 0x9 | OneMinusDstColor |
| 0xA | SrcAlphaSaturated |

**Common presets**:
| Name | Value | Formula |
|------|-------|---------|
| Opaque | 0x01 | `1 × src + 0 × dst` |
| Alpha | 0x54 | `srcα × src + (1-srcα) × dst` |
| Additive | 0x11 | `1 × src + 1 × dst` |
| Multiply | 0x80 | `0 × src + srcColor × dst` |

---

## Texture Parameters

### PARAM_TEXTURE0-7 (7-14)

Texture slot bindings.

```rust
MaterialValue::Texture(Option<String>)
// String is TexGen output path: "graph_name/output_name"
```

**Binary encoding**: N/A (stored as reference)
**Default**: None (uses fallback texture)

**Slot conventions**:
| Slot | Name | PBR Usage |
|------|------|-----------|
| 0 | Texture0 | Albedo.rgb + Metalness.a |
| 1 | Texture1 | Normal.rgb + Roughness.a |
| 2 | Texture2 | Emissive.rgb + Opacity.a |
| 3-7 | Texture3-7 | Custom |

### PARAM_DEPTHTEXTURE7 (25)

Depth buffer sampled as texture (slot 7).

```rust
MaterialValue::Texture(Some("$depth".to_string()))
```

**Special handling**: Binds the depth buffer from a previous pass
**wgpu binding**: `texture_depth_2d` sample type

### PARAM_3DTEXTURE6 (26)

3D volume texture (slot 6).

```rust
MaterialValue::Texture(Some("volume_name".to_string()))
```

**wgpu binding**: `TextureViewDimension::D3`
**Usage**: Volumetric effects, 3D LUTs

---

## Special Parameters

### PARAM_RENDERPRIORITY (6)

Draw order within a render layer.

```rust
MaterialValue::RenderPriority(i32)
```

**Binary encoding**: 4 bytes signed i32
**Default**: 0
**Behavior**: Lower values render first

### PARAM_RENDERTARGET (23)

Target render target for post-process effects.

```rust
MaterialValue::RenderTarget(Option<String>)
```

**Binary encoding**: Reference/pointer
**Default**: Main RT
**Usage**: Post-processing chains

### PARAM_PARTICLELIFEFLOAT (24)

Particle lifetime as float.

```rust
MaterialValue::Float(f32)  // 0.0 = birth, 1.0 = death
```

**Usage**: Particle system age-based effects

### PARAM_MESHDATA0-3 (27-30)

Mesh attribute bindings.

```rust
MaterialValue::MeshData { attribute: u8 }
```

**Usage**: Binding vertex attributes for special effects

### PARAM_PARTICLELIFE (31)

Particle lifetime curve reference.

```rust
MaterialValue::SplineRef(Option<String>)
```

**Usage**: Animated particle parameters

### PARAM_LTC1 (32)

LTC matrix lookup table for area lights.

```rust
// Engine-global resource, not user-configurable
```

**wgpu binding**: Texture2D, sampled with linear filtering
**Size**: 64×64 RGBA16F

### PARAM_LTC2 (33)

LTC magnitude/Fresnel lookup table.

```rust
// Engine-global resource, not user-configurable
```

**wgpu binding**: Texture2D, sampled with linear filtering
**Size**: 64×64 RGBA16F

---

## Type Compatibility Matrix

When overriding parameters, types must match:

| Default Type | Allowed Override Types |
|--------------|----------------------|
| Float | Float |
| Color | Color |
| ZMode | ZMode |
| ZFunction | ZFunction |
| FillMode | FillMode |
| CullMode | CullMode |
| BlendMode | BlendMode |
| Texture | Texture |
| RenderPriority | RenderPriority |

---

## Shader Access Patterns

### Numeric parameters in WGSL

```wgsl
struct MaterialUniforms {
    // Floats packed into vec4s
    float_params: vec4<f32>,
    // Colors
    tint_color: vec4<f32>,
    emissive_color: vec4<f32>,
}

@group(2) @binding(4) var<uniform> material: MaterialUniforms;

fn get_roughness_mod() -> f32 {
    return material.float_params.x;
}
```

### Texture parameters in WGSL

```wgsl
@group(2) @binding(0) var albedo_metalness: texture_2d<f32>;
@group(2) @binding(1) var normal_roughness: texture_2d<f32>;
@group(2) @binding(2) var emissive_alpha: texture_2d<f32>;
@group(2) @binding(3) var material_sampler: sampler;

fn sample_albedo(uv: vec2<f32>) -> vec3<f32> {
    return textureSample(albedo_metalness, material_sampler, uv).rgb;
}
```

### Pipeline state (compile-time)

Pipeline state parameters don't appear in shaders - they configure the fixed-function pipeline at pipeline creation time.

---

## Validation Rules

1. **Type match**: Override type must equal default type
2. **Scope respect**: Constant parameters should not be overridden (warning)
3. **Range limits**: Floats should be clamped to valid ranges
4. **Texture existence**: Texture paths must resolve to valid handles
5. **Blend validity**: Blend factors must be valid nibble values

---

## Related Documents

- [01-data-structures.md](../01-data-structures.md) - Rust type definitions
- [02-parameter-merging.md](../02-parameter-merging.md) - Merge algorithm
- [04-pipeline-generation.md](../04-pipeline-generation.md) - State usage
