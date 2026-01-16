# Three.js: The Art of Partial Updates

> What if you could tell the GPU exactly which bytes changed?

---

## The Bandwidth Problem

A vertex buffer with 10,000 vertices takes 480KB at 12 floats per vertex (position, normal, UV, color). Upload it every frame at 60fps, and you're pushing 28MB/second—just for one mesh. With a complex scene, bandwidth becomes the bottleneck.

But in most frames, most vertices don't change. A character's idle animation might move 500 vertices out of 10,000. The other 9,500 vertices are identical to last frame. Uploading everything is wasteful.

Three.js pioneered a solution that's now standard across web 3D: update range tracking. Instead of "this buffer changed," you say "bytes 2400-4400 in this buffer changed." The GPU uploads 2KB instead of 480KB.

The question guiding this exploration: *how do you track fine-grained changes without drowning in bookkeeping?*

---

## Update Ranges: Tracking What Actually Changed

### The Core API

Every `BufferAttribute` in Three.js maintains a list of dirty regions:

```javascript
this.updateRanges = [];

addUpdateRange(start, count) {
    this.updateRanges.push({ start, count });
}

clearUpdateRanges() {
    this.updateRanges.length = 0;
}
```

User code that modifies vertices can declare exactly which portion changed:

```javascript
// Modified vertices 100-200
attribute.setXYZ(100, x1, y1, z1);
// ... modify more vertices ...
attribute.setXYZ(199, xN, yN, zN);

// Tell Three.js what changed
attribute.addUpdateRange(100, 100);
attribute.needsUpdate = true;
```

### Why an Array?

A single range would be simpler, but consider a scene with two animated objects sharing a vertex buffer:
- Object A uses vertices 100-200, and its arm moved
- Object B uses vertices 5000-5100, and its leg moved

One range covering 100-5100 would upload 4,900 unchanged vertices. Two ranges—[100, 100] and [5000, 100]—upload only what actually changed.

The array accommodates disjoint modifications within the same frame. Each modification adds its range; the renderer processes all of them.

---

## Version Counters: More Than a Boolean

### The needsUpdate Pattern

Three.js uses a version counter, not a boolean flag:

```javascript
set needsUpdate(value) {
    if (value === true) this.version++;
}
```

Setting `needsUpdate = true` increments an internal version number. The renderer compares cached versions against current versions:

```javascript
if (textureData.version === texture.version)
    return;  // Skip - nothing changed
```

### Why Counters Beat Booleans

Boolean flags have a flaw: once cleared, you can't tell who cleared them. If two subsystems both need to respond to changes, the first one to process the flag steals it from the second.

Version counters solve this elegantly:
1. Texture version is 5
2. Renderer A caches version 5
3. Renderer B caches version 5
4. Texture changes → version becomes 6
5. Renderer A sees cached=5, current=6 → updates, caches 6
6. Renderer B sees cached=5, current=6 → also updates, caches 6

Each consumer tracks its own "last seen" version independently. No coordination needed.

This matters for Three.js's multi-renderer scenarios—the same scene might render to a preview canvas and a main canvas, each with its own renderer. Both need to see texture changes.

---

## The WebGPU Backend

### Partial Upload Implementation

When it's time to send data to the GPU, Three.js's WebGPU backend checks for update ranges:

```javascript
updateAttribute(attribute) {
    const updateRanges = attribute.updateRanges;

    if (updateRanges.length === 0) {
        // No ranges - upload entire buffer
        device.queue.writeBuffer(buffer, 0, array, 0, array.length);
    } else {
        // Upload only specified ranges
        for (let i = 0; i < updateRanges.length; i++) {
            const range = updateRanges[i];
            const dataOffset = range.start * byteOffsetFactor;
            const size = range.count * byteOffsetFactor;
            const bufferOffset = dataOffset * array.BYTES_PER_ELEMENT;

            device.queue.writeBuffer(buffer, bufferOffset, array, dataOffset, size);
        }
    }

    attribute.clearUpdateRanges();  // Reset for next frame
}
```

If no ranges are specified, the entire buffer uploads—the fallback for simple cases where tracking ranges isn't worth the effort. If ranges exist, only those regions upload. Either way, the ranges clear after processing, ready for the next frame.

### Uniform Buffers Too

The pattern extends to uniform buffers:

```javascript
updateBinding(binding) {
    const updateRanges = binding.buffer.updateRanges;

    if (updateRanges.length === 0) {
        device.queue.writeBuffer(buffer, 0, array);
    } else {
        for (const range of updateRanges) {
            device.queue.writeBuffer(buffer, range.start * bytes, array, range.start, range.count);
        }
    }

    binding.buffer.clearUpdateRanges();
}
```

The same approach that works for vertex data works for material parameters, transform matrices, anything sent to the GPU repeatedly.

---

## Range Merging: Reducing GPU Calls

### The Optimization

WebGL backends add another layer: merging adjacent ranges before upload. Each GPU call has overhead; fewer calls with larger payloads is more efficient than many small calls.

```javascript
// Sort ranges by start position
updateRanges.sort((a, b) => a.start - b.start);

// Merge overlapping/adjacent ranges
let mergedIndex = 0;
for (let i = 1; i < updateRanges.length; i++) {
    const current = updateRanges[i];
    const merged = updateRanges[mergedIndex];

    if (current.start <= merged.start + merged.count) {
        // Overlapping or adjacent - merge
        merged.count = Math.max(
            merged.count,
            current.start + current.count - merged.start
        );
    } else {
        // Gap - keep separate
        mergedIndex++;
        updateRanges[mergedIndex] = current;
    }
}

updateRanges.length = mergedIndex + 1;
```

Consider ranges [100, 50], [120, 40], [200, 30]:
- Ranges 1 and 2 overlap (120 < 100+50), so they merge into [100, 60]
- Range 3 is separate (200 > 160)
- Result: two calls instead of three

### When Merging Helps

Merging matters most when:
- Many small, adjacent changes occur (e.g., particle system updates)
- Driver call overhead is significant (older APIs, mobile GPUs)
- The gap between ranges is small

For WebGPU, `queue.writeBuffer` is relatively cheap per-call, so merging helps less. For WebGL's `bufferSubData`, each call has more overhead, making merging more valuable.

### Texture Merging: Row-Aware

Texture updates complicate merging. Textures are 2D; merging across rows would upload data that doesn't need uploading:

```javascript
// Only merge ranges in the same row
const prevRow = Math.floor(prev.start / width);
const currRow = Math.floor(curr.start / width);

if (currRow === prevRow && curr.start <= prev.start + prev.count) {
    // Same row and overlapping - merge
    prev.count = Math.max(prev.count, curr.start + curr.count - prev.start);
} else {
    // Different row or gap - keep separate
    mergeIndex++;
    updateRanges[mergeIndex] = curr;
}
```

Two ranges in the same row merge normally. Two ranges in different rows stay separate, even if their indices are adjacent numerically.

---

## The Abstract Buffer Layer

### Backend Independence

Three.js abstracts the update range pattern in `renderers/common/Buffer.js`:

```javascript
class Buffer {
    constructor() {
        this._updateRanges = [];
    }

    get updateRanges() {
        return this._updateRanges;
    }

    addUpdateRange(start, count) {
        this._updateRanges.push({ start, count });
    }

    clearUpdateRanges() {
        this._updateRanges.length = 0;
    }

    update() {
        return true;  // Override in subclasses
    }
}
```

This abstraction lets WebGL and WebGPU backends share the range-tracking logic while implementing backend-specific upload methods. The same user code works regardless of which backend renders.

---

## Dimension Changes

### A Different Kind of Update

Not all changes are equal. Modifying vertices 100-200 is a data update—the buffer size stays the same. Changing a texture from 512x512 to 1024x1024 is a structural change—you need a completely new GPU texture.

Three.js distinguishes these:

```javascript
textureNeedsUpdate = textureNeedsUpdate ||
    textureData.width !== textureDescriptor.width ||
    textureData.height !== textureDescriptor.height ||
    textureData.sampleCount !== textureDescriptor.sampleCount;

if (textureNeedsUpdate) {
    depthTexture.needsUpdate = true;  // Full reallocation
}
```

Size changes bypass the update range optimization entirely. You can't partially update your way to a larger texture—you must reallocate.

---

## Lessons for the GPU Resource Pool

Three.js's patterns suggest several approaches:

**Update ranges for large buffers.** For buffers over a few KB where sparse updates are common, tracking which regions changed can dramatically reduce bandwidth. For small uniform buffers, the overhead isn't worth it—just upload everything.

**Version counters for multi-consumer scenarios.** When multiple systems might respond to the same change, version counters let each track independently. Each consumer caches the last version it saw.

**Range merging with care.** Merge adjacent ranges to reduce GPU calls, but be aware of structure. For 2D data, don't merge across rows. The optimization is backend-dependent—measure before committing.

**Clear ranges after processing.** The range list resets each frame. Stale ranges from previous frames would cause redundant uploads or, worse, incorrect data.

**Distinguish data changes from structural changes.** Changing a texture's pixels is different from changing its dimensions. Data changes can use partial updates; structural changes require reallocation.

**Abstract the mechanism.** The same range-tracking pattern works for vertices, uniforms, textures—anything that uploads repeatedly. A shared abstraction reduces code duplication and ensures consistent behavior.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `src/core/BufferAttribute.js` | 116-191 | Core update range API |
| `src/textures/Texture.js` | 315-752 | Texture dirty tracking |
| `src/renderers/common/Buffer.js` | 49-87 | Abstract buffer layer |
| `src/renderers/common/Textures.js` | 77-348 | Texture version management |
| `src/renderers/webgpu/utils/WebGPUAttributeUtils.js` | 177-228 | WebGPU partial uploads |
| `src/renderers/webgl/WebGLAttributes.js` | 83-150 | WebGL range merging |
| `src/renderers/webgl/WebGLTextures.js` | 756-857 | Texture range merging |

---

## Related Documents

- [tixl.md](tixl.md) — Different dirty flag approach (reference/target)
- [wgpu.md](wgpu.md) — How wgpu implements similar patterns at a lower level
- [../cache-invalidation.md](../cache-invalidation.md) — Cross-framework comparison
