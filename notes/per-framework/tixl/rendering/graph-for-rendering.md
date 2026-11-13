# Why tixl's Graph Works for Rendering (and flux didn't)

## The Core Difference

flux flows **values** through its graph — textures move forward immutably through typed ports. tixl flows **commands** — opaque imperative closures that mutate global GPU state when invoked. This single design choice resolves four of the five failure modes that killed flux's render management.

The `Command` type is the entire mechanism:

```csharp
// Core/DataTypes/Command.cs — the complete type
public class Command
{
    public Action<EvaluationContext> PrepareAction { get; init; }
    public Action<EvaluationContext> RestoreAction { get; set; }
}
```

Two callbacks. No data, no textures, no serializable state. The graph does not transport pixel data — it orchestrates *when* and *in what order* imperative GPU mutations happen.

## Failure Mode Analysis

### 1. Shared Mutable Targets

**flux problem:** Multiple passes (ambient → lighting → LTC → emissive) accumulate into the same HDR buffer. Dataflow requires every value to flow forward immutably. Modeling "add to existing texture" requires every pass to output the target (graph clutter) or ordering hacks.

**tixl solution:** `RenderTarget` owns its `Texture2D` as a private field, binds it to `device.ImmediateContext.OutputMerger`, then pulls its entire command subtree via `Command.GetValue(context)`. Every downstream operator — however many there are — writes into the already-bound render target through direct DX11 draw calls. No texture copies, no output ports carrying intermediate buffers.

```csharp
// Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs:78-162
// 1. Bind our render target
deviceContext.OutputMerger.SetTargets(_multiSampledDepthBufferDsv, _multiSampledColorBufferRtv);

// 2. Pull the entire downstream command tree — all passes accumulate here
Command.GetValue(context);

// 3. Restore previous render target
deviceContext.OutputMerger.SetTargets(prevDsv, prevTargets);
```

The accumulation problem vanishes because the render target is not a value flowing through ports — it is global mutable GPU state that child commands write into as a side effect.

**Verdict:** Fully solved by the command pattern.

### 2. Geometry Rendering Needs Imperative Control

**flux problem:** The `GpuOperator` trait is "declare inputs, run shader, produce output." Scene passes need vertex/index buffers, per-object uniforms, multi-RT writes, draw call loops. This requires either a massive context bag or abandoning the declarative pattern.

**tixl solution:** Operators call DX11 directly during graph evaluation. There is no abstraction between the operator and the GPU:

```csharp
// Operators/Lib/Symbols/render/_dx11/api/Draw.cs:23-49
private void Update(EvaluationContext context)
{
    var deviceContext = ResourceManager.Device.ImmediateContext;
    deviceContext.Draw(vertexCount, startVertexLocation);  // immediate DX11 call
}
```

Shader binding, vertex buffer setup, input assembler configuration — all happen through dedicated operator types that directly mutate `device.ImmediateContext`:

| Operator | DX11 Calls |
|----------|------------|
| `SetPixelAndVertexShaderStage` | `vsStage.Set(vs)`, `psStage.Set(ps)`, `SetConstantBuffers()`, `SetShaderResources()` |
| `InputAssemblerStage` | `iaStage.SetVertexBuffers()`, `iaStage.PrimitiveTopology = ...` |
| `OutputMergerStage` | `omStage.SetBlendState()`, `omStage.SetDepthStencilState()` |
| `Draw` | `deviceContext.Draw(n, start)` |
| `DrawIndexed` | `deviceContext.DrawIndexed(n, start, base)` |

Each of these saves the previous GPU state in `PrepareAction` and restores it in `RestoreAction`, creating a cooperative save/restore stack through the recursive call tree.

**On the context bag question:** tixl does use `EvaluationContext` as a context bag, but it is bounded to *inherited hierarchical state* — transforms, materials, lights, fog, colors. It does **not** carry GPU handles (no render targets, no shader references, no buffer bindings). Those live in `device.ImmediateContext` as global mutable pipeline state. This split is the key:

| Carried in `EvaluationContext` | Set on `device.ImmediateContext` |
|-------------------------------|----------------------------------|
| `ObjectToWorld` matrix | Render targets (OMSetTargets) |
| `WorldToCamera` matrix | Shaders (VS/PS/GS/CS) |
| `CameraToClipSpace` matrix | Constant buffers |
| `PbrMaterial` | Shader resource views |
| `PointLightStack` | Vertex/index buffers |
| `FogSettings` | Blend/depth/rasterizer state |
| `ForegroundColor` | Sampler state |

"What am I rendering" goes in the context. "How am I rendering it" goes directly to the device.

**Verdict:** Solved — but by giving up the declarative model entirely. tixl operators are imperative closures, not declarative transforms. The graph provides ordering and composition, not abstraction.

### 3. Deferred Command Recording Performance

**flux problem:** Two-phase execution (evaluate graph → flush GPU commands) measured +31% frame time on Metal because the driver optimizes better with incremental command submission over ~5ms rather than a single ~0.5ms burst.

**tixl solution:** One-phase, inline execution. Graph evaluation *is* GPU submission:

```csharp
// Player/Program.RenderLoop.cs:41-81
private static void RenderCallback()
{
    DirtyFlag.IncrementGlobalTicks();
    _evalContext.Reset();

    // This single call walks the graph AND issues all DX11 commands
    var outputTexture = _textureOutput.GetValue(_evalContext);

    _swapChain.Present(_vsyncInterval, PresentFlags.None);
}
```

There is no command buffer, no recording phase, no deferred submission. Each operator's `Update()` calls `deviceContext.Draw()` or `deviceContext.Dispatch()` immediately. By the time `GetValue` returns, every draw call has already been issued to the GPU. `Present()` follows immediately.

This is possible because DX11's `ImmediateContext` is itself an inline command submission model — there is no command encoder to build up and submit. The graph walk and the GPU command stream are interleaved in the same call stack.

**Verdict:** Sidesteps the problem entirely. No two-phase architecture means no batching penalty. However, this is DX11-specific — wgpu and Metal require command encoders, so a Rust port would need to thread the encoder through the evaluation context rather than relying on global immediate submission.

### 4. Conditional Passes

**flux problem:** Toggling SSAO via a checkbox requires either rebuilding graph topology (expensive) or per-operator enabled flags (defeats declarative model).

**tixl solution:** Three complementary mechanisms, none requiring graph topology changes:

**A. `Execute.IsEnabled` boolean guard:**
```csharp
// Operators/Lib/Symbols/flow/Execute.cs:14-39
if (IsEnabled.GetValue(context))
{
    for (int i = 0; i < commands.Count; i++)
        commands[i].GetValue(context);    // evaluate subtree
}
// DirtyFlag cleared regardless — no stale state
```

The entire subtree is simply not evaluated when `IsEnabled` is false. No topology change.

**B. `Switch.LimitMultiInputInvalidationToIndices`:**
```csharp
// Operators/Lib/Symbols/flow/Switch.cs:59-88
// Only evaluate the selected branch
index %= commands.Count;
commands[index].GetValue(context);

// Tell the MultiInputSlot to only propagate dirty flags to the active branch
if (OptimizeInvalidation.GetValue(context))
    commandSlot.LimitMultiInputInvalidationToIndices = _activeIndices.ToArray();
```

This is the advanced case. `Switch` tells `MultiInputSlot` to restrict dirty flag propagation to only the active branch index. Inactive branches are skipped during both invalidation *and* evaluation — no wasted work walking dead subtrees in large graphs.

**C. `Group` with color alpha guard:**
```csharp
// Operators/Lib/Symbols/render/transform/Group.cs:58-77
if (IsEnabled.GetValue(context) && color.W > 0)
{
    foreach (var t1 in commands) { ... }
}
```

**Verdict:** Fully solved. Graph topology is always static. Conditional execution is a runtime check during evaluation, not a structural change. The `Switch` optimization goes further by preventing dirty flag cascades through inactive branches.

### 5. Resource Lifetime Mismatch

**flux problem:** Centralized texture pool with static output descriptors adds indirection overhead. `Value` enum wrapping and `(operator_id, port_index)` caching adds overhead without value for rendering.

**tixl solution:** No texture pool. Each operator owns its GPU resources as private fields:

```csharp
// Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs:291-389
private Texture2D _multiSampledColorBuffer;
private Texture2D _resolvedColorBuffer;
private Texture2D _multiSampledDepthBuffer;
private Texture2D _resolvedNormalBuffer;
// ... 6 textures total with their SRV/RTV/DSV views
```

Textures are lazily allocated on first use and recreated only when format/size/MSAA changes, using change detection:

```csharp
var colorFormatChanged = _multiSampledColorBuffer == null
    || _multiSampledColorBuffer.Description.Format != colorFormat
    || _multiSampledColorBuffer.Description.Width != size.Width
    || _multiSampledColorBuffer.Description.Height != size.Height
    || _multiSampledColorBuffer.Description.SampleDescription.Count != _sampleCount;

if (colorFormatChanged)
{
    Utilities.Dispose(ref _multiSampledColorBuffer);
    _multiSampledColorBuffer = Texture2D.CreateTexture2D(texture2DDescription);
}
```

Resources are freed in `Dispose()` when the operator is destroyed (graph node deletion or project close).

**Tradeoff:** No cross-frame texture reuse between different operators, no memory budget management. But also no pool fragmentation, no descriptor staleness, no indirection. Since graph instances live for the project lifetime, holding a texture is effectively free — the real cost is avoiding per-frame reallocation, which the change detection handles.

**Verdict:** Avoided rather than solved. tixl doesn't have transient textures that need pooling — each RenderTarget persists. A deferred renderer with per-frame transients (G-buffer intermediates, bloom mips) would need pooling. tixl's image processing operators (Bloom, Blur, etc.) each own their own intermediate textures permanently.

## The Dual-Mode Graph

The deepest architectural insight is that tixl's graph has **two modes of data flow** encoded at the type level:

| Property | Value Slots (`Slot<T>`) | Command Slots (`Slot<Command>`) |
|----------|------------------------|-------------------------------|
| Caching | Dirty-flag gated; cached when clean | Always re-executed every frame |
| Semantics | Produce immutable data | Execute side effects |
| Examples | `float`, `Vector3`, `Texture2D` | Draw calls, state changes |
| Evaluation | Only when `DirtyFlag.IsDirty` | Unconditionally (`_valueIsCommand = true`) |

```csharp
// Core/Operator/Slots/Slot.cs:162
// The branch that makes this work:
if (_dirtyFlag.IsDirty || _valueIsCommand)
{
    UpdateAction(context);  // always runs for commands
}
```

Value nodes behave like a normal dataflow graph — cached, lazy, pull-based. Command nodes behave like an imperative call tree — always re-executed, side-effectful, order-dependent. The graph topology provides composition and ordering for both, but the execution semantics diverge at the type level.

This is why tixl can use a graph for rendering where flux could not: flux tried to make rendering fit the dataflow model. tixl made the dataflow model accommodate imperative rendering by introducing a second slot type with different evaluation rules.

## What This Means for a wgpu-Based Framework

### The command pattern translates directly

```rust
struct Command {
    prepare: Option<Box<dyn FnOnce(&mut RenderContext)>>,
    restore: Option<Box<dyn FnOnce(&mut RenderContext)>>,
}
```

### The global device context does not

tixl's PrepareAction/RestoreAction works because DX11 has global mutable pipeline state. wgpu does not — it uses `CommandEncoder` and `RenderPass` objects that are built up and submitted. The equivalent pattern threads the encoder through the context:

```rust
struct RenderContext<'a> {
    encoder: &'a mut wgpu::CommandEncoder,
    // hierarchical state (equivalent to EvaluationContext)
    object_to_world: Mat4,
    world_to_camera: Mat4,
    camera_to_clip: Mat4,
    pbr_material: PbrMaterial,
    lights: PointLightStack,
}
```

But there is a tension: `RenderPass` in wgpu borrows the `CommandEncoder` mutably and cannot coexist with other encoder operations. tixl's pattern of "bind render target, walk subtree, unbind" becomes "begin render pass, walk subtree, end render pass" — and the render pass lifetime constrains what child operators can do. They cannot start a new render pass without ending the current one.

### The real question for the Rust framework

tixl's approach works because it gave up on making rendering declarative. Commands are imperative closures. The graph provides ordering and composition, but not abstraction — operators talk directly to the GPU API.

The question is: does this trade-off apply to wgpu? Or does wgpu's command encoder model (which is already a deferred recording system) mean you get the benefits of tixl's one-phase inline execution *and* the benefits of batched submission automatically?

The answer is probably: **use a hybrid**. Keep flux for post-processing (texture → shader → texture, genuinely declarative). Use a separate render graph system for the deferred pipeline (explicit pass ordering, resource aliasing, barrier insertion). Let the two systems meet at well-defined texture handoff points. This is what Bevy does with its render graph + ECS, and what Unreal does with RDG + scene renderer.

## Comparison Matrix

| Concern | flux (Rust, dataflow) | tixl (C#, command-flow) | Recommendation |
|---------|----------------------|------------------------|----------------|
| **Shared mutable targets** | Cannot model; values are immutable | Commands write to already-bound RT | Command pattern or explicit read-write resource bindings |
| **Geometry draw calls** | GpuOperator trait is too narrow | Operators call DX11 directly | Separate `ScenePass` trait from `ImageOp` trait |
| **Command timing** | Two-phase; +31% on Metal | One-phase; inline execution | Thread encoder through context; let wgpu batch internally |
| **Conditional passes** | Requires topology rebuild or flag hacks | `Execute.IsEnabled` + `Switch` invalidation limiting | Runtime boolean guards; invalidation pruning for large graphs |
| **Resource lifetimes** | Centralized pool with indirection | Per-operator ownership, lazy alloc | Per-operator ownership for persistent; pool for transients |
| **Declarative model** | Pure dataflow; clean but insufficient | Abandoned for rendering; pragmatic | Hybrid: dataflow for image ops, render graph for passes |
