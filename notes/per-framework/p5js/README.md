# p5.js: A Sketchbook That Runs

> Processing's spiritual successor for the web, where accessibility is the architecture.

---

## Why Study p5.js?

Most creative coding frameworks optimize for power users. They assume you already understand coordinate systems, rendering pipelines, and state machines. p5.js asks a different question: *What if the framework bent over backwards to help beginners succeed?*

This makes p5.js a fascinating case study. Not because we want to copy its implementation, but because its design choices reveal something important: **the barrier to creative coding is rarely technical capability, it's cognitive load**. Every decision in p5.js trades some flexibility or performance for reduced mental overhead. Studying these trade-offs helps us understand what accessibility actually means in practice.

For a Rust framework, the lesson is not "do exactly what p5.js does." Rust's type system and compilation model are fundamentally different. The lesson is understanding *why* p5.js makes its choices, so we can achieve similar accessibility through Rust-appropriate means.

---

## The Philosophy: Training Wheels That Don't Slow You Down

Think of p5.js as a sketchbook that happens to run code. A physical sketchbook has no boilerplate. You open it, pick up a pencil, and draw. You don't configure the paper first, or instantiate a drawing context, or think about how marks get from your hand to the page. p5.js aims for that same immediacy in code.

This philosophy manifests in three core design choices, each trading something for cognitive simplicity:

**Global mode by default.** In most programming, you explicitly create objects and call their methods: `canvas.drawCircle(100, 100, 50)`. In p5.js, you just write `circle(100, 100, 50)`. The canvas exists. The drawing context exists. Functions are just *there*, bound to the global scope. This violates conventional wisdom about namespace pollution and encapsulation, but it means a beginner's first sketch is three lines, not thirty.

**Immediate-mode rendering.** When you call `circle()`, a circle appears. There's no scene graph to manage, no retained mode where objects persist between frames. This is less efficient than batched rendering, but it maps directly to how beginners think: "I want a circle here, so I tell it to draw a circle here." The mental model is a pencil, not a database.

**Friendly errors over silent failures.** Most graphics APIs fail silently or with cryptic messages. Call `circle()` with a string instead of a number, and p5.js doesn't just error. It tells you: "circle() was expecting Number for parameter 0, but got String." It suggests what you probably meant. This error system adds runtime overhead, but it transforms debugging from archaeology into conversation.

---

## How p5.js Makes This Work

The framework achieves its beginner-friendly API through clever architecture, not magic. Understanding this architecture reveals patterns worth studying.

### The Sketch Lifecycle

Every p5.js sketch follows a simple rhythm: prepare, initialize, repeat. The framework calls your functions at the right times:

```
preload() -> setup() -> draw() -> draw() -> draw() ...
```

You define these functions globally. p5.js finds them and orchestrates the timing. `preload()` runs first, handling async operations like loading images. Setup waits until everything is loaded. Then `draw()` runs every frame via `requestAnimationFrame`, giving you the animation loop without you having to think about it.

This lifecycle pattern solves a real problem: async resource loading breaks beginners. Without it, you'd write `loadImage()` in setup, and the image wouldn't exist yet when you try to use it. p5.js handles the complexity so you don't have to.

### The Renderer Abstraction

Under the hood, p5.js maintains a clean separation between the API you use and the rendering backend. When you call `circle()`, the method delegates to `this._renderer.ellipse()`. That renderer might be `p5.Renderer2D` (wrapping the Canvas 2D API) or `p5.RendererGL` (wrapping WebGL).

Let's trace exactly what happens when you call `circle(100, 100, 50)`:

1. The global `circle` function (bound in global mode) calls `p5.prototype.circle()`
2. `circle()` calls `this.ellipse(100, 100, 50, 50)` since a circle is just an equal-sided ellipse
3. `ellipse()` applies any active transforms (translate, rotate, scale)
4. `ellipse()` calls `this._renderer.ellipse()` to delegate to the backend
5. `p5.Renderer2D.ellipse()` translates this into Canvas 2D calls: `beginPath()`, `arc()`, `fill()`, `stroke()`
6. The browser's Canvas 2D implementation rasterizes the shape to pixels

This separation is why switching from 2D to 3D rendering requires only changing a single parameter in `createCanvas()`. Your drawing code largely stays the same. For framework design, it's a good example of how to provide multiple backends without exposing that complexity to users.

### The Friendly Error System

The error system deserves particular attention because it represents a design choice many frameworks dismiss as too expensive. p5.js validates parameters at runtime, checking types and ranges. When validation fails, it constructs helpful messages that explain *what went wrong* and *what you probably meant*.

Here's the difference in practice. In most graphics frameworks, you might see:

```
TypeError: Cannot read property 'x' of undefined
```

In p5.js, you get something like:

```
p5.js says: circle() was expecting Number for the first parameter,
received String instead. [Reference: https://p5js.org/reference/#/p5/circle]
```

The message names the function, identifies the parameter, explains the type mismatch, and links to documentation. This transforms "what broke?" into "here's what to fix."

You can disable this system with `p5.disableFriendlyErrors = true` for production, but it's on by default because the developers decided beginner experience matters more than raw performance. For a Rust framework, we'd achieve similar helpfulness differently, using the type system at compile time rather than runtime validation. But the goal is the same: errors that teach rather than confuse.

---

## Repository Structure at a Glance

The source code reflects the modular nature of the API:

```
src/
├── core/               # The foundation everything else builds on
│   ├── main.js         # The p5 constructor and lifecycle management
│   ├── rendering.js    # Canvas creation and the render loop
│   ├── p5.Renderer.js  # Base class for rendering backends
│   ├── p5.Renderer2D.js # The 2D canvas implementation
│   └── shape/          # Drawing primitives (circle, rect, etc.)
├── color/              # Color parsing, conversion, and modes
├── math/               # Vectors, noise, random functions
├── events/             # Mouse, keyboard, touch handling
├── image/              # Image loading and manipulation
├── io/                 # File loading and data parsing
├── typography/         # Text and font rendering
├── dom/                # HTML element creation and manipulation
└── webgl/              # The 3D rendering backend
```

**How data flows through this structure:** When you call `circle(100, 100, 50)`, the call starts in `core/main.js` (where the global function is bound), routes through `core/shape/2d_primitives.js` (where the API is defined), and lands in `core/p5.Renderer2D.js` (where the actual Canvas 2D `arc()` call happens). The `color/` and `math/` modules provide utilities that get called along the way for stroke colors and coordinate transforms.

To understand the framework, start with `src/core/main.js`. This is where the p5 class is defined, where the lifecycle is orchestrated, and where global mode binds functions to the window object. From there, `src/core/rendering.js` shows how canvases are created and managed, while `src/core/p5.Renderer2D.js` reveals how drawing commands become pixels.

---

## What Can Rust Learn From This?

p5.js makes certain trade-offs that don't translate directly to Rust: global mutable state, dynamic typing, runtime validation. But the *goals* behind these choices translate perfectly:

**Minimal boilerplate.** A beginner's first program should be short. In Rust, this might mean smart defaults, builder patterns, or macros that expand simple code into complex initialization. Imagine something like:

```rust
// A hypothetical Rust creative coding framework
use sketch::prelude::*;

fn main() {
    sketch::run(|ctx| {
        ctx.background(220);
        ctx.circle(100.0, 100.0, 50.0);
    });
}
```

Compare this to raw [wgpu](https://github.com/gfx-rs/wgpu), which requires 50+ lines just to create a surface and render pass. The framework handles device creation, swap chain configuration, and render loop timing, letting the user focus on the creative work.

**Progressive disclosure.** p5.js lets you use global mode until you need instance mode. A Rust framework could similarly offer simple high-level APIs that expand into more control when needed, perhaps through configuration structs with sensible defaults.

**Errors that educate.** Rust's type system catches many errors at compile time, which is better than runtime validation. But compiler error messages can still be cryptic. Investing in clear error messages and documentation pays dividends in accessibility.

**Lifecycle management.** The preload/setup/draw pattern handles complexity for the user. A Rust framework could similarly manage async resource loading and frame timing automatically.

The deeper lesson is philosophical: accessibility isn't an afterthought or a compromise. p5.js proves that a framework designed around beginner experience can still be capable enough for sophisticated work. It's a sketchbook that scales into a studio.

---

## Where to Go Next

This document provides the philosophical overview. For deeper exploration:

- [Architecture](./architecture.md) - The module structure and how pieces connect
- [Rendering Pipeline](./rendering-pipeline.md) - How drawing commands become pixels
- [API Design](./api-design.md) - Naming conventions, overloading, and patterns

---

| Property | Value |
|----------|-------|
| **Language** | JavaScript |
| **License** | LGPL-2.1 |
| **First Release** | 2014 |
| **Repository** | [processing/p5.js](https://github.com/processing/p5.js) |
| **Documentation** | [p5js.org/reference](https://p5js.org/reference/) |
