# nannou Architecture

> Understanding nannou's internal structure and module organization.

## Key Insight

> **Architecture's core idea:** nannou separates concerns into focused crates (core, [wgpu](https://github.com/gfx-rs/wgpu), mesh, audio) that compose together, with App as the central orchestrator managing windows, events, and the model-update-view lifecycle.

## Crate Dependency Graph

```
nannou (main crate)
    │
    ├── nannou_core ─────── No-std core (color, geom, math)
    │   └── glam ────────── Linear algebra
    │
    ├── nannou_wgpu ─────── WebGPU backend
    │   └── wgpu ────────── Graphics API
    │
    ├── nannou_mesh ─────── Mesh utilities
    │
    └── winit ───────────── Window management
```

## Core Abstractions

### App ([`app.rs`](https://github.com/nannou-org/nannou/blob/master/src/app.rs))
Central application context:
- `Builder<M>` — fluent app configuration
- `SketchBuilder<E>` — simplified for sketches
- Holds state, manages windows, dispatches events

### Window ([`window.rs`](https://github.com/nannou-org/nannou/blob/master/src/window.rs))
Window representation:
- `Window` struct — active window handle
- `Builder` — window configuration
- Surface management, input state

### Draw (`draw/mod.rs`)
High-level drawing interface:
- `Draw` struct — drawing context
- Transform stack (push/pop)
- Primitive methods (ellipse, rect, line, etc.)

### Frame (`frame/mod.rs`)
Per-frame rendering context:
- `Frame` — high-level frame
- `RawFrame` — low-level [wgpu](https://github.com/gfx-rs/wgpu) access

## Initialization Flow

```rust
nannou::app(model)    // Create builder with model function
    .update(update)   // Set update callback
    .run();           // Start event loop

// Internally:
// 1. Initialize winit event loop
// 2. Call model() to create initial state
// 3. Create windows as configured
// 4. Enter event loop:
//    a. Handle winit events
//    b. Call update() with state
//    c. Call view() for each window
//    d. Present frames
```

## Module Organization

### nannou_core
- `color/` — Color types, conversions (sRGB, linear, HSL, etc.)
- `geom/` — 14 geometry types (Rect, Ellipse, Line, Path, etc.)
- [`math.rs`](https://github.com/nannou-org/nannou/blob/master/nannou/math.rs) — map, clamp, wrap utilities
- [`rand.rs`](https://github.com/nannou-org/nannou/blob/master/nannou/rand.rs) — Random number generation

### nannou_wgpu
- [`render_pipeline_builder.rs`](https://github.com/nannou-org/nannou/blob/master/nannou/render_pipeline_builder.rs) — Pipeline construction
- [`bind_group_builder.rs`](https://github.com/nannou-org/nannou/blob/master/nannou/bind_group_builder.rs) — Resource binding
- `texture/` — Texture management
- [`device_map.rs`](https://github.com/nannou-org/nannou/blob/master/nannou/device_map.rs) — GPU device handling

## Key Files to Read

| Concept | File | Size |
|---------|------|------|
| Public API | `nannou/src/lib.rs` | 2 KB |
| App lifecycle | `nannou/src/app.rs` | 71 KB |
| Drawing | `nannou/src/draw/mod.rs` | 23 KB |
| Primitives | `nannou/src/draw/primitive/` | Various |
| Window | `nannou/src/window.rs` | 62 KB |
| Events | `nannou/src/event.rs` | 14 KB |
