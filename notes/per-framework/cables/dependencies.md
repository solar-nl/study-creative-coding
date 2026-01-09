# cables - Dependencies

## Overview

| Property | Value |
|----------|-------|
| **Dependency File** | `package.json` |
| **Package Manager** | npm |
| **Build System** | Webpack + Gulp |
| **Version** | varies (monorepo) |

cables.gl is a node-based visual programming environment for WebGL.

## Project Structure

```
cables/
├── package.json
├── webpack.config.js
├── gulpfile.js
├── src/
│   ├── core/            # Core engine
│   ├── libs/            # Shared libraries
│   └── ui/              # Editor UI
└── cables-shared-client/ # Shared client code
```

## Dependencies by Category

### Runtime Dependencies

| Dependency | Version | Purpose |
|------------|---------|---------|
| `@webgpu/types` | 0.1.53 | WebGPU TypeScript definitions |
| `cables-shared-client` | (local) | Shared client utilities |

### Build Dependencies

#### Bundling

| Dependency | Version | Purpose |
|------------|---------|---------|
| `webpack` | 5.91.0 | Module bundler |
| `webpack-cli` | varies | CLI tools |
| `webpack-bundle-analyzer` | 4.10.2 | Bundle analysis |
| `gulp` | 5.0.0 | Task automation |

#### Analysis

| Dependency | Version | Purpose |
|------------|---------|---------|
| `webpack-bundle-analyzer` | 4.10.2 | Size analysis |

## Graphics APIs

cables uses **native browser APIs**:

| Feature | API |
|---------|-----|
| Primary Renderer | WebGL 2.0 |
| Experimental | WebGPU |
| 2D Fallback | Canvas 2D |

## Node-Based Architecture

Unlike code-based frameworks, cables operates through:

1. **Operators (Ops)** - Visual nodes with inputs/outputs
2. **Patches** - Connected graphs of operators
3. **Core Engine** - Executes patches in real-time

## Operator Categories

| Category | Purpose |
|----------|---------|
| `Gl` | WebGL rendering ops |
| `Math` | Math operations |
| `Array` | Data manipulation |
| `String` | Text processing |
| `Audio` | Web Audio integration |
| `Video` | Video playback |
| `User` | Custom user ops |

## Dependency Philosophy

cables follows a **minimal core** approach:

1. **Browser-native rendering** - No graphics library deps
2. **TypeScript for WebGPU** - Only type definitions
3. **Heavy build tooling** - Complex development workflow
4. **Monorepo structure** - Internal package sharing

## WebGPU Support

cables is adding WebGPU support:

```typescript
// WebGPU types only for development
import type { GPUDevice, GPUTexture } from '@webgpu/types';
```

## Dependency Graph Notes

- **Minimal runtime** - Browser APIs only
- **Webpack-centric** - Complex bundling setup
- **Monorepo** - Shared code via internal packages
- **WebGPU experimental** - Types only, not runtime dep

## Key Files

- Package config: `visual-programming/cables/package.json`
- Webpack config: `visual-programming/cables/webpack.config.js`
