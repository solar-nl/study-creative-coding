# Node Graph Patterns: From Werkkzeug4 to Rust

> Six battle-tested patterns from demoscene tooling that transfer directly to modern Rust frameworks

---

## The Demoscene's Hidden Curriculum

The demoscene has spent thirty years solving problems that creative coding frameworks are only now encountering. When Farbrausch shipped "fr-041: debris" in 64 kilobytes, they were not just showing off compression techniques. They were demonstrating a mature architecture for real-time procedural content that could handle complex 3D scenes, animations, and effects while remaining responsive to artist input. Werkkzeug4, the tool behind that demo, contains patterns that transfer directly to modern frameworks.

This document extracts six patterns from Werkkzeug4's architecture. Each pattern addresses a specific problem that any node-based creative system will eventually face. The patterns are battle-tested, not theoretical. They shipped in commercial demoscene productions and survived the pressure of live performances where a crash meant public embarrassment.

Think of these patterns as the difference between amateur and professional theater. An amateur production might work through sheer enthusiasm, but a professional production has systems: costume organization, prop management, blocking notation, lighting cues. Each system seems like overhead until the show scales up. Then the systems become essential. Werkkzeug4's patterns are these systems for node-based creative tools.

The central challenge is this: node graphs are wonderfully intuitive for artists but treacherous to implement well. The visual simplicity hides computational complexity. A naive implementation works for ten nodes but collapses at a hundred. Caching seems straightforward until subroutines share operators across different call contexts. Type checking seems obvious until artists demand the flexibility to wire anything to anything without explicit conversions cluttering their graphs.

Farbrausch solved these problems. The solutions are not obvious, but they are elegant. And they translate surprisingly well to Rust.

---

## The Theatrical Production Analogy

Imagine you are staging a play. The process divides naturally into two phases that have fundamentally different needs.

**Rehearsal** is collaborative and iterative. Actors experiment with line readings. The director adjusts blocking. Someone realizes scene three needs a different prop. Changes happen constantly, and the system must accommodate them without disrupting the creative flow. Nobody expects polish during rehearsal. What matters is flexibility.

**Performance** is a different world entirely. Every actor knows their marks. Every lighting cue fires at the right moment. The stage manager has transformed the director's notes into a precise sequence of instructions. Changes are not welcome. What matters is execution speed and reliability.

Werkkzeug4 works exactly like this. The editor is rehearsal: a graph of operators that artists manipulate freely. Execution is performance: a compiled sequence of commands that the runtime blasts through without interpretation. A compilation step transforms one into the other, just as a production transforms rehearsal notes into a show.

This analogy will guide us through each pattern. We will see how Werkkzeug4 handles scripts (declarative operator definitions), how it separates rehearsal from performance (two-tier runtime), how it manages props that appear in multiple scenes (context-aware caching), how it handles costume changes (type conversions), how it avoids unnecessary copying (reference stealing), and how it structures complex choreography (flow control as operators).

---

## Pattern 1: The Script — Declarative Operator Definitions

Every theatrical production starts with a script. The script declares what exists: characters, their attributes, their lines. Directors and actors build from this foundation, but they do not reinvent the characters from scratch. The script is the single source of truth.

Werkkzeug4's operators need the same single source of truth. Each operator requires parameter storage, GUI widgets, serialization code, default values, and execution logic. Writing this by hand for hundreds of operators creates maintenance nightmares. A parameter name changes in the struct but not in the GUI code. A default value updates in one place but not another. The inconsistencies accumulate until the codebase becomes hostile to change.

The solution is a domain-specific language that declares operators once. A code generator produces all the boilerplate from that single declaration. Change the declaration, and all dependent code updates automatically.

Here is what a complete operator declaration looks like in Werkkzeug4's `.ops` format. Notice how fifteen lines capture everything the system needs to know about a torus mesh generator.

```c
operator Wz4Mesh Torus()
{
  shortcut = 'o';
  parameter
  {
    int Slices(3..4096)=12;
    float InnerRadius(0..1024 step 0.01)=0.25;
    float OuterRadius(0..1024 step 0.01)=1;
  }
  code
  {
    out->MakeTorus(para->Slices, para->OuterRadius, para->InnerRadius);
  }
}
```

From this declaration, the `wz4ops` code generator produces a parameter struct, a GUI function emitting sliders with the correct ranges, an initialization function setting the defaults, and registration code adding the operator to the editor's palette. One declaration, five outputs, perfect consistency.

In Rust, procedural macros achieve the same automation without external code generators. The declaration becomes a struct with attributes, and the macro generates all supporting code at compile time.

```rust
#[derive(Operator)]
#[operator(name = "Torus", category = "Mesh/Primitives", shortcut = 'o')]
pub struct TorusOp {
    #[param(range = 3..=4096, default = 12)]
    pub slices: i32,

    #[param(range = 0.0..=1024.0, step = 0.01, default = 0.25)]
    pub inner_radius: f32,
}

impl Execute for TorusOp {
    type Output = Mesh;
    fn execute(&self, _ctx: &Context) -> Result<Self::Output> {
        Ok(Mesh::torus(self.slices, self.inner_radius, 1.0))
    }
}
```

The `#[derive(Operator)]` macro becomes the script's stage manager, generating `impl Default` with specified defaults, `impl Gui` for editor widgets, `impl Serialize` for project files, and registration with the operator registry. The single source of truth principle transfers directly.

**Key takeaway:** Treat operator definitions as declarative scripts. Generate all boilerplate from a single source. This eliminates drift between GUI, serialization, and execution code.

---

## Pattern 2: Rehearsal vs. Performance — Two-Tier Runtime

In theater, no one expects the rehearsal room to function like the stage. Rehearsals need interruptions, discussions, the ability to stop mid-scene and try something different. Performances need uninterrupted flow from curtain to curtain. Optimizing for both simultaneously is impossible.

Werkkzeug4 faces the same dilemma. The editor needs flexibility: undo and redo, rich metadata for display, the ability to select and manipulate operators interactively. The executor needs speed: linear memory access, minimal branching, no graph traversal during rendering. These requirements conflict.

The solution splits the runtime into two tiers, each with data structures optimized for its purpose. The editor tier stores operators as a pointer-based graph with full metadata. The execution tier stores commands as a flat array with copied parameters. A compilation step transforms one into the other.

| Concern | Rehearsal (Editor) | Performance (Executor) |
|---------|-------------------|----------------------|
| Structure | Pointer-based graph | Flat array |
| Parameters | Shared with GUI, live-editable | Copied snapshot, immutable |
| Metadata | Full: name, position, selection state | None |
| Lifetime | Persistent across sessions | Per-calculation |

The compilation step functions like a stage manager writing the show's run sheet. Walking through the director's notes (the operator graph), the stage manager resolves all cross-references and produces a linear sequence of instructions (the command buffer). During performance, technicians execute the run sheet without consulting the director's notes.

This separation enables a powerful workflow. Artists can tweak parameters in the editor while the current frame renders. The tweaks only take effect on the next compilation. No race conditions, no synchronization complexity.

The Rust translation makes ownership explicit. The editor owns the graph; compilation transfers parameter data into an arena-allocated command buffer; execution consumes commands and produces results.

```rust
pub struct CommandBuffer<'a> {
    commands: Vec<Command<'a>>,
    arena: &'a bumpalo::Bump,  // Owns all parameter data
}

impl<'a> CommandBuffer<'a> {
    pub fn execute(&self, ctx: &mut ExecContext) -> Result<Arc<dyn Object>> {
        let mut outputs: Vec<Option<Arc<dyn Object>>> = vec![None; self.commands.len()];
        for (i, cmd) in self.commands.iter().enumerate() {
            let inputs: Vec<_> = cmd.input_indices.iter()
                .map(|&idx| outputs[idx].as_ref().unwrap().clone())
                .collect();
            outputs[i] = Some((cmd.execute)(&inputs, cmd.params)?);
        }
        outputs.pop().flatten().ok_or(ExecError::NoOutput)
    }
}
```

**Key takeaway:** Separate data structures for editing and execution. Copy parameters at compilation time. This decouples the editor's flexibility from the executor's performance requirements.

---

## Pattern 3: The Props Table — Context-Aware Caching

In a play with multiple scenes, the props table tracks which items appear where. A wine glass might appear in both Act 1 and Act 3, but these are different wine glasses prepared for different contexts. Grabbing the Act 1 glass during Act 3 would be wrong, even though both entries in the props table say "wine glass."

Naive caching in node graphs makes exactly this mistake. The cache uses operator identity as the key: "I computed this Blur operator before, so I will reuse the result." But what if the same Blur appears inside a subroutine called twice with different inputs? The first call blurs the background; the second call should blur the foreground. Returning the cached background blur for the foreground produces garbage.

Werkkzeug4 solves this with context-aware cache keys. Each compilation context receives a unique identifier called a `CallId`. Cache lookups require matching both the operator identity AND the context identifier. The same operator in different subroutine calls produces different cache entries.

Think of it as labeling the props: "wine glass (Act 1, Scene 2)" versus "wine glass (Act 3, Scene 1)." The label includes context, not just identity.

```cpp
// Werkkzeug4's cache check includes context
if(op->Cache && op->Cache->CallId == node->CallId)
{
    // Cache hit: same operator AND same context
}
```

When the compiler enters a subroutine, it mints a new CallId. All operators compiled within that subroutine carry the new identifier in their cache keys. Loop iterations work the same way: each iteration gets its own context.

The Rust translation uses composite cache keys.

```rust
#[derive(Hash, Eq, PartialEq, Clone, Copy)]
pub struct CacheKey {
    pub op_id: OpId,
    pub call_context: u32,
}

impl CallContext {
    pub fn child(&self, index: u32) -> Self {
        Self(self.0.wrapping_add(index + 1))
    }
}
```

During compilation, entering a subroutine or loop iteration calls `child()` to derive a new context. Cache lookups and stores use the composite key. Context isolation happens automatically without operators needing awareness of their call stack.

**Key takeaway:** Cache keys must include context, not just identity. The same operator in different subroutine calls or loop iterations needs separate cache entries.

---

## Pattern 4: Quick Changes — Hierarchical Types with Automatic Conversions

Theater productions often need quick costume changes. An actor exits stage left in one outfit and enters stage right in another. The wardrobe team does not rebuild the costume from scratch. They prepare conversion pieces: a jacket that transforms the silhouette, a hat that changes the period.

Type systems in node graphs face similar demands. Artists want to wire a texture output to a material input without inserting explicit conversion nodes. The graph should stay clean while the system handles the wardrobe changes automatically.

Werkkzeug4's type system enables this through two mechanisms. First, types form an inheritance hierarchy. An operator accepting "any RenderNode" automatically accepts meshes, particle systems, and scenes because they all inherit from RenderNode. Second, the system maintains a catalog of conversion operators. When a connection fails the inheritance check, the system searches for a converter that bridges the gap. Finding one, it inserts the conversion automatically.

The type check walks up the inheritance chain first, then searches conversions.

```cpp
sBool wType::IsTypeOrConversion(wType *target)
{
  if(IsType(target)) return 1;  // Direct or inherited match
  sFORALL(Doc->Conversions, conv)
    if(conv->OutputType->IsType(target) && IsType(conv->Inputs[0].Type))
      return 1;  // Conversion available
  return 0;
}
```

The Rust translation uses traits for the hierarchy and `From`/`Into` implementations for conversions. The compiler can verify much of this statically.

```rust
pub trait Renderable: NodeOutput {
    fn render(&self, ctx: &RenderContext);
}

// Any Renderable can be rendered, enabling polymorphic operators
impl<T: Renderable> Operator for RenderOp<T> {
    type Input = T;
    type Output = Frame;
}

// Automatic conversion via standard traits
impl From<Texture> for Material {
    fn from(tex: Texture) -> Self {
        Material { diffuse: Some(tex), ..Default::default() }
    }
}
```

The trait hierarchy provides compile-time polymorphism. Conversion implementations provide compile-time or runtime bridging. Artists experience maximum flexibility while the system catches genuine type errors before expensive rendering begins.

**Key takeaway:** Types should form a hierarchy enabling polymorphic operators. Automatic conversions should bridge common gaps. Check types early, during graph compilation, not during rendering.

---

## Pattern 5: Prop Reuse — Reference Stealing for In-Place Operations

Experienced stage crews know which props can be reused between scenes and which need duplicates. If a letter gets torn up in Act 2, you need a fresh letter for each performance. But if a chair just sits there, one chair serves all performances.

Many node operations transform data in place: scaling a mesh, adjusting texture brightness, applying a filter. Creating copies wastes memory when the input has no other consumers. If an operator is the sole consumer of its input, transforming in place is both safe and efficient.

Werkkzeug4 marks operators that can work in place with a `PASSINPUT` flag. During execution, the runtime checks whether the input has exactly one reference (meaning this command is the sole consumer). If so, it steals the reference rather than copying.

```cpp
if(cmd->PassInput >= 0)
{
  wObject *in = cmd->GetInput(cmd->PassInput);
  if(in && in->RefCount == 1)    // Sole consumer
  {
    cmd->Output = in;             // Steal reference
    cmd->Inputs[cmd->PassInput]->Output = 0;  // Clear source
  }
}
```

Rust's ownership system makes this pattern explicit through `Arc::try_unwrap()`. When the Arc's strong count equals one, unwrapping succeeds and yields owned data. Otherwise, you clone.

```rust
pub fn execute_maybe_in_place(
    &self,
    input: Arc<Mesh>
) -> Result<Arc<Mesh>> {
    match Arc::try_unwrap(input) {
        Ok(mut owned) => {
            // Sole owner: modify in place
            self.transform_in_place(&mut owned);
            Ok(Arc::new(owned))
        }
        Err(shared) => {
            // Multiple owners: clone first
            let mut cloned = (*shared).clone();
            self.transform_in_place(&mut cloned);
            Ok(Arc::new(cloned))
        }
    }
}
```

The decision happens automatically at runtime. Chains of in-place transformations avoid allocation entirely when each operator consumes its predecessor's output exclusively.

**Key takeaway:** Steal references when safe, copy when necessary. Let the runtime check ownership and make the optimal choice automatically.

---

## Pattern 6: Complex Choreography — Flow Control as Operators

Ambitious plays have complex choreography. A dance number might repeat with variations. A scene might fork based on audience participation. The notation system must handle these structures while remaining visual and intuitive.

Traditional node graphs lack loops and conditionals. Artists wanting ten variations must copy-paste ten times. Artists wanting conditional behavior must build parallel paths. This clutters the graph with redundancy.

Werkkzeug4 implements flow control as special operators that the compiler handles differently. A Loop operator does not execute during runtime. Instead, the compiler unrolls it into N copies of its body, each with a unique context identifier. The visual graph stays clean while the compiled commands contain the expanded structure.

| Flow Operator | Visual Graph | Compiled Commands |
|--------------|--------------|-------------------|
| Loop(5) | Single body | Five copies with different contexts |
| Call | Reference to subroutine | Inline expansion with injected inputs |
| Switch | Multiple branches | All branches compiled, runtime selection |

This approach treats control flow as data flow. A loop is an operator that takes a body and produces multiple results. A subroutine call is an operator that takes arguments and expands inline. The graph paradigm extends rather than breaks.

```rust
fn compile_loop(&mut self, count: usize, body: OpId, ctx: CallContext)
    -> Result<Vec<CompileNode>>
{
    (0..count).map(|i| {
        let loop_ctx = ctx.child(i as u32);
        self.set_loop_variable(i);
        self.compile(body, loop_ctx)
    }).collect()
}
```

The loop counter becomes a variable accessible to operators within the body. Each iteration compiles with its own context, enabling independent caching. The executor sees only flat commands, never loops.

**Key takeaway:** Implement flow control as special operators with compiler support. Unroll at compile time. Keep the visual graph simple while the compiled structure handles complexity.

---

## Implementation Order

These patterns have dependencies. Implementing them in the wrong order creates rework.

1. **Start with declarative operators.** The proc-macro foundation supports everything else. Get `#[derive(Operator)]` working first.

2. **Add two-tier compilation.** Define editor and execution data structures. Use `bumpalo` for arena allocation of command buffers.

3. **Implement basic type checking.** Start with exact type matches. Add inheritance checking. Add conversions last.

4. **Add context-aware caching.** The CallId pattern is simple to implement and immediately useful for subroutine support.

5. **Add reference stealing.** This optimization matters once graphs reach meaningful complexity. It requires the type system to track mutability.

6. **Add flow control last.** Loops and subroutines are the most complex patterns. Get everything else solid first.

---

## Summary

| Pattern | Problem | Solution | Rust Mechanism |
|---------|---------|----------|----------------|
| Declarative Operators | Boilerplate drift | Single-source DSL/codegen | Proc-macros |
| Two-Tier Runtime | Editor vs. executor needs | Separate data structures | Owned types, arenas |
| Context-Aware Caching | Subroutine cache pollution | Composite cache keys | `(OpId, CallContext)` |
| Hierarchical Types | Flexibility vs. safety | Inheritance + auto-conversion | Traits + `From`/`Into` |
| Reference Stealing | Unnecessary copies | Steal when sole owner | `Arc::try_unwrap()` |
| Flow as Operators | Loops and conditionals | Compiler-expanded operators | Enum variants + match |

---

## Related Documents

| Source | Patterns Covered |
|--------|-----------------|
| `werkkzeug4/operator-system.md` | Declarative operators |
| `werkkzeug4/graph-execution.md` | Two-tier runtime, caching |
| `werkkzeug4/type-system.md` | Type hierarchy, conversions |
| `../../themes/api-ergonomics.md` | Builder patterns, method chaining |
| `../../../insights/rust-specific.md` | `Arc`, ownership, trait design |
