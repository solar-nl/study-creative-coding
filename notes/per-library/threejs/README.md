# three.js

> A JavaScript 3D library that makes WebGL easy.

## Quick Facts

| Property | Value |
|----------|-------|
| **Language** | JavaScript |
| **License** | MIT |
| **First Release** | 2010 |
| **Repository** | [mrdoob/three.js](https://github.com/mrdoob/three.js) |
| **Documentation** | [threejs.org/docs](https://threejs.org/docs/) |

## Philosophy & Target Audience

three.js abstracts WebGL complexity into a scene graph model. Key principles:

- **Retained-mode rendering**: Build a scene graph, renderer handles drawing
- **Object-oriented hierarchy**: Everything inherits from Object3D
- **Material/Geometry separation**: Decouple appearance from shape
- **Progressive complexity**: Simple defaults, deep customization available

Target audience: Web developers building 3D experiences, games, visualizations.

## Repository Structure

```
threejs/
├── src/
│   ├── Three.js           # Main entry (imports Three.Core.js)
│   ├── Three.Core.js      # Core API exports
│   ├── Three.WebGPU.js    # WebGPU renderer variant
│   ├── constants.js       # Global constants
│   ├── core/              # Object3D, BufferGeometry, Raycaster
│   ├── cameras/           # Camera types
│   ├── scenes/            # Scene, Fog
│   ├── renderers/         # WebGLRenderer, WebGPU, shaders
│   │   ├── webgl/         # 33 WebGL modules
│   │   ├── webgpu/        # WebGPU implementation
│   │   └── shaders/       # ShaderLib, UniformsLib
│   ├── objects/           # Mesh, Line, Points, Sprite
│   ├── materials/         # 22 material types
│   ├── geometries/        # 23 geometry types
│   ├── lights/            # Light types
│   ├── math/              # Vector, Matrix, Quaternion, Color
│   ├── animation/         # AnimationMixer, clips, tracks
│   ├── loaders/           # Asset loaders
│   ├── textures/          # Texture types
│   ├── audio/             # Web Audio integration
│   ├── helpers/           # Debug visualizers
│   └── nodes/             # Node-based materials (TSL)
├── build/                 # Distribution builds
└── examples/              # Extensive example collection
```

## Key Entry Points

Start reading here to understand the framework:

1. **`src/Three.Core.js`** — Core exports, shows API surface
2. **`src/core/Object3D.js`** — Base class for all scene objects
3. **`src/renderers/WebGLRenderer.js`** — Main rendering engine
4. **`src/scenes/Scene.js`** — Scene container
5. **`src/cameras/PerspectiveCamera.js`** — Most common camera

## Notable Patterns

- **Scene graph**: Hierarchical Object3D tree with transforms
- **Geometry + Material = Mesh**: Separation of shape and appearance
- **Render targets**: Off-screen rendering for post-processing
- **Shader chunks**: Modular GLSL building blocks

## Study Questions

- [ ] How does the scene graph traverse and render?
- [ ] How does WebGLRenderer batch draw calls?
- [ ] How does the material/shader compilation work?
- [ ] How does the geometry attribute system work?
- [ ] How does the new node-based material system (TSL) work?
- [ ] How is WebGPU support architected alongside WebGL?

## Related Documents

- [Architecture](./architecture.md)
- [Rendering Pipeline](./rendering-pipeline.md)
- [API Design](./api-design.md)
