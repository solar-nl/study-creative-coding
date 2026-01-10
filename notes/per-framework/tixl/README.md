# tixl (Tooll3)

> An open-source, real-time motion graphics and creative coding framework.

## Key Insight

> **tixl's core idea:** A visual node graph where operators (Symbols) are instantiated at runtime (Instances) and communicate through typed data slots with dirty-flag tracking for efficient lazy evaluation.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | C# on .NET 9.0 |
| **Repository** | [tixl3d/tixl](https://github.com/tixl3d/tixl) |
| **Website** | [tixl.app](https://tixl.app) |
| **License** | MIT |
| **Platforms** | Windows, Linux, macOS (via Silk.NET) |
| **Rendering** | DirectX 11 (SharpDX) |
| **UI Framework** | Dear ImGui (via ImGui.NET) |
| **Windowing** | Silk.NET (cross-platform) |
| **Version** | 4.x (alpha) |

## Philosophy & Target Audience

tixl is a **node-based visual programming environment** for real-time motion graphics:

- **Graph-based composition** - Operators connected via typed slots
- **Real-time performance** - GPU-centric rendering with efficient dirty tracking
- **Audio-reactive** - Built-in support for audio input, OSC, MIDI
- **VJ-focused** - Timeline, animation curves, live performance features
- **Professional tooling** - Similar workflow to TouchDesigner, Nuke, or Fusion

**Target audience:** Motion graphics artists, VJs, creative coders who prefer visual node-based workflows over code-first approaches.

## Key Entry Points

| File | Purpose |
|------|---------|
| `Editor/Program.cs` | Main application entry point |
| `Core/Operator/Symbol.cs` | Operator definition (template) |
| `Core/Operator/Instance.cs` | Operator runtime instance |
| `Core/Operator/Slot/` | Input/output slot system |
| `Operators/Lib/` | Built-in operator library (890+ operators) |

## Architecture Overview

tixl uses a **Symbol-Instance-Slot** architecture:

```
Symbol (Definition)
    └── Instance (Runtime)
            ├── InputSlot<T>  ─┐
            ├── InputSlot<T>  ─┼── Slot System (Data Flow)
            └── Slot<T> (out) ─┘
```

- **Symbol**: The template/definition of an operator
- **Instance**: A runtime realization (multiple instances can share one symbol)
- **Slot**: Typed input/output connections with dirty flag tracking

## Key Technologies

| Component | Technology | Purpose |
|-----------|------------|---------|
| Graphics | SharpDX (DirectX 11) | GPU rendering, shaders |
| UI | ImGui.NET (Dear ImGui) | Node editor, parameter UI |
| Windowing | Silk.NET | Cross-platform window management |
| Audio | NAudio, ManagedBass | Audio input/analysis |
| Video | MediaFoundation, OpenCV | Video I/O and processing |
| Networking | NDI, OSC, MIDI | External control and video streaming |
| 3D Formats | SharpGLTF, OBJ loader | Scene/mesh import |

## Study Questions

- [x] How does tixl's architecture compare to nannou? → Very different: node-graph vs procedural code
- [x] What rendering backend does it use? → DirectX 11 via SharpDX
- [x] How is the API designed? → Attribute-based operator definition with typed slots
- [x] What patterns does it employ? → Symbol-Instance separation, CRTP generics, dirty flags
- [x] How does it handle 3D primitives? → SceneSetup with hierarchical nodes, MeshBuffers

## Comparison Notes

| Aspect | tixl | nannou |
|--------|------|--------|
| Language | C# | Rust |
| Paradigm | Node-based graph | Procedural code |
| Workflow | Visual editor | Code editor |
| Learning curve | Lower (visual) | Higher (code) |
| Flexibility | Constrained to operators | Unlimited (code) |
| Live coding | Excellent | Good |
| Cross-platform | Yes (Silk.NET) | Yes (wgpu) |
