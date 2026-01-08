# Chapter 2: Factory Pattern

> *How the system decides which renderer to use for each type*

---

## The Problem: Matching Types to Renderers

In Chapter 1, we established that each output type gets its own specialized renderer. FloatOutputUi knows how to display floats. Texture2dOutputUi knows how to display textures. But this raises an immediate question: **how does the system know which renderer to create?**

Somewhere, something needs to maintain the mapping: "when I see a float, give me a FloatOutputUi."

The naive approach is a giant conditional:

```csharp
IOutputUi CreateRenderer(Type type)
{
    if (type == typeof(float)) return new FloatOutputUi();
    if (type == typeof(Texture2D)) return new Texture2dOutputUi();
    if (type == typeof(Command)) return new CommandOutputUi();
    // ... imagine 20 more of these
}
```

This works, but it has problems. Every time you add a new type, you modify this central function. The function grows endlessly. And there's a subtle issue: what about types you *don't* know about? Someone might create a custom `ParticleSystem` type. The switch statement can't handle it.

---

## The Key Insight: Separate Registration from Creation

The factory pattern solves this by splitting the problem in two:

1. **Registration phase** (at startup): "Hey factory, when you see `float`, use this function to create the renderer."
2. **Creation phase** (at runtime): "Factory, give me a renderer for this type."

Think of it like a phone directory. You don't hardcode everyone's number into your phone app. Instead, you have a directory that maps names to numbers, and the app just looks things up.

```
                    Registration (startup)
                           │
                           ▼
    ┌─────────────────────────────────────────┐
    │              Factory Registry           │
    │                                         │
    │  float      →  () => new FloatOutputUi  │
    │  Texture2D  →  () => new Texture2dOutput│
    │  Command    →  () => new CommandOutputUi│
    │  ...                                    │
    └─────────────────────────────────────────┘
                           │
                           ▼
                   Creation (runtime)
                           │
        "I need a renderer for float"
                           │
                           ▼
              Factory looks up, returns
                   FloatOutputUi
```

---

## GenericFactory: The Implementation

The OutputUi system uses a class called `GenericFactory<T>` to implement this pattern. Let's understand what it does before looking at the code.

The factory maintains a dictionary: Type → factory function. When you ask for a renderer, it looks up the type and calls the factory function.

But here's where it gets interesting: **what happens when you ask for a type that wasn't registered?**

You might wonder why this matters. Can't we just register every type upfront? The problem is that output types aren't always known at compile time. Users can create custom operators with custom output types. The system needs to handle types it has never seen before.

The solution: **a fallback**. The factory is initialized with a "default type" - an open generic like `ValueOutputUi<>`. When an unknown type is requested, the factory:

1. Takes this open generic
2. Closes it with the actual type: `ValueOutputUi<MyCustomType>`
3. Creates a factory for it
4. Caches it for next time

This means *every* type gets some visualization, even if it's just the basic "show the type name and call ToString()" treatment.

---

## Walking Through the Code

Now that you understand the concept, let's look at the implementation.

**Key Source Files:**
- `Core/Compilation/GenericFactory.cs`
- `Editor/Gui/OutputUi/OutputUiFactory.cs`
- `Editor/UiModel/UiRegistration.cs`

The core factory class:

```csharp
public sealed class GenericFactory<T>
{
    private readonly Type _defaultType;
    private readonly ConcurrentDictionary<Type, Func<T>> _entries = new();

    public GenericFactory(Type defaultType)
    {
        _defaultType = defaultType;
    }

    public T CreateFor(Type type)
    {
        if (_entries.TryGetValue(type, out var factory))
            return factory();

        // Unknown type - create a fallback factory
        var newFactory = AddFactory(type, null);
        return newFactory();
    }
}
```

Notice that `CreateFor` is just a dictionary lookup. If the type is found, call the factory and return the result. If not, create a fallback and cache it.

The OutputUi system wraps this in a simple singleton:

```csharp
public static class OutputUiFactory
{
    public static readonly GenericFactory<IOutputUi> Instance =
        new(typeof(ValueOutputUi<>));
}
```

The default type is `ValueOutputUi<>` - an open generic. This is the fallback that handles unknown types.

---

## Why Expression Compilation?

You might notice the factory uses "expression compilation" to create instances. Why not just use `Activator.CreateInstance(type)`?

The answer is performance. `Activator.CreateInstance` uses reflection on every call. It has to look up the constructor, check the parameters, create the instance - every single time.

Expression compilation does the reflection work *once*, then produces a delegate that creates instances directly:

```csharp
// Slow: Reflection every call
var instance = Activator.CreateInstance(type);

// Fast: Direct call after one-time compilation
var factory = CompileFactory(type);
var instance = factory();  // Just a function call
```

The key insight is that factory creation is rare (once per type), but factory *usage* is frequent (every time an output is displayed). By paying the cost upfront, every subsequent creation is fast.

Here's how the compilation works:

```csharp
private Func<T> CompileFactory(Type concreteType)
{
    // Find the parameterless constructor
    var ctor = concreteType.GetConstructor(Type.EmptyTypes);

    // Build an expression tree: () => new ConcreteType()
    var newExpr = Expression.New(ctor);
    var lambda = Expression.Lambda<Func<T>>(newExpr);

    // Compile to a delegate
    return lambda.Compile();
}
```

Think of expression trees as "code that describes code." We're building a description of `new ConcreteType()`, then asking the runtime to compile it into an actual function. The result is a delegate that, when called, executes the equivalent of `new ConcreteType()` directly.

---

## Type Registration: Setting Up the Directory

During editor initialization, specific types are registered with explicit factory functions:

```csharp
public static void RegisterUiTypes()
{
    // Scalar types
    RegisterIOType(typeof(float), () => new FloatOutputUi());
    RegisterIOType(typeof(bool), () => new BoolOutputUi());
    RegisterIOType(typeof(string), () => new StringOutputUi());

    // Vector types
    RegisterIOType(typeof(Vector2), () => new VectorOutputUi<Vector2>());
    RegisterIOType(typeof(Vector3), () => new VectorOutputUi<Vector3>());

    // Texture types
    RegisterIOType(typeof(Texture2D), () => new Texture2dOutputUi());

    // Complex types
    RegisterIOType(typeof(Command), () => new CommandOutputUi());
    // ... and so on
}
```

This happens at startup, before any symbols are loaded. By the time the editor needs to display outputs, the registry is fully populated with all the known types.

The timing matters. If you try to create an OutputUi before registration happens, you'll get the fallback instead of the specialized renderer.

```
Program.Main()
    │
    └─── UiRegistration.RegisterUiTypes()  ← Registration phase
            │
            ├─── OutputUiFactory.Instance.AddFactory(float, ...)
            ├─── OutputUiFactory.Instance.AddFactory(Texture2D, ...)
            └─── ... (all types registered)

Later:
    │
    └─── SymbolUi.Load()  ← Creation phase
            │
            └─── OutputUiFactory.Instance.CreateFor(outputType)
                     │
                     └─── Returns FloatOutputUi (if registered)
                          or ValueOutputUi<T> (if unknown)
```

---

## The Fallback: ValueOutputUi<T>

When a type isn't registered, the factory creates `ValueOutputUi<T>`. This is a minimal implementation that works for any type:

```csharp
internal sealed class ValueOutputUi<T> : OutputUi<T>
{
    protected override void DrawTypedValue(ISlot slot, string viewId)
    {
        if (slot is not Slot<T> typedSlot)
            return;

        var value = typedSlot.Value;

        // Display type information
        ImGui.TextUnformatted($"Type: {typeof(T).Namespace}.{typeof(T).Name}");

        // Display value using ToString()
        if (value != null)
            ImGui.TextUnformatted(value.ToString());
        else
            ImGui.TextUnformatted("NULL");
    }
}
```

This ensures the system never crashes on an unknown type. You'll see something - even if it's just the type name and a string representation. It's not pretty, but it's functional.

The key insight is that the fallback is *generic*. When the factory creates `ValueOutputUi<MyCustomType>`, it preserves the type parameter. This means the slot cast `slot is Slot<T>` works correctly, and `typeof(T)` shows the actual type name.

Compare this to what would happen without generics:

```csharp
// Without generics - loses type information
return new GenericOutputUi(type);  // Can't cast slot properly!

// With generics - preserves type
return new ValueOutputUi<MyCustomType>();  // Slot<MyCustomType> cast works!
```

---

## Thread Safety: Why ConcurrentDictionary?

The factory uses `ConcurrentDictionary` instead of a regular `Dictionary`:

```csharp
private readonly ConcurrentDictionary<Type, Func<T>> _entries = new();
```

You might wonder: does this matter if registration happens at startup before any threading?

The answer is yes, for a subtle reason. While registration is single-threaded, *creation* can happen from multiple threads. Multiple views might try to create OutputUis simultaneously. Multiple operators might evaluate in parallel.

`ConcurrentDictionary` ensures:
- Safe reads from multiple threads simultaneously
- Safe writes (if late registration ever happens)
- No locks needed for the common case (lookups)

This is defensive programming - even if the current usage is single-threaded, the implementation is ready for future changes.

---

## The Complete Resolution Flow

Let's trace what happens when the editor asks for a renderer:

**Case 1: Known type (float)**
```
CreateFor(typeof(float))
    │
    ├─── Check _entries dictionary
    │    └─── Found! Key: float, Value: () => new FloatOutputUi()
    │
    └─── Return factory()  →  new FloatOutputUi()
```

**Case 2: Unknown type (MyCustomType)**
```
CreateFor(typeof(MyCustomType))
    │
    ├─── Check _entries dictionary
    │    └─── Not found
    │
    ├─── AddFactory(MyCustomType, null)
    │    │
    │    ├─── _defaultType = ValueOutputUi<>
    │    ├─── Close generic: ValueOutputUi<MyCustomType>
    │    ├─── CompileFactory(ValueOutputUi<MyCustomType>)
    │    │    └─── Create expression tree and compile to delegate
    │    │
    │    └─── Cache in _entries for next time
    │
    └─── Return factory()  →  new ValueOutputUi<MyCustomType>()
```

Notice that Case 2 only does the expensive work once. The next time `MyCustomType` is requested, it's a simple dictionary lookup.

---

## Why This Design Over Alternatives

You might be thinking: why not just use polymorphism? Have each type implement an interface that knows how to render itself?

The problem is **separation of concerns**. The `float` type shouldn't know about ImGui. The `Texture2D` class shouldn't know about the editor's canvas system. Data types are about *computation*, not visualization.

The factory pattern keeps visualization code in the editor, separate from the types being visualized. You can:
- Change the editor without touching operator code
- Have different editors with different visualizations
- Test data types without any UI dependencies

Another alternative would be a service locator pattern, where each type registers itself. But that would require every data type to know about the OutputUi system - violating the same separation of concerns.

The factory pattern is the clean solution: a single registry that knows about both sides but keeps them separate.

---

## Adding Your Own Type

If you create a custom type and want specialized visualization:

```csharp
// During initialization (before any symbols load)
OutputUiFactory.Instance.AddFactory(
    typeof(MyType),
    () => new MyTypeOutputUi()
);
```

Or let the factory create a fallback automatically:

```csharp
// Just use it - factory creates ValueOutputUi<MyType>
var outputUi = OutputUiFactory.Instance.CreateFor(typeof(MyType));
```

The first option gives specialized visualization. The second gives basic visualization with no extra code.

---

## Summary

The factory pattern solves the "which renderer for which type" problem elegantly:

1. **Registration** at startup populates a type-to-factory dictionary
2. **Creation** at runtime is just a dictionary lookup
3. **Fallback** via open generics handles unknown types gracefully
4. **Expression compilation** makes creation fast after one-time setup
5. **Thread safety** via ConcurrentDictionary handles concurrent access

The result is a system where adding new types is easy (just register them), unknown types work automatically (via fallback), and the common case (looking up known types) is extremely fast.

---

## What's Next

Now that you understand how renderers are selected and created, the next chapter explores what those renderers must do:

- **[Chapter 3: Base Classes](03-base-classes.md)** - The contract defined by IOutputUi and OutputUi<T>, and how the template method pattern structures the render flow

