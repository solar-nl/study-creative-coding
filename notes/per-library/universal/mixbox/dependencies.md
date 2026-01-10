# [Mixbox](https://github.com/scrtwpns/[mixbox](https://github.com/scrtwpns/mixbox)) - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | Varies by language |
| **Package Managers** | Cargo, npm, pip, NuGet, Maven |
| **Build System** | Language-specific |
| **Version** | 2.0.0 |

[Mixbox](https://github.com/scrtwpns/[mixbox](https://github.com/scrtwpns/mixbox)) is designed to be **dependency-free** in most implementations.

## By Language

### Rust

```toml
# Cargo.toml
[dependencies]
mixbox = "2.0.0"
```

**Dependencies:** None (pure Rust)

### JavaScript/Node

```json
// package.json
{
  "dependencies": {
    "mixbox": "^2.0.0"
  }
}
```

Or via CDN:
```html
<script src="https://scrtwpns.com/mixbox.js"></script>
```

**Dependencies:** None

### Python

```bash
pip install pymixbox
```

**Dependencies:** None (pure Python)

### C#/.NET

```xml
<!-- NuGet -->
<PackageReference Include="Mixbox" Version="2.0.0" />
```

**Dependencies:** None

### Java

```groovy
// Gradle
implementation 'com.scrtwpns:mixbox:2.0.0'
```

**Dependencies:** None

### C/C++

No package manager - include source directly:

```
mixbox.h   # Header
mixbox.c   # Implementation
```

**Dependencies:** None

## Shader Dependencies

### GLSL

**Required:**
- `mixbox.glsl` - Shader include file
- `mixbox_lut.png` - LUT texture (must be bound)

```glsl
uniform sampler2D mixbox_lut;  // Texture unit 0 or custom
#include "mixbox.glsl"
```

### HLSL

**Required:**
- `mixbox.hlsl` - Shader include file
- `mixbox_lut.png` - LUT texture

```hlsl
Texture2D mixbox_lut : register(t0);
SamplerState mixbox_sampler : register(s0);
#include "mixbox.hlsl"
```

### Metal

**Required:**
- `mixbox.metal` - Shader include file
- `mixbox_lut.png` - LUT texture

## Game Engine Integration

### Unity

```
// Package Manager - Add git URL:
https://github.com/scrtwpns/mixbox.git#upm
```

**Dependencies:**
- Unity 2019.4+ (built-in render pipeline)
- Or URP/HDRP compatible

### Godot

Copy files to project:
```
mixbox.gd       # GDScript implementation
mixbox.gdshader # Shader implementation
mixbox_lut.png  # LUT texture
```

**Dependencies:** Godot 3.x or 4.x

## The LUT Texture

`mixbox_lut.png` is the **critical dependency** for GPU implementations:

| Property | Value |
|----------|-------|
| Format | PNG (RGB) |
| Size | 512×512 (typical) |
| Usage | Must be loaded and bound as texture |
| Filtering | Bilinear recommended |
| Wrap Mode | Clamp to edge |

**Loading example (OpenGL):**
```c
GLuint lut_texture;
glGenTextures(1, &lut_texture);
glBindTexture(GL_TEXTURE_2D, lut_texture);
// Load mixbox_lut.png...
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
```

## Dependency Philosophy

[Mixbox](https://github.com/scrtwpns/[mixbox](https://github.com/scrtwpns/mixbox)) follows a **zero-dependency** approach:

1. **Pure implementations** - No external libraries required
2. **Self-contained** - All code in single file per language
3. **LUT is data** - Not a code dependency, just a texture asset
4. **Cross-platform** - Same algorithm, no platform-specific deps

## File Sizes

| Component | Size |
|-----------|------|
| `mixbox.rs` | ~50 KB |
| `mixbox.js` | ~40 KB |
| `mixbox.glsl` | ~5 KB |
| `mixbox_lut.png` | ~200 KB |

The implementations are small because the LUT encodes the complex math.

## Integration Recommendations

### For Rust Framework

```toml
[dependencies]
mixbox = { version = "2.0.0", optional = true }

[features]
default = []
pigment-mixing = ["mixbox"]
```

### For Shader Pipeline

Bundle these files with your framework:
```
shaders/
├── includes/
│   └── mixbox.glsl
└── textures/
    └── mixbox_lut.png
```

## License Note

[Mixbox](https://github.com/scrtwpns/[mixbox](https://github.com/scrtwpns/mixbox)) uses **CC BY-NC 4.0** (non-commercial) by default.

For commercial use, a separate license is required from Secret Weapons (the creators).
