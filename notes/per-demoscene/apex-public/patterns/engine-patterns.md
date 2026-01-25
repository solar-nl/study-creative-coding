# Engine Patterns from Phoenix

When you're building software that needs to fit in 64 kilobytes, every architectural choice matters. You can't afford layers of abstraction, redundant systems, or flexible-but-bloated designs. Yet the Phoenix demo engine still achieves complete 3D rendering, multi-pass effects, procedural content, synchronized animation, and real-time playback. The reason it works is a set of deliberate patterns that trade generality for specificity, flexibility for predictability, and runtime decision-making for compile-time preparation.

These patterns aren't just optimizations for size-constrained code. They represent fundamental design principles that apply to any system where performance, predictability, and clarity matter more than flexibility and dynamism. Modern creative coding frameworks often prioritize ease of learning and rapid prototyping, which leads to designs where the framework makes decisions at runtime based on user code. Phoenix inverts this: decisions happen during authoring and compilation, leaving runtime execution to be a simple, predictable march through pre-computed data.

The challenge Phoenix addresses is this: how do you build a complete demo production pipeline where artists create content visually, the engine renders it perfectly synchronized to music, and the final executable compiles to under 64KB? The solution involves treating time as the fundamental dimension, expanding abstractions early into self-contained work packages, using splines for compact animation storage, organizing effects through layer composition, separating authoring tools from runtime players, and generating content procedurally instead of storing assets.

## Why Study Demoscene Engine Patterns?

The demoscene operates under constraints that force excellent engineering. A 64k intro must contain all code, shaders, textures, geometry, music, and synchronization data in 65,536 bytes compressed. For comparison, a single JPEG photo is often larger. This extreme constraint eliminates waste. Every abstraction must justify its existence. Every feature must earn its code budget.

But these aren't arbitrary limitations. They reveal patterns that transfer to modern creative coding frameworks. When you can't hide complexity behind megabytes of library code, your architecture becomes visible. Phoenix's rendering pipeline is straightforward not because its authors didn't know how to build more sophisticated systems, but because sophistication costs bytes. The simplicity is intentional, and that simplicity makes the system easier to understand, debug, and reason about than many general-purpose engines.

The patterns Phoenix uses solve problems every creative coding framework faces: synchronizing visuals to timelines, managing multi-pass rendering effects, animating properties smoothly over time, organizing content authoring separately from playback, and generating rich content from minimal data. The difference is that Phoenix's solutions are distilled to their essence. No framework bloat. No feature creep. Just the minimum necessary structure to accomplish the goal.

## Pattern 1: Timeline-Driven Execution

Demos are fundamentally time-based experiences. Everything synchronizes to a timeline: camera movements follow music beats, scenes transition at precise moments, effects fade in and out rhythmically. Phoenix embraces this by making time the primary dimension of execution. Not user input. Not physics simulation. Not AI behavior. Just `t`, a single floating-point parameter representing elapsed time.

The timeline contains events with start times, end times, and types. Each frame, the engine evaluates which events are active at the current timestamp and executes them in sequence. A `RenderScene` event draws a 3D scene. A `Shadertoy` event runs a fullscreen shader. A `ParticleCalc` event updates particle physics. Events don't poll the timeline asking "am I active?" The timeline actively triggers events when they enter their time window.

Think of this like a film production. The timeline is the script with precisely timed scene directions: "At 1:23, camera pans left. At 1:26, lights fade to blue. At 1:30, transition to underwater scene." The actors don't improvise. They execute choreography. This determinism is crucial. Play the demo at time `t = 42.5` seconds and you get identical output every time. No randomness, no variation, perfect reproducibility.

### The Problem This Solves

Most interactive applications are event-driven: user clicks a button, code responds. Or they're simulation-driven: physics updates, AI thinks, world state evolves. But demos aren't interactive and they don't simulate emergent behavior. They play back authored sequences. Using event-driven or simulation-driven patterns would add complexity without benefit. Timeline-driven execution matches the domain perfectly.

Synchronizing visuals to music is the motivating use case. A demo's soundtrack has a precise beat pattern. Visual elements need to pulse, flash, or transition exactly on beat. If animation updates via `dt` (delta time between frames), tiny timing errors accumulate. After 200 frames at 60fps, a 0.5ms error per frame becomes 100ms of drift. The visuals are visibly out of sync with music.

Timeline-driven animation eliminates drift. Each frame, query the current playback time `t` from the audio system, evaluate all splines at exactly that timestamp, render the frame. If frames drop due to performance issues, visuals skip ahead to match audio. Perfect synchronization without manual compensation.

### Implementation Approach

Phoenix's timeline is a flat array of event structures. Each event stores a type tag, start frame, end frame, and type-specific parameters. The timeline owns render layers, render targets, and scene references. Each frame, it iterates events and activates those whose time range includes the current frame.

```cpp
struct Event {
    EventType type;
    int start_frame;
    int end_frame;
    union {
        RenderSceneParams render_scene;
        ShaderToyParams shadertoy;
        ParticleCalcParams particle_calc;
        // ... other event types
    } params;
};

void Timeline::Render(float t) {
    int frame = (int)(t * frames_per_second);

    for (int i = 0; i < event_count; i++) {
        if (events[i].start_frame <= frame && frame < events[i].end_frame) {
            events[i].Execute(t);
        }
    }
}
```

Events are polymorphic via a type tag, not virtual methods. This compresses better. The event array is data, not code. Serialize it directly to disk, load it at runtime, execute. No complex initialization, no dependency injection, just linear iteration.

Splines connect properties to time. Object position, rotation, scale, material colors, camera field-of-view, particle emission rates, light intensities all derive from spline curves evaluated at `t`. The object doesn't track its current position and update it. The object queries its position spline at time `t` and uses the result. State is a function of time, not a mutable accumulation.

### Trade-offs

Timeline-driven execution trades runtime flexibility for determinism. You can't add events dynamically. You can't branch based on conditions. The timeline is fixed at authoring time. For demos, this is perfect. For interactive applications, it's limiting.

Interactive creativity tools could adopt a hybrid approach. Use a timeline for choreographed sequences but allow runtime modification. Artists scrub the timeline during authoring, tweaking spline curves and event parameters. The final export bakes everything to a compact format for playback. The authoring tool stays flexible, the player stays deterministic.

The pattern also assumes dense timeline utilization. If most frames have active events, iterating all events is efficient. If events are sparse (90% of the timeline is empty), spatial indexing (interval trees or segment trees) would be faster. Phoenix assumes dense timelines because demos pack content tightly.

### Rust Sketch

Rust's enum types model timeline events elegantly. Each event type is a variant with specific data.

```rust
pub enum TimelineEvent {
    RenderScene {
        scene: SceneHandle,
        camera: CameraHandle,
        clear_color: bool,
        clear_depth: bool,
    },
    Shadertoy {
        shader: ShaderHandle,
        target: RenderTargetHandle,
    },
    ParticleCalc {
        emitter: EmitterHandle,
        delta_time: f32,
    },
}

pub struct Timeline {
    events: Vec<(TimeRange, TimelineEvent)>,
    current_time: f32,
}

impl Timeline {
    pub fn update(&mut self, t: f32) {
        self.current_time = t;
    }

    pub fn execute(&self, renderer: &mut Renderer) {
        for (range, event) in &self.events {
            if range.contains(self.current_time) {
                match event {
                    TimelineEvent::RenderScene { scene, camera, .. } => {
                        renderer.render_scene(*scene, *camera);
                    }
                    TimelineEvent::Shadertoy { shader, target } => {
                        renderer.run_shadertoy(*shader, *target);
                    }
                    TimelineEvent::ParticleCalc { emitter, delta_time } => {
                        renderer.update_particles(*emitter, *delta_time);
                    }
                }
            }
        }
    }
}
```

The borrow checker ensures events can't mutate the timeline during execution. Handles prevent dangling references to scenes or shaders. The pattern is safe, efficient, and maps directly to Phoenix's design.

## Pattern 2: Material Expansion

In Phoenix, a single mesh object with a multi-pass material generates multiple independent render instances, one per pass. A chrome material with three passes (base color, environment reflection, specular highlight) creates three separate render commands, each containing complete GPU state: vertex buffer, index buffer, five shader stage pointers, three render state objects, eight texture slots, transformation matrices, and material parameters.

This expansion happens during scene graph traversal, not during rendering. By the time the render loop executes, every decision is frozen. The renderer doesn't ask "what shaders does this material need?" It just iterates render instances and binds pre-packaged state. Think of it like preparing complete work orders in advance. Each instance is a self-contained instruction card: "Bind these resources, set this state, draw this geometry." No lookups, no decisions, pure execution.

### The Problem This Solves

Multi-pass rendering is essential for high-quality graphics. A realistic material needs depth pre-pass, shadow mapping, ambient occlusion, lighting, and post-processing. Managing these passes manually is error-prone. Artists would need to write rendering code for each material, duplicating boilerplate.

Phoenix solves this by embedding pass definitions in materials. An artist creates a "metal" material and specifies it has a depth pass, a lighting pass, and a reflection pass. During scene traversal, the engine automatically expands the material into three render instances. The artist declares intent, the engine handles execution.

This also enables render layer composition. Each material pass targets a specific layer. The depth pass goes to layer 0 (which renders to a depth texture). The lighting pass goes to layer 1 (which reads the depth texture). The reflection pass goes to layer 2 (which samples an environment cubemap). Artists compose effects by assigning passes to layers without writing orchestration code.

### Implementation Approach

Phoenix's `CphxRenderDataInstance` structure contains everything needed for a draw call. The material system iterates passes, allocates instances, and copies GPU handles in bulk using `memcpy`.

```cpp
struct RenderDataInstance {
    // Geometry
    ID3D11Buffer* vertex_buffer;
    ID3D11Buffer* index_buffer;
    int index_count;

    // Pipeline stages (5 pointers copied via memcpy)
    ID3D11VertexShader* vs;
    ID3D11PixelShader* ps;
    ID3D11GeometryShader* gs;
    ID3D11HullShader* hs;
    ID3D11DomainShader* ds;

    // States and textures (11 pointers copied via memcpy)
    ID3D11BlendState* blend_state;
    ID3D11RasterizerState* rasterizer_state;
    ID3D11DepthStencilState* depth_stencil_state;
    ID3D11ShaderResourceView* textures[8];

    // Per-instance data
    Matrix4x4 world_matrix;
    Matrix4x4 inverse_transpose_matrix;
    float material_data[64];

    int render_priority;
    LayerDescriptor* target_layer;
};

void Material::CreateRenderInstances(Mesh* mesh, Scene* scene) {
    for (int i = 0; i < pass_count; i++) {
        RenderDataInstance* instance = new RenderDataInstance();

        instance->vertex_buffer = mesh->vertex_buffer;
        instance->index_buffer = mesh->index_buffer;
        instance->index_count = mesh->index_count;

        // Bulk copy shader pointers (5 pointers)
        memcpy(&instance->vs, &passes[i]->vs, sizeof(void*) * 5);

        // Bulk copy states and textures (11 pointers)
        memcpy(&instance->blend_state, &passes[i]->blend_state, sizeof(void*) * 11);

        instance->world_matrix = mesh->world_matrix;
        instance->inverse_transpose_matrix = mesh->inverse_transpose_matrix;

        // Copy material parameters
        memcpy(instance->material_data, passes[i]->constant_data, passes[i]->data_size);

        instance->render_priority = passes[i]->priority;
        instance->target_layer = passes[i]->layer;

        scene->AddRenderInstance(instance);
    }
}
```

The `memcpy` calls exploit struct layout. Instead of assigning fields individually, copy contiguous blocks. This saves executable bytes. The code relies on exact memory alignment, which is fragile but effective for size-constrained systems.

### Trade-offs

Material expansion duplicates GPU state across instances. Eight texture pointers, three state objects, five shader pointers, and 64 floats of material data per instance. For 100 meshes with 3-pass materials, that's 300 instances and roughly 100KB of redundant pointers. Modern engines avoid this by batching instances with identical materials and using handles instead of inline state.

Phoenix accepts the memory cost because the alternative costs more code. Batching requires material hashing, instance sorting, indirect drawing, and dynamic buffer uploads. That's kilobytes of code. For demos with a few hundred instances, the memory cost is negligible and the code simplicity is valuable.

Interactive tools with thousands of instances should batch. But for tightly authored content where every object is visible and intentionally placed, one-instance-per-pass is straightforward and predictable.

### Rust Sketch

Rust's ownership system makes inline GPU state awkward. Instead, use handles and cache materials.

```rust
pub struct RenderInstance {
    mesh: MeshHandle,
    material: MaterialHandle,
    pass_index: usize,
    transform: Mat4,
    layer: LayerIndex,
    priority: i32,
}

pub struct Material {
    passes: Vec<MaterialPass>,
}

pub struct MaterialPass {
    pipeline: wgpu::RenderPipeline,
    bind_groups: Vec<wgpu::BindGroup>,
    layer: LayerIndex,
    priority: i32,
}

impl Material {
    pub fn create_instances(
        &self,
        mesh: MeshHandle,
        transform: Mat4,
    ) -> Vec<RenderInstance> {
        self.passes.iter().enumerate().map(|(index, pass)| {
            RenderInstance {
                mesh,
                material: self.handle(),
                pass_index: index,
                transform,
                layer: pass.layer,
                priority: pass.priority,
            }
        }).collect()
    }
}
```

The material caches pipelines and bind groups. Instances hold handles (4-8 bytes) instead of raw pointers (64+ bytes). This reduces memory and enables safe sharing. Multiple instances reference the same material without ownership issues.

## Pattern 3: Spline-Based Animation

Every animatable property in Phoenix derives from spline curves. Object position, rotation, scale, material colors, camera field-of-view, light intensities, particle emission rates, all come from splines evaluated at the current timestamp. Instead of storing dense keyframe arrays, Phoenix stores sparse control points and interpolation modes. A smooth camera path might use six control points with Catmull-Rom interpolation, compressing to 48 bytes instead of thousands of keyframes.

Think of splines like mathematical recipes for motion. Instead of saying "at frame 0, position is (0,0,0); at frame 10, position is (1,0,0); at frame 20, position is (2,0,0)..." you say "here are four control points and I want cubic interpolation." The engine evaluates the curve at any timestamp, producing smooth motion from compact data.

### The Problem This Solves

Dense keyframe animation requires storing values at every frame or using large deltas between keyframes. For 60fps video at 3 minutes, that's 10,800 frames. If every object animates position, rotation, and scale (10 floats), that's 108,000 floats or 432KB just for transformation data. For a 64k intro, that's unacceptable.

Splines compress beautifully. Smooth motion needs few control points. A camera sweeping through a scene might use 8 position spline points and 6 rotation points, totaling 56 floats or 224 bytes. The interpolated motion is identical to dense keyframes but costs 99.9% less storage.

Splines also enable temporal anti-aliasing and motion blur. Evaluate the spline at `t` and `t - dt` to get current and previous positions. The difference is velocity, which shaders use to compute motion vectors. This technique produces cinematic blur without storing velocity fields.

### Implementation Approach

Phoenix uses 16-bit floating point (half-precision) for spline control points. A typical spline stores four control points (for Catmull-Rom interpolation) and an interpolation mode enum, totaling about 10 bytes.

```cpp
enum InterpolationMode {
    Linear,
    CatmullRom,
    Bezier,
};

struct Spline_float16 {
    half control_points[4];  // 16-bit floats
    InterpolationMode mode;

    float Evaluate(float t) {
        // Convert control points to f32
        float p0 = half_to_float(control_points[0]);
        float p1 = half_to_float(control_points[1]);
        float p2 = half_to_float(control_points[2]);
        float p3 = half_to_float(control_points[3]);

        // Catmull-Rom interpolation
        float t2 = t * t;
        float t3 = t2 * t;

        float result = 0.5f * (
            (2.0f * p1) +
            (-p0 + p2) * t +
            (2.0f*p0 - 5.0f*p1 + 4.0f*p2 - p3) * t2 +
            (-p0 + 3.0f*p1 - 3.0f*p2 + p3) * t3
        );

        return result;
    }
};

struct SplineResults {
    float values[SPLINE_TYPE_COUNT];
};

void Object::CalculateAnimation(int clip, float t) {
    for (int i = 0; i < spline_count; i++) {
        Spline_float16* spline = &splines[i];
        results.values[spline->target_type] = spline->Evaluate(t);
    }
}
```

Each object allocates a `SplineResults` array indexed by `SplineType` enum. Splines target specific properties: `Spline_Position_x`, `Spline_Rotation_y`, `Spline_Material_ColorR`, etc. During animation evaluation, the engine iterates splines, evaluates them at time `t`, and writes results to the appropriate array slot.

### Trade-offs

Half-precision floats have only 10 bits of mantissa, giving roughly 3 decimal digits of precision. This works for colors and positions but accumulates error in rotations over long sequences. Modern approaches should use f32 for computation and compress storage using delta encoding or quantization.

Spline evaluation is CPU-intensive. Catmull-Rom requires four control points and multiple multiplications per sample. For hundreds of splines per frame, this costs milliseconds. But demos are all about motion. Static content doesn't justify making a demo. The CPU cost is accepted because animation is the primary feature.

Caching spline results between frames would save CPU time if properties change slowly. But Phoenix regenerates the scene graph every frame because everything animates. Caching would add code complexity without benefit. This is the "know your workload" principle: optimize for the actual use case, not hypothetical scenarios.

### Rust Sketch

Rust's generic system makes splines reusable for any interpolatable type.

```rust
pub trait Interpolate: Copy {
    fn lerp(a: Self, b: Self, t: f32) -> Self;
    fn catmull_rom(p0: Self, p1: Self, p2: Self, p3: Self, t: f32) -> Self;
}

impl Interpolate for f32 {
    fn lerp(a: Self, b: Self, t: f32) -> Self {
        a + (b - a) * t
    }

    fn catmull_rom(p0: Self, p1: Self, p2: Self, p3: Self, t: f32) -> Self {
        let t2 = t * t;
        let t3 = t2 * t;
        0.5 * (
            (2.0 * p1) +
            (-p0 + p2) * t +
            (2.0*p0 - 5.0*p1 + 4.0*p2 - p3) * t2 +
            (-p0 + 3.0*p1 - 3.0*p2 + p3) * t3
        )
    }
}

pub struct Spline<T: Interpolate> {
    control_points: Vec<(f32, T)>,
    mode: InterpolationMode,
}

impl<T: Interpolate> Spline<T> {
    pub fn evaluate(&self, t: f32) -> T {
        // Find surrounding control points
        let (p0, p1, p2, p3) = self.find_segment(t);

        match self.mode {
            InterpolationMode::Linear => T::lerp(p1.1, p2.1, t),
            InterpolationMode::CatmullRom => T::catmull_rom(p0.1, p1.1, p2.1, p3.1, t),
            InterpolationMode::Bezier => unimplemented!(),
        }
    }
}

// Embed in objects
pub struct Transform {
    position: Spline<Vec3>,
    rotation: Spline<Quat>,
    scale: Spline<Vec3>,
}

impl Transform {
    pub fn evaluate(&self, t: f32) -> Mat4 {
        let pos = self.position.evaluate(t);
        let rot = self.rotation.evaluate(t);
        let scale = self.scale.evaluate(t);
        Mat4::from_scale_rotation_translation(scale, rot, pos)
    }
}
```

The trait-based approach enables animating custom types. Color splines, quaternion splines, even custom material parameter splines all use the same mechanism. The framework provides implementations for common types, users extend for domain-specific types.

## Pattern 4: Render Layer Composition

Phoenix organizes multi-pass rendering through layers. Each layer has independent render targets, clear flags, and instance queues. Materials specify which layer each pass targets. The engine renders all instances in layer 0, then layer 1, then layer 2, sequentially. This enables sophisticated effects without explicit orchestration code.

Think of layers like photo editing layers in Photoshop. Layer 0 is the base image. Layer 1 applies a blur filter. Layer 2 adds color grading. Each layer processes its inputs and produces an output. The final composite combines all layers. But unlike Photoshop where users manually arrange layers, Phoenix materials declare their target layer and the engine handles sequencing automatically.

### The Problem This Solves

Multi-pass effects are essential for high-quality rendering. Bloom requires rendering the scene, extracting bright areas, blurring them, and combining with the original. Depth-of-field requires rendering the scene with depth, blurring based on depth, and compositing. Motion blur requires rendering velocity, using it to blur the final image. Managing render targets, clear operations, and pass dependencies manually is error-prone.

Render layers make effects compositional. Want bloom? Create a layer that extracts bright pixels, a layer that blurs, and a layer that combines. Want to add depth-of-field? Insert new layers between existing ones. The material system ensures passes execute in the correct order without explicit dependencies.

This also solves the render order problem elegantly. Within each layer, instances sort by priority. But across layers, execution order is fixed. A transparent effect in layer 3 always renders after opaque geometry in layer 0, regardless of priority. This guarantees correct compositing without manual sorting.

### Implementation Approach

Phoenix's `RenderLayer` structure contains a descriptor (which specifies render targets and clear flags) and a queue of render instances. During scene traversal, materials add instances to specific layers. During rendering, the engine iterates layers and renders all instances in each.

```cpp
struct LayerDescriptor {
    RenderTarget* targets[8];
    int target_count;
    bool clear_color;
    bool clear_depth;
    float clear_color_value[4];
    float clear_depth_value;
};

struct RenderLayer {
    LayerDescriptor* descriptor;
    Array<RenderDataInstance*> instances;
};

struct Scene {
    RenderLayer* layers[16];
    int layer_count;

    void Render() {
        for (int i = 0; i < layer_count; i++) {
            RenderLayer* layer = layers[i];

            // Bind render targets and clear
            layer->descriptor->SetEnvironment();

            // Upload scene-level data (camera, lights)
            UploadSceneUniforms();

            // Render all instances
            for (int j = 0; j < layer->instances.Count(); j++) {
                layer->instances[j]->Render();
            }

            // Generate mipmaps if needed
            layer->descriptor->GenerateMipmaps();
        }
    }
};
```

Material passes specify their target layer during definition. An artist creates a "bloom glow" material and assigns it to layer 3. The engine automatically renders it after layers 0, 1, and 2 without additional material code.

### Trade-offs

Layer sequencing is fixed. You can't conditionally skip layers or reorder them at runtime. For demos, this is fine. The effect pipeline is authored once and baked. For interactive tools, users might want dynamic layer ordering or conditional effects. A hybrid approach could use layers for static effects and explicit render passes for dynamic ones.

Layers also assume linear dependency chains. Layer 3 depends on layer 2, which depends on layer 1. If you need DAG-style dependencies (layer 5 depends on both layer 2 and layer 4), layers are insufficient. Modern render graphs handle arbitrary dependencies. But linear chains cover 90% of real-world effects, and the simplicity saves code size.

### Rust Sketch

Rust's type system ensures render targets outlive layer descriptors, preventing use-after-free bugs.

```rust
pub struct LayerDescriptor {
    targets: Vec<RenderTargetHandle>,
    clear_color: Option<[f32; 4]>,
    clear_depth: Option<f32>,
}

pub struct RenderLayer {
    descriptor: LayerDescriptor,
    instances: Vec<RenderInstance>,
}

impl RenderLayer {
    pub fn render(&mut self, encoder: &mut wgpu::CommandEncoder, context: &RenderContext) {
        // Create render pass with targets and clear values
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("layer_pass"),
            color_attachments: &self.descriptor.color_attachments(context),
            depth_stencil_attachment: self.descriptor.depth_attachment(context),
        });

        // Upload scene uniforms
        context.bind_scene_uniforms(&mut pass);

        // Render instances
        for instance in &self.instances {
            instance.render(&mut pass, context);
        }
    }

    pub fn add_instance(&mut self, instance: RenderInstance) {
        self.instances.push(instance);
    }

    pub fn clear(&mut self) {
        self.instances.clear();
    }
}

pub struct Scene {
    layers: Vec<RenderLayer>,
}

impl Scene {
    pub fn render(&mut self, encoder: &mut wgpu::CommandEncoder, context: &RenderContext) {
        for layer in &mut self.layers {
            layer.render(encoder, context);
        }
    }
}
```

The borrow checker ensures instances can't outlive the scene, and render targets can't be destroyed while referenced by layers. The pattern is safe, efficient, and maps directly to wgpu's render pass model.

## Pattern 5: Tool/Player Separation

Phoenix compiles in two modes: full build for the authoring tool, minimal build for the 64k player executable. The authoring environment includes GUI widgets, editors, importers, debug helpers, and dynamic allocation. The minimal build strips all of that, compiling only the runtime engine. Both share common libraries (math types, rendering primitives) but differ radically in features.

Think of this like a film production pipeline. The player is a theater projector optimized for one thing: playing back pre-computed content efficiently. The authoring tool is the editing suite where directors arrange scenes, apply effects, and preview results. The projector doesn't need editing features. The editing suite doesn't need to fit on a delivery truck. They're complementary but separate systems.

### The Problem This Solves

Most creative coding frameworks bundle everything together. Processing includes its IDE. OpenFrameworks ships sketches with the entire framework. This conflates authoring and runtime, making executables large and complex. For demos, this is fatal. The final executable must fit in 64KB. Including editor code would consume half that budget.

Phoenix solves this by separating concerns from the start. Foundation libraries (vectors, matrices, arrays) belong in both tool and player. Rendering code belongs in both. But GUI widgets, importers, and editors belong only in tools. Making this distinction explicit in the module structure forces good architectural decisions.

This also enables aggressive optimization. The player disables destructors (objects never deallocate), removes error checking (content is pre-validated), and strips debug info. The tool enables everything for rich feedback. Both are valid builds of the same codebase, optimized for different goals.

### Implementation Approach

Phoenix uses preprocessor macros to conditionally compile features. The `PHX_MINIMAL_BUILD` flag switches between tool and player modes. Feature flags like `PHX_OBJ_MODEL` and `PHX_EVENT_RENDERSCENE` enable specific subsystems.

```cpp
// PhoenixConfig.h
#ifdef PHX_MINIMAL_BUILD
  #define PHX_DESTRUCTOR
#else
  #define PHX_DESTRUCTOR virtual ~ClassName() { /* cleanup */ }
#endif

// Object.h
class Object {
public:
    Object();
    PHX_DESTRUCTOR

    #ifndef PHX_MINIMAL_BUILD
    void* ToolData;  // Editor metadata pointer
    #endif
};

// Scene.cpp
void Scene::AddRenderInstance(Layer* layer, RenderDataInstance* rdi) {
    for (int i = 0; i < layer_count; i++) {
        if (layers[i]->descriptor == layer) {
            layers[i]->instances.Add(rdi);
            return;
        }
    }

    #ifndef PHX_MINIMAL_BUILD
    delete rdi;  // Layer not found, clean up
    #endif
}
```

Destructors only exist in tool builds. The player never deallocates objects, so destructors would add code size without benefit. Tool-specific data like editor metadata compiles out in minimal builds. Invalid operations (adding instances to non-existent layers) silently fail in players but clean up properly in tools.

### Trade-offs

Preprocessor conditionals create an exponential configuration space. Enabling `PHX_OBJ_SUBSCENE` might require enabling `PHX_EVENT_RENDERSCENE`, which might require enabling `PHX_HAS_TIMELINE_EVENTS`. Tracking dependencies between features is manual and error-prone.

Modern build systems handle this better. Rust's Cargo features are first-class, composable, and additive. Dependencies between features are explicit in `Cargo.toml`. The compiler type-checks all configurations, not just the one currently defined.

The separation also complicates testing. You need to test both tool and player builds to ensure feature flags don't break either. Continuous integration should build all valid feature combinations and run tests on each. This is extra infrastructure but catches bugs early.

### Rust Sketch

Rust's `cfg` attributes and Cargo features handle conditional compilation cleanly.

```rust
// Cargo.toml
[features]
default = ["runtime"]
runtime = []
authoring = ["runtime", "gui", "importers", "debug"]
minimal = ["runtime"]

// lib.rs
#[cfg(feature = "authoring")]
pub mod editor;

#[cfg(feature = "authoring")]
pub mod importers;

pub struct Object {
    pub id: ObjectId,
    pub transform: Transform,

    #[cfg(feature = "authoring")]
    pub tool_data: Option<EditorMetadata>,
}

impl Object {
    pub fn new(id: ObjectId) -> Self {
        Self {
            id,
            transform: Transform::default(),
            #[cfg(feature = "authoring")]
            tool_data: None,
        }
    }
}

#[cfg(feature = "authoring")]
impl Object {
    pub fn set_editor_metadata(&mut self, data: EditorMetadata) {
        self.tool_data = Some(data);
    }
}
```

The `authoring` feature pulls in GUI and importers. The `minimal` feature includes only runtime. Code using `#[cfg(feature = "authoring")]` compiles only when that feature is enabled. The compiler enforces correct usage across all configurations.

## Pattern 6: Procedural Content Generation

Phoenix includes generators for textures, trees, meshes, and materials. These generators run in the authoring tool to create content. The resulting geometry and textures serialize to compact binary formats. The 64k player loads pre-generated data, not generator code. This is crucial: generators can be large and complex because they don't ship in the final executable.

Think of procedural generation like a factory. The factory (authoring tool) manufactures products (textures, meshes) using complex machinery (generation code). The store (player) sells pre-manufactured products without needing the factory equipment. The factory can use heavy machinery because it doesn't travel with the products.

### The Problem This Solves

Storing textures and geometry in traditional formats is wasteful. A 1024x1024 PNG texture is 3MB uncompressed, maybe 200KB compressed. For a 64k intro, that's the entire budget gone. But procedural textures generate from mathematical functions: Perlin noise, fractals, domain warping. A texture generator might be 2KB of code, producing textures that would cost 200KB to store.

The same applies to geometry. A tree model with 10,000 vertices is 480KB raw (position, normal, UV per vertex). But an L-system tree generator is a few hundred bytes of code plus parameters. The generator produces identical geometry at a fraction of the storage cost.

Phoenix's approach combines the benefits of both. Use complex generators during authoring to create rich content. Serialize the results to compact formats. The player loads pre-generated data without generator overhead. Artists get full-featured tools, players get minimal executables.

### Implementation Approach

Phoenix's texture generator uses a graph of operators: noise sources, blends, color adjustments, filters. Each operator has a small amount of state (parameters) and a function to evaluate a pixel at coordinates `(u, v)`.

```cpp
struct TexGenOp {
    OpType type;
    float parameters[8];
    TexGenOp* inputs[4];

    Color Evaluate(float u, float v) {
        switch (type) {
            case OP_PERLIN_NOISE:
                return PerlinNoise(u * parameters[0], v * parameters[1]);

            case OP_BLEND:
                Color a = inputs[0]->Evaluate(u, v);
                Color b = inputs[1]->Evaluate(u, v);
                return Blend(a, b, parameters[0]);

            case OP_COLOR_ADJUST:
                Color c = inputs[0]->Evaluate(u, v);
                return AdjustHSV(c, parameters[0], parameters[1], parameters[2]);

            // ... other operators
        }
    }
};

void TexGenOp::Bake(Texture* output) {
    for (int y = 0; y < output->height; y++) {
        for (int x = 0; x < output->width; x++) {
            float u = (float)x / output->width;
            float v = (float)y / output->height;
            output->SetPixel(x, y, Evaluate(u, v));
        }
    }
}
```

During authoring, artists build operator graphs visually. Preview windows show results in real-time. When satisfied, they bake the graph to a texture and serialize it. The player loads the baked texture without operator code.

Mesh generators work similarly. The tree generator takes parameters (branch count, recursion depth, randomness seed) and produces a mesh. The mesh serializes to a custom format that compresses better than OBJ or glTF. The player loads pre-generated meshes directly.

### Trade-offs

Pre-generating content loses runtime variation. You can't adjust procedural parameters at runtime because the generator doesn't exist in the player. For demos, this is fine. Content is authored once and baked. For interactive tools, users might want runtime procedural generation (Minecraft-style terrain, for instance).

A hybrid approach could work: simple generators ship in the player for runtime variation, complex generators remain tool-only for asset creation. The framework provides both paths, users choose based on needs.

Storage size depends on compression. Baked textures compress well with PNG or DXT formats. Baked meshes compress well with quantized positions and delta-encoded indices. But if procedural code is very small (a simple fractal generator is 500 bytes), runtime generation might be smaller than baked data. Profile to decide.

### Rust Sketch

Rust's trait system makes procedural generators composable.

```rust
pub trait TexGen {
    fn evaluate(&self, u: f32, v: f32) -> Color;
}

pub struct PerlinNoise {
    frequency: f32,
    octaves: u32,
}

impl TexGen for PerlinNoise {
    fn evaluate(&self, u: f32, v: f32) -> Color {
        let value = perlin_octaves(u * self.frequency, v * self.frequency, self.octaves);
        Color::gray(value)
    }
}

pub struct Blend {
    input_a: Box<dyn TexGen>,
    input_b: Box<dyn TexGen>,
    factor: f32,
}

impl TexGen for Blend {
    fn evaluate(&self, u: f32, v: f32) -> Color {
        let a = self.input_a.evaluate(u, v);
        let b = self.input_b.evaluate(u, v);
        Color::lerp(a, b, self.factor)
    }
}

pub fn bake_texture(generator: &dyn TexGen, width: u32, height: u32) -> Texture {
    let mut texture = Texture::new(width, height);
    for y in 0..height {
        for x in 0..width {
            let u = x as f32 / width as f32;
            let v = y as f32 / height as f32;
            let color = generator.evaluate(u, v);
            texture.set_pixel(x, y, color);
        }
    }
    texture
}
```

The trait-based approach enables mixing and matching generators. Users compose simple generators into complex ones. The framework provides common operators (noise, blend, gradient), users extend for custom effects.

## Implications for Creative Coding Frameworks

Phoenix's patterns offer concrete lessons for modern framework design. Some patterns transfer directly, others require adaptation to modern constraints, and a few work only under demoscene-specific assumptions.

**Timeline-driven execution** transfers directly to animation-heavy projects. Instead of manually tracking time and calling update functions, declare animations as timelines with events and splines. The runtime evaluates automatically, guaranteeing synchronization. This pattern maps well to Rust's functional style.

**Material expansion** is correct for 64k intros but wasteful for general use. Modern frameworks should batch instances with identical materials and use multi-draw indirect when available. The principle (expand abstractions early into concrete commands) still applies, but the implementation should optimize for modern hardware.

**Spline-based animation** should be first-class in any creative coding framework. Provide generic spline types that work with positions, colors, custom parameters. Support perceptually uniform color interpolation (Oklab instead of RGB). Enable temporal queries for motion blur and velocity-based effects.

**Render layers** solve multi-pass rendering elegantly without explicit pass management. Materials declare target layers, the engine handles sequencing. This pattern maps naturally to modern render graphs and should be a core abstraction.

**Tool/player separation** is brilliant. The authoring environment can be megabytes, support every file format, include rich debugging, and use heavy libraries. The runtime player strips all of that, compiling only the minimal execution engine. Rust's feature flags make this pattern safe and type-checked.

**Procedural content generation** should offer both tool-time and runtime paths. Simple generators ship in the player for variation. Complex generators remain tool-only for asset creation. Let users choose based on their constraints.

The key insight is that Phoenix makes deliberate tradeoffs. It sacrifices generality for size, flexibility for predictability, and runtime decisions for compile-time preparation. These tradeoffs make sense for the demoscene and reveal patterns that benefit any system where performance, predictability, and clarity matter.

## References

- `/Users/scjas/Developer/03 - solar-nl/02 - Github Public/study-creative-coding/notes/per-demoscene/apex-public/architecture.md` - Phoenix engine module structure and design philosophy
- `/Users/scjas/Developer/03 - solar-nl/02 - Github Public/study-creative-coding/notes/per-demoscene/apex-public/rendering/pipeline.md` - Complete rendering pipeline trace from timeline to GPU
- `/Users/scjas/Developer/03 - solar-nl/02 - Github Public/study-creative-coding/notes/per-demoscene/apex-public/code-traces/scene-to-pixels.md` - Detailed code walkthrough of scene graph traversal and material expansion
- `demoscene/apex-public/apEx/Phoenix/Timeline.cpp` - Timeline event execution and spline evaluation
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp` - Scene graph traversal and render layer management
- `demoscene/apex-public/apEx/Phoenix/Material.cpp` - Material pass expansion into render instances
- `demoscene/apex-public/apEx/Phoenix/phxSpline.h` - 16-bit float spline implementation
- `demoscene/apex-public/apEx/Phoenix/PhoenixConfig.h` - Conditional compilation feature flags
