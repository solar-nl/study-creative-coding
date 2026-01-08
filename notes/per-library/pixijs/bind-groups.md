# PixiJS Bind Group Management

> Resource binding with key-based caching and FNV-1a hashing

---

## Overview

PixiJS has two layers of bind group management:

1. **BindGroup class** - Wraps resources, generates cache keys from resource IDs
2. **BindGroupSystem** - Creates and caches actual `GPUBindGroup` objects
3. **Texture batch optimization** - FNV-1a hash for fast texture batch lookups

---

## The BindGroup Class

`BindGroup` is a container for shader resources that generates cache keys:

```typescript
class BindGroup {
    // Resources indexed by binding number
    resources: Record<string, BindResource> = {};

    // Cache key generated from resource IDs
    _key: string;
    private _dirty = true;

    constructor(resources?: Record<string, BindResource>) {
        let index = 0;
        for (const i in resources) {
            this.setResource(resources[i], index++);
        }
        this._updateKey();
    }

    _updateKey(): void {
        if (!this._dirty) return;
        this._dirty = false;

        const keyParts = [];
        let index = 0;

        for (const i in this.resources) {
            keyParts[index++] = this.resources[i]._resourceId;
        }

        this._key = keyParts.join('|');
    }
}
```

### Key Generation

The key is built from resource IDs joined by `|`:

```
Example key: "42|15|7|89"
             │   │  │  │
             │   │  │  └─ Sampler resource ID
             │   │  └──── Texture resource ID
             │   └─────── Uniform buffer ID
             └────────── Another buffer ID
```

### Resource Change Detection

BindGroup listens for changes on its resources:

```typescript
setResource(resource: BindResource, index: number): void {
    const currentResource = this.resources[index];
    if (resource === currentResource) return;

    // Remove old listener
    if (currentResource) {
        resource.off?.('change', this.onResourceChange, this);
    }

    // Add new listener
    resource.on?.('change', this.onResourceChange, this);

    this.resources[index] = resource;
    this._dirty = true;  // Mark for key regeneration
}

onResourceChange(resource: BindResource) {
    this._dirty = true;

    if (resource.destroyed) {
        // Remove destroyed resources
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

---

## BindGroupSystem

The system creates and caches `GPUBindGroup` objects:

```typescript
class BindGroupSystem {
    private _hash: Record<string, GPUBindGroup> = {};

    getBindGroup(bindGroup: BindGroup, program: GpuProgram, groupIndex: number): GPUBindGroup {
        bindGroup._updateKey();  // Ensure key is current

        return this._hash[bindGroup._key] || this._createBindGroup(bindGroup, program, groupIndex);
    }

    private _createBindGroup(group: BindGroup, program: GpuProgram, groupIndex: number): GPUBindGroup {
        const device = this._gpu.device;
        const groupLayout = program.layout[groupIndex];
        const entries: GPUBindGroupEntry[] = [];

        for (const j in groupLayout) {
            const resource = group.resources[j] ?? group.resources[groupLayout[j]];
            let gpuResource: GPUSampler | GPUTextureView | GPUBufferBinding;

            // Convert PixiJS resources to WebGPU resources
            if (resource._resourceType === 'uniformGroup') {
                const uniformGroup = resource as UniformGroup;
                this._renderer.ubo.updateUniformGroup(uniformGroup);
                const buffer = uniformGroup.buffer;

                gpuResource = {
                    buffer: this._renderer.buffer.getGPUBuffer(buffer),
                    offset: 0,
                    size: buffer.descriptor.size,
                };
            }
            else if (resource._resourceType === 'buffer') {
                const buffer = resource as Buffer;
                gpuResource = {
                    buffer: this._renderer.buffer.getGPUBuffer(buffer),
                    offset: 0,
                    size: buffer.descriptor.size,
                };
            }
            else if (resource._resourceType === 'bufferResource') {
                const bufferResource = resource as BufferResource;
                gpuResource = {
                    buffer: this._renderer.buffer.getGPUBuffer(bufferResource.buffer),
                    offset: bufferResource.offset,
                    size: bufferResource.size,
                };
            }
            else if (resource._resourceType === 'textureSampler') {
                gpuResource = this._renderer.texture.getGpuSampler(resource as TextureStyle);
            }
            else if (resource._resourceType === 'textureSource') {
                gpuResource = this._renderer.texture.getGpuSource(resource as TextureSource).createView();
            }

            entries.push({
                binding: groupLayout[j],
                resource: gpuResource,
            });
        }

        const layout = this._renderer.shader.getProgramData(program).bindGroups[groupIndex];

        const gpuBindGroup = device.createBindGroup({ layout, entries });
        this._hash[group._key] = gpuBindGroup;

        return gpuBindGroup;
    }
}
```

### Resource Type Mapping

| PixiJS Type | WebGPU Resource |
|-------------|-----------------|
| `uniformGroup` | `GPUBufferBinding` |
| `buffer` | `GPUBufferBinding` |
| `bufferResource` | `GPUBufferBinding` (with offset/size) |
| `textureSampler` | `GPUSampler` |
| `textureSource` | `GPUTextureView` |

---

## Texture Batch Bind Groups

For batched sprite rendering, PixiJS uses a specialized approach with FNV-1a hashing:

```typescript
const cachedGroups: Record<number, BindGroup> = {};

function getTextureBatchBindGroup(
    textures: TextureSource[],
    size: number,
    maxTextures: number
): BindGroup {
    // FNV-1a hash of texture UIDs
    let uid = 2166136261;  // FNV offset basis

    for (let i = 0; i < size; i++) {
        uid ^= textures[i].uid;
        uid = Math.imul(uid, 16777619);  // FNV prime
        uid >>>= 0;  // Convert to unsigned 32-bit
    }

    return cachedGroups[uid] || generateTextureBatchBindGroup(textures, size, uid, maxTextures);
}

function generateTextureBatchBindGroup(
    textures: TextureSource[],
    size: number,
    key: number,
    maxTextures: number
): BindGroup {
    const bindGroupResources: Record<string, any> = {};
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

### FNV-1a Algorithm

FNV-1a (Fowler–Noll–Vo) is a fast, non-cryptographic hash:

```
hash = FNV_offset_basis (2166136261 for 32-bit)

for each byte:
    hash = hash XOR byte
    hash = hash × FNV_prime (16777619 for 32-bit)
```

Properties:
- **Fast**: Simple XOR and multiply operations
- **Low collision**: Good distribution for small inputs
- **Deterministic**: Same inputs always produce same hash

### Bind Group Layout

Texture batches interleave textures and samplers:

```
Bind Group 1 (Texture Batch):
├── Binding 0: Texture 0    ─┐
├── Binding 1: Sampler 0     │ Pair 0
├── Binding 2: Texture 1    ─┐
├── Binding 3: Sampler 1     │ Pair 1
├── ...
├── Binding 2n:   Texture n ─┐
└── Binding 2n+1: Sampler n  │ Pair n
```

This allows the shader to select textures by ID:

```wgsl
@group(1) @binding(0) var tex0: texture_2d<f32>;
@group(1) @binding(1) var sam0: sampler;
@group(1) @binding(2) var tex1: texture_2d<f32>;
@group(1) @binding(3) var sam1: sampler;
// ...

fn sample_batch(texture_id: u32, uv: vec2<f32>) -> vec4<f32> {
    switch texture_id {
        case 0u: { return textureSample(tex0, sam0, uv); }
        case 1u: { return textureSample(tex1, sam1, uv); }
        // ...
    }
}
```

---

## Garbage Collection Integration

BindGroups are tracked for GC via the `_touch` method:

```typescript
class BindGroup {
    _touch(now: number, tick: number): void {
        const resources = this.resources;

        for (const i in resources) {
            (resources[i] as BindResource & GCable)._gcLastUsed = now;
            resources[i]._touched = tick;
        }
    }
}

// Called when bind group is used
setBindGroup(index: number, bindGroup: BindGroup, program: GpuProgram) {
    // ... cache check ...

    bindGroup._touch(this._renderer.gc.now, this._renderer.tick);

    // ... set bind group ...
}
```

This keeps resources alive while they're being used, allowing unused resources to be collected.

---

## wgpu Implementation

```rust
use std::collections::HashMap;

struct BindGroupCache {
    cache: HashMap<String, wgpu::BindGroup>,
    texture_batch_cache: HashMap<u32, wgpu::BindGroup>,
}

impl BindGroupCache {
    /// Get or create a bind group from resources
    fn get_bind_group(
        &mut self,
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        resources: &[BindResource],
    ) -> &wgpu::BindGroup {
        let key = Self::compute_key(resources);

        self.cache.entry(key).or_insert_with(|| {
            Self::create_bind_group(device, layout, resources)
        })
    }

    /// Compute cache key from resource IDs
    fn compute_key(resources: &[BindResource]) -> String {
        resources.iter()
            .map(|r| r.id().to_string())
            .collect::<Vec<_>>()
            .join("|")
    }

    /// Get or create texture batch bind group using FNV-1a
    fn get_texture_batch(
        &mut self,
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        textures: &[&wgpu::TextureView],
        samplers: &[&wgpu::Sampler],
        max_textures: usize,
    ) -> &wgpu::BindGroup {
        let hash = Self::fnv1a_hash(textures);

        self.texture_batch_cache.entry(hash).or_insert_with(|| {
            Self::create_texture_batch(device, layout, textures, samplers, max_textures)
        })
    }

    /// FNV-1a hash of texture IDs
    fn fnv1a_hash(textures: &[&wgpu::TextureView]) -> u32 {
        let mut hash = 2166136261u32;  // FNV offset basis

        for tex in textures {
            // Use global_id or similar identifier
            let id = tex.global_id().inner() as u32;
            hash ^= id;
            hash = hash.wrapping_mul(16777619);  // FNV prime
        }

        hash
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
            // Pad with default texture/sampler if needed
            let tex = textures.get(i).copied().unwrap_or(&DEFAULT_TEXTURE);
            let sam = samplers.get(i).copied().unwrap_or(&DEFAULT_SAMPLER);

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

    fn create_bind_group(
        device: &wgpu::Device,
        layout: &wgpu::BindGroupLayout,
        resources: &[BindResource],
    ) -> wgpu::BindGroup {
        let entries: Vec<_> = resources.iter().enumerate()
            .map(|(i, resource)| wgpu::BindGroupEntry {
                binding: i as u32,
                resource: resource.as_wgpu_resource(),
            })
            .collect();

        device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout,
            entries: &entries,
        })
    }
}

/// Resource types that can be bound
enum BindResource {
    UniformBuffer { buffer: wgpu::Buffer, size: u64 },
    StorageBuffer { buffer: wgpu::Buffer, size: u64 },
    Texture(wgpu::TextureView),
    Sampler(wgpu::Sampler),
}

impl BindResource {
    fn id(&self) -> u64 {
        match self {
            BindResource::UniformBuffer { buffer, .. } => buffer.global_id().inner(),
            BindResource::StorageBuffer { buffer, .. } => buffer.global_id().inner(),
            BindResource::Texture(view) => view.global_id().inner(),
            BindResource::Sampler(sampler) => sampler.global_id().inner(),
        }
    }

    fn as_wgpu_resource(&self) -> wgpu::BindingResource {
        match self {
            BindResource::UniformBuffer { buffer, size } => {
                wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                    buffer,
                    offset: 0,
                    size: std::num::NonZeroU64::new(*size),
                })
            }
            BindResource::StorageBuffer { buffer, size } => {
                wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                    buffer,
                    offset: 0,
                    size: std::num::NonZeroU64::new(*size),
                })
            }
            BindResource::Texture(view) => {
                wgpu::BindingResource::TextureView(view)
            }
            BindResource::Sampler(sampler) => {
                wgpu::BindingResource::Sampler(sampler)
            }
        }
    }
}
```

---

## Key Patterns

### 1. Two-Level Caching

```
BindGroup._key (string)  →  BindGroupSystem cache  →  GPUBindGroup
     ↑
     │
Resource IDs joined by '|'
```

### 2. Dirty Flag for Lazy Updates

```typescript
setResource(resource, index) {
    this._dirty = true;  // Mark for key regeneration
}

_updateKey() {
    if (!this._dirty) return;  // Skip if unchanged
    this._dirty = false;
    // ... regenerate key ...
}
```

### 3. FNV-1a for Texture Batches

Integer hashing is faster than string comparison for frequently-accessed texture batches.

### 4. Padding for Fixed Layouts

Texture batches pad with empty textures to maintain consistent bind group layouts:

```typescript
const texture = i < size ? textures[i] : Texture.EMPTY.source;
```

---

## Performance Characteristics

| Operation | Cost |
|-----------|------|
| Key lookup (cache hit) | O(1) string hash |
| FNV-1a lookup (texture batch) | O(n) texture count |
| Bind group creation | Expensive (GPU call) |
| Key regeneration | O(n) resource count |

The caching strategy ensures expensive GPU bind group creation only happens once per unique resource combination.

---

## Sources

- `libraries/pixijs/src/rendering/renderers/gpu/BindGroupSystem.ts`
- `libraries/pixijs/src/rendering/renderers/gpu/shader/BindGroup.ts`
- `libraries/pixijs/src/rendering/batcher/gpu/getTextureBatchBindGroup.ts`

---

*Next: [Graphics API](graphics-api.md)*
