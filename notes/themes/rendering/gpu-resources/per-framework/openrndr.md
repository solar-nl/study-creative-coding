# OpenRNDR: LRU Caching and Shadow Buffers

> How a Kotlin creative coding framework manages GPU resources

---

## Overview

OpenRNDR is a Kotlin-based creative coding framework with a sophisticated approach to GPU resource management. Two patterns stand out: **LRU caching for compiled shaders** and **shadow buffers for CPU-GPU synchronization**.

The key insight: **lazy shadow buffers provide efficient CPU access to GPU data without the overhead of always maintaining a CPU copy**.

---

## LRU Cache: Capacity-Based Eviction

### The Pattern

OpenRNDR uses a simple LRU cache for shader structures:

```kotlin
// From openrndr-gl-common/src/commonMain/kotlin/Cache.kt:1-29
class LRUCache<K, V>(val capacity: Int = 1_000) {
    val map = mutableMapOf<K, V>()
    val order = ArrayDeque<K>()

    fun get(key: K): V? {
        val v = map[key]
        if (v != null) {
            order.remove(key)
            order.addLast(key)  // Move to end (most recent)
        }
        return v
    }

    fun set(key: K, value: V) {
        while (order.size >= capacity) {
            val k = order.removeFirst()  // Evict oldest
            map.remove(k)
        }
        order.addLast(key)
        map[key] = value
    }

    fun getOrSet(key: K, forceSet: Boolean, valueFunction: () -> V): V {
        if (!forceSet) {
            get(key)?.let { return it }
        }
        val v = valueFunction()
        set(key, v)
        return v
    }
}
```

### Why 1,000 Capacity?

The default capacity of 1,000 is tuned for shader structures. A typical creative coding application might have:
- 50-100 unique shaders
- Each with multiple parameter combinations
- Maybe 5-10x variants for different blend modes, etc.

1,000 entries provides headroom without unbounded memory growth.

### Dirty Flag Integration

The cache integrates with dirty flags via `forceSet`:

```kotlin
// From ShadeStructureGLCommon.kt:22
shadeStyleCache.getOrSet(cacheEntry, shadeStyle?.dirty ?: false) {
    shadeStyle?.dirty = false
    // ... generate shader structure
}
```

When `shadeStyle.dirty` is true, the cache is bypassed and a fresh value is computed.

### Flux Implications

For Flux's caching:
- **Bounded caches** - prevent unbounded growth
- **LRU eviction** - simple, effective for temporal locality
- **Force-invalidation** - integrate with dirty flags

---

## Shadow Buffers: CPU-GPU Synchronization

### The Problem

GPU buffers aren't directly accessible from CPU code. To read or modify GPU data, you need to:
1. Map the buffer (expensive, blocks GPU)
2. Copy data
3. Unmap the buffer

Doing this per-frame for every buffer is wasteful.

### OpenRNDR's Solution

Shadow buffers provide a CPU-side mirror that syncs on demand:

```kotlin
// From ColorBufferShadowGL3.kt:1-129
class ColorBufferShadowGL3(override val colorBuffer: ColorBufferGL3) : ColorBufferShadow {
    val size = colorBuffer.effectiveWidth * colorBuffer.effectiveHeight
    val elementSize = colorBuffer.format.componentCount * colorBuffer.type.componentSize
    override val buffer: ByteBuffer = BufferUtils.createByteBuffer(elementSize * size)

    override fun download() {
        colorBuffer.read(buffer)  // GPU → CPU
    }

    override fun upload() {
        colorBuffer.write(buffer)  // CPU → GPU
    }

    override fun destroy() {
        // Cleanup...
    }
}
```

### Lazy Shadow Creation

Shadows aren't created until first access:

```kotlin
// From ColorBufferGL3.kt:712-722
override val shadow: ColorBufferShadow
    get() {
        if (multisample == Disabled) {
            if (realShadow == null) {
                realShadow = ColorBufferShadowGL3(this)
            }
            return realShadow!!
        } else {
            throw IllegalArgumentException("multisample targets cannot be shadowed")
        }
    }
```

This is important because:
- Most buffers never need CPU access
- Shadows double memory usage
- Creating shadows is cheap but uses memory

### VertexBuffer Shadow

```kotlin
// From VertexBufferGL3.kt:26-60
class VertexBufferShadowGL3(override val vertexBuffer: VertexBufferGL3) : VertexBufferShadow {
    val buffer: ByteBuffer = ByteBuffer.allocateDirect(
        vertexBuffer.vertexCount * vertexBuffer.vertexFormat.size
    ).apply { order(ByteOrder.nativeOrder()) }

    override fun upload(offsetInBytes: Int, sizeInBytes: Int) {
        // Partial upload support
    }

    override fun download() {
        // Full download
    }
}
```

Note the partial upload support - you can sync just a portion of the buffer.

### Flux Implications

For Flux's CPU-GPU synchronization:
- **Lazy shadows** - don't create until needed
- **Explicit sync direction** - download vs upload
- **Partial sync** - for large buffers with small changes

---

## Session-Based Resource Tracking

### The Pattern

OpenRNDR uses sessions to track GPU resources:

```kotlin
// From Session.kt:99-112
val renderTargets: Set<RenderTarget> = mutableSetOf()
val colorBuffers: Set<ColorBuffer> = mutableSetOf()
val depthBuffers: Set<DepthBuffer> = mutableSetOf()
val bufferTextures: Set<BufferTexture> = mutableSetOf()
val vertexBuffers: Set<VertexBuffer> = mutableSetOf()
val shaders: Set<Shader> = mutableSetOf()
// ... 10+ more resource types
```

### Automatic Tracking

Resources are registered on creation:

```kotlin
// From DriverGL3.kt:517
override fun createColorBuffer(...): ColorBuffer {
    synchronized(this) {
        val colorBuffer = ColorBufferGL3.create(...)
        session?.track(colorBuffer)  // Register
        return colorBuffer
    }
}
```

### Batch Cleanup

When a session ends, all its resources are destroyed:

```kotlin
// From Session.kt:206-210
colorBuffers as MutableSet<ColorBuffer>
colorBuffers.map { it }.forEach {
    it.destroy()
}
colorBuffers.clear()
```

### Hierarchical Sessions

Sessions can have parent-child relationships:

```kotlin
// From Session.kt (conceptual)
class Session {
    val parent: Session?
    val children: MutableList<Session>

    fun end() {
        children.forEach { it.end() }  // Cascade to children
        destroyAllResources()
    }
}
```

This enables patterns like:
- Root session for application-lifetime resources
- Child sessions for per-scene resources
- Grandchild sessions for per-frame temporaries

### Flux Implications

For Flux's resource lifetime:
- **Session-based grouping** - resources belong to a scope
- **Automatic cleanup** - session end cleans its resources
- **Hierarchical ownership** - parent-child for nested scopes

---

## Resource Destruction

### The Pattern

Resources track their own destruction state:

```kotlin
// From VertexBufferGL3.kt:204-217
override fun destroy() {
    if (!isDestroyed) {
        logger.debug { "destroying vertex buffer with id $buffer" }
        session?.untrack(this)
        isDestroyed = true
        realShadow = null
        glDeleteBuffers(buffer)
        (Driver.instance as DriverGL3).destroyVAOsForVertexBuffer(this)
        checkGLErrors()
        Session.active.untrack(this)
    }
}
```

Key details:
- `isDestroyed` flag prevents double-destroy
- Session untrack happens before GL deletion
- Shadow is nulled (allows GC)
- VAOs referencing this buffer are cleaned up

### Shadow Cleanup

Shadows can be destroyed independently:

```kotlin
// From ColorBufferGL3.kt:296-298
fun destroyShadow() {
    realShadow = null
}
```

This frees CPU memory while keeping the GPU resource.

---

## Shader Dirty Tracking

### The Pattern

ShadeStyle (OpenRNDR's material equivalent) has a dirty flag:

```kotlin
// From ShadeStyle.kt (conceptual)
class ShadeStyle {
    var dirty = true

    fun setParameter(name: String, value: Any) {
        parameters[name] = value
        dirty = true  // Mark for recompilation
    }
}
```

The shader cache checks this flag:

```kotlin
// From ShadeStructureGLCommon.kt:22
shadeStyleCache.getOrSet(cacheEntry, shadeStyle?.dirty ?: false) {
    shadeStyle?.dirty = false  // Clear after recompile
    // ... compile shader
}
```

### Cache Key Design

The cache key includes all factors that affect compilation:

```kotlin
// From ShadeStructureGLCommon.kt:8-12
private data class CacheEntry(
    val shadeStyle: ShadeStyle?,
    val vertexFormats: List<VertexFormat>,
    val instanceAttributeFormats: List<VertexFormat>
)
```

Different vertex formats produce different shaders, so they're part of the key.

---

## Summary: Key Patterns for Flux

| Pattern | OpenRNDR Approach | Flux Application |
|---------|-------------------|------------------|
| **Shader caching** | LRU with 1K capacity | Bounded cache, evict old entries |
| **Dirty integration** | `forceSet` parameter | Bypass cache when dirty |
| **CPU-GPU sync** | Shadow buffers | Lazy CPU mirror on demand |
| **Lazy creation** | Shadow on first access | Don't allocate until needed |
| **Partial sync** | Upload with offset/size | Efficient for large buffers |
| **Resource tracking** | Session sets | Track by scope/owner |
| **Hierarchical cleanup** | Parent-child sessions | Nested lifetimes |
| **Destruction guard** | `isDestroyed` flag | Prevent double-free |
| **Cache key** | Data class with all factors | Include all variant factors |

---

## Design Insight: Lazy Everything

OpenRNDR's approach is deeply lazy:
- Shadows created on first access
- Shaders compiled on first use (then cached)
- VAOs created when first drawn
- Resources destroyed when session ends

This fits creative coding well - you might define 100 potential elements but only render 10. Lazy creation means the 90 unused elements cost nothing.

`★ Insight ─────────────────────────────────────`
The shadow buffer pattern inverts typical CPU-GPU thinking. Instead of "GPU mirrors CPU data," it's "CPU can optionally mirror GPU data." This makes the GPU the primary owner, which aligns with modern graphics programming.
`─────────────────────────────────────────────────`

---

## Source Files

| File | Purpose |
|------|---------|
| `openrndr-gl-common/src/.../Cache.kt:1-29` | LRU cache |
| `openrndr-gl-common/src/.../ShadeStructureGLCommon.kt:8-22` | Shader caching |
| `openrndr-jvm/openrndr-gl3/src/.../ColorBufferShadowGL3.kt:1-129` | Color buffer shadow |
| `openrndr-jvm/openrndr-gl3/src/.../VertexBufferGL3.kt:26-217` | Vertex buffer + shadow |
| `openrndr-jvm/openrndr-gl3/src/.../ColorBufferGL3.kt:712-939` | Lazy shadow, destruction |
| `openrndr-draw/src/.../Session.kt:99-276` | Session tracking |

---

## Related Documents

- [tixl.md](tixl.md) - Different dirty flag approach
- [../cache-invalidation.md](../cache-invalidation.md) - Cross-framework comparison
- [wgpu.md](wgpu.md) - Lower-level patterns these build on
