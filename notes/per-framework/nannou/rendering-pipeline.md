# nannou Rendering Pipeline

> How drawing commands become pixels on screen.

## Key Insight

> **Rendering Pipeline's core idea:** nannou provides an immediate-mode drawing API (queue commands each frame) that internally batches primitives and submits them to wgpu's retained-mode GPU backend for efficient rendering.

## Overview

nannou uses an **immediate-mode drawing API** backed by wgpu (retained-mode GPU).

## From User Code to Pixels

```
User calls draw.ellipse().x_y(100.0, 100.0).radius(50.0);
        │
        ▼
Drawing<Ellipse> created, queued in Draw context
        │
        ▼
In view function: frame.submit() or automatic submission
        │
        ▼
Draw renderer processes primitives
        │
        ▼
Vertices generated, uploaded to GPU buffers
        │
        ▼
wgpu render pass executes
        │
        ▼
Surface presented to screen
```

## Renderer Abstraction

### Draw (`draw/mod.rs`)
- Accumulates drawing commands
- Manages transform stack
- Holds drawing state (fill, stroke, etc.)

### Draw Renderer (`draw/renderer/`)
- Converts Draw commands to GPU primitives
- Manages vertex/index buffers
- Executes wgpu render passes

### wgpu Backend (`nannou_wgpu`)
- Thin wrapper over wgpu
- Pipeline builders
- Texture and buffer management

## State Management

### Transform Stack
```rust
let draw = draw.x_y(100.0, 100.0);  // Returns new Draw with transform
draw.ellipse().radius(50.0);

// Or with push/pop pattern
draw.push().translate(100.0, 100.0);
// draw things
draw.pop();
```

### Drawing State
- Fill color
- Stroke color/weight
- Blend mode

## Frame Loop

```rust
fn view(app: &App, model: &Model, frame: Frame) {
    let draw = app.draw();

    draw.background().color(BLACK);
    draw.ellipse().color(RED);

    draw.to_frame(app, &frame).unwrap();
}
```

## Performance Considerations

- Commands batched per frame
- Vertex data uploaded each frame
- Consider `nannou_mesh` for static geometry
- wgpu handles GPU synchronization

## Study Questions

- [ ] How does the Draw struct accumulate commands?
- [ ] How are transforms composed?
- [ ] How does the renderer batch primitives?
- [ ] How does text rendering integrate with the draw API?
