# [three.js](https://github.com/mrdoob/three.js) - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `package.json` |
| **Package Manager** | npm |
| **Build System** | Rollup |
| **Version** | 0.182.0 |

## Project Structure

```
threejs/
├── package.json
├── rollup.config.js
├── src/
│   ├── Three.js              # Main entry
│   ├── Three.WebGPU.js       # WebGPU entry
│   ├── animation/            # Animation system
│   ├── audio/                # 3D audio
│   ├── cameras/              # Camera types
│   ├── core/                 # Core classes
│   ├── geometries/           # Geometry primitives
│   ├── lights/               # Light types
│   ├── loaders/              # Asset loaders
│   ├── materials/            # Material system
│   ├── math/                 # Math utilities
│   ├── objects/              # Scene objects
│   ├── renderers/            # WebGL/WebGPU renderers
│   ├── scenes/               # Scene management
│   └── textures/             # Texture handling
├── examples/                 # Usage examples
│   └── jsm/                  # ES modules
└── build/                    # Built output
```

## Dependencies by Category

### Runtime Dependencies

Like p5.js, [three.js](https://github.com/mrdoob/three.js) has **zero runtime dependencies**:

| Dependency | Version | Purpose |
|------------|---------|---------|
| (none) | - | Browser APIs only |

### Build Dependencies (devDependencies)

#### Build Tools

| Dependency | Version | Purpose |
|------------|---------|---------|
| `rollup` | 4.6.0 | Module bundler |
| `@rollup/plugin-node-resolve` | varies | Module resolution |
| `terser` | 0.4.0 | Minification |
| `magic-string` | 0.30.0 | Source manipulation |

#### Documentation

| Dependency | Version | Purpose |
|------------|---------|---------|
| `jsdoc` | 4.0.5 | API documentation |

#### Testing

| Dependency | Version | Purpose |
|------------|---------|---------|
| `puppeteer` | 24.25.0 | Headless browser |
| `qunit` | 2.19.4 | Unit testing |
| `jpeg-js` | varies | JPEG testing |
| `pngjs` | 7.0.0 | PNG testing |

#### Linting

| Dependency | Version | Purpose |
|------------|---------|---------|
| `eslint` | 9.0.0 | Code linting |
| `eslint-config-mdcs` | 5.0.0 | Style config |

## Graphics APIs

[three.js](https://github.com/mrdoob/three.js) supports multiple rendering backends:

| Backend | Entry Point | Status |
|---------|-------------|--------|
| WebGL | `three.module.js` | Stable, default |
| WebGPU | `three.webgpu.js` | Experimental |

### WebGPU Features

[three.js](https://github.com/mrdoob/three.js) includes a **TSL (Three Shader Language)** for WebGPU:

```javascript
import * as THREE from 'three/webgpu';
import { tslFn, vec4 } from 'three/tsl';
```

## Module Exports

```json
{
  "exports": {
    ".": "./build/three.module.js",
    "./webgpu": "./build/three.webgpu.js",
    "./tsl": "./build/three.tsl.js",
    "./addons/*": "./examples/jsm/*"
  }
}
```

## Addons (examples/jsm)

[three.js](https://github.com/mrdoob/three.js) addons are **separate imports**, not bundled:

| Category | Examples |
|----------|----------|
| Controls | OrbitControls, FlyControls, PointerLockControls |
| Loaders | GLTFLoader, OBJLoader, FBXLoader, DRACOLoader |
| Post-processing | EffectComposer, RenderPass, ShaderPass |
| Physics | (external: cannon-es, ammo.js, rapier) |
| Utils | BufferGeometryUtils, SkeletonUtils |

## Dependency Philosophy

[three.js](https://github.com/mrdoob/three.js) follows **zero-dependency** approach:

1. **Self-contained core** - No runtime dependencies
2. **Tree-shakeable** - ES modules for dead code elimination
3. **Addons as separate files** - Don't bundle what you don't use
4. **External physics** - Physics engines are external choice

## Math Implementation

[three.js](https://github.com/mrdoob/three.js) has **custom math classes** (not a library):

| Class | Purpose |
|-------|---------|
| `Vector2/3/4` | Vector math |
| `Matrix3/4` | Matrix operations |
| `Quaternion` | Rotation |
| `Euler` | Euler angles |
| `Color` | Color math |
| `Box2/3` | Bounding boxes |
| `Sphere` | Bounding spheres |

## Dependency Graph Notes

- **Zero runtime deps** - Maximum portability
- **Addons are modular** - Import only what you need
- **WebGPU is separate build** - Different renderer architecture
- **Custom everything** - Even math is internal

## Key Files

- Package config: `frameworks/threejs/package.json`
- Rollup config: `frameworks/threejs/rollup.config.js`
- Main entry: `frameworks/threejs/src/Three.js`
