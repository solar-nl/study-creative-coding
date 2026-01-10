# Batching: Turning Thousands of Draw Calls into Dozens

> The postal sorting office principle applied to GPU rendering

## Key Insight

> **Batching's core idea:** Group sprites by compatible state (textures, blend mode, topology) and render them in one draw call, using per-vertex texture IDs so multiple textures can coexist in a single batch.

---

## The Problem: Death by a Thousand Draw Calls

Imagine a postal worker who delivers each letter individually. They walk to a house, deliver one letter, return to the post office, pick up the next letter, walk to a different house, return to the post office... This is absurd, obviously. Real postal systems sort mail by route first, then deliver entire bundles in sequence.

GPU rendering faces the same problem. Every draw call has overhead: the CPU must prepare parameters, communicate with the GPU driver, and wait for confirmation. A game with 10,000 sprites could naively issue 10,000 draw calls. At roughly 100 microseconds per call, that's a full second of overhead before any actual rendering happens. Your frame budget is gone.

The solution is the same as the postal system: sort and combine. Group sprites that can be drawn together, pack them into shared buffers, and issue one draw call for the whole bundle. This is batching.

---

## The Mental Model: A Shipping Consolidator

Think of the batcher as a shipping consolidator. Packages arrive throughout the day with different destinations, different shipping priorities, and different handling requirements. The consolidator groups compatible packages into containers before sending them to the loading dock.

The key insight is *compatibility*. Two packages can share a container if they:
- Go to the same general region (same texture atlas)
- Have the same priority (same blend mode)
- Need the same handling (same primitive topology)

The moment any of these differ, you need a new container. The consolidator's job is to maximize container utilization while respecting these constraints.

In PixiJS terms:
- **Packages** are sprites, graphics, and other renderable elements
- **Containers** are batches (single draw calls)
- **Loading dock** is the GPU command encoder

---

## What Triggers a Batch Break?

This is the critical question. Every batch break means another draw call, so you want to minimize them. PixiJS breaks batches when:

```
                    BATCH BREAK TRIGGERS

    1. Texture slots full
       The batch already has maxTextures bound, and this
       sprite needs a different texture.

    2. Blend mode changes
       Switching from "normal" to "additive" blending
       requires different GPU pipeline state.

    3. Topology changes
       Triangle lists can't mix with triangle strips
       in a single draw call.

    4. Non-batchable element encountered
       Filters, masks, and custom shaders break the flow
       and force the batch to flush.
```

Here's where it gets interesting: textures don't always break batches. PixiJS can bind multiple textures to a single draw call, up to the GPU's limit (typically 8-16). Each vertex stores which texture index it should sample from. Only when the batch runs out of texture slots does it need to break.

---

## How Batching Works: A Concrete Example

Let's trace what happens when you render a scene with 1,000 sprites using 4 different textures, all with normal blending:

**Phase 1: Collection**

During scene traversal, each sprite registers with the batcher:

```typescript
batcher.add(sprite) {
    // Record where this sprite's data will go
    sprite._indexStart = this.indexSize;
    sprite._attributeStart = this.attributeSize;

    // Accumulate sizes for buffer allocation
    this.indexSize += 6;      // Quad = 6 indices
    this.attributeSize += 4;  // Quad = 4 vertices
}
```

At this point, nothing is packed. The batcher just knows it needs space for 1,000 quads (6,000 indices, 4,000 vertices).

**Phase 2: Breaking into Batches**

Now the batcher walks through all elements and decides where to break:

```typescript
break() {
    let batch = new Batch();
    let textureCount = 0;
    let currentBlendMode = elements[0].blendMode;

    for (const element of elements) {
        const needNewBatch =
            textureCount >= maxTextures ||
            element.blendMode !== currentBlendMode;

        if (needNewBatch) {
            finishBatch(batch);        // Mark batch complete
            batch = new Batch();        // Start fresh
            textureCount = 0;
        }

        // Add texture if not already in this batch
        if (!batch.hasTexture(element.texture)) {
            batch.addTexture(element.texture);
            textureCount++;
        }

        // Pack vertex/index data
        packQuad(element, batch);
    }
}
```

With 4 textures fitting in one batch (assuming maxTextures >= 4), all 1,000 sprites end up in a single batch. One draw call for the entire scene.

**Phase 3: Execution**

When the batch executes, it:

1. Sets up geometry (one big vertex buffer, one big index buffer)
2. Binds all 4 textures into a single bind group
3. Issues one `drawIndexed(6000, 1, 0)` call

The shader selects the correct texture based on a per-vertex texture ID:

```wgsl
fn sample_batch(texture_id: u32, uv: vec2<f32>) -> vec4<f32> {
    switch texture_id {
        case 0u: { return textureSample(tex0, sam0, uv); }
        case 1u: { return textureSample(tex1, sam1, uv); }
        case 2u: { return textureSample(tex2, sam2, uv); }
        case 3u: { return textureSample(tex3, sam3, uv); }
        default: { return textureSample(tex0, sam0, uv); }
    }
}
```

---

## Texture Batch Bind Groups

Here's a clever optimization: bind groups for texture batches are cached using FNV-1a hashing.

The problem: bind group creation is expensive. Every unique combination of textures could require a new GPU bind group. But many frames use the exact same texture combinations.

The solution: hash the texture UIDs to create a cache key:

```typescript
function getTextureBatchBindGroup(textures: TextureSource[]) {
    // FNV-1a hash
    let hash = 2166136261;  // Magic offset basis
    for (const tex of textures) {
        hash ^= tex.uid;
        hash = Math.imul(hash, 16777619);  // Magic prime
    }

    return cache[hash] || createAndCache(textures, hash);
}
```

FNV-1a is chosen because it's fast (just XOR and multiply), produces good distribution for small inputs, and deterministic. The hash becomes the cache key, so identical texture combinations immediately hit the cache.

The bind group layout interleaves textures and samplers:

```
Bind Group 1 (Texture Batch):
    Binding 0: Texture 0
    Binding 1: Sampler 0
    Binding 2: Texture 1
    Binding 3: Sampler 1
    ...
    Binding 2n:   Texture n
    Binding 2n+1: Sampler n
```

When a batch has fewer textures than the maximum, empty slots are filled with a placeholder texture. This maintains a consistent layout so the same bind group can be reused regardless of actual texture count.

---

## The Vertex Format

Each batched vertex packs position, UV, color, and texture selection into 24 bytes:

```typescript
struct BatchedVertex {
    position: vec2<f32>,           // 8 bytes: screen position
    uv: vec2<f32>,                 // 8 bytes: texture coordinates
    color: vec4<u8> normalized,    // 4 bytes: tint color (RGBA)
    textureIdAndFlags: u32,        // 4 bytes: texture index + options
}
```

The `textureIdAndFlags` field is bit-packed: the high 16 bits store the texture index (which texture in the batch to sample), and the low bits store flags like "round to pixel" for crisp sprite rendering.

This tight packing matters. With 4,000 vertices per batch, the difference between 24 bytes and 32 bytes per vertex is 32KB of memory bandwidth saved per batch.

---

## Performance Characteristics

So how does this play out in practice?

**Best case**: All sprites use compatible textures, same blend mode, same topology.

Result: Thousands of sprites in a single draw call.

**Worst case**: Every sprite has a unique texture, different blend mode, or different topology.

Result: One draw call per sprite. No batching benefit.

**Typical case (well-optimized game)**:
- Background layer: 1 batch (texture atlas)
- Characters: 1-2 batches (sprite sheets)
- Particles: 1 batch (particle texture)
- UI: 1-2 batches

Result: 5-10 draw calls for scenes with thousands of sprites.

The key optimization insight: **use texture atlases**. Combining sprites into shared textures is the single most impactful thing you can do for batching performance.

---

## wgpu Implementation

Here's how the same pattern translates to Rust and wgpu:

```rust
struct Batcher {
    elements: Vec<BatchableElement>,
    batches: Vec<Batch>,

    // Shared geometry buffers
    vertices: Vec<BatchedVertex>,
    indices: Vec<u16>,

    max_textures: usize,
}

struct Batch {
    start: u32,           // Index offset
    size: u32,            // Index count
    textures: Vec<TextureId>,
    blend_mode: BlendMode,
    topology: wgpu::PrimitiveTopology,
    bind_group: Option<wgpu::BindGroup>,
}

impl Batcher {
    fn break_batches(&mut self, device: &wgpu::Device) {
        let mut current = Batch::new();

        for element in &self.elements {
            let needs_break =
                current.blend_mode != element.blend_mode ||
                current.topology != element.topology ||
                current.textures.len() >= self.max_textures;

            if needs_break && !current.is_empty() {
                self.finalize_batch(&mut current, device);
                self.batches.push(current);
                current = Batch::new();
            }

            let texture_id = current.add_texture(element.texture);
            self.pack_element(element, texture_id);
            current.size += element.index_count;
        }

        // Don't forget the last batch
        if !current.is_empty() {
            self.finalize_batch(&mut current, device);
            self.batches.push(current);
        }
    }
}
```

For texture batch bind group caching with FNV-1a:

```rust
struct BindGroupCache {
    cache: HashMap<u32, wgpu::BindGroup>,
}

impl BindGroupCache {
    fn get_texture_batch(
        &mut self,
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        textures: &[&wgpu::TextureView],
        samplers: &[&wgpu::Sampler],
    ) -> &wgpu::BindGroup {
        let hash = Self::fnv1a_hash(textures);

        self.cache.entry(hash).or_insert_with(|| {
            Self::create_texture_batch(device, layout, textures, samplers)
        })
    }

    fn fnv1a_hash(textures: &[&wgpu::TextureView]) -> u32 {
        // Note: texture identity extraction varies by wgpu version.
        // You may need to use a custom identifier or hash the texture
        // view's debug name depending on your setup.
        let mut hash = 2166136261u32;
        for tex in textures {
            let id = tex.global_id().inner() as u32;
            hash ^= id;
            hash = hash.wrapping_mul(16777619);
        }
        hash
    }
}
```

---

## Key Takeaways

1. **Batching is about compatibility** - Elements batch together when they share textures (up to a limit), blend mode, and topology. Design your assets with this in mind.

2. **Texture arrays enable multi-texture batches** - The shader selects textures by index, allowing many textures per draw call. This is why PixiJS can batch sprites with different textures.

3. **FNV-1a hashing for bind group caching** - Integer hashing is faster than string comparison for frequently-accessed texture batches. The hash of texture UIDs becomes the cache key.

4. **Lazy bind group creation** - Bind groups are created when batches execute, not when elements are added. This avoids creating bind groups for batches that get merged or discarded.

5. **Quad optimization matters** - Sprites are always quads (4 vertices, 6 indices). The batcher has a fast path for this common case, avoiding per-element size calculations.

6. **Pool pattern reduces allocation pressure** - Batch objects are pooled and reused frame-to-frame, avoiding allocation churn in the hot render path.

---

## Sources

- `libraries/pixijs/src/rendering/batcher/shared/Batcher.ts`
- `libraries/pixijs/src/rendering/batcher/gpu/GpuBatchAdaptor.ts`
- `libraries/pixijs/src/rendering/batcher/gpu/getTextureBatchBindGroup.ts`

---

*See also: [Bind Groups](bind-groups.md) for how texture batches are bound to shaders, [Pipeline Caching](pipeline-caching.md) for how blend mode and topology affect pipeline selection*
