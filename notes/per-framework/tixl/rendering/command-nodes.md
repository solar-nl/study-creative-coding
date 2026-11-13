# tixl Command Nodes: GPU Operations as Graph Operators

## The Problem

A rendering pipeline requires dozens of GPU state mutations in precise order: bind shaders, set vertex buffers, configure rasterizer state, set blend mode, issue a draw call, then undo everything so the next object starts clean. Traditional engines encode this as imperative code in a renderer class. tixl needed to express it as composable graph nodes in a visual editor — without exposing that complexity to users.

The solution is a two-tier architecture. At the top tier, users wire together high-level compound operators like `DrawMesh` (one node, 14 input ports). At the bottom tier, inside each compound, a sub-graph of primitive GPU command nodes handles the actual DX11 calls. Users work at the top tier. The bottom tier exists for power users and framework authors.

This document traces the primitive command nodes, the two composition primitives that orchestrate them, and the compound operator system that hides them behind user-friendly interfaces.

## The Primitive Command Nodes

Every GPU command node lives in `Operators/Lib/render/_dx11/api/` and follows the same contract:

```csharp
internal sealed class SomeGpuOp : Instance<SomeGpuOp>
{
    [Output] public readonly Slot<Command> Output = new(new Command());

    public SomeGpuOp()
    {
        Output.UpdateAction += Update;        // called during graph evaluation
        Output.Value.RestoreAction = Restore; // called by parent after evaluation
    }

    private void Update(EvaluationContext context)
    {
        // 1. Read input values from upstream slots
        // 2. Snapshot current GPU state into private fields
        // 3. Set new GPU state on device.ImmediateContext
    }

    private void Restore(EvaluationContext context)
    {
        // 4. Put the previous GPU state back
    }
}
```

The operator does not call its own `Restore`. That is the parent's responsibility — the composition primitive (Execute or Group) calls `RestoreAction` after the operator and all its dependents have finished. This separation is what makes command nodes composable: each node only knows how to set and undo one piece of GPU state, and the parent controls when the undo happens.

### The Complete Operator Catalog

Each operator maps to one slice of the DX11 pipeline:

**Pipeline State Operators** — these save, set, and restore GPU configuration:

| Operator | What it controls | DX11 calls |
|----------|-----------------|------------|
| `SetPixelAndVertexShaderStage` | Shader programs, constant buffers, SRVs, samplers | `vsStage.Set(vs)`, `psStage.Set(ps)`, `SetConstantBuffers()`, `SetShaderResources()`, `SetSamplers()` |
| `OutputMergerStage` | Render targets, depth/stencil, blend state, UAVs | `outputMerger.SetTargets()`, `SetBlendState()`, `SetDepthStencilState()`, `SetUnorderedAccessViews()` |
| `InputAssemblerStage` | Vertex/index buffers, primitive topology, input layout | `iaStage.PrimitiveTopology = ...`, vertex/index buffer binding |
| `Rasterizer` | Cull mode, fill mode, viewports, scissor rects | `rasterizer.State = newState`, `SetViewports()` |

**Draw Call Operators** — these issue GPU commands but do not change state:

| Operator | DX11 call | Notes |
|----------|----------|-------|
| `Draw` | `deviceContext.Draw(vertexCount, startVertex)` | No save/restore needed — draw calls don't mutate state |
| `DrawInstancedIndirect` | `deviceContext.DrawInstancedIndirect(buffer, offset)` | GPU-driven draw count from buffer |

**Resource Operators** — these create or transform GPU resources (no state mutation):

| Operator | Purpose |
|----------|---------|
| `TransformsConstBuffer` | Packs ObjectToWorld/WorldToCamera/CameraToClipSpace matrices into a cbuffer |
| `ResolutionConstBuffer` | Packs viewport resolution into a cbuffer |
| `TimeConstBuffer` | Packs playback time into a cbuffer |
| `FloatsToBuffer` | Packs arbitrary float values into a constant buffer |
| `SrvFromTexture2d` | Creates a ShaderResourceView from a Texture2D |
| `RtvFromTexture2d` | Creates a RenderTargetView from a Texture2D |
| `DsvFromTexture2d` | Creates a DepthStencilView from a Texture2D |
| `UavFromTexture2d` | Creates an UnorderedAccessView for compute |
| `SrvFromStructuredBuffer` | SRV from a structured buffer |
| `UavFromBuffer` / `UavFromStructuredBuffer` | UAV from buffer for compute write |
| `CalcDispatchCount` | Computes compute shader dispatch dimensions from buffer size |
| `ClearRenderTarget` | Calls `ClearRenderTargetView` with a color |
| `GenerateMips` | Calls `GenerateMips` on a texture SRV |
| `GetTextureSize` / `GetSRVProperties` | Queries GPU resource metadata |
| `Viewport` | Creates viewport structs without setting them |

### Anatomy of a State Operator: SetPixelAndVertexShaderStage

The most complex state operator binds both shader stages plus all their resources. Its `Update` method demonstrates the full save/set pattern:

```csharp
// Operators/Lib/Symbols/render/_dx11/fxsetup/SetPixelAndVertexShaderStage.cs
private void Update(EvaluationContext context)
{
    var vsStage = deviceContext.VertexShader;
    var psStage = deviceContext.PixelShader;

    // Pull resource values from upstream graph connections
    ConstantBuffers.GetValues(ref _constantBuffers, context);
    ShaderResources.GetValues(ref _shaderResourceViews, context);
    SamplerStates.GetValues(ref _samplerStates, context);

    // SAVE current GPU state
    _prevConstantBuffers = vsStage.GetConstantBuffers(0, _constantBuffers.Length);
    _prevShaderResourceViews = vsStage.GetShaderResources(0, _shaderResourceViews.Length);
    _prevSamplerStates = vsStage.GetSamplers(0, _samplerStates.Length);
    _prevVertexShader = vsStage.Get();
    _prevPixelShader = psStage.Get();

    // Pull shader objects (may trigger compilation)
    var vs = VertexShader.GetValue(context);
    var ps = PixelShader.GetValue(context);

    // SET new GPU state
    if (vs != null)
    {
        vsStage.Set(vs);
        vsStage.SetSamplers(0, _samplerStates);
        vsStage.SetConstantBuffers(0, _constantBuffers);
        vsStage.SetShaderResources(0, _shaderResourceViews);
    }
    if (ps != null)
    {
        psStage.Set(ps);
        psStage.SetSamplers(0, _samplerStates);
        psStage.SetConstantBuffers(0, _constantBuffers);
        psStage.SetShaderResources(0, _shaderResourceViews);
    }
}
```

Its inputs are all multi-input slots: a shader stage can receive any number of constant buffers and SRVs. The connection order in the graph determines the binding slot indices — the first connected SRV goes to slot 0, the second to slot 1, and so on.

`Restore` reverses every mutation:

```csharp
private void Restore(EvaluationContext context)
{
    vsStage.Set(_prevVertexShader);
    vsStage.SetConstantBuffers(0, _prevConstantBuffers);
    vsStage.SetShaderResources(0, _prevShaderResourceViews);
    psStage.Set(_prevPixelShader);
    psStage.SetConstantBuffers(0, _prevConstantBuffers);
    psStage.SetSamplers(0, _prevSamplerStates);
}
```

### Anatomy of a Draw Operator: Draw

The simplest command node. No state to save or restore — a draw call does not change the pipeline:

```csharp
// Operators/Lib/Symbols/render/_dx11/api/Draw.cs
private void Update(EvaluationContext context)
{
    var vertexCount = VertexCount.GetValue(context);
    var startVertexLocation = VertexStartLocation.GetValue(context);

    var setVs = deviceContext.VertexShader.Get();
    var setPs = deviceContext.PixelShader.Get();

    if (setVs == null || setPs == null)
    {
        Log.Warning("Trying to issue draw call, but shaders are null.");
        return;
    }

    deviceContext.Draw(vertexCount, startVertexLocation);
}
```

The safety check (are shaders bound?) guards against wiring errors in the graph. Draw trusts that the pipeline state operators above it have already configured everything correctly.

## The Two Composition Primitives

Command nodes are useless alone. They need orchestration: something must call `PrepareAction`, trigger `Update` via `GetValue`, and later call `RestoreAction`. tixl has two orchestrators with different semantics.

### Execute: Parallel State Assembly

`Execute` collects multiple command inputs and runs them with a three-pass strategy:

```csharp
// Operators/Lib/Symbols/flow/Execute.cs
private void Update(EvaluationContext context)
{
    if (!IsEnabled.GetValue(context))
        return;

    var commands = Command.CollectedInputs;

    // Phase 1: Prepare ALL commands (set all GPU state)
    for (int i = 0; i < commands.Count; i++)
        commands[i].Value?.PrepareAction?.Invoke(context);

    // Phase 2: Execute ALL commands (fire draw calls)
    for (int i = 0; i < commands.Count; i++)
        commands[i].GetValue(context);

    // Phase 3: Restore ALL commands (undo all GPU state)
    for (int i = 0; i < commands.Count; i++)
        commands[i].Value?.RestoreAction?.Invoke(context);
}
```

This means all state-setting operators are active simultaneously when the draw call fires. The execution timeline looks like:

```
Time ──▸

SetShaderStage:    ┃ save+set ┃─────────active─────────┃ restore ┃
OutputMerger:      ┃ save+set ┃─────────active─────────┃ restore ┃
Rasterizer:        ┃ save+set ┃─────────active─────────┃ restore ┃
InputAssembler:    ┃ save+set ┃─────────active─────────┃ restore ┃
Draw:              ─────────────────┃ Draw() ┃──────────────────────
```

Execute is used **inside compounds** to assemble one complete GPU pipeline configuration. All the cooperating state operators need to be active simultaneously so that when `Draw` fires, shaders, buffers, blend state, and rasterizer state are all bound.

### Group: Sequential Object Composition

`Group` iterates its children with per-child bracketing:

```csharp
// Operators/Lib/Symbols/render/transform/Group.cs
private void Update(EvaluationContext context)
{
    // Build transform matrix from Translation, Rotation, Scale inputs
    var objectToParentObject = GraphicsMath.CreateTransformationMatrix(s, r, t);

    // Save and push hierarchical state
    var previousWorldToObject = context.ObjectToWorld;
    context.ObjectToWorld = Matrix4x4.Multiply(objectToParentObject, context.ObjectToWorld);

    var previousColor = context.ForegroundColor;
    context.ForegroundColor *= Color.GetValue(context);

    // Iterate children: each gets full prepare/execute/restore
    if (IsEnabled.GetValue(context) && color.W > 0)
    {
        foreach (var child in Commands.CollectedInputs)
        {
            child.Value?.PrepareAction?.Invoke(context);
            child.GetValue(context);
            child.Value?.RestoreAction?.Invoke(context);
        }
    }

    // Restore hierarchical state
    context.ForegroundColor = previousColor;
    context.ObjectToWorld = previousWorldToObject;
}
```

The execution timeline for two children:

```
Time ──▸

Child 1 (DrawMesh A):  ┃ prepare ┃ execute ┃ restore ┃
Child 2 (DrawMesh B):  ──────────────────────┃ prepare ┃ execute ┃ restore ┃
```

Each child sets up its own complete GPU state, draws, and tears down before the next child begins. Children are fully independent — they don't share state.

Group also pushes hierarchical state onto the EvaluationContext (transforms, color). These affect all children uniformly and are restored after iteration. This is the mechanism for scene hierarchy: a parent Group at position [10,0,0] containing two DrawMesh children places both meshes offset by [10,0,0] without the children knowing.

### When to Use Which

| Primitive | Use case | State lifetime | Children are... |
|-----------|----------|---------------|----------------|
| **Execute** | Inside a compound: assemble one pipeline config | All active simultaneously | Cooperating parts of one operation |
| **Group** | Scene composition: draw multiple objects | Each fully set up and torn down | Independent objects |

## Compound Operators: The User-Facing Layer

Users never interact with primitive command nodes directly. They use compound operators — graph nodes that contain internal sub-graphs.

### How a Compound is Defined

A compound operator consists of three files:

| File | Purpose |
|------|---------|
| `DrawMesh.cs` | C# class declaring exposed input/output ports |
| `DrawMesh.t3` | JSON sub-graph: children, connections, default values |
| `DrawMesh.t3ui` | Visual layout metadata: node positions, sizes |

The C# class declares what the user sees:

```csharp
internal sealed class DrawMesh : Instance<DrawMesh>
{
    [Output] public readonly Slot<Command> Output = new();

    [Input] public readonly InputSlot<Vector4> Color = new();
    [Input] public readonly InputSlot<MeshBuffers> Mesh = new();
    [Input] public readonly InputSlot<int> BlendMode = new();
    [Input] public readonly InputSlot<string> Culling = new();
    [Input] public readonly InputSlot<bool> EnableZTest = new();
    [Input] public readonly InputSlot<bool> EnableZWrite = new();
    // ... 14 inputs total
}
```

The `.t3` file defines the internal sub-graph: 25 child nodes wired together with ~35 connections. This is where the primitive command nodes live.

### Inside DrawMesh: The Sub-Graph

The `.t3` JSON contains three sections:

**Inputs** — exposed ports with default values:
```json
{ "Id": "8c9dee45-...", "Name": "Color", "DefaultValue": {"X":1,"Y":1,"Z":1,"W":1} },
{ "Id": "97429e1f-...", "Name": "Mesh", "DefaultValue": null },
{ "Id": "9e957f4a-...", "Name": "Culling", "DefaultValue": "Back" }
```

**Children** — internal operator instances:
```json
{ "Id": "69767494-...", "SymbolId": "b956f707-..." }  // SetPixelAndVertexShaderStage
{ "Id": "44cb1668-...", "SymbolId": "9d1266c5-..." }  // InputAssemblerStage
{ "Id": "eddca9ff-...", "SymbolId": "fbd7f0f0-..." }  // Rasterizer
{ "Id": "8632c707-...", "SymbolId": "5efaf208-..." }  // OutputMergerStage
{ "Id": "ad43d468-...", "SymbolId": "9b28e6b9-..." }  // Draw
{ "Id": "1ac59a27-...", "SymbolId": "936e4324-..." }  // Execute (orchestrator)
// ... plus 19 resource/utility nodes
```

**Connections** — wiring between children and exposed ports:

The critical connections wire the five command operators as **siblings into Execute's multi-input slot**:

```json
// InputAssemblerStage.Output → Execute.Commands
{ "Source": "44cb1668/18cae035", "Target": "1ac59a27/5d73ebe6" },
// SetPixelAndVertexShaderStage.Output → Execute.Commands
{ "Source": "69767494/805e271d", "Target": "1ac59a27/5d73ebe6" },
// Rasterizer.Output → Execute.Commands
{ "Source": "eddca9ff/c723ad69", "Target": "1ac59a27/5d73ebe6" },
// OutputMergerStage.Output → Execute.Commands
{ "Source": "8632c707/cee8c3f0", "Target": "1ac59a27/5d73ebe6" },
// Draw.Output → Execute.Commands
{ "Source": "ad43d468/49b28dc3", "Target": "1ac59a27/5d73ebe6" }
```

And Execute's output routes to the compound's exposed output:

```json
// Execute.Output → DrawMesh.Output (exposed)
{ "Source": "1ac59a27/e81c99ce", "Target": "00000000/53b3fdca" }
```

The `00000000` target ID means "the compound's own port" — the boundary between inside and outside.

### The Data Flow Inside DrawMesh

The remaining ~20 children prepare the resources that the five command nodes consume:

```
User Inputs                          Resource Preparation           Command Nodes
───────────                          ────────────────────           ─────────────
Color ──▸ Vector4Components ──▸ FloatsToBuffer ──────────────────▸ SetPixelAndVertexShaderStage
Mesh ───▸ _MeshBufferComponents ─────────────────────────────────▸ InputAssemblerStage
                                                                   │
(context) ──▸ TransformsConstBuffer ─────────────────────────────▸ │ (ConstantBuffers multi-input)
(context) ──▸ ContextCBuffers ───────────────────────────────────▸ │
                                                                   │
ShaderSource ──▸ GenerateShaderGraphCode ──▸ VertexShaderFromSrc ▸ │ (VertexShader input)
                                    └──────▸ PixelShaderFromSrc ─▸ │ (PixelShader input)
                                                                   │
Filter ──▸ SamplerState (linear) ────────────────────────────────▸ │ (SamplerStates multi-input)
         ┌ SamplerState (clamped) ───────────────────────────────▸ │
WrapMode ┘                                                         │
                                                                   │
PbrTextures ──▸ SrvFromTexture2d (albedo, normal, RMO, etc.) ───▸ │ (ShaderResources multi-input)
                                                                   │
Culling ──▸ RasterizerState ─────────────────────────────────────▸ Rasterizer
FillMode ──┘                                                       │
                                                                   │
BlendMode ──▸ PickBlendMode ──▸ BlendState ──────────────────────▸ OutputMergerStage
EnableZTest ──▸ DepthStencilState ───────────────────────────────▸ │
EnableZWrite ──┘                                                   │
                                                                   │
MeshBufferComponents.IndexCount ─────────────────────────────────▸ Draw (VertexCount)
                                                                   │
                                All five ─────────────────────────▸ Execute
                                                                      │
                                                                      ▼
                                                                   OUTPUT
```

The resource nodes are standard value slots — they only re-evaluate when their inputs change (dirty-flag gated). The command nodes are always re-evaluated every frame. Execute orchestrates the three-pass prepare/execute/restore sequence.

## What the User Sees in the Editor

### Placing and Wiring Nodes

The operator browser is organized by filesystem namespace:

```
Lib > mesh > draw > DrawMesh
Lib > mesh > draw > DrawMeshUnlit
Lib > mesh > draw > DrawMeshAtPoints
Lib > render > camera > OrbitCamera
Lib > render > camera > Camera
Lib > render > transform > Group
Lib > render > scene > DrawScene
Lib > image > generate > RenderTarget
Lib > image > fx > Bloom
Lib > image > fx > ColorGrade
```

The user drags nodes onto the canvas and wires them. Type checking is enforced: a `Slot<Command>` output can only connect to a `Slot<Command>` or `MultiInputSlot<Command>` input. A `Slot<Texture2D>` output cannot connect to a `Slot<Command>` input.

### A Typical Scene

A standard PBR scene with post-processing uses 10-15 visible nodes:

```
SphereMesh ──▸ DrawMesh ──┐
                          ├──▸ Group ──▸ OrbitCamera ──▸ RenderTarget ──▸ Bloom ──▸ ColorGrade ──▸ Layer2d
CubeMesh ────▸ DrawMesh ──┘       │
                            Pos: [0,2,0]
```

Each DrawMesh hides its 25-node internal pipeline. Group provides the transform hierarchy. Camera provides view/projection matrices. RenderTarget captures the scene to a texture (the command-to-value phase boundary). Bloom and ColorGrade are value-chain operators processing the texture.

### Drilling Into Compounds

Double-clicking a compound node opens its internal sub-graph in a new editor view. The user can see and modify the wiring between primitive nodes. This is how power users create custom rendering setups — duplicate DrawMesh, replace the shader source, add extra SRV bindings, change the rasterizer defaults.

The back button returns to the parent graph.

### Parameter Editing

Clicking a node shows its input ports in a property panel. Most inputs have defaults that work out of the box:

| DrawMesh Input | Default | User changes it when... |
|---------------|---------|------------------------|
| Color | white [1,1,1,1] | They want a tinted mesh |
| Mesh | null (required) | Always — must connect a mesh generator |
| Culling | Back | Rendering double-sided geometry |
| FillMode | Solid (3) | Wireframe debugging |
| BlendMode | 0 (opaque) | Transparent objects |
| EnableZTest | true | 2D overlays, UI |
| EnableZWrite | true | Transparent objects |
| Shading | 0 (default PBR) | Custom shader override |
| Filter | MinMagMipLinear | Pixel art (use point filtering) |
| WrapMode | Wrap | Clamped edge textures |

### ICompoundWithUpdate: Wrapping Context Around Children

Some compounds need to modify the EvaluationContext before their internal sub-graph runs. `DrawScene` demonstrates this:

```csharp
// Operators/Lib/Symbols/render/scene/DrawScene.cs
internal sealed class DrawScene : Instance<DrawScene>, ICompoundWithUpdate
{
    private void Update(EvaluationContext context)
    {
        // Select material by name from context
        var previousMaterial = context.PbrMaterial;
        var materialId = UseMaterialId.GetValue(context);
        if (!string.IsNullOrEmpty(materialId))
        {
            foreach (var m in context.Materials)
            {
                if (m.Name == materialId)
                {
                    context.PbrMaterial = m;
                    break;
                }
            }
        }

        // Execute the internal sub-graph
        Output.ConnectedUpdate(context);

        // Restore
        context.PbrMaterial = previousMaterial;
    }
}
```

The `ICompoundWithUpdate` marker interface tells the graph evaluator that this compound's C# class has an `Update` method that should wrap the sub-graph execution. Without it, the sub-graph evaluates on its own; with it, the C# class intercepts evaluation to push/pop context state.

## Summary: The Architecture Stack

```
┌──────────────────────────────────────────────────────────────┐
│  User-Facing Layer                                            │
│  DrawMesh, DrawScene, OrbitCamera, Group, RenderTarget        │
│  (compound operators, 10-15 per scene)                        │
├──────────────────────────────────────────────────────────────┤
│  Composition Layer                                            │
│  Execute (parallel state assembly)                            │
│  Group (sequential object iteration)                          │
│  ExecRepeatedly (N-times command loop)                        │
│  Switch / ExecuteIf (conditional branching)                   │
├──────────────────────────────────────────────────────────────┤
│  GPU Command Layer                                            │
│  SetPixelAndVertexShaderStage, OutputMergerStage,             │
│  InputAssemblerStage, Rasterizer, Draw, DrawInstancedIndirect │
│  (save/set/restore pattern)                                   │
├──────────────────────────────────────────────────────────────┤
│  Resource Layer                                               │
│  TransformsConstBuffer, FloatsToBuffer, SrvFromTexture2d,     │
│  SamplerState, RasterizerState, BlendState, DepthStencilState │
│  (value slots, dirty-flag cached)                             │
├──────────────────────────────────────────────────────────────┤
│  DX11 (SharpDX)                                              │
│  device.ImmediateContext — global mutable pipeline state       │
└──────────────────────────────────────────────────────────────┘
```

Each layer only talks to the one directly below it. Users compose at the top. Compounds wire together the middle. The bottom two layers are the concrete GPU interface. The entire stack evaluates in a single recursive `GetValue` call from the root output slot.
