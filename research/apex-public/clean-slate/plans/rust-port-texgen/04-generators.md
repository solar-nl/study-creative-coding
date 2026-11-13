# Generator Operators

Generators create patterns from parameters without any input textures. They form the foundation layer of TexGen graphs.

## Generator Categories

| Generator | Passes | Hash | Primary Output |
|-----------|--------|------|----------------|
| **Noise** | 1-8 | Yes | Grayscale FBM |
| **Cells** | 1-16 | Yes | Grayscale distance |
| **Cells2** | 1 | Yes | Grayscale Voronoi |
| **CellEdges** | 1 | Yes | Grayscale edges |
| **Gradient** | 1 | No | 6 geometric patterns |
| **Rectangle** | 1 | No | Superellipse SDF |
| **SolidColor** | 1 | No | Constant RGBA |
| **Tiles** | 1 | No | Grid with IDs |
| **SubPlasma** | 3 | Yes | Smooth plasma |
| **EnvMap** | 1 | No | Radial falloff |

## Common Shader Infrastructure

All generators share common WGSL utilities:

```wgsl
// common.wgsl

struct TexgenUniforms {
    pass_data: vec4<f32>,  // x = pass index, yzw = random values
    params: array<vec4<f32>, 4>,
}

@group(0) @binding(0) var<uniform> u: TexgenUniforms;
@group(0) @binding(1) var hash_texture: texture_2d<f32>;
@group(0) @binding(2) var linear_sampler: sampler;
@group(0) @binding(3) var output: texture_storage_2d<rgba16float, write>;

// Access parameter by linear index
fn param(i: u32) -> f32 {
    return u.params[i / 4u][i % 4u];
}

// Sample hash texture with wrapping
fn hash(coord: vec2<f32>) -> vec4<f32> {
    let scaled = coord * 256.0;
    let wrapped = (scaled % 256.0 + 256.0) % 256.0;
    return textureSampleLevel(hash_texture, linear_sampler, wrapped / 256.0, 0.0);
}

// Get pass index
fn pass_index() -> u32 {
    return u32(u.pass_data.x);
}

// Get random values for this pass
fn pass_random() -> vec3<f32> {
    return u.pass_data.yzw;
}

// Convert global ID to normalized UV
fn gid_to_uv(gid: vec3<u32>, dims: vec2<u32>) -> vec2<f32> {
    return (vec2<f32>(gid.xy) + 0.5) / vec2<f32>(dims);
}

// Standard smoothstep
fn smooth(t: f32) -> f32 {
    return t * t * (3.0 - 2.0 * t);
}

// Bilinear interpolation
fn bilerp(v00: f32, v10: f32, v01: f32, v11: f32, f: vec2<f32>) -> f32 {
    let x0 = mix(v00, v10, f.x);
    let x1 = mix(v01, v11, f.x);
    return mix(x0, x1, f.y);
}
```

---

## Noise Generator

Multi-octave Perlin noise using FBM (Fractal Brownian Motion).

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | min_octave | 0-8 | Starting octave (frequency) |
| 1 | max_octave | 0-8 | Ending octave |
| 2 | persistence | 0-1 | Amplitude decay per octave |
| 3 | interpolation | 0/1 | 0=smoothstep, 1=linear |

### Algorithm

Each pass adds one octave:
- Frequency doubles each octave (cell size halves)
- Amplitude decays by persistence factor
- Smoothstep interpolation removes grid artifacts

### WGSL Implementation

```wgsl
// noise.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let pass = pass_index();

    // Decode parameters
    let min_octave = u32(param(0) * 255.0);
    let max_octave = u32(param(1) * 255.0);
    let persistence = param(2);
    let use_linear = param(3) > 0.5;

    // Skip if pass is outside octave range
    if (pass < min_octave || pass > max_octave) {
        // First pass outside range: just copy input or clear
        if (pass == 0u) {
            textureStore(output, gid.xy, vec4<f32>(0.0));
        }
        return;
    }

    // Load previous result (for accumulation)
    var prev = 0.0;
    if (pass > min_octave) {
        // Would need to sample from backbuffer texture
        // prev = textureSampleLevel(backbuffer, sampler, uv, 0.0).r;
    }

    // Calculate cell size for this octave
    let octave = pass - min_octave;
    let cell_size = 1.0 / pow(2.0, f32(octave + 2u));

    // Grid coordinates
    let grid_pos = uv / cell_size;
    let cell = floor(grid_pos);
    var frac = fract(grid_pos);

    // Apply smoothstep for smooth interpolation
    if (!use_linear) {
        frac = vec2<f32>(smooth(frac.x), smooth(frac.y));
    }

    // Sample hash at 4 corners
    let h00 = hash(cell + vec2<f32>(0.0, 0.0)).r;
    let h10 = hash(cell + vec2<f32>(1.0, 0.0)).r;
    let h01 = hash(cell + vec2<f32>(0.0, 1.0)).r;
    let h11 = hash(cell + vec2<f32>(1.0, 1.0)).r;

    // Bilinear interpolation
    let noise = bilerp(h00, h10, h01, h11, frac);

    // Amplitude for this octave
    let amplitude = pow(persistence, f32(octave));

    // Accumulate
    let result = prev + (noise - 0.5) * amplitude;

    textureStore(output, gid.xy, vec4<f32>(result + 0.5, result + 0.5, result + 0.5, 1.0));
}
```

---

## Gradient Generator

Six geometric gradient patterns in a single shader.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | pattern | 0-5 | Pattern selector |

### Patterns

| Value | Pattern | Formula |
|-------|---------|---------|
| 0 | Radial | `1 - length(uv - 0.5) * sqrt(2)` |
| 1 | Box | `1 - max(abs(uv.x - 0.5), abs(uv.y - 0.5)) * 2` |
| 2 | Horizontal | `uv.x` |
| 3 | Vertical | `uv.y` |
| 4 | Horizontal-Bi | `1 - abs(uv.x * 2 - 1)` |
| 5 | Vertical-Bi | `1 - abs(uv.y * 2 - 1)` |

### WGSL Implementation

```wgsl
// gradient.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let pattern = u32(param(0) * 255.0);

    var value: f32;
    let centered = uv - 0.5;

    switch (pattern) {
        case 0u: {
            // Radial (circular)
            value = 1.0 - length(centered) * 2.0 / sqrt(2.0);
        }
        case 1u: {
            // Box (Chebyshev distance)
            value = 1.0 - max(abs(centered.x), abs(centered.y)) * 2.0;
        }
        case 2u: {
            // Horizontal
            value = uv.x;
        }
        case 3u: {
            // Vertical
            value = uv.y;
        }
        case 4u: {
            // Horizontal bidirectional
            value = 1.0 - abs(1.0 - uv.x * 2.0);
        }
        case 5u: {
            // Vertical bidirectional
            value = 1.0 - abs(1.0 - uv.y * 2.0);
        }
        default: {
            value = 0.0;
        }
    }

    value = saturate(value);
    textureStore(output, gid.xy, vec4<f32>(value, value, value, 1.0));
}
```

---

## Cells Generator (Voronoi)

Voronoi distance field via multi-pass distance propagation.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | iterations | 0-16 | Propagation passes |
| 1 | power | 0-1 | Distance scale |
| 2 | size | 0-1 | Cell density |
| 3 | manhattan | 0/1 | Distance metric |

### WGSL Implementation

```wgsl
// cells.wgsl

fn distance_metric(delta: vec2<f32>, manhattan: bool) -> f32 {
    if (manhattan) {
        return abs(delta.x) + abs(delta.y);
    } else {
        return length(delta);
    }
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);
    let pass = pass_index();
    let random = pass_random();

    let power = param(1) * 10.0;
    let size = param(2) * 10.0 + 0.1;
    let use_manhattan = param(3) > 0.5;

    if (pass == 0u) {
        // First pass: compute initial distance to random feature point
        let feature = hash(random.xy * 256.0).xy;
        let delta = fract(uv * size - feature) - 0.5;
        let dist = distance_metric(delta, use_manhattan);
        let value = saturate(dist * power);

        textureStore(output, gid.xy, vec4<f32>(value, value, value, 1.0));
    } else {
        // Subsequent passes: propagate minimum distance
        // Sample neighbors from previous result
        // (Would need backbuffer access)

        // For now, just demonstrate the pattern
        let offset1 = random.xy * 0.1;
        let offset2 = random.yz * 0.1;

        // Current distance (would come from backbuffer)
        var dist = 1.0;

        // Check neighbors and take minimum
        // dist = min(dist, sample_backbuffer(uv + offset1).r);
        // dist = min(dist, sample_backbuffer(uv + offset2).r);

        textureStore(output, gid.xy, vec4<f32>(dist, dist, dist, 1.0));
    }
}
```

---

## Cells2 (Classic Voronoi)

Single-pass Voronoi checking 3×3 neighborhood.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | grid_x | 0-255 | Horizontal cell count |
| 1 | grid_y | 0-255 | Vertical cell count |

### WGSL Implementation

```wgsl
// cells2.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let grid_x = param(0) * 255.0 + 1.0;
    let grid_y = param(1) * 255.0 + 1.0;
    let grid = vec2<f32>(grid_x, grid_y);

    let pos = uv * grid;
    let cell = floor(pos);
    let local = fract(pos);

    var min_dist = 8.0;

    // Check 3×3 neighborhood
    for (var j = -1; j <= 1; j++) {
        for (var i = -1; i <= 1; i++) {
            let neighbor = vec2<f32>(f32(i), f32(j));
            let neighbor_cell = cell + neighbor;

            // Get random offset for seed in this cell
            let seed_offset = hash(neighbor_cell / grid * 256.0).xy;

            // Vector from local position to seed
            let to_seed = neighbor - local + seed_offset;

            // Update minimum distance
            min_dist = min(min_dist, dot(to_seed, to_seed));
        }
    }

    let value = saturate(sqrt(min_dist));
    textureStore(output, gid.xy, vec4<f32>(value, value, value, 1.0));
}
```

---

## SolidColor Generator

Trivial constant color output.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | red | 0-1 | Red channel |
| 1 | green | 0-1 | Green channel |
| 2 | blue | 0-1 | Blue channel |
| 3 | alpha | 0-1 | Alpha channel |

### WGSL Implementation

```wgsl
// solid_color.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let color = vec4<f32>(param(0), param(1), param(2), param(3));
    textureStore(output, gid.xy, color);
}
```

---

## Rectangle Generator

Superellipse (squircle) with configurable roundness.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | center_x | 0-1 | Horizontal center |
| 1 | center_y | 0-1 | Vertical center |
| 2 | half_width | 0-1 | Radius X |
| 3 | half_height | 0-1 | Radius Y |
| 4 | chamfer | 0-1 | Roundness (0=rect, 1=circle) |
| 5 | falloff | 0-1 | Edge softness |

### WGSL Implementation

```wgsl
// rectangle.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let center = vec2<f32>(param(0), param(1));
    let half_size = vec2<f32>(param(2), param(3)) * 0.5 + 0.001;
    let chamfer = max(param(4), 0.001);
    let falloff = max(param(5), 0.001);

    // Superellipse exponent: n = 2/chamfer
    // chamfer=1 → n=2 (circle)
    // chamfer→0 → n→∞ (rectangle)
    let n = 2.0 / chamfer;

    // Distance from center, normalized by half-size
    let delta = abs(uv - center) / half_size;

    // Superellipse distance: (|x|^n + |y|^n)^(1/n)
    let dist = pow(pow(delta.x, n) + pow(delta.y, n), 1.0 / n);

    // Inside amount: 1 when fully inside, 0 at boundary
    let inside = 1.0 - saturate(dist);

    // Apply falloff for soft edges
    let falloff_exp = 1.0 / falloff * 10.0;
    let value = pow(saturate(inside + 0.5), falloff_exp);

    textureStore(output, gid.xy, vec4<f32>(value, value, value, 1.0));
}
```

---

## Tiles Generator

Grid pattern with brick-style row offset.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | columns | 0-255 | Horizontal tile count |
| 1 | rows | 0-255 | Vertical tile count |
| 2 | offset | 0-1 | Row offset (0.5 = brick) |
| 3 | border | 0-1 | Gap/mortar width |

### WGSL Implementation

```wgsl
// tiles.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let cols = max(param(0) * 255.0, 1.0);
    let rows = max(param(1) * 255.0, 1.0);
    let offset = param(2);
    let border = param(3);

    let tile_size = vec2<f32>(1.0 / cols, 1.0 / rows);
    let border_size = min(tile_size.x, tile_size.y) * border;

    // Which row are we in?
    let row = floor(uv.y * rows);

    // Apply offset for this row
    var x = uv.x + row * offset * tile_size.x;
    x = fract(x);  // Wrap around

    // Which tile?
    let col = floor(x * cols);
    let tile_id = (row * cols + col + 1.0) / (rows * cols);

    // Local position within tile
    let local = vec2<f32>(
        fract(x * cols),
        fract(uv.y * rows)
    );

    // Check if in border region
    let in_border = local.x < border || local.x > (1.0 - border) ||
                    local.y < border || local.y > (1.0 - border);

    let value = select(tile_id, 0.0, in_border);

    textureStore(output, gid.xy, vec4<f32>(value, value, value, 1.0));
}
```

---

## EnvMap Generator

Radial gradient for environment map falloff.

### Parameters

| Index | Name | Range | Description |
|-------|------|-------|-------------|
| 0 | outer | 0-1 | Outer radius (where falloff=0) |
| 1 | inner | 0-1 | Inner radius (where falloff=1) |
| 2 | scale_x | 0-1 | Horizontal scale |
| 3 | scale_y | 0-1 | Vertical scale |

### WGSL Implementation

```wgsl
// envmap.wgsl

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(output);
    if (gid.x >= dims.x || gid.y >= dims.y) { return; }

    let uv = gid_to_uv(gid, dims);

    let outer = max(param(0), 0.001);
    let inner = param(1) * outer;
    let scale = vec2<f32>(
        max(param(2), 0.001),
        max(param(3), 0.001)
    );

    // Distance from center with scale
    let centered = (uv - 0.5) / (scale * outer);
    let dist = length(centered);

    // Linear interpolation between inner and outer radii
    let range = outer - inner;
    let value = 1.0 + (inner - dist) / max(range, 0.001);

    textureStore(output, gid.xy, vec4<f32>(saturate(value), saturate(value), saturate(value), 1.0));
}
```

---

## Related Documents

- [01-data-structures.md](01-data-structures.md) - Uniform struct layout
- [02-graph-evaluation.md](02-graph-evaluation.md) - How generators are invoked
- [05-transforms.md](05-transforms.md) - Transform operators
- [07-filters.md](07-filters.md) - Filter operators
