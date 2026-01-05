# p5.js Rendering Pipeline

## Overview

p5.js uses an **immediate-mode** rendering model where drawing commands execute immediately against a canvas context.

## From User Code to Pixels

```
User calls circle(100, 100, 50)
        │
        ▼
p5.prototype.circle() in core/shape/2d_primitives.js
        │
        ▼
this._renderer.ellipse() - delegates to active renderer
        │
        ▼
p5.Renderer2D.ellipse() in core/p5.Renderer2D.js
        │
        ▼
CanvasRenderingContext2D.arc() + fill()/stroke()
        │
        ▼
Browser composites to screen
```

## Renderer Abstraction

### Base Renderer (`p5.Renderer`)
- Common interface for all renderers
- Manages canvas element
- Handles resize events

### 2D Renderer (`p5.Renderer2D`)
- Wraps `CanvasRenderingContext2D`
- Direct pass-through for most operations
- State managed via `save()`/`restore()`

### WebGL Renderer (`p5.RendererGL`)
- Maintains GL state machine
- Batches geometry where possible
- Manages shader compilation/linking
- Handles texture uploads

## State Management

### Transform Stack
- `push()` saves current transform matrix
- `pop()` restores previous state
- Implemented via canvas `save()`/`restore()` in 2D
- Manual matrix stack in WebGL

### Drawing State
- Fill color, stroke color, stroke weight
- Blend mode, tint
- Text properties (font, size, align)

## Frame Loop

```javascript
// In core/main.js
_draw() {
  // Calculate timing
  this._frameRate = 1000 / (now - this._lastFrameTime);

  // Clear if needed
  if (this._loop) {
    // Call user's draw function
    this._userDraw();
  }

  // Schedule next frame
  requestAnimationFrame(this._draw.bind(this));
}
```

## Performance Considerations

- Each drawing call is immediate (no batching in 2D mode)
- WebGL mode batches some geometry
- `noLoop()` stops the draw loop for static sketches
- `push()`/`pop()` have overhead

## Study Questions

- [ ] How does WebGL mode batch draw calls?
- [ ] What happens when switching between 2D and WebGL?
- [ ] How is pixel density (retina) handled?
- [ ] How does p5.Graphics manage off-screen rendering?
