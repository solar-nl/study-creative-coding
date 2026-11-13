# tixl Compound Operator Mechanics: 12 Questions for flux-gpu

This document answers twelve specific architectural questions about tixl's graph-as-renderer design, traced from source code. These findings directly inform how flux-gpu should implement command-flow rendering.

## Priority 1 — Compound Operator Mechanics

### Q1: How does a compound operator's sub-graph get instantiated?

Four phases, each lazy:

**Phase 1 — Type registry at assembly load.**
Every class extending `Instance` has a `[Guid("...")]` attribute. At load time, `AssemblyInformation.TypeInfoExtraction.cs:117` scans assemblies, reads the GUID, and registers the type in a `ConcurrentDictionary<Guid, OperatorTypeInfo>`. Each entry pre-compiles a fast constructor via `Expression.Lambda<Func<object>>(Expression.New(type)).Compile()`. GUID is the sole identity primitive — there are no type-name strings in the hot path.

**Phase 2 — .t3 JSON → Symbol definition.**
`SymbolJson.ReadSymbolRoot()` deserializes each `.t3` file into a `Symbol` object holding `InputDefinitions`, `OutputDefinitions`, and `Connections`. Children are **not parsed yet** — the raw JSON array is stored as `ChildrenJsonArray` for deferred processing.

**Phase 3 — Children added to Symbol (still no instances).**
`SymbolPackage.ApplySymbolChildren()` runs in parallel. For each child JSON entry, it looks up the child's `SymbolId` in `SymbolRegistry`, creates a `Symbol.Child` record, and adds it to the parent Symbol's `Children` dictionary. At this point the complete symbolic graph exists (Symbol → Children → Connections), but zero `Instance` objects have been created.

**Phase 4 — Instance creation on first access.**
When evaluation first reaches a compound, `Symbol.Child.TryGetOrCreateInstance(path)` fires. It calls the pre-compiled constructor, creates the C# object, then immediately runs `ReconnectChildren()` to wire up all slot connections for the sub-graph.

**Each compound instance gets its own sub-graph.** Instances are stored in `Symbol.Child._instancesOfSelf`, a `Dictionary<int, Instance>` keyed by the hash of the full GUID path through the graph. Two uses of DrawMesh in the same scene have different path hashes and get separate Instance objects. The `Symbol` definition (the template) is shared; the `Instance` objects (the runtime state) are per-path.

```
.t3 file  →  Symbol (shared definition)  →  Instance (per-use, lazy)
                │                                │
                ├── InputDefinitions              ├── InputSlot<T> fields
                ├── OutputDefinitions             ├── Slot<T> fields
                ├── Symbol.Child[]                ├── InstanceChildren (lazy)
                └── Connection[]                  └── wired slot pointers
```

### Q2: How do ports bridge the compound boundary?

The `Guid.Empty` (`00000000-...`) in Connection records means "this compound's own port." Resolution happens in `Instance.Connections.cs:119-232`:

```csharp
if (sourceParentOrChildId == Guid.Empty)
    sourceSlotList = instance.Inputs;   // the compound's own InputSlots
else
    sourceSlotList = child.Outputs;     // a child's outputs

if (targetParentOrChildId == Guid.Empty)
    targetSlotList = instance.Outputs;  // the compound's own OutputSlots
else
    targetSlotList = child.Inputs;      // a child's inputs
```

**The graph is not flattened.** When an inner child's input is connected to the compound's exposed input, `targetSlot.AddConnection(sourceSlot)` stores a **direct in-memory pointer** to the outer compound's `InputSlot<T>`. At evaluation time:

```csharp
// Slot.cs:173 — ConnectedUpdate
Value = InputConnections[0].GetValue(context);
```

The inner child calls `GetValue()` on its input slot, which follows `InputConnections[0]` — a direct reference to the outer compound's `InputSlot<T>`. That call propagates outward to wherever the compound itself is connected. There is no boundary proxy, no indirection layer. It is a direct slot pointer that happens to cross the instance hierarchy.

### Q3: Can compounds nest? How deep does it go?

**Yes, nesting is unlimited.** `Symbol.Child.SearchForChild()` is recursive, and instance paths are `Guid[]` arrays that grow by one element per nesting level. The path hash is computed as a fold: `HashCode.Combine(hash, path[i].GetHashCode())`.

A real rendering path traces to 4-5 levels:

```
User scene (depth 0)
  └── DrawScene (compound, depth 1)
       └── _DispatchSceneDraws (C# executor, depth 2)

  └── DrawMesh (compound, depth 1)
       └── Execute (compound, depth 2)
            ├── SetPixelAndVertexShaderStage (C#, depth 3)
            ├── InputAssemblerStage (C#, depth 3)
            ├── OutputMergerStage (C#, depth 3)
            ├── Rasterizer (C#, depth 3)
            └── Draw (C#, depth 3)

  └── Bloom (compound, depth 1)
       └── _ExecuteBloomPasses (C# executor, depth 2)
            └── (internal: N-level pyramid passes, depth 3+)
```

In practice, rendering compounds bottom out at depth 3-4 where primitive C# operators make the actual DX11 calls.

---

## Priority 2 — Execute and Group Implementation

### Q4: How does Execute's three-phase lifecycle work with nested commands?

Execute's phases are **not recursive** — they are flat loops over direct children. Recursion happens when a child's `GetValue()` call triggers that child's own `Update`, which may itself contain an Execute with its own three-phase loop.

The concrete phases from `Execute.cs:14`:

```csharp
// Phase 1: PrepareAll — runs on PREVIOUS FRAME's Command.Value
for (i in 0..N) commands[i].Value?.PrepareAction?.Invoke(context);

// Phase 2: ExecuteAll — triggers each child's Update via GetValue
for (i in 0..N) commands[i].GetValue(context);

// Phase 3: RestoreAll — runs on CURRENT frame's Command.Value (updated in Phase 2)
for (i in 0..N) commands[i].Value?.RestoreAction?.Invoke(context);
```

**Phase 1 uses stale callbacks.** `commands[i].Value` in Phase 1 is the `Command` object from the previous frame — `GetValue()` hasn't been called yet. This is intentional: `PrepareAction` closures capture `this` (the operator instance) and are stable across frames. They save GPU state before any sibling has changed it.

**Phase 2 recurses through compounds.** When `commands[i].GetValue(context)` hits a compound like DrawMesh, it calls `DrawMesh.Update(context)`, which calls `Output.ConnectedUpdate(context)`, which enters the inner Execute's `Update`, which runs its own three-phase loop.

**Complete call stack for Group → 2× DrawMesh:**

```
Group.Update(ctx)
├── child1.PrepareAction(ctx)                    ← stale, typically null
├── child1.GetValue(ctx)
│   └── DrawMesh_A.Update(ctx)
│       └── Output.ConnectedUpdate(ctx)
│           └── Execute.Update(ctx)
│               ├── Phase 1: PrepareAll (5 children) — mostly null
│               ├── Phase 2: ExecuteAll
│               │   ├── InputAssemblerStage.Update()  — set topology, buffers
│               │   ├── SetShaderStage.Update()       — bind VS/PS/CBs/SRVs
│               │   ├── OutputMergerStage.Update()    — set blend, depth
│               │   ├── Rasterizer.Update()           — set cull, fill
│               │   └── Draw.Update()                 — deviceContext.Draw()
│               └── Phase 3: RestoreAll
│                   ├── InputAssemblerStage.Restore()
│                   ├── SetShaderStage.Restore()
│                   ├── OutputMergerStage.Restore()
│                   └── Rasterizer.Restore()
├── child1.RestoreAction(ctx)                    ← typically null for DrawMesh
│
├── child2.PrepareAction(ctx)
├── child2.GetValue(ctx)
│   └── DrawMesh_B.Update(ctx)                   ← same path, second draw call
└── child2.RestoreAction(ctx)
```

**Group vs Execute semantics differ:**
- **Execute** — PrepareAll, then ExecuteAll, then RestoreAll. All state operators are active simultaneously when Draw fires. Used **inside** compounds.
- **Group** — (Prepare → Execute → Restore) per child, sequentially. Each child is fully isolated. Used for **sibling objects** in a scene.

### Q5: How does Group propagate transforms to children?

**Implicitly, through EvaluationContext mutation.** Group does not wire transforms as graph connections. It mutates `context.ObjectToWorld` directly:

```csharp
// Group.cs:54-55
var previousWorldToObject = context.ObjectToWorld;
context.ObjectToWorld = Matrix4x4.Multiply(objectToParentObject, context.ObjectToWorld);
```

Children inherit the mutated value. The matrix flows through the following path:

```
Group.Update() sets context.ObjectToWorld
  → DrawMesh.Update() → Execute.Update()
    → SetPixelAndVertexShaderStage.Update()
      → ConstantBuffers.GetValues() calls:
        → TransformsConstBuffer.Update(context)
```

`TransformsConstBuffer.cs:48-60` reads the ambient context:

```csharp
var data = new TransformBufferLayout(
    context.CameraToClipSpace,
    context.WorldToCamera,
    context.ObjectToWorld);    // ← reads the mutated value
ResourceManager.UpdateConstBuffer(data, current);
```

`TransformBufferLayout` computes six derived matrices (ObjectToWorld, WorldToObject, ObjectToCamera, ObjectToClipSpace, WorldToClipSpace, ClipSpaceToWorld), packs them into a 640-byte constant buffer, and uploads to the GPU. The vertex shader reads `ObjectToWorld` from register b0.

**TransformsConstBuffer is internal to DrawMesh**, wired in the `.t3` sub-graph. The user-facing DrawMesh API exposes no transform inputs — transforms come entirely from the ambient context.

TransformsConstBuffer uses a **ping-pong double buffer** (`_cbA`/`_cbB` toggled each frame) so that shaders can access both the current and previous frame's transform for motion blur.

---

## Priority 3 — The Value/Command Boundary

### Q6: How does RenderTarget bridge command → value?

RenderTarget has one `InputSlot<Command>` (the scene to render) and three `Slot<Texture2D>` outputs (color, depth, normal). All three output slots share a single `Update()` method — the first consumer to request any output triggers the full render; the other two see already-filled `Value` fields.

The complete flow in `RenderTarget.cs:40-233`:

```
1. Pull value params: size, format, clear color      (normal dirty-flag cache path)
2. UpdateTextures(): create/resize DX11 textures      (only on format/size change)
3. Save GPU state: prevTargets, prevViewports          (DX11 OutputMerger)
   Save context state: matrices, resolution            (EvaluationContext)
4. Bind our render target + clear
     deviceContext.OutputMerger.SetTargets(_colorBufferRtv, _dsvBuffer)
     deviceContext.ClearRenderTargetView(clearColor)
5. Command.GetValue(context)                           ← THE SIDE-EFFECT PULL
     Forces re-execution every frame (_valueIsCommand = true)
     All child commands draw into our now-bound render target
6. Restore GPU state + context state
7. MSAA resolve (multi-sample → single-sample)
8. ColorBuffer.Value = resolved Texture2D              ← cache it as a value
   ColorBuffer.DirtyFlag.Clear()
   DepthBuffer.Value = ...; NormalBuffer.Value = ...
```

The transition is explicit: step 5 pulls the imperative command world (always re-executed, side-effectful). Step 8 stores the result in the value world (cached, dirty-flag gated). Downstream post-processing reads `ColorBuffer` without re-triggering the render.

### Q7: How do value and command nodes coexist?

**Type-level separation via a single boolean.** In `Slot.cs:133-134`:

```csharp
_valueType = typeof(T);
_valueIsCommand = _valueType == typeof(Command);
```

This is set once at construction via `typeof(T)` comparison. The evaluation branch at `Slot.cs:159`:

```csharp
if (_dirtyFlag.IsDirty || _valueIsCommand)
{
    UpdateAction?.Invoke(context);
    _dirtyFlag.Clear();
}
```

- **Value slots** (`_valueIsCommand = false`): only execute when dirty. Cached between frames.
- **Command slots** (`_valueIsCommand = true`): always execute. The dirty flag is cleared but irrelevant — `|| _valueIsCommand` short-circuits.

**Connection type checking** is enforced at `Slot.cs:211`:

```csharp
if (sourceSlot.ValueType != _valueType)
{
    Log.Warning("Type mismatch during connection");
    return;  // silently rejects the wire
}
```

You cannot wire a `Slot<Command>` output to a `Slot<Texture2D>` input. The editor also filters wire targets during dragging. **RenderTarget is the only sanctioned crossing point** — it explicitly holds both slot types and performs the GPU-to-texture conversion between them.

---

## Priority 4 — Multi-Pass Patterns

### Q8: How is Bloom implemented?

**Hybrid.** A thin compound (`.t3`) shell wires shader resources into a single opaque C# executor.

The compound `Bloom.t3` assembles:
- 5 `PixelShader` nodes (BrightPass, Downsample, SeparableBlur, Upsample, Copy — each loading a distinct `.hlsl`)
- 1 `VertexShader` node (fullscreen triangle)
- 2 `SamplerState` nodes (point + linear)

All feed into `_ExecuteBloomPasses` — a single C# class (`_ExecuteBloomPasses.cs:38-271`) that implements the full multi-pass pipeline imperatively:

```
1. BrightPass:    source → _brightPassTarget        (threshold + luminance)
2. Downsample pyramid (N levels):
     for level 0..N:
       lastSRV → _blurTargetsA[level]               (downsample)
       A → B                                        (vertical blur)
       B → A                                        (horizontal blur)
3. Copy source → _compositeTarget                   (point-sampler)
4. Upsample + additive blend (N levels reverse):
     for level N-1..0:
       _blurTargetsA[level] → _compositeTarget      (additive, weighted)
5. OutputTexture.Value = _compositeTarget
```

The `_` prefix convention signals internal infrastructure. The C# executor owns the texture pyramid (`List<RenderTargetSet>`), manages `D3D11StateBackup` for full pipeline save/restore, and uses a bisection root-finder to compute perceptual intensity weights per mip level.

**This is the standard pattern for multi-pass effects in tixl:** The `.t3` compound expresses which resources exist (shaders, samplers) as hot-reloadable graph nodes. The C# `_Executor` does all actual GPU work imperatively.

### Q9: How are shadow maps handled?

**`SetShadow` is a compound** that re-renders the scene from a light's perspective. Its `.t3` sub-graph:

1. Allocates color + depth `Texture2d` at shadow resolution
2. Sets `context.IntVariables["__IsShadowPassId"] = 1` (via `SetIntVar`)
3. Sets `context.MatrixVariables["_WorldToLightClipSpace"]` (via `SetMatrixVar`)
4. Calls `Execute(Command)` — the scene geometry re-renders into the shadow map
5. Stores depth texture into `context.ContextTextures["ShadowMap"]` (via `SetContextTexture`)
6. Clears `__IsShadowPassId = 0`
7. Calls `Execute(Command)` again — normal render with shadow map available

**Multiple lights = multiple `SetShadow` nodes**, each wired separately. There is no loop or array-of-lights system. Each shadow-casting light is a separate graph-level command that re-traverses the entire scene geometry.

Shadow state propagates through **named context dictionaries** (`IntVariables`, `ContextTextures`), not typed connections. Draw operators must explicitly opt in by checking `__IsShadowPassId` and sampling `"ShadowMap"` from context.

### Q10: How does ExecRepeatedly work?

`ExecRepeatedly.cs` re-evaluates its children N times per frame:

```csharp
// Phase 1: Prepare once
for (i in 0..N) commands[i].Value?.PrepareAction?.Invoke(context);

// Phase 2: Execute N times
for (rep in 0..repeatCount)
    for (i in 0..N) commands[i].GetValue(context);

// Phase 3: Restore once
for (i in 0..N) commands[i].Value?.RestoreAction?.Invoke(context);
```

**Children do NOT know which iteration they're on.** ExecRepeatedly writes no loop index. It has a `SkipFrameCount` input for throttling (skip N frames between bursts), but no iteration variable.

For iteration-aware repetition, tixl has a separate `Loop` operator (`Loop.cs:14-41`):

```csharp
for (var i = 0; i < end; i++)
{
    context.FloatVariables[indexVariableName] = i;
    context.IntVariables[indexVariableName] = i;
    context.FloatVariables[progressVariableName] = i / (float)(end - 1);
    DirtyFlag.InvalidationRefFrame++;  // force re-evaluation
    Command.Invalidate();
    Command.GetValue(context);
}
```

`Loop` writes named float/int variables into `context.FloatVariables`/`context.IntVariables`. Children read them with `GetFloatVar`/`GetIntVar` nodes.

**ExecRepeatedly** = blind repetition for stateful simulation steps.
**Loop** = iteration-aware repetition with named index variables.

---

## Priority 5 — Serialization and Runtime Binding

### Q11: How does the .t3 format reference GPU resources?

**Two-phase, lazy and demand-driven.**

**Phase 1 (parse):** When the `.t3` file is loaded, `InputSlot<string>` values are wired with the shader path string (e.g., `"Resources/lib/3d/mesh/mesh-Draw.hlsl"`). No compilation happens.

**Phase 2 (first evaluation):** When evaluation first reaches a `VertexShader` or `PixelShader` operator, its `UpdateAction` fires:

```csharp
// IShaderOperator.cs:128-150
var resource = ResourceManager.CreateShaderResource<T>(Path, () => CachedEntryPoint);
resource.GetValue(context);  // triggers compile if file changed
```

`ResourceManager.CreateShaderResource` creates a file-watched `Resource<TShader>`. The first `GetValue` call reads the HLSL from disk, compiles it via `ShaderCompiler.TryCompileShaderFromSource`, and caches the result. The cache key is `(sourceHash × entryPoint)` as a 64-bit integer. Subsequent frames return the cached shader unless the file has been modified on disk (detected via file watcher).

For runtime-generated shaders (e.g., SDF raymarchers), `VertexShaderFromSource`/`PixelShaderFromSource` take the HLSL source as a `string` input slot rather than a path. The same compilation pipeline runs, but triggered by the source string changing rather than a file watcher.

### Q12: Are there nodes that can't be defined in .t3?

**Three categories exist:**

| Category | Count | Examples |
|----------|-------|---------|
| **Pure compound** (slot declarations only, all work in `.t3` sub-graph) | Most high-level operators | `Bloom.cs`, `SetShadow.cs`, `ShadowPlane.cs` |
| **Pure C# executor** (all GPU work in `Update()`, no meaningful `.t3` children) | Common for multi-pass | `_ExecuteBloomPasses.cs`, `_ReprojectShadowMap.cs`, `_DispatchSceneDraws.cs`, `Draw.cs`, `Rasterizer.cs` |
| **C# hybrid with ICompoundWithUpdate** | Very rare (only 2 found) | `DrawMesh.cs`, `DrawScene.cs` |

**`ICompoundWithUpdate`** is a marker interface (`Core/Operator/Interfaces/ICompoundWithUpdate.cs`) with a single effect: it prevents `Slot.AddConnection()` from replacing the compound's custom `UpdateAction` with `ConnectedUpdate`. This lets the C# class run code before and after the sub-graph evaluates:

```csharp
// DrawScene.cs — the canonical example
private void Update(EvaluationContext context)
{
    var previousMaterial = context.PbrMaterial;
    context.PbrMaterial = selectedMaterial;   // push material
    Output.ConnectedUpdate(context);          // evaluate sub-graph
    context.PbrMaterial = previousMaterial;   // pop material
}
```

Both `DrawMesh` and `DrawScene` use this exclusively for material injection — pushing `context.PbrMaterial` before the sub-graph and restoring after.

**What `.t3` cannot express:**
1. Imperative loops over GPU resources (texture pyramids with runtime N)
2. DX11 state save/restore around a block of draw calls (`D3D11StateBackup`)
3. Context mutation with restore around sub-graph evaluation (requires `ICompoundWithUpdate`)
4. Forced dirty-flag invalidation mid-evaluation (`Loop` calls `DirtyFlag.InvalidationRefFrame++`)

The `_` prefix convention marks internal C# executors. Public-facing compounds (no `_`) are the user API; `_`-prefixed nodes are implementation details visible only inside compound sub-graphs.

---

## Synthesis: What This Means for flux-gpu

### The graph-as-renderer pattern requires four primitives

1. **Symbol/Instance split** — shared definitions, per-use instances. In Rust: `Arc<SymbolDef>` + owned `OperatorInstance` per path.

2. **Dual-mode slot evaluation** — one boolean (`_valueIsCommand`) changes whether a slot caches or always re-executes. In Rust: a `SlotKind` marker trait with `const fn always_execute() -> bool`.

3. **Two composition primitives** — Execute (parallel state assembly: prepare all → execute all → restore all) and Group (sequential object iteration: per-child bracket). Both are needed; they serve different purposes.

4. **RenderTarget as the phase boundary** — the only operator that holds both `InputSlot<Command>` and `Slot<Texture2D>`. Commands above, values below. The transition is explicit and auditable.

### The `_` executor pattern is the key insight for multi-pass

Complex GPU operations (Bloom, shadow maps, scene dispatch) are not graph-composed — they are **code-composed inside a single C# class** that the graph wires resources into. The graph provides composability and hot-reloadability for resource references (which shader, which sampler). The executor provides the imperative multi-pass logic.

For flux-gpu: don't try to express a Bloom pyramid as graph nodes. Express it as a `BloomExecutor` that receives compiled shader handles from the graph and runs the multi-pass loop internally.

### Context-variable conventions should be typed

tixl's `context.IntVariables["__IsShadowPassId"]` and `context.ContextTextures["ShadowMap"]` work but are stringly-typed. In Rust, use typed fields or a `TypeMap` on EvaluationContext. Shadow participation should be a trait, not a name lookup.

### Compound boundary crossing is just a pointer

The absence of a boundary proxy is elegant — inner slots hold direct references to outer slots. In Rust, this maps to `Weak<SlotState<T>>` or index-based slot references within an arena allocator. The key is that evaluation traverses slot references without caring about compound boundaries.
