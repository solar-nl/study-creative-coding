# OpenRNDR: Lazy Shadows and Bounded Caches

> When should the CPU know what the GPU knows?

---

## A Different Ownership Model

Most CPU-GPU programming starts from a CPU-centric worldview: you have data on the CPU, and you upload it to the GPU for rendering. The CPU is the source of truth; the GPU is a rendering servant.

OpenRNDR inverts this. GPU buffers are the primary owners of their data. The CPU can *optionally* maintain a shadow copy—a mirror of the GPU data—but only when needed. Most buffers never need CPU access after initial upload. Why pay the memory cost for mirrors you'll never use?

The question guiding this exploration: *how do you provide CPU access to GPU data without paying for it universally?*

---

## Shadow Buffers: Mirrors on Demand

### The Problem

GPU buffers aren't directly accessible from CPU code. To read vertex positions back from the GPU, you must map the buffer, copy data, and unmap. This is expensive—it blocks the GPU, waits for pending work to complete, and involves driver overhead.

Doing this every frame for every buffer is wasteful. Most buffers are write-once; you set them up, send them to the GPU, and never look at them again. But some buffers need frequent CPU access: dynamic geometry, procedurally animated meshes, readback for collision detection.

### OpenRNDR's Solution

Each buffer *can* have a shadow, but doesn't by default:

```kotlin
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

The first time you access `buffer.shadow`, it allocates a CPU-side ByteBuffer matching the GPU buffer's size. Subsequent accesses return the cached shadow. If you never access the shadow, you never pay for it.

The shadow itself is straightforward:

```kotlin
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
}
```

Two explicit operations: `download()` pulls GPU data to the CPU shadow; `upload()` pushes CPU changes to the GPU. The sync is manual, which means you control when the expensive operations happen.

### Partial Uploads

For vertex buffers, OpenRNDR supports partial synchronization:

```kotlin
override fun upload(offsetInBytes: Int, sizeInBytes: Int) {
    // Upload only a portion of the shadow to GPU
}
```

If you modify vertices 100-200 in a 10,000-vertex buffer, you can upload just those 400 bytes instead of the entire buffer. This matters for dynamic geometry where small regions change frequently.

### The Memory Tradeoff

Shadows double memory usage for the buffers that use them. A 4K RGBA texture takes 33MB on the GPU; with a shadow, it takes another 33MB on the CPU. For render targets that never need CPU access, that's pure waste.

The lazy allocation solves this: most buffers have `realShadow == null` and consume no extra memory. Only the buffers that actually need CPU access pay the cost.

---

## LRU Caching: Bounded Growth

### The Problem

Creative coding applications compile shaders dynamically—different blend modes, different vertex formats, different material parameters. Each combination might produce a different compiled shader. Without caching, you'd recompile the same shader every frame.

But unbounded caching has its own problem: memory grows without limit. Run the application long enough with enough shader variations, and you exhaust memory.

### OpenRNDR's Solution

A simple LRU (Least Recently Used) cache with fixed capacity:

```kotlin
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
}
```

The cache holds at most 1,000 entries. When you exceed capacity, the least-recently-used entries get evicted. The working set of "shaders you're actively using" stays cached; obscure combinations eventually fall out.

### Why 1,000?

The default capacity is tuned for typical creative coding workloads:
- 50-100 unique base shaders
- Each with multiple parameter combinations
- Maybe 5-10x variants for different blend modes, vertex formats, etc.

1,000 entries provides comfortable headroom without unbounded growth. For unusual workloads, the capacity is configurable.

### Dirty Flag Integration

The cache integrates with dirty flags via a `forceSet` parameter:

```kotlin
fun getOrSet(key: K, forceSet: Boolean, valueFunction: () -> V): V {
    if (!forceSet) {
        get(key)?.let { return it }
    }
    val v = valueFunction()
    set(key, v)
    return v
}
```

When `forceSet` is true, the cache is bypassed—the value function runs unconditionally and replaces any cached entry. This hooks into OpenRNDR's material system:

```kotlin
shadeStyleCache.getOrSet(cacheEntry, shadeStyle?.dirty ?: false) {
    shadeStyle?.dirty = false
    // ... generate shader structure
}
```

When a material's dirty flag is set, its shader recompiles regardless of cache state. The dirty flag integrates seamlessly with the caching layer.

---

## Session-Based Resource Tracking

### The Problem

GPU resources must be cleaned up eventually. In OpenGL or Vulkan, forgetting to delete a buffer leaks memory. But tracking every resource individually is tedious and error-prone.

### OpenRNDR's Solution: Sessions

A session is a scope that owns resources:

```kotlin
val renderTargets: Set<RenderTarget> = mutableSetOf()
val colorBuffers: Set<ColorBuffer> = mutableSetOf()
val depthBuffers: Set<DepthBuffer> = mutableSetOf()
val bufferTextures: Set<BufferTexture> = mutableSetOf()
val vertexBuffers: Set<VertexBuffer> = mutableSetOf()
val shaders: Set<Shader> = mutableSetOf()
// ... 10+ more resource types
```

When you create a resource, it registers with the current session:

```kotlin
override fun createColorBuffer(...): ColorBuffer {
    synchronized(this) {
        val colorBuffer = ColorBufferGL3.create(...)
        session?.track(colorBuffer)  // Register
        return colorBuffer
    }
}
```

When a session ends, all its resources clean up together:

```kotlin
colorBuffers as MutableSet<ColorBuffer>
colorBuffers.map { it }.forEach {
    it.destroy()
}
colorBuffers.clear()
```

### Hierarchical Sessions

Sessions can nest. A root session owns application-lifetime resources. A child session owns per-scene resources. A grandchild owns per-frame temporaries:

```kotlin
class Session {
    val parent: Session?
    val children: MutableList<Session>

    fun end() {
        children.forEach { it.end() }  // Cascade to children
        destroyAllResources()
    }
}
```

End the parent, and all descendants clean up automatically. This matches the natural hierarchy of creative coding applications: application → scene → frame → effect.

---

## Destruction Guards

### Double-Free Prevention

GPU resource destruction needs care. Delete a buffer twice, and you get undefined behavior—usually a crash, sometimes silent corruption. OpenRNDR guards against this:

```kotlin
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

The `isDestroyed` flag ensures the cleanup code runs exactly once. Subsequent calls are no-ops.

Notice the order: session untrack happens *before* the GL deletion. This prevents the session from holding a reference to a destroyed resource. The shadow is nulled, allowing garbage collection of the CPU-side memory.

### Shadow Cleanup

Sometimes you want to free the CPU shadow while keeping the GPU resource:

```kotlin
fun destroyShadow() {
    realShadow = null
}
```

After initial upload, you might not need CPU access anymore. Destroying the shadow reclaims CPU memory while the GPU resource continues working.

---

## Shader Dirty Tracking

### Cache Keys That Capture Everything

The shader cache needs keys that uniquely identify each shader variant:

```kotlin
private data class CacheEntry(
    val shadeStyle: ShadeStyle?,
    val vertexFormats: List<VertexFormat>,
    val instanceAttributeFormats: List<VertexFormat>
)
```

The key includes everything that affects compilation: the material, the vertex format, the instance attributes. Different vertex formats might enable different shader code paths, so they're part of the key.

### Integration with Materials

Materials track their own dirtiness:

```kotlin
class ShadeStyle {
    var dirty = true

    fun setParameter(name: String, value: Any) {
        parameters[name] = value
        dirty = true  // Mark for recompilation
    }
}
```

Change a material parameter, and its shader needs recompilation. The dirty flag propagates through the cache's `forceSet` mechanism.

---

## Lessons for the GPU Resource Pool

OpenRNDR's patterns suggest several approaches:

**Lazy shadows for optional CPU access.** Don't allocate CPU mirrors unless they're actually needed. The first access creates the shadow; most resources never need it.

**Explicit sync direction.** Distinguish `download()` (GPU → CPU) from `upload()` (CPU → GPU). Let user code control when expensive synchronization happens.

**Bounded caches with LRU eviction.** Fixed capacity prevents unbounded memory growth. LRU ensures the working set stays cached while cold entries eventually evict.

**Force-invalidation through caches.** The `forceSet` pattern lets dirty flags bypass caching cleanly. One mechanism handles both cache hits and dirty-triggered recomputation.

**Session-based resource ownership.** Group resources by lifetime scope. When the scope ends, everything in it cleans up. Hierarchical sessions match the natural structure of applications.

**Destruction guards.** Track whether a resource has been destroyed. Never double-free. Cleanup happens exactly once.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `openrndr-gl-common/src/.../Cache.kt` | 1-29 | LRU cache |
| `openrndr-gl-common/src/.../ShadeStructureGLCommon.kt` | 8-22 | Shader caching |
| `openrndr-jvm/openrndr-gl3/src/.../ColorBufferShadowGL3.kt` | 1-129 | Color buffer shadow |
| `openrndr-jvm/openrndr-gl3/src/.../VertexBufferGL3.kt` | 26-217 | Vertex buffer + shadow |
| `openrndr-jvm/openrndr-gl3/src/.../ColorBufferGL3.kt` | 712-939 | Lazy shadow, destruction |
| `openrndr-draw/src/.../Session.kt` | 99-276 | Session tracking |

---

## Related Documents

- [tixl.md](tixl.md) — Different dirty flag approach (reference/target)
- [../cache-invalidation.md](../cache-invalidation.md) — Cross-framework comparison
- [wgpu.md](wgpu.md) — Lower-level patterns these build on
