# C++ Libraries

Native C++ rendering engines and libraries.

## Libraries

| Library | Focus | Cross-Platform Strategy |
|---------|-------|------------------------|
| [filament](./filament/) | Real-time physically based rendering | Vulkan/Metal/OpenGL/WebGL backends |

## Why C++ Rendering Libraries

C++ remains dominant in production rendering due to performance requirements and legacy codebases. Studying C++ rendering engines provides insights into:

- **Backend abstraction patterns** — How to support multiple GPU APIs (Vulkan, Metal, OpenGL) through a unified interface
- **Ahead-of-time compilation** — Material compilation strategies that optimize before runtime
- **Memory management** — Handle-based resource systems and GPU resource lifetime management
- **Performance optimization** — Mobile optimization techniques, memory layouts, cache-friendly data structures

While this study repository focuses on designing a Rust-based creative coding framework, C++ engines like Filament demonstrate battle-tested patterns for cross-platform rendering that translate well to Rust.

## Architecture Patterns

C++ rendering engines typically use one of these abstraction strategies:

### Command Stream Pattern (Filament)
Abstract commands recorded to a buffer, consumed by backend-specific implementations. Allows runtime backend selection with minimal overhead.

### Virtual Interface Pattern
Pure virtual classes define GPU operations, concrete backend classes implement them. Common in older engines but adds vtable overhead.

### Template Metaprogramming
Compile-time backend selection using C++ templates. Zero runtime overhead but increases compilation time and binary size.

## Material Compilation Approaches

| Engine | Strategy | Tradeoff |
|--------|----------|----------|
| Filament | Ahead-of-time (matc compiler) | Better optimization, longer builds |
| three.js | Runtime (node graph compilation) | Flexible, limited optimization |
| wgpu | Ahead-of-time (naga) | Cross-backend SPIR-V/WGSL/MSL/GLSL |

Filament's ahead-of-time approach generates backend-specific shaders during build time, allowing aggressive optimization but requiring recompilation for material changes.

## See Also

- [notes/per-library/cpp/](../../notes/per-library/cpp/) — Detailed library documentation
- [notes/themes/rendering-backends.md](../../notes/themes/rendering-backends.md) — Cross-framework backend comparison
