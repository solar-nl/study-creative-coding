# Three.js API Design

> Why the way you name things shapes how people think about them

---

## The Problem: Designing an API for 3D Graphics

Here is a challenge: you are building a 3D graphics library that will be used by millions of developers. Some are hobbyists making their first WebGL experiment. Some are professionals building complex visualizations. Some know nothing about graphics programming. Some have decades of OpenGL experience.

How do you design an API that serves all of them?

This is not just about picking good names. Every API decision is a trade-off. Do you expose the full power of the underlying graphics system, or do you hide complexity behind friendly abstractions? Do you follow the conventions of the web platform, or the conventions of computer graphics academia? Do you optimize for discoverability (can a beginner figure out what to do?) or for expressiveness (can an expert do everything they need?)?

Three.js has been making these decisions for over a decade, and its choices reveal a coherent philosophy: progressive disclosure. The simple things are simple. The complex things are possible. And you do not need to understand the complex things to use the simple ones.

---

## The Mental Model: A Vocabulary for 3D

Think of Three.js's API as a vocabulary for talking about 3D scenes. Like any language, it has nouns (Scene, Mesh, Light), verbs (add, remove, lookAt), and adjectives (visible, castShadow).

The brilliance of a well-designed vocabulary is that it lets you think at the right level of abstraction. You do not say "emit photons at 550 nanometers wavelength in a hemispherical distribution pattern." You say "add a green light." The vocabulary matches the mental model of the domain.

Three.js's naming conventions are not arbitrary. They encode decades of accumulated wisdom about how to think about 3D graphics:

- **PascalCase for classes** tells you "this is a thing you can create"
- **camelCase for methods** tells you "this is an action you can perform"
- **Boolean properties named for their true state** (visible, not hidden) match natural language
- **Suffixes that reveal relationships** (MeshStandardMaterial works with Mesh) help you navigate

---

## The Philosophy: Progressive Disclosure

Three.js's API follows a principle called progressive disclosure. The surface is simple. The depths are vast. You only encounter complexity when you need it.

Watch how each constructor signature matches its domain's needs:

```javascript
// Geometry: just dimensions
new BoxGeometry(1, 1, 1);

// Material: named options
new MeshStandardMaterial({ color: 0xff0000, metalness: 0.5 });

// Camera: frustum parameters
new PerspectiveCamera(75, aspect, 0.1, 1000);
```

These three constructors have different signatures, but each makes sense for its domain. Geometries are defined by dimensions, so positional arguments work. Materials have many optional properties, so an options object is cleaner. Cameras need exactly four numbers that define the frustum, and the order matters mathematically.

The alternative would be rigid consistency. Every constructor could take an options object. Every class could have the same initialization pattern. But that would be worse. It would add ceremony to simple cases (why wrap a single number in an object?) and obscure the semantic meaning of parameters.

The key insight: consistency should serve comprehension, not the other way around. Being consistent for consistency's sake can actually make an API harder to understand.

---

## Alternative Approaches: What Could They Have Done?

To understand Three.js's choices, consider the alternatives:

### 1. The Low-Level Approach (like WebGL raw)

```javascript
// What WebGL looks like
gl.bindBuffer(gl.ARRAY_BUFFER, positionBuffer);
gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(positions), gl.STATIC_DRAW);
gl.vertexAttribPointer(positionAttributeLocation, 3, gl.FLOAT, false, 0, 0);
gl.enableVertexAttribArray(positionAttributeLocation);
// ... 50 more lines to draw a single triangle
```

This is maximally flexible but requires understanding GPU state machines, buffer binding points, and the precise order of operations. Three.js abstracts this entirely. The trade-off: power users cannot optimize at the GL level (though the WebGPU backend changes this somewhat).

### 2. The Declarative Approach (like React Three Fiber)

```jsx
<mesh position={[0, 0, 0]}>
  <boxGeometry args={[1, 1, 1]} />
  <meshStandardMaterial color="red" />
</mesh>
```

This is how React Three Fiber wraps Three.js. It is declarative rather than imperative. You describe what you want, not how to create it. The trade-off: harder to express complex procedural logic, and it requires understanding a different paradigm.

### 3. The Entity-Component-System Approach (like PlayCanvas or Bevy)

```javascript
const entity = app.root.addChild(new Entity());
entity.addComponent('render', { type: 'box' });
entity.addComponent('rigidbody', { type: 'dynamic' });
```

ECS treats everything as an entity with attached components. This is composition over inheritance. The trade-off: less obvious what an entity "is" (a Mesh feels like a thing; an entity with a render component feels like a bag of properties).

Three.js chose classical object-oriented design: a Mesh is a concrete thing that has geometry and material. This matches how artists think about 3D scenes better than components do. Whether that is "right" depends on your users.

Each approach solves the same fundamental problem—getting geometry rendered to screen—but makes different trade-offs. WebGL raw optimizes for control. React Three Fiber optimizes for declarative composition. ECS optimizes for runtime flexibility. Three.js optimizes for intuition. The "best" choice depends on your audience and use case.

---

## Concrete Patterns in Action

### The Geometry + Material = Mesh Pattern

This is Three.js's most fundamental abstraction:

```javascript
const geometry = new BoxGeometry(1, 1, 1);
const material = new MeshStandardMaterial({ color: 0xff0000 });
const mesh = new Mesh(geometry, material);
```

Why separate geometry from material? Because they change at different rates and for different reasons.

**Geometry describes shape.** A box is 1x1x1. It has vertices at specific positions, normals pointing outward, UVs for texturing. This rarely changes at runtime.

**Material describes appearance.** Red, shiny, transparent. This might change every frame (pulsing effects) or when the user interacts (hover states).

**Mesh combines them.** A specific red box at a specific position. Multiple meshes can share the same geometry (instancing) or the same material (consistent style).

The alternative would be a monolithic object:

```javascript
// Hypothetical combined API
new RenderableBox({
  width: 1, height: 1, depth: 1,
  color: 0xff0000, metalness: 0.5
});
```

This is simpler for the common case but falls apart for complex cases. What if you want 1000 boxes with different colors? With separate geometry and material, you create one geometry and 1000 materials. With the combined API, you create 1000 complete objects, duplicating vertex data.

### The Scene Graph: add() and remove()

```javascript
const group = new Group();
group.add(mesh1, mesh2, mesh3);
scene.add(group);

// Later
group.remove(mesh2);
```

The scene graph is a tree. Objects have parents and children. Transforms are hierarchical. Moving a group moves all its children.

This matches the mental model of "things in a scene." A car has wheels. Moving the car moves the wheels. You do not need to update each wheel separately.

Let's trace what happens when you call `scene.add(mesh)`:

1. **Parent assignment** — The mesh's `parent` property is set to the scene
2. **Children update** — The mesh is added to the scene's `children` array
3. **Event dispatch** — The mesh fires an `added` event, the scene fires a `childadded` event
4. **Matrix invalidation** — The mesh's `matrixWorldNeedsUpdate` flag is set to true
5. **Next render** — During the render loop, `updateMatrixWorld()` walks the tree and recomputes world transforms for any invalidated nodes

This lazy evaluation is key to performance. You can add and remove many objects between frames, but matrix math only happens once per render.

The alternative would be a flat list with explicit transforms:

```javascript
// Hypothetical flat API
scene.addObject(mesh1, { transform: carTransform.compose(wheelTransform) });
// Every frame:
mesh1.setTransform(carTransform.compose(wheelTransform));
```

More explicit, but more tedious for the common case of nested objects.

### Method Chaining: Fluent Returns

```javascript
vector.add(other).normalize().multiplyScalar(2);
```

Math operations return `this`, allowing chains. This reads like a sentence: "add other, normalize, multiply by 2."

The alternative is separate statements:

```javascript
vector.add(other);
vector.normalize();
vector.multiplyScalar(2);
```

The chained version is more concise and makes the operation sequence explicit. The separate version is easier to debug (you can inspect intermediate values).

Three.js's choice to enable chaining does not prevent the separate style. You can still break it into lines. This is progressive disclosure again: the simple case is concise, the debug case is possible.

---

## The Naming System

### Class Naming: Hierarchy in the Name

```
MeshBasicMaterial
MeshStandardMaterial
MeshPhysicalMaterial
MeshDepthMaterial
```

Notice the pattern: `Mesh` + `Adjective` + `Material`. The prefix tells you what it works with. The adjective tells you the quality level or purpose.

This is a design decision. The alternative would be:

```
BasicMaterial
StandardMaterial
PhysicalMaterial
```

Shorter, but now you need to remember which materials work with which objects. The prefix is documentation in the name itself.

The same pattern appears in geometries:

```
BoxGeometry
SphereGeometry
PlaneGeometry
CylinderGeometry
```

And in helpers:

```
BoxHelper
CameraHelper
DirectionalLightHelper
```

The suffix system creates families of related classes. You can often guess what something does from its name.

### Method Naming: Verbs and Conventions

```javascript
lookAt(target)           // verb: do this action
setFromAxisAngle(...)    // verb + from: construct from
updateMatrixWorld()      // verb + what: update this aspect
clone()                  // verb: create copy
dispose()                // verb: release resources
```

The verbs are consistent:
- `set*` mutates in place
- `get*` retrieves data
- `add*` / `remove*` modify collections
- `update*` recalculates derived state
- `clone` creates copies
- `dispose` releases GPU resources

This vocabulary, once learned, applies everywhere. You do not need to remember whether to call `geometry.free()` or `geometry.destroy()` or `geometry.release()`. It is always `dispose()`.

---

## Error Handling: Soft Failures and Console Warnings

Three.js takes a forgiving approach to errors:

```javascript
// Missing texture shows magenta
const material = new MeshBasicMaterial({ map: nonExistentTexture });

// Deprecated features warn, do not throw
// Console: "THREE.Geometry has been removed. Use THREE.BufferGeometry instead."
```

This is a deliberate choice. The alternative is strict validation:

```javascript
// Hypothetical strict API
if (!texture.isLoaded) {
  throw new Error("Cannot create material with unloaded texture");
}
```

Strict validation catches errors early but also crashes the app for recoverable issues. The magenta texture is ugly, but the scene still renders. The user can see something is wrong and fix it. The alternative is a blank screen with an error in the console that a beginner might not know to check.

The trade-off: soft failures can hide bugs. A missing texture in production might go unnoticed for months if no one looks closely at that particular model. Three.js trusts developers to notice visual anomalies rather than catching them programmatically.

---

## wgpu Considerations: Designing a Rust API

How would you apply Three.js's lessons to a Rust creative coding library?

### Builder Pattern Instead of Config Objects

JavaScript's options objects translate naturally to builders in Rust:

```rust
// JavaScript
new MeshStandardMaterial({
    color: 0xff0000,
    metalness: 0.5,
    roughness: 0.3
});

// Rust equivalent
MeshStandardMaterial::builder()
    .color(Color::from_hex(0xff0000))
    .metalness(0.5)
    .roughness(0.3)
    .build()
```

Builders give you compile-time validation, IDE autocomplete, and the ability to enforce required fields.

### Method Chaining with Ownership

Three.js returns `this` for chaining. In Rust, you have choices:

```rust
// Option 1: Return &mut Self (borrow)
vector.add(&other).normalize().scale(2.0);

// Option 2: Return Self (move)
let vector = vector.add(other).normalize().scale(2.0);
```

The borrow approach matches JavaScript's behavior. The move approach is more functional and plays better with immutable data patterns. Each has trade-offs.

### Type-Enforced Separation

Rust's type system can enforce the geometry/material separation that Three.js uses by convention:

```rust
// Geometry and material are different types
struct Mesh<G: Geometry, M: Material> {
    geometry: G,
    material: M,
}

// Compiler prevents mixing incompatible combinations
let mesh: Mesh<BoxGeometry, MeshStandardMaterial> = ...;
```

This is stricter than JavaScript but catches errors at compile time rather than runtime.

### Scene Graph Patterns

Three.js's add/remove pattern is tricky in Rust because of ownership. Common approaches:

```rust
// Arena-based (like generational-arena)
let node_id = scene.add(mesh);
let child_id = scene.add_child(node_id, another_mesh);

// ECS-based (like bevy)
commands.spawn((Transform::default(), Mesh::default()));
```

Neither feels exactly like Three.js's `scene.add(mesh)`, but both handle the ownership semantics correctly.

### Event System

Three.js uses EventDispatcher:

```javascript
object.addEventListener('removed', callback);
```

In Rust, common patterns include:

```rust
// Callback-based (requires Rc/RefCell or channels)
object.on_removed(|event| { ... });

// Channel-based
while let Ok(event) = events.try_recv() {
    match event {
        Event::Removed(obj) => { ... }
    }
}

// Observer pattern via trait objects
impl Observer for MyHandler {
    fn on_removed(&mut self, object: &Object3D) { ... }
}
```

The channel approach plays best with Rust's ownership model.

---

## Trade-offs: What Three.js Sacrifices

Every API choice has costs:

### Flexibility vs. Simplicity

Three.js hides the raw WebGL/WebGPU API. You cannot optimize at the lowest level. You cannot easily implement custom rendering techniques that the architecture does not anticipate. The node material system (TSL) helps, but you are still working within Three.js's mental model.

### Convention vs. Type Safety

JavaScript has no way to enforce that a MeshStandardMaterial only goes with certain objects. You can create nonsensical combinations that fail silently or render incorrectly. TypeScript helps but cannot catch everything.

### Convenience vs. Performance

Soft failures and automatic resource management are convenient but have costs. Checking every operation for errors adds overhead. Automatic disposal via garbage collection is unpredictable. A performance-critical application might need lower-level control.

### Consistency vs. Domain Fit

The different constructor signatures (positional args vs. options objects) reduce consistency. Someone learning the API cannot predict whether a new class will use one pattern or the other. But forcing everything into one pattern would make individual classes harder to use.

---

## Key Insights

### 1. Names Are Design Decisions

Class names like `MeshStandardMaterial` encode relationships. Method names like `updateMatrixWorld()` describe exactly what happens. These names teach users how to think about the system.

### 2. Progressive Disclosure Wins

Simple things should be simple. Complex things should be possible. You should not need to understand the complex things to use the simple things. This is the core of good API design.

### 3. Match the Mental Model

Three.js's API matches how artists and designers think about 3D: scenes contain objects, objects have geometry and appearance, transforms are hierarchical. The API vocabulary mirrors the domain vocabulary.

### 4. Be Forgiving in Development

Soft failures (magenta textures, console warnings) let developers see what went wrong without crashing the app. This is friendlier than strict validation for learning and prototyping.

### 5. Trade-offs Are Inevitable

There is no perfect API. Every choice favors some users over others, some use cases over others. Three.js consistently chooses accessibility over raw power, which is why it succeeded as a mainstream library rather than a specialist tool.

---

## Next Steps

- **[Architecture](./architecture.md)** - How these API patterns manifest in the codebase structure
- **[Rendering Pipeline](./rendering-pipeline.md)** - How the high-level API translates to GPU commands
- **[Node System (TSL)](./node-system.md)** - The material system that enables custom shaders while preserving the simple API

---

## Sources

- `libraries/threejs/src/Three.js` - Main entry point; export structure reveals the public API surface
- `libraries/threejs/src/core/Object3D.js` - Scene graph base; source for add/remove trace and event patterns
- `libraries/threejs/src/materials/Material.js` - Material base; options object pattern and dispose lifecycle
- `libraries/threejs/src/geometries/BoxGeometry.js` - Geometry example; positional constructor pattern
- `libraries/threejs/src/math/Vector3.js` - Math operations; method chaining and mutation patterns
