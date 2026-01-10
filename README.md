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

### openrndr Ecosystem
| Framework | Language | Focus |
|-----------|----------|-------|
| [openrndr](frameworks/openrndr) | Kotlin | Modern JVM, DSL patterns |

### Visual Programming Environments
| Environment | Language | Focus |
|-------------|----------|-------|
| [cables.gl](visual-programming/cables) | JavaScript | Web-based node editor, WebGL |
| [cables_ui](visual-programming/cables_ui) | JavaScript | cables.gl editor interface |
| [tixl](visual-programming/tixl) | C#/.NET | Node-based 3D creative coding |

### Rust-Native References
| Framework | Language | Focus |
|-----------|----------|-------|
| [nannou](frameworks/nannou) | Rust | Established Rust creative coding |

### Typography-Focused
| Framework | Language | Focus |
|-----------|----------|-------|
| [DrawBot](frameworks/drawbot) | Python | Print-quality output, variable fonts, macOS |

## Libraries Under Study

### Web Libraries
| Library | Language | Focus |
|---------|----------|-------|
| [three.js](libraries/web/threejs) | JavaScript | WebGL/WebGPU 3D scene graph |
| [PixiJS](libraries/web/pixijs) | JavaScript | High-performance 2D WebGL renderer |
| [Babylon.js](libraries/web/babylonjs) | JavaScript | Full-featured 3D game engine |

### Universal Libraries
| Library | Languages | Focus |
|---------|-----------|-------|
| [mixbox](libraries/universal/mixbox) | C++, JS, Rust, GLSL, Python | Pigment-based color mixing (Kubelka-Munk) |

### OPENRNDR Ecosystem
| Library | Language | Focus |
|---------|----------|-------|
| [orx](libraries/openrndr-ecosystem/orx) | Kotlin | Extensions for OPENRNDR |

### Processing Ecosystem
| Library | Language | Focus |
|---------|----------|-------|
| [toxiclibs](libraries/processing-ecosystem/toxiclibs) | Java | Computational geometry, physics, color theory |
| [ControlP5](libraries/controlp5) | Java | GUI library with 30+ widgets |

### Rust Libraries
| Library | Language | Focus |
|---------|----------|-------|
| [wgpu](libraries/rust/wgpu) | Rust | WebGPU implementation (nannou backend) |

## Examples & Samples

| Repository | Language | Focus |
|------------|----------|-------|
| [WebGPU samples](examples/webgpu-samples) | JS/TS | Next-gen graphics API examples |

## Demoscene

| Project | Languages | Focus |
|---------|-----------|-------|
| [fr_public](demoscene/fr_public) | C++, Assembly | Werkkzeug demo tool, V2 synthesizer, .kkrieger, procedural content (2001-2011) |

## Repository Structure

```
study-creative-coding/
├── README.md                    # This file
├── FRAMEWORK_COMPARISON.md      # High-level comparison matrix
│
├── frameworks/                  # Creative coding frameworks (8 submodules)
├── visual-programming/          # Node-based environments (3 submodules)
├── libraries/                   # Reusable libraries (8 submodules, organized by ecosystem)
├── examples/                    # Sample code & demos (1 submodule)
├── demoscene/                   # Demoscene tools and techniques (1 submodule)
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
│   ├── per-demoscene/           # Demoscene project analysis
│   ├── per-example/             # Example-specific notes
│   │
│   └── themes/                  # Cross-cutting analysis
│       ├── README.md            # Theme index
│       ├── typography/          # Text rendering, fonts
│       ├── vector-graphics/     # Paths, tessellation
│       ├── rendering/           # Pipelines, shaders
│       ├── core/                # Architecture, color, API design
│       └── systems/             # Events, animation, assets
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

Cross-cutting analysis organized by category. See [themes/README.md](notes/themes/README.md) for full index.

| Category | Topics |
|----------|--------|
| **[Typography](notes/themes/typography/)** | Font rendering, fallback chains, variable fonts, text shaping |
| **[Vector Graphics](notes/themes/vector-graphics/)** | Tessellation, boolean ops, SVG interop, stroke styles |
| **[Rendering](notes/themes/rendering/)** | Immediate/retained modes, instancing, backends, shaders |
| **[Core](notes/themes/core/)** | Architecture, color systems, API ergonomics, transforms |
| **[Systems](notes/themes/systems/)** | Events, animation, asset loading, cross-platform, extensions |

## Not Included

Some frameworks were considered but not included as submodules:

- **vvvv gamma** — Main IDE is not open source; VL.StandardLibs requires git-lfs. Study via [The Gray Book](https://thegraybook.vvvv.org/) and [VL.StandardLibs](https://github.com/vvvv/VL.StandardLibs) online.

## Documentation Status

| Category | Complete | Partial | Planned |
|----------|----------|---------|---------|
| **Frameworks** | p5.js, cables | nannou, tixl, drawbot | openrndr, cinder, openframeworks, processing |
| **Libraries** | mixbox, threejs, pixijs, babylonjs | controlp5 | orx, toxiclibs, wgpu |
| **Demoscene** | fr_public | — | — |
| **Examples** | — | — | webgpu-samples |
| **Themes** | typography/, vector-graphics/ | rendering/, core/ | systems/ |

**Legend:**
- **Complete**: Deep analysis with architecture traces, code walkthroughs, and conceptual explanations
- **Partial**: Template structure with some content, needs expansion
- **Planned**: Stub files marked "Not yet documented" with planned topics

## Contributing

This is a personal study repository. Notes are opinionated and focused on extracting patterns for a specific Rust framework design.
