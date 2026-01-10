# Vector Graphics Deep Dive: Tessellation

> How do you turn a Bezier curve into triangles?

## Key Insight

> **The core challenge:** Tessellation is expensive enough that you must cache results, yet dynamic enough that the cache strategy defines your framework's performance ceiling.

---

## The Problem: GPUs Only Understand Triangles

When you draw an ellipse, your creative coding framework doesn't send "ellipse" to the GPU. GPUs have one primitive they're optimized for: **triangles**. Everything else—curves, circles, complex polygons—must be converted to triangles first.

This conversion is called **tessellation** (or triangulation). It's computationally expensive, which is why understanding when and how it happens matters for performance.

---

## The Two-Stage Pipeline

Tessellation typically happens in two stages:

```
┌──────────────────────────────────────────────────────────────┐
│  Stage 1: Flattening                                          │
│  "Convert curves to line segments"                           │
│                                                               │
│  Bezier curve → Series of short straight lines               │
│  Uses: Adaptive subdivision based on error tolerance         │
└──────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────┐
│  Stage 2: Triangulation                                       │
│  "Convert polygon to triangles"                              │
│                                                               │
│  Complex polygon → Triangle mesh                              │
│  Uses: Ear clipping, monotone decomposition, Delaunay        │
└──────────────────────────────────────────────────────────────┘
```

### Adaptive Curve Flattening

The key insight: you don't need uniform subdivision. Tight curves need more segments; gentle curves need fewer.

```
Uniform (wasteful):        Adaptive (efficient):
  ●───●───●───●───●          ●─────────●
  │       curve       │      │   curve   │
  ●───●───●───●───●          ●──●──●──●──●
  (same segments              (more where
   everywhere)                 curvature high)
```

Lyon's adaptive sampling:

```rust
fn adaptive_flatten(curve: &CubicBezier, tolerance: f32) -> Vec<Point> {
    let mut points = vec![curve.start];
    adaptive_flatten_recursive(curve, tolerance, &mut points);
    points.push(curve.end);
    points
}

fn adaptive_flatten_recursive(curve: &CubicBezier, tol: f32, out: &mut Vec<Point>) {
    // Measure how far the curve deviates from a straight line
    let deviation = curve.baseline_distance();

    if deviation < tol {
        // Close enough to a line—stop subdividing
        return;
    }

    // Split at t=0.5 and recurse
    let (left, right) = curve.split(0.5);
    adaptive_flatten_recursive(&left, tol, out);
    out.push(left.end);
    adaptive_flatten_recursive(&right, tol, out);
}
```

---

## Tessellation Libraries

### GLU Tessellator (Legacy)

The original. Part of OpenGL since the 90s.

**Pros:** Available everywhere OpenGL is.
**Cons:** Fixed-function era API, callback-heavy, some edge case bugs.

Used by: Cinder, older OpenFrameworks

### libtess2 (OpenFrameworks)

A cleanup of the GLU tessellator with better API and fewer bugs.

```cpp
TESStesselator* tess = tessNewTess(nullptr);

// Add contours
tessAddContour(tess, 2, points.data(), sizeof(vec2), points.size());

// Tessellate with winding rule
tessTesselate(tess, TESS_WINDING_ODD, TESS_POLYGONS, 3, 2, nullptr);

// Get triangles
const float* verts = tessGetVertices(tess);
const int* indices = tessGetElements(tess);
```

### Lyon (Rust)

Modern, pure-Rust tessellation. Battle-tested in Firefox (via WebRender).

```rust
use lyon::tessellation::{FillTessellator, FillOptions, BuffersBuilder};

let mut tessellator = FillTessellator::new();
let options = FillOptions::tolerance(0.1);

tessellator.tessellate_path(
    path.iter(),
    &options,
    &mut BuffersBuilder::new(&mut vertex_buffer, |vertex: FillVertex| {
        MyVertex {
            position: vertex.position().to_array(),
        }
    }),
)?;
```

**Key features:**
- Adaptive curve flattening
- Handles self-intersecting paths
- Memory-efficient (no intermediate allocations)
- Customizable vertex generation via `GeometryBuilder` trait

### kartifex (openrndr)

Used internally by openrndr for boolean operations and tessellation.

```kotlin
// Convert to kartifex primitives
val ring = Ring2(segments.map { it.toCurve2() })
val region = Region2(listOf(ring))

// Boolean ops return new regions
val result = region1.union(region2)

// Convert back to openrndr shapes
result.toShape()
```

---

## CPU vs GPU Tessellation

### CPU Tessellation (Most Frameworks)

**How it works:** Tessellation runs on CPU before upload to GPU.

```
Path data → CPU tessellator → Vertex buffer → GPU render
```

**Pros:**
- Works on all GPUs
- Predictable performance
- Results can be cached

**Cons:**
- Main thread work (can stutter)
- Upload cost for changing geometry

**When to use:** Static or slowly-changing shapes.

### GPU Tessellation (Hardware)

**How it works:** GPU tessellation shaders generate vertices.

```
Control points → Tessellation Control Shader → Tessellation Evaluation Shader → Vertices
```

Available in: OpenGL 4.0+, Direct3D 11+, Vulkan, Metal

**Pros:**
- No CPU bottleneck
- Can animate smoothly (just change parameters)
- LOD automatic based on screen size

**Cons:**
- More complex shaders
- Not available on older/mobile GPUs
- Less control over triangle quality

**When to use:** Dynamic geometry, terrain, LOD systems.

### Compute Shader Tessellation

**How it works:** General-purpose compute generates vertex buffers.

Used by advanced renderers like Vello for resolution-independent text and paths.

---

## Winding Rules

When paths self-intersect, winding rules determine what's "inside":

```
        Self-Intersecting Star

          Even-Odd Rule:           Non-Zero Rule:
              ★                         ★
           /     \                   /     \
          /   ☆   \                 /       \
         /_________\               /_________\

    (center is outside)         (center is inside)
```

**Even-Odd (most common):** A point is inside if a ray crosses the boundary an odd number of times.

**Non-Zero:** Count +1 for clockwise crossings, -1 for counter-clockwise. Inside if sum ≠ 0.

Both Lyon and libtess2 support configurable winding rules.

---

## Performance Considerations

### Cache Tessellated Geometry

The biggest win: don't re-tessellate shapes that haven't changed.

```rust
struct CachedShape {
    path: Path,
    mesh: Option<Mesh>,
    dirty: bool,
}

impl CachedShape {
    fn get_mesh(&mut self, tessellator: &mut Tessellator) -> &Mesh {
        if self.dirty || self.mesh.is_none() {
            let mesh = tessellator.tessellate(&self.path);
            self.mesh = Some(mesh);
            self.dirty = false;
        }
        self.mesh.as_ref().unwrap()
    }

    fn set_path(&mut self, path: Path) {
        self.path = path;
        self.dirty = true;
    }
}
```

### Tolerance Trade-offs

Lower tolerance = more triangles = smoother curves = slower.

```rust
// For UI elements at screen resolution
let options = FillOptions::tolerance(0.5);  // ~0.5 pixel error

// For zooming/export
let options = FillOptions::tolerance(0.01);  // Sub-pixel precision

// For thumbnails
let options = FillOptions::tolerance(2.0);  // Coarser is fine
```

### Batch Similar Shapes

One draw call with many triangles beats many draw calls with few:

```rust
// Bad: 100 draw calls
for shape in shapes {
    tessellator.tessellate(&shape, &mut mesh);
    gpu.draw(&mesh);
    mesh.clear();
}

// Good: 1 draw call
for shape in shapes {
    tessellator.tessellate(&shape, &mut combined_mesh);
}
gpu.draw(&combined_mesh);
```

---

## Framework Comparison

| Framework | Tessellator | Curve Flattening | Caching |
|-----------|-------------|------------------|---------|
| p5.js | Browser (Canvas/WebGL) | Browser handles | None |
| Processing | Java2D/OpenGL | Per-renderer | PShape |
| OpenFrameworks | libtess2 | Configurable | ofPath cache |
| Cinder | GLU tessellator | Per-call | Manual |
| openrndr | kartifex | Configurable | Lazy |
| nannou | Lyon | Adaptive | Manual |

---

## Recommendations for Rust

1. **Use Lyon** for fill tessellation—it's fast, correct, and pure Rust.

2. **Cache aggressively**—tessellation should happen once per shape change, not once per frame.

3. **Choose tolerance based on output**—0.1-0.5 for screen, 0.01 for export.

4. **Consider GPU tessellation** only for truly dynamic geometry (particle systems, terrain).

5. **Batch draws** when rendering many similar shapes.

---

## Sources

- [Lyon GitHub](https://github.com/nical/lyon) — The tessellation library
- [libtess2 GitHub](https://github.com/memononen/libtess2) — Improved GLU tessellator
- [OpenGL Tessellation](https://www.khronos.org/opengl/wiki/Tessellation) — GPU tessellation shaders
- [Polygon Triangulation Algorithms](https://www.geometrictools.com/Documentation/TriangulationByEarClipping.pdf)

---

*This document is part of the [Vector Graphics Theme](vector-graphics.md) research.*
