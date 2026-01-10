# Theme: Vector Graphics

> How do you turn a mathematical curve into pixels on screen?

## Key Insight

> **The core challenge:** GPUs only understand triangles, so every curve, circle, and complex polygon must be tessellated into triangles before rendering—a computationally expensive step that most frameworks hide from you.

---

## The Problem: Shapes Aren't Pixels

When you write `ellipse(100, 100, 50, 50)`, something remarkable happens. Your mathematical description—a center point and dimensions—becomes thousands of colored pixels arranged in an oval. But GPUs don't understand ellipses. They only understand triangles.

This is the fundamental challenge of vector graphics: **translating mathematical descriptions of shapes into triangles that GPUs can render**. The process involves:

- **Path representation**: How do you describe curves mathematically? Bezier control points? Parametric equations?
- **Tessellation**: How do you convert curved paths into straight-edged triangles?
- **Fill rules**: When paths cross themselves, which regions are "inside"?
- **Stroke expansion**: A "line" with thickness is actually a filled ribbon—how do you generate that geometry?

Different frameworks make radically different choices here, with profound implications for performance, features, and API design.

---

## The Mental Model: The Vector Graphics Pipeline

Every vector graphics system follows roughly this pipeline:

```
┌─────────────────────────────────────────────────────────────┐
│  Stage 1: Path Definition                                    │
│  "Describe the shape mathematically"                        │
│  Types: lines, quadratic Beziers, cubic Beziers, arcs       │
│  Storage: command lists, point arrays, segment objects      │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage 2: Tessellation                                       │
│  "Convert curves to triangles"                              │
│  Methods: adaptive subdivision, monotone decomposition      │
│  Libraries: GLU, libtess2, Lyon, kartifex                   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage 3: GPU Rendering                                      │
│  "Draw the triangles"                                       │
│  Data: vertex buffers, index buffers                        │
│  Backends: Canvas 2D, OpenGL, WebGL, wgpu                   │
└─────────────────────────────────────────────────────────────┘
```

### Immediate vs. Retained Mode

A crucial distinction runs through all graphics APIs:

**Immediate mode**: Draw commands execute immediately. Shape data is discarded after rendering.
```javascript
// p5.js immediate mode
ellipse(100, 100, 50, 50);  // Drawn now, data gone
```

**Retained mode**: Shapes are stored as objects. They persist and can be redrawn efficiently.
```java
// Processing retained mode
PShape circle = createShape(ELLIPSE, 100, 100, 50, 50);
shape(circle);  // Draw
shape(circle);  // Draw again without rebuilding
```

Most creative coding frameworks offer both modes. Immediate mode is simpler for sketching; retained mode is faster for complex, animated scenes.

---

## Framework Deep Dives

### p5.js: The Browser-Delegated Approach

**The approach:** p5.js abstracts over two rendering backends—Canvas 2D and WebGL—with a unified API.

**What makes this interesting:** p5.js delegates the hard work to the browser. When you call `ellipse()`, you're ultimately calling `CanvasRenderingContext2D.arc()` or generating WebGL geometry. This means p5.js gets browser-optimized rendering for free.

The shape building API uses the familiar `beginShape()`/`endShape()` pattern:

```javascript
beginShape();
vertex(30, 20);
vertex(85, 20);
vertex(85, 75);
vertex(30, 75);
endShape(CLOSE);
```

**Bezier and curve support:**

```javascript
// Cubic Bezier
bezier(85, 20,  // start
       10, 10,  // control 1
       90, 90,  // control 2
       15, 80); // end

// In vertex mode
beginShape();
vertex(30, 20);
bezierVertex(80, 0, 80, 75, 30, 75);  // cubic via control points
endShape();

// Catmull-Rom splines (smooth curves through points)
beginShape();
curveVertex(84, 91);  // control point
curveVertex(68, 19);  // curve goes through these
curveVertex(21, 17);
curveVertex(32, 91);  // control point
endShape();
```

**The dual-mode complexity:** The same code behaves differently in 2D vs WebGL mode. Canvas 2D natively supports curves; WebGL approximates them with line segments based on `bezierDetail()` and `curveDetail()`.

**Shape assembly modes** control how vertices are interpreted:

```javascript
beginShape(TRIANGLES);      // Every 3 vertices = 1 triangle
beginShape(TRIANGLE_STRIP); // Each new vertex forms triangle with previous 2
beginShape(TRIANGLE_FAN);   // All triangles share first vertex
beginShape(QUADS);          // Every 4 vertices = 1 quad
```

**Key insight:** p5.js issue [#8277](https://github.com/processing/p5.js/issues/8277) reveals that not all primitive drawing goes through the internal `p5.Shape` class—there's inconsistency between `rect()` and custom shapes. This is typical of the organic growth of creative coding frameworks.

**Key files:**
- `src/core/shape/2d_primitives.js` — rect, ellipse, arc, etc.
- `src/core/shape/curves.js` — bezier, curve, interpolation
- `src/core/shape/vertex.js` — beginShape/endShape state machine

---

### Processing: The Retained-Mode Pioneer

**The approach:** Processing introduced the `PShape` class for retained-mode graphics, storing shapes as objects that can be transformed and redrawn efficiently.

**The key insight:** Processing classifies shapes into families:

```java
static final int PRIMITIVE = 101;  // rect, ellipse, arc—parametric
static final int PATH = 102;       // bezierVertex, curveVertex—sequential commands
static final int GEOMETRY = 103;   // beginShape/endShape—custom vertices
static final int GROUP = 0;        // Container for child shapes
```

This classification enables different rendering strategies. A `PRIMITIVE` ellipse can be rendered with a specialized algorithm; a `PATH` needs sequential curve processing.

```java
// Creating retained shapes
PShape rect = createShape(RECT, 50, 50, 100, 100);
PShape customShape = createShape();
customShape.beginShape();
customShape.vertex(50, 50);
customShape.bezierVertex(100, 20, 150, 100, 200, 50);
customShape.endShape();

// GROUP shapes enable hierarchies
PShape car = createShape(GROUP);
car.addChild(createShape(RECT, 0, 0, 100, 50));  // body
car.addChild(createShape(ELLIPSE, 20, 50, 15, 15));  // wheel
car.addChild(createShape(ELLIPSE, 80, 50, 15, 15));  // wheel

// Transform the whole group
pushMatrix();
translate(100, 100);
shape(car);
popMatrix();
```

**Style retention:** Each `PShape` stores its fill, stroke, and style information:

```java
PShape s = createShape();
s.beginShape();
s.fill(255, 0, 0);     // Red fill stored with shape
s.stroke(0);           // Black stroke stored
s.strokeWeight(2);
s.vertex(50, 50);
// ...
s.endShape(CLOSE);

// Later, styles are applied automatically
shape(s);  // Draws with retained red fill, black stroke
```

**Holes via contours:**

```java
PShape withHole = createShape();
withHole.beginShape();
// Outer boundary
withHole.vertex(100, 100);
withHole.vertex(300, 100);
withHole.vertex(300, 300);
withHole.vertex(100, 300);

// Start hole (opposite winding)
withHole.beginContour();
withHole.vertex(150, 150);
withHole.vertex(150, 250);
withHole.vertex(250, 250);
withHole.vertex(250, 150);
withHole.endContour();

withHole.endShape(CLOSE);
```

**Key files:**
- `core/src/processing/core/PShape.java` — The retained shape class
- `core/src/processing/core/PGraphics.java` — Immediate-mode drawing

---

### OpenFrameworks: The Dual Path/Polyline Model

**The approach:** OpenFrameworks provides two complementary types: `ofPath` for high-level declarative drawing, and `ofPolyline` for low-level geometric manipulation.

**Why two types?** They serve different purposes:

| Aspect | ofPath | ofPolyline |
|--------|--------|-----------|
| Purpose | Declarative drawing | Geometric operations |
| Storage | Command list | Raw vertices |
| Beziers | Native support | Must convert to points |
| Subpaths | Multiple (via close) | Single |
| Math ops | Limited | Extensive (closest point, simplify) |

```cpp
// ofPath: High-level, declarative
ofPath path;
path.moveTo(100, 100);
path.lineTo(200, 150);
path.bezierTo(250, 100, 300, 200, 350, 100);  // cubic
path.quadBezierTo(400, 50, 450, 100);         // quadratic
path.close();
path.draw();

// ofPolyline: Low-level, procedural
ofPolyline line;
line.addVertex(100, 100);
line.addVertex(200, 150);
line.addVertex(300, 100);
line.curveTo(350, 200);  // Catmull-Rom
line.close();
line.draw();

// ofPolyline math operations
glm::vec3 closest = line.getClosestPoint(mousePos);
float length = line.getPerimeter();
ofPolyline simplified = line.getResampledBySpacing(10);
```

**Tessellation via ofTessellator:**

OpenFrameworks uses libtess2 (a rewrite of the GLU tessellator) to convert paths to triangles:

```cpp
ofPath complexShape;
// ... build shape ...
complexShape.setFilled(true);
complexShape.tessellate();  // Converts to mesh internally
complexShape.draw();        // Draws cached triangles
```

**Winding rules:**

```cpp
ofPath path;
path.setPolyWindingMode(OF_POLY_WINDING_ODD);      // Even-odd rule
path.setPolyWindingMode(OF_POLY_WINDING_NONZERO);  // Non-zero rule
path.setPolyWindingMode(OF_POLY_WINDING_POSITIVE); // Fill positive areas
```

**Stroke styling** is more limited than you might expect—OpenFrameworks targets OpenGL, which doesn't natively support stroke caps, joins, or dashes. These require additional geometry generation or a different renderer (like Cairo).

**Key files:**
- `libs/openFrameworks/graphics/ofPath.h` — Declarative path commands
- `libs/openFrameworks/graphics/ofPolyline.h` — Low-level geometry
- `libs/openFrameworks/graphics/ofTessellator.h` — libtess2 wrapper

---

### Cinder: The SVG-Compatible Pragmatist

**The approach:** Cinder provides `Path2d` (single contour) and `Shape2d` (multiple contours) with an API designed for SVG compatibility.

**The unique feature:** Smooth curve variants that automatically infer control points:

```cpp
Path2d path;
path.moveTo(vec2(0, 0));
path.curveTo(vec2(50, 100), vec2(100, 100), vec2(150, 0));  // Explicit cubic

// Now the magic: smoothCurveTo infers the first control point
// by reflecting the previous control point across the current point
path.smoothCurveTo(vec2(200, -100), vec2(250, 0));
// First control point = 2 * (150,0) - (100,100) = (200, -100)
```

This matches SVG's `S` and `T` commands, enabling smooth curve chains without manual control point calculation.

**Arc variants:**

```cpp
// Center-based arc
path.arc(vec2(100, 100), 50, 0, M_PI);  // center, radius, start, end

// Tangent-based arc (for rounded corners)
path.arcTo(vec2(100, 0), vec2(100, 100), 20);  // through point, end, radius

// SVG elliptical arc (full SVG compatibility)
path.arcTo(50, 30,           // rx, ry
           M_PI / 4,         // x-axis rotation
           true, true,       // large-arc, sweep flags
           vec2(200, 100));  // end point
```

**Multi-contour shapes:**

```cpp
Shape2d shape;

// Each moveTo starts a new contour
shape.moveTo(vec2(0, 0));
shape.lineTo(vec2(100, 0));
shape.lineTo(vec2(100, 100));
shape.close();

shape.moveTo(vec2(25, 25));  // New contour (hole)
shape.lineTo(vec2(75, 25));
shape.lineTo(vec2(75, 75));
shape.close();

// Fill rules determine how overlaps render
bool inside = shape.contains(vec2(50, 50), true);  // evenOddFill = true
```

**Advanced operations:**

```cpp
// Stroke to shape conversion
Shape2d stroked = path.calcStroke(strokeStyle, tolerance);

// Path offsetting (for outlines, insets)
Path2d offset = path.calcOffset(10.0f, Join::ROUND, 4.0f);

// Intersection detection
auto intersections = path1.findIntersections(path2);
```

**Key files:**
- `include/cinder/Path2d.h` — SVG-compatible path class
- `include/cinder/Shape2d.h` — Multi-contour shapes

---

### openrndr: The Boolean Operations Champion

**The approach:** openrndr has the cleanest data model—`Shape` contains `ShapeContour`s, which contain `Segment2D`s—and uniquely offers built-in boolean operations.

**The data model:**

```kotlin
// Segment2D: The atomic unit
data class Segment2D(
    val start: Vector2,
    val control: List<Vector2>,  // Empty = line, 1 = quadratic, 2 = cubic
    val end: Vector2
)

// ShapeContour: Connected segments (open or closed)
data class ShapeContour(
    val segments: List<Segment2D>,
    val closed: Boolean
)

// Shape: Multiple contours (boundaries + holes)
class Shape(val contours: List<ShapeContour>)
```

**Builder DSL:**

```kotlin
val myShape = shape {
    boundary {  // Clockwise
        moveTo(0.0, 0.0)
        lineTo(100.0, 0.0)
        lineTo(100.0, 100.0)
        lineTo(0.0, 100.0)
        close()
    }
    hole {  // Counter-clockwise
        moveTo(25.0, 25.0)
        lineTo(75.0, 25.0)
        lineTo(75.0, 75.0)
        lineTo(25.0, 75.0)
        close()
    }
}
```

**Boolean operations** (unique to openrndr among these frameworks):

```kotlin
val circle1 = Circle(vec2(-50.0, 0.0), 100.0).contour
val circle2 = Circle(vec2(50.0, 0.0), 100.0).contour

// Union: combine shapes
val combined = union(circle1, circle2.shape)

// Difference: subtract one from another
val crescent = difference(circle1, circle2.shape)

// Intersection: keep only overlapping region
val lens = intersection(circle1, circle2.shape)
```

Under the hood, openrndr uses the **kartifex** library (a computational geometry library) to perform these operations. Shapes are converted to kartifex's `Ring2` and `Region2` types, operations performed, then converted back.

**Why this matters:** Boolean operations enable effects that are awkward or impossible otherwise—text knocked out of shapes, complex compound paths, procedural shape generation.

**Key files:**
- `openrndr-shape/src/.../Shape.kt` — Shape container
- `openrndr-shape/src/.../ShapeContour.kt` — Contour with segments
- `openrndr-shape/src/.../ShapeArtifex.kt` — Boolean operations via kartifex

---

### nannou: The Pure Rust Path

**The approach:** nannou is built entirely in Rust, using Lyon for tessellation and wgpu for rendering—no C++ dependencies.

**The tessellation pipeline:**

```
User code:  draw.polygon().points(vertices)
                ↓
Builder:    PolygonInit → Polygon (stores point data)
                ↓
Render:     Lyon tessellation → MeshBuilder → GPU buffers
                ↓
GPU:        wgpu draw call
```

**Builder pattern API:**

```rust
// Points with uniform color
draw.polygon()
    .x(-100.0)
    .color(WHITE)
    .stroke(PINK)
    .stroke_weight(20.0)
    .join_round()
    .points(vertices);

// Points with per-vertex colors
let colored_points = (0..7).map(|i| {
    let angle = (i as f32 / 7.0) * TAU;
    let x = 100.0 * angle.cos();
    let y = 100.0 * angle.sin();
    let color = rgb(i as f32 / 7.0, 1.0 - i as f32 / 7.0, 0.5);
    (pt2(x, y), color)
});

draw.polygon().points_colored(colored_points);
```

**Lyon integration:**

Lyon handles the hard part—converting paths to triangles. nannou implements Lyon's `GeometryBuilder` trait to receive tessellated vertices directly:

```rust
// Simplified from nannou source
impl FillGeometryBuilder for MeshBuilder {
    fn add_fill_vertex(&mut self, vertex: FillVertex) -> Result<VertexId, _> {
        let position = vertex.position();
        let point = self.transform.transform_point3(
            Point2::new(position.x, position.y).extend(0.0)
        );
        self.mesh.push_vertex(vertex::new(point, self.color, tex_coords));
        Ok(VertexId::from_usize(self.mesh.points().len() - 1))
    }

    fn add_triangle(&mut self, a: VertexId, b: VertexId, c: VertexId) {
        self.mesh.push_index(a.to_usize() as u32);
        self.mesh.push_index(b.to_usize() as u32);
        self.mesh.push_index(c.to_usize() as u32);
    }
}
```

**Why this design is elegant:**

1. **Zero-copy tessellation:** Vertices flow directly to GPU buffers
2. **Transform at tessellation time:** No GPU transform overhead
3. **Reusable tessellators:** `FillTessellator` and `StrokeTessellator` persist across frames

**Key files:**
- `nannou/src/draw/primitive/path.rs` — Path tessellation
- `nannou/src/draw/mesh/builder.rs` — Lyon → GPU bridge
- `nannou_core/src/geom/` — Basic geometry types

---

## The Trade-offs, Visualized

```
                    Boolean Ops?    Smooth Beziers?    Pure Language?
                    (CSG)           (auto-control)     (no C deps)
                         │                 │                  │
    p5.js          ○○○○○○○○         ○○○○○○○○          ●●●●●●●●
    Processing     ○○○○○○○○         ○○○○○○○○          ●●●●●●●●
    OpenFrameworks ○○○○○○○○         ●●●●○○○○          ○○○○○○○○
    Cinder         ○○○○○○○○         ●●●●●●●●          ○○○○○○○○
    openrndr       ●●●●●●●●         ○○○○○○○○          ●●●●●●●●
    nannou         ○○○○○○○○         ○○○○○○○○          ●●●●●●●●
```

| Framework | Path Model | Tessellation | Boolean Ops | Unique Strength |
|-----------|------------|--------------|-------------|-----------------|
| p5.js | Implicit (Canvas state) | Browser handles | No | Simplest API |
| Processing | PShape (retained) | Java2D/OpenGL | No | GROUP hierarchies |
| OpenFrameworks | ofPath + ofPolyline | libtess2 | No | Rich path math |
| Cinder | Shape2d/Path2d | GLU tessellator | No | SVG-compatible API |
| openrndr | Shape/ShapeContour | kartifex | **Yes** | Boolean operations |
| nannou | geom + lyon | Lyon | No | Pure Rust, wgpu |

---

## Best Practices Extracted

### 1. Separate Path Definition from Rendering

openrndr's token-based approach (compute positions, then decide how to draw) and nannou's builder pattern both demonstrate this principle. It enables:

- Pre-render measurement ("how wide will this shape be?")
- Alternative rendering (fill vs stroke vs texture)
- Per-vertex transformations for animation

### 2. Use Retained Mode for Complex Scenes

Processing's `PShape` and OpenFrameworks' `ofPath` show how retained shapes avoid redundant computation:

```java
// Bad: Rebuilds tessellation every frame
void draw() {
    beginShape();
    for (int i = 0; i < 1000; i++) {
        vertex(points[i].x, points[i].y);
    }
    endShape();
}

// Good: Tessellate once, draw many times
PShape shape;
void setup() {
    shape = createShape();
    shape.beginShape();
    for (int i = 0; i < 1000; i++) {
        shape.vertex(points[i].x, points[i].y);
    }
    shape.endShape();
}
void draw() {
    shape(shape);
}
```

### 3. Handle Winding Rules Explicitly

Self-intersecting paths need explicit winding rules. Even-odd is simpler to understand; non-zero is more predictable for nested shapes:

```
Even-Odd Rule:        Non-Zero Rule:
    ___                   ___
   /   \                 /   \
  / ___ \               /     \
  ||   ||               |     |
  ||___||               |     |
   \___/                 \___/

(hole in middle)     (filled solid)
```

### 4. Consider Stroke Expansion Early

"Thick lines" are actually filled shapes. Generating stroke geometry is non-trivial—you need to handle caps, joins, and miters. Lyon's `StrokeTessellator` and Cinder's `calcStroke()` show how to do this properly.

---

## Anti-Patterns to Avoid

### 1. Tessellating Every Frame

Tessellation is expensive. If your shape doesn't change, cache the triangles:

```rust
// Bad: Re-tessellates every frame
fn draw(&self) {
    let path = Path::builder().add_circle(100.0).build();
    tessellator.tessellate(&path, &mut mesh);
}

// Good: Tessellate once
fn setup(&mut self) {
    let path = Path::builder().add_circle(100.0).build();
    tessellator.tessellate(&path, &mut self.cached_mesh);
}
fn draw(&self) {
    render(&self.cached_mesh);
}
```

### 2. Mixing Coordinate Systems

Some frameworks (p5.js, Processing) have modes that change coordinate interpretation:

```javascript
rectMode(CENTER);   // Now (x, y) is center, not corner
ellipseMode(CORNER); // Now (x, y) is corner, not center
// Confusing when mixed!
```

Pick one and stick with it, or always reset to defaults.

### 3. Ignoring Degenerate Cases

Empty paths, zero-length segments, and collinear points can crash tessellators or produce garbage geometry. Validate input:

```kotlin
if (points.size < 3) return  // Need at least 3 points for a polygon
if (path.empty) return
```

---

## Recommendations for a Rust Framework

Based on this analysis, here's a suggested architecture:

### Suggested Data Model (inspired by openrndr)

```rust
/// A bezier segment: line, quadratic, or cubic
pub struct Segment {
    pub start: Vec2,
    pub controls: SmallVec<[Vec2; 2]>,  // 0, 1, or 2 control points
    pub end: Vec2,
}

/// A connected sequence of segments
pub struct Contour {
    pub segments: Vec<Segment>,
    pub closed: bool,
}

/// One or more contours forming a shape
pub struct Shape {
    pub contours: Vec<Contour>,
}
```

### Suggested Tessellation Strategy (use Lyon)

Lyon is battle-tested and handles edge cases well:

```rust
let mut tessellator = FillTessellator::new();
let mut mesh = Mesh::new();

tessellator.tessellate_path(
    &path,
    &FillOptions::default(),
    &mut BuffersBuilder::new(&mut mesh, |vertex: FillVertex| {
        Vertex {
            position: vertex.position().to_array(),
            color: fill_color,
        }
    }),
)?;
```

### Consider Boolean Operations (evaluate geo or i_overlay)

If you want boolean operations like openrndr:

```rust
// Using the geo crate
use geo::{BooleanOps, Polygon};

let union = polygon_a.union(&polygon_b);
let difference = polygon_a.difference(&polygon_b);
let intersection = polygon_a.intersection(&polygon_b);
```

### API Sketch

```rust
// Immediate mode (simple cases)
draw.ellipse(100.0, 100.0, 50.0, 50.0)
    .fill(RED)
    .stroke(BLACK)
    .stroke_weight(2.0);

// Path building (complex shapes)
let path = Path::builder()
    .move_to(vec2(0.0, 0.0))
    .line_to(vec2(100.0, 0.0))
    .quadratic_to(vec2(150.0, 50.0), vec2(100.0, 100.0))
    .close()
    .build();

draw.path(&path)
    .fill(gradient)
    .stroke(WHITE);

// Retained mode (performance)
let shape = Shape::from_path(&path);
draw.shape(&shape);  // Reuse cached tessellation

// Boolean operations (advanced)
let combined = shape_a.union(&shape_b);
let cutout = shape_a.difference(&shape_b);
```

---

## Deep Dives: Further Research

These topics warranted their own detailed analysis:

- **[Tessellation](vector-graphics-tessellation.md)** — How lyon, libtess2, and GLU tessellators work. CPU vs GPU tessellation trade-offs. Adaptive subdivision strategies.

- **[Boolean Operations](vector-graphics-boolean-ops.md)** — How openrndr implements union/intersection/difference via kartifex. Why this is computationally hard. Options for Rust (geo crate, i_overlay).

- **[SVG Interop](vector-graphics-svg-interop.md)** — How frameworks handle SVG import/export. Path data format. The subset of SVG that matters for creative coding.

- **[Stroke Styles](vector-graphics-stroke-styles.md)** — How strokes become filled geometry. Caps, joins, dashes, variable width. Why OpenGL makes this hard.

---

## Where to Go Next

- **If implementing vector graphics in Rust:** Start with [Lyon](https://github.com/nical/lyon) for tessellation. Consider [kurbo](https://github.com/linebender/kurbo) for path math.

- **If you need boolean operations:** Look at openrndr's kartifex integration, or explore Rust's [geo](https://crates.io/crates/geo) or [i_overlay](https://crates.io/crates/i_overlay) crates.

- **If debugging tessellation issues:** Check winding rules first. Then check for degenerate geometry (zero-length segments, collinear points).

---

## Source Files Reference

| Framework | Key Vector Graphics Files |
|-----------|---------------------------|
| p5.js | `src/core/shape/2d_primitives.js`, `src/core/shape/curves.js`, `src/core/shape/vertex.js` |
| Processing | `core/src/processing/core/PShape.java`, `core/src/processing/core/PGraphics.java` |
| OpenFrameworks | `libs/openFrameworks/graphics/ofPath.h`, `libs/openFrameworks/graphics/ofPolyline.h`, `libs/openFrameworks/graphics/ofTessellator.h` |
| Cinder | `include/cinder/Path2d.h`, `include/cinder/Shape2d.h` |
| openrndr | `openrndr-shape/.../Shape.kt`, `openrndr-shape/.../ShapeContour.kt`, `openrndr-shape/.../ShapeArtifex.kt` |
| nannou | `nannou/src/draw/primitive/path.rs`, `nannou/src/draw/mesh/builder.rs`, `nannou_core/src/geom/` |

---

## GitHub Issues Worth Reading

| Issue | Framework | What You'll Learn |
|-------|-----------|-------------------|
| [#8277](https://github.com/processing/p5.js/issues/8277) | p5.js | Internal p5.Shape inconsistency |
| [#5670](https://github.com/processing/p5.js/issues/5670) | p5.js | Dashed lines feature discussion |
| [#901](https://github.com/openframeworks/openFrameworks/issues/901) | OpenFrameworks | ofPolyline to ofPath conversion confusion |
| [#5236](https://github.com/openframeworks/openFrameworks/issues/5236) | OpenFrameworks | Arc command adding radial lines |
| [#300](https://github.com/openrndr/openrndr/issues/300) | openrndr | Stroke vs contour rendering differences |
| [#281](https://github.com/openrndr/openrndr/issues/281) | openrndr | Antialiasing for contour strokes |
