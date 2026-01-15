# Per-Library Notes

Documentation for reusable libraries that complement creative coding frameworks, organized by ecosystem.

## Web Libraries

JavaScript libraries for browser-based graphics.

| Library | Status | Description |
|---------|--------|-------------|
| [threejs](./web/threejs/) | Complete | WebGL/WebGPU 3D scene graph |
| [pixijs](./web/pixijs/) | Complete | High-performance 2D WebGL renderer |
| [babylonjs](./web/babylonjs/) | Complete | Full-featured 3D game engine with WebGPU support |

## Universal Libraries

Cross-platform libraries available in multiple languages.

| Library | Languages | Status | Description |
|---------|-----------|--------|-------------|
| [mixbox](https://github.com/scrtwpns/mixbox) | C++, JS, Rust, GLSL, Python | Complete | Pigment-based color mixing (Kubelka-Munk) |

## OPENRNDR Ecosystem

Kotlin libraries for the OPENRNDR framework.

| Library | Status | Description |
|---------|--------|-------------|
| [orx](./openrndr-ecosystem/orx/) | Planned | Official extension collection |

## Processing Ecosystem

Java libraries for the Processing environment.

| Library | Status | Description |
|---------|--------|-------------|
| [controlp5](./processing-ecosystem/controlp5/) | Partial | GUI library with 30+ widgets and method-chaining API |
| [toxiclibs](./processing-ecosystem/toxiclibs/) | Planned | Computational geometry, physics, color |

## Rust Libraries

Native Rust graphics libraries.

| Library | Status | Description |
|---------|--------|-------------|
| [wgpu](https://github.com/gfx-rs/wgpu) | Planned | Cross-platform WebGPU implementation |
| [rend3](./rust/rend3/) | Planned | High-level rendering framework on wgpu |

## Status Legend

- **Complete**: Full documentation with architecture traces and code walkthroughs
- **Partial**: Template structure with some content
- **Planned**: Stub files with planned topics

## How to Read

New to this documentation? See [READING_GUIDE.md](../READING_GUIDE.md) for tips on navigating these docs effectively (based on cognitive science research).

## See Also

- [libraries/](../../libraries/) — Source code submodules
- [per-framework/](../per-framework/) — Framework-specific documentation
- [themes/](../themes/) — Cross-cutting analysis by topic
