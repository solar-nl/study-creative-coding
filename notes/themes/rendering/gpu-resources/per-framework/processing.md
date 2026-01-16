# Processing: Surviving Context Loss

> What happens when the GPU forgets everything you told it?

---

## The Mobile Reality

Processing targets platforms where desktop assumptions don't hold. On Android, switching apps can destroy the GL context. On WebGL, resizing the canvas might recreate it. One moment your textures exist; the next, they're gone—and using the old handles produces undefined behavior.

This isn't a bug; it's a feature of resource-constrained environments. The system reclaims GPU memory when your app isn't visible. When you return, you must recreate everything.

Processing handles this gracefully. Every resource tracks which context created it. Before use, it checks if that context is still valid. If not, the resource disposes itself and—if needed—recreates on demand.

The question guiding this exploration: *how do you build a graphics framework that survives context loss?*

---

## Context Tracking: Every Resource Knows Its Origin

Every GPU resource in Processing stores a context ID:

```java
class VertexBuffer {
    protected int context;

    protected void create() {
        context = pgl.getCurrentContext();
        glres = new GLResourceVertexBuffer(this);
    }

    protected boolean contextIsOutdated() {
        boolean outdated = !pgl.contextIsCurrent(context);
        if (outdated) {
            dispose();
        }
        return outdated;
    }
}
```

When you create a buffer, it captures the current context ID. Before any operation, you can check `contextIsOutdated()`. If the context has changed, the resource automatically disposes itself.

The context check is cheap—one integer comparison. The disposal is immediate. No stale handles linger; no invalid operations execute.

```java
protected int createEmptyContext() {
    return -1;  // Sentinel: not yet bound
}

protected int getCurrentContext() {
    return glContext;
}

protected boolean contextIsCurrent(int other) {
    return other == -1 || other == glContext;
}
```

The sentinel value `-1` means "created but not yet bound to a context." This handles the case where you create a resource before the GL context exists. Once you actually allocate, it captures the real context ID.

---

## Exponential Growth: Doubling When Full

Processing doesn't know in advance how many vertices you'll draw. Start with a small buffer; grow it as needed:

```java
static protected final int INIT_VERTEX_BUFFER_SIZE = 256;
static protected final int INIT_INDEX_BUFFER_SIZE = 512;

static protected int expandArraySize(int currSize, int newMinSize) {
    int newSize = currSize;
    while (newSize < newMinSize) {
        newSize <<= 1;  // Double
    }
    return newSize;
}
```

Start at 256 vertices. Need 257? Double to 512. Need 1000? Double to 512, then 1024. The buffer is always a power of two, which helps GPU alignment and allocation.

The doubling strategy has a well-known property: amortized O(1) insertion. You pay for occasional expensive reallocations, but averaged over many insertions, the cost per element is constant.

```java
void polyVertexCheck() {
    if (polyVertexCount == polyVertices.length / 4) {
        int newSize = polyVertexCount << 1;  // Double

        expandPolyVertices(newSize);
        expandPolyColors(newSize);
        expandPolyNormals(newSize);
        expandPolyTexCoords(newSize);
        // ... expand all attribute arrays
    }

    firstPolyVertex = polyVertexCount;
    polyVertexCount++;
    lastPolyVertex = polyVertexCount - 1;
}
```

When the vertex count hits capacity, all related arrays double together. This keeps them synchronized—positions, colors, normals, texture coordinates all have matching capacity.

---

## Weak References for Automatic Cleanup

Processing uses Java's weak references to tie GPU resource cleanup to garbage collection:

```java
private static abstract class Disposable<T> extends WeakReference<T> {
    protected Disposable(T obj) {
        super(obj, refQueue);
        drainRefQueueBounded();
        reachableWeakReferences.add(this);
    }

    public void dispose() {
        reachableWeakReferences.remove(this);
        disposeNative();
    }

    abstract public void disposeNative();
}
```

Each GPU resource wrapper holds a weak reference to its Java object. When the Java object becomes unreachable (eligible for GC), the weak reference is enqueued. Processing periodically drains this queue, calling `disposeNative()` to free GL resources.

The concrete implementation for textures:

```java
protected static class GLResourceTexture extends Disposable<Texture> {
    int glName;
    private PGL pgl;
    private final int context;

    public GLResourceTexture(Texture tex) {
        super(tex);
        pgl = tex.pg.getPrimaryPGL();
        pgl.genTextures(1, intBuffer);
        tex.glName = intBuffer.get(0);

        this.glName = tex.glName;
        this.context = tex.context;
    }

    @Override
    public void disposeNative() {
        if (pgl != null) {
            if (glName != 0) {
                intBuffer.put(0, glName);
                pgl.deleteTextures(1, intBuffer);
                glName = 0;
            }
            pgl = null;
        }
    }
}
```

The GL texture is created in the constructor and deleted in `disposeNative()`. Context is part of the resource's identity—if the context changes, the resource needs recreation, not just disposal.

---

## Memory-Aware Caching

Processing faces memory pressure more acutely than desktop frameworks. Its caching adapts:

```java
protected static final int MAX_UPDATES = 10;
protected static final int MIN_MEMORY = 5;  // MB

protected void releasePixelBuffer() {
    double freeMB = Runtime.getRuntime().freeMemory() / 1E6;
    if (pixBufUpdateCount < MAX_UPDATES || freeMB < MIN_MEMORY) {
        pixelBuffer = null;
    }
}
```

If a buffer hasn't been used many times (< 10 updates), release it—it's probably not frequently needed. If free memory drops below 5MB, release it regardless—survival trumps convenience.

This heuristic balances two concerns: keeping frequently-used data cached (fast) versus releasing rarely-used data (memory-efficient). The threshold values come from experience with mobile devices where memory is scarce.

---

## Video Buffer Pooling

For video textures, Processing maintains a small pool:

```java
public static final int MAX_BUFFER_CACHE_SIZE = 3;

public void copyBufferFromSource(Object natRef, ByteBuffer byteBuf, int w, int h) {
    if (bufferCache == null) {
        bufferCache = new LinkedList<>();
    }

    if (bufferCache.size() + 1 <= MAX_BUFFER_CACHE_SIZE) {
        bufferCache.add(new BufferData(natRef, byteBuf.asIntBuffer(), w, h));
    } else {
        // Cache full—mark for disposal
        if (usedBuffers == null) {
            usedBuffers = new LinkedList<>();
        }
        usedBuffers.add(new BufferData(natRef, byteBuf.asIntBuffer(), w, h));
    }
}
```

Video frames arrive continuously. Caching the last few frames enables operations like pixel access without re-downloading from GPU. But caching too many wastes memory.

Three buffers is enough for typical use: current frame, previous frame, and one being processed. Beyond that, new frames push old ones to the disposal queue.

---

## FrameBuffer Context Resilience

Framebuffers need special handling because they compose multiple resources:

```java
protected boolean contextIsOutdated() {
    if (screenFb) return false;  // Screen FB is always valid

    boolean outdated = !pgl.contextIsCurrent(context);
    if (outdated) {
        dispose();
        for (int i = 0; i < numColorBuffers; i++) {
            colorBufferTex[i] = null;
        }
    }
    return outdated;
}
```

When a framebuffer's context becomes invalid, it disposes itself *and* nulls its color buffer references. Those textures are now invalid too—keeping references would allow accidental use of stale handles.

The screen framebuffer (ID 0) is special: it's provided by the windowing system, not created by your code. It survives context changes because it *is* the context's output.

---

## The Allocation Choreography

Processing separates array allocation from GL buffer allocation:

```java
void expandPolyVertices(int n) {
    float[] temp = new float[4 * n];
    PApplet.arrayCopy(polyVertices, 0, temp, 0, 4 * polyVertexCount);
    polyVertices = temp;
    if (!bufObjStreaming) {
        polyVerticesBuffer = PGL.allocateFloatBuffer(polyVertices);
    }
}
```

CPU-side arrays grow independently of GPU buffers. In "streaming" mode (mapping buffers directly), no CPU-side buffer is needed. In "retained" mode, both exist and must stay synchronized.

This flexibility matters for performance tuning. Streaming is faster when data changes every frame; retained is faster when data is static. Processing supports both patterns with the same high-level API.

---

## Lessons for the GPU Resource Pool

Processing's patterns suggest several approaches:

**Context tracking for portability.** When targeting WebGPU (where similar context loss can occur), tracking resource-context binding enables graceful recovery.

**Exponential growth for dynamic data.** When you don't know the final size, doubling is simple and efficient. The power-of-two sizes help with alignment and allocation.

**Weak references for cleanup.** Rust doesn't have garbage collection, but similar patterns exist with `Weak` and explicit cleanup passes. The principle—tie cleanup to reachability—translates.

**Memory-aware caching.** On constrained platforms, cache aggressively used data and release rarely-used data. Runtime memory checks can guide the heuristic.

**Null references on context loss.** When a resource becomes invalid, null or invalidate all references to it. Prevent accidental use of stale handles.

**Separate CPU and GPU allocation.** Growing CPU arrays doesn't require regrowing GPU buffers immediately. Batch the GL reallocation for efficiency.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `opengl/VertexBuffer.java` | 41, 50-51, 60-61, 80-86 | Context tracking |
| `opengl/Texture.java` | 82-95, 136-141, 1186-1192 | Texture context management |
| `opengl/PGraphicsOpenGL.java` | 31-32, 7120-7126 | Growth constants, algorithm |
| `opengl/PGraphicsOpenGL.java` | 74-87, 889-984 | Disposable wrapper, GL resources |
| `opengl/PGL.java` | 1175-1192 | Context ID management |
| `opengl/Texture.java` | 815-880, 1326-1341 | Buffer caching, memory-aware release |
| `opengl/FrameBuffer.java` | 44-47, 330-354, 371-382 | FBO context tracking |

---

## Related Documents

- [openrndr.md](openrndr.md) — Session-based cleanup, similar concerns
- [../allocation-strategies.md](../allocation-strategies.md) — Growth strategy comparison
- [../reclamation-timing.md](../reclamation-timing.md) — When to free resources
