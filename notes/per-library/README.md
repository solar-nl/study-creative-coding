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
| [ltc](./universal/ltc/) | C++, GLSL | Planned | Real-time area light shading (Linearly Transformed Cosines) |

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

## vvvv Ecosystem

C# node libraries for vvvv gamma.

| Library | Status | Description |
|---------|--------|-------------|
| [VL.StandardLibs](./vvvv-ecosystem/vl-standardlibs/) | Planned | Standard nodes; VL.Skia 2D layer model over SkiaSharp (GPU via ANGLE) |

## C++ Libraries

Native C++ rendering libraries.

| Library | Status | Description |
|---------|--------|-------------|
| [filament](./cpp/filament/) | Planned | Real-time physically based rendering engine (Vulkan/Metal/OpenGL/WebGL) |

## Rust Libraries

Native Rust graphics libraries.

| Library | Status | Description |
|---------|--------|-------------|
| [wgpu](https://github.com/gfx-rs/wgpu) | Planned | Cross-platform WebGPU implementation |
| [rend3](./rust/rend3/) | Planned | High-level rendering framework on wgpu |
| [vello](./rust/vello/) | Complete | GPU-accelerated 2D vector renderer: architecture, sparse strips, CPU/GPU split, wgpu integration, paints and layers, text, compute renderer, fill_path code-trace |

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
