# Node Graph Systems: Cross-Framework Comparison

> How three visual programming frameworks approach the same fundamental challenge

---

## Overview

This document compares node-based procedural content systems across three frameworks:

| Framework | Language | Era | Focus |
|-----------|----------|-----|-------|
| **Werkkzeug4** (fr_public) | C++ | 2004-2011 | Demoscene, size-coded demos, procedural 3D |
| **cables.gl** | JavaScript | 2015-present | Web-based, WebGL/WebGPU, real-time visuals |
| **tixl** | C#/.NET | 2020-present | Desktop, modern GPU, VJ/live performance |

Each framework solves the same core problem: how to let artists create complex procedural content by connecting visual nodes, while managing the complexity of GPU rendering underneath.

---

## Architectural Comparison

### Data Structure Philosophy

| Aspect | Werkkzeug4 | cables.gl | tixl |
|--------|------------|-----------|------|
| **Node representation** | `wOp` (editor) + `wCommand` (runtime) | `Op` with ports | `Symbol` (definition) + `Instance` (runtime) |
| **Connection model** | Links with type checking | Ports with type-restricted links | Slots with dirty flags |
| **Execution model** | Compile then execute | Dual: values (pull) + triggers (push) | Pull-based lazy evaluation |
| **Type system** | Hierarchical with conversions | Port types (value/trigger/object) | Strongly typed slots with generics |

### Two-Tier vs. Single-Tier

**Werkkzeug4** separates editor and execution completely:

```
wOp (editor)          wCommand (runtime)
- Rich metadata       - Minimal, flat
- Pointer graph       - Array of commands
- Live editing        - Snapshot copy
- Undo/redo state     - No metadata
```

**cables.gl** uses a single structure with dual execution modes:

```
Op (single tier)
- Values propagate on change (lazy)
- Triggers fire every frame (eager)
- Same structure serves both modes
```

**tixl** separates definition from instance but not editor from runtime:

```
Symbol (definition)   Instance (runtime)
- Input/output defs   - Actual slot values
- Shared template     - Per-instance state
- Connections         - Dirty flags
```

### Insight: Compilation vs. Live Execution

Werkkzeug4's compilation step was necessary for demoscene's extreme size constraints. Compiling to a flat command buffer enabled aggressive optimizations and tiny executables.

cables.gl and tixl prioritize live iteration. Changes take effect immediately without a compilation step. The tradeoff: less aggressive optimization, but faster creative feedback.

---

## Execution Models

### Werkkzeug4: Compile-Execute

```
Edit graph → Compile → Execute commands → Display
                ↓
         (parameters copied,
          caches checked,
          types verified)
```

Six-phase pipeline:
1. **Parse**: Build intermediate node tree
2. **Optimize**: Insert caches, conversions
3. **TypeCheck**: Verify compatibility
4. **SkipToSlow**: Handle expensive ops
5. **Output**: Generate command buffer
6. **Execute**: Run commands sequentially

Changes during execution are ignored until next compile.

### cables.gl: Dual Execution

```
Every frame:
  MainLoop fires trigger → cascade through trigger ports

On value change:
  Source port updates → propagate to connected inputs
```

Two complementary modes:
- **Triggers** (push): Fire every frame for animation
- **Values** (pull): Propagate on change for efficiency

Cycle prevention via trigger stack tracking.

### tixl: Pull-Based Lazy

```
Output requested → check dirty flag → evaluate if dirty → cache result
                          ↓
                   (clean: return cached)
```

Dirty flags propagate invalidation:
- Input changes → mark dependents dirty
- Evaluation only happens when output is requested
- Natural fit for incremental updates

### Comparison Table

| Aspect | Werkkzeug4 | cables.gl | tixl |
|--------|------------|-----------|------|
| **When does execution happen?** | On explicit request | Every frame (triggers) + on change (values) | On output request |
| **Caching strategy** | Explicit Store/Load ops + context-aware cache | Dirty flags + cached values | Dirty flags + slot caching |
| **Cycle handling** | Compile-time detection | Runtime trigger stack | Dirty flag propagation stops |
| **Change propagation** | Next compile | Immediate | Marked dirty, evaluated on demand |

---

## Type Systems

### Werkkzeug4: Hierarchical with Conversions

Types form an inheritance tree with `AnyType` at the root.

```
AnyType
├── Wz4Mesh
│   └── Wz4MeshInstance
├── Texture2D
│   └── TextureAtlas
└── GroupType
```

Type checking walks up the parent chain. Automatic conversion operators bridge incompatible types.

```c
// Type check: walks inheritance
sBool wType::IsType(wType *type) {
  do {
    if(type == this) return 1;
    this = this->Parent;
  } while(this);
  return 0;
}

// Conversion: automatic insertion
operator Wz4Mtrl FromTexture(Texture2D) {
  flags = conversion;
  // ...
}
```

### cables.gl: Port Types

Three port categories with type restrictions:

| Port Type | What It Carries | Connection Rules |
|-----------|-----------------|------------------|
| **Value** | Number, string, color | Same type only |
| **Trigger** | Execution signal | Trigger to trigger only |
| **Object** | Texture, mesh, context | Compatible types |

Type checking happens at connection time in the editor.

### tixl: Generic Slots

Strongly typed with C# generics:

```csharp
public class InputSlot<T> : Slot<T>, IInputSlot {
    public T GetValue(EvaluationContext context);
}

// Usage in operator
[Input(Guid = "...")]
public readonly InputSlot<float> Scale = new();

[Output(Guid = "...")]
public readonly Slot<Mesh> Result = new();
```

Compile-time type safety via generics. No runtime type checking needed.

### Comparison

| Aspect | Werkkzeug4 | cables.gl | tixl |
|--------|------------|-----------|------|
| **Type checking timing** | Compile phase | Connection time | Compile time (C#) |
| **Polymorphism** | Inheritance hierarchy | Port categories | Generics + interfaces |
| **Automatic conversion** | Conversion operators | Manual | Type coercion where possible |
| **Type definition** | .ops DSL | JavaScript objects | C# attributes |

---

## Operator Definition

### Werkkzeug4: DSL with Code Generation

```c
// In .ops file
operator Wz4Mesh Torus()
{
  parameter
  {
    int Slices(3..4096)=12;
    float InnerRadius(0..1024 step 0.01)=0.25;
  }
  code
  {
    out->MakeTorus(para->Slices, para->InnerRadius, ...);
  }
}
```

External tool generates C++ structs, GUI, registration.

### cables.gl: JavaScript Functions

```javascript
// In op.js file
const Ops = Ops || {};
Ops.MyOp = function() {
    const inTrigger = this.inTrigger("Trigger");
    const inRadius = this.inFloat("Radius", 1.0);
    const outMesh = this.outObject("Mesh");

    inTrigger.onTriggered = () => {
        const mesh = generateTorus(inRadius.get());
        outMesh.setRef(mesh);
    };
};
```

Runtime registration, dynamic port creation.

### tixl: Attributes with CRTP

```csharp
[Guid("...")]
public class TorusOp : Instance<TorusOp>
{
    [Input(Guid = "...")]
    public readonly InputSlot<int> Slices = new(12);

    [Input(Guid = "...")]
    public readonly InputSlot<float> InnerRadius = new(0.25f);

    [Output(Guid = "...")]
    public readonly Slot<Mesh> Result = new();

    public TorusOp()
    {
        Result.UpdateAction = ctx => {
            Result.Value = GenerateTorus(Slices.GetValue(ctx), InnerRadius.GetValue(ctx));
        };
    }
}
```

Reflection at load time, compile-time type safety.

### Comparison

| Aspect | Werkkzeug4 | cables.gl | tixl |
|--------|------------|-----------|------|
| **Definition syntax** | Custom DSL | JavaScript | C# with attributes |
| **Generation timing** | Build tool (offline) | Runtime | Load time (reflection) |
| **Type safety** | Generated code | Runtime checks | Compile-time generics |
| **Registration** | AddOps_* functions | Patch.addOp() | Assembly scanning |
| **GUI generation** | Code-generated functions | Op template | Reflection + ImGui |

---

## Caching Strategies

### Werkkzeug4: Context-Aware Caching

Cache key = operator ID + CallId (context identifier).

```cpp
// Same operator, different contexts = different cache entries
if(op->Cache && op->Cache->CallId == node->CallId)
{
    // Cache hit: operator AND context match
}
```

Subroutines and loops get unique CallIds, preventing cache pollution.

### cables.gl: Dirty Flags + Cached Values

Each port caches its value. Dirty flags track when re-evaluation is needed.

```javascript
// Conceptual dirty flag pattern
port.get = () => {
    if (this.dirty) {
        this.cachedValue = this.computeValue();
        this.dirty = false;
    }
    return this.cachedValue;
};
```

No context isolation - same operator always returns same cached value.

### tixl: Dirty Flag Propagation

Dirty flags propagate through the graph on input changes.

```csharp
// When input changes
inputSlot.SetDirty();

// Propagates to dependent outputs
foreach (var dependent in inputSlot.Dependents)
    dependent.MarkDirty();

// Evaluation clears dirty flag
T value = slot.GetValue(context);  // Evaluates if dirty
```

Context via `EvaluationContext` parameter, not cache isolation.

### Comparison

| Aspect | Werkkzeug4 | cables.gl | tixl |
|--------|------------|-----------|------|
| **Cache key** | OpId + CallId | Port identity | Slot identity |
| **Context isolation** | Yes (CallId) | No | Via EvaluationContext |
| **Invalidation** | On compile | On value change | Dirty flag propagation |
| **Memory management** | LRU eviction | Garbage collection | .NET GC |

---

## Flow Control

### Werkkzeug4: Flow as Operators

Special operators with compiler support:

| Operator | Behavior |
|----------|----------|
| `Call` | Invoke subroutine with injected inputs |
| `Loop` | Unroll N iterations at compile time |
| `Input` | Access call arguments |
| `ShellSwitch` | Runtime conditional |

Flow control is visual - appears as nodes in the graph.

### cables.gl: Trigger-Based Flow

Flow control through trigger connections:

```javascript
// Counter op
const inTrigger = this.inTrigger("In");
const inReset = this.inTrigger("Reset");
const outTrigger = this.outTrigger("Out");
const outCount = this.outNumber("Count");

let count = 0;
inTrigger.onTriggered = () => {
    count++;
    outCount.set(count);
    outTrigger.trigger();
};
inReset.onTriggered = () => { count = 0; };
```

Loops via trigger feedback (with cycle prevention).

### tixl: Flow Operators

Dedicated flow control operators:

- `Loop` - Iterate N times
- `Time.Ramp` - Time-based sequencing
- `List.GetItem` - Iteration over collections

Flow is part of the operator library, not special-cased.

---

## Key Insights for Rust Framework

### What to Adopt

| Pattern | From | Why |
|---------|------|-----|
| Declarative operators | All three | Single source of truth eliminates sync bugs |
| Two-tier runtime | Werkkzeug4 | Editor flexibility + execution performance |
| Dirty flag propagation | tixl, cables | Efficient incremental updates |
| Context-aware caching | Werkkzeug4 | Correct subroutine/loop handling |
| Pull-based evaluation | tixl | Only compute what's needed |

### What to Combine

- **Werkkzeug4's compilation model** with **tixl's dirty flags**: Compile for execution, but track invalidation for selective recompilation.
- **cables' dual execution** with **Rust's type system**: Trigger ports as a distinct type, value ports as generic `Slot<T>`.
- **Werkkzeug4's DSL approach** via **Rust proc-macros**: Get the same benefits without external tools.

### What to Avoid

| Anti-pattern | Why |
|--------------|-----|
| Runtime type checking via strings | Rust's type system is stronger |
| Global document/context pointers | Ownership makes this unnecessary |
| Manual reference counting | Use `Arc<T>` |
| External code generators | Proc-macros integrate better |

---

## Summary

Three successful approaches to the same problem:

1. **Werkkzeug4**: Compile-execute with extreme optimization for demoscene constraints
2. **cables.gl**: Live execution with dual modes for creative iteration
3. **tixl**: Pull-based lazy evaluation with modern language features

A Rust framework can learn from all three:
- Use proc-macros for declarative operator definitions (Werkkzeug4's insight)
- Support both immediate and deferred execution (cables' insight)
- Leverage the type system for safety without runtime overhead (tixl's insight)
- Add context-aware caching for correct subroutine behavior (Werkkzeug4's unique contribution)

---

## Files Referenced

| Source | Key Documents |
|--------|---------------|
| Werkkzeug4 | `per-demoscene/fr_public/werkkzeug4/operator-system.md`, `graph-execution.md`, `type-system.md` |
| cables.gl | `per-framework/cables/architecture.md`, `rendering-pipeline.md` |
| tixl | `per-framework/tixl/architecture.md`, `editor/maggraph/` |
