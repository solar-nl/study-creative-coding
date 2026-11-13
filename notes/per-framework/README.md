# Per-Framework Notes

Deep-dive documentation for each creative coding framework.

## Frameworks

| Framework | Language | Status | Description |
|-----------|----------|--------|-------------|
| [p5.js](./p5js/) | JavaScript | Complete | Beginner-friendly, immediate-mode canvas |
| [nannou](./nannou/) | Rust | Partial | Rust-native creative coding |
| [drawbot](./drawbot/) | Python | Partial | Typography-focused, macOS, print-quality output |
| [openrndr](./openrndr/) | Kotlin | Partial | Modern JVM with DSL patterns; rendering pipeline and contour code-trace documented |
| [processing](./processing/) | Java | Partial | Original creative coding framework; rendering pipeline (Java2D vs P2D) and shape code-trace documented |
| [openframeworks](./openframeworks/) | C++ | Planned | Native with addon ecosystem |
| [cinder](./cinder/) | C++ | Planned | High-performance native |
| [harfang3d](./harfang3d/) | C++ (Python, Lua, Go bindings) | Partial | bgfx-backed 3D visualization engine; architecture (handle-based scene, binding-first API) and rendering pipeline (view-id tickets, variant x configuration shaders, basic and AAA tiers) documented |

## Visual Programming

Node-based creative coding environments. Source code is in `visual-programming/`, not `frameworks/`.

| Environment | Language | Status | Description |
|-------------|----------|--------|-------------|
| [cables](./cables/) | JavaScript | Complete | Node-based visual programming, WebGL/WebGPU |
| [tixl](./tixl/) | C#/.NET | Partial | Node-based 3D creative coding |

## Status Legend

- **Complete**: Full documentation with architecture traces and code walkthroughs
- **Partial**: Template structure with some content
- **Planned**: Stub files with planned topics

## How to Read

New to this documentation? See [READING_GUIDE.md](../READING_GUIDE.md) for tips on navigating these docs effectively (based on cognitive science research).

## See Also

- [FRAMEWORK_COMPARISON.md](../FRAMEWORK_COMPARISON.md) — Cross-framework comparison matrix
- [themes/](../themes/) — Cross-cutting analysis by topic
