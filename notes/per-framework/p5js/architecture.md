# p5.js Architecture

How do you build a framework that beginners can use in five minutes but experts can extend indefinitely?

---

## The Problem: Two Audiences, One Framework

p5.js faces a fundamental tension. On one hand, it exists for artists and beginners who want to see something on screen immediately, without understanding JavaScript classes, module systems, or browser APIs. On the other hand, it needs to support experienced developers who want custom shaders, complex state management, and integration with other libraries.

Most frameworks pick a side. Simple tools stay simple but hit walls. Powerful frameworks demand expertise. p5.js tries something harder: a layered architecture where beginners see simplicity but complexity hides beneath, accessible when you need it.

---

## The Mental Model: A Stage with Spotlight and Rigging

Think of p5.js like a theater stage. When you walk in as an audience member, you see the spotlight illuminating the actors. Everything looks simple and magical. But behind the curtain, there's an elaborate rigging system: pulleys, lights, sound boards, trapdoors.

p5.js works the same way:

- **The spotlight** is global mode, where `circle(100, 100, 50)` just works
- **The rigging** is the underlying class system, renderers, and extension points
- **The stage itself** is the p5 instance holding all the state

Beginners watch the show. Experts can climb into the rafters.

---

## The Sketch Context: What the p5 Class Actually Does

At the heart of everything is the `p5` class in `core/main.js`. You might wonder why there's a class at all when beginners never write `new p5()`. The answer reveals the architecture's elegance.

The p5 instance is your **sketch context**. It holds everything your sketch needs:

- **State**: `frameCount`, `mouseX`, `mouseY`, `width`, `height`
- **The renderer**: either a 2D canvas or WebGL context
- **Timing**: frame rate tracking, delta time, animation loop
- **User functions**: references to your `setup()` and `draw()`

When you call `circle(100, 100, 50)` in global mode, you're actually calling a method on this hidden p5 instance. The framework creates it automatically and binds all its methods to `window`, so `circle()` becomes `window.circle()` becomes `theHiddenP5Instance.circle()`.

The key insight is that p5 doesn't pollute the global namespace with static functions. It creates an object with state, then projects that object's methods outward. This matters because state needs to live somewhere, and having it in an instance means you could theoretically have multiple sketches.

---

## From Script Tag to Pixels: Tracing the Initialization

Let's trace exactly what happens when you include p5.js and write a sketch:

**Step 1: Script Loads**

When the browser loads `p5.js`, it executes immediately. This defines the `p5` class and attaches it to `window`, but doesn't create an instance yet.

**Step 2: DOMContentLoaded Fires**

p5.js registers a listener for `DOMContentLoaded`. When the page finishes loading, it checks: did the user define `setup()` or `draw()` functions on `window`?

**Step 3: Global Mode Detection**

If `window.setup` or `window.draw` exists, p5.js assumes global mode. It creates a new p5 instance automatically:

```javascript
// Simplified from core/main.js
if (window.setup || window.draw) {
  new p5();  // Global mode: auto-create instance
}
```

This auto-detection is why beginners never see `new p5()`. The framework infers intent from the presence of familiar function names.

**Step 4: Instance Creation**

The p5 constructor does several things:

1. Creates an internal renderer (2D by default)
2. Stores references to user functions (`this._setup = window.setup`)
3. Binds all prototype methods to `window` in global mode
4. Starts the lifecycle

**Step 5: Preload Phase**

If you defined `preload()`, it runs first. p5.js tracks async operations started here (like `loadImage()`) and waits for all of them to complete before moving on. This is why you don't need callbacks or promises for basic asset loading.

**Step 6: Setup Phase**

Once preload completes, `setup()` runs exactly once. This is where you typically call `createCanvas()`, which:

1. Creates an HTML canvas element
2. Instantiates the appropriate renderer (2D or WebGL)
3. Attaches the canvas to the DOM

**Step 7: Draw Loop**

Finally, p5.js starts the animation loop using `requestAnimationFrame`. Each frame:

1. Updates time tracking (`frameCount++`, `deltaTime` calculation)
2. Updates input state (`mouseX`, `mouseY`, key states)
3. Calls your `draw()` function
4. The renderer presents the frame

```
┌─────────────────────────────────────────────────────────────┐
│                   Initialization Flow                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  Script loads ─▶ DOMContentLoaded ─▶ Global mode check      │
│                                           │                 │
│                                           ▼                 │
│                                    new p5() instance        │
│                                           │                 │
│              ┌────────────────────────────┼────────────┐    │
│              ▼                            ▼            ▼    │
│         preload()              bind methods to      setup   │
│         (if defined)           window (global)      timing  │
│              │                                              │
│              ▼                                              │
│         setup() ──────────▶ createCanvas()                  │
│              │                    │                         │
│              │                    ▼                         │
│              │              Renderer created                │
│              ▼                                              │
│         draw loop ◀──── requestAnimationFrame               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Global Mode vs Instance Mode: Why Both Exist

p5.js offers two ways to write sketches. Understanding why reveals important architectural decisions.

### Global Mode: The Beginner Experience

```javascript
function setup() {
  createCanvas(400, 400);
}

function draw() {
  background(220);
  circle(mouseX, mouseY, 50);
}
```

Global mode is what tutorials teach. No classes, no `this`, no boilerplate. You define functions, and they run. The framework handles everything.

But global mode has a cost: it assumes one sketch per page. Every p5 function occupies a slot in `window`. If you tried to run two sketches, they'd fight over `setup`, `draw`, `mouseX`, and hundreds of other names.

### Instance Mode: The Expert Escape Hatch

```javascript
const sketch1 = new p5((p) => {
  p.setup = function() {
    p.createCanvas(200, 200);
  };
  p.draw = function() {
    p.background(255, 0, 0);
    p.circle(p.mouseX, p.mouseY, 30);
  };
});

const sketch2 = new p5((p) => {
  p.setup = function() {
    p.createCanvas(200, 200);
  };
  p.draw = function() {
    p.background(0, 0, 255);
    p.rect(p.mouseX, p.mouseY, 30, 30);
  };
});
```

Instance mode wraps everything in a function that receives the p5 instance as `p`. Now each sketch has isolated state. You can run multiple sketches on one page, embed sketches in larger applications, or integrate with frameworks like React.

The pattern is sometimes called "namespace injection" or "sketch closure." The framework passes itself to you rather than attaching to globals.

### The Design Trade-off

Why not just use instance mode everywhere? Because `p.circle(p.mouseX, p.mouseY, 50)` is uglier than `circle(mouseX, mouseY, 50)`. For beginners, that extra `p.` prefix obscures the creative intent. p5.js chooses friendliness by default and provides the escape hatch for those who need it.

---

## The Renderer Architecture

p5.js abstracts rendering through a class hierarchy:

```
p5.Renderer (base class)
    │
    ├── p5.Renderer2D
    │   └── Wraps Canvas 2D Context API
    │
    └── p5.RendererGL
        └── Wraps WebGL API
```

When you call `createCanvas(400, 400)`, you get a 2D renderer. Call `createCanvas(400, 400, WEBGL)`, and you get WebGL. The same drawing commands work with both, though WebGL offers additional 3D capabilities.

The key insight is that `circle()`, `rect()`, and other primitives are defined on `p5.prototype`, but they delegate to whatever renderer is active. The renderer holds the actual canvas context and knows how to translate p5's high-level commands into native API calls.

This abstraction is why p5.js can support both 2D and 3D with largely the same API. It's also where future renderers (WebGPU, perhaps) would plug in.

---

## How the API Grows: The Prototype Extension Pattern

p5.js is remarkably extensible. Want to add a new function that all sketches can use? Add it to the prototype.

Let's say you're building a particle system and want a convenient way to draw highlighted particles. You could add a custom function that any sketch can call:

```javascript
p5.prototype.myCustomFunction = function(x, y, size) {
  // 'this' is the p5 instance
  // Access the renderer via this._renderer
  this.push();
  this.fill(255, 0, 0);
  this.ellipse(x, y, size, size);
  this.pop();
};
```

Now every sketch can call `myCustomFunction(100, 100, 50)`.

This pattern is how p5.js itself is structured internally. The `color/`, `math/`, `image/`, and other directories all add methods to `p5.prototype`. The core doesn't know about all these features; it just provides the foundation, and modules extend it.

### Registering Preload Methods

Some extensions need async loading. p5.js provides a registration system:

```javascript
p5.prototype.loadMyCustomData = function(path, callback) {
  // Async loading logic
};

// Tell p5 this function participates in preload
p5.prototype.registerPreloadMethod('loadMyCustomData', p5.prototype);
```

Now when someone calls `loadMyCustomData()` inside `preload()`, p5.js automatically waits for it to complete before starting `setup()`.

---

## Module Organization

```
core/
├── main.js ─────────────── p5 class, lifecycle, global mode
├── constants.js ────────── PI, TWO_PI, HALF_PI, blend modes
├── environment.js ──────── display density, window dimensions
├── rendering.js ────────── createCanvas, background, clear
├── structure.js ────────── push, pop, loop, noLoop
├── transform.js ────────── translate, rotate, scale, shear
├── p5.Renderer.js ──────── base renderer interface
├── p5.Renderer2D.js ────── Canvas 2D implementation
├── p5.Element.js ───────── DOM element wrapper
├── p5.Graphics.js ──────── off-screen rendering buffers
└── shape/ ──────────────── primitives, curves, vertices

color/ ──────── p5.Color class, color modes, conversions
events/ ─────── mouse, keyboard, touch input handling
math/ ────────── p5.Vector, noise, random, trigonometry
image/ ──────── p5.Image, pixel manipulation, filters
io/ ──────────── file loading (JSON, images, tables, XML)
typography/ ─── p5.Font, text rendering
dom/ ─────────── HTML element creation and manipulation
webgl/ ──────── p5.RendererGL, shaders, 3D geometry
```

The organization mirrors the mental categories artists use: color, math, images, text. Each directory extends `p5.prototype` with its functions.

---

## wgpu Considerations

If you were building a similar architecture with Rust and wgpu, several patterns would translate while others would need rethinking.

### What Transfers Well

**The Renderer Abstraction**: The separation between high-level API and backend renderer maps cleanly. You'd define a `Renderer` trait with methods like `draw_circle()`, `draw_rect()`, etc. Different backends implement the trait:

```rust
trait Renderer {
    fn draw_circle(&mut self, x: f32, y: f32, diameter: f32);
    fn set_fill(&mut self, color: Color);
    fn push(&mut self);
    fn pop(&mut self);
}

struct WgpuRenderer {
    device: wgpu::Device,
    queue: wgpu::Queue,
    // ...
}

impl Renderer for WgpuRenderer {
    fn draw_circle(&mut self, x: f32, y: f32, diameter: f32) {
        // Tessellate circle into triangles
        // Add to current batch
    }
}
```

**State Stack**: The `push()`/`pop()` mechanism for saving and restoring transform state translates directly. In Rust, you'd maintain a `Vec<TransformState>` and push/pop matrix stacks.

**Asset Loading**: The preload pattern has parallels in Rust async. Instead of callback registration, you'd use `async fn load_image()` and `.await` in your setup phase.

### What Changes Significantly

**No Global Mode**: Rust doesn't have JavaScript's ability to inject methods into a global scope at runtime. Your API would always be explicit:

```rust
fn main() {
    let mut sketch = Sketch::new(400, 400);
    sketch.run(|p| {
        p.background(220);
        p.circle(p.mouse_x(), p.mouse_y(), 50.0);
    });
}
```

This is actually instance mode by default. The beginner-friendly global mode is a JavaScript-specific affordance that wouldn't make sense in Rust.

**Prototype Extension**: Rust uses traits, not prototype chains. Extensibility would come from either:

- Extension traits that add methods to your `Sketch` type
- A plugin system where modules register capabilities at startup
- Feature flags at compile time

**Renderer Backend**: wgpu requires explicit resource management that p5.js hides. Creating render pipelines, managing buffers, and batching draw calls all become your responsibility. The architecture would need explicit batching: collecting draw calls during `draw()`, then flushing them to the GPU in one go.

Here's a glimpse of what the render loop would look like with actual wgpu types:

```rust
fn flush_batched_draws(&mut self) {
    let mut encoder = self.device.create_command_encoder(&Default::default());

    {
        let mut render_pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Shape Batch Pass"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &self.frame_view,
                resolve_target: None,
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Load,  // Preserve background
                    store: wgpu::StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            ..Default::default()
        });

        render_pass.set_pipeline(&self.shape_pipeline);
        render_pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
        render_pass.draw(0..self.vertex_count, 0..1);
    }

    self.queue.submit(std::iter::once(encoder.finish()));
}
```

All that ceremony happens behind the scenes so the artist can simply write `p.circle(100, 100, 50)`.

### A Potential Rust Architecture

```
sketch-lib/
├── core/
│   ├── app.rs ─────────── Sketch struct, lifecycle management
│   ├── renderer.rs ────── Renderer trait definition
│   └── math.rs ────────── Vector types, transforms
│
├── backends/
│   ├── wgpu_renderer.rs ── wgpu implementation
│   └── software.rs ─────── CPU fallback for testing
│
├── extensions/
│   ├── color.rs ────────── Color types and conversions
│   ├── shape.rs ────────── 2D shape batching
│   └── image.rs ────────── Texture loading and drawing
```

The core insight from p5.js that survives the port: separate the artist-facing API from rendering mechanics. Let users think in terms of circles and colors, not vertices and pipelines.

---

## Questions Worth Exploring

- **Preload System**: How does p5.js track which async operations started in `preload()` and know when they're all complete?

- **Frame Timing**: What's the strategy for consistent frame pacing? How does `frameRate()` interact with `requestAnimationFrame`?

- **Off-screen Buffers**: How does `createGraphics()` create independent rendering contexts, and how do they compose back to the main canvas?

- **Event Dispatching**: How do mouse and keyboard events flow from the browser through to user-defined handlers like `mousePressed()`?

---

## Further Reading

- [p5.js source on GitHub](https://github.com/processing/p5.js) - start with `src/core/main.js`
- [Instance Mode documentation](https://github.com/processing/p5.js/wiki/Global-and-instance-mode)
- [Creating p5.js libraries](https://github.com/processing/p5.js/blob/main/contributor_docs/creating_libraries.md)

---

## Navigation

| Previous | Up | Next |
|----------|-----|------|
| [API Design](api-design.md) | [p5.js Overview](README.md) | [Rendering Pipeline](rendering-pipeline.md) |
