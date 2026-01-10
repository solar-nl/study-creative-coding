# The Type System: Automatic Adapters for Node Connections

> How Werkkzeug4 lets artists wire anything to anything, while catching mistakes before they waste render time

---

## The Problem: When Flexibility Becomes Chaos

Visual programming tools promise freedom. Wire outputs to inputs. Experiment. See what happens. But that freedom creates a tension that every node-based system must resolve.

Wire a mesh generator to a texture filter. What should happen? In a system with no type checking, you get a crash during rendering, or worse, silent corruption that wastes an hour of debugging. In a system with strict type checking, you cannot even make the connection. The first approach ruins creative flow with mysterious errors. The second ruins creative flow by blocking experiments.

Werkkzeug4 takes a middle path. The system knows what types every operator produces and consumes. When you try to make an incompatible connection, it first asks: "Can I convert this for you?" A texture can become a material. A single mesh can become a group. If a conversion exists, the system inserts it automatically, invisibly. If no conversion exists, the wire turns red and an error appears. You learn about the problem immediately, not during an expensive render.

This is the trade-off that makes real-time demoscene production possible: maximum flexibility within guardrails that catch mistakes early.

---

## The Mental Model: Electrical Adapters

Think about traveling internationally with electronic devices. Your laptop charger has a US plug. The hotel wall has a European socket. The shapes do not match directly, but you brought an adapter. The adapter accepts the US plug on one side and presents European prongs on the other. Power flows.

Werkkzeug4's type system works the same way.

Every operator output is a "plug" with a specific shape. Every operator input is a "socket" expecting a particular shape. The system maintains a catalog of available adapters. When you connect a plug to an incompatible socket, the system checks the catalog: "Do I have an adapter that accepts this plug shape and presents that socket shape?" If yes, the adapter gets inserted automatically between the two nodes. If no, the connection fails with a clear error message.

The key insight is that compatibility is not just "same or different." Compatibility has three levels:

1. **Direct fit.** A USB-C cable fits a USB-C port. No adapter needed. A Mesh output connects directly to a Mesh input.

2. **Inherited fit.** A USB-C cable also fits a "USB-C or USB-A" port that accepts both. The port is more general than what you are providing. In Werkkzeug4, an operator accepting "any RenderNode" will accept meshes, particle systems, or scenes, because they all inherit from RenderNode.

3. **Adapted fit.** A USB-C cable can connect to an HDMI monitor if you have the right adapter. The adapter actively transforms the signal. In Werkkzeug4, a Texture can connect to a Material input if a conversion operator exists to wrap textures into materials.

Let us trace exactly what happens when you connect a Texture output to a Material input.

---

## Let's Trace What Happens: Texture to Material

You are building a 3D scene. You have a node that generates a procedural texture: stripes, noise, gradients. You have a Cube mesh that needs a material applied. You draw a wire from the texture output to the material input slot on the cube.

The moment you release the mouse button, three things happen in rapid succession.

**First, the GUI checks direct compatibility.** The output is type `Texture2D`. The input expects type `Wz4Mtrl`. These are different types, so no direct fit. The GUI does not reject the connection yet. It proceeds to check inheritance.

**Second, the GUI checks inherited compatibility.** Starting from `Texture2D`, it walks up the inheritance chain: Texture2D's parent is `AnyType`. It checks: is `AnyType` the same as `Wz4Mtrl`? No. Does `AnyType` have a parent? No, it is the root. No inherited fit either. Still not rejected. One more check.

**Third, the GUI searches for adapters.** It scans the registered conversion operators. It finds one: `FromTexture`, which accepts a `Texture2D` and outputs a `Wz4Mtrl`. This adapter can bridge the gap. The wire turns green. Connection allowed.

When you later hit Calculate to render the scene, the graph compiler walks this connection again. It confirms the adapter is needed, creates a hidden conversion node, and inserts it between your texture generator and the cube's material input. The conversion operator runs automatically, wrapping your texture into a material with default settings. The cube renders with your procedural stripes.

You never see the adapter node in your graph. It exists only in the compiled command sequence. Your visual graph stays clean while the runtime handles the plumbing.

---

## The Inheritance Hierarchy

Types in Werkkzeug4 form a family tree. At the root sits `AnyType`, the universal ancestor. Every concrete type descends from it. The tree might look like this:

```
AnyType
├── Texture2D
├── Wz4Mesh
├── Wz4Mtrl (Material)
├── RenderNode
│   ├── Wz4Particles
│   └── Wz4Scene
└── GroupType
```

When an operator declares that its input accepts `RenderNode`, it automatically accepts `Wz4Particles`, `Wz4Scene`, and any future type that inherits from `RenderNode`. The operator's author does not need to enumerate every possible subtype. New types integrate with existing operators by choosing the right parent.

The inheritance check walks this tree upward. Given a candidate type and a required type, the algorithm asks: "Starting from the candidate, can I reach the required type by following parent pointers?"

Here is how to visualize the check for "Does Wz4Particles satisfy a RenderNode requirement?"

```
Start at Wz4Particles
    Is Wz4Particles == RenderNode?  No.
    Move to parent: RenderNode
    Is RenderNode == RenderNode?    Yes. Match found.
```

The walk terminates successfully. For a check that fails, like "Does Texture2D satisfy RenderNode?":

```
Start at Texture2D
    Is Texture2D == RenderNode?     No.
    Move to parent: AnyType
    Is AnyType == RenderNode?       No.
    Move to parent: (none)
    End of chain. No match.
```

The walk reaches the root without finding a match. Direct inheritance fails. Time to search for adapters.

---

## How Types Are Declared

Type declarations live in `.ops` files alongside operator definitions. Each type specifies its place in the hierarchy, its visual color in the editor, and optional behavior flags.

```c
type virtual AnyType : 0
{
  color = 0xffc0c0c0;
  name = "any";
  flags = notab;
}

type Wz4Mesh
{
  color = 0xff8080ff;
  name = "Mesh";
  flags = render3d | uncache;
}
```

The `virtual` keyword marks `AnyType` as abstract. You never create objects of type `AnyType` directly; you create concrete descendants like meshes or textures. The `render3d` flag tells the preview system to use the 3D viewport with camera controls. The `uncache` flag enables memory pressure management: when RAM runs low, the system can evict cached meshes and regenerate them later.

The editor uses the color field for visual distinction. Mesh wires appear blue-purple. Texture wires appear green. Material wires appear orange. Artists learn to read these colors intuitively, catching misconnections before even attempting them.

---

## Conversion Operators: The Adapter Catalog

Conversion operators bridge incompatible types. They look like regular operators but carry a special flag that registers them in the adapter catalog.

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
    Wz4Mtrl *mtrl = new Wz4Mtrl;
    mtrl->SetChannel(para->Channel, in0);
    out = mtrl;
  }
}
```

This conversion accepts a `Texture2D` and produces a `Wz4Mtrl`. The `flags = conversion` line is the key. At startup, the document system scans all operators for this flag and builds a catalog: "From Texture2D, I can reach Wz4Mtrl using FromTexture."

Notice the `Channel` parameter. Conversion operators can have their own parameters. When the system auto-inserts this conversion, it uses the default value: 0 for "diffuse." If you need your texture in the specular channel instead, you can manually insert the conversion operator, adjust the parameter, and achieve finer control.

The system searches conversions in registration order. If multiple conversions could bridge a gap, the first registered one wins. Framework authors place specific conversions before general ones to establish priority.

---

## Runtime Type Information

At runtime, every object carries a pointer to its type. This enables dynamic checks that the static hierarchy cannot catch.

Consider a GroupType that contains multiple objects of varying types. When you extract an object from the group, you might need to verify it is a mesh before passing it to mesh-specific operations. The object's runtime type pointer enables this check.

```cpp
sBool wObject::IsType(wType *required)
{
  return Type->IsType(required);
}
```

The object delegates to its type, which walks the inheritance chain. This is the same algorithm the GUI uses, now applied at runtime. The result tells you whether casting is safe.

Reference counting handles memory. When an operator stores a reference to an object, it increments the count. When the operator finishes and releases the reference, the count decrements. When the count reaches zero, the object frees itself. The `PASSOUTPUT` optimization in the executor can steal references without incrementing, avoiding copies when an operator is the sole consumer of its input.

---

## The Pass-Through Problem

Some operators work with any type. A `Nop` (no-operation) passes its input unchanged. A `Store` saves any value for later retrieval. How do you declare their types?

The naive approach uses `AnyType` for both input and output. But this loses type information. If a mesh enters a `Nop`, the output is marked as `AnyType`, not `Mesh`. Downstream operators expecting meshes would reject the connection.

The solution is the `typefrominput` flag. This tells the compiler: "My output type is whatever my input type is. Propagate it."

```c
operator AnyType Nop(AnyType)
{
  flags = typefrominput;
}
```

During graph compilation, the builder resolves actual types. It sees Nop receives a mesh, so Nop's output is marked as mesh. The next operator in the chain sees a mesh input and accepts the connection. Type information flows through pass-through operators without loss.

This pattern appears throughout Werkkzeug4: `Store`, `Load`, routing operators, conditional operators. The flag ensures that generic utilities do not become type-information black holes.

---

## Putting It Together: The Type Checking Flow

When you hit Calculate, the graph compiler validates every connection. Here is the flow:

```
For each wire in the graph:
    |
    v
Output type == Input type?
    Yes: Direct fit. Accept.
    No:  Continue checking.
    |
    v
Walk output type's inheritance chain.
Does any ancestor match the input type?
    Yes: Inherited fit. Accept.
    No:  Continue checking.
    |
    v
Search conversion catalog.
Any converter: (accepts output type) -> (produces input type)?
    Yes: Insert conversion node. Accept.
    No:  Type error. Reject graph.
```

Errors stop compilation before expensive GPU operations begin. The user sees a clear message: "Type mismatch between MeshGenerator and TextureFilter. No conversion available." They fix the problem and try again. No wasted render time. No cryptic runtime crashes.

---

## Key Insights

**Hierarchy enables extension.** New types automatically work with existing operators by choosing the right parent. An operator accepting RenderNode works with any render node subtype, including ones created after the operator was written.

**Conversions enable flexibility.** Artists can wire a texture to a material input without manually inserting conversion nodes. The system handles the plumbing. The visual graph stays clean.

**Early checking enables iteration.** Errors surface during graph compilation, not during minute-long renders. The feedback loop tightens. Experimentation speeds up.

**Runtime types enable dynamism.** Groups can contain mixed types. Scripts can inspect and branch on types. The static hierarchy handles the common case; runtime checks handle the exceptions.

---

## Implications for a Rust Framework

Werkkzeug4's type system maps naturally to Rust, with some idiomatic adjustments.

**Adopt: Trait-based polymorphism.** Replace the `wType` hierarchy with traits. An operator accepting `impl RenderNode` works with any type implementing that trait. Rust checks this at compile time.

**Adopt: From/Into for conversions.** Rust's standard conversion traits serve the same purpose as conversion operators. `impl From<Texture> for Material` enables automatic conversion where the compiler can infer it.

**Modify: Use enums for closed type sets.** If your framework has a fixed set of output types (mesh, texture, material, scene), an enum with pattern matching is simpler than trait objects and enables exhaustive checking.

```rust
pub enum NodeOutput {
    Mesh(Mesh),
    Texture(Texture),
    Material(Material),
}

fn process_input(input: NodeOutput) -> Result<Mesh, TypeError> {
    match input {
        NodeOutput::Mesh(m) => Ok(m),
        _ => Err(TypeError::Expected("Mesh")),
    }
}
```

**Avoid: Runtime type tags.** Rust's type system eliminates the need for `Type` pointers on objects. Use generics or enums instead. Reserve `TypeId` for truly dynamic scenarios like plugin systems.

**Avoid: Manual reference counting.** Use `Arc<T>` for shared ownership. Rust's drop semantics handle cleanup automatically. The `Arc::try_unwrap()` method enables reference stealing when strong count equals one.

---

## Further Reading

- [Operator System](./operator-system.md) for how operators declare their input and output types
- [Graph Execution](./graph-execution.md) for how types affect caching and conversion insertion during compilation

---

## Files Referenced

| File | Purpose |
|------|---------|
| `altona/main/wz4lib/doc.hpp:268-300` | wType class definition |
| `altona/main/wz4lib/doc.cpp:867-898` | IsType and IsTypeOrConversion methods |
| `altona/main/wz4lib/basic_ops.ops:28-73` | Type declarations in DSL |
| `altona/main/wz4lib/build.cpp:559-580` | Conversion insertion during compilation |
