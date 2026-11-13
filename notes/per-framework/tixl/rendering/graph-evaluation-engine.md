# tixl — Graph Evaluation Engine

## Key Insight

> **tixl's rendering pipeline IS graph evaluation.** There is no separate renderer — the graph executor walks the operator tree, and operators issue GPU calls inline during their `UpdateAction`. Understanding the evaluation engine is understanding how every frame gets rendered.

## Overview

This document covers the foundational graph machinery that sits below tixl's rendering layer: the evaluation loop, slot types, dirty flag system, and connection model. The rendering documents ([command-nodes.md](command-nodes.md), [compound-mechanics.md](compound-mechanics.md), [overview.md](overview.md)) describe what operators *do* with GPU state. This document describes how and when those operators get *called*.

The evaluation engine has four interlocking subsystems:

1. **The evaluation loop** — a two-phase pull model (invalidate upstream, then evaluate downstream)
2. **The slot system** — typed ports with swappable update delegates
3. **The dirty flag system** — counter-based version tracking with diamond-graph deduplication
4. **The connection model** — GUID-based definitions resolved lazily to direct slot pointers

```
FRAME START
    │
    ▼
┌────────────────────────────────────────────┐
│  Phase 1: Invalidation Pass (upstream)     │
│  rootOutput.Invalidate()                   │
│  Walks from root toward leaves,            │
│  propagating Target version counters       │
└────────────────────────────────────────────┘
    │
    ▼
┌────────────────────────────────────────────┐
│  Phase 2: Evaluation Pass (downstream)     │
│  rootOutput.GetValue(context)              │
│  Pulls from root, re-executing only        │
│  operators whose slots are dirty           │
│  (Reference != Target)                     │
└────────────────────────────────────────────┘
    │
    ▼
FRAME END → SwapChain.Present()
```

---

## Q1: How Does GetValue / DirtyFlag Caching Work?

### The DirtyFlag Data Structure

The dirty flag is not a boolean. It is a **counter comparison** system: two integers that track whether a slot has seen the latest version of its inputs.

**`Core/Operator/Slots/DirtyFlag.cs:6`**:

```csharp
public sealed class DirtyFlag
{
    public bool IsDirty => TriggerIsEnabled || Reference != Target;

    public int Reference;       // "last version I evaluated with"
    public int Target = 1;      // "current version" (starts at 1 → initially dirty)

    public static int InvalidationRefFrame = 0;   // global frame epoch
    internal int InvalidatedWithRefFrame = -1;     // last epoch this slot was visited

    public int Invalidate()
    {
        if (InvalidationRefFrame != InvalidatedWithRefFrame)
        {
            InvalidatedWithRefFrame = InvalidationRefFrame;
            Target++;
        }
        return Target;
    }

    public void Clear() { Reference = Target; }
}
```

`IsDirty` means "I haven't evaluated the current version yet" (`Reference != Target`), or "I'm forced always-dirty" (`TriggerIsEnabled`). `Target` starts at 1, `Reference` starts at 0, so every slot is dirty on first access.

The `InvalidatedWithRefFrame` guard prevents double-counting in diamond graphs. If slot A feeds both B and C, and both B and C feed D, then D's invalidation pass reaches A twice. The guard ensures `A.Invalidate()` increments `Target` only once per frame.

**`Core/Operator/Slots/DirtyFlagTrigger.cs:6`**:

```csharp
[Flags]
public enum DirtyFlagTrigger : byte
{
    None     = 0,
    Always   = 0x1,   // random generators, real-time inputs
    Animated = 0x2,   // animated parameters, time-dependent values
}
```

Slots with `Always` or `Animated` triggers have `TriggerIsEnabled = true`, making `IsDirty` always return `true` regardless of the counter state.

### The Slot.Update() Hot Path

**`Core/Operator/Slots/Slot.cs:159`**:

```csharp
[MethodImpl(MethodImplOptions.AggressiveInlining)]
public void Update(EvaluationContext context)
{
    if (_dirtyFlag.IsDirty || _valueIsCommand)
    {
        OpUpdateCounter.CountUp();
        UpdateAction?.Invoke(context);
        _dirtyFlag.Clear();
        _dirtyFlag.SetUpdated();
    }
}
```

`_valueIsCommand` is set in the constructor when `T == typeof(Command)`. Command slots always re-execute regardless of their dirty flag — they carry GPU side effects, not cacheable values.

### GetValue: The Pull Entry Point

**`Core/Operator/Slots/Slot.cs:181`**:

```csharp
public T? GetValue(EvaluationContext context)
{
    Update(context);
    return Value;
}
```

`GetValue` = "ensure this slot is current, then return its value." `Value` is a plain `T` field — no boxing for value types because `Slot<T>` is generic.

### ConnectedUpdate: What Happens When a Wire Exists

When an input slot is connected to an upstream output, `AddConnection` replaces its `UpdateAction` with `ConnectedUpdate`:

**`Core/Operator/Slots/Slot.cs:171`**:

```csharp
public void ConnectedUpdate(EvaluationContext context)
{
    Value = InputConnections[0].GetValue(context)!;
}
```

This is the pull: the input calls `GetValue` on the upstream output, which calls `Update` on that output, which invokes the parent operator's `UpdateAction`. The chain recurses upstream through the graph.

### Operator Update Registration

Operators don't have a virtual `Update()` method. Instead, they register a delegate on their output slot in the constructor:

**`Operators/Lib/Symbols/flow/Execute.cs:11`**:

```csharp
public Execute()
{
    Output.UpdateAction += Update;
}
```

When `Output.GetValue(context)` is called, it calls `Output.Update(context)`, which calls `Output.UpdateAction(context)`, which IS `Execute.Update(context)`. The operator's logic runs as a side effect of pulling on its output slot.

### The Two-Phase Frame Loop

**`Player/Program.RenderLoop.cs:41`**:

```csharp
DirtyFlag.IncrementGlobalTicks();
DirtyFlag.InvalidationRefFrame++;

_evalContext.Reset();
_evalContext.RequestedResolution = _resolution;

_textureOutput.Invalidate();                          // Phase 1
var outputTexture = _textureOutput.GetValue(_evalContext);  // Phase 2
```

Phase 1 (`Invalidate`) walks the graph upstream from the root output, propagating `Target` version numbers. Phase 2 (`GetValue`) walks the graph downstream, re-executing any operator whose output slot has `Reference != Target`.

### The Invalidation Walk

**`Core/Operator/Slots/Slot.cs:269`**:

```csharp
public int Invalidate()
{
    var refFrame = DirtyFlag.InvalidationRefFrame;
    if (refFrame == _dirtyFlag.InvalidatedWithRefFrame)
        return _dirtyFlag.Target;    // already visited this epoch — stop

    // Special slot types (MultiInput, TimeClip) override
    if (HasInvalidationOverride)
    {
        var target = InvalidationOverride();
        _dirtyFlag.Target = target;
        _dirtyFlag.InvalidatedWithRefFrame = refFrame;
        return target;
    }

    // Connected slot: forward upstream and inherit their target
    if (InputConnections.Length > 0)
    {
        var target = InputConnections[0].Invalidate();
        _dirtyFlag.Target = target;
        _dirtyFlag.InvalidatedWithRefFrame = refFrame;
        return target;
    }

    // Unconnected input slot: check its own trigger
    if (_isInputSlot)
    {
        if (_dirtyFlag.TriggerIsEnabled)
            return _dirtyFlag.Invalidate();
        _dirtyFlag.InvalidatedWithRefFrame = refFrame;
        return _dirtyFlag.Target;
    }

    // Unconnected output slot (operator leaf): aggregate all parent's inputs
    var parentInputs = _parent.Inputs;
    bool outputDirty = _dirtyFlag.IsDirty;
    for (var i = 0; i < parentInputs.Count; i++)
    {
        var input = parentInputs[i];
        input.Invalidate();
        outputDirty |= input.IsDirty;
    }
    if (outputDirty)
        return _dirtyFlag.Invalidate();

    _dirtyFlag.InvalidatedWithRefFrame = refFrame;
    return _dirtyFlag.Target;
}
```

Key behavior: an unconnected output slot checks all of its parent operator's inputs. If any input is dirty, the output is dirty too. This is how changes propagate from inputs through an operator to its outputs.

### Dirty Propagation Direction: Pull, Not Push

The system is **pull-based with a preparatory invalidation pass**. Setting an input value does not immediately notify downstream consumers. Instead:

1. Editor calls `DirtyFlag.Invalidate()` on the changed input slot
2. Next frame, the render loop calls `rootOutput.Invalidate()` which recurses upstream
3. The invalidation pass discovers the changed input and marks dependent outputs dirty
4. `GetValue` from the root then re-evaluates dirty outputs

There is no push notification, no subscriber list, no event dispatch. The traversal always starts from the root and walks inward.

### Cost Model

- **Per-frame allocation**: Zero for the core evaluation path. `Value` is a typed field on `Slot<T>` — no boxing. `EvaluationContext` is created once and reused. `InputConnections` is a plain `Slot<T>[]` array.
- **Dirty check cost**: Two integer comparisons per slot per frame, marked `[AggressiveInlining]`.
- **Command slots**: Bypass the cache entirely, re-invoking `UpdateAction` every frame unconditionally.
- **Animated slots**: `TriggerIsEnabled = true` makes them always-dirty, like Command slots but for value types.

---

## Q2: How Does MultiInputSlot Work?

### Class Definition

**`Core/Operator/Slots/MultiInputSlot.cs:10`**:

```csharp
public sealed class MultiInputSlot<T> : InputSlot<T>, IMultiInputSlot
{
    public List<Slot<T>> CollectedInputs => _collectedInputs;
    private readonly List<Slot<T>> _collectedInputs = new(10);
    public int[] LimitMultiInputInvalidationToIndices = [];
}
```

`MultiInputSlot<T>` inherits `InputSlot<T>` which inherits `Slot<T>`. Its `InputConnections[]` array grows as connections are added. The `_collectedInputs` list is a cached, flattened view rebuilt only when dirty.

### GetCollectedTypedInputs: Flattening Nested Multi-Inputs

**`Core/Operator/Slots/MultiInputSlot.cs:21`**:

```csharp
public List<Slot<T>> GetCollectedTypedInputs(bool forceRefresh = false)
{
    if (!forceRefresh && !DirtyFlag.IsDirty)
        return _collectedInputs;

    _collectedInputs.Clear();
    for (var i = 0; i < InputConnections.Length; i++)
    {
        var slot = InputConnections[i];
        if (slot.TryGetAsMultiInputTyped(out var multiInput))
            _collectedInputs.AddRange(multiInput.GetCollectedTypedInputs());
        else
            _collectedInputs.Add(slot);
    }
    return _collectedInputs;
}
```

If a `MultiInputSlot` is wired to another `MultiInputSlot`, the nested sources are flattened into one list. The result is cached — no allocation on clean frames.

### How Execute Uses It

**`Operators/Lib/Symbols/flow/Execute.cs:14`**:

```csharp
private void Update(EvaluationContext context)
{
    var commands = Command.CollectedInputs;
    if (IsEnabled.GetValue(context))
    {
        for (int i = 0; i < commands.Count; i++)
            commands[i].Value?.PrepareAction?.Invoke(context);

        for (int i = 0; i < commands.Count; i++)
            commands[i].GetValue(context);

        for (int i = 0; i < commands.Count; i++)
            commands[i].Value?.RestoreAction?.Invoke(context);
    }
    Command.DirtyFlag.Clear();
}
```

Execute reads `Command.CollectedInputs` — the pre-flattened list. The three-pass loop (Prepare → Execute → Restore) is the rendering protocol. `GetValue` on each slot triggers upstream evaluation.

### Order: Deterministic by Connection Order

Order is the order of entries in `Symbol.Connections` in the `.t3` JSON, which is the order connections were created. `AddConnection` uses `InsertAtIndexOrEnd` with an explicit `multiInputIndex` counter:

**`Core/Operator/Instance.Connections.cs:68`**:

```csharp
var conHashToCount = new Dictionary<ulong, int>(connections.Count);
for (var index = 0; index < connections.Count; index++)
{
    conHashToCount.TryGetValue(hash, out int count);
    instance.TryAddConnection(connection, count, true);
    conHashToCount[hash] = count + 1;
}
```

Connection 0 in the JSON is index 0 in `InputConnections[]`. The order is stable and deterministic.

### Type Safety

`MultiInputSlot<T>` is always typed. You cannot mix types in a single multi-input. `AddConnection` rejects type mismatches:

**`Core/Operator/Slots/Slot.cs:210`**:

```csharp
if (sourceSlot.ValueType != _valueType)
{
    Log.Warning("Type mismatch during connection");
    return;
}
```

### Evaluation: Lazy per GetValue

`GetCollectedTypedInputs` does not evaluate any upstream operators. It builds the flat list of `Slot<T>` references. Evaluation is lazy — triggered only when Execute (or another consumer) calls `commands[i].GetValue(context)`.

### The Switch Optimization

`Switch.cs` demonstrates `LimitMultiInputInvalidationToIndices`:

**`Operators/Lib/Symbols/flow/Switch.cs:71`**:

```csharp
if (OptimizeInvalidation.GetValue(context))
{
    commandSlot.LimitMultiInputInvalidationToIndices = _activeIndices.ToArray();
}
```

**`Core/Operator/Slots/MultiInputSlot.cs:57`**:

```csharp
if (multiInputLimitCount > 0)
{
    for (int i = 0; i < multiInputLimitCount; i++)
    {
        var index = LimitMultiInputInvalidationToIndices[i];
        if (index >= collectedCount) continue;
        target += collectedInputs[index].Invalidate();
    }
}
```

When `Switch` is active, only the active branch's subgraph is invalidated. Inactive branches skip `Invalidate()` entirely — their `Target` doesn't advance, they stay clean, and they won't be evaluated. This is significant for large scenes with mutually exclusive branches.

---

## Q3: How Does EvaluationContext Work?

### Full Field Inventory

**`Core/Operator/EvaluationContext.cs:33`** (178 lines total):

| Category | Field | Type |
|----------|-------|------|
| **Timing** | `Playback` | `Playback` (reference to global) |
| | `LocalTime` | `double` (bars) |
| | `LocalFxTime` | `double` (bars, runs even when paused) |
| **Resolution** | `RequestedResolution` | `Int2` |
| **Transform stack** | `CameraToClipSpace` | `Matrix4x4` |
| | `WorldToCamera` | `Matrix4x4` |
| | `ObjectToWorld` | `Matrix4x4` |
| **Rendering** | `FogParameters` | `Buffer` (DX11 constant buffer) |
| | `PbrMaterial` | `PbrMaterial` (reference) |
| | `Materials` | `List<PbrMaterial>` (capacity 8) |
| | `ContextTextures` | `Dictionary<string, Texture2D>` |
| | `PointLights` | `PointLightStack` (push/pop, max 8) |
| | `BackgroundColor` | `Vector4` |
| | `ForegroundColor` | `Vector4` |
| **Editor** | `ShowGizmos` | `GizmoVisibility` (enum) |
| | `TransformGizmoMode` | `TransformGizmoModes` (enum) |
| **Named variables** | `BoolVariables` | `Dictionary<string, bool>` |
| | `IntVariables` | `Dictionary<string, int>` |
| | `FloatVariables` | `Dictionary<string, float>` |
| | `ObjectVariables` | `Dictionary<string, object>` |
| | `StringVariables` | `Dictionary<string, string>` |
| **Iteration** | `IteratedList` | `StructuredList` |
| | `IteratedListIndex` | `int` |
| **Camera** | `BypassCameras` | `bool` |
| **Particles** | `LegacyParticleSystem` | `LegacyParticleSystem` |
| | `ParticleSystem` | `ParticleSystem` |

### Passing Convention: Shared Mutable Reference

`EvaluationContext` is a single heap-allocated object passed by reference through every `GetValue`/`Update` call. There is no cloning. There is no scoping. The same object flows from root to leaf:

```csharp
public T? GetValue(EvaluationContext context)  // same object everywhere
public void Update(EvaluationContext context)  // passed unchanged
```

### Mutation Protocol: Manual Save/Restore

Because the context is shared and mutable, operators that need to scope their changes must manually save and restore. There is no built-in stack mechanism (except `PointLightStack`).

**`Core/Operator/Slots/TimeClipSlot.cs:61`** — the most rigorous example:

```csharp
private void UpdateWithTimeRangeCheck(EvaluationContext context)
{
    var prevTime = context.LocalTime;
    var prevFxTime = context.LocalFxTime;

    context.LocalTime = prevTime.Remap(...);
    context.LocalFxTime = prevFxTime.Remap(...);

    _baseUpdateAction(context);   // descend into subtree with modified time

    context.LocalTime = prevTime;      // restore
    context.LocalFxTime = prevFxTime;  // restore
}
```

**`Operators/Lib/Symbols/flow/context/SetFloatVar.cs:28`** — named variables:

```csharp
var hadPreviousValue = context.FloatVariables.TryGetValue(name, out var previous);
context.FloatVariables[name] = newValue;

SubGraph.GetValue(context);  // subtree sees overridden variable

if (hadPreviousValue)
    context.FloatVariables[name] = previous;   // restore
else if (!clearAfterExecution)
    context.FloatVariables.Remove(name);
```

`PointLightStack` is the one exception with proper Push/Pop:

**`Core/Rendering/PointLightStack.cs:68`**:

```csharp
public bool Push(PointLight pointLight) { _pointLights[_currentSize++] = pointLight; }
public void Pop() { if (_currentSize > 0) _currentSize--; }
```

The three transform matrices have no stack — operators must save and restore manually.

### Reset at Frame Start

**`Core/Operator/EvaluationContext.cs:43`**:

```csharp
public void Reset()
{
    Playback = Playback.Current;
    LocalTime = Playback.TimeInBars;
    LocalFxTime = Playback.FxTimeInBars;
    PointLights.Clear();
    FloatVariables.Clear();
    BoolVariables.Clear();
    IntVariables.Clear();
    ObjectVariables.Clear();
    StringVariables.Clear();
    PbrContextSettings.SetDefaultToContext(this);
}
```

Called by the render loop before each frame. Clears all dictionaries, clears the light stack, and re-applies default PBR material/textures. Matrices and `RequestedResolution` are NOT reset here — they're set explicitly by the caller.

### Non-Rendering Fields

`EvaluationContext` carries several things unrelated to DX11 rendering:

- **Time**: `LocalTime` and `LocalFxTime` in musical bars. `TimeClipSlot` remaps them for sub-timelines.
- **Named variables**: Five `*Variables` dictionaries implement dynamic variable scoping. `SetFloatVar`/`GetFloatVar` operators read and write these — a lightweight parameter passing mechanism across graph boundaries without explicit connections.
- **`ObjectVariables`**: An untyped escape hatch — `Dictionary<string, object>`. Used by `SetMatrixVar` to pass `Vector4[]` arrays.
- **Iteration state**: `IteratedList` and `IteratedListIndex` support `Loop` and iterator operators.
- **Particle systems**: `LegacyParticleSystem` and `ParticleSystem` passed as context references.

### Fragility

If an operator throws mid-evaluation, the context is left in a dirty state. There is no RAII, no automatic cleanup. The `Reset()` call at frame start is the only recovery mechanism.

---

## Q4: What Slot Types Exist?

### The Interface Layer

```
ISlot                              (non-generic, type-erased base)
  ├── IInputSlot : ISlot           (adds Input, MappedType, IsMultiInput)
  │     └── IMultiInputSlot        (adds GetCollectedInputs())
  └── IOutputSlot                  (minimal: Guid Id only)
```

**`Core/Operator/Slots/ISlot.cs:5`**:

```csharp
public interface ISlot
{
    Guid Id { get; set; }
    Type ValueType { get; }
    Instance Parent { get; set; }
    DirtyFlag DirtyFlag { get; }
    int Invalidate();
    void Update(EvaluationContext context);
    void AddConnection(ISlot source, int index = 0);
    void RemoveConnection(int index = 0);
    bool HasInputConnections { get; }
}
```

`ISlot` holds `Type ValueType` as a runtime `System.Type` — this is how the system talks about "what type flows through this wire" without needing generics everywhere.

### The Concrete Class Hierarchy

```
Slot<T> : ISlot                                    — the universal node
  ├── (used directly as output slot)
  ├── InputSlot<T> : Slot<T>, IInputSlot           — input slot
  │     └── MultiInputSlot<T> : InputSlot<T>       — multi-connection input [sealed]
  ├── TimeClipSlot<T> : Slot<T>                    — output-side time gating [sealed]
  └── TransformCallbackSlot<T> : Slot<T>           — output-side gizmo hook [sealed]
```

**`Slot<T>`** is the core. It serves double duty as both output slot and base of input slots:

**`Core/Operator/Slots/Slot.cs:19`**:

```csharp
public class Slot<T> : ISlot
{
    public T Value;                                    // the held value
    public Action<EvaluationContext>? UpdateAction;     // swappable function pointer
    protected DirtyFlag _dirtyFlag;
    protected Slot<T>[] InputConnections = [];          // upstream slots
    private bool _isInputSlot;
    private bool _valueIsCommand;
}
```

**`InputSlot<T>`** adds the connection to the parameter data layer:

**`Core/Operator/Slots/InputSlot.cs:5`**:

```csharp
public class InputSlot<T> : Slot<T>, IInputSlot
{
    public InputValue<T> TypedInputValue;       // literal value set by user in UI
    public InputValue<T> TypedDefaultValue;     // operator's factory default

    public void InputUpdate(EvaluationContext context)
    {
        Value = Input.IsDefault ? TypedDefaultValue.Value : TypedInputValue.Value;
    }
}
```

An unconnected `InputSlot` has `UpdateAction = InputUpdate` (reads from its stored literal value). When a wire is connected, `AddConnection` replaces `UpdateAction` with `ConnectedUpdate` (pulls from upstream).

**`TimeClipSlot<T>`** wraps its `UpdateAction` to gate on the playhead time range — nested content only evaluates when the clip is active.

**`TransformCallbackSlot<T>`** wraps its `UpdateAction` to fire a transform gizmo callback before delegating to the inner update.

### Type Checking: Editor Time vs Runtime

**At connection time (editor)**: The operator browser filters candidates by exact `System.Type` equality — no subtype checking, no covariance:

**`Core/Operator/Symbol.cs:321`**:

```csharp
public InputDefinition GetInputMatchingType(Type type)
{
    foreach (var inputDefinition in InputDefinitions)
    {
        if (type == null || inputDefinition.DefaultValue.ValueType == type)
            return inputDefinition;
    }
    return null;
}
```

If a user manages to drag a mismatched wire, `Slot<T>.AddConnection` catches it with a warning log and silent rejection — no exception, no UI feedback from the slot layer:

```csharp
if (sourceSlot.ValueType != _valueType)
{
    Log.Warning("Type mismatch during connection");
    return;
}
```

**At evaluation time**: No type checking occurs. Once a connection is in `InputConnections[]`, it has already survived the type check. The `(Slot<T>)` cast is statically safe.

---

## Q5: How Does ConnectedUpdate Differ from GetValue?

### They Are Nested, Not Alternatives

`GetValue` is the public entry point. `ConnectedUpdate` is a stored delegate installed as `UpdateAction` when a wire exists. They call each other:

```
someSlot.GetValue(context)
  └── someSlot.Update(context)          [dirty check]
        └── someSlot.UpdateAction(context)
              = ConnectedUpdate(context)    [installed by AddConnection]
                  └── InputConnections[0].GetValue(context)
                        └── upstreamSlot.Update(context)
                              └── upstreamSlot.UpdateAction(context)
                                    = operator.Update(context)  [the real work]
```

### The ICompoundWithUpdate Special Case

For compound operators (`DrawScene`, `DrawMesh`) that implement `ICompoundWithUpdate`, `AddConnection` does NOT replace `UpdateAction` with `ConnectedUpdate`:

**`Core/Operator/Slots/Slot.cs:193`**:

```csharp
if (_parentIsICompoundWithUpdate && !_isInputSlot && _parent.Children.Count > 0)
{
    // Keep the operator's own Update method as UpdateAction
    ArrayUtils.InsertAtIndexOrEnd(ref InputConnections, (Slot<T>)sourceSlot, index);
    _dirtyFlag.Target = sourceSlot.DirtyFlag.Target;
    _dirtyFlag.Reference = _dirtyFlag.Target - 1;
    return;   // early return — UpdateAction stays
}
```

The operator's `Update` method calls `Output.ConnectedUpdate(context)` manually, allowing it to modify the context before and restore it after the inner graph evaluates:

**`Operators/Lib/Symbols/render/scene/DrawScene.cs:49`**:

```csharp
private void Update(EvaluationContext context)
{
    // ... set context.PbrMaterial, etc. ...

    Output.ConnectedUpdate(context);    // manually pull inner child graph

    context.PbrMaterial = previousMaterial;   // restore
}
```

### Summary

| Method | Role | Who calls it |
|--------|------|-------------|
| `GetValue(context)` | Public pull entry point. Dirty-checks, evaluates if needed, returns `Value` | Downstream consumers, `ConnectedUpdate` |
| `Update(context)` | Dirty check + delegate dispatch. Does NOT return a value | `GetValue` |
| `ConnectedUpdate(context)` | Installed as `UpdateAction` when a wire exists. Calls `GetValue` on upstream | `Update` (via delegate) or explicitly by `ICompoundWithUpdate` operators |
| `InputUpdate(context)` | Installed as `UpdateAction` on unconnected inputs. Reads stored literal | `Update` (via delegate) |
| `operator.Update(context)` | Registered as `UpdateAction` on output slots. The actual operator logic | `Update` (via delegate) |

---

## Q6: How Does Dirty Propagation Work Across Compound Boundaries?

### No Special Boundary Handling

Compound boundaries are transparent to the dirty flag system. When `AddConnection` is called — even across a compound boundary — `InputConnections[0]` holds a direct reference to the source slot object. There is no indirection layer:

```csharp
public void AddConnection(ISlot sourceSlot, int index = 0)
{
    // ...
    ArrayUtils.InsertAtIndexOrEnd(ref InputConnections, (Slot<T>)sourceSlot, index);
}
```

When `Invalidate()` calls `InputConnections[0].Invalidate()`, it directly calls into the slot on the other side of the compound boundary. The graph is a flat object graph of `Slot<T>` references — compound nesting is only conceptual/organizational.

### MultiInputSlot Invalidation: Aggregation by Sum

**`Core/Operator/Slots/MultiInputSlot.cs:46`**:

```csharp
protected override int InvalidationOverride()
{
    var collectedInputs = GetCollectedTypedInputs(true);
    int target = 0;
    for (int i = 0; i < collectedCount; i++)
        target += collectedInputs[i].Invalidate();
    return target;
}
```

A `MultiInputSlot` sums all upstream target values. Any one upstream slot incrementing its `Target` changes the sum, marking the multi-input as dirty. This is how a value change deep inside a compound that feeds into a `Group`'s `MultiInputSlot` propagates outward.

### The ICompoundWithUpdate Caveat

`ICompoundWithUpdate` only affects the evaluation phase (whether `AddConnection` replaces `UpdateAction`). The invalidation phase is completely unaffected — dirty flag arithmetic is identical regardless of whether the operator implements `ICompoundWithUpdate`.

### Summary: Pull-Based with Editor-Pushed Seeds

The system is pull-based, initiated by the render loop. But value changes from editor interaction call `DirtyFlag.Invalidate()` directly on the affected input slot (editor-side push), ensuring the counter diverges before the render loop's pull pass.

```
User edits a value
    │
    ▼
inputSlot.DirtyFlag.ForceInvalidate()      // editor-side push: Target++
    │
    ▼  [next frame]
rootOutput.Invalidate()                     // pull pass walks upstream
    │
    └─ discovers Target != Reference → marks dependent outputs dirty
    │
    ▼
rootOutput.GetValue(context)                // evaluates dirty operators
```

---

## Q7: How Do Command Slots Interact with Dirty Flags?

### The `_valueIsCommand` Bypass

**`Core/Operator/Slots/Slot.cs:128`**:

```csharp
public Slot()
{
    _valueIsCommand = typeof(T) == typeof(Command);
}
```

**`Core/Operator/Slots/Slot.cs:160`**:

```csharp
if (_dirtyFlag.IsDirty || _valueIsCommand)   // commands always enter this block
{
    UpdateAction?.Invoke(context);
    _dirtyFlag.Clear();       // cleared — but irrelevant since _valueIsCommand bypasses
}
```

Command slots re-execute every frame regardless of their dirty flag. The dirty flag IS cleared afterward, but `_valueIsCommand` makes the next `Update` call re-enter unconditionally.

### Do Command Slots Dirty Downstream Value Nodes?

No — not automatically. Consider `RenderTarget`: it takes a `Command` input and produces `Texture2D` outputs.

**`Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs:21`**:

```csharp
public RenderTarget()
{
    ColorBuffer.UpdateAction += Update;
    DepthBuffer.UpdateAction += Update;
    NormalBuffer.UpdateAction += Update;
}

private void Update(EvaluationContext context)
{
    if (formatChanged || enableUpdate)
    {
        Command.GetValue(context);         // triggers command chain
    }

    ColorBuffer.Value = ColorTexture;
    ColorBuffer.DirtyFlag.Clear();         // explicit clear
    DepthBuffer.Value = DepthTexture;
    DepthBuffer.DirtyFlag.Clear();
    NormalBuffer.Value = NormalTexture;
    NormalBuffer.DirtyFlag.Clear();
}
```

The `ColorBuffer` output is `Slot<Texture2D>` — a value slot with normal dirty semantics. During invalidation, the upstream `Command` slots have their dirty flags cleared from the previous frame, so they report a stable `Target`. The texture output's dirty flag only advances when non-command inputs (size, format, `EnableUpdate`) change.

`RenderTarget` manually calls `DirtyFlag.Clear()` on its texture outputs after filling them. This is explicit lifecycle management — the operator owns its output's dirty state.

### The `EnableUpdate` Flag

`RenderTarget` has an `EnableUpdate` boolean input (default `false`). When `false`, the render target only re-renders when format/size changes. When `true`, it re-renders every frame. This is the user-facing control for whether command re-execution propagates to texture output re-computation.

### Dirty Flag Lifecycle Summary

| Event | What happens |
|-------|-------------|
| Slot construction | `Target = 1`, `Reference = 0` → initially dirty |
| `AddConnection()` | `Target = sourceSlot.Target`, `Reference = Target - 1` → dirty on first eval |
| `RemoveConnection()` | `ForceInvalidate()` → dirty again |
| Frame start | `InvalidationRefFrame++` |
| `Invalidate()` called | `Target++` if inputs changed; epoch guard prevents double-visits |
| `Update()` fires | `UpdateAction` executes, then `Clear()` → `Reference = Target` |
| Next `Invalidate()` | If no upstream change: `Target` stays, `Reference == Target`, not dirty |

---

## Q8: How Are Connections Stored and Resolved?

### The .t3 File Format

Connections are stored as GUID quadruplets in JSON:

```json
{
  "Connections": [
    {
      "SourceParentOrChildId": "guid-a",
      "SourceSlotId":          "guid-b",
      "TargetParentOrChildId": "guid-c",
      "TargetSlotId":          "guid-d"
    }
  ]
}
```

`Guid.Empty` in `SourceParentOrChildId` means "this Symbol's own input" (boundary pass-through). `Guid.Empty` in `TargetParentOrChildId` means "this Symbol's own output."

### Deserialization: GUIDs Only

**`Core/Model/SymbolJson.cs:249`**:

```csharp
private static bool TryReadConnection(JToken jsonConnection,
    [NotNullWhen(true)] out Symbol.Connection? connection)
{
    // Parse 4 GUIDs from JSON → create Symbol.Connection value object
    connection = new Symbol.Connection(sourceInstanceId, sourceSlotId,
                                       targetInstanceId, targetSlotId);
    return true;
}
```

Each JSON object becomes a `Symbol.Connection` — a tiny immutable value object holding four GUIDs. No slot pointer resolution happens at parse time.

### The Canonical Store: Symbol.Connections

**`Core/Operator/Symbol.cs:38`**:

```csharp
public readonly List<Connection> Connections = [];
```

A flat `List<Connection>` owned by the Symbol definition, shared by all instances of that Symbol. This is the single source of truth for graph topology.

### GUID-to-Slot Resolution

Resolution happens in `Instance.Connections.cs` during `ReconnectChildren()`:

**`Core/Operator/Instance.Connections.cs:185`**:

```csharp
private bool TryGetSourceSlot(Symbol.Connection connection,
    [NotNullWhen(true)] out ISlot sourceSlot, bool allowCreate)
{
    if (sourceParentOrChildId == Guid.Empty)
        sourceSlotList = Inputs;          // boundary slot
    else
    {
        Children.TryGetChildInstance(sourceParentOrChildId, out var sourceInstance, allowCreate);
        sourceSlotList = sourceInstance.Outputs;
    }

    foreach (var slot in sourceSlotList)
    {
        if (slot.Id != connection.SourceSlotId) continue;
        sourceSlot = slot;
        return true;
    }
}
```

Resolution is a linear scan of a small list (operators typically have 1–20 slots), so lookup cost is negligible.

### Wiring the Live Slot

**`Core/Operator/Instance.Connections.cs:223`**:

```csharp
internal bool TryAddConnection(Symbol.Connection connection, int multiInputIndex, bool allowCreate)
{
    if (!TryGetSourceSlot(connection, out var sourceSlot, allowCreate) ||
        !TryGetTargetSlot(connection, out var targetSlot, allowCreate))
        return false;

    targetSlot.AddConnection(sourceSlot, multiInputIndex);
    sourceSlot.DirtyFlag.Invalidate();
    return true;
}
```

The moment `AddConnection` returns, `InputConnections[0]` holds a direct `Slot<T>` pointer. GUIDs are retired.

### The Runtime Storage Field

**`Core/Operator/Slots/Slot.cs:267`**:

```csharp
protected Slot<T>[] InputConnections = [];
```

An array of upstream `Slot<T>` references on every slot. For a normal `InputSlot<T>`: length 0 or 1. For `MultiInputSlot<T>`: length 0..N. **There is no connection field on the output side** — outputs have no idea how many downstream inputs pull from them.

### When Does Resolution Happen?

`ReconnectChildren()` is called:
- First time a parent instance is evaluated (lazy, on first access)
- When a child's type changes (recompile / hot-reload)
- When a new child is added to a live graph

After `ReconnectChildren()`, pointers are cached until a structural change invalidates them. This is neither fully eager (not at parse time) nor per-frame lazy (not re-resolved each tick).

---

## Q9: Fan-Out and Fan-In

### Fan-Out: Implicit and Unlimited

A single output can connect to any number of inputs. The output slot stores **no list of downstream consumers**. Fan-out is entirely pull-based:

- Input A calls `InputConnections[0].GetValue(context)` → pulls the output
- Input B independently calls `InputConnections[0].GetValue(context)` → pulls the same output
- The output's `DirtyFlag.IsDirty` check ensures it recalculates only once per frame

At the Symbol level, `Symbol.Connections` holds multiple entries with the same `SourceParentOrChildId/SourceSlotId` pair. At runtime, each downstream `InputSlot` independently holds the same upstream `Slot<T>` reference in its `InputConnections[0]`.

### Fan-In on Plain InputSlot: Replace Rule

A plain `InputSlot<T>` enforces single-connection semantics. Wiring a second output to an already-connected input replaces the first:

**`Core/Operator/Symbol.cs:158`**:

```csharp
public void AddConnection(Connection connection, int multiInputIndex = 0)
{
    var isMultiInput = IsTargetMultiInput(connection);
    var connectionsAtInput = Connections.FindAll(c =>
        c.TargetParentOrChildId == connection.TargetParentOrChildId &&
        c.TargetSlotId == connection.TargetSlotId);

    if (!isMultiInput)
    {
        if (connectionsAtInput.Count > 0)
            RemoveConnection(connectionsAtInput[0]);   // old wire killed
        Connections.Add(connection);
    }
    else
    {
        Connections.Insert(insertIndex, connection);   // ordered insert
    }
}
```

### Fan-In on MultiInputSlot: The Only Multi-Wire Mechanism

`MultiInputSlot<T>` is the only way to accept multiple connections. Its `InputConnections[]` array holds all upstream sources in order. There is no way to configure a plain `InputSlot<T>` to accept multiple wires — the `IsMultiInput` flag is declared in C# code with `[Input(Guid = "...", IsMultiInput = true)]` and is not user-configurable.

### Summary Table

| Property | `InputSlot<T>` | `MultiInputSlot<T>` | Output `Slot<T>` |
|----------|----------------|---------------------|------------------|
| Connections stored | `InputConnections[]` (0 or 1) | `InputConnections[]` (0..N) | None |
| Multiple wires in | No — replaces existing | Yes — ordered insert | N/A |
| Fan-out tracking | N/A | N/A | Not tracked |
| Fan-out mechanism | N/A | N/A | Each consumer pulls independently |

---

## Implications for flux-core

### What to Adopt

**Counter-based dirty flags.** The `Reference`/`Target` integer pair is allocation-free, branch-predictor-friendly, and naturally handles diamond graphs via the epoch guard. In Rust: `struct DirtyFlag { reference: u32, target: u32, last_invalidated_epoch: u32 }`.

**Two-phase evaluation (invalidate then pull).** Separating the invalidation pass (reads only `Target` counters, borrows immutably) from the evaluation pass (writes `Value`, borrows mutably) is clean and correct. The Switch optimization (selective invalidation) depends on this separation.

**Pull-based fan-out with no source-side tracking.** Output nodes need zero knowledge of consumers. Each consumer calls `get_value()` independently. No subscriber lists, no `Arc<RefCell<Vec<...>>>` overhead.

**Flat connection list on the graph definition.** Keep a `Vec<Connection>` on the `Symbol` type and derive instance-level wiring from it. This cleanly separates "what the graph means" from "what a specific instance has wired."

**Replace-on-single-input at the model layer.** Enforce the single-connection rule in `graph.add_connection()`, not in the UI.

### What to Modify

**EvaluationContext split.** In Rust, passing `&mut EvaluationContext` through the call chain prevents re-entrancy and requires borrow checker satisfaction. Consider splitting: an immutable `&FrameConfig` (time, resolution, camera) and a mutable `&mut RenderState` (lights, materials, transforms with proper push/pop stacks).

**Type-level Command/Value distinction.** `_valueIsCommand` as a runtime bool in the hot path is a leaky abstraction. In Rust, use separate types: `DataSlot<T>` that caches, and `CommandSlot` that never caches. The type system enforces the distinction at compile time.

**Slot hierarchy.** `Slot<T>` / `InputSlot<T>` / `MultiInputSlot<T>` as C# inheritance is awkward in Rust. Use composition: a `Slot<T>` struct with a `Source` enum (`Constant(T)`, `Connected(SlotId)`, `Multi(Vec<SlotId>)`).

**`InvalidationRefFrame` as a passed parameter.** The C# global static `DirtyFlag.InvalidationRefFrame` requires `unsafe` in Rust. Pass the epoch counter through the evaluation context instead.

### What to Avoid

**Implicit context mutation via named variables.** The five `*Variables` dictionaries allow operators to communicate sideways (A sets a variable, B reads it without being connected). This creates invisible coupling. In Rust, prefer explicit connections or typed parameter passing.

**Untyped `ObjectVariables`.** The `Dictionary<string, object>` escape hatch is a typed hole. In Rust, use `anymap`-style typed storage if truly needed.

**Manual `DirtyFlag.Clear()` in operator code.** RenderTarget's explicit `ColorBuffer.DirtyFlag.Clear()` is fragile — forgetting it causes every-frame re-evaluation. The evaluation harness should own the clear call.

**`ICompoundWithUpdate` as a cross-cutting concern in AddConnection.** The slot layer checking `_parentIsICompoundWithUpdate` is a leaky abstraction. In Rust, compound operators should have a different slot setup mechanism (e.g., a `CompoundOutput<T>` type) rather than a runtime flag check inside the connection logic.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `Core/Operator/Slots/Slot.cs` | Universal slot: Value, UpdateAction, GetValue, Update, ConnectedUpdate, Invalidate, AddConnection |
| `Core/Operator/Slots/InputSlot.cs` | Input slot: InputUpdate, TypedInputValue, TypedDefaultValue |
| `Core/Operator/Slots/MultiInputSlot.cs` | Multi-connection input: CollectedInputs, InvalidationOverride, LimitMultiInputInvalidationToIndices |
| `Core/Operator/Slots/DirtyFlag.cs` | Counter-based dirty tracking: Reference/Target, InvalidationRefFrame epoch guard |
| `Core/Operator/Slots/TimeClipSlot.cs` | Time-gated output: evaluates content only when playhead is in range |
| `Core/Operator/Slots/TransformCallbackSlot.cs` | Gizmo hook output: fires transform callback before evaluation |
| `Core/Operator/EvaluationContext.cs` | Shared mutable context: transforms, materials, lights, time, named variables |
| `Core/Operator/Symbol.cs` | Graph definition: Connections list, AddConnection (replace/insert), type matching |
| `Core/Operator/Instance.Connections.cs` | GUID-to-slot resolution: ReconnectChildren, TryGetSourceSlot, TryAddConnection |
| `Core/Model/SymbolJson.cs` | .t3 deserialization: TryReadConnection (4 GUIDs) |
| `Player/Program.RenderLoop.cs` | Frame loop: InvalidationRefFrame++, Invalidate(), GetValue() |
| `Operators/Lib/Symbols/flow/Execute.cs` | Three-phase command execution: Prepare-all, Execute-all, Restore-all |
| `Operators/Lib/Symbols/flow/Switch.cs` | Selective invalidation optimization via LimitMultiInputInvalidationToIndices |
