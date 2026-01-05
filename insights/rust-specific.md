# Rust-Specific Patterns

How patterns from other frameworks map to Rust idioms.

## Ownership and Borrowing

### Challenge: Drawing State
In p5.js/Processing, drawing state is global. In Rust, we need to manage ownership.

**Pattern from nannou**:
```rust
fn view(app: &App, model: &Model, frame: Frame) {
    let draw = app.draw();  // Borrows drawing context
    draw.ellipse().x_y(100.0, 100.0);
    draw.to_frame(app, &frame).unwrap();
}
```

**Key insight**:
- `App` owns the drawing context
- User code borrows it
- Drawing commands are queued, not executed immediately

## Lifetimes

### Challenge: Callbacks
Other frameworks use callbacks freely. Rust requires lifetime management.

**Pattern from nannou**:
```rust
nannou::app(model)
    .update(update)  // Function pointer, no lifetime issues
    .view(view)
    .run();
```

**Alternative with closures**:
```rust
// If closures need to capture state:
// Consider Box<dyn Fn()> or generics with trait bounds
```

## Trait-Based Generics

### From Processing's PGraphics
Processing uses inheritance (PGraphics2D, PGraphicsOpenGL).

**Rust alternative**:
```rust
trait Renderer {
    fn draw_ellipse(&mut self, x: f32, y: f32, w: f32, h: f32);
    // ...
}

struct Renderer2D { /* Canvas 2D */ }
struct RendererGL { /* OpenGL */ }

impl Renderer for Renderer2D { ... }
impl Renderer for RendererGL { ... }
```

## Enums for Variants

### From p5.js Modes
```javascript
rectMode(CENTER);
colorMode(HSB);
```

**Rust with enums**:
```rust
#[derive(Clone, Copy)]
pub enum RectMode {
    Corner,
    Center,
    Corners,
}

draw.rect_mode(RectMode::Center);
```

**Benefits**: Type-safe, exhaustive matching, good IDE support.

## Builder Pattern

### Heavily used in nannou/openrndr
Rust's lack of default arguments makes builders valuable:

```rust
pub struct WindowBuilder {
    size: Option<(u32, u32)>,
    title: Option<String>,
    // ...
}

impl WindowBuilder {
    pub fn size(mut self, w: u32, h: u32) -> Self {
        self.size = Some((w, h));
        self
    }

    pub fn build(self) -> Result<Window, Error> {
        // ...
    }
}
```

## Into Traits for Flexibility

### Replacing overloaded functions
```rust
impl<C: Into<Color>> Drawing {
    pub fn color(mut self, c: C) -> Self {
        self.color = c.into();
        self
    }
}

// Now accepts:
draw.ellipse().color(RED);              // Named constant
draw.ellipse().color(Rgb::new(1.0, 0.0, 0.0));  // Explicit type
draw.ellipse().color((255, 0, 0));      // Tuple (if From impl exists)
```

## Error Handling

### Replace try/catch with Result
```rust
pub fn load_image(path: &Path) -> Result<Image, ImageError> {
    // ...
}

// User code:
let img = load_image("photo.jpg")?;  // Propagate error
// or
let img = load_image("photo.jpg").unwrap_or_else(|_| default_image());
```

---

*Add more patterns as you study frameworks.*
