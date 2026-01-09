# Connections Subsystem

> *Ports, cables, and the visual language of data flow*

---

## Overview

The Connections subsystem handles how operators link together. It manages ports (the connection points on operators), cables (the visual connections), and the drag-to-connect interaction.

---

## Chapters

| # | Chapter | Description |
|---|---------|-------------|
| 01 | [Ports & Visual Connections](01-ports-connections.md) | GlPort, GlLink, GlCable, drag-to-connect flow |
| 02 | Cables & Bezier Rendering (planned) | Deep dive into bezier math, cable styles, hover detection |

---

## Key Concepts

### Connection Data Flow

```
User drags port
       │
       ▼
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   GlPort    │────▶│ GlDragLine  │────▶│   GlPatch   │
│ mousedown   │     │  follows    │     │ mouseup     │
│             │     │  cursor     │     │ over port   │
└─────────────┘     └─────────────┘     └──────┬──────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │ gui.core    │
                                        │ Patch.link()│
                                        └──────┬──────┘
                                               │
                                               ▼
                                        ┌─────────────┐
                                        │   GlLink    │
                                        │ + GlCable   │
                                        └─────────────┘
```

### Port Types

Cables.gl supports multiple port types, each with its own color:

| Type | Purpose |
|------|---------|
| `number` | Numeric values |
| `trigger` | Execution flow (bang) |
| `object` | Complex objects |
| `array` | Array data |
| `string` | Text values |
| `dynamic` | Type determined at runtime |

### Cable Rendering

Cables are bezier splines with four possible styles:
- **Curved** (default) - Smooth bezier curves
- **Straight** - Direct lines
- **Simple** - Less complex curves
- **Hanging** - Gravity-affected curves

---

## Source Files

| File | LOC | Purpose |
|------|-----|---------|
| `glpatch/glport.js` | ~490 | Port rendering, interaction |
| `glpatch/gllink.js` | ~785 | Connection management |
| `glpatch/glcable.js` | ~400 | Visual bezier cable |
| `glpatch/gldragline.js` | ~150 | Temporary drag line |

---

## Mental Model

Think of connections as a **three-layer system**:

1. **Ports** - The connectors on operators (like USB ports)
2. **Links** - The logical connection (the data model)
3. **Cables** - The visual representation (the rendered curve)

When you drag from a port, you create a temporary `GlDragLine`. When you release on a valid port, the system creates a `Link` in the data model, then a `GlLink` + `GlCable` to visualize it.

---

## Related Subsystems

- **GlPatch** - Where connections are rendered
- **OpSelect** - Suggests compatible operators when dragging
- **Commands** - Connection undo/redo
