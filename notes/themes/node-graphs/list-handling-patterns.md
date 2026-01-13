# List Handling Patterns in Visual Programming Systems

> How operator graph systems handle the transition from scalar to collection

---

## The Problem: Scalars Meet Collections

Every visual programming system faces a fundamental question: what happens when a list connects to a node that expects a single value? The answer shapes the entire user experience and determines whether the system feels intuitive or confusing.

Consider a simple `Add(a, b)` node. What should happen when:
- Both inputs receive single values? → Obviously outputs a single value
- One input receives a list of 10 values, the other a single value? → ???
- Both inputs receive lists of different lengths (5 and 10)? → ???

Different systems answer these questions differently, and understanding these patterns is essential for designing a new framework.

---

## Terminology Rosetta Stone

| Concept | vvvv gamma | cables.gl | tixl |
|---------|------------|-----------|------|
| **List type** | `Spread<T>` | ARRAY port (untyped) | `StructuredList<T>`, `List<T>` slot |
| **Automatic iteration** | None (explicit loops only) | None (iterator operators) | None (multi-input slots) |
| **Iteration mechanism** | ForEach + Splicers | ArrayIterator triggers | Multi-input collection |
| **Accumulator** | Accumulator in loop regions | ArrayBuffer operator | Feedback connections |
| **Length mismatch** | Zip shortest (ForEach) / Cycling (Repeat) | First array wins | N/A (explicit) |

---

## Pattern 1: Explicit Iteration Only (vvvv gamma / VL)

### Core Philosophy

vvvv gamma made a deliberate design choice: **no automatic spreading**. This is a departure from vvvv beta, which had implicit spreading where operations auto-vectorized over collections.

> "LOOPS: there is no automatic spreading. instead, VL only has explicit loops"
> — [Gray Book: Introduction for vvvv beta users](../../references/the-gray-book/reference/getting-started/beta/introduction-for-vvvv-beta-users.md)

### Mechanics

**ForEach Loop with Splicers:**
```
[Spread of 10 items] ──┬── Splicer ──► [ForEach Region] ──► [Spread of 10 results]
                       │                    │
[Spread of 10 items] ──┴── Splicer ──────────┘
```

**Splicers** provide consecutive slices to consecutive iterations. The loop body receives one element at a time.

**Length Mismatch Resolution:**
- **ForEach loop**: Uses **zip-shortest** — iterations = minimum slice count of all splicers
- **Repeat loop**: Uses **cycling/modulo** — wraps around shorter spreads

**Accumulator Pattern:**
Accumulators pass data between iterations, enabling reduce/fold operations:
```
[Initial Value] ──► Accumulator Input ──► [Loop Body] ──► Accumulator Output ──► [Final Result]
                         │                    │                │
                         └────────────────────┘ (carried between iterations)
```

### Trade-offs

| Advantage | Disadvantage |
|-----------|--------------|
| Explicit is debuggable | More verbose for simple cases |
| Clear length handling | Requires learning loop mechanics |
| No surprising auto-vectorization | Can't quickly prototype spread operations |

### Rust Applicability

Maps directly to explicit iteration:
```rust
// ForEach with splicers = iter().zip()
let results: Vec<_> = a.iter().zip(b.iter())
    .map(|(x, y)| x + y)
    .collect();

// Accumulator = fold
let sum = values.iter().fold(0.0, |acc, x| acc + x);
```

---

## Pattern 2: Trigger-Pumped Iteration (cables.gl)

### Core Philosophy

cables.gl uses a **trigger-based execution model** where array iteration is an explicit operation that "pumps" triggers through the graph.

### Mechanics

**Array Iterator Pattern** (from `Ops.Array.Array3Iterator.js`):
```javascript
exe.onTriggered = function() {
    for (let i = 0; i < ar.length; i += vstep) {
        idx.set(count);          // Set loop index
        valX.set(ar[i + 0]);     // Set current X value
        valY.set(ar[i + 1]);     // Set current Y value
        valZ.set(ar[i + 2]);     // Set current Z value
        trigger.trigger();        // Fire downstream trigger
        count++;
    }
}
```

The iterator **synchronously fires N triggers** for an array of N elements. Downstream nodes receive values one at a time in sequence.

**Port Type System:**
```javascript
static TYPE_VALUE = 0;    // Numbers
static TYPE_TRIGGER = 1;  // Execution flow
static TYPE_OBJECT = 2;   // Complex objects
static TYPE_ARRAY = 3;    // Arrays (first-class, untyped!)
static TYPE_DYNAMIC = 4;  // Runtime typing
static TYPE_STRING = 5;   // Text
```

ARRAY is a distinct port type, not a generic wrapper. This means `Array<Texture>` vs `Array<Number>` are both just "ARRAY" at the type level.

**Binary Array Operations** (from `Ops.Array.ArrayMathArray.js`):
```javascript
const l = mathArray.length = array0.length;  // Uses FIRST array's length
for (let i = 0; i < l; i++) {
    mathArray[i] = mathFunc(array0[i], array1[i]);  // No bounds checking!
}
```

Length mismatch handling: **first-array-wins** — uses the first array's length, may access undefined values from shorter second array.

### Trade-offs

| Advantage | Disadvantage |
|-----------|--------------|
| Explicit control flow visible | Iteration operators add visual noise |
| Works with trigger system | Untyped arrays lose compile-time safety |
| No implicit magic | First-array-wins can cause silent bugs |

### Rust Applicability

The trigger-pumped pattern maps to push-based iteration:
```rust
fn iterate_array3<F>(array: &[f32], step: usize, mut callback: F)
where F: FnMut(usize, f32, f32, f32)
{
    let stride = 3 * step;
    for (count, i) in (0..array.len()).step_by(stride).enumerate() {
        callback(count, array[i], array[i+1], array[i+2]);
    }
}
```

---

## Pattern 3: Multi-Input Collection (tixl)

### Core Philosophy

tixl uses **typed slots with multi-input capability**. Multiple connections to a single input slot are collected into a typed list.

### Mechanics

**MultiInputSlot<T>** (from `MultiInputSlot.cs`):
```csharp
public sealed class MultiInputSlot<T> : InputSlot<T>, IMultiInputSlot
{
    public List<Slot<T>> CollectedInputs => _collectedInputs;

    public List<Slot<T>> GetCollectedTypedInputs(bool forceRefresh = false)
    {
        // Collects all connected slots
        for (var i = 0; i < InputConnections.Length; i++)
        {
            var slot = InputConnections[i];
            if (slot.TryGetAsMultiInputTyped(out var multiInput))
            {
                // Flatten nested multi-inputs
                _collectedInputs.AddRange(multiInput.GetCollectedTypedInputs());
            }
            else
            {
                _collectedInputs.Add(slot);
            }
        }
        return _collectedInputs;
    }
}
```

This allows operators to receive **multiple connections as a typed list**, with:
- Automatic flattening of nested multi-inputs
- Dirty flag propagation per-connection
- Selective invalidation for performance

**StructuredList<T>** for GPU-friendly collections:
```csharp
public class StructuredList<T> : StructuredList where T : unmanaged
```

The `unmanaged` constraint ensures only blittable types (floats, vectors, structs) — perfect for GPU upload but no arbitrary objects.

### Trade-offs

| Advantage | Disadvantage |
|-----------|--------------|
| Type-safe collections | No auto-spreading |
| GPU-optimized data layout | Must handle iteration explicitly |
| Clean multi-input UI | More complex slot system |

### Rust Applicability

The multi-input pattern maps well to Rust:
```rust
pub struct MultiInputSlot<T> {
    connections: Vec<Arc<Slot<T>>>,
    dirty: DirtyFlag,
}

impl<T: Copy + 'static> MultiInputSlot<T> {
    pub fn get_values(&self, ctx: &EvaluationContext) -> Vec<T> {
        self.connections.iter()
            .map(|slot| slot.get_value(ctx))
            .collect()
    }
}
```

---

## Comparison Tables

### Spreading Semantics

| System | List → Scalar Input | Scalar → List Context | Mismatch Handling |
|--------|---------------------|----------------------|-------------------|
| **vvvv gamma** | Must use explicit loop | Scalar constant in all iterations | Zip shortest (ForEach) |
| **cables.gl** | Must use iterator op | Manual repetition | First array wins |
| **tixl** | Multi-input collects | N/A | Explicit in operator |

### Iteration Constructs

| System | Loop Type | Entry Mechanism | Exit Mechanism |
|--------|-----------|-----------------|----------------|
| **vvvv gamma** | ForEach / Repeat regions | Splicers | Splicers / Accumulators |
| **cables.gl** | ArrayIterator operators | Trigger input | Trigger output per element |
| **tixl** | Operator-level | Multi-input slots | Typed output |

### Type System Integration

| System | List Type | Generic? | Compile-Time Safety |
|--------|-----------|----------|---------------------|
| **vvvv gamma** | `Spread<T>` | Yes | Yes (CLR generics) |
| **cables.gl** | ARRAY port | No (untyped) | No |
| **tixl** | `StructuredList<T>` | Yes (`unmanaged` constraint) | Yes |

---

## Key Insights for Rust Framework Design

### 1. All Three Systems Require Explicit Iteration

None of these modern systems use automatic spreading (NumPy-style broadcasting). This is a deliberate design choice for:
- **Predictability**: Users always know when iteration happens
- **Debuggability**: Can inspect values at each iteration
- **Performance**: No hidden O(n) operations

### 2. Length Mismatch is a Design Decision

| Strategy | When to Use |
|----------|-------------|
| **Zip shortest** | Safe default, no silent errors |
| **Zip longest (pad)** | When default values make sense |
| **Cycling/modulo** | For periodic patterns |
| **Error** | For strict type safety |
| **First wins** | Simple but dangerous |

**Recommendation**: Default to zip-shortest with optional cycling for repeat loops.

### 3. Typed Collections Enable GPU Optimization

tixl's `StructuredList<T> where T: unmanaged` constraint ensures GPU-uploadable data. For a Rust framework:

```rust
pub struct StructuredList<T: Copy + bytemuck::Pod> {
    data: Vec<T>,
}

impl<T: Copy + bytemuck::Pod> StructuredList<T> {
    pub fn as_bytes(&self) -> &[u8] {
        bytemuck::cast_slice(&self.data)
    }
}
```

### 4. Multi-Input Slots Are Powerful

tixl's multi-input pattern is elegant — one slot accepts multiple connections, collected into a typed list. This is cleaner than having N separate inputs.

---

## Recommendations for Rust Framework

### ADR: Spreading Model

**Decision**: Explicit iteration only, no automatic spreading.

**Rationale**:
- Matches all modern systems studied
- Predictable behavior
- Better for debugging
- Can add opt-in spreading later if needed

### ADR: Length Mismatch

**Decision**: Zip-shortest by default, cycling available for repeat patterns.

**Rationale**:
- Safest default (no silent undefined access)
- Cycling useful for creative coding (color palettes, transforms)
- Matches vvvv gamma semantics

### ADR: Collection Type

**Decision**: Use `Spread<T: Copy + Pod>` with:
- Immutable by default (like vvvv gamma)
- `SpreadBuilder<T>` for efficient construction
- GPU-uploadable via bytemuck

```rust
pub struct Spread<T: Copy + Pod>(Arc<[T]>);

pub struct SpreadBuilder<T: Copy + Pod> {
    data: Vec<T>,
}

impl<T: Copy + Pod> SpreadBuilder<T> {
    pub fn push(&mut self, value: T) { self.data.push(value); }
    pub fn build(self) -> Spread<T> { Spread(self.data.into()) }
}
```

---

## Related Documents

- [Node Graph Systems](./node-graph-systems.md) — Execution models comparison
- [Node Graph Architecture](./node-graph-architecture.md) — Node representation patterns
- [cables.gl: Trigger System](../../per-framework/cables/trigger-system.md) — Trigger-pumped iteration deep dive
- [Rust Specific Patterns](../../insights/rust-specific.md) — Rust idiom mappings

---

## Source Material

### In-Repository
- `visual-programming/cables/src/ops/base/Ops.Array.*` — cables.gl array operators
- `visual-programming/tixl/Core/Operator/Slots/MultiInputSlot.cs` — tixl multi-input
- `visual-programming/tixl/Core/DataTypes/StructuredList.cs` — tixl typed collections
- `references/the-gray-book/` — vvvv gamma documentation

### Key Files Analyzed
- cables.gl: `Ops.Array.Array3Iterator.js` (trigger-pumped iteration)
- cables.gl: `Ops.Array.ArrayMathArray.js` (binary operations, length handling)
- cables.gl: `core_port.js` (port type definitions)
- tixl: `MultiInputSlot.cs` (collection pattern)
- tixl: `StructuredList.cs` (GPU-friendly typed lists)
- vvvv: `loops.md`, `introduction-for-vvvv-beta-users.md` (spreading semantics)
