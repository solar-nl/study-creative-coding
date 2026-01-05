# OpenFrameworks

> An open source C++ toolkit for creative coding.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | C++ |
| **License** | MIT |
| **Repository** | [openframeworks/openFrameworks](https://github.com/openframeworks/openFrameworks) |
| **Documentation** | [openframeworks.cc/documentation](https://openframeworks.cc/documentation/) |

## Philosophy & Target Audience

OpenFrameworks wraps C++ complexity in a creative-friendly API:
- "Glue" for many C/C++ libraries
- Cross-platform (desktop, mobile, embedded)
- Strong addon ecosystem
- Immediate-mode drawing

Target audience: Artists, designers wanting native performance.

## Repository Structure

```
openframeworks/
├── libs/              # Core libraries
│   └── openFrameworks/
│       ├── app/       # ofApp, window management
│       ├── graphics/  # ofGraphics, drawing
│       ├── gl/        # OpenGL utilities
│       ├── math/      # ofVec, ofMatrix
│       ├── events/    # Event system
│       └── utils/     # Utilities
├── addons/            # Official addons
└── examples/          # Example projects
```

## Key Entry Points

1. **`libs/openFrameworks/app/ofApp.h`** — Base application class
2. **`libs/openFrameworks/graphics/ofGraphics.cpp`** — Drawing functions
3. **`libs/openFrameworks/gl/ofGLRenderer.cpp`** — OpenGL rendering

## Study Questions

- [ ] How does the addon system work?
- [ ] How are cross-platform differences handled?
- [ ] How does the event system work?
- [ ] How does ofGraphics manage state?
- [ ] How does the project generator work?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md)
- [API Design](./api-design.md)
