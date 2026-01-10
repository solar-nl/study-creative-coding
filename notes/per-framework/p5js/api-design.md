# p5.js API Design

> How do you design an API for people who have never programmed before?

## Key Insight

> **p5.js API's core idea:** Global functions with implicit state let beginners write `circle(100, 100, 50)` instead of managing objects, contexts, and method chains.

---

## The Problem: Programming is Hostile to Beginners

Imagine you want to draw a circle on screen. In a traditional graphics API, you might write something like this:

```javascript
const canvas = document.getElementById('canvas');  // Find the canvas element
const ctx = canvas.getContext('2d');               // Get the 2D drawing context
ctx.beginPath();                                   // Start a new path
ctx.arc(100, 100, 50, 0, Math.PI * 2);             // Define a full circle arc
ctx.fillStyle = 'rgb(255, 0, 0)';                  // Set fill color to red
ctx.fill();                                        // Actually draw the fill
```

That is six lines of code, three method calls on an object you had to retrieve, magic numbers (what is `Math.PI * 2`?), and a string format for colors. For someone who just wants to see a red circle, this is a wall of incidental complexity.

p5.js exists because creative coding should feel like sketching, not like enterprise software development. The entire API is designed around one question: what would make this *obvious* to someone who has never written code?

---

## The Philosophy: Accessibility Through Design

p5.js makes specific, opinionated choices that trade power for approachability. Understanding these choices reveals a coherent design philosophy.

### Flat Global Functions Instead of Objects

In p5.js, drawing a circle is:

```javascript
circle(100, 100, 50);
```

No canvas retrieval. No context. No method chaining. Just a function call that reads like an instruction: "circle at 100, 100, radius 50."

You might wonder why p5.js uses flat global functions instead of methods on objects. After all, object-oriented programming is considered good practice. Here's the reasoning:

**Objects introduce cognitive overhead.** When you write `ctx.arc()`, you need to understand:
- What is `ctx`?
- Where did it come from?
- Why do I call methods on it?
- What other methods does it have?

Global functions eliminate this. `circle()` is just `circle()`. It exists. It draws circles. That's all a beginner needs to know.

**The mental model is simpler.** Think of p5.js as a drawing robot that responds to voice commands. You say "circle" and it draws a circle. You don't need to understand the robot's internal structure. You just give commands.

This is the opposite of most API design advice. Experienced programmers prefer namespaced, composable APIs. But p5.js optimizes for the first hour of programming, not the first year.

### Instance Mode: The Escape Hatch

The global approach has limits. What if you want two sketches on one page? What if you're integrating p5 into a larger application?

p5.js provides an escape hatch called "instance mode":

```javascript
const sketch = function(p) {
  p.setup = function() {
    p.createCanvas(400, 400);
  };
  p.draw = function() {
    p.background(220);
    p.circle(200, 200, 50);
  };
};

new p5(sketch, 'container-id');
```

Now every function is prefixed with `p.` and the sketch is scoped to a container. This is closer to traditional object-oriented design. The key insight: p5.js provides both paths. Beginners get globals; advanced users can switch to instances when they need isolation.

---

## Overloaded Parameters: Many Paths to the Same Result

Consider the `color()` function. It accepts:

```javascript
color(128)                      // grayscale
color(128, 64)                  // grayscale with alpha
color(255, 0, 0)                // RGB
color(255, 0, 0, 128)           // RGBA
color('#ff0000')                // hex string
color('rgb(255, 0, 0)')         // CSS color string
color('red')                    // named color
```

A "cleaner" API might have separate functions: `colorGray()`, `colorRGB()`, `colorHex()`. But that increases the number of things a beginner must learn and remember.

p5.js takes a different approach: one function, many input formats. The library figures out what you meant. This is more work for the library authors, but it makes the API feel forgiving. You don't need to remember the "right" way to specify color. Just try something reasonable and it probably works.

The key insight is that overloading shifts cognitive burden from the user to the library. Users can think about *what* they want (a red color) rather than *how* to specify it correctly.

This pattern appears throughout p5.js:

```javascript
// image() accepts different argument counts
image(img, x, y);                          // draw at position
image(img, x, y, width, height);           // draw with size
image(img, dx, dy, dw, dh, sx, sy, sw, sh); // draw with source region
```

---

## Mode-Based State: Changing the Rules

Some p5.js functions change how other functions behave:

```javascript
colorMode(HSB);           // Now color(0, 100, 100) is red (hue, saturation, brightness)
rectMode(CENTER);         // Now rect(x, y, w, h) draws centered at x, y
angleMode(DEGREES);       // Now rotate(90) rotates 90 degrees, not 90 radians
```

Why does p5.js use modes instead of explicit parameters?

Consider the alternative. If `rect()` always needed to know its alignment mode:

```javascript
rect(x, y, w, h, CENTER);
rect(x, y, w, h, CORNER);
```

Every call becomes longer. You repeat yourself constantly. And worse, beginners must make a decision they don't yet understand: what's the difference between CENTER and CORNER mode?

Modes let p5.js provide sensible defaults while allowing customization. Most sketches never call `rectMode()`. They accept the default (CORNER) and draw rectangles without thinking about it. But when you need different behavior, you can change the mode once and every subsequent call respects it.

**The tradeoff is implicit state.** Looking at `rect(100, 100, 50, 50)` in isolation, you can't tell where it draws without knowing the current mode. This makes p5.js code harder to reason about in large programs. But for small sketches, the reduced verbosity is worth it.

---

## The Lifecycle: preload, setup, draw

p5.js structures every sketch around three special functions:

```javascript
function preload() {
  // Load assets here - p5 waits for completion
}

function setup() {
  // Run once at start
}

function draw() {
  // Run every frame (about 60 times per second)
}
```

You might wonder why p5.js uses this structure instead of letting users write imperative code. The answer is that animation and asset loading are hard problems, and p5.js wants to hide that complexity.

### The Preload Problem

Loading an image from disk takes time. In JavaScript, this is asynchronous:

```javascript
// Without preload - doesn't work as expected
let img;
function setup() {
  img = loadImage('photo.jpg');  // Starts loading, doesn't wait
  image(img, 0, 0);              // ERROR: img isn't ready yet!
}
```

The image starts loading but isn't available immediately. A traditional solution requires callbacks or promises, which are advanced JavaScript concepts:

```javascript
loadImage('photo.jpg', function(img) {
  // Now we can use img
});
```

p5.js solves this with `preload()`. Any loading function called in `preload()` is tracked. p5.js waits until all assets are ready, then calls `setup()`. The user never sees promises or callbacks:

```javascript
let img;
function preload() {
  img = loadImage('photo.jpg');  // p5 tracks this
}
function setup() {
  image(img, 0, 0);              // Works! p5 waited for us
}
```

This is clever engineering disguised as simplicity. The library does real work (tracking async operations, waiting for completion) so users can think synchronously.

### The Draw Loop Problem

Animation requires a loop that runs continuously. In raw JavaScript:

```javascript
function animate() {
  // Clear canvas
  ctx.clearRect(0, 0, width, height);

  // Draw frame
  // ...

  // Schedule next frame
  requestAnimationFrame(animate);
}
animate();  // Start the loop
```

This involves understanding `requestAnimationFrame`, setting up the loop, managing timing. p5.js abstracts this entirely:

```javascript
function draw() {
  background(220);  // Clear with gray
  circle(mouseX, mouseY, 50);  // Follow the mouse
}
```

The user writes what happens in one frame. p5.js handles the loop, timing, and frame scheduling. The `draw()` function just runs, about 60 times per second.

---

## The Callback Registration Pattern

Here's something subtle that confuses developers from other languages: how does p5.js find your `setup()` and `draw()` functions?

You define them as global functions:

```javascript
function setup() {
  createCanvas(400, 400);
}
```

Then p5.js somehow calls them at the right time. There's no explicit registration like `p5.registerSetup(myFunction)`. How does this work?

The mechanism is global scope inspection. When p5.js initializes, it does something like:

```javascript
// Inside p5.js (simplified)
_start() {
  // Check if user defined preload globally
  if (typeof preload === 'function') {
    this._isGlobal = true;
    this._preload = preload;
  }

  // Same for setup, draw, mousePressed, etc.
  if (typeof setup === 'function') {
    this._setup = setup;
  }
  if (typeof draw === 'function') {
    this._draw = draw;
  }

  // ...start the lifecycle
}
```

p5.js scans the global scope for functions with specific names. If they exist, it uses them. If not, it uses defaults (empty functions).

This approach is controversial among experienced developers. Global namespace pollution! Implicit behavior! But for beginners, the effect is magical: you write a function called `setup`, and it just runs. No boilerplate, no registration, no understanding of how libraries work.

The same pattern applies to event handlers:

```javascript
function mousePressed() {
  // This just works
  console.log('clicked at', mouseX, mouseY);
}

function keyPressed() {
  if (key === 'r') {
    background(255, 0, 0);
  }
}
```

Define a function with the right name, and p5.js calls it when the event happens. The documentation serves as the API contract: "name your function `mousePressed` and it will be called on mouse clicks."

---

## The Friendly Error System

The Friendly Error System (FES) is one of p5.js's most innovative features. It transforms cryptic JavaScript errors into helpful, specific guidance.

### The Problem with JavaScript Errors

When something goes wrong in JavaScript, you get messages like:

```
TypeError: Cannot read property 'width' of undefined
```

This tells you nothing about what you did wrong. Was it a typo? A wrong function call? A timing issue?

### FES in Action

With the Friendly Error System, p5.js catches errors before they propagate and provides context:

```
p5.js says: circle() was expecting Number for the third parameter (diameter),
but received String. (line 5)

Did you mean to use a number like 50 instead of "fifty"?
```

This error tells you:
- Which function had the problem (`circle()`)
- Which parameter was wrong (third, diameter)
- What type was expected (Number)
- What you passed (String)
- Where it happened (line 5)
- A suggestion for fixing it

### How It Works

FES validates parameters at runtime. Each p5.js function knows its expected signature:

```javascript
// Internal: circle expects (x: Number, y: Number, d: Number)
p5.prototype.circle = function(x, y, d) {
  // FES checks types before proceeding
  p5._validateParameters('circle', arguments);

  // Actual implementation
  return this._renderer.arc(x, y, d, d, 0, constants.TWO_PI, ...);
};
```

The validation function compares actual arguments against expected types. If there's a mismatch, it constructs a helpful message using function metadata.

### The Performance Tradeoff

Runtime validation isn't free. Checking every argument of every function call adds overhead. That's why FES can be disabled:

```javascript
p5.disableFriendlyErrors = true;  // For production
```

With FES disabled, p5.js skips validation and runs faster. But during development, the friendly messages are invaluable for beginners.

### Deep Insight: Errors as Teaching Tools

FES embodies a philosophy: errors are learning opportunities, not punishments. Every error message is written assuming the reader doesn't know what went wrong. This is unusual. Most software assumes users will understand technical error messages.

p5.js treats errors as part of the API. The error messages are designed as carefully as the functions themselves.

---

## Naming Conventions: Designed for Discovery

p5.js names are chosen for discoverability, not brevity or tradition.

### Functions: Verb-First Actions

```javascript
createCanvas(400, 400);   // Not canvas(400, 400) or newCanvas()
loadImage('photo.jpg');   // Not getImage() or fetchImage()
saveCanvas('output');     // Not exportCanvas() or downloadCanvas()
```

The verb comes first because it makes code read like instructions: "create a canvas," "load an image."

### State: Noun or Adjective Properties

```javascript
width              // Current canvas width
height             // Current canvas height
frameCount         // How many frames have drawn
mouseX, mouseY     // Mouse position
keyIsPressed       // Boolean: is any key down?
```

These are things you check, not actions you take. The naming reflects that: `frameCount` (a count), not `getFrameCount()` (an action to get a count).

### Constants: UPPER_SNAKE_CASE

```javascript
colorMode(RGB);     // Not colorMode("rgb") or colorMode(1)
textAlign(CENTER);  // Not textAlign("center")
blendMode(ADD);     // Not blendMode("add")
```

Constants are discoverable via autocomplete and stand out visually in code. They're safer than strings (typos are caught as reference errors) and more readable than numbers.

---

## What Would a Traditional API Look Like?

To appreciate p5.js's choices, consider how a more "traditional" graphics library might design the same features:

```javascript
// Traditional approach
const app = new GraphicsApp({
  canvas: document.getElementById('canvas'),
  width: 400,
  height: 400
});

const renderer = app.createRenderer();
const circle = new Circle({ x: 200, y: 200, radius: 50 });

circle.setFill(new Color(255, 0, 0));
circle.setStroke(new Color(0, 0, 0, 0));

renderer.add(circle);

app.onFrame(() => {
  renderer.render();
});

app.start();
```

This is "cleaner" by some definitions: explicit dependencies, no globals, clear object lifecycle. But it's also:

- More boilerplate before anything draws
- More concepts to understand (App, Renderer, Circle, Color)
- More ways to get it wrong (forgot to call `start()`, forgot to add circle to renderer)
- Less like "sketching" and more like "engineering"

p5.js makes the opposite choice: hide complexity, accept some messiness, optimize for immediate gratification.

---

## Tradeoffs: What p5.js Sacrifices

Every design choice has costs. p5.js's accessibility comes at a price.

### Global State Makes Testing Hard

Functions like `fill()` modify global state. To test that a function draws correctly, you'd need to inspect that state or mock it. There's no way to pass a renderer explicitly:

```javascript
// Can't do this in p5.js
function drawMyShape(renderer) {
  renderer.fill(255, 0, 0);
  renderer.circle(100, 100, 50);
}
```

Everything goes through the global p5 instance.

### Implicit Behavior Causes Confusion

The callback registration pattern is magical until it breaks. If your `setup()` function doesn't run, is it because:
- You misspelled it (`Setup()`, `setUp()`)?
- p5.js didn't load?
- You're in instance mode and forgot to attach it?

The implicitness that helps beginners can mystify intermediate users.

### Performance Overhead

Between FES validation, mode checking, and parameter overloading, p5.js does more work per function call than raw Canvas API. For most sketches this doesn't matter. For performance-critical applications, it can.

### Not Suitable for Large Codebases

The global function approach doesn't scale. A 10,000-line p5.js sketch would be unmaintainable. There's no module system, no encapsulation, no way to organize code beyond multiple files.

p5.js is optimized for sketches, not applications.

---

## Lessons for Rust API Design

Translating p5.js's philosophy to Rust requires adaptation. Some patterns transfer directly; others need Rust-specific alternatives.

### What Translates Well

**Overloaded parameters via traits and macros.** Rust can achieve similar flexibility:

```rust
// Multiple ways to specify color
fn fill(color: impl Into<Color>) { ... }

// Usage
fill(128);                    // u8 grayscale
fill((255, 0, 0));            // RGB tuple
fill(Color::rgb(255, 0, 0));  // Explicit type
fill("#ff0000");              // Hex string (with trait impl)
```

**Mode-based state via enums.** Rust's enums are perfect for modes:

```rust
pub enum ColorMode { RGB, HSB, HSL }
pub enum RectMode { Corner, Center, Corners }

fn set_color_mode(mode: ColorMode) { ... }
```

**The Friendly Error System via rich error types.** Rust can provide helpful errors at compile time:

```rust
// This fails to compile with a clear message
fn circle(x: f32, y: f32, diameter: f32) { ... }

circle(100.0, 100.0, "fifty");  // Error: expected f32, found &str
```

Runtime errors can use custom error types with context:

```rust
#[derive(Debug)]
pub enum SketchError {
    InvalidParameter { function: &'static str, expected: &'static str, got: String },
    AssetNotFound { path: PathBuf },
}
```

### What Requires Adaptation

**The preload pattern needs async/await.** Rust doesn't have implicit blocking:

```rust
// Option 1: Async setup
async fn setup() {
    let img = load_image("photo.jpg").await?;
}

// Option 2: Loading state
enum SketchState {
    Loading(LoadingContext),
    Running(RuntimeContext),
}
```

**Callback registration doesn't work the same way.** Rust doesn't have runtime global scope inspection. Use explicit registration or traits:

```rust
// Trait approach
trait Sketch {
    fn setup(&mut self, ctx: &mut Context);
    fn draw(&mut self, ctx: &mut Context);
    fn mouse_pressed(&mut self, _ctx: &mut Context) {} // Default empty
}

// User implements
struct MySketch { ... }
impl Sketch for MySketch {
    fn setup(&mut self, ctx: &mut Context) { ... }
    fn draw(&mut self, ctx: &mut Context) { ... }
}
```

**Global state is discouraged.** Rust's ownership system makes global mutable state awkward. Consider context-passing:

```rust
// Instead of global fill()
fn draw(&mut self, ctx: &mut Context) {
    ctx.fill(Color::RED);
    ctx.circle(100.0, 100.0, 50.0);
}
```

This is more verbose but makes state explicit and eliminates the testing problems.

### Immediate Mode and wgpu's Command Buffer Model

Here's where p5.js's design creates interesting challenges for GPU-based implementations. p5.js uses "immediate mode" drawing: you call `fill(255, 0, 0)` and then `circle(100, 100, 50)`, and the circle appears red. State changes apply to subsequent draw calls.

wgpu (and WebGPU, and modern GPUs generally) works differently. Drawing happens through command buffers: you record a sequence of operations, then submit the entire buffer to the GPU at once. Each draw call needs a complete pipeline state — shaders, blend modes, vertex layouts — bound before issuing the draw.

How would `fill()` followed by `circle()` map to this model?

```rust
// What the user writes (p5.js style)
fill(255, 0, 0);
circle(100, 100, 50);

// What must happen internally (wgpu style)
// 1. fill() stores the color in draw state
draw_state.fill_color = Color::rgb(255, 0, 0);

// 2. circle() generates geometry and issues a draw
let vertices = generate_circle_vertices(100.0, 100.0, 50.0);
let pipeline = get_or_create_pipeline(ShapeType::FilledCircle, &draw_state);

// 3. At frame end, batch and submit
render_pass.set_pipeline(&pipeline);
render_pass.set_bind_group(0, &bind_group_with_color, &[]);
render_pass.draw(0..vertex_count, 0..1);
```

The key insight: immediate mode is a *user-facing abstraction*. Under the hood, you're typically batching draw calls, managing pipeline state, and deferring actual GPU work until the frame ends. Libraries like nannou bridge this gap by collecting immediate mode commands and translating them to wgpu's retained mode at submission time.

This is why understanding p5.js's API model matters for Rust/wgpu implementations: you need to design an abstraction layer that feels immediate to users while being efficient for the GPU's command buffer model.

---

## Summary: Radical Accessibility Through Design

p5.js succeeds because every API decision serves one goal: make programming feel approachable. The flat global functions, overloaded parameters, lifecycle callbacks, mode-based state, and friendly errors all push in the same direction.

This is not "good API design" by conventional standards. It violates encapsulation, pollutes global scope, uses implicit state, and doesn't scale. But those standards assume experienced programmers. p5.js assumes the opposite: users who have never written code and might give up at the first wall of complexity.

For Rust creative coding libraries, the lesson isn't to copy p5.js directly. Rust has different constraints (ownership, no runtime reflection) and different users (typically more experienced with programming). But the *philosophy* transfers: understand your users' mental models, reduce cognitive load ruthlessly, and treat error messages as part of the interface.

The best API is one that feels obvious in retrospect.

---

## What's Next

This document focused on p5.js's *external* API — the interface users see. To understand how that interface is implemented:

- **[architecture.md](./architecture.md)** explains how p5.js organizes its code internally: the module structure, addon system, and how global mode gets wired up.
- **[rendering-pipeline.md](./rendering-pipeline.md)** traces what happens after you call `circle()` — how drawing commands become pixels on the Canvas 2D and WebGL backends.

If you're building a Rust creative coding library, the sequence matters: understand the user-facing API philosophy first (this document), then study how p5.js implements it internally, then consider how those patterns translate to Rust's ownership model and wgpu's command buffer architecture.

---

## Further Reading

- [architecture.md](./architecture.md) - How p5.js is organized internally
- [rendering-pipeline.md](./rendering-pipeline.md) - How drawing commands become pixels
- [p5.js Source: core/main.js](https://github.com/processing/p5.js/blob/main/src/core/main.js) - Lifecycle and global mode implementation
- [p5.js Friendly Error System documentation](https://github.com/processing/p5.js/blob/main/contributor_docs/friendly_error_system.md)
