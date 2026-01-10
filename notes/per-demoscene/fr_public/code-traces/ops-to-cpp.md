# Code Trace: .ops to C++ Code Generation

> Tracing the path of `wz4ops basic_ops.ops` from DSL definition to executable operator code.

## Overview

**Framework**: fr_public (altona_wz4 / Werkkzeug4)
**Operation**: How a `.ops` operator definition becomes executable C++ code
**Files Touched**: 7 core files

The `.ops` DSL is the heart of Werkkzeug4's meta-programming approach. It eliminates boilerplate by generating:
- Parameter structs with proper memory layout
- GUI code for the parameter editor
- Default value initialization
- Script bindings for animation
- Command execution wrappers

## The Problem: Boilerplate Explosion in Node-Based Systems

Every operator in a visual programming system needs:
1. A way to define parameters (int, float, color, enum, etc.)
2. GUI widgets bound to those parameters
3. Serialization for save/load
4. Default value initialization
5. Type information for the node graph
6. The actual operator logic

Writing this by hand for hundreds of operators would mean massive code duplication. A single change to the GUI system would require updating every operator. The `.ops` DSL solves this by generating all the infrastructure from a compact declaration.

## User Code

A typical `.ops` file definition looks like this:

```c
// From wz4_mesh_ops.ops:186
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

This compact definition generates approximately 200 lines of C++ code.

## Call Stack

### 1. Entry Point: main.cpp

**File**: `altona/tools/wz4ops/main.cpp:17`

```cpp
void sMain()
{
  const sChar *name = sGetShellParameter(0,0);
  if(!name)
  {
    sPrintF(L"wz4ops %s %s\n",VERSION,REVISION);
    sPrint(L"usage: wz4ops name.ops\n");
    // ...
    return;
  }

  Doc = new Document;
  Doc->SetNames(name);

  if(!Doc->Parse(Doc->InputFileName))
  {
    sSetErrorCode();
  }
  else
  {
    if(!Doc->Output())
    {
      sSetErrorCode();
    }
    else
    {
      // Write output files
      sSaveTextAnsi(Doc->HPPFileName,Doc->HPP.Get());
      sSaveTextAnsi(Doc->CPPFileName,Doc->CPP.Get());
    }
  }
  delete Doc;
}
```

**What happens**: The tool is invoked as `wz4ops myfile.ops`. It creates a global `Document` object, parses the input, generates output to text buffers, then writes `.hpp` and `.cpp` files.

---

### 2. Parsing Phase: Parse()

**File**: `altona/tools/wz4ops/parse.cpp:12`

```cpp
sBool Document::Parse(const sChar *filename)
{
  Scan.Init();
  Scan.Flags |= sSF_MERGESTRINGS;
  Scan.DefaultTokens();
  Scan.AddToken(L"&&",TOK_ANDAND);
  Scan.AddToken(L"||",TOK_OROR);
  Scan.AddToken(L"if",TOK_IF);
  Scan.AddToken(L"else",TOK_ELSE);
  Scan.AddToken(L"array",TOK_ARRAY);
  Scan.StartFile(filename);

  Priority = 0x10;
  CurrentOp = 0;
  _Global();

  return Scan.Errors==0;
}
```

**What happens**: Initializes the scanner with custom tokens for the DSL (`&&`, `||`, `if`, `else`, `array`), then calls `_Global()` to parse the top-level constructs.

---

### 3. Global Declaration Parsing: _Global()

**File**: `altona/tools/wz4ops/parse.cpp:33`

```cpp
void Document::_Global()
{
  while(!Scan.Errors && Scan.Token!=sTOK_END)
  {
    if(Scan.IfName(L"header"))
    {
      CodeBlock *cb = _CodeBlock();
      if(cb) Doc->HCodes.AddTail(cb);
    }
    else if(Scan.IfName(L"code"))
    {
      CodeBlock *cb = _CodeBlock();
      if(cb) Doc->CCodes.AddTail(cb);
    }
    else if(Scan.IfName(L"type"))
    {
      _Type();
    }
    else if(Scan.IfName(L"operator"))
    {
      _Operator();
    }
    else if(Scan.IfName(L"priority"))
    {
      Scan.Match('=');
      Priority = Scan.ScanInt();
      Scan.Match(';');
    }
    // ...
  }
}
```

**What happens**: Dispatches to appropriate parsing methods based on the keyword. The DSL supports:
- `header { }` - Raw C++ for the .hpp file
- `code { }` - Raw C++ for the .cpp file
- `type TypeName { }` - Define a new data type
- `operator Type Name(inputs) { }` - Define an operator
- `priority = N;` - Set loading priority

---

### 4. Operator Parsing: _Operator()

**File**: `altona/tools/wz4ops/parse.cpp:288`

```cpp
void Document::_Operator()
{
  Op *op = new Op;
  CurrentOp = op;

  Scan.ScanName(op->OutputType);      // "Wz4Mesh"
  Scan.ScanName(op->Name);            // "Torus"
  if(Scan.Token == sTOK_STRING)
    Scan.ScanString(op->Label);       // optional display name
  else
    op->Label = op->Name;

  // Parse inputs: (Type1, ?Type2, *Type3)
  Scan.Match('(');
  while(!Scan.Errors && Scan.Token!=')')
  {
    Input *in = new Input;
    for(;;)
    {
      if(Scan.IfToken('*'))           // variadic inputs
        op->Flags |= 1;
      else if(Scan.IfToken('?'))      // optional input
        in->InputFlags = IF_OPTIONAL;
      else if(Scan.IfToken('~'))      // weak reference
        in->InputFlags = IF_WEAK;
      else
        break;
    }
    Scan.ScanName(in->Type);
    op->Inputs.AddTail(in);
    // ...
  }
  Scan.Match(')');
  Scan.Match('{');

  // Parse operator body
  while(!Scan.Errors && Scan.Token!='}')
  {
    if(Scan.IfName(L"parameter"))
      _Parameters(op,...);
    else if(Scan.IfName(L"code"))
      op->Code = _CodeBlock();
    else if(Scan.IfName(L"shortcut"))
    {
      Scan.Match('=');
      op->Shortcut = Scan.ScanInt();
      Scan.Match(';');
    }
    // ... handles, actions, flags, etc.
  }

  if(!Scan.Errors)
    Doc->Ops.AddTail(op);
}
```

**What happens**: Parses the operator signature (output type, name, inputs) and body (parameters, code blocks, metadata). Creates an `Op` AST node containing all the information.

---

### 5. Parameter Parsing: _Parameter()

**File**: `altona/tools/wz4ops/parse.cpp:452`

```cpp
void Document::_Parameter(Op *op,ExprNode *cond,sInt &offset,
                          sInt &stringoffset,sInt inarray,sInt &linkoffset)
{
  Parameter *para = new Parameter;

  // Parse modifiers: nolabel, layout, continue, anim, etc.
  for(;;)
  {
    if(Scan.IfName(L"nolabel"))
      nolabel = 1;
    else if(Scan.IfName(L"layout"))
      para->LayoutFlag = 1;
    else if(Scan.IfName(L"anim"))
      para->Flags |= PF_Anim;
    // ...
    else break;
  }

  // Parse type
  if(Scan.IfName(L"float"))
  {
    type = TYPE_FLOAT;
    para->CType = L"sF32";
  }
  else if(Scan.IfName(L"float31"))  // 3D position
  {
    type = TYPE_FLOAT;
    para->CType = L"sVector31";
    count = 3;
    para->XYZW = 1;
  }
  else if(Scan.IfName(L"int"))
  {
    type = TYPE_INT;
    para->CType = L"sInt";
  }
  else if(Scan.IfName(L"flags"))
  {
    type = TYPE_FLAGS;
    para->CType = L"sInt";
  }
  // ... color, string, filein, fileout, link, etc.

  // Parse name and optional label
  Scan.ScanName(para->Symbol);

  // Parse range: (min..max step S)
  if(Scan.IfToken('('))
  {
    para->Min = Scan.ScanFloat();
    Scan.Match(sTOK_ELLIPSES);
    para->Max = Scan.ScanFloat();
    if(Scan.IfName(L"step"))
      para->Step = Scan.ScanFloat();
    Scan.Match(')');
  }

  // Parse default: = value
  if(Scan.IfToken('='))
  {
    para->DefaultF[0] = Scan.ScanFloat();  // or int, etc.
  }

  // Calculate memory offset
  para->Offset = offset;
  offset += count;

  op->Parameters.AddTail(para);
}
```

**What happens**: Parses each parameter declaration, determining its C type, GUI widget type, valid range, step size, default value, and memory offset within the parameter struct.

---

### 6. AST Data Structures

**File**: `altona/tools/wz4ops/doc.hpp:79-283`

The key AST nodes:

```cpp
// A type definition (like "type Wz4Mesh : MeshBase")
class Type
{
public:
  sPoolString Parent;       // "MeshBase"
  sPoolString Symbol;       // "Wz4Mesh"
  sPoolString Label;        // "wz4 Mesh"
  sU32 Color;               // Node color in UI
  sInt Flags;               // notab|render3d|uncache
  CodeBlock *Code;          // Type implementation code
  CodeBlock *Header;        // Type header code
  sArray<External *> Externals;  // Virtual methods
};

// A parameter in an operator
class Parameter
{
public:
  sInt Type;                // TYPE_INT, TYPE_FLOAT, etc.
  sInt Offset;              // Byte offset in struct
  sPoolString Symbol;       // C variable name
  sPoolString Label;        // GUI label
  sPoolString CType;        // "sF32", "sVector31", etc.
  sF32 Min, Max, Step;      // Valid range
  sInt Count;               // Array size (1 for scalar)
  union {
    sF32 DefaultF[16];
    sU32 DefaultU[16];
  };
  ExprNode *Condition;      // Conditional visibility
};

// An operator definition
class Op
{
public:
  sPoolString Name;         // "Torus"
  sPoolString OutputType;   // "Wz4Mesh"
  sArray<Parameter *> Parameters;
  sArray<Parameter *> ArrayParam;  // For array parameters
  sArray<Input *> Inputs;   // Input connections
  CodeBlock *Code;          // Operator implementation
  CodeBlock *Handles;       // 3D manipulation handles
  CodeBlock *Actions;       // Button actions
  sInt Shortcut;            // Keyboard shortcut
  sInt Column;              // UI column placement
};
```

---

### 7. Code Generation Entry: Output()

**File**: `altona/tools/wz4ops/output.cpp:21`

```cpp
sBool Document::Output()
{
  // Write file headers
  HPP.Print(L"/**** Computer generated code - do not modify ****/\n");
  HPP.PrintF(L"#ifndef HEADER_WZ4OPS_%s\n",ProjectName);
  // ...

  CPP.Print(L"#include \"gui/gui.hpp\"\n");
  CPP.PrintF(L"#include \"%s.hpp\"\n",ProjectName);

  // Generate in order:
  OutputTypes1();        // Type forward declarations
  OutputCodeblocks();    // Raw code blocks
  OutputTypes2();        // Type class definitions
  OutputOps();           // Operator implementations
  OutputAnim();          // Animation bindings
  OutputMain();          // Registration function

  HPP.Print(L"#endif\n");
  return 1;
}
```

**What happens**: Orchestrates all code generation phases, writing to `HPP` (header) and `CPP` (implementation) text buffers.

---

### 8. Operator Code Generation: OutputOps()

**File**: `altona/tools/wz4ops/output.cpp:550`

For each operator, generates multiple components:

```cpp
void Document::OutputOps()
{
  sFORALL(Ops,op)
  {
    // 1. Parameter struct
    OutputParaStruct(L"Para", op->Parameters, op);

    // 2. Command execution function
    if(op->Code)
    {
      CPP.PrintF(L"sBool %sCmd%s(wExecutive *exe,wCommand *cmd)\n",
                 op->OutputType, op->Name);
      CPP.Print(L"{\n");
      // Cast parameter data
      CPP.PrintF(L"  %sPara%s *para = (%sPara%s *)(cmd->Data);\n",
                 op->OutputType,op->Name,op->OutputType,op->Name);
      // Cast inputs
      sFORALL(op->Inputs,in)
        CPP.PrintF(L"  %s *in%d = cmd->GetInput<%s *>(%d);\n",
                   in->Type,_i,in->Type,_i);
      // Get output
      CPP.PrintF(L"  %s *out = (%s *) cmd->Output;\n",type,type);
      CPP.PrintF(L"  if(!out) { out=new %s; cmd->Output=out; }\n",type);
      // Insert user code
      op->Code->Output(CPP,CPPFileName,1);
      CPP.Print(L"  return 1;\n}\n");
    }

    // 3. GUI generation function
    CPP.PrintF(L"void %sGui%s(wGridFrameHelper &gh,wOp *op)\n",
               op->OutputType, op->Name);
    CPP.Print(L"{\n");
    OutputPara(op->Parameters, op, 0);  // Generate widget code
    CPP.Print(L"}\n");

    // 4. Default value initialization
    CPP.PrintF(L"void %sDef%s(wOp *op)\n", op->OutputType, op->Name);
    // ...

    // 5. Script bindings
    CPP.PrintF(L"void %sBind%s(wCommand *cmd,ScriptContext *ctx)\n",
               op->OutputType, op->Name);
    // ...
  }
}
```

---

### 9. Parameter Struct Generation: OutputParaStruct()

**File**: `altona/tools/wz4ops/output.cpp:220`

```cpp
void Document::OutputParaStruct(const sChar *label,
                                sArray<Parameter *> &pa, Op *op)
{
  // Sort by offset to ensure proper memory layout
  sSortUp(sorted, &Parameter::Offset);
  offset = 0;

  HPP.PrintF(L"struct %s%s%s\n", op->OutputType, label, op->Name);
  HPP.Print(L"{\n");
  sFORALL(sorted, para)
  {
    // Add padding if needed
    if(para->Offset > offset)
    {
      sInt delta = para->Offset - offset;
      HPP.PrintF(L"  sInt _pad%d[%d];\n", offset, delta);
      offset += delta;
    }
    // Output the field
    HPP.PrintF(L"  %s %s", para->CType, para->Symbol);
    if(para->Count > 1 && !para->XYZW)
      HPP.PrintF(L"[%d]", para->Count);
    HPP.Print(L";\n");
    offset += para->Count;
  }
  HPP.Print(L"};\n\n");
}
```

**Generated output** for the Torus operator:

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

---

### 10. GUI Widget Generation: OutputPara()

**File**: `altona/tools/wz4ops/output.cpp:274`

```cpp
void Document::OutputPara(sArray<Parameter *> &pa, Op *op, sBool inarray)
{
  sFORALL(pa, para)
  {
    // Generate label
    if(!para->Label.IsEmpty())
      CPP.PrintF(L"  gh.Label(L\"%s\");\n", para->Label);

    // Generate widget based on type
    switch(para->Type)
    {
    case TYPE_FLOAT:
      CPP.PrintF(L"  sFloatControl *float_%s = "
                 L"gh.Float(&para->%s,%9F,%9F,%9F);\n",
                 para->Symbol, para->Symbol,
                 para->Min, para->Max, para->Step);
      CPP.PrintF(L"  float_%s->Default = %9F;\n",
                 para->Symbol, para->DefaultF[0]);
      break;

    case TYPE_INT:
      CPP.PrintF(L"  sIntControl *int_%s = "
                 L"gh.Int(&para->%s,%d,%d,%9F);\n",
                 para->Symbol, para->Symbol,
                 (sInt)para->Min, (sInt)para->Max, para->Step);
      break;

    case TYPE_FLAGS:
      CPP.PrintF(L"  gh.Flags(&para->%s,L\"%s\",gh.ChangeMsg);\n",
                 para->Symbol, para->Options);
      break;

    case TYPE_COLOR:
      CPP.PrintF(L"  gh.ColorPick(&para->%s,L\"%s\",0);\n",
                 para->Symbol, para->Options);
      break;
    // ... string, filein, fileout, link, etc.
    }
  }
}
```

---

### 11. Registration Function: OutputMain()

**File**: `altona/tools/wz4ops/output.cpp:1240`

```cpp
void Document::OutputMain()
{
  // Generate registration function
  CPP.PrintF(L"void AddOps_%s(sBool secondary)\n", ProjectName);
  CPP.Print(L"{\n");
  CPP.Print(L"  sVERIFY(Doc);\n");
  CPP.Print(L"  wClass *cl=0;\n");

  sFORALL(Ops, op)
  {
    CPP.Print(L"  cl = new wClass;\n");
    CPP.PrintF(L"  cl->Name = L\"%s\";\n", op->Name);
    CPP.PrintF(L"  cl->OutputType = %sType;\n", op->OutputType);

    if(op->Code)
      CPP.PrintF(L"  cl->Command = %sCmd%s;\n",
                 op->OutputType, op->Name);
    CPP.PrintF(L"  cl->MakeGui = %sGui%s;\n",
               op->OutputType, op->Name);
    CPP.PrintF(L"  cl->SetDefaults = %sDef%s;\n",
               op->OutputType, op->Name);
    // ... bindings, shortcuts, flags, etc.

    CPP.Print(L"  Doc->Classes.AddTail(cl);\n");
  }
  CPP.Print(L"}\n");
}
```

**Generated output**:

```cpp
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

## Data Flow Diagram

```
                    .ops File Input
                          |
                          v
    +-----------------------------------------+
    |         Scanner (Lexer)                 |
    |   Tokenizes: keywords, symbols, {}      |
    +-----------------------------------------+
                          |
                          v
    +-----------------------------------------+
    |         Parser (parse.cpp)              |
    |   _Global() -> _Operator() -> _Parameter|
    +-----------------------------------------+
                          |
                          v
    +-----------------------------------------+
    |            AST Structures               |
    |   Document { Types[], Ops[], Codes[] }  |
    |   Op { Parameters[], Inputs[], Code }   |
    |   Parameter { Type, Offset, Default }   |
    +-----------------------------------------+
                          |
                          v
    +-----------------------------------------+
    |       Code Generation (output.cpp)      |
    |   OutputTypes() -> OutputOps() ->       |
    |   OutputAnim() -> OutputMain()          |
    +-----------------------------------------+
                     /        \
                    v          v
         +-----------+    +-----------+
         | .hpp File |    | .cpp File |
         +-----------+    +-----------+
                |               |
                v               v
    +-----------------------------------------------+
    |          Parameter Struct                     |
    |   struct Wz4MeshParaTorus { ... }             |
    +-----------------------------------------------+
    |          Command Function                     |
    |   sBool Wz4MeshCmdTorus(exe, cmd) { ... }     |
    +-----------------------------------------------+
    |          GUI Function                         |
    |   void Wz4MeshGuiTorus(gh, op) { ... }        |
    +-----------------------------------------------+
    |          Default Function                     |
    |   void Wz4MeshDefTorus(op) { ... }            |
    +-----------------------------------------------+
    |          Registration                         |
    |   void AddOps_wz4_mesh_ops() { ... }          |
    +-----------------------------------------------+
```

## Key Observations

### 1. Single Source of Truth

The `.ops` file is the canonical definition. Parameter names, types, ranges, and defaults are declared once and propagate everywhere:
- Parameter struct field names match DSL symbols
- GUI labels come from DSL
- Script binding names derive from DSL symbols
- Default initialization uses DSL values

This eliminates the classic problem of having to update three places when adding a parameter.

### 2. Memory Layout Control

The `:offset` syntax allows explicit memory layout control:

```c
parameter
{
  float31 Scale:0 (-1024..1024 step 0.01) = 1;
  float30 Rotate:3 (-16..16 step 0.01) = 0;
  float31 Translate:6 (-65536..65536 step 0.01) = 0;
  int Count:9 (1..1024) = 2;
}
```

The numbers after `:` specify word offsets in the parameter struct. This allows:
- Binary compatibility across versions
- Explicit padding control
- Sharing memory layouts between related operators

### 3. Conditional Parameters

The DSL supports conditional parameter visibility:

```c
parameter
{
  flags Mode ("rotate|target") = 32;
  if((Mode & 15) == 1)
    float31 Target (-1024..1024 step 0.01);
}
```

The parser builds an `ExprNode` AST for conditions, and the code generator emits C++ conditionals in the GUI function.

### 4. Type-Safe Input Declarations

Input type checking happens at DSL level:

```c
operator Wz4Mesh Transform(Wz4Mesh, ?Wz4Skeleton)
```

- `?` = optional input
- `~` = weak reference (no dependency tracking)
- `*` = variadic (multiple inputs)

### 5. Embedded C++ Code Blocks

User code is wrapped but not transformed:

```c
code
{
  out->MakeTorus(para->Slices, para->Segments, ...);
}
```

The code generator surrounds this with boilerplate (parameter casting, output allocation) but preserves the user code verbatim with `#line` directives for debugger support.

### 6. GUI Hints in Type Names

Types like `float30` (3-component direction vector) vs `float31` (3-component position) affect both the generated struct type and implied GUI behavior (e.g., normalization).

## Implications for Rust Framework

### Adopt

**Declarative operator definitions**: The concept of a DSL that generates:
- Parameter structs
- GUI bindings
- Default initialization
- Serialization support

This pattern is directly applicable using Rust proc-macros.

**Explicit memory layout control**: Important for GPU buffer compatibility. Use `#[repr(C)]` and explicit field ordering.

**Type-safe inputs**: Rust's type system can enforce input constraints at compile time.

### Modify

**Replace text-based code generation with proc-macros**: Instead of generating `.cpp` files at build time, use Rust's `#[derive(...)]` and attribute macros to generate code at compile time. This provides:
- Better error messages (pointing to original source)
- IDE integration
- Type checking of generated code

**Replace runtime registration with static dispatch**: Instead of `Doc->Classes.AddTail(cl)`, use inventory/linkme crates for static registration, or traits for operator dispatch.

**Replace dynamic GUI generation with immediate-mode UI**: The generated GUI code is imperative. For Rust, consider egui or imgui patterns where UI code is written directly but parameter metadata is derived.

### Avoid

**String-based type identification**: The `.ops` system uses string comparisons (`L"Wz4Mesh"`) for type checking. Use Rust's type system instead.

**Global Document pointer**: The `Doc` global is convenient but not thread-safe. Use explicit context passing or dependency injection.

**Manual memory offset calculation**: Rust's `#[repr(C)]` and `std::mem::offset_of!` handle this safely.

### API Sketch

```rust
use framework::prelude::*;

#[derive(Operator)]
#[operator(
    name = "Torus",
    category = "Mesh/Primitives",
    shortcut = 'o'
)]
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

The `#[derive(Operator)]` macro would generate:
- `impl Default for TorusOp` with specified defaults
- `impl Gui for TorusOp` with appropriate widgets
- `impl Serialize/Deserialize for TorusOp`
- Registration with the operator registry

This achieves the same boilerplate reduction as wz4ops while being fully type-safe and integrated with Rust tooling.
