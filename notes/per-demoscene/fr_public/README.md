# Farbrausch fr_public Study

> Werkkzeug demo tool, V2 synthesizer, .kkrieger, and procedural content generation (2001-2011)

---

## Why Study fr_public?

Farbrausch is one of the most influential demoscene groups, known for pushing the boundaries of real-time procedural content generation. Their fr_public repository, open-sourced in 2012, contains a decade of production tools including:

- **Werkkzeug** — Node-based demo authoring tool used for legendary productions like "fr-041: debris."
- **V2 synthesizer** — Compact software synthesizer capable of rich audio in minimal space
- **.kkrieger** — A complete first-person shooter in 96KB, achieved through procedural generation
- **kkrunchy** — Executable packer that achieves extreme compression ratios

This codebase represents hard-won knowledge about procedural content pipelines, node-based authoring systems, and size-constrained real-time graphics — all directly applicable to creative coding framework design.

### Relevance to Rust Framework

- **Procedural texture generation** (ktg, Werkkzeug) provides patterns for GPU-accelerated texture synthesis
- **Node-based operators** demonstrate type-safe visual programming with efficient evaluation
- **Real-time synthesis** (V2) shows audio DSP patterns applicable to audio-reactive visuals
- **Altona framework** provides a complete application framework comparable to openframeworks or nannou

---

## Key Areas to Study

### High Priority

- **altona_wz4/** — Modern framework + Werkkzeug4 demo tool
  - `altona/` — Base framework (graphics, sound, IO, GUI)
  - `wz4/` — Wz4FRlib demo operators and player

- **ktg/** — OpenKTG texture generator (cleanest code)
  - Reference implementation with clear semantics
  - 16-bit per channel, premultiplied alpha
  - Designed for shader/compute port

- **v2/** — V2 synthesizer system
  - Virtual analog synthesis engine
  - Compact representation for 64k intros
  - Used in kkrieger and debris

### Medium Priority

- **werkkzeug3_kkrieger/** — .kkrieger game source
  - Complete FPS in 96KB
  - Procedural meshes, textures, audio
  - Game mode with AI, physics, weapons

- **RG2/** — RauschGenerator 2
  - Earlier 64k intro framework
  - Simpler architecture than Werkkzeug3
  - Productions: flybye, dopplerdefekt, ein.schlag

### Lower Priority

- **kkrunchy/** — Executable packer
- **genthree/** — GenThree (Candytron era)
- **lekktor/** — Experimental tool
- **Altona2/** — Successor framework (incomplete)

**Source locations:**
- `demoscene/fr_public/altona_wz4/` — Modern framework and tool
- `demoscene/fr_public/ktg/` — Clean texture generator
- `demoscene/fr_public/v2/` — Synthesizer source
- `demoscene/fr_public/werkkzeug3_kkrieger/` — kkrieger branch

---

## Repository Structure

```
fr_public/
├── altona_wz4/           # Altona framework + Werkkzeug4
│   ├── altona/           # Framework libraries
│   │   ├── main/         # Core types, graphics, sound
│   │   ├── examples/     # Sample applications
│   │   ├── doc/          # Documentation
│   │   └── tools/        # Build tools (makeproject, asc)
│   ├── wz4/              # Werkkzeug4 demo ops and player
│   └── demos/            # Demo data files
│
├── Altona2/              # Successor framework (partial)
│
├── ktg/                  # OpenKTG texture generator
│   ├── gentexture.cpp    # Core texture operations
│   ├── gentexture.hpp    # Public API
│   ├── types.hpp         # Basic types
│   └── demo.cpp          # Usage example
│
├── v2/                   # V2 synthesizer
│   ├── synth.asm         # Core synth (assembly)
│   ├── synth_core.cpp    # C++ port (partial)
│   ├── libv2/            # Library interface
│   ├── vsti/             # VST plugin
│   └── tinyplayer/       # Minimal player
│
├── werkkzeug3/           # Werkkzeug3 (demos)
│   └── data/
│       ├── debris/       # fr-041: debris source
│       └── theta/        # fr-038: theta source
│
├── werkkzeug3_kkrieger/  # kkrieger branch
│
├── RG2/                  # RauschGenerator 2
│   ├── dopplerdefekt/    # fr-029 data
│   ├── einschlag/        # fr-022 data
│   ├── flybye/           # fr-013 data
│   └── welcome_to/       # fr-024 data
│
├── kkrunchy/             # Executable packer 0.23alpha
├── kkrunchy_k7/          # Improved packer
├── genthree/             # GenThree (Candytron)
└── lekktor/              # Experimental
```

---

## Comparison with Creative Coding Frameworks

| Aspect | fr_public (Werkkzeug4) | openframeworks | nannou |
|--------|------------------------|----------------|--------|
| Language | C++ | C++ | Rust |
| Paradigm | Node-based operators | Immediate mode | Immediate mode |
| Texture gen | Built-in procedural | Manual/shaders | Manual/shaders |
| Audio | V2 synthesizer | ofSoundPlayer | CPAL/dasp |
| GUI | Custom immediate | ofxGui/ImGui | egui/nannou_egui |
| Size focus | Extreme optimization | General purpose | General purpose |
| Era | 2001-2014 | 2005-present | 2018-present |

---

## Technical Highlights

### Altona Framework Architecture

- **Build system** — Custom `makeproject` generates VS solutions from annotations
- **Graphics** — DirectX 9/11 abstraction with shader compilation
- **Operators** — Type-safe node graph with lazy evaluation
- **GUI** — Immediate-mode custom widgets
- **Serialization** — Binary format for compact demos

### OpenKTG Texture Operations

- Generators: Flat, Perlin, Voronoi, Gradient
- Filters: Blur, Sharpen, Color transforms
- Compositing: Blend modes, masks
- Distortion: Rotozoom, Twirl, Warp
- All operations respect premultiplied alpha

### V2 Synthesizer

- 16 polyphonic voices
- Virtual analog oscillators (saw, pulse, noise, FM)
- Filters (12/24dB low/high/band pass)
- Modulation matrix
- Built-in effects (reverb, chorus, delay)
- Speech synthesis (Ronan module)

---

## Documentation Status

### Complete

| Document | Description |
|----------|-------------|
| `README.md` | Overview and study rationale (this file) |
| `architecture.md` | Altona/Wz4 module structure |
| `werkkzeug4/operator-system.md` | .ops DSL and C++ code generation |
| `werkkzeug4/graph-execution.md` | wOp → wCommand → GPU pipeline |
| `werkkzeug4/type-system.md` | Type hierarchy and automatic conversions |
| `patterns/node-graph-patterns.md` | Transferable patterns for Rust framework |
| `code-traces/ops-to-cpp.md` | Line-by-line trace of .ops compilation |
| `code-traces/graph-execution.md` | Trace of graph compilation and execution |
| `code-traces/graphics-abstraction.md` | Trace of sGeometry to draw calls |

### Planned

| Document | Description |
|----------|-------------|
| `texture-generation.md` | OpenKTG and Werkkzeug texture ops |
| `audio-synthesis.md` | V2 synthesizer deep dive |
| `altona/graphics-abstraction.md` | DX9/DX11/OpenGL backend comparison |

### Cross-References

- **Theme**: [Node Graph Systems](../../themes/node-graphs/node-graph-systems.md) — Comparison with cables.gl and tixl

---

## Key Contributors

- **Fabian "ryg" Giesen** — GenThree, kkrunchy, ktg, RG2, werkkzeug3, altona
- **Tammo "kb" Hinrichs** — V2 synthesizer, RG2, altona, werkkzeug4
- **Dierk "Chaos" Ohlerich** — GenThree, werkkzeug3, altona, werkkzeug4
- **Thomas "fiver2" Mahlke** — werkkzeug3, werkkzeug4, debris, kkrieger
- **Christoph "giZMo" Muetze** — genthree, RG2, werkkzeug3, debris, kkrieger

---

## External Resources

- [Farbrausch pouet page](https://www.pouet.net/groups.php?which=322) — Production archive
- [.werkkzeug4 blog](http://werkkzeug4.tumblr.com/) — Development notes (archived)
- [Breakpoint 2007 slides](https://fgiesen.wordpress.com/2012/04/08/metaprogramming-for-madmen/) — ryg on metaprogramming
- [Debris shader analysis](https://iquilezles.org/articles/debris/) — IQ's technical breakdown
