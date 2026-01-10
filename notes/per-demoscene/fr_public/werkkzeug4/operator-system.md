# The Operator System: Werkkzeug4's DSL-to-C++ Code Generation

> How a 20-line declaration becomes 200 lines of boilerplate-free C++

---

## The Problem: Death by a Thousand Parameters

Visual programming tools live or die by their operators. A node-based system for creating 3D meshes, textures, and animations might have hundreds of operators, each needing the same infrastructure: parameter definitions, GUI widgets, serialization, default values, and the actual logic. The naive approach is to write all of this by hand for every operator.

Consider what a simple "Torus" mesh generator actually requires. You need a struct to hold the six parameters (slices, segments, radii, phase, arc). You need GUI code that creates the right widget for each parameter type, with correct ranges and step sizes. You need initialization code that sets sensible defaults. You need the execution function that calls the mesh generation. You need registration code so the editor knows this operator exists. And if you want animation support, you need bindings that let scripts access each parameter by name.

That is six separate concerns for one operator. Now multiply by the hundred-plus operators in Werkkzeug4. Any change to the GUI system requires touching every operator file. Any typo in a parameter name creates subtle bugs where the GUI shows "InnerRadius" but the code accesses "innerRadius". The maintenance burden becomes crushing.

Farbrausch solved this with a domain-specific language. Instead of writing hundreds of lines of C++ per operator, you write a compact `.ops` declaration. A code generator transforms this into all the boilerplate C++ automatically. The DSL becomes the single source of truth.

---

## The Mental Model: A Factory That Stamps Out Bureaucracy

Think of `.ops` files as forms that you fill out once. The code generator is a tireless clerk who takes your form and produces all the paperwork that the C++ compiler actually needs. You specify "I want an integer parameter named Slices with range 3 to 4096 and default 12." The clerk produces the struct field, the GUI widget code, the default initialization, and the script binding, all perfectly consistent because they come from the same source.

This is not code generation in the scary sense of outputting incomprehensible machine-generated code. The generated C++ is clean, readable, and debuggable. The DSL simply automates the repetitive parts while you write the interesting logic yourself.

The flow looks like this:

```
.ops declaration  -->  wz4ops tool  -->  .hpp + .cpp files  -->  Compiled into editor
```

The `wz4ops` tool reads your declaration, parses it into an abstract syntax tree, then walks that tree to emit C++ code for each concern. The generated files are checked into source control and compiled normally.

---

## What the DSL Looks Like

A Torus operator declaration fits in about 15 lines.

```c
// From wz4_mesh_ops.ops
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

The declaration packs a lot of information: `Wz4Mesh` is the output type. `Torus` is the name. The parentheses after the name would list input types if this operator had any. The `parameter` block defines six parameters with their types, valid ranges, step sizes, and defaults. The `code` block contains the actual implementation, with `para` and `out` as magic variables that the code generator provides.

This compact definition generates approximately 200 lines of C++ across four functions plus a struct. Let us trace what each piece becomes.

---

## What Gets Generated

### The Parameter Struct

Each operator gets a POD struct holding its parameters. The DSL types map to C types: `int` becomes `sInt`, `float` becomes `sF32`, and specialized types like `float31` (3D position) become `sVector31`. The code generator emits this struct definition.

```cpp
// Generated in .hpp file
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

The struct name follows a consistent pattern: `{OutputType}Para{OperatorName}`. This predictability matters because the execution code casts raw memory to this struct type.

### The Command Execution Function

The `code` block gets wrapped in a function that handles all the ceremony: casting the parameter data, retrieving inputs, allocating output if needed.

```cpp
// Generated in .cpp file
sBool Wz4MeshCmdTorus(wExecutive *exe, wCommand *cmd)
{
  Wz4MeshParaTorus *para = (Wz4MeshParaTorus *)(cmd->Data);
  Wz4Mesh *out = (Wz4Mesh *) cmd->Output;
  if(!out) { out = new Wz4Mesh; cmd->Output = out; }

  // User code from the 'code' block, inserted verbatim
  out->MakeTorus(para->Slices, para->Segments,
                 para->OuterRadius, para->InnerRadius,
                 para->Phase, para->Arc, 0);

  return 1;
}
```

Notice how the user never writes the casting or null-checking. The DSL handles the plumbing. The user code accesses `para->Slices` naturally because the generated wrapper provides that variable.

### The GUI Function

Each parameter type maps to an appropriate widget. Integers and floats get sliders with the specified range. Flags get checkbox groups. Colors get color pickers. The generator emits the calls.

```cpp
// Generated in .cpp file
void Wz4MeshGuiTorus(wGridFrameHelper &gh, wOp *op)
{
  Wz4MeshParaTorus *para = (Wz4MeshParaTorus *)op->EditData;

  gh.Label(L"Slices");
  sIntControl *int_Slices = gh.Int(&para->Slices, 3, 4096, 1.0);
  int_Slices->Default = 12;

  gh.Label(L"Segments");
  sIntControl *int_Segments = gh.Int(&para->Segments, 3, 4096, 1.0);
  int_Segments->Default = 8;

  gh.Label(L"InnerRadius");
  sFloatControl *float_InnerRadius = gh.Float(&para->InnerRadius, 0.0, 1024.0, 0.01);
  float_InnerRadius->Default = 0.25;

  // ... remaining parameters
}
```

The parameter names in the DSL become both the struct field names and the GUI labels. Change the name in one place, it changes everywhere.

### The Registration Function

At startup, each operator must register itself with the document system. The generator emits a function that creates class descriptors and wires up all the function pointers.

```cpp
// Generated in .cpp file
void AddOps_wz4_mesh_ops(sBool secondary)
{
  sVERIFY(Doc);
  wClass *cl = 0;

  cl = new wClass;
  cl->Name = L"Torus";
  cl->Label = L"Torus";
  cl->OutputType = Wz4MeshType;
  cl->Command = Wz4MeshCmdTorus;
  cl->MakeGui = Wz4MeshGuiTorus;
  cl->SetDefaults = Wz4MeshDefTorus;
  cl->BindPara = Wz4MeshBindTorus;
  cl->Shortcut = 'o';
  cl->Column = 0;
  Doc->Classes.AddTail(cl);

  // ... more operators
}
```

The registration connects everything: the name for the menu, the shortcut key, and all the generated functions.

---

## The Generation Pipeline

The `wz4ops` tool follows a classic compiler architecture: scan, parse, generate.

**Step 1: Scanning.** The scanner tokenizes the `.ops` file, recognizing keywords like `operator`, `parameter`, `code`, `if`, and `else`. It handles the DSL's custom syntax like range specifications `(3..4096)` and type modifiers like `logstep`.

**Step 2: Parsing.** The parser builds an AST from tokens. Each `operator` block becomes an `Op` object containing arrays of `Parameter` objects, `Input` objects, and `CodeBlock` objects. The parser calculates memory offsets for parameters as it goes, ensuring the struct layout is deterministic.

**Step 3: Generation.** The generator walks the AST and emits C++ to string buffers. One buffer accumulates the header file (structs, function declarations), another accumulates the implementation file (function bodies, registration). Finally, the tool writes both files to disk.

The data flow diagram captures this:

```
                    .ops File Input
                          |
                          v
    +-----------------------------------------+
    |              Scanner                    |
    |   Tokenizes keywords, symbols, braces   |
    +-----------------------------------------+
                          |
                          v
    +-----------------------------------------+
    |               Parser                    |
    |   _Global -> _Operator -> _Parameter    |
    +-----------------------------------------+
                          |
                          v
    +-----------------------------------------+
    |            AST Structures               |
    |   Document { Types[], Ops[], Codes[] }  |
    |   Op { Parameters[], Inputs[], Code }   |
    +-----------------------------------------+
                          |
                          v
    +-----------------------------------------+
    |           Code Generator                |
    |   OutputTypes -> OutputOps ->           |
    |   OutputAnim -> OutputMain              |
    +-----------------------------------------+
                     /        \
                    v          v
         +-----------+    +-----------+
         | .hpp File |    | .cpp File |
         +-----------+    +-----------+
```

---

## Advanced Features

### Memory Layout Control

Sometimes you need explicit control over the parameter struct layout, perhaps for binary compatibility or GPU buffer alignment. The DSL supports explicit offsets.

```c
parameter
{
  float31 Scale:0 (-1024..1024 step 0.01) = 1;
  float30 Rotate:3 (-16..16 step 0.01) = 0;
  float31 Translate:6 (-65536..65536 step 0.01) = 0;
  int Count:9 (1..1024) = 2;
}
```

The `:0`, `:3`, `:6`, `:9` specify word offsets. The generator inserts padding as needed to achieve this layout. This is valuable when operators share parameter memory with GPU constant buffers.

### Conditional Parameters

The GUI can show or hide parameters based on other parameter values.

```c
parameter
{
  flags Mode ("rotate|target") = 0;
  if((Mode & 15) == 1)
    float31 Target (-1024..1024 step 0.01);
}
```

The parser builds an expression tree for the condition. The generator emits a C++ conditional around the widget code. The parameter is always present in the struct, but only visible in the GUI when the condition holds.

### Typed Inputs

Input declarations specify type constraints.

```c
operator Wz4Mesh Transform(Wz4Mesh, ?Wz4Skeleton)
```

Here `Wz4Mesh` is a required input and `?Wz4Skeleton` is optional. The generated code retrieves inputs with appropriate null checks for optional ones. Other modifiers include `*` for variadic inputs (accepting multiple connections) and `~` for weak references that do not force evaluation.

### Semantic Type Hints

Types like `float30` versus `float31` carry semantic meaning beyond storage size. Both store three floats, but `float30` represents a direction (normalized vector) while `float31` represents a position (point in space). The GUI can use this hint to offer appropriate manipulation handles in the 3D viewport.

---

## Why This Architecture Works

### Single Source of Truth

The DSL declaration is the canonical definition. Change a parameter name in one place, and it propagates to the struct, GUI, serialization, and script bindings automatically. This eliminates the entire class of bugs where names drift out of sync.

### Separation of Concerns

The user writes the interesting logic (how to generate a torus). The generator writes the boring infrastructure (GUI widgets, type casting, registration). Neither pollutes the other.

### Debuggable Output

The generated C++ is clean and readable. The generator emits `#line` directives so debugger breakpoints in user code map back to the `.ops` file. You can step through generated code and understand what is happening.

### Extensibility

Adding a new parameter type requires adding a case to the parser and a case to the generator. Existing operators automatically benefit. This is far easier than updating hundreds of operator files by hand.

---

## Implications for a Rust Framework

The core insight transfers directly: declarative operator definitions with code generation eliminate boilerplate while maintaining type safety. Rust's procedural macros offer a more integrated approach than external code generators.

### The Rust Equivalent

```rust
use framework::prelude::*;

#[derive(Operator)]
#[operator(name = "Torus", category = "Mesh/Primitives", shortcut = 'o')]
pub struct TorusOp {
    #[param(range = 3..=4096, default = 12)]
    pub slices: i32,

    #[param(range = 3..=4096, default = 8)]
    pub segments: i32,

    #[param(range = 0.0..=1024.0, step = 0.01, default = 0.25)]
    pub inner_radius: f32,

    #[param(range = 0.0..=1024.0, step = 0.01, default = 1.0)]
    pub outer_radius: f32,

    #[param(range = -4.0..=4.0, step = 0.001)]
    pub phase: f32,

    #[param(range = 0.0..=1.0, step = 0.001, default = 1.0)]
    pub arc: f32,
}

impl Execute for TorusOp {
    type Output = Mesh;

    fn execute(&self, _ctx: &Context) -> Result<Self::Output> {
        Ok(Mesh::torus(
            self.slices,
            self.segments,
            self.outer_radius,
            self.inner_radius,
            self.phase,
            self.arc,
        ))
    }
}
```

The `#[derive(Operator)]` macro generates:
- `impl Default for TorusOp` with the specified defaults
- `impl Gui for TorusOp` emitting egui widgets
- `impl Serialize + Deserialize` for save/load
- Registration with the operator registry via `inventory` or `linkme`

### What to Adopt

**Declarative parameter definitions.** The attribute-based approach captures the same information as the DSL. Range, step, default, and semantic hints all become attributes.

**Compile-time code generation.** Proc-macros integrate with the Rust toolchain. Error messages point to your source code, not generated files. IDE features like autocompletion work naturally.

**Type-safe inputs.** Rust's type system enforces input constraints at compile time. An operator that requires a `Mesh` input cannot accidentally receive a `Texture`.

### What to Change

**Replace runtime registration with static dispatch.** The `Doc->Classes.AddTail(cl)` pattern uses runtime registration. Rust can do better with the `inventory` crate for static registration, or simply with traits and generic dispatch.

**Replace string type names with actual types.** The `.ops` system uses string comparisons (`L"Wz4Mesh"`) for type checking. Rust's generics and trait bounds provide this statically.

**Replace global document with explicit context.** The global `Doc` pointer is convenient but not thread-safe. Rust's ownership system encourages explicit context passing, which also makes testing easier.

### What to Avoid

**External code generators.** Keeping generated files in sync with source files is fragile. Proc-macros generate code at compile time, eliminating the synchronization problem.

**Manual memory layout.** The explicit offset syntax exists because C++ lacks reflection. Rust's `#[repr(C)]` and `std::mem::offset_of!` handle layout concerns safely.

---

## Further Reading

- [Architecture overview](../architecture.md) for how the operator system fits into the larger Altona framework
- [Code trace: .ops to C++](../code-traces/ops-to-cpp.md) for line-by-line source analysis
- [ryg's Breakpoint 2007 talk on metaprogramming](https://fgiesen.wordpress.com/2012/04/08/metaprogramming-for-madmen/) for the philosophy behind the approach
