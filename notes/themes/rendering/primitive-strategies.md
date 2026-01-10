# Rendering Deep Dive: Optimal Strategies per Primitive Type

> Which 2D primitives can be instanced, and which need other approaches?

## Key Insight

> **Primitive strategy's core idea:** Instance when variation fits in fixed-size data (circles, rects); bucket by topology when it doesn't (varying polygon sides); accumulate geometry for arbitrary shapes (beziers, paths).

---

## The Core Principle

Instance rendering works when a shape can be expressed as:

```
final_shape = canonical_geometry × per_instance_parameters
```

The question for each primitive: **can its variation be captured in fixed-size instance data?**

---

## Tier 1: Perfect for Instancing

These primitives map cleanly to `unit_shape + transform`:

### Circles

```rust
// Unit geometry: circle radius 1, centered at origin (64 vertices)
// Instance data: 16 bytes
struct CircleInstance {
    center: [f32; 2],   // 8 bytes
    radius: f32,        // 4 bytes
    color: u32,         // 4 bytes (packed RGBA)
}
```

```glsl
// Vertex shader
vec2 world = a_position * i_radius + i_center;
```

### Ellipses

```rust
// Unit geometry: circle radius 1
// Instance data: 20 bytes
struct EllipseInstance {
    center: [f32; 2],
    radii: [f32; 2],    // (rx, ry)
    color: u32,
}
```

```glsl
vec2 world = a_position * i_radii + i_center;
```

### Rectangles

```rust
// Unit geometry: quad from (0,0) to (1,1)
// Instance data: 20 bytes
struct RectInstance {
    position: [f32; 2], // top-left corner
    size: [f32; 2],     // (width, height)
    color: u32,
}
```

```glsl
vec2 world = a_position * i_size + i_position;
```

### Lines (as Thick Segments)

```rust
// Unit geometry: quad from (0, -0.5) to (1, 0.5)
// Instance data: 24 bytes
struct LineInstance {
    start: [f32; 2],
    end: [f32; 2],
    width: f32,
    color: u32,
}
```

```glsl
// Vertex shader computes rotation and scale from start/end
vec2 dir = normalize(i_end - i_start);
vec2 perp = vec2(-dir.y, dir.x);
float len = length(i_end - i_start);

vec2 local = a_position * vec2(len, i_width);
vec2 world = mat2(dir, perp) * local + i_start;
```

### Regular Polygons (Fixed Vertex Count)

```rust
// Unit geometry: hexagon with radius 1 (or any fixed N-gon)
// Instance data: 20 bytes
struct HexagonInstance {
    center: [f32; 2],
    radius: f32,
    rotation: f32,
    color: u32,
}
```

```glsl
// Vertex shader applies rotation then scale
float c = cos(i_rotation), s = sin(i_rotation);
mat2 rot = mat2(c, -s, s, c);
vec2 world = rot * a_position * i_radius + i_center;
```

**Tier 1 Result:** One draw call per primitive type, regardless of instance count.

---

## Tier 2: Works with Shader Tricks

These need extra per-instance parameters or fragment shader computation:

### Rounded Rectangles

**Challenge:** Corner radius varies per instance, but tessellation depends on it.

**Solution A: SDF in Fragment Shader**

```rust
// Unit geometry: quad (0,0) to (1,1)
// Instance data: 24 bytes
struct RoundedRectInstance {
    position: [f32; 2],
    size: [f32; 2],
    corner_radius: f32,
    color: u32,
}
```

```glsl
// Fragment shader computes rounded rect SDF
float rounded_rect_sdf(vec2 p, vec2 half_size, float radius) {
    vec2 q = abs(p) - half_size + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

void main() {
    // v_local_pos is 0..1, convert to centered coordinates
    vec2 local = (v_local_pos - 0.5) * i_size;
    float d = rounded_rect_sdf(local, i_size * 0.5, i_corner_radius);

    // Anti-aliased edge
    float alpha = 1.0 - smoothstep(0.0, fwidth(d), d);
    fragColor = vec4(unpack_color(i_color).rgb, alpha);
}
```

**Solution B: LOD Buckets by Radius**

```rust
// Pre-tessellate for discrete corner radii
let rounded_rects = [
    tessellate_rounded_rect(0.0),      // Sharp corners
    tessellate_rounded_rect(4.0),      // Small radius
    tessellate_rounded_rect(8.0),      // Medium
    tessellate_rounded_rect(16.0),     // Large
    tessellate_rounded_rect(f32::MAX), // Stadium (fully rounded ends)
];

// Bucket instances by closest radius
// Maximum 5 draw calls
```

### Arcs (Partial Circles)

**Challenge:** Start and end angles vary per instance.

**Solution: Full Circle + Fragment Discard**

```rust
// Unit geometry: full circle (reuse from circles)
// Instance data: 28 bytes
struct ArcInstance {
    center: [f32; 2],
    radius: f32,
    start_angle: f32,   // radians
    end_angle: f32,     // radians
    width: f32,         // stroke width (0 for filled)
    color: u32,
}
```

```glsl
// Fragment shader discards pixels outside angle range
void main() {
    vec2 local = v_local_pos;  // Position on unit circle
    float angle = atan(local.y, local.x);

    // Normalize angle to [0, 2π)
    if (angle < 0.0) angle += 2.0 * PI;

    float start = i_start_angle;
    float end = i_end_angle;

    // Handle wraparound (e.g., start=350°, end=10°)
    bool in_arc;
    if (start <= end) {
        in_arc = (angle >= start && angle <= end);
    } else {
        in_arc = (angle >= start || angle <= end);
    }

    if (!in_arc) discard;

    // Optional: stroke width check for arc strokes
    float r = length(local);
    if (i_width > 0.0) {
        float half_w = i_width / (2.0 * i_radius);
        if (r < 1.0 - half_w || r > 1.0 + half_w) discard;
    }

    fragColor = unpack_color(i_color);
}
```

### Rings (Donuts)

```rust
// Unit geometry: circle (filled disc)
// Instance data: 24 bytes
struct RingInstance {
    center: [f32; 2],
    outer_radius: f32,
    inner_ratio: f32,   // inner/outer radius (0.0 to 1.0)
    color: u32,
}
```

```glsl
void main() {
    float r = length(v_local_pos);

    // Discard inside inner circle
    if (r < i_inner_ratio) discard;

    // SDF for anti-aliased edges
    float outer_d = r - 1.0;
    float inner_d = i_inner_ratio - r;
    float d = max(outer_d, inner_d);

    float alpha = 1.0 - smoothstep(0.0, fwidth(d), d);
    fragColor = vec4(unpack_color(i_color).rgb, alpha);
}
```

### Pie Slices (Filled Arcs)

```rust
// Unit geometry: circle
// Instance data: 24 bytes
struct PieInstance {
    center: [f32; 2],
    radius: f32,
    start_angle: f32,
    end_angle: f32,
    color: u32,
}
```

Same angle-checking logic as arcs, but without the inner radius check.

**Tier 2 Result:** One draw call, but fragment shader does extra work. Trade-off between draw calls and fragment complexity.

---

## Tier 3: Topology Buckets Required

These need separate batches for different configurations:

### Regular Polygons (Varying Vertex Count)

Can't instance a triangle to a hexagon—different vertex counts mean different geometry.

```rust
// Separate unit geometries per vertex count
let unit_polygons: HashMap<u32, VertexBuffer> = [
    (3, tessellate_regular_polygon(3)),  // Triangle
    (4, tessellate_regular_polygon(4)),  // Square
    (5, tessellate_regular_polygon(5)),  // Pentagon
    (6, tessellate_regular_polygon(6)),  // Hexagon
    (8, tessellate_regular_polygon(8)),  // Octagon
].into();

// Instance data (same for all)
struct PolygonInstance {
    center: [f32; 2],
    radius: f32,
    rotation: f32,
    color: u32,
}

// Bucket by vertex count
let mut buckets: HashMap<u32, Vec<PolygonInstance>> = HashMap::new();

for shape in &shapes {
    buckets
        .entry(shape.sides)
        .or_default()
        .push(shape.to_instance());
}

// One draw call per unique vertex count
for (sides, instances) in &buckets {
    let geo = &unit_polygons[sides];
    draw_instanced(geo, instances);
}
```

**Typical case:** 3-8 sided polygons = maximum 6 draw calls.

### Stars (Varying Point Count)

```rust
// star(5 points) has 10 vertices
// star(6 points) has 12 vertices
// Can't instance between them

struct StarInstance {
    center: [f32; 2],
    outer_radius: f32,
    inner_radius: f32,  // Controls "pointiness"
    rotation: f32,
    color: u32,
}

// Bucket by point count
```

### Polylines (Fixed Segment Count)

If all polylines have the same segment count, instancing works:

```rust
// 4-segment polyline = 5 points
struct Polyline4Instance {
    points: [[f32; 2]; 5],  // 40 bytes
    width: f32,
    color: u32,
}
```

But varying segment counts require separate batches or mesh accumulation.

**Tier 3 Result:** O(configurations) draw calls, typically a small constant (3-10).

---

## Tier 4: Must Accumulate Geometry

These can't be efficiently instanced—topology varies arbitrarily per shape:

### Arbitrary Triangles

Three arbitrary points can't be uniformly parameterized with a simple transform.

**Option A: Store Points as Instance Data**

```rust
struct TriangleInstance {
    p0: [f32; 2],
    p1: [f32; 2],
    p2: [f32; 2],  // 24 bytes for positions
    color: u32,
}
```

```glsl
// Vertex shader selects point based on vertex index
void main() {
    vec2 positions[3] = vec2[3](i_p0, i_p1, i_p2);
    vec2 world = positions[gl_VertexID % 3];
    // ...
}
```

This works but is awkward. The "unit geometry" is just 3 indices.

**Option B: Accumulate into Mesh (Often Better)**

```rust
let mut mesh = Mesh::new();
for tri in &triangles {
    mesh.push_vertex(tri.p0, tri.color);
    mesh.push_vertex(tri.p1, tri.color);
    mesh.push_vertex(tri.p2, tri.color);
}
draw.mesh(&mesh);  // One draw call, simple
```

### Quadrilaterals (Arbitrary)

Same situation—4 arbitrary points need 32 bytes of instance data, or just accumulate.

### Bezier Curves

Control points vary arbitrarily per curve:

```rust
// Could pass control points as instance data...
struct CubicBezierInstance {
    p0: [f32; 2],  // start
    p1: [f32; 2],  // control 1
    p2: [f32; 2],  // control 2
    p3: [f32; 2],  // end
    width: f32,
    color: u32,
}
// 40 bytes, and tessellation must happen somewhere
```

**Problem:** Tessellation (curve → line segments) can't easily happen in vertex shader.

**Practical approach:** Tessellate on CPU (using Lyon, etc.), accumulate into single mesh.

```rust
let mut mesh = Mesh::new();
for curve in &curves {
    let segments = tessellate_bezier(&curve, tolerance);
    mesh.append_polyline(&segments, curve.width, curve.color);
}
draw.mesh(&mesh);
```

### Arbitrary Paths

Variable segment types (line, quadratic, cubic, arc) and segment counts:

```
Path A: M 0 0 L 100 100 Q 150 50 200 100 Z        // 3 segments
Path B: M 0 0 C 10 20 30 40 50 60 L 100 0         // 2 segments, different types
Path C: M 0 0 L 10 10 L 20 0 L 30 10 L 40 0 ...   // Many segments
```

**No instancing possible.** Must tessellate and accumulate:

```rust
let mut mesh = Mesh::new();
for path in &paths {
    // Lyon or similar tessellates path to triangles
    let tessellated = tessellate_path(path, fill_options);
    mesh.append(&tessellated);
}
draw.mesh(&mesh);  // One draw call for all paths
```

**Tier 4 Result:** One draw call via mesh accumulation, but CPU tessellation required.

---

## Summary Table

| Primitive | Strategy | Instance Size | Draw Calls | Notes |
|-----------|----------|---------------|------------|-------|
| Circle | Instance | 16 bytes | 1 | Optimal |
| Ellipse | Instance | 20 bytes | 1 | Optimal |
| Rectangle | Instance | 20 bytes | 1 | Optimal |
| Line segment | Instance | 24 bytes | 1 | Optimal |
| Regular polygon (same N) | Instance | 20 bytes | 1 | Optimal |
| Rounded rect | SDF or LOD bucket | 24 bytes | 1-5 | SDF preferred |
| Arc | Instance + discard | 28 bytes | 1 | Fragment work |
| Ring | Instance + discard | 24 bytes | 1 | Fragment work |
| Pie slice | Instance + discard | 24 bytes | 1 | Fragment work |
| Regular polygon (varying N) | Bucket by N | 20 bytes | O(unique N) | Typically 3-8 |
| Star (varying points) | Bucket by N | 28 bytes | O(unique N) | Typically 3-8 |
| Arbitrary triangle | Accumulate | — | 1 | Mesh append |
| Bezier curve | Accumulate | — | 1 | CPU tessellation |
| Arbitrary path | Accumulate | — | 1 | CPU tessellation |

---

## Unified Rendering Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         DRAW COMMANDS                                    │
│  draw.circles(...)   draw.rects(...)   draw.paths(...)                  │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      PRIMITIVE ROUTER                                    │
│                                                                          │
│  Tier 1 (Instance)        Tier 2 (Instance+SDF)    Tier 4 (Accumulate) │
│  ┌──────────────────┐     ┌──────────────────┐     ┌──────────────────┐ │
│  │ circles: [...]   │     │ rounded_rects:   │     │ paths: [...]     │ │
│  │ ellipses: [...]  │     │   [...] (SDF)    │     │ curves: [...]    │ │
│  │ rects: [...]     │     │ arcs: [...]      │     │ triangles: [...] │ │
│  │ lines: [...]     │     │ rings: [...]     │     │                  │ │
│  └────────┬─────────┘     └────────┬─────────┘     └────────┬─────────┘ │
│           │                        │                        │           │
│           ▼                        ▼                        ▼           │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    INSTANCE BUFFERS                               │  │
│  │  circles_instances   (1 draw)                                     │  │
│  │  ellipses_instances  (1 draw)                                     │  │
│  │  rects_instances     (1 draw)                                     │  │
│  │  lines_instances     (1 draw)                                     │  │
│  │  rounded_instances   (1 draw, SDF shader)                         │  │
│  │  arcs_instances      (1 draw, discard shader)                     │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    ACCUMULATED MESH                               │  │
│  │  [tessellated path vertices + indices]  (1 draw)                  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                         GPU SUBMISSION                                   │
│                                                                          │
│  Draw 1: circles (instanced)      1000 circles → 1 call                 │
│  Draw 2: ellipses (instanced)     500 ellipses → 1 call                 │
│  Draw 3: rects (instanced)        2000 rects → 1 call                   │
│  Draw 4: lines (instanced)        300 lines → 1 call                    │
│  Draw 5: rounded_rects (SDF)      100 rounded rects → 1 call            │
│  Draw 6: arcs (discard)           50 arcs → 1 call                      │
│  Draw 7: paths (indexed)          20 paths → 1 call                     │
│                                                                          │
│  Total: 7 draw calls for 3970 shapes                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## API Design

### High-Level (Framework Routes Automatically)

```rust
fn draw(&self, draw: &Draw) {
    // All circles batched together (instanced, 1 draw call)
    for particle in &self.particles {
        draw.ellipse()
            .xy(particle.pos)
            .radius(particle.size)
            .color(particle.color);
    }

    // All rects batched together (instanced, 1 draw call)
    for button in &self.ui_buttons {
        draw.rect()
            .xy(button.pos)
            .wh(button.size)
            .color(button.color);
    }

    // All rounded rects batched (SDF instanced, 1 draw call)
    for card in &self.cards {
        draw.rounded_rect()
            .xy(card.pos)
            .wh(card.size)
            .corner_radius(8.0)
            .color(card.color);
    }

    // All paths accumulated (mesh, 1 draw call)
    for curve in &self.curves {
        draw.path()
            .points(&curve.points)
            .stroke_weight(2.0)
            .color(curve.color);
    }
}
// Result: 4 draw calls total, regardless of shape counts
```

### Explicit Batching (When Needed)

```rust
// Force specific batching behavior
draw.instances::<Circle>()
    .geometry(&unit_circle)
    .data(&circle_instances)
    .draw();

// Or batch builder for complex cases
draw.batch(|b| {
    for shape in &mixed_shapes {
        match shape {
            Shape::Circle(c) => b.circle(c.x, c.y, c.r),
            Shape::Rect(r) => b.rect(r.x, r.y, r.w, r.h),
            // Framework figures out optimal batching
        }
    }
});
```

---

## Performance Characteristics

### Typical Creative Coding Scene

| Content | Count | Strategy | Draw Calls |
|---------|-------|----------|------------|
| Background particles | 5000 | Instance (circles) | 1 |
| Foreground shapes | 200 | Instance (ellipses) | 1 |
| UI rectangles | 50 | Instance (rects) | 1 |
| Connecting lines | 500 | Instance (lines) | 1 |
| Bezier curves | 20 | Accumulate | 1 |
| **Total** | **5770** | | **5** |

### Scaling Limits

| Approach | Practical Limit | Bottleneck |
|----------|-----------------|------------|
| Instancing | 100,000+ shapes | Instance buffer size, vertex shader |
| SDF instancing | 10,000+ shapes | Fragment shader (per-pixel SDF) |
| Mesh accumulation | 50,000+ shapes | CPU tessellation time |

---

## Decision Flowchart

```
Is the shape parameterizable with fixed-size data?
│
├─ YES: Can all instances share the same vertex topology?
│   │
│   ├─ YES: Is the parameterization a simple transform?
│   │   │
│   │   ├─ YES → Tier 1: Pure instancing
│   │   │        (circle, ellipse, rect, line)
│   │   │
│   │   └─ NO → Tier 2: Instance + shader tricks
│   │            (rounded rect via SDF, arc via discard)
│   │
│   └─ NO → Tier 3: Bucket by topology
│            (regular polygons, stars)
│
└─ NO → Tier 4: Accumulate geometry
         (arbitrary triangles, beziers, paths)
```

---

## Key Insight

The optimal rendering strategy depends on **how much shape variation can be captured in fixed-size instance data**:

| Variation Type | Strategy |
|----------------|----------|
| Position, scale, rotation, color | Instance with transform |
| Continuous parameter (radius, angle) | Instance with parameter |
| Discrete topology (vertex count) | Bucket by topology |
| Arbitrary topology | Accumulate geometry |

A well-designed framework routes primitives to the optimal strategy automatically, achieving **O(primitive types)** draw calls rather than **O(shape count)**.

---

## Sources

- [OpenGL Instanced Rendering](https://www.khronos.org/opengl/wiki/Vertex_Rendering#Instancing)
- [wgpu](https://github.com/gfx-rs/wgpu)
- [Inigo Quilez - 2D SDF Functions](https://iquilezles.org/articles/distfunctions2d/)
- [Lyon Tessellation](https://github.com/nical/lyon)

---

*This document is part of the [Rendering Modes](rendering-modes.md) research.*
