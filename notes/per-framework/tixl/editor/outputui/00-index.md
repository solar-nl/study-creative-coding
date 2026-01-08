# OutputUi Technical Documentation

> **Type-Driven Output Visualization System**
>
> *Rendering operator outputs in the Tooll3 Editor*

**Part of:** [Editor Documentation](../00-architecture.md) | [Progress Tracker](../PROGRESS.md)

---

## About This Documentation

The OutputUi system handles visualization of operator output values. It uses a generic factory pattern to dispatch rendering based on data type, providing specialized viewers for textures, curves, lists, commands, and more.

**Total Size:** ~2,500 LOC across 24 files

**Location:** `Editor/Gui/OutputUi/`

---

## Documentation Structure

### Core Architecture

| Chapter | Title | Description |
|---------|-------|-------------|
| [01](01-architecture-overview.md) | Architecture Overview | System design and data flow |
| [02](02-factory-pattern.md) | Factory Pattern | GenericFactory and type registration |
| [03](03-base-classes.md) | Base Classes | IOutputUi, OutputUi<T>, and inheritance |

### Output Type Implementations

| Chapter | Title | Description |
|---------|-------|-------------|
| [04](04-scalar-outputs.md) | Scalar Outputs | Float, bool, string, vectors |
| [05](05-texture-outputs.md) | Texture Outputs | Texture2D, Texture3D, ShaderResourceView |
| [06](06-collection-outputs.md) | Collection Outputs | Lists, dictionaries, structured data |
| [07](07-command-rendering.md) | Command Rendering | Full rendering pipeline for Command type |

### Extension

| Chapter | Title | Description |
|---------|-------|-------------|
| [08](08-extending-outputui.md) | Extending OutputUi | Adding new output type renderers |

---

## Quick Reference

### Factory Usage

```csharp
// Create OutputUi for any type
var outputUi = OutputUiFactory.Instance.CreateFor(typeof(float));

// Draw the output value
outputUi.DrawValue(slot, context, viewId, recompute: true);
```

### Type Registration

```csharp
// In UiRegistration.cs
OutputUiFactory.Instance.AddFactory(typeof(MyType), () => new MyTypeOutputUi());
```

### Creating a Custom OutputUi

```csharp
internal sealed class MyTypeOutputUi : OutputUi<MyType>
{
    public override IOutputUi Clone() => new MyTypeOutputUi
    {
        OutputDefinition = OutputDefinition,
        PosOnCanvas = PosOnCanvas,
        Size = Size
    };

    protected override void DrawTypedValue(ISlot slot, string viewId)
    {
        if (slot is not Slot<MyType> typedSlot) return;

        var value = typedSlot.Value;
        // Render with ImGui...
    }
}
```

---

## Supported Output Types

### Scalar Types

| Type | OutputUi Class | Visualization |
|------|----------------|---------------|
| `float` | `FloatOutputUi` | Curve plot (500 samples) |
| `bool` | `BoolOutputUi` | 0/1 curve plot |
| `string` | `StringOutputUi` | Line-numbered text |
| `Vector2/3/4` | `VectorOutputUi<T>` | Multi-channel curves |
| `Quaternion` | `VectorOutputUi<Quaternion>` | XYZW curves |

### Texture Types

| Type | OutputUi Class | Visualization |
|------|----------------|---------------|
| `Texture2D` | `Texture2dOutputUi` | Image canvas with pan/zoom |
| `Texture3dWithViews` | `Texture3dOutputUi` | Z-slice viewer |
| `ShaderResourceView` | `ShaderResourceViewOutputUi` | Minimal (WIP) |

### Collection Types

| Type | OutputUi Class | Visualization |
|------|----------------|---------------|
| `List<float>` | `FloatListOutputUi` | Grid/Plot view modes |
| `List<int>` | `IntListOutputUi` | Grid/Plot view modes |
| `List<string>` | `StringListOutputUi` | Scrollable list |
| `Dict<float>` | `FloatDictOutputUi` | Multi-channel plot |
| `Point[]` | `PointArrayOutputUi` | Position list |
| `StructuredList` | `StructuredListOutputUi` | Editable table |

### Complex Types

| Type | OutputUi Class | Visualization |
|------|----------------|---------------|
| `Command` | `CommandOutputUi` | Full render pipeline |
| `DataSet` | `DataSetOutputUi` | Timeline event viewer |
| `SceneSetup` | `SceneSetupOutputUi` | Hierarchy tree |
| `BufferWithViews` | `BufferWithViewsOutputUi` | Metadata display |

### Fallback

| Type | OutputUi Class | Visualization |
|------|----------------|---------------|
| Any other | `ValueOutputUi<T>` | Type name + ToString() |

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         Operator Output Slot                             │
│                            (ISlot<T>)                                    │
└─────────────────────────────────┬───────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                      OutputUiFactory.CreateFor(Type)                     │
│                         (GenericFactory<IOutputUi>)                      │
├─────────────────────────────────────────────────────────────────────────┤
│  Type Registry:                                                          │
│  ┌────────────┬─────────────────────┐                                   │
│  │ float      │ FloatOutputUi       │                                   │
│  │ Texture2D  │ Texture2dOutputUi   │                                   │
│  │ Command    │ CommandOutputUi     │                                   │
│  │ ...        │ ...                 │                                   │
│  │ (default)  │ ValueOutputUi<T>    │                                   │
│  └────────────┴─────────────────────┘                                   │
└─────────────────────────────────┬───────────────────────────────────────┘
                                  │
                                  ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                           IOutputUi Instance                             │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                          │
│  DrawValue(slot, context, viewId, recompute)                            │
│      │                                                                   │
│      ├─── Recompute(slot, context)  ←── if recompute=true               │
│      │        │                                                          │
│      │        ├─── StartInvalidation(slot)                              │
│      │        └─── slot.Update(context)  [Evaluate operator]            │
│      │                                                                   │
│      └─── DrawTypedValue(slot, viewId)                                  │
│               │                                                          │
│               ├─── Extract Slot<T>.Value                                │
│               ├─── Per-view settings (ConditionalWeakTable)             │
│               └─── Render to ImGui                                       │
│                                                                          │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Key Source Files

| File | Lines | Purpose |
|------|-------|---------|
| `OutputUi.cs` | ~120 | Abstract base class |
| `IOutputUi.cs` | ~20 | Interface definition |
| `OutputUiFactory.cs` | ~15 | Factory singleton |
| `CommandOutputUi.cs` | ~200 | Render pipeline |
| `FloatOutputUi.cs` | ~80 | Curve plotting |
| `Texture2dOutputUi.cs` | ~50 | Image display |
| `DataSetOutputUi.cs` | ~680 | Event timeline |

---

## Related Systems

- **[InputUi](../inputui/)** - Parameter input widgets (mirror pattern)
- **[UiModel/SymbolUi](../uimodel/)** - OutputUi storage and serialization
- **[Graph](../graph/)** - OutputUi selection and display
- **[ImageOutputCanvas](../windows/)** - Texture viewing infrastructure

---

## Next Steps

Start with [Chapter 1: Architecture Overview](01-architecture-overview.md) for the complete system design.

