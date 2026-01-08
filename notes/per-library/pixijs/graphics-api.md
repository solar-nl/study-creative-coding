# PixiJS Graphics API

> Canvas-like drawing API with instruction-based rendering

---

## Overview

PixiJS provides a familiar Canvas 2D-style API for vector graphics that compiles to GPU-renderable geometry. The system has three layers:

1. **Graphics** - Scene object, wraps a GraphicsContext
2. **GraphicsContext** - Stores drawing instructions, shareable between Graphics objects
3. **GraphicsPipe + Adaptor** - Converts instructions to GPU commands

---

## Graphics vs GraphicsContext

The split allows context sharing for efficiency:

```typescript
// GraphicsContext stores the drawing instructions
const sharedContext = new GraphicsContext()
    .circle(100, 100, 50)
    .fill({ color: 0xff0000 });

// Multiple Graphics objects can share the same context
// Tessellation happens once, GPU data is reused
const graphics1 = new Graphics({ context: sharedContext });
const graphics2 = new Graphics({ context: sharedContext });
```

### Why Separate?

- **GraphicsContext**: Expensive to create (tessellation, GPU upload)
- **Graphics**: Cheap to create (just a transform + reference)

This mirrors the Texture/Sprite relationship—one piece of content, many instances.

---

## Drawing API

GraphicsContext provides a fluent, chainable API matching Canvas 2D:

```typescript
const graphics = new Graphics();

graphics
    // Path building
    .moveTo(50, 50)
    .lineTo(100, 50)
    .bezierCurveTo(150, 50, 150, 100, 100, 100)
    .quadraticCurveTo(50, 100, 50, 50)
    .closePath()
    .fill({ color: 0xff0000 })

    // Primitive shapes
    .rect(200, 50, 100, 80)
    .circle(350, 90, 40)
    .ellipse(450, 90, 50, 40)
    .roundRect(500, 50, 100, 80, 15)
    .fill({ color: 0x00ff00 })

    // Advanced shapes
    .regularPoly(650, 90, 40, 6)       // Hexagon
    .star(750, 90, 5, 40, 20)          // 5-pointed star
    .roundPoly(850, 90, 40, 5, 8)      // Pentagon with rounded corners
    .fill({ color: 0x0000ff })

    // Strokes
    .circle(100, 250, 50)
    .stroke({ width: 4, color: 0x000000 });
```

---

## Instruction Types

Drawing commands compile to three instruction types:

```typescript
type GraphicsInstructions = FillInstruction | StrokeInstruction | TextureInstruction;

interface FillInstruction {
    action: 'fill' | 'cut';
    data: {
        style: ConvertedFillStyle;
        path: GraphicsPath;
        hole?: GraphicsPath;  // For cutouts
    };
}

interface StrokeInstruction {
    action: 'stroke';
    data: {
        style: ConvertedStrokeStyle;
        path: GraphicsPath;
    };
}

interface TextureInstruction {
    action: 'texture';
    data: {
        image: Texture;
        dx: number; dy: number;
        dw: number; dh: number;
        transform: Matrix;
        alpha: number;
        style: number;  // Tint color
    };
}
```

### Fill Style

```typescript
interface ConvertedFillStyle {
    color: number;           // 0xRRGGBB
    alpha: number;           // 0-1
    texture: Texture;        // For textured fills
    matrix: Matrix | null;   // UV transform
    fill: FillPattern | FillGradient | null;
    textureSpace: 'local' | 'global';
}
```

### Stroke Style

```typescript
interface ConvertedStrokeStyle extends ConvertedFillStyle {
    width: number;           // Line width
    alignment: number;       // 0=inner, 0.5=center, 1=outer
    miterLimit: number;      // Miter join limit
    cap: 'butt' | 'round' | 'square';
    join: 'miter' | 'round' | 'bevel';
    pixelLine: boolean;      // 1px line optimization
}
```

---

## Transform Stack

GraphicsContext maintains a transform stack similar to Canvas:

```typescript
class GraphicsContext {
    private _transform: Matrix = new Matrix();
    private _stateStack: { transform, fillStyle, strokeStyle }[] = [];

    // Push current state
    save(): this {
        this._stateStack.push({
            transform: this._transform.clone(),
            fillStyle: { ...this._fillStyle },
            strokeStyle: { ...this._strokeStyle },
        });
        return this;
    }

    // Pop and restore
    restore(): this {
        const state = this._stateStack.pop();
        if (state) {
            this._transform = state.transform;
            this._fillStyle = state.fillStyle;
            this._strokeStyle = state.strokeStyle;
        }
        return this;
    }

    // Transform operations
    translate(x, y): this { this._transform.translate(x, y); return this; }
    rotate(angle): this { this._transform.rotate(angle); return this; }
    scale(x, y): this { this._transform.scale(x, y); return this; }
}
```

All path coordinates are transformed before being stored:

```typescript
lineTo(x: number, y: number): this {
    const t = this._transform;

    this._activePath.lineTo(
        (t.a * x) + (t.c * y) + t.tx,  // Transform x
        (t.b * x) + (t.d * y) + t.ty   // Transform y
    );

    return this;
}
```

---

## Cutouts (Holes)

The `cut()` method creates holes in shapes:

```typescript
graphics
    .circle(100, 100, 50)   // Outer circle
    .fill({ color: 0xff0000 })
    .circle(100, 100, 25)   // Inner circle
    .cut();                  // Subtract from previous fill
```

Implementation adds the hole path to the previous instruction:

```typescript
cut(): this {
    const lastInstruction = this.instructions[this.instructions.length - 1];
    const holePath = this._activePath.clone();

    if (lastInstruction?.action === 'fill' || lastInstruction?.action === 'stroke') {
        if (lastInstruction.data.hole) {
            lastInstruction.data.hole.addPath(holePath);  // Multiple holes
        } else {
            lastInstruction.data.hole = holePath;
        }
    }

    return this;
}
```

---

## Rendering Pipeline

### GraphicsPipe

The pipe decides whether graphics can be batched or need direct rendering:

```typescript
class GraphicsPipe implements RenderPipe<Graphics> {
    addRenderable(graphics: Graphics, instructionSet: InstructionSet) {
        const gpuContext = this.renderer.graphicsContext.updateGpuContext(graphics.context);

        if (graphics.didViewUpdate) {
            this._rebuild(graphics);  // Re-tessellate if changed
        }

        if (gpuContext.isBatchable) {
            // Simple graphics → add to sprite batcher
            this._addToBatcher(graphics, instructionSet);
        } else {
            // Complex graphics → render directly
            this.renderer.renderPipes.batch.break(instructionSet);
            instructionSet.add(graphics);
        }
    }
}
```

### Batching Decision

Graphics are batchable when:
- Few vertices (under threshold)
- Simple fills (solid color or single texture)
- No custom shader

When batchable, graphics get converted to `BatchableGraphics` elements that go through the standard sprite batcher.

### Direct Rendering (GpuGraphicsAdaptor)

Non-batchable graphics render directly:

```typescript
class GpuGraphicsAdaptor implements GraphicsAdaptor {
    execute(graphicsPipe: GraphicsPipe, renderable: Graphics): void {
        const context = renderable.context;
        const renderer = graphicsPipe.renderer as WebGPURenderer;
        const encoder = renderer.encoder;

        const { batcher, instructions } = renderer.graphicsContext.getContextRenderData(context);

        // Set geometry (tessellated paths)
        encoder.setGeometry(batcher.geometry, shader.gpuProgram);

        // Bind groups
        encoder.setBindGroup(0, globalUniformsBindGroup, shader.gpuProgram);
        encoder.setBindGroup(2, localBindGroup, shader.gpuProgram);

        // Execute each batch within the graphics
        const batches = instructions.instructions as Batch[];

        for (let i = 0; i < instructions.instructionSize; i++) {
            const batch = batches[i];

            // Set pipeline if topology changed
            if (batch.topology !== currentTopology) {
                encoder.setPipelineFromGeometryProgramAndState(
                    batcher.geometry,
                    shader.gpuProgram,
                    graphicsPipe.state,
                    batch.topology
                );
            }

            // Get/create texture bind group
            if (!batch.gpuBindGroup) {
                batch.bindGroup = getTextureBatchBindGroup(
                    batch.textures.textures,
                    batch.textures.count,
                    this._maxTextures
                );
                batch.gpuBindGroup = renderer.bindGroup.getBindGroup(batch.bindGroup, shader.gpuProgram, 1);
            }

            encoder.setBindGroup(1, batch.bindGroup, shader.gpuProgram);
            encoder.renderPassEncoder.drawIndexed(batch.size, 1, batch.start);
        }
    }
}
```

---

## Path to GPU Flow

```
                        ┌───────────────────────────────────────┐
                        │          GraphicsContext               │
                        │                                        │
graphics.circle()  ──►  │  instructions: [                      │
graphics.fill()         │    { action: 'fill',                  │
                        │      data: { path, style } }          │
                        │  ]                                     │
                        └───────────────────────────────────────┘
                                        │
                                        ▼
                        ┌───────────────────────────────────────┐
                        │       GraphicsContextSystem            │
                        │                                        │
                        │  1. Tessellate paths → triangles      │
                        │  2. Build vertex/index buffers        │
                        │  3. Create batches by texture         │
                        │  4. Upload to GPU                     │
                        └───────────────────────────────────────┘
                                        │
                                        ▼
                        ┌───────────────────────────────────────┐
                        │           GpuGraphicsContext           │
                        │                                        │
                        │  geometry: Geometry (vertex+index)    │
                        │  batches: Batch[]                     │
                        │  isBatchable: boolean                 │
                        └───────────────────────────────────────┘
                                        │
                        ┌───────────────┴───────────────┐
                        │                               │
                        ▼                               ▼
                Batchable Path                  Non-Batchable Path
                        │                               │
                        ▼                               ▼
                Add to Batcher               Execute via Adaptor
                (merged with sprites)        (direct draw calls)
```

---

## Context Sharing Pattern

GraphicsContext can be shared to avoid redundant tessellation:

```typescript
// Create context once
const circleContext = new GraphicsContext()
    .circle(0, 0, 50)
    .fill({ color: 0xff0000 });

// Use many times with different transforms
for (let i = 0; i < 100; i++) {
    const g = new Graphics({ context: circleContext });
    g.x = Math.random() * 800;
    g.y = Math.random() * 600;
    container.addChild(g);
}
```

Benefits:
- **Tessellation**: Done once, shared across all instances
- **GPU buffers**: Uploaded once, referenced many times
- **Memory**: One set of vertex data instead of 100

This is similar to instancing but works for arbitrary shapes.

---

## Event System

GraphicsContext emits events for change tracking:

```typescript
class GraphicsContext extends EventEmitter<{
    update: GraphicsContext;   // Content changed
    destroy: GraphicsContext;  // Being destroyed
    unload: GraphicsContext;   // GPU data unloaded
}> {
    // Called after any drawing operation
    protected onUpdate(): void {
        this._boundsDirty = true;

        if (this.dirty) return;  // Already marked
        this.emit('update', this, 0x10);
        this.dirty = true;
    }
}
```

Graphics listens to its context:

```typescript
set context(context: GraphicsContext) {
    if (this._context) {
        this._context.off('update', this.onViewUpdate, this);
        this._context.off('unload', this.unload, this);
    }

    this._context = context;
    this._context.on('update', this.onViewUpdate, this);
    this._context.on('unload', this.unload, this);

    this.onViewUpdate();  // Trigger re-render
}
```

---

## wgpu Equivalent Sketch

```rust
// Drawing context with instruction recording
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

// Tessellated GPU data
struct GpuGraphicsContext {
    geometry: Geometry,
    batches: Vec<GraphicsBatch>,
    is_batchable: bool,
}

// Scene object that references a context
struct Graphics {
    context: Arc<GraphicsContext>,
    transform: Transform2D,
    gpu_data: Option<GpuGraphicsContext>,
}
```

---

## Key Patterns

### 1. Instruction Recording, Deferred Tessellation

Drawing calls record instructions. Tessellation happens lazily when rendering:

```typescript
// These just record instructions
graphics.circle(100, 100, 50);
graphics.fill({ color: 0xff0000 });

// Tessellation happens here (on first render)
renderer.render(graphics);
```

### 2. Context Sharing for Instancing

Share context between Graphics objects to avoid redundant tessellation.

### 3. Dirty Flag Optimization

Changes only trigger re-tessellation on render, not immediately:

```typescript
onUpdate(): void {
    this._boundsDirty = true;
    if (this.dirty) return;  // Already dirty
    this.emit('update', this);
    this.dirty = true;
}
```

### 4. Batching Decision

Simple graphics batch with sprites. Complex graphics render directly but with internal batching by texture.

---

## Sources

- `libraries/pixijs/src/scene/graphics/shared/Graphics.ts`
- `libraries/pixijs/src/scene/graphics/shared/GraphicsContext.ts`
- `libraries/pixijs/src/scene/graphics/shared/GraphicsPipe.ts`
- `libraries/pixijs/src/scene/graphics/gpu/GpuGraphicsAdaptor.ts`

---

*Previous: [Bind Groups](bind-groups.md)*
