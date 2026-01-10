# Demoscene Projects

> Analysis of demoscene tools, engines, and techniques for procedural content generation

---

## Overview

The demoscene is a computer art subculture that creates real-time audiovisual presentations ("demos") within strict size and resource constraints. Demoscene productions pioneered many techniques now common in creative coding: procedural texture and audio synthesis, node-based content authoring, extreme size optimization, and real-time graphics.

### Historical Context

Texture and audio synthesis techniques were pioneered by Dutch groups like The Black Lotus (TBL). Hardware-accelerated 64k intros were first achieved by Dutch groups Aardbei and Threestate. German group Farbrausch built on these foundations, creating influential tools like Werkkzeug and the V2 synthesizer, and notably open-sourced their entire toolchain in 2012.

### Relevance to Creative Coding

Demoscene techniques are highly relevant to creative coding framework design:

- **Procedural generation** reduces asset sizes and enables infinite variation
- **Node-based authoring** provides intuitive visual programming interfaces
- **Real-time synthesis** of textures and audio enables dynamic content
- **Size optimization** techniques inform efficient data representation
- **Performance constraints** drive innovative algorithm design

---

## Projects

| Project | Status | Description |
|---------|--------|-------------|
| [fr_public](./fr_public/) | Partial | Werkkzeug demo tool, V2 synthesizer, .kkrieger, procedural content (2001-2011) |

### Status Legend

- **Planned** — Submodule added, no documentation yet
- **Partial** — README exists, exploration incomplete
- **Complete** — Full documentation set

---

## Key Techniques

### Procedural Texture Generation

- Noise functions (Perlin, Simplex, Worley)
- Cellular automata
- Reaction-diffusion
- Layered composition with blend modes
- Filter chains (blur, sharpen, distort)

### Procedural Audio Synthesis

- Virtual analog synthesis (oscillators, filters, envelopes)
- FM synthesis
- Wavetable synthesis
- Real-time effects (reverb, delay, distortion)
- Tracker-style sequencing

### Size Optimization

- Executable packers (kkrunchy)
- Data compression (range coding, LZ variants)
- Code generation from data
- Shader-based procedural content
- Symbolic algebra for expression trees

### Node-Based Authoring

- Operator graphs with type-safe connections
- Lazy evaluation and caching
- Exportable operator trees for players
- Parameter animation over time

---

## Cross-References

Related theme analyses:

- `notes/themes/rendering/` — GPU pipeline techniques
- `notes/themes/core/architecture.md` — Framework architecture patterns

---

## Future Projects to Consider

| Project | Group | Notes |
|---------|-------|-------|
| GNU Rocket | Conspiracy | Sync tracker for demo timing |
| Werkzeug (XT) | XPLSV | Independent procedural tool |
| NoisePlug | Gargaj | Audio synthesis library |
