# Node Graph Architecture: Four Building Materials

> How Werkkzeug4, cables.gl, vvvv gamma, and tixl structure their operator graphs

---

## The Structural Challenge

Every visual programming system faces the same fundamental question: how do you represent a graph of interconnected operations in a way that serves both the artist editing it and the machine executing it? This is not merely a technical choice but an architectural one that shapes the entire user experience.

The challenge intensifies when we consider the dual nature of node graphs. In the editor, nodes must be flexible, editable, and responsive to human intuition. During execution, they must be fast, predictable, and efficient. These requirements pull in opposite directions.

Four frameworks approached this problem with fundamentally different architectural materials:

- **Werkkzeug4** builds with **pre-fabricated concrete**: rigid, compiled structures that cannot flex once set. The graph compiles into an immutable command buffer, then executes.
- **Cables.gl** builds with **flexible scaffolding**: a single integrated structure of steel and joints that handles both editing and execution, bending as needed.
- **vvvv gamma** builds with **region-bounded rooms**: patches contain operations organized into distinct regions that control execution flow, with explicit boundaries for iteration, conditions, and caching.
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

### vvvv gamma: Region-Bounded Rooms

vvvv gamma organizes code into patches containing operations—like rooms in a building connected by corridors (links). Each operation can be a simple node or contain an entire subpatch. The key structural innovation is regions: rectangular areas that change execution semantics for everything inside them.

A ForEach region transforms its contents into an iteration body. A Cache region wraps its contents in change detection. An If region guards conditional execution. These regions have border control pins (splicers, accumulators) that define how data enters and exits. The architecture is fundamentally about boundaries—operations live within well-defined spaces.

Operations come in two flavors: member operations (belonging to a datatype, like methods on a class) and static operations (standalone functions). This distinction maps to .NET's object model, enabling seamless interop with C# libraries.

### tixl: Modular Prefab Blocks

Tixl uses the template-instance pattern—prefabricated blocks manufactured once, then stamped out as needed. A `Symbol` serves as the template: ID, input definitions, output definitions, and the type to instantiate. An `Instance` is a runtime copy: actual input/output slots and a parent reference. Like prefab construction, you design once and deploy many times, getting both consistency and efficiency.

**Trade-off Table: Node Representation**

| Material | Flexibility | Execution Speed | Memory |
|----------|-------------|-----------------|--------|
| Concrete (Wz4) | High edit, rigid exec | Fast (linear buffer) | Snapshot overhead |
| Scaffolding (cables) | Fully flexible | Medium (traversal) | Shared state |
| Regions (vvvv gamma) | Patch-defined structure | Fast (JIT compiled) | Runtime instances |
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

### vvvv gamma: The Region-Controlled Flow

Explicit region-based execution—each region type defines its own control flow rules. A ForEach region iterates: data enters via splicers, the body executes once per element, results exit via output splicers. A Repeat region executes a fixed count. An If region guards execution behind a boolean. A Cache region executes only when inputs change.

Splicers are the key mechanism. When a spread connects into a ForEach via a splicer bar, consecutive iterations receive consecutive elements. Multiple splicers entering the same loop determine iteration count by minimum length (zip-shortest). Accumulators carry state between iterations, enabling fold/reduce patterns.

The VL compiler transforms patches into .NET IL, enabling JIT optimization at runtime. Live recompilation happens transparently—edit a patch, see the change immediately without restart.

### tixl: The Prefab On-Demand Workshop

Pull-based lazy evaluation—prefab blocks that only activate when you walk up to them. `GetValue()` calls `Update()`, which checks a dirty flag before invoking the actual computation. The `EvaluationContext` carries frame-specific state (time, camera, render targets) through the pull chain, avoiding global variables.

Like a modular workshop, each station (Instance) only runs when its output is needed. Unchanged stations sit idle, saving computation.

**Trade-off Table: Execution Models**

| Material | First Edit Cost | Incremental Cost | Live Tweaking |
|----------|-----------------|------------------|---------------|
| Concrete (compile-execute) | High (pour & cure) | Low (caching) | Requires recompile |
| Scaffolding (streaming) | None | Per-operator | Immediate |
| Regions (vvvv gamma) | Low (JIT recompile) | Region-scoped | Immediate (hot reload) |
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

### vvvv gamma: The Generic Type Inference System

.NET generics with type inference—pins can be explicitly annotated with types or left for inference. When you create a new pin, VL infers its type from connections. Explicit annotation is available via the pin configuration menu for disambiguation or documentation.

No automatic type conversion exists—unlike Werkkzeug4's adapter catalog, vvvv gamma requires explicit conversion nodes. This explicitness matches the overall philosophy: what you see is what executes. Pin groups (for `Spread<T>`, `Array<T>`, etc.) allow variadic inputs that dynamically add pins to a node.

Type errors surface at patch save time when the VL compiler validates the graph. Color-coded links provide immediate visual feedback: each type has a distinct color, making connection compatibility visible at a glance.

### tixl: The Precision-Machined Prefab Connectors

C# generics for compile-time type safety—prefab blocks with precision-machined connectors that only fit their exact counterpart. `Slot<T>` carries the type parameter; `InputSlot<float>` cannot connect to `Slot<Mesh>`. The compiler catches mismatches before runtime.

Prefab precision means errors surface at design time, not performance time.

**Trade-off Table: Type Systems**

| Material | Type Flexibility | Error Detection | Visual Feedback |
|----------|------------------|-----------------|-----------------|
| Concrete (adapters) | High (auto-convert) | Runtime | None |
| Scaffolding (colors) | Low (must match) | Edit-time | Color-coded |
| Regions (vvvv gamma) | Medium (inference + explicit) | Compile-time | Type-colored links |
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

### vvvv gamma: Region-Scoped Cache Rooms

Cache regions as explicit caching boundaries—wrap any subgraph in a Cache region to enable change detection. Border control pins track which inputs changed since last execution. The `HasChanged` output notifies downstream consumers whether recomputation occurred.

This approach inverts the typical pattern: instead of marking nodes as cacheable, you explicitly define cache boundaries. Everything outside a Cache region executes every frame. Everything inside only executes when border inputs change.

The region model provides clear debugging: if a cached subgraph isn't updating, check its border pins. The boundary is visible in the patch, not hidden in node implementation.

### tixl: Prefab Serial Numbers

Dirty flags at the slot level with pull-based propagation—each prefab block tracks its own version number. `DirtyFlag` compares `Target` (current version) against `Reference` (last computed version). `Invalidate()` increments the global frame counter and returns a new target.

Context flows through `EvaluationContext`, not cache keys. Each prefab block carries its own manufacturing serial number.

**Trade-off Table: Caching Strategies**

| Material | Cache Granularity | Context Handling | Memory Overhead |
|----------|-------------------|------------------|-----------------|
| Concrete (CallId) | Per-operator | Composite keys | High (all contexts) |
| Scaffolding (dirty flags) | Per-port | None | Low |
| Regions (vvvv gamma) | Per-region | Border pins | User-controlled |
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

### From Regions (vvvv gamma)

**Adopt explicit iteration** over implicit spreading. Regions as first-class constructs make control flow visible. In Rust, this maps to explicit iterator combinators rather than hidden auto-vectorization:

```rust
// vvvv gamma's ForEach with splicers = explicit zip + map
let results: Vec<_> = a.iter().zip(b.iter())
    .map(|(x, y)| process(x, y))
    .collect();
```

**Adopt immutable Spreads** as the default collection type. `Arc<[T]>` provides shared ownership of immutable data with cheap cloning—matching vvvv gamma's Spread semantics exactly.

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
| Explicit iteration | Regions | Iterator combinators, no auto-spreading |
| Immutable collections | Regions | `Arc<[T]>` Spreads |
| Lazy eval | Prefab | Trait-based `Instance::update()` |
| Type safety | Prefab | Generics + `Into<T>` conversions |
| Ownership | Rust-native | `Arc<T>` for shared, unique for owned |

**Specifically avoid:**
- External code generators (use proc-macros instead)
- Runtime type checking via strings (leverage generics)
- Manual reference counting (use `Arc<T>`)
- Global document pointers (pass contexts explicitly)
- Implicit auto-spreading (use explicit iteration)

The result: a material that has concrete's execution speed, scaffolding's live-editing flexibility, region's explicitness, and prefab's compile-time guarantees—forged with Rust's zero-cost abstractions.

---

## Related Documents

- `node-graph-systems.md` - Higher-level comparison
- `architecture-patterns.md` - Cross-cutting patterns
- `api-ergonomics.md` - API design considerations
