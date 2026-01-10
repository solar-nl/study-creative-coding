# Vector Graphics Deep Dive: Stroke Styles

> How do you turn a 1D path into visible geometry?

## Key Insight

> **The core challenge:** A "line" with thickness is actually a filled shape requiring tessellation—and the offset curve of a Bezier is not itself a Bezier, forcing approximation at every step.

---

## The Problem: Lines Have No Thickness

A mathematical path is infinitely thin—it has position but no width. To draw it on screen, we need to expand it into 2D geometry. This expansion involves choices:

```
Path (1D):           Stroked (2D):
                       ┌───────┐
    ●────────●   →     │       │
                       └───────┘

What happens at the ends?   What happens at corners?
      ┌──┐                       /\
      │  │  ← Square             /\  ← Miter
      ●                          ●
      │  │                      /  \
      └──┘                     /    \
```

---

## Cap Styles: How Lines End

When a path is open, the ends need caps:

```
         BUTT             ROUND            SQUARE
        (flat)           (semi-circle)    (extended flat)

         ──┬──             ──╭──             ──┬──
           │                 │                 │
           │                 │                 │
         ──┴──             ──╰──             ──┴──
         ▲                 ▲                 ▲
         │                 │                 └── Extends by half stroke-width
         │                 └── Rounded cap
         └── Ends exactly at endpoint
```

### Framework Support

| Framework | BUTT | ROUND | SQUARE | Notes |
|-----------|------|-------|--------|-------|
| p5.js | ✓ | ✓ | PROJECT | PROJECT = SQUARE |
| Processing | ✓ | ✓ | PROJECT | PROJECT = SQUARE |
| OpenFrameworks | Limited | Limited | Limited | Needs Cairo |
| Cinder | CAP_BUTT | CAP_ROUND | CAP_SQUARE | Full support |
| openrndr | BUTT | ROUND | SQUARE | Full support |
| nannou | Butt | Round | Square | Via Lyon |

### Code Examples

**p5.js:**
```javascript
strokeCap(ROUND);
strokeWeight(20);
line(30, 30, 170, 30);
```

**Processing:**
```java
strokeCap(ROUND);
strokeWeight(20);
line(30, 30, 170, 30);
```

**openrndr:**
```kotlin
drawer.lineCap = LineCap.ROUND
drawer.strokeWeight = 20.0
drawer.lineSegment(30.0, 30.0, 170.0, 30.0)
```

**nannou:**
```rust
draw.line()
    .start(pt2(30.0, 30.0))
    .end(pt2(170.0, 30.0))
    .stroke_weight(20.0)
    .caps_round();
```

---

## Join Styles: How Lines Connect

When a path turns a corner, the outer edge needs to be handled:

```
        MITER              ROUND              BEVEL
       (pointed)          (curved)          (cut off)

          ╱                  ╱                  ╱
         ╱                  ╱                  ╱
        ◢                  ◢                  ◢
       ╱ ◣                ╱◜◝               ╱──╲
      ╱   ◣              ╱   ╲             ╱    ╲
     ╱     ◣            ╱     ╲           ╱      ╲

   Extends to a     Rounded corner      Straight cut
   sharp point                          at corner
```

### The Miter Limit Problem

Sharp angles create long miters that look bad:

```
Acute angle without limit:         With miter limit:

        ╱                              ╱
       ╱                              ╱
      ◢────────────────             ◢──╲
     ╱                              ╱   ╲
                                   ╱     ╲
  (extends way out!)              (falls back to bevel)
```

The **miter limit** defines when to switch from miter to bevel:

```
Miter limit = miter_length / stroke_width

For angle θ:
  miter_length = stroke_width / sin(θ/2)

Common defaults:
  - SVG: 4.0
  - Most frameworks: 4.0
  - Lyon: 4.0
```

### Framework Support

| Framework | MITER | ROUND | BEVEL | MITER_CLIP | Miter Limit |
|-----------|-------|-------|-------|------------|-------------|
| p5.js | ✓ | ✓ | ✓ | — | No control |
| Processing | ✓ | ✓ | ✓ | — | No control |
| OpenFrameworks | Limited | Limited | Limited | — | Needs Cairo |
| Cinder | ✓ | ✓ | ✓ | — | In calcStroke() |
| openrndr | ✓ | ✓ | ✓ | ✓ | miterLimit |
| nannou | ✓ | ✓ | ✓ | ✓ | miter_limit() |

**MITER_CLIP** (openrndr, nannou): A variant that clips the miter at a specified length instead of falling back to bevel. Preserves the miter shape for moderate angles.

---

## Dash Patterns

Dashed lines are surprisingly hard:

```
Solid:     ────────────────────────
Dashed:    ── ── ── ── ── ── ── ──
Dotted:    ·  ·  ·  ·  ·  ·  ·  ·
Custom:    ───  ─  ───  ─  ───  ─
```

### The Challenge

Dash patterns interact with:
- **Caps**: Each dash segment needs caps
- **Corners**: Does the pattern continue smoothly around corners?
- **Closed paths**: Does the pattern seamlessly wrap?
- **Arc length**: Pattern must follow curve length, not parameter

### Framework Support

**No framework in the study has built-in dash support.**

| Framework | Dash Support | Workaround |
|-----------|--------------|------------|
| p5.js | None | `drawingContext.setLineDash([5, 10])` |
| Processing | None | Manual vertex sampling |
| OpenFrameworks | None (OpenGL) | Cairo backend supports dashes |
| Cinder | None | Manual or Cairo |
| openrndr | None | Contour sampling |
| nannou | None | Manual path splitting |

### p5.js Workaround

```javascript
// Access browser's Canvas 2D API directly
drawingContext.setLineDash([10, 5]);  // 10px dash, 5px gap
line(20, 20, 180, 20);
drawingContext.setLineDash([]);  // Reset to solid
```

### Manual Implementation

```rust
fn dash_path(path: &Path, pattern: &[f32]) -> Vec<PathSegment> {
    let mut segments = Vec::new();
    let mut pattern_index = 0;
    let mut pattern_offset = 0.0;
    let mut drawing = true;  // Alternates dash/gap

    let total_length = path.arc_length();
    let mut current_length = 0.0;

    for event in path.iter() {
        match event {
            PathEvent::Line { from, to, .. } => {
                let segment_length = from.distance(to);

                while pattern_offset < segment_length {
                    let dash_length = pattern[pattern_index];
                    let remaining = dash_length - (current_length % dash_length);
                    let end_t = (pattern_offset + remaining) / segment_length;

                    if drawing {
                        let start = from.lerp(to, pattern_offset / segment_length);
                        let end = from.lerp(to, end_t.min(1.0));
                        segments.push(PathSegment::Line(start, end));
                    }

                    pattern_offset += remaining;
                    pattern_index = (pattern_index + 1) % pattern.len();
                    drawing = !drawing;
                }
            }
            // ... handle curves (need arc length parameterization)
        }
    }

    segments
}
```

---

## Variable Width Strokes

The holy grail of digital drawing: strokes that vary in width along the path.

```
Uniform width:       Variable width (calligraphy):

    ══════════             ═══╲
                              ╲═══╲
                                  ╲═══
```

### Framework Support

**No framework in the study has built-in variable width support.**

This is because:
1. Tessellation is complex (no simple offset algorithm)
2. Interpolation between widths is ambiguous
3. GPU acceleration is harder (need vertex attributes)

### Approaches

**1. Per-Vertex Width:**
```rust
struct StrokeVertex {
    position: Vec2,
    width: f32,  // Width at this point
}

// Tessellate by computing perpendicular offset at each vertex
fn tessellate_variable_stroke(vertices: &[StrokeVertex]) -> Mesh {
    let mut triangles = Vec::new();

    for window in vertices.windows(2) {
        let v0 = &window[0];
        let v1 = &window[1];

        let direction = (v1.position - v0.position).normalize();
        let perpendicular = Vec2::new(-direction.y, direction.x);

        let p0_left = v0.position + perpendicular * v0.width * 0.5;
        let p0_right = v0.position - perpendicular * v0.width * 0.5;
        let p1_left = v1.position + perpendicular * v1.width * 0.5;
        let p1_right = v1.position - perpendicular * v1.width * 0.5;

        // Two triangles for this segment
        triangles.push([p0_left, p1_left, p0_right]);
        triangles.push([p0_right, p1_left, p1_right]);
    }

    Mesh::from_triangles(triangles)
}
```

**2. Pressure-Sensitive Input:**
```rust
// Tablet input provides pressure per sample
struct TabletSample {
    position: Vec2,
    pressure: f32,  // 0.0 to 1.0
}

fn samples_to_variable_stroke(
    samples: &[TabletSample],
    min_width: f32,
    max_width: f32,
) -> Vec<StrokeVertex> {
    samples.iter().map(|s| StrokeVertex {
        position: s.position,
        width: min_width + s.pressure * (max_width - min_width),
    }).collect()
}
```

**3. Distance-Based Tapers:**
```rust
// Taper at start and end
fn taper_widths(vertices: &mut [StrokeVertex], taper_length: f32) {
    let path_length = compute_path_length(vertices);

    let mut distance = 0.0;
    for i in 1..vertices.len() {
        distance += vertices[i].position.distance(vertices[i-1].position);

        // Taper at start
        if distance < taper_length {
            vertices[i].width *= distance / taper_length;
        }

        // Taper at end
        let from_end = path_length - distance;
        if from_end < taper_length {
            vertices[i].width *= from_end / taper_length;
        }
    }
}
```

---

## How Strokes Become Geometry

### The Stroke Expansion Algorithm

Converting a stroked path to filled geometry:

```
Input path:              Expanded stroke:
                         ┌─────────────────┐
    ●────────●    →      │   original      │
                         │   path line     │
                         └─────────────────┘
                         ▲                 ▲
                         │                 │
                         offset by         offset by
                         -width/2          +width/2
```

### Cinder's calcStroke()

Cinder provides the cleanest API for stroke expansion:

```cpp
Path2d path;
path.moveTo(vec2(10, 50));
path.lineTo(vec2(90, 50));
path.lineTo(vec2(90, 90));

// Convert stroke to filled shape
Shape2d strokedShape = path.calcStroke(
    5.0f,            // stroke width
    Path2d::CAP_ROUND,   // cap style
    Path2d::JOIN_MITER,  // join style
    4.0f,            // miter limit
    0.25f            // tolerance (for curve flattening)
);

// strokedShape is now tessellated geometry
gl::draw(strokedShape);
```

### Lyon's StrokeTessellator

Lyon is the most complete stroke implementation in Rust:

```rust
use lyon::tessellation::{StrokeTessellator, StrokeOptions};
use lyon::tessellation::{LineCap, LineJoin};

let mut tessellator = StrokeTessellator::new();

let options = StrokeOptions::default()
    .with_line_width(5.0)
    .with_line_cap(LineCap::Round)
    .with_line_join(LineJoin::Miter)
    .with_miter_limit(4.0)
    .with_tolerance(0.1);

tessellator.tessellate_path(
    &path,
    &options,
    &mut BuffersBuilder::new(&mut vertex_buffer, |vertex: StrokeVertex| {
        // vertex.position(), vertex.normal(), vertex.advancement()
        MyVertex {
            position: vertex.position().to_array(),
        }
    }),
)?;
```

### The Offset Curve Problem

For bezier curves, the offset (parallel) curve is not itself a bezier. This is a fundamental mathematical limitation:

```
Original cubic bezier:    Offset curve (not a bezier!):

        ●                        ●
       / \                      ╱ ╲
      /   \                    ╱   ╲
     ●     ●                  ●     ●
    /       \                ╱       ╲
   ●         ●              ●         ●

  (3rd degree)            (higher degree or
                           approximation needed)
```

Solutions:
1. **Flatten then offset** (most common)
2. **Approximate with bezier chain**
3. **Subdivide until error is acceptable**

---

## Performance Considerations

### When to Tessellate

```
┌──────────────────────────────────────────────────────┐
│ Tessellate ONCE when:                                 │
│   - Path is static                                   │
│   - Stroke style doesn't change                      │
│   - Transform-only animations                        │
└──────────────────────────────────────────────────────┘
                    vs
┌──────────────────────────────────────────────────────┐
│ Tessellate PER-FRAME when:                           │
│   - Path changes                                     │
│   - Stroke width animates                            │
│   - Interactive drawing                              │
└──────────────────────────────────────────────────────┘
```

### Caching Strategy

```rust
struct StrokedPath {
    path: Path,
    options: StrokeOptions,
    mesh: Option<Mesh>,
    dirty: bool,
}

impl StrokedPath {
    fn get_mesh(&mut self, tessellator: &mut StrokeTessellator) -> &Mesh {
        if self.dirty || self.mesh.is_none() {
            self.mesh = Some(tessellate(&self.path, &self.options, tessellator));
            self.dirty = false;
        }
        self.mesh.as_ref().unwrap()
    }

    fn set_path(&mut self, path: Path) {
        self.path = path;
        self.dirty = true;
    }

    fn set_stroke_width(&mut self, width: f32) {
        if (self.options.line_width - width).abs() > 0.001 {
            self.options.line_width = width;
            self.dirty = true;
        }
    }
}
```

### GPU vs CPU Strokes

For **dynamic strokes** (like drawing), consider GPU-based approaches:

```glsl
// Vertex shader: expand stroke in shader
uniform float u_stroke_width;
in vec2 a_position;
in vec2 a_normal;  // Perpendicular direction

void main() {
    vec2 offset = a_normal * u_stroke_width * 0.5;
    vec2 world_pos = a_position + offset;
    gl_Position = u_projection * vec4(world_pos, 0.0, 1.0);
}
```

This allows stroke width to animate without re-tessellation.

---

## Framework Comparison: Stroke API

### p5.js (Simplest)

```javascript
stroke(255, 0, 0);     // Color
strokeWeight(10);       // Width
strokeCap(ROUND);       // Caps
strokeJoin(MITER);      // Joins
noFill();

beginShape();
vertex(30, 20);
vertex(85, 75);
vertex(30, 75);
endShape();
```

### openrndr (Most Flexible)

```kotlin
drawer.stroke = ColorRGBa.RED
drawer.strokeWeight = 10.0
drawer.lineCap = LineCap.ROUND
drawer.lineJoin = LineJoin.MITER
drawer.miterLimit = 4.0
drawer.fill = null

drawer.contour {
    moveTo(30.0, 20.0)
    lineTo(85.0, 75.0)
    lineTo(30.0, 75.0)
}
```

### nannou (Most Control)

```rust
draw.polyline()
    .stroke_weight(10.0)
    .caps_round()
    .join_miter()
    .miter_limit(4.0)
    .color(RED)
    .points(vec![
        pt2(30.0, 20.0),
        pt2(85.0, 75.0),
        pt2(30.0, 75.0),
    ]);
```

### Cinder (Explicit Tessellation)

```cpp
Path2d path;
path.moveTo(vec2(30, 20));
path.lineTo(vec2(85, 75));
path.lineTo(vec2(30, 75));

// Explicit conversion to geometry
Shape2d shape = path.calcStroke(10.0f, Cap::ROUND, Join::MITER, 4.0f, 0.1f);
gl::draw(shape);
```

---

## Recommendations for Rust Framework

1. **Use Lyon for Stroke Tessellation**
   - Battle-tested, correct implementation
   - All standard cap/join styles
   - Good performance

2. **Provide Both Modes**
   ```rust
   // Immediate (tessellates each frame)
   draw.line()
       .stroke_weight(5.0)
       .caps_round();

   // Cached (explicit tessellation)
   let mesh = stroke_to_mesh(&path, &StrokeOptions {
       width: 5.0,
       cap: LineCap::Round,
       join: LineJoin::Miter,
   });
   draw.mesh(&mesh);
   ```

3. **Consider GPU Strokes for Dynamic Use**
   ```rust
   // Pre-computed path with normals
   let stroke_geometry = StrokeGeometry::new(&path);

   // In draw loop (width can animate without re-tessellation)
   stroke_geometry.draw(&draw, stroke_width);
   ```

4. **Add Dash Patterns as a Path Operation**
   ```rust
   let dashed = path.dashed(&[10.0, 5.0]);  // Returns multiple paths
   for segment in dashed {
       draw.path(&segment).stroke_weight(2.0);
   }
   ```

5. **Variable Width as Optional Feature**
   ```rust
   // Opt-in for complexity
   draw.variable_stroke(&path)
       .widths(|t| 2.0 + 8.0 * (t * PI).sin())  // Width varies with t
       .color(RED);
   ```

---

## Sources

- [Lyon StrokeOptions](https://docs.rs/lyon_tessellation/latest/lyon_tessellation/struct.StrokeOptions.html)
- [SVG stroke-linecap](https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/stroke-linecap)
- [SVG stroke-linejoin](https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/stroke-linejoin)
- [p5.js strokeCap()](https://p5js.org/reference/p5/strokeCap/)
- [p5.js strokeJoin()](https://p5js.org/reference/p5/strokeJoin/)
- [openrndr Drawing Style](https://guide.openrndr.org/drawing/managingDrawStyle.html)
- [Cinder Path2d::calcStroke](https://libcinder.org/docs/branch/master/classcinder_1_1_path2d.html)
- [Offset Curves of Cubic Beziers](https://pomax.github.io/bezierinfo/#offsetting)

---

*This document is part of the [Vector Graphics Theme](vector-graphics.md) research.*
