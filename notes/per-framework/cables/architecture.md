# Cables Architecture

> How do you build a visual programming environment on top of raw GPU APIs?

## Key Insight

> **Cables' core idea:** A three-layer architecture separates the visual graph (patches/operators) from GPU abstraction (CgContext) from platform specifics (WebGL/WebGPU), letting artists think in connections while the framework handles state management.

---

## The Problem: Bridging Artists and GPU Pipelines

Visual artists want to experiment with real-time graphics. They want to connect things, see results immediately, and iterate without writing code. But underneath, WebGL demands explicit state management, shader compilation, buffer binding, and draw call orchestration.

The challenge is this: how do you create an abstraction that feels like connecting boxes with wires, while correctly managing the complexity of GPU rendering underneath?

Cables solves this with a three-layer architecture. Think of it like a film studio:

- **The Patch** is the entire production - it coordinates everything
- **Operators (Ops)** are departments - lighting, sound, effects - each doing specialized work
- **Ports** are the communication channels - scripts, dailies, memos flowing between departments
- **Links** are the formal agreements about what gets passed where

This mental model scales from simple demos to complex multi-pass rendering pipelines. Let us look at how these layers are organized.

---

## The Three-Layer Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         PATCH LAYER                             │
│  ┌─────────┐    ┌─────────┐    ┌─────────┐    ┌─────────┐      │
│  │   Op    │───▶│   Op    │───▶│   Op    │───▶│   Op    │      │
│  │(Trigger)│    │(Value)  │    │(Render) │    │(Output) │      │
│  └─────────┘    └─────────┘    └─────────┘    └─────────┘      │
│       Node graph evaluation, links, ports                       │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    GRAPHICS ABSTRACTION LAYER                   │
│                                                                 │
│   CgContext ──▶ Matrix stacks (projection, model, view)        │
│   CgShader  ──▶ Uniform binding, module composition            │
│   CgMesh    ──▶ Geometry + material association                │
│                                                                 │
│       API-agnostic: no WebGL or WebGPU specifics here          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   PLATFORM IMPLEMENTATIONS                      │
│                                                                 │
│   ┌─────────────────────┐    ┌─────────────────────┐           │
│   │     CglContext      │    │     CgpContext      │           │
│   │      (WebGL2)       │    │      (WebGPU)       │           │
│   │                     │    │                     │           │
│   │  - State stacks     │    │  - Bind groups      │           │
│   │  - gl.bindTexture   │    │  - Pipeline cache   │           │
│   │  - gl.drawElements  │    │  - Command encoder  │           │
│   └─────────────────────┘    └─────────────────────┘           │
└─────────────────────────────────────────────────────────────────┘
```

This layering means operators can be written once and work with either rendering backend. The abstraction layer handles the translation.

Now let us examine each layer in detail, starting from the top.

---

## Layer 1: The Patch - Orchestrating the Node Graph

The patch is the container for everything. It holds operators, manages their connections, and drives execution. The key insight is that a visual programming graph needs two kinds of data flow:

1. **Values** that propagate when they change (like a spreadsheet)
2. **Triggers** that fire once per frame (like an animation loop)

### The Core Entities

```
┌─────────────────────────────────────────────────────────────────┐
│                           Patch                                 │
│                                                                 │
│   ┌─────────────────┐                                          │
│   │       Op        │  An operator with inputs and outputs     │
│   │  ┌───┐   ┌───┐  │                                          │
│   │  │ P │   │ P │  │  Ports: connection points                │
│   │  └─┬─┘   └─┬─┘  │                                          │
│   └────┼───────┼────┘                                          │
│        │       │                                                │
│        ▼       ▼                                                │
│   ┌─────────────────┐                                          │
│   │      Link       │  Edge connecting two ports               │
│   └─────────────────┘                                          │
└─────────────────────────────────────────────────────────────────┘
```

**Patch** (`core_patch.js`): The production manager. It owns all operators, maintains the link graph, and coordinates frame execution. When you "run" a patch, it fires the trigger chain that cascades through connected operators.

**Op** (`core_op.js`): A single node in the graph. Each op has a name, a set of ports, and an execute function. Ops can be anything: math operations, texture loaders, shader renderers, audio analyzers.

**Port** (`core_port.js`): The connection point on an operator. Ports come in three flavors:
- **Value ports**: Hold data (numbers, strings, colors). Changes propagate immediately.
- **Trigger ports**: Fire events. Used for frame loops and sequencing.
- **Object ports**: Pass complex objects (textures, meshes, render contexts).

**Link** (`core_link.js`): An edge connecting an output port to an input port. Links enforce type compatibility and manage the data flow. For example, a trigger port cannot connect to a value port, and a number port cannot connect to a texture port.

### The Dual Execution Model

Here is where Cables gets interesting. The framework uses two complementary execution strategies — but, importantly, *neither is a graph evaluator*. There is no scheduler, no topological sort, and no dirty-set. `core_patch.js` has no `exec()` or `update()` method. Both strategies are **eager and synchronous push**; they differ only in *what* they push and *when*.

**Value-driven (eager push on change)**: When an output value port is `set()`, the new value is immediately and synchronously written down every outgoing link into the connected input ports — which fire those operators' `onChange` handlers in the same call stack. There is no pull, no laziness, and no value cache: `Port.get()` simply returns the stored `value` field. The only pull-style computation in the whole system is *animation* — an animated port lazily samples its keyframe curve once per frame inside `get()`. A connected value port is therefore *always already current*, because every upstream change pushed it there the instant it happened.

**Trigger-driven (push every frame)**: A mainloop operator's `requestAnimationFrame` callback fires a trigger. This cascades synchronously, depth-first, through connected trigger ports, causing operators to execute in order. This is the animation heartbeat.

```
                    ┌─────────────┐
                    │  MainLoop   │  Fires every frame
                    │   trigger   │
                    └──────┬──────┘
                           │
          ┌────────────────┼────────────────┐
          ▼                ▼                ▼
    ┌───────────┐    ┌───────────┐    ┌───────────┐
    │ Transform │    │  Shader   │    │   Mesh    │
    │    Op     │    │    Op     │    │    Op     │
    └───────────┘    └───────────┘    └───────────┘
          │                │                │
          └────────────────┼────────────────┘
                           ▼
                    ┌───────────┐
                    │   Render  │  Final draw call
                    └───────────┘
```

Why both? Consider a slider controlling rotation speed. The slider value is pushed into the graph only when the artist drags it — between drags, no value-flow work happens at all. But the rotation itself must advance every frame, so it hangs off the trigger heartbeat. The split lets the two kinds of change ride their own clocks: values move on edit, triggers move on `requestAnimationFrame`. When a trigger reaches an operator, that operator's value inputs have *already* been kept current by earlier pushes — the two flows meet without any dependency tracking.

### Cycles Are Not Prevented

Visual programming has a dangerous trap: cycles. If Op A triggers Op B which triggers Op A, you get infinite recursion. It is worth being precise here, because Cables is often described as having cycle protection — **it does not**.

`Patch` keeps a `_triggerStack` array (`core_patch.js`), and `Port.trigger()` pushes/pops onto it around each downstream call. But nothing ever consults it to skip a re-entrant trigger — its *only* consumer is `printTriggerStack()`, a `console.table` debug dump. There is no `triggerStack.includes(op)` guard anywhere in the core.

A genuine A→B→A trigger cycle therefore recurses on the JavaScript call stack until the engine throws a stack-overflow `RangeError`. The `try/catch` wrapping the trigger loop catches it, sets `op.enabled = false` on the crashing operator, and aborts the rest of that fan-out. So a cyclic patch does not hard-lock the browser — but that is incidental crash *recovery*, not cycle *prevention*. (Iteration operators like `Repeat` are fine: they re-enter *downstream* paths, never themselves.)

With the patch layer handling node execution, we now need a way to translate those node actions into actual GPU commands.

---

## Layer 2: The Graphics Abstraction - API-Agnostic Rendering

The patch layer knows about nodes and connections. It does not know about WebGL or WebGPU. That knowledge lives in the graphics abstraction layer, which provides a consistent interface regardless of the underlying API.

### The Core Abstractions

**CgContext**: The rendering context base class. It manages:
- **Matrix stacks**: Projection (pMatrix), Model (mMatrix), View (vMatrix)
- **Resource lifecycle**: Creating and destroying GPU resources
- **Frame management**: Beginning and ending render passes

**CgShader**: Represents a compiled shader program. Key features:
- Uniform binding with type safety
- Module injection for composition (inject code snippets into shaders)
- Caching to avoid redundant compilation

**CgMesh**: Combines geometry with rendering state:
- Vertex attributes and index buffers
- Associated materials and textures
- Draw call configuration

**CgGeometry**: Raw vertex data before it becomes a mesh:
- Position, normal, UV, color arrays
- Index array for indexed drawing
- Attribute layout specification

### Matrix Stacks: Why Stacks?

The matrix stack pattern deserves explanation. In a hierarchical scene, a child object's transform depends on its parent. Consider a robot arm: the hand's position depends on the arm's rotation, which depends on the shoulder's rotation.

```
World
└── Shoulder (rotate 30deg)
    └── Arm (rotate 45deg)
        └── Hand (position depends on both rotations)
```

Without stacks, you would need to manually track and restore matrices:

```javascript
// Tedious and error-prone
let savedMatrix = copyMatrix(modelMatrix);
modelMatrix = multiply(modelMatrix, shoulderTransform);
// ... draw shoulder ...
modelMatrix = multiply(modelMatrix, armTransform);
// ... draw arm ...
modelMatrix = savedMatrix; // Oops, what about the hand?
```

With stacks, hierarchy becomes natural:

```javascript
pushMatrix();
  applyTransform(shoulderTransform);
  // draw shoulder
  pushMatrix();
    applyTransform(armTransform);
    // draw arm
    pushMatrix();
      applyTransform(handTransform);
      // draw hand
    popMatrix();
  popMatrix();
popMatrix();
```

Each push/pop pair creates a scope. Transforms applied inside the scope are automatically undone when the scope exits. This pattern appears throughout Cables, not just for matrices.

---

## Layer 3: Platform Implementations

The abstraction layer defines interfaces. The platform layer implements them for specific APIs.

### CglContext: WebGL2 Implementation

WebGL is stateful. Binding a texture affects all subsequent draw calls until you bind something else. This creates a problem: if Operator A sets blend mode to additive and Operator B forgets to reset it, B's output is wrong.

Cables solves this with **state stacks** - the same pattern as matrix stacks, applied to GPU state:

```javascript
// Without state stacks (fragile)
gl.enable(gl.BLEND);
gl.blendFunc(gl.SRC_ALPHA, gl.ONE);
// ... draw with additive blend ...
// Oops, forgot to restore. Next operator inherits this state.

// With state stacks (robust)
pushBlendMode(BLEND_ADDITIVE);
// ... draw with additive blend ...
popBlendMode();
// Previous blend mode automatically restored
```

CglContext maintains stacks for:
- **Depth state**: depth test, depth write, depth function
- **Blend state**: blend enable, blend function, blend equation
- **Cull state**: face culling mode
- **Shader state**: currently bound shader program
- **Framebuffer state**: render target stack

This isolation means operators cannot accidentally affect each other's rendering state.

### CgpContext: WebGPU Implementation

WebGPU takes a different approach. Instead of mutable global state, it uses **bind groups** - immutable bundles of resources bound together:

```
┌─────────────────────────────────────────┐
│              Bind Group 0               │
│  ┌─────────┐ ┌─────────┐ ┌─────────┐   │
│  │ Uniform │ │ Texture │ │ Sampler │   │
│  │ Buffer  │ │         │ │         │   │
│  └─────────┘ └─────────┘ └─────────┘   │
└─────────────────────────────────────────┘
```

CgpContext translates the stack-based mental model to WebGPU's bind group model. When you "push" state, it prepares a new bind group. When you "pop," it switches back to the previous one.

The key difference: WebGPU requires more upfront work (creating pipelines, bind group layouts) but executes more predictably. There is no hidden global state to corrupt.

Understanding these platform differences helps when porting Cables concepts to other environments.

---

## Mapping to [wgpu](https://github.com/gfx-rs/wgpu) (Rust)

If you are building a similar system in Rust with [wgpu](https://github.com/gfx-rs/wgpu), here is how the concepts translate:

| Cables Concept | [wgpu](https://github.com/gfx-rs/wgpu) Equivalent |
|----------------|-----------------|
| CgContext | `wgpu::Device` + `wgpu::Queue` |
| CgShader | `wgpu::ShaderModule` + `wgpu::RenderPipeline` |
| CgMesh | `wgpu::Buffer` (vertex + index) + `wgpu::BindGroup` |
| Matrix stacks | Custom `MatrixStack` struct with `Vec<Mat4>` |
| State stacks | `RenderPassDescriptor` + custom state tracking |
| Bind groups | `wgpu::BindGroup` (already native) |

The key architectural decision: [wgpu](https://github.com/gfx-rs/wgpu) does not have WebGL's global state problem, so you might not need state stacks. However, the matrix stacks pattern remains valuable for hierarchical transforms.

```rust
// Conceptual Rust equivalent of the matrix stack
struct MatrixStack {
    stack: Vec<Mat4>,
}

impl MatrixStack {
    fn push(&mut self) {
        let current = *self.stack.last().unwrap();
        self.stack.push(current);
    }

    fn pop(&mut self) -> Mat4 {
        self.stack.pop().expect("Stack underflow")
    }

    fn apply(&mut self, transform: Mat4) {
        let current = self.stack.last_mut().unwrap();
        *current = *current * transform;
    }
}
```

---

## Key Patterns Summary

1. **Dual execution model**: Values are pushed eagerly on change; triggers are pushed every frame. Both are synchronous — there is no graph evaluator, scheduler, or dirty-set.

2. **Stack-based state management**: Push before modifying, pop to restore. Works for matrices and GPU state alike.

3. **No cycle prevention**: The trigger stack is debug-only telemetry. Trigger cycles recurse until a JS stack overflow, which `try/catch` turns into disabling the crashed operator.

4. **Eager push, not lazy evaluation**: A value is propagated the instant it is set; `get()` just returns a stored field. Animation sampling (once per frame) is the only lazy path.

5. **API abstraction layer**: Write operators once, run on multiple backends.

6. **Module injection for shader composition**: Operators can inject code snippets into shaders without knowing the full shader source.

These patterns work together to create a visual programming environment that feels immediate while correctly managing GPU complexity underneath.

---

## What is Next

- **rendering-pipeline.md**: How a frame flows from trigger to pixels
- **api-design.md**: Patterns for writing your own operators

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `core_patch.js` | Patch container and execution coordinator |
| `core_op.js` | Operator base class and lifecycle |
| `core_port.js` | Port types and value propagation |
| `core_link.js` | Connection management |
| `cg/cg_context.js` | Abstract graphics context |
| `cg/cg_shader.js` | Abstract shader interface |
| `cgl/cgl_context.js` | WebGL2 implementation |
| `cgp/cgp_context.js` | WebGPU implementation |
