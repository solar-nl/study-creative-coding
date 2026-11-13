# Briefing: Fitting tixl's Command Design into flux

## Purpose

This document frames the design space for integrating tixl's command-flow pattern into our Rust framework's dataflow graph (flux). It is a briefing for exploration, not a proposal — it maps what we know, identifies the open questions, and outlines the candidate approaches so we can have a productive design session.

## What We Know

### flux today

flux is a dataflow graph. Operators declare typed input/output ports, produce immutable values, and the executor resolves the DAG. It works well for post-processing (texture in → shader → texture out).

It failed at render management for five reasons:
1. **Shared mutable targets** — multiple passes accumulating into the same HDR buffer
2. **Imperative geometry** — draw call loops, per-object uniforms, multi-RT writes
3. **Deferred recording penalty** — two-phase (evaluate → flush) measured +31% frame time on Metal
4. **Conditional passes** — toggling requires topology rebuild or flag hacks
5. **Resource lifetime mismatch** — pool indirection without value for rendering

These led to `ScenePassNode` as a separate trait outside flux.

### tixl's solution

tixl uses the same graph topology for both data and rendering, but with a type-level split:

- **Value slots** (`Slot<float>`, `Slot<Texture2D>`, etc.) — cached, dirty-flag gated, lazy
- **Command slots** (`Slot<Command>`) — always re-executed every frame, side-effectful

`Command` is just two callbacks:
```csharp
public class Command {
    public Action<EvaluationContext> PrepareAction { get; init; }
    public Action<EvaluationContext> RestoreAction { get; set; }
}
```

Key mechanics:
- `RenderTarget` binds its texture to the GPU, pulls its command subtree (children draw into it), then restores previous state
- Operators call DX11 directly during graph evaluation — one-phase, inline execution
- `Execute.IsEnabled` skips subtrees without topology changes
- `Switch` prunes dirty flag propagation through inactive branches
- Each operator owns its GPU resources (no pool)

### The wgpu constraint

tixl relies on DX11's global mutable `ImmediateContext`. wgpu doesn't have that:

- Commands go into `CommandEncoder` (built up, then submitted)
- `RenderPass` borrows the encoder mutably — you can't start a new pass without ending the current one
- Pipeline state is bound per-pass, not globally

This means tixl's pattern doesn't transplant directly. The command-flow idea is sound, but the execution model needs adaptation.

## The Design Space

There are three broad approaches. They aren't mutually exclusive — the final design likely combines elements.

### Approach A: Add Command Slots to flux

Extend flux's type system with a `Command` variant alongside `Value`. Command-typed ports have different evaluation semantics: always dirty, execute inline during graph walk.

**What this looks like in flux:**
```rust
enum SlotType<T> {
    Value(T),                                    // cached, dirty-flag gated
    Command(Box<dyn FnOnce(&mut RenderCtx)>),    // always re-executed
}
```

**What it solves:**
- Shared mutable targets (commands write to bound state, not flowing textures)
- Conditional passes (command evaluation can be skipped at runtime)
- Geometry rendering (commands can issue arbitrary GPU calls)

**Open questions:**
- Does flux's DAG executor need to change? Commands are order-sensitive — the current topological sort may not preserve the ordering that rendering requires (parent before children, sibling order matters)
- How do Command slots interact with flux's caching? If a subgraph has both value and command outputs, the value path caches but the command path always runs — is that confusing?
- What is the Rust type for the command callback? `Box<dyn FnOnce(&mut RenderCtx)>` has allocation overhead per frame. `&dyn FnMut(...)` requires a borrowed context. A trait object in a slot has lifetime implications

### Approach B: Keep flux for Data, Build a Render Tree Alongside

Don't extend flux. Instead, build a separate command tree for rendering that shares the same topology representation but has its own executor with imperative semantics.

**What this looks like:**
```
┌──────────────────────┐     ┌──────────────────────┐
│   flux (dataflow)    │     │  render tree (cmds)   │
│                      │     │                       │
│  texture → shader    │────▶│  bind RT → draw mesh  │
│   → texture → ...    │     │   → draw mesh → ...   │
│                      │◀────│                        │
│  (post-processing)   │     │  (scene rendering)    │
└──────────────────────┘     └──────────────────────┘
         ▲                            │
         │    texture handoff         │
         └────────────────────────────┘
```

**What it solves:**
- Clean separation: flux stays pure dataflow, render tree is purely imperative
- No need to modify flux's executor or type system
- Each system has optimal semantics for its domain

**Open questions:**
- Where exactly are the handoff points? `RenderTarget` is the natural boundary (command world above, value world below) — but is that the only one?
- How does the user author the render tree? Is it a separate graph editor, or is it expressed in code? tixl uses the same visual graph for both — splitting them might hurt the user experience
- Does this create a "two systems" problem where users need to understand both models?

### Approach C: Encode Rendering as a Stateful Pipeline (Not a Graph)

Don't try to graph-ify rendering at all. The deferred pipeline is inherently a linear sequence of passes with explicit resource dependencies. Express it as a pipeline builder:

```rust
RenderPipeline::new()
    .pass("geometry", |pass| {
        pass.output("albedo", Format::Rgba8)
            .output("normal", Format::Rgba16F)
            .output("depth", Format::D32)
            .render(|ctx, encoder| { /* draw scene */ })
    })
    .pass("lighting", |pass| {
        pass.read("albedo").read("normal").read("depth")
            .output("hdr", Format::Rgba16F)
            .render(|ctx, encoder| { /* fullscreen lighting */ })
    })
    .pass("post", |pass| {
        pass.read("hdr")
            .output("ldr", Format::Rgba8)
            .render_with_flux(|graph| { /* flux post-processing chain */ })
    })
```

**What it solves:**
- Resource lifetimes (pipeline declares all resources upfront, enables pooling/aliasing)
- Pass merging / subpass detection (linear topology makes this analyzable)
- Async compute overlap (independent passes on different queues)
- Conditional passes (skip by index without topology changes)

**Open questions:**
- This is a render graph (Bevy/Unreal RDG style), not tixl's approach at all. Does it lose the composability that makes tixl powerful?
- Where does the command pattern fit? Within each pass's `render` closure?
- How does the user compose scene rendering (which is hierarchical — transforms nest) within a linear pipeline?

## The Hard Subproblems

Regardless of which approach, these four problems need concrete answers:

### 1. The `RenderPass` Lifetime Problem

wgpu's `RenderPass<'a>` borrows `&'a mut CommandEncoder`. While a render pass is open, nothing else can use the encoder. In tixl, child operators can start new render passes freely because DX11 has no such constraint.

**Possible solutions:**
- **A.** Thread `&mut RenderPass` through the command tree. All children draw into the same pass. Starting a new pass requires ending the current one — so a `RenderTarget` operator would end the parent pass, do its work, then... it can't restart the parent pass (state is gone)
- **B.** Pre-split the graph at RenderTarget boundaries. Each RenderTarget subtree becomes a separate render pass recorded sequentially on the encoder. The graph executor identifies these boundaries during a planning phase before execution
- **C.** Use multiple `CommandEncoder`s. Each RenderTarget gets its own encoder, submitted in order. Avoids the borrow conflict but adds submission overhead
- **D.** Don't nest render targets. Unlike tixl where RenderTarget can nest arbitrarily, require the pipeline to be flat (all render targets at the same level). This is the render graph approach — simpler but less composable

### 2. Inline Recording vs Driver Optimization

flux's two-phase execution (evaluate → flush) caused a 31% penalty on Metal. tixl's one-phase (evaluate = execute) avoids this. But wgpu is inherently two-phase (record → submit).

**The question:** Does wgpu's internal batching already handle this? When we call `encoder.begin_render_pass()` and record draw calls inline during graph evaluation, does the driver see them incrementally (like tixl on DX11) or in a batch (like flux)?

This may need benchmarking. The answer likely differs between Metal, Vulkan, and DX12 backends.

### 3. Hierarchical State vs Flat Pipeline

tixl's power comes from hierarchical composition: a `Group` operator sets a transform, and all children inherit it. This is natural for scene rendering (transform tree → draw calls). But wgpu render passes are flat — there's no concept of "push transform, draw children, pop transform" at the GPU level.

**The question:** Where does the hierarchical state live? Options:
- In a `RenderContext` struct threaded through the tree (like tixl's `EvaluationContext`) — but this is CPU-side bookkeeping, the GPU sees flat uniform updates
- In per-draw-call uniform bindings — each draw call gets its own `ObjectToWorld` in a dynamic uniform buffer
- In a scene graph that flattens to a draw list before submission

### 4. The Composition Question

tixl's single-graph model means a user can wire a `RenderTarget` → `Bloom` → `ToneMap` → `Display` in one graph. The `RenderTarget` contains scene rendering (commands), and `Bloom`/`ToneMap` are image operators (values). The transition happens automatically at the `RenderTarget` boundary.

**The question for our framework:** If we split rendering and post-processing into different systems, how does the user compose them? Do they need to manually wire the handoff? Or can we detect the command→value boundary and handle it transparently?

## What to Explore

When we sit down to design this, here's what I'd want to work through:

1. **Type sketch** — What does `Command` look like in Rust with wgpu? What borrows what? Can we avoid allocation per frame?

2. **Executor walk** — Given a mixed graph (some value nodes, some command nodes), what does the evaluation order look like? Draw it out for a concrete example: Camera → Group → [DrawMesh, DrawMesh] → RenderTarget → Bloom → Display

3. **RenderPass boundary detection** — Can we statically identify where render passes start and end in the graph? If so, we can split the graph into segments that each get their own render pass, avoiding the lifetime problem

4. **Benchmark the Metal question** — Record wgpu commands inline during a tree walk, measure frame time on M1 Pro, compare with the batched approach. If inline recording is fast enough, that eliminates the two-phase concern

5. **Prototype the minimal case** — A `RenderTarget` that takes a command input and produces a texture output. One scene pass writing geometry, one post-process reading the texture. Get this working in wgpu and see what falls out

## Reference

- **tixl analysis**: `notes/per-framework/tixl/rendering/graph-for-rendering.md`
- **tixl command pattern**: `notes/per-framework/tixl/rendering/overview.md`
- **tixl frame trace**: `notes/per-framework/tixl/code-traces/rendering-frame.md`
- **ADR-002**: wgpu as graphics backend (`insights/architecture-decisions.md`)
- **ADR-013** (internal): flux Metal benchmark — 10.9ms → 14.3ms (+31%)
