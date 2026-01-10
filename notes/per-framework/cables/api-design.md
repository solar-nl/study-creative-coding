# Cables API Design

> How do you make GPU programming accessible to visual artists?

## Key Insight

> **Cables API's core idea:** Operators are self-contained units with typed ports (Value/Trigger/Object) that connect like LEGO bricks, hiding GPU complexity while preserving full capability through the push/pop state pattern.

---

## The Problem: GPU Programming Is Hard

Graphics programming has a steep learning curve. You need to understand shader languages, buffer management, texture binding, uniform locations, matrix stacks, and render state. For artists who just want to create visual experiences, this is an enormous barrier.

The naive solution is to wrap everything in a thick abstraction layer. But then you lose flexibility, and power users can't do anything interesting.

Cables takes a different approach: decompose GPU operations into small, connectable units that hide complexity without removing capability. Think of it like LEGO bricks. Each brick is simple - a single shape with standard connectors. But snap enough together, and you can build anything.

---

## The Mental Model: LEGO for Graphics

Cables organizes everything around three concepts:

| Concept | LEGO Equivalent | Purpose |
|---------|-----------------|---------|
| **Ops** | Individual bricks | Self-contained units of functionality |
| **Ports** | Studs and holes | Connection points between ops |
| **Patches** | Assembled builds | Complete programs made from connected ops |

An op might rotate geometry, apply a texture, or output a number. Ports define what goes in and what comes out. Connect the right ports together, and data flows through your patch.

Here's where it gets interesting: this visual model maps directly to how GPUs actually work. Shaders receive inputs, transform them, and produce outputs. Cables just makes this explicit and visual.

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Geometry   │────▶│  Transform  │────▶│   Shader    │────▶ Screen
│     Op      │     │     Op      │     │     Op      │
└─────────────┘     └─────────────┘     └─────────────┘
     mesh            position/rot         color/tex
```

---

## The Declarative-Imperative Split

With the mental model in place, let's look at implementation. Every op consists of two parts: a JSON manifest that declares *what* the op is, and JavaScript that defines *how* it works.

### The Manifest: Describing Structure

The JSON file declares ports, metadata, and documentation:

```json
{
  "id": "myMaterialOp",
  "layout": {
    "portsIn": [
      { "name": "render", "type": 1 },
      { "name": "color", "type": 0, "value": [1, 0, 0, 1] },
      { "name": "texture", "type": 2 }
    ],
    "portsOut": [
      { "name": "trigger", "type": 1 }
    ]
  }
}
```

Notice the port types. This is how Cables distinguishes between data categories:

| Type | Name | Purpose | Examples |
|------|------|---------|----------|
| 0 | Value | Numbers, strings, colors, booleans | `inFloat`, `inBool`, `inString` |
| 1 | Trigger | Execution flow signals | `inTrigger`, `outTrigger` |
| 2 | Object | Complex resources | Geometry, textures, shaders |

Why separate these? Because they have fundamentally different semantics. A Value changes occasionally. A Trigger fires every frame. An Object is a handle to GPU memory. Mixing them would create confusion and bugs.

### The Implementation: Defining Behavior

The JavaScript file brings the op to life:

```javascript
// Port creation mirrors the manifest
const render = op.inTrigger("render");
const inColor = op.inFloat("color", 1.0);
const inTexture = op.inObject("texture", null, "texture");
const trigger = op.outTrigger("trigger");

// Shader setup
const shader = new CGL.Shader(cgl, "myMaterial");
shader.setModules(["MODULE_VERTEX_POSITION", "MODULE_COLOR"]);

const uniColor = new CGL.Uniform(shader, "f", "uColor", inColor);
```

The key insight: JavaScript handles the imperative aspects - responding to events, managing state, updating uniforms. The JSON handles the declarative aspects - what ports exist, their types, their default values. Each does what it's best at.

In [wgpu](https://github.com/gfx-rs/wgpu) terms, this split resembles the distinction between pipeline descriptors (declarative) and command encoding (imperative).

---

## Trigger Propagation: The Execution Model

Understanding how data flows through an op is one thing. Understanding how *execution* flows is another. Here's the core pattern that makes Cables tick: ops don't just sit there - they respond to triggers and propagate execution downstream.

```javascript
render.onTriggered = function() {
    // 1. Push state onto stack
    cgl.pushShader(shader);
    cgl.pushModelMatrix();

    // 2. Apply transformations
    mat4.translate(cgl.mMatrix, cgl.mMatrix, [x, y, z]);

    // 3. Propagate downstream
    trigger.trigger();

    // 4. Pop state from stack
    cgl.popModelMatrix();
    cgl.popShader();
};
```

Let's trace what happens when a frame renders:

1. The root `MainLoop` op fires its trigger (once per frame)
2. Connected ops receive `onTriggered` calls
3. Each op does its work (transform matrices, bind shaders, etc.)
4. Each op calls `trigger.trigger()` to continue the chain
5. The trigger propagates through the entire patch graph
6. Stack-based state management ensures proper cleanup

This is essentially a depth-first traversal of the patch graph, with automatic state scoping via push/pop pairs.

```
MainLoop triggers
       │
       ▼
┌──────────────┐
│ pushShader() │
│ pushMatrix() │
│              │──▶ trigger.trigger()
│ popMatrix()  │         │
│ popShader()  │         ▼
└──────────────┘   (child ops...)
                         │
                         ▼
                   (returns here)
```

The push/pop pattern ensures that each op's state changes are scoped to its subtree. Children inherit the parent's state, but siblings don't affect each other.

---

## Tracing a Material Op: From Definition to Pixels

Now that we understand the core patterns, let's walk through a complete material op to see how all the pieces fit together.

### Step 1: File Structure

A material op lives in a directory with these files:

```
Ops.Gl.Shader.MyMaterial/
├── MyMaterial.js       # Implementation
├── MyMaterial.json     # Port definitions
├── MyMaterial.md       # Documentation
├── att_material.vert   # Vertex shader
└── att_material.frag   # Fragment shader
```

The `att_` prefix marks shader attachments. Cables loads these automatically when the op initializes.

### Step 2: Shader Creation

```javascript
const shader = new CGL.Shader(cgl, "myMaterial");
shader.setSource(
    attachments.material_vert,
    attachments.material_frag
);

// Enable modular features
shader.setModules([
    "MODULE_VERTEX_POSITION",  // Position transforms
    "MODULE_COLOR",            // Vertex colors
    "MODULE_BEGIN_FRAG"        // Fragment preprocessing
]);
```

Shader modules are Cables' answer to shader variants. Instead of maintaining separate shaders for every feature combination, modules inject code snippets at specific points. This is similar to [wgpu](https://github.com/gfx-rs/wgpu)'s approach of composing shader modules.

### Step 3: Uniform Binding

```javascript
const inColor = op.inFloat("baseColor", 1.0);
const uniColor = new CGL.Uniform(shader, "f", "uBaseColor", inColor);

// When the port changes, the uniform updates automatically
// No explicit update() call needed - Cables handles this
```

Ports and uniforms are linked. Change the port value in the editor, and the uniform updates on the next frame. This is the magic that makes real-time tweaking possible.

### Step 4: Texture Handling

```javascript
const inTexture = op.inObject("Texture", null, "texture");

render.onTriggered = function() {
    // Dynamic shader configuration based on input
    if (inTexture.get()) {
        shader.define("HAS_TEXTURE");
        cgl.pushTexture(inTexture.get().tex, 0);
    } else {
        shader.removeDefine("HAS_TEXTURE");
    }

    cgl.pushShader(shader);
    trigger.trigger();
    cgl.popShader();

    if (inTexture.get()) {
        cgl.popTexture(0);
    }
};
```

Notice the pattern: define/removeDefine toggles shader features at runtime. The shader uses `#ifdef HAS_TEXTURE` to conditionally sample. This avoids the combinatorial explosion of separate shaders for every feature permutation.

In [wgpu](https://github.com/gfx-rs/wgpu), you'd achieve similar flexibility with bind group layouts and pipeline variants, though the mechanism is more explicit.

### Step 5: The Complete Render Loop

```javascript
render.onTriggered = function() {
    if (!mesh) return;  // Guard against missing geometry

    // Configure shader
    shader.define("USE_LIGHTING");

    // Bind resources
    cgl.pushShader(shader);
    cgl.pushModelMatrix();
    cgl.pushTexture(texture.tex, 0);

    // Update per-frame uniforms
    uniTime.setValue(op.patch.timer.getTime());

    // Draw
    mesh.render(shader);

    // OR propagate to children
    trigger.trigger();

    // Cleanup (reverse order)
    cgl.popTexture(0);
    cgl.popModelMatrix();
    cgl.popShader();
};
```

The stack discipline is critical. Push in one order, pop in reverse. Miss a pop, and subsequent ops render with wrong state. This is why Cables encourages the push-work-pop pattern - it's harder to forget cleanup when it's structurally required.

---

## Resource Lifecycle: Creation, Use, and Cleanup

Beyond rendering, there's another critical concern: GPU resources need explicit management. Cables provides patterns for each phase of the lifecycle.

### Lazy Initialization

```javascript
let mesh = null;
let needsUpdate = true;

inParam.onChange = function() {
    needsUpdate = true;  // Mark dirty, don't rebuild yet
};

render.onTriggered = function() {
    if (needsUpdate) {
        if (mesh) mesh.dispose();  // Clean up old resource
        mesh = buildMesh();        // Create new one
        needsUpdate = false;
    }

    mesh.render(shader);
    trigger.trigger();
};
```

Why lazy? Because parameters often change multiple times before the next render (slider dragging, animation curves). Rebuilding immediately would waste work. Instead, mark dirty and rebuild only when actually needed.

### Cleanup on Deletion

```javascript
op.onDelete = function() {
    if (mesh) mesh.dispose();
    if (framebuffer) framebuffer.delete();
    if (texture) texture.delete();
};
```

When an op is removed from the patch, `onDelete` fires. This is your chance to release GPU resources. Miss this, and you leak VRAM.

In [wgpu](https://github.com/gfx-rs/wgpu) terms, this maps to explicit `drop()` calls or letting resources fall out of scope. The difference: [wgpu](https://github.com/gfx-rs/wgpu) uses Rust's ownership system to enforce cleanup; Cables relies on developer discipline.

### Common Resource Types and Their Cleanup Methods

| Resource | Create | Cleanup |
|----------|--------|---------|
| Mesh | `new CGL.Mesh(cgl)` | `mesh.dispose()` |
| Framebuffer | `new CGL.Framebuffer(cgl, w, h)` | `framebuffer.delete()` |
| Texture | `CGL.Texture.load(cgl, url)` | `texture.delete()` |
| Shader | `new CGL.Shader(cgl, name)` | (automatic on op delete) |

---

## Patterns Worth Stealing

Having traced through Cables' architecture, several patterns stand out as broadly applicable - even outside of visual programming environments.

### 1. The Push/Pop State Stack

Cables' hierarchical state management via push/pop is elegant. Each op modifies state for its subtree without polluting siblings. In [wgpu](https://github.com/gfx-rs/wgpu), you'd implement this with render pass builders or command encoder scopes.

```rust
// wgpu equivalent concept
fn render_subtree(encoder: &mut CommandEncoder, state: &State) {
    let child_state = state.with_transform(my_transform);
    render_children(encoder, &child_state);
    // child_state dropped here - no explicit pop needed
}
```

### 2. Declarative + Imperative Split

Separating "what exists" (JSON) from "how it behaves" (JS) is powerful. In Rust, this could be a derive macro that generates port declarations from struct definitions.

```rust
#[derive(Op)]
struct MyMaterial {
    #[port(trigger)] render: InTrigger,
    #[port(value, default = 1.0)] color: InFloat,
    #[port(object)] texture: InTexture,
    #[port(trigger)] trigger: OutTrigger,
}
```

### 3. Dirty Flags for Lazy Updates

The `needsUpdate` pattern avoids redundant rebuilds. In [wgpu](https://github.com/gfx-rs/wgpu), you'd track which buffers need uploading and batch updates before the render pass.

### 4. Typed Port Connections

Distinguishing Value/Trigger/Object at the type level prevents nonsensical connections. A geometry output can't connect to a float input. The type system enforces correctness visually.

---

## What's Next

- **Shader Modules**: How Cables composes shaders from reusable pieces
- **Animation System**: How ops handle time-varying values
- **Performance Patterns**: Batching, instancing, and render-to-texture in Cables

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `src/corelibs/cgl/cgl_shader.js` | Shader creation, uniform management, module system |
| `src/corelibs/cgl/cgl_mesh.js` | Geometry buffer management |
| `src/corelibs/cgl/cgl_state.js` | Push/pop state stack implementation |
| `src/core/core_op.js` | Op base class, port creation |
| `src/ops/base/Ops.Gl.Shader.*/*.js` | Material op implementations |
