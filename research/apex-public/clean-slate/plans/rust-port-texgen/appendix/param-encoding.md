# Parameter Encoding

TexGen operators store parameters as 16 bytes (4 × vec4<u8>). This appendix documents how parameters are encoded and decoded for each operator type.

## General Encoding Scheme

All parameters are stored as unsigned bytes (0-255) and normalized to floating point when passed to shaders.

```
Byte Storage: [u8; 16]
GPU Upload:   [f32; 16] where each f32 = byte / 255.0
```

### Common Decoding Patterns

| Pattern | Formula | Range | Use Case |
|---------|---------|-------|----------|
| **Normalized** | `b / 255.0` | 0.0 - 1.0 | Colors, factors |
| **Centered** | `(b / 255.0 - 0.5) * 2.0` | -1.0 - 1.0 | Offsets, shifts |
| **Integer** | `b` as-is | 0 - 255 | Counts, indices |
| **Angle** | `b / 256.0 * 2π` | 0 - 2π | Rotations |
| **Exponential** | `pow(2, b / X)` | varies | Octaves, sizes |

## Per-Operator Parameter Maps

### Generators

#### Noise
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | min_octave | `b - 1` | -1 to 254 (maps to octave 0-8) |
| 1 | max_octave | `b - 1` | -1 to 254 |
| 2 | persistence | `b / 255.0` | 0.0 - 1.0 |
| 3 | interpolation | `b > 127 ? 1 : 0` | 0=smooth, 1=linear |

#### Gradient
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | pattern | `b * 6 / 256` | 0-5 (pattern index) |

#### Cells
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | iterations | `b` | 0-255 (pass count) |
| 1 | power | `b / 255.0 * 10.0` | 0.0 - 10.0 |
| 2 | size | `b / 255.0 * 10.0` | 0.0 - 10.0 |
| 3 | manhattan | `b > 127 ? 1 : 0` | 0=euclidean, 1=manhattan |

#### Cells2 / CellEdges
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | grid_x | `b` | 1-256 cells |
| 1 | grid_y | `b` | 1-256 cells |
| 2 | thickness (CellEdges only) | `b / 255.0` | 0.0 - 1.0 |

#### Rectangle
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | center_x | `b / 255.0` | 0.0 - 1.0 |
| 1 | center_y | `b / 255.0` | 0.0 - 1.0 |
| 2 | half_width | `b / 255.0 * 0.5` | 0.0 - 0.5 |
| 3 | half_height | `b / 255.0 * 0.5` | 0.0 - 0.5 |
| 4 | chamfer | `max(b / 255.0, 0.01)` | 0.01 - 1.0 |
| 5 | falloff | `max(b / 255.0, 0.01)` | 0.01 - 1.0 |

#### SolidColor
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | red | `b / 255.0` | 0.0 - 1.0 |
| 1 | green | `b / 255.0` | 0.0 - 1.0 |
| 2 | blue | `b / 255.0` | 0.0 - 1.0 |
| 3 | alpha | `b / 255.0` | 0.0 - 1.0 |

#### Tiles
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | columns | `max(b, 1)` | 1-255 |
| 1 | rows | `max(b, 1)` | 1-255 |
| 2 | offset | `b / 255.0` | 0.0 - 1.0 |
| 3 | border | `b / 255.0` | 0.0 - 1.0 |

#### SubPlasma
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | density | `pow(2, b / 255.0 * 8)` | 1-256 cells |
| 1 | linear | `b > 127 ? 1 : 0` | 0=catmull-rom, 1=linear |

#### EnvMap
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | outer_radius | `max(b / 255.0, 0.01)` | 0.01 - 1.0 |
| 1 | inner_radius | `b / 255.0 * outer` | 0.0 - outer |
| 2 | scale_x | `max(b / 255.0, 0.01)` | 0.01 - 1.0 |
| 3 | scale_y | `max(b / 255.0, 0.01)` | 0.01 - 1.0 |

### Transforms

#### Rotozoom
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | angle | `b / 256.0 * 2π` | 0 - 2π |
| 1 | zoom | `b / 255.0 * 4.0 + 0.01` | 0.01 - 4.0 |
| 2 | center_x | `b / 255.0` | 0.0 - 1.0 |
| 3 | center_y | `b / 255.0` | 0.0 - 1.0 |

#### Translate
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | offset_x | `(b / 255.0 - 0.5) * 2.0` | -1.0 - 1.0 |
| 1 | offset_y | `(b / 255.0 - 0.5) * 2.0` | -1.0 - 1.0 |

#### Mirror
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | mode | `b % 4` | 0-3 (bit flags) |

#### Loop
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | tile_x | `b / 16.0 + 1.0` | 1.0 - 17.0 |
| 1 | tile_y | `b / 16.0 + 1.0` | 1.0 - 17.0 |

#### Pixelize
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | pixels_x | `max(b, 1)` | 1-255 |
| 1 | pixels_y | `max(b, 1)` | 1-255 |

#### ToPolar
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | center_x | `b / 255.0` | 0.0 - 1.0 |
| 1 | center_y | `b / 255.0` | 0.0 - 1.0 |

### Color Operations

#### Colorize
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0-3 | color1 RGBA | `b / 255.0` each | 0.0 - 1.0 |
| 4-7 | color2 RGBA | `b / 255.0` each | 0.0 - 1.0 |

#### HSL
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | hue_shift | `(b / 255.0 - 0.5) * 2.0` | -1.0 - 1.0 |
| 1 | saturation | `b / 127.5` | 0.0 - 2.0 |
| 2 | lightness | `b / 127.5` | 0.0 - 2.0 |

#### Scale
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0-3 | min RGBA | `b / 255.0` each | 0.0 - 1.0 |
| 4-7 | max RGBA | `b / 255.0` each | 0.0 - 1.0 |

#### Contrast
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | contrast | `b / 127.5` | 0.0 - 2.0 |
| 1 | brightness | `(b / 255.0 - 0.5) * 2.0` | -1.0 - 1.0 |
| 2 | pivot | `b / 255.0` | 0.0 - 1.0 |

#### Smoothstep
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | edge0 | `b / 255.0` | 0.0 - 1.0 |
| 1 | edge1 | `b / 255.0` | 0.0 - 1.0 |

### Blend Operations

#### Combine
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | mode | `b % 10` | 0-9 (blend mode) |

#### Mix
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | factor | `b / 255.0` | 0.0 - 1.0 |

### Filters

#### Blur
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | radius | `b / 255.0` | 0.0 - 1.0 (% of size) |
| 1 | sigma | `b / 25.5` | 0.0 - 10.0 |

#### DirBlur
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | angle | `b / 256.0 * 2π` | 0 - 2π |
| 1 | length | `b / 255.0 * 0.2` | 0.0 - 0.2 |
| 2 | samples | `max(b / 8, 1)` | 1-32 |

#### Normalmap
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | strength | `b / 25.5` | 0.0 - 10.0 |
| 1 | mode | `b > 127 ? 1 : 0` | 0=sobel, 1=simple |

#### Turbulence
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | distortion | `b / 255.0 * 0.5` | 0.0 - 0.5 |
| 1 | iterations | `max(b / 64, 1)` | 1-4 |

#### Glass
| Byte | Name | Decode | Range |
|------|------|--------|-------|
| 0 | bevel | `b / 255.0 * 0.1` | 0.0 - 0.1 |
| 1 | depth | `b / 255.0` | 0.0 - 1.0 |

## GPU Upload Format

Parameters are uploaded as a uniform buffer:

```rust
#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
pub struct TexgenUniforms {
    /// Pass info: x = pass index, yzw = random values
    pub pass_data: [f32; 4],
    /// Parameters as 4 vec4s (16 floats)
    pub params: [[f32; 4]; 4],
}

impl TexgenUniforms {
    pub fn from_operator(op: &TexgenOperator, pass: u32) -> Self {
        let mut rng = Xorshf96::new(op.seed as u32);

        Self {
            pass_data: [
                pass as f32,
                rng.next_f32(),
                rng.next_f32(),
                rng.next_f32(),
            ],
            params: [
                [
                    op.params.bytes[0] as f32 / 255.0,
                    op.params.bytes[1] as f32 / 255.0,
                    op.params.bytes[2] as f32 / 255.0,
                    op.params.bytes[3] as f32 / 255.0,
                ],
                // ... bytes 4-7, 8-11, 12-15
            ],
        }
    }
}
```

## WGSL Parameter Access

```wgsl
struct TexgenUniforms {
    pass_data: vec4<f32>,
    params: array<vec4<f32>, 4>,
}

@group(0) @binding(0) var<uniform> u: TexgenUniforms;

// Access by linear index
fn param(i: u32) -> f32 {
    return u.params[i / 4u][i % 4u];
}

// Example: Decode rotozoom angle
let angle = param(0) * 6.28318530718;  // Already normalized, just scale to 2π
```

## JSON Representation

Parameters in JSON graphs use human-readable names:

```json
{
  "filter": "Noise",
  "params": {
    "octaves": 6,
    "persistence": 0.5,
    "frequency": 4,
    "mode": "smoothstep"
  }
}
```

Conversion to bytes:
```rust
fn encode_noise_params(octaves: u8, persistence: f32, frequency: u8, smooth: bool) -> [u8; 16] {
    let mut bytes = [0u8; 16];
    bytes[0] = 0;  // min_octave (start from 0)
    bytes[1] = octaves;  // max_octave
    bytes[2] = (persistence * 255.0) as u8;
    bytes[3] = if smooth { 0 } else { 255 };
    bytes
}
```

## Precision Considerations

- **8-bit quantization**: 1/256 ≈ 0.4% precision loss
- **Angles**: 256 steps = 1.4° resolution
- **Colors**: Standard 8-bit per channel (no loss)
- **Small values**: May need special handling (e.g., `max(b, 1)` to avoid zero)

For higher precision requirements, consider:
1. Packing two bytes per parameter
2. Using HDR texture format for parameter texture
3. Direct float upload instead of byte encoding
