# Appendix C: Legacy Comparison

> *Why a rewrite was necessary, and what changed*

---

## Why Rewrite the Graph Editor?

The original Tooll3 graph editor worked, but had accumulated architectural debt:

- **All-in-one file** - 3,000+ lines of tangled rendering and interaction
- **Implicit state** - Boolean flags scattered throughout, hard to trace
- **Per-frame computation** - Everything recalculated constantly, even static graphs
- **Hard to extend** - Adding features meant touching many unrelated places

MagGraph addressed these by starting fresh with deliberate architecture. This appendix documents what changed and why.

---

## Architecture Comparison

### Legacy System

```
┌─────────────────────────────────────────────────────────┐
│                    Legacy Graph                          │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  • Direct rendering from Symbol data                     │
│  • Dictionary lookups during draw                        │
│  • Implicit state through local variables                │
│  • Connection routing calculated per-frame               │
│  • Scattered interaction handling                        │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### MagGraph System

```
┌─────────────────────────────────────────────────────────┐
│                    MagGraph                              │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  • Cached view model (MagGraphLayout)                   │
│  • Pre-computed item references                          │
│  • Explicit state machine                                │
│  • Connection styles computed on structure change        │
│  • Centralized interaction in states                     │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

---

## Key Differences

### 1. View Model

| Legacy | MagGraph |
|--------|----------|
| Direct Symbol iteration | Cached `MagGraphLayout` |
| Dictionary lookups | Pre-built references |
| Computed per frame | Computed on change |

**Legacy:**
```csharp
foreach (var child in compositionOp.Children)
{
    if (!childUis.TryGetValue(child.Key, out var childUi))
        continue;
    // Draw...
}
```

**MagGraph:**
```csharp
foreach (var item in layout.Items.Values)
{
    // Item already has all references
    DrawNode(item);
}
```

### 2. Connections

| Legacy | MagGraph |
|--------|----------|
| Drawn as curves always | Snapped = invisible |
| Route calculation per frame | Style computed once |
| No grouping concept | Items snap together |

**Legacy:**
```csharp
// Always draw curve
DrawBezier(sourcePos, targetPos, typeColor);
```

**MagGraph:**
```csharp
if (connection.IsSnapped)
    return;  // Items are touching, no curve needed

DrawBezier(connection.DampedSourcePos, connection.DampedTargetPos, typeColor);
```

### 3. Interaction

| Legacy | MagGraph |
|--------|----------|
| Scattered in Draw methods | Centralized in States |
| Implicit via flags | Explicit state machine |
| Hard to track state | Clear state transitions |

**Legacy:**
```csharp
// In GraphCanvas.Draw():
if (_isDragging)
{
    HandleDrag();
}
else if (_isConnecting)
{
    HandleConnection();
}
// Many nested conditions...
```

**MagGraph:**
```csharp
// State handles everything
internal static State<GraphUiContext> DragItems = new(
    Enter: context => { /* setup */ },
    Update: context => { /* per-frame */ },
    Exit: context => { /* cleanup */ }
);
```

### 4. Operator Browser

| Legacy | MagGraph |
|--------|----------|
| Separate popup window | Inline placeholder item |
| Modal dialog | Part of canvas |
| Search only | Tree + search |

### 5. Item Movement

| Legacy | MagGraph |
|--------|----------|
| Move single item | Move snapped groups |
| No magnetic snap | Automatic snapping |
| No insertion | Splice into connections |
| Manual disconnect | Shake to disconnect |

---

## Feature Comparison

| Feature | Legacy | MagGraph |
|---------|--------|----------|
| Zoom/Pan | ✓ | ✓ |
| Drag operators | ✓ | ✓ (with snapping) |
| Drag connections | ✓ | ✓ |
| Operator browser | Popup | Inline |
| Multi-selection | ✓ | ✓ |
| Copy/Paste | ✓ | ✓ |
| Undo/Redo | ✓ | ✓ |
| Annotations | ✓ | ✓ |
| Magnetic snapping | ✗ | ✓ |
| Grouped movement | ✗ | ✓ |
| Connection insertion | ✗ | ✓ |
| Shake disconnect | ✗ | ✓ |
| Long-press creation | ✗ | ✓ |
| Position damping | ✗ | ✓ |
| Collapsed items | ✗ | ✓ |

---

## Performance Comparison

| Metric | Legacy | MagGraph |
|--------|--------|----------|
| 100 operators | ~60fps | ~60fps |
| 500 operators | ~30fps | ~55fps |
| 1000 operators | ~15fps | ~45fps |

MagGraph's cached layout and visibility culling provide significant improvements at scale.

---

## Migration Notes

### SymbolBrowser → PlaceholderCreation

Legacy:
```csharp
SymbolBrowser.Open(position, filterType);
```

MagGraph:
```csharp
context.Placeholder.OpenOnCanvas(context, position, filterType);
context.StateMachine.SetState(GraphStates.Placeholder, context);
```

### Direct Position Changes → Commands

Legacy:
```csharp
childUi.PosOnCanvas = newPos;
```

MagGraph:
```csharp
var command = new ModifyCanvasElementsCommand(symbolId, items, selection);
// Make changes...
command.StoreCurrentValues();
UndoRedoStack.Add(command);
```

### Connection Creation

Legacy:
```csharp
symbol.AddConnection(connection, 0);
```

MagGraph:
```csharp
context.MacroCommand.AddAndExecCommand(
    new AddConnectionCommand(symbol, connection, 0)
);
```

---

## Coexistence

Both systems currently coexist in Tooll3:

- Legacy: `Editor/Gui/Graph/` directory
- MagGraph: `Editor/Gui/MagGraph/` directory

The active system is selected via user settings or feature flags.

---

## Future Direction

MagGraph is designed to eventually replace the legacy system entirely. Key remaining work:

- Complete feature parity for edge cases
- Tour/tutorial system integration
- Performance optimization for very large graphs
- Additional keyboard shortcuts
- Accessibility improvements
