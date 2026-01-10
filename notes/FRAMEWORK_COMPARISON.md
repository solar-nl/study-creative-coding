# Framework Comparison

> What can we learn from studying eight creative coding frameworks?

---

## Why Compare Frameworks?

Every creative coding framework makes trade-offs. Processing prioritizes accessibility over performance. OpenFrameworks wraps C++ complexity for artists. nannou brings Rust's safety to creative coding. Cables abstracts GPU programming into visual nodes.

Studying these trade-offs reveals patterns that transcend any single framework. Some patterns appear everywhere (immediate-mode drawing, frame lifecycle callbacks). Others are unique innovations worth stealing (Cables' push/pop state stacks, PixiJS's batching system, openrndr's token-based text layout).

This document synthesizes insights from eight frameworks studied in depth:

| Framework | Language | First Release | Paradigm |
|-----------|----------|---------------|----------|
| Processing | Java | 2001 | Code-first, immediate mode |
| p5.js | JavaScript | 2014 | Code-first, accessibility-focused |
| OpenFrameworks | C++ | 2005 | Code-first, addon ecosystem |
| Cinder | C++ | 2010 | Code-first, professional quality |
| openrndr | Kotlin | 2018 | Code-first, DSL-oriented |
| nannou | Rust | 2018 | Code-first, type-safe |
| Cables | JavaScript | 2016 | Visual programming, dataflow |
| tixl | C# | 2019 | Visual programming, node-based |

The goal is not to crown a winner. It's to extract patterns that would make a Rust creative coding framework excellent.

---

## The Three Paradigms

Creative coding frameworks cluster into three approaches. Understanding these helps contextualize everything else.

### Immediate-Mode Scripting

**Processing, p5.js, OpenFrameworks, Cinder, openrndr, nannou**

The dominant paradigm. You write code that runs every frame:

```
setup() once → draw() every frame
```

Drawing is immediate: `circle(100, 100, 50)` draws right now. There's no scene graph, no retained objects. The mental model is a blank canvas redrawn 60 times per second.

**Strengths:** Direct, easy to understand, flexible.
**Weaknesses:** No object persistence, harder to do hit-testing or scene queries.

### Visual Node Programming

**Cables, tixl**

You connect boxes with wires. Data flows through connections. Execution order emerges from the graph structure.

**Strengths:** No code required for basics, highly visual, excellent for prototyping.
**Weaknesses:** Complex logic becomes spaghetti, less flexible than code.

### Retained-Mode Scene Graphs

**[Three.js](https://github.com/mrdoob/[three.js](https://github.com/mrdoob/three.js)), Babylon.js** (see [threejs](per-library/web/threejs/) and [babylonjs](per-library/web/babylonjs/))

You build a scene tree of objects, then the framework renders it. Objects persist between frames.

**Strengths:** Natural for 3D, easy object manipulation, built-in culling.
**Weaknesses:** More overhead, less direct control.

---

## Comparison Matrices

### Quick Overview

| Framework | GPU Backend | State Model | Batching | Extensibility |
|-----------|-------------|-------------|----------|---------------|
| Processing | OpenGL (JOGL) | Global + per-call | Manual | Libraries |
| p5.js | Canvas 2D / WebGL | Global | Browser-handled | Addons |
| OpenFrameworks | OpenGL | Push/pop stacks | Manual | Addons |
| Cinder | OpenGL | Explicit state | Manual | Blocks |
| openrndr | OpenGL 3.3 | Drawer context | Manual | orx extensions |
| nannou | [wgpu](https://github.com/gfx-rs/wgpu) | Draw context | Automatic (lyon) | Crates |
| Cables | WebGL / WebGPU | Push/pop stacks | Manual | Operators |
| tixl | DirectX 11 | Dirty flags | Automatic | Operators |

### Architecture Patterns

| Framework | Lifecycle | Resource Loading | Error Handling |
|-----------|-----------|------------------|----------------|
| Processing | `setup()` / `draw()` | Blocking in `setup()` | Stack traces |
| p5.js | `preload()` / `setup()` / `draw()` | Async with preload | Friendly errors |
| OpenFrameworks | `setup()` / `update()` / `draw()` | Manual | Exceptions |
| Cinder | `setup()` / `update()` / `draw()` | Manual | Exceptions |
| openrndr | `extend {}` blocks | Suspend functions | Kotlin exceptions |
| nannou | `model()` / `update()` / `view()` | Futures | Rust Results |
| Cables | Trigger-driven | Async loading ops | Console warnings |
| tixl | Frame evaluation | Symbol evaluation | Editor feedback |

### Rendering Approaches

| Framework | Transform Model | Shader System | Geometry |
|-----------|----------------|---------------|----------|
| Processing | `pushMatrix()` / `popMatrix()` | Built-in + GLSL | PShape |
| p5.js | `push()` / `pop()` | Built-in + GLSL | p5.Geometry |
| OpenFrameworks | `ofPushMatrix()` / `ofPopMatrix()` | ofShader | ofMesh |
| Cinder | Explicit matrices | ci::gl::GlslProg | ci::geom |
| openrndr | Drawer transforms | GLSL + composition | Shape/Contour |
| nannou | Draw context transforms | wgsl | Mesh types |
| Cables | Context stacks | Module injection | CgMesh |
| tixl | Context stacks | HLSL | MeshBuffers |

---

## Pattern Deep Dives

### Pattern 1: The Frame Lifecycle

Every framework needs a way to structure time. The nearly universal pattern:

```
initialize_once() → repeat { update_state(); render_frame(); }
```

The variations matter:

**Processing/p5.js/OpenFrameworks**: Two functions (`setup`, `draw` or equivalent). Simple and proven.

**nannou**: Three functions (`model`, `update`, `view`). Separates state initialization from state updates from rendering. More explicit, but more verbose.

**Cables/tixl**: No explicit functions. The graph structure defines execution order. A "MainLoop" operator triggers the cascade.

**Recommendation for Rust:** The three-function pattern (model/update/view) aligns well with Rust's ownership model. State is explicit, borrows are clear.

### Pattern 2: State Management

GPU rendering involves lots of state: current transform, blend mode, bound textures, active shader. How do frameworks handle this?

**Global Mutable State (Processing, p5.js)**

```java
pushMatrix();
translate(100, 100);
rotate(PI/4);
rect(0, 0, 50, 50);  // Uses current transform
popMatrix();         // Restore previous
```

Simple, but error-prone. Forget to pop, and you've corrupted global state.

**Push/Pop Stacks (OpenFrameworks, Cables)**

```cpp
ofPushStyle();       // Save all style state
ofSetColor(255, 0, 0);
ofDrawCircle(100, 100, 50);
ofPopStyle();        // Restore all style state
```

More robust. The stack enforces proper cleanup.

**Explicit State (Cinder, nannou)**

```rust
draw.ellipse()
    .x_y(100.0, 100.0)
    .radius(50.0)
    .color(RED);
```

No global state to manage. Each call specifies its own properties. More verbose, but impossible to corrupt shared state.

**Recommendation for Rust:** Explicit state via builder patterns. Rust's ownership model makes global mutable state awkward anyway.

### Pattern 3: Resource Lifecycle

GPU resources (textures, buffers, shaders) need explicit management. Different languages handle this differently:

**Garbage Collection (Java, JavaScript, Kotlin, C#)**

Resources are cleaned up when no longer referenced. Convenient, but cleanup timing is unpredictable.

**RAII (C++)**

Resources are freed when their owning object goes out of scope. Predictable, but requires careful lifetime management.

**Rust Ownership**

Resources are freed when their owner is dropped. Compile-time guarantees about lifetimes. No garbage collection pauses, no manual free calls.

**Recommendation:** Rust's approach is ideal for GPU resources. Make `Texture`, `Buffer`, and `Shader` types own their GPU handles, and cleanup is automatic and deterministic.

### Pattern 4: Shader Composition

GLSL shaders are notoriously hard to compose. You can't just `#include` functionality like in C++.

**String Concatenation (most frameworks)**

```javascript
const shader = vertexHeader + customCode + vertexFooter;
```

Works, but fragile. Line numbers in errors don't match source.

**Module Injection (Cables)**

```glsl
{{MODULE_VERTEX_POSITION}}  // Placeholder for injected code
```

Operators inject snippets at marked positions. More structured, but still string-based.

**Node-Based Composition (tixl, Unreal)**

The shader is a graph. Each node contributes a fragment. The system compiles the graph into a shader.

**Recommendation for Rust:** Consider naga for shader manipulation at the AST level. This enables proper composition without string hacks.

### Pattern 5: Extensibility

How do you add functionality without modifying core code?

| Framework | Extension Model |
|-----------|----------------|
| Processing | Libraries (zip files with jars) |
| p5.js | Addons (npm packages) |
| OpenFrameworks | Addons (folders with src/) |
| Cinder | Blocks (similar to OF addons) |
| openrndr | orx (Kotlin packages) |
| nannou | Crates (Cargo packages) |
| Cables | Operators (JS classes) |
| tixl | Operators (C# classes) |

The pattern: a defined interface for extensions, plus a discovery/loading mechanism.

**Recommendation:** Rust's crate system is perfect. Define clear trait interfaces for extensions.

---

## Unique Strengths Worth Stealing

### From p5.js: Friendly Errors

p5.js validates function parameters at runtime and produces helpful error messages:

```
p5.js says: circle() was expecting Number for parameter 0,
received String instead. [Reference: https://p5js.org/reference/#/p5/circle]
```

In Rust, we get this at compile time through types. But we can still improve: custom error types, helpful panic messages, and good documentation.

### From Cables: Push/Pop State Stacks

Cables wraps GPU state in stacks that enforce proper cleanup:

```javascript
cgl.pushDepthTest(true);
// render with depth testing
cgl.popDepthTest();  // automatically restores previous value
```

This pattern works beautifully in Rust with guards:

```rust
let _guard = ctx.push_blend_mode(BlendMode::Additive);
// render with additive blending
// guard drops here, restoring previous blend mode
```

### From openrndr: Token-Based Text Layout

openrndr separates text *layout* from text *rendering*:

```kotlin
writer {
    text("hello", visible = false)  // Layout only
    // glyphOutput.rectangles now contains glyph positions
    // Transform them however you want before drawing
}
```

This enables effects that would be awkward otherwise: text on curves, per-glyph animation, custom hit-testing.

### From nannou: Modular Crate Architecture

nannou splits functionality into focused crates:

```
nannou_core  → No-std color, geometry, math
nannou_wgpu  → GPU backend (depends on wgpu)
nannou_mesh  → Mesh utilities
nannou_audio → Audio processing
```

This enables:
- Using core types without the full framework
- Replacing the audio backend without affecting rendering
- Cross-platform core with platform-specific backends

### From PixiJS: Automatic Batching

PixiJS examines draw calls and automatically merges compatible ones:

```
1000 sprites with same texture → 1 draw call
```

This requires careful attention to state: only batch when blend modes, textures, and shaders match. But the payoff is enormous for 2D rendering.

---

## Common Pitfalls

### Pitfall 1: Global Mutable State

**Problem:** Frameworks that use global state (`currentFillColor`, `currentTransform`) create subtle bugs when library code modifies state unexpectedly.

**Solution:** Explicit state passing. Builder patterns. RAII guards for temporary state changes.

### Pitfall 2: Blocking Resource Loading

**Problem:** Synchronous resource loading freezes the UI. Users see a blank screen while images load.

**Solution:** p5.js's `preload()` pattern. Async loading with loading indicators. Placeholder textures until real textures arrive.

### Pitfall 3: Memory Leaks in Caches

**Problem:** Font caches, texture caches, and shader caches can grow unbounded. (See Cinder #524, nannou #786)

**Solution:** LRU eviction. Weak references. Explicit cache size limits. In Rust: tie cache entries to a frame lifetime or use `Weak<T>`.

### Pitfall 4: Cross-Platform Inconsistencies

**Problem:** The same font renders differently on macOS vs Windows. OpenGL state defaults vary by driver.

**Solution:** Explicit initialization of all state. Bundled fonts rather than system fonts. Integration tests on multiple platforms.

---

## Recommendations for a Rust Framework

Based on patterns observed across all eight frameworks:

### Architecture

1. **Use the model/update/view pattern.** It's explicit about state ownership and works well with Rust's borrow checker.

2. **Modular crate architecture.** Core types (color, geometry) in a no-std crate. GPU backend separate. Audio separate.

3. **Explicit state via builders.** No global mutable state. Each draw call specifies its own properties.

4. **RAII for GPU resources.** Textures, buffers, shaders drop when their owners drop.

### API Design

1. **Builder pattern for configuration.** Methods chain fluidly, return `Self`.

2. **Type-safe primitives.** `Color`, `Point`, `Rect` as distinct types, not just `f32` tuples.

3. **Progressive disclosure.** Simple things are simple. Complex things are possible.

4. **Good error messages.** Use `thiserror` with descriptive variants.

### Rendering

1. **Push/pop guard pattern for state.** Use RAII to ensure cleanup.

2. **Automatic batching where possible.** Especially for 2D sprites and text.

3. **Shader composition via AST.** Use naga rather than string concatenation.

4. **Explicit render passes.** Don't hide [wgpu](https://github.com/gfx-rs/wgpu)'s command buffer model.

### Extensibility

1. **Trait-based extension points.** Define traits for backends, text engines, audio systems.

2. **Feature flags for optional dependencies.** Don't force everyone to compile audio support.

3. **Publish as library, not framework.** Let users compose pieces as needed.

---

## Quick Reference: Per-Framework Documentation

| Framework | Documentation |
|-----------|---------------|
| Processing | [README](per-framework/processing/README.md) · [Architecture](per-framework/processing/architecture.md) |
| p5.js | [README](per-framework/p5js/README.md) · [Architecture](per-framework/p5js/architecture.md) |
| OpenFrameworks | [README](per-framework/openframeworks/README.md) · [Architecture](per-framework/openframeworks/architecture.md) |
| Cinder | [README](per-framework/cinder/README.md) · [Architecture](per-framework/cinder/architecture.md) |
| openrndr | [README](per-framework/openrndr/README.md) · [Architecture](per-framework/openrndr/architecture.md) |
| nannou | [README](per-framework/nannou/README.md) · [Architecture](per-framework/nannou/architecture.md) |
| Cables | [README](per-framework/cables/README.md) · [Architecture](per-framework/cables/architecture.md) |
| tixl | [README](per-framework/tixl/README.md) · [Architecture](per-framework/tixl/architecture.md) |

## Related Theme Studies

Cross-cutting analyses that compare frameworks on specific topics:

| Theme | Document |
|-------|----------|
| Typography | [themes/typography.md](themes/typography.md) |
| Rendering Backends | [themes/rendering-backends.md](themes/rendering-backends.md) |
| Transform Stacks | [themes/transform-stacks.md](themes/transform-stacks.md) |
| Shader Abstractions | [themes/shader-abstractions.md](themes/shader-abstractions.md) |
| Event Systems | [themes/event-systems.md](themes/event-systems.md) |

---

## Key Takeaways

1. **Accessibility and power aren't opposites.** p5.js proves you can be beginner-friendly and capable. The key is progressive disclosure.

2. **State management is the hardest problem.** Every framework struggles with this. Push/pop stacks and explicit state are the best solutions.

3. **Composition is undervalued.** Shader composition, operator composition, scene composition. The frameworks that do this well scale better.

4. **Visual programming has lessons for code.** Even if you prefer code, the patterns in Cables and tixl (dataflow, dirty flags, dual execution models) apply broadly.

5. **Rust is well-positioned.** Ownership prevents memory leaks. Types prevent errors. The challenge is API ergonomics, not correctness.

---
