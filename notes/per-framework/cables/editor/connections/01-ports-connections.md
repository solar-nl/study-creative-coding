# Ports and Visual Connections

> *Click a port, drag across the canvas, release on another - a cable appears. Behind this simple gesture is a surprisingly intricate dance of hit testing, type checking, and bezier math.*

---

## The Problem: Making Data Flow Visible and Interactive

Connecting operators is the fundamental interaction in a visual programming environment. You need to grab an output, drag it to an input, and see the result. Simple, right?

Not quite. The system must solve several challenges simultaneously:

1. **Visual feedback during drag** - A temporary line must follow your cursor, updating 60 times per second
2. **Type validation** - Not every port can connect to every other port; numbers cannot flow into textures
3. **Smooth cable rendering** - Bezier curves must look good at any angle and distance
4. **Performance at scale** - All of this must work instantly even with hundreds of existing connections

The naive approach - checking every port on mouse move, redrawing every cable every frame - would stutter and lag. The solution is a three-layer architecture that separates concerns and optimizes each layer independently.

---

## Mental Model: Ports, Links, and Cables

Think of the connection system as a **three-layer hierarchy**:

1. **Ports** - The physical connectors on operators, like USB ports on a laptop. Each port has a type (number, texture, trigger) and a direction (input or output).

2. **Links** - The logical connection in the data model. A link says "output X connects to input Y" but knows nothing about visual representation.

3. **Cables** - The visual bezier curves you see on screen. A cable renders a link, but the link could exist without any visual (in headless mode, for instance).

This separation matters. When you drag from a port, the system creates a temporary visual (GlDragLine) that is *not* a real link. Only when you release on a valid target does the data model update. Then, and only then, does a permanent GlCable appear.

```
┌─────────────────────────────────────────────────────────────┐
│                     Connection System                        │
│                                                              │
│  Data Model Layer          Visual Layer                      │
│  ┌──────────────┐         ┌──────────────┐                  │
│  │    Port      │◄───────▶│   GlPort     │                  │
│  │  (core.js)   │         │  (glport.js) │                  │
│  └──────────────┘         └──────────────┘                  │
│         │                        │                           │
│         ▼                        ▼                           │
│  ┌──────────────┐         ┌──────────────┐                  │
│  │    Link      │◄───────▶│   GlLink     │                  │
│  │  (core.js)   │         │  (gllink.js) │                  │
│  └──────────────┘         └──────────────┘                  │
│                                  │                           │
│                                  ▼                           │
│                           ┌──────────────┐                  │
│                           │   GlCable    │                  │
│                           │ (glcable.js) │                  │
│                           └──────────────┘                  │
└─────────────────────────────────────────────────────────────┘
```

---

## GlPort: The Connection Point

Every port on every operator needs three things: a visual rectangle, interaction handling, and a connection to the data model. GlPort manages all three.

### Type-Based Coloring

Port color immediately communicates type. When you see a blue port, you know it accepts numbers. Orange means trigger. This visual language helps you find compatible connections at a glance:

| Type | Color | Purpose |
|------|-------|---------|
| `number` | Blue | Numeric values |
| `trigger` | Orange | Execution flow (bang signals) |
| `object` | Purple | Complex objects |
| `array` | Cyan | Array data |
| `string` | Green | Text values |
| `dynamic` | Gray | Type determined at runtime |

### Hover and Activity States

Ports are not static rectangles. When you hover over a port, it highlights - and more importantly, every cable connected to that port highlights too. This visual feedback helps you trace data flow through complex patches.

In flow mode, ports also show activity visualization. A port receiving data pulses or animates, making the patch feel alive and helping you debug signal flow.

---

## Port Interaction Flow

Here is where things get interesting. Port interaction involves three classes working together: GlPort captures the initial click, GlPatch orchestrates the drag, and eventually GlLink handles the connection.

### Mouse Down: Starting the Drag

When you click on a port, GlPort does not immediately start drawing a line. Instead, it emits an event:

```javascript
_onMouseDown(e, _rect) {
    this.#glPatch.emitEvent(GlPatch.EVENT_MOUSE_DOWN_OVER_PORT,
        this, this.#glop.id, this.#port.name, e);
}
```

GlPatch receives this event and creates the temporary drag line - a GlDragLine instance that follows your cursor. This separation keeps GlPort simple: it only handles hit testing and event emission.

### During Drag: The Temporary Line

GlDragLine is a spline that renders in the overlay layer. It is not a real cable - it uses a simpler rendering path and updates its endpoint to track `viewBox.mousePatchX/Y` every frame:

```javascript
// GlDragLine conceptually:
this._x2 = viewBox.mousePatchX;
this._y2 = viewBox.mousePatchY;
this._splineDrawer.update();
```

The `isActive` flag tracks whether a drag is in progress. The overlay spline drawer keeps the drag line visually separated from permanent cables.

### Mouse Up: Creating the Connection

When you release the mouse over another port, GlPort emits the completion event:

```javascript
_onMouseUp(e, _rect) {
    // Right-click removes links instead of creating them
    if (performance.now() - this.#mouseButtonRightTimeDown < gluiconfig.clickMaxDuration) {
        this.#port.removeLinks();
        return;
    }
    this.#glPatch.emitEvent(GlPatch.EVENT_MOUSE_UP_OVER_PORT,
        this.#port.op.id, this.#port, e);
}
```

GlPatch receives this event, validates the connection (type compatibility, direction matching), and if valid, calls `gui.corePatch().link()` to create the actual Link in the data model. The drag line stops. A new GlLink + GlCable pair takes its place.

---

## GlLink: Bridging Data and Visuals

GlLink is the glue between a core Link and its visual GlCable. When a Link is created in the data model, the patch API creates a corresponding GlLink:

```javascript
constructor(glpatch, link, id, opIdInput, opIdOutput, ...) {
    this.#cable = new GlCable(this.#glPatch,
        this.#glPatch.getSplineDrawer(this._subPatch),
        this._buttonRect, this._type, this, this._subPatch);

    // Listen for operator movement
    this.#glOpIn.on("move", () => { this.update(); });
    this.#glOpOut.on("move", () => { this.update(); });
}
```

The key insight: GlLink subscribes to movement events from both connected operators. When either operator moves (dragged by the user), GlLink recalculates cable endpoints:

```javascript
_updatePosition() {
    this.#cable.setPosition(
        pos1x, pos1y,  // Input port position in patch space
        pos2x, pos2y   // Output port position in patch space
    );
}
```

This reactive pattern means cables "just work" when you rearrange operators. No manual refresh needed.

---

## GlCable: Bezier Curve Rendering

The actual curve rendering happens in GlCable. It supports four line types to match user preference:

| Type | Constant | Visual |
|------|----------|--------|
| Curved | `LINETYPE_CURVED = 0` | Smooth bezier curves (default) |
| Straight | `LINETYPE_STRAIGHT = 1` | Direct lines |
| Simple | `LINETYPE_SIMPLE = 2` | Less complex curves |
| Hanging | `LINETYPE_HANGING = 3` | Gravity-affected, drooping curves |

GlCable uses GlSplineDrawer for rendering, which batches many cables into a single draw call. When `setPosition(x1, y1, x2, y2)` is called, the cable recalculates its bezier control points based on the line type and endpoint distance.

### Cable Interaction

Cables are not just visuals - they are interactive. Hover over a cable and a button appears: click to insert an operator (splits the connection) or delete the cable entirely. This hover detection happens during the render loop, checking mouse distance to the bezier curve.

---

## Trace: Dragging from Output to Input

Let us walk through the complete flow of creating a connection.

**1. You click on an output port**

GlPort's `_onMouseDown()` fires. It emits `EVENT_MOUSE_DOWN_OVER_PORT` with port information.

**2. GlPatch starts the drag line**

```javascript
// In GlPatch's event handler:
this.portDragLine.start(portX, portY, port.type);
this.portDragLine.isActive = true;
```

The drag line anchors to the port position and begins tracking the mouse.

**3. You drag across the canvas**

Every frame, the drag line updates its endpoint to follow `mousePatchX/Y`. The spline redraws smoothly.

**4. You hover over a valid input port**

GlPort detects the hover and highlights. If the port type is incompatible, it may show a different highlight color or suggestion.

**5. You release the mouse**

GlPort's `_onMouseUp()` emits `EVENT_MOUSE_UP_OVER_PORT`.

**6. GlPatch validates and creates the link**

```javascript
// Simplified validation:
if (outputPort.type === inputPort.type || inputPort.type === "dynamic") {
    gui.corePatch().link(outputPort, inputPort);
}
```

**7. Core patch creates Link, triggers GlLink creation**

The data model Link triggers an event. GlPatchAPI receives it and creates a GlLink with a GlCable.

**8. Drag line stops, permanent cable appears**

```javascript
this.portDragLine.stop();
// GlLink + GlCable now render the connection
```

---

## Edge Cases and Gotchas

### Cross-Subpatch Connections

Cables.gl supports subpatches - patches within patches. When you connect ports across subpatch boundaries, the system actually creates *two* cables: one in each subpatch context. The visual representation differs from a same-subpatch connection.

### Reroute Dots

Sometimes you want to redirect a cable path for visual clarity. Reroute operators are special: they have one input and one output of the same type, and they exist purely to change cable routing. The system treats them as transparent pass-throughs for data flow.

### Long Ports

Some operators have ports that span multiple slots vertically (array inputs that can accept many connections, for instance). GlPort handles this with a `posCount` parameter that affects the hit test rectangle size and visual rendering.

### Right-Click to Disconnect

Notice the right-click check in `_onMouseUp()`. A quick right-click on a port removes all its links - a fast way to disconnect without hunting for cable buttons. The timing threshold (`clickMaxDuration`) distinguishes a click from a hold.

### Type Compatibility and Converters

When you try to connect incompatible ports (say, a number to a texture), the connection fails - but OpSelect can suggest converter operators. Drag from a number to a texture input, and the operator browser may offer "NumberToTexture" or similar conversion operators.

---

## What's Next

Ports and cables create the visual language of data flow, but what about the operators themselves? The next logical step is understanding how operators render their body, ports, title bar, and interactive states. See [GlOp: Operator Rendering](../glpatch/02-operator-rendering.md) for the visual representation of operators.

For deeper understanding of how the patch canvas coordinates all these elements, see [The Patch Canvas Architecture](../glpatch/01-patch-canvas.md).
