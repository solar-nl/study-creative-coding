# Three.js: Update Range Tracking

> How JavaScript's most popular 3D library optimizes GPU updates

---

## Overview

Three.js pioneered many patterns now common in web 3D graphics. Its approach to GPU resource management emphasizes **version-based dirty tracking** and **partial update ranges** that minimize data transfer to the GPU.

The key insight: **tracking which portions of a buffer changed enables uploading only the modified regions, dramatically reducing bandwidth for large dynamic geometry**.

---

## Update Range Architecture

### The Core Pattern

Every `BufferAttribute` can track which portions need GPU updates:

```javascript
// From src/core/BufferAttribute.js:116
this.updateRanges = [];

// From BufferAttribute.js:178-191
addUpdateRange(start, count) {
    this.updateRanges.push({ start, count });
}

clearUpdateRanges() {
    this.updateRanges.length = 0;
}
```

When you modify vertices 100-200 in a 10,000 vertex buffer, you add an update range covering just those vertices. The renderer then uploads only that portion.

### Why Arrays Instead of Single Range?

Multiple disjoint regions might change in a single frame:
- Vertex 100-200 (one object moved)
- Vertex 5000-5100 (another object moved)

Uploading vertices 100-5100 would waste bandwidth on unchanged data. The array allows tracking both regions separately.

---

## Version-Based Dirty Tracking

### The needsUpdate Pattern

```javascript
// From BufferAttribute.js:152-156
set needsUpdate(value) {
    if (value === true) this.version++;
}

// From Texture.js:743-752
set needsUpdate(value) {
    if (value === true) {
        this.version++;
        this.source.needsUpdate = true;  // Propagate to source
    }
}
```

Setting `needsUpdate = true` increments an internal version counter. The renderer compares cached versions against current versions:

```javascript
// From renderers/common/Textures.js:190
if (textureData.initialized === true && textureData.version === texture.version)
    return;  // Skip - nothing changed
```

### Why Version Counters?

Boolean dirty flags have a problem: once you clear the flag, you can't tell if something else already processed it. Version counters solve this:

1. Texture.version = 5 (current)
2. Renderer caches version 5
3. Later: texture.needsUpdate = true → version becomes 6
4. Renderer sees cached=5, current=6 → needs update
5. After update: cache version 6

Multiple subsystems can independently track whether they've processed the latest version.

---

## WebGPU Backend: Partial Uploads

### Attribute Updates

```javascript
// From renderers/webgpu/utils/WebGPUAttributeUtils.js:177-228
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

### Uniform Buffer Updates

The same pattern applies to uniform buffers:

```javascript
// From renderers/webgpu/utils/WebGPUBindingUtils.js:184-229
updateBinding(binding) {
    const updateRanges = binding.buffer.updateRanges;

    if (updateRanges.length === 0) {
        device.queue.writeBuffer(buffer, 0, array);
    } else {
        for (const range of updateRanges) {
            // Handle byte alignment for both typed and untyped arrays
            device.queue.writeBuffer(buffer, range.start * bytes, array, range.start, range.count);
        }
    }

    binding.buffer.clearUpdateRanges();
}
```

---

## WebGL Backend: Range Merging

### The Optimization

WebGL backends take update ranges a step further with **range merging**:

```javascript
// From renderers/webgl/WebGLAttributes.js:103-136
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

// Trim array to remove merged-away entries
updateRanges.length = mergedIndex + 1;
```

### Why Merge?

Consider ranges [100, 150], [120, 80], [230, 50]:
- Without merging: 3 `bufferSubData` calls
- After merging: [100, 100], [230, 50] - 2 calls
- If [230, 50] were [200, 50]: would merge to [100, 150] - 1 call

Fewer GPU commands means less driver overhead.

### Texture Range Merging (Row-Aware)

Texture updates are more complex because 2D data has rows:

```javascript
// From renderers/webgl/WebGLTextures.js:777-820
// Sort by start
updateRanges.sort((a, b) => a.start - b.start);

// Merge only ranges in same row
for (let i = 1; i < updateRanges.length; i++) {
    const prev = updateRanges[mergeIndex];
    const curr = updateRanges[i];

    // Calculate row for each range
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
}
```

Merging ranges that span rows would require uploading more data than separate uploads.

---

## Abstract Buffer Layer

### The Pattern

Three.js abstracts buffers in `renderers/common/Buffer.js`:

```javascript
// From renderers/common/Buffer.js:49-87
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
        // Returns true if GPU upload needed
        return true;
    }
}
```

This abstraction allows the WebGL and WebGPU backends to share the same update range logic while implementing backend-specific upload methods.

---

## Texture Versioning

### The Full Pipeline

```javascript
// From renderers/common/Textures.js (conceptual flow)

// 1. User modifies texture
texture.image = newImageData;
texture.needsUpdate = true;  // → version++

// 2. During render, Textures manager checks
if (textureData.version === texture.version) {
    return;  // Cached version matches - skip
}

// 3. Upload new texture data
uploadTexture(texture);

// 4. Cache new version
textureData.version = texture.version;
```

### Dimension Change Detection

```javascript
// From Textures.js:77-108
textureNeedsUpdate = textureNeedsUpdate ||
    textureData.width !== textureDescriptor.width ||
    textureData.height !== textureDescriptor.height ||
    textureData.sampleCount !== textureDescriptor.sampleCount;

if (textureNeedsUpdate) {
    // Need to recreate GPU texture (dimensions changed)
    depthTexture.needsUpdate = true;
}
```

Size changes require full reallocation, not just data upload.

---

## Summary: Key Patterns for Flux

| Pattern | Three.js Approach | Flux Application |
|---------|-------------------|------------------|
| **Dirty tracking** | Version counter per resource | Integrate with slot dirty flags |
| **Partial updates** | Update range array | Track which portions changed |
| **Range clearing** | After GPU upload | Reset per frame |
| **Range merging** | Sort + merge adjacent | Reduce GPU commands |
| **Row-aware merging** | For 2D textures | Don't merge across rows |
| **Backend abstraction** | Buffer class | Share logic across backends |
| **Dimension change** | Separate flag + realloc | Distinguish data change from size change |

---

## Design Insight: Granularity Matters

Three.js tracks changes at multiple granularities:
1. **Resource level**: `needsUpdate` → "something changed"
2. **Range level**: `updateRanges` → "these specific bytes changed"
3. **Version level**: `version` → "how many times has it changed"

This layered tracking enables optimizations at each level:
- Skip entirely if version matches
- Upload only changed ranges
- Merge ranges when beneficial

`★ Insight ─────────────────────────────────────`
The range merging algorithm in WebGL backends shows that optimal strategies differ between backends. WebGPU's `queue.writeBuffer` is cheaper per-call than WebGL's `bufferSubData`, so merging matters less. Backend-specific optimization paths are valuable.
`─────────────────────────────────────────────────`

---

## Source Files

| File | Purpose |
|------|---------|
| `src/core/BufferAttribute.js:116-191` | Core update range API |
| `src/textures/Texture.js:315-752` | Texture dirty tracking |
| `src/renderers/common/Buffer.js:49-87` | Abstract buffer layer |
| `src/renderers/common/Textures.js:77-348` | Texture version management |
| `src/renderers/webgpu/utils/WebGPUAttributeUtils.js:177-228` | WebGPU partial uploads |
| `src/renderers/webgl/WebGLAttributes.js:83-150` | WebGL range merging |
| `src/renderers/webgl/WebGLTextures.js:756-857` | Texture range merging |

---

## Related Documents

- [tixl.md](tixl.md) - Different dirty flag approach
- [wgpu.md](wgpu.md) - How wgpu implements similar patterns
- [../cache-invalidation.md](../cache-invalidation.md) - Cross-framework comparison
