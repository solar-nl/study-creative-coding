# Node Graph Rendering: Three Bridges to the GPU

> How Werkkzeug4, cables.gl, and tixl translate operators to pixels

---

## The Translation Challenge

Every visual programming system faces a fundamental gap. Artists work with boxes and wires, thinking in terms of transformations and effects. GPUs work with command buffers and pipeline states, thinking in terms of draw calls and shader bindings. Something must translate between these worlds.

The translation is not straightforward. A node graph represents potential computation, a declaration of what could happen given certain inputs. The GPU demands imperative commands, explicit sequences of state changes and draw operations executed in precise order. The graph is a plan; the GPU wants actions.

Three frameworks have built three distinct bridges across this gap. Each bridge reflects its era's constraints and priorities. Werkkzeug4, emerging from the demoscene's obsession with minimal runtime overhead, constructs a highway: wide lanes, high speed, but requiring significant construction time before the first car can cross. cables.gl, born for the web's demand for immediate feedback, builds a cable car: continuous flow, responsive to changes mid-journey, but with limited throughput per trip. tixl, designed for live performance where stability meets flexibility, builds a drawbridge: efficient when stable, with controlled overhead for changes.

---

## Operator to GPU Pipeline

### Werkkzeug4: The Highway

The highway model compiles the visual graph into a flat command buffer before any pixel touches the screen. When the artist clicks "Calculate," the entire graph transforms into a linear sequence of operations. During rendering, no graph traversal occurs. The executor simply walks through commands in order.

This separation creates a clean boundary between editing and execution. The graph can change arbitrarily while the current frame renders using last compile's commands. Changes take effect only on the next explicit compile. The trade-off is latency: parameter tweaks require recompilation to see.

The compilation happens in `wBuilder::Execute()`, which orchestrates six phases. First, parsing walks the operator graph recursively, building an intermediate node representation. The system detects cycles during this traversal, preventing infinite loops. Second, optimization checks the cache and inserts type conversion nodes where needed. Third, type verification ensures all connections are valid. Fourth, the system handles any operators marked as "slow" that should be skipped during interactive editing. Fifth, output generation produces the actual command list by walking the node tree depth-first. Sixth, execution runs through those commands linearly.

```cpp
// Werkkzeug4: The compile-then-execute orchestration
wObject *wBuilder::Execute(wExecutive &exe, wOp *root)
{
  if(!Parse(root)) goto ende;      // Build node graph
  if(!Optimize(1)) goto ende;      // Insert caches, conversions
  if(!TypeCheck()) goto ende;      // Verify type compatibility

  if(Root->LoadCache)              // Fast path: result already cached
  {
    result = Root->Op->Cache;
    result->AddRef();
  }
  else
  {
    if(!Output(exe)) goto ende;    // Generate command list
    result = exe.Execute(progress); // Execute commands sequentially
  }
}
```

Commands are self-contained. Each `wCommand` captures a snapshot of parameter values at compile time. The executor runs through commands without referring back to the original graph. This isolation enables the reference-stealing optimization: when a command is the sole consumer of its input, the executor takes ownership rather than copying.

### cables.gl: The Cable Car

The cable car model executes operators directly during graph traversal. When a trigger signal flows through a connection, the receiving operator runs immediately. No intermediate compilation step exists. Changes take effect on the next frame, or even mid-frame for certain operators.

The key mechanism is the state stack. Before an operator modifies GPU state, it pushes the current state. After execution, it pops. This push-pop pattern creates isolated scopes. An operator need not know what states its neighbors set because the stack restores context automatically.

```javascript
// cables.gl: State stack in CglContext
pushShader(shader) {
    if (this.tempData.forceShaderMods) {
        for (let i = 0; i < this.tempData.forceShaderMods.length; i++) {
            shader = this.tempData.forceShaderMods[i].bind(shader, false);
        }
    }
    this._shaderStack.push(shader);
    this._currentShader = shader;
}

popShader() {
    if (this.tempData.forceShaderMods) {
        for (let i = 0; i < this.tempData.forceShaderMods.length; i++) {
            this.tempData.forceShaderMods[i].unbind(false);
        }
    }
    this._shaderStack.pop();
    this._currentShader = this._shaderStack[this._shaderStack.length - 1];
}
```

The cables.gl context maintains stacks for viewports, framebuffers, shaders, depth testing, blending, culling, and stencil operations. At frame end, `endFrame()` verifies all stacks have returned to their initial state, catching mismatched push/pop pairs that would cause state leakage.

This approach trades compilation overhead for runtime flexibility. Every parameter change takes effect immediately. But every frame pays the cost of graph traversal and stack operations.

### tixl: The Drawbridge

The drawbridge model produces Command objects during evaluation but defers their execution. Operators return data structures describing what should happen rather than immediately performing GPU operations. This separation enables composition: commands can be combined, filtered, or transformed before execution.

```csharp
// tixl: Command as a deferred action pair
public class Command
{
    public Action<EvaluationContext> PrepareAction { get; init; }
    public Action<EvaluationContext> RestoreAction { get; set; }
}
```

The `PrepareAction` sets up GPU state. The `RestoreAction` cleans up afterward. This mirrors the push-pop pattern of cables.gl but makes the pairing explicit in the type system. Forgetting to restore becomes a compile-time error rather than a runtime state leak.

The key optimization is the dirty flag system. Each slot tracks whether its value has changed since last evaluation. The `DirtyFlag` class maintains a reference counter and target counter. When they differ, the slot is dirty and needs recomputation. Commands always re-execute because their effects are temporal, but pure data operators skip work when inputs are unchanged.

```csharp
// tixl: Conditional update based on dirty flags
public void Update(EvaluationContext context)
{
    if (_dirtyFlag.IsDirty || _valueIsCommand)
    {
        OpUpdateCounter.CountUp();
        UpdateAction?.Invoke(context);
        _dirtyFlag.Clear();
        _dirtyFlag.SetUpdated();
    }
}
```

The drawbridge rises only when something needs to cross. Stable portions of the graph skip evaluation entirely.

**Trade-off Table**

| Bridge Type | Compilation Cost | Runtime Cost | Flexibility |
|-------------|------------------|--------------|-------------|
| Highway (Wz4) | High once | Very low | Low during render |
| Cable car (cables) | None | Per-operator | High |
| Drawbridge (tixl) | Medium | Low | Medium |

---

## Resource Management

### The Lifecycle Problem

GPU resources present a lifecycle challenge that CPU-only programming rarely encounters. Textures consume VRAM, which is limited and precious. Shader programs must be compiled and linked, an expensive operation. Vertex buffers need upload to GPU memory. Framebuffers require compatible texture attachments.

Who creates these resources? Who owns them? When are they freed? Each bridge handles cargo differently. The highway pre-loads everything at toll booths. The cable car checks tickets continuously. The drawbridge inventories cargo only when needed.

### Werkkzeug4: Reference Stealing

Werkkzeug4 treats GPU resources as reference-counted objects inheriting from `wObject`. The cache stores `wObject` pointers keyed by operator identity and CallId context. When an operator produces output, the result enters the cache with a reference count of one.

The clever optimization is reference stealing during execution. When a command is the sole owner of its input and transforms in-place, the executor checks `RefCount == 1`. If true, it steals the reference, making the output point to the input object itself.

```cpp
// Werkkzeug4: Reference stealing during execution
if(cmd->PassInput >= 0)
{
    wObject *in = cmd->GetInput(cmd->PassInput);
    if(in && in->RefCount == 1)
    {
        cmd->Output = in;  // Steal ownership
        cmd->Inputs[cmd->PassInput]->Output = 0;
    }
}
```

This pattern eliminates allocations for chains of in-place operations. A sequence of Add, Multiply, and Normalize on a mesh can share a single buffer, each operation transforming the data in place. Only the final consumer actually owns the result.

The CallId system prevents cache collisions for shared operators. A Blur inside a subroutine called twice with different inputs gets distinct cache entries, one for each CallId context. Cache lookups require matching both operator identity and context.

### cables.gl: WebGL Managed

cables.gl delegates much of resource management to WebGL's own reference counting. Textures receive integer slot assignments. Each shader material receives an incrementing `_materialId` used for cache lookups, enabling reuse across operators that request identical shader configurations.

The state stack inherently prevents resource leaks for per-frame resources. Framebuffers pushed onto the stack get popped and unbound automatically. Shaders pushed are popped. The paired operations guarantee cleanup.

Longer-lived resources like compiled shaders persist in caches keyed by configuration hash. The WebGL context manages GPU memory directly, garbage collecting unused resources. This simplifies operator implementation at the cost of less predictable memory usage.

### tixl: Format-Aware Pools

tixl classifies GPU buffers by intended usage. The system distinguishes static buffers (geometry that rarely changes), dynamic buffers (particle data updated each frame), and render targets (framebuffer attachments for post-processing chains).

Shader management uses compiled bytecode caching. When an operator requests a shader, the system checks if matching bytecode already exists. The `AbstractShader` base class wraps SharpDX shader objects and manages their lifecycle through typed wrappers (`PixelShader`, `VertexShader`, etc.) that enforce correct usage at compile time. A `PixelShader` cannot be bound where a `VertexShader` is expected; the C# type system catches such errors before runtime.

**Trade-off Table**

| Strategy | Memory Efficiency | Complexity | Predictability |
|----------|-------------------|------------|----------------|
| Reference stealing | Excellent | Medium | High |
| WebGL managed | Good | Low | Medium |
| Format-aware pools | Good | High | High |

---

## Frame Timing

### The Synchronization Problem

When does an operator execute relative to frame boundaries? The answer determines interactivity, latency, and consistency. Too early and you render stale data. Too late and you miss the frame entirely.

Each bridge has its own schedule. The highway runs on fixed departure times; you wait for the next bus. The cable car runs continuously; step on whenever ready. The drawbridge raises only when ships approach; otherwise traffic flows freely.

### Werkkzeug4: Explicit Calculate

Werkkzeug4 decouples editing from rendering through explicit compilation. The artist clicks "Calculate" to trigger a full compilation pass. The resulting command buffer executes on subsequent frames until the next Calculate.

This explicit model enables parameter snapshotting. Commands capture parameter values at compile time through `CopyParameters()`, freezing them for execution. The artist can tweak sliders while rendering continues with last compile's values. Changes become visible only after the next explicit compile.

The model works well for demoscene production where compilation happens once during tool load and rendering runs for the entire demo. For interactive editing, the delay between parameter change and visible result requires mental adjustment.

### cables.gl: RAF-Driven Loop

cables.gl runs on the browser's requestAnimationFrame cycle. The `CglRenderLoop` requests each frame, limits FPS if configured, and emits the render event that triggers graph execution.

```javascript
// cables.gl: Frame loop driven by requestAnimationFrame
exec(timestamp) {
    cancelAnimationFrame(this.#animReq);

    if (this.#patch.config.fpsLimit) {
        this._frameInterval = 1000 / this.#patch.config.fpsLimit;
    }

    // Render if no limit, or enough time has passed
    if (this.#renderOneFrame || this.#patch.config.fpsLimit === 0
        || frameDelta > this._frameInterval) {
        this.renderFrame(timestamp);
    }

    if (this.#patch.config.doRequestAnimation) {
        this.#animReq = this.#patch.getDocument().defaultView
            .requestAnimationFrame(this.exec.bind(this));
    }
}
```

Parameter changes take effect immediately on the next frame. No explicit compile step exists. The graph executes every frame, checking each operator's dirty state to determine what needs updating. This continuous execution provides instant feedback but consumes more resources than explicit compilation.

### tixl: Game Loop Integration

tixl integrates with Silk.NET's window loop, providing standard game loop timing semantics. The dirty flag system determines which operators actually execute. When an input parameter changes, the flag propagates downstream, marking affected outputs for recomputation.

The `DirtyFlag` class tracks invalidation globally per frame. Each flag stores when it was last invalidated, preventing double-invalidation of shared operators.

```csharp
// tixl: Global tick management for dirty tracking
public static void IncrementGlobalTicks()
{
    _globalTickCount += GlobalTickDiffPerFrame;
}

public bool IsDirty => TriggerIsEnabled || Reference != Target;
```

The system distinguishes triggered slots (always dirty, for animation) from value slots (dirty only when input changes). Commands always re-execute because their GPU effects are temporal, but pure computation skips work when inputs are stable.

**Trade-off Table**

| Timing Model | Latency | Resource Usage | Predictability |
|--------------|---------|----------------|----------------|
| Highway (Wz4) | High (explicit compile) | Low | High |
| Cable car (cables) | Low (next frame) | High | Medium |
| Drawbridge (tixl) | Medium (dirty-driven) | Medium | High |

---

## Cross-Platform Considerations

### The Portability Problem

The three frameworks target different platforms with different GPU APIs. Werkkzeug4 speaks DirectX 9 and 11, rooted in the Windows demoscene. cables.gl speaks WebGL and emerging WebGPU, targeting browsers everywhere. tixl speaks DirectX 11 through SharpDX, designed for Windows desktop performance.

| Framework | WebGL | DirectX | Vulkan |
|-----------|-------|---------|--------|
| Werkkzeug4 | No | DX9, DX11 | Planned (never shipped) |
| cables.gl | Primary | Via WebGL2 | Via WebGPU |
| tixl | No | DX11 | Via Stride (planned) |

Each framework optimized for its primary target. Werkkzeug4's reference stealing and compile-time loop unrolling assume consistent driver behavior available on Windows but less guaranteed elsewhere. cables.gl's state stacks abstract WebGL's quirks. tixl's typed shaders wrap SharpDX's DirectX bindings.

### The wgpu Opportunity

A Rust implementation targeting wgpu gains genuine cross-platform from the start. wgpu runs on Windows (DirectX 12, Vulkan), macOS (Metal), Linux (Vulkan), and browsers (WebGPU). The same Rust code compiles for all targets.

This changes how we build our fourth bridge. Werkkzeug4's compile-time optimizations remain valuable for performance-critical paths. cables.gl's state stacks remain valuable for operator isolation. But neither needs platform-specific implementations because wgpu handles the translation layer.

wgpu's explicit resource management aligns with Werkkzeug4's reference-counted objects. The Rust ownership system makes reference stealing natural through `Arc::try_unwrap()`. Pipeline states can be pre-compiled like Werkkzeug4's commands. Bind groups can be stacked like cables.gl's state.

---

## Key Insight for Rust

The three bridges suggest a hybrid architecture for Rust with wgpu.

**Adopt Werkkzeug4's compilation phase.** Translate the visual graph into a flat command buffer before rendering. Use arena allocation (perhaps `bumpalo`) for commands. Snapshot parameters at compile time, enabling editing during render. Implement reference stealing through `Arc::try_unwrap()` for chains of in-place operations.

**Adopt cables.gl's state stacks.** Wrap wgpu pipeline state in push-pop abstractions. Let operators modify state within scoped guards that automatically restore on drop. Rust's `Drop` trait makes this pattern safe and automatic.

**Adopt tixl's dirty flags.** Track which operators need recomputation. Skip work for stable portions of the graph. Distinguish always-dirty commands from conditionally-dirty data. Let the type system enforce correct flag propagation.

**Pre-compile wgpu pipelines.** Like Werkkzeug4's command compilation, build `RenderPipeline` and `ComputePipeline` objects during an explicit compile phase. Store them in a cache keyed by configuration. Runtime execution binds pre-built pipelines rather than creating them.

**Use ring buffers for frame data.** Like game engines, maintain multiple copies of per-frame uniform data to avoid GPU-CPU synchronization. The compile phase fills the next frame's buffer while the GPU consumes the current frame's buffer.

**Enable shader module injection for composition.** Like cables.gl's shader modules, design shaders with injection points where additional code can be inserted. Pre-compile multiple variants for common combinations. Cache the compiled variants by configuration hash.

The resulting architecture takes the best of each bridge: highway-speed execution, cable-car responsiveness to changes, and drawbridge efficiency for stable graphs.

---

## Related Documents

- [Node Graph Systems](./node-graph-systems.md) - Overview of visual programming across three eras
- [Werkkzeug4: Graph Execution](../../per-demoscene/fr_public/werkkzeug4/graph-execution.md) - Detailed trace of compile-then-execute
- [cables.gl: Rendering Pipeline](../../per-framework/cables/rendering-pipeline.md) - Frame lifecycle and state management
- [Transform Stacks](./transform-stacks.md) - Matrix stack patterns across frameworks
- [Shader Abstractions](../rendering/shader-abstractions.md) - Shader management strategies

---

*Three bridges to the GPU, each shaped by the terrain it crosses. The highway for speed, the cable car for responsiveness, the drawbridge for efficiency. A fourth bridge, built with Rust and wgpu, can learn from all three.*
