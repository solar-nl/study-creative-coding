# Rendering Deep Dive: Instance Rendering for Dynamic Shapes

> How do you efficiently render 1000 ellipses that change every frame?

---

## The Scenario

You have a simulation with 1000 ellipses. Every frame, each ellipse's position, width, and height change. What's the optimal way to render this?

This is a common pattern in creative coding:
- Particle systems
- Physics simulations
- Data visualizations
- Generative art with many moving elements

---

## Approach 1: Naive Immediate Mode (Baseline)

What most frameworks do by default:

```rust
for ellipse in &ellipses {
    draw.ellipse()
        .xy(ellipse.pos)
        .w_h(ellipse.width, ellipse.height);
}
```

**Cost per frame:**

| Operation | Count | Notes |
|-----------|-------|-------|
| Tessellation | 1000 | CPU-intensive (~4ms) |
| Buffer uploads | 1000 | Many small uploads |
| Draw calls | 1000 | Main bottleneck |

Each draw call has CPU-GPU synchronization overhead of ~10-20μs. With 1000 calls, that's 10-20ms of overhead alone—already over budget for 60fps.

---

## Approach 2: Accumulate into Single Mesh

Batch all geometry into one mesh:

```rust
let mut mesh = Mesh::new();
for ellipse in &ellipses {
    let verts = tessellate_ellipse(ellipse.width, ellipse.height);
    mesh.append_transformed(&verts, translate(ellipse.x, ellipse.y));
}
draw.mesh(&mesh);
```

**Cost per frame:**

| Operation | Count | Notes |
|-----------|-------|-------|
| Tessellation | 1000 | Still expensive |
| Buffer uploads | 1 | Combined ~200KB |
| Draw calls | 1 | Good! |

**Better**—one draw call instead of 1000. But still tessellating 1000 ellipses per frame. This is roughly what nannou does with automatic batching.

---

## Approach 3: Instance Rendering (Optimal)

### The Key Insight

An ellipse is just a scaled circle:

```
Circle:  x² + y² = 1
Ellipse: (x/a)² + (y/b)² = 1  →  circle scaled by (a, b)
```

So we can:
1. **Pre-tessellate a unit circle once** (at startup)
2. **Use instance rendering** with per-ellipse transform data

### Implementation

```rust
// === SETUP (once) ===
let unit_circle: VertexBuffer = tessellate_unit_circle(64); // 64 segments

// === EACH FRAME ===
// Build instance data (just the parameters that changed)
let instances: Vec<EllipseInstance> = ellipses.iter()
    .map(|e| EllipseInstance {
        position: [e.x, e.y],
        scale: [e.width * 0.5, e.height * 0.5],
        color: e.color.into(),
    })
    .collect();

// Upload instance buffer and draw
gpu.upload_instances(&instances);  // ~32KB for 1000 ellipses
gpu.draw_instanced(&unit_circle, instances.len());
```

**Cost per frame:**

| Operation | Count | Notes |
|-----------|-------|-------|
| Tessellation | 0 | Pre-computed! |
| Buffer uploads | 1 | Just instance data (~32KB) |
| Draw calls | 1 | Optimal |

### The Vertex Shader

The GPU transforms each vertex using instance data:

```glsl
// Per-vertex (unit circle, uploaded once, never changes)
layout(location = 0) in vec2 a_position;

// Per-instance (uploaded every frame, 32 bytes each)
layout(location = 1) in vec2 i_position;
layout(location = 2) in vec2 i_scale;
layout(location = 3) in vec4 i_color;

out vec4 v_color;

uniform mat4 u_projection;

void main() {
    // Transform unit circle vertex to ellipse
    vec2 world_pos = a_position * i_scale + i_position;
    gl_Position = u_projection * vec4(world_pos, 0.0, 1.0);
    v_color = i_color;
}
```

---

## Instance Data Layout

```rust
#[repr(C)]
struct EllipseInstance {
    position: [f32; 2],  // 8 bytes  - center (x, y)
    scale: [f32; 2],     // 8 bytes  - (width/2, height/2)
    color: [f32; 4],     // 16 bytes - RGBA
}
// Total: 32 bytes per ellipse
// 1000 ellipses = 32KB upload per frame
```

For comparison, tessellated geometry would be:
- 64 vertices × 12 bytes × 1000 ellipses = **768KB** per frame

Instance rendering uploads **24× less data**.

---

## Performance Comparison

For 1000 ellipses at 60fps:

| Approach | CPU Time | GPU Transfer | Draw Calls | Frame Budget |
|----------|----------|--------------|------------|--------------|
| Naive immediate | ~8ms | ~800KB | 1000 | Over budget |
| Single mesh | ~4ms | ~200KB | 1 | Tight |
| **Instancing** | **~0.1ms** | **~32KB** | **1** | **Plenty of headroom** |

Instance rendering is **~40× faster** than naive immediate mode.

---

## The Complete Pipeline

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           SETUP (once)                                   │
├─────────────────────────────────────────────────────────────────────────┤
│  Unit Circle Tessellation                                                │
│  ┌─────────────────────┐                                                │
│  │   64 vertices       │──▶ Upload to GPU ──▶ [VBO: never changes]      │
│  │   ~800 bytes        │                                                │
│  └─────────────────────┘                                                │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         EACH FRAME                                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  1. User updates ellipse data (simulation, physics, etc.)               │
│     ellipses[i].x = ...                                                 │
│     ellipses[i].width = ...                                             │
│                                                                          │
│  2. Build instance buffer (CPU, fast: ~0.05ms)                          │
│     ┌──────────────────────────────────────────────────────────┐        │
│     │ [pos, scale, color] × 1000 = 32KB                        │        │
│     └──────────────────────────────────────────────────────────┘        │
│                              │                                           │
│                              ▼                                           │
│  3. Upload instance buffer (one GPU transfer)                           │
│     ┌──────────────────────────────────────────────────────────┐        │
│     │ Instance VBO: 32KB ──▶ GPU                               │        │
│     └──────────────────────────────────────────────────────────┘        │
│                              │                                           │
│                              ▼                                           │
│  4. Draw instanced (ONE draw call)                                      │
│     ┌──────────────────────────────────────────────────────────┐        │
│     │ glDrawArraysInstanced(TRIANGLE_FAN, 0, 64, 1000)         │        │
│     │                                                          │        │
│     │ GPU executes vertex shader 64,000 times in parallel:     │        │
│     │   world_pos = unit_circle_vertex * scale + position      │        │
│     └──────────────────────────────────────────────────────────┘        │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Handling Strokes

Non-uniform scaling distorts stroke width:

```
Unit circle with stroke:        Scaled to ellipse:
        ┌───┐                        ┌─────────┐
       ╱     ╲                      ╱           ╲
      │   ●   │                    │      ●      │
       ╲     ╱                      ╲           ╱
        └───┘                        └─────────┘
     uniform stroke              stroke thicker on sides!
```

### Solution A: Accept It

Often fine for creative coding. Many generative artworks don't need precise strokes.

### Solution B: Shader-Based Correction

```glsl
// Fragment shader with stroke width correction
in vec2 v_local_pos;   // Position on unit circle
in vec2 v_scale;       // Instance scale

uniform float u_stroke_width;

void main() {
    // Distance to unit circle edge in local space
    float r = length(v_local_pos);
    float dist_to_edge = 1.0 - r;

    // Correction factor for non-uniform scale
    vec2 normal = normalize(v_local_pos);
    float scale_factor = length(normal * v_scale);

    // Corrected distance in world space
    float world_dist = dist_to_edge * scale_factor;

    // Anti-aliased stroke
    float stroke = smoothstep(0.0, fwidth(world_dist),
                              u_stroke_width - abs(world_dist));
    // Use stroke for alpha or color mixing
}
```

### Solution C: SDF Rendering

Compute ellipse distance in fragment shader for perfect strokes at any scale:

```glsl
float ellipse_sdf(vec2 p, vec2 radii) {
    vec2 p_normalized = p / radii;
    float r = length(p_normalized);
    return (r - 1.0) * min(radii.x, radii.y);
}

void main() {
    float d = ellipse_sdf(v_local_pos * v_scale, v_scale);
    float fill = 1.0 - smoothstep(0.0, fwidth(d), d);
    float stroke = 1.0 - smoothstep(u_stroke_width, u_stroke_width + fwidth(d), abs(d));
    // Combine fill and stroke
}
```

---

## Adaptive Level of Detail

Large ellipses need more segments than small ones. Use LOD buckets:

```rust
// Pre-tessellate circles at different detail levels
let lod_circles = [
    tessellate_unit_circle(16),   // LOD 0: tiny ellipses (<20px)
    tessellate_unit_circle(32),   // LOD 1: small (20-50px)
    tessellate_unit_circle(64),   // LOD 2: medium (50-200px)
    tessellate_unit_circle(128),  // LOD 3: large (>200px)
];

// Group ellipses by LOD
let mut lod_buckets: [Vec<EllipseInstance>; 4] = Default::default();

for e in &ellipses {
    let screen_size = e.width.max(e.height) * zoom;
    let lod = match screen_size {
        s if s < 20.0 => 0,
        s if s < 50.0 => 1,
        s if s < 200.0 => 2,
        _ => 3,
    };
    lod_buckets[lod].push(e.to_instance());
}

// 4 draw calls instead of 1, but adaptive quality
for (lod, instances) in lod_buckets.iter().enumerate() {
    if !instances.is_empty() {
        gpu.draw_instanced(&lod_circles[lod], instances);
    }
}
```

**Trade-off:** 4 draw calls instead of 1, but:
- Tiny ellipses render faster (fewer vertices)
- Large ellipses look smoother (more vertices)
- Total vertex count is often lower

---

## Framework Support

| Framework | Default Approach | Instance Rendering Support |
|-----------|------------------|---------------------------|
| p5.js | 1000 tessellations + 1000 draws | No (requires raw WebGL) |
| Processing | Batches by texture, still tessellates | No native instancing |
| OpenFrameworks | 1000 draws (or manual mesh) | Yes, via ofVbo + custom shader |
| Cinder | Manual mesh or Batch | Yes, `batch->drawInstanced()` |
| openrndr | Batches circles (not ellipses) | Yes, custom batch builder |
| nannou | Accumulates mesh, tessellates | Yes, via raw wgpu |

Only **Cinder** has a clean built-in API for this. Others require dropping to low-level graphics APIs.

---

## Optimal API Design

### High-Level (Hides Complexity)

```rust
// Batch builder pattern
draw.ellipses(|batch| {
    for e in &simulation.ellipses {
        batch.ellipse(e.x, e.y, e.width, e.height)
             .fill(e.color);
    }
});

// Iterator pattern (even cleaner)
draw.ellipses_from(simulation.ellipses.iter().map(|e| {
    Ellipse::at(e.x, e.y)
        .size(e.width, e.height)
        .fill(e.color)
}));
```

Framework automatically:
- Uses pre-tessellated unit circle
- Builds instance buffer
- Issues single draw call

### Low-Level (Full Control)

```rust
// Manual instance management
let circle_geo = Geometry::unit_circle(64);
let mut instances = InstanceBuffer::<EllipseInstance>::new(1000);

// In draw loop
instances.clear();
for e in &ellipses {
    instances.push(EllipseInstance {
        position: e.pos,
        scale: e.size * 0.5,
        color: e.color,
    });
}
instances.upload();
draw.instanced(&circle_geo, &instances);
```

---

## Extending to Other Shapes

The same pattern works for any shape that can be uniformly parameterized:

| Shape | Unit Geometry | Instance Data |
|-------|---------------|---------------|
| Circle | Unit circle | position, radius, color |
| Ellipse | Unit circle | position, scale_xy, color |
| Rectangle | Unit quad | position, size, color |
| Rounded rect | Unit rounded rect | position, size, corner_radius, color |
| Line segment | Unit line (0,0)→(1,0) | start, end, width, color |
| Triangle | N/A (must tessellate) | — |
| Arbitrary path | N/A (must tessellate) | — |

For arbitrary paths, fall back to mesh accumulation (Approach 2).

---

## When NOT to Use Instancing

Instance rendering isn't always the answer:

1. **Few shapes** (<50): Overhead of instancing may exceed benefit
2. **Shapes with different topology**: Can't instance a circle with a star
3. **Complex per-shape effects**: Custom shaders per shape
4. **Static scenes**: Pre-bake everything into one mesh

---

## Summary

For many dynamic shapes of the same type:

```
┌────────────────────────────────────────────────────────────┐
│  1. Pre-tessellate canonical geometry (once)               │
│  2. Store per-shape parameters as instance attributes      │
│  3. Upload only instance buffer each frame (~32 bytes/shape)│
│  4. One instanced draw call renders everything             │
└────────────────────────────────────────────────────────────┘
```

This leverages GPU parallelism—the vertex shader transforms all vertices simultaneously while you only upload the parameters that changed.

**Result:** 40× faster than naive immediate mode, with headroom for 10,000+ shapes at 60fps.

---

## Sources

- [OpenGL Instanced Rendering](https://www.khronos.org/opengl/wiki/Vertex_Rendering#Instancing)
- [wgpu Instance Rendering](https://sotrh.github.io/learn-wgpu/beginner/tutorial7-instancing/)
- [Cinder gl::Batch::drawInstanced](https://libcinder.org/docs/branch/master/classcinder_1_1gl_1_1_batch.html)
- [GPU Gems: Instancing](https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-3-inside-geometry-instancing)

---

*This document is part of the [Rendering Modes](rendering-modes.md) research.*
