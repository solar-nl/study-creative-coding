# Bind Groups: Packing Resources for the GPU

> Every shader needs resources - textures, buffers, samplers. Bind groups are how you bundle them for delivery.

---

## The Problem: Shaders Need Supplies

Picture a shader as a specialist craftsperson. To do their job, they need tools and materials: a texture to sample from, uniforms that describe the current transform, a sampler that controls filtering. But here's the catch - you can't just hand resources to a shader one by one. The GPU works in parallel, processing thousands of fragments simultaneously. Each one needs instant access to the same set of resources.

This is where bind groups come in. Think of them like a chef's mise en place - that French culinary term meaning "everything in its place." Before service begins, a chef arranges all ingredients and tools within arm's reach. No hunting through the pantry mid-dish. Bind groups work the same way: you bundle all the resources a shader needs into a single package, then hand over the entire package at once.

The challenge isn't just bundling - it's efficiency. Creating a `GPUBindGroup` involves GPU driver calls. If you create a new bind group every frame, or worse, every draw call, you're paying that cost repeatedly. PixiJS solves this with smart caching: create each unique combination once, then reuse it forever.

---

## The Mental Model: A Toolbox for Every Job

Here's a useful analogy. Imagine you're a contractor managing multiple job sites. Each job needs a specific set of tools - maybe a drill, a hammer, and a level for one site; a saw, clamps, and sandpaper for another.

The naive approach: pack a fresh toolbox for every job, every day. That's wasteful - you're constantly gathering the same tools.

The smart approach: pre-pack toolboxes for each job type. "Kitchen renovation" gets toolbox A. "Deck repair" gets toolbox B. When a job comes in, grab the matching toolbox off the shelf.

PixiJS implements exactly this pattern. Each unique combination of resources gets its own pre-packed bind group. The first time you need textures 3, 7, and 12 together, PixiJS creates that bind group. Every subsequent frame that needs the same combination? Cache hit. Instant reuse.

The key insight: bind groups are identified by their contents, not their usage. Two completely different sprites using the same texture get the same bind group.

---

## Two Layers of Management

PixiJS separates bind group handling into two distinct concerns:

```
┌─────────────────────────────────────────────────────────────────────┐
│  Layer 1: BindGroup Class                                           │
│  "What resources do I contain? What's my identity?"                 │
│                                                                     │
│  - Holds references to resources (textures, buffers, samplers)      │
│  - Generates a cache key from resource IDs                          │
│  - Listens for resource changes (dirty tracking)                    │
└─────────────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────────────┐
│  Layer 2: BindGroupSystem                                           │
│  "Has this combination been created before?"                        │
│                                                                     │
│  - Maps PixiJS resources to WebGPU resources                        │
│  - Creates GPUBindGroup objects on demand                           │
│  - Caches by the BindGroup's key                                    │
└─────────────────────────────────────────────────────────────────────┘
```

This separation matters. The `BindGroup` class is a lightweight descriptor - it knows what resources it contains but doesn't touch the GPU. The `BindGroupSystem` is the heavy lifter that actually creates GPU objects. This lets PixiJS defer expensive GPU calls until absolutely necessary.

---

## How Cache Keys Work

Here's where PixiJS gets clever. Every resource in the system has a unique ID. A bind group's identity is simply its resources' IDs joined together:

```
Cache key: "42|15|7|89"
            │   │  │  │
            │   │  │  └─ Sampler resource ID
            │   │  └──── Texture resource ID
            │   └─────── Uniform buffer ID
            └────────── Another buffer ID
```

This key generation is lazy - it only regenerates when resources change. The `BindGroup` class uses a dirty flag pattern:

```typescript
setResource(resource, index) {
    this._dirty = true;  // Mark for regeneration
}

_updateKey() {
    if (!this._dirty) return;  // Skip if unchanged
    this._dirty = false;
    this._key = /* regenerate from resource IDs */;
}
```

The string key approach works well for general bind groups, but PixiJS has a faster path for its most performance-critical case: texture batches.

---

## The Texture Batch Problem

PixiJS's batching system can render thousands of sprites in a single draw call by putting multiple textures in one bind group. The shader then selects the right texture based on a texture ID packed into each vertex. (See [Batching](batching.md) for the full batching strategy.)

But here's a performance wrinkle. Texture batches change constantly as sprites with different textures get grouped together. A batch might contain textures 3, 7, and 12 one frame, then 3, 8, and 15 the next. String key generation and comparison becomes a bottleneck when you're doing it hundreds of times per frame.

PixiJS's solution: FNV-1a hashing.

### What is FNV-1a?

FNV-1a (Fowler-Noll-Vo) is a non-cryptographic hash function designed for speed. It's embarrassingly simple:

```
hash = 2166136261          // Start with "offset basis"

for each value:
    hash = hash XOR value  // Mix in the value
    hash = hash * 16777619 // Scramble with "FNV prime"
```

That's it. Two operations per input. The magic numbers aren't arbitrary - they're carefully chosen to produce good distribution across the output space.

For texture batches, PixiJS hashes the texture UIDs:

```typescript
function getTextureBatchBindGroup(textures, size, maxTextures) {
    // FNV-1a hash of texture UIDs
    let uid = 2166136261;  // FNV offset basis

    for (let i = 0; i < size; i++) {
        uid ^= textures[i].uid;
        uid = Math.imul(uid, 16777619);  // FNV prime
        uid >>>= 0;  // Keep as unsigned 32-bit
    }

    return cachedGroups[uid] || generateTextureBatchBindGroup(...);
}
```

Why is this faster than string keys? Integer comparison is a single CPU instruction. The hash computation is a tight loop of XOR and multiply - operations that modern CPUs execute in single cycles. No string allocation, no garbage collection pressure.

### Why Not Just Use Array Index?

You might wonder: why hash at all? Why not just use the first texture's ID as the key?

The problem is combinatorics. Texture batches are defined by the combination of all their textures. [Texture 3, 7, 12] is different from [Texture 3, 7, 15]. Using just the first ID would cause cache collisions - different combinations would map to the same key, returning the wrong bind group.

The hash captures the entire combination in a single integer.

---

## Inside a Texture Batch Bind Group

When PixiJS creates a texture batch bind group, it follows a specific layout:

```
Bind Group 1 (Texture Batch):
├── Binding 0: Texture 0  ─┐
├── Binding 1: Sampler 0   │ Pair 0
├── Binding 2: Texture 1  ─┐
├── Binding 3: Sampler 1   │ Pair 1
├── Binding 4: Texture 2  ─┐
├── Binding 5: Sampler 2   │ Pair 2
└── ...
```

Textures and samplers are interleaved in pairs. This matches the shader's expectations - it can calculate the binding indices from the texture ID:

```wgsl
// In the shader
fn sample_batch(texture_id: u32, uv: vec2<f32>) -> vec4<f32> {
    switch texture_id {
        case 0u: { return textureSample(tex0, sam0, uv); }
        case 1u: { return textureSample(tex1, sam1, uv); }
        case 2u: { return textureSample(tex2, sam2, uv); }
        // ...
    }
}
```

### The Padding Requirement

WebGPU requires bind groups to match their layout exactly. If the layout declares 16 texture slots, you must fill all 16 - even if this batch only uses 3 textures.

PixiJS solves this by padding with empty textures:

```typescript
for (let i = 0; i < maxTextures; i++) {
    // Use real texture or pad with empty
    const texture = i < size ? textures[i] : Texture.EMPTY.source;

    bindGroupResources[bindIndex++] = texture.source;  // Texture
    bindGroupResources[bindIndex++] = texture.style;   // Sampler
}
```

This is why texture batches have a fixed `maxTextures` limit (typically 16). The layout is fixed, so all bind groups are interchangeable regardless of how many textures they actually use.

---

## Resource Change Detection

Resources can change. A texture might get replaced with a higher-resolution version. A uniform buffer might be updated with new transform data. When resources change, bind groups need to invalidate their cached keys.

PixiJS uses an event-based approach:

```typescript
setResource(resource, index) {
    const currentResource = this.resources[index];
    if (resource === currentResource) return;

    // Unsubscribe from old resource
    currentResource?.off?.('change', this.onResourceChange, this);

    // Subscribe to new resource
    resource.on?.('change', this.onResourceChange, this);

    this.resources[index] = resource;
    this._dirty = true;  // Invalidate key
}

onResourceChange(resource) {
    this._dirty = true;

    if (resource.destroyed) {
        // Clean up destroyed resources
        for (const i in this.resources) {
            if (this.resources[i] === resource) {
                this.resources[i] = null;
            }
        }
    } else {
        this._updateKey();
    }
}
```

This ensures the cache key always reflects current resource identities. When a resource changes its internal ID (perhaps because it was re-uploaded to the GPU), the bind group's key updates accordingly, and the next lookup will create a fresh `GPUBindGroup`.

---

## The Full Lookup Flow

Let's trace what happens when PixiJS needs a bind group for a draw call:

```
1. Renderer asks: "Give me a bind group for these resources"
                            │
                            ▼
2. BindGroup._updateKey()
   - Check dirty flag
   - If dirty: regenerate key from resource IDs
   - Result: "42|15|7|89"
                            │
                            ▼
3. BindGroupSystem.getBindGroup(bindGroup, program, groupIndex)
   - Look up bindGroup._key in cache
                            │
            ┌───────────────┴───────────────┐
            │                               │
       Cache Hit                       Cache Miss
            │                               │
            ▼                               ▼
    Return cached                   Create GPUBindGroup:
    GPUBindGroup                    - Map PixiJS resources to WebGPU
                                    - device.createBindGroup()
                                    - Store in cache
                                    - Return new bind group
```

The expensive path (cache miss) involves converting PixiJS resource types to their WebGPU equivalents:

| PixiJS Type | WebGPU Resource |
|-------------|-----------------|
| `uniformGroup` | `GPUBufferBinding` |
| `buffer` | `GPUBufferBinding` |
| `bufferResource` | `GPUBufferBinding` (with offset/size) |
| `textureSampler` | `GPUSampler` |
| `textureSource` | `GPUTextureView` |

---

## Garbage Collection Integration

Resources need to stay alive while they're being used, but should be collectible when no longer needed. PixiJS integrates bind groups with its garbage collection system through a "touch" mechanism:

```typescript
// Called when bind group is used
setBindGroup(index, bindGroup, program) {
    // ... cache lookup ...

    // Mark all resources as recently used
    bindGroup._touch(this._renderer.gc.now, this._renderer.tick);

    // ... set bind group ...
}
```

The `_touch` method updates timestamps on all contained resources:

```typescript
_touch(now, tick) {
    for (const i in this.resources) {
        this.resources[i]._gcLastUsed = now;
        this.resources[i]._touched = tick;
    }
}
```

This keeps resources alive while they're actively used, allowing the garbage collector to reclaim resources that haven't been touched for several frames.

---

## Common Gotchas

A few pitfalls that catch developers working with bind groups:

### Forgetting to Update After Resource Changes

When you swap a texture or buffer, the bind group's cached key becomes stale. PixiJS handles this automatically through event subscriptions, but if you're implementing your own system, remember: changing a resource's contents is different from changing which resource is bound. The former might not need a new bind group; the latter always does.

### Layout Mismatches

WebGPU is strict about bind group layouts matching pipeline layouts exactly. A bind group created for one pipeline won't work with another pipeline that expects different bindings - even if the actual resources would work fine. This manifests as cryptic validation errors. Always create bind groups against the same layout they'll be used with.

### Cache Miss Storms

The first frame of a new scene can be slow because every bind group is a cache miss. If you're loading a level with hundreds of unique texture combinations, consider warming the cache during a loading screen rather than taking the hit during gameplay.

### Hash Collisions in Texture Batches

FNV-1a is fast but not collision-free. Two different texture combinations can theoretically hash to the same value. In practice, this is rare enough that PixiJS doesn't check for it. If you're seeing mysterious texture glitches, collision is a possible (if unlikely) culprit.

---

## wgpu Equivalent

Here's how this pattern translates to Rust with wgpu. The core concepts remain identical - the main difference is Rust's ownership model requires more explicit lifetime management:

```rust
use std::collections::HashMap;

// Note: DEFAULT_TEXTURE and DEFAULT_SAMPLER must be defined elsewhere,
// typically as lazily-initialized static resources created at startup.
// They serve as padding for bind group slots that aren't actively used.

struct BindGroupCache {
    // General bind groups keyed by resource ID string
    cache: HashMap<String, wgpu::BindGroup>,
    // Texture batches keyed by FNV-1a hash
    texture_batch_cache: HashMap<u32, wgpu::BindGroup>,
}

impl BindGroupCache {
    /// FNV-1a hash for texture batch lookup
    fn fnv1a_hash(texture_ids: &[u32]) -> u32 {
        let mut hash = 2166136261u32;  // FNV offset basis

        for &id in texture_ids {
            hash ^= id;
            hash = hash.wrapping_mul(16777619);  // FNV prime
        }

        hash
    }

    /// Get or create texture batch bind group
    fn get_texture_batch(
        &mut self,
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        textures: &[&wgpu::TextureView],
        samplers: &[&wgpu::Sampler],
        max_textures: usize,
    ) -> &wgpu::BindGroup {
        // Compute hash from texture global IDs
        let ids: Vec<u32> = textures.iter()
            .map(|t| t.global_id().inner() as u32)
            .collect();
        let hash = Self::fnv1a_hash(&ids);

        self.texture_batch_cache.entry(hash).or_insert_with(|| {
            Self::create_texture_batch(device, layout, textures, samplers, max_textures)
        })
    }

    fn create_texture_batch(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        textures: &[&wgpu::TextureView],
        samplers: &[&wgpu::Sampler],
        max_textures: usize,
    ) -> wgpu::BindGroup {
        let mut entries = Vec::with_capacity(max_textures * 2);

        for i in 0..max_textures {
            // Pad with default if fewer textures than slots
            let tex = textures.get(i).copied().unwrap_or(&DEFAULT_TEXTURE);
            let sam = samplers.get(i).copied().unwrap_or(&DEFAULT_SAMPLER);

            // Interleaved: texture at 2i, sampler at 2i+1
            entries.push(wgpu::BindGroupEntry {
                binding: (i * 2) as u32,
                resource: wgpu::BindingResource::TextureView(tex),
            });
            entries.push(wgpu::BindGroupEntry {
                binding: (i * 2 + 1) as u32,
                resource: wgpu::BindingResource::Sampler(sam),
            });
        }

        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("texture_batch"),
            layout,
            entries: &entries,
        })
    }
}
```

The wgpu version is more explicit about resource lifetimes, but the caching strategy is identical: compute a key, check the cache, create on miss.

---

## Key Patterns Summary

### 1. Two-Level Architecture

Separate the "what" (BindGroup descriptor) from the "how" (BindGroupSystem creation). This enables lazy GPU object creation and cleaner resource management.

### 2. Identity-Based Caching

Resources have stable IDs. Bind groups derive their identity from their contents, not their usage context. This maximizes cache hits across unrelated draw calls.

### 3. FNV-1a for Hot Paths

String operations are expensive. For frequently-accessed caches (texture batches), integer hashing provides significant speedup.

### 4. Fixed Layout with Padding

Bind group layouts must match exactly. Pad unused slots with dummy resources to maintain layout compatibility across different actual resource counts.

### 5. Event-Driven Invalidation

Resources emit change events. Bind groups subscribe to their resources and invalidate their cached keys when contents change.

---

## Performance Characteristics

| Operation | Cost |
|-----------|------|
| Cache hit (string key) | O(1) hash + string comparison |
| Cache hit (FNV-1a) | O(n) texture count, integer comparison |
| Cache miss | Expensive: GPU driver call |
| Key regeneration | O(n) resource count |

The caching strategy ensures expensive GPU bind group creation happens once per unique resource combination. Typical scenes see near-100% cache hit rates after the first few frames.

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/BindGroupSystem.ts`
- `libraries/pixijs/src/rendering/renderers/gpu/shader/BindGroup.ts`
- `libraries/pixijs/src/rendering/batcher/gpu/getTextureBatchBindGroup.ts`

---

*Next: [Graphics API](graphics-api.md) - Canvas-like drawing with GPU acceleration*
