# Stack-Based vs RAII-Scoped GPU State Management

**Question:** When managing GPU state across complex rendering pipelines, should frameworks use explicit push/pop stacks or rely on scoped lifetime management?

---

## The Core Tension

GPU state management presents a fundamental challenge: rendering operations depend on bound resources (shaders, buffers, blend modes, viewports), but the order of binding and unbinding must be carefully orchestrated to avoid corruption.

Two philosophies emerge:

1. **Explicit Stack Operations** — Push state before operations, pop after. The programmer (or system) explicitly manages the lifecycle. Errors manifest at runtime, but the model is transparent and debuggable.

2. **RAII Scoped Bindings** — Tie resource binding to object lifetime. Constructors bind, destructors unbind. The language enforces cleanup, but the model is implicit and relies on compiler/runtime guarantees.

Both patterns achieve the same goal — ensuring GPU state is properly restored after temporary modifications — but they optimize for different contexts, failure modes, and mental models.

---

## Pattern A: Stack-Based State (cables.gl)

### Context

cables.gl is a visual programming environment where users build shaders and effects by connecting nodes in a graph. Key characteristics:

- **Non-programmer users** — Artists and designers who think in data flow, not lexical scope
- **Node graphs** — Execution order determined by graph topology, not source code order
- **Multi-author nodes** — Different people write different operators; no shared lexical context
- **Runtime composition** — Patches are assembled and modified at runtime

In this environment, lexical scope has no meaning. A node that modifies shader state cannot rely on C++ destructors or Rust's `Drop` because the "scope" is the node's execution within a graph traversal.

### How It Works

```javascript
// State stacks declared in the WebGL context wrapper
this._shaderStack = [];
this._stackBlendMode = [];
this._viewPortStack = [];
this._frameBufferStack = [];
this._glBlendModeStack = [];

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

pushBlendMode(mode, premul) {
    this._stackBlendMode.push({ mode, premul });
    this._setBlendMode(mode, premul);
}

popBlendMode() {
    this._stackBlendMode.pop();
    const prev = this._stackBlendMode[this._stackBlendMode.length - 1];
    if (prev) this._setBlendMode(prev.mode, prev.premul);
}
```

Operators (nodes) use these stacks to isolate their state modifications:

```javascript
// Inside an operator's execute() method
execute() {
    cgl.pushShader(this.shader);
    cgl.pushBlendMode(CGL.BLEND_ADD, false);

    this.triggerChildren();  // Execute downstream nodes

    cgl.popBlendMode();
    cgl.popShader();
}
```

### The Flow

```
Frame Start
    │
    ├─► Node A executes
    │       push(shaderA)           Stack: [shaderA]
    │       │
    │       ├─► Node B executes
    │       │       push(shaderB)   Stack: [shaderA, shaderB]
    │       │       draw()
    │       │       pop()           Stack: [shaderA]
    │       │
    │       ├─► Node C executes
    │       │       push(shaderC)   Stack: [shaderA, shaderC]
    │       │       draw()
    │       │       pop()           Stack: [shaderA]
    │       │
    │       pop()                   Stack: []
    │
Frame End
    │
    └─► Validate: all stacks empty?
```

### Frame Boundary Validation

cables.gl validates stack state at frame boundaries:

```javascript
endFrame() {
    if (this._shaderStack.length > 0)
        this.logStackError("_shaderStack length !=0 at end of rendering...");
    if (this._stackBlendMode.length > 0)
        this.logStackError("_stackBlendMode length !=0 at end of rendering...");
    if (this._frameBufferStack.length > 0)
        this.logStackError("_frameBufferStack length !=0 at end of rendering...");
}
```

This catches mismatched push/pop calls but only after the frame completes — potentially after visual artifacts have occurred.

### When It Excels

- **Visual programming** — Node authors don't share lexical scope
- **Dynamic graphs** — Execution paths change at runtime
- **Debugging** — Stack contents are inspectable at any point
- **Cross-language** — Works in JavaScript where RAII doesn't exist
- **Explicit control** — No hidden behavior; every state change is visible

---

## Pattern B: RAII Scoped Bindings (Cinder)

### Context

Cinder is a C++ creative coding framework for professional graphics programming. Key characteristics:

- **C++ programmers** — Developers who think in objects, lifetimes, and scope
- **Sequential code** — Execution follows source code order
- **Exception safety** — Must handle early returns and thrown exceptions
- **Compile-time guarantees** — Leverage the type system for correctness

In this environment, lexical scope maps directly to resource lifetime. A function that binds a buffer expects it unbound when the function exits, regardless of how it exits.

### How It Works

```cpp
struct ScopedBuffer : public Noncopyable {
    ScopedBuffer( const BufferObjRef &bufferObj )
        : mCtx( gl::context() ), mTarget( bufferObj->getTarget() )
    {
        mCtx->pushBufferBinding( mTarget, bufferObj->getId() );
    }

    ~ScopedBuffer()
    {
        mCtx->popBufferBinding( mTarget );
    }

private:
    Context     *mCtx;
    GLenum      mTarget;
};

struct ScopedVao : public Noncopyable {
    ScopedVao( const VaoRef &vao )
        : mCtx( gl::context() )
    {
        mCtx->pushVao( vao );
    }

    ~ScopedVao()
    {
        mCtx->popVao();
    }

private:
    Context *mCtx;
};
```

Usage is implicit — binding happens at declaration, unbinding at scope exit:

```cpp
void BufferObj::bufferData( GLsizeiptr size, const GLvoid *data, GLenum usage )
{
    ScopedBuffer bufferBind( mTarget, mId );  // Bind on construction
    mSize = size;
    glBufferData( mTarget, mSize, data, usage );
}  // Unbind on scope exit (destructor called)

void draw()
{
    ScopedGlslProg shader( mShader );
    ScopedVao vao( mVao );
    ScopedTextureBind tex( mTexture );

    if (earlyExitCondition) {
        return;  // All three resources properly unbound!
    }

    gl::drawArrays( GL_TRIANGLES, 0, mVertexCount );
}  // Automatic cleanup even with early return
```

### The Flow

```
Function Entry
    │
    ├─► ScopedShader constructed
    │       └─► pushShader()        Stack: [shaderA]
    │
    ├─► ScopedVao constructed
    │       └─► pushVao()           Stack: [vaoA]
    │
    ├─► draw()
    │
    ├─► (scope exit - reverse order)
    │
    ├─► ~ScopedVao
    │       └─► popVao()            Stack: []
    │
    └─► ~ScopedShader
            └─► popShader()         Stack: []

Function Exit (normal, early return, or exception)
```

### Exception Safety

The critical advantage appears in error handling:

```cpp
void complexRender()
{
    ScopedFramebuffer fbo( mOffscreenFbo );
    ScopedViewport viewport( mOffscreenSize );
    ScopedBlendAlpha blend;

    processData();        // Might throw!
    uploadToGPU();        // Might fail!
    gl::draw( mBatch );   // Might error!

}  // Even if any line throws, all three resources are unbound
```

### When It Excels

- **Exception safety** — Guaranteed cleanup regardless of exit path
- **Compile-time correctness** — Impossible to forget the pop
- **Nested scopes** — Natural nesting with `{ }` blocks
- **Code clarity** — No explicit cleanup code cluttering logic
- **Single-author code** — One developer controls the entire scope

---

## Side-by-Side Comparison

| Dimension | Stack-Based (cables.gl) | RAII Scoped (Cinder) |
|-----------|------------------------|----------------------|
| **Binding/Unbinding** | Explicit `push()`/`pop()` calls | Implicit via constructor/destructor |
| **Error Detection** | Runtime (frame boundary checks) | Compile-time (scope rules) |
| **Exception Safety** | Manual (must catch and pop) | Automatic (destructor always runs) |
| **Debuggability** | High (inspect stack at any time) | Medium (must trace object lifetimes) |
| **Mental Model** | Data structure (stack) | Language feature (scope) |
| **Multi-author** | Natural (each node isolated) | Challenging (must agree on scope) |
| **Visual Programming** | Natural fit | Poor fit |
| **Traditional Programming** | Verbose | Idiomatic |

---

## Combining the Patterns

The patterns are not mutually exclusive. A sophisticated framework can layer RAII on top of stacks, getting both explicit debuggability and automatic safety.

### Hybrid Architecture

```
┌─────────────────────────────────────────────┐
│            User-Facing API Layer            │
│  (RAII guards for traditional programming) │
│  (Explicit push/pop for visual systems)    │
└─────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│         Internal State Stack Layer          │
│    (Always stack-based for consistency)     │
│    (Enables debugging and validation)       │
└─────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────┐
│           GPU Binding Layer                 │
│      (Actual WebGPU/OpenGL calls)          │
└─────────────────────────────────────────────┘
```

### Rust Implementation

Rust's ownership system and `Drop` trait enable a clean hybrid:

```rust
/// Internal state stack (always present)
pub struct RenderContext {
    shader_stack: Vec<ShaderId>,
    blend_mode_stack: Vec<BlendMode>,
    viewport_stack: Vec<Viewport>,
}

impl RenderContext {
    /// Explicit push for visual programming / node graphs
    pub fn push_shader(&mut self, shader: ShaderId) {
        self.shader_stack.push(shader);
        self.bind_shader(shader);
    }

    /// Explicit pop for visual programming / node graphs
    pub fn pop_shader(&mut self) -> Result<(), StateError> {
        self.shader_stack.pop()
            .ok_or(StateError::EmptyStack("shader"))?;

        if let Some(&prev) = self.shader_stack.last() {
            self.bind_shader(prev);
        } else {
            self.unbind_shader();
        }
        Ok(())
    }

    /// RAII guard for traditional programming
    pub fn scoped_shader(&mut self, shader: ShaderId) -> ShaderGuard<'_> {
        self.push_shader(shader);
        ShaderGuard { ctx: self }
    }
}

/// RAII guard that pops on drop
pub struct ShaderGuard<'a> {
    ctx: &'a mut RenderContext,
}

impl Drop for ShaderGuard<'_> {
    fn drop(&mut self) {
        // Infallible: we pushed in scoped_shader, so pop must succeed
        let _ = self.ctx.pop_shader();
    }
}

// Traditional programming usage (RAII):
fn render_scene(ctx: &mut RenderContext) {
    let _shader = ctx.scoped_shader(pbr_shader);
    let _blend = ctx.scoped_blend_mode(BlendMode::Alpha);

    draw_meshes(ctx);  // Shader and blend mode active

}  // Automatic cleanup via Drop

// Visual programming / node graph usage (explicit):
fn execute_node(ctx: &mut RenderContext, node: &Node) {
    ctx.push_shader(node.shader);

    for child in &node.children {
        execute_node(ctx, child);
    }

    ctx.pop_shader().expect("balanced push/pop");
}
```

### Frame Validation (Debug Builds)

```rust
impl RenderContext {
    pub fn end_frame(&self) {
        #[cfg(debug_assertions)]
        {
            assert!(self.shader_stack.is_empty(),
                "Shader stack not empty at frame end: {:?}", self.shader_stack);
            assert!(self.blend_mode_stack.is_empty(),
                "Blend mode stack not empty at frame end");
            assert!(self.viewport_stack.is_empty(),
                "Viewport stack not empty at frame end");
        }
    }
}
```

---

## Implications for the GPU Resource Pool

### Recommendation 1: Stack Internals, RAII Surface

The internal implementation should always use stacks:

- **Debuggable** — Can dump stack state for diagnostics
- **Validateable** — Frame boundary checks catch bugs
- **Flexible** — Works for both programming models

The public API should offer both interfaces:

```rust
// For procedural/scripting use:
ctx.push_shader(shader);
ctx.pop_shader();

// For idiomatic Rust use:
let _guard = ctx.scoped_shader(shader);
```

### Recommendation 2: Guard Types Should Be Explicit

Don't hide the RAII pattern too deeply. Users should see and understand the guards:

```rust
// Good: explicit guard variable
let _shader_guard = ctx.scoped_shader(my_shader);
draw_mesh(ctx, &mesh);

// Avoid: inline guard that's immediately dropped
ctx.scoped_shader(my_shader);  // Oops! Guard dropped immediately!
draw_mesh(ctx, &mesh);         // Shader not active!
```

Rust's `#[must_use]` attribute helps:

```rust
#[must_use = "ShaderGuard unbinds shader when dropped"]
pub struct ShaderGuard<'a> { /* ... */ }
```

### Recommendation 3: Support Nested Binding with Clear Semantics

Both patterns support nesting naturally, but semantics should be documented:

```rust
fn render() {
    let _outer = ctx.scoped_shader(shader_a);
    // shader_a active

    {
        let _inner = ctx.scoped_shader(shader_b);
        // shader_b active (overrides shader_a)

    }  // shader_a restored

}  // original state restored
```

### Recommendation 4: Validate in Debug, Trust in Release

Frame boundary validation is valuable but has runtime cost:

```rust
#[cfg(debug_assertions)]
fn validate_frame_end(&self) {
    // Full stack validation with detailed error messages
}

#[cfg(not(debug_assertions))]
fn validate_frame_end(&self) {
    // No-op in release builds
}
```

### Recommendation 5: Error Recovery Strategy

When a stack error is detected, the framework needs a recovery strategy:

```rust
pub enum StackErrorRecovery {
    /// Log warning and continue (cables.gl approach)
    LogAndContinue,
    /// Reset all stacks to empty (safe but might cause visual glitches)
    ResetStacks,
    /// Panic (debug builds) / Reset (release builds)
    PanicDebugResetRelease,
}
```

For creative coding, `LogAndContinue` or `ResetStacks` are usually preferable to crashing — a visual glitch is better than a dead application.

### Recommendation 6: Consider Async Rendering

Modern GPU APIs (WebGPU, Vulkan) have command buffer models where state binding is recorded, not immediately executed. This changes the calculus:

```rust
// Command buffer recording (state is recorded, not applied)
encoder.set_pipeline(&pipeline);
encoder.set_bind_group(0, &bind_group);
encoder.draw(0..vertex_count);

// No "pop" needed — command buffer is self-contained
```

For these APIs, the stack pattern may live at a higher abstraction level (managing which resources are "current" for the recording context) rather than directly wrapping GPU calls.

---

## Conclusion

Stack-based state management and RAII scoped bindings are complementary tools addressing the same problem from different angles. The choice depends on context:

- **Visual programming, node graphs, dynamic composition** → Explicit push/pop stacks
- **Traditional programming, exception safety, compile-time guarantees** → RAII guards

A well-designed framework provides both, layering RAII convenience on top of stack internals. This gives users the API that matches their mental model while maintaining debuggability and validation throughout.

For a Rust creative coding framework, this hybrid approach leverages the language's strengths: `Drop` for automatic cleanup, `#[must_use]` for preventing dropped guards, and debug assertions for frame validation — combining the best of both worlds.

---

## Related Documents

- [Resource Lifecycle Patterns](./resource-lifecycle.md) — Creation, caching, and destruction strategies
- [Command Buffer Architecture](../command-buffers.md) — How modern GPU APIs change state management
- [../api-ergonomics.md](../../api-ergonomics.md) — Builder patterns and method chaining across frameworks
- [/insights/rust-specific.md](/insights/rust-specific.md) — Rust idioms for creative coding APIs
