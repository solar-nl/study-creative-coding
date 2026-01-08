# PixiJS Batching Strategy

> How PixiJS minimizes draw calls through automatic batching

---

## Overview

PixiJS's batching system is one of its key performance features. It automatically combines multiple sprites/graphics into single draw calls based on:

1. **Texture compatibility** - Can textures fit in a single bind group?
2. **Blend mode** - Same blending operation?
3. **Topology** - Same primitive type (triangles, triangle-strip)?

---

## The Batch Class

A `Batch` represents a single draw call:

```typescript
// From Batcher.ts
class Batch implements Instruction {
    renderPipeId = 'batch';
    action: 'startBatch' | 'renderBatch';

    // Draw call parameters
    start: number;           // Index offset into index buffer
    size: number;            // Number of indices to draw

    // State
    textures: BatchTextureArray;  // Textures in this batch
    blendMode: BLEND_MODES;       // Blend operation
    topology: Topology;           // 'triangle-list', 'triangle-strip', etc.

    // WebGPU-specific (cached for performance)
    gpuBindGroup: GPUBindGroup;
    bindGroup: BindGroup;

    batcher: Batcher;
}
```

---

## BatchableElement Interface

Elements that can be batched implement this interface:

```typescript
interface BatchableElement {
    batcherName: string;     // Which batcher to use ("default")
    texture: Texture;        // Texture to render
    blendMode: BLEND_MODES;  // Blend operation
    indexSize: number;       // Number of indices
    attributeSize: number;   // Number of vertices
    topology: Topology;      // Primitive type
    packAsQuad: boolean;     // Optimization for rectangles

    // Internal tracking
    _textureId: number;      // Index in texture batch
    _attributeStart: number; // Offset in attribute buffer
    _indexStart: number;     // Offset in index buffer
    _batcher: Batcher;
    _batch: Batch;
}
```

### Quad Optimization

Sprites are always quads (4 vertices, 6 indices). PixiJS optimizes this:

```typescript
interface BatchableQuadElement extends BatchableElement {
    packAsQuad: true;
    attributeSize: 4;  // Always 4 vertices
    indexSize: 6;      // Always 6 indices (two triangles)
    bounds: BoundsData;
}
```

---

## The Batching Algorithm

### Phase 1: Element Collection

```typescript
// During scene traversal
batcher.add(element: BatchableElement) {
    this._elements[this.elementSize++] = element;

    // Track where this element's data will go
    element._indexStart = this.indexSize;
    element._attributeStart = this.attributeSize;
    element._batcher = this;

    // Accumulate sizes
    this.indexSize += element.indexSize;
    this.attributeSize += element.attributeSize * this.vertexSize;
}
```

### Phase 2: Break into Batches

The `break()` method is where batching decisions happen:

```typescript
break(instructionSet: InstructionSet) {
    const elements = this._elements;
    const maxTextures = this.maxTextures;

    let batch = getBatchFromPool();
    let textureBatch = batch.textures;
    let blendMode = firstElement.blendMode;
    let topology = firstElement.topology;

    for (let i = this.elementStart; i < this.elementSize; i++) {
        const element = elements[i];
        const source = element.texture._source;
        const adjustedBlendMode = getAdjustedBlendModeBlend(element.blendMode, source);

        // Check if we need to break the batch
        const breakRequired =
            blendMode !== adjustedBlendMode ||
            topology !== element.topology;

        // Check if texture already in this batch
        if (source._batchTick === BATCH_TICK && !breakRequired) {
            // Texture already bound - just pack data
            element._textureId = source._textureBindLocation;
            this.packData(element);
            continue;
        }

        // New texture - check if batch is full
        if (textureBatch.count >= maxTextures || breakRequired) {
            // BATCH BREAK - finish current batch
            this._finishBatch(batch, ...);

            // Start new batch
            batch = getBatchFromPool();
            textureBatch = batch.textures;
            blendMode = adjustedBlendMode;
            topology = element.topology;
            BATCH_TICK++;
        }

        // Add texture to batch
        element._textureId = textureBatch.count;
        source._textureBindLocation = textureBatch.count;
        textureBatch.textures[textureBatch.count++] = source;
        element._batch = batch;

        this.packData(element);
    }

    // Finish final batch
    if (textureBatch.count > 0) {
        this._finishBatch(batch, ...);
    }
}
```

### Batch Break Conditions

```
┌─────────────────────────────────────────────────────────────────────┐
│                      BATCH BREAK TRIGGERS                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  1. Texture count exceeds maxTextures                               │
│     └─► textureBatch.count >= maxTextures                           │
│                                                                      │
│  2. Blend mode changes                                              │
│     └─► blendMode !== adjustedBlendMode                             │
│                                                                      │
│  3. Topology changes                                                │
│     └─► topology !== element.topology                               │
│                                                                      │
│  4. Non-batchable element (filters, masks, custom shaders)          │
│     └─► Handled at pipe level, forces batch break                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## WebGPU Batch Execution

The `GpuBatchAdaptor` executes batches:

```typescript
// GpuBatchAdaptor.ts
class GpuBatchAdaptor implements BatcherAdaptor {

    start(batchPipe: BatcherPipe, geometry: Geometry, shader: Shader) {
        const renderer = batchPipe.renderer;
        const encoder = renderer.encoder;

        // Set geometry (vertex + index buffers)
        encoder.setGeometry(geometry, shader.gpuProgram);

        // Set global uniforms at bind group 0
        encoder.setBindGroup(0, renderer.globalUniforms.bindGroup, program);

        // Reset bind group 1 (texture batch)
        encoder.resetBindGroup(1);
    }

    execute(batchPipe: BatcherPipe, batch: Batch) {
        const renderer = batchPipe.renderer;
        const encoder = renderer.encoder;

        // Create/get texture bind group
        if (!batch.bindGroup) {
            batch.bindGroup = getTextureBatchBindGroup(
                batch.textures.textures,
                batch.textures.count,
                renderer.limits.maxBatchableTextures
            );
        }

        // Get cached GPU bind group
        const gpuBindGroup = renderer.bindGroup.getBindGroup(
            batch.bindGroup, program, 1
        );

        // Get/create pipeline for current state
        const pipeline = renderer.pipeline.getPipeline(
            this._geometry,
            program,
            { blendMode: batch.blendMode },
            batch.topology
        );

        // Execute draw call
        encoder.setPipeline(pipeline);
        encoder.renderPassEncoder.setBindGroup(1, gpuBindGroup);
        encoder.renderPassEncoder.drawIndexed(batch.size, 1, batch.start);
    }
}
```

---

## Texture Batch Bind Groups

PixiJS groups multiple textures into a single bind group using FNV-1a hashing:

```typescript
// getTextureBatchBindGroup.ts
const cachedGroups: Record<number, BindGroup> = {};

function getTextureBatchBindGroup(textures: TextureSource[], size: number, maxTextures: number) {
    // FNV-1a hash of texture UIDs
    let uid = 2166136261;  // FNV offset basis
    for (let i = 0; i < size; i++) {
        uid ^= textures[i].uid;
        uid = Math.imul(uid, 16777619);  // FNV prime
        uid >>>= 0;  // Convert to unsigned
    }

    return cachedGroups[uid] || generateTextureBatchBindGroup(textures, size, uid, maxTextures);
}

function generateTextureBatchBindGroup(textures, size, key, maxTextures) {
    const bindGroupResources = {};
    let bindIndex = 0;

    for (let i = 0; i < maxTextures; i++) {
        // Pad with empty textures if needed
        const texture = i < size ? textures[i] : Texture.EMPTY.source;

        bindGroupResources[bindIndex++] = texture.source;  // Texture
        bindGroupResources[bindIndex++] = texture.style;   // Sampler
    }

    const bindGroup = new BindGroup(bindGroupResources);
    cachedGroups[key] = bindGroup;
    return bindGroup;
}
```

### Bind Group Layout

```
Bind Group 1 (Texture Batch):
├── Binding 0: Texture 0
├── Binding 1: Sampler 0
├── Binding 2: Texture 1
├── Binding 3: Sampler 1
├── ...
├── Binding 2n:   Texture n
└── Binding 2n+1: Sampler n
```

---

## Vertex Format

Each vertex in the batch has this layout:

```typescript
// 24 bytes per vertex (6 × 4 bytes)
struct Vertex {
    aPosition: vec2<f32>,        // x, y (8 bytes)
    aUV: vec2<f32>,              // u, v (8 bytes)
    aColor: vec4<u8> normalized, // RGBA (4 bytes)
    aTextureIdAndRound: u16x2,   // texture index, round flag (4 bytes)
}
```

### Packing Quads

```typescript
packQuadAttributes(element, float32View, uint32View, index, textureId) {
    const { minX, minY, maxX, maxY } = element.bounds;
    const uvs = element.uvs;
    const color = element.color;
    const textureIdAndRound = (textureId << 16) | (element.roundPixels ? 1 : 0);

    // Vertex 0 (top-left)
    float32View[index + 0] = minX;
    float32View[index + 1] = minY;
    float32View[index + 2] = uvs.x0;
    float32View[index + 3] = uvs.y0;
    uint32View[index + 4] = color;
    uint32View[index + 5] = textureIdAndRound;

    // Vertex 1, 2, 3...
    // Similar pattern for other corners
}
```

---

## wgpu Implementation

### Rust Equivalent

```rust
struct Batcher {
    elements: Vec<BatchableElement>,
    attribute_buffer: Vec<u8>,
    index_buffer: Vec<u16>,
    batches: Vec<Batch>,
    max_textures: usize,
}

struct Batch {
    start: u32,
    size: u32,
    textures: Vec<TextureId>,
    blend_mode: BlendMode,
    topology: wgpu::PrimitiveTopology,
    bind_group: Option<wgpu::BindGroup>,
}

impl Batcher {
    fn break_batches(&mut self, device: &wgpu::Device) {
        let mut current_batch = Batch::new();
        let mut batch_tick = 0u32;

        for element in &self.elements {
            let needs_break =
                current_batch.blend_mode != element.blend_mode ||
                current_batch.topology != element.topology ||
                current_batch.textures.len() >= self.max_textures;

            if needs_break && !current_batch.is_empty() {
                self.finalize_batch(&mut current_batch, device);
                self.batches.push(current_batch);
                current_batch = Batch::new();
                batch_tick += 1;
            }

            // Add element to current batch
            let texture_id = current_batch.add_texture(element.texture);
            self.pack_element(element, texture_id);
            current_batch.size += element.index_count;
        }

        // Finalize last batch
        if !current_batch.is_empty() {
            self.finalize_batch(&mut current_batch, device);
            self.batches.push(current_batch);
        }
    }
}
```

### Texture Bind Group Caching

```rust
use std::collections::HashMap;

struct BindGroupCache {
    cache: HashMap<u32, wgpu::BindGroup>,
}

impl BindGroupCache {
    fn get_or_create(
        &mut self,
        textures: &[&wgpu::TextureView],
        samplers: &[&wgpu::Sampler],
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
    ) -> &wgpu::BindGroup {
        // FNV-1a hash
        let mut hash = 2166136261u32;
        for tex in textures {
            // Use texture view id or similar
            hash ^= tex.global_id().inner() as u32;
            hash = hash.wrapping_mul(16777619);
        }

        self.cache.entry(hash).or_insert_with(|| {
            let entries: Vec<_> = textures.iter().zip(samplers.iter())
                .enumerate()
                .flat_map(|(i, (tex, sampler))| {
                    vec![
                        wgpu::BindGroupEntry {
                            binding: (i * 2) as u32,
                            resource: wgpu::BindingResource::TextureView(tex),
                        },
                        wgpu::BindGroupEntry {
                            binding: (i * 2 + 1) as u32,
                            resource: wgpu::BindingResource::Sampler(sampler),
                        },
                    ]
                })
                .collect();

            device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("texture_batch"),
                layout,
                entries: &entries,
            })
        })
    }
}
```

---

## Performance Characteristics

### Best Case

All elements use:
- Same texture (or textures fit in one batch)
- Same blend mode
- Same topology

**Result:** 1 draw call for entire scene

### Worst Case

Every element has:
- Different texture
- Different blend mode
- Different topology

**Result:** N draw calls for N elements (no batching benefit)

### Typical Case

Sprites grouped by texture atlas + blend mode:
- Background sprites: 1 batch
- Character sprites: 1 batch
- UI elements: 1-2 batches
- Particles: 1 batch

**Result:** 5-10 draw calls for thousands of sprites

---

## Key Takeaways

1. **Texture batching via bind groups** - Multiple textures per draw call using array indexing in shader

2. **FNV-1a hashing** - Fast cache key generation for bind group reuse

3. **Lazy bind group creation** - Only create when batch is executed, not when elements are added

4. **Quad optimization** - Special fast path for 4-vertex rectangles

5. **State-based batching** - Blend mode and topology changes break batches

6. **Pool pattern** - Batch objects are pooled to avoid allocation

---

## Sources

- `libraries/pixijs/src/rendering/batcher/shared/Batcher.ts`
- `libraries/pixijs/src/rendering/batcher/gpu/GpuBatchAdaptor.ts`
- `libraries/pixijs/src/rendering/batcher/gpu/getTextureBatchBindGroup.ts`

---

*Next: [Pipeline Caching](pipeline-caching.md)*
