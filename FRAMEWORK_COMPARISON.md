# Framework Comparison Matrix

A high-level comparison of all frameworks under study.

## Overview

| Framework | Language | Paradigm | Primary Target | Rendering Backend |
|-----------|----------|----------|----------------|-------------------|
| p5.js | JavaScript | Immediate | Web | Canvas/WebGL |
| Processing | Java | Immediate | Desktop | Java2D/OpenGL |
| toxiclibs | Java | Library | Desktop | N/A (geometry lib) |
| three.js | JavaScript | Retained (Scene Graph) | Web | WebGL/WebGPU |
| OpenFrameworks | C++ | Immediate | Desktop/Mobile | OpenGL |
| Cinder | C++ | Immediate | Desktop/Mobile | OpenGL |
| cables.gl | JavaScript | Node-based | Web | WebGL |
| vvvv | C#/.NET | Node-based | Desktop | Stride/DirectX |
| VL.StandardLibs | C#/.NET | Library | Desktop | N/A |
| VL.Stride | C#/.NET | Retained | Desktop | Stride Engine |
| openrndr | Kotlin | Immediate | Desktop | OpenGL |
| orx | Kotlin | Library | Desktop | N/A (extensions) |
| tixl | Rust | TBD | Desktop/Web | TBD |
| WebGPU samples | JS/Rust | Examples | Web | WebGPU |
| nannou | Rust | Immediate | Desktop | wgpu |
| wgpu | Rust | Low-level | All | Vulkan/Metal/DX12/WebGPU |

## Architecture Patterns

| Framework | Module System | Extension Model | Config Approach |
|-----------|---------------|-----------------|-----------------|
| p5.js | | | |
| Processing | | | |
| three.js | | | |
| OpenFrameworks | | | |
| Cinder | | | |
| vvvv | | | |
| openrndr | | | |
| nannou | | | |

## API Design

| Framework | Chaining | Error Handling | Type Safety | DSL Features |
|-----------|----------|----------------|-------------|--------------|
| p5.js | | | | |
| Processing | | | | |
| three.js | | | | |
| OpenFrameworks | | | | |
| Cinder | | | | |
| openrndr | | | | |
| nannou | | | | |

## Rendering Features

| Framework | 2D Shapes | 3D Meshes | Shaders | Post-Processing | Instancing |
|-----------|-----------|-----------|---------|-----------------|------------|
| p5.js | | | | | |
| Processing | | | | | |
| three.js | | | | | |
| OpenFrameworks | | | | | |
| Cinder | | | | | |
| openrndr | | | | | |
| nannou | | | | | |

## Platform Support

| Framework | Desktop | Mobile | Web | Native GPU API |
|-----------|---------|--------|-----|----------------|
| p5.js | | | | |
| Processing | | | | |
| three.js | | | | |
| OpenFrameworks | | | | |
| Cinder | | | | |
| vvvv | | | | |
| openrndr | | | | |
| nannou | | | | |
| wgpu | | | | |

---

*This matrix will be filled in as each framework is studied.*
