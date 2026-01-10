# Vector Graphics Deep Dive: Boolean Operations

> How do you combine two shapes into one?

---

## The Problem: Combining Shapes

You have two circles that overlap. You want to:
- **Union**: Combine them into one blob
- **Difference**: Cut one from the other (like a crescent moon)
- **Intersection**: Keep only where they overlap (a lens shape)

```
Circle A    Circle B       Union         Difference      Intersection
   ●           ●           ●●●            ◐                ◯
  / \         / \         /   \          /
 |   | + |   |   =   |     |   =   |   |   =       |
  \ /         \ /         \   /          \
   ●           ●           ●●●            ◑                ◯
```

This is surprisingly hard to implement correctly. Among the 6 creative coding frameworks studied, **only openrndr has built-in boolean operations**.

---

## Why This Is Hard

Boolean operations on curves involve:

1. **Finding all intersection points** between the two shapes
2. **Tracing the correct boundaries** (following A, then switching to B, etc.)
3. **Handling edge cases**: tangent intersections, coincident edges, self-intersecting paths
4. **Maintaining numerical stability** with floating-point math

The classic paper "A New Algorithm for Computing Boolean Operations on Polygons" by Francisco Martínez et al. describes a sweep-line approach that handles most cases, but robust implementation is tricky.

---

## How openrndr Does It

openrndr integrates the **kartifex** library for computational geometry:

```kotlin
// ShapeArtifex.kt - Converting between openrndr and kartifex

internal fun Segment2D.toCurve2(): Curve2 {
    return when (control.size) {
        0 -> Line2.line(start.toVec2(), end.toVec2())
        1 -> Bezier2.curve(start.toVec2(), control[0].toVec2(), end.toVec2())
        2 -> Bezier2.curve(start.toVec2(), control[0].toVec2(),
                          control[1].toVec2(), end.toVec2())
        else -> throw IllegalArgumentException()
    }
}

// Shapes become kartifex Region2 objects
internal val region2 by resettableLazy {
    Region2(contours.map { it.ring2 })
}
```

### Union

```kotlin
fun union(from: Shape, add: Shape): Shape {
    return if (from.topology == ShapeTopology.CLOSED) {
        val result = from.region2.union(add.region2)
        result.toShape()
    } else {
        from  // Can't union open paths
    }
}

// Usage
val combined = union(circle1.shape, circle2.shape)
```

### Difference

```kotlin
fun difference(from: Shape, subtract: Shape): Shape {
    if (from.empty) return Shape.EMPTY
    if (subtract.empty) return from

    return when (from.topology) {
        ShapeTopology.CLOSED -> {
            val result = from.region2.difference(subtract.region2)
            result.toShape()
        }
        // Open paths: Sample midpoints, keep segments outside subtractor
        ShapeTopology.OPEN -> {
            val ints = intersections(from, subtract)
            // ... partition and filter
        }
    }
}
```

### Intersection

```kotlin
fun intersection(from: Shape, with: Shape): Shape {
    return when (from.topology) {
        ShapeTopology.CLOSED -> {
            val result = from.region2.intersection(with.region2)
            result.toShape()
        }
        // ...
    }
}
```

### Handling Open Paths

openrndr's approach for open paths (strokes) is clever: find intersection points, split the path at those points, then test whether each segment's midpoint lies inside/outside the other shape.

```kotlin
// For open contours with closed regions
val ints = intersections(from, subtract)
val partitions = weldedInts.zipWithNext().mapNotNull { (t1, t2) ->
    val partition = from.sub(t1, t2)
    // Point-in-region test
    if (partition.position(0.5) !in subtract) {
        partition
    } else {
        null
    }
}
```

---

## Options for Rust

### The `geo` Crate

The most mature option. Provides `BooleanOps` trait:

```rust
use geo::{BooleanOps, Polygon, MultiPolygon};
use geo::coord;

let poly_a: Polygon<f64> = Polygon::new(
    vec![coord! {x: 0., y: 0.}, coord! {x: 100., y: 0.},
         coord! {x: 100., y: 100.}, coord! {x: 0., y: 100.}].into(),
    vec![]
);

let poly_b: Polygon<f64> = Polygon::new(
    vec![coord! {x: 50., y: 50.}, coord! {x: 150., y: 50.},
         coord! {x: 150., y: 150.}, coord! {x: 50., y: 150.}].into(),
    vec![]
);

let union: MultiPolygon<f64> = poly_a.union(&poly_b);
let intersection: MultiPolygon<f64> = poly_a.intersection(&poly_b);
let difference: MultiPolygon<f64> = poly_a.difference(&poly_b);
let xor: MultiPolygon<f64> = poly_a.xor(&poly_b);
```

**Limitations:** Works on polygons (line segments only), not bezier curves. You'd need to flatten curves first.

### The `i_overlay` Crate

Focused specifically on boolean operations with better performance:

```rust
use i_overlay::core::fill_rule::FillRule;
use i_overlay::f64::overlay::F64Overlay;

let mut overlay = F64Overlay::new();
overlay.add_paths(subject_paths, ShapeType::Subject);
overlay.add_paths(clip_paths, ShapeType::Clip);

let result = overlay.overlay(OverlayRule::Union, FillRule::NonZero);
```

### Manual Implementation Path

If you need bezier-curve boolean operations:

1. **Flatten curves** to polylines (with appropriate tolerance)
2. **Use geo or i_overlay** for the boolean operation
3. **(Optional) Re-fit beziers** to the result using curve fitting

This is what many professional applications do. The bezier re-fitting step is complex but not essential for creative coding.

---

## When to Use Boolean Operations

**Good use cases:**
- Text knockouts (text shape subtracted from background)
- Procedural shape generation (metaballs via union)
- Complex masks and clipping
- CSG (Constructive Solid Geometry) for 2D

**Alternatives to consider:**
- **Stencil buffer**: For rendering knockouts without modifying geometry
- **Shader-based SDF**: For soft, animated boolean effects
- **Separate draw calls with blend modes**: Sometimes simpler

---

## Performance Considerations

Boolean operations are computationally expensive—O(n log n) for well-behaved inputs, worse for pathological cases.

**Tips:**
1. **Cache results** when shapes don't change
2. **Simplify inputs** first (fewer vertices = faster)
3. **Use bounding box tests** to skip obviously non-intersecting shapes
4. **Consider LOD**: Use coarser geometry for background/small shapes

---

## Framework Comparison

| Framework | Boolean Ops | Library | Notes |
|-----------|-------------|---------|-------|
| p5.js | No | — | Would need external JS library |
| Processing | No | — | PShape doesn't support |
| OpenFrameworks | No | — | ofPath doesn't support |
| Cinder | No | — | Would need manual implementation |
| openrndr | **Yes** | kartifex | Full support for closed shapes |
| nannou | No | — | Could use geo crate |

---

## Recommendations for Rust Framework

1. **Don't build from scratch**—boolean operations are notoriously bug-prone.

2. **Start with `geo`** for polygon operations. It's well-maintained and handles edge cases.

3. **Flatten beziers before boolean ops** if needed:
   ```rust
   let flattened = path.flattened(0.1);  // Tolerance in pixels
   let polygon = Polygon::from(flattened);
   let result = polygon.union(&other);
   ```

4. **Consider whether you need them**—many creative coding effects can be achieved with stencils, blend modes, or shaders instead.

5. **If you need curve-preserving booleans**, look at kartifex (via openrndr) or the experimental Rust port of paper.js's boolean ops.

---

## Sources

- [openrndr Shape Operations](https://guide.openrndr.org/drawing/shapeOperations.html) — Official documentation
- [geo Crate](https://crates.io/crates/geo) — Rust geospatial library
- [i_overlay Crate](https://crates.io/crates/i_overlay) — Fast boolean operations
- [Martínez et al. Boolean Operations Paper](https://www.cs.ucr.edu/~vbz/cs230papers/martinez_boolean.pdf) — The algorithm

---

*This document is part of the [Vector Graphics Theme](vector-graphics.md) research.*
