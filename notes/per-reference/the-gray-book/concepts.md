# VL Core Concepts

> Key mental models and terminology from The Gray Book

---

## Dataflow Model

VL is fundamentally a **dataflow programming** language. Understanding this model is essential.

### Data Sources and Sinks

Every connection in VL has a direction:
- **Data Source** — An output that provides data (e.g., a node's output pin)
- **Data Sink** — An input that consumes data (e.g., a node's input pin)

> "A data source can only be connected to a data sink (and vice versa)."

This is enforced by the type system — you cannot connect two outputs or two inputs together.

### Links

**Links** are the connections between data hubs. They represent data flow, not control flow. The key insight:

> "Programming visually with data flow you can link some data from one node to the other. All these nodes are doing their thing and together they form something new, a new functionality."

**Rust parallel:** Links are like function composition — the output of one function flows into the input of another. In Rust: `a.then(b).then(c)` or `c(b(a(x)))`.

---

## Patches and Nodes

### Patches

A **Patch** is the canvas where you build programs. It's both:
1. A visual workspace
2. A scope/namespace for definitions

Patches can contain:
- Nodes (instances of operations)
- Regions (control flow constructs)
- Pads (named storage locations)
- Links (connections)

### Nodes

A **Node** is an instance of an operation placed on a patch. Nodes have:
- **Inputs** (data sinks)
- **Outputs** (data sources)
- An underlying **operation** that transforms inputs to outputs

**Rust parallel:** A node is like a function call. The operation is the function definition; the node is an invocation.

---

## Regions

Regions are VL's approach to **control flow in a visual context**. They're bordered areas that define scope and execution semantics.

### ForEach Region

Iterates over collections at the same pace:

> "A ForEach region lets you iterate over several collections at the same pace. For each collection you get one item inside the region to work with."

**Rust parallel:** `Iterator::zip()` combined with `for_each()`:
```rust
a.iter().zip(b.iter()).for_each(|(x, y)| { /* body */ })
```

### Repeat Region

Executes a fixed number of times:

> "A Repeat region lets you define how many times the body should be called via the Iteration Count Pin."

**Rust parallel:** `(0..n).for_each(|i| { /* body */ })`

### If Region

Conditional execution:

> "The body of this region is only executed when the condition holds."

With a default value when the condition is false.

**Rust parallel:** `if cond { compute() } else { default }`

### Delegate Region

Defines an anonymous operation that can be passed as a value:

> "With a delegate you may define an operation anonymously... The delegate region has an output that holds the operation defined within the region — as a value."

This is VL's approach to **first-class functions**.

**Rust parallel:** Closures:
```rust
let f = |x| x * 2;  // Delegate region
some_node.apply(f); // Passing to another node
```

### Where Region

Filter operation:

> "The 'Where [Spread]' region allows you to decide for each item if this item shall be included in the resulting spread or not."

**Rust parallel:** `Iterator::filter()`

---

## Spreads

**Spreads** are VL's primary collection type. They're central to VL's programming model.

### Automatic Spreading

When you connect a spread to a node that expects a single value, VL automatically "spreads" — applies the operation to each element:

> "The spreading behavior means operations automatically map over collections."

**Rust parallel:** This is similar to `Iterator::map()`, but implicit. In Rust, we'd make this explicit:
```rust
// VL: connect spread to node expecting single value = auto-map
// Rust: spread.iter().map(|x| node(x))
```

### Spread Operations

Common operations:
- **Cons** — Add element to spread
- **GetSlice** — Extract subset
- **Zip** — Combine multiple spreads
- **Count** — Number of elements

---

## Process vs Operation Nodes

This distinction is crucial for understanding state in VL.

### Operations

Pure transformations — no state between frames:

> "Operations are stateless — they compute outputs from inputs without remembering anything."

### Process Nodes

Stateful — maintain state across frames:

> "Process nodes accumulate state. They remember values between executions."

**Rust parallel:**
- Operations → Pure functions: `fn op(input: T) -> U`
- Process nodes → Structs with state: `struct Process { state: S } impl Process { fn update(&mut self, input: T) -> U }`

---

## Pads

**Pads** are named storage locations within a patch:

> "Pads allow you to give a name to a value and use it in multiple places."

Types of pads:
- **Input pads** — Parameters for the patch
- **Output pads** — Return values from the patch
- **Local pads** — Internal named values

**Rust parallel:** Variables in a function, or fields in a struct.

---

## Type System

### Generics

VL supports generic types:

> "Generics allow you to write operations that work with any type."

The type system infers types where possible and shows type errors visually (red links).

**Rust parallel:** Generics with trait bounds: `fn process<T: Add>(x: T, y: T) -> T`

### Type Inference

VL infers types from connections:

> "The system knows which data to expect. This will help you... to prevent some errors which would be hard to find otherwise."

**Rust parallel:** Rust's type inference, but visualized through link colors.

---

## Categories

**Categories** organize nodes for discovery:

> "Categories group related nodes together, making it easier to find what you need."

This is about API discoverability — how users find functionality.

**Rust parallel:** Module organization and preludes. A well-organized `prelude` module that re-exports commonly-used items.

---

## Key Takeaways for Rust Framework

| VL Concept | Rust Adaptation |
|------------|-----------------|
| Dataflow | Method chaining, builder pattern |
| Spreads + auto-spreading | Iterator adapters (explicit `.map()`) |
| Regions | Closures and combinators |
| Process vs Operation | Stateful structs vs pure functions |
| Pads | Named fields, builder pattern |
| Categories | Module organization, preludes |
| Visual type errors | Compiler errors with good diagnostics |
