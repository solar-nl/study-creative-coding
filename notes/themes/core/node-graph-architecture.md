# Node Graph Architecture: Three Building Materials

> How Werkkzeug4, cables.gl, and tixl structure their operator graphs

---

## The Structural Challenge

Every visual programming system faces the same fundamental question: how do you represent a graph of interconnected operations in a way that serves both the artist editing it and the machine executing it? This is not merely a technical choice but an architectural one that shapes the entire user experience.

The challenge intensifies when we consider the dual nature of node graphs. In the editor, nodes must be flexible, editable, and responsive to human intuition. During execution, they must be fast, predictable, and efficient. These requirements pull in opposite directions.

Three frameworks approached this problem with fundamentally different architectural materials:

- **Werkkzeug4** builds with **pre-fabricated concrete**: rigid, compiled structures that cannot flex once set. The graph compiles into an immutable command buffer, then executes.
- **Cables.gl** builds with **flexible scaffolding**: a single integrated structure of steel and joints that handles both editing and execution, bending as needed.
- **Tixl** builds with **modular prefab blocks**: templates (Symbols) manufactured once, then instantiated as needed into runtime objects (Instances) with pull-based evaluation.

These material choices ripple through every architectural decision that follows.

---

## Node Representation

### The Blueprint Problem

What data structure should represent a node? A node in the editor needs position coordinates, selection state, and undo information. A node during execution needs input values, output buffers, and a function to call. Combining these creates bloat; separating them creates synchronization complexity.

Each material choice leads to a different answer.

### Werkkzeug4: Pre-Fabricated Concrete

Werkkzeug4 chose complete separation—like pouring concrete into a mold. The `wOp` class serves the editor with rich, mutable graph-based data (name, edit parameters, graph edges, cache). During execution, this transforms into `wCommand`: a minimal, immutable structure containing only a function pointer, flattened inputs, output buffer, and cache key. The rigidity of concrete means no flexibility at runtime, but maximum execution speed.

### cables.gl: Flexible Scaffolding

Cables.gl uses a single structure for both modes—scaffolding that can be reconfigured while standing on it. The `Op` class holds both input/output port arrays and editor UI attributes in one object. `Port` objects carry value, links, and type together. This flexibility means you can add ports, rewire connections, and see changes instantly. The scaffolding bends with you, though it carries more weight than specialized structures would.

### tixl: Modular Prefab Blocks

Tixl uses the template-instance pattern—prefabricated blocks manufactured once, then stamped out as needed. A `Symbol` serves as the template: ID, input definitions, output definitions, and the type to instantiate. An `Instance` is a runtime copy: actual input/output slots and a parent reference. Like prefab construction, you design once and deploy many times, getting both consistency and efficiency.

**Trade-off Table: Node Representation**

| Material | Flexibility | Execution Speed | Memory |
|----------|-------------|-----------------|--------|
| Concrete (Wz4) | High edit, rigid exec | Fast (linear buffer) | Snapshot overhead |
| Scaffolding (cables) | Fully flexible | Medium (traversal) | Shared state |
| Prefab (tixl) | Template reuse | Fast (lazy) | Efficient sharing |

---

## Execution Models

### The Flow Problem

When should a node compute its output? Push-based systems propagate changes immediately. Pull-based systems compute lazily when outputs are requested. Compile-execute systems transform the graph into a linear sequence.

Each building material suggests a different execution pattern—and the frameworks follow their material logic.

### Werkkzeug4: The Concrete Assembly Line

Compile-then-execute—once the concrete sets, you run the assembly line. The Builder transforms the graph (`wOp` nodes) into a linear command buffer, then the Executive iterates through sequentially: `for (cmd in Commands) cmd->Code(this, cmd)`.

The linearity maximizes cache locality. For demoscene intros on constrained hardware, this mattered enormously. But like any concrete structure, changes require tearing down and rebuilding.

### cables.gl: The Scaffolding Event Stream

Dual execution—the scaffolding carries two types of traffic. Triggers push control flow: when a trigger fires, it iterates through linked ports calling `_onTriggered()`. Values propagate on change: when `setValue(v)` detects a difference, it propagates to linked ports. This flexibility lets artists see changes immediately while performing. The scaffolding trembles with each change but stays standing.

### tixl: The Prefab On-Demand Workshop

Pull-based lazy evaluation—prefab blocks that only activate when you walk up to them. `GetValue()` calls `Update()`, which checks a dirty flag before invoking the actual computation. The `EvaluationContext` carries frame-specific state (time, camera, render targets) through the pull chain, avoiding global variables.

Like a modular workshop, each station (Instance) only runs when its output is needed. Unchanged stations sit idle, saving computation.

**Trade-off Table: Execution Models**

| Material | First Edit Cost | Incremental Cost | Live Tweaking |
|----------|-----------------|------------------|---------------|
| Concrete (compile-execute) | High (pour & cure) | Low (caching) | Requires recompile |
| Scaffolding (streaming) | None | Per-operator | Immediate |
| Prefab (pull-based) | None | Only dirty nodes | Immediate |

---

## Type Systems

### The Compatibility Problem

How do you prevent invalid connections while enabling flexibility? The challenge deepens with polymorphism and automatic conversions. Each material imposes different constraints on what can connect to what.

### Werkkzeug4: The Concrete Adapter Catalog

Hierarchical types with automatic conversion operators—like having a catalog of adapters that let different concrete forms connect. Types form an inheritance tree; type checking walks up the parent chain via `IsType()`. Conversion operators are regular operators flagged with `wCF_CONVERSION`; the Builder automatically inserts them when types do not match.

The rigidity of concrete requires explicit adapters. You cannot connect incompatible blocks without a pre-cast joining piece.

### cables.gl: The Color-Coded Scaffolding Joints

Simple port categories with color-coded types—scaffolding joints that only fit their matching color. Five types: VALUE (green), TRIGGER (yellow), OBJECT (blue), ARRAY (orange), STRING (cyan). No inheritance hierarchy, no automatic conversion. What you see is what connects.

The scaffolding approach prioritizes visual clarity over type sophistication. Artists see immediately what can connect.

### tixl: The Precision-Machined Prefab Connectors

C# generics for compile-time type safety—prefab blocks with precision-machined connectors that only fit their exact counterpart. `Slot<T>` carries the type parameter; `InputSlot<float>` cannot connect to `Slot<Mesh>`. The compiler catches mismatches before runtime.

Prefab precision means errors surface at design time, not performance time.

**Trade-off Table: Type Systems**

| Material | Type Flexibility | Error Detection | Visual Feedback |
|----------|------------------|-----------------|-----------------|
| Concrete (adapters) | High (auto-convert) | Runtime | None |
| Scaffolding (colors) | Low (must match) | Edit-time | Color-coded |
| Prefab (generics) | Medium (explicit) | Compile-time | IDE support |

---

## Caching Strategies

### The Recomputation Problem

Naive evaluation recomputes everything every frame. Smart caching remembers results. But what is the cache key? How do you handle subroutines called from multiple contexts? The building material determines how much you can remember—and how.

### Werkkzeug4: Concrete Cache Vaults

Context-aware cache keys—like numbered storage vaults in the concrete structure. Each `wCommand` has a `CallId` distinguishing the same operator called from different contexts. The cache key is `(OpId, CallId)`.

This matters for loops: a loop calling SubroutineA three times produces three distinct cache entries (CallId 0x100, 0x101, 0x102). Without this, the loop would overwrite its own cache on each iteration.

The concrete approach: build the vault addresses into the structure itself. Rigid but reliable.

### cables.gl: Scaffolding Change Detection

Simple dirty flags on ports—the scaffolding remembers what moved. When a value changes, connected ports mark themselves for recomputation on next access. No context tracking, no composite keys. The simplicity matches the scaffolding philosophy: quick to reconfigure, minimal bookkeeping.

### tixl: Prefab Serial Numbers

Dirty flags at the slot level with pull-based propagation—each prefab block tracks its own version number. `DirtyFlag` compares `Target` (current version) against `Reference` (last computed version). `Invalidate()` increments the global frame counter and returns a new target.

Context flows through `EvaluationContext`, not cache keys. Each prefab block carries its own manufacturing serial number.

**Trade-off Table: Caching Strategies**

| Material | Cache Granularity | Context Handling | Memory Overhead |
|----------|-------------------|------------------|-----------------|
| Concrete (CallId) | Per-operator | Composite keys | High (all contexts) |
| Scaffolding (dirty flags) | Per-port | None | Low |
| Prefab (version numbers) | Per-slot | Context parameter | Medium |

---

## Choosing Your Material: Rust Recommendations

Each building material offers lessons for a Rust-based node graph system. The goal is not to copy any single approach but to select the best components and forge them together using Rust's unique strengths.

### From Concrete (Werkkzeug4)

**Adopt the CallId pattern** for context-aware caching. Composite cache keys `(OpId, CallId)` prevent cache pollution in loops and subroutines. In Rust:

```rust
#[derive(Hash, Eq, PartialEq)]
struct CacheKey { op_id: OpId, call_id: CallId }
```

**Skip the two-tier separation.** Rust's ownership model makes runtime separation less necessary—you can have compile-time guarantees about mutability without separate structures.

### From Scaffolding (cables.gl)

**Adopt the dual execution model.** Triggers for control flow, values for data. Rust enums express this naturally:

```rust
enum Port<T> {
    Value(T),              // Pull-based, cached
    Trigger(fn(&Context)), // Push-based, immediate
}
```

**Skip the runtime type flexibility.** Rust's generics provide compile-time type safety that scaffolding cannot.

### From Prefab (tixl)

**Adopt pull-based lazy evaluation** with dirty flags. The `EvaluationContext` pattern avoids global mutable state—critical for Rust's borrowing rules.

**Adopt the template-instance pattern** using Rust traits:

```rust
trait Symbol { type Instance: Instance; fn instantiate(&self) -> Self::Instance; }
trait Instance { fn update(&mut self, ctx: &EvaluationContext); }
```

### The Rust Alloy

Combine these elements into something none of the originals could achieve:

| Component | Source | Rust Implementation |
|-----------|--------|---------------------|
| Cache keys | Concrete | `#[derive(Hash)]` composite keys |
| Dual ports | Scaffolding | `enum Port<T>` with variants |
| Lazy eval | Prefab | Trait-based `Instance::update()` |
| Type safety | Prefab | Generics + `Into<T>` conversions |
| Ownership | Rust-native | `Arc<T>` for shared, unique for owned |

**Specifically avoid:**
- External code generators (use proc-macros instead)
- Runtime type checking via strings (leverage generics)
- Manual reference counting (use `Arc<T>`)
- Global document pointers (pass contexts explicitly)

The result: a material that has concrete's execution speed, scaffolding's live-editing flexibility, and prefab's compile-time guarantees—forged with Rust's zero-cost abstractions.

---

## Related Documents

- `node-graph-systems.md` - Higher-level comparison
- `architecture-patterns.md` - Cross-cutting patterns
- `api-ergonomics.md` - API design considerations
