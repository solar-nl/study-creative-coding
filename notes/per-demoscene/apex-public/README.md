# Conspiracy apEx Demotool Study

> apEx demotool, Phoenix 64k engine, MVX synthesizer, and Whiteboard UI (2010-2023)

---

## Why Study apEx?

The apEx demotool by Hungarian demogroup Conspiracy represents a complete modern demoscene production pipeline, actively developed between 2010-2021 and used for releases through 2023. Unlike the historical fr_public codebase, apEx demonstrates contemporary approaches to demo tooling with modern C++, DirectX 11, and sophisticated UI design.

Key productions created with apEx include Clean Slate, Darkness Lay Your Eyes Upon Me, Offscreen Colonies, and When Silence Dims the Stars Above - all showcasing cutting-edge real-time rendering and procedural content generation.

### Relevance to Rust Framework

- **Phoenix engine** — Complete 64k demo engine with modern rendering pipeline
- **Whiteboard UI** — Custom immediate-mode UI library (comparison point for egui integration)
- **MVX synthesizer** — Modern synth based on V2 and WaveSabre technologies
- **Bedrock libraries** — Foundation layer comparable to nannou's core abstractions
- **Tool architecture** — Node-based content authoring with live preview and export

### Comparison with fr_public

| Aspect | apEx (Conspiracy) | fr_public (Farbrausch) |
|--------|-------------------|------------------------|
| Era | 2010-2023 | 2001-2014 |
| Graphics API | DirectX 11 | DirectX 9/11 |
| Language | Modern C++ (VS2022) | C++ (VS2010) |
| Synthesizer | MVX (V2 + WaveSabre) | V2 |
| UI Library | Whiteboard | Custom immediate |
| License | CC-NC | Public Domain |
| Documentation | Sparse | Community-documented |

---

## Key Areas to Study

### High Priority

- **apEx/Phoenix/** — 64k demo engine core
  - Rendering pipeline (DX11)
  - Scene graph and object system
  - Material and shader system
  - Procedural content generators

- **Bedrock/Whiteboard/** — UI library
  - Widget system architecture
  - Event handling and layout
  - Immediate-mode patterns in C++
  - Integration with rendering backend

- **apEx/MVX/** — Synthesizer library
  - Based on V2 and WaveSabre
  - Audio synthesis architecture
  - Integration with demo timeline

### Medium Priority

- **apEx/Phoenix_Tool/** — Tool wrapper for Phoenix engine
  - Live preview system
  - Parameter editing and animation
  - Scene export for minimal player

- **Bedrock/CoRE2/** — Conspiracy Rendering Engine 2
  - DirectX 11 abstraction layer
  - Resource management
  - Originally designed for MMO (Perpetuum)

- **apEx/MinimalPlayer/** — Release executable
  - Minimal runtime for deployed demos
  - Size optimization techniques
  - Integration with kkrunchy/rekkrunchy

### Lower Priority

- **Bedrock/BaseLib/** — Basic runtime classes
- **Bedrock/UtilLib/** — Utility functions
- **apEx/LibCTiny/** — Tiny CRT for releases
- **Projects/** — Actual demo project files

**Source locations:**
- `demoscene/apex-public/apEx/Phoenix/` — Core 64k engine
- `demoscene/apex-public/Bedrock/Whiteboard/` — UI library
- `demoscene/apex-public/apEx/MVX/` — Synthesizer
- `demoscene/apex-public/Projects/` — Demo sources

---

## Repository Structure

```
apex-public/
├── apEx/                      # Main tool and engine
│   ├── apEx/                  # Tool executable project (editor)
│   ├── Phoenix/               # Core 64k demo engine
│   ├── Phoenix_Tool/          # Tool wrapper for Phoenix
│   ├── MinimalPlayer/         # Release executable project
│   ├── MVX/                   # Synthesizer library (V2 + WaveSabre)
│   ├── LibCTiny/              # Tiny CRT for minimal releases
│   ├── Libraries/             # Third-party dependencies
│   ├── ThirdParty/            # D3DX headers and libraries
│   └── Utils/                 # Build tools (NASM, compressors)
│
├── Bedrock/                   # Foundation libraries
│   ├── BaseLib/               # Basic runtime classes
│   ├── CoRE2/                 # DirectX 11 rendering engine
│   ├── UtilLib/               # Utility functions
│   └── Whiteboard/            # Immediate-mode UI library
│
└── Projects/                  # Demo project files
    ├── Clean Slate/
    ├── Darkness Lay Your Eyes Upon Me/
    ├── Offscreen Colonies/
    ├── One of These Days The Sky's Gonna Break/
    ├── Supermode/
    ├── Universal Sequence/
    ├── Vessel/
    └── When Silence Dims the Stars Above/
```

---

## Technical Highlights

### apEx Tool Architecture

- **Editor** — Node-based scene authoring with live preview
- **Timeline** — Animation and sequencing system
- **Export** — Generates minimal player executable
- **Build system** — Visual Studio 2022 solution

### Phoenix Engine Features

- DirectX 11 rendering pipeline
- Procedural mesh generators
- Material and shader system
- Particle systems
- Post-processing effects
- Scene graph with transforms

### Whiteboard UI

- Custom immediate-mode widget library
- Written before egui existed
- Integrated with CoRE2 rendering
- Supports docking, tabs, menus, dialogs
- Optimized for tool development

### MVX Synthesizer

- Based on V2 by Tammo "kb" Hinrichs
- Incorporates WaveSabre by Jake "Ferris" Taylor
- Compact representation for 64k size limit
- VST interface for standalone use

### Size Optimization

- Uses .kkrunchy by Fabian "ryg" Giesen
- Uses .rekkrunchy by Ralph "revivalizer" Brorsen
- LibCTiny minimal C runtime
- HLSL shader minification via modified UE AST code

---

## Documentation Status

### Core Architecture Documents ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`architecture.md`](architecture.md) | Phoenix engine and Bedrock structure | Complete |
| [`rendering/pipeline.md`](rendering/pipeline.md) | DirectX 11 abstraction and scene rendering | Complete |
| [`tool/ui-system.md`](tool/ui-system.md) | Whiteboard immediate-mode UI patterns | Complete |
| [`synthesis.md`](synthesis.md) | MVX architecture and V2/WaveSabre integration | Complete |
| [`tool/architecture.md`](tool/architecture.md) | apEx editor design and export pipeline | Complete |
| [`size-optimization.md`](size-optimization.md) | Techniques for 64k size constraints | Complete |

### Geometry System ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`geometry/overview.md`](geometry/overview.md) | Procedural geometry architecture | Complete |
| [`geometry/primitives.md`](geometry/primitives.md) | Built-in mesh primitives | Complete |
| [`geometry/filters.md`](geometry/filters.md) | Mesh modification filters | Complete |
| [`geometry/scene-integration.md`](geometry/scene-integration.md) | Scene graph integration | Complete |
| [`geometry/examples.md`](geometry/examples.md) | Modeling workflow examples | Complete |

### Rendering System ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`rendering/overview.md`](rendering/overview.md) | PBR architecture and mental model | Complete |
| [`rendering/pipeline.md`](rendering/pipeline.md) | Scene-to-GPU flow, render layers | Complete |
| [`rendering/materials.md`](rendering/materials.md) | Material parameters and techniques | Complete |
| [`rendering/shaders.md`](rendering/shaders.md) | HLSL patterns and BRDF implementation | Complete |
| [`rendering/lighting.md`](rendering/lighting.md) | Lights, shadows, LTC area lights | Complete |
| [`rendering/deferred.md`](rendering/deferred.md) | G-Buffer layout and reconstruction | Complete |
| [`rendering/examples.md`](rendering/examples.md) | Clean Slate production examples | Complete |
| [`rendering/post-processing.md`](rendering/post-processing.md) | Post-processing effects pipeline | Complete |
| [`rendering/reflections.md`](rendering/reflections.md) | 5 reflection techniques: SSR, IBL, mirror, LTC, non-LTC | Complete |

### Code Traces ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`code-traces/scene-to-pixels.md`](code-traces/scene-to-pixels.md) | Trace scene graph to GPU draw calls | Complete |
| [`code-traces/pbr-pipeline.md`](code-traces/pbr-pipeline.md) | Cook-Torrance BRDF, G-Buffer packing | Complete |
| [`code-traces/ltc-area-lighting.md`](code-traces/ltc-area-lighting.md) | LTC lookup tables and area light integration | Complete |
| [`code-traces/ui-rendering.md`](code-traces/ui-rendering.md) | Whiteboard widget render path | Complete |
| [`code-traces/synth-pipeline.md`](code-traces/synth-pipeline.md) | Audio generation from MVX data | Complete |
| [`code-traces/noise-generation.md`](code-traces/noise-generation.md) | Perlin noise implementation trace | Complete |
| [`code-traces/operator-evaluation.md`](code-traces/operator-evaluation.md) | Texgen operator dispatch | Complete |
| [`code-traces/timeline-frame.md`](code-traces/timeline-frame.md) | Frame iteration and event dispatch | Complete |
| [`code-traces/spline-evaluation.md`](code-traces/spline-evaluation.md) | Keyframe interpolation trace | Complete |
| [`code-traces/tree-generation.md`](code-traces/tree-generation.md) | Arbaro L-system execution | Complete |
| [`code-traces/scene-update.md`](code-traces/scene-update.md) | Scene graph traversal and matrices | Complete |
| [`code-traces/particle-frame.md`](code-traces/particle-frame.md) | Particle simulation step | Complete |
| [`code-traces/reflections-ssr.md`](code-traces/reflections-ssr.md) | Screen-space reflections ray march | Complete |
| [`code-traces/reflections-ibl.md`](code-traces/reflections-ibl.md) | Fake cubemap IBL with GGX importance sampling | Complete |
| [`code-traces/reflections-mirror.md`](code-traces/reflections-mirror.md) | 2D planar mirror reflection | Complete |

### Pattern Documents ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`patterns/ui-patterns.md`](patterns/ui-patterns.md) | Transferable UI design patterns | Complete |
| [`patterns/engine-patterns.md`](patterns/engine-patterns.md) | 64k engine architecture patterns | Complete |

### Texture Generation System ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`texgen/overview.md`](texgen/overview.md) | Procedural texture architecture | Complete |
| [`texgen/operators.md`](texgen/operators.md) | Operator types and parameters | Complete |
| [`texgen/generators.md`](texgen/generators.md) | Pattern generators (noise, cells, etc.) | Complete |
| [`texgen/transforms.md`](texgen/transforms.md) | UV transforms and distortion | Complete |
| [`texgen/color-blend.md`](texgen/color-blend.md) | Color operations and blending | Complete |
| [`texgen/pipeline.md`](texgen/pipeline.md) | Evaluation and caching | Complete |
| [`texgen/shaders.md`](texgen/shaders.md) | HLSL shader patterns | Complete |
| [`texgen/examples.md`](texgen/examples.md) | Clean Slate texture examples | Complete |

### Timeline System ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`timeline/overview.md`](timeline/overview.md) | Event types and architecture | Complete |
| [`timeline/events.md`](timeline/events.md) | 7 event types with render methods | Complete |
| [`timeline/sequencing.md`](timeline/sequencing.md) | Frame iteration and time mapping | Complete |
| [`timeline/render-targets.md`](timeline/render-targets.md) | RT management and viewports | Complete |
| [`timeline/examples.md`](timeline/examples.md) | Clean Slate timeline analysis | Complete |

### Spline Animation ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`spline/overview.md`](spline/overview.md) | Animation system architecture | Complete |
| [`spline/interpolation.md`](spline/interpolation.md) | 4 interpolation modes | Complete |
| [`spline/waveforms.md`](spline/waveforms.md) | 5 waveform modifiers | Complete |
| [`spline/integration.md`](spline/integration.md) | 57 spline types for materials/transforms | Complete |

### Arbaro Tree Generation ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`arbaro/overview.md`](arbaro/overview.md) | L-system architecture | Complete |
| [`arbaro/parameters.md`](arbaro/parameters.md) | 30+ tree parameters | Complete |
| [`arbaro/generation.md`](arbaro/generation.md) | Procedural algorithm | Complete |
| [`arbaro/shapes-taper.md`](arbaro/shapes-taper.md) | 9 shape types and taper | Complete |
| [`arbaro/mesh-output.md`](arbaro/mesh-output.md) | Mesh integration | Complete |

### Scene Graph ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`scene/overview.md`](scene/overview.md) | Object types and hierarchy | Complete |
| [`scene/objects.md`](scene/objects.md) | 12 object types | Complete |
| [`scene/rendering.md`](scene/rendering.md) | Matrix transforms and lights | Complete |
| [`scene/examples.md`](scene/examples.md) | Clean Slate scene analysis | Complete |

### Particle System ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`particles/overview.md`](particles/overview.md) | Emitter architecture | Complete |
| [`particles/emitters.md`](particles/emitters.md) | Spawn logic and parameters | Complete |
| [`particles/affectors.md`](particles/affectors.md) | 4 force types | Complete |
| [`particles/simulation.md`](particles/simulation.md) | Fixed timestep physics | Complete |

### Shader Reference ✓

| Document | Description | Status |
|----------|-------------|--------|
| [`shaders/index.md`](shaders/index.md) | Complete 71-shader inventory | Complete |

---

## Cross-References

Related demoscene projects:
- `notes/per-demoscene/fr_public/` — Farbrausch's Werkkzeug and V2 (predecessor technologies)

Related theme analyses:
- `notes/themes/node-graphs/` — Node-based authoring systems
- `notes/themes/rendering/` — GPU pipeline and resource management
- `notes/themes/systems/audio-synthesis.md` — Synth architecture comparison

---

## Key Contributors

- **BoyC** — Tool and engine code, Phoenix architecture
- **Gargaj** — MVX synthesizer code, WaveSabre integration
- **Zoom** — UI design, testing, UX feedback, primary user

---

## Third-Party Technologies

apEx builds on established demoscene technologies:

- **V2 Synthesizer** by Tammo "kb" Hinrichs (Farbrausch)
- **WaveSabre** by Jake "Ferris" Taylor (Logicoma)
- **.kkrunchy** by Fabian "ryg" Giesen (Farbrausch)
- **.rekkrunchy** by Ralph "revivalizer" Brorsen

Other dependencies include D3DX, JSON++, RapidXML, STB libraries, ASSIMP, Arbaro, OpenSSL, Miniz, NvTriStrip, and UE HLSL AST code.

---

## External Resources

- [Conspiracy official site](https://www.conspiracy.hu) — Group homepage
- [Conspiracy at Pouet](https://www.pouet.net/groups.php?which=50) — Production archive
- [apEx productions at Demozoo](https://demozoo.org/productions/tagged/apex/) — Full release list
- [Clean Slate (2023)](https://www.pouet.net/prod.php?which=92762) — Final production
- [Darkness Lay Your Eyes Upon Me (2021)](https://www.pouet.net/prod.php?which=88642) — Notable release

---

## License Note

apEx is released under a Creative Commons Non-Commercial (CC-NC) license, reflecting Conspiracy's intention to share knowledge within the demoscene community while preventing commercial exploitation. This differs from fr_public's public domain release but aligns with the spirit of collaborative learning in the scene.
