# Dependencies - Cross-Framework Comparison

> What libraries power creative coding frameworks under the hood?

## Key Insight

> **Dependency selection's core idea:** In Rust, the ecosystem has converged: wgpu for graphics, winit for windowing, glam for math, cpal for audio, image for textures - embrace these standards rather than reinventing.

## Overview

This document analyzes the dependency ecosystems across creative coding frameworks, identifying patterns and commonalities that inform decisions for a new Rust-based framework.

## Dependency Categories

| Category | Purpose | Key Decisions |
|----------|---------|---------------|
| **Graphics/Rendering** | GPU access, draw calls | Which API abstraction level? |
| **Windowing** | Window creation, events | Cross-platform strategy |
| **Math** | Vectors, matrices, transforms | Performance vs ergonomics |
| **Audio** | Sound playback, synthesis | Real-time requirements |
| **Image** | Texture loading, formats | Format support breadth |
| **Input** | Keyboard, mouse, gamepad | Event model design |
| **Serialization** | Save/load, config | Format choices |
| **Build System** | Compilation, bundling | Developer experience |

---

## Graphics/Rendering Backends

### Frameworks

| Framework | Primary Backend | Abstraction Level | Cross-Platform |
|-----------|-----------------|-------------------|----------------|
| **nannou** | wgpu | High (wgpu API) | Yes (Vulkan/Metal/DX12/WebGPU) |
| **openrndr** | OpenGL 3.3+ via LWJGL | Medium | Yes (JVM) |
| **tixl** | DirectX 11 via SharpDX | Medium | Windows primary |
| **p5.js** | Canvas 2D / WebGL | High | Web only |
| **cables** | WebGL | High (node graph) | Web only |
| **openframeworks** | OpenGL | Medium | Yes (native) |
| **cinder** | OpenGL | Medium | Yes (native) |
| **processing** | OpenGL via JOGL | High | Yes (JVM) |

### Libraries

| Library | Primary Backend | Abstraction Level | Cross-Platform |
|---------|-----------------|-------------------|----------------|
| **wgpu** | Vulkan/Metal/DX12/WebGPU | Low-Medium | Yes |
| **three.js** | WebGL / WebGPU | High (scene graph) | Web only |
| **orx** | (uses openrndr) | Medium | Yes (JVM) |
| **toxiclibs** | (no renderer) | N/A | N/A |
| **mixbox** | (color library) | N/A | N/A |

### Examples

| Repository | Primary Backend | Notes |
|------------|-----------------|-------|
| **webgpu-samples** | WebGPU | Reference examples |

### Key Dependencies

| Framework | Graphics Dependency | Version |
|-----------|---------------------|---------|
| nannou | `wgpu` | 0.17.1 |
| wgpu | `ash` (Vulkan), `metal`, `d3d12` | 0.38+ |
| openrndr | `lwjgl-opengl` | 3.3.6 |
| tixl | `SharpDX.Direct3D11` | 4.2.0 |
| p5.js | Native browser APIs | - |
| three.js | Native browser APIs | - |
| processing | `jogl-all` | varies |

### Patterns Observed

1. **Modern Rust frameworks use wgpu** - Provides Vulkan/Metal/DX12 abstraction
2. **JVM frameworks use LWJGL** - Standard for Java/Kotlin OpenGL
3. **Web frameworks rely on browser** - No external graphics deps
4. **C++ frameworks use raw OpenGL** - Maximum control

---

## Windowing Libraries

### Frameworks

| Framework | Windowing Library | Event Model |
|-----------|-------------------|-------------|
| **nannou** | winit | Callback-based |
| **openrndr** | LWJGL-GLFW | Polling + callbacks |
| **tixl** | Silk.NET | Event-based |
| **p5.js** | Browser DOM | Event listeners |
| **cables** | Browser DOM | Event listeners |
| **openframeworks** | GLFW/native | Polling |
| **cinder** | Native/GLFW | Polling |
| **processing** | AWT/Swing | Event dispatch |

### Libraries

| Library | Windowing Library | Event Model |
|---------|-------------------|-------------|
| **wgpu** | winit (examples) | Callback-based |
| **three.js** | Browser DOM | Event listeners |

### Key Dependencies

| Framework | Windowing Dependency | Version |
|-----------|----------------------|---------|
| nannou | `winit` | 0.28 |
| wgpu | `winit` | 0.29 |
| openrndr | `lwjgl-glfw` | 3.3.6 |
| tixl | `Silk.NET.Windowing` | 2.22.0 |

### Patterns Observed

1. **winit dominates Rust ecosystem** - De facto standard
2. **GLFW popular across languages** - Via LWJGL (Kotlin), native (C++)
3. **Browser handles web frameworks** - No windowing deps needed

---

## Math Libraries

### Frameworks

| Framework | Math Library | Features |
|-----------|--------------|----------|
| **nannou** | glam (via wgpu) | SIMD, no generics |
| **openrndr** | Custom + LWJGL | DSL-friendly |
| **tixl** | SharpDX.Mathematics / System.Numerics | .NET native |
| **p5.js** | Custom (p5.Vector) | Simple, mutable |
| **cables** | Custom | Node-graph compatible |
| **openframeworks** | glm | C++ standard |
| **cinder** | glm / custom | C++ standard |
| **processing** | PVector (custom) | Simple, mutable |

### Libraries

| Library | Math Library | Features |
|---------|--------------|----------|
| **wgpu** | glam | SIMD, no generics |
| **three.js** | Custom (THREE.Vector3, etc.) | Scene graph integrated |
| **toxiclibs** | Custom (Vec2D, Vec3D) | Geometry focused |

### Key Dependencies

| Framework | Math Dependency | Version |
|-----------|-----------------|---------|
| nannou | `glam` | (via wgpu) |
| wgpu | `glam` | 0.30.7 |
| openrndr | `lwjgl` math | 3.3.6 |
| tixl | `SharpDX.Mathematics` | 4.2.0 |

### Patterns Observed

1. **glam is Rust standard** - Fast, SIMD-optimized, no generics overhead
2. **Most frameworks roll their own** - For API ergonomics (p5, Processing, three.js)
3. **C++ uses glm** - Industry standard

---

## Audio Libraries

### Frameworks

| Framework | Audio Library | Features |
|-----------|---------------|----------|
| **nannou** | nannou_audio (cpal) | Cross-platform streams |
| **openrndr** | LWJGL-OpenAL | 3D positional audio |
| **tixl** | ManagedBass, NAudio | Windows audio, MIDI |
| **p5.js** | Web Audio API | Browser native |
| **cables** | Web Audio API | Node-based audio |
| **openframeworks** | OpenAL / native | Platform-specific |
| **processing** | Minim / native | Simple playback |

### Libraries

| Library | Audio Library | Features |
|---------|---------------|----------|
| **three.js** | Web Audio API | 3D positional |
| **orx** | Minim | Processing-style audio |

### Key Dependencies

| Framework | Audio Dependency | Version |
|-----------|------------------|---------|
| nannou | `cpal` | (internal) |
| openrndr | `lwjgl-openal` | 3.3.6 |
| orx | `minim` | 2.2.2 |
| tixl | `ManagedBass` | 3.1.1 |

### Patterns Observed

1. **cpal for Rust** - Cross-platform audio I/O
2. **OpenAL for native** - 3D audio standard
3. **Web Audio API for web** - Browser built-in

---

## Image Loading

### Frameworks

| Framework | Image Library | Formats |
|-----------|---------------|---------|
| **nannou** | image crate | PNG, JPEG, GIF, BMP, etc. |
| **openrndr** | LWJGL STB | Common formats |
| **tixl** | OpenCvSharp4, custom | Extensive |
| **p5.js** | Browser native | Web formats |
| **cables** | Browser native | Web formats |
| **openframeworks** | FreeImage / native | Extensive |
| **processing** | Java ImageIO | Common formats |

### Libraries

| Library | Image Library | Formats |
|---------|---------------|---------|
| **wgpu** | image crate | PNG (examples) |
| **three.js** | Browser native | Web formats |

### Key Dependencies

| Framework | Image Dependency | Version |
|-----------|------------------|---------|
| nannou | `image` | 0.23 |
| wgpu | `image` | 0.25 |
| tixl | `OpenCvSharp4` | 4.11.0 |

### Patterns Observed

1. **`image` crate for Rust** - Comprehensive format support
2. **stb_image popular** - Single-header C library, many bindings
3. **OpenCV for advanced** - When processing needed beyond loading

---

## Build Systems

### Frameworks

| Framework | Build System | Package Manager |
|-----------|--------------|-----------------|
| **nannou** | Cargo | crates.io |
| **openrndr** | Gradle | Maven Central |
| **tixl** | MSBuild | NuGet |
| **p5.js** | npm/Grunt | npm |
| **cables** | npm/Webpack | npm |
| **openframeworks** | CMake/Make | Manual/addons |
| **cinder** | CMake | Manual |
| **processing** | Ant | Manual |

### Libraries

| Library | Build System | Package Manager |
|---------|--------------|-----------------|
| **wgpu** | Cargo | crates.io |
| **three.js** | npm/Rollup | npm |
| **orx** | Gradle | Maven Central |
| **toxiclibs** | Maven/Gradle | Maven Central |
| **mixbox** | Multiple | Cargo/npm/pip/NuGet |

### Patterns Observed

1. **Language dictates build system** - Cargo (Rust), Gradle (Kotlin), npm (JS)
2. **C++ most fragmented** - CMake, Make, custom
3. **Modern systems have package managers** - Easier dependency management

---

## Cross-Platform Strategies

| Strategy | Frameworks/Libraries | Pros | Cons |
|----------|---------------------|------|------|
| **Native abstraction (wgpu)** | nannou, wgpu (library) | Best performance | Complex implementation |
| **JVM abstraction** | openrndr, processing | Write once | JVM overhead |
| **Web only** | p5.js, cables, three.js (library) | Easy distribution | Browser limitations |
| **Per-platform builds** | openframeworks, cinder | Full control | Maintenance burden |
| **Single platform** | tixl (Windows primary) | Optimized | Limited reach |

---

## Recommendations for Rust Framework

### Graphics
- **Use wgpu** - Industry standard for Rust, cross-platform, WebGPU future-proof
- Consider thin wrapper for ergonomics (like nannou does)

### Windowing
- **Use winit** - De facto Rust standard, well-maintained
- Event loop design critical for API feel

### Math
- **Use glam** - Fast, well-integrated with wgpu ecosystem
- Consider wrapper types for creative coding ergonomics (like p5.js Vector)

### Audio
- **Use cpal** - Cross-platform audio I/O
- Consider rodio for higher-level playback

### Image
- **Use image crate** - Comprehensive, pure Rust
- Add stb_image for any missing formats

### Build
- **Cargo workspace** - Standard Rust approach
- Consider feature flags for optional components

---

## Dependency Ecosystem Health

| Ecosystem | Maturity | Maintenance | Fragmentation |
|-----------|----------|-------------|---------------|
| **Rust/Cargo** | Growing | Active | Low |
| **JVM/Gradle** | Mature | Active | Low |
| **npm/JS** | Mature | Active | High |
| **C++/CMake** | Mature | Varies | Very High |
| **.NET/NuGet** | Mature | Active | Low |

The Rust ecosystem, while younger, benefits from:
- Centralized package registry (crates.io)
- Strong type system reducing "dependency hell"
- wgpu emerging as clear graphics standard
