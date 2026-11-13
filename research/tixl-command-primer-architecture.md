# Primer: tixl `Command` — Architecture and Principle Analysis

**Date:** 2026-05-21
**Companion primers:** *Internals* (Slot mechanism, push/pop, eval lifecycle), *Patterns* (canonical Command-tree shapes in real projects).
**This primer's contribution:** cross-framework comparison + direct answer to the principle question.

---

## TL;DR

**`Command` honors the topology-not-values principle — it is a value type in name only.** The `Command` class in `Core/DataTypes/Command.cs` is two nullable callback fields (`PrepareAction`, `RestoreAction`); the `Value` field on a `Slot<Command>` is *never* a tree. The hierarchy in `Transform { Camera { RenderMesh(box) } }` lives entirely in the operator-graph wires (`InputSlot<Command>` connections + `MultiInputSlot<Command>` fan-in on `Group`). Each parent operator's `UpdateAction` mutates `EvaluationContext`, calls `GetValue(context)` on its child `Command` slot — which recursively runs the child's `UpdateAction` — and then restores. `Command` is a *typed protocol marker* meaning "this slot, when pulled, executes a draw-side-effect under current context." On the same axis, Werkkzeug's `Wz4Render` (despite the verbal label "tree of render commands") is the same shape: operators of type `Wz4Render` compose by wiring with `Render(?*Wz4Render)`-style variadic ports. Three.js's `Object3D` is the structurally-opposite case — there the hierarchy really is value-internal. Flux's existing `Region` operators are a *narrower* version of the same idea, scoped to specific concerns (render-pass, loop, accumulate). Command generalizes the Region pattern to "scope arbitrary ambient state."

The single most surprising finding: **`Command` is closer to flux's `Region::*` enum tag than it is to flux's `Value::Texture`.** It's a port-type marker, not a payload.

---

## The principle being tested

Restated in this primer's words:

> **A value type passes the principle if no author would ever want to "wire into" a specific part of its contents.** If an author would naturally want to address some sub-piece (entity #3's rotation, light #2's color, the second child of a group), then that sub-piece belongs in graph topology — as its own operator or its own port — and the value type's internal structure is hiding load-bearing graph information.

What makes a value type *fail* the test:

1. The value carries multiple addressable sub-objects.
2. Authors would normally want to inspect, replace, override, or animate one of those sub-objects independently.
3. The structure is therefore load-bearing *as graph topology* but is hidden inside the value.
4. Symptom: tooling can't show the structure on the canvas; identity is forced into the value layer; "two evaluation models" appear (the outer dataflow plus the inner walk).

What makes a value type *pass*:

- Atomic scalar/composite leaf with no internally-addressable parts (`Matrix4`, `Vec3`, `Color`).
- An opaque resource handle (a `Texture` is identifiable but not internally addressable in port semantics — nobody wires "row 17 of texture A" anywhere).
- A typed *protocol marker* whose Value never carries the substantive content — content lives in the topology.

The third category is the crucial subtle one. It's where `Command` lives.

---

## Is Command a value?

Direct evidence from source. The entirety of the `Command` class:

```csharp
// Core/DataTypes/Command.cs
namespace T3.Core.DataTypes;

public class Command
{
    public Action<EvaluationContext> PrepareAction { get; init; }
    public Action<EvaluationContext> RestoreAction { get; set; }
}
```

Two nullable callbacks. No children, no operator references, no tree. That's the whole type. No tree means no internally-addressable sub-parts means **the "opaque composite with hidden structure" objection does not apply by construction — there is no internal structure to hide.**

Where does the work actually live? Not in the `Command` value but in the operator's `Slot.UpdateAction`:

```csharp
// Operators/Lib/Symbols/render/transform/Transform.cs
public Transform()
{
    Output.UpdateAction += Update;          // 1. Wire side-effect onto the OUTPUT SLOT
}

private void Update(EvaluationContext context)
{
    // ... compute objectToParentObject ...
    var previousWorldTobject = context.ObjectToWorld;     // 2. PUSH
    context.ObjectToWorld =                                //    onto the
        Matrix4x4.Multiply(objectToParentObject,           //    EvaluationContext
                           context.ObjectToWorld);          //    (NOT into a value!)
    Command.GetValue(context);                              // 3. PULL the child
                                                           //    (this recursively runs
                                                           //     the child's UpdateAction)
    context.ObjectToWorld = previousWorldTobject;           // 4. POP
}
```

`Transform`'s output is typed `Slot<Command>`, but the `Command` *value* on that slot is never set by `Transform.Update()`. The output slot exists for two reasons:

1. **Typing**: it declares "I am a downstream-execution endpoint that can be plugged into another `InputSlot<Command>`."
2. **Pull triggering**: when a parent calls `Output.GetValue(context)`, the framework runs `UpdateAction` (= the push/pull/pop), and *as a side effect* the GPU draw happens.

The `Command.Value` field can be non-null in operators that genuinely need to expose `PrepareAction` / `RestoreAction` separately (e.g. for the `Group` collector to call them in order — see below), but it is never the carrier of "the subtree." The subtree is carried by **the operator graph itself**: the `InputSlot<Command> Command` field on `Transform` is a graph edge, not a data slot.

**Conclusion of section:** `Command` is a typed marker on a Slot that means *"pulling this triggers a downstream draw-side-effect under current context."* It carries no tree, no list of operators, no scene graph. It is closer in spirit to a Rust `()` or a Haskell `IO ()` — a marker that the slot's purpose is *effect*, not *data*.

---

## Where the hierarchy actually lives

Walk through `Transform { Camera { RenderMesh(box) } }` end to end.

**Step 1: graph topology (what the author wires in the editor).**

```
[CubeMesh] ──output──┐
                     ▼
              [RenderMesh] ──Output(Command)──┐
                                              ▼
                                       [Camera] ──Output(Command)──┐
                                                                   ▼
                                                          [Transform] ──Output(Command)──> ...root
```

Each operator declares its output as `Slot<Command>` (or `TransformCallbackSlot<Command>`) and its child-receiving input as `InputSlot<Command>`. The wires between these slots are the **only** place the parent/child relationship lives. There is no `Command` value anywhere on disk that says "Transform's child is Camera." The `.t3` symbol file records the wire from `Camera.Output` → `Transform.Command`.

**Step 2: pull-evaluation walks the topology, mutating context.**

When the frame's root output asks `Transform.Output.GetValue(context)`:

1. `Transform.Update(context)` runs.
2. It pushes the local-to-parent matrix onto `context.ObjectToWorld`.
3. It calls `this.Command.GetValue(context)` — this is the *input* slot.
4. The input slot is wired to `Camera.Output`, so this triggers `Camera.Update(context)`.
5. `Camera.Update` mutates `context.CameraToClipSpace` / `WorldToCamera`, then calls `this.Command.GetValue(context)` on its own child input.
6. That's wired to `RenderMesh.Output`, so `RenderMesh.Update(context)` runs.
7. `RenderMesh` reads `context.ObjectToWorld`, `context.WorldToCamera`, `context.CameraToClipSpace`, `context.Materials`, `context.PointLights`, etc., and *issues a GPU draw*.
8. Control returns up the call stack. Each parent restores the context fields it pushed.

**Where is the hierarchy in this sequence?**

- It is **not** in any value flowing along wires. The `Command.Value` field is null for `Transform`, `Camera`, and `RenderMesh` outputs in normal use (or, if set, carries only `PrepareAction`/`RestoreAction` callbacks for the `Group` collector — see below).
- It is **in the graph wires** (`Transform.Command` ← `Camera.Output`, `Camera.Command` ← `RenderMesh.Output`).
- It is **manifested at runtime in the evaluation stack frames**, which mirror the wire topology by recursive `GetValue` calls.
- The push/pop discipline guarantees correct nesting because **the same call stack that walks the wires is the call stack that pushes/pops the context**. They cannot diverge.

This is the load-bearing observation: tixl does not have "two evaluation models." It has *one* evaluation model — pull-based dataflow — and `Command` is a port-type label that says "this connection is the pull-edge of a draw subtree." The "scene walk" is just dataflow with side effects.

**One subtlety — Group's MultiInputSlot.** `Group` accepts many `Command` children:

```csharp
// Operators/Lib/Symbols/render/transform/Group.cs
public readonly MultiInputSlot<Command> Commands = new();

private void Update(EvaluationContext context)
{
    // ...push group transform onto context...
    var commands = Commands.CollectedInputs;
    foreach (var t1 in commands)
    {
        t1.Value?.PrepareAction?.Invoke(context);
        t1.GetValue(context);          // ← actually run the child subtree
        t1.Value?.RestoreAction?.Invoke(context);
    }
    // ...pop group transform...
}
```

This is the only place `Command.PrepareAction` / `RestoreAction` matter, and it's still topology-flat: `MultiInputSlot<Command>` is a port with N wires fanning in, not one wire carrying a list-of-commands value. The hierarchy stays in topology; the per-child prepare/restore hooks are out-of-band callbacks for special needs (e.g. a child that needs to set up its own render target before its siblings inside the same group).

---

## Comparison: Werkkzeug `Wz4Render`

The synthesis file describes `Wz4Render` as "a separate type representing a tree of render commands" and "the entire scene-graph abstraction." On its face that sounds like the opaque-composite case the user fears — a value type whose contents are a tree.

Reading the operator signatures the inventory provides:

> `Render` ("Add"), `RenderNull`, `Camera(?Rendertarget2D, ?*Wz4Render)`, `BillboardCamera`, `RenderMesh`, `Layer2D`, `SkyCube`, ... — `wz4_demo2_ops.ops`
>
> Input cardinality declared in the signature: `Render(?*Wz4Render)` — zero or more `Wz4Render` children.

That `?*Wz4Render` is the giveaway. **It's a variadic port of `Wz4Render`-typed inputs, not a single `Wz4Render` value with internal children.** Each `Wz4Render` is the *output* of a different operator; `Render`'s tree shape comes from how many of these outputs the author wires into it.

Concretely:

- A user writes `Render(meshA, meshB, meshC)` by placing three `RenderMesh` ops and three wires into one `Render` op.
- The `Wz4Render` type itself, like `Command`, must be an opaque marker (or a thin handle) that says "I am an output of a renderable op." The "tree" of `Wz4Render` is the wire graph of `Wz4Render`-typed connections.
- Werkkzeug's GUI shows the children of a `Render` op as separate operator nodes connected by wires — not as a JSON tree inside a single op's parameters.

The verbal label "tree of render commands" is technically true in the same way the verbal label "tree of `Command` slots" is true for tixl. **Both refer to a tree shape that exists in the operator graph topology, not inside any value.** The two frameworks are *structurally identical* on this axis — `Wz4Render` and `Command` are both port-type markers for "pull-edge of a draw subtree."

Confirming evidence for the structural identity:

- Werkkzeug `Wz4Render Transform(Wz4Render)` — exactly tixl's `Transform { Command: InputSlot<Command>; Output: Slot<Command> }`.
- Werkkzeug `Wz4Render Multiply(Wz4Render, count, delta-transform)` — instancing a subtree N times by wrapping it in a `Multiply` operator (the subtree is the wired-in child, the data is the count + delta).
- Werkkzeug post-stack `Wz4Render(Wz4Render)` chain — tixl's `Bloom`-takes-Command-returns-Command exactly.

Caveat — what this primer can't confirm from source: I did not open the Werkkzeug C++ source to confirm `Wz4Render` is a thin marker class vs. a value that internally holds children. The synthesis describes it consistently with the marker reading, and the variadic-port signatures (`?*Wz4Render`) are direct evidence the children live as separate operator outputs. **If `Wz4Render` turns out to be a value-type with internal child pointers, that would contradict this section; flag as a high-priority verification target if the comparison matters for a decision.**

---

## Comparison: three.js Object3D

`Object3D` is the structurally-opposite case. From the three.js inventory:

> Retained `Object3D` tree with parent/child transforms, world-matrix propagation, layers, and visibility flags — the spine of every three.js project.

In code: `Object3D` is a JavaScript class with a `children: Object3D[]` array and `parent: Object3D | null` references. The renderer (`WebGLRenderer.render(scene, camera)`) walks `scene.children` recursively. The tree is the value. There is no operator graph at the project layer — only an imperative API the user calls to build the tree.

Translating to the principle test:

- An author absolutely does want to address individual nodes ("rotate cube #3 around the Y axis"). Three.js answers this by giving each `Object3D` a `.uuid` and an `.id` and exposing `scene.getObjectByName(...)` / `getObjectById(...)`.
- The tree is mutable in place: `cube.position.y += 0.1` is the canonical update.
- The structure is load-bearing but lives entirely inside the value graph (or, more precisely, inside the in-memory object graph). External tooling has to introspect the heap to see it; a node graph's wires never see it.
- There is no "outer" pull-dataflow at all in three.js — the only evaluation model *is* the scene walk.

So `Object3D` fails the principle test exactly the way the user fears, but it fails *because three.js is not a node-graph framework in the first place*. The hierarchy lives in values not because the designers chose value-tree-over-topology, but because there is no topology layer.

This is the contrast that anchors the analysis: **value-typed scene tree is what you get when you don't have a graph.** Tixl, having a graph, doesn't need it. `Command` is an opaque marker because the structure has somewhere else to live (the wires).

Three.js TSL (the shader language) makes the same boundary visible from inside three.js: when the team built a node graph (TSL, for shaders), they used edges-not-values for the hierarchy; when they kept retained-mode (the scene), they used value-tree. The boundary is "do you have a graph or not," not "do you like opaque values or not."

---

## Comparison: flux's existing Region operators

Flux already has `Region::RenderPass`, `Region::Loop`, `Region::Accumulate`. These are operators whose effect is to *scope* an enclosed subgraph: a `Region::RenderPass` wraps a set of draw operators and binds them to a render target; `Region::Loop` wraps a subgraph and runs it N times; `Region::Accumulate` wraps a feedback step.

Architectural shape (from inspection of `libs/flux/flux-eval/tests/region_render_pass_test.rs`, `region_loop_test.rs`):

- A Region is an operator. Its inputs include some exposed slots that surface from the enclosed subgraph (e.g. `pipeline` exposed from `FullscreenDrawOp.pipeline`, or `color_0` standard inputs).
- The enclosed subgraph is *referenced by the Region operator* and evaluated under a scoping context (the render-pass encoder, the loop counter, the accumulate state).
- The hierarchy lives in the graph: the Region's children are explicit graph nodes; the Region itself is an explicit operator.
- The Region is a scope-pusher: it pushes a render-pass / loop-iteration / accumulation context, evaluates the children, pops.

**This is precisely the same architecture as tixl's `Command`-typed scope operators.** Side by side:

| Concept                    | tixl                                                | flux Region                              |
|----------------------------|-----------------------------------------------------|------------------------------------------|
| Operator that pushes scope | `Transform`, `Group`, `SetMaterial`, `SetFog`, ...  | `Region::RenderPass`, `Region::Loop`, ...|
| Port type marker           | `Slot<Command>` / `InputSlot<Command>`              | Region exposed-slot machinery            |
| Subtree referent           | wires to / from `InputSlot<Command>`                | enclosed subgraph reference              |
| Scope state                | `EvaluationContext` (matrix, materials, lights, ...)| pass encoder, loop var, accum state      |
| Push/pop discipline        | parent's `Update` mutates context, calls `GetValue`, restores | Region operator wraps child evaluation |

**The strong reading: tixl's `Command` is what flux's `Region` family looks like when you generalize from "wrap render-pass / loop / accumulate" to "wrap *any* ambient state — transform, material, light, fog, environment, time, playback, requested-resolution."**

Two important differences worth flagging:

1. **Region is currently an enum-tagged operator family in flux** (`Region::RenderPass`, `Region::Loop`, `Region::Accumulate`); tixl ships dozens of independent operators (`Transform`, `Group`, `SetMaterial`, `SetPointLight`, `SetFog`, `SetShadow`, `SetEnvironment`, `Layer2d`, ...) all returning the same `Slot<Command>` type. The tixl pattern allows the *operator catalog* to grow arbitrarily without the framework needing to learn new region kinds. Flux's enum-tag pattern is closed: adding `Region::Transform` means changing the enum.

2. **Region's body is structurally distinct in flux's IR** — a Region knows about its enclosed subgraph as a Symbol/Instance reference, evaluated under a specific scheduling discipline. Tixl's "Command subtree" is *just operators wired into an InputSlot* with no special enclosure status; the framework doesn't know it's a "subtree" — it's just upstream-of-this-pull-edge. The catalog uniformity comes at the cost of the framework being unable to introspect "the subtree" as a thing (since there isn't one — there are only upstream operators, the same as for any pull-input).

Item 2 is the central architectural tradeoff: **tixl gains catalog extensibility (any operator can be a scope) at the cost of subtree identity (the framework has no first-class notion of "the children of this scope").** Flux's Region pattern gains first-class subtree identity at the cost of needing a new Region kind for every new ambient state.

---

## Verdict on the principle question

**`Command` honors the principle.** Direct answer with evidence:

1. The `Command` *value* (the C# class) is two nullable `Action<EvaluationContext>` fields. It has no children, no sub-operators, no internally-addressable parts. **There is no internal structure for tooling to be blind to.**

2. The hierarchy of `Transform { Camera { RenderMesh(box) } }` is fully visible **in the operator-graph wires**: each parent has an `InputSlot<Command>` whose connection is a graph edge to a child operator's `Slot<Command>` output. The editor canvas shows it; the `.t3` symbol file serializes it as wires; tooling can walk it via the same connection-introspection used for every other port type.

3. Identity stays in the operator graph. Each operator instance has its own GUID (from `[Guid(...)]` attributes), addressable by the same machinery as every other operator. There is no per-Command identity because there is no per-Command anything.

4. The push/pop scope discipline runs *inside* the standard pull-evaluation. There is no parallel scene-walk pass; the dataflow IS the walk.

5. The "wire into a specific part of this value?" test: nobody wires into `Command.PrepareAction` directly. They wire into operator input slots — `Transform.Translation`, `Camera.Position`, `RenderMesh.Mesh`. Each of those is a typed port on a graph-visible operator. The structural authoring affordances live where the principle says they should.

**Where uncertainty remains:**

- `Command.Value` is non-null in some cases (it must be, since `Group.Update` reads `t1.Value?.PrepareAction`). I have not exhaustively surveyed which operators set `Command.Value` and what they put there. The reading consistent with all evidence I've seen is: when set, it carries the operator's own `PrepareAction`/`RestoreAction` callbacks for the *parent's* benefit (so a `Group` can run prepare/restore in iteration order). This still doesn't put structure inside the value; it just lets a parent reach a child's hook. **If some operator sets `Command.Value` to a complex object that *does* carry tree shape, the verdict would need revision.** I haven't found one; flag as a possible hole.

- The variadic `MultiInputSlot<Command>` on `Group` could be argued either way: it does collect N children into one parent. But `CollectedInputs` returns the list of *input slots* (each with its own wire), not a list of value-objects. The list is over edges, not over value internals. This keeps the topology view intact.

---

## The two-evaluation-models objection

The user argued: mixing pulled dataflow with walked scene graph composes awkwardly. Does tixl hit this?

**No, because tixl does not have two evaluation models.** It has one — pull-based dataflow with side effects — and `Command` is a typed marker that says "the side effect is a draw."

The reason this works:

- Every operator's `UpdateAction` is the same shape: read inputs, compute, write outputs (or side-effect the context).
- The only difference between a "value-typed operator" (e.g. `AddVec3`) and a "Command-typed operator" (e.g. `Transform`) is what they do during `UpdateAction`. The value-typed one assigns `Output.Value = ...`. The Command-typed one mutates `context.ObjectToWorld`, calls `Command.GetValue(context)` to pull the child, and restores.
- Both kinds of operator are pulled by the same `GetValue` call from their parent. Both kinds participate in the same dirty-flag invalidation, the same per-frame walk, the same connection-resolution.
- The "scene walk" is just the subset of the pull-dataflow walk that happens to flow through `Command`-typed edges.

Contrast with the failure mode the user fears (three.js):

- Three.js's `WebGLRenderer.render(scene, camera)` is a *separate top-level entry point*. It walks `scene.children`, builds a render list, sorts, culls. This is genuinely a second evaluation model.
- If a user wanted to drive `scene.children[3].position` from outside data, they'd write JS that pokes the value — there's no graph for that data to flow through.

The composition awkwardness in three.js comes from having two pipelines (your data → scene mutation, renderer → render list construction) glued by mutable state. Tixl avoids it by having one pipeline (pull-evaluation) and putting the renderer call deep inside it as a leaf side effect.

**Where the awkwardness could re-appear in tixl:**

- If you want to do something *to* a scene that requires walking it (compute a bounding box, raycast, gather all lights into a list), you have a problem. Tixl's `Command` can't be inspected — `GetValue(context)` just *runs the draws*. There's no way to "collect" the draws into a list of meshes without writing a parallel "collect mode" pass that all the Command-emitting operators would have to participate in. This is the cost: **you trade introspectability for marker-purity.** A value-typed scene tree (three.js's `Object3D`) is walkable for arbitrary purposes; a marker-typed command edge is only "runnable."
- In practice tixl pays this cost by having `EvaluationContext.PointLights` (an explicit accumulator list pushed onto by `SetPointLight` ops) and similar. The collection pass is folded into the same pull walk by making accumulators part of the context.

The general principle: **markers compose cleanly with dataflow because they are dataflow with side effects. Value-typed trees compose awkwardly because they're a parallel model. The cost of going marker-only is loss of post-hoc introspection — you can't ask "what's in this scene" without re-evaluating with a different effect mode.**

---

## The identity question

In a Command tree, do individual draw nodes have identity? Can an author "address" them from outside?

**Yes — they have operator-instance identity, addressable by graph path / GUID, the same as any other operator.** No — they do not have *Command-value* identity, because the Command value is a thin marker and doesn't carry a per-node ID.

Concretely:

- Each operator instance is uniquely identified by its position in the operator graph (Symbol child id, or in flux's case `InstanceId`). It also carries a stable `[Guid(...)]` from source.
- An author who wants to animate "the rotation of the third box" addresses the *operator instance* (`RenderMesh` at graph path X) and animates its `Rotation` port (or, in tixl, the input port that feeds the `Transform` wrapping it).
- An author cannot say "the Command emitted by this Transform" as a distinct addressable thing — there's nothing to address. The Command is the act of being pulled; you address the act by addressing the operator that performs it.

Comparison to three.js: every `Object3D` has `.uuid` (stable, persistent identity inside the value graph) and `.id` (process-lifetime integer). You can hold a reference to an `Object3D` from a separate part of your code, mutate its `position` directly, and the next render frame picks up the change. The identity lives in the value layer.

In tixl, the same workflow looks like: the operator instance has identity in the graph layer; to "mutate it from outside," you wire a new connection into one of its input ports. There's no value-layer identity *because there's no value-layer*.

**Implication:** the kind of authoring affordance "drag this transform gizmo and the cube follows" works *because the gizmo is bound to an operator instance, not a Command*. Tixl's `ITransformable` interface (visible on `Transform`, `Group`, `Layer2d`) lets the editor surface a transform gizmo whose drags write into the operator's `Translation`/`Rotation`/`Scale` *input slots* — i.e., into the graph layer. The Command-typed output stays opaque.

This is consistent with the principle: identity that you might want to address belongs to operators, not to values flowing on wires.

---

## Implications for flux — sketch options

Three distinct shapes flux could take if it wanted a Command-equivalent. **No recommendation here — this primer is about the principle question, not the design choice.**

### Sketch A: a new opaque marker value `Value::DrawCmd`

- Add `Value::DrawCmd(())` (or similar zero-content variant) to the existing `Value` enum.
- Operators like `TransformOp`, `GroupOp`, `SetMaterialOp` declare their output port as `Value::DrawCmd`.
- The evaluator treats `DrawCmd`-typed edges as pull-edges-with-side-effect: pulling them runs the operator's effect closure under the current `EvalContext`, including a push/pop of the context scope.
- The hierarchy lives in flux's existing graph wires; no new IR concept needed.
- Catalog grows by ordinary operator authoring: any operator that declares a `DrawCmd` output port participates.
- Cost: requires plumbing in the evaluator to know that `DrawCmd` pulls have side-effects on `EvalContext` and that the context push/pop is the operator's responsibility (a slightly different mental model from "operator computes a Value and stores it").

### Sketch B: generalize `Region` to scope arbitrary ambient state

- Keep the existing `Region::RenderPass` / `Region::Loop` / `Region::Accumulate` machinery; expand the enum to cover transform / material / light / fog / etc.
- Each new region kind defines what it pushes onto `EvalContext` and how it composes with siblings.
- The subgraph identity stays first-class (the framework knows "the children of this region").
- Cost: every new ambient-state scope is a new Region kind, which requires evaluator changes. Doesn't get tixl's catalog-extensibility property where any operator can become a scope.

### Sketch C: typed pull-edges with declarative scope effects

- Introduce port-type metadata "this output port, when pulled, pushes/pops scope X on the EvalContext."
- The push/pop is declared by the operator (e.g. via a derive macro attribute), not hardcoded in the evaluator.
- Operators wire together like any other port; the evaluator inspects the type metadata to know "this pull also pushes a transform scope."
- Lets the catalog grow without evaluator changes (operators self-declare their scope effects).
- Subgraph identity is *not* first-class (same as tixl); collection passes need explicit accumulator mechanisms.
- Cost: the most ambitious of the three; needs design work to define the scope-effect grammar.

The three sketches map roughly to "tixl's actual approach" (A), "extend what flux has" (B), and "tixl's approach reified through Rust's type system" (C).

A natural follow-up question (for the user to consider, not for this primer to answer): **does flux value first-class subgraph identity (a Region knows its children) or first-class catalog extensibility (any operator can scope)? The two are in tension.**

---

## Sources cited

### Tixl source (read directly)

- `visual-programming/tixl/Core/DataTypes/Command.cs` — the entire `Command` class (10 lines).
- `visual-programming/tixl/Core/Operator/EvaluationContext.cs` — context fields pushed/popped by scope operators (`ObjectToWorld`, `WorldToCamera`, `CameraToClipSpace`, `PointLights`, `Materials`, `ContextTextures`, `FogParameters`, `LocalTime`, `LocalFxTime`, `ForegroundColor`).
- `visual-programming/tixl/Core/Operator/Slots/Slot.cs` — `Slot<T>` mechanism: `T Value` field, `UpdateAction` invoked on `GetValue(context)`.
- `visual-programming/tixl/Operators/Lib/Symbols/render/transform/Transform.cs` — canonical push/pull/pop pattern with `context.ObjectToWorld`.
- `visual-programming/tixl/Operators/Lib/Symbols/render/transform/Group.cs` — `MultiInputSlot<Command>` iteration with per-child `PrepareAction`/`RestoreAction` hooks.
- `visual-programming/tixl/Operators/Lib/Symbols/render/basic/Layer2d.cs` — `TransformCallbackSlot<Command>` as another `Command` output variant.

### Research inventories (read)

- `research/inventory-tixl.md` — pattern catalog: matrix-stack scope pattern, `Command` as universal draw-output type, multiple time bases on context, ExecuteRepeatedly/Once/ResetSubtreeTrigger.
- `research/inventory-werkkzeug.md` — `Wz4Render` definition and op signatures (`Render(?*Wz4Render)`, `Camera(?Rendertarget2D, ?*Wz4Render)`).
- `research/inventory-threejs.md` — `Object3D` retained scene graph, TSL vs scenes boundary.

### Synthesis (read)

- `notes/themes/node-graphs/operator-families-vs-flux.md` — Render-state-as-scope pattern entry; Transform / Scene-State Mutators family; Renderer-as-Ops pattern.

### Flux source (spot-checked for Region comparison)

- Flux test suite (private), `region_render_pass_test.rs` — `Region::RenderPass` exposed-slot architecture.
- Flux test suite (private), `region_loop_test.rs` — `Region::Loop` iteration discipline.

### Not opened (flagged as future verification targets)

- Werkkzeug C++ source for `Wz4Render` type definition (would confirm whether it's a marker class or carries internal children).
- Tixl `Core/Operator/Slots/MultiInputSlot.cs` (the exact collection semantics of `CollectedInputs`).
- Operators that set `Command.Value` to a non-null instance — survey would confirm whether any encode subtree shape there rather than just exposing prepare/restore callbacks.
