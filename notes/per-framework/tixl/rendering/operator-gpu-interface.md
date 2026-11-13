# tixl — Operator-to-GPU Interface

## Key Insight

> **Operators are the GPU interface.** There is no abstraction layer between an operator's `UpdateAction` and the DX11 device context. Operators declare typed slots via C# attributes, reference HLSL shaders by file path, manually pack cbuffers with `[StructLayout]` structs, and bind textures positionally through `MultiInputSlot<ShaderResourceView>`. The entire GPU pipeline — from slot declaration to draw call — is expressed in the operator graph.

## Overview

This document covers the interface between tixl's operator graph and the GPU: how operators declare themselves, how shaders bind, how parameters flow from UI to cbuffer, how textures reach shader registers, how geometry is supplied, where pipeline state lives, how multi-pass pipelines compose, and what the serialization boundary looks like.

These are the questions that determine whether flux-gpu's `Graph`, `InputPort`/`OutputPort`, and operator model need new abstractions or can map directly onto tixl's proven patterns.

---

## Q1: Operator Self-Description

### How Operators Declare Inputs, Outputs, and Types

The mechanism is **C# field declarations with attributes, discovered via runtime reflection at assembly load**. There is no manifest, no codegen, no registration call.

An operator declares public fields of generic slot types, decorated with `[Input]` or `[Output]`:

**`Operators/Lib/Symbols/numbers/float/basic/Add.cs`** — a minimal value operator:

```csharp
[Guid("c160f925-0a66-4505-a569-cadd878dbb6f")]
internal sealed class Add : Instance<Add>
{
    [Output(Guid = "{5CE9C625-F890-4620-9747-C98EAB4B9447}")]
    public readonly Slot<float> Result = new();

    [Input(Guid = "{E3550929-8905-4CDF-BC85-C31E97DA4BAA}")]
    public readonly InputSlot<float> Input1 = new();

    [Input(Guid = "{993D59BB-1FC0-4857-A36D-629B0E7AA0D2}")]
    public readonly InputSlot<float> Input2 = new();

    public Add() { Result.UpdateAction += Update; }

    private void Update(EvaluationContext context)
    {
        Result.Value = Input1.GetValue(context) + Input2.GetValue(context);
    }
}
```

**`Operators/Lib/Symbols/render/_dx11/fxsetup/SetPixelAndVertexShaderStage.cs`** — a rendering operator:

```csharp
[Input(...)] public readonly InputSlot<VertexShader> VertexShader = new();
[Input(...)] public readonly InputSlot<PixelShader> PixelShader = new();
[Input(...)] public readonly MultiInputSlot<Buffer> ConstantBuffers = new();
[Input(...)] public readonly MultiInputSlot<ShaderResourceView> ShaderResources = new();
[Input(...)] public readonly MultiInputSlot<SamplerState> SamplerStates = new();
```

The C# type parameter `T` carries the data type: `float`, `Texture2D`, `Command`, `Buffer`, `ShaderResourceView`, `PbrMaterial`, any SharpDX type, or any custom data type. The slot GUID provides stable identity across refactors — connections persist as long as the GUID is preserved, even if the field is renamed.

### The Registration System: Pure Reflection

**`Core/Compilation/AssemblyInformation.TypeInfoExtraction.cs:117`**:

```csharp
private static void SetUpOperatorType(Type type, ...)
{
    TryGetGuidOfType(type, out var id);   // reads [GuidAttribute]

    var allMembers = type.GetMembers(BindingFlags.Public | BindingFlags.NonPublic
                                   | BindingFlags.DeclaredOnly | BindingFlags.Instance);
    for (int i = 0; i < allMembers.Length; i++)
    {
        if (member is not FieldInfo field) continue;
        if (!fieldType.IsAssignableTo(typeof(ISlot))) continue;

        if (fieldType.IsAssignableTo(typeof(IInputSlot)))
            inputFields.Add(new InputSlotInfo(...));
        else
            outputFields.Add(new OutputSlotInfo(...));
    }
    operatorTypeInfo.TryAdd(id, new OperatorTypeInfo(type, inputFields, outputFields));
}
```

This runs in parallel across all types at assembly load. Adding a new operator is purely a matter of creating a C# class inheriting `Instance<T>` — zero registration boilerplate.

### Output Texture Format and Dimensions

**There is no format inference.** Every operator that allocates a texture declares explicit inputs for format and size:

**`Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs`**:

```csharp
[Input(...)] public readonly InputSlot<Int2> Resolution = new();
[Input(...)] public readonly InputSlot<Format> TextureFormat = new();
[Input(...)] public readonly InputSlot<bool> WithDepthBuffer = new();
[Input(...)] public readonly InputSlot<bool> WithNormalBuffer = new();
[Input(..., MappedType = typeof(Samples))] public readonly InputSlot<int> Multisampling = new();
```

Resolution has one fallback: if width or height is 0, it inherits from `context.RequestedResolution`. But format is always explicit — there is no propagation from upstream textures.

The `MappedType` attribute tells the UI to render `int` as an enum dropdown (e.g., MSAA sample counts: 1, 2, 4, 8).

---

## Q2: Shader-to-Operator Binding

### Shader Source: Separate Files Referenced by Path

Shaders are **separate `.hlsl` files**, not embedded. A `PixelShader` operator takes a path string as input:

**`Operators/TypeOperators/Symbols/Gfx/PixelShader.cs`**:

```csharp
[Input(...)] public readonly InputSlot<string> Source = new();      // relative path to .hlsl
[Input(...)] public readonly InputSlot<string> EntryPoint = new();  // e.g. "psMain"
```

The `PixelShader` operator implements `IShaderOperator<PixelShaderT3>`. Its `Initialize()` creates a file-watched resource:

**`Core/Operator/IShaderOperator.cs:128`**:

```csharp
void Initialize()
{
    var resource = ResourceManager.CreateShaderResource<T>(Path, () => CachedEntryPoint);
    resource.AddDependentSlots(shaderSlot);   // invalidate slot when file changes on disk

    shaderSlot.UpdateAction = context =>
    {
        CachedEntryPoint = EntryPoint.GetValue(context);
        ShaderSlot.Value = resource.GetValue(context);   // compiled shader object
    };
}
```

Path resolution searches: (1) the operator's own package resource folder, (2) other registered packages, (3) global shared shader packages. No absolute paths anywhere in operator code.

There is also `PixelShaderFromSource` for inline HLSL (live coding):

```csharp
[Input(...)] public readonly InputSlot<string> ShaderSource = new();  // literal HLSL string
```

The shader compiler caches bytecode by hash of the source string.

### Parameter-to-Cbuffer Sync: Entirely Manual

There is **no codegen, no shader reflection, no automatic sync**. Developers manually define C# structs with `[StructLayout(LayoutKind.Explicit)]` matching the HLSL cbuffer, then call `ResourceManager.SetupConstBuffer`.

**C# side** (`Operators/Lib/Symbols/image/fx/_/_ExecuteBloomPasses.cs:305`):

```csharp
[StructLayout(LayoutKind.Explicit, Size = 16)]
private struct ThresholdParams
{
    [FieldOffset(0)]  public Vector3 ColorWeights;   // 12 bytes
    [FieldOffset(12)] public float Threshold;         // 4 bytes
}
```

**HLSL side** (`Operators/Lib/Assets/shaders/img/blur/Bloom-BrightpassPS.hlsl`):

```hlsl
cbuffer ThresholdParams : register(b0)
{
    float3 ColorWeights;
    float Threshold;
};
```

**Upload** (`_ExecuteBloomPasses.cs:141`):

```csharp
_thresholdParams.Threshold = threshold;
_thresholdParams.ColorWeights = new Vector3(colorWeights.X, colorWeights.Y, colorWeights.Z);
ResourceManager.SetupConstBuffer(_thresholdParams, ref _thresholdParamsBuffer);
deviceContext.PixelShader.SetConstantBuffer(0, _thresholdParamsBuffer);
```

`ResourceManager.SetupConstBuffer` uses `DataStream.Write(bufferData)` — a raw struct memory copy via `Marshal`. Alignment is entirely the developer's responsibility. HLSL cbuffer rules (16-byte alignment, packing) must be obeyed manually.

**`TransformBufferLayout`** (`Core/Rendering/TransformBufferLayout.cs`) is the most structured example: 10 `Matrix4x4` values at explicit `[FieldOffset]` increments of 64 bytes, with manual transposition for HLSL's row-major convention.

**`PbrMaterial.PbrParameters`** (`Core/Rendering/Material/PbrMaterial.cs:29`):

```csharp
[StructLayout(LayoutKind.Explicit, Size = Stride)]
public struct PbrParameters
{
    [FieldOffset(0)]  public Vector4 BaseColor;       // 16 bytes
    [FieldOffset(16)] public Vector4 EmissiveColor;   // 16 bytes
    [FieldOffset(32)] public float Roughness;          // 4 bytes
    [FieldOffset(36)] public float Specular;           // 4 bytes
    [FieldOffset(40)] public float Metal;              // 4 bytes
    [FieldOffset(44)] private float __padding;         // explicit HLSL alignment padding
    public const int Stride = 48;
}
```

### The `FloatsToBuffer` Graph-Level Packing Node

For dynamically-composed shaders, `FloatsToBuffer` collects all connected float inputs and packs them sequentially into a buffer:

**`Operators/Lib/Symbols/render/_dx11/api/FloatsToBuffer.cs:18`**:

```csharp
private void Update(EvaluationContext context)
{
    var floatParams = Params.GetCollectedTypedInputs();
    for (var i = 0; i < floatParams.Count; i++)
        _uploadBuffer[totalFloatIndex++] = floatParams[i].GetValue(context);

    ResourceUtils.WriteDynamicBufferData<float>(
        device.ImmediateContext, Buffer.Value, _uploadBuffer.AsSpan(0, totalFloatCount));
}
```

The graph connection order determines the byte layout. The HLSL shader must match the expected order. This is entirely manual.

---

## Q3: Parameters Through the Graph

### Where User-Set Values Are Stored

Values live in **three layers**:

| Layer | Location | When used |
|-------|----------|-----------|
| **Type default** | `Symbol.InputDefinition.DefaultValue` | Factory default for freshly placed node |
| **Per-instance override** | `Symbol.Child.Input.Value` + `IsDefault = false` | User changed value in editor |
| **Animation** | `Symbol.Animator` (curve per childId/inputId) | Animated parameter (wins over static) |

**Per-instance overrides** are stored in the `.t3` file under each child's `InputValues` array. Only non-default values are written — `if (inputValue.IsDefault) continue`:

```json
{
  "Id": "f8e99532...",
  "SymbolId": "4912ba82...",
  "InputValues": [
    { "Id": "747e043b...", "Type": "System.Single", "Value": 96.6 },
    { "Id": "7b77b6fb...", "Type": "System.Numerics.Vector4",
      "Value": { "X": 0.803, "Y": 0.829, "Z": 0.282, "W": 1.0 } }
  ]
}
```

At runtime, `InputSlot<T>.InputUpdate()` reads through to `Symbol.Child.Input`:

```csharp
public void InputUpdate(EvaluationContext context)
{
    Value = Input.IsDefault ? TypedDefaultValue.Value : TypedInputValue.Value;
}
```

**Animation** lives in a separate `"Animator"` section of the same `.t3` file. When both static and animated values exist for the same input, animation wins — it replaces the slot's `UpdateAction` with a curve evaluator.

### How Uniform Buffers Get Populated

**Every operator packs its own cbuffers manually.** There is no framework-level automatic collection.

Three patterns exist:

1. **Explicit struct** — `SetMaterial.Update()` reads `InputSlot<float>` values, fills a `PbrParameters` struct, calls `UpdateParameterBuffer()` → `ResourceManager.SetupConstBuffer(Parameters, ref ParameterBuffer)`

2. **Graph-wired `FloatsToBuffer`** — collects all connected `MultiInputSlot<float>` values into a sequential buffer. Connection order = byte layout.

3. **Context-sourced `TransformsConstBuffer`** — reads `context.CameraToClipSpace`, `context.WorldToCamera`, `context.ObjectToWorld`, packs into a 640-byte struct with ping-pong buffering for motion blur.

---

## Q4: Resource Binding (The Bind Group Problem)

### How Textures Connect to Shader Slots

The binding model is **positional-by-connection-order**. No name matching, no semantics.

`SetPixelAndVertexShaderStage` binds its `MultiInputSlot<ShaderResourceView>` as an array starting at register 0:

**`Operators/Lib/Symbols/render/_dx11/fxsetup/SetPixelAndVertexShaderStage.cs:23`**:

```csharp
ShaderResources.GetValues(ref _shaderResourceViews, context);
ConstantBuffers.GetValues(ref _constantBuffers, context);

vsStage.SetShaderResources(0, _shaderResourceViews.Length, _shaderResourceViews);  // t0, t1, t2...
vsStage.SetConstantBuffers(0, _constantBuffers.Length, _constantBuffers);            // b0, b1, b2...
psStage.SetShaderResources(0, _shaderResourceViews.Length, _shaderResourceViews);
psStage.SetConstantBuffers(0, _constantBuffers.Length, _constantBuffers);
```

Whatever is wired to the first input of `ShaderResources` goes to `t0`, second to `t1`, and so on. The HLSL shader must declare `Texture2D albedo : register(t0)` to match. Rewiring the graph silently changes the register mapping.

`SrvFromTexture2d` is the adapter: it wraps a `Texture2D` into a `ShaderResourceView`. It carries no metadata about which register it targets.

### Multiple Textures: Typed Input Ports

Operators that consume multiple textures use **one named `InputSlot<Texture2D>` per map**:

**`Operators/Lib/Symbols/render/shading/SetMaterial.cs:112`**:

```csharp
[Input(...)] public readonly InputSlot<Texture2D> BaseColorMap = new();
[Input(...)] public readonly InputSlot<Texture2D> EmissiveColorMap = new();
[Input(...)] public readonly InputSlot<Texture2D> NormalMap = new();
[Input(...)] public readonly InputSlot<Texture2D> RoughnessMetallicOcclusionMap = new();
```

Each is stored on a `PbrMaterial` object via context. `GetPbrParameters` then surfaces them as individual typed outputs:

```csharp
AlbedoColorMap.Value = context.PbrMaterial.AlbedoMapSrv;
NormalMap.Value = context.PbrMaterial.NormalSrv;
```

### IBL Textures: Context Side-Channel

IBL textures (BRDF LUT, prefiltered specular) bypass the graph entirely. They are injected into `EvaluationContext.ContextTextures` by a `SetEnvironment` operator and retrieved by string key:

```csharp
context.ContextTextures.TryGetValue(PbrContextSettings.PrefilteredSpecularId, out var texture);
PrefilteredSpecularMap.Value = texture;
```

This is an implicit global side-channel — convenient but invisible in the graph editor.

---

## Q5: Draw Calls and Geometry

### Separation of "What to Draw" from "How to Draw It"

They are **completely separate operators**, composed through the graph. `DrawMesh` is a compound operator whose `.t3` subgraph internally wires together:

- `_MeshBufferComponents` — extracts vertex/index buffers from `MeshBuffers`
- `GetBufferComponents` — creates SRVs from buffers
- `SetPixelAndVertexShaderStage` — binds shaders, SRVs, cbuffers, samplers
- `RasterizerState` — builds rasterizer state from CullMode, FillMode inputs
- `DepthStencilState` — builds depth-stencil state from EnableZTest, EnableZWrite
- `OutputMergerStage` — saves/restores blend state, depth-stencil, render targets
- `Rasterizer` — saves/restores rasterizer state and viewports
- `InputAssemblerStage` — sets primitive topology
- `Draw` — issues `deviceContext.Draw(vertexCount, 0)`

`Draw.cs` is a **completely dumb terminal**. It receives only two integers:

```csharp
[Input(...)] public readonly InputSlot<int> VertexCount = new();
[Input(...)] public readonly InputSlot<int> VertexStartLocation = new();
```

By the time control reaches `Draw.cs`, all pipeline state has been installed on the `ImmediateContext` by earlier commands in the Execute chain.

### Geometry: Bufferless Vertex Fetch via StructuredBuffer

This is tixl's most architecturally distinctive rendering choice. Vertex and index buffers are **not bound via the Input Assembler**. They are bound as `StructuredBuffer` SRVs, and the vertex shader uses `SV_VertexID` to index manually:

**`Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl:74`**:

```hlsl
StructuredBuffer<PbrVertex> PbrVertices : register(t0);
StructuredBuffer<int3> FaceIndices : register(t1);

psInput vsMain(uint id : SV_VertexID)
{
    int faceIndex = id / 3;
    int faceVertexIndex = id % 3;
    PbrVertex vertex = PbrVertices[FaceIndices[faceIndex][faceVertexIndex]];
    // ...
}
```

No `InputLayout`, no bound vertex buffer, no bound index buffer in the traditional sense. The `InputAssemblerStage` in `DrawMesh.t3` only sets `PrimitiveTopology`.

`MeshBuffers` flows as a **value-world graph resource** (`Slot<MeshBuffers>`). Multiple operators produce this type: `LoadObj`, `LoadGltf`, `CubeMesh`, `SphereMesh`, `TorusMesh`, and procedural generators. Modify operators (`TransformMesh`, `DeformMesh`, `DisplaceMesh`) consume and re-emit `MeshBuffers`.

The only two terminal draw operators are `Draw.cs` (`deviceContext.Draw`) and `DrawInstancedIndirect.cs` (`deviceContext.DrawInstancedIndirect`). There is no `DrawIndexed` — indexing is done in the shader.

---

## Q6: Pipeline State

### Where Pipeline State Lives

**Every piece of pipeline state is a separate operator with explicit `InputSlot<T>` parameters.** No state is inherited from context.

`OutputMergerStage.cs` receives blend and depth-stencil as typed slots:

```csharp
[Input(...)] public readonly InputSlot<BlendState> BlendState = new();
[Input(...)] public readonly InputSlot<DepthStencilState> DepthStencilState = new();
[Input(...)] public readonly InputSlot<DepthStencilView> DepthStencilView = new();
[Input(...)] public readonly MultiInputSlot<RenderTargetView> RenderTargetViews = new();
```

`Rasterizer.cs` receives rasterizer state and viewports:

```csharp
[Input(...)] public readonly InputSlot<RasterizerState> RasterizerState = new();
[Input(...)] public readonly MultiInputSlot<RawViewportF> Viewports = new();
```

`EvaluationContext` carries matrices, fog, materials, and lights — but **not** render pipeline state (blend, depth, cull). Those come through graph edges as typed DX11 state objects.

Each stage operator saves/restores: `Rasterizer.Update` captures `_prevState = rasterizer.State` and `Restore` calls `rasterizer.State = _prevState`.

### Multi-Render-Target Passes

MRT is handled inside `RenderTarget.cs` as a single operator with three outputs:

```csharp
[Output(...)] public readonly Slot<Texture2D> ColorBuffer = new();   // SV_Target0
[Output(...)] public readonly Slot<Texture2D> DepthBuffer = new();   // depth
[Output(...)] public readonly Slot<Texture2D> NormalBuffer = new();  // SV_Target1
```

When `WithNormalBuffer = true`, both color and normal RTVs are bound:

```csharp
deviceContext.OutputMerger.SetTargets(dsv, colorRtv, normalRtv);
```

This is a two-target MRT baked into the operator. The layout is not composable — adding a third target (e.g., velocity for TAA) requires modifying `RenderTarget.cs`. However, `OutputMergerStage` takes `MultiInputSlot<RenderTargetView>`, so arbitrary MRT is possible at the primitive API level.

---

## Q7: The Composition Question

### How Multi-Pass Pipelines Are Structured

A two-tier compound model: passes are encapsulated in subgraphs, those subgraphs can contain Execute nodes for command aggregation.

**3D scene (Command world)**: Camera, DrawMesh, Lights → wired into `Execute` (multi-input aggregator) → `RenderTarget` (boundary: Command in, Texture2D out)

**Post-processing (Value world)**: Bloom, ToneMap, ColorGrade → chained linearly as `Texture2D` → `Texture2D`

The `RenderTarget` operator is the phase boundary. Above it: Command-typed slots, always re-executed. Below it: Texture2D-typed slots, dirty-flag cached.

For multi-pass effects like **Bloom**, the structure is:

- **Layer 1** — `Bloom.cs`/`Bloom.t3` (compound): declares user-facing interface (Image input, Intensity, ColorWeights). The `.cs` file has no `UpdateAction`.
- **Layer 2** — Inside the `Bloom.t3` subgraph: `PixelShader` nodes (brightpass, blur, upsample HLSL), `SamplerState`, and `_ExecuteBloomPasses` (a private C# operator that drives 10+ render passes in a single `Update` call).

### How a User Creates a New Render Pass Type

Three escalating levels:

**Level 1 — Pure graph (zero logic code)**

Use `_multiImageFxSetup` as a base template. It is a pre-wired subgraph containing: PixelShader, VertexShader, RenderTarget, Execute, samplers, cbuffers. Connect `ShaderPath` to your `.hlsl` file path. The `.cs` file exists only for GUID and slot declaration — no `UpdateAction`:

```csharp
[Guid("a2567844-3314-48de-bda7-7904b5546535")]
internal sealed class _multiImageFxSetup : Instance<_multiImageFxSetup>
{
    [Output(...)] public readonly Slot<Texture2D> Output = new();
    [Input(...)]  public readonly InputSlot<string> ShaderPath = new();
    [Input(...)]  public readonly InputSlot<Texture2D> ImageA = new();
    // no UpdateAction — all behavior is in the .t3 subgraph
}
```

**Level 2 — Graph + HLSL**

Write a new `.hlsl` shader. Connect it into `_multiImageFxSetup` via a `PixelShader` node. No C# logic required.

**Level 3 — C# operator (full custom)**

For effects with dynamic pass counts (Bloom's variable mip levels), dynamic resource management, or bypassing per-node graph traversal overhead, write a C# `Instance<T>` with a full `UpdateAction`. `_ExecuteBloomPasses` is the reference: it manually drives passes in a loop, manages a `RenderTargetSet` pool, and uses `D3D11StateBackup` for save/restore.

**The boundary rule**: pure graph is sufficient for single-pass fullscreen effects. C# is required when pass count is dynamic or resources must be managed across frames.

---

## Q8: Serialization Boundary

### Minimal Code for a New Fullscreen Post-Process Pass

For a fixed-algorithm fullscreen effect:

- One `.hlsl` shader file (the pixel shader)
- One `.cs` file (slot declarations only — GUID, inputs, outputs, no logic)
- One `.t3` file (subgraph wiring `_multiImageFxSetup`)

The `.cs` file can literally be:

```csharp
[Guid("your-guid-here")]
internal sealed class MyEffect : Instance<MyEffect>
{
    [Output(Guid = "...")] public readonly Slot<Texture2D> Output = new();
    [Input(Guid = "...")]  public readonly InputSlot<Texture2D> Image = new();
    [Input(Guid = "...")]  public readonly InputSlot<float> Strength = new();
}
```

All GPU work happens in pre-existing primitive operators wired by the `.t3`.

### What's in a .t3 File

The `.t3` format uses **GUIDs exclusively** — no type names, no assembly references, no executable code:

```json
{
  "Id": "dda89242-8a90-4442-b3df-ed2d855e32a4",
  "SymbolId": "a3c5471e-079b-4d4b-886a-ec02d6428ff6",
  "InputValues": [
    { "Id": "9e957f4a...", "Type": "SharpDX.Direct3D11.CullMode", "Value": "None" }
  ]
}
```

The GUID→type resolution pipeline:

1. **Assembly scan** — `AssemblyInformation.SetUpOperatorType` reads `[GuidAttribute]` from every C# class, stores in `ConcurrentDictionary<Guid, OperatorTypeInfo>`
2. **Symbol creation** — `SymbolPackage.LoadSymbols` creates a `Symbol` for each type, keyed by GUID, registered in `SymbolRegistry`
3. **`.t3` load** — `SymbolJson.TryReadSymbolChild` extracts `SymbolId`, calls `SymbolRegistry.TryGetSymbol(guid)`. If not found → warning log, child skipped

**Portability**: A `.t3` file is **not portable without matching assemblies**. If the C# assembly for a referenced GUID is not loaded, that child is silently skipped. There is no embedded fallback.

The `Type` field in `InputValues` (e.g., `"SharpDX.Direct3D11.CullMode"`) is used only for JSON deserialization dispatch — it selects the right `JsonToTypeValueConverters` entry. It does not load assemblies by name.

---

## Implications for flux-gpu

### Adopt

**GUID-keyed slot identity.** Connections persist across refactors as long as the UUID is stable. In Rust, use `const UUID` on each slot field via a proc-macro attribute.

**Shader operators as graph nodes.** The `PixelShader` operator taking a file path and outputting a compiled shader object enables hot-reload, A/B switching via `Switch` nodes, and procedural shader path construction — all expressible as graph operations.

**Bufferless vertex fetch.** Translates directly to wgpu's `@builtin(vertex_index)` with storage buffers. Avoids `VertexBufferLayout` complexity and makes mesh data interchangeable with any buffer-backed resource.

**Explicit pipeline state as typed inputs.** Every draw compound declares its blend mode, cull mode, depth test as inputs, not ambient state. This is transparent and composable.

**Two-tier compound model.** User-facing clean interface (DrawMesh: 14 inputs) hiding internal complexity (25-node subgraph).

**Diffed-against-defaults serialization.** Only non-default values written. Keeps files compact.

### Modify

**Cbuffer sync via derive macro, not manual `[StructLayout]`.** In Rust, `#[derive(GpuLayout)]` + `bytemuck::Pod` can generate safe buffer packing and optionally validate layouts against WGSL declarations at startup via naga reflection.

**Named binding instead of positional.** tixl's "position-in-multi-input = register number" model silently breaks when wires are reordered. In wgpu, bind groups have explicit binding indices. Each texture port should carry a `@binding(N)` annotation validated against the shader.

**Composable MRT.** Rather than baking MRT into RenderTarget, expose `RenderPassDescriptor` with a typed list input (`MultiSlot<ColorAttachment>`) so the MRT layout is graph-configurable.

**Pure compound operators without a code file.** tixl requires a `.cs` file for GUID registration even for logic-free compounds. A Rust framework could represent compound operators purely as graph definition files with the UUID in the file header — no Rust struct needed.

**Format as `Option<TextureFormat>`.** Instead of `Format::Unknown` as a sentinel, use `None` for "inherit from context" and `Some(fmt)` for explicit.

### Avoid

**Unchecked cbuffer layout.** Mismatches between `[FieldOffset]` and HLSL are silent. In Rust, validate at startup via naga reflection.

**Positional SRV binding without validation.** Graph rewiring silently changes register mapping. Validate bindings against the shader's declared resources.

**`Dictionary<string, object>` escape hatches.** tixl's `ObjectVariables` on `EvaluationContext` and `MultiInputSlot<Object>` on `SetPixelAndVertexShaderStage` are type-unsafe holes. Use Rust's enum-based polymorphism or `anymap`-style typed storage.

**IBL textures via invisible context side-channel.** Prefer explicit optional ports with sensible defaults so the data flow is visible in the graph editor.

---

## Key Source Files

| File | Purpose |
|------|---------|
| `Core/Operator/Attributes/InputAttribute.cs` | `[Input]` attribute definition with GUID and MappedType |
| `Core/Operator/Attributes/OutputAttribute.cs` | `[Output]` attribute definition with DirtyFlagTrigger |
| `Core/Compilation/AssemblyInformation.TypeInfoExtraction.cs` | Assembly scan: reflection → OperatorTypeInfo registry |
| `Core/Operator/IShaderOperator.cs` | File-watched shader compilation, invalidation on disk change |
| `Operators/TypeOperators/Symbols/Gfx/PixelShader.cs` | Shader-as-graph-node: path input → compiled shader output |
| `Core/Resource/ResourceManager.Graphics.cs` | `SetupConstBuffer<T>`: struct → GPU cbuffer upload |
| `Core/Rendering/TransformBufferLayout.cs` | 10-matrix cbuffer layout with explicit `[FieldOffset]` |
| `Core/Rendering/Material/PbrMaterial.cs` | PbrParameters struct: BaseColor, Roughness, Metal, padding |
| `Operators/Lib/Symbols/render/_dx11/api/FloatsToBuffer.cs` | Graph-level cbuffer packing: connection order = byte layout |
| `Operators/Lib/Symbols/render/_dx11/fxsetup/SetPixelAndVertexShaderStage.cs` | Positional SRV/CB binding: index = register number |
| `Operators/Lib/Symbols/render/shading/SetMaterial.cs` | Per-texture named inputs: BaseColorMap, NormalMap, etc. |
| `Operators/Lib/Symbols/render/shading/_/GetPbrParameters.cs` | Context → typed SRV outputs for PBR textures |
| `Operators/Lib/Symbols/render/_dx11/api/Draw.cs` | Terminal draw: receives only vertexCount + startVertex |
| `Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl` | Bufferless vertex fetch: StructuredBuffer + SV_VertexID |
| `Operators/Lib/Symbols/render/_dx11/api/OutputMergerStage.cs` | Blend/depth-stencil/RTV state as typed InputSlots |
| `Operators/Lib/Symbols/render/_dx11/api/Rasterizer.cs` | Rasterizer state + viewport as typed InputSlots |
| `Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs` | Phase boundary: Command input → Texture2D outputs, MRT |
| `Operators/Lib/Symbols/image/fx/_/_multiImageFxSetup.cs` | Generic fullscreen-effect template: zero-logic compound |
| `Operators/Lib/Symbols/image/fx/_/_ExecuteBloomPasses.cs` | Multi-pass C# executor: manual pass loop + state backup |
| `Core/Model/SymbolJson.cs` | .t3 serialization: GUID-only child refs, diffed InputValues |
| `Core/Operator/Symbol.Child.cs` | Instance-level value storage: Input, IsDefault, Clone |
