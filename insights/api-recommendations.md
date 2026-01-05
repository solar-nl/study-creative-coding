# API Recommendations

Extracted best practices for your Rust framework's API design.

## Naming Conventions

### From p5.js/Processing
- Short, memorable function names
- Verb-first for actions: `draw_`, `load_`, `create_`
- Abbreviated common methods: `x_y()`, `w_h()`, `rgb()`

### From nannou/Rust
- Follow Rust conventions: `snake_case`
- Clear, descriptive names
- Prelude module for common imports

## Method Patterns

### Builder Pattern (from nannou, openrndr)
```rust
app.new_window()
    .size(800, 600)
    .title("My Sketch")
    .build()?;
```

**Recommendation**: Use builders for configuration with multiple optional parameters.

### Method Chaining (from three.js, nannou)
```rust
draw.ellipse()
    .x_y(100.0, 100.0)
    .radius(50.0)
    .color(RED);
```

**Recommendation**: Return `Self` or `&mut Self` for fluent APIs.

### Mode-Based State (from p5.js/Processing)
```rust
draw.color_mode(ColorMode::Hsb);
draw.rect_mode(RectMode::Center);
```

**Recommendation**: Use enums for modes, consider if global state is appropriate.

## Parameter Flexibility

### From p5.js
```javascript
// Multiple ways to specify color
color(gray)
color(r, g, b)
color(r, g, b, a)
color("#ff0000")
```

**Recommendation**: Use trait implementations and `Into<T>` for flexible inputs.

```rust
pub fn color(c: impl Into<Color>) -> Self { ... }

// Allows:
draw.ellipse().color(RED);           // Constant
draw.ellipse().color((255, 0, 0));   // Tuple
draw.ellipse().color("#ff0000");     // String (via From impl)
```

## Error Handling

### From Rust Best Practices
- Use `Result<T, E>` for fallible operations
- Provide good error messages
- Consider `anyhow` for application code
- Consider `thiserror` for library errors

## Discoverability

### From All Frameworks
- Comprehensive documentation
- Examples for every feature
- Prelude module with common types
- IDE autocomplete support (good type annotations)

---

*Add more recommendations as you study each framework.*
