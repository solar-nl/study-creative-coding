# Babylon.js: Production WebGPU at Scale

> How does a mature engine manage GPU resources across WebGL and WebGPU backends?

---

## A Different League

Babylon.js isn't a creative coding framework—it's a production 3D engine powering games, visualizations, and digital twins. But its WebGPU implementation, one of the earliest production-ready implementations, demonstrates patterns that any serious GPU resource management system should understand.

The challenge Babylon.js faces is ambitious: maintain API compatibility with WebGL while exploiting WebGPU's explicit, deferred command model. The same application code should run on both backends, transparently. This constraint shapes every resource management decision.

The question guiding this exploration: *how do you build a caching and cleanup system that works across two fundamentally different GPU APIs?*

---

## Deferred Buffer Destruction

### The Problem

WebGPU buffers can't be destroyed while the GPU is still using them. But with deferred command submission, "using" might mean "referenced in a command buffer that hasn't been submitted yet" or "submitted but still executing."

### Babylon's Solution

The `WebGPUBufferManager` queues buffers for deferred destruction:

```typescript
export class WebGPUBufferManager {
    private _deferredReleaseBuffers: Array<GPUBuffer> = [];

    public releaseBuffer(buffer: DataBuffer | GPUBuffer): boolean {
        if (WebGPUBufferManager._IsGPUBuffer(buffer)) {
            this._deferredReleaseBuffers.push(buffer);
            return true;
        }

        buffer.references--;

        if (buffer.references === 0) {
            this._deferredReleaseBuffers.push(buffer.underlyingResource as GPUBuffer);
            return true;
        }

        return false;
    }

    public destroyDeferredBuffers(): void {
        for (let i = 0; i < this._deferredReleaseBuffers.length; ++i) {
            this._deferredReleaseBuffers[i].destroy();
        }
        this._deferredReleaseBuffers.length = 0;
    }
}
```

The flow is straightforward:
1. When you release a buffer, it goes into `_deferredReleaseBuffers`
2. At frame end, `destroyDeferredBuffers()` actually destroys them
3. By then, all command buffers have been submitted and the GPU is working on them

### Reference Counting

For `DataBuffer` (Babylon's buffer wrapper), reference counting determines when to queue for destruction:

```typescript
dataBuffer.references = 1;  // On creation

// On release:
buffer.references--;
if (buffer.references === 0) {
    this._deferredReleaseBuffers.push(buffer.underlyingResource);
}
```

This is simpler than Arc—just manual counting. But it fits Babylon's architecture where buffer lifetimes are well-defined by the scene graph.

---

## Tree-Based Bind Group Caching

### The Problem

WebGPU bind groups bundle resources (buffers, textures, samplers) for shader access. Creating them is expensive. But the cache key is complex: you need to match all resources exactly.

Hash-based caching would require hashing all resource IDs together—expensive for large bind groups. And hash collisions could cause subtle bugs.

### Babylon's Solution: Prefix Trees

The `WebGPUCacheBindGroups` uses a tree structure where each level represents one resource:

```typescript
class WebGPUBindGroupCacheNode {
    public values: { [id: number]: WebGPUBindGroupCacheNode };
    public bindGroups: GPUBindGroup[];
}

// ID offsets prevent collision
const BufferIdStart = 1 << 20;    // 1,048,576
const TextureIdStart = 2 ** 35;   // 34,359,738,368
```

Lookup walks the tree:

```typescript
public getBindGroups(pipelineContext, drawContext, materialContext): GPUBindGroup[] {
    let node = WebGPUCacheBindGroups._Cache;

    // Walk tree by buffer IDs
    for (const bufferName of pipelineContext.shaderProcessingContext.bufferNames) {
        const uboId = (drawContext.buffers[bufferName]?.uniqueId ?? 0) + BufferIdStart;
        let nextNode = node.values[uboId];
        if (!nextNode) {
            nextNode = new WebGPUBindGroupCacheNode();
            node.values[uboId] = nextNode;
        }
        node = nextNode;
    }

    // Continue with samplers...
    for (const samplerName of pipelineContext.shaderProcessingContext.samplerNames) {
        const samplerHashCode = materialContext.samplers[samplerName]?.hashCode ?? 0;
        // ... navigate tree
    }

    // Continue with textures...
    for (const textureName of pipelineContext.shaderProcessingContext.textureNames) {
        const textureId = (materialContext.textures[textureName]?.uniqueId ?? 0) + TextureIdStart;
        // ... navigate tree
    }

    // At leaf: check for cached bind groups
    if (node.bindGroups) {
        return node.bindGroups;
    }

    // Cache miss: create and store
    // ...
}
```

### Why This Works

The tree structure has several advantages:

- **No hashing**: Just integer comparisons and property access
- **Incremental**: Partial matches share tree nodes
- **No collisions**: Unique paths for unique resource combinations
- **Memory efficient**: Common prefixes share storage

The ID offsets (`BufferIdStart`, `TextureIdStart`) ensure buffer ID 5 and texture ID 5 land in different tree branches. With `2^35` for textures, you can have 32,768 buffers and 524,288 textures before any risk of collision.

---

## Multi-Level Dirty Tracking

### The Three Levels

Babylon tracks dirtiness at multiple granularities:

```typescript
// 1. Draw Context: per-draw-call state
class WebGPUDrawContext {
    private _isDirty: boolean;
    private _materialContextUpdateId: number;

    public isDirty(materialContextUpdateId: number): boolean {
        return this._isDirty || this._materialContextUpdateId !== materialContextUpdateId;
    }
}

// 2. Material Context: per-material state
class WebGPUMaterialContext {
    public updateId: number;  // Incremented on any change
    public isDirty: boolean;  // Quick flag

    public setTexture(name: string, texture: InternalTexture) {
        this.textures[name] = { texture, ... };
        this.updateId++;
        this.isDirty = true;
    }
}

// 3. Pipeline Context: shader/format state
// (Handled by separate pipeline cache)
```

### The Fast Path

The cache check has a fast path for unchanged state:

```typescript
if (!drawContext.isDirty(materialContext.updateId) && !materialContext.isDirty) {
    WebGPUCacheBindGroups._NumBindGroupsNoLookupCurrentFrame++;
    return drawContext.bindGroups!;
}
```

If nothing changed since the last draw call with this context, skip the entire cache lookup. Just return the cached bind groups. This is the common case for static scenes—same material, same resources, frame after frame.

### updateId: A Version Counter

The `updateId` is essentially Three.js's version counter pattern:

```typescript
// Material changes → increment updateId
materialContext.updateId++;

// Draw context caches last-seen updateId
this._materialContextUpdateId = materialContextUpdateId;

// Dirty check: has material changed since we last looked?
this._materialContextUpdateId !== materialContextUpdateId
```

Each draw context independently tracks which material version it last saw. Multiple draw contexts can use the same material; each tracks its own sync state.

---

## Per-Frame Statistics

### Observability Built In

Babylon tracks cache performance per frame:

```typescript
export class WebGPUCacheBindGroups {
    public static NumBindGroupsCreatedTotal = 0;
    public static NumBindGroupsCreatedLastFrame = 0;
    public static NumBindGroupsLookupLastFrame = 0;
    public static NumBindGroupsNoLookupLastFrame = 0;

    private static _NumBindGroupsCreatedCurrentFrame = 0;
    private static _NumBindGroupsLookupCurrentFrame = 0;
    private static _NumBindGroupsNoLookupCurrentFrame = 0;

    public endFrame(): void {
        NumBindGroupsCreatedLastFrame = _NumBindGroupsCreatedCurrentFrame;
        NumBindGroupsLookupLastFrame = _NumBindGroupsLookupCurrentFrame;
        NumBindGroupsNoLookupLastFrame = _NumBindGroupsNoLookupCurrentFrame;
        _NumBindGroupsCreatedCurrentFrame = 0;
        _NumBindGroupsLookupCurrentFrame = 0;
        _NumBindGroupsNoLookupCurrentFrame = 0;
    }

    public static get Statistics() {
        return {
            totalCreated: NumBindGroupsCreatedTotal,
            lastFrameCreated: NumBindGroupsCreatedLastFrame,
            lookupLastFrame: NumBindGroupsLookupLastFrame,
            noLookupLastFrame: NumBindGroupsNoLookupLastFrame,
        };
    }
}
```

### What These Numbers Mean

- **NoLookup**: Fast path—nothing changed, reused cached bind groups immediately
- **Lookup**: Tree traversal found cached bind groups
- **Created**: Cache miss—had to create new bind groups

A healthy scene shows mostly NoLookup (static content reusing bind groups) with occasional Lookup (dynamic content) and rare Created (new materials or first frame).

The pipeline cache has similar statistics for tracking pipeline compilation.

---

## Buffer Alignment

### WebGPU's Requirements

WebGPU requires buffer sizes and offsets to be multiples of 4 bytes. Babylon handles this transparently:

```typescript
public createRawBuffer(viewOrSize: ArrayBufferView | number, flags: GPUBufferUsageFlags): GPUBuffer {
    const alignedLength = (viewOrSize as ArrayBufferView).byteLength !== undefined
        ? ((viewOrSize as ArrayBufferView).byteLength + 3) & ~3
        : ((viewOrSize as number) + 3) & ~3;

    return this._device.createBuffer({
        size: alignedLength,
        usage: flags,
        // ...
    });
}
```

The expression `(size + 3) & ~3` rounds up to the nearest multiple of 4. A 13-byte request becomes 16 bytes.

For partial updates, alignment is handled at write time:

```typescript
public setSubData(dataBuffer: WebGPUDataBuffer, dstByteOffset: number, src: ArrayBufferView): void {
    // Align destination offset
    const startPre = dstByteOffset & 3;
    srcByteOffset -= startPre;
    dstByteOffset -= startPre;

    // Align byte length
    byteLength = (byteLength + startPre + 3) & ~3;

    // Handle backing buffer too small for aligned copy
    if (backingBufferSize < byteLength) {
        const tmpBuffer = new Uint8Array(byteLength);
        tmpBuffer.set(new Uint8Array(src.buffer, src.byteOffset + srcByteOffset, originalByteLength));
        src = tmpBuffer;
        srcByteOffset = 0;
    }

    this.setRawData(buffer, dstByteOffset, src, srcByteOffset, byteLength);
}
```

This complexity is hidden from user code. You write bytes; Babylon handles alignment.

---

## Two Command Encoders

### Separating Uploads from Rendering

Babylon uses separate encoders for upload and render operations:

```typescript
this._uploadEncoder = this._device.createCommandEncoder(this._uploadEncoderDescriptor);
this._renderEncoder = this._device.createCommandEncoder(this._renderEncoderDescriptor);
```

At frame end, both submit together:

```typescript
public flushFramebuffer(): void {
    this._commandBuffers[0] = this._uploadEncoder.finish();
    this._commandBuffers[1] = this._renderEncoder.finish();
    this._device.queue.submit(this._commandBuffers);

    // Fresh encoders for next frame
    this._uploadEncoder = this._device.createCommandEncoder(...);
    this._renderEncoder = this._device.createCommandEncoder(...);
}
```

### Why Separate?

WebGPU requires uploads to complete before rendering can use the data. By encoding them separately and submitting in order, Babylon ensures correct synchronization without explicit barriers.

The pattern also enables potential parallelism: uploads could be prepared on one thread while render commands are built on another. (Babylon doesn't currently do this, but the architecture allows it.)

---

## Lessons for the GPU Resource Pool

Babylon.js's patterns suggest several approaches:

**Tree-based caching for complex keys.** When cache keys involve multiple resource IDs, tree traversal beats hashing. No collisions, incremental lookup, and shared storage for common prefixes.

**Multi-level dirty tracking.** Per-material version counters (`updateId`) combined with per-draw dirty flags enable both change detection and fast-path skipping. Each consumer tracks its own "last seen" state.

**Deferred destruction with frame boundary.** Queue resources for destruction during the frame; actually destroy at frame end. This naturally handles in-flight command buffers.

**Observability through statistics.** Tracking cache hit rates per frame makes optimization visible. You can see when the cache is working and when it's not.

**Alignment handled internally.** Don't expose WebGPU's 4-byte alignment requirements to users. Handle padding and alignment transparently in the buffer manager.

**Separate upload and render encoding.** Cleaner architecture that naturally orders operations correctly and enables future parallelism.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `WebGPU/webgpuBufferManager.ts` | 16, 228-250 | Deferred buffer destruction |
| `WebGPU/webgpuCacheBindGroups.ts` | 16-24, 98-150 | Tree-based bind group caching |
| `WebGPU/webgpuMaterialContext.ts` | 25-40 | Material dirty tracking |
| `WebGPU/webgpuDrawContext.ts` | 56-67 | Per-draw dirty state |
| `webgpuEngine.ts` | 784-809, 3090-3100 | Dual encoder, frame submission |

All paths relative to: `packages/dev/core/src/Engines/`

---

## Related Documents

- [wgpu.md](wgpu.md) — The Rust equivalent of Babylon's WebGPU backend
- [threejs.md](threejs.md) — Alternative JavaScript approach with version counters
- [rend3.md](rend3.md) — Similar frame-delayed deletion patterns
- [../cache-invalidation.md](../cache-invalidation.md) — Dirty tracking comparison
