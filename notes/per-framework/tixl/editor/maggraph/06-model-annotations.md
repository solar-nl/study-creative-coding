# Chapter 6: MagGraphAnnotation - Frames and Labels

> *Colored rectangles that do more than you'd think*

---

## Why a Wrapper Class?

At first glance, annotations seem simple: colored rectangles with titles. The core `Annotation` class already handles this. Why wrap it?

The answer is the same reason we have `MagGraphItem` and `MagGraphConnection`: **animation and lifecycle tracking**.

When you drag an annotation, it shouldn't teleport - it should glide smoothly. When you resize it, the new dimensions should animate in. When you delete it, MagGraph needs to know it's gone without expensive list comparisons.

`MagGraphAnnotation` adds these capabilities while keeping the core `Annotation` class clean and focused on data storage.

**Source:** [MagGraphAnnotation.cs](../../../Editor/Gui/MagGraph/Model/MagGraphAnnotation.cs) (~40 lines)

---

## The Wrapper Pattern

The annotation wrapper follows the same pattern as other MagGraph view models:

```
┌─────────────────────────────────────────────────────────┐
│                    MagGraphAnnotation                    │
│              (View Model / UI Wrapper)                   │
├─────────────────────────────────────────────────────────┤
│  • Damped position/size for smooth animation             │
│  • Update cycle tracking for obsolescence detection      │
│  • Selection and snapping integration                    │
│                         ↓                                │
│  ┌─────────────────────────────────────────────────────┐│
│  │                    Annotation                        ││
│  │              (Core Data Model)                       ││
│  ├─────────────────────────────────────────────────────┤│
│  │  • Position and size                                 ││
│  │  • Title and color                                   ││
│  │  • Collapsed items tracking                          ││
│  └─────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────┘
```

---

## Class Definition

```csharp
internal sealed class MagGraphAnnotation : ISelectableCanvasObject, IValueSnapAttractor
{
    public required Annotation Annotation;
    public ISelectableCanvasObject Selectable => Annotation;

    // Position forwarding
    public Vector2 PosOnCanvas { get => Annotation.PosOnCanvas; set => Annotation.PosOnCanvas = value; }
    public Vector2 Size { get => Annotation.Size; set => Annotation.Size = value; }

    // Damped values for smooth animation
    public Vector2 DampedPosOnCanvas;
    public Vector2 DampedSize;

    public Guid Id { get; init; }

    // Lifecycle tracking
    public int LastUpdateCycle;
    public bool IsRemoved;
}
```

---

## Key Properties

### Identity

| Property | Type | Description |
|----------|------|-------------|
| `Id` | `Guid` | Unique identifier matching the underlying Annotation |
| `Annotation` | `Annotation` | The core data model |
| `Selectable` | `ISelectableCanvasObject` | Returns the Annotation for selection |

### Positioning

| Property | Type | Description |
|----------|------|-------------|
| `PosOnCanvas` | `Vector2` | Current position (forwards to Annotation) |
| `Size` | `Vector2` | Current size (forwards to Annotation) |
| `DampedPosOnCanvas` | `Vector2` | Smoothed position for animation |
| `DampedSize` | `Vector2` | Smoothed size for animation |

### Lifecycle

| Property | Type | Description |
|----------|------|-------------|
| `LastUpdateCycle` | `int` | When this annotation was last updated |
| `IsRemoved` | `bool` | Marked for removal |

---

## Value Snapping

Annotations participate in the value snapping system for alignment:

```csharp
void IValueSnapAttractor.CheckForSnap(ref SnapResult snapResult)
{
    if (snapResult.Orientation == SnapResult.Orientations.Horizontal)
    {
        snapResult.TryToImproveWithAnchorValue(DampedPosOnCanvas.X);
        snapResult.TryToImproveWithAnchorValue(DampedPosOnCanvas.X + DampedSize.X);
    }
    else if (snapResult.Orientation == SnapResult.Orientations.Vertical)
    {
        snapResult.TryToImproveWithAnchorValue(DampedPosOnCanvas.Y);
        snapResult.TryToImproveWithAnchorValue(DampedPosOnCanvas.Y + DampedSize.Y);
    }
}
```

This allows items to snap to annotation edges:

```
Horizontal Snapping:
                   ↓ (left edge)               ↓ (right edge)
┌──────────────────────────────────────────────────────────┐
│                     Annotation Frame                      │
│                                                           │
│   ┌─────────┐ ← Item snaps to left edge                  │
│   │ Operator│                                             │
│   └─────────┘                                             │
│                                                           │
└──────────────────────────────────────────────────────────┘

Vertical Snapping:
↓ (top edge)
┌──────────────────────────────────────────────────────────┐
│                     Annotation Frame                      │
│   ┌─────────┐                                             │
│   │ Operator│ ← Item snaps to top edge                   │
│   └─────────┘                                             │
↑ (bottom edge)
└──────────────────────────────────────────────────────────┘
```

---

## Collection in Layout

Annotations are collected in `MagGraphLayout.CollectedAnnotations`:

```csharp
private void CollectedAnnotations(SymbolUi compositionSymbolUi)
{
    Annotations.Clear();
    var addedCount = 0;
    var updatedCount = 0;

    foreach (var (annotationId, annotation) in compositionSymbolUi.Annotations)
    {
        if (Annotations.TryGetValue(annotationId, out var opItem))
        {
            updatedCount++;
            opItem.LastUpdateCycle = _structureUpdateCycle;
        }
        else
        {
            opItem = new MagGraphAnnotation
            {
                Id = annotation.Id,
                Annotation = annotation,
                DampedPosOnCanvas = annotation.PosOnCanvas,
                DampedSize = annotation.Size,
            };

            Annotations[annotationId] = opItem;
            addedCount++;
        }
    }

    // Remove obsolete annotations
    var hasObsoleteAnnotations = Annotations.Count > updatedCount + addedCount;
    if (!hasObsoleteAnnotations) return;

    foreach (var a in Annotations.Values)
    {
        if (a.LastUpdateCycle >= _structureUpdateCycle)
            continue;

        Annotations.Remove(a.Id);
        a.IsRemoved = true;
    }
}
```

---

## Damping Animation

Position and size damping is applied during the rendering phase:

```csharp
// In MagGraphView.SmoothPositions():
foreach (var annotation in _context.Layout.Annotations.Values)
{
    annotation.DampedPosOnCanvas = Vector2.Lerp(
        annotation.PosOnCanvas,
        annotation.DampedPosOnCanvas,
        dampAmount
    );

    annotation.DampedSize = Vector2.Lerp(
        annotation.Size,
        annotation.DampedSize,
        dampAmount
    );
}
```

The damping creates smooth transitions when:
- An annotation is created (animates from initial position)
- An annotation is moved (smoothly glides to new position)
- An annotation is resized (smoothly scales to new size)

---

## Relationship with Items

Items can be collapsed into annotations:

```csharp
// In MagGraphItem:
public bool IsCollapsedAway => ChildUi != null
    && ChildUi.CollapsedIntoAnnotationFrameId != Guid.Empty;
```

When collapsed:
- The item is rendered **inside** the annotation frame
- The item is not rendered at its normal canvas position
- Connections to/from the item still exist but may be drawn differently

```
Normal State:                    Collapsed State:

┌─────────────────┐              ┌─────────────────────────┐
│   Annotation    │              │      Annotation         │
│                 │              │  ┌─────────┐            │
│                 │              │  │   Op1   │ (collapsed)│
└─────────────────┘              │  ├─────────┤            │
                                 │  │   Op2   │ (collapsed)│
┌─────────┐  ┌─────────┐         │  └─────────┘            │
│   Op1   │  │   Op2   │         │                         │
└─────────┘  └─────────┘         └─────────────────────────┘
```

---

## Annotation States

Annotations support several interaction states through the state machine:

| State | Description |
|-------|-------------|
| `DragAnnotation` | Moving the annotation frame |
| `ResizeAnnotation` | Resizing the annotation frame |
| `RenameAnnotation` | Editing the annotation title |

These states handle the specific interaction logic for annotations.

---

## The Underlying Annotation Class

The core `Annotation` class (from `T3.Editor.UiModel`) contains:

```csharp
public class Annotation : ISelectableCanvasObject
{
    public Guid Id;
    public string Title;
    public Vector2 PosOnCanvas;
    public Vector2 Size;
    public Color Color;

    // Items collapsed into this annotation
    public HashSet<Guid> CollapsedItemIds;
}
```

The `MagGraphAnnotation` wrapper adds:
- **Damping** - Smooth position/size transitions
- **Lifecycle tracking** - Update cycle and removal state
- **Snap integration** - Edge snapping for items

---

## Next Steps

- **[State Machine](07-state-machine.md)** - Annotation interaction states
- **[Rendering Annotations](17-rendering-annotations.md)** - How frames are drawn
- **[Interaction Annotations](12-interaction-annotations.md)** - Drag and resize behavior
