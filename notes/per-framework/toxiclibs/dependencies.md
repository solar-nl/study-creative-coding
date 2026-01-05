# toxiclibs - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | Ant build + source structure |
| **Package Manager** | None |
| **Build System** | Apache Ant |
| **Version** | 0021 |

toxiclibs is a **library**, not a framework - it provides computational geometry, physics, and utilities for Processing/Java.

## Project Structure

```
toxiclibs/
├── build.xml
├── src.core/           # Core utilities
├── src.color/          # Color theory
├── src.physics/        # Physics engine
├── src.data/           # Data structures
├── src.geom/           # Geometry primitives
├── src.math/           # Math utilities
├── src.audio/          # Audio (legacy)
├── src.image/          # Image processing
├── src.net/            # Networking
├── src.volume/         # Volumetric data
├── src.newmesh/        # Mesh generation
├── src.sim/            # Simulation
├── src.p5/             # Processing integration
└── lib/                # Runtime dependencies
```

## Dependencies by Category

### Runtime Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| `core.jar` | Processing core | For Processing mode |
| `joal.jar` | OpenAL audio | For audio module |
| `jogl.jar` | OpenGL | For rendering |

### Modules

toxiclibs is split into independent modules:

| Module | Purpose | Dependencies |
|--------|---------|--------------|
| **toxiclibscore** | Core utilities | None |
| **colorutils** | Color theory | toxiclibscore |
| **geomutils** | 2D/3D geometry | toxiclibscore |
| **volumeutils** | Volumetric/voxels | toxiclibscore |
| **verletphysics** | Physics engine | toxiclibscore |
| **datautils** | Data structures | toxiclibscore |
| **simutils** | Simulation | toxiclibscore |
| **audioutils** | Audio processing | toxiclibscore, JOAL |
| **imageutils** | Image processing | toxiclibscore |

## Key Classes

### Geometry (geomutils)

| Class | Purpose |
|-------|---------|
| `Vec2D`, `Vec3D` | Vector math |
| `Matrix4x4` | Transform matrices |
| `AABB` | Axis-aligned bounding box |
| `Sphere`, `Plane`, `Ray` | 3D primitives |
| `Polygon2D`, `Triangle3D` | Shape primitives |
| `TriangleMesh` | 3D mesh |

### Physics (verletphysics)

| Class | Purpose |
|-------|---------|
| `VerletPhysics2D`, `VerletPhysics3D` | Physics worlds |
| `VerletParticle` | Point mass |
| `VerletSpring` | Spring constraint |
| `AttractionBehavior` | Force fields |
| `GravityBehavior` | Gravity |

### Color (colorutils)

| Class | Purpose |
|-------|---------|
| `TColor` | Color representation |
| `ColorList` | Color palettes |
| `ColorGradient` | Gradient generation |
| `ColorTheme` | Themed palettes |
| `Hue` | Hue manipulation |

## Build Output

```
dist/
├── toxiclibscore.jar
├── colorutils.jar
├── geomutils.jar
├── volumeutils.jar
├── verletphysics.jar
├── datautils.jar
├── simutils.jar
├── audioutils.jar
└── imageutils.jar
```

## Usage Patterns

### Standalone Java
```java
import toxi.geom.*;
import toxi.physics2d.*;

Vec3D v = new Vec3D(1, 2, 3);
VerletPhysics2D physics = new VerletPhysics2D();
```

### With Processing
```java
import toxi.geom.*;
import toxi.processing.*;

ToxiclibsSupport gfx;

void setup() {
    gfx = new ToxiclibsSupport(this);
}

void draw() {
    gfx.mesh(myMesh);
}
```

## Dependency Philosophy

toxiclibs follows:

1. **Minimal dependencies** - Core has zero deps
2. **Modular JARs** - Only include what you need
3. **Processing-compatible** - But not Processing-dependent
4. **Pure Java** - No native code (except audio)
5. **Educational** - Clear, readable implementations

## Modern Alternatives

toxiclibs concepts have been adopted elsewhere:

| toxiclibs | Modern Alternative |
|-----------|-------------------|
| Vec2D/Vec3D | glm, nalgebra, Processing PVector |
| VerletPhysics | Box2D, Bullet, Rapier |
| TriangleMesh | Half-edge structures |
| ColorUtils | culori (JS), palette crates (Rust) |

## Dependency Graph Notes

- **Self-contained core** - toxiclibscore has no deps
- **Optional integration** - Processing support is separate
- **Legacy audio** - JOAL dependency is outdated
- **Influential design** - Many patterns copied elsewhere

## Key Files

- Build config: `frameworks/toxiclibs/build.xml`
- Core source: `frameworks/toxiclibs/src.core/`
- Geometry: `frameworks/toxiclibs/src.geom/`
- Physics: `frameworks/toxiclibs/src.physics/`
