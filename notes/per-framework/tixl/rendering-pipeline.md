# tixl - Rendering Pipeline

## Overview

tixl uses **DirectX 11** via SharpDX for GPU rendering, with a focus on real-time performance for motion graphics and VJ applications.

```
┌──────────────────────────────────────────────────────────────────┐
│                      Operator Graph                               │
│  (Evaluation produces Command objects)                            │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                    Command Execution                              │
│  (Commands set GPU state, issue draw calls)                       │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                     DirectX 11 (SharpDX)                         │
│  (Vertex/Pixel/Geometry/Compute shaders, render targets)          │
└──────────────────────────────────────────────────────────────────┘
                              ↓
┌──────────────────────────────────────────────────────────────────┐
│                        GPU Output                                 │
│  (Window, texture, NDI stream, Spout)                            │
└──────────────────────────────────────────────────────────────────┘
```

## Graphics Backend

### SharpDX Components

| Component | Purpose |
|-----------|---------|
| `SharpDX.Direct3D11` | Core rendering API |
| `SharpDX.D3DCompiler` | Runtime HLSL compilation |
| `SharpDX.Direct2D1` | 2D rendering overlay |
| `SharpDX.MediaFoundation` | Video decode/encode |
| `SharpDX.Mathematics` | Vector/matrix math |

### Shader Types

tixl supports all DirectX 11 shader stages:

```csharp
// Core/DataTypes/Shader.cs
public sealed class ComputeShader : Shader<SharpDX.Direct3D11.ComputeShader>
public sealed class PixelShader : Shader<SharpDX.Direct3D11.PixelShader>
public sealed class VertexShader : Shader<SharpDX.Direct3D11.VertexShader>
public sealed class GeometryShader : Shader<SharpDX.Direct3D11.GeometryShader>
```

**Shader compilation:**
- HLSL source code compiled at runtime via D3DCompiler
- Bytecode caching for performance
- Error reporting with line numbers
- Reflection for compute shader thread group sizes

## Scene Structure

### SceneSetup (Hierarchical Nodes)

3D content is organized in a hierarchical scene graph:

```csharp
// Core/DataTypes/SceneSetup.cs
public class SceneSetup
{
    public SceneNode[] RootNodes;
}

public class SceneNode
{
    public string Name;
    public Vector3 Translation;
    public Quaternion Rotation;
    public Vector3 Scale;
    public Matrix4x4 CombinedTransform;  // Computed world matrix
    public MeshBuffers MeshBuffers;
    public SceneMaterial Material;
    public SceneNode[] ChildNodes;       // Recursive children
}
```

### MeshBuffers (GPU Data)

```csharp
// Core/Rendering/MeshBuffers.cs
public class MeshBuffers
{
    // Vertex data
    public Vector3[] Positions;
    public Vector3[] Normals;
    public Vector2[] UVs;
    public Vector4[] Colors;

    // Index data
    public int[] Indices;

    // GPU buffers
    public Buffer VertexBuffer;
    public Buffer IndexBuffer;
}
```

### Vertex Formats

```csharp
// PBR vertex format
public struct PbrVertex
{
    public Vector3 Position;
    public Vector3 Normal;
    public Vector3 Tangent;
    public Vector3 Bitangent;
    public Vector2 TexCoord;
    public float Selected;  // For vertex selection in editor
}

// Transform buffer for instancing
public struct TransformBufferLayout
{
    public Matrix4x4 WorldMatrix;
    public Matrix4x4 WorldMatrixInverseTranspose;
}
```

## Material System

### PBR Materials

tixl uses a **physically-based rendering** material model:

```csharp
// Core/Rendering/Material/PbrMaterial.cs
public class PbrMaterial
{
    // Base properties
    public Vector4 BaseColor;
    public float Metallic;
    public float Roughness;
    public float EmissiveIntensity;

    // Texture maps
    public Texture2D AlbedoMap;
    public Texture2D NormalMap;
    public Texture2D RoughnessMap;
    public Texture2D MetallicMap;
    public Texture2D EmissiveMap;
    public Texture2D AmbientOcclusionMap;
}
```

### Lighting

```csharp
// Core/Rendering/PointLightStack.cs
public class PointLightStack
{
    public List<PointLight> Lights;

    public struct PointLight
    {
        public Vector3 Position;
        public Vector3 Color;
        public float Intensity;
        public float Range;
    }
}

// Fog settings in EvaluationContext
public FogSettings Fog;
public struct FogSettings
{
    public Vector4 Color;
    public float Density;
    public float Start;
    public float End;
}
```

## Transform Stack

The `EvaluationContext` maintains transform matrices:

```csharp
public sealed class EvaluationContext
{
    // Camera transforms
    public Matrix4x4 CameraToClipSpace;   // Projection matrix
    public Matrix4x4 WorldToCamera;        // View matrix

    // Object transforms
    public Matrix4x4 ObjectToWorld;        // Model matrix

    // Combined (computed)
    public Matrix4x4 ObjectToClipSpace => ObjectToWorld * WorldToCamera * CameraToClipSpace;
}
```

Operators can push/pop transforms by modifying `ObjectToWorld` before evaluating children.

## Command Pattern

Rendering operations are encapsulated as `Command` objects:

```csharp
// Command output slot (common pattern)
[Output(Guid = "...")]
public readonly Slot<Command> Output = new();

// Commands set GPU state and issue draw calls
public class Command
{
    public Action<EvaluationContext> Execute;
}
```

This allows:
- Deferred execution
- Command composition
- Render-to-texture workflows

## Render Targets

tixl supports multiple render target configurations:

```csharp
// Texture types
public Texture2D CreateRenderTarget(int width, int height, Format format);
public Texture2D CreateDepthStencil(int width, int height);

// Common formats
Format.R8G8B8A8_UNorm      // Standard color
Format.R16G16B16A16_Float  // HDR color
Format.R32_Float           // Depth/data
Format.R32G32B32A32_Float  // Full precision
```

## Output Paths

### Window Output
- Silk.NET window with DirectX swap chain
- Dear ImGui overlay for editor UI

### Texture Sharing
- **Spout**: GPU texture sharing (Windows)
- **NDI**: Network video streaming
- Video file export via MediaFoundation

## Performance Considerations

| Technique | Purpose |
|-----------|---------|
| **Dirty flags** | Only re-render when inputs change |
| **Shader caching** | Compiled bytecode stored on disk |
| **GPU instancing** | TransformBufferLayout for many objects |
| **Lazy evaluation** | Pull-based graph only computes visible outputs |
| **Texture atlasing** | Reduce draw call overhead |

## Patterns for Rust Framework

1. **Command abstraction** - Rust could use closures or a trait-based command system
2. **PBR material struct** - Direct translation to Rust struct with wgpu textures
3. **Transform stack** - Could use a stack of matrices or a scene graph
4. **Shader compilation** - wgpu handles this cross-platform; cache SPIR-V
5. **Render-to-texture** - wgpu `TextureView` as render target

## Key Files to Study

| File | Purpose |
|------|---------|
| `Core/DataTypes/SceneSetup.cs` | Scene hierarchy |
| `Core/Rendering/MeshBuffers.cs` | GPU mesh data |
| `Core/Rendering/Material/PbrMaterial.cs` | PBR material system |
| `Core/Resource/ShaderCompiler.cs` | HLSL compilation |
| `Operators/Lib/render/Camera.cs` | Camera implementation |
| `Operators/Lib/render/Draw.cs` | Basic draw commands |
| `Operators/Lib/mesh/` | Mesh generation operators |
