# Themes

Cross-cutting analysis documents comparing how creative coding frameworks handle common concerns.

## Categories

### [Typography](./typography/)
Text rendering, font handling, and text layout across frameworks.
- [Overview](./typography/README.md) — Framework comparison and key concepts
- [Font Fallback](./typography/font-fallback.md) — Fallback chain strategies
- [Variable Fonts](./typography/variable-fonts.md) — OpenType variable font support
- [WASM Shaping](./typography/wasm-shaping.md) — WebAssembly text shaping
- [Layout Mutability](./typography/layout-mutability.md) — Mutable vs immutable text layout

### [Vector Graphics](./vector-graphics/)
Path rendering, tessellation, and 2D geometry operations.
- [Overview](./vector-graphics/README.md) — Framework comparison and key concepts
- [Tessellation](./vector-graphics/tessellation.md) — Path to triangle conversion
- [Boolean Operations](./vector-graphics/boolean-ops.md) — Union, intersection, difference
- [SVG Interop](./vector-graphics/svg-interop.md) — SVG import/export patterns
- [Stroke Styles](./vector-graphics/stroke-styles.md) — Caps, joins, dashes

### [Rendering](./rendering/)
Graphics pipelines, batching, and shader management.
- [Overview](./rendering/README.md) — Immediate vs retained mode patterns
- [Instance Rendering](./rendering/instance-rendering.md) — GPU instancing strategies
- [Primitive Strategies](./rendering/primitive-strategies.md) — Shape rendering approaches
- [Backends](./rendering/backends.md) — OpenGL, WebGL, WebGPU, Metal, Vulkan
- [Shader Abstractions](./rendering/shader-abstractions.md) — Shader compilation and uniforms

### [Core](./core/)
Foundational framework design patterns.
- [Architecture Patterns](./core/architecture-patterns.md) — Module organization, plugins
- [Color Systems](./core/color-systems.md) — Color spaces, blending, gradients
- [API Ergonomics](./core/api-ergonomics.md) — Naming, chaining, error handling
- [Transform Stacks](./core/transform-stacks.md) — Matrix push/pop patterns
- [Geometry Primitives](./core/geometry-primitives.md) — Shape representations
- [Dependencies](./core/dependencies.md) — Dependency analysis across frameworks

### [Systems](./systems/)
Runtime concerns and framework infrastructure.
- [Event Systems](./systems/event-systems.md) — Input handling, callbacks
- [Animation & Timing](./systems/animation-timing.md) — Frame loops, easing, delta time
- [Asset Loading](./systems/asset-loading.md) — Images, fonts, models, async patterns
- [Cross-Platform](./systems/cross-platform.md) — Desktop, mobile, web targeting
- [Extension Systems](./systems/extension-systems.md) — Plugins, addons, middleware

## How to Read

New to this documentation? See [READING_GUIDE.md](../READING_GUIDE.md) for tips on navigating these docs effectively (based on cognitive science research).

## Documentation Status

| Category | Status |
|----------|--------|
| Typography | Complete |
| Vector Graphics | Complete |
| Rendering | Partial (backends, shader-abstractions need expansion) |
| Core | Mixed (color-systems complete, others partial/planned) |
| Systems | Planned (all files are stubs) |
