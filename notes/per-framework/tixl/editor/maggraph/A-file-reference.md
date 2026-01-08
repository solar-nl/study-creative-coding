# Appendix A: File Reference

> *Where to find what you're looking for*

This appendix maps MagGraph's ~11,000 lines of code across 29 files. Use it when you know what you want to modify but need to find the right file.

---

## Directory Structure

```
Editor/Gui/MagGraph/
├── Model/                      # Data structures (~2,600 LOC)
│   ├── MagGraphItem.cs         # Unified node abstraction
│   ├── MagGraphConnection.cs   # Connection data model
│   ├── MagGraphLayout.cs       # Cached view model
│   └── MagGraphAnnotation.cs   # Annotation wrapper
│
├── States/                     # State machine (~1,300 LOC)
│   ├── GraphStates.cs          # All interaction states
│   ├── GraphUiContext.cs       # Central context object
│   └── StateMachine.cs         # Generic state machine
│
├── Interaction/                # User interaction (~5,000 LOC)
│   ├── MagItemMovement.cs      # Drag, snap, insert
│   ├── MagItemMovement.Snapping.cs  # Snap detection
│   ├── PlaceholderCreation.cs  # Operator browser controller
│   ├── PlaceHolderUi.cs        # Browser UI drawing
│   ├── SymbolBrowsing.cs       # Symbol tree navigation
│   ├── InputSnapper.cs         # Find snap targets (inputs)
│   ├── OutputSnapper.cs        # Find snap targets (outputs)
│   ├── InputPicking.cs         # Hidden input selector
│   ├── OutputPicking.cs        # Hidden output selector
│   ├── ConnectionHovering.cs   # Wire hover detection
│   ├── KeyboardActions.cs      # Keyboard shortcuts
│   ├── GraphContextMenu.cs     # Right-click menu
│   ├── AnnotationDragging.cs   # Move annotations
│   ├── AnnotationResizing.cs   # Resize annotations
│   ├── AnnotationRenaming.cs   # Edit annotation titles
│   ├── RenamingOperator.cs     # Edit operator names
│   ├── Modifications.cs        # Delete, duplicate helpers
│   └── TourInteraction.cs      # Tutorial tour support
│
└── Ui/                         # Rendering (~2,100 LOC)
    ├── MagGraphView.cs         # Main canvas view
    ├── MagGraphCanvas.Drawing.cs    # Frame drawing
    └── MagGraphCanvas.DrawNode.cs   # Node drawing
```

---

## File Details

### Model Layer

| File | Lines | Description |
|------|-------|-------------|
| `MagGraphItem.cs` | ~370 | Unified item abstraction with variants |
| `MagGraphConnection.cs` | ~100 | Connection styles and conversion |
| `MagGraphLayout.cs` | ~930 | Layout computation and caching |
| `MagGraphAnnotation.cs` | ~40 | Annotation wrapper with damping |

### State Machine Layer

| File | Lines | Description |
|------|-------|-------------|
| `GraphStates.cs` | ~730 | All 17+ interaction states |
| `GraphUiContext.cs` | ~260 | Central context and state |
| `StateMachine.cs` | ~100 | Generic state machine implementation |

### Interaction Layer

| File | Lines | Description |
|------|-------|-------------|
| `MagItemMovement.cs` | ~1500 | Core movement logic |
| `MagItemMovement.Snapping.cs` | ~240 | Snap detection helpers |
| `PlaceholderCreation.cs` | ~400 | Browser state management |
| `PlaceHolderUi.cs` | ~600 | Browser UI drawing |
| `SymbolBrowsing.cs` | ~300 | Namespace tree navigation |
| `InputSnapper.cs` | ~150 | Input snap detection |
| `OutputSnapper.cs` | ~150 | Output snap detection |
| `InputPicking.cs` | ~200 | Hidden input UI |
| `OutputPicking.cs` | ~100 | Hidden output UI |
| `ConnectionHovering.cs` | ~150 | Wire hover tracking |
| `KeyboardActions.cs` | ~300 | Keyboard handling |
| `GraphContextMenu.cs` | ~250 | Context menu |
| `AnnotationDragging.cs` | ~100 | Annotation drag |
| `AnnotationResizing.cs` | ~200 | Annotation resize |
| `AnnotationRenaming.cs` | ~150 | Annotation rename |
| `RenamingOperator.cs` | ~100 | Operator rename |
| `Modifications.cs` | ~200 | Helper functions |
| `TourInteraction.cs` | ~100 | Tour support |

### Rendering Layer

| File | Lines | Description |
|------|-------|-------------|
| `MagGraphView.cs` | ~800 | Canvas and transform |
| `MagGraphCanvas.Drawing.cs` | ~400 | Connection rendering |
| `MagGraphCanvas.DrawNode.cs` | ~600 | Node rendering |

---

## Key Classes Quick Reference

### Data Model

```csharp
MagGraphItem           // Node on canvas
MagGraphConnection     // Wire between nodes
MagGraphLayout         // Cached view model
MagGraphAnnotation     // Frame wrapper
```

### State Machine

```csharp
GraphUiContext         // Central context
StateMachine<T>        // Generic state machine
State<T>               // State definition
GraphStates            // All state instances
```

### Interaction

```csharp
MagItemMovement        // Drag and snap
PlaceholderCreation    // Operator browser
ConnectionHovering     // Wire interaction
KeyboardActions        // Shortcuts
```

### Rendering

```csharp
MagGraphView           // Main canvas
ScalableCanvas         // Base class for zoom/pan
```

---

## Import Dependencies

### External

- `ImGuiNET` - UI rendering
- `System.Numerics` - Vector2 math
- `T3.Core.Operator` - Symbol and Instance

### Internal

- `T3.Editor.Gui.Interaction` - Snapping helpers
- `T3.Editor.Gui.UiHelpers` - UI utilities
- `T3.Editor.UiModel` - SymbolUi, Commands
- `T3.Editor.UiModel.Selection` - NodeSelection

---

## Total Line Count

| Layer | Lines |
|-------|-------|
| Model | ~1,440 |
| States | ~1,090 |
| Interaction | ~4,900 |
| Rendering | ~1,800 |
| **Total** | **~11,230** |
