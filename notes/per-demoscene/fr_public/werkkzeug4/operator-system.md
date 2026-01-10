# The Operator System: Werkkzeug4's DSL-to-C++ Code Generation

> How a 20-line declaration becomes 200 lines of boilerplate-free C++

---

## The Problem: Death by a Thousand Parameters

Visual programming tools live or die by their operators. A node-based system for creating 3D meshes, textures, and animations might have hundreds of operators, each needing the same infrastructure: parameter definitions, GUI widgets, serialization, default values, and the actual logic. The naive approach writes all of this by hand for every operator.

Consider what a simple "Torus" mesh generator actually requires. You need a struct to hold six parameters: slices, segments, inner radius, outer radius, phase, and arc. You need GUI code that creates the right widget for each parameter type, with correct ranges and step sizes. You need initialization code that sets sensible defaults. You need the execution function that calls the mesh generation. You need registration code so the editor knows this operator exists. And if you want animation support, you need bindings that let scripts access each parameter by name.

That is six separate concerns for one operator. Now multiply by the hundred-plus operators in Werkkzeug4. Any change to the GUI system requires touching every operator file. Any typo in a parameter name creates subtle bugs where the GUI shows "InnerRadius" but the code accesses "innerRadius". The maintenance burden becomes crushing.

Farbrausch solved this with a domain-specific language. Instead of writing hundreds of lines of C++ per operator, you write a compact `.ops` declaration. A code generator transforms this into all the boilerplate C++ automatically. The DSL becomes the single source of truth.

---

## The Mental Model: A Government Office That Never Makes Mistakes

Think of the `.ops` file as a form you fill out once at a government office. You write down what you need: "I want an integer parameter named Slices with range 3 to 4096 and default 12." Then you hand this form to a tireless clerk named `wz4ops`.

This clerk is remarkably diligent. From your single form, the clerk produces five different documents that various departments need:

1. **The Parameter Registry** (a C++ struct) - The accounting department needs to know exactly how much memory your operator requires and what fields it contains.

2. **The Execution Permit** (the Cmd function) - The operations department needs instructions for actually running your operator when the time comes.

3. **The Public Interface Form** (the Gui function) - The front desk needs to know what widgets to display when a citizen wants to adjust your operator's parameters.

4. **The Default Values Certificate** (the Def function) - New operators need to start with sensible values; this document specifies them.

5. **The Business License** (registration code) - The central directory needs to know your operator exists, what shortcut key summons it, and which category it belongs to.

Here is the beautiful part: all five documents use the exact same names, the exact same ranges, the exact same defaults. The clerk copies from your original form with perfect fidelity. Change the form once, and all five documents update automatically. No more hunting through three files to rename a parameter. No more subtle mismatches between what the GUI displays and what the code expects.

The clerk's output is not mysterious machine-generated gibberish. It is clean, readable C++ that you could debug if needed. The DSL simply automates the repetitive copying while you write the interesting logic yourself.

---

## Filling Out the Form

A Torus operator declaration fills about 15 lines on the form. Let me walk through each section, because understanding the form is understanding the entire system.

```c
operator Wz4Mesh Torus()
{
  column = 0;
  shortcut = 'o';
  parameter
  {
    int Slices(3..4096)=12;
    int Segments(3..4096)=8;
    float InnerRadius(0..1024 logstep 0.01)=0.25;
    float OuterRadius(0..1024 logstep 0.01)=1;
    float Phase(-4..4 step 0.001);
    float Arc(0..1 step 0.001)=1;
  }
  code
  {
    out->MakeTorus(para->Slices,para->Segments,
                   para->OuterRadius,para->InnerRadius,
                   para->Phase,para->Arc,0);
  }
}
```

The first line declares the operator's identity. `Wz4Mesh` tells the clerk what type of object this operator produces - in bureaucratic terms, which department handles the output. `Torus` is the operator's name, used for menus, registration, and generated function names. The empty parentheses after `Torus` indicate this operator has no inputs; it generates a mesh from nothing.

The `column` and `shortcut` lines fill in metadata fields. When the editor builds its operator palette, `column = 0` places Torus in the first column of mesh generators. When the user presses 'o' with a mesh tab selected, Werkkzeug4 creates a Torus node.

The `parameter` block is the heart of the form. Each line declares one parameter with its type, valid range, step size for UI drag operations, and default value. The clerk extracts all this information to generate the struct fields, GUI widgets, and initialization code. Notice `logstep` on the radius parameters - this tells the GUI to use logarithmic scaling for drag operations, making it easier to adjust both tiny (0.01) and large (100) values.

The `code` block contains your actual implementation. Here you write C++ that does the real work. The clerk wraps this in boilerplate that provides `para` (a pointer to your parameter struct) and `out` (the output object to populate). You never write the casting or null-checking; the clerk handles that ceremony.

---

## Let's Trace What Happens When the Clerk Processes This Form

When you run `wz4ops wz4_mesh_ops.ops`, the clerk reads your form and begins generating documents. Let me trace exactly what emerges for our Torus operator.

### Document 1: The Parameter Registry

The accounting department needs to know the memory layout. The clerk produces a struct in the header file with one field per parameter. The struct name follows a predictable pattern: `{OutputType}Para{OperatorName}`.

```cpp
struct Wz4MeshParaTorus
{
  sInt Slices;
  sInt Segments;
  sF32 InnerRadius;
  sF32 OuterRadius;
  sF32 Phase;
  sF32 Arc;
};
```

This struct is a plain-old-data type with no methods. The clerk maps DSL types to C types: `int` becomes `sInt`, `float` becomes `sF32`. For vector types like `float31` (a 3D position), the clerk would emit `sVector31`. The field names match your parameter names exactly - this matters because the `code` block accesses them through `para->Slices`.

Why does this predictability matter? Because at runtime, the executor casts raw memory to this struct type. The struct layout must match what the executor expects. By generating both the struct and the code that uses it from the same source, the clerk guarantees they stay synchronized.

### Document 2: The Execution Permit

The operations department receives a function that knows how to run your operator. The clerk wraps your `code` block in boilerplate that handles all the ceremony.

```cpp
sBool Wz4MeshCmdTorus(wExecutive *exe, wCommand *cmd)
{
  Wz4MeshParaTorus *para = (Wz4MeshParaTorus *)(cmd->Data);
  Wz4Mesh *out = (Wz4Mesh *) cmd->Output;
  if(!out) { out = new Wz4Mesh; cmd->Output = out; }

  // Your code block, inserted verbatim:
  out->MakeTorus(para->Slices, para->Segments,
                 para->OuterRadius, para->InnerRadius,
                 para->Phase, para->Arc, 0);

  return 1;
}
```

The first line casts `cmd->Data` to your parameter struct. Commands store parameter data as raw bytes; this cast interprets those bytes as your struct. The next lines handle output allocation - if no output exists, create one. Then your code runs, accessing `para` and `out` as if by magic. Finally, the function returns success.

If your operator had inputs (declared in the parentheses after the name), the clerk would generate additional lines to retrieve them: `Wz4Mesh *in0 = cmd->GetInput<Wz4Mesh *>(0);`. Optional inputs get null checks. The clerk knows all this from your form.

### Documents 3, 4, and 5: The Supporting Cast

The clerk generates three more functions following the same pattern. The Gui function creates a slider for each parameter, using the ranges and step sizes from your form. The Def function writes default values into a fresh operator's memory. The registration code creates a `wClass` object, wires up all four function pointers, and adds it to the document's class list.

I will spare you the full code for these - they follow the pattern you have already seen. The key insight is that all five documents derive from your single form. The clerk ensures perfect consistency across all of them.

---

## The Clerk's Internal Process

How does the `wz4ops` tool actually work? It follows a classic compiler architecture: scan, parse, generate.

**Scanning** tokenizes the `.ops` file. The scanner recognizes keywords like `operator`, `parameter`, `code`, and the DSL's special syntax like range specifications `(3..4096)` and modifiers like `logstep`. Every token carries position information so error messages can point to the right line.

**Parsing** builds an abstract syntax tree from tokens. Each `operator` block becomes an `Op` object containing arrays of `Parameter` objects, `Input` objects, and `CodeBlock` objects. The parser calculates memory offsets for parameters as it goes - Slices at offset 0, Segments at offset 1, InnerRadius at offset 2, and so on. This ensures the struct layout is deterministic.

**Generation** walks the AST and emits C++ to string buffers. One buffer accumulates the header file (structs, function declarations), another accumulates the implementation file (function bodies, registration). The clerk visits each operator in turn, emitting all five documents for each. Finally, the tool writes both files to disk.

The generated files are checked into source control and compiled normally. They are not hidden intermediates - you can read them, debug into them, and understand exactly what the clerk produced.

---

## Advanced Features: When Simple Forms Are Not Enough

The basic form handles most operators, but some need special handling. The clerk understands several extensions.

### Explicit Memory Layout

Sometimes you need exact control over the parameter struct layout, perhaps for binary compatibility with GPU constant buffers. You can specify word offsets explicitly.

```c
parameter
{
  float31 Scale:0 (-1024..1024 step 0.01) = 1;
  float30 Rotate:3 (-16..16 step 0.01) = 0;
  float31 Translate:6 (-65536..65536 step 0.01) = 0;
}
```

The `:0`, `:3`, `:6` after each name specify word offsets. `float31` occupies three words (x, y, z), so Scale sits at offset 0-2, Rotate at 3-5, Translate at 6-8. The clerk inserts padding as needed to achieve this layout. This is valuable when operators share parameter memory with shader uniform buffers.

### Conditional Parameters

The GUI can show or hide parameters based on other parameter values. Imagine a camera operator that offers both "orbit" and "target" modes. In orbit mode, you adjust rotation angles. In target mode, you specify a look-at point.

```c
parameter
{
  flags Mode ("orbit|target") = 0;
  if((Mode & 15) == 1)
    float31 Target (-1024..1024 step 0.01);
}
```

The clerk parses the condition, builds an expression tree, and generates C++ conditionals around the widget code. The Target parameter exists in the struct regardless, but only appears in the GUI when the condition holds. Users see a clean interface that adapts to their chosen mode.

### Typed Inputs

Input declarations specify type constraints and optionality. The parentheses after an operator name list what inputs the operator accepts.

```c
operator Wz4Mesh Transform(Wz4Mesh, ?Wz4Skeleton)
```

`Wz4Mesh` is a required input - the operator will not run without it. `?Wz4Skeleton` is optional - the skeleton enhances the transform but is not mandatory. The clerk generates appropriate null checks for optional inputs. Other modifiers include `*` for variadic inputs (accepting multiple connections) and `~` for weak references that do not force evaluation.

---

## Why This Architecture Works

### Single Source of Truth

The DSL declaration is the canonical definition of your operator. Change a parameter name in one place, and it propagates to the struct, GUI, serialization, and script bindings automatically. This eliminates the entire class of bugs where names drift out of sync across files.

### Separation of Concerns

You write the interesting logic (how to generate a torus from parameters). The clerk writes the boring infrastructure (GUI widgets, type casting, registration). Neither pollutes the other. Your code block focuses on mesh generation; it never mentions sliders or default values.

### Debuggable Output

The generated C++ is clean and readable. The clerk emits `#line` directives so debugger breakpoints in user code map back to the `.ops` file. You can step through generated code and understand what is happening. When something breaks, you are not fighting opaque machine output.

### Extensibility

Adding a new parameter type requires adding a case to the parser and a case to the generator. All existing operators automatically benefit from the new capability. This is far easier than updating hundreds of operator files by hand.

---

## Implications for a Rust Framework

The core insight transfers directly: declarative operator definitions with code generation eliminate boilerplate while maintaining type safety. Rust's procedural macros offer a more integrated approach than external code generators.

### The Rust Equivalent

Where Werkkzeug4 uses an external tool reading `.ops` files, Rust can achieve the same result with derive macros. The developer writes a struct with attributes, and the macro generates all the supporting code at compile time.

```rust
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

    fn execute(&self, _ctx: &Context) -> Result<Self::Output> {
        Ok(Mesh::torus(self.slices, self.inner_radius, self.outer_radius))
    }
}
```

The `#[derive(Operator)]` macro becomes the tireless clerk, generating `impl Default` with the specified defaults, `impl Gui` emitting egui widgets, `impl Serialize + Deserialize` for save/load, and registration with the operator registry. The single source of truth is the struct definition with its attributes.

### What to Adopt

**Declarative parameter definitions.** The attribute-based approach captures the same information as the DSL. Range, step, default, and semantic hints all become attributes on struct fields.

**Compile-time code generation.** Proc-macros integrate with the Rust toolchain. Error messages point to your source code, not generated files. IDE features like autocompletion work naturally because the compiler understands everything.

**Type-safe inputs.** Rust's type system enforces input constraints at compile time. An operator that requires a `Mesh` input cannot accidentally receive a `Texture`. The type system catches these errors before runtime.

### What to Change

**Replace runtime registration with static dispatch.** The `Doc->Classes.AddTail(cl)` pattern uses runtime registration and global state. Rust can do better with the `inventory` or `linkme` crates for static registration, or simply with traits and generic dispatch.

**Replace string type names with actual types.** The `.ops` system uses string comparisons (`L"Wz4Mesh"`) for type checking at runtime. Rust's generics and trait bounds provide this statically, catching errors at compile time.

**Replace global document with explicit context.** The global `Doc` pointer is convenient but not thread-safe. Rust's ownership system encourages explicit context passing, which also makes testing easier and enables parallel execution.

### What to Avoid

**External code generators.** Keeping generated files in sync with source files is fragile. If someone edits the generated file directly, chaos ensues. Proc-macros generate code at compile time within the compiler's own process, eliminating the synchronization problem entirely.

**Manual memory layout.** The explicit offset syntax exists because C++ lacks reflection and has complex struct layout rules. Rust's `#[repr(C)]` provides predictable layout, and `std::mem::offset_of!` handles layout concerns safely when needed.

---

## Further Reading

- [Graph Execution](./graph-execution.md) for how wOp graphs become wCommand sequences
- [Type System](./type-system.md) for type hierarchy and automatic conversions
- [Code trace: .ops to C++](../code-traces/ops-to-cpp.md) for line-by-line source analysis
- [ryg's Breakpoint 2007 talk on metaprogramming](https://fgiesen.wordpress.com/2012/04/08/metaprogramming-for-madmen/) for the philosophy behind the approach
