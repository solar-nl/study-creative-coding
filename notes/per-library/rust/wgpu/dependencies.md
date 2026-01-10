# wgpu - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `Cargo.toml` (workspace) |
| **Package Manager** | Cargo / crates.io |
| **Build System** | Cargo |
| **Version** | 28.0.0 |

## Workspace Structure

wgpu is a large workspace with backend-specific crates:

```
wgpu/
├── Cargo.toml          # Workspace root
├── wgpu/               # Main public API
├── wgpu-core/          # Core implementation
├── wgpu-hal/           # Hardware abstraction layer
├── wgpu-types/         # Shared types
├── naga/               # Shader compiler
├── naga-cli/           # Shader CLI tools
└── player/             # Trace replay tool
```

## Dependencies by Category

### Graphics/Rendering (Backend-Specific)

| Dependency | Version | Purpose | Platform |
|------------|---------|---------|----------|
| `ash` | 0.38 | Vulkan bindings | All |
| `metal` | native | Metal API | macOS/iOS |
| `windows` | 0.62 | DirectX 12 | Windows |
| `khronos-egl` | 6 | EGL support | Linux/Android |
| `glutin` | varies | OpenGL context | Desktop |
| `glow` | varies | OpenGL ES wrapper | Mobile/Web |

### Shader Compilation

| Dependency | Version | Purpose |
|------------|---------|---------|
| `naga` | 28.0.0 | Shader translation (WGSL/GLSL/SPIR-V) |
| `spirv` | varies | SPIR-V support |
| `rspirv` | varies | SPIR-V manipulation |

### Math

| Dependency | Version | Purpose |
|------------|---------|---------|
| `glam` | 0.30.7 | Vector/matrix math |

### Memory/Data

| Dependency | Version | Purpose |
|------------|---------|---------|
| `bytemuck` | 1.22 | Safe byte casting |
| `encase` | 0.12 | GPU memory layout |

### Image

| Dependency | Version | Purpose |
|------------|---------|---------|
| `image` | 0.25 | PNG loading (examples) |
| `ktx2` | 0.4 | KTX2 texture format |

### Web/WASM

| Dependency | Version | Purpose |
|------------|---------|---------|
| `wasm-bindgen` | 0.2.100 | WASM FFI |
| `web-sys` | 0.3.77 | Web API bindings |
| `js-sys` | 0.3.77 | JavaScript bindings |

### Windowing (Examples)

| Dependency | Version | Purpose |
|------------|---------|---------|
| `winit` | 0.29 | Window management |

## Feature Flags

wgpu uses extensive feature flags for backend selection:

```toml
[features]
vulkan = ["wgpu-hal/vulkan"]
metal = ["wgpu-hal/metal"]
dx12 = ["wgpu-hal/dx12"]
gles = ["wgpu-hal/gles"]
webgpu = []  # Default for wasm32
webgl = ["gles"]
```

## Dependency Graph Notes

- **HAL pattern** - `wgpu-hal` abstracts over platform-specific APIs
- **naga is critical** - All shader compilation goes through naga
- **Feature-gated backends** - Only compile needed backends
- **Zero-cost abstractions** - Minimal runtime overhead
- **Web-first design** - WebGPU API shapes the public interface

## Key Files

- Main Cargo.toml: `frameworks/wgpu/Cargo.toml`
- wgpu crate: `frameworks/wgpu/wgpu/Cargo.toml`
- HAL: `frameworks/wgpu/wgpu-hal/Cargo.toml`
- Naga: `frameworks/wgpu/naga/Cargo.toml`
