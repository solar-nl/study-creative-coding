# Babylon.js API Design

> TypeScript patterns that make a 2-million-line engine usable

---

## The Problem: Complexity at Scale

Babylon.js has thousands of classes, hundreds of methods per class, and supports everything from simple cubes to AAA game engines. How do you make this learnable? How do you prevent users from drowning in options?

The answer isn't simplicity — you can't make a full-featured engine simple. The answer is **progressive disclosure**: easy things are easy, complex things are possible, and the path between them is gradual.

Babylon's API reflects this philosophy. Creating a spinning cube takes 10 lines. Adding shadows takes 3 more. Adding PBR materials, another 5. Each step builds on the last without rewriting what came before.

Understanding these patterns helps when designing any creative coding API.

---

## The Mental Model: Russian Nesting Dolls

Think of Babylon's API like matryoshka dolls. The outermost doll is simple: `MeshBuilder.CreateBox()`. Inside that is a more detailed doll: `new Mesh()` with vertex data. Inside that, individual buffer creation. Inside that, raw WebGL or WebGPU calls.

Most users only need the outer dolls. But when you need control, the inner dolls are accessible. And importantly, the dolls nest cleanly — you can mix high-level boxes with low-level custom geometry in the same scene.

---

## Pattern 1: Factory Methods with Options

Creating objects uses factory methods that accept options objects:

### Simple Case

```typescript
const box = MeshBuilder.CreateBox("myBox", {}, scene);
```

One line. Default size, position, material. The empty options object `{}` means "use defaults."

### Customized Case

```typescript
const box = MeshBuilder.CreateBox("myBox", {
    width: 2,
    height: 3,
    depth: 1,
    faceColors: [
        new Color4(1, 0, 0, 1),  // front
        new Color4(0, 1, 0, 1),  // back
        // ...
    ],
    updatable: true,
}, scene);
```

Same method, more options. No need to remember parameter order or set unused values.

### Why This Works

**Discoverability:** IDE autocomplete shows all available options.

**Forward compatibility:** New options can be added without breaking existing code.

**Self-documenting:** `{ width: 2, height: 3 }` is clearer than `(2, 3)`.

### Rust Translation

```rust
#[derive(Default)]
pub struct BoxOptions {
    pub width: f32,
    pub height: f32,
    pub depth: f32,
    pub updatable: bool,
    // ...
}

impl MeshBuilder {
    pub fn create_box(name: &str, options: BoxOptions, scene: &Scene) -> Mesh {
        let options = BoxOptions {
            width: options.width.max(1.0),  // Default handling
            ..options
        };
        // ...
    }
}

// Usage
let box = MeshBuilder::create_box("box", BoxOptions::default(), &scene);
let custom = MeshBuilder::create_box("custom", BoxOptions {
    width: 2.0,
    height: 3.0,
    ..Default::default()
}, &scene);
```

---

## Pattern 2: Method Chaining with Fluent API

Many Babylon operations return `this`, enabling chaining:

```typescript
mesh
    .setPosition(new Vector3(0, 1, 0))
    .setRotation(new Vector3(0, Math.PI / 4, 0))
    .setScaling(new Vector3(2, 2, 2))
    .setEnabled(true);
```

### When Chaining Works

- **Setters that modify state** — Each call changes the object
- **Operations that commonly sequence** — Position, rotation, scale often set together
- **When order doesn't matter** — Can set position before or after rotation

### When Chaining Breaks Down

- **Methods with meaningful return values** — Can't chain if you need the result
- **Error-prone operations** — Chaining obscures which step failed
- **Conditional logic** — Hard to chain with if/else

### Rust Translation

```rust
impl Mesh {
    pub fn set_position(mut self, pos: Vector3) -> Self {
        self.position = pos;
        self
    }

    pub fn set_rotation(mut self, rot: Vector3) -> Self {
        self.rotation = rot;
        self
    }
}

// Usage
let mesh = Mesh::new("cube")
    .set_position(Vector3::new(0.0, 1.0, 0.0))
    .set_rotation(Vector3::new(0.0, PI / 4.0, 0.0));
```

For mutable references (more common in Rust):

```rust
impl Mesh {
    pub fn set_position(&mut self, pos: Vector3) -> &mut Self {
        self.position = pos;
        self
    }
}

// Usage
mesh
    .set_position(Vector3::new(0.0, 1.0, 0.0))
    .set_rotation(Vector3::new(0.0, PI / 4.0, 0.0));
```

---

## Pattern 3: Observable Events

Babylon uses observables (reactive event streams) for lifecycle and interaction:

```typescript
scene.onBeforeRenderObservable.add(() => {
    mesh.rotation.y += 0.01;
});

mesh.onPointerPickObservable.add((pointerInfo) => {
    console.log("Mesh clicked!", pointerInfo);
});

engine.onResizeObservable.add(() => {
    camera.aspectRatio = engine.getRenderWidth() / engine.getRenderHeight();
});
```

### Observable vs Callback

**Callbacks:** One handler per event. Setting a new callback replaces the old one.

```typescript
// Problem: second handler replaces first
mesh.onPicked = () => console.log("A");
mesh.onPicked = () => console.log("B");  // Only B runs
```

**Observables:** Multiple handlers. Adding doesn't replace.

```typescript
mesh.onPickedObservable.add(() => console.log("A"));
mesh.onPickedObservable.add(() => console.log("B"));  // Both run
```

### Observable Benefits

- **Decoupled code** — Multiple systems can react to one event
- **Lifecycle management** — Remove individual handlers without affecting others
- **Filtering** — Observers can have masks and priority

### Rust Translation

```rust
use std::sync::Arc;
use parking_lot::Mutex;

pub struct Observable<T> {
    observers: Arc<Mutex<Vec<Box<dyn Fn(&T) + Send>>>>,
}

impl<T> Observable<T> {
    pub fn add<F>(&self, callback: F) -> ObserverHandle
    where
        F: Fn(&T) + Send + 'static,
    {
        let mut observers = self.observers.lock();
        observers.push(Box::new(callback));
        ObserverHandle { /* ... */ }
    }

    pub fn notify(&self, data: &T) {
        let observers = self.observers.lock();
        for observer in observers.iter() {
            observer(data);
        }
    }
}
```

---

## Pattern 4: Hierarchical Defaults

Babylon uses cascading defaults where children inherit from parents:

```typescript
// Scene-level default
scene.defaultMaterial = new StandardMaterial("default", scene);

// Mesh without material uses scene default
const box = MeshBuilder.CreateBox("box", {}, scene);
// box.material === scene.defaultMaterial

// Mesh with explicit material overrides
const sphere = MeshBuilder.CreateSphere("sphere", {}, scene);
sphere.material = new PBRMaterial("pbr", scene);
// sphere.material !== scene.defaultMaterial
```

### Hierarchy Chain

```
Engine
  └── Scene
       ├── Default material
       ├── Default camera
       ├── Ambient light
       └── Fog settings
            └── Mesh
                 └── Override specific properties
```

### Why This Works

- **Reasonable out-of-box behavior** — Things work without configuration
- **Easy bulk changes** — Change scene default, all inheritors update
- **Explicit overrides** — When you need something specific, just set it

### Rust Translation

```rust
pub struct Scene {
    default_material: Arc<dyn Material>,
    meshes: Vec<Mesh>,
}

pub struct Mesh {
    material: Option<Arc<dyn Material>>,  // None = use scene default
}

impl Mesh {
    pub fn effective_material(&self, scene: &Scene) -> &dyn Material {
        self.material
            .as_ref()
            .map(|m| m.as_ref())
            .unwrap_or(scene.default_material.as_ref())
    }
}
```

---

## Pattern 5: Lazy Initialization

Babylon delays expensive operations until actually needed:

```typescript
// Material created, but shader not compiled yet
const material = new StandardMaterial("mat", scene);
material.diffuseColor = new Color3(1, 0, 0);

// Shader compiles here, first time material is used
mesh.material = material;
scene.render();  // isReadyForSubMesh() triggers compilation
```

### Where Lazy Init Appears

- **Shader compilation** — First render that uses the material
- **Texture loading** — Starts async, renders once loaded
- **Buffer creation** — First draw that needs the buffer
- **World matrix computation** — Only when transform changes

### isReady Pattern

Many objects have `isReady()` or `isReadyForSubMesh()`:

```typescript
// Material checks if it can render
if (!material.isReadyForSubMesh(mesh, subMesh, instances)) {
    return;  // Skip this frame, try again next
}
```

This enables:
- **Non-blocking loading** — Scene renders partially while assets load
- **Automatic retry** — Framework keeps checking until ready
- **No explicit load/wait** — Just create and use

### Rust Translation

```rust
pub struct Material {
    shader: OnceCell<CompiledShader>,
    // ...
}

impl Material {
    pub fn is_ready(&self, device: &Device) -> bool {
        self.shader.get_or_try_init(|| {
            self.compile_shader(device)
        }).is_ok()
    }

    pub fn get_shader(&self) -> Option<&CompiledShader> {
        self.shader.get()
    }
}
```

---

## Pattern 6: Mixins and Extensions

Babylon extends core classes without modifying them using side-effect imports:

```typescript
// Core mesh has basic functionality
import { Mesh } from "@babylonjs/core/Meshes/mesh";

// Import adds physics methods to Mesh prototype
import "@babylonjs/core/Physics/physicsEngineComponent";

// Now mesh has physics methods
mesh.physicsImpostor = new PhysicsImpostor(mesh, PhysicsImpostor.BoxImpostor);
```

### How It Works

The side-effect import runs code that patches the prototype:

```typescript
// In physicsEngineComponent.ts
declare module "./mesh" {
    interface Mesh {
        physicsImpostor: PhysicsImpostor | null;
    }
}

Mesh.prototype.physicsImpostor = null;
```

### Benefits

- **Tree shaking** — Only imported features add to bundle
- **Modular codebase** — Features in separate files
- **Discoverable** — IDE shows augmented methods

### Rust Alternative: Traits

```rust
// Core mesh
pub struct Mesh {
    // ...
}

// Physics extension
pub trait PhysicsBody {
    fn add_physics(&mut self, impostor: PhysicsImpostor);
    fn apply_force(&mut self, force: Vector3);
}

impl PhysicsBody for Mesh {
    fn add_physics(&mut self, impostor: PhysicsImpostor) {
        // ...
    }

    fn apply_force(&mut self, force: Vector3) {
        // ...
    }
}

// Usage
use physics::PhysicsBody;  // Import trait to use methods
mesh.add_physics(PhysicsImpostor::box_impostor());
```

---

## Pattern 7: Dispose Pattern

Babylon explicitly manages resource cleanup:

```typescript
// Create resources
const material = new StandardMaterial("mat", scene);
const texture = new Texture("image.png", scene);
material.diffuseTexture = texture;

// Clean up when done
material.dispose();  // Also disposes texture if not shared
```

### Dispose Chains

Disposing a parent can dispose children:

```typescript
scene.dispose();  // Disposes all meshes, materials, textures
mesh.dispose();   // Disposes geometry, doesn't dispose shared material
```

### Why Not Garbage Collection?

GPU resources aren't garbage collected. A texture holds GPU memory until explicitly released. Babylon's `dispose()` ensures deterministic cleanup.

### Rust Translation

Rust's ownership model handles this naturally:

```rust
{
    let texture = Texture::new("image.png", &device);
    let material = StandardMaterial::new(texture);
    // Use material...
}  // Both dropped here, GPU resources freed

// Or explicit drop
drop(material);  // Frees now, doesn't wait for scope exit
```

---

## Pattern 8: Clone vs Instance

Babylon distinguishes between copies and references:

```typescript
// Clone: independent copy
const meshClone = originalMesh.clone("clone");
meshClone.material = differentMaterial;  // Doesn't affect original

// Instance: shares geometry, unique transform
const meshInstance = originalMesh.createInstance("instance");
// meshInstance can't have different geometry

// Thin Instance: shares everything, just different transform
originalMesh.thinInstanceAdd(matrix);
// No new mesh object, just transform matrix
```

### Performance Implications

| Method | Geometry | Material | Transform | Draw Calls |
|--------|----------|----------|-----------|------------|
| Clone | Copy | Independent | Independent | +1 |
| Instance | Shared | Shared | Independent | +1 (batched) |
| Thin Instance | Shared | Shared | Independent | +0 |

1000 trees:
- 1000 clones = 1000 draw calls
- 1000 instances = ~100 draw calls (batched)
- 1000 thin instances = 1 draw call

### Rust Translation

```rust
pub struct Mesh {
    geometry: Arc<Geometry>,  // Shared
    material: Arc<dyn Material>,  // Shared
    transform: Transform,  // Unique
}

impl Mesh {
    pub fn clone(&self) -> Mesh {
        Mesh {
            geometry: Arc::new((*self.geometry).clone()),
            material: Arc::clone(&self.material),
            transform: self.transform.clone(),
        }
    }

    pub fn create_instance(&self) -> MeshInstance {
        MeshInstance {
            source: Arc::clone(&self.source),
            transform: Transform::identity(),
        }
    }
}
```

---

## Pattern 9: Serialization

Babylon objects serialize to JSON for saving and loading:

```typescript
// Serialize
const serialized = SceneSerializer.Serialize(scene);
const json = JSON.stringify(serialized);

// Deserialize
const data = JSON.parse(json);
const scene = SceneLoader.Load("", data, engine);
```

### How It Works

Each class implements serialization:

```typescript
class StandardMaterial {
    serialize(): any {
        return {
            name: this.name,
            diffuseColor: this.diffuseColor.asArray(),
            specularColor: this.specularColor.asArray(),
            // ...
        };
    }

    static Parse(source: any, scene: Scene): StandardMaterial {
        const material = new StandardMaterial(source.name, scene);
        material.diffuseColor = Color3.FromArray(source.diffuseColor);
        // ...
        return material;
    }
}
```

### Rust Translation

```rust
use serde::{Serialize, Deserialize};

#[derive(Serialize, Deserialize)]
pub struct StandardMaterial {
    pub name: String,
    pub diffuse_color: [f32; 3],
    pub specular_color: [f32; 3],
    // ...
}

// Automatic serialization
let json = serde_json::to_string(&material)?;
let loaded: StandardMaterial = serde_json::from_str(&json)?;
```

---

## Pattern 10: Inspector Integration

Babylon's Inspector reveals internal state at runtime:

```typescript
scene.debugLayer.show();
```

This opens a panel showing:
- Scene hierarchy
- Material properties (editable!)
- Performance metrics
- GPU state

### How Properties Are Exposed

Decorators mark inspector-editable properties:

```typescript
class StandardMaterial {
    @serialize()
    @expandToProperty("_markAllSubMeshesAsLightsDirty")
    public diffuseColor = new Color3(1, 1, 1);
}
```

### Why This Matters

- **Debugging** — See actual values, not just code
- **Tweaking** — Adjust parameters live, then copy to code
- **Learning** — Explore what properties exist

### Rust Alternative: Debug UI

```rust
use egui;

pub trait Inspectable {
    fn inspect(&mut self, ui: &mut egui::Ui);
}

impl Inspectable for StandardMaterial {
    fn inspect(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            ui.label("Diffuse:");
            ui.color_edit_button_rgb(&mut self.diffuse_color);
        });
        // ...
    }
}
```

---

## API Design Principles Summary

| Principle | Babylon Pattern | Rust Equivalent |
|-----------|-----------------|-----------------|
| Progressive disclosure | Factory methods with options | Builder pattern, Default trait |
| Fluent operations | Method chaining returning this | Methods returning Self or &mut Self |
| Event handling | Observables with multiple listeners | Channels, callbacks, or reactive crate |
| Cascading config | Hierarchical defaults | Option<T> with fallback chains |
| Lazy loading | isReady() pattern | OnceCell, lazy_static |
| Extension | Side-effect imports, mixins | Trait implementations |
| Cleanup | dispose() method | Drop trait, explicit cleanup |
| Copying | clone/instance distinction | Clone trait, Arc for sharing |
| Persistence | JSON serialization | serde |
| Debugging | Inspector decorators | Debug trait, egui integration |

---

## Key Takeaways for wgpu Framework

1. **Options objects are powerful** — Use Rust's Default trait and struct initialization
2. **Method chaining improves ergonomics** — Return self for setters
3. **Observables beat callbacks** — Multiple listeners, clean removal
4. **Lazy initialization hides complexity** — Compile shaders on first use
5. **Distinguish shared vs owned** — Arc<T> vs T, instances vs clones
6. **Serialize everything useful** — serde makes this easy
7. **Build an inspector** — egui or similar for runtime debugging

---

## Source File Reference

| Pattern | Example Location |
|---------|------------------|
| Factory methods | `Meshes/Builders/boxBuilder.ts` |
| Method chaining | `Meshes/mesh.ts` (setPosition, etc.) |
| Observables | `Misc/observable.ts` |
| Defaults | `scene.ts` (defaultMaterial) |
| Lazy init | `Materials/material.ts` (isReadyForSubMesh) |
| Dispose | `Meshes/mesh.ts`, `Materials/material.ts` |
| Clone/Instance | `Meshes/mesh.ts` |
| Serialization | `Misc/sceneSerializer.ts` |
| Inspector | `Debug/debugLayer.ts` |

All paths relative to: `packages/dev/core/src/`
