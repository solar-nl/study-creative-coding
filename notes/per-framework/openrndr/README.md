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
├── openrndr-gl3/            # OpenGL backend
├── openrndr-math/           # Math utilities
├── openrndr-color/          # Color handling
└── openrndr-shape/          # Shape/path utilities
```

## Key Entry Points

1. **`openrndr-application/`** — Application structure
2. **`openrndr-draw/`** — Drawer class and drawing API
3. **`openrndr-gl3/`** — OpenGL 3 rendering

## Study Questions

- [ ] How does Kotlin's DSL capabilities shape the API?
- [ ] How does the Drawer abstraction work?
- [ ] How does the orx extension system work?
- [ ] How is the shader system designed?
- [ ] How does the color handling compare to others?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md)
- [API Design](./api-design.md)
