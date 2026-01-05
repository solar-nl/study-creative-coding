# Theme: Shader Abstractions

> Cross-cutting analysis of how frameworks wrap shader programming.

## Concept Overview

Shader abstractions include:
- High-level material systems
- Shader compilation/loading
- Uniform management
- Pre-built shaders vs custom

## Key Questions

- How are shaders loaded/compiled?
- How are uniforms set?
- What abstraction level is exposed?
- How is GLSL/WGSL managed?

## Recommendations for Rust Framework

1. **Pre-built shaders** — Common effects out of the box
2. **Custom shader support** — Allow WGSL/SPIR-V
3. **Uniform helpers** — Type-safe uniform setting
4. **Hot reload** — Development workflow consideration
