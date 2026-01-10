# fr_public Architecture

> Module organization and key architectural patterns across the Farbrausch toolchain

---

## Overview

The fr_public repository contains multiple generations of demo tools spanning 2001-2014. The architecture evolved from simpler 64k intro frameworks (RG2) through the demo-focused Werkkzeug3 to the mature Altona/Werkkzeug4 framework.

This document focuses on the most mature codebase: **Altona + Werkkzeug4**.

---

## Altona Framework Architecture

Altona is a complete application framework comparable to SDL or openframeworks, providing platform abstraction, graphics, audio, GUI, and tooling.

### Module Structure

```
altona_wz4/altona/
├── main/
│   ├── base/           # Core platform abstraction
│   │   ├── types.hpp       # Fundamental types (sInt, sF32, sU32)
│   │   ├── system.hpp      # Platform detection, entry point
│   │   ├── graphics.hpp    # Graphics abstraction layer
│   │   ├── math.hpp        # Vector, matrix, color math
│   │   ├── sound.hpp       # Audio output
│   │   ├── serialize.hpp   # Binary serialization
│   │   └── windows.hpp     # Windowing (Win32, X11, iOS)
│   │
│   ├── gui/            # Immediate-mode GUI system
│   │   ├── gui.hpp         # Core widgets
│   │   ├── manager.hpp     # Layout and input handling
│   │   └── 3dwindow.hpp    # 3D viewport widget
│   │
│   ├── util/           # Utility modules
│   │   ├── image.hpp       # Image loading/saving
│   │   ├── mesh.hpp        # 3D mesh types
│   │   ├── anim.hpp        # Animation curves
│   │   └── shaders.hpp     # Shader compilation
│   │
│   ├── wz4lib/         # Werkkzeug4 core (GUI-less)
│   │   ├── doc.hpp         # Document model
│   │   ├── basic.hpp       # Basic operators
│   │   └── script.hpp      # Scripting system
│   │
│   ├── shadercomp/     # Runtime shader compiler
│   ├── network/        # Network utilities
│   └── wiki/           # Documentation generator
│
├── tools/
│   ├── makeproject/    # Build system generator
│   ├── asc/            # Altona Shader Compiler
│   └── wz4ops/         # Operator code generator
│
└── examples/           # Sample applications
```

### Graphics Abstraction

Altona provides a thin abstraction over DirectX 9, DirectX 11, OpenGL 2.0, and OpenGL ES 2.0:

```cpp
// graphics.hpp key abstractions
class sGeometry;          // Vertex/index buffers
class sTexture2D;         // 2D textures
class sTextureCube;       // Cube maps
class sMaterial;          // Shader + state
class sShader;            // Compiled shader program

// Rendering context
void sSetTarget(...);     // Set render target
void sSetRendertarget();  // Reset to backbuffer
void sEnableScissor();    // Scissor rectangle

// Platform-specific implementations:
// - graphics_dx9.cpp
// - graphics_dx11.cpp
// - graphics_ogl2.cpp
// - graphics_ogles2.cpp
```

### Entry Point Pattern

Altona uses a macro-based entry point that handles platform differences:

```cpp
// Application structure
class sApp : public sObject
{
public:
  void OnInit();          // Called once at startup
  void OnExit();          // Called on shutdown
  void OnPaint();         // Called each frame
  void OnInput(sInput2Event &ie);  // Input events
};

// Entry point macro
sDEFINE_APP(MyApp);
```

---

## Werkkzeug4 Operator System

The heart of Werkkzeug4 is its node-based operator graph. Operators are defined declaratively in `.ops` files and compiled into C++ by the `wz4ops` tool.

### Operator Definition

```
// Example from wz4frlib/chaosmesh_ops.ops
operator Wz4Mesh Multiply(Wz4Mesh in)
{
  parameter
  {
    int Count(1..1024 step 1 = 2);
    float31 TransS(-1024..1024 step 0.01 = 0);
    float31 TransR(-1024..1024 step 0.01 = 0);
    float31 TransT(-1024..1024 step 0.01 = 0);
  }
  code
  {
    out->CopyFrom(in);
    for(sInt i=1;i<para->Count;i++)
    {
      sMatrix34 mat;
      mat.Init();
      mat.EulerXYZ(para->TransR * i * sPI2F);
      mat.Scale(1.0f + para->TransS * i);
      mat.l = para->TransT * i;
      out->Transform(mat, in);
    }
  }
}
```

### Operator Types

Operators are organized by data type:

| Type | Description | File Pattern |
|------|-------------|--------------|
| `Wz4Mesh` | 3D mesh data | `*mesh*.ops` |
| `Wz4Render` | Render nodes | `*render*.ops` |
| `Wz4Channel` | Animation channels | `*channel*.ops` |
| `Wz4Particle` | Particle systems | `*particle*.ops` |
| `Texture2D` | 2D textures | `*tex*.ops` |
| `GenBitmap` | CPU bitmaps | `basic_ops.ops` |

### Operator Graph Execution

```
Document
  └── Pages (organizational)
        └── Operators (nodes)
              ├── Inputs (typed connections)
              ├── Parameters (UI controls)
              └── Cached output

Evaluation:
1. Request output from "root" operator
2. Recursively evaluate inputs (cached if clean)
3. Execute operator code
4. Cache result, mark as clean
5. Return to caller
```

---

## OpenKTG Architecture

The simplest and cleanest code in fr_public. A self-contained texture generator designed as a reference implementation.

### Module Structure

```
ktg/
├── gentexture.hpp    # Public API
├── gentexture.cpp    # Implementation (~37KB)
├── types.hpp         # Basic types (sInt, sF32, etc.)
├── demo.cpp          # Usage example
└── CMakeLists.txt    # CMake build
```

### Key Types

```cpp
// 16-bit per channel RGBA pixel (premultiplied alpha)
union Pixel {
  struct { sU16 r, g, b, a; };  // OpenGL byte order
  sU64 v;                        // Whole value for comparison

  void Lerp(sInt t, const Pixel &x, const Pixel &y);
  void CompositeROver(const Pixel &b);
};

// Texture with power-of-2 dimensions
struct GenTexture {
  Pixel *Data;
  sInt XRes, YRes;    // Must be power of 2
  sInt ShiftX, ShiftY; // log2(resolution)

  // Sampling with 1.7.24 fixed-point coordinates
  void SampleFiltered(Pixel &result, sInt x, sInt y, sInt mode) const;

  // Generators
  void Noise(params...);
  void GlowRect(params...);
  void Cells(params...);

  // Filters
  void ColorMatrixTransform(params...);
  void CoordMatrixTransform(params...);
  void Blur(params...);
  void Derive(params...);  // Gradient, normals

  // Compositing
  void Paste(params...);   // With blend modes
  void Bump(params...);    // Lighting
  void LinearCombine(params...);
};
```

### Filter Modes

```cpp
enum FilterMode {
  WrapU = 0,        ClampU = 1,      // U addressing
  WrapV = 0,        ClampV = 2,      // V addressing
  FilterNearest = 0, FilterBilinear = 4  // Sampling
};

// Combined as flags: WrapU | WrapV | FilterBilinear
```

---

## V2 Synthesizer Architecture

A complete virtual analog synthesizer capable of generating demo soundtracks in minimal code.

### Module Structure

```
v2/
├── synth.asm         # Core synthesis (x86 assembly, 175KB)
├── synth_core.cpp    # C++ port (partial, 83KB)
├── libv2.h           # Public C API
├── libv2/            # Static library build
│
├── sounddef.h        # Patch data structures
├── v2mplayer.cpp     # V2M file player
├── v2mconv.cpp       # V2M version converter
│
├── vsti/             # VST instrument plugin
├── tinyplayer/       # Minimal playback (for demos)
└── standalone/       # Standalone player app
```

### Synthesis Architecture

```
V2 Synthesizer
├── 16 Voices (polyphonic)
│   ├── 3 Oscillators
│   │   ├── Saw, Pulse, Noise
│   │   ├── FM synthesis
│   │   └── Sync
│   │
│   ├── 2 Filters
│   │   ├── 12/24dB LP/HP/BP
│   │   └── Modulation matrix
│   │
│   └── 2 LFOs + 2 Envelopes
│
├── Voice Bus → Effects Chain
│   ├── Distortion
│   ├── Chorus
│   ├── Compressor
│   └── Reverb
│
└── Global → Master Output
```

### Data Format

V2M files contain:
- Patch bank (instrument definitions)
- Sequence data (MIDI-like events)
- Global parameters (BPM, etc.)

The tinyplayer is designed for 64k intros with minimal footprint.

---

## Build System

Altona uses a custom build system generator called `makeproject`:

```bash
# Generate Visual Studio solutions
makeproject -r path_to_source

# Generates:
# - .sln solution files
# - .vcxproj project files
# Based on .mp.txt manifest files
```

### Shader Compilation

The ASC (Altona Shader Compiler) processes `.asc` files into platform shaders:

```
*.asc (shader source)
    ↓ ASC
*.hpp (embedded HLSL/GLSL)
    ↓ Build
Platform shaders
```

---

## Cross-Module Patterns

### Type System

All fr_public code uses consistent type aliases:

```cpp
// types.hpp (consistent across ktg, altona, v2)
typedef signed char sS8;
typedef unsigned char sU8;
typedef signed short sS16;
typedef unsigned short sU16;
typedef signed int sS32;
typedef unsigned int sU32;
typedef signed long long sS64;
typedef unsigned long long sU64;
typedef float sF32;
typedef double sF64;
typedef int sInt;     // Natural int size
typedef int sBool;    // Boolean
```

### Memory Management

Custom allocation through `sAlloc` / `sFree`:

```cpp
void *sAlloc(sInt size, sInt align);
void sFree(void *ptr);
template<class T> T *sAllocArray(sInt count);
```

### Error Handling

Assertions and fatal errors:

```cpp
sVERIFY(condition);           // Debug assertion
sVERIFYFALSE;                 // Always fails
sFatal("message");            // Fatal error
sLog("module", "message");    // Logging
```

---

## Architectural Takeaways

### For Creative Coding Framework Design

1. **Operator system** provides type-safe node graphs with declarative definition
2. **Lazy evaluation with caching** enables interactive editing of complex graphs
3. **Clean separation** between framework (Altona) and application (Wz4)
4. **Platform abstraction** keeps most code platform-independent
5. **Code generation** (wz4ops, asc) reduces boilerplate while maintaining type safety

### For Texture Generation

1. **16-bit per channel** prevents banding in procedural gradients
2. **Premultiplied alpha** simplifies compositing
3. **Fixed-point coordinates** enable exact pixel alignment
4. **Power-of-2 textures** allow efficient wrapping with bit operations

### For Audio Synthesis

1. **Compact data representation** enables full soundtrack in 64k
2. **Virtual analog** provides rich sound with minimal CPU
3. **Assembly core** achieves maximum efficiency (though portability suffers)
