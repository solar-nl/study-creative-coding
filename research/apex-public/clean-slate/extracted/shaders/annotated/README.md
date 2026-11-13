# Annotated Clean Slate Shaders

Readable, annotated versions of the 71 HLSL shaders extracted from Conspiracy's **Clean Slate** 64kb intro. The originals are minified for executable size; these versions add descriptive names, comments, and algorithm documentation for educational purposes.

## Purpose

These annotated shaders serve as learning resources for:

1. **Demoscene rendering techniques** — How professionals achieve production-quality visuals in 64kb
2. **HLSL best practices** — Cook-Torrance BRDF, area lighting, procedural textures
3. **Algorithm documentation** — Multi-octave noise, Voronoi cells, LTC integration

## Directory Structure

```
annotated/
├── README.md           # This file
├── algorithms.md       # Cross-reference index of algorithms
├── materials/          # 34 rendering shaders
│   ├── pbr-mixed-rendering.hlsl
│   ├── area-sphere-light-ltc.hlsl
│   └── ...
└── texgen/             # 37 procedural texture generators
    ├── noise.hlsl
    ├── cells.hlsl
    └── ...
```

## Naming Conventions

### Entry Points

| Minified | Readable | Stage |
|----------|----------|-------|
| `v()` | `VertexMain()` | Vertex Shader |
| `p()` | `PixelMain()` | Pixel Shader |
| `g()` | `GeometryMain()` | Geometry Shader |
| `h()` | `HullMain()` | Hull Shader |
| `d()` | `DomainMain()` | Domain Shader |

### Common Variables

| Minified | Readable | Description |
|----------|----------|-------------|
| `t` | `texCoord` | Texture coordinates (UV) |
| `tt` | `texCoord` | Alternative texture coordinate name |
| `n` | `normal` | Surface normal vector |
| `k` | `result` or `temp` | Temporary calculation result |
| `l` | `lightDir` or `distance` | Light direction or distance |
| `d` | `depth` or `distance` | Depth value or distance |
| `s` | `scale` or `step` | Scale factor or step size |
| `p` (var) | `position` | World/view position |
| `r` | `reflection` or `radius` | Reflection vector or radius |

### Constant Buffers

| Minified | Readable | Purpose |
|----------|----------|---------|
| `dat` | `materialParams` | Per-material data (roughness mod, metalness mod, flags) |
| `shd` | `shadowParams` | Shadow mapping parameters + albedo multipliers |
| `sda` | `spotDirAttenuation` | Spotlight direction and attenuation |
| `data1` | `texgenParams` | Texture generator parameters |
| `PassData` | `passInfo` | Multi-pass rendering state |

### Material Parameter Layout

The `materialParams` (`dat`) float4 typically contains:

```hlsl
// dat.x = roughness modifier (0-1, 0.5 = neutral)
// dat.y = metalness modifier (0-1, 0.5 = neutral)
// dat.z = two-sided rendering flag (0 or 1)
// dat.w = shadow bias
```

The modifier system uses 127/255.0 as the neutral midpoint:
- Values < 0.498 (127/255) scale the texture value down
- Values > 0.498 interpolate toward 1.0

### Texgen Parameter Encoding

Texture generator parameters encode floats as normalized bytes:

```hlsl
// data1.x = parameter 0 (often minimum bound, encoded as x*255)
// data1.y = parameter 1 (often maximum bound, encoded as y*255)
// data1.z = parameter 2 (often blend/falloff factor)
// data1.w = parameter 3 (often mode selector: 0 or 1)
```

## Annotation Format

Each annotated shader follows this structure:

```hlsl
// ============================================================================
// READABLE VERSION: [Shader Name]
// Original: ../[texgen|materials]/[filename].hlsl
//
// Algorithm: [Brief algorithm description]
//
// Parameters:
//   data1.x — [Description of parameter]
//   data1.y — [Description of parameter]
//   ...
//
// References:
//   - [Link to algorithm paper/documentation]
// ============================================================================

// [Annotated shader code with inline comments]
```

### Magic Number Documentation

Magic numbers receive inline comments explaining their derivation:

```hlsl
// Smoothstep: S(t) = t²(3 - 2t), provides smooth interpolation
fractionalPart *= fractionalPart * (3.0 - 2.0 * fractionalPart);

// Modifier midpoint: 127/255 ≈ 0.498 serves as neutral value
// Values below scale down; values above interpolate to 1.0
if (modifier <= 127.0 / 255.0)
    return value * modifier / (127.0 / 255.0);
```

## Shader Priority Tiers

### Tier 1 — Core Educational Value

High-value shaders demonstrating fundamental techniques:

| Shader | Lines | Technique |
|--------|-------|-----------|
| `noise.hlsl` | 53 | Multi-octave Perlin noise |
| `cells.hlsl` | 45 | Voronoi/Worley patterns |
| `pbr-mixed-rendering.hlsl` | 337 | Complete PBR pipeline |
| `area-sphere-light-ltc.hlsl` | 246 | LTC area lighting |

### Tier 2 — Advanced Techniques

Post-processing and screen-space effects:

| Shader | Lines | Technique |
|--------|-------|-----------|
| `ssao.hlsl` | ~150 | Screen-space ambient occlusion |
| `fxaa.hlsl` | ~100 | Fast approximate anti-aliasing |
| `depth-of-field.hlsl` | ~120 | Bokeh depth of field |
| `screen-space-reflections.hlsl` | ~180 | SSR with ray marching |

### Tier 3 — Core Texgen Algorithms

Procedural texture generation foundations:

| Shader | Lines | Technique |
|--------|-------|-----------|
| `subplasma.hlsl` | ~80 | Catmull-Rom interpolated plasma |
| `turbulence.hlsl` | ~60 | Fractal turbulence |
| `normalmap.hlsl` | ~40 | Height-to-normal conversion |

### Tier 4 — Utility Operations

Simpler image processing and blending:

- `blur.hlsl`, `dirblur.hlsl` — Gaussian and directional blur
- `colorize.hlsl`, `hsl.hlsl` — Color space transformations
- `mix.hlsl`, `combine.hlsl` — Blend operations

## Verification

Annotated shaders are semantically equivalent to originals:

1. **Rename only** — No logic changes, only identifier and comment additions
2. **Consistent mappings** — Variable names map identically across all shaders
3. **Preserve formatting** — Original structure maintained where possible

## Related Documentation

- `../../../notes/per-demoscene/apex-public/rendering/materials.md` — Material system architecture
- `../../../notes/per-demoscene/apex-public/rendering/shaders.md` — BRDF and constant buffer details
- `../../../notes/per-demoscene/apex-public/code-traces/ltc-area-lighting.md` — LTC algorithm trace

## Attribution

Original shaders: **Conspiracy** (Clean Slate, 64kb intro)
Annotations: Educational study for creative coding research
