# Transform Operators

Transform operators modify UV coordinates before sampling an input texture. They enable rotation, scaling, tiling, and coordinate space conversions.

## Transform Overview

| Operator | Input | Description |
|----------|-------|-------------|
| **Rotozoom** | 1 | Rotate + scale + translate |
| **Translate** | 1 | Simple UV offset |
| **Mirror** | 1 | Axis mirroring |
| **Loop** | 1 | Tile repetition control |
| **Pixelize** | 1 | Quantize to pixel grid |
| **ToPolar** | 1 | Cartesian → polar coordinates |
| **MapDistort** | 2 | UV displacement via map |

## Common Transform Pattern

All transforms follow the same structure:
1. Compute modified UV coordinates
2. Sample input texture at modified UV
3. Write result to output

```wgsl
// transform_common.wgsl

// Shared bindings for transform operators
@group(0) @binding(0) var<uniform> u: TexgenUniforms;
@group(0) @binding(1) var input_texture: texture_2d<f32>;
@group(0) @binding(2) var linear_sampler: sampler;
@group(0) @binding(3) var output: texture_storage_2d<rgba16float, write>;
```

---

## Rotozoom

Combines rotation, zoom, and translation in a single operator.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | angle | 0-360° | Rotation angle (encoded as 0-1 → 0-360) |
| 1 | zoom | 0-4 | Scale factor (0.5 = 2× zoom in) |
| 2 | center_x | 0-1 | Rotation center X |
| 3 | center_y | 0-1 | Rotation center Y |

### Algorithm

1. Translate to rotation center
2. Apply rotation matrix
3. Apply scale
4. Translate back and add offset

### WGSL Implementation

```wgsl
// rotozoom.wgsl

const TAU: f32 = 6.28318530718;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    // Decode parameters
    let angle = param(0) * TAU;  // 0-1 → 0-2π
    let zoom = param(1) * 4.0 + 0.001;  // Avoid division by zero
    let center = vec2<f32>(param(2), param(3));

    // Rotation matrix
    let c = cos(angle);
    let s = sin(angle);

    // Transform UV:
    // 1. Translate to origin (relative to center)
    var p = uv - center;

    // 2. Rotate
    p = vec2<f32>(
        p.x * c - p.y * s,
        p.x * s + p.y * c
    );

    // 3. Scale (inverse zoom - smaller zoom value = more magnification)
    p = p / zoom;

    // 4. Translate back
    p = p + center;

    // Sample input at transformed UV
    let color = textureSampleLevel(input_texture, linear_sampler, p, 0.0);
    textureStore(output, gid.xy, color);
}
```

---

## Translate

Simple UV offset with wrapping.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | offset_x | -1 to 1 | Horizontal offset (0.5 = centered) |
| 1 | offset_y | -1 to 1 | Vertical offset (0.5 = centered) |

### WGSL Implementation

```wgsl
// translate.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    // Decode offset (0.5 = no offset, 0 = -0.5, 1 = +0.5)
    let offset = vec2<f32>(
        (param(0) - 0.5) * 2.0,
        (param(1) - 0.5) * 2.0
    );

    // Apply offset with wrapping
    let p = fract(uv + offset);

    let color = textureSampleLevel(input_texture, linear_sampler, p, 0.0);
    textureStore(output, gid.xy, color);
}
```

---

## Mirror

Mirror texture along X, Y, or both axes.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | mode | 0-3 | 0=none, 1=X, 2=Y, 3=XY |

### WGSL Implementation

```wgsl
// mirror.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let mode = u32(param(0) * 3.0 + 0.5);

    var p = uv;

    // Mirror X (mode 1 or 3)
    if ((mode & 1u) != 0u) {
        p.x = 1.0 - p.x;
    }

    // Mirror Y (mode 2 or 3)
    if ((mode & 2u) != 0u) {
        p.y = 1.0 - p.y;
    }

    let color = textureSampleLevel(input_texture, linear_sampler, p, 0.0);
    textureStore(output, gid.xy, color);
}
```

---

## Loop

Control tile repetition and seamless tiling.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | tile_x | 0-16 | Horizontal repetitions |
| 1 | tile_y | 0-16 | Vertical repetitions |

### WGSL Implementation

```wgsl
// loop.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let tile_x = param(0) * 16.0 + 1.0;
    let tile_y = param(1) * 16.0 + 1.0;

    // Scale UV and wrap
    let p = fract(uv * vec2<f32>(tile_x, tile_y));

    let color = textureSampleLevel(input_texture, linear_sampler, p, 0.0);
    textureStore(output, gid.xy, color);
}
```

---

## Pixelize

Quantize UV coordinates to create pixelated effect.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | pixels_x | 0-256 | Horizontal pixel count |
| 1 | pixels_y | 0-256 | Vertical pixel count |

### WGSL Implementation

```wgsl
// pixelize.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let pixels_x = max(param(0) * 256.0, 1.0);
    let pixels_y = max(param(1) * 256.0, 1.0);
    let grid = vec2<f32>(pixels_x, pixels_y);

    // Quantize UV to grid
    let p = (floor(uv * grid) + 0.5) / grid;

    let color = textureSampleLevel(input_texture, linear_sampler, p, 0.0);
    textureStore(output, gid.xy, color);
}
```

---

## ToPolar

Convert Cartesian coordinates to polar coordinates.

This transforms:
- X axis → angle (0 to 2π)
- Y axis → radius (0 to 1)

Useful for creating radial patterns from linear textures.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | center_x | 0-1 | Polar origin X |
| 1 | center_y | 0-1 | Polar origin Y |

### WGSL Implementation

```wgsl
// to_polar.wgsl

const TAU: f32 = 6.28318530718;
const PI: f32 = 3.14159265359;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let center = vec2<f32>(param(0), param(1));

    // Vector from center
    let delta = uv - center;

    // Convert to polar coordinates
    let radius = length(delta) * 2.0;  // Scale so radius 0.5 → 1.0
    let angle = atan2(delta.y, delta.x);  // -π to π

    // Map angle from [-π, π] to [0, 1]
    let angle_norm = (angle + PI) / TAU;

    // Create new UV: X = angle, Y = radius
    let p = vec2<f32>(angle_norm, radius);

    let color = textureSampleLevel(input_texture, linear_sampler, p, 0.0);
    textureStore(output, gid.xy, color);
}
```

---

## MapDistort

Displace UV coordinates using a displacement map.

### Inputs

- Input 0: Source texture to distort
- Input 1: Displacement map (RG channels = X/Y offset)

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | strength_x | 0-1 | Horizontal displacement strength |
| 1 | strength_y | 0-1 | Vertical displacement strength |

### WGSL Implementation

```wgsl
// mapdistort.wgsl

@group(0) @binding(0) var<uniform> u: TexgenUniforms;
@group(0) @binding(1) var source: texture_2d<f32>;
@group(0) @binding(2) var displacement: texture_2d<f32>;
@group(0) @binding(3) var linear_sampler: sampler;
@group(0) @binding(4) var output: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let strength = vec2<f32>(
        (param(0) - 0.5) * 2.0,  // -1 to 1
        (param(1) - 0.5) * 2.0
    );

    // Sample displacement map
    let disp = textureSampleLevel(displacement, linear_sampler, uv, 0.0);

    // Apply displacement (RG channels centered at 0.5)
    let offset = (disp.rg - 0.5) * strength;
    let p = uv + offset;

    // Sample source at displaced UV
    let color = textureSampleLevel(source, linear_sampler, p, 0.0);
    textureStore(output, gid.xy, color);
}
```

---

## Rust Operator Dispatch

```rust
impl TexgenEvaluator {
    fn dispatch_transform(
        &self,
        op: &TexgenOperator,
        encoder: &mut wgpu::CommandEncoder,
        input: TextureHandle,
        output: TextureHandle,
    ) {
        let pipeline = match op.op_type {
            OperatorType::Rotozoom => &self.pipelines.rotozoom,
            OperatorType::Translate => &self.pipelines.translate,
            OperatorType::Mirror => &self.pipelines.mirror,
            OperatorType::Loop => &self.pipelines.loop_op,
            OperatorType::Pixelize => &self.pipelines.pixelize,
            OperatorType::ToPolar => &self.pipelines.to_polar,
            _ => panic!("Not a transform operator"),
        };

        // Create bind group
        let bind_group = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("Transform Bind Group"),
            layout: &self.transform_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: self.uniform_buffer.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(
                        self.pool.get_view(input)
                    ),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&self.linear_sampler),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(
                        self.pool.get_storage_view(output, 0)
                    ),
                },
            ],
        });

        // Dispatch
        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
                label: Some("Transform Pass"),
                timestamp_writes: None,
            });

            pass.set_pipeline(pipeline);
            pass.set_bind_group(0, &bind_group, &[]);

            let res = op.resolution;
            pass.dispatch_workgroups(
                (res.width() + 7) / 8,
                (res.height() + 7) / 8,
                1
            );
        }
    }
}
```

---

## Related Documents

- [04-generators.md](04-generators.md) - Pattern generators
- [06-color-blend.md](06-color-blend.md) - Color operations
- [07-filters.md](07-filters.md) - Filter operations
