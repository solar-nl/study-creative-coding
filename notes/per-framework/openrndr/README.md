# openrndr

> A Kotlin framework for creative coding.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | Kotlin |
| **License** | BSD-2-Clause |
| **Repository** | [openrndr/openrndr](https://github.com/openrndr/openrndr) |
| **Documentation** | [guide.openrndr.org](https://guide.openrndr.org/) |

## Philosophy & Target Audience

openrndr leverages Kotlin's DSL capabilities:
- Kotlin-idiomatic API
- Excellent DSL design
- Strong shader support
- Extensions via orx

Target audience: Kotlin developers, creative coders wanting modern JVM.

## Repository Structure

```
openrndr/
├── openrndr-application/    # Application lifecycle
├── openrndr-draw/           # Drawing API
├── openrndr-jvm/openrndr-gl3/  # OpenGL 3.3 backend (DriverGL3.kt)
├── openrndr-math/           # Math utilities
├── openrndr-color/          # Color handling
└── openrndr-shape/          # Shape/path utilities
```

## Key Entry Points

1. **`openrndr-application/`** — Application structure
2. **`openrndr-draw/`** — Drawer class and drawing API
3. **`openrndr-jvm/openrndr-gl3/`** — OpenGL 3.3 rendering (`DriverGL3.kt`); `openrndr-js/openrndr-webgl/` is the WebGL driver

## Study Questions

- [ ] How does Kotlin's DSL capabilities shape the API?
- [ ] How does the Drawer abstraction work?
- [ ] How does the orx extension system work?
- [ ] How is the shader system designed?
- [ ] How does the color handling compare to others?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md) — NanoVG-style expansion, stencil fills, AA fringe
- [Code trace: contour to pixels](./code-traces/contour-to-pixels.md) — `drawer.contour()` through `Expansion`, `ExpansionDrawer` and `DriverGL3`, with `file:line`
- [API Design](./api-design.md)

## See Also

- [orx](../../per-library/openrndr-ecosystem/orx/) — Extensions library for openrndr (color, noise, shapes, etc.)
- [Processing](../processing/) — Original creative coding framework that inspired many designs
- [Cinder](../cinder/) — C++ framework with similar professional focus
- [wgpu](https://github.com/gfx-rs/wgpu) — Modern GPU abstraction used by Rust creative coding tools
