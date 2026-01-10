# The Type System: Runtime Polymorphism with Compile-Time Safety

> How Werkkzeug4 enables flexible node connections while catching errors before execution

---

## The Problem: Flexibility vs. Safety

Visual programming tools face a fundamental tension around types. Too strict, and users cannot experiment freely. Too loose, and runtime crashes ruin the creative flow.

Consider what happens when you wire a mesh generator to a texture filter. In a dynamically typed system, you get a cryptic crash during execution, or worse, silent corruption. In an overly strict system, you cannot even make the connection to see what happens. Neither extreme serves artists well.

Werkkzeug4 navigates this tension with a layered type system. Types form a hierarchy with inheritance. Operators declare what types they accept. The system checks compatibility during graph compilation, before expensive operations begin. When types are incompatible but convertible, automatic conversion operators bridge the gap.

Think of it like electrical adapters. A European plug does not fit an American socket directly, but with the right adapter, power flows. Werkkzeug4's conversion operators are those adapters, automatically inserted when needed and checked for existence at connection time.

---

## The Mental Model: Shapes That Fit

Imagine a children's shape-sorting toy. Round pegs fit round holes. Square pegs fit square holes. But this toy has a twist: some holes accept multiple shapes. A "polygon" hole accepts triangles, squares, and pentagons. A "any shape" hole accepts everything.

In Werkkzeug4:
- **wType** is a shape category (circle, polygon, any)
- **wObject** is an actual shape instance (this particular red triangle)
- **wClass** is a machine that produces shapes (the TriangleGenerator)
- **Conversion operators** reshape objects to fit different holes

The hierarchy matters. If "Polygon" is a parent of "Triangle", then any hole accepting "Polygon" also accepts "Triangle". This saves operators from enumerating every specific type they could handle.

---

## The Type Hierarchy

Types form a tree with `AnyType` at the root. Here is how types are declared in `.ops` files, from `basic_ops.ops:28`:

```c
type virtual AnyType : 0
{
  color = 0xffc0c0c0;
  name = "any";
  flags = notab;
}

type GroupType
{
  color = 0xffc0c0c0;
  name = "Group";
  flags = notab|render3d;
  gui = base3d;

  extern void Show(wObject *obj, wPaintInfo &pi)
  {
    // ...rendering code...
  }
}

type TextObject
{
  color = 0xffc0c0c0;
  name = "String";
  flags = notab;
}
```

The `virtual` keyword marks `AnyType` as abstract. Real objects never have `AnyType` directly; they have a concrete derived type. The `: 0` specifies the inheritance order (0 means no parent specified, implying AnyType).

Each type declaration includes:
- **color** — For visual distinction in the editor
- **name** — Human-readable label
- **flags** — Behavior modifiers (notab, render3d, uncache)
- **gui** — Which preview mode to use (base2d, base3d)
- **Show()** — How to render objects of this type

---

## Type Flags: Controlling Behavior

Three flags modify how the system treats types, defined in `doc.hpp:60`:

```cpp
enum wTypeFlags
{
  wTF_NOTAB         = 0x01,   // Hide from operator palette tabs
  wTF_RENDER3D      = 0x02,   // Preview in 3D viewport
  wTF_UNCACHE       = 0x04,   // Enable memory management/eviction
};
```

The `NOTAB` flag hides utility types from the UI. `AnyType` is `NOTAB` because you never create an "any" object directly; you create meshes, textures, or other concrete types.

The `RENDER3D` flag tells the preview system which viewport to use. Meshes and scenes need the 3D viewport with camera controls. Textures need the 2D viewport with zoom and pan.

The `UNCACHE` flag enables aggressive memory management. Large textures and meshes can be evicted from memory and regenerated when needed. Small metadata objects stay cached indefinitely.

---

## Type Checking: The IsType Algorithm

When the graph compiler checks if a connection is valid, it walks up the inheritance chain. Here is the core logic from `doc.cpp:867`:

```cpp
sBool wType::IsType(wType *type)
{
  wType *owntype = this;
  do
  {
    if(type == owntype)
      return 1;
    owntype = owntype->Parent;
  }
  while(owntype);
  return 0;
}
```

The method answers: "Can I be used where `type` is expected?" If the expected type is `Wz4Mesh`, and I am a `Wz4Mesh`, yes. If the expected type is `AnyType`, and I inherit from `AnyType` (everything does), yes. If the expected type is `Texture2D` and I am a `Wz4Mesh`, no.

This simple parent-walking algorithm enables polymorphism. An operator accepting `RenderNode` can receive any of its descendants: meshes, scenes, particle systems. The operator does not need to know about every possible subtype.

---

## Automatic Type Conversion

Sometimes types are incompatible but convertible. A texture exists as pixel data, but a mesh shader needs UV-mapped surfaces. Werkkzeug4 handles this with conversion operators.

Conversion operators are marked with `wCF_CONVERSION` and registered in a global list. Here is how the system finds and applies conversions, from `doc.cpp:880`:

```cpp
sBool wType::IsTypeOrConversion(wType *type)
{
  wClass *cl;

  // Direct match or inheritance?
  if(IsType(type)) return 1;

  // Search for conversion operator
  sFORALL(Doc->Conversions, cl)
    if(cl->OutputType->IsType(type) && IsType(cl->Inputs[0].Type))
      return 1;

  return 0;
}
```

The extended check asks: "Can I become what you need?" Either directly (inheritance) or through a conversion operator that accepts my type and produces your type.

During graph compilation, the builder automatically inserts conversion operators when needed. From `build.cpp:574`:

```cpp
// Type mismatch: insert conversion
if(in->OutType != reqtype && !in->OutType->IsType(reqtype))
{
  wOp *convop = in->Op->MakeConversionTo(reqtype, node->CallId);
  if(convop)
  {
    // Insert conversion node between input and this operator
    wNode *convnode = MakeNode(1);
    convnode->Inputs[0] = in;
    convnode->Op = convop;
    convnode->OutType = convop->Class->OutputType;
    node->Inputs[i] = convnode;
  }
  else
  {
    Error(op, L"type mismatch");
  }
}
```

The user sees a green wire connecting a texture output to a mesh input. Under the hood, a conversion operator silently transforms the texture into a mesh material. If no conversion exists, the system reports a type error before execution wastes time.

---

## Defining Conversion Operators

Conversion operators look like regular operators but have the `conversion` flag. From `basic_ops.ops:383`:

```c
operator GroupType ToGroup(AnyType)
{
  flags = conversion;
  code
  {
    GroupType *group = new GroupType;
    group->Add(in0);
    out = group;
  }
}
```

This operator converts any single object into a GroupType containing that object. The system can now wire any output to an input expecting GroupType.

For type-specific conversions, you specify exact types:

```c
operator Wz4Mtrl FromTexture(Texture2D)
{
  flags = conversion;
  parameter
  {
    int Channel ("diffuse|specular|normal") = 0;
  }
  code
  {
    // Create material from texture...
  }
}
```

The conversion list is searched in registration order. Put specific conversions before general ones if you need priority.

---

## Runtime Objects: wObject

Every runtime value inherits from `wObject`, defined in `doc.hpp:970`:

```cpp
class wObject
{
protected:
  virtual ~wObject();
public:
  wObject();
  wType *Type;        // Runtime type information
  sInt RefCount;      // Reference counting
  sInt CallId;        // Context for caching

  void AddRef()  { if(this) RefCount++; }
  void Release() { if(this) { if(--RefCount <= 0) delete this; } }

  sBool IsType(wType *type) { return Type->IsType(type); }
  virtual wObject *Copy() { return 0; }
};
```

The `Type` pointer enables runtime type checks. Even after compilation, some operations need to verify types. A script might extract a mesh from a group at runtime; the extraction needs type information to validate.

The `CallId` field connects objects to their compilation context. The same operator called twice from different subroutines produces objects with different CallIds. Cache lookups match both the operator AND the CallId.

Reference counting handles ownership. Operators increment the count when storing references. When counts hit zero, memory is freed. The `PASSOUTPUT` optimization steals references without incrementing, avoiding copies when safe.

---

## Type-Specific Operators

Operators declare their input and output types in `.ops` syntax:

```c
operator Wz4Mesh Transform(Wz4Mesh, ?Wz4Skeleton)
{
  // ...
}
```

This declares:
- **Output type**: `Wz4Mesh` — what this operator produces
- **Input 1**: `Wz4Mesh` — required input
- **Input 2**: `?Wz4Skeleton` — optional input (the `?` prefix)

The generated C++ includes type metadata:

```cpp
cl = new wClass;
cl->OutputType = Wz4MeshType;
cl->Inputs.AddTail();
cl->Inputs.GetTail()->Type = Wz4MeshType;
cl->Inputs.AddTail();
cl->Inputs.GetTail()->Type = Wz4SkeletonType;
cl->Inputs.GetTail()->Flags |= wCIF_OPTIONAL;
```

The type system uses this metadata during compilation. A wire from a `Texture2D` output to the `Wz4Mesh` input fails the `IsType` check and triggers conversion search.

---

## The AnyType Escape Hatch

Some operators work with any type. The `Nop` operator passes through unchanged. The `Store` operator saves any value. These use `AnyType`:

```c
operator AnyType Nop(AnyType)
{
  flags = typefrominput;
}

operator AnyType Store(AnyType)
{
  flags = store|typefrominput;
}
```

The `typefrominput` flag is crucial. It tells the compiler: "My output type is whatever my input type is." Without this flag, the output would be `AnyType`, losing type information and breaking downstream operators.

During graph compilation, operators with `typefrominput` have their actual output type resolved from their input connections. This preserves type safety even through pass-through operators.

---

## Type System Flow

Here is how types flow through the compilation pipeline:

```
User connects wire: MeshGen → Transform
    |
    v
GUI validates connection
    |
    +---> Check: MeshGen.OutputType.IsType(Transform.Input0.Type)?
    |     Yes: Wire allowed (green)
    |     No:  Check IsTypeOrConversion
    |            Yes: Wire allowed (with conversion icon)
    |            No:  Wire disallowed (red)
    |
    v
User requests calculation
    |
    v
wBuilder.Parse()
    |
    +---> Read OutputType from each operator
    +---> Resolve typefrominput operators
    |
    v
wBuilder.Optimize()
    |
    +---> Insert conversion nodes where needed
    |     MeshGen → [AutoConvert] → Transform
    |
    v
wBuilder.TypeCheck()
    |
    +---> Verify all connections are compatible
    +---> Verify conversions actually exist
    |
    v
wBuilder.Output()
    |
    +---> Generate commands with type-aware caching
```

---

## Key Insights

### Compile-Time Validation

Type errors are caught during graph compilation, before expensive GPU operations. This gives immediate feedback while editing, not crashes during rendering.

### Implicit Conversions

Artists do not manually insert conversion nodes. The system finds and applies conversions automatically. This reduces friction while maintaining type safety.

### Hierarchical Types

The parent-child relationship enables polymorphism. New types automatically work with existing operators that accept their parent type.

### Preserved Identity

The `typefrominput` flag ensures type information flows through pass-through operators. A mesh remains a mesh even after going through a `Nop` or `Store`.

---

## Rust Implications

The Werkkzeug4 type system maps naturally to Rust's type system, with some idiomatic adjustments.

### Adopt Directly

**Trait-based polymorphism.** The `wType` hierarchy becomes trait bounds. An operator accepting `impl RenderNode` works with any type implementing that trait.

**Compile-time type checking.** Rust's generics catch type mismatches at compile time. No runtime `IsType` checks needed for static graphs.

**Automatic conversions.** Rust's `From`/`Into` traits provide the same capability. `impl From<Texture> for Material` enables implicit conversion.

### Modify for Rust

**Use enums for known type sets.** If you have a closed set of types (mesh, texture, material), an enum with methods is simpler than trait objects.

```rust
pub enum NodeOutput {
    Mesh(Mesh),
    Texture(Texture),
    Material(Material),
}

impl NodeOutput {
    pub fn as_mesh(&self) -> Option<&Mesh> {
        match self {
            NodeOutput::Mesh(m) => Some(m),
            _ => None,
        }
    }
}
```

**Replace runtime type checks with pattern matching.** Instead of `IsType`, use `match` or `if let`:

```rust
fn process_input(input: NodeOutput) -> Result<Mesh, TypeError> {
    match input {
        NodeOutput::Mesh(m) => Ok(m),
        _ => Err(TypeError::Expected("Mesh")),
    }
}
```

### Avoid

**Runtime type tags.** Rust's type system eliminates the need for `wType *Type` pointers on objects. Use enums or generics instead.

**String-based type names.** The `.ops` system compares type names as strings. Rust uses actual types, catching errors at compile time.

**Manual reference counting.** Use `Arc<T>` for shared ownership, `Rc<T>` for single-threaded contexts.

---

## Files Referenced

| File | Purpose |
|------|---------|
| `altona/main/wz4lib/doc.hpp:60-73` | wTypeFlags, wTypeGuiSets enums |
| `altona/main/wz4lib/doc.hpp:268-300` | wType class definition |
| `altona/main/wz4lib/doc.hpp:970-987` | wObject class definition |
| `altona/main/wz4lib/doc.cpp:849-898` | wType methods implementation |
| `altona/main/wz4lib/basic_ops.ops:28-73` | Type definitions in DSL |
| `altona/main/wz4lib/build.cpp:559-580` | Conversion insertion |

---

## Next Steps

- See [Operator System](./operator-system.md) for how operators declare their types
- See [Graph Execution](./graph-execution.md) for how types affect caching
- For wgpu comparison, see `../../altona/graphics-abstraction.md` (planned)
