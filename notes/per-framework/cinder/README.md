# Cinder

> A free, open source library for professional-quality creative coding in C++.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | C++ |
| **License** | BSD-2-Clause |
| **Repository** | [cinder/Cinder](https://github.com/cinder/Cinder) |
| **Documentation** | [libcinder.org/docs](https://libcinder.org/docs/) |

## Philosophy & Target Audience

Cinder focuses on professional quality and modern C++:
- Clean, modern C++ API
- High performance
- Strong graphics focus
- Built-in audio, video support

Target audience: Professional artists, studios, installations.

## Repository Structure

```
cinder/
├── include/cinder/    # Headers
│   ├── app/           # Application classes
│   ├── gl/            # OpenGL utilities
│   ├── audio/         # Audio processing
│   ├── geom/          # Geometry
│   └── ...
├── src/cinder/        # Implementation
└── samples/           # Examples
```

## Key Entry Points

1. **`include/cinder/app/App.h`** — Base application
2. **`include/cinder/gl/gl.h`** — OpenGL wrapper
3. **`include/cinder/geom/Geom.h`** — Geometry system

## Study Questions

- [ ] How does Cinder's C++ API differ from OpenFrameworks?
- [ ] How does the geometry source/target system work?
- [ ] How does the shader system work?
- [ ] How does the Block/TinderBox system work?
- [ ] How are platform differences abstracted?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md)
- [API Design](./api-design.md)

## See Also

- [OpenFrameworks](../openframeworks/) — Alternative C++ creative coding toolkit
- [Processing](../processing/) — Java-based framework with simpler learning curve
- [openrndr](../openrndr/) — Modern Kotlin framework with similar professional focus
