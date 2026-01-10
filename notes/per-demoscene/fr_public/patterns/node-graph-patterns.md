# Node Graph Patterns: From Werkkzeug4 to Rust

> Transferable patterns for building production-quality node-based creative coding systems

---

## Overview

This document synthesizes patterns from Werkkzeug4's architecture that transfer to a Rust creative coding framework. Each pattern includes the problem it solves, how Werkkzeug4 implements it, and a concrete Rust sketch.

Werkkzeug4 shipped in commercial demoscene productions and handled complex 3D scenes at 64KB. These patterns are battle-tested, not theoretical.

---

## Pattern 1: Declarative Operator Definitions

### The Problem

Every node-based system needs operators. Each operator requires boilerplate: parameter storage, GUI widgets, serialization, defaults, execution logic. Writing this by hand for hundreds of operators leads to inconsistencies and maintenance burden.

### The Werkkzeug4 Approach

A domain-specific language (`.ops` files) declares operators. A code generator produces all boilerplate C++.

```c
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

One 15-line declaration generates ~200 lines of consistent C++ for struct, GUI, defaults, and registration.

### The Rust Pattern

Use procedural macros to achieve the same automation without external code generators.

```rust
use framework::prelude::*;

#[derive(Operator)]
#[operator(name = "Torus", category = "Mesh/Primitives", shortcut = 'o')]
pub struct TorusOp {
    #[param(range = 3..=4096, default = 12)]
    pub slices: i32,

    #[param(range = 0.0..=1024.0, step = 0.01, default = 0.25)]
    pub inner_radius: f32,

    #[param(range = 0.0..=1024.0, step = 0.01, default = 1.0)]
    pub outer_radius: f32,
}

impl Execute for TorusOp {
    type Output = Mesh;

    fn execute(&self, _ctx: &Context) -> Result<Self::Output, ExecError> {
        Ok(Mesh::torus(self.slices, self.outer_radius, self.inner_radius))
    }
}
```

The `#[derive(Operator)]` macro generates:
- `impl Default` with attribute-specified defaults
- `impl Gui` emitting egui widgets with ranges
- `impl Serialize + Deserialize` for project files
- Registration via `inventory` or `linkme` crates

### Implementation Sketch

```rust
// In framework_derive/src/lib.rs
#[proc_macro_derive(Operator, attributes(operator, param))]
pub fn derive_operator(input: TokenStream) -> TokenStream {
    let ast = syn::parse(input).unwrap();
    let name = &ast.ident;

    let default_impl = generate_default(&ast);
    let gui_impl = generate_gui(&ast);
    let registration = generate_registration(&ast);

    quote! {
        #default_impl
        #gui_impl
        #registration
    }
    .into()
}

fn generate_gui(ast: &DeriveInput) -> TokenStream2 {
    let fields = extract_fields(ast);
    let widgets: Vec<_> = fields.iter().map(|f| {
        let name = &f.ident;
        let label = name.to_string();
        match &f.ty {
            Type::Path(p) if is_f32(p) => {
                let range = get_range_attr(f);
                let step = get_step_attr(f);
                quote! {
                    ui.add(egui::Slider::new(&mut self.#name, #range).step_by(#step));
                }
            }
            Type::Path(p) if is_i32(p) => {
                let range = get_range_attr(f);
                quote! {
                    ui.add(egui::Slider::new(&mut self.#name, #range));
                }
            }
            _ => quote! {}
        }
    }).collect();

    quote! {
        impl Gui for #name {
            fn ui(&mut self, ui: &mut egui::Ui) {
                #(#widgets)*
            }
        }
    }
}
```

### Key Insight

The DSL/macro approach creates a **single source of truth**. Change a parameter name once, and it updates everywhere: struct field, GUI label, serialization key, script binding.

---

## Pattern 2: Two-Tier Runtime (Editor vs. Execution)

### The Problem

Editors need flexibility: undo/redo, rich metadata, interactive manipulation. Execution needs speed: linear memory access, minimal branching, cache locality. Optimizing for both simultaneously is impossible.

### The Werkkzeug4 Approach

Separate data structures for editing and execution:

| Concern | Editor (`wOp`) | Execution (`wCommand`) |
|---------|----------------|------------------------|
| Structure | Pointer-based graph | Flat array |
| Parameters | Shared with GUI | Copied snapshot |
| Metadata | Full: name, position, selection | None |
| Lifetime | Persistent | Per-calculation |

A compilation step transforms `wOp` graphs into `wCommand` sequences. Parameters are copied at compilation time, decoupling execution from editing.

### The Rust Pattern

Define separate types for each tier with explicit ownership transfer.

```rust
/// Editor-side operator (owned by graph)
pub struct EditorOp {
    pub id: OpId,
    pub name: String,
    pub position: Vec2,
    pub params: Box<dyn OperatorParams>,
    pub inputs: Vec<Option<OpId>>,
    pub selected: bool,
}

/// Execution-side command (owned by command buffer)
pub struct Command<'a> {
    pub code: fn(&CommandContext, &[&dyn Object]) -> Result<Box<dyn Object>, ExecError>,
    pub params: &'a [u8],  // Serialized parameters
    pub inputs: &'a [CommandIndex],
    pub cache_slot: Option<CacheKey>,
}

/// Graph compiler transforms editor to execution
pub struct GraphCompiler<'a> {
    arena: &'a bumpalo::Bump,
    nodes: Vec<CompileNode<'a>>,
}

impl<'a> GraphCompiler<'a> {
    pub fn compile(&mut self, root: OpId, graph: &EditorGraph) -> Result<CommandBuffer<'a>, CompileError> {
        // Phase 1: Parse into intermediate nodes
        let root_node = self.parse(root, graph)?;

        // Phase 2: Optimize (insert caches, conversions)
        self.optimize(&root_node)?;

        // Phase 3: Type check
        self.type_check(&root_node)?;

        // Phase 4: Flatten to command buffer
        self.output(root_node)
    }
}

/// Command buffer owns all execution data
pub struct CommandBuffer<'a> {
    commands: Vec<Command<'a>>,
    param_data: &'a [u8],  // Arena-allocated parameter copies
}

impl<'a> CommandBuffer<'a> {
    pub fn execute(&self, ctx: &mut ExecContext) -> Result<Box<dyn Object>, ExecError> {
        let mut outputs: Vec<Option<Box<dyn Object>>> = vec![None; self.commands.len()];

        for (i, cmd) in self.commands.iter().enumerate() {
            let inputs: Vec<&dyn Object> = cmd.inputs
                .iter()
                .map(|&idx| outputs[idx.0].as_deref().unwrap())
                .collect();

            let output = (cmd.code)(&CommandContext::from(cmd), &inputs)?;

            if let Some(key) = cmd.cache_slot {
                ctx.cache.store(key, output.clone());
            }

            outputs[i] = Some(output);
        }

        outputs.pop().flatten().ok_or(ExecError::NoOutput)
    }
}
```

### Key Insight

**Copy-on-compile** decouples execution from editing. You can modify the graph while previous commands execute. Changes only take effect on the next compilation.

---

## Pattern 3: Context-Aware Caching

### The Problem

Naive caching uses operator identity as the key: "I computed this Blur before, reuse it." But what if the same Blur appears inside a function called twice with different inputs? The cache returns the wrong result.

### The Werkkzeug4 Approach

Each compilation context gets a unique `CallId`. Cache lookups require both operator ID and matching CallId.

```cpp
// Cache lookup
if(op->Cache && op->Cache->CallId == node->CallId)
{
    // Cache hit: same operator AND same context
}
```

When entering a subroutine or loop iteration, the compiler increments `CallId`. All nodes compiled within that context carry the new ID.

### The Rust Pattern

Use composite cache keys with context information.

```rust
/// Cache key includes both identity and context
#[derive(Clone, Copy, Hash, Eq, PartialEq)]
pub struct CacheKey {
    pub op_id: OpId,
    pub call_context: CallContext,
}

#[derive(Clone, Copy, Hash, Eq, PartialEq)]
pub struct CallContext(u32);

impl CallContext {
    pub fn root() -> Self { Self(0) }
    pub fn child(&self, index: u32) -> Self { Self(self.0.wrapping_add(index + 1)) }
}

pub struct Cache {
    entries: HashMap<CacheKey, CacheEntry>,
    lru_counter: u64,
}

impl Cache {
    pub fn get(&mut self, key: CacheKey) -> Option<Arc<dyn Object>> {
        self.entries.get_mut(&key).map(|entry| {
            entry.lru = self.lru_counter;
            self.lru_counter += 1;
            entry.value.clone()
        })
    }

    pub fn store(&mut self, key: CacheKey, value: Arc<dyn Object>) {
        self.entries.insert(key, CacheEntry {
            value,
            lru: self.lru_counter,
        });
        self.lru_counter += 1;
    }

    pub fn evict_lru(&mut self, keep_count: usize) {
        if self.entries.len() <= keep_count { return; }

        let mut entries: Vec<_> = self.entries.iter().map(|(k, v)| (*k, v.lru)).collect();
        entries.sort_by_key(|(_, lru)| *lru);

        for (key, _) in entries.into_iter().take(self.entries.len() - keep_count) {
            self.entries.remove(&key);
        }
    }
}
```

### Usage During Compilation

```rust
impl<'a> GraphCompiler<'a> {
    fn parse_call(&mut self, call_op: &EditorOp, ctx: CallContext) -> Result<CompileNode<'a>, CompileError> {
        // Each call gets a new context
        let child_ctx = ctx.child(self.next_call_id());

        // Parse the subroutine body with the child context
        let body = self.parse_with_context(call_op.target, child_ctx)?;

        // Commands inside carry child_ctx in their cache keys
        Ok(body)
    }
}
```

### Key Insight

**Context isolation** prevents cache pollution. The same operator in different contexts produces different cache entries automatically.

---

## Pattern 4: Hierarchical Type System

### The Problem

Type checking needs flexibility and safety. Too strict, and artists cannot experiment. Too loose, and runtime crashes interrupt creative flow.

### The Werkkzeug4 Approach

Types form an inheritance hierarchy with `AnyType` at the root. Type checking walks up the parent chain. Automatic conversions bridge incompatible types.

```cpp
// Type checking: walk up the inheritance chain
sBool wType::IsType(wType *type)
{
  wType *owntype = this;
  do {
    if(type == owntype) return 1;
    owntype = owntype->Parent;
  } while(owntype);
  return 0;
}

// Extended check: includes automatic conversions
sBool wType::IsTypeOrConversion(wType *type)
{
  if(IsType(type)) return 1;
  sFORALL(Doc->Conversions, cl)
    if(cl->OutputType->IsType(type) && IsType(cl->Inputs[0].Type))
      return 1;
  return 0;
}
```

### The Rust Pattern

Use traits for the hierarchy and `From`/`Into` for conversions.

```rust
/// Base trait for all node outputs
pub trait NodeOutput: Send + Sync + 'static {
    fn type_id(&self) -> TypeId;
    fn type_name(&self) -> &'static str;
}

/// Trait for outputs that can be rendered in 3D
pub trait Renderable: NodeOutput {
    fn render(&self, ctx: &RenderContext);
}

/// Trait for outputs that contain geometry
pub trait Geometry: Renderable {
    fn vertices(&self) -> &[Vertex];
    fn indices(&self) -> &[u32];
}

/// Concrete types implement relevant traits
pub struct Mesh { /* ... */ }

impl NodeOutput for Mesh {
    fn type_id(&self) -> TypeId { TypeId::of::<Mesh>() }
    fn type_name(&self) -> &'static str { "Mesh" }
}

impl Renderable for Mesh {
    fn render(&self, ctx: &RenderContext) { /* ... */ }
}

impl Geometry for Mesh {
    fn vertices(&self) -> &[Vertex] { &self.vertices }
    fn indices(&self) -> &[u32] { &self.indices }
}

/// Type-safe input requirements
pub trait Operator {
    type Input: ?Sized;
    type Output: NodeOutput;

    fn execute(&self, input: &Self::Input) -> Result<Self::Output, ExecError>;
}

/// Operator accepting any Geometry
pub struct SmoothOp { pub iterations: i32 }

impl Operator for SmoothOp {
    type Input = dyn Geometry;
    type Output = Mesh;

    fn execute(&self, input: &Self::Input) -> Result<Self::Output, ExecError> {
        // Works with Mesh, Terrain, any Geometry implementor
        let verts = input.vertices();
        // ... smooth vertices ...
        Ok(Mesh::from_vertices(smoothed))
    }
}
```

### Automatic Conversions

```rust
/// Conversion trait (like From but for node outputs)
pub trait ConvertFrom<T: NodeOutput>: NodeOutput {
    fn convert_from(value: T) -> Result<Self, ConvertError> where Self: Sized;
}

/// Texture to Material conversion
impl ConvertFrom<Texture> for Material {
    fn convert_from(tex: Texture) -> Result<Self, ConvertError> {
        Ok(Material {
            diffuse: Some(tex),
            ..Default::default()
        })
    }
}

/// Registry of available conversions
pub struct ConversionRegistry {
    conversions: HashMap<(TypeId, TypeId), Box<dyn ConvertFn>>,
}

impl ConversionRegistry {
    pub fn register<From: NodeOutput, To: ConvertFrom<From>>(&mut self) {
        let from_id = TypeId::of::<From>();
        let to_id = TypeId::of::<To>();
        self.conversions.insert(
            (from_id, to_id),
            Box::new(|input: Box<dyn NodeOutput>| {
                let concrete = input.downcast::<From>()?;
                Ok(Box::new(To::convert_from(*concrete)?) as Box<dyn NodeOutput>)
            })
        );
    }
}
```

### Key Insight

Traits provide **compile-time polymorphism** (static dispatch) while trait objects provide **runtime polymorphism** (dynamic dispatch). Choose based on whether the type set is open or closed.

---

## Pattern 5: Reference Stealing for In-Place Operations

### The Problem

Many operations transform data in place: scaling a mesh, adjusting texture colors. Creating copies wastes memory and time when the input has no other consumers.

### The Werkkzeug4 Approach

The `PASSINPUT` flag marks operators that can reuse their input. During execution, if the input has `RefCount == 1` (sole consumer), the executor steals the reference.

```cpp
if(cmd->PassInput >= 0)
{
  wObject *in = cmd->GetInput<wObject *>(cmd->PassInput);
  if(in && in->RefCount == 1)  // Only consumer
  {
    cmd->Output = in;          // Steal reference
    cmd->Inputs[cmd->PassInput]->Output = 0;  // Clear source
  }
}
```

### The Rust Pattern

Use `Arc::try_unwrap()` or pass ownership explicitly.

```rust
/// For operators that can work in-place
pub trait InPlaceOperator {
    type Data: NodeOutput;

    fn execute_in_place(&self, data: &mut Self::Data) -> Result<(), ExecError>;

    fn execute(&self, input: Arc<Self::Data>) -> Result<Arc<Self::Data>, ExecError> {
        match Arc::try_unwrap(input) {
            Ok(mut owned) => {
                // Sole owner: modify in place
                self.execute_in_place(&mut owned)?;
                Ok(Arc::new(owned))
            }
            Err(shared) => {
                // Multiple owners: clone then modify
                let mut cloned = (*shared).clone();
                self.execute_in_place(&mut cloned)?;
                Ok(Arc::new(cloned))
            }
        }
    }
}

/// Scale operator can work in-place
pub struct ScaleOp { pub factor: f32 }

impl InPlaceOperator for ScaleOp {
    type Data = Mesh;

    fn execute_in_place(&self, mesh: &mut Mesh) -> Result<(), ExecError> {
        for v in &mut mesh.vertices {
            v.position *= self.factor;
        }
        Ok(())
    }
}
```

### Alternative: Cow-based Approach

```rust
use std::borrow::Cow;

pub trait CowOperator {
    type Data: Clone + NodeOutput;

    fn execute(&self, input: Cow<Self::Data>) -> Result<Cow<Self::Data>, ExecError>;
}

impl CowOperator for ScaleOp {
    type Data = Mesh;

    fn execute(&self, input: Cow<Mesh>) -> Result<Cow<Mesh>, ExecError> {
        let mut mesh = input.into_owned();  // Clone only if borrowed
        for v in &mut mesh.vertices {
            v.position *= self.factor;
        }
        Ok(Cow::Owned(mesh))
    }
}
```

### Key Insight

**Steal when safe, copy when necessary.** The runtime checks ownership and makes the optimal choice automatically.

---

## Pattern 6: Flow Control as Operators

### The Problem

Creative tools need loops (generate 10 variations), conditionals (if parameter X, use approach A), and subroutines (reusable operator groups). Traditional node graphs lack these constructs.

### The Werkkzeug4 Approach

Flow control is implemented as special operators with compiler support.

| Operator | Purpose | Compiler Behavior |
|----------|---------|-------------------|
| `Call` | Invoke subroutine | Push context, inject inputs |
| `Loop` | Repeat with variation | Unroll into N copies |
| `Input` | Access call arguments | Reference caller's inputs |
| `ShellSwitch` | Runtime conditional | Select input based on flag |

These operators have flags (`wCF_CALL`, `wCF_LOOP`, etc.) that trigger special handling during compilation.

### The Rust Pattern

```rust
/// Flow control operators have special compilation behavior
pub enum FlowControlOp {
    Call { target: OpId, arguments: Vec<OpId> },
    Loop { count: usize, body: OpId },
    Input { index: usize },
    Switch { condition: OpId, branches: Vec<OpId> },
}

impl<'a> GraphCompiler<'a> {
    fn compile_flow_control(
        &mut self,
        op: &FlowControlOp,
        ctx: CallContext,
    ) -> Result<CompileNode<'a>, CompileError> {
        match op {
            FlowControlOp::Call { target, arguments } => {
                // Compile arguments first
                let arg_nodes: Vec<_> = arguments
                    .iter()
                    .map(|arg| self.compile(*arg, ctx))
                    .collect::<Result<_, _>>()?;

                // Push new context with arguments accessible
                let call_ctx = ctx.child(self.next_call_id());
                self.push_call_context(arg_nodes);

                // Compile subroutine body
                let body = self.compile(*target, call_ctx)?;

                self.pop_call_context();
                Ok(body)
            }

            FlowControlOp::Loop { count, body } => {
                // Unroll loop at compile time
                let mut iterations = Vec::with_capacity(*count);
                for i in 0..*count {
                    let loop_ctx = ctx.child(i as u32);
                    self.set_loop_variable(i);
                    iterations.push(self.compile(*body, loop_ctx)?);
                }
                Ok(CompileNode::Sequence(iterations))
            }

            FlowControlOp::Input { index } => {
                // Reference caller's argument
                self.get_call_argument(*index)
                    .ok_or(CompileError::InputOutsideCall)
            }

            FlowControlOp::Switch { condition, branches } => {
                // Compile all branches, select at runtime
                let cond_node = self.compile(*condition, ctx)?;
                let branch_nodes: Vec<_> = branches
                    .iter()
                    .map(|b| self.compile(*b, ctx))
                    .collect::<Result<_, _>>()?;

                Ok(CompileNode::Switch {
                    condition: Box::new(cond_node),
                    branches: branch_nodes,
                })
            }
        }
    }
}
```

### Key Insight

**Flow control looks like data flow.** Subroutines are just operators that expand inline. Loops are operators that duplicate their body. The graph stays visual and intuitive.

---

## Summary: Patterns at a Glance

| Pattern | Problem | Solution | Rust Mechanism |
|---------|---------|----------|----------------|
| Declarative Operators | Boilerplate consistency | DSL/code generation | Proc-macros |
| Two-Tier Runtime | Editor vs. execution needs | Separate data structures | Owned types, arenas |
| Context-Aware Caching | Subroutine cache pollution | Composite cache keys | `(OpId, CallContext)` |
| Hierarchical Types | Flexibility vs. safety | Inheritance + auto-conversion | Traits + `From`/`Into` |
| Reference Stealing | Unnecessary copies | Steal when sole owner | `Arc::try_unwrap()` |
| Flow as Operators | Loops, conditionals | Special compiler handling | Enum variants + match |

---

## Recommended Implementation Order

1. **Start with declarative operators.** Get the proc-macro working first. Every subsequent feature builds on this foundation.

2. **Add two-tier compilation.** Once operators exist, you can define the editor and execution data structures. Use `bumpalo` for arena allocation.

3. **Implement basic type checking.** Start without conversions. Add conversions once the basic type system works.

4. **Add caching with contexts.** The CallId pattern is simple to implement and immediately useful.

5. **Add flow control last.** Loops and subroutines are complex. Get everything else solid first.

---

## Files Referenced

| Source | Pattern |
|--------|---------|
| `werkkzeug4/operator-system.md` | Declarative operators |
| `werkkzeug4/graph-execution.md` | Two-tier runtime, caching |
| `werkkzeug4/type-system.md` | Type hierarchy, conversions |
| `code-traces/ops-to-cpp.md` | Code generation details |
| `code-traces/graph-execution.md` | Compilation pipeline |
