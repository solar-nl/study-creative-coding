# GlPatch Subsystem

> *The WebGL-powered canvas where operators live and connect*

---

## Overview

The GlPatch subsystem is the visual heart of cables.gl. It renders operators, handles pan/zoom navigation, manages selection, and coordinates all canvas-level interactions.

---

## Chapters

| # | Chapter | Description |
|---|---------|-------------|
| 01 | [The Patch Canvas Architecture](01-patch-canvas.md) | WebGL rendering, viewbox, instancing |
| 02 | [Operators & Visual Rendering](02-operator-rendering.md) | GlOp, ports, selection states |

---

## Key Concepts

### Rendering Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    GlPatch                               │
│                                                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ GlRectInst.  │  │ GlSplineDraw │  │ GlTextWriter │  │
│  │ (batched     │  │ (bezier      │  │ (text        │  │
│  │  rectangles) │  │  cables)     │  │  labels)     │  │
│  └──────────────┘  └──────────────┘  └──────────────┘  │
│         │                │                 │            │
│         ▼                ▼                 ▼            │
│  ┌─────────────────────────────────────────────────┐   │
│  │              WebGL 2.0 Context                   │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### GPU Instancing

The key to performance with hundreds of operators:
- **GlRectInstancer** batches all rectangles in one draw call
- Position, size, color uploaded as attributes
- GPU handles the multiplication

### Coordinate Systems

- **Screen space** - Pixel coordinates from mouse events
- **Patch space** - World coordinates for operators
- **GlViewBox** - Manages the transformation between them

---

## Source Files

| File | LOC | Purpose |
|------|-----|---------|
| `glpatch/glpatch.js` | ~2077 | Main canvas, event handling, selection |
| `glpatch/glop.js` | ~400 | Individual operator rendering |
| `glpatch/glviewbox.js` | ~400 | Pan, zoom, coordinate transforms |
| `glpatch/mousestate.js` | ~200 | Button state tracking |
| `gldraw/glrectinstancer.js` | ~700 | GPU-instanced rectangle rendering |
| `gldraw/glsplinedrawer.js` | ~400 | Bezier spline rendering for cables |

---

## Mental Model

Think of GlPatch as a **drawing program's canvas**:
- You can pan and zoom to navigate
- Objects (operators) live in world coordinates
- The viewport transforms world to screen
- All rendering is batched for performance

The key insight is **everything is rectangles**. Operators, ports, selection boxes, even text backgrounds - all rectangles batched through GlRectInstancer. Cables are the exception - they use GlSplineDrawer for smooth bezier curves.

---

## Related Subsystems

- **OpSelect** - How operators get added to the canvas
- **Connections** - How cables are drawn and managed
- **Commands** - How operator creation integrates with undo/redo
