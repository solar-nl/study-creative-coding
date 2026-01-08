# ShaderGraph System Architecture Overview

## High-Level Concept

The ShaderGraph system is a **node-based shader code generation framework** for building complex HLSL shaders by composing reusable operators. Instead of writing shaders manually, you connect operators visually (like a node graph) and the system generates optimized HLSL code automatically.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           USER-FACING GRAPH                                 │
│  ┌──────────┐    ┌──────────────┐    ┌────────────┐    ┌────────────────┐  │
│  │SphereSDF │───▶│TransformField│───▶│ CombineSDF │───▶│ RaymarchField  │  │
│  └──────────┘    └──────────────┘    └────────────┘    └────────────────┘  │
│                                            ▲                                │
│  ┌──────────┐    ┌──────────────┐          │                                │
│  │ BoxSDF   │───▶│ RepeatField  │──────────┘                                │
│  └──────────┘    └──────────────┘                                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        GENERATED HLSL SHADER                                │
│  cbuffer GraphParams { float SphereSDF_abc_Radius; float3 BoxSDF_def_Size;} │
│  float4 getField(float4 p) {                                                │
│      float4 f = float4(0,0,0,1e10);                                         │
│      p.xyz = mul(float4(p.xyz,1), Transform).xyz;                           │
│      f.w = length(p.xyz - Center) - Radius;                                 │
│      ...                                                                    │
│  }                                                                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. ShaderGraphNode (Core/DataTypes/ShaderGraphNode.cs)

The **backbone** of the system. Each operator that participates in shader generation owns a `ShaderGraphNode`.

**Key responsibilities:**
- **Graph structure tracking** - Maintains `InputNodes` list of connected upstream nodes
- **Change detection** - Uses `StructureHash` and `ChangedFlags` to detect what needs updating
- **Recursive update** - `Update()` propagates through the graph tree
- **Code collection** - `CollectEmbeddedShaderCode()` recursively gathers HLSL fragments
- **Parameter collection** - `CollectAllNodeParams()` gathers all float values for constant buffers

> **Note:** ShaderGraphNode replicates the instance graph structure to allow processing without updating all instances - enabling output caching. The prefix system (e.g., `SphereSDF_abc123_`) ensures unique variable names when the same operator type appears multiple times in a graph.

### 2. IGraphNodeOp (Core/DataTypes/ShaderGraph/IGraphNodeOp.cs)

The **interface** that operators implement to contribute shader code:

| Method | Purpose |
|--------|---------|
| `ShaderNode` | Access to the node's ShaderGraphNode |
| `AddDefinitions()` | Register globals and constant definitions |
| `GetPreShaderCode()` | Code to execute **before** processing child nodes |
| `GetPostShaderCode()` | Code to execute **after** processing child nodes |
| `TryBuildCustomCode()` | Override for nodes needing complete control |
| `AppendShaderResources()` | Provide SRV/buffer resources |

### 3. CodeAssembleContext (Core/DataTypes/ShaderGraph/CodeAssembleContext.cs)

A **context object** passed during code collection. Think of it as a "shader code builder":

```csharp
public sealed class CodeAssembleContext
{
    public Dictionary<string, string> Globals;      // Reusable functions
    public StringBuilder Definitions;               // Instance-specific code
    public StringBuilder Calls;                     // Main shader body
    public List<string> ContextIdStack;             // p0, p1a, p1b, etc.
}
```

**Context stacking** is crucial - when nodes have multiple inputs, each gets its own "sub-context" with unique position (`p`) and field (`f`) variables:

```hlsl
// Main context
float4 p = input_position;
float4 f = float4(0,0,0,1e10);

// Sub-context for first input
float4 p1a = p;  float4 f1a = f;
// ... first branch code ...

// Sub-context for second input
float4 p1b = p;  float4 f1b = f;
// ... second branch code ...

// Combine results
f.w = min(f1a.w, f1b.w);
```

### 4. GenerateShaderGraphCode (Operators/Lib/field/render/_/GenerateShaderGraphCode.cs)

The **orchestrator** that triggers the whole process:

```
┌────────────────────────────────────────────────────────────────┐
│                   GenerateShaderGraphCode                       │
│                                                                 │
│  1. Update() ──▶ Recursively update all ShaderGraphNodes       │
│                  Detect changes (Structural/Code/Parameters)    │
│                                                                 │
│  2. AssembleParams() ──▶ CollectAllNodeParams() recursively    │
│                          Build float constant buffer            │
│                                                                 │
│  3. AssembleCode() ──▶ CollectEmbeddedShaderCode() recursively │
│                        Inject into template via hooks:          │
│                        /*{FLOAT_PARAMS}*/ /*{FIELD_CALL}*/     │
│                                                                 │
│  4. Output ──▶ ShaderCode (string), FloatParams (Buffer)       │
└────────────────────────────────────────────────────────────────┘
```

---

## Operator Pattern

Here's how operators participate in the system (using SphereSDF as example):

```csharp
internal sealed class SphereSDF : Instance<SphereSDF>, IGraphNodeOp
{
    // 1. Output the ShaderGraphNode (not a texture or mesh - the node itself!)
    [Output] public readonly Slot<ShaderGraphNode> Result = new();

    // 2. Create and own a ShaderGraphNode
    public ShaderGraphNode ShaderNode { get; }

    public SphereSDF()
    {
        ShaderNode = new ShaderGraphNode(this);  // No inputs - leaf node
        Result.Value = ShaderNode;
        Result.UpdateAction += Update;
    }

    // 3. Contribute HLSL code via Pre/Post methods
    public void GetPreShaderCode(CodeAssembleContext c, int inputIndex)
    {
        // c = context suffix (e.g., "1a"), ShaderNode = unique prefix
        c.AppendCall($"f{c}.w = length(p{c}.xyz - {ShaderNode}Center) - {ShaderNode}Radius;");
    }

    // 4. Mark inputs as shader parameters with [GraphParam]
    [GraphParam] [Input] public readonly InputSlot<float> Radius = new();
    [GraphParam] [Input] public readonly InputSlot<Vector3> Center = new();
}
```

> **Note:** Leaf nodes (like SphereSDF) only implement `GetPreShaderCode`. Transform nodes implement BOTH Pre and Post - Pre transforms the position before children, Post adjusts the result after. The `{ShaderNode}` prefix in HLSL becomes something like `SphereSDF_a1b2c3d4_` - ensuring unique variable names.

---

## Data Flow During Execution

```
Frame N: User connects SphereSDF → TransformField → RaymarchField

┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 1: UPDATE                                                          │
│                                                                          │
│ RaymarchField.Update()                                                   │
│   └─▶ TransformField.ShaderNode.Update()                                │
│         └─▶ SphereSDF.ShaderNode.Update()                               │
│               └─▶ Returns: StructureHash, ChangedFlags                  │
│         └─▶ Combines child changes, checks own params                   │
│   └─▶ Combines all changes, decides what to regenerate                  │
└─────────────────────────────────────────────────────────────────────────┘
                               │
                               ▼ (if Structural or Code changed)
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 2: CODE COLLECTION                                                 │
│                                                                          │
│ ShaderNode.CollectEmbeddedShaderCode(context)                           │
│   │                                                                      │
│   ├─▶ TransformField.GetPreShaderCode()  // Transform position          │
│   │     └─▶ Appends: "p.xyz = mul(float4(p.xyz,1), Transform).xyz;"    │
│   │                                                                      │
│   ├─▶ SphereSDF.GetPreShaderCode()       // Calculate distance          │
│   │     └─▶ Appends: "f.w = length(p.xyz - Center) - Radius;"          │
│   │                                                                      │
│   └─▶ TransformField.GetPostShaderCode() // Scale result                │
│         └─▶ Appends: "f.w *= UniformScale;"                             │
└─────────────────────────────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ PHASE 3: TEMPLATE INJECTION                                              │
│                                                                          │
│ Template: "float4 getField(float4 p) { /*{FIELD_CALL}*/ return f; }"   │
│                                           │                              │
│                                           ▼                              │
│ Result:   "float4 getField(float4 p) {                                  │
│               p.xyz = mul(float4(p.xyz,1), Transform).xyz;              │
│               f.w = length(p.xyz - Center) - Radius;                    │
│               f.w *= UniformScale;                                       │
│               return f;                                                  │
│           }"                                                             │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Change Detection System

The system uses three levels of change detection to minimize recompilation:

| Flag | Trigger | Action |
|------|---------|--------|
| `Structural` | Nodes connected/disconnected | Full recompile |
| `Code` | `FlagCodeChanged()` called | Recompile shader |
| `Parameters` | Input slot values changed | Update constant buffer only |

> **Note:** Parameter changes are the cheapest - only the constant buffer updates. The StructureHash is a rolling hash combining all connected node IDs, so any topology change is instantly detected. This is why real-time parameter animation is smooth - no recompilation!

---

## File Locations Summary

| Component | Location |
|-----------|----------|
| Core types | `Core/DataTypes/ShaderGraph/` |
| ShaderGraphNode | `Core/DataTypes/ShaderGraphNode.cs` |
| SDF primitives | `Operators/Lib/field/generate/sdf/` |
| Spatial transforms | `Operators/Lib/field/space/` |
| Combiners | `Operators/Lib/field/combine/` |
| Renderers | `Operators/Lib/field/render/` |
