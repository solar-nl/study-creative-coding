# cables.gl: Stack-Based State and Comprehensive Profiling

> How do you make GPU state management safe in a visual programming environment?

---

## The Visual Programming Challenge

cables.gl faces a unique challenge: non-programmers build GPU graphics by connecting boxes. They don't think about state management, cleanup, or resource lifecycles. Yet the node graph they create must translate into correct, efficient WebGL and WebGPU calls.

This means cables can't rely on user discipline. The framework must enforce safety through architecture. Push/pop state stacks ensure resources are correctly restored. Profiling catches performance problems early. Heavy event tracking surfaces expensive operations in the editor UI.

The question guiding this exploration: *how do you make GPU resource management safe for users who don't know they're managing GPU resources?*

---

## Stack-Based State Management

### The Problem

GPU state is global. Set a shader, and it stays set until you set another. Forget to restore the previous shader after a render pass, and everything downstream draws wrong.

In code, careful programmers track state manually. In a visual node graph, where execution order is implicit and nodes are authored by different people, manual tracking is impossible.

### The Stack Solution

cables wraps every piece of GPU state in a push/pop stack:

```javascript
export class CglContext extends CgContext {
    constructor(_patch) {
        // ...
        this._shaderStack = [];
        this._stackBlendMode = [];
        this._stackBlendModePremul = [];
        this._stackBlend = [];
        this._stackDepthFunc = [];
        this._stackCullFaceFacing = [];
        this._stackCullFace = [];
        this._stackDepthWrite = [];
        this._stackDepthTest = [];
        this._stackStencil = [];
        this._viewPortStack = [];
        this._frameBufferStack = [];
        this._glFrameBufferStack = [];
    }

    pushShader(shader) {
        this._shaderStack.push(shader);
        this._currentShader = shader;
    }

    popShader() {
        if (this._shaderStack.length === 0)
            throw new Error("Invalid shader stack pop!");
        this._shaderStack.pop();
        this._currentShader = this._shaderStack[this._shaderStack.length - 1];
    }
}
```

Every operator that modifies state must push before and pop after:

```javascript
// Inside a "set shader" operator
execute() {
    cgl.pushShader(this.shader);
    this.triggerChildren();  // Execute child nodes
    cgl.popShader();         // Restore previous state
}
```

### Frame Boundary Validation

At frame end, cables validates all stacks are empty:

```javascript
endFrame() {
    if (this._shaderStack.length > 0)
        this.logStackError("_shaderStack length !=0 at end of rendering...");
    if (this._stackCullFace.length > 0)
        this.logStackError("_stackCullFace length !=0 at end of rendering...");
    if (this._viewPortStack.length > 0)
        this.logStackError("viewport stack length !=0 at end of rendering...");
    // ... check all stacks
}
```

Unbalanced push/pop is a bug in the operator. The error message tells the user which state was corrupted, helping them find the broken node.

---

## Comprehensive Profiling

### The ProfileData Class

cables tracks nearly every GPU operation through a centralized `ProfileData` class:

```javascript
export class ProfileData {
    constructor(cgl) {
        this._cgl = cgl;

        // Texture operations
        this.profileTextureNew = 0;
        this.profileTextureDelete = 0;
        this.profileTextureResize = 0;
        this.profileGenMipMap = 0;

        // Shader operations
        this.profileShaderCompiles = 0;
        this.profileShaderBinds = 0;
        this.profileShaderGetUniform = 0;
        this.shaderCompileTime = 0;

        // Mesh operations
        this.profileMeshDraw = 0;
        this.profileMeshSetGeom = 0;
        this.profileMeshAttributes = 0;
        this.profileMeshNumElements = 0;

        // Buffer operations
        this.profileFrameBuffercreate = 0;
        this.profileFramebuffer = 0;
        this.profileEffectBuffercreate = 0;

        // Heavy events (expensive operations)
        this.heavyEvents = [];
        this.counts = {};
    }

    clear() {
        // Reset all counters at frame start
        this.profileTextureNew = 0;
        this.profileShaderCompiles = 0;
        // ... reset all
    }
}
```

### Per-Operation Instrumentation

Every GPU operation increments the appropriate counter:

```javascript
// In Texture constructor
constructor(__cgl, options = {}) {
    // ...
    this._cgl.profileData.profileTextureNew++;
    this._cgl.profileData.addHeavyEvent(
        "texture created",
        this.name,
        options.width + "x" + options.height
    );
}

// In Texture.delete()
delete() {
    this.deleted = true;
    this._cgl.profileData.profileTextureDelete++;
    this._cgl.gl.deleteTexture(this.tex);
}

// In Shader.compile()
_compile() {
    this._cgl.profileData.profileShaderCompiles++;
    this._cgl.profileData.profileShaderCompileName = this._name;
    this._cgl.profileData.addHeavyEvent(
        "shader compile",
        this._name + " [" + this._compileReason + "]"
    );
    // ... actual compilation
}
```

### Heavy Events

Expensive operations emit "heavy events" that the editor UI can surface:

```javascript
addHeavyEvent(event, name, info) {
    const e = {
        "event": event,
        "name": name,
        "info": info,
        "date": performance.now()
    };
    this.heavyEvents.push(e);
    this._cgl.emitEvent("heavyEvent", e);
}
```

When a user creates a 4096x4096 texture or triggers a shader recompile, they see it immediately in the editor. This feedback helps non-programmers understand why their patch is slow.

---

## Resource Lifecycle

### The deleted Flag

cables uses a simple boolean flag to track resource validity:

```javascript
export class Texture extends CgTexture {
    constructor(__cgl, options = {}) {
        // ...
        this.tex = this._cgl.gl.createTexture();
        this.deleted = false;
    }

    delete() {
        if (this.loading) {
            // Can't delete while loading—would corrupt async operation
            return;
        }

        this.deleted = true;
        this.width = 0;
        this.height = 0;
        this._cgl.profileData.profileTextureDelete++;
        this._cgl.gl.deleteTexture(this.tex);
        this.image = null;
        this.tex = null;
    }

    dispose() {
        this.delete();
    }
}
```

### Framebuffer Disposal Guards

Framebuffers track their disposed state and warn on use-after-dispose:

```javascript
export class Framebuffer2 {
    constructor(cgl, options) {
        this._disposed = false;
        // ...
    }

    dispose() {
        this._disposed = true;

        for (let i = 0; i < this._numRenderBuffers; i++)
            this._colorTextures[i].delete();
        if (this._textureDepth) this._textureDepth.delete();

        for (let i = 0; i < this._numRenderBuffers; i++)
            this._cgl.gl.deleteRenderbuffer(this._colorRenderbuffers[i]);
        this._cgl.gl.deleteRenderbuffer(this._depthRenderbuffer);
        this._cgl.gl.deleteFramebuffer(this._frameBuffer);
    }

    renderStart() {
        if (this._disposed) {
            return this._log.warn("disposed framebuffer renderStart...");
        }
        // ... normal render start
    }

    setSize(width, height) {
        if (this._disposed) {
            return this._log.warn("disposed framebuffer setsize...");
        }
        // ... normal resize
    }
}
```

### Immediate Deletion

Unlike Babylon.js's deferred deletion queue, cables deletes resources immediately. This is simpler but requires more careful coordination with async operations (note the loading check in `delete()`).

---

## WebGPU Dirty Tracking

### needsUpdate Pattern

For WebGPU buffers, cables uses a `needsUpdate` flag similar to Three.js:

```javascript
export class CgpGguBuffer extends Events {
    needsUpdate = true;

    setData(arr) {
        this.floatArr = new Float32Array(arr);
        this.setLength(this.floatArr.length);
        this.needsUpdate = true;
    }

    get gpuBuffer() {
        if (!this.#gpuBuffer || this.needsUpdate)
            this.updateGpuBuffer();
        return this.#gpuBuffer;
    }

    updateGpuBuffer(cgp = null) {
        // ... create/update GPU buffer
        this.#cgp.device.queue.writeBuffer(
            this.#gpuBuffer, 0,
            this.floatArr.buffer,
            this.floatArr.byteOffset,
            this.floatArr.byteLength
        );
        this.needsUpdate = false;
    }
}
```

### Pipeline Rebuild Tracking

Shaders and meshes track when pipelines need rebuilding:

```javascript
export class RenderPipeline extends Pipeline {
    setPipeline(shader, mesh = null) {
        let needsRebuildReason = "";

        if (!this.#renderPipeline)
            needsRebuildReason = "no renderpipeline";
        if (this.#old.mesh != mesh)
            needsRebuildReason = "mesh changed";
        if (this.#old.shader != shader)
            needsRebuildReason = "shader changed";

        if (shader.needsPipelineUpdate) {
            needsRebuildReason = "shader needs update: " + shader.needsPipelineUpdate;
            shader.needsPipelineUpdate = "";
        }

        if (mesh.needsPipelineUpdate) {
            needsRebuildReason = "mesh needs update";
            mesh.needsPipelineUpdate = false;
        }

        if (needsRebuildReason) {
            this.rebuild(needsRebuildReason);
        }
    }
}
```

The reason string aids debugging—when a pipeline rebuilds, you know why.

---

## Bind Group Management

### Binding Objects

cables wraps WebGPU bind groups with explicit dirty tracking:

```javascript
export class BindGroup {
    needsPipelineUpdate = false;
    #gpuBindGroups = [];
    #bindings = [];

    addBinding(b) {
        const oldBinding = this.getBindingByName(b.name);
        if (oldBinding) this.removeBinding(oldBinding);

        b.needsRebuildBindgroup = true;
        this.#bindings.push(b);
        this.setBindingNums();

        return b;
    }

    create(shader) {
        // ...
        this.#cgp.profileData.count("bindgroup created", this.name);
        // ... create GPU bind group
    }
}
```

### Binding-Level Dirty Flags

Individual bindings track their own dirty state:

```javascript
// In binding classes
needsRebuildBindgroup = false;

update() {
    this.needsRebuildBindgroup = true;
}
```

When any binding changes, the containing bind group knows to rebuild.

---

## Texture Comparison for Caching

cables provides a utility for checking if textures can share settings:

```javascript
compareSettings(tex) {
    if (!tex) return false;
    return (
        tex.width == this.width &&
        tex.height == this.height &&
        tex.filter == this.filter &&
        tex.wrap == this.wrap &&
        tex.textureType == this.textureType &&
        tex.unpackAlpha == this.unpackAlpha &&
        tex.anisotropic == this.anisotropic &&
        tex.shadowMap == this.shadowMap &&
        tex.texTarget == this.texTarget &&
        tex.flip == this.flip
    );
}
```

This enables texture reuse decisions—if two textures have the same settings, they can potentially share underlying resources.

---

## Lessons for the GPU Resource Pool

cables.gl's patterns suggest several approaches:

**Stack-based state for composability.** When rendering is hierarchical (which it always is), push/pop stacks prevent state corruption. Validate at frame boundaries to catch bugs early.

**Comprehensive profiling from day one.** Tracking every GPU operation adds minimal overhead but provides invaluable debugging information. The cost is worth it, especially for users who don't understand GPU performance.

**Heavy event notifications.** Expensive operations should emit events. This enables UI feedback, logging, and performance monitoring without coupling the renderer to specific UI code.

**Simple deletion with loading guards.** Immediate deletion is simpler than deferred queues. Guard against deleting resources that are still loading or in use.

**Reason strings for pipeline rebuilds.** When tracking dirty state, record *why* something is dirty. This transforms opaque "rebuilt pipeline" into actionable "rebuilt pipeline: shader uniforms changed."

**Texture comparison for pooling.** If you can compare texture settings, you can implement texture pooling. The comparison function becomes the cache key.

---

## Source Files

| File | Key Lines | Purpose |
|------|-----------|---------|
| `cgl/cgl_state.js` | 69-84, 452-500 | Stack declarations, push/pop shader |
| `cgl/cgl_state.js` | 389-395 | Frame boundary validation |
| `cg/cg_profiledata.js` | 1-103 | ProfileData class |
| `cgl/cgl_texture.js` | 27-89, 339-361 | Texture lifecycle, deleted flag |
| `cgl/cgl_framebuffer2.js` | 166-176, 369, 410 | Framebuffer disposal guards |
| `cgp/cgp_gpubuffer.js` | 26, 60-73, 97-140 | needsUpdate pattern |
| `cgp/cgp_renderpipeline.js` | 66-99 | Pipeline rebuild tracking |
| `cgp/binding/bindgroup.js` | 16, 79-89, 166 | Bind group dirty tracking |

All paths relative to: `visual-programming/cables/src/corelibs/`

---

## Related Documents

- [tixl.md](tixl.md) — Another visual programming tool with dirty flag patterns
- [threejs.md](threejs.md) — Similar needsUpdate pattern
- [babylonjs.md](babylonjs.md) — Comparison: deferred vs immediate deletion
- [../cache-invalidation.md](../cache-invalidation.md) — Dirty tracking patterns
