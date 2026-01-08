# PixiJS Pipeline Caching

> Two-tier caching strategy for GPURenderPipeline reuse

---

## The Problem

Creating a `GPURenderPipeline` is expensive:
- Compiles shaders
- Validates state combinations
- Allocates GPU resources

PixiJS caches pipelines aggressively using composite state keys.

---

## Two-Tier Caching Strategy

PixiJS separates state into two categories:

### Tier 1: Global State (Changes Rarely)

```typescript
// Changes when render target or masking changes
function getGlobalStateKey(
    stencilStateId: number,   // 3 bits (0-7)
    multiSampleCount: number, // 1 bit (0-1)
    colorMask: number,        // 4 bits (0-15)
    renderTarget: number,     // 2 bits (0-3)
    colorTargetCount: number, // 2 bits (0-3)
): number {
    return (colorMask << 8)
         | (stencilStateId << 5)
         | (renderTarget << 3)
         | (colorTargetCount << 1)
         | multiSampleCount;
}
// Result: 12-bit key (4096 possible combinations)
```

### Tier 2: Graphics State (Changes Per Draw)

```typescript
// Changes with geometry, shader, blend mode
function getGraphicsStateKey(
    geometryLayout: number,   // 8 bits (0-255)
    shaderKey: number,        // 8 bits (0-255)
    state: number,            // 6 bits (0-63)
    blendMode: number,        // 5 bits (0-31)
    topology: number,         // 3 bits (0-7)
): number {
    return (geometryLayout << 24)
         | (shaderKey << 16)
         | (state << 10)
         | (blendMode << 5)
         | topology;
}
// Result: 30-bit key (many combinations)
```

---

## Cache Structure

```typescript
class PipelineSystem {
    // Tier 1: Global state → Tier 2 cache
    private _pipeStateCaches: Record<number, PipeHash> = {};

    // Tier 2: Current graphics state cache (pointer to one of the above)
    private _pipeCache: PipeHash = {};

    getPipeline(geometry, program, state, topology): GPURenderPipeline {
        const key = getGraphicsStateKey(
            geometry._layoutKey,
            program._layoutKey,
            state.data,
            state._blendModeId,
            topologyStringToId[topology]
        );

        // Check current tier 2 cache
        if (this._pipeCache[key]) {
            return this._pipeCache[key];
        }

        // Create and cache
        this._pipeCache[key] = this._createPipeline(geometry, program, state, topology);
        return this._pipeCache[key];
    }

    // Called when global state changes
    private _updatePipeHash() {
        const key = getGlobalStateKey(
            this._stencilMode,
            this._multisampleCount,
            this._colorMask,
            this._depthStencilAttachment,
            this._colorTargetCount
        );

        // Switch to appropriate tier 2 cache
        if (!this._pipeStateCaches[key]) {
            this._pipeStateCaches[key] = {};
        }
        this._pipeCache = this._pipeStateCaches[key];
    }
}
```

### Visualization

```
Global State Changes (setRenderTarget, setStencilMode, etc.)
    │
    ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Tier 1: Global State Caches                                         │
│                                                                      │
│  globalKey=0 ──► { graphicsKey → pipeline, graphicsKey → pipeline }  │
│  globalKey=1 ──► { graphicsKey → pipeline, graphicsKey → pipeline }  │
│  globalKey=2 ──► { graphicsKey → pipeline }                          │
│       ▲                                                              │
│       │                                                              │
│  _pipeCache points to current tier 2 cache                          │
└─────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
            getPipeline(geometry, program, state)
                    │
                    ▼
            Check _pipeCache[graphicsKey]
                    │
            ┌───────┴───────┐
            │               │
          Found           Not Found
            │               │
            ▼               ▼
          Return        Create Pipeline
                            │
                            ▼
                        Cache & Return
```

---

## Shader Module Caching

Shader modules are cached separately by source code:

```typescript
private _moduleCache: Record<string, GPUShaderModule> = {};

private _getModule(code: string): GPUShaderModule {
    return this._moduleCache[code] || this._createModule(code);
}

private _createModule(code: string): GPUShaderModule {
    this._moduleCache[code] = device.createShaderModule({ code });
    return this._moduleCache[code];
}
```

---

## Buffer Layout Caching

Vertex buffer layouts are cached by geometry + program combination:

```typescript
private _bufferLayoutsCache: Record<number, GPUVertexBufferLayout[]> = {};

private _createVertexBufferLayouts(geometry, program): GPUVertexBufferLayout[] {
    const key = (geometry._layoutKey << 16) | program._attributeLocationsKey;

    if (this._bufferLayoutsCache[key]) {
        return this._bufferLayoutsCache[key];
    }

    // Generate buffer layouts...
    const layouts = [];
    geometry.buffers.forEach((buffer) => {
        const layout = {
            arrayStride: 0,
            stepMode: 'vertex',
            attributes: [],
        };
        // ... populate from geometry attributes
        layouts.push(layout);
    });

    this._bufferLayoutsCache[key] = layouts;
    return layouts;
}
```

---

## Pipeline Creation

When no cached pipeline exists:

```typescript
private _createPipeline(geometry, program, state, topology): GPURenderPipeline {
    const descriptor: GPURenderPipelineDescriptor = {
        vertex: {
            module: this._getModule(program.vertex.source),
            entryPoint: program.vertex.entryPoint,
            buffers: this._createVertexBufferLayouts(geometry, program),
        },
        fragment: {
            module: this._getModule(program.fragment.source),
            entryPoint: program.fragment.entryPoint,
            targets: this._renderer.state.getColorTargets(state, this._colorTargetCount),
        },
        primitive: {
            topology,
            cullMode: state.cullMode,
        },
        layout: this._renderer.shader.getProgramData(program).pipeline,
        multisample: {
            count: this._multisampleCount,
        },
        label: 'PIXI Pipeline',
    };

    // Add depth/stencil if render target has it
    if (this._depthStencilAttachment) {
        descriptor.depthStencil = {
            ...this._stencilState,
            format: 'depth24plus-stencil8',
            depthWriteEnabled: state.depthTest,
            depthCompare: state.depthTest ? 'less' : 'always',
        };
    }

    return device.createRenderPipeline(descriptor);
}
```

---

## wgpu Implementation

```rust
use std::collections::HashMap;

struct PipelineCache {
    // Tier 1: global state → tier 2 cache
    global_caches: HashMap<u32, HashMap<u32, wgpu::RenderPipeline>>,
    // Current tier 2 cache
    current_cache: u32,
}

impl PipelineCache {
    fn get_pipeline(
        &mut self,
        device: &wgpu::Device,
        geometry: &Geometry,
        shader: &Shader,
        state: &State,
        topology: wgpu::PrimitiveTopology,
    ) -> &wgpu::RenderPipeline {
        let graphics_key = Self::graphics_key(geometry, shader, state, topology);

        let cache = self.global_caches
            .get_mut(&self.current_cache)
            .unwrap();

        cache.entry(graphics_key).or_insert_with(|| {
            Self::create_pipeline(device, geometry, shader, state, topology)
        })
    }

    fn set_global_state(&mut self, stencil: u8, msaa: u8, color_mask: u8, depth: u8) {
        let key = Self::global_key(stencil, msaa, color_mask, depth);

        if !self.global_caches.contains_key(&key) {
            self.global_caches.insert(key, HashMap::new());
        }

        self.current_cache = key;
    }

    fn graphics_key(geometry: &Geometry, shader: &Shader, state: &State, topology: wgpu::PrimitiveTopology) -> u32 {
        let topo_id = match topology {
            wgpu::PrimitiveTopology::PointList => 0,
            wgpu::PrimitiveTopology::LineList => 1,
            wgpu::PrimitiveTopology::LineStrip => 2,
            wgpu::PrimitiveTopology::TriangleList => 3,
            wgpu::PrimitiveTopology::TriangleStrip => 4,
        };

        (geometry.layout_key as u32) << 24
            | (shader.layout_key as u32) << 16
            | (state.data as u32) << 10
            | (state.blend_mode as u32) << 5
            | topo_id
    }

    fn global_key(stencil: u8, msaa: u8, color_mask: u8, depth: u8) -> u32 {
        ((color_mask as u32) << 8)
            | ((stencil as u32) << 5)
            | ((depth as u32) << 3)
            | (msaa as u32)
    }
}
```

---

## Key Bit Allocations

### Graphics State Key (30 bits)

| Field | Bits | Range | Purpose |
|-------|------|-------|---------|
| geometryLayout | 8 | 0-255 | Vertex buffer layout ID |
| shaderKey | 8 | 0-255 | Shader program ID |
| state | 6 | 0-63 | Render state flags |
| blendMode | 5 | 0-31 | Blend operation |
| topology | 3 | 0-7 | Primitive type |

### Global State Key (12 bits)

| Field | Bits | Range | Purpose |
|-------|------|-------|---------|
| colorMask | 4 | 0-15 | RGBA write mask |
| stencilStateId | 3 | 0-7 | Stencil operation |
| renderTarget | 2 | 0-3 | Depth/stencil config |
| colorTargetCount | 2 | 0-3 | MRT count |
| multiSampleCount | 1 | 0-1 | MSAA enabled |

---

## Performance Benefits

1. **Pipeline reuse** - Most frames reuse 100% of pipelines
2. **Fast lookup** - Integer key comparison, no string hashing
3. **Lazy creation** - Pipelines created on demand
4. **Memory efficient** - Separate caches prevent key collision

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/pipeline/PipelineSystem.ts`

---

*Next: [Encoder System](encoder-system.md)*
