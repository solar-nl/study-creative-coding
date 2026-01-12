# Babylon.js Frame Graph

> Declarative render pipeline composition — from imperative chaos to structured DAGs

---

## The Problem: Render Pipeline Complexity

Modern rendering involves shadow maps, main passes, post-processing, effect layers, depth peeling, and more. Traditional imperative rendering requires manually ordering draw calls, managing render targets, and handling texture lifecycles. Dependencies between passes are implicit and error-prone.

Consider a typical frame:
1. Render shadow maps (one per light)
2. Render depth pre-pass
3. Render opaque geometry
4. Render transparent geometry (sorted)
5. Apply SSAO
6. Apply bloom
7. Apply tone mapping
8. Render UI overlay

Each step has dependencies. SSAO needs the depth buffer. Bloom needs the color buffer. Shadow maps must complete before main rendering. Managing this imperatively means tracking state everywhere.

---

## The Solution: Frame Graph

Babylon.js 7.0 introduced **FrameGraph**, a task-based declarative system where developers compose a **Directed Acyclic Graph (DAG)** of rendering operations.

The key insight: treat **render passes as data** rather than **render passes as code**. This enables composition, optimization, and debugging.

```
┌─────────────────────────────────────────────────────────────┐
│  User defines tasks → FrameGraph analyzes → Engine executes │
└─────────────────────────────────────────────────────────────┘
```

---

## Core Architecture

| Component | Purpose |
|-----------|---------|
| **FrameGraph** | Orchestrates tasks, manages texture allocation, drives execution |
| **FrameGraphTask** | Abstract node in graph; defines `record()` method |
| **FrameGraphPass** | Actual render operation (compute or draw) |
| **FrameGraphTextureHandle** | Opaque ID for textures; enables deferred allocation |
| **FrameGraphTextureManager** | Allocates/reuses GPU textures based on lifetimes |
| **FrameGraphRenderContext** | Per-pass context with bindings and render target management |

---

## Execution Flow

The system operates in distinct phases:

```
1. DEFINITION ──────────────────────────────────────────────────
   User creates FrameGraph and adds Tasks

2. RECORDING ───────────────────────────────────────────────────
   await frameGraph.buildAsync()
   Each task.record() declares passes and texture dependencies

3. ALLOCATION ──────────────────────────────────────────────────
   TextureManager computes lifetimes, allocates textures
   Resource aliasing: multiple handles → same GPU texture

4. INITIALIZATION ──────────────────────────────────────────────
   Passes create render targets, compile shaders

5. EXECUTION (per frame) ───────────────────────────────────────
   Update history textures (temporal effects)
   For each task: task._execute()
     For each pass: pass._execute()
       Bind targets → Run logic → Restore state
```

---

## Texture Handle System

The key innovation is **handle indirection**. Texture handles are opaque IDs assigned before actual GPU textures exist.

```typescript
type FrameGraphTextureHandle = number;

// Special handles for built-in textures
const backbufferColorTextureHandle = 0;
const backbufferDepthStencilTextureHandle = 1;
```

**Why handles instead of textures directly?**

1. **Deferred allocation** — Handles assigned during recording, textures created later
2. **Resource aliasing** — Multiple handles can map to the same GPU texture if lifetimes don't overlap
3. **History textures** — Handles automatically flip between read/write for temporal effects
4. **Validation** — TextureManager enforces handle validity

```typescript
// Texture creation is declarative
const handle = frameGraph.createTexture({
    size: { width: 1920, height: 1080 },
    options: { format: TextureFormat.RGBA8 },
    sizeIsPercentage: false,
    isHistoryTexture: false,
});
```

---

## Task Composition

Tasks compose into hierarchies. Complex effects are built from reusable primitives.

```typescript
// A glow layer task composes multiple sub-tasks
export class FrameGraphBaseLayerTask extends FrameGraphTask {
    private readonly _clearLayerTextures: FrameGraphClearTextureTask;
    private readonly _objectRenderer: FrameGraphObjectRendererTask;
    private readonly _blurX: FrameGraphBlurTask[];
    private readonly _blurY: FrameGraphBlurTask[];

    constructor(name: string, frameGraph: FrameGraph, scene: Scene) {
        super(name, frameGraph);

        // Compose sub-tasks
        this._clearLayerTextures = new FrameGraphClearTextureTask(...);
        this._objectRenderer = new FrameGraphObjectRendererTask(...);

        for (let i = 0; i < numBlurPasses; i++) {
            this._blurX.push(new FrameGraphBlurTask(...));
            this._blurY.push(new FrameGraphBlurTask(...));
        }
    }

    public record(): void {
        // Record in logical order — FrameGraph handles dependencies
        this._clearLayerTextures.record();
        this._objectRenderer.record();

        for (let i = 0; i < this._blurX.length; i++) {
            this._blurX[i].record();
            this._blurY[i].record();
        }
    }
}
```

---

## Pass Types

### FrameGraphPass

Base pass for compute or utility operations:

```typescript
const pass = frameGraph.addPass("myPass");
pass.setExecuteFunc((context: FrameGraphContext) => {
    // Custom logic here
});
```

### FrameGraphRenderPass

Specialized for rendering to textures:

```typescript
const renderPass = frameGraph.addRenderPass("mainRender");
renderPass.setRenderTarget(colorHandle);
renderPass.setRenderTargetDepth(depthHandle);

renderPass.setExecuteFunc((context: FrameGraphRenderContext) => {
    // Render geometry
    this._renderer.render(objectList, camera);
});
```

### FrameGraphObjectListPass

Collects objects to render (culling, sorting):

```typescript
const cullPass = frameGraph.addObjectListPass("cullPass");
cullPass.objectList = new FrameGraphObjectList();
// Objects collected and sorted
```

---

## History Textures for Temporal Effects

Temporal anti-aliasing, motion blur, and other effects need access to the previous frame's data. FrameGraph handles this with history textures.

```typescript
const handle = frameGraph.createTexture({
    ...options,
    isHistoryTexture: true,
});
```

Internally, history textures are double-buffered:

```typescript
type HistoryTexture = {
    textures: [Nullable<InternalTexture>, Nullable<InternalTexture>];
    index: number;  // 0 or 1, flipped each frame
};

// Each frame:
// - Read from textures[index]
// - Write to textures[1 - index]
// At frame end: index = 1 - index
```

No manual ping-pong management required.

---

## Concrete Task Examples

### Simple Custom Task

```typescript
export class FrameGraphExecuteTask extends FrameGraphTask {
    public func: (context: FrameGraphContext) => void;

    public record(): FrameGraphPass<FrameGraphContext> {
        const pass = this._frameGraph.addPass(this.name);
        pass.setExecuteFunc((context) => {
            this.func(context);
        });
        return pass;
    }
}
```

### Object Rendering

```typescript
export class FrameGraphObjectRendererTask extends FrameGraphTask {
    public targetTexture: FrameGraphTextureHandle;
    public depthTexture?: FrameGraphTextureHandle;
    public objectList: FrameGraphObjectList;

    public record(): void {
        const renderPass = this._frameGraph.addRenderPass(this.name);
        renderPass.setRenderTarget(this.targetTexture);
        renderPass.setRenderTargetDepth(this.depthTexture);

        renderPass.setExecuteFunc((context) => {
            this._renderer.render(this.objectList, this.camera);
        });
    }
}
```

### Post-Processing

```typescript
export class FrameGraphPostProcessTask extends FrameGraphTask {
    public readonly postProcess: ThinPostProcess;
    public sourceTexture: FrameGraphTextureHandle;
    public outputTexture: FrameGraphTextureHandle;

    public record(): void {
        const renderPass = this._frameGraph.addRenderPass(this.name);
        renderPass.setRenderTarget(this.outputTexture);

        renderPass.setExecuteFunc((context) => {
            const source = context.getTextureFromHandle(this.sourceTexture);
            this.postProcess.render(source, this.outputTexture);
        });
    }
}
```

---

## Design Patterns

### Two-Phase Record/Execute

Separating "what the graph looks like" from "how it runs" enables analysis:

```typescript
abstract class FrameGraphTask {
    // RECORDING: Define structure
    public abstract record(): void;

    // EXECUTION: Run the passes
    public _execute(): void {
        for (const pass of this._passes) {
            pass._execute();
        }
    }
}
```

### Observable Hooks

Tasks expose lifecycle events without coupling:

```typescript
export class FrameGraphTask {
    public onTexturesAllocatedObservable: Observable<FrameGraphRenderContext>;
    public onBeforeTaskExecute: Observable<FrameGraphTask>;
    public onAfterTaskExecute: Observable<FrameGraphTask>;
}
```

### Disabled Pass Fallback

Tasks can have alternate passes when toggled off:

```typescript
export class FrameGraphTask {
    private readonly _passes: IFrameGraphPass[] = [];
    private readonly _passesDisabled: IFrameGraphPass[] = [];

    // Toggle between active and disabled passes
    // No graph rebuild needed
}
```

### Type-Safe Pass Discrimination

Runtime type checking without casting overhead:

```typescript
public static IsRenderPass(pass: IFrameGraphPass): pass is FrameGraphRenderPass {
    return (pass as FrameGraphRenderPass).setRenderTarget !== undefined;
}
```

---

## Comparison with Traditional Pipeline

| Aspect | Imperative (Traditional) | FrameGraph |
|--------|--------------------------|------------|
| Pass ordering | Manual, error-prone | Automatic from dependencies |
| Texture lifetime | Manual allocation/disposal | Automatic, with aliasing |
| Composition | Callback chains | Task hierarchies |
| Debugging | Scattered state | Inspectable graph |
| Optimization | Manual batching | Automatic pass merging |

---

## Patterns for Rust Framework

1. **Handle Indirection** — Use opaque IDs for GPU resources, enabling deferred allocation and aliasing
2. **Two-Phase Build** — Separate graph construction from execution
3. **Task Composition** — Build complex effects from reusable primitives
4. **History Textures** — Built-in temporal buffer management
5. **Observable Hooks** — Lifecycle events for extensibility

```rust
// Conceptual Rust API
let mut frame_graph = FrameGraph::new(&device);

let depth_handle = frame_graph.create_texture(TextureDesc {
    size: (1920, 1080),
    format: TextureFormat::Depth24,
});

let color_handle = frame_graph.create_texture(TextureDesc {
    size: (1920, 1080),
    format: TextureFormat::Rgba8,
});

frame_graph.add_task("depth_prepass", |builder| {
    builder.writes(depth_handle);
    builder.render(|ctx| {
        // Depth-only rendering
    });
});

frame_graph.add_task("main_pass", |builder| {
    builder.reads(depth_handle);
    builder.writes(color_handle);
    builder.render(|ctx| {
        // Main scene rendering
    });
});

frame_graph.compile()?;  // Allocate textures, validate dependencies
frame_graph.execute(&mut encoder)?;  // Run all passes
```

---

## Key Source Files

| Purpose | Path |
|---------|------|
| Main orchestrator | `FrameGraph/frameGraph.ts` |
| Type definitions | `FrameGraph/frameGraphTypes.ts` |
| Base task class | `FrameGraph/frameGraphTask.ts` |
| Pass base class | `FrameGraph/Passes/pass.ts` |
| Render pass | `FrameGraph/Passes/renderPass.ts` |
| Object list pass | `FrameGraph/Passes/objectListPass.ts` |
| Texture manager | `FrameGraph/frameGraphTextureManager.ts` |
| Render context | `FrameGraph/frameGraphRenderContext.ts` |
| Execute task | `FrameGraph/Tasks/Misc/executeTask.ts` |
| Object renderer task | `FrameGraph/Tasks/Rendering/objectRendererTask.ts` |
| Post-process tasks | `FrameGraph/Tasks/PostProcesses/` |

All paths relative to: `packages/dev/core/src/`

---

## See Also

- [Rendering Pipeline](rendering-pipeline.md) — Traditional imperative pipeline
- [WebGPU Engine](webgpu-engine.md) — How draw calls become GPU commands
- [wgpu](https://github.com/gfx-rs/wgpu) — Rust GPU library with similar render pass concepts
