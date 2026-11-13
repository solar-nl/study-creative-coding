# End-to-End Frame Trace: Rendering a PBR Mesh with Lighting

A single rendered frame in tixl travels a surprisingly long road before it becomes pixels on screen. The journey begins not in a traditional render loop but in a C# operator graph — a directed acyclic graph where each node is a live .NET object and each edge is a typed slot connection. Understanding this path is essential for understanding how tixl decouples scene description from GPU execution while still issuing efficient DirectX 11 draw calls.

This document traces one complete frame rendering a PBR mesh with point lights and IBL. The scenario is a `Camera` operator wrapping a `RenderTarget`, which wraps a `DrawMesh` operator connected to mesh geometry. That `DrawMesh` compound in turn contains shader setup, state configuration, and a raw `Draw` call. We follow data from the Windows message pump through operator graph traversal, camera matrix propagation, framebuffer allocation, shader resource binding, and finally the swap chain `Present` call.

The mental model to keep in mind throughout is that tixl operators are not fire-and-forget functions. They are stateful objects that check a dirty flag before recomputing, and they communicate through a shared `EvaluationContext` object that flows through the graph like a baton in a relay race — each operator reads from it, writes to it, and hands it to its children before restoring it on the way back out.

---

## The Scenario

```
Player (Texture2D output)
  └─ RenderTarget
        └─ Camera
              └─ DrawMesh
                    ├─ [Mesh geometry: SphereMesh]
                    └─ [Material via context: SetMaterial -> PBR textures]
```

The root output slot of the project is a `Slot<Texture2D>`. The player calls `GetValue` on it each frame, triggering the entire graph to evaluate recursively.

---

## Step 1: Main Loop Entry and Swap Chain Setup

**File:** `Player/Program.cs:133-178` and `Player/Program.RenderLoop.cs:16-82`

The player application creates a triple-buffered DXGI swap chain and a back-buffer render target view during startup. The swap chain is configured for 1920x1080, `R8G8B8A8_UNorm`, `FlipDiscard` swap effect, and hardware feature level 11.1 (with 11.0 fallback).

```csharp
// Player/Program.cs:133
var desc = new SwapChainDescription
{
    BufferCount = 3,
    ModeDescription = new ModeDescription(resolution.Width, resolution.Height,
                                          new Rational(60, 1), Format.R8G8B8A8_UNorm),
    IsWindowed = _resolvedOptions.Windowed,
    OutputHandle = windowHandle,
    SampleDescription = new SampleDescription(1, 0),
    SwapEffect = SwapEffect.FlipDiscard,
    Flags = SwapChainFlags.AllowModeSwitch,
    Usage = Usage.RenderTargetOutput,
};

Device.CreateWithSwapChain(DriverType.Hardware, deviceCreationFlags, desc, out _device, out _swapChain);
```

After startup, the main loop runs via `RenderLoop.Run(_renderForm, RenderCallback)` — SharpDX's Windows message pump wrapper. Each pump cycle calls `RenderCallback`.

The render callback does the following, in order:

```csharp
// Player/Program.RenderLoop.cs:41-81
DirtyFlag.IncrementGlobalTicks();   // advance the global dirty counter by 100 ticks
DirtyFlag.InvalidationRefFrame++;   // bump the invalidation reference epoch

_deviceContext.Rasterizer.SetViewport(new Viewport(0, 0, _resolution.Width, _resolution.Height, 0.0f, 1.0f));
_deviceContext.OutputMerger.SetTargets(_renderView);  // bind back buffer as default target

_evalContext.Reset();
_evalContext.RequestedResolution = _resolution;

_textureOutput.Invalidate();                          // mark root slot dirty
var outputTexture = _textureOutput.GetValue(_evalContext);  // kick off graph evaluation
```

The DX11 API calls at this point set the output merger to the swap chain back buffer and configure the rasterizer viewport. These are overridden almost immediately by `RenderTarget`, but they serve as a safe default and as the final destination for the compositing pass.

---

## Step 2: Dirty Flag Propagation and Graph Invalidation

**File:** `Core/Operator/Slots/DirtyFlag.cs:9-37` and `Core/Operator/Slots/Slot.cs:159-186`

Before evaluation begins, the frame increments two global counters:

```csharp
// Core/Operator/Slots/DirtyFlag.cs:9
public static void IncrementGlobalTicks()
{
    _globalTickCount += GlobalTickDiffPerFrame;  // +100 each frame
}

// DirtyFlag.cs:14
public bool IsDirty => TriggerIsEnabled || Reference != Target;
```

The dirty flag system works like a generation counter. Each slot has a `Reference` (the generation last evaluated) and a `Target` (the current expected generation). A slot is dirty when `Reference != Target`. When a slot with `DirtyFlagTrigger.Animated` is invalidated, its `Target` increments. When a slot is evaluated, its `Reference` is set to match `Target` via `DirtyFlag.Clear()`.

Think of this like a version vector in distributed systems: each slot tracks what version of the world it last computed against. When the world version advances, it knows it needs to recompute.

The `Invalidate()` call on the root texture output walks the connection graph upward, bumping `Target` on every slot that has a dirty input:

```csharp
// Core/Operator/Slots/Slot.cs:269-326
public int Invalidate()
{
    // if connected, propagate upstream
    if (InputConnections.Length > 0)
    {
        var target = InputConnections[0].Invalidate();
        _dirtyFlag.Target = target;
        return target;
    }

    // unconnected output slots: check all parent inputs
    bool outputDirty = _dirtyFlag.IsDirty;
    for (var i = 0; i < parentInputCount; i++)
    {
        input.Invalidate();
        outputDirty |= input.IsDirty;
    }

    if (outputDirty)
        return _dirtyFlag.Invalidate();
    ...
}
```

After invalidation, `GetValue` triggers evaluation:

```csharp
// Core/Operator/Slots/Slot.cs:181-186
public T? GetValue(EvaluationContext context)
{
    Update(context);
    return Value;
}

public void Update(EvaluationContext context)
{
    if (_dirtyFlag.IsDirty || _valueIsCommand)
    {
        UpdateAction?.Invoke(context);
        _dirtyFlag.Clear();
    }
}
```

The `_valueIsCommand` check is the key insight: `Command`-typed slots are always re-executed regardless of dirty state, because they represent side-effectful GPU operations that must fire every frame.

---

## Step 3: EvaluationContext Reset and Camera Matrix Preparation

**File:** `Core/Operator/EvaluationContext.cs:35-96`

At the start of each frame, `_evalContext.Reset()` is called before graph evaluation begins. This clears the point light stack, resets all context variables, and applies default PBR settings:

```csharp
// Core/Operator/EvaluationContext.cs:43-58
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

The `EvaluationContext` is the central data bus for a frame. It carries three transform matrices — `ObjectToWorld`, `WorldToCamera`, and `CameraToClipSpace` — plus the point light stack, fog parameters, PBR material, requested resolution, and a dictionary of named textures for IBL. Any operator can read from or write to these fields, but convention demands it saves and restores any field it modifies.

---

## Step 4: RenderTarget Saves DX11 State and Creates Framebuffer

**File:** `Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs:40-165`

When evaluation reaches `RenderTarget`, its `Update` method fires. The first action is to snapshot the current DX11 pipeline state so it can be restored afterward. This save-and-restore pattern repeats at nearly every level of the operator hierarchy.

```csharp
// RenderTarget.cs:80-91
var prevRequestedResolution = context.RequestedResolution;
var prevViewports = deviceContext.Rasterizer.GetViewports<RawViewportF>();
const int RtCount = 3;
var prevTargets = deviceContext.OutputMerger.GetRenderTargets(RtCount, out var prevDsv);

var prevObjectToWorld = context.ObjectToWorld;
var prevWorldToCamera = context.WorldToCamera;
var prevCameraToClipSpace = context.CameraToClipSpace;
var keepCameraBypass = context.BypassCameras;
```

Next, `UpdateTextures` creates or re-uses DX11 textures for the color, depth, and optional normal buffers. If the format or resolution changed since last frame, the old resources are disposed and new ones allocated:

```csharp
// RenderTarget.cs:310-336
var texture2DDescription = new Texture2DDescription
{
    ArraySize = 1,
    BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
    CpuAccessFlags = CpuAccessFlags.None,
    Format = colorFormat,
    Width = size.Width,
    Height = size.Height,
    MipLevels = mipLevels,
    SampleDescription = new SampleDescription(_sampleCount, 0),
    Usage = ResourceUsage.Default,
};
_multiSampledColorBuffer = Texture2D.CreateTexture2D(texture2DDescription);
_multiSampledColorBufferRtv = new RenderTargetView(device, _multiSampledColorBuffer, ...);
```

With textures ready, the render targets are bound and cleared:

```csharp
// RenderTarget.cs:99-126
deviceContext.Rasterizer.SetViewport(new SharpDX.Viewport(0, 0, size.Width, size.Height, 0.0f, 1.0f));
deviceContext.OutputMerger.SetTargets(_multiSampledDepthBufferDsv, _multiSampledColorBufferRtv);

if (clear || !_wasClearedOnce)
{
    deviceContext.ClearRenderTargetView(_multiSampledColorBufferRtv,
        new SharpDX.Color(clearColor.X, clearColor.Y, clearColor.Z, clearColor.W));
    deviceContext.ClearDepthStencilView(_multiSampledDepthBufferDsv,
        DepthStencilClearFlags.Depth, 1.0f, 0);
}
```

The DX11 calls here are `OMSetRenderTargets`, `RSSetViewports`, `ClearRenderTargetView`, and `ClearDepthStencilView`. After clearing, `RenderTarget` sets a default camera on the context and then calls `Command.GetValue(context)`, passing execution downstream to the `Camera` operator.

---

## Step 5: Camera Writes Matrices to EvaluationContext

**File:** `Operators/Lib/Symbols/render/camera/Camera.cs:22-80`

The `Camera` operator's `UpdateOutputWithSubtree` method fires next. Its job is to compute view and projection matrices and write them into the `EvaluationContext` before evaluating its child subgraph.

```csharp
// Camera.cs:22-46
private void UpdateOutputWithSubtree(EvaluationContext context)
{
    if (!Reference.HasInputConnections || Reference.DirtyFlag.IsDirty)
        UpdateCameraDefinition(context);

    Reference.DirtyFlag.Clear();

    if (context.BypassCameras)
    {
        Command.GetValue(context);  // skip camera, pass through unchanged
        return;
    }

    // Push matrices onto context
    var prevWorldToCamera = context.WorldToCamera;
    var prevCameraToClipSpace = context.CameraToClipSpace;

    context.WorldToCamera = WorldToCamera;
    context.CameraToClipSpace = CameraToClipSpace;

    Command.GetValue(context);  // evaluate children with camera active

    // Restore
    context.CameraToClipSpace = prevCameraToClipSpace;
    context.WorldToCamera = prevWorldToCamera;
}
```

The matrix computation itself happens in `UpdateCameraDefinition`:

```csharp
// Camera.cs:48-80
_cameraDefinition = new CameraDefinition
{
    Position = Position.GetValue(context),
    Target = Target.GetValue(context),
    FieldOfView = FieldOfView.GetValue(context).ToRadians(),
    AspectRatio = (float)context.RequestedResolution.Width / context.RequestedResolution.Height,
    NearFarClip = ClipPlanes.GetValue(context),
    ...
};

_cameraDefinition.BuildProjectionMatrices(out var camToClipSpace, out var worldToCamera);
CameraToClipSpace = camToClipSpace;
WorldToCamera = worldToCamera;
```

`BuildProjectionMatrices` constructs a right-handed perspective projection (`PerspectiveFovRH`) and a right-handed look-at view matrix (`LookAtRH`). These are stored on the `Camera` instance, then copied to the context before children evaluate. The old values are restored afterward, preserving the scoping semantics that allow nested camera operators to work correctly.

---

## Step 6: DrawMesh Compound Selects Material, Triggers Inner Graph

**File:** `Operators/Lib/Symbols/mesh/draw/DrawMesh.cs:18-44`

`DrawMesh` is a compound operator — it has a C# wrapper class plus a `.t3` JSON file describing its inner graph. The C# `Update` method runs first to resolve material selection, then delegates to the inner graph via `ConnectedUpdate`:

```csharp
// DrawMesh.cs:18-44
private void Update(EvaluationContext context)
{
    if (context.Materials != null)
    {
        _pbrMaterials.Clear();
        _pbrMaterials.AddRange(context.Materials);
    }

    var previousMaterial = context.PbrMaterial;

    var materialId = UseMaterialId.GetValue(context);
    if (!string.IsNullOrEmpty(materialId))
    {
        foreach (var m in context.Materials)
        {
            if (m.Name != materialId) continue;
            context.PbrMaterial = m;
            break;
        }
    }

    Output.ConnectedUpdate(context);  // evaluate inner graph
    context.PbrMaterial = previousMaterial;  // restore
}
```

The inner graph (described in `DrawMesh.t3`) instantiates and connects the following operators in sequence:

- `_MeshBufferComponents` — extracts `VertexBuffer` and `IndicesBuffer` SRVs from the `MeshBuffers` input
- `TransformsConstBuffer` — packs current frame's transform matrices into a DX11 constant buffer
- `ContextCBuffers` — packages `context.FogParameters` and `context.PointLights.ConstBuffer`
- `GetPbrParameters` — reads `context.PbrMaterial` and exposes its texture SRVs and parameter buffer
- `SetPixelAndVertexShaderStage` — binds VS/PS and sets all constant buffers and SRVs
- `RasterizerState`, `DepthStencilState`, `OutputMergerStage` — configure pipeline state
- `InputAssemblerStage` — sets primitive topology (TriangleList)
- `Execute` — orchestrates `PrepareAction`, `GetValue`, `RestoreAction` for each command
- `Draw` — issues `deviceContext.Draw(vertexCount, 0)` directly

---

## Step 7: Constant Buffer Assembly

**File:** `Operators/Lib/render/_dx11/api/TransformsConstBuffer.cs:48-69` and `Core/Rendering/TransformBufferLayout.cs`

`TransformsConstBuffer` packs 10 matrices into a 640-byte constant buffer bound to register `b0`:

```csharp
// TransformsConstBuffer.cs:48-69
private void Update(EvaluationContext context)
{
    EnsureAllocated();

    Buffer current = _toggle ? _cbA : _cbB;
    Buffer previous = _toggle ? _cbB : _cbA;

    var data = new TransformBufferLayout(context.CameraToClipSpace,
                                         context.WorldToCamera,
                                         context.ObjectToWorld);
    ResourceManager.UpdateConstBuffer(data, current);

    Buffer.Value = current;
    PrevBuffer.Value = previous;
    _toggle = !_toggle;  // ping-pong between two buffers for TAA support
}
```

`TransformBufferLayout` derives all 10 matrix variants from the three source matrices — including inverses and concatenated forms — and transposes them all for HLSL's column-major memory layout:

```csharp
// Core/Rendering/TransformBufferLayout.cs:8-31
public TransformBufferLayout(Matrix4x4 cameraToClipSpace, Matrix4x4 worldToCamera, Matrix4x4 objectToWorld)
{
    Matrix4x4.Invert(cameraToClipSpace, out var clipSpaceToCamera);
    Matrix4x4.Invert(worldToCamera, out var cameraToWorld);
    Matrix4x4.Invert(objectToWorld, out var worldToObject);

    WorldToClipSpace = Matrix4x4.Multiply(worldToCamera, cameraToClipSpace);
    ObjectToCamera = Matrix4x4.Multiply(objectToWorld, worldToCamera);
    ObjectToClipSpace = Matrix4x4.Multiply(ObjectToCamera, cameraToClipSpace);
    // ... all 10 are then transposed for HLSL
}
```

`ContextCBuffers` similarly extracts fog and light data from the context:

```csharp
// Operators/Lib/Symbols/render/shading/_/ContextCBuffers.cs:19-22
private void Update(EvaluationContext context)
{
    FogParameters.Value = context.FogParameters;
    PointLights.Value = context.PointLights.ConstBuffer;
}
```

The `PointLightStack` lazily serializes up to 8 `PointLight` structs into a constant buffer bound to register `b3`. If no lights have been pushed onto the context this frame, it returns a default two-light setup: a warm key light and a cool fill light.

---

## Step 8: Shader and Pipeline State Binding

**File:** `Operators/Lib/Symbols/render/_dx11/fxsetup/SetPixelAndVertexShaderStage.cs:15-58`

`SetPixelAndVertexShaderStage` saves the current VS/PS state, then applies the new shaders and all associated resources:

```csharp
// SetPixelAndVertexShaderStage.cs:15-57
private void Update(EvaluationContext context)
{
    // Snapshot current state
    _prevConstantBuffers = vsStage.GetConstantBuffers(0, _constantBuffers.Length);
    _prevShaderResourceViews = vsStage.GetShaderResources(0, _shaderResourceViews.Length);
    _prevVertexShader = vsStage.Get();
    _prevPixelShader = psStage.Get();

    var vs = VertexShader.GetValue(context);
    var ps = PixelShader.GetValue(context);

    if (vs != null)
    {
        vsStage.Set(vs);
        vsStage.SetSamplers(0, _samplerStates.Length, _samplerStates);
        vsStage.SetConstantBuffers(0, _constantBuffers.Length, _constantBuffers);
        vsStage.SetShaderResources(0, _shaderResourceViews.Length, _shaderResourceViews);
    }

    if (ps != null)
    {
        psStage.Set(ps);
        psStage.SetSamplers(0, _samplerStates.Length, _samplerStates);
        psStage.SetConstantBuffers(0, _constantBuffers.Length, _constantBuffers);
        psStage.SetShaderResources(0, _shaderResourceViews.Length, _shaderResourceViews);
    }
}
```

The constant buffer register layout after this call matches the HLSL declarations in `mesh-Draw.hlsl`:

| Register | Source | Content |
|---|---|---|
| `b0` | `TransformsConstBuffer` | 10 matrices, 640 bytes |
| `b1` | `FloatsToBuffer` | Color, AlphaCutOff, UseFlatShading |
| `b2` | `ContextCBuffers.FogParameters` | FogColor, FogDistance, FogBias |
| `b3` | `ContextCBuffers.PointLights` | 8 × PointLight structs + count |
| `b4` | `GetPbrParameters.PbrParameterBuffer` | BaseColor, EmissiveColor, Roughness, Specular, Metal |

The shader resource view register layout:

| Register | Source | Content |
|---|---|---|
| `t0` | `_MeshBufferComponents.Vertices` | `StructuredBuffer<PbrVertex>` |
| `t1` | `_MeshBufferComponents.Indices` | `StructuredBuffer<int3>` (face indices) |
| `t2` | `GetPbrParameters.AlbedoColorMap` | Base color texture |
| `t3` | `GetPbrParameters.EmissiveColorMap` | Emissive texture |
| `t4` | `GetPbrParameters.RoughnessMetallicOcclusionMap` | RSMO packed texture |
| `t5` | `GetPbrParameters.NormalMap` | Tangent-space normal map |
| `t6` | `GetPbrParameters.PrefilteredSpecularMap` | IBL cubemap |
| `t7` | `GetPbrParameters.BrdfLookupMap` | Pre-integrated BRDF LUT |

`GetPbrParameters` reads texture SRVs from the live `context.PbrMaterial` object and routes the IBL cubemap through `context.ContextTextures`, which is populated upstream by a `SetEnvironmentMap` or similar operator:

```csharp
// GetPbrParameters.cs:41-52
private void UpdateAlbedoColorMap(EvaluationContext context)
    => AlbedoColorMap.Value = context.PbrMaterial.AlbedoMapSrv;

private void UpdatePrefilteredSpecularMap(EvaluationContext context)
{
    context.ContextTextures.TryGetValue(PbrContextSettings.PrefilteredSpecularId, out var texture);
    PrefilteredSpecularMap.Value = texture;
}
```

---

## Step 9: Execute Operator Orchestrates Command Lifecycle

**File:** `Operators/Lib/Symbols/flow/Execute.cs:14-38` and `Core/DataTypes/Command.cs`

The `Execute` operator ties together the three-phase command execution pattern. A `Command` is a minimal object holding two delegates:

```csharp
// Core/DataTypes/Command.cs
public class Command
{
    public Action<EvaluationContext> PrepareAction { get; init; }
    public Action<EvaluationContext> RestoreAction { get; set; }
}
```

`Execute` runs all commands in three passes:

```csharp
// Execute.cs:17-37
private void Update(EvaluationContext context)
{
    var commands = Command.CollectedInputs;
    if (IsEnabled.GetValue(context))
    {
        // Phase 1: Setup
        for (int i = 0; i < commands.Count; i++)
            commands[i].Value?.PrepareAction?.Invoke(context);

        // Phase 2: Execution (triggers UpdateAction on each slot)
        for (int i = 0; i < commands.Count; i++)
            commands[i].GetValue(context);

        // Phase 3: Cleanup
        for (int i = 0; i < commands.Count; i++)
            commands[i].Value?.RestoreAction?.Invoke(context);
    }
}
```

This three-pass structure lets operators like `SetPixelAndVertexShaderStage` snapshot DX11 state in `PrepareAction` (conceptually), execute the draw in `GetValue`, and restore the snapshot in `RestoreAction`. In practice, the save happens inside `Update` itself and the restore is wired to the `RestoreAction` delegate — as seen in `SetPixelAndVertexShaderStage.Restore()`.

---

## Step 10: Vertex Shader — Vertex Fetch and TBN Computation

**File:** `Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl:85-122`

With shaders bound and resources set, `Draw` issues `deviceContext.Draw(vertexCount, 0)`. There is no vertex buffer bound to the input assembler in the traditional sense. Instead, tixl uses a **structured buffer vertex fetch** pattern: the input assembler runs in topology-only mode (TriangleList with no input layout), and the vertex shader fetches geometry data by indexing into `StructuredBuffer<PbrVertex>` using the system-provided `SV_VertexID`.

```hlsl
// mesh-Draw.hlsl:85-122
psInput vsMain(uint id : SV_VertexID)
{
    psInput output;

    int faceIndex = id / 3;
    int faceVertexIndex = id % 3;

    PbrVertex vertex = PbrVertices[FaceIndices[faceIndex][faceVertexIndex]];

    float4 posInObject = float4(vertex.Position, 1);
    float4 posInClipSpace = mul(posInObject, ObjectToClipSpace);
    output.pixelPosition = posInClipSpace;

    float2 uv = vertex.TexCoord;
    output.texCoord = float2(uv.x, 1 - uv.y);  // flip V for DX convention

    // Compute TBN in world space
    float3x3 TBN = float3x3(vertex.Tangent, vertex.Bitangent, vertex.Normal);
    TBN = mul(TBN, (float3x3)ObjectToWorld);

    output.tbnToWorld = float3x3(
        normalize(TBN._m00_m01_m02),
        normalize(TBN._m10_m11_m12),
        normalize(TBN._m20_m21_m22));

    output.worldPosition = mul(posInObject, ObjectToWorld).xyz;

    // Fog attenuation in camera space
    if (FogDistance > 0)
    {
        float4 posInCamera = mul(posInObject, ObjectToCamera);
        float fog = pow(saturate(-posInCamera.z / FogDistance), FogBias);
        output.fog = fog;
    }

    return output;
}
```

The `PbrVertex` struct (defined in `Operators/Lib/Assets/shaders/shared/pbr.hlsl`) holds 12 floats: `Position` (float3), `Normal` (float3), `Tangent` (float3), `Bitangent` (float3), `TexCoord` (float2), `TexCoord2` (float2), `Selected` (float), and three padding floats. This is a 64-byte vertex.

The TBN matrix is computed per-vertex and passed to the pixel shader as a `float3x3` interpolant (`TBASIS` semantic). Each basis vector is normalized after transformation to world space to account for non-uniform scale in `ObjectToWorld`.

Fog uses camera-space depth (`-posInCamera.z`) to compute an attenuation factor, which is passed as the `fog : VPOS` varying.

---

## Step 11: Pixel Shader — ComputePbr, 8-Light Loop, and IBL

**File:** `Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl:189-224` and `Operators/Lib/Assets/shaders/shared/pbr-render.hlsl:4-89`

The pixel shader reads material maps, computes the world-space normal, and delegates all lighting to `ComputePbr()`:

```hlsl
// mesh-Draw.hlsl:189-224
psOutput psMain(psInput pin) : SV_TARGET
{
    psOutput output;

    float4 roughnessMetallicOcclusion = RSMOMap.Sample(WrappedSampler, pin.texCoord);

    frag.Roughness = saturate(roughnessMetallicOcclusion.x + Roughness);
    frag.Metalness = saturate(roughnessMetallicOcclusion.y + Metal);
    frag.Occlusion = roughnessMetallicOcclusion.z;
    frag.albedo = BaseColorMap.Sample(WrappedSampler, pin.texCoord);
    frag.uv = pin.texCoord;
    frag.N = ComputeNormal(pin, pin.tbnToWorld);
    frag.fog = pin.fog;
    frag.worldPosition = pin.worldPosition;

    float4 eyePosition = mul(float4(0, 0, 0, 1), CameraToWorld);
    frag.Lo = normalize(eyePosition.xyz - frag.worldPosition);

    float4 litColor = ComputePbr();

    litColor.rgba *= GetField(float4(pin.worldPosition.xyz, 0)).rgba;

    if (AlphaCutOff > 0 && litColor.a < AlphaCutOff)
        discard;

    output.Color = litColor;
    output.Normal = float4(frag.N, 1.0);  // MRT: world normal to SV_Target1
    return output;
}
```

The fragment uses a module-static `FragmentMaterial frag` struct (defined in `pbr.hlsl`) as a scratch pad for passing values to `ComputePbr()`. This avoids a long parameter list at the cost of making `ComputePbr` depend on a global — a deliberate design trade-off in this codebase.

Inside `ComputePbr()` (in `pbr-render.hlsl`), the lighting model follows the Epic Games Unreal Engine 4 approach from their 2013 SIGGRAPH course notes:

```hlsl
// Operators/Lib/Assets/shaders/shared/pbr-render.hlsl:4-88
float4 ComputePbr()
{
    float3 N = frag.N;
    float3 V = frag.Lo;

    frag.cosLo = abs(dot(N, V));
    float3 Lr = 2.0 * frag.cosLo * N - V;  // specular reflection direction

    float3 F0 = lerp(Fdielectric, frag.albedo.rgb, frag.Metalness);  // Fresnel at normal incidence

    // --- Direct lighting loop (up to 8 point lights) ---
    float3 directLighting = 0.0;
    for (uint i = 0; i < (uint)ActiveLightCount; ++i)
    {
        float3 Lvec = Lights[i].position - frag.worldPosition;
        float dist = length(Lvec);
        float3 L = Lvec / max(dist, 1e-4);

        float intensity = Lights[i].intensity /
            (pow(dist / Lights[i].range, Lights[i].decay) + 1);
        float3 Lradiance = Lights[i].color.rgb * intensity;

        float3 H = normalize(L + V);
        float NdotL = saturate(dot(N, L));
        float NdotH = saturate(dot(N, H));
        float NdotV = saturate(dot(N, V));

        float3 F = fresnelSchlick(F0, saturate(dot(H, V)));
        float D = ndfGGX(NdotH, frag.Roughness);   // GGX normal distribution
        float G = gaSchlickGGX(NdotL, NdotV, frag.Roughness);  // Smith geometry term

        float3 kd = lerp(1.0 - F, 0.0, frag.Metalness);
        float3 diffuseBRDF = kd * frag.albedo.rgb;
        float3 specularBRDF = ((F * D * G) / max(Epsilon, 4.0 * NdotL * NdotV)) * Specular;

        directLighting += (diffuseBRDF + specularBRDF) * Lradiance * NdotL;
    }

    // --- IBL ambient lighting ---
    float3 ambientLighting = 0;
    {
        // Diffuse IBL: sample low-resolution mip of prefilteredspecular cubemap
        uint width, height, levels;
        PrefilteredSpecular.GetDimensions(0, width, height, levels);
        float3 irradiance = PrefilteredSpecular.SampleLevel(WrappedSampler, N, 0.6 * levels).rgb;

        float3 F = fresnelSchlick(F0, frag.cosLo);
        float3 kd = lerp(1.0 - F, 0.0, frag.Metalness);
        float3 diffuseIBL = kd * frag.albedo.rgb * irradiance;

        // Specular IBL: sample pre-filtered mip based on roughness
        float3 specularIrradiance =
            PrefilteredSpecular.SampleLevel(WrappedSampler, Lr, frag.Roughness * levels).rgb;

        // Split-sum BRDF LUT
        float2 specularBRDF =
            BRDFLookup.SampleLevel(ClampedSampler, float2(frag.cosLo, frag.Roughness), 0).rg;

        float3 specularIBL = (F0 * specularBRDF.x + specularBRDF.y) * specularIrradiance;
        ambientLighting = (diffuseIBL + specularIBL) * frag.Occlusion;
    }

    // Combine, tint, add emissive, apply fog
    float4 litColor = float4(directLighting + ambientLighting, 1.0) * BaseColor * Color;
    litColor += float4(EmissiveColorMap.Sample(WrappedSampler, frag.uv).rgb * EmissiveColor.rgb, 0);
    litColor.rgb = lerp(litColor.rgb, FogColor.rgb, frag.fog * FogColor.a);
    litColor.a *= frag.albedo.a;

    return litColor;
}
```

Three things are worth noting here. First, the diffuse IBL samples the prefilteredspecular cubemap at a high mip level (0.6 * total levels) rather than a separate irradiance map — a simplification that avoids needing two separate IBL textures. Second, the specular IBL uses the split-sum approximation: the pre-filtered environment color is multiplied by a BRDF scale-and-bias factor from a pre-integrated lookup texture, indexed by `(cosLo, roughness)`. Third, fog is applied as a linear blend in linear color space before output, with the fog alpha controlling blend weight.

The pixel shader writes to two render targets simultaneously: `SV_Target0` for the lit color and `SV_Target1` for the world-space normal. This dual-target output is only active when `RenderTarget` was configured with `WithNormalBuffer = true`.

---

## Step 12: RenderTarget Restores DX11 State and Resolves MSAA

**File:** `Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs:153-220`

After `Command.GetValue(context)` returns, `RenderTarget` restores all the pipeline state it saved before rendering:

```csharp
// RenderTarget.cs:153-162
context.BypassCameras = keepCameraBypass;
context.ObjectToWorld = prevObjectToWorld;
context.WorldToCamera = prevWorldToCamera;
context.CameraToClipSpace = prevCameraToClipSpace;
context.RequestedResolution = prevRequestedResolution;
context.BackgroundColor = keepBackgroundColor;
context.ForegroundColor = keepForegroundColor;
deviceContext.Rasterizer.SetViewports(prevViewports);
deviceContext.OutputMerger.SetTargets(prevDsv, prevTargets);
```

If multisampling was enabled (`_sampleCount > 1`), the multisampled color buffer is resolved to the single-sample buffer using `ResolveSubresource`. For depth, a compute shader handles the custom resolve since DXGI does not support depth resolve directly:

```csharp
// RenderTarget.cs:166-193
if (_sampleCount > 1)
{
    device.ImmediateContext.ResolveSubresource(_multiSampledColorBuffer, 0,
                                                _resolvedColorBuffer, 0,
                                                _resolvedColorBuffer.Description.Format);
    if (withDepthBuffer)
        ResolveDepthBuffer();  // dispatches a compute shader
}
```

The `ResolveDepthBuffer` method (lines 251-284) dispatches `resolve-multisampled-depth-buffer-cs.hlsl` in 16x16 thread groups to perform a min-depth reduction across samples. Finally, `RenderTarget` outputs the resolved texture:

```csharp
// RenderTarget.cs:216-221
ColorBuffer.Value = ColorTexture;  // _resolvedColorBuffer or _multiSampledColorBuffer
ColorBuffer.DirtyFlag.Clear();
DepthBuffer.Value = DepthTexture;
DepthBuffer.DirtyFlag.Clear();
```

---

## Step 13: Final Composite to Back Buffer and Swap Chain Present

**File:** `Player/Program.RenderLoop.cs:57-81`

Back in `RenderCallback`, the evaluated `Texture2D` is now available. The player composites it to the back buffer using a full-screen triangle pass — a classic screenspace technique where a single `Draw(3, 0)` call with no vertex buffer generates a triangle that covers the entire viewport:

```csharp
// Player/Program.RenderLoop.cs:57-78
var outputTexture = _textureOutput.GetValue(_evalContext);

_deviceContext.Rasterizer.State = _rasterizerState;
_deviceContext.VertexShader.Set(_fullScreenVertexShaderResource.Value);
_deviceContext.PixelShader.Set(_fullScreenPixelShaderResource.Value);

if (_outputTextureSrv == null || textureChanged)
    _outputTextureSrv = new ShaderResourceView(_device, _outputTexture);

_deviceContext.PixelShader.SetShaderResource(0, _outputTextureSrv);
_deviceContext.InputAssembler.PrimitiveTopology = PrimitiveTopology.TriangleList;
_deviceContext.ClearRenderTargetView(_renderView, new Color(0.45f, 0.55f, 0.6f, 1.0f));
_deviceContext.Draw(3, 0);
_deviceContext.PixelShader.SetShaderResource(0, null);
```

The full-screen vertex shader computes UV coordinates from `SV_VertexID` without needing vertex data. The pixel shader samples the operator-graph texture and outputs to the back buffer. After this, the swap chain presents:

```csharp
// Player/Program.RenderLoop.cs:81
_swapChain.Present(_vsyncInterval, PresentFlags.None);
```

`_vsyncInterval` is 1 for vsync-on and 0 for vsync-off, controlled by the `--no-vsync` command-line flag.

---

## Data Flow Summary

The following table shows how data moves between each step:

| Step | Operator / System | DX11 Calls | Context Mutation |
|---|---|---|---|
| 1 | Player main loop | `OMSetRenderTargets`, `RSSetViewports` | Resets `EvaluationContext` |
| 2 | `DirtyFlag.Invalidate()` | None | Increments dirty targets |
| 3 | `EvaluationContext.Reset()` | None | Clears lights, vars, PBR defaults |
| 4 | `RenderTarget.Update` | `CreateTexture2D`, `OMSetRenderTargets`, `ClearRenderTargetView`, `ClearDepthStencilView` | Saves/sets `RequestedResolution`, sets default camera |
| 5 | `Camera.UpdateOutputWithSubtree` | None | Writes `WorldToCamera`, `CameraToClipSpace` |
| 6 | `DrawMesh.Update` | None | Reads/sets `PbrMaterial` |
| 7 | `TransformsConstBuffer`, `ContextCBuffers` | `UpdateSubresource` (for CBs) | None |
| 8 | `SetPixelAndVertexShaderStage.Update` | `VSSetShader`, `PSSetShader`, `VSSetConstantBuffers`, `PSSetConstantBuffers`, `VSSetShaderResources`, `PSSetShaderResources` | None |
| 9 | `Execute.Update` | None (orchestration only) | None |
| 10 | `Draw.Update` | `Draw(vertexCount, 0)` | None |
| 10–11 | GPU: VS runs | — | — |
| 10–11 | GPU: PS runs | — | — |
| 12 | `RenderTarget` post-draw | `ResolveSubresource`, `Dispatch` (depth resolve) | Restores all saved context fields |
| 13 | Player back-buffer composite | `VSSetShader`, `PSSetShader`, `PSSetShaderResources`, `Draw(3, 0)` | None |
| 13 | `SwapChain.Present` | `Present` | None |

---

## Architectural Observations

Several patterns emerge from tracing this path that are worth recording for the Rust framework study.

The **save-restore sandwich** appears at every level. `RenderTarget` saves DX11 state before rendering and restores it after. `Camera` saves context matrices. `DrawMesh` saves `PbrMaterial`. `SetPixelAndVertexShaderStage` saves shaders. This layered approach ensures that operators are composable: any operator can be nested inside any other without polluting the outer rendering context. The cost is per-frame CPU work for state snapshots, which is measurable but acceptable for interactive frame rates.

The **Command as deferred side effect** is an elegant solution to a hard problem. Tixl needs operators to participate in the render loop (so they can set up and tear down GPU state) without requiring the operator graph to have explicit "begin frame" and "end frame" callbacks. The `Command` type with `PrepareAction` and `RestoreAction` delegates achieves this cleanly.

The **no-IA structured buffer fetch** is unusual. By using `SV_VertexID` indexing into `StructuredBuffer<PbrVertex>`, tixl avoids specifying an input layout (`ID3D11InputLayout`) entirely. The vertex format is defined in HLSL, not in C#. This makes it easy to change the vertex format without touching C# code — but it requires the GPU to issue gather reads rather than sequential vertex reads, which may be slightly less cache-efficient for large meshes.

The **EvaluationContext as ambient state** means that any operator anywhere in the graph can read camera matrices, active material, or the point light stack without any explicit wiring. This enables powerful implicit behaviors (a light placed anywhere in the graph just works) but can make data flow opaque when reading the graph structure alone.

---

## References

- `Player/Program.cs` — device and swap chain creation
- `Player/Program.RenderLoop.cs` — `RenderCallback`, composite pass, `Present`
- `Core/Operator/Slots/DirtyFlag.cs` — dirty flag generation counter
- `Core/Operator/Slots/Slot.cs` — `GetValue`, `Update`, `Invalidate`
- `Core/Operator/EvaluationContext.cs` — per-frame ambient state carrier
- `Core/Rendering/TransformBufferLayout.cs` — 10-matrix constant buffer struct
- `Core/Rendering/PointLightStack.cs` — light stack with lazy serialization
- `Core/DataTypes/Command.cs` — PrepareAction/RestoreAction pattern
- `Operators/Lib/Symbols/image/generate/basic/RenderTarget.cs` — framebuffer management
- `Operators/Lib/Symbols/render/camera/Camera.cs` — matrix computation and context injection
- `Operators/Lib/Symbols/mesh/draw/DrawMesh.cs` — compound operator with material selection
- `Operators/Lib/Symbols/mesh/draw/DrawMesh.t3` — inner graph JSON: shader setup, state, draw call
- `Operators/Lib/render/_dx11/api/TransformsConstBuffer.cs` — ping-pong transform CBs
- `Operators/Lib/Symbols/render/shading/_/ContextCBuffers.cs` — fog and light CBs from context
- `Operators/Lib/Symbols/render/shading/_/GetPbrParameters.cs` — material SRVs from context
- `Operators/Lib/Symbols/render/_dx11/fxsetup/SetPixelAndVertexShaderStage.cs` — shader + resource binding
- `Operators/Lib/Symbols/flow/Execute.cs` — three-pass command orchestration
- `Operators/Lib/Symbols/render/_dx11/api/Draw.cs` — raw `Draw()` call
- `Operators/Lib/Assets/shaders/3d/mesh/mesh-Draw.hlsl` — VS (vertex fetch, TBN) and PS (PBR dispatch)
- `Operators/Lib/Assets/shaders/shared/pbr.hlsl` — PbrVertex struct, BRDF math functions, FragmentMaterial
- `Operators/Lib/Assets/shaders/shared/pbr-render.hlsl` — `ComputePbr()`: direct lights loop + IBL split-sum
- `Operators/Lib/Assets/shaders/shared/point-light.hlsl` — PointLight HLSL struct declaration
