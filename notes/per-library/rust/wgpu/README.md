# [wgpu](https://github.com/gfx-rs/wgpu)

> A cross-platform, safe, pure-Rust graphics API.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | Rust |
| **License** | MIT/Apache-2.0 |
| **Repository** | [gfx-rs/[wgpu](https://github.com/gfx-rs/wgpu)](https://github.com/gfx-rs/wgpu) |
| **Documentation** | [docs.rs/[wgpu](https://github.com/gfx-rs/wgpu)](https://docs.rs/wgpu) |

## Philosophy & Target Audience

[wgpu](https://github.com/gfx-rs/wgpu) implements WebGPU in Rust:
- Safe abstraction over native APIs
- Cross-platform (Vulkan, Metal, DX12, WebGPU)
- Modern graphics API design
- Used by nannou, bevy, and others

Target audience: Rust developers needing GPU access.

## Key Concepts

- **Device/Queue** — GPU handle and command submission
- **Buffer/Texture** — GPU memory
- **Pipeline** — Shader + state configuration
- **RenderPass** — Drawing scope
- **BindGroup** — Resource binding

## Study Questions

- [ ] How does [wgpu](https://github.com/gfx-rs/wgpu) abstract backend differences?
- [ ] How does the resource binding model work?
- [ ] How are command buffers structured?
- [ ] How does compute shader support work?
- [ ] How does the web target differ from native?

## See Also

- [openrndr](../../per-framework/openrndr/) — Framework using OpenGL (different abstraction level)
- [Cinder](../../per-framework/cinder/) — C++ framework with direct OpenGL access
- [OpenFrameworks](../../per-framework/openframeworks/) — C++ toolkit with GL renderer
