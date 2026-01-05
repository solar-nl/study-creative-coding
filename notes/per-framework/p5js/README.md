# p5.js

> A JavaScript library that makes coding accessible for artists, designers, educators, and beginners.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | JavaScript |
| **License** | LGPL-2.1 |
| **First Release** | 2014 |
| **Repository** | [processing/p5.js](https://github.com/processing/p5.js) |
| **Documentation** | [p5js.org/reference](https://p5js.org/reference/) |

## Philosophy & Target Audience

p5.js is the spiritual successor to Processing, designed for the web. Its core philosophy is **accessibility**:

- Beginner-friendly API with minimal boilerplate
- Global mode by default (no explicit class instantiation)
- Immediate-mode drawing (call functions, things appear)
- Comprehensive error messages through the "Friendly Error System"

Target audience: Artists, designers, educators, creative coding beginners.

## Repository Structure

```
p5js/
├── src/                    # Source code
│   ├── app.js              # Main entry point
│   ├── core/               # Core framework (required for all builds)
│   │   ├── main.js         # p5 constructor class
│   │   ├── constants.js    # Global constants
│   │   ├── environment.js  # Window/environment management
│   │   ├── rendering.js    # Canvas/rendering pipeline
│   │   ├── structure.js    # push/pop, sketch lifecycle
│   │   ├── transform.js    # 2D transformations
│   │   ├── p5.Renderer.js  # Base renderer class
│   │   ├── p5.Renderer2D.js # 2D canvas renderer
│   │   ├── p5.Element.js   # DOM element wrapper
│   │   ├── p5.Graphics.js  # Off-screen graphics buffer
│   │   ├── friendly_errors/ # Error handling system
│   │   └── shape/          # 2D primitives, curves, vertex
│   ├── webgl/              # 3D/WebGL rendering (20+ files)
│   ├── color/              # Color manipulation
│   ├── events/             # Input handling
│   ├── math/               # p5.Vector, noise, etc.
│   ├── image/              # Image processing
│   ├── io/                 # File I/O, data parsing
│   ├── typography/         # Text/font rendering
│   └── dom/                # DOM manipulation
├── lib/                    # Built output
├── tasks/                  # Build scripts
└── test/                   # Test suite
```

## Key Entry Points

Start reading here to understand the framework:

1. **`src/app.js`** — Main entry, imports all modules, exports p5 constructor
2. **`src/core/main.js`** — p5 class constructor, lifecycle (preload/setup/draw)
3. **`src/core/rendering.js`** — Canvas creation, background, rendering pipeline
4. **`src/core/p5.Renderer2D.js`** — How 2D drawing commands are implemented

## Notable Patterns

- **Prototype extension**: Methods added to `p5.prototype` become available globally
- **Global vs Instance mode**: Functions can be bound to `window` or a p5 instance
- **Friendly Error System**: Runtime validation with helpful error messages
- **Modular builds**: Custom builds can exclude unused modules

## Study Questions

- [ ] How does the lifecycle (preload → setup → draw loop) work?
- [ ] How does global mode bind functions to window?
- [ ] How does the Friendly Error System detect and report errors?
- [ ] How does the 2D renderer batch drawing commands?
- [ ] How does WebGL mode differ from 2D mode architecturally?
- [ ] How are async operations (loadImage, loadFont) handled?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md)
- [API Design](./api-design.md)
