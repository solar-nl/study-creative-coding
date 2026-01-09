# The Patch Canvas Architecture

> *Pan across a thousand operators without a stutter - the patch canvas makes it look easy, but there's serious GPU optimization behind the scenes.*

---

## The Problem: Rendering Hundreds of Operators at 60fps

Think about what the patch canvas actually needs to draw. Each operator is a rectangle with a title, potentially dozens of ports (each a smaller rectangle), connection points, and hover states. Multiply that by hundreds of operators. Add cables - smooth bezier curves that update when you drag. Now do all of that 60 times per second while the user pans and zooms.

The naive approach would be disastrous. Drawing each element with a separate WebGL draw call introduces significant overhead. With 200 operators and 10 ports each, you could hit thousands of draw calls per frame. Frame rates would plummet.

The solution is **GPU instancing**: one draw call for all rectangles, one for all cables, one for all text. The GPU handles the multiplication. Coordinating this requires careful architecture - which is exactly what GlPatch provides.

---

## Mental Model: A Drawing Program's Canvas

Think of GlPatch as the canvas in Figma or Illustrator. It handles the same core responsibilities:

1. **World coordinates vs. screen coordinates** - Operators live in "patch space." Your screen shows a viewport into that world.
2. **Pan and zoom navigation** - Click-drag to pan, scroll to zoom. The viewport transforms world to screen.
3. **Hit testing** - When you click, something figures out *what* you clicked on.
4. **Batched rendering** - All shapes draw efficiently, not one at a time.

The key insight: **everything is rectangles**. Operators, ports, selection boxes, hover highlights - all batched through a single instanced renderer. Cables are the exception; they use a separate spline renderer.

```
┌─────────────────────────────────────────────────────────────┐
│                        GlPatch                               │
│  ┌───────────────┐  ┌────────────────┐  ┌────────────────┐  │
│  │ GlRectInst.   │  │ GlSplineDrawer │  │ GlTextWriter   │  │
│  │ (operators,   │  │ (bezier        │  │ (operator      │  │
│  │  ports)       │  │  cables)       │  │  titles)       │  │
│  └───────────────┘  └────────────────┘  └────────────────┘  │
│         │                  │                   │             │
│         └──────────────────┼───────────────────┘             │
│                            ▼                                 │
│  ┌───────────────────────────────────────────────────────┐  │
│  │                  WebGL 2.0 Context                     │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

---

## GlPatch: The Orchestrator

GlPatch extends the Events class, making it both a renderer and an event hub. When something happens on the canvas - mouse up over an operator, mouse down over a port - GlPatch emits events that other systems listen for.

```javascript
export default class GlPatch extends Events {
    static EVENT_MOUSE_UP_OVER_OP = "mouseUpOverOp";
    static EVENT_MOUSE_UP_OVER_PORT = "mouseUpOverPort";
    static EVENT_MOUSE_DOWN_OVER_PORT = "mouseDownOverPort";
```

The constructor assembles all rendering subsystems:

```javascript
constructor(cgl) {
    this.#cgl = cgl;
    this.mouseState = new MouseState(cgl.canvas);

    // GPU instanced renderers
    this.#rectInstancer = new GlRectInstancer(cgl, {
        "name": "mainrects", "initNum": 1000, "hoverWhenButton": true
    });
    this.#splineDrawers = { "0": new GlSplineDrawer(cgl, "patchCableSplines_0") };
    this.#textWriter = new GlTextWriter(cgl, { "name": "mainText", "initNum": 1000 });

    this.viewBox = new GlViewBox(cgl, this);
    this.#selectionArea = new GlSelectionArea(this._overLayRects);
    this.portDragLine = new GlDragLine(this.#overlaySplines, this);
}
```

Notice `initNum: 1000` - renderers pre-allocate space, avoiding expensive reallocation as you add operators.

---

## GPU Instancing with GlRectInstancer

Here is where performance magic happens. Traditional rendering draws each rectangle separately - each draw call is overhead. GlRectInstancer uploads all rectangle data as GPU attributes and draws everything in one call:

```
upload position/size/color for all rectangles  →  GPU
draw instanced  →  GPU renders all 500
```

When you create a visual element, you request a GlRect handle:

```javascript
const rect = glpatch.rectInstancer.createRect();
rect.setPosition(x, y);
rect.setSize(width, height);
rect.setColor(r, g, b, a);
```

The rect queues into attribute buffers. When the frame renders, all rectangles draw together. This is why panning across a thousand operators feels smooth - the GPU does what it does best: parallel processing.

---

## GlViewBox: Pan and Zoom

GlViewBox manages the viewport transformation:

- `_scrollX`, `_scrollY` - Current pan offset in world coordinates
- `_zoom` - Current zoom level (default 500)
- `mousePatchX`, `mousePatchY` - Mouse position in world coordinates

When you scroll or drag, GlViewBox animates with easing:

```javascript
if (this._zoom !== this._targetZoom) {
    this._zoom += (this._targetZoom - this._zoom) * 0.2;
}
```

Converting mouse coordinates to patch space is essential for hit testing. When you click at screen position (400, 300), the viewbox converts it to patch coordinates like (1234.5, 567.8). All operators store positions in patch space.

---

## MouseState and Subpatches

MouseState tracks button states using a bitmask (`LEFT=1`, `RIGHT=2`, `WHEEL=4`) and which button triggers which action - `buttonForScrolling` for panning, `buttonForSelecting` for selection rectangles.

Cables.gl supports subpatches - patches within patches. GlPatch tracks which is visible via `_currentSubpatch`. Each subpatch gets its own spline drawer in the `#splineDrawers` map, since cables only render within their subpatch.

---

## Trace: Adding an Operator to the Canvas

**1.** User selects operator from OpSelect - dialog calls `gui.patchView.addOp(opname, options)`.

**2.** Core patch creates the Op with unique ID, ports, and defaults.

**3.** GlPatch creates visual representation:

```javascript
addOp(op, fromDeserialize) {
    const glOp = new GlOp(this, op, this._glOpz.length, this.#rectInstancer);
    this._glOpz[op.id] = glOp;
}
```

**4.** GlOp requests rectangles from the shared instancer - one for the body, one per port, optional decorations.

**5.** Rectangles batch into next frame. One draw call renders the new operator alongside all existing ones.

**6.** If linking context exists, cable is created automatically via `newOpOptions.linkNewOpToPort`.

---

## Trace: Mouse Down on Canvas

**1.** MouseState captures the event, updating button state.

**2.** GlPatch tests what is under cursor using `viewBox.mousePatchX/Y`:

```javascript
for (const id in this._glOpz) {
    const glOp = this._glOpz[id];
    if (glOp.hitTest(mousePatchX, mousePatchY)) {
        // Clicked on operator
    }
}
```

**3.** Decision branches:
- **Operator**: Emit `EVENT_MOUSE_DOWN_OVER_OP`, start potential drag
- **Port**: Emit `EVENT_MOUSE_DOWN_OVER_PORT`, start drag line
- **Empty space + pan button**: Begin viewport pan
- **Empty space + select button**: Begin selection rectangle

**4.** Space key override: holding space triggers pan mode regardless of what is under cursor.

---

## Edge Cases and Gotchas

### Canvas Resize

When the browser window resizes, WebGL needs explicit notification via `viewBox.setSize(newWidth, newHeight)`. Without this, mouse coordinates misalign with rendered content.

### Space Key for Panning

Space+drag enables panning anywhere. The key must be pressed *before* mouse down, not during drag.

### Cut Line Mode

Alt+drag creates a "cut line" that severs cables it crosses. Intersection testing uses bezier curve parameterization.

### High-DPI Displays

GlPatch accounts for device pixel ratio when setting up the WebGL viewport, ensuring sharp rendering on retina screens.

---

## What's Next

GlPatch provides canvas infrastructure, but operators need visual representation. The next chapter, [Operators & Visual Rendering](02-operator-rendering.md), dives into GlOp - how operators render their body, ports, and interactive states.
