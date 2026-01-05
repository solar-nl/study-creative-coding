# nannou API Design

## Public API Surface

nannou exposes a Rust-idiomatic API using builders, traits, and method chaining.

## Naming Conventions

### Types
- **PascalCase**: `App`, `Draw`, `Frame`, `Window`
- **Descriptive**: `Drawing<Ellipse>`, `Builder<M>`

### Functions
- **snake_case**: `app()`, `sketch()`, `x_y()`, `w_h()`
- **Abbreviated**: `x_y()`, `w_h()`, `rgb()` (common in creative coding)

### Modules
- **snake_case**: `nannou::prelude`, `nannou::draw`

## Method Signatures

### Builder Pattern
```rust
nannou::app(model)
    .update(update)
    .view(view)
    .run();

app.new_window()
    .size(800, 600)
    .view(view)
    .build()
    .unwrap();
```

### Method Chaining (Drawing)
```rust
draw.ellipse()
    .x_y(100.0, 100.0)
    .radius(50.0)
    .color(RED)
    .stroke(WHITE)
    .stroke_weight(2.0);
```

### Prelude Pattern
```rust
use nannou::prelude::*;  // Imports common types
```

## Error Handling

- **Result types**: `build().unwrap()` pattern
- **Option types**: For optional values
- **Panics**: On unrecoverable errors (shader compilation)

## Type System Usage

### Generic Builders
```rust
struct Builder<M> {
    model: ModelFn<M>,
    // ...
}
```

### Associated Types
```rust
trait Primitive {
    type State;
    fn render(&self, state: &Self::State);
}
```

## API Patterns Worth Studying

### Callback Registration
```rust
fn model(app: &App) -> Model { ... }
fn update(app: &App, model: &mut Model, update: Update) { ... }
fn view(app: &App, model: &Model, frame: Frame) { ... }

nannou::app(model).update(update).view(view).run();
```

### Spatial Methods
```rust
draw.ellipse()
    .x(100.0)           // Set x
    .y(50.0)            // Set y
    .x_y(100.0, 50.0)   // Set both
    .xy(pt2(100.0, 50.0)) // Set from point
```

### Color Flexibility
```rust
.color(RED)              // Named constant
.color(rgb(1.0, 0.0, 0.0))  // RGB
.color(hsla(0.0, 1.0, 0.5, 1.0))  // HSL
.rgba(1.0, 0.0, 0.0, 0.5)  // Direct RGBA
```

## Recommendations for Your Framework

1. **Builder pattern** — Works excellently in Rust
2. **Method chaining** — Return `Self` for fluent APIs
3. **Prelude module** — Convenience imports
4. **Abbreviated methods** — `x_y()` vs `set_position(x, y)`
5. **Generic callbacks** — Allow flexibility in model types
6. **Crate separation** — Core, graphics, audio as separate crates
