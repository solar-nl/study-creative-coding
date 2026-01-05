# webgpu-samples - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `package.json` |
| **Package Manager** | npm |
| **Build System** | Rollup |
| **Version** | 0.1.0 |

webgpu-samples is a collection of WebGPU examples demonstrating the API.

## Project Structure

```
webgpu-samples/
├── package.json
├── rollup.config.js
├── sample/
│   ├── helloTriangle/
│   ├── rotatingCube/
│   ├── texturedCube/
│   ├── computeBoids/
│   └── ...
└── src/
    └── [shared utilities]
```

## Dependencies by Category

### Runtime Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `@webgpu/types` | 0.1.61 | WebGPU TypeScript definitions |
| `wgpu-matrix` | 3.4.0 | WebGPU-optimized matrix math |
| `dat.gui` | 0.7.9 | GUI controls for demos |
| `stats.js` | varies | Performance monitoring |

### Code Editor (for WGSL editing)

| Dependency | Version | Purpose |
|------------|---------|---------|
| `@codemirror/state` | 6.x | Editor state |
| `@codemirror/view` | 6.x | Editor view |
| `@codemirror/lang-javascript` | 6.x | JS syntax |
| `@uiw/codemirror-theme-github` | varies | Theme |
| `@aspect-dev/codemirror-lang-wgsl` | varies | WGSL syntax |

### Utilities

| Dependency | Version | Purpose |
|------------|---------|---------|
| `showdown` | 2.1.0 | Markdown rendering |
| `teapot` | 1.0.0 | Utah teapot model |

### Build Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `rollup` | varies | Bundler |
| `typescript` | 5.8.3 | Type checking |
| `prettier` | varies | Formatting |
| `@rollup/plugin-node-resolve` | varies | Module resolution |
| `@rollup/plugin-typescript` | varies | TS compilation |

## WebGPU Types

The samples use WebGPU TypeScript definitions:

```typescript
// Types from @webgpu/types
declare global {
  interface Navigator {
    gpu: GPU;
  }
}

interface GPU {
  requestAdapter(): Promise<GPUAdapter | null>;
}

interface GPUAdapter {
  requestDevice(): Promise<GPUDevice>;
}

interface GPUDevice {
  createShaderModule(descriptor: GPUShaderModuleDescriptor): GPUShaderModule;
  createRenderPipeline(descriptor: GPURenderPipelineDescriptor): GPURenderPipeline;
  // ...
}
```

## Math Library: wgpu-matrix

Chosen for WebGPU compatibility:

```typescript
import { mat4, vec3 } from 'wgpu-matrix';

const projection = mat4.perspective(
  Math.PI / 4,  // fov
  aspect,       // aspect ratio
  0.1,          // near
  100           // far
);
```

Features:
- Column-major matrices (WebGPU default)
- Float32Array output (GPU-ready)
- No allocation in hot paths

## Sample Categories

| Category | Examples |
|----------|----------|
| **Basic** | helloTriangle, rotatingCube |
| **Textures** | texturedCube, cubemap |
| **Compute** | computeBoids, gameOfLife |
| **Advanced** | shadowMapping, deferredRendering |
| **Techniques** | particles, instancing |

## Dependency Philosophy

webgpu-samples follows:

1. **Minimal runtime** - Few dependencies
2. **Educational focus** - Clear, readable code
3. **wgpu-matrix for math** - WebGPU-optimized
4. **TypeScript** - Type safety for API learning
5. **Interactive** - dat.gui for parameter tweaking

## Browser Requirements

WebGPU requires modern browsers:

| Browser | Status |
|---------|--------|
| Chrome 113+ | Stable |
| Edge 113+ | Stable |
| Firefox | Nightly (flag) |
| Safari 17+ | Stable |

## Dependency Graph Notes

- **@webgpu/types is essential** - API definitions
- **wgpu-matrix over gl-matrix** - Better WebGPU fit
- **dat.gui for interaction** - Standard demo UI
- **CodeMirror for WGSL** - Shader editing in browser

## Key Files

- Package config: `frameworks/webgpu-samples/package.json`
- Build config: `frameworks/webgpu-samples/rollup.config.js`
- Sample structure: `frameworks/webgpu-samples/sample/`
