# The p5.js Rendering Pipeline

> Every frame, p5.js executes your drawing commands and immediately forgets them. Understanding this "stateless" approach is key to understanding both its simplicity and its limitations.

---

## The Problem: How Do You Make Drawing Code Simple?

Imagine you're designing a creative coding framework. Your users are artists, students, and hobbyists who want to see circles appear on screen without learning graphics programming theory. What's the simplest mental model you can give them?

One approach: build a scene graph. Users create objects (`Circle`, `Rectangle`), add them to a scene, and the system renders the scene. This is **retained mode** rendering. It's powerful -- you can query objects, animate them, remove them later. Libraries like Three.js, PixiJS, and most game engines work this way.

But there's a cost. Users must understand object creation, scene hierarchies, and state management. "I just want a circle" becomes "create a circle object, configure it, add it to the scene, remember to update it if you want it to move."

p5.js takes the opposite path: **immediate mode** rendering. You call `circle(100, 100, 50)`, and a circle appears. Right now. No objects to manage, no scene to maintain. The command executes, pixels change, and the system forgets everything about that circle.

Think of it like the difference between arranging furniture in a room versus painting a picture. With furniture (retained mode), each piece exists as an object you can move around later. With paint (immediate mode), each brushstroke becomes part of the canvas immediately -- there's no "undo stroke" beyond painting over it.

---

## The Mental Model: A Painter Working on a Canvas

Here's how to think about p5.js rendering:

1. **The canvas is a bitmap** -- a grid of pixels that accumulates paint
2. **Drawing commands are brushstrokes** -- they modify pixels and are immediately forgotten
3. **Each frame starts with what was there before** -- unless you explicitly clear it
4. **State (color, transform) is like holding a brush** -- it affects all strokes until you change it

This model explains several p5.js behaviors that initially seem surprising:

- **Why does animation leave trails?** Because each frame draws on top of the previous one. You need `background()` to clear it.
- **Why can't I query "what circles are on screen"?** Because the circles don't exist as objects -- only pixels.
- **Why does order matter so much?** Because later draws paint over earlier ones, and transforms accumulate.

---

## Tracing a Drawing Call: From `circle()` to Pixels

Let's trace exactly what happens when you write `circle(100, 100, 50)`. This reveals the architecture:

```
User code: circle(100, 100, 50)
                │
                ▼
┌─────────────────────────────────────────────────────┐
│ p5.prototype.circle() in core/shape/2d_primitives.js│
│ - Validates arguments (Friendly Error System)       │
│ - Converts circle to ellipse parameters             │
│ - Delegates to renderer                             │
└─────────────────────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────┐
│ this._renderer.ellipse()                            │
│ - _renderer is either Renderer2D or RendererGL     │
│ - This indirection enables both backends            │
└─────────────────────────────────────────────────────┘
                │
        ┌───────┴───────┐
        ▼               ▼
┌─────────────┐   ┌─────────────┐
│ Renderer2D  │   │ RendererGL  │
│ (Canvas API)│   │ (WebGL API) │
└─────────────┘   └─────────────┘
        │               │
        ▼               ▼
┌─────────────┐   ┌─────────────────────────────┐
│ ctx.arc()   │   │ Build geometry buffers      │
│ ctx.fill()  │   │ Set uniforms (color, matrix)│
│ ctx.stroke()│   │ Issue draw call             │
└─────────────┘   └─────────────────────────────┘
        │               │
        └───────┬───────┘
                ▼
┌─────────────────────────────────────────────────────┐
│ Browser composites canvas to screen                 │
│ (Happens at display refresh, not per draw call)    │
└─────────────────────────────────────────────────────┘
```

The key insight here is the **renderer abstraction**. User code calls high-level functions like `circle()`, which delegate to a renderer. The renderer translates those calls to actual graphics API commands. This lets p5.js support both Canvas 2D and WebGL through the same user-facing API.

---

## The Renderer Abstraction: Why Two Backends?

p5.js supports two rendering backends, selected when you call `createCanvas()`:

```javascript
createCanvas(400, 400);           // 2D Canvas API (default)
createCanvas(400, 400, WEBGL);    // WebGL API
```

You might wonder why both exist. The answer lies in different trade-offs:

### Canvas 2D Renderer (`p5.Renderer2D`)

The 2D renderer wraps the browser's `CanvasRenderingContext2D`. It's essentially a thin pass-through:

- `circle()` becomes `ctx.arc()` + `ctx.fill()`
- `rect()` becomes `ctx.fillRect()` + `ctx.strokeRect()`
- Transforms use `ctx.translate()`, `ctx.rotate()`, `ctx.scale()`
- State uses `ctx.save()` / `ctx.restore()`

**Strengths:**
- Simple, predictable behavior
- Excellent browser support
- Good for 2D drawings, text, images
- Pixel-perfect rendering

**Weaknesses:**
- No GPU acceleration for complex scenes
- Each draw call is immediate (no batching)
- No 3D support
- Performance degrades with many objects

### WebGL Renderer (`p5.RendererGL`)

The WebGL renderer is fundamentally different. It maintains a GPU state machine and must manage:

- Shader compilation and linking
- Geometry buffer creation
- Texture uploads and binding
- Uniform updates
- Matrix stacks (no built-in transforms in WebGL)
- Depth testing and blending

**Strengths:**
- GPU acceleration
- 3D rendering with perspective/lighting
- Custom shaders
- Can batch some operations

**Weaknesses:**
- More complex mental model
- Some 2D operations behave differently
- Higher setup cost
- Browser/driver inconsistencies

The renderer abstraction insulates users from these differences. You write `circle()`, and it works in both modes -- the implementation details are hidden behind the interface.

---

## The Frame Loop: Timing and Animation

p5.js runs a continuous draw loop powered by `requestAnimationFrame`. Here's the conceptual flow:

```javascript
// Simplified from core/main.js
// (The actual implementation includes additional complexity for handling
// different loop modes and error handling)
_draw() {
  const now = performance.now();

  // Track timing for frameRate() and deltaTime
  this._frameRate = 1000 / (now - this._lastFrameTime);
  this.deltaTime = now - this._lastFrameTime;
  this._lastFrameTime = now;

  // Increment frame counter
  this.frameCount++;

  // Call user's draw function (where your code runs)
  this._userDraw();

  // Schedule next frame (if looping)
  if (this._loop) {
    requestAnimationFrame(this._draw.bind(this));
  }
}
```

Several things happen that aren't obvious:

1. **No automatic clearing.** The canvas retains its pixels between frames. You must call `background()` if you want a fresh slate.

2. **`requestAnimationFrame` timing.** The browser aims for 60fps but adapts to display refresh rate. Your `draw()` function runs once per frame.

3. **`noLoop()` stops the cycle.** For static sketches, call `noLoop()` to stop continuous rendering. Use `redraw()` to trigger manual updates.

4. **`frameRate()` throttles, doesn't accelerate.** You can limit to 30fps, but you can't force 120fps on a 60Hz display.

This frame loop model matches how animation traditionally works: redraw everything each frame, like a flipbook. It's simple but has implications for performance -- you're redrawing even unchanged content.

---

## State Management: The Hidden Complexity

Immediate mode seems simple until you realize there's hidden state everywhere. Every draw call is affected by:

- Current fill color
- Current stroke color and weight
- Current transform matrix (position, rotation, scale)
- Blend mode
- Text properties (font, size, alignment)
- Tint (for images)
- Clipping masks

This state is **global to the renderer**. When you write:

```javascript
fill(255, 0, 0);
circle(100, 100, 50);  // Red circle
circle(200, 100, 50);  // Also red -- state persists!
```

The fill color affects all subsequent draws until changed. This is convenient for consistency but creates problems when you want isolated changes.

### Push and Pop: Creating State Isolation

The `push()` and `pop()` functions create a state stack:

```javascript
fill(255, 0, 0);
circle(100, 100, 50);  // Red

push();                // Save current state
  fill(0, 0, 255);
  translate(200, 0);
  circle(0, 100, 50);  // Blue, translated
pop();                 // Restore saved state

circle(300, 100, 50);  // Back to red, no translation
```

Think of `push()` like taking a snapshot of your current brush and position. `pop()` returns to that snapshot, discarding any changes made inside the block.

Under the hood, this maps directly to the Canvas 2D API:

```javascript
// p5.Renderer2D
push() {
  this.drawingContext.save();    // Built-in canvas state save
  // Plus: save additional p5-specific state
}

pop() {
  this.drawingContext.restore(); // Built-in canvas state restore
  // Plus: restore p5-specific state
}
```

In WebGL mode, there's no equivalent built-in, so `p5.RendererGL` maintains manual stacks for matrices and style properties.

**The cost:** `push()`/`pop()` aren't free. In 2D mode, the browser must copy state. In WebGL mode, p5.js must copy objects. For performance-critical code with many state changes, consider restructuring to minimize push/pop calls.

---

## Immediate Mode vs. Retained Mode: What You Gain and Lose

Let's compare p5.js with retained-mode frameworks to understand the trade-offs:

| Aspect | p5.js (Immediate) | Three.js/PixiJS (Retained) |
|--------|-------------------|----------------------------|
| **Mental Model** | "Draw commands paint pixels" | "Scene is a tree of objects" |
| **Object Persistence** | None -- drawing is forgotten | Objects exist, can be queried |
| **Animation** | Redraw everything each frame | Update object properties |
| **Hit Testing** | Manual (check coordinates) | Built-in (scene graph queries) |
| **Memory** | Low (no object storage) | Higher (scene graph overhead) |
| **Complexity** | Simple API, simple concepts | More concepts to learn |
| **Optimization** | Limited (you control everything) | Automatic batching, culling |

### What p5.js Gains

**Simplicity.** The entire API is a set of functions with no class hierarchies to understand. New users can be productive in minutes.

**Transparency.** There's no hidden optimization that might reorder your draws. What you write is what happens.

**Flexibility.** You can draw anything anywhere without fitting it into a scene graph structure.

**Low overhead.** No object allocation for simple drawings.

### What p5.js Loses

**No scene management.** Want to know if the mouse is over a shape? You must track that yourself. Want to remove a circle? You can't -- you just don't draw it next frame.

**Limited optimization.** Each draw call typically executes immediately. Retained-mode systems can batch similar draws, cull off-screen objects, and cache geometry.

**Redundant redrawing.** In a retained system, you update the moving object; the system handles redrawing. In immediate mode, you redraw everything every frame, even static elements.

**No temporal coherence.** The system can't optimize based on what changed since last frame because it has no memory of what was drawn.

---

## Rust/wgpu Considerations

If you're implementing an immediate-mode renderer in Rust with wgpu, here are the key mapping considerations:

### The Renderer Abstraction in Rust

Where p5.js has a class hierarchy (`p5.Renderer` -> `p5.Renderer2D`), Rust would use traits:

```rust
// The equivalent of p5.Renderer as an interface
trait Renderer {
    fn circle(&mut self, x: f32, y: f32, diameter: f32);
    fn rect(&mut self, x: f32, y: f32, w: f32, h: f32);
    fn push(&mut self);
    fn pop(&mut self);
    // ... other drawing operations
}

// State that all renderers share
struct RenderState {
    fill_color: [f32; 4],
    stroke_color: [f32; 4],
    stroke_weight: f32,
    transform: glam::Mat4,
}

// A state stack for push/pop
struct StateStack {
    stack: Vec<RenderState>,
    current: RenderState,
}
```

### Immediate Mode in a Deferred-Rendering World

Here's where it gets interesting. wgpu (and GPU APIs in general) aren't truly immediate -- they buffer commands that execute later. To implement immediate-mode semantics:

**Option 1: True immediate submission**
```rust
// Build and submit a render pass for each draw call
// Very inefficient but matches p5.js semantics exactly
fn circle(&mut self, x: f32, y: f32, d: f32) {
    let vertices = self.tessellate_circle(x, y, d);
    let buffer = self.device.create_buffer_init(&vertices);

    let mut encoder = self.device.create_command_encoder();
    {
        let mut pass = encoder.begin_render_pass(&self.pass_desc);
        pass.set_pipeline(&self.circle_pipeline);
        pass.draw(0..vertices.len(), 0..1);
    }
    self.queue.submit([encoder.finish()]);
}
```

This is catastrophically slow. Each draw is a full GPU submit.

**Option 2: Frame batching (recommended)**
```rust
// Accumulate draws during the frame, submit once at end
struct ImmediateBatch {
    vertices: Vec<Vertex>,
    draw_calls: Vec<DrawCall>,
}

impl Renderer for WgpuRenderer {
    fn circle(&mut self, x: f32, y: f32, d: f32) {
        // Tessellate and add to batch
        let start = self.batch.vertices.len();
        self.tessellate_circle_into(&mut self.batch.vertices, x, y, d);
        let end = self.batch.vertices.len();

        self.batch.draw_calls.push(DrawCall {
            range: start..end,
            state: self.state_stack.current.clone(),
        });
    }

    fn end_frame(&mut self) {
        // Upload all vertices once
        // Issue all draws in a single render pass
        // This is where the actual GPU work happens
    }
}
```

This gives immediate-mode semantics (draws happen in order, state changes respected) with reasonable performance.

### The State Stack in wgpu

wgpu has no concept of transform matrices or fill colors -- those are entirely your responsibility. You'll need:

```rust
struct WgpuRenderer {
    state_stack: StateStack,

    // Pipeline variations for different blend modes
    pipelines: HashMap<BlendMode, wgpu::RenderPipeline>,

    // Uniform buffer for transform matrix + colors
    uniform_buffer: wgpu::Buffer,
    bind_group: wgpu::BindGroup,
}

impl WgpuRenderer {
    fn push(&mut self) {
        self.state_stack.push();
    }

    fn pop(&mut self) {
        self.state_stack.pop();
        // Note: unlike Canvas 2D, we don't update GPU state here
        // The state will be applied when the next draw uses it
    }

    fn translate(&mut self, x: f32, y: f32) {
        self.state_stack.current.transform *=
            glam::Mat4::from_translation(glam::vec3(x, y, 0.0));
    }
}
```

### Shape Tessellation

The Canvas 2D API has built-in primitives (`arc()`, `bezierCurveTo()`). In wgpu, you draw triangles. Every shape must be tessellated:

```rust
fn tessellate_circle(&self, x: f32, y: f32, diameter: f32) -> Vec<Vertex> {
    let r = diameter / 2.0;
    let segments = self.calculate_segments_for_radius(r);
    let mut vertices = Vec::with_capacity(segments * 3);

    // TAU = 2π, available in std::f32::consts::TAU
    for i in 0..segments {
        let angle0 = (i as f32 / segments as f32) * TAU;
        let angle1 = ((i + 1) as f32 / segments as f32) * TAU;

        // Triangle fan from center
        vertices.push(Vertex { pos: [x, y], color: self.fill_color });
        vertices.push(Vertex {
            pos: [x + r * angle0.cos(), y + r * angle0.sin()],
            color: self.fill_color
        });
        vertices.push(Vertex {
            pos: [x + r * angle1.cos(), y + r * angle1.sin()],
            color: self.fill_color
        });
    }

    vertices
}
```

Consider using a tessellation library like `lyon` for complex paths.

---

## Performance Patterns and Gotchas

### The Redraw Everything Problem

Every frame, p5.js redraws everything. For complex scenes, this becomes a bottleneck. Strategies:

1. **Layered canvases.** Use `createGraphics()` for static backgrounds. Draw the background once, copy it each frame.

```javascript
let bg;

function setup() {
  createCanvas(800, 600);
  bg = createGraphics(800, 600);
  drawComplexBackground(bg);  // Once
}

function draw() {
  image(bg, 0, 0);  // Copy static layer (fast)
  drawAnimatedContent();       // Only moving parts
}
```

2. **`noLoop()` for static sketches.** If nothing moves, don't loop.

3. **Throttle animations.** Use `frameRate(30)` if 60fps isn't needed.

### The State Change Problem

Each style change can trigger GPU state changes. Batching by style improves performance:

```javascript
// Slow: alternating styles
for (let obj of objects) {
  fill(obj.color);
  circle(obj.x, obj.y, obj.size);
}

// Faster: batch by style
let byColor = groupBy(objects, 'color');
for (let [color, group] of byColor) {
  fill(color);
  for (let obj of group) {
    circle(obj.x, obj.y, obj.size);
  }
}
```

### Pixel Density (Retina) Handling

p5.js automatically handles high-DPI displays:

```javascript
pixelDensity(2);  // Force 2x rendering
pixelDensity(1);  // Force 1x (lower quality, better performance)
```

The canvas is actually larger than the CSS dimensions. `width` and `height` give you CSS pixels; internally the canvas may have more actual pixels. This affects `loadPixels()` operations.

---

## Related Documents

- [Architecture](./architecture.md) -- Module structure and initialization flow
- [API Design](./api-design.md) -- How the friendly API is constructed

---

## Summary

p5.js implements **immediate-mode rendering**: draw calls execute immediately against a canvas, with no persistent scene graph. This approach prioritizes simplicity over optimization.

The key concepts:
- **Renderer abstraction** enables both Canvas 2D and WebGL backends
- **Frame loop** uses `requestAnimationFrame`, calling `draw()` continuously
- **State is implicit** -- colors and transforms affect subsequent draws
- **`push()`/`pop()`** create isolated state contexts
- **No object persistence** -- you can't query what's drawn, only draw again

For Rust/wgpu implementations, the main challenge is mapping immediate-mode semantics onto a command-buffer architecture. Frame batching provides a practical middle ground: accumulate draws, submit once.

The trade-off is clear: p5.js sacrifices scene management and optimization potential for an API that lets beginners draw circles in one line of code. For creative coding education, that's often the right trade.
