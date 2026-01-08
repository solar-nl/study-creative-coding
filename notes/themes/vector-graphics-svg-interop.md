# Vector Graphics Deep Dive: SVG Interoperability

> How do frameworks import and export vector graphics?

---

## The Problem: Asset Exchange

Vector graphics exist in a shared ecosystem. Designers create in Illustrator or Figma, developers code in Processing or nannou, and the final output might be web SVG, print PDF, or laser cutter G-code. SVG is the lingua franca of this ecosystem.

```
                Design Tools                Creative Coding               Output
                ───────────                 ──────────────                ──────
                Illustrator ──┐
                     Figma ──┼── SVG ──▶ Framework ──▶ Canvas/GPU
                  Inkscape ──┘                       └──▶ SVG ──▶ Web/Print/Cut
```

Supporting SVG well means your framework can:
1. **Import** assets from design tools
2. **Export** generated art for web or fabrication
3. **Interoperate** with the broader tooling ecosystem

---

## Framework SVG Support Overview

| Framework | Import | Export | Path Data Parsing | Notes |
|-----------|--------|--------|-------------------|-------|
| p5.js | None | None | Manual via vertices | Browser handles Canvas |
| Processing | Yes | Yes (via Batik) | Full SVG parser | Most mature |
| OpenFrameworks | Yes (addon) | Cairo | Via ofxSvg | Good integration |
| Cinder | Yes | Via Cairo | SVG-compatible API | Not file parsing |
| openrndr | **Yes** | **Yes** | Full regex parser | Most complete |
| nannou | None | None | Via Lyon builder | No file I/O |

**Key finding:** openrndr has the most comprehensive SVG support. Most frameworks either delegate to external libraries or don't support SVG files at all.

---

## SVG Path Data: The Universal Format

The SVG `<path>` element's `d` attribute is a mini-language for describing shapes:

```svg
<path d="M 10 10 L 90 10 L 90 90 L 10 90 Z"/>
<!--    ▲      ▲       ▲       ▲       ▲
        │      │       │       │       └── Close path
        │      │       │       └── Line to (10,90)
        │      │       └── Line to (90,90)
        │      └── Line to (90,10)
        └── Move to (10,10)
-->
```

### All Path Commands

| Command | Name | Parameters | Example |
|---------|------|------------|---------|
| M/m | MoveTo | x y | `M 10 10` |
| L/l | LineTo | x y | `L 90 10` |
| H/h | Horizontal | x | `H 90` |
| V/v | Vertical | y | `V 10` |
| C/c | Cubic Bezier | x1 y1 x2 y2 x y | `C 20 0, 80 0, 100 50` |
| S/s | Smooth Cubic | x2 y2 x y | `S 80 100, 100 50` |
| Q/q | Quadratic | x1 y1 x y | `Q 50 0, 100 50` |
| T/t | Smooth Quadratic | x y | `T 200 50` |
| A/a | Arc | rx ry rot large sweep x y | `A 25 25 0 1 0 50 50` |
| Z/z | Close | (none) | `Z` |

Uppercase = absolute coordinates, lowercase = relative to current point.

### The "Smooth" Commands (S/T)

The S and T commands are ergonomic shortcuts for continuous curves:

```
Regular cubic bezier:         Smooth continuation:
    C x1 y1 x2 y2 x y            S x2 y2 x y
           ●                          ●
          /                          /
    ctrl1●   ●ctrl2            (implied)  ●ctrl2
        /     \                         \
   start●       ●end                     ●end

The first control point is reflected from the previous curve.
```

Cinder explicitly supports this pattern:

```cpp
// Cinder's smoothCurveTo mirrors SVG's S command
path.moveTo(vec2(0, 0));
path.curveTo(vec2(10, 0), vec2(40, 50), vec2(50, 50));  // C command
path.smoothCurveTo(vec2(60, 100), vec2(100, 100));      // S command (infers first ctrl)
```

---

## How Processing Parses SVG

Processing's `PShapeSVG.java` is the most thorough implementation in the studied frameworks.

### Loading an SVG

```java
PShape logo = loadShape("logo.svg");
shape(logo, 100, 100);

// Access elements
PShape path = logo.getChild("myPath");
```

### The Parsing Pipeline

```
SVG File
    │
    ▼
┌──────────────────────────────────────────────────┐
│ 1. XML Parsing (org.xml.sax)                     │
│    - Parse SVG structure                         │
│    - Build element tree                          │
└──────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────┐
│ 2. Element Processing                             │
│    - <g> → PShape GROUP                          │
│    - <path> → PShape PATH with vertices          │
│    - <rect>, <circle>, etc. → PShape PRIMITIVE   │
└──────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────┐
│ 3. Style Extraction                               │
│    - fill, stroke attributes                     │
│    - CSS class/style parsing                     │
│    - Inherited styles from parents               │
└──────────────────────────────────────────────────┘
    │
    ▼
┌──────────────────────────────────────────────────┐
│ 4. Transform Handling                             │
│    - parseTransform() for matrix operations      │
│    - Nested transforms multiply                  │
└──────────────────────────────────────────────────┘
```

### Supported Elements

Processing supports these SVG elements:

```java
// From PShapeSVG.java
switch (name) {
    case "g":        // Groups (become GROUP shapes)
    case "defs":     // Definitions (gradients, etc.)
    case "path":     // Path with d attribute
    case "rect":     // Rectangle
    case "circle":   // Circle
    case "ellipse":  // Ellipse
    case "line":     // Line segment
    case "polygon":  // Closed polygon
    case "polyline": // Open polyline
    case "image":    // Embedded images
    case "text":     // Text (limited)
}
```

### What's NOT Supported

```java
// These elements trigger warnings:
case "filter":   System.err.println("Filters not supported");
case "mask":     System.err.println("Masks not supported");
case "pattern":  System.err.println("Patterns not supported");
```

Also unsupported:
- `<clipPath>` - Clipping regions
- `<use>` - Symbol references
- Complex text (font-stretch, letter-spacing, text-align)
- CSS animations
- JavaScript/interactivity

---

## How openrndr Parses SVG

openrndr's `orx-svg` module is the most complete implementation.

### Loading and Saving

```kotlin
// Load from file, URL, or string
val composition = loadSVG("artwork.svg")

// Save to file
composition.saveToFile(File("output.svg"))

// Convert to string
val svgString = composition.toSVG()

// Shapes can export their path data
val pathData = myShape.toSvg()  // Returns "M 10 10 L 90 90..."
```

### Comprehensive Element Support

```kotlin
// From SVGConstants.kt - all supported elements
object SVGTags {
    const val circle = "circle"
    const val defs = "defs"
    const val ellipse = "ellipse"
    const val g = "g"
    const val image = "image"
    const val line = "line"
    const val linearGradient = "linearGradient"
    const val path = "path"
    const val polygon = "polygon"
    const val polyline = "polyline"
    const val radialGradient = "radialGradient"
    const val rect = "rect"
    const val text = "text"
    const val tspan = "tspan"
    const val use = "use"  // Reference elements!
}
```

### ViewBox and Aspect Ratio Handling

openrndr properly handles SVG's viewport system:

```kotlin
// SVG with viewBox
// <svg viewBox="0 0 100 100" width="200" height="200" preserveAspectRatio="xMidYMid meet">

val composition = loadSVG(svg)

// Access viewBox
val viewBox = composition.viewBox  // Rectangle(0, 0, 100, 100)

// Transform respects preserveAspectRatio
// Supported modes: xMinYMin, xMidYMin, xMaxYMin, xMinYMid, xMidYMid, etc.
```

### Path Data Parsing (Regex-Based)

```kotlin
// From SVGParse.kt - regex for path commands
val pathCommandRegex = """[MmZzLlHhVvCcSsQqTtAa][^MmZzLlHhVvCcSsQqTtAa]*""".toRegex()

fun parsePathData(d: String): List<PathCommand> {
    return pathCommandRegex.findAll(d).map { match ->
        val command = match.value[0]
        val params = match.value.drop(1).trim()
            .split("""[\s,]+""".toRegex())
            .filter { it.isNotEmpty() }
            .map { it.toDouble() }

        PathCommand(command, params)
    }.toList()
}
```

---

## Options for Rust

### The `svg` Crate (Parsing)

```rust
use svg::node::element::path::Data;
use svg::parser::Event;

let content = std::fs::read_to_string("drawing.svg")?;

for event in svg::read(&content)? {
    match event {
        Event::Tag(svg::node::element::tag::Path, _, attributes) => {
            let data = attributes.get("d").unwrap();
            let path_data = Data::parse(data)?;

            for command in path_data.iter() {
                match command {
                    data::Command::MoveTo(position, parameters) => { ... }
                    data::Command::LineTo(position, parameters) => { ... }
                    data::Command::CubicCurveTo(position, parameters) => { ... }
                    // etc.
                }
            }
        }
        _ => {}
    }
}
```

### The `usvg` Crate (Preprocessing)

`usvg` simplifies SVG into a normalized form:

```rust
use usvg::{Tree, Options};

let svg_data = std::fs::read("complex.svg")?;
let tree = Tree::from_data(&svg_data, &Options::default())?;

// All transforms are baked in
// All styles are computed
// Text is converted to paths (optional)

for node in tree.root.descendants() {
    if let usvg::NodeKind::Path(ref path) = *node.borrow() {
        // path.data contains normalized path commands
        // path.fill and path.stroke have computed styles
    }
}
```

### Lyon's SVG Builder

Lyon provides SVG-compatible path construction:

```rust
use lyon::path::builder::WithSvg;
use lyon::path::Path;

let path = Path::builder()
    .with_svg()  // Enable SVG-style commands
    .move_to(point(0.0, 0.0))
    .line_to(point(100.0, 0.0))
    .cubic_bezier_to(
        point(150.0, 50.0),   // ctrl1
        point(150.0, 100.0),  // ctrl2
        point(100.0, 150.0)   // end
    )
    .smooth_cubic_bezier_to(  // SVG's S command!
        point(50.0, 200.0),   // ctrl2
        point(0.0, 150.0)     // end
    )
    .close()
    .build();
```

### Writing SVG Output

```rust
// Simple path data generation
fn path_to_svg_data(path: &Path) -> String {
    let mut d = String::new();

    for event in path.iter() {
        match event {
            PathEvent::Begin { at } => {
                write!(d, "M {} {} ", at.x, at.y).unwrap();
            }
            PathEvent::Line { to, .. } => {
                write!(d, "L {} {} ", to.x, to.y).unwrap();
            }
            PathEvent::Quadratic { ctrl, to, .. } => {
                write!(d, "Q {} {}, {} {} ", ctrl.x, ctrl.y, to.x, to.y).unwrap();
            }
            PathEvent::Cubic { ctrl1, ctrl2, to, .. } => {
                write!(d, "C {} {}, {} {}, {} {} ",
                    ctrl1.x, ctrl1.y, ctrl2.x, ctrl2.y, to.x, to.y).unwrap();
            }
            PathEvent::End { close, .. } => {
                if close { d.push_str("Z "); }
            }
        }
    }

    d.trim().to_string()
}

// Full SVG document
fn shapes_to_svg(shapes: &[Shape], width: f32, height: f32) -> String {
    let mut svg = format!(
        r#"<svg xmlns="http://www.w3.org/2000/svg" width="{}" height="{}">"#,
        width, height
    );

    for shape in shapes {
        let d = path_to_svg_data(&shape.path);
        svg.push_str(&format!(
            r#"<path d="{}" fill="{}" stroke="{}" stroke-width="{}"/>"#,
            d,
            color_to_css(shape.fill),
            color_to_css(shape.stroke),
            shape.stroke_width
        ));
    }

    svg.push_str("</svg>");
    svg
}
```

---

## The Arc Problem

SVG arcs are notoriously complex:

```svg
<!-- SVG arc: 7 parameters -->
<path d="A rx ry x-axis-rotation large-arc-flag sweep-flag x y"/>
```

Where:
- `rx, ry` - ellipse radii
- `x-axis-rotation` - ellipse tilt
- `large-arc-flag` - use the larger arc (0 or 1)
- `sweep-flag` - clockwise vs counter-clockwise (0 or 1)
- `x, y` - endpoint

### The Challenge

Most graphics APIs don't have arc primitives—they have Bezier curves. Converting requires:

1. **Endpoint to center parameterization** (math-heavy)
2. **Splitting arcs > 90°** into multiple segments
3. **Approximating with cubic Beziers**

### Implementation Example

```rust
// Simplified arc-to-beziers (real implementation is ~100 lines)
fn arc_to_beziers(
    start: Point, rx: f32, ry: f32, rotation: f32,
    large_arc: bool, sweep: bool, end: Point
) -> Vec<CubicBezier> {
    // 1. Convert endpoint params to center params
    let (center, start_angle, sweep_angle) =
        endpoint_to_center(start, rx, ry, rotation, large_arc, sweep, end);

    // 2. Split into segments ≤ 90°
    let num_segments = (sweep_angle.abs() / (PI / 2.0)).ceil() as usize;
    let segment_angle = sweep_angle / num_segments as f32;

    // 3. Approximate each segment with a cubic bezier
    (0..num_segments).map(|i| {
        let angle1 = start_angle + segment_angle * i as f32;
        let angle2 = angle1 + segment_angle;
        arc_segment_to_bezier(center, rx, ry, rotation, angle1, angle2)
    }).collect()
}
```

Lyon handles this internally, but if building from scratch, arc conversion is the hardest part of SVG path parsing.

---

## What SVG Subset to Support?

For a creative coding framework, a practical subset:

### Essential (Level 1)

| Element | Why |
|---------|-----|
| `<path>` | Core vector primitive |
| `<rect>`, `<circle>`, `<ellipse>` | Basic shapes |
| `<line>`, `<polyline>`, `<polygon>` | Line-based shapes |
| `<g>` | Grouping and hierarchy |
| `transform` attribute | Position/rotate/scale |
| `fill`, `stroke` | Basic styling |

### Useful (Level 2)

| Element | Why |
|---------|-----|
| `<linearGradient>`, `<radialGradient>` | Fill effects |
| `viewBox`, `preserveAspectRatio` | Proper scaling |
| `<defs>`, `<use>` | Symbol reuse |
| CSS class/style | External styling |

### Probably Skip

| Element | Why Skip |
|---------|----------|
| `<filter>` | Complex, GPU-specific |
| `<mask>`, `<clipPath>` | Requires stencil buffer |
| `<text>` | Font rendering is separate concern |
| `<animate>` | Framework has own animation |
| `<script>` | Not applicable |

---

## Export Considerations

### Precision

Floating-point numbers need formatting:

```rust
// Too precise (wasteful)
format!("{}", 10.123456789)  // "10.123456789"

// Just right
format!("{:.3}", 10.123456789)  // "10.123"

// SVG spec allows scientific notation
format!("{:.3e}", 0.000123)  // "1.230e-4"
```

### Compactness

SVG path data can be compressed:

```svg
<!-- Verbose -->
<path d="M 0 0 L 100 0 L 100 100 L 0 100 Z"/>

<!-- Compact (omit spaces, use relative) -->
<path d="M0 0l100 0 0 100-100 0z"/>
```

### Units and ViewBox

Always include a viewBox for scalability:

```svg
<!-- Fixed size -->
<svg width="800" height="600">

<!-- Scalable -->
<svg viewBox="0 0 800 600" width="100%" height="100%">
```

---

## Framework Comparison: SVG Workflow

### Processing (Mature)

```java
// Import
PShape svg = loadShape("drawing.svg");

// Manipulate
PShape path = svg.getChild("myPath");
path.setFill(color(255, 0, 0));
path.scale(2.0);

// Draw
shape(svg, 0, 0);

// Export (requires import processing.svg.*)
beginRecord(SVG, "output.svg");
// ... draw commands ...
endRecord();
```

### openrndr (Most Complete)

```kotlin
// Import with full feature support
val composition = loadSVG("drawing.svg")

// Access and manipulate
composition.findShapes().forEach { shape ->
    drawer.shape(shape.effectiveShape)
}

// Export back to SVG
composition.saveToFile(File("modified.svg"))

// Or generate SVG from scratch
val svg = buildSVG {
    path {
        d = myShape.toSvg()
        fill = ColorRGBa.RED.toSVG()
    }
}
```

### nannou (Build From Scratch)

```rust
// No SVG file I/O, but SVG-compatible building
let path = geom::path::Builder::new()
    .begin(pt2(0.0, 0.0))
    .line_to(pt2(100.0, 0.0))
    .cubic_bezier_to(pt2(150.0, 50.0), pt2(150.0, 100.0), pt2(100.0, 150.0))
    .close()
    .build();

// Would need custom code for export
```

---

## Recommendations for Rust Framework

1. **Use `usvg` for Import**
   - Handles the complexity of full SVG
   - Normalizes transforms and styles
   - Battle-tested (used by resvg)

2. **Build Simple Export**
   - Most sketches need basic output only
   - `<path>` with `d` attribute covers most cases
   - Add gradients and groups as needed

3. **Expose Path Data Format**
   ```rust
   // Allow direct path data string
   let shape = Shape::from_svg_path("M 0 0 L 100 100")?;
   let d = shape.to_svg_path();  // "M 0 0 L 100 100"
   ```

4. **Consider `lyon::path::builder::WithSvg`**
   - Already SVG-compatible
   - Handles smooth curves (S/T commands)
   - Zero additional dependencies

5. **Minimal ViewBox Support**
   ```rust
   struct SvgExport {
       view_box: Rect,
       shapes: Vec<Shape>,
   }

   impl SvgExport {
       fn to_string(&self) -> String {
           // Generate proper SVG with viewBox
       }
   }
   ```

---

## Sources

- [SVG Path Specification](https://www.w3.org/TR/SVG/paths.html) — W3C reference
- [Processing loadShape() Reference](https://processing.org/reference/loadShape_.html)
- [openrndr orx-svg Documentation](https://guide.openrndr.org/drawing/svg.html)
- [usvg Crate](https://crates.io/crates/usvg) — SVG simplification
- [svg Crate](https://crates.io/crates/svg) — SVG parsing/building
- [Lyon PathBuilder with SVG](https://docs.rs/lyon_path/latest/lyon_path/builder/struct.WithSvg.html)
- [Arc Implementation Notes](https://www.w3.org/TR/SVG/implnote.html#ArcImplementationNotes) — The math

---

*This document is part of the [Vector Graphics Theme](vector-graphics.md) research.*
