# Primer: tixl `Command` — Patterns and Usage

## TL;DR

In tixl, every render-state-bearing op has the same shape: a `Slot<Command>` output and an `InputSlot<Command>` input (or `MultiInputSlot<Command>` for fan-in). When the parent pulls on a Command op's output, the op mutates `EvaluationContext` (push state), pulls on its child Command input (which causes everything below to evaluate under that pushed state), then unmutates (pop state). The "tree" the author wires is therefore a *reversed pull-tree* — the root of the visual graph (the window/RenderTarget) sits at the top, leaf draw-calls hang off the bottom, and the `Command` wire is the spine that carries no data — it carries *the right to execute*. Composing a scene means stacking these scoped operators along the spine; transforms, materials, cameras, fog, environment, and lights are all uniform in shape, which is what makes the model coherent. The trade-off is that any operator wanting to know "what is the current world matrix here?" has to either consume Command (and read context inside its own Update) or break the discipline via a side-channel op like `CurrentCamMatrices`.

## The canonical render tree

A minimal "rotating mesh in a lit, fogged scene" looks like this in tixl. Every box below has the `Slot<Command> Output` / `InputSlot<Command> Command` shape unless noted. The wire from a parent's `Command` input down to a child's `Output` *is* the subtree connection.

```
            ┌──────────────────────────────────┐
ROOT pull ─►│  RenderTarget                    │  (Texture2D output to window)
            │  • clears RTV, sets viewport     │
            │  • saves context (RT/DSV/cam)    │
            │    .Command ◄────────────────┐   │
            └──────────────────────────────┼───┘
                                           │
            ┌──────────────────────────────▼───┐
            │  Camera (or OrbitCamera)         │
            │  • pushes WorldToCamera,         │
            │    CameraToClipSpace             │
            │    .Command ◄────────────────┐   │
            └──────────────────────────────┼───┘
                                           │
            ┌──────────────────────────────▼───┐
            │  SetPointLight                   │
            │  • PointLights.Push(light)       │
            │    .Command ◄────────────────┐   │
            └──────────────────────────────┼───┘
                                           │
            ┌──────────────────────────────▼───┐
            │  SetFog                          │
            │  • context.FogParameters = …     │
            │    .Command ◄────────────────┐   │
            └──────────────────────────────┼───┘
                                           │
            ┌──────────────────────────────▼───┐
            │  SetMaterial                     │
            │  • context.PbrMaterial = m       │
            │  • context.Materials.Add(m)      │
            │    .SubTree ◄────────────────┐   │
            └──────────────────────────────┼───┘
                                           │
            ┌──────────────────────────────▼───┐
            │  Transform                       │
            │  • context.ObjectToWorld =       │
            │      objLocal * prev             │
            │    .Command ◄────────────────┐   │
            └──────────────────────────────┼───┘
                                           │
            ┌──────────────────────────────▼───┐
            │  DrawMesh                        │
            │  • reads ObjectToWorld,          │
            │    WorldToCamera, CameraToClip,  │
            │    PbrMaterial, FogParameters,   │
            │    PointLights from context      │
            │  • issues the draw call          │
            └──────────────────────────────────┘
```

The pull goes top→down. State pushes happen on the way down. The draw at the leaf samples the fully composed state. State pops happen as control returns up.

The exact arrow-on-the-wire matters: in the `.t3` JSON the *source* is the child's `Output` and the *target* is the parent's `Command` input (see `examples/lib/mesh/DrawMeshAtPointsExample.t3` lines 124-135 — `SetFog.Output` → `RenderTarget.Command`, and `Execute.Output` → `SetFog.Command`). Visually in the editor this looks like a downward-flowing chain, but the evaluation direction is from `RenderTarget` *pulling* on `SetFog` which pulls on `Execute`, etc.

## State-pushing operators (inventory)

Every op listed below has the same surface contract: at least one `Slot<Command> Output` and one `InputSlot<Command>` (named `Command` or `SubTree` interchangeably). What differs is which field on `EvaluationContext` gets stashed/replaced/restored around the inner pull.

| Op | Pushed state (on `EvaluationContext`) | Typical position | Source |
|---|---|---|---|
| `Transform` | `ObjectToWorld = local * ObjectToWorld` | Around any drawable subtree | `Operators/Lib/Symbols/render/transform/Transform.cs` |
| `RotateAroundAxis` | `ObjectToWorld` (rotation only) | Same as Transform, narrower | `Operators/Lib/Symbols/render/transform/RotateAroundAxis.cs` |
| `Group` | `ObjectToWorld` + `ForegroundColor`; **MultiInput** of children | Aggregation node, "scene folder" | `Operators/Lib/Symbols/render/transform/Group.cs` |
| `ApplyTransformMatrix` | `ObjectToWorld` (from a `Vector4[]` matrix-on-port) | Bridge from value-flow back to scope | `Operators/Lib/Symbols/render/_/ApplyTransformMatrix.cs` |
| `ApplyCamMatrices` | `ObjectToWorld` adjusted by camera matrices (for projecting overlays) | Lens-flare / screen-space tricks | `Operators/Lib/Symbols/render/_/ApplyCamMatrices.cs` |
| `Camera` | `WorldToCamera`, `CameraToClipSpace` | High in the tree, above draws | `Operators/Lib/Symbols/render/camera/Camera.cs` |
| `OrbitCamera` | Same as Camera; interactive | Same as Camera | `Operators/Lib/Symbols/render/camera/OrbitCamera.cs` |
| `ReuseCamera` | Same as Camera but reads from a `CameraReference` `Object` port | Shadow pass, second viewport | `Operators/Lib/Symbols/render/camera/ReuseCamera.cs` |
| `SetMaterial` | `PbrMaterial` + appended to `Materials` stack | Above mesh draws | `Operators/Lib/Symbols/render/shading/SetMaterial.cs` |
| `UseMaterial` | Same as SetMaterial, but reads `MaterialReference` from a port | Reuse a material defined elsewhere | `Operators/Lib/Symbols/render/shading/UseMaterial.cs` |
| `DefineMaterials` | Appends N `PbrMaterial`s to `context.Materials` (no `PbrMaterial` swap) | Scene-root: declare a palette | `Operators/Lib/Symbols/render/shading/DefineMaterials.cs` |
| `SetPointLight` | `PointLights.Push(light)` (a stack of `PointLight`) | Above lit subtree | `Operators/Lib/Symbols/render/shading/SetPointLight.cs` |
| `SetFog` | `FogParameters` (constant buffer) | High in the tree | `Operators/Lib/Symbols/render/shading/SetFog.cs` |
| `SetEnvironment` | IBL cubemap + background settings | Scene root | `Operators/Lib/Symbols/render/shading/SetEnvironment.cs` |
| `SetShadow` | Shadow map render + binds it for later sampling | Wraps both shadow-caster and lit subtree | `Operators/Lib/Symbols/render/shading/SetShadow.cs` |
| `SetRequestedResolution` | `RequestedResolution` (consumed by RenderTarget defaults, AspectRatio fallback, etc.); op outputs Texture not Command — see "Escape hatches" | Around a Texture-producing op | `Operators/Lib/Symbols/render/shading/SetRequestedResolution.cs` |
| `RenderTarget` | Binds offscreen RTV+DSV; resets default camera, viewport, ObjectToWorld; *outputs Texture2D, not Command* | At the boundary between scene tree and image tree | `Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs` |
| `Execute` | None — just a fan-in pass-through (variadic Command input) | Junction node | `Operators/Lib/Symbols/flow/Execute.cs` |
| `Switch` | None — picks 1 of N child Commands | A/B scenes | `Operators/Lib/Symbols/flow/Switch.cs` |
| `Loop` | Sets `IntVariables[name]`, `FloatVariables[name]`; re-pulls Command N times | Spawning N instances of a subtree | `Operators/Lib/Symbols/flow/Loop.cs` |
| `BlendScenes` | Cross-fades between two child Commands | Live performance scene transitions | `Operators/Lib/Symbols/flow/BlendScenes.cs` |

A few patterns are worth calling out:

- **Two flavors of "set X"**: `SetMaterial` *defines* a new material inline; `UseMaterial` *references* one that was defined elsewhere. Same scoped-push contract; different value-flow shape. (`SetMaterial.cs` lines 48-65; `UseMaterial.cs` lines 17-35.)
- **Implicit vs. explicit scope width**: `Group` wraps a *multi-input* of Commands (`MultiInputSlot<Command>` at `Group.cs:91`) — its scope spans all children, evaluated in sequence. `Transform` and most "Set*" ops have a *single* `Command` input; their scope is whatever single subtree is wired in (which can be a `Group` to multiplex).
- **`ITransformable` opt-in**: `Transform`, `Group`, `Layer2d`, and `PointLight` all implement `ITransformable`, exposing their Translation/Rotation/Scale input GUIDs for the editor's gizmo. This is independent of the Command contract — it just lets the 3D viewport drag them.

## Composition patterns

### 1. Scene-Root-Lights → Camera-Scope → Mesh

The default shape: lights and environment live at the scene root so every draw sees them; camera sits below them; transforms and material wrap each mesh.

```
RenderTarget
└─ DefineMaterials  (palette: red, blue, metal)
   └─ SetEnvironment  (HDRI)
      └─ SetPointLight  (key light)
         └─ SetPointLight  (fill light)
            └─ Camera
               └─ Group  ◄── multi-input fan-in
                  ├─ Transform ─► UseMaterial("red")  ─► DrawMesh(torus)
                  ├─ Transform ─► UseMaterial("blue") ─► DrawMesh(cube)
                  └─ Transform ─► UseMaterial("metal")─► DrawMesh(sphere)
```

Why this nesting order: lights are appended via `pointLights.Push` (`SetPointLight.cs:22`) and consumed by shaders via the constant buffer that `DrawMesh` binds. Anything below the `SetPointLight` "sees" the light; anything above does not. Materials defined via `DefineMaterials` (`DefineMaterials.cs:34`) are appended to `context.Materials` and become dropdown options on every `DrawMesh.UseMaterialId` below — that's why `DefineMaterials` sits at the root.

### 2. Material-Inside-Transform (per-mesh leaf shape)

```
SetMaterial(baseColor=red)
└─ Transform(pos=(1,0,0), rot=…)
   └─ DrawMesh(torusMesh)
```

This is the per-leaf idiom. The transform doesn't carry geometry; it carries a 4×4 push. The mesh handle (`MeshBuffers`) is on a *separate* port — `DrawMesh.cs` reads `context.PbrMaterial` and `context.ObjectToWorld` rather than taking them as port values. So the *Command* wire never carries the mesh; it carries the right to draw under the current state.

### 3. Group-as-folder (variadic sibling fan-in)

`Group` is the only state-pusher with `MultiInputSlot<Command>`. It is the *only* idiomatic way to put two draws under the same transform without nesting:

```
Group(translation=(0,3,0))     ◄─── single Transform applies to all children
├─ Transform(local) ─► DrawMesh(head)
├─ Transform(local) ─► DrawMesh(torso)
└─ Transform(local) ─► DrawMesh(arm)
```

Inside `Group.Update` the multi-input is iterated in order, each child gets `PrepareAction`, `GetValue`, then `RestoreAction` (`Group.cs:60-77`). This means each *sibling subtree* sees the same outer ObjectToWorld push but starts from a clean inner state — no accidental bleed between siblings, even though they share the parent's pushed transform. `Execute` (`Operators/Lib/Symbols/flow/Execute.cs`) is the no-state-push variant of the same fan-in pattern; the example `DrawMeshAtPointsExample.t3` uses `Execute` to fan two siblings into `SetFog.Command`.

### 4. Wrapped-Post-FX (Command tree feeds image pipeline)

Post-FX in tixl does *not* live on the Command wire. The bridge is `RenderTarget`, which terminates a Command tree and exposes color/depth/normal textures. Post-FX (`SSAO`, `DepthOfField`, `GodRays`, `MotionBlur`, `TemporalAccumulation`) are all pure texture-in/texture-out ops:

```
[Command tree]
RenderTarget(MSAA=4, WithDepthBuffer=true, WithNormalBuffer=true)
├─ ColorBuffer ─┐
├─ DepthBuffer ─┤
└─ NormalBuffer─┤
                ▼
            SSAO  (Texture2D Texture2d, Texture2D DepthBuffer …)
                │
                ▼
            DepthOfField
                │
                ▼
            [window]
```

`SSAO.cs` has no Command port at all — only `Texture2D` ports. This is *intentional*: post-FX is image-space, not scene-space; the Command tree's job is to produce the inputs, the texture chain does the rest. (See `Operators/Lib/Symbols/render/postfx/SSAO.cs:1-44` for the shape.)

### 5. ReuseCamera-for-Shadows (the same camera evaluating twice)

Shadow passes need to render the scene from the light's POV, then again from the main camera's POV. `ReuseCamera` (`Operators/Lib/Symbols/render/camera/ReuseCamera.cs:14-47`) does this without duplicating camera state — it takes a `Reference` to another `Camera` op (every Camera has both `Output: Slot<Command>` and `Reference: Slot<Object>`) and pushes that camera's matrices around its own subtree.

```
                 ┌──────► Camera (main)  ──Reference──┐
RenderTarget ─►  │       └─ Output ─► [scene subtree] │
                 │                                     │
                 └──► ShadowRenderTarget               │
                      └─ ReuseCamera ◄── CameraReference
                         └─ Output ─► [scene subtree again, from light POV]
```

The `Reference` port is the explicit value-flow side-channel; the `Command` ports remain the scope-push surface. Same shape, two evaluations.

## Authoring at the wire level

What does the author actually connect when wiring `Transform → Camera → SetMaterial → DrawMesh`?

**One wire per nesting level, on a single port name.** Each scope-pushing op has one `InputSlot<Command>` (named `Command` or `SubTree`). The author drags from the child's `Output` to the parent's `Command` input. There is no separate "parent" port; parenting is implicit in the wire direction.

From `DrawMeshAtPointsExample.t3`:
```
{ "SourceParentOrChildId": "SetFog",
  "SourceSlotId": "7c2134d1…"   /* SetFog.Output */,
  "TargetParentOrChildId": "RenderTarget",
  "TargetSlotId": "4da253b7…"   /* RenderTarget.Command */ },
{ "SourceParentOrChildId": "Execute",
  "SourceSlotId": "e81c99ce…"   /* Execute.Output */,
  "TargetParentOrChildId": "SetFog",
  "TargetSlotId": "afadb109…"   /* SetFog.Command */ },
```

So the topology is **a linear pull-chain along the Command wire**, with **tree-shaped fan-in only where a `MultiInputSlot<Command>` op (Group / Execute / Switch / BlendScenes) appears**. There are no diamond connections through Command — a given `Output: Slot<Command>` is consumed exactly once. (Reuse demands an explicit `Execute` or `Group`.)

Side-channel value-flow runs *across* the Command spine: a `OscillateVec3` driving a `RadialPoints.OrientationAxis`, a Texture coming out of `RenderTarget` into `SSAO`. The Command spine is purely the scope-and-order spine; everything substantive (positions, colors, textures, meshes) is on other ports.

## Affordances unlocked

Concrete comparisons against a hypothetical "matrix-flows-on-a-port" model:

- **Add a new mesh under an existing transform.** With Command: insert one `Group` (if not already there) and wire the new `DrawMesh` into it — one new op, one new wire. With matrix-on-port: each draw must take a Matrix4 input port; sharing the same matrix means either splitting the wire (which is fine) *or* duplicating the transform sub-graph (because nothing else carries the rest of the inherited state — material, lights, camera). Multiply by every other context field (PbrMaterial, FogParameters, PointLights stack, RequestedResolution…) and the matrix-on-port version requires N parallel wires per draw.

- **Switch between two materials for the same subtree.** Wrap the subtree in `SetMaterial`. To swap, change one port (BaseColor/Texture) or replace the `SetMaterial` with a different material op. The draws below don't change at all. Without scope, every `DrawMesh` would need a `Material` port wired to the same source.

- **Scope a light to part of the scene.** Place `SetPointLight` above only the relevant subtree (e.g. above one branch of a `Group`); siblings outside that branch don't see the light because `pointLights.Pop()` happens when control returns. With value-flow, you'd need a "light list" port on every draw and would have to author the masking logic by hand.

- **Re-use the same camera for shadow + main pass.** `ReuseCamera` takes a `Reference` to the source Camera and re-runs the scene subtree under its matrices (`ReuseCamera.cs:35-41`). The scene subtree is wired once; both passes invoke it via different parent Command ops. Without scope, you'd be threading view/proj matrices through every leaf.

- **Recursive instancing via `Loop`.** `Loop.cs:23-40` literally re-evaluates its `Command` input N times with `Invalidate()` between iterations, mutating context variables each time. Whatever expensive-to-set-up subtree lives below the loop is *authored once*; the loop body sees a fresh `IndexVariable` / `ProgressVariable` per iteration. Without scope, you'd need explicit duplication or a much heavier "instance buffer" plumbing.

- **`SetShadow` wraps both the shadow pass and the lit pass in one op.** A single op declares both the caster sweep and the lit-pass binding — internally it does two pulls of `Command` against its own off-screen depth target, then leaves the resulting shadow map bound for the lit pass to sample. Author affordance: one wire.

## Affordances lost

Real things this pattern makes awkward (visible in the codebase as workarounds):

- **Inspecting the current world matrix mid-graph.** Nothing on the Command wire carries the matrix as a value, because it lives in `context.ObjectToWorld` and is only readable *while* being evaluated. The workaround is `CurrentCamMatrices` (`Operators/Lib/Symbols/render/camera/CurrentCamMatrices.cs`), which has *both* a `Slot<Command>` and a `Slot<Vector4[]> WorldToClipSpace` output and acts as a probe: when evaluated as part of a Command pull, it samples `context.WorldToCamera * context.CameraToClipSpace` and exposes it as a value-port. It's a side-channel that only works because of where it's wired. The matrix it exposes is "the matrix at the point in the tree where this probe is wired" — but the probe itself doesn't draw anything, so it has to be evaluated as a sibling under an `Execute`/`Group` next to whatever else needed that matrix. Awkward.

- **Branching one mesh into two different transform contexts.** Because `Output: Slot<Command>` can only be consumed once (the pull mutates context — re-pulling re-mutates), you can't fan one `DrawMesh` into two parent transforms. You have to duplicate the draw and put each copy under its own Transform. `Loop` partially papers over this (re-evaluates the same subtree N times under different context-variables), but only when the variation is uniform.

- **Caching/memoizing under scope.** The "value" produced by a Command op is essentially `void` — the work happens via side effects on context and the framebuffer. There's nothing to memoize at the Command wire. The DirtyFlag system handles invalidation upstream (input ports), but if you want to skip a subtree because nothing relevant changed *and* nothing in context changed, the pattern offers no help. `Switch.cs` has explicit `LimitMultiInputInvalidationToIndices` plumbing (`Switch.cs:71-86`) to avoid re-evaluating disabled branches — that's the manual mitigation.

- **Animating a value that depends on something downstream.** Pull semantics are strict: parents pull children. If the position of a Transform should depend on where its child mesh's bounding box ends up (e.g. "fit camera to scene"), there's nothing in the Command pattern that helps; the child hasn't been evaluated when the parent's port values are gathered. Cameras work around this with the dual-slot pattern: `Reference: Slot<Object>` (lazy) plus `Output: Slot<Command>` (active) — `Camera.cs:16-46` shows `UpdateCameraDefinition` being called by the `Reference` slot independently of the Command subtree pull.

- **Diamond reuse across two scopes.** If you want one mesh-generation pipeline feeding two render passes with different cameras, the mesh data has to be on a value port (it can be, e.g. `MeshBuffers`) but the *draw* (which reads `ObjectToWorld` from context) cannot. So in practice you duplicate the `DrawMesh` op and share only its mesh input.

## Subtree-as-value composition (Group, Layer2d, Execute, etc.)

Three ops aggregate multiple `Command` inputs:

- **`Group`** (`Operators/Lib/Symbols/render/transform/Group.cs:91`): `MultiInputSlot<Command> Commands`. Iterates in connection order. Pushes Transform + ForegroundColor scope around the *whole* batch, but each child gets its own `PrepareAction` / `GetValue` / `RestoreAction` cycle (`Group.cs:60-77`). Semantically: "scope this group's transform around N siblings."

- **`Execute`** (`Operators/Lib/Symbols/flow/Execute.cs:42`): `MultiInputSlot<Command> Command`. No state pushed. Pure fan-in / sequencer. Use when you need multiple sibling Commands to feed a single parent's `Command` input without sharing any new scope.

- **`Switch`** (`Operators/Lib/Symbols/flow/Switch.cs:94`): `MultiInputSlot<Command> Commands` + an `Index` int port. Selects *one* (or all, if `Index == -2`) of the children to evaluate. The state push is whatever the selected child's subtree does — `Switch` itself doesn't push anything beyond invalidation bookkeeping.

- **`BlendScenes`** (`Operators/Lib/Symbols/flow/BlendScenes.cs:10`): `MultiInputSlot<Command> Scenes` + a `BlendFraction` float. Cross-fade between two scenes — typical live-performance pattern.

**Sequence semantics.** Connection order on a MultiInput is the iteration order. There's no out-of-order or parallel evaluation; the framework just walks the slice. This means later children in a `Group` see state mutations from earlier ones if those mutations leaked (e.g. constant buffers that an op forgot to restore), but the well-behaved ops always pair push/pop via `try{push}finally{pop}`-equivalent code.

**Fan-in is the *only* place tree-shaped wiring shows up.** Outside of these four ops, every Command edge is a single-source single-sink linear chain.

**`Layer2d`** is worth a separate mention (`Operators/Lib/Symbols/render/basic/Layer2d.cs`). It outputs `TransformCallbackSlot<Command>` and has no `Command` input — it's a *leaf* Command op (like `DrawMesh`), but with built-in 2D-rect rendering. Its purpose is the 2D compositing case (`Position`, `Stretch`, `BlendMode`, `EnableDepthTest`); it consumes a `Texture2D` and emits the draw as a Command. Combining several `Layer2d`s under a `Group` (each with its own Texture) is the canonical "render-to-texture overlay" stack. The fact that `Layer2d` doesn't have a `Command` input port means you can't nest a sub-scene *inside* a Layer2d — its scope is fixed as "this textured quad."

## Escape hatches

Where the Command discipline gets bent or broken:

- **`CurrentCamMatrices`** (`Operators/Lib/Symbols/render/camera/CurrentCamMatrices.cs`): Dual output — both `Slot<Command>` and `Slot<Vector4[]> WorldToClipSpace`. Functions as an in-line probe of context state, converting scope back to value-flow. Used by overlay/projection ops (`ApplyCamMatrices`, lens flare math) that need the matrices as port values to feed into shader constants on a different subtree.

- **`Camera.Reference: Slot<Object>`** (`Camera.cs:13`): The same camera op exposes both its scope-pushing Command output *and* a passive Object reference. The Reference output triggers `UpdateCameraDefinition` independently — letting `ReuseCamera`, `BlendCameras`, and `CamPosition` query camera state without entering the camera's Command subtree.

- **`SetMaterial.Reference: Slot<PbrMaterial>`** (`SetMaterial.cs:13`): Same trick. Exposes the constructed `PbrMaterial` as a value so a downstream `UseMaterial` op can reference it elsewhere in the tree. The "definition" lives inside a Command scope; the "reference" leaks out as a value.

- **`SetRequestedResolution`** outputs `Texture2D`, not `Command` (`SetRequestedResolution.cs:14`). It pushes `RequestedResolution` and then pulls a *Texture* input. This is the case of "scope-pushing op whose body is value-flow not Command-flow" — pragmatic, but it means the same scope behavior is repeated in a different surface shape.

- **`RenderTarget`** is the top-of-tree terminator. It consumes Command and emits Texture2D. Inside its Update it saves *everything* on context (`prevObjectToWorld`, `prevWorldToCamera`, `prevCameraToClipSpace`, `prevRequestedResolution`, `prevBackgroundColor`, `prevForegroundColor`, `BypassCameras` — see `RenderTarget.cs:88-94`) and explicitly calls `context.SetDefaultCamera()`. It's the boundary between "render-state-as-scope" and "image-as-value" — and it has to be aware of *every* context field to save it, which is a tell about the cost of the model: adding a new context field means auditing every push/pop site.

- **`Execute`/`Loop`/`Switch`** in `Lib.flow` are not strictly render-state ops but inhabit the same Command surface. They allow control-flow over scope subtrees without owning a particular state field — this is what makes the Command pattern compose with iteration and branching at all.

- **`Loop` mutates `context.IntVariables` / `FloatVariables`** (`Loop.cs:25-26`) but the code comment notes `// TODO: may restore context variable after iterating.` — i.e. the dictionary entries are *not* popped. So the Loop's "loop variables" leak out into surrounding scope, which is presumably fine in practice but not the strict push/pop discipline.

## Sources cited

All paths are under `visual-programming/tixl/`.

| Path | What it shows |
|---|---|
| `Operators/Lib/Symbols/render/transform/Transform.cs` | Canonical single-input scope op: `ObjectToWorld` push/pop (lines 22-46). |
| `Operators/Lib/Symbols/render/transform/RotateAroundAxis.cs` | Narrow Transform — rotation only, same shape. |
| `Operators/Lib/Symbols/render/transform/Group.cs` | Multi-input scope: `MultiInputSlot<Command>` + Transform + Color scope; Prepare/Get/Restore loop (lines 57-77). |
| `Operators/Lib/Symbols/render/_/ApplyTransformMatrix.cs` | Bridge from `Vector4[]` matrix-on-port back into the ObjectToWorld scope. |
| `Operators/Lib/Symbols/render/_/ApplyCamMatrices.cs` | Same bridge for camera matrices — used in lens-flare/2D-overlay pipelines. |
| `Operators/Lib/Symbols/render/camera/Camera.cs` | Camera with dual outputs: `Slot<Command> Output` *and* `Slot<Object> Reference`. Pushes WorldToCamera, CameraToClipSpace (lines 36-46). |
| `Operators/Lib/Symbols/render/camera/OrbitCamera.cs` | Camera variant — confirms the dual-output pattern is shared. |
| `Operators/Lib/Symbols/render/camera/ReuseCamera.cs` | The "use another camera's matrices here" op — explicit value-side-channel via `CameraReference`. |
| `Operators/Lib/Symbols/render/camera/CurrentCamMatrices.cs` | Probe op: turns scope back into a value-port mid-graph. |
| `Operators/Lib/Symbols/render/shading/SetMaterial.cs` | Defines a material inline, scopes it, exposes a `Reference: Slot<PbrMaterial>`. |
| `Operators/Lib/Symbols/render/shading/UseMaterial.cs` | The reuse-by-reference variant. |
| `Operators/Lib/Symbols/render/shading/DefineMaterials.cs` | Multi-material palette at scene root (no `PbrMaterial` swap, just appends to `Materials`). |
| `Operators/Lib/Symbols/render/shading/SetPointLight.cs` | Stack-push of a `PointLight` (lines 14-26). |
| `Operators/Lib/Symbols/render/shading/PointLight.cs` | Lightweight `ITransformable` variant — note no UpdateAction, only metadata. |
| `Operators/Lib/Symbols/render/shading/SetFog.cs` | Constant-buffer scope: replaces `context.FogParameters`. |
| `Operators/Lib/Symbols/render/shading/SetEnvironment.cs` | IBL + background scope (no UpdateAction visible in skeleton — implementation likely partial in the open source export). |
| `Operators/Lib/Symbols/render/shading/SetShadow.cs` | Shadow-map scope. |
| `Operators/Lib/Symbols/render/shading/SetRequestedResolution.cs` | Scope op whose body is value-flow (Texture2D in, Texture2D out). |
| `Operators/Lib/Symbols/render/basic/Layer2d.cs` | Leaf 2D-quad Command, no Command input port — only a Texture input. |
| `Operators/Lib/Symbols/mesh/draw/DrawMesh.cs` | The canonical leaf draw — reads `context.PbrMaterial`, `Materials`, etc. (lines 18-44). |
| `Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs` | Tree terminator: consumes Command, emits Texture2D; massive context save/restore at lines 80-162. |
| `Operators/Lib/Symbols/render/postfx/SSAO.cs` | Pure texture-in/texture-out post-FX — *no* Command port. |
| `Operators/Lib/Symbols/flow/Execute.cs` | No-state fan-in: multi-input Command + IsEnabled. |
| `Operators/Lib/Symbols/flow/Switch.cs` | Conditional fan-in with explicit invalidation bookkeeping (lines 71-86). |
| `Operators/Lib/Symbols/flow/Loop.cs` | Re-pulls Command N times with mutated context-variables. |
| `Operators/Lib/Symbols/flow/BlendScenes.cs` | Crossfade between two Command subtrees. |
| `Operators/Examples/Symbols/Lib/mesh/DrawMeshAtPointsExample.t3` | Real `.t3` JSON showing Connections array — confirms `Output → ParentCommand` wiring (lines 117-172). |
