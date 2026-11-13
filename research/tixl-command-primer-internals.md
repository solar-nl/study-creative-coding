# Primer: tixl `Command` — Internals (Code-Level)

> **Scope.** This primer covers the C#-level mechanics of tixl/Tooll3's `Command`
> type, how it participates in the pull-based slot evaluator, and how the
> push/pop of render state actually happens. Companion primers cover canonical
> usage patterns and architectural comparison.

> **Root path used throughout.**
> `tixl-root = visual-programming/tixl`
> All `path:line` citations below are relative to that root unless otherwise marked.

---

## TL;DR

1. **`Command` is a two-delegate bag, not a value.** Its entire definition
   ([`Core/DataTypes/Command.cs:6-10`](#)) is a class with two
   `Action<EvaluationContext>` properties — `PrepareAction` and `RestoreAction`
   — and *no other fields*. It does not carry transforms, children, meshes,
   or any scene data.
2. **`Slot<Command>` is treated specially by the evaluator.** The dirty-flag
   short-circuit in `Slot<T>.Update` is bypassed when `T == Command`
   ([`Slot.cs:134, 162`](#)) — a Command output is *always* re-invoked on every
   pull. This is what turns the "value" port into an "execute this side-effect"
   port.
3. **Push/pop happens in the producer's `Update` method, not in `Command`
   itself.** Operators like `Transform`
   ([`render/transform/Transform.cs:22-46`](#)) cache the previous context
   field, mutate the context, pull the upstream `Command` (which causes the
   subtree to execute under the mutated context), then write the previous value
   back. There is no `try/finally` — exception safety is *not* guaranteed by
   the framework.
4. **State propagates down the subtree through `EvaluationContext`, not
   through Command's payload.** Hierarchy lives in the *graph topology*: when
   `Transform.Update` calls `Command.GetValue(context)`, the engine recursively
   pulls whatever Command-producing operators are connected upstream — under
   the new `context.ObjectToWorld`. The subtree is just "everything reachable
   from `Transform.Command`'s input connection."
5. **`Command` is essentially a typed `void`.** Its value is the `Command`
   object itself (which may be `null` for Transform-style ops that ignore it,
   or a non-null instance with `PrepareAction`/`RestoreAction` for stages like
   `PixelShaderStage`). The *meaningful work* is the side effects performed
   while pulling it.

---

## The Command type

The entire definition, in full:

```csharp
// Core/DataTypes/Command.cs
using System;
using T3.Core.Operator;

namespace T3.Core.DataTypes;

public class Command
{
    public Action<EvaluationContext> PrepareAction { get; init; }
    public Action<EvaluationContext> RestoreAction { get; set; }
}
```

Path: `Core/DataTypes/Command.cs:1-10` — entire file is 10 lines.

Observations:

- **No constructor body.** The default parameterless constructor is used
  everywhere. There is no payload to initialize.
- **No children, no list of sub-commands.** A `Command` is not a tree node.
- **`PrepareAction` is `init`-only**; once set on construction it cannot be
  reassigned. `RestoreAction` is a normal `set` and *can* be rewired after
  construction (e.g. `PixelShaderStage` sets it in its own constructor —
  `Operators/TypeOperators/Symbols/Gfx/PixelShaderStage.cs:12`).
- **Both actions take `EvaluationContext`.** That's the only parameter — there
  is no way for one Command to pass information to another except via the
  context.

The two actions encode "do this *before* my downstream consumer pulls me" and
"do this *after* my downstream consumer pulls me." Crucially, the *consumer*
decides whether to call them — see "Push/pop in practice" below.

Many operators that produce a `Command` output **never construct a `Command`
object at all** — they leave `Output.Value` as `default(Command)` (i.e.
`null`) and put all their work in the `UpdateAction` delegate. `Transform`,
`Group`, `SetMaterial`, and `SetPointLight` are all examples of this. Operators
that *do* construct a `Command` (so they can hand callers a paired
prepare/restore) do so via the slot constructor:

```csharp
// Operators/TypeOperators/Symbols/Gfx/PixelShaderStage.cs:7
public readonly Slot<Command> Output = new(new Command());
```

The `new(new Command())` form ensures `Output.Value` is non-null from the start
so the operator can write `Output.Value.RestoreAction = Restore;`
([`PixelShaderStage.cs:12`](#)).

---

## The Slot mechanism

### `Slot<T>` shape

The base slot is in `Core/Operator/Slots/Slot.cs`. Key fields and methods:

```csharp
// Core/Operator/Slots/Slot.cs:19-40
public class Slot<T> : ISlot
{
    public Guid Id;
    private readonly Type _valueType;
    ...
    public DirtyFlag DirtyFlag => _dirtyFlag;
    private protected DirtyFlag _dirtyFlag = new();

    public T Value;

    ...
}
```

The `Value` field is a plain mutable field of type `T`. There is no
property/getter logic — the value is just written by whoever runs the slot's
`UpdateAction`.

### `UpdateAction` — the side-effect closure

Each slot owns a single delegate:

```csharp
// Core/Operator/Slots/Slot.cs:336
public virtual Action<EvaluationContext>? UpdateAction { get; set; }
```

Operators wire their compute into this delegate from their constructor. For
`Transform`:

```csharp
// Operators/Lib/Symbols/render/transform/Transform.cs:17-20
public Transform()
{
    Output.UpdateAction += Update;
}
```

`Update` is a private method on the operator instance. When the slot is pulled,
the framework invokes this delegate.

### `GetValue` and the pull

The single entrypoint for evaluation is `GetValue`:

```csharp
// Core/Operator/Slots/Slot.cs:181-186
public T? GetValue(EvaluationContext context)
{
    Update(context);
    return Value;
}
```

`Update` is what makes `Command` slots different:

```csharp
// Core/Operator/Slots/Slot.cs:159-169
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

The `|| _valueIsCommand` clause is **the load-bearing piece**. `_valueIsCommand`
is set once in the constructor:

```csharp
// Core/Operator/Slots/Slot.cs:128-140
public Slot()
{
    Value = default!;
    _valueType = typeof(T);
    _valueIsCommand = _valueType == typeof(Command);
    ...
}
```

So a `Slot<Command>` **always re-invokes its `UpdateAction` on every pull**,
regardless of whether the dirty flag says "still clean." A `Slot<float>` only
re-runs when something upstream invalidated it.

### How `Slot<Command>` differs from `Slot<float>`

| Aspect | `Slot<float>` | `Slot<Command>` |
|---|---|---|
| `Value` field type | `float` | `Command` (may be `null`) |
| `_valueIsCommand` flag | `false` | `true` ([`Slot.cs:134`](#)) |
| Dirty-flag short-circuit in `Update` | Yes — skips work if clean | **No** — always re-runs ([`Slot.cs:162`](#)) |
| Typical operator pattern | Compute `value`, write to `Value`, done | Mutate `context`, pull upstream, restore `context` |
| What downstream does with `.Value` | Reads the number | Usually ignores it (or invokes `.PrepareAction`/`.RestoreAction` if non-null) |

The `Slot<Command>` is *not* really a value-carrying port. It is an
**evaluation hook** that the pull-engine guarantees to invoke every frame.

### Other slot subtypes

`Core/Operator/Slots/` contains a small family:
- `Slot.cs` — base.
- `InputSlot.cs` — the input-side counterpart; carries `TypedInputValue` for
  the unconnected default.
- `MultiInputSlot.cs` — variable-arity input that gathers a `List<Slot<T>>` via
  `CollectedInputs` ([`MultiInputSlot.cs:12-13`](#)).
  `Group` uses `MultiInputSlot<Command>` to collect a list of subtrees.
- `TimeClipSlot.cs`, `TransformCallbackSlot.cs` — domain-specific.

`MultiInputSlot<Command>` is how operators like `Group` and `Execute` get a
flat list of upstream Command-producers — each list element is itself a
`Slot<Command>` they can pull independently.

---

## Push/pop in practice — walking `Transform.Update()`

The canonical state-pushing operator. Output is `Slot<Command>`; input has
both parameter ports (Translation/Rotation/Scale/...) and a `Command` input
that represents "the subtree to render under my transform."

```csharp
// Operators/Lib/Symbols/render/transform/Transform.cs:22-46
private void Update(EvaluationContext context)
{
    TransformCallback?.Invoke(this, context); // editor gizmo hook

    var pivot = Pivot.GetValue(context);
    var s = Scale.GetValue(context) * UniformScale.GetValue(context);
    var r = Rotation.GetValue(context);
    float yaw = r.Y.ToRadians();
    float pitch = r.X.ToRadians();
    float roll = r.Z.ToRadians();
    var t = Translation.GetValue(context);
    var objectToParentObject = GraphicsMath.CreateTransformationMatrix(
        scalingCenter: pivot,
        scalingRotation: Quaternion.Identity,
        scaling: s,
        rotationCenter: pivot,
        rotation: Quaternion.CreateFromYawPitchRoll(yaw, pitch, roll),
        translation: t);

    var previousWorldTobject = context.ObjectToWorld;
    context.ObjectToWorld = Matrix4x4.Multiply(objectToParentObject, context.ObjectToWorld);
    Command.GetValue(context);
    context.ObjectToWorld = previousWorldTobject;
}
```

Step by step:

1. **L25** — Editor-only callback (gizmo wiring). Ignore for evaluation
   semantics.
2. **L27-33** — Pull all the parameter input slots. These are normal `float`/
   `Vector3` `InputSlot<T>`s; they may or may not be dirty.
3. **L34-40** — Compute the local matrix `objectToParentObject` (pure
   computation, no context mutation yet).
4. **L42** — **Save the previous context state to a local variable.**
   `previousWorldTobject` is a plain `Matrix4x4` (struct, value copy).
5. **L43** — **Mutate the context.** Set `context.ObjectToWorld` to the
   composed matrix.
6. **L44** — **Pull the upstream `Command` input.** This call to
   `Command.GetValue(context)` is what makes the subtree execute. Because
   `Command` is an `InputSlot<Command>` (`Transform.cs:48-49`), its
   `GetValue(context)` will, via the `ConnectedUpdate` path
   ([`Slot.cs:171-174`](#)), forward to the upstream `Slot<Command>` and
   recursively invoke its `UpdateAction` under the *mutated* context.
7. **L45** — **Restore.** Write the saved matrix back into `context.ObjectToWorld`.

### What "pushes" and what "pops"

- "Push" = "snapshot a context field into a local + overwrite the field"
  (L42-43).
- "Pop" = "write the snapshot back" (L45).

There is no explicit stack data structure for `ObjectToWorld`. The call stack
of `Update` invocations *is* the stack — each frame on the C# call stack holds
its own local `previousWorldTobject`.

This works because:
- `Matrix4x4` is a `struct` (value semantics).
- Pulls are synchronous and single-threaded within an evaluation.
- The "stack" is implicit in the recursive `GetValue` chain.

### Exception safety — **none**

There is no `try/finally`. If anything in the subtree throws, `ObjectToWorld`
is left in the mutated state and corruption leaks back to whatever rendered
above this Transform. Verified by inspection: `Transform.Update` has no
`try`/`catch`/`finally` blocks ([`Transform.cs:22-46`](#)), and the same is
true for `Group` ([`Group.cs:25-88`](#)), `SetPointLight`
([`SetPointLight.cs:14-27`](#)), `SetContextTexture`
([`SetContextTexture.cs:16-35`](#)), and `SetMaterial`
([`SetMaterial.cs:21-69`](#)).

### Two distinct "Command-as-scope" patterns

The codebase mixes two patterns:

**Pattern A — context-only push/pop in the producer's `UpdateAction`** (used by
`Transform`, `SetPointLight`, `SetContextTexture`, `SetMaterial`). The producer
mutates context, pulls its `InputSlot<Command>` representing the subtree, and
restores. The producer's `Output.Value` is `null` (the default for
`Slot<Command>` constructed as `new()`). Downstream consumers never look at
`.Value`.

**Pattern B — Command.PrepareAction / RestoreAction handed off to consumer**
(used by DX11 stage operators: `PixelShaderStage`, `VertexShaderStage`,
`InputAssemblerStage`, `Rasterizer`, `OutputMergerStage`). The producer
constructs a `new Command()` at slot-construction time, wires
`RestoreAction = Restore` in its own constructor, and writes the "before"
state into private fields during `UpdateAction`. The *consumer* (typically
`Group`, `Execute`, `Switch`, or one of the `flow/*` ops) is responsible for
invoking `PrepareAction`, pulling the value, then invoking `RestoreAction`.

Pattern B is visible in `Group.Update`:

```csharp
// Operators/Lib/Symbols/render/transform/Group.cs:57-77
var commands = Commands.CollectedInputs;
if (IsEnabled.GetValue(context) && color.W > 0)
{
    foreach (var t1 in commands)
    {
        // Do preparation if needed
        t1.Value?.PrepareAction?.Invoke(context);

        if (forceColorUpdate)
        {
            DirtyFlag.InvalidationRefFrame++;
            t1.Invalidate();
        }

        // Execute commands
        t1.GetValue(context);

        // Cleanup after usage
        t1.Value?.RestoreAction?.Invoke(context);
    }
}
```

For Pattern A producers `t1.Value` is `null` and the `?.` calls are no-ops —
all the work happens inside `t1.GetValue(context)`'s recursive update. For
Pattern B producers (a DX11 stage in the multi-input list), the consumer
explicitly brackets the pull with prepare/restore.

The same prepare/pull/restore pattern repeats in `Execute`
([`flow/Execute.cs:14-39`](#)), `Switch` ([`flow/Switch.cs:30-89`](#)),
`SpreadLayout`, `ExecuteOnce`, `ExecRepeatedly`, `LoadSoundtrack`,
`TimeClip` (all in `Operators/Lib/flow/` or `Operators/Lib/render/transform/`).

---

## The pull evaluation lifecycle

### Top-of-graph entry

The top-level renderer (e.g. `RenderTarget`,
`Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs`) is *not* a
`Slot<Command>` producer — its outputs are `Slot<Texture2D>`. Inside its
`Update` it eventually does:

```csharp
// Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs:151
Command.GetValue(context);
```

with `Command` being its own `InputSlot<Command>` ([`RenderTarget.cs:654`](#)).
Before that call it has set the DX11 render targets, viewport, clear color,
ObjectToWorld, WorldToCamera, BypassCameras, BackgroundColor, ForegroundColor
(`RenderTarget.cs:88-149`), and after it restores them (`RenderTarget.cs:153-162`).
This is the outermost "push/pop" — the same pattern as `Transform`, just for
DX11 device state and camera matrices.

### Example trace: `Transform { SetPointLight { DrawMesh } }`

Conceptual graph (data flows up to the right):

```
DrawMesh.Output  --->  SetPointLight.Command  ;  SetPointLight.Output  --->  Transform.Command  ;  Transform.Output  --->  RenderTarget.Command
```

Call sequence when `RenderTarget.Update` reaches its `Command.GetValue(context)`:

1. `RenderTarget.Command.GetValue(ctx)`
   → `Slot<Command>.Update(ctx)` on the connected `Transform.Output` slot
   → because `_valueIsCommand`, `UpdateAction` is invoked unconditionally
   → enters `Transform.Update(ctx)` ([`Transform.cs:22`](#))
2. `Transform.Update` reads Translation/Rotation/Scale etc.
3. `Transform.Update` snapshots `previousWorldTobject = ctx.ObjectToWorld`
4. `Transform.Update` writes the composed matrix into `ctx.ObjectToWorld`
5. `Transform.Update` calls `Command.GetValue(ctx)` on its own
   `InputSlot<Command>`
   → forwards to the connected `SetPointLight.Output` `Slot<Command>`
   → again `_valueIsCommand` forces re-evaluation
   → enters `SetPointLight.Update(ctx)` ([`SetPointLight.cs:14`](#))
6. `SetPointLight.Update`:
   - reads light parameters (under the new ObjectToWorld)
   - calls `ctx.PointLights.Push(light)` ([`SetPointLight.cs:22`](#))
   - calls `Command.GetValue(ctx)` → forwards to `DrawMesh.Output`
7. `DrawMesh.Update` ([`DrawMesh.cs:18-45`](#)) — reads
   `ctx.PointLights`/`ctx.ObjectToWorld`/`ctx.PbrMaterial`, issues the
   draw call. It does *not* push anything; it's a leaf renderer.
   (Strictly, `DrawMesh` does its own `previousMaterial`/`context.PbrMaterial`
   dance for the `UseMaterialId` selector, lines 26-44, but no children to
   recurse into.)
8. Control returns to `SetPointLight.Update` → calls `ctx.PointLights.Pop()`
9. Control returns to `Transform.Update` → writes
   `previousWorldTobject` back into `ctx.ObjectToWorld`
10. Control returns to `RenderTarget.Update` → its own restore block runs.

**Who pulls whom:** Consumers pull producers. The renderer pulls
Transform.Output; Transform pulls SetPointLight.Output via its own Command
input; SetPointLight pulls DrawMesh.Output via its own Command input. The
*topology of the operator graph* defines the subtree shape; the *call stack*
realises the push/pop.

### Dirty flag and multi-input invalidation

`DirtyFlag.InvalidationRefFrame` is a static counter
(`DirtyFlag.cs:16` — `public static int InvalidationRefFrame = 0;`). Each
invalidation pass bumps it. For `Slot<Command>` the dirty machinery is mostly
moot for *whether* to run (it always runs), but `Slot<T>.Invalidate`
([`Slot.cs:269-326`](#)) still walks the graph to propagate invalidation
through the upstream side, which matters when Command subtrees contain
operators whose own outputs are *not* Command (e.g. a `SetMaterial.Reference`
output of type `Slot<PbrMaterial>`).

---

## EvaluationContext anatomy

Defined in `Core/Operator/EvaluationContext.cs`. Single `sealed class`
(`EvaluationContext.cs:33`), constructed once per top-level evaluation
(`Reset()` at `EvaluationContext.cs:43-58`).

| Field | Type | Push/pop pattern | Where used |
|---|---|---|---|
| `Playback` | `Playback` | immutable per-frame after `Reset` | `EvaluationContext.cs:102` |
| `LocalTime` | `double` (set) | overridden per-subtree by time ops | `EvaluationContext.cs:111` |
| `LocalFxTime` | `double` (set) | overridden per-subtree | `EvaluationContext.cs:117` |
| `RequestedResolution` | `Int2` | snapshot/restore in RenderTarget | `EvaluationContext.cs:121`, `RenderTarget.cs:81,140,158` |
| `CameraToClipSpace` | `Matrix4x4` | snapshot/restore in RenderTarget, cameras | `EvaluationContext.cs:123` |
| `WorldToCamera` | `Matrix4x4` | snapshot/restore in cameras | `EvaluationContext.cs:124` |
| `ObjectToWorld` | `Matrix4x4` | **stack (local-var snapshot)** in Transform/Group | `EvaluationContext.cs:125`, `Transform.cs:42-45`, `Group.cs:54-55,82` |
| `FogParameters` | `Buffer` | bag (set) | `EvaluationContext.cs:129` |
| `PbrMaterial` | `PbrMaterial` | **stack (local-var snapshot)** in SetMaterial / DrawMesh | `EvaluationContext.cs:132`, `SetMaterial.cs:48-65`, `DrawMesh.cs:26-44` |
| `Materials` | `List<PbrMaterial>` | **stack (Add/RemoveAt)** in SetMaterial | `EvaluationContext.cs:133`, `SetMaterial.cs:56,62` |
| `ContextTextures` | `Dictionary<string, Texture2D>` | **per-key snapshot/restore** in SetContextTexture | `EvaluationContext.cs:138`, `SetContextTexture.cs:22-33` |
| `PointLights` | `PointLightStack` | **explicit stack object** (Push/Pop) | `EvaluationContext.cs:140`, `SetPointLight.cs:22,26` |
| `BackgroundColor` | `Vector4` | snapshot/restore in RenderTarget | `EvaluationContext.cs:145` |
| `ForegroundColor` | `Vector4` | snapshot/restore in Group | `EvaluationContext.cs:150`, `Group.cs:48-81` |
| `ShowGizmos` | `GizmoVisibility` | bag | `EvaluationContext.cs:152` |
| `TransformGizmoMode` | `TransformGizmoModes` | bag | `EvaluationContext.cs:153` |
| `BoolVariables` | `Dictionary<string, bool>` | bag (cleared on `Reset`) | `EvaluationContext.cs:156` |
| `IntVariables` | `Dictionary<string, int>` | bag | `EvaluationContext.cs:157` |
| `FloatVariables` | `Dictionary<string, float>` | bag (with set/restore by variable ops) | `EvaluationContext.cs:158` |
| `ObjectVariables` | `Dictionary<string, object>` | bag | `EvaluationContext.cs:163` |
| `StringVariables` | `Dictionary<string, string>` | bag | `EvaluationContext.cs:168` |
| `IteratedList` | `StructuredList` | per-iteration (loop ops) | `EvaluationContext.cs:172` |
| `IteratedListIndex` | `int` | per-iteration | `EvaluationContext.cs:173` |
| `BypassCameras` | `bool` | snapshot/restore in RenderTarget | `EvaluationContext.cs:174`, `RenderTarget.cs:91,154` |
| `LegacyParticleSystem` | `LegacyParticleSystem` | bag/field | `EvaluationContext.cs:176` |
| `ParticleSystem` | `ParticleSystem` | bag/field | `EvaluationContext.cs:177` |

**Three idioms summarized:**

1. **Local-var snapshot stack** — the most common. Producer reads
   `prev = context.X`, writes new value, recurses, writes `context.X = prev`.
   Implicit stack via C# call frames. Used for scalars, structs, single-slot
   fields. (Transform, Group, RenderTarget, SetMaterial, SetContextTexture.)

2. **Explicit stack object** — only `PointLightStack`
   (`Core/Rendering/PointLightStack.cs:38`). Has its own
   `Push(PointLight)` / `Pop()` methods backed by a fixed-size array
   (`MaxPointLights = 8`, `PointLightStack.cs:40`). Probably explicit because
   the GPU constant buffer needs to track current depth and aggregate.

3. **Bag** — keyed dictionaries (`*Variables`, `ContextTextures`). Producers
   that *want* scope discipline (`SetContextTexture`) do per-key snapshot/
   restore manually; producers that don't care just write and leave it. The
   `Reset()` at evaluation start clears these.

The `PbrMaterial` "stack" is half-and-half: `context.PbrMaterial` is a single
field (snapshot/restore), but `context.Materials` is a `List<PbrMaterial>` that
`SetMaterial` `Add`s to ([`SetMaterial.cs:56`](#)) and `RemoveAt(Count-1)`s from
([`SetMaterial.cs:62`](#)) — i.e. used as a manual stack.

---

## What Command is NOT

Every claim below confirmed by reading `Core/DataTypes/Command.cs` in full
(10 lines):

| Claim | Confirmation |
|---|---|
| **Command does not carry a tree of children.** | The class has only `PrepareAction` and `RestoreAction`. There is no `Children`, `Subtree`, `List<Command>`, or equivalent field. Where you see a "subtree" semantically, it is an `InputSlot<Command>` *on the consuming operator* — i.e. the tree lives in the operator graph, not in `Command`. (`Command.cs:6-10`) |
| **Command does not carry a transform matrix.** | No `Matrix4x4`/`Transform` field exists on `Command`. `ObjectToWorld` is a field on `EvaluationContext` (`EvaluationContext.cs:125`), mutated by `Transform.Update` (`Transform.cs:42-45`). |
| **Command does not carry mesh data.** | No `Mesh`/`Buffer`/`MeshBuffers` field. `DrawMesh` reads its mesh from its own `InputSlot<MeshBuffers> Mesh` input (`DrawMesh.cs:86`); the mesh never travels through `Command`. |
| **Command does not carry material data.** | No material field. Materials flow via `context.PbrMaterial` and `context.Materials` (`SetMaterial.cs:48,56`). |
| **Command does not carry a list of draw calls.** | No collection of any kind. Draw calls are issued *inline* by leaf operators (e.g. `DrawMesh`) during their pull-induced `UpdateAction`. |
| **Command does not own the EvaluationContext.** | `EvaluationContext` is constructed externally (likely once per frame; see `EvaluationContext.cs:35-38` constructor + `Reset` at `:43`) and passed *into* every `UpdateAction` invocation. `Command`'s actions are `Action<EvaluationContext>` — they receive context as a parameter, they do not store it. |
| **Command is not invoked by the framework.** | `Slot<Command>.Update` invokes the *slot's `UpdateAction`* (`Slot.cs:165`), not the `Command.Value.PrepareAction`. Invoking `PrepareAction`/`RestoreAction` is the *consumer's* responsibility (e.g. `Group.cs:63, 75`; `Execute.cs:22, 34`). If nobody invokes them, they never run. |
| **Command does not enforce push/pop pairing.** | There is no framework-side guarantee that `RestoreAction` runs even if a sibling threw. The push/pop pairing is by convention. No `try/finally` in any of the producer `Update` methods inspected. |

---

## Hidden invariants and caveats

1. **`_valueIsCommand` is set in `Slot<T>`'s constructor and never re-evaluated**
   ([`Slot.cs:134`](#)). This means *only* a slot of exact type `Command`
   (not a subclass, not an interface) gets the dirty-flag bypass. If you
   subclass `Command`, you lose the "always re-run" behavior unless the
   slot is still typed `Slot<Command>`.

2. **`Command` is a `class`, not a `struct`.** ([`Command.cs:6`](#).)
   `Slot<Command>.Value` therefore stores a reference (or `null`). The default
   value for `new Slot<Command>()` is `null` ([`Slot.cs:130`](#) — `Value =
   default!`). Operators that want non-null must use `new Slot<Command>(new
   Command())` ([`PixelShaderStage.cs:7`](#)).

3. **`PrepareAction` is `init`-only; `RestoreAction` is plain `set`.**
   ([`Command.cs:8-9`](#).) In practice, observed usage sets `RestoreAction`
   in the operator constructor (e.g. `PixelShaderStage.cs:12`) but mutates
   nothing during evaluation. `PrepareAction` is never actually set in the
   inspected codebase — every consumer uses `t1.Value?.PrepareAction?.Invoke`
   with the null-conditional, so it gracefully no-ops. (Worth confirming with
   a wider grep — see open questions below.)

4. **Evaluation is recursive C# calls.** No queue, no scheduler, no
   topological sort visible at the operator-graph level — `GetValue` simply
   recurses through `InputConnections[0].GetValue(context)` in
   `ConnectedUpdate` ([`Slot.cs:171-174`](#)). Stack depth scales with graph
   depth; a deeply nested Transform/Group hierarchy can blow the stack.

5. **No threading model documented.** Slots have mutable fields
   (`Slot.cs:39 public T Value;`, plus `_dirtyFlag`, `UpdateAction`). Nothing
   in the inspected files takes a lock. The framework appears
   single-threaded-by-construction during evaluation. The single static
   `DirtyFlag.InvalidationRefFrame` ([`DirtyFlag.cs:16`](#)) reinforces
   this — a global counter would be a race otherwise.

6. **`Slot<Command>`'s dirty-flag bypass is *not* free.** Every Command-typed
   output re-runs its `UpdateAction` on every pull, even if nothing it depends
   on has changed. `Group` explicitly clears its `Commands.DirtyFlag` at the
   end of every update ([`Group.cs:79`](#)) — the framework doesn't expect
   stable values from a Command slot.

7. **The `Slot<Command>(new Command())` constructor path matters.**
   ([`Slot.cs:142-145`](#).) Operators that want Pattern B (PrepareAction/
   RestoreAction handoff) must construct a `Command` instance up-front in the
   slot initializer; the framework does not lazily allocate one.

8. **`MultiInputSlot<Command>.CollectedInputs` is the official "subtree
   list" API** ([`MultiInputSlot.cs:12-13`](#)). It flattens nested
   multi-inputs ([`MultiInputSlot.cs:32-40`](#)). Anything iterating
   "children" of a `Group`-like op uses this.

9. **`Slot<Command>` outputs are wired with `+=`, not `=`.**
   ([`Transform.cs:19`](#), `Group.cs:22`, etc.) This allows multiple update
   callbacks per slot, but in practice only one is registered. The pattern is
   uniform across the codebase.

10. **`DirtyFlagTrigger.Always` exists.** `SetPointLight.Output` is declared
    `[Output(... DirtyFlagTrigger = DirtyFlagTrigger.Always)]`
    ([`SetPointLight.cs:6`](#)). This forces invalidation each frame even
    beyond the `_valueIsCommand` bypass — relevant for propagation to non-Command
    slots downstream that *do* check dirty flags.

---

## Sources cited

Paths are relative to
`visual-programming/tixl/`.

- **`Core/DataTypes/Command.cs`** — entire file, 10 lines. The `Command`
  class definition.
- **`Core/Operator/EvaluationContext.cs`** — `EvaluationContext` class
  (`:33`), `Reset` (`:43-58`), all enumerated fields (`:102-177`).
- **`Core/Operator/Slots/Slot.cs`** — `Slot<T>` class (`:19`), `_valueIsCommand`
  flag (`:134, 348`), `Update` short-circuit (`:159-169`), `GetValue`
  (`:181-186`), `ConnectedUpdate` (`:171-174`), `UpdateAction` (`:336`),
  `Invalidate` (`:269-326`).
- **`Core/Operator/Slots/MultiInputSlot.cs`** — `CollectedInputs` (`:12-13`),
  `GetCollectedTypedInputs` (`:21-44`).
- **`Core/Operator/Slots/DirtyFlag.cs`** — `InvalidationRefFrame` static
  counter (`:16`).
- **`Core/Operator/Instance.cs`** — `Instance` class layout (`:13-50`),
  Outputs/Inputs lists (`:23-24`).
- **`Core/Rendering/PointLightStack.cs`** — `PointLight` struct (`:11-36`),
  `PointLightStack` (`:38`), `MaxPointLights = 8` (`:40`), `Push`/`Pop`
  (`:68-89`).
- **`Operators/Lib/Symbols/render/transform/Transform.cs`** — canonical Pattern A
  push/pop (`:22-46`); slot declarations (`:9-10, 48-64`).
- **`Operators/Lib/Symbols/render/transform/Group.cs`** — MultiInputSlot iteration
  + PrepareAction/RestoreAction calls (`:25-88`).
- **`Operators/Lib/Symbols/render/shading/SetPointLight.cs`** — explicit-stack
  push/pop (`:14-27`); `DirtyFlagTrigger.Always` (`:6`).
- **`Operators/Lib/Symbols/render/shading/SetMaterial.cs`** — `PbrMaterial` +
  `Materials` push/pop (`:21-69`).
- **`Operators/Lib/Symbols/render/shading/_/SetContextTexture.cs`** — per-key
  dictionary snapshot/restore (`:16-35`).
- **`Operators/Lib/Symbols/mesh/draw/DrawMesh.cs`** — leaf renderer (`:18-45`).
- **`Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs`** — outermost
  push/pop, DX11 root (`:40-233`).
- **`Operators/Lib/Symbols/flow/Execute.cs`** — Pattern B prepare/pull/restore loop
  (`:14-39`).
- **`Operators/Lib/Symbols/flow/Switch.cs`** — Pattern B with active-index limiting
  (`:30-89`).
- **`Operators/TypeOperators/Symbols/Gfx/PixelShaderStage.cs`** — Pattern B producer
  that constructs `new Command()` and wires `RestoreAction` (`:7-13`,
  `:41-53`).

---

## Anti-paraphrase note

Where this primer says "Command is a typed `void`," the literal source is:

```csharp
public class Command
{
    public Action<EvaluationContext> PrepareAction { get; init; }
    public Action<EvaluationContext> RestoreAction { get; set; }
}
```

(`Core/DataTypes/Command.cs`, lines 6-10, entire class.) No other fields, no
methods, no inheritance, no interfaces implemented. The "typed `void`"
description means: as a value type its only role is *being non-null vs null*,
and *holding optional bracket actions* — the meaningful work happens via the
slot's `UpdateAction` and the side effects it imposes on the shared
`EvaluationContext`.
