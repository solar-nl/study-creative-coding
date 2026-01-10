# Processing

> A flexible software sketchbook and language for learning how to code within the context of the visual arts.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | Java |
| **License** | GPL/LGPL |
| **First Release** | 2001 |
| **Repository** | [processing/processing4](https://github.com/processing/processing4) |
| **Documentation** | [processing.org/reference](https://processing.org/reference/) |

## Philosophy & Target Audience

Processing is the **original** creative coding framework. Key principles:
- Minimal boilerplate for beginners
- Immediate visual feedback
- IDE included (PDE)
- Extensible via "libraries"

Target audience: Artists, designers, students, educators.

## Key Entry Points

1. **`core/src/processing/core/PApplet.java`** — Main sketch class
2. **`core/src/processing/core/PGraphics.java`** — Rendering abstraction
3. **`core/src/processing/opengl/`** — OpenGL renderer

## Study Questions

- [ ] How does PApplet manage the sketch lifecycle?
- [ ] How does the rendering abstraction (PGraphics) work?
- [ ] How does the library/contribution system work?
- [ ] How does Processing's preprocessor work?
- [ ] What influenced p5.js's design?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md)
- [API Design](./api-design.md)

## See Also

- [OpenFrameworks](../openframeworks/) — C++ creative coding toolkit with similar philosophy
- [Cinder](../cinder/) — Professional-quality C++ alternative
- [openrndr](../openrndr/) — Modern Kotlin-based framework inspired by Processing
- [toxiclibs](../../per-library/processing-ecosystem/toxiclibs/) — Computational design library for Processing/Java
- [controlp5](../../per-library/processing-ecosystem/controlp5/) — GUI library with 30+ widgets
