# PixiJS Graphics API

> A Canvas-like drawing API that records your artistic intent before translating it into GPU-renderable geometry

---

## The Problem: Drawing Shapes on a GPU

Imagine you want to draw a simple red circle. On a 2D canvas, this is trivial: call `arc()`, call `fill()`, done. The CPU draws pixels directly to a bitmap. But GPUs do not understand circles. They understand triangles.

This creates a fundamental mismatch. Artists think in shapes, curves, and strokes. GPUs think in vertices, triangles, and textures. Something has to bridge the gap.

The naive solution would be to tessellate (convert curves to triangles) every single time you call a drawing method. Draw a circle? Immediately generate 50 triangles. Draw another circle? Generate 50 more. This is wasteful. If the circle has not changed, why regenerate the geometry?

PixiJS solves this with a two-phase approach: **record first, tessellate later**. Think of it like an architect creating drawings. The architect sketches circles, rectangles, and curves on paper. These drawings do not become a building directly. Instead, they get converted into construction blueprints when it is time to build. If the architect makes ten copies of the same house, they do not redraw the blueprints ten times.

---

## The Mental Model: Drawings Become Blueprints

The Graphics API works like a recipe that gets "compiled" into cooking steps:

1. **You write the recipe** (drawing commands): "Draw a circle at position 100,100 with radius 50, fill it red"
2. **The recipe is stored** as instructions, not executed immediately
3. **When you cook** (render), the instructions are tessellated into triangles
4. **The triangles are cached** so the next time you serve the dish, you skip the prep work

This deferred execution model has three layers:

```
┌─────────────────────────────────────────────────────────────────┐
│  Graphics                                                        │
│  The scene object - position, rotation, scale                   │
│  Think: "A canvas element on your page"                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ references
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  GraphicsContext                                                 │
│  The drawing instructions - what shapes, what colors            │
│  Think: "The actual drawing, independent of where it appears"   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              │ tessellates to
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│  GraphicsPipe + Adaptor                                          │
│  GPU geometry and rendering commands                            │
│  Think: "The construction blueprints the GPU can execute"       │
└─────────────────────────────────────────────────────────────────┘
```

---

## Why Separate Graphics from GraphicsContext?

Here is where it gets interesting. PixiJS deliberately separates the "scene object" (Graphics) from the "drawing content" (GraphicsContext). Why the split?

Consider a particle system with 1000 identical stars. Each star is at a different position, but they all look the same. Without sharing, you would tessellate the star shape 1000 times, upload 1000 copies of identical vertex data to the GPU, and waste megabytes of memory.

With context sharing, you tessellate once and reference that data 1000 times:

```typescript
// The drawing instructions - expensive to create
const starContext = new GraphicsContext()
    .star(0, 0, 5, 40, 20)  // 5-pointed star at origin
    .fill({ color: 0xffff00 });

// The scene objects - cheap to create
for (let i = 0; i < 1000; i++) {
    const star = new Graphics({ context: starContext });
    star.x = Math.random() * 800;
    star.y = Math.random() * 600;
    container.addChild(star);
}
```

This mirrors the Texture/Sprite relationship you might know from sprite-based games. One image, many instances. One set of drawing instructions, many transforms.

The key insight: **GraphicsContext is expensive (tessellation, GPU upload). Graphics is cheap (just a transform and a reference).**

---

## Recording Instructions: The Fluent API

The drawing API feels like Canvas 2D, but remember: nothing renders immediately. You are writing a recipe.

```typescript
const graphics = new Graphics();

graphics
    // Build a path
    .moveTo(50, 50)
    .lineTo(100, 50)
    .bezierCurveTo(150, 50, 150, 100, 100, 100)
    .closePath()
    .fill({ color: 0xff0000 })

    // Or use shorthand primitives
    .rect(200, 50, 100, 80)
    .circle(350, 90, 40)
    .ellipse(450, 90, 50, 40)
    .fill({ color: 0x00ff00 })

    // Even complex shapes
    .regularPoly(650, 90, 40, 6)    // Hexagon
    .star(750, 90, 5, 40, 20)       // 5-pointed star
    .fill({ color: 0x0000ff });
```

Each call records an instruction. When you call `.fill()`, the system packages up the current path with the fill style:

```typescript
interface FillInstruction {
    action: 'fill';
    data: {
        style: ConvertedFillStyle;  // Color, texture, gradient
        path: GraphicsPath;          // The shape to fill
        hole?: GraphicsPath;         // Optional cutout
    };
}
```

There are three instruction types:
- **Fill**: Solid shapes (circles, rectangles, complex paths)
- **Stroke**: Outlines with width, caps, and joins
- **Texture**: Embedded images with transforms

---

## The Transform Stack: Context Switching

Like Canvas 2D, GraphicsContext maintains a transform stack. This lets you compose complex drawings without manually calculating coordinates:

```typescript
graphics
    .save()                    // Push current state
    .translate(100, 100)       // Move origin
    .rotate(Math.PI / 4)       // Rotate 45 degrees
    .circle(0, 0, 50)          // Draw at "local" origin
    .fill({ color: 0xff0000 })
    .restore();                // Pop back to original state
```

The key detail: **coordinates are transformed before being stored**. When you call `lineTo(x, y)`, the context applies its current transform matrix and records the transformed point:

```typescript
lineTo(x: number, y: number): this {
    const t = this._transform;

    // Store transformed coordinates, not originals
    this._activePath.lineTo(
        (t.a * x) + (t.c * y) + t.tx,
        (t.b * x) + (t.d * y) + t.ty
    );

    return this;
}
```

This means the stored path is already in final coordinates. No transform matrices need to be applied during tessellation.

---

## Creating Holes: The Cut Operation

You might wonder: how do you draw a donut shape? A circle with a smaller circle removed from the center?

The `cut()` method solves this. It takes whatever path you just defined and punches it out of the previous fill:

```typescript
graphics
    .circle(100, 100, 50)   // Outer circle
    .fill({ color: 0xff0000 })
    .circle(100, 100, 25)   // Inner circle
    .cut();                  // Subtract from the fill above
```

The implementation is elegant: `cut()` does not create a new instruction. It modifies the previous fill instruction by attaching a hole path:

```typescript
cut(): this {
    const lastInstruction = this.instructions[this.instructions.length - 1];
    const holePath = this._activePath.clone();

    if (lastInstruction?.action === 'fill') {
        lastInstruction.data.hole = holePath;  // Attach hole to fill
    }

    return this;
}
```

The tessellator knows how to handle fills with holes - it generates triangles for the outer shape that exclude the inner region.

---

## From Instructions to Triangles: The Rendering Pipeline

Let's trace what happens when the renderer encounters a Graphics object. The journey from `graphics.circle()` to actual pixels follows these steps:

1. **Recording**: Your drawing commands become instruction objects stored in an array
2. **Tessellation**: The GraphicsContextSystem converts each instruction into triangles (circles become triangle fans, curves become polylines)
3. **Batching**: The system decides whether to merge with sprite batches or render directly
4. **Draw call**: GPU geometry buffers are bound and the draw command is issued

Here is the flow visualized:

```
┌───────────────────────────────────────────────────────────────┐
│  1. Recording Phase (your code)                               │
│                                                               │
│     graphics.circle(100, 100, 50);                           │
│     graphics.fill({ color: 0xff0000 });                      │
│                                                               │
│     Result: Instructions array with FillInstruction          │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────┐
│  2. Tessellation (first render or after changes)             │
│                                                               │
│     GraphicsContextSystem processes instructions:            │
│     - Circles become triangle fans                           │
│     - Rectangles become two triangles                        │
│     - Bezier curves become many small triangles              │
│                                                               │
│     Result: Vertex buffer, index buffer, texture batches     │
└───────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────┐
│  3. Batching Decision                                         │
│                                                               │
│     Simple graphics (few verts, solid color)?                │
│       → Batch with sprites (see batching.md)                 │
│                                                               │
│     Complex graphics (many verts, custom shaders)?           │
│       → Render directly via GpuGraphicsAdaptor               │
└───────────────────────────────────────────────────────────────┘
```

The batching decision matters for performance. Simple graphics can be merged with sprite batches, reducing draw calls (see [Batching](./batching.md) for details). Complex graphics get their own draw calls but still benefit from internal batching by texture.

---

## Dirty Flag Optimization

A subtle but important pattern: changes do not trigger immediate tessellation. They just set a dirty flag:

```typescript
onUpdate(): void {
    this._boundsDirty = true;

    if (this.dirty) return;  // Already marked, skip redundant work
    this.emit('update', this);
    this.dirty = true;
}
```

Why does this matter? Consider animation. If you modify a graphics context 60 times per second, you do not want 60 tessellations. You want one tessellation per frame, right before rendering. The dirty flag ensures that even if you call `graphics.clear().circle(...).fill(...)` multiple times in a frame, tessellation happens only once.

---

## Event-Driven Updates

GraphicsContext is an event emitter. When content changes, it notifies listeners:

```typescript
class GraphicsContext extends EventEmitter<{
    update: GraphicsContext;   // Content changed
    destroy: GraphicsContext;  // Being destroyed
    unload: GraphicsContext;   // GPU data unloaded
}>
```

Graphics objects listen to their context:

```typescript
set context(context: GraphicsContext) {
    // Unsubscribe from old context
    if (this._context) {
        this._context.off('update', this.onViewUpdate, this);
    }

    // Subscribe to new context
    this._context = context;
    this._context.on('update', this.onViewUpdate, this);
}
```

This enables the sharing pattern. When a shared context updates, all Graphics objects referencing it receive the notification and know to re-render.

---

## Direct Rendering: The Adaptor

When graphics cannot be batched, the `GpuGraphicsAdaptor` handles direct rendering. Here is the conceptual flow:

1. **Set geometry**: The tessellated vertex and index buffers
2. **Bind global uniforms**: Camera, time, etc. (see [Bind Groups](./bind-groups.md))
3. **For each internal batch** (grouped by texture):
   - Update pipeline if topology changed (see [Pipeline Caching](./pipeline-caching.md))
   - Bind texture group
   - Issue draw call

The internal batching is important. A single Graphics object might have shapes with different textures. Rather than one draw call per shape, the system groups by texture and uses indexed drawing to render multiple shapes per call.

---

## wgpu Equivalent Sketch

For those building a similar system in Rust with wgpu:

```rust
// The instruction recording structure
struct GraphicsContext {
    instructions: Vec<GraphicsInstruction>,
    active_path: Path,
    transform: Matrix3x2,
    fill_style: FillStyle,
    stroke_style: StrokeStyle,
    state_stack: Vec<GraphicsState>,
}

enum GraphicsInstruction {
    Fill { style: FillStyle, path: Path, hole: Option<Path> },
    Stroke { style: StrokeStyle, path: Path },
    Texture { texture: TextureId, rect: Rect, transform: Matrix3x2 },
}

impl GraphicsContext {
    // Fluent API with transform application
    fn circle(&mut self, x: f32, y: f32, radius: f32) -> &mut Self {
        let transformed = self.transform.transform_point(Vec2::new(x, y));
        self.active_path.circle(transformed.x, transformed.y, radius);
        self
    }

    fn fill(&mut self, style: impl Into<FillStyle>) -> &mut Self {
        self.instructions.push(GraphicsInstruction::Fill {
            style: style.into(),
            path: self.active_path.clone(),
            hole: None,
        });
        self.active_path.clear();
        self
    }

    fn cut(&mut self) -> &mut Self {
        if let Some(GraphicsInstruction::Fill { hole, .. }) = self.instructions.last_mut() {
            *hole = Some(self.active_path.clone());
        }
        self.active_path.clear();
        self
    }

    fn save(&mut self) -> &mut Self {
        self.state_stack.push(GraphicsState {
            transform: self.transform,
            fill_style: self.fill_style.clone(),
            stroke_style: self.stroke_style.clone(),
        });
        self
    }

    fn restore(&mut self) -> &mut Self {
        if let Some(state) = self.state_stack.pop() {
            self.transform = state.transform;
            self.fill_style = state.fill_style;
            self.stroke_style = state.stroke_style;
        }
        self
    }
}

// The tessellated GPU data
struct GpuGraphicsContext {
    geometry: Geometry,
    batches: Vec<GraphicsBatch>,
    is_batchable: bool,
}

// The scene object that references a context
struct Graphics {
    context: Arc<GraphicsContext>,
    transform: Transform2D,
    gpu_data: Option<GpuGraphicsContext>,
}
```

The key difference from PixiJS: Rust's `Arc` provides explicit shared ownership, making the context-sharing pattern type-safe. You do not need event systems for memory management since the borrow checker handles lifetimes.

For tessellation, the Rust ecosystem offers the [lyon](https://github.com/nical/lyon) crate - a battle-tested library for path tessellation that handles fills, strokes, and curves. Rather than implementing your own triangle fan generation, lyon provides configurable tolerance settings and handles edge cases like self-intersecting paths. It outputs vertex and index buffers directly compatible with wgpu.

---

## Key Takeaways

### 1. Record First, Tessellate Later

Drawing calls capture your intent. Tessellation happens lazily when rendering. This enables optimization and caching.

### 2. Separate Content from Instance

GraphicsContext holds the expensive data (instructions, tessellated geometry). Graphics holds the cheap data (transform, reference). Share contexts when shapes repeat.

### 3. Dirty Flags Prevent Redundant Work

Multiple changes in a frame result in one tessellation, not many. The dirty flag coalesces updates.

### 4. Batching When Possible

Simple graphics merge with sprite batches for fewer draw calls. Complex graphics render directly but with internal texture batching.

---

## Where to Go From Here

- **[Batching](./batching.md)** - How simple graphics get merged with sprite batches
- **[Pipeline Caching](./pipeline-caching.md)** - How render pipelines are reused across draw calls
- **[Encoder System](./encoder-system.md)** - How draw commands get recorded for the GPU
- **[Bind Groups](./bind-groups.md)** - How textures and uniforms are bound for rendering

---

## Sources

- `libraries/pixijs/src/scene/graphics/shared/Graphics.ts`
- `libraries/pixijs/src/scene/graphics/shared/GraphicsContext.ts`
- `libraries/pixijs/src/scene/graphics/shared/GraphicsPipe.ts`
- `libraries/pixijs/src/scene/graphics/gpu/GpuGraphicsAdaptor.ts`

---

*Previous: [Bind Groups](bind-groups.md)*
