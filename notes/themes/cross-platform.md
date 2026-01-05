# Theme: Cross-Platform Support

> Cross-cutting analysis of how frameworks target multiple platforms.

## Concept Overview

Cross-platform concerns:
- Desktop (Windows, macOS, Linux)
- Mobile (iOS, Android)
- Web (WebGL, WebGPU)
- Build systems

## Key Questions

- What platforms are supported?
- How are platform differences abstracted?
- What's the build/deploy process?
- Platform-specific features?

## Recommendations for Rust Framework

1. **wgpu for graphics** — Vulkan/Metal/DX12/WebGPU
2. **winit for windowing** — Cross-platform windows
3. **WASM support** — Web target via wasm-bindgen
4. **Conditional compilation** — Platform-specific code paths
