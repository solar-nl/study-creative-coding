# Research Briefing: Implementing Command-Flow in flux

## Context

This builds on [command-flow-briefing.md](command-flow-briefing.md) which mapped three candidate approaches. This document narrows to concrete implementation: what does tixl's command pattern look like in Rust with wgpu, how do existing frameworks solve the hard subproblems, and what architecture should flux adopt?

## New Evidence Since the First Briefing

### tixl's compound operators solve the complexity objection

The "every GPU call is a graph node" concern is misleading. tixl operates at two tiers:

**User tier** — compound operators like `DrawScene` that encapsulate entire rendering workflows. A PBR scene is 10-15 visible nodes. Users rarely touch the low-level graph.

**Engine tier** — inside each compound, a sub-graph of 10-20 primitive operators (SetShader, InputAssembler, Draw, etc.) wired together in a `.t3` definition file. This is the Symbol-Instance model: a Symbol contains child operators, and instantiating it creates one node in the parent graph.

The critical operator is `_DispatchSceneDraws`, which batches an entire `SceneSetup` (flat list of draw dispatches) into a single command with internal state-change minimization:

```csharp
// Setup once: shaders, IBL textures, shared cbuffers
SetShaders();
BindSharedResources();

// Loop: only rebind what changed
foreach (dispatch in Dispatches) {
    if (material != lastMaterial) RebindMaterialSRVs();
    UpdateTransformCBuffer(dispatch.CombinedTransform);
    BindMeshBuffers(dispatch);
    deviceContext.Draw(dispatch.VertexCount, dispatch.VertexStartIndex);
}
```

**Implication for flux:** The command pattern doesn't mean one node per draw call at the user level. It means the graph provides composition and ordering; batching happens inside operators. flux needs compound operator support (nested sub-graphs) and a `SceneSetup`-equivalent data structure.

### The wgpu RenderPass lifetime problem has three known solutions

Existing Rust frameworks each solved this differently:

**rend3: `UnsafeCell` + enum (encoder OR pass, never both)**

rend3 wraps a single `CommandEncoder` in `UnsafeCell` and executes graph nodes sequentially. Each node declares upfront whether it needs an encoder (for compute, copies) or a render pass (for drawing). The graph:
- Merges consecutive nodes with compatible render targets into a single `RenderPass`
- Drops and recreates the pass at incompatible boundaries
- Uses `unsafe { &mut *encoder_cell.get() }` to re-borrow the encoder after dropping a pass

```rust
// rend3's execution loop (simplified)
let encoder_cell = UnsafeCell::new(device.create_command_encoder(&desc));
let mut rpass = None;

for node in pruned_nodes {
    if !compatible_with_prev {
        rpass = None;  // drop old pass, releasing encoder borrow
        if node.needs_rpass {
            rpass = Some(unsafe { &mut *encoder_cell.get() }.begin_render_pass(&desc));
        }
    }
    let ctx = match rpass {
        Some(ref mut rp) => EncoderOrPass::RenderPass(rp),
        None => EncoderOrPass::Encoder(unsafe { &mut *encoder_cell.get() }),
    };
    (node.exec)(ctx);
}
```

Safety is guaranteed by the graph's sequential execution order and the invariant that no node holds references across the boundary. rend3 also provides a `RpassTemporaryPool` (bump allocator) for bind groups created inside render pass closures that need to outlive the closure but not the pass.

**Bevy: `Vec<CommandBuffer>` + lazy encoder**

Bevy's `RenderContext` creates encoders on demand and accumulates finished command buffers in a `Vec`. Each node calls `begin_tracked_render_pass()`, uses it, drops it, and the next node gets a fresh pass on the same or a new encoder. `TrackedRenderPass` wraps `RenderPass` with redundant-bind elimination.

No unsafe required. Slightly suboptimal barrier placement because wgpu may insert transition command buffers between submissions.

**Simple scoped blocks**

For sequential passes without graph infrastructure, just use Rust's scoping:

```rust
// Pass 1
{
    let mut pass = encoder.begin_render_pass(&shadow_desc);
    pass.draw(0..3, 0..1);
} // pass dropped, encoder free

// Pass 2
{
    let mut pass = encoder.begin_render_pass(&scene_desc);
    pass.draw(0..6, 0..1);
} // pass dropped
```

**wgpu v22+ escape hatch:** `RenderPass::forget_lifetime()` converts `RenderPass<'a>` to `RenderPass<'static>`, moving enforcement from compile-time to runtime. Useful when you need to store pass and encoder in the same struct.

| Strategy | Safety | Pass merging | Mobile perf | Complexity |
|---|---|---|---|---|
| rend3 `UnsafeCell` | Unsafe, invariant-guarded | Yes | Optimal | High |
| Bevy `Vec<CommandBuffer>` | Safe | No | Extra barriers | Medium |
| Scoped blocks | Safe | Manual | Manual | Low |
| `forget_lifetime()` | Runtime-checked | Manual | Manual | Low |

### Mobile performance matters

On tile-based GPUs (all mobile, Apple Silicon in some modes), each render pass break forces the GPU to flush tile memory to system memory. Samsung's documentation shows 40%+ bandwidth savings from keeping data on-chip with fewer passes. This means **render pass merging is not optional for mobile/web targets** — it's a core performance requirement.

## Proposed Architecture

Based on the evidence, flux should adopt **Approach A from the first briefing** (add Command slots to flux) but with the two-tier compound operator model from tixl and the render pass management strategy from rend3.

### Layer 1: The Slot Type Split

Add a `Command` variant to flux's slot system. The execution rules diverge at the type level:

```rust
/// A slot that produces a cached, immutable value.
/// Re-evaluated only when dirty flags indicate upstream changes.
pub struct ValueSlot<T: Send + 'static> {
    value: Option<T>,
    dirty: DirtyFlag,
    update: Box<dyn FnMut(&EvalContext) -> T>,
}

/// A slot that executes GPU side effects.
/// Always re-evaluated every frame. Never cached.
pub struct CommandSlot {
    dirty: DirtyFlag,  // used only for invalidation propagation, not gating
    update: Box<dyn FnMut(&mut RenderContext)>,
}
```

The executor checks the slot type:

```rust
fn evaluate_slot(&mut self, slot: &mut dyn Slot, ctx: &mut EvalContext) {
    match slot.kind() {
        SlotKind::Value => {
            if slot.dirty_flag().is_dirty() {
                slot.update(ctx);
                slot.dirty_flag().clear();
            }
        }
        SlotKind::Command => {
            // Always execute. Commands are side effects.
            slot.update(ctx);
            slot.dirty_flag().clear();
        }
    }
}
```

### Layer 2: The Command Type

The Rust equivalent of tixl's `Command`. The key question is allocation:

**Option A: Trait object (heap allocated)**
```rust
pub struct Command {
    prepare: Option<Box<dyn FnMut(&mut RenderContext)>>,
    restore: Option<Box<dyn FnMut(&mut RenderContext)>>,
}
```
Allocates per-frame. Simple. Probably fine for <1000 commands/frame.

**Option B: Trait-based (static dispatch)**
```rust
pub trait CommandOp: Send + Sync {
    fn prepare(&mut self, ctx: &mut RenderContext);
    fn execute(&mut self, ctx: &mut RenderContext);
    fn restore(&mut self, ctx: &mut RenderContext);
}
```
No per-frame allocation. Each operator is a struct implementing `CommandOp`. The slot stores `Box<dyn CommandOp>` once at graph construction time, reused every frame.

**Option C: Enum dispatch (no allocation, no vtable)**
```rust
pub enum Command {
    SetPipeline(SetPipelineCmd),
    Draw(DrawCmd),
    DrawScene(DrawSceneCmd),
    BindRenderTarget(BindRenderTargetCmd),
    Group(GroupCmd),
    // ...
}
```
Fastest dispatch but closed set. New command types require modifying the enum.

**Recommendation:** Option B. The trait is defined once, the `Box<dyn CommandOp>` is allocated once when the graph is built, and `prepare`/`execute`/`restore` take `&mut self` so the operator can hold mutable state (GPU resources, cached bindings) without per-frame allocation.

### Layer 3: RenderContext (replaces tixl's EvaluationContext + device.ImmediateContext)

tixl splits state into two buses: `EvaluationContext` for hierarchical scene state and `device.ImmediateContext` for GPU pipeline state. In wgpu, there is no global device context, so both must live in a threaded context struct:

```rust
pub struct RenderContext<'frame> {
    // ── GPU access ───────────────────────────────
    encoder: EncoderOrPass<'frame>,
    device: &'frame wgpu::Device,
    queue: &'frame wgpu::Queue,

    // ── Hierarchical scene state (save/restore) ──
    object_to_world: Mat4,
    world_to_camera: Mat4,
    camera_to_clip: Mat4,
    pbr_material: PbrMaterial,
    lights: PointLightStack,
    fog: FogSettings,
    requested_resolution: UVec2,

    // ── Per-frame temporaries ────────────────────
    temps: BumpAllocator,  // for bind groups created during pass
}
```

The `EncoderOrPass` enum follows rend3's pattern:

```rust
pub enum EncoderOrPass<'a> {
    Encoder(&'a mut wgpu::CommandEncoder),
    RenderPass(&'a mut wgpu::RenderPass<'a>),
}
```

A command operator gets `&mut RenderContext` and can:
- Read/write hierarchical state (transforms, materials)
- Issue draw calls through the active render pass
- Create compute passes through the encoder (after ending the render pass)

### Layer 4: RenderTarget as the Phase Boundary

The `RenderTarget` operator bridges command world → value world, exactly as in tixl:

```rust
pub struct RenderTargetOp {
    color_texture: Option<wgpu::Texture>,
    depth_texture: Option<wgpu::Texture>,
    color_view: Option<wgpu::TextureView>,
    depth_view: Option<wgpu::TextureView>,
    format: wgpu::TextureFormat,
    size: UVec2,
    msaa_samples: u32,
}

impl CommandOp for RenderTargetOp {
    fn prepare(&mut self, ctx: &mut RenderContext) {
        // 1. Recreate textures if size/format changed
        self.ensure_textures(ctx.device);

        // 2. Save parent's active pass
        let parent_pass = ctx.encoder.take_pass();

        // 3. Begin our render pass
        let pass = ctx.encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: self.color_view.as_ref().unwrap(),
                load: wgpu::LoadOp::Clear(wgpu::Color::BLACK),
                store: wgpu::StoreOp::Store,
            })],
            depth_stencil_attachment: Some(/* ... */),
            ..Default::default()
        });

        // 4. Save hierarchical state
        // (transform matrices, resolution, etc.)
    }

    fn execute(&mut self, ctx: &mut RenderContext) {
        // Pull the command subtree — children draw into our render pass
        self.command_input.evaluate(ctx);
    }

    fn restore(&mut self, ctx: &mut RenderContext) {
        // 1. End our render pass (drop it)
        ctx.encoder.end_pass();

        // 2. MSAA resolve if needed

        // 3. Restore parent's pass (or leave encoder in encoder mode)

        // 4. Restore hierarchical state

        // 5. Output: set our color_view as a value on the texture output slot
        self.texture_output.set(self.resolved_view.clone());
    }
}
```

Above the RenderTarget: commands (always re-executed, side-effectful).
Below the RenderTarget: values (cached textures flowing through post-processing).

### Layer 5: Compound Operators (the Two-Tier System)

flux needs a way to define operator sub-graphs, equivalent to tixl's `.t3` files:

```rust
/// A compound operator contains an internal sub-graph.
/// Users see one node; the sub-graph evaluates internally.
pub struct CompoundOperator {
    symbol: OperatorGraph,           // the internal sub-graph
    exposed_inputs: Vec<PortId>,     // inputs exposed to parent graph
    exposed_outputs: Vec<PortId>,    // outputs exposed to parent graph
}

impl CommandOp for CompoundOperator {
    fn execute(&mut self, ctx: &mut RenderContext) {
        // Map parent inputs to internal graph inputs
        self.bind_exposed_inputs(ctx);
        // Evaluate the internal graph
        self.symbol.evaluate(ctx);
    }
}
```

Standard compounds shipped with the framework:

| Compound | Internal sub-graph |
|---|---|
| `DrawMesh` | SetPipeline → BindVertexBuffer → BindIndexBuffer → BindMaterialGroup → DrawIndexed |
| `DrawScene` | ForEach dispatch in SceneSetup → conditional material rebind → transform update → Draw |
| `PbrPass` | Camera → Group → DrawScene → (outputs to RenderTarget) |
| `ShadowPass` | ShadowCamera → DrawScene with shadow pipeline → (outputs depth texture) |
| `PostProcess` | flux value chain: texture → Bloom → ToneMap → FXAA → output |

Users compose these at the top level. Power users can drill in or build custom compounds.

### Layer 6: Batching Inside Operators

The `DrawScene` compound internally uses a `SceneDispatcher` that mirrors tixl's `_DispatchSceneDraws`:

```rust
pub struct SceneDispatcher {
    shared_bind_group: Option<wgpu::BindGroup>,  // IBL, fog, lights
    last_material_id: Option<MaterialId>,
    last_mesh_id: Option<MeshId>,
}

impl SceneDispatcher {
    pub fn dispatch(&mut self, ctx: &mut RenderContext, scene: &SceneSetup) {
        let pass = ctx.encoder.as_render_pass();

        // Bind shared resources once
        pass.set_bind_group(0, &self.shared_bind_group, &[]);

        for dispatch in &scene.dispatches {
            // Rebind material only if changed
            if Some(dispatch.material_id) != self.last_material_id {
                pass.set_bind_group(1, &dispatch.material_bind_group, &[]);
                self.last_material_id = Some(dispatch.material_id);
            }

            // Per-object: dynamic offset into transform UBO
            pass.set_bind_group(2, &scene.transform_bind_group,
                                &[dispatch.transform_offset]);

            // Rebind mesh only if changed
            if Some(dispatch.mesh_id) != self.last_mesh_id {
                pass.set_vertex_buffer(0, dispatch.vertex_buffer.slice(..));
                pass.set_index_buffer(dispatch.index_buffer.slice(..),
                                      wgpu::IndexFormat::Uint32);
                self.last_mesh_id = Some(dispatch.mesh_id);
            }

            pass.draw_indexed(0..dispatch.index_count, 0, 0..1);
        }
    }
}
```

This is one operator node that issues N draw calls with minimal state changes. The graph doesn't see individual draws — it sees one `DrawScene` command.

### Layer 7: Conditional Execution

Follow tixl's pattern exactly. No topology changes:

```rust
pub struct ExecuteIf {
    enabled: ValueSlot<bool>,
    commands: MultiInputSlot<Command>,
}

impl CommandOp for ExecuteIf {
    fn execute(&mut self, ctx: &mut RenderContext) {
        if self.enabled.get(ctx) {
            for cmd in &mut self.commands {
                cmd.prepare(ctx);
                cmd.execute(ctx);
                cmd.restore(ctx);
            }
        }
    }
}

pub struct Switch {
    index: ValueSlot<u32>,
    branches: MultiInputSlot<Command>,
}

impl CommandOp for Switch {
    fn execute(&mut self, ctx: &mut RenderContext) {
        let i = self.index.get(ctx) as usize % self.branches.len();
        // Only evaluate the selected branch
        self.branches[i].prepare(ctx);
        self.branches[i].execute(ctx);
        self.branches[i].restore(ctx);
    }

    fn propagate_dirty(&self, flag: &mut DirtyFlag) {
        // Only propagate to active branch
        let i = self.index.cached() as usize % self.branches.len();
        self.branches[i].invalidate(flag);
    }
}
```

## The Render Pass Management Strategy

This is the make-or-break decision. Three options, with recommendation:

### Option 1: rend3-style (single encoder, `UnsafeCell`, pass merging)

**Best for:** Maximum mobile/web performance. Minimum render pass breaks.

The graph executor pre-analyzes the command tree to identify render pass boundaries (every `RenderTarget` node starts a new pass). Consecutive commands within the same render target share a single `RenderPass`. The executor uses `UnsafeCell` to manage the encoder/pass borrow dance.

**Pros:** Optimal pass count. Automatic load/store op inference. Dead node elimination.
**Cons:** Requires unsafe. Graph must be fully analyzed before execution. More complex executor.

### Option 2: Bevy-style (Vec<CommandBuffer>, lazy encoder)

**Best for:** Safety. Simpler implementation. Desktop-first targets.

Each render target boundary finishes the current encoder into a `CommandBuffer` and starts a new one. All buffers are collected and submitted at frame end.

**Pros:** No unsafe. Simpler executor. Nodes are more independent.
**Cons:** No pass merging. Extra barrier overhead. Suboptimal on mobile.

### Option 3: Hybrid (scoped passes with `forget_lifetime` for nesting)

**Best for:** Prototyping. Getting something working fast.

Use Rust's scoping for sequential passes. Use `forget_lifetime()` when you need to store a pass in the context. Add pass merging later as an optimization.

**Pros:** Simplest starting point. Uses wgpu's built-in escape hatch.
**Cons:** Runtime errors instead of compile-time. No automatic merging.

### Recommendation: Start with Option 3, migrate to Option 1

Option 3 lets you prototype the command pattern and validate the architecture without building a full graph analyzer. Once the command-flow model is proven, migrate the executor to Option 1 (rend3-style) for production performance. The command operators themselves don't change — only the executor's pass management does.

## Open Questions for Prototyping

### 1. Nested RenderTargets under wgpu

tixl nests RenderTargets arbitrarily (a render-to-texture inside a render-to-texture). Under wgpu, each nesting level requires ending the parent pass and starting a child pass. When the child completes, the parent pass must be re-created (not resumed — wgpu has no pause/resume for render passes).

**Question:** Is this acceptable? Every nesting level costs two pass breaks (end parent + begin child + end child + re-begin parent). For shadow maps rendered inside the main scene graph, this is 4 extra pass breaks per shadow cascade.

**Alternative:** Pre-sort render targets by dependency order (shadows before main pass) and execute them sequentially rather than nested. This is the render graph approach and eliminates nesting entirely, at the cost of tixl's composability.

### 2. The `&mut RenderContext` threading problem

If the context carries `&mut RenderPass`, and a child operator needs to end the pass (to do a compute dispatch or start a nested render target), the child needs to mutably access the encoder — but the parent's render pass holds it.

**Question:** Does `EncoderOrPass` need to be an `Option` that children can `.take()` and `.replace()`? This would make the API more complex but solves the mutual exclusion problem.

### 3. Dirty flag propagation through compound operators

When an input to a compound operator changes, how far does invalidation propagate into the sub-graph? tixl propagates through connections: if the changed input connects to an internal node, only that node and its dependents are invalidated.

**Question:** Should flux's dirty flags propagate through compound boundaries transparently, or should compounds be opaque (entire sub-graph re-evaluates if any exposed input changes)?

Transparent: more efficient, more complex dirty flag tracking.
Opaque: simpler, potentially wasteful for large compounds.

### 4. SceneSetup: flatten at load or flatten at draw?

tixl flattens the scene hierarchy into a `List<SceneDrawDispatch>` at load time (in `SceneSetup.GenerateSceneDrawDispatches()`). Transforms are pre-computed. The draw loop is a flat iteration.

**Question:** For animated scenes where transforms change every frame, should the flatten happen at draw time? Or should the flat list persist and only transform buffers update? The latter is more GPU-friendly (stable vertex/index bindings, only cbuffer updates).

### 5. Command allocation lifetime

If `Command` uses `Box<dyn CommandOp>`, the box is allocated once at graph build time. But if operators need per-frame temporary state (bind groups, dynamic buffer offsets), where does that live?

**Options:**
- In the `CommandOp`'s `&mut self` (persistent, reused across frames)
- In a per-frame bump allocator on `RenderContext` (rend3's `RpassTemporaryPool` pattern)
- In a frame-scoped arena passed through the context

## Prototype Milestones

1. **Slot type split** — Add `CommandSlot` to flux with always-dirty semantics. Verify mixed graphs (some value, some command) evaluate correctly.

2. **Minimal RenderTarget** — One operator that begins a render pass, pulls a command subtree, ends the pass, outputs a `TextureView`. Wire it to a triangle draw command and a post-process value chain.

3. **Save/restore pattern** — Implement `prepare`/`restore` for transform push/pop (Group operator). Verify nested Groups compose correctly.

4. **DrawScene batching** — Load a glTF, flatten to `SceneSetup`, draw with material/mesh state-change minimization inside a single command.

5. **Conditional execution** — `ExecuteIf` and `Switch` with dirty flag pruning on inactive branches.

6. **Compound operators** — Define `DrawMesh` as a sub-graph. Verify it shows as one node in the parent graph.

7. **Pass merging** — Migrate from scoped passes to rend3-style single-encoder execution with automatic pass merging.

## Reference

| Document | What it covers |
|---|---|
| [command-flow-briefing.md](command-flow-briefing.md) | High-level design space (approaches A/B/C) |
| `notes/per-framework/tixl/rendering/graph-for-rendering.md` | Why tixl's command-flow works where flux failed |
| `notes/per-framework/tixl/rendering/overview.md` | Command pattern, EvaluationContext, dirty flags |
| `notes/per-framework/tixl/code-traces/rendering-frame.md` | 13-step frame trace |
| `notes/per-framework/tixl/architecture.md` | Symbol-Instance-Slot model |
| rend3 source: `libraries/rend3/rend3/src/graph/` | UnsafeCell encoder, pass merging, temp pool |
