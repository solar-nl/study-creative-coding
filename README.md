# Creative Coding Frameworks Study

A comprehensive study repository for analyzing creative coding frameworks to inform the design of a new **Rust-based creative coding framework** targeting desktop, mobile, and web platforms.

## Purpose

This repository collects major creative coding frameworks as git submodules alongside structured documentation to:

1. **Understand architecture patterns** across different languages and paradigms
2. **Trace rendering pipelines** from user code to pixels
3. **Compare API design** philosophies and ergonomics
4. **Extract best practices** for a new Rust implementation

## Frameworks Under Study

### 2D/Canvas Focused
| Framework | Language | Focus |
|-----------|----------|-------|
| [p5.js](frameworks/p5js) | JavaScript | Beginner-friendly API, immediate-mode |
| [Processing](frameworks/processing) | Java | Original creative coding framework |

### 3D/GPU Focused
| Framework | Language | Focus |
|-----------|----------|-------|
| [OpenFrameworks](frameworks/openframeworks) | C++ | Native, addon ecosystem |
| [Cinder](frameworks/cinder) | C++ | High-performance, excellent API |
| [cables.gl](frameworks/cables) | JavaScript | Node-based visual programming |

### openrndr Ecosystem
| Framework | Language | Focus |
|-----------|----------|-------|
| [openrndr](frameworks/openrndr) | Kotlin | Modern JVM, DSL patterns |

### Modern/Experimental
| Framework | Language | Focus |
|-----------|----------|-------|
| [tixl](frameworks/tixl) | C#/.NET | Node-based 3D creative coding |

### Rust-Native References
| Framework | Language | Focus |
|-----------|----------|-------|
| [nannou](frameworks/nannou) | Rust | Established Rust creative coding |

## Libraries Under Study

| Library | Language | Focus |
|---------|----------|-------|
| [toxiclibs](libraries/toxiclibs) | Java | Computational geometry, physics, color theory |
| [orx](libraries/orx) | Kotlin | Extensions for openrndr |
| [mixbox](libraries/mixbox) | Multi | Pigment-based color mixing (Kubelka-Munk) |
| [three.js](libraries/threejs) | JavaScript | WebGL 3D graphics library |
| [wgpu](libraries/wgpu) | Rust | WebGPU implementation (nannou backend) |

## Examples & Samples

| Repository | Language | Focus |
|------------|----------|-------|
| [WebGPU samples](examples/webgpu-samples) | JS/TS | Next-gen graphics API examples |

## Repository Structure

```
study-creative-coding/
├── README.md                    # This file
├── FRAMEWORK_COMPARISON.md      # High-level comparison matrix
│
├── frameworks/                  # Creative coding frameworks (8 submodules)
├── libraries/                   # Reusable libraries (5 submodules)
├── examples/                    # Sample code & demos (1 submodule)
│
├── notes/
│   ├── per-framework/           # Deep dives into each framework
│   │   └── {framework}/
│   │       ├── README.md        # Overview & key insights
│   │       ├── architecture.md  # Module structure, entry points
│   │       ├── rendering-pipeline.md
│   │       ├── api-design.md
│   │       └── code-traces/     # Annotated walkthroughs
│   │
│   ├── per-library/             # Library-specific notes
│   ├── per-example/             # Example-specific notes
│   │
│   └── themes/                  # Cross-cutting analysis
│       ├── architecture-patterns.md
│       ├── rendering-backends.md
│       ├── api-ergonomics.md
│       └── ...
│
├── templates/                   # Reusable note templates
├── diagrams/                    # Architecture diagrams (Mermaid)
└── insights/                    # Extracted patterns for Rust framework
```

## Getting Started

Clone with submodules:
```bash
git clone --recurse-submodules <repo-url>
```

Or if already cloned:
```bash
git submodule update --init --recursive
```

## Study Themes

Cross-cutting analysis documents compare how frameworks handle:

- **Architecture Patterns** — Module organization, dependency injection, plugins
- **Rendering Backends** — Canvas, WebGL, OpenGL, Vulkan, WebGPU
- **API Ergonomics** — Method chaining, DSLs, error handling
- **Color Systems** — Color spaces, blending, gradients
- **Transform Stacks** — push/pop, matrix management
- **Event Systems** — Input handling, callbacks, reactive patterns
- **Shader Abstractions** — GLSL management, material systems
- **Geometry Primitives** — Shape representations, tesselation
- **Animation & Timing** — Frame loops, easing, delta time
- **Asset Loading** — Images, fonts, models, async patterns
- **Cross-Platform** — Desktop/mobile/web targeting
- **Extension Systems** — Plugins, addons, middleware

## Not Included

Some frameworks were considered but not included as submodules:

- **vvvv gamma** — Main IDE is not open source; VL.StandardLibs requires git-lfs. Study via [The Gray Book](https://thegraybook.vvvv.org/) and [VL.StandardLibs](https://github.com/vvvv/VL.StandardLibs) online.

## Contributing

This is a personal study repository. Notes are opinionated and focused on extracting patterns for a specific Rust framework design.
