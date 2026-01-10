# nannou

> A Rust framework for creative coding.

## Key Insight

> **nannou's core idea:** A modular workspace of focused crates that brings creative coding to Rust through idiomatic builder patterns, callback-based lifecycles, and [wgpu](https://github.com/gfx-rs/wgpu)-powered graphics.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | Rust |
| **License** | MIT |
| **Repository** | [nannou-org/nannou](https://github.com/nannou-org/nannou) |
| **Documentation** | [docs.rs/nannou](https://docs.rs/nannou) |

## Philosophy & Target Audience

nannou brings creative coding to Rust with idiomatic patterns:

- **Type safety**: Leverage Rust's type system for correctness
- **Performance**: Native speed, no GC pauses
- **Modular**: Workspace of focused crates (core, [wgpu](https://github.com/gfx-rs/wgpu), audio, etc.)
- **Builder pattern**: Fluent API for configuration

Target audience: Rust developers interested in creative coding, artists wanting performance.

## Repository Structure

```
nannou/
├── nannou/                 # Main framework crate
│   └── src/
│       ├── lib.rs          # Root module, exports API
│       ├── prelude.rs      # Convenience re-exports
│       ├── app.rs          # Application lifecycle (71 KB)
│       ├── window.rs       # Window management (62 KB)
│       ├── draw/           # High-level drawing API
│       │   ├── mod.rs      # Draw context
│       │   ├── primitive/  # 14 primitive types
│       │   ├── properties/ # Color, fill, stroke, spatial
│       │   └── renderer/   # GPU rendering
│       ├── event.rs        # Event definitions
│       ├── frame/          # Frame rendering
│       └── text/           # Text rendering
├── nannou_core/            # Core abstractions (no-std compatible)
│   └── src/
│       ├── color/          # Color handling
│       ├── geom/           # Geometry primitives
│       └── math.rs         # Mathematical functions
├── nannou_wgpu/            # WebGPU graphics backend
├── nannou_mesh/            # Mesh data structures
├── nannou_audio/           # Audio processing
├── nannou_egui/            # Immediate-mode UI
└── examples/               # Example applications
```

## Key Entry Points

Start reading here to understand the framework:

1. **`nannou/src/lib.rs`** — Public API exports
2. **`nannou/src/app.rs`** — Application builder and lifecycle
3. **`nannou/src/draw/mod.rs`** — Drawing API
4. **`nannou/src/window.rs`** — Window management

## Notable Patterns

- **Builder pattern**: `nannou::app(model).run()`
- **Callback-based lifecycle**: model, update, view functions
- **Workspace crates**: Separation of concerns
- **Re-exports**: `nannou::prelude::*` for convenience

## Study Questions

- [ ] How does the App builder configure the application?
- [ ] How does the Draw API map to [wgpu](https://github.com/gfx-rs/wgpu)?
- [ ] How does the event system dispatch to user code?
- [ ] How is the crate workspace organized for reuse?
- [ ] What Rust idioms are used for the drawing DSL?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md)
- [API Design](./api-design.md)

## Related Libraries

- [wgpu](https://github.com/gfx-rs/wgpu) — WebGPU implementation that powers nannou's graphics backend
