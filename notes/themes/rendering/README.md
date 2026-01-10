# Rendering Modes: Batching, Immediate Mode, and Draw Call Optimization

> How do creative coding frameworks turn your drawing commands into efficient GPU operations?

---

## The Problem: Draw Calls Are Expensive

Every time you call `circle()` or `rect()`, your framework must:

1. **Set GPU state** (shader, blend mode, uniforms)
2. **Upload vertex data** (or bind existing buffers)
3. **Issue a draw call** (`glDrawElements` / `draw_indexed`)

The bottleneck isn't the triangles—modern GPUs can render millions. It's the **draw call overhead**. Each draw call involves CPU-GPU synchronization that takes microseconds.

```
1000 circles × 1 draw call each = slow (~16ms of overhead alone)
1000 circles × 1 batched draw call = fast (~0.1ms overhead)
```

This is why batching matters.

---

## The Two Fundamental Modes

### Immediate Mode: Draw and Forget

```
Your Code                    Framework                    GPU
─────────                    ─────────                    ───
circle(x, y, r)    →    tessellate → upload    →    draw
circle(x2, y2, r2) →    tessellate → upload    →    draw
circle(x3, y3, r3) →    tessellate → upload    →    draw
                                                    (3 draw calls)
```

**Characteristics:**
- No persistent geometry storage
- Simple mental model
- Each shape = one draw call (typically)
- Re-tessellates every frame

**Used by:** p5.js (default), Processing (beginShape/endShape), OpenFrameworks (ofDraw*)

### Retained Mode: Store and Reuse

```
Your Code                    Framework                    GPU
─────────                    ─────────                    ───
shape = createShape()   →    tessellate → upload    →    (stored in VRAM)
shape = createShape()   →    tessellate → upload    →    (stored in VRAM)
shape = createShape()   →    tessellate → upload    →    (stored in VRAM)
                                                    (one-time upload)
Later:
draw(shape)            →    bind existing          →    draw
draw(shape)            →    bind existing          →    draw
                                                    (fast, no re-upload)
```

**Characteristics:**
- Geometry persists across frames
- Must manually invalidate when shape changes
- Can batch multiple retained shapes
- More complex API

**Used by:** Processing (PShape), Cinder (Batch), openrndr (Shape), nannou (Mesh)

---

## Framework-by-Framework Analysis

### p5.js: Browser Delegation with WebGL Optimization

**Architecture:**
```
p5.RendererGL
├── immediateMode
│   ├── geometry: p5.Geometry (reused temp object)
│   └── buffers: { fill: [], stroke: [], point: [] }
└── retainedMode
    ├── geometry: { gId: p5.Geometry }  // cached by ID
    └── buffers: { fill: [], stroke: [] }
```

**Immediate Mode:**
```javascript
beginShape();
vertex(30, 20);
vertex(85, 75);
endShape(CLOSE);
```
- Vertices accumulate in `immediateMode.geometry`
- On `endShape()`: tessellate → upload → draw → clear

**Retained Mode:**
```javascript
let shape = createShape();
shape.beginShape();
shape.vertex(30, 20);
shape.vertex(85, 75);
shape.endShape(CLOSE);

// Later (fast)
shape(shape, x, y);
```
- Geometry cached by ID in `retainedMode.geometry`
- Draw reuses existing VBOs

**Batching Strategy:** None explicitly. Each `shape()` call = one draw call.

**State Management:**
- Fill/stroke colors stored **per-vertex** (no batch breaking)
- Shader selection based on lighting/texture state
- No automatic batching of similar shapes

**Key Limitation:** No multi-shape batching. Drawing 1000 circles = 1000 draw calls.

---

### Processing: Sophisticated Automatic Batching

**Architecture:**
```
PGraphicsOpenGL
├── InGeometry (raw input vertices)
├── TessGeometry (tessellated triangles)
│   ├── polyVertices[], polyColors[], polyNormals[]
│   ├── lineVertices[], lineColors[]
│   └── pointVertices[], pointColors[]
├── IndexCache (tracks batch boundaries)
└── TexCache (groups by texture)
```

**The Flush System:**

Processing has two flush modes:

```java
static protected final int FLUSH_CONTINUOUSLY = 0;  // Draw after each endShape
static protected final int FLUSH_WHEN_FULL    = 1;  // Default: batch until buffer fills
```

With `FLUSH_WHEN_FULL`, vertices accumulate across multiple `beginShape()`/`endShape()` calls:

```java
// All these get batched together if same texture/state
beginShape(); vertex(...); endShape();
beginShape(); vertex(...); endShape();
beginShape(); vertex(...); endShape();
// Flush happens when: buffer full OR state changes OR frame ends
```

**Batching Trigger:**
```java
boolean isFull() {
    return PGL.FLUSH_VERTEX_COUNT <= polyVertexCount ||
           PGL.FLUSH_VERTEX_COUNT <= lineVertexCount ||
           PGL.FLUSH_VERTEX_COUNT <= pointVertexCount;
}
// Default FLUSH_VERTEX_COUNT ≈ 10,000+ vertices
```

**Texture-Based Grouping:**

Processing groups draw calls by texture:

```java
for (int i = 0; i < texCache.size; i++) {
    Texture tex = texCache.getTexture(i);
    // All geometry with same texture → one draw call
    shader.draw(bufPolyIndex.glId, icount, ioffset);
}
```

**State Changes That Break Batches:**
- Texture change
- `textureWrap()` change (explicit flush)
- Transform changes (tracked in IndexCache)

**PShape (Retained Mode):**
```java
PShape s = createShape(RECT, 0, 0, 100, 50);
// Pre-tessellated, stored in VBOs

shape(s, x, y);  // Fast: just bind and draw
```

`PShapeOpenGL` maintains separate VBOs for polys, lines, and points.

---

### OpenFrameworks: Explicit Control with Lazy Updates

**Architecture:**
```
ofPath (high-level)           ofVboMesh (low-level)
├── polylines[]               ├── vertexData
├── tessellator               ├── colorData
├── cachedTessellation        ├── normalData
└── bNeedsTessellation        └── vbo (ofVbo)
```

**ofPath - Deferred Tessellation:**

```cpp
ofPath path;
path.lineTo(100, 100);
path.lineTo(200, 50);
path.close();

// Tessellation happens lazily on first draw
path.draw();  // tessellate() called internally if needed
```

**ofVboMesh - Change Tracking:**

```cpp
void ofVboMesh::updateVbo() {
    if(!vbo.getIsAllocated()) {
        // First time: allocate and upload all
        vbo.setVertexData(vertices, GL_STATIC_DRAW);
    } else {
        // Incremental: only update what changed
        if(haveVertsChanged()) {
            vbo.updateVertexData(vertices);
        }
    }
}
```

**Buffer Usage Hints:**

```cpp
// Explicit control over upload strategy
mesh.setMode(OF_PRIMITIVE_TRIANGLES);
vbo.setVertexData(verts, count, GL_STATIC_DRAW);   // Never changes
vbo.setVertexData(verts, count, GL_DYNAMIC_DRAW);  // Changes occasionally
vbo.setVertexData(verts, count, GL_STREAM_DRAW);   // Changes every frame
```

**Batching:** Manual. Each `ofPath::draw()` or `ofVboMesh::draw()` = one draw call.

**Limitation:** No automatic batching. Must manually combine geometry into single mesh for batching.

---

### Cinder: Explicit Batch Objects

**Architecture:**
```
Batch (primary abstraction)
├── mVboMesh: VboMeshRef
├── mGlsl: GlslProgRef
└── mVao: VaoRef (pre-computed vertex layout)
```

**The Batch Pattern:**

```cpp
// Create batch once
auto mesh = gl::VboMesh::create(geom::Sphere().radius(50));
auto shader = gl::getStockShader(gl::ShaderDef().color());
auto batch = gl::Batch::create(mesh, shader);

// Draw many times (fast)
batch->draw();
batch->draw();
batch->draw();
```

**VAO Pre-binding:**

Cinder computes the vertex attribute layout once during `Batch::create()`:

```cpp
void Batch::initVao(const AttributeMapping &attributeMapping) {
    mVao = Vao::create();
    mVboMesh->buildVao(mGlsl, attributeMapping);  // Maps attributes to shader
}
```

**Draw is Minimal:**

```cpp
void Batch::draw(GLint first, GLsizei count) {
    gl::ScopedGlslProg scopedShader(mGlsl);  // Bind shader
    gl::ScopedVao scopedVao(mVao);           // Bind VAO
    mVboMesh->drawImpl(first, count);        // Just glDrawElements
}
```

**VertBatch - Immediate Mode Alternative:**

```cpp
gl::VertBatch vb(GL_TRIANGLES);
vb.color(1, 0, 0);
vb.vertex(0, 0);
vb.vertex(100, 0);
vb.vertex(50, 100);
vb.draw();
```

**Batching:** Manual. Each Batch = one draw call. For multiple shapes, tessellate into single VboMesh.

**Instanced Drawing:**

```cpp
batch->drawInstanced(1000);  // Draw 1000 instances with one draw call
```

---

### openrndr: Explicit Batching with Builder Pattern

**Architecture:**
```
Drawer
├── circleDrawer: CircleDrawer
│   ├── batch: CircleBatch (geometry + drawStyle VBOs)
│   └── singleBatches: List<CircleBatch> (rotating pool)
├── rectangleDrawer: RectangleDrawer
├── pointDrawer: PointDrawer
└── qualityPolygonDrawer: QualityPolygonDrawer
```

**Single Shape (Unbatched):**

```kotlin
drawer.circle(100.0, 100.0, 50.0)  // One draw call
drawer.circle(200.0, 200.0, 50.0)  // Another draw call
```

**Batched Drawing:**

```kotlin
drawer.circles {
    fill = ColorRGBa.RED
    circle(100.0, 100.0, 50.0)

    fill = ColorRGBa.BLUE  // No batch break! Per-instance style
    circle(200.0, 200.0, 50.0)
}
// One draw call for all circles
```

**Per-Instance Style Data:**

openrndr stores style data in vertex buffers alongside geometry:

```kotlin
val drawStyleFormat = vertexFormat {
    attribute("fill", VertexElementType.VECTOR4_FLOAT32)
    attribute("stroke", VertexElementType.VECTOR4_FLOAT32)
    attribute("strokeWeight", VertexElementType.FLOAT32)
}
```

This allows different fills/strokes per shape **without breaking the batch**.

**Multi-Buffer Rotation:**

To avoid GPU sync stalls, openrndr rotates through buffer pools:

```kotlin
private val singleBatches = (0 until DrawerConfiguration.vertexBufferMultiBufferCount)
    .map { CircleBatch.create(1) }
private var count = 0

fun drawCircle(...) {
    val batch = singleBatches[count.mod(singleBatches.size)]
    count++  // Next call uses different buffer
}
```

**Quality vs Performance Modes:**

```kotlin
drawer.drawStyle.quality = DrawQuality.PERFORMANCE  // Fast lines
drawer.drawStyle.quality = DrawQuality.QUALITY      // Smooth lines with caps/joins
```

---

### nannou: Context-Aware Automatic Batching

**Architecture:**
```
Draw (accumulates commands)
├── state: State
│   ├── draw_commands: Vec<DrawCommand>
│   └── intermediary_mesh: Mesh
└── context: Context (transform, blend, scissor, topology)

Renderer (converts to GPU commands)
├── pipelines: HashMap<PipelineId, RenderPipeline>
├── render_commands: Vec<RenderCommand>
└── mesh: accumulated vertex data
```

**Two-Phase Pipeline:**

```
Phase 1: Draw API                    Phase 2: Render
────────────────                     ──────────────
draw.rect()                          Drain DrawCommands
  → DrawCommand::Primitive(Rect)  →  Tessellate via Lyon
draw.ellipse()                       Accumulate vertices
  → DrawCommand::Primitive(Ellipse) → Generate RenderCommands
draw.path()                          Create GPU buffers
  → DrawCommand::Primitive(Path)     Execute draw calls
```

**Automatic Batching:**

nannou batches automatically based on context:

```rust
// All these become ONE draw call if same context
draw.rect().color(RED);
draw.rect().color(BLUE);
draw.ellipse().color(GREEN);
// Color differences don't break batch (per-vertex attribute)

// This DOES break the batch (different blend mode)
draw.rect().blend(BLEND_ADD);
```

**What Breaks Batches:**
- Pipeline change (blend mode + topology)
- Texture change
- Scissor rect change

**RenderCommand Types:**

```rust
enum RenderCommand {
    SetPipeline(PipelineId),    // Changes shader/blend
    SetBindGroup(BindGroupId),  // Changes texture
    SetScissor(Scissor),        // Changes clip region
    DrawIndexed { ... },        // Actual draw call
}
```

**Vertex Mode Per-Vertex:**

nannou supports mixed content via per-vertex mode flags:

```rust
// Single mesh can have colored vertices AND textured vertices
// Shader branches based on vertex_mode attribute
```

---

## Comparison Matrix

| Framework | Auto-Batching | Batch Granularity | State Break Triggers | Retained Mode |
|-----------|---------------|-------------------|---------------------|---------------|
| p5.js | None | Per-shape | N/A | Yes (createShape) |
| Processing | **Yes** | Per-texture | Texture, textureWrap | Yes (PShape) |
| OpenFrameworks | None | Per-draw call | N/A | Yes (ofVboMesh) |
| Cinder | None | Per-Batch object | N/A | Yes (Batch) |
| openrndr | **Yes** (builder) | Per-builder block | Shader change only | Yes (Shape) |
| nannou | **Yes** | Per-context | Blend, texture, scissor | Yes (Mesh) |

---

## Performance Patterns

### Pattern 1: Pre-Compute Static Geometry

```rust
// BAD: Tessellate every frame
fn draw(&self) {
    for circle in &self.circles {
        draw.ellipse().xy(circle.pos).radius(circle.r);  // Tessellate each
    }
}

// GOOD: Tessellate once, transform to draw
fn setup(&mut self) {
    self.circle_mesh = tessellate_circle(1.0);  // Unit circle
}

fn draw(&self) {
    for circle in &self.circles {
        draw.mesh(&self.circle_mesh)
            .xy(circle.pos)
            .scale(circle.r);  // Just transform
    }
}
```

### Pattern 2: Use Builder Batching (openrndr style)

```kotlin
// BAD: 1000 draw calls
for (circle in circles) {
    drawer.circle(circle.x, circle.y, circle.r)
}

// GOOD: 1 draw call
drawer.circles {
    for (circle in circles) {
        circle(circle.x, circle.y, circle.r)
    }
}
```

### Pattern 3: Instance Rendering

```cpp
// Cinder: Draw 10000 spheres with one draw call
auto batch = gl::Batch::create(geom::Sphere(), shader);
batch->drawInstanced(10000);

// Instance transforms via uniform buffer or vertex attributes
```

### Pattern 4: Minimize State Changes

```rust
// BAD: Alternating textures breaks batches
for i in 0..100 {
    draw.texture(&tex_a).rect();
    draw.texture(&tex_b).rect();  // Batch break every iteration!
}

// GOOD: Group by texture
for i in 0..100 {
    draw.texture(&tex_a).rect();
}
for i in 0..100 {
    draw.texture(&tex_b).rect();
}
// Only 2 batches total
```

### Pattern 5: Buffer Pooling (Avoid Sync Stalls)

```rust
// Rotating buffer pool to avoid GPU sync
let buffers: Vec<Buffer> = (0..3).map(|_| create_buffer()).collect();
let mut current = 0;

fn draw(&mut self) {
    let buffer = &self.buffers[self.current % 3];
    // GPU might still be reading previous frame's data
    // Using different buffer avoids stall
    upload_to(buffer, &self.data);
    draw_with(buffer);
    self.current += 1;
}
```

---

## Mental Model: The Batching Pipeline

```
┌─────────────────────────────────────────────────────────────────────┐
│                        YOUR DRAWING CODE                             │
│  for item in items {                                                │
│      draw.circle(item.x, item.y, item.r).color(item.color);        │
│  }                                                                   │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      COMMAND ACCUMULATION                            │
│  Commands: [Circle, Circle, Circle, ContextChange, Circle, ...]     │
│  Framework decides: same context? → accumulate                       │
│                      different context? → batch boundary             │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        TESSELLATION                                  │
│  Convert paths/shapes to triangles                                  │
│  Accumulate into single vertex buffer per batch                     │
│  Track index ranges for each batch                                  │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         GPU UPLOAD                                   │
│  Upload vertex buffer (all batches)                                 │
│  Upload index buffer (all batches)                                  │
│  One-time per frame                                                 │
└───────────────────────────────┬─────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        RENDER COMMANDS                               │
│  for batch in batches {                                              │
│      if batch.pipeline != current_pipeline {                         │
│          set_pipeline(batch.pipeline);    // State change           │
│      }                                                               │
│      draw_indexed(batch.index_range);     // THE ACTUAL DRAW        │
│  }                                                                   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Recommendations for Rust Framework

### 1. Automatic Context-Based Batching (like nannou)

```rust
// Accumulate commands, batch automatically
draw.rect().color(RED);
draw.rect().color(BLUE);  // Same batch (color is per-vertex)
draw.rect().blend(ADD);   // New batch (blend changes pipeline)
```

### 2. Explicit Batch Builders (like openrndr)

```rust
// Opt-in explicit batching for performance-critical code
draw.batch(|b| {
    for circle in &circles {
        b.circle(circle.x, circle.y, circle.r)
         .fill(circle.color);
    }
});  // Guaranteed single draw call
```

### 3. Retained Mode for Static Geometry

```rust
// Pre-tessellate complex shapes
let mesh = shape.tessellate();

// Fast repeated drawing
draw.mesh(&mesh).transform(matrix);
```

### 4. Instance Rendering for Many Identical Shapes

```rust
// 10000 circles with one draw call
draw.instances(&circle_mesh, &transforms);
```

### 5. Pipeline Caching

```rust
// Cache pipelines by (blend_mode, topology, shader) tuple
// Reuse across frames
```

### 6. Double/Triple Buffering

```rust
// Avoid GPU sync stalls
struct FrameResources {
    vertex_buffer: Buffer,
    index_buffer: Buffer,
}
let resources: [FrameResources; 3] = ...;
let current_frame = frame_count % 3;
```

---

## Sources

- [p5.js WebGL Renderer Source](https://github.com/processing/p5.js/tree/main/src/webgl)
- [Processing OpenGL Source](https://github.com/processing/processing4/tree/main/core/src/processing/opengl)
- [openrndr Draw Source](https://github.com/openrndr/openrndr/tree/master/openrndr-draw)
- [nannou Renderer Source](https://github.com/nannou-org/nannou/tree/master/nannou/src/draw/renderer)
- [Cinder gl::Batch Documentation](https://libcinder.org/docs/branch/master/classcinder_1_1gl_1_1_batch.html)
- [OpenFrameworks ofVbo Documentation](https://openframeworks.cc/documentation/gl/ofVbo/)

---

*This document is part of the creative coding framework research study.*
