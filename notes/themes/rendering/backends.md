# Theme: Rendering Backends

> Partially documented. Needs deeper analysis per framework.

Cross-cutting analysis of how frameworks abstract graphics APIs.

## Concept Overview

Creative coding frameworks need to render graphics. How they abstract the underlying APIs varies:
- Direct API usage (Canvas, OpenGL)
- Abstraction layers (Renderer classes)
- Multiple backend support

## Framework Implementations

| Framework | Backend(s) | Abstraction Level |
|-----------|------------|-------------------|
| p5.js | Canvas 2D, WebGL | Renderer classes |
| Processing | Java2D, OpenGL | PGraphics |
| [three.js](https://github.com/mrdoob/three.js) | WebGL, WebGPU | WebGLRenderer/WebGPURenderer |
| OpenFrameworks | OpenGL | ofGLRenderer |
| Cinder | OpenGL | ci::gl namespace |
| openrndr | OpenGL | Drawer |
| nannou | [wgpu](https://github.com/gfx-rs/wgpu) | Draw → [wgpu](https://github.com/gfx-rs/wgpu) |
| [wgpu](https://github.com/gfx-rs/wgpu) | Vulkan/Metal/DX12/WebGPU | Direct |

## Key Questions

- How are state changes batched?
- How is shader compilation handled?
- How are textures managed?
- How is memory allocated?

## Recommendations for Rust Framework

1. **[wgpu](https://github.com/gfx-rs/wgpu) as backend** — Cross-platform, Rust-native
2. **High-level abstraction** — Hide [wgpu](https://github.com/gfx-rs/wgpu) complexity for common cases
3. **Escape hatch** — Allow raw [wgpu](https://github.com/gfx-rs/wgpu) access when needed
4. **Automatic batching** — Group similar draw calls
