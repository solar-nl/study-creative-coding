# tixl - Architecture

## Overview

tixl is built on a **Symbol-Instance-Slot** graph system - a three-layer architecture that separates operator definitions from their runtime instances, connected via typed data flow slots.

```
┌─────────────────────────────────────────────────────────────────┐
│                        Symbol Layer                              │
│  (Definitions: what operators exist, their inputs/outputs)       │
├─────────────────────────────────────────────────────────────────┤
│                       Instance Layer                             │
│  (Runtime: actual operator instances with state)                 │
├─────────────────────────────────────────────────────────────────┤
│                         Slot Layer                               │
│  (Data Flow: typed connections, dirty tracking)                  │
└─────────────────────────────────────────────────────────────────┘
```

## Core Abstractions

### 1. Symbol (Definition Layer)

A `Symbol` represents the **template/definition** of an operator - analogous to a class definition.

```csharp
// Core/Operator/Symbol.cs
public sealed partial class Symbol : IDisposable, IResource
{
    public readonly Guid Id;
    public IReadOnlyDictionary<Guid, Child> Children => _children;
    public readonly List<Connection> Connections = [];
    public readonly List<InputDefinition> InputDefinitions = new();
    public readonly List<OutputDefinition> OutputDefinitions = new();
    public Animator Animator { get; private set; } = new();
    public PlaybackSettings PlaybackSettings { get; set; } = new();
}
```

**Key concepts:**
- **Child**: A reference to another symbol used within this symbol (composition)
- **Connection**: Links between operator outputs and inputs
- **InputDefinition/OutputDefinition**: Metadata about slots

### 2. Instance (Runtime Layer)

An `Instance` is the **runtime realization** of a symbol - analogous to an object instance.

```csharp
// Core/Operator/Instance.cs
public abstract partial class Instance : IGuidPathContainer, IResourceConsumer
{
    public abstract Symbol Symbol { get; }
    public Symbol.Child SymbolChild { get; private set; }
    public readonly List<ISlot> Outputs;
    public readonly List<IInputSlot> Inputs;
    public IReadOnlyList<Guid> InstancePath { get; private set; }
    public InstanceChildren Children { get; private set; }
}
```

**CRTP Pattern** - Operators use the Curiously Recurring Template Pattern:

```csharp
// Generic base with static symbol reference
public class Instance<T> : Instance where T : Instance<T>, new()
{
    private protected static Symbol StaticSymbol = null!;
    public sealed override Type Type => typeof(T);
    public sealed override Symbol Symbol => StaticSymbol;
}
```

This enables:
- Type-safe operator definitions without runtime reflection overhead
- Shared symbol reference across all instances of the same operator type
- Compile-time type checking

### 3. Slot System (Data Flow Layer)

Slots are **typed connections** that carry data between operators.

```csharp
// Input slots
public interface IInputSlot : ISlot { }
public class InputSlot<T> : Slot<T>, IInputSlot
{
    public T GetValue(EvaluationContext context);
    public DirtyFlag DirtyFlag { get; }
}

// Output slots
public class Slot<T> : ISlot
{
    public T Value { get; set; }
    public Action<EvaluationContext> UpdateAction { get; set; }
}

// Special slots
public class MultiInputSlot<T> : IInputSlot  // Multiple connections
public class TransformCallbackSlot<T>        // Transform-aware operations
```

**Dirty Flag System:**
- Tracks when slots need re-evaluation
- Propagates invalidation through the graph
- Enables efficient lazy evaluation

## Module Structure

```
tixl/
├── Core/                    # Core framework (195 files)
│   ├── Operator/           # Symbol, Instance, Slot system
│   │   ├── Symbol.cs       # Operator definitions
│   │   ├── Instance.cs     # Runtime instances
│   │   ├── Slot/           # Input/output slots
│   │   └── Attributes/     # [Input], [Output], [Guid] attributes
│   ├── DataTypes/          # Shader, Mesh, Gradient, Curve, Particles
│   ├── Rendering/          # Materials (PBR), lights, fog
│   ├── Compilation/        # Assembly loading, type extraction
│   ├── Animation/          # Keyframe curves, timing
│   ├── Resource/           # Shader compilation, resource management
│   └── Serialization/      # JSON save/load
│
├── Editor/                  # Main application
│   └── Program.cs          # Entry point
│
├── Operators/              # Operator library (890+ operators)
│   ├── Lib/               # Core operators
│   │   ├── render/        # Cameras, text, sprites, materials
│   │   ├── mesh/          # Mesh generation/modification
│   │   ├── numbers/       # Math and animation
│   │   ├── point/         # Point cloud operations
│   │   ├── particle/      # Particle systems
│   │   ├── flow/          # Control flow
│   │   ├── image/         # Image processing
│   │   └── io/            # NDI, OSC, MIDI, video
│   └── Examples/          # Tutorial operators
│
├── ImguiWindows/           # Dear ImGui UI components
├── SilkWindows/            # Silk.NET windowing layer
├── Player/                 # Standalone player (no editor)
└── Serialization/          # Project file I/O
```

## Evaluation Flow

tixl uses **pull-based lazy evaluation**:

```
1. Output requested → 2. Check dirty flag → 3. If dirty, evaluate inputs → 4. Update output
                              ↓
                      (if clean, return cached value)
```

The `EvaluationContext` carries state through the graph:

```csharp
public sealed class EvaluationContext
{
    // Timing
    public Playback Playback { get; }
    public double LocalTime { get; set; }
    public double LocalFxTime { get; set; }

    // Transform stack
    public Matrix4x4 CameraToClipSpace { get; set; }
    public Matrix4x4 WorldToCamera { get; set; }
    public Matrix4x4 ObjectToWorld { get; set; }

    // Rendering state
    public PbrMaterial PbrMaterial { get; set; }
    public PointLightStack PointLights { get; }
    public ParticleSystem ParticleSystem;

    // Variables (for data passing)
    public Dictionary<string, float> FloatVariables { get; }
    public Dictionary<string, object> ObjectVariables { get; }
}
```

## Key Architectural Decisions

| Decision | Rationale |
|----------|-----------|
| **Symbol-Instance separation** | Multiple instances can share definitions; enables instancing and efficient memory |
| **CRTP generics** | Type safety without reflection overhead at runtime |
| **Dirty flag system** | Efficient incremental updates; only re-evaluate what changed |
| **Pull-based evaluation** | Only compute what's needed for current output |
| **EvaluationContext passing** | Single object carries all state; avoids parameter explosion |
| **Attribute-driven metadata** | Declarative operator definition; reflection at compile/load time only |
| **Package system** | Operators grouped into reloadable packages with dependencies |

## Patterns Applicable to Rust Framework

1. **Separation of definition and instance** - Could use Rust traits for definitions, structs for instances
2. **Typed slot system** - Rust's type system would enforce this even more strictly
3. **Dirty flag propagation** - Interior mutability (`Cell`/`RefCell`) or message passing
4. **Pull-based evaluation** - Natural fit for Rust's ownership (compute on demand)
5. **Context object** - Could be a struct passed by reference, or use a more Rustic approach with closures

## Key Files to Study

| File | Why It's Important |
|------|-------------------|
| `Core/Operator/Symbol.cs` | Core definition abstraction |
| `Core/Operator/Instance.cs` | Runtime instance with CRTP |
| `Core/Operator/Slot/InputSlot.cs` | Input slot with dirty tracking |
| `Core/Operator/Slot/Slot.cs` | Output slot with update action |
| `Core/Operator/EvaluationContext.cs` | State passed through graph |
| `Core/Operator/Attributes/` | Declarative operator metadata |
| `Operators/Lib/render/Camera.cs` | Example complex operator |
