# apEx Architecture

When you're producing a 64-kilobyte demo that needs to render complex 3D scenes with multiple render passes, particle systems, and synchronized music, every architectural decision carries weight. You can't afford bloated abstractions or redundant systems. Yet you still need a complete production pipeline: a real-time engine for playback, content creation tools for artists, and foundation libraries that don't balloon executable size.

apEx solves this problem by splitting into three distinct layers. The Phoenix engine handles runtime rendering and scene management with a minimal footprint. The Bedrock libraries provide foundational types, DirectX wrappers, and GUI infrastructure that both the engine and tooling consume. And the demotool application ties everything together, giving artists a visual interface to choreograph scenes, materials, and timeline events without writing code.

This architecture matters because most creative coding frameworks bundle everything together. Processing includes its IDE. OpenFrameworks expects you to write code. But demoscene production has different constraints. The runtime player needs to fit in 64KB compressed. The authoring tool can be megabytes because it ships separately. This forces a clean separation between minimal runtime code and full-featured tooling that few other frameworks achieve.

The problem apEx addresses is this: how do you build a complete 3D demo production pipeline where the runtime engine compiles to under 64KB while still providing artists with a powerful visual authoring environment? The solution involves aggressive modularity, compile-time feature selection, and a deliberate split between tool-only code and player-only code that both share a common foundation.

Think of apEx like a film production pipeline. Phoenix is the theater projector that plays back the final movie. It's optimized for one thing: taking pre-computed content and rendering it efficiently. Bedrock is the film stock and camera equipment that both the studio and theater use. And the demotool is the editing suite where directors arrange scenes, apply effects, and orchestrate the final production. The projector doesn't need editing features. The editing suite doesn't need to fit on a delivery truck. But both need compatible film formats.

## Module Overview

apEx organizes into three distinct layers, each with a specific role in the production pipeline.

**Phoenix** is the 64k demo engine. It handles scene graph traversal, material rendering, timeline playback, and procedural content generation. The engine compiles in two modes: minimal build for 64k player executables, and full build for the authoring tool. The minimal build strips out all editor-specific features, debug helpers, and dynamic allocation where possible. Every class has conditional destructors that only exist in full builds.

**Bedrock** provides foundation libraries that both Phoenix and the authoring tool consume. It splits into four major modules. BaseLib defines core types, math primitives, containers, and platform utilities. CoRE2 wraps DirectX 9 and DirectX 11 with a unified API. UtilLib adds higher-level functionality like XML parsing and image loading. Whiteboard implements the GUI system for the authoring tool. This layering means Phoenix can depend on BaseLib and CoRE2 without pulling in GUI code.

**The Demotool** is the visual authoring application artists use to create demos. Built on top of Phoenix and Bedrock, it provides scene editors, material editors, timeline sequencing, and real-time preview. The tool saves projects as compact binary data that the minimal Phoenix player can load. Artists never write code. They connect operators in graphs, adjust splines in curves editors, and preview results in real time.

## Directory Structure

The repository layout mirrors the architectural layers.

```
apex-public/
├── Bedrock/              # Foundation libraries
│   ├── BaseLib/          # Core types and utilities
│   │   ├── Types.h           # TU8, TS32, TF32, TBOOL
│   │   ├── Array.h           # Dynamic array template
│   │   ├── String.h          # String class
│   │   ├── Vector.h          # Math vectors (2D, 3D, 4D)
│   │   ├── Matrix.h          # 4x4 matrices
│   │   ├── Quaternion.h      # Rotation quaternions
│   │   ├── Color.h           # RGBA color
│   │   ├── BBox.h            # Axis-aligned bounding box
│   │   ├── Spline.h          # Spline evaluation
│   │   ├── Random.h          # Random number generation
│   │   ├── Timer.h           # High-precision timing
│   │   ├── Thread.h          # Threading primitives
│   │   └── Memory.h          # Memory management
│   │
│   ├── CoRE2/            # DirectX wrapper (DX9 + DX11)
│   │   ├── Device.h          # Abstract device interface
│   │   ├── DX9Device.h       # DX9 implementation
│   │   ├── DX11Device.h      # DX11 implementation
│   │   ├── Texture.h         # Texture interface
│   │   ├── VertexBuffer.h    # Vertex buffer management
│   │   ├── IndexBuffer.h     # Index buffer management
│   │   ├── Shader.h          # Shader compilation
│   │   ├── RenderState.h     # Blend/depth/rasterizer states
│   │   └── Material.h        # Material techniques (tool-side)
│   │
│   ├── UtilLib/          # Utilities (XML, images, etc.)
│   │   ├── XMLDocument.h     # XML parsing
│   │   └── ExternalLibraries/
│   │       └── openssl/      # Compression libraries
│   │
│   └── Whiteboard/       # GUI system
│       ├── WhiteBoard.h      # Main GUI header
│       ├── Application.h     # GUI application framework
│       ├── Window.h          # Window management
│       ├── Button.h          # Button widget
│       ├── TextBox.h         # Text input
│       ├── TrackBar.h        # Slider control
│       └── ...               # Additional widgets
│
├── apEx/                 # Phoenix engine and tool
│   ├── Phoenix/          # Core 64k engine
│   │   ├── phxEngine.h       # Engine entry point
│   │   ├── Scene.h           # Scene graph
│   │   ├── Model.h           # Mesh objects
│   │   ├── Material.h        # Material system
│   │   ├── Timeline.h        # Event timeline
│   │   ├── RenderLayer.h     # Multi-pass rendering
│   │   ├── RenderTarget.h    # Render-to-texture
│   │   ├── Mesh.h            # Mesh data structures
│   │   ├── Texgen.h          # Procedural textures
│   │   ├── TreeGen.h         # Procedural trees
│   │   ├── phxSpline.h       # Animation splines (float16)
│   │   ├── phxMath.h         # Math utilities
│   │   ├── phxarray.h        # Minimal array container
│   │   └── PhoenixConfig.h   # Feature flags
│   │
│   ├── apEx/             # Authoring tool application
│   │   └── (Tool source files)
│   │
│   └── Libraries/        # Third-party dependencies
│       ├── V2/               # V2 music synthesizer
│       ├── WaveSabre/        # WaveSabre synthesizer
│       ├── Assimp/           # Model import
│       └── MVX/              # Video playback
│
└── Projects/             # Demo projects
    └── (Individual demos)
```

This separation enforces strict dependency boundaries. Bedrock has no dependency on Phoenix. Phoenix depends on BaseLib and CoRE2 but not UtilLib or Whiteboard. The demotool depends on everything. This allows the 64k player to link only Phoenix, BaseLib, and CoRE2, avoiding megabytes of GUI and utility code.

## Phoenix Engine Architecture

Phoenix is the runtime heart of apEx. Every demo built with apEx compiles a version of Phoenix optimized for size, then loads pre-authored content at runtime.

### Timeline-Driven Execution

Demos are fundamentally time-based experiences. Phoenix structures everything around a timeline containing events. Each event has a start frame, end frame, and type. The timeline evaluates which events are active at the current frame, then renders them in sequence.

Event types define what happens during that time range. A `RenderScene` event renders a 3D scene with a specific camera. A `Shadertoy` event runs a fullscreen shader effect. A `ParticleCalc` event updates particle physics. A `CameraShake` event applies procedural camera motion. Events can render to textures, which later events consume as inputs. This enables complex multi-pass effects without manual render target management.

The timeline itself is just data: an array of event structs with type tags and parameters. The engine iterates active events each frame, calling their polymorphic `Render()` method with the current timestamp. Events query spline curves to animate parameters smoothly over time. Everything from camera position to material colors to particle emission rates derives from spline data.

### Scene Graph and Object Hierarchy

A scene contains objects in a parent-child hierarchy. Each object stores a local transformation matrix and animation splines for position, rotation, and scale. During scene graph traversal, the engine accumulates transformations down the hierarchy, computing world matrices for every object.

Objects are polymorphic. The base `CphxObject` class defines the traversal interface and animation evaluation. Derived classes add specific behavior. `CphxObject_Model` creates render instances for meshes. `CphxObject_Light` contributes to the light array. `CphxObject_ParticleEmitter_CPU` simulates particle systems. `CphxObject_SubScene` embeds nested scenes with independent timelines.

The key insight is that object types determine what happens during traversal, but traversal order is always depth-first. Parent transformations always apply before child transformations. Animation always evaluates before rendering. This rigid structure eliminates conditional logic in the core loop, which compresses better and runs faster.

### Material System and Render Layers

Materials in Phoenix are techniques containing multiple passes. A single material might have a base color pass, an environment reflection pass, and a specular highlight pass. Each pass defines complete GPU state: vertex shader, pixel shader, geometry shader, hull shader, domain shader, blend state, rasterizer state, depth-stencil state, and eight texture slots.

During scene traversal, the engine expands materials into render instances. One mesh with a three-pass material generates three independent render instances, each containing all GPU state needed to issue a draw call. This expansion happens early, during scene graph traversal, not during rendering. By the time the render loop executes, every decision is frozen into self-contained instances.

Render layers organize multi-pass rendering. Each material pass targets a specific layer. Layers have independent render target configurations and clear flags. The engine renders all instances in layer 0, then layer 1, then layer 2, sequentially. This enables effects like rendering the scene to a texture (layer 0), blurring it (layer 1), and compositing with the original (layer 2). Artists specify target layers in material definitions. The engine handles sequencing automatically.

### Animation and Spline System

Everything in Phoenix animates via splines. Object transformations, material parameters, camera fields of view, particle emission rates, light colors all derive from spline curves evaluated at the current timestamp. The spline system uses 16-bit floating point values to save memory. A typical spline stores four 16-bit control points and an interpolation mode, compressing to 10 bytes instead of the 20 bytes required by 32-bit floats.

Splines attach to specific object properties via an enum-based targeting system. The `PHXSPLINETYPE` enum defines slots like `Spline_Position_x`, `Spline_Rotation`, `Spline_Light_DiffuseR`, and `Spline_Particle_EmissionPerSecond`. Each object contains a `SplineResults` array indexed by this enum. During animation evaluation, the engine iterates all splines attached to the current clip, evaluates them at time `t`, and writes results into the appropriate array slots.

Material splines work similarly but target material parameters instead of object properties. A material might have a color parameter animated by four splines (RGBA). The engine evaluates these splines, packs the results into the material's animated data buffer, then copies this data into render instances during material expansion.

### Procedural Content Generation

Phoenix includes several procedural generators to create content without storing geometry data. The texture generator creates 2D textures from mathematical functions and filters. The tree generator builds tree geometry using L-system-like rules. The mesh system includes modifiers for subdivision, deformation, and boolean operations.

These generators run in the tool during content authoring. The resulting geometry and textures serialize to compact binary formats. The 64k player loads pre-generated data, not generator code. This is crucial: the generators can be large and complex because they don't ship in the final executable. Only their output matters.

The minimal build conditionally compiles out generator code using preprocessor flags. Features like `PHX_OBJ_SUBSCENE`, `PHX_HAS_PARTICLE_SORTING`, and `PHX_HAS_MESH_PARTICLES` enable or disable specific subsystems. A typical 64k intro might disable subscenes, mesh particles, and several light types, saving kilobytes of code.

## Bedrock Foundation Libraries

Bedrock provides the substrate on which Phoenix builds. The libraries prioritize consistency, minimal overhead, and explicit control over magic and convenience.

### BaseLib: Core Types and Utilities

BaseLib defines the foundational types every module uses. Instead of `int`, code uses `TS32` (signed 32-bit integer). Instead of `unsigned char`, code uses `TU8`. Instead of `float`, code uses `TF32`. This explicitness eliminates platform ambiguity. An `int` might be 16-bit or 32-bit depending on the compiler. A `TS32` is always exactly 32 bits.

The math types follow the same philosophy. `CVector3` is always three 32-bit floats. `CMatrix4x4` is always sixteen floats in row-major order. `CQuaternion` is always four floats in XYZW order. No padding, no alignment surprises, no platform-dependent layouts. This predictability enables direct memory copying and binary serialization without marshaling.

Collections use templates but avoid STL. `CArray<T>` is a dynamic array with explicit control over growth. `CDictionary<K,V>` is a hash table with visible collision handling. `CString` manages character data with reference counting. These containers provide exactly the functionality demos need without the code size overhead of STL's generality.

Memory management is explicit. BaseLib provides `new` and `delete`, but also `FreeArray()`, `Resize()`, and `Reserve()` methods that make allocation visible. The 64k player can use arena allocators or stack-based memory where appropriate because the API doesn't hide allocations behind opaque operations.

### CoRE2: DirectX Abstraction

CoRE2 wraps DirectX 9 and DirectX 11 behind a unified interface. This matters because demos need to run on a wide range of hardware, including older systems with only DX9 support. But the abstraction is thin. It exposes GPU concepts directly rather than inventing new abstractions.

The device interface defines methods like `CreateTexture2D()`, `CreateVertexBuffer()`, `SetPixelShader()`, and `DrawIndexedTriangles()`. These map almost one-to-one with DirectX calls. The difference is that calling these methods dispatches to either a DX9 implementation or a DX11 implementation based on runtime detection. Artists see one API. The engine compiles both backends.

Resource management uses reference counting. Each `CCoreTexture` or `CCoreVertexBuffer` tracks references and self-destructs when the count hits zero. This avoids manual lifecycle management without requiring garbage collection or smart pointers. Resources register with the device on creation and unregister on destruction, allowing the device to release all resources during shutdown.

Render states separate into distinct objects. `CCoreBlendState` encapsulates alpha blending. `CCoreDepthStencilState` controls depth testing. `CCoreRasterizerState` defines culling and fill mode. Materials specify state objects by reference, not by setting individual state flags. This matches how modern GPUs work: state changes are coarse-grained pipeline switches, not fine-grained flag toggles.

### Whiteboard: GUI System

The authoring tool needs a complete GUI system for windows, buttons, sliders, text fields, and custom widgets. Whiteboard provides this using an immediate-mode-inspired API with retained widgets. Widgets store state but rebuild layouts every frame based on current window size and parent constraints.

Applications derive from `CWBApplication` and implement `InitializeGui()` to create the widget hierarchy. Each widget type (button, text box, track bar) inherits from `CWBItem` and handles its own rendering and input. Parent widgets lay out children using box models with margins and padding. Resizing automatically reflows the layout.

The 3D viewport widget deserves special mention. `CWB3DWindow` embeds a CoRE2 device and renders Phoenix scenes inside a GUI panel. This enables real-time preview without launching a separate player executable. Artists adjust parameters in one panel, see results update immediately in another panel. The tight integration between tool UI and engine preview is what makes rapid iteration possible.

## Data Flow: Tool to Player

Understanding how content flows from authoring tool to runtime player illuminates the architecture's design.

Artists create content in the demotool GUI. They build scene graphs by adding objects, assign materials to meshes, animate parameters with spline editors, and arrange timeline events. All of this data lives in memory as C++ objects. When artists save a project, the tool serializes everything to a compact binary format.

The binary format stores objects sequentially with minimal metadata. Arrays store their count followed by raw element data. Strings store length then bytes. Objects store type tags then field data. No JSON. No XML. No human-readable text. The format optimizes for two goals: small file size and fast deserialization. Both matter when fitting a complete demo in 64KB.

The 64k player executable contains the Phoenix engine compiled in minimal mode. At startup, it loads the binary project data, allocates objects, and deserializes content. Scene graphs, materials, textures, meshes all reconstruct from the data stream. Once loaded, the player enters the main loop: advance timeline, evaluate events, render frames, swap buffers.

Crucially, the player contains zero authoring code. No GUI. No editors. No importers. No generators. Just runtime systems: scene graph traversal, material rendering, spline evaluation, particle physics. The separation is absolute. Tool code never compiles into players. This is how a multi-megabyte authoring environment produces a sub-64KB executable.

## Key Abstractions

Several patterns recur throughout the apEx codebase. Understanding these patterns reveals the design philosophy.

### Polymorphic Rendering via Virtual Methods

Phoenix uses virtual methods for polymorphic dispatch during scene traversal. The base `CphxObject` class declares `virtual void CreateRenderDataInstances()`. Derived classes override this to generate render commands appropriate for their type. Mesh objects create render instances. Light objects update the light array. Particle emitters update simulation state.

This approach differs from component-entity-system (ECS) architectures common in modern game engines. Phoenix uses classic object-oriented inheritance because it's simple, compresses well, and has zero runtime overhead beyond one virtual function call per object per frame. ECS systems require dynamic component lookups and cache-unfriendly indirection. For demos with hundreds of objects, not millions, inheritance is faster and smaller.

### Material Expansion Creates Self-Contained Instances

When a mesh object creates render instances, the material system expands each pass into a complete `CphxRenderDataInstance` struct. This struct contains:

- Vertex buffer and index buffer handles
- Five shader stage pointers (vertex, pixel, geometry, hull, domain)
- Three render state objects (blend, rasterizer, depth-stencil)
- Eight texture resource views
- Two transformation matrices (world, inverse-transpose)
- A block of material parameter data

Everything needed to render that object in that pass. No lookups. No state diffing. No conditional logic. The render loop iterates instances and issues draw calls. This trades memory for simplicity and predictability. A scene with 100 meshes and materials averaging three passes generates 300 instances, perhaps 100KB of data. For a demo, that's acceptable.

### Spline-Based Animation

Splines are first-class primitives in Phoenix, not afterthoughts. The `CphxSpline_float16` class stores control points and evaluates curves using Catmull-Rom or Bezier interpolation. Objects allocate spline result arrays sized to hold all possible animated properties. During animation evaluation, the engine iterates splines, evaluates them at the current time, and writes to result arrays.

This design makes time the fundamental dimension. Everything derives from `t`. Camera position at time `t`, material color at time `t`, particle emission rate at time `t`. This is how demos achieve perfectly synchronized motion and music. The timeline is the source of truth. Objects are just slaves to time's progression.

### Conditional Compilation for Size Optimization

Phoenix uses preprocessor macros extensively to enable or disable features. The `PhoenixConfig.h` header defines flags like `PHX_OBJ_MODEL`, `PHX_OBJ_LIGHT`, `PHX_HAS_PARTICLE_SORTING`, and `PHX_EVENT_RENDERSCENE`. Entire subsystems compile to nothing if their flags are disabled.

This is somewhat unusual for modern C++, which prefers templates and constexpr for conditional compilation. But macros are simpler and more transparent to size-optimizing compilers. When `PHX_OBJ_SUBSCENE` is undefined, subscene code doesn't just get inlined away, it never reaches the compiler at all. This guarantees zero code size contribution.

The minimal build defines a much smaller feature set than the full build. Player executables disable debugging, destructors, and optional features. Tool builds enable everything for maximum flexibility during authoring.

## Cross-Module Patterns

Certain patterns appear consistently across Bedrock and Phoenix, creating a unified coding style.

### Explicit Type Naming

Every module uses explicit integer types: `TU8`, `TS16`, `TU32`, `TS64`, `TF32`, `TF64`, `TBOOL`. This eliminates ambiguity and makes data layouts explicit. A `TU16` is always unsigned 16 bits. A `TBOOL` is always an 8-bit boolean stored as an unsigned char, never C++'s implementation-defined `bool` type.

Pointers use Hungarian notation prefixes. `CArray<T>` arrays are named with plural nouns: `Objects`, `Materials`, `Splines`. Counts use the pattern `ObjectCount`, `MaterialCount`, `SplineCount`. This consistency makes code readable even without IDE tooltips. You know `Objects` is a collection, `ObjectCount` is its size, and iterating uses `for (int x = 0; x < ObjectCount; x++)`.

### Minimal Abstraction

Bedrock and Phoenix avoid abstraction for abstraction's sake. There are no factory patterns. No dependency injection. No abstract interfaces with single implementations. If a subsystem needs a texture, it stores a `CCoreTexture2D*`, not an `ITexture` interface pointer. If it needs a mesh, it stores `CphxMesh*`, not a `unique_ptr<IMesh>`.

This directness reduces code size and improves debuggability. Every pointer points to a concrete type. There's no polymorphism unless multiple implementations actually exist. The DX9 vs DX11 split requires polymorphism, so CoRE2 uses abstract interfaces. The scene graph requires polymorphism, so objects use virtual methods. But render instances don't need polymorphism, so they're plain structs.

### Manual Memory Management

apEx predates modern C++ smart pointers and largely eschews them. Resources use raw pointers with reference counting. Arrays use `CArray<T>` with explicit `FreeArray()` calls. Ownership is clear from naming and documentation, not enforced by types.

This is pragmatic for size-constrained code. Smart pointers add overhead: `shared_ptr` requires atomic refcounting, `unique_ptr` requires move semantics and careful thinking about ownership transfer. Raw pointers are free at runtime and obvious in code. The 64k player allocates most resources at startup and never deallocates them until shutdown. Smart pointers would add complexity without benefit.

The tool build uses more dynamic allocation, but even there, the pattern is to allocate large buffers once and reuse them. Arena allocation is common for per-frame temporary data. The engine knows its working set and preallocates rather than thrashing the allocator with small allocations.

### Preprocessor-Driven Modularity

Preprocessor macros control feature inclusion throughout Phoenix. The `PHX_MINIMAL_BUILD` flag switches between tool and player builds. Feature flags like `PHX_OBJ_MODEL` and `PHX_EVENT_RENDERSCENE` enable specific subsystems. Even within subsystems, flags like `PHX_HAS_PARTICLE_SORTING` control optional features.

This approach is old-school but effective. Modern C++ prefers templates and constexpr conditionals, but those still generate code that the linker must consider. Preprocessor conditionals remove code before compilation, guaranteeing it never contributes to binary size. For 64k demos, this matters. An unused class in a template library might get linked anyway. An undefined macro removes all code dependent on it.

## Implications for Creative Coding Frameworks

apEx's architecture offers concrete lessons for modern framework design. Some patterns deserve adoption, others require adaptation, and a few work only under demoscene constraints. Here's what translates to general-purpose creative coding tools.

### Adopt: Clean Separation Between Authoring and Runtime

apEx's split between tool and player is brilliant. The authoring environment can be megabytes, support every file format, include debugging features, and use rich GUI libraries. The runtime player strips all of that, compiling only the minimal execution engine. Both share common libraries (BaseLib, CoRE2) but differ radically in features.

Most creative coding frameworks conflate these concerns. Processing bundles its IDE with runtime libraries. OpenFrameworks ships sketches with the entire framework. But separating authoring from playback enables radical optimization. A Rust framework could provide a full-featured editor with live coding, rich debugging, and visual scripting, while player builds compile to WebAssembly or native code with zero editor overhead.

The key is designing libraries with this split in mind from the start. Foundation types (vectors, matrices, colors) belong in both. Resource management and rendering belong in both. But GUI widgets, importers, and editors belong only in tools. Making this distinction explicit in the module structure forces good architectural decisions.

### Adopt: Timeline as First-Class Abstraction

Demos are fundamentally time-based. Phoenix embraces this with its timeline system. Events have start and end times. Splines evaluate at specific timestamps. The entire demo derives from a single time parameter. This is elegant and powerful.

A creative coding framework could adopt this pattern for animation-heavy projects. Instead of manually tracking time and calling update functions, declare animations as splines or keyframe sequences. The runtime evaluates these automatically, guaranteeing synchronization. Artists think in terms of "at time 1.5 seconds, the color is red" instead of "increment the color value each frame."

This pattern maps well to Rust. Splines are pure functions of time, perfect for safe parallelism. An animation system could evaluate splines on background threads, producing buffers of animation data that the main thread consumes for rendering. The functional nature eliminates race conditions.

### Adopt: Material as Multi-Pass Technique

Phoenix materials are techniques containing multiple passes. This matches how modern rendering works: a physically-based material needs a depth pre-pass, a lighting pass, and maybe a transparency pass. Encoding this in the material definition, not in engine code, gives artists control without requiring programming.

Rust frameworks should embrace multi-pass materials. A material trait could define methods like `collect_passes(&self) -> Vec<RenderPass>`. Each pass specifies a shader, blend state, and render layer. The engine collects passes from all materials, sorts by layer and priority, then renders. Artists declare intent, the engine handles execution.

This pattern also enables material inheritance and composition. Base materials define common passes. Derived materials override specific passes or add new ones. A "metallic" base material might have standard lighting. A "holographic" derived material adds a refraction pass and a fresnel highlight pass.

### Modify: Avoid Per-Instance State Duplication

Phoenix's render instances duplicate GPU state across every instance. Each instance stores eight texture pointers, five shader pointers, and three state objects. For 300 instances, that's thousands of redundant pointers. Modern engines batch instances with identical materials to avoid this waste.

A Rust framework should use material handles instead of inline state. Render instances store a `MaterialHandle` (4-8 bytes) plus instance-specific data like transformation matrices. Materials cache pipeline state and bind groups. The renderer groups instances by material handle, binds material state once, then uses indirect drawing or instancing to render all instances with one GPU command.

This pattern maps naturally to wgpu's bind group system. Bind group 0 holds scene uniforms (camera, lights). Bind group 1 holds material data (textures, parameters). Bind group 2 holds per-instance data (transforms). The renderer sets bind groups 0 and 1 once per material, bind group 2 per instance or per batch.

### Modify: Use Generational Arenas Instead of Raw Pointers

apEx uses raw pointers extensively. Objects hold `CphxObject* Parent` and `CphxObject** Children`. Materials hold `CphxRenderLayerDescriptor* TargetLayer`. This works in C++ with careful lifetime management but would be unsafe in Rust.

Generational arenas solve this elegantly. Store objects in a `Arena<CphxObject>` keyed by `ObjectHandle`. Handles contain a generation counter that invalidates when objects are removed. References become handles, not pointers. The borrow checker is satisfied because handles don't borrow the arena. Dereferencing handles performs a generation check that fails safely if the object was deallocated.

This pattern also enables better serialization. Handles are small integers that serialize trivially. On deserialization, rebuild the arena and patch handles. No pointer fixup, no address space layout randomization issues. Demos load identically on every run.

### Modify: Splines with Modern Interpolation

Phoenix splines use Catmull-Rom and Bezier interpolation with 16-bit floats. This is compact but limited. Modern animation systems support ease-in/ease-out curves, bounce effects, and perceptually uniform motion. A Rust framework should provide richer interpolation while maintaining compact storage.

Consider storing splines as control point deltas with variable-length integer encoding. Keyframes rarely jump by huge amounts frame-to-frame. Encoding deltas compresses better than absolute values. Combine this with interpolation mode tags (linear, cubic, ease-in-out, bounce) to give animators expressive control.

For color animation, support interpolation in perceptually uniform spaces like Oklab. Interpolating RGB values produces muddy midpoints. Interpolating Oklab produces smooth, vivid transitions. The storage cost is identical (four floats) but the quality improvement is dramatic.

### Avoid: Extensive Preprocessor Configuration

Phoenix uses preprocessor macros for feature flags throughout. This works but creates an exponential configuration space. Enabling `PHX_OBJ_SUBSCENE` might require enabling `PHX_EVENT_RENDERSCENE`, which might require enabling `PHX_HAS_TIMELINE_EVENTS`. Tracking dependencies between features is manual and error-prone.

Rust's feature flags and conditional compilation are superior. Cargo features are first-class, composable, and additive. Dependencies between features are explicit in `Cargo.toml`. Code uses `#[cfg(feature = "subscenes")]` instead of `#ifdef PHX_OBJ_SUBSCENE`. The compiler type-checks all configurations, not just the one currently defined.

A Rust framework should use Cargo features for optional subsystems. Default features include core rendering. Optional features add particle systems, procedural generation, or advanced post-processing. The build system ensures valid feature combinations and the compiler enforces correct usage.

### Avoid: 16-Bit Floats for General Use

Phoenix uses 16-bit floats (half-precision) for spline storage to save memory. This works for animation curves but introduces precision issues. Half-precision has only 10 bits of mantissa, giving roughly 3 decimal digits of precision. Colors and positions tolerate this. Rotations and scales accumulate error over long animation sequences.

Modern hardware supports half-precision compute (via f16/bf16 types) but Rust's `f32` and `f64` are better defaults. For compression, quantize data explicitly. Store position as 16-bit integers with an explicit scale factor. Store rotations as compressed quaternions (smallest-three representation uses three 16-bit integers, fourth component computed from constraint). This gives better precision than half-floats with similar storage.

For GPU data, use `wgpu::VertexFormat::Float16x4` where appropriate. GPUs handle half-float vertex attributes efficiently. But keep CPU-side data in f32 unless profiling proves memory bandwidth is a bottleneck.

## Comparative Observations

apEx occupies a unique position compared to other creative coding frameworks.

**Versus Processing/p5.js**: Processing prioritizes beginner-friendliness with high-level functions like `fill()`, `rect()`, and `background()`. apEx prioritizes explicit control with materials, shaders, and render layers. Processing sketches are code. apEx demos are data. Processing artists write loops. apEx artists connect nodes. Both are valid but target different creative workflows.

**Versus OpenFrameworks**: OpenFrameworks is a C++ toolkit requiring programming for everything. apEx provides a visual tool for most tasks. OpenFrameworks addons are code libraries. apEx features are engine modules. OpenFrameworks compiles sketches to megabyte executables. apEx compiles demos to 64KB players. OpenFrameworks optimizes for rapid prototyping. apEx optimizes for production quality and minimal size.

**Versus Unity/Unreal**: Commercial engines provide complete production pipelines with visual editors. apEx matches this for demos but strips features irrelevant to the demoscene. No networking, no asset streaming, no mobile deployment, no monetization. Unity scenes are megabytes of JSON. apEx scenes are kilobytes of binary. Unity is general-purpose. apEx is specialized, and that specialization enables extreme optimization.

**Versus Notch/TouchDesigner**: Visual programming environments let artists build by connecting nodes, like apEx's demotool. But Notch and TouchDesigner are runtime systems. You ship the entire tool with your project. apEx separates authoring from playback. The tool is heavy. The player is light. This enables demos to ship as standalone executables instead of tool projects.

The key insight is that apEx makes deliberate tradeoffs. It sacrifices generality for size. It sacrifices programmer flexibility for artist accessibility. It sacrifices rapid iteration for production optimization. These tradeoffs make sense for the demoscene, which values technical achievement and final results over development speed.

## References

- `demoscene/apex-public/apEx/Phoenix/Scene.h` — Scene graph object hierarchy
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp` — Scene traversal and rendering (line 51-440)
- `demoscene/apex-public/apEx/Phoenix/Material.h` — Material technique and pass definitions
- `demoscene/apex-public/apEx/Phoenix/Material.cpp` — Material expansion logic (line 117-236)
- `demoscene/apex-public/apEx/Phoenix/Timeline.h` — Event timeline structure
- `demoscene/apex-public/apEx/Phoenix/Timeline.cpp` — Timeline event triggering (line 152)
- `demoscene/apex-public/apEx/Phoenix/RenderLayer.h` — Render instance data structure
- `demoscene/apex-public/apEx/Phoenix/RenderLayer.cpp` — Draw call execution (line 27)
- `demoscene/apex-public/Bedrock/BaseLib/Types.h` — Foundation type definitions
- `demoscene/apex-public/Bedrock/CoRE2/Device.h` — DirectX abstraction interface
- `demoscene/apex-public/Bedrock/Whiteboard/WhiteBoard.h` — GUI system entry point
- `notes/per-demoscene/apex-public/code-traces/scene-to-pixels.md` — Detailed rendering pipeline trace
