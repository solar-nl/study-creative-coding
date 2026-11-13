# tixl Particle System Overview

When you think of a particle system running in a visual programming environment, you might picture simulation logic on the CPU — a C# update loop iterating over a list, applying forces, testing lifetimes, then uploading the results to the GPU each frame for rendering. That's the familiar model, and it works fine for modest counts. tixl takes a different approach entirely. Its particles never touch the CPU after emission. They're born on the GPU, live on the GPU, aged on the GPU, and killed on the GPU. The CPU's job is simply to orchestrate: dispatch a compute shader, move on.

This isn't a minor optimization. It's an architectural commitment with implications that ripple through every part of the system. Because the GPU owns canonical particle state, there's no upload bottleneck, no synchronization stall, no "map buffer, write, unmap" ceremony each frame. The entire simulation — emission, force accumulation, lifetime management, and result copy — runs as a sequence of compute shader dispatches against a fixed-size GPU buffer. That buffer never changes shape. It's allocated once at setup, sized to `MaxParticleCount`, and the system works within that constraint forever.

Why this design for a live creative tool? Visual programming environments like tixl are interactive by nature. Artists tweak parameters in real time, connect force nodes, change emission shapes, and expect to see hundreds of thousands of particles respond immediately. A CPU simulation bottleneck would destroy that interactivity the moment particle counts crossed a few thousand. By committing fully to the GPU, tixl can handle large counts without sacrificing the low-latency feedback loop that makes node-graph iteration pleasant.

The key insight is that most of what makes a particle system expressive — turbulence, SDF constraints, mesh-surface following, velocity stretching — maps naturally onto compute shader dispatches. Each force is an independent kernel. You connect them in the node graph, and the system fires them sequentially, each one reading and writing the same buffer. The particles don't know how many forces are attached. They just accumulate velocity deltas until the main simulation shader integrates position.

## The Point/Particle Struct Duality

Here's where tixl's design gets genuinely interesting. The particle system doesn't introduce a separate, heavyweight particle buffer alongside the existing point infrastructure. Instead, it reuses the same 64-byte per-element layout that points use throughout the rest of the framework — but it changes what the fields mean depending on which system is looking at them.

Think of it like a diplomatic passport that means different things at different borders. The same booklet, the same data, but a customs officer in one country reads the photo as an identity document while an officer in another reads it as a travel permit. The physical object hasn't changed; the interpretation has. tixl's particle buffer works the same way. A single 64-byte block of memory is simultaneously a `Point` (for rendering), a `Particle` (for simulation), and a `LegacyPoint` (for older operators that predate the current naming).

The struct definitions live in a shared header that every shader includes:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point.hlsl

// Points are particles share the same structure and stride,
// But some attributes change their meaning:
//   W -> Radius
//   Stretch -> Velocity
//   Selected -> BirthTime

struct Point {
    float3 Position;  // offset 0  — world-space position
    float  FX1;       // offset 12 — user-defined attribute (age, speed, or kept original)
    float4 Rotation;  // offset 16 — quaternion
    float4 Color;     // offset 32 — RGBA
    float3 Scale;     // offset 48 — per-axis scale
    float  FX2;       // offset 60 — second user-defined attribute
};

struct Particle {
    float3 Position;  // offset 0  — same as Point.Position
    float  Radius;    // offset 12 — FX1 reinterpreted as collision radius
    float4 Rotation;  // offset 16 — same quaternion
    float4 Color;     // offset 32 — same RGBA
    float3 Velocity;  // offset 48 — Scale reinterpreted as velocity vector
    float  BirthTime; // offset 60 — FX2 reinterpreted as birth timestamp
};

struct LegacyPoint {
    float3 Position;
    float  W;
    float4 Rotation;
    float4 Color;
    float3 Stretch;
    float  Selected;
};
```

The field that becomes `Velocity` in the `Particle` view occupies the same 12 bytes as `Scale` in the `Point` view. The field that becomes `BirthTime` is `FX2` in the rendering view. This is semantic reinterpretation, not a type union in the C sense — there's no `union` keyword anywhere. Both structs simply declare the same memory layout with different names. The shader compiler sees identical offsets; only the programmer's intent changes.

The C# side has a matching layout for cases where the CPU needs to inspect or initialize particle state:

```csharp
// visual-programming/tixl/Core/DataTypes/ParticleSystem.cs

[StructLayout(LayoutKind.Explicit, Size = 16 * 4)]
public struct ParticlePoint
{
    [FieldOffset(0)]       public Vector3    Position;
    [FieldOffset(3 * 4)]   public float      W;
    [FieldOffset(4 * 4)]   public Quaternion Rotation;
    [FieldOffset(8 * 4)]   public Vector4    Color;
    [FieldOffset(12 * 4)]  public Vector3    Velocity;
    [FieldOffset(15 * 4)]  public float      Extra;
}
```

The `FieldOffset` attributes make the byte alignment explicit, ensuring C# and HLSL agree on the layout even though the managed runtime might otherwise insert padding.

> **Key Insight:** By sharing the same struct layout between point operations and particle simulation, tixl avoids the need for separate buffer plumbing. Any operator that consumes points can consume the `ResultPoints` buffer that the particle system writes. The distinction between "this is a particle system" and "this is a static point cloud" is semantic, not structural.

## The Dual-Buffer Architecture

With a single struct layout established, tixl maintains two views of particle data at runtime. The main simulation kernel (`ParticleSystem.hlsl`) binds both buffers simultaneously:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl

StructuredBuffer<Point>    EmitPoints    : t0;  // input: new particles to emit
RWStructuredBuffer<Particle> Particles   : u0;  // simulation read/write
RWStructuredBuffer<Point>  ResultPoints  : u1;  // rendering output
```

The simulation buffer (`Particles`, UAV slot u0) carries the fields that matter for physics: `Velocity`, `Radius`, and `BirthTime`. Force shaders bind only this buffer and modify `Velocity` in-place. They never touch `ResultPoints` directly.

After forces have run and the simulation has integrated velocity into position, the main kernel copies the results into `ResultPoints` (UAV slot u1) in the `Point` semantic. Position and rotation transfer directly. Color is copied. But the fields whose meaning differs between views — `Scale`/`Velocity` and `FX1`/`FX2`/`BirthTime` — get special treatment. The operator exposes two parameters, `SetFx1To` and `SetFx2To`, that control what ends up in those user-facing slots:

- `KeepOriginal` — preserve whatever value was assigned at emission time
- `ParticleAge` — write `normalizedAge` into the field, ranging from 0.0 at birth to 1.0 at death
- `ParticleSpeed` — write `length(velocity) * 100` into the field

This means an artist can connect `FX1` downstream to drive size-over-lifetime in the billboard shader, or feed `FX2` into a gradient lookup, without the particle system caring about what those fields are used for. The simulation knows only physics quantities; the rendering side gets whatever variation data it needs.

Dead particles communicate their status through the `ResultPoints` buffer alone. When a particle's normalized age exceeds 1.0, the main kernel writes `NAN` into `ResultPoints[gi].Scale`. The rendering shaders test for this implicitly — a billboard sized by NAN produces degenerate geometry that the GPU discards — or explicitly via `isnan()` checks. The `Particles` buffer entry for that slot keeps its `BirthTime` until the circular buffer overwrites it at the next emission cycle.

## NAN-Based Death

Traditional particle systems maintain a dead list: a separate buffer of available slot indices, an atomic counter, and a compaction step to keep live particles tightly packed. tixl discards all of that.

A particle is dead when its `BirthTime == NAN`. That's it. No dead list, no counter, no compaction. The check at the top of every simulation and force shader is a single comparison:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl

if (Particles[gi].BirthTime == NAN)
    return;
```

Death itself happens in two ways. A reset writes `NAN` to all particles immediately:

```hlsl
if (TriggerReset > 0.5)
{
    Particles[gi].BirthTime = NAN;
    Particles[gi].Position  = NAN;
    ResultPoints[gi].Scale  = NAN;
}
```

Lifetime expiry writes `NAN` to `ResultPoints[gi].Scale` but leaves `Particles[gi].BirthTime` intact until overwritten. The distinction matters: force shaders skip dead particles via the `BirthTime` check, but the rendering shader only needs the scale to be NAN to suppress the billboard.

The elegance is in what NAN arithmetic does naturally. If a dead particle's velocity or position somehow leaks into a calculation, the result will be NAN, which will be discarded or clamped before it reaches the screen. The GPU's IEEE 754 behavior is the safety net. There's no explicit "don't process this particle" flag to propagate — the poison value does it automatically.

> **Key Insight:** NAN-as-dead-sentinel eliminates the need for dead-list management entirely. The tradeoff is that you can't reclaim dead slots selectively — you rely on the circular buffer to overwrite them in order. For a creative tool where "cycle through the buffer" behavior is perfectly acceptable, this is a pure win.

## Circular Buffer Emission

If the NAN sentinel replaces the dead list, what replaces the allocation logic? A monotonically incrementing counter called `CollectCycleIndex`, passed to the shader as an integer parameter each frame.

The main kernel runs with `[numthreads(64,1,1)]` across all `maxParticleCount` threads. Each thread handles exactly one particle slot. Whether that slot receives a new particle this frame is determined by `addIndex`:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl

int addIndex = 0;
if (EmitMode == 0)  // Sequential
{
    addIndex = (gi + CollectCycleIndex + maxParticleCount) % maxParticleCount;
}
```

The expression `(gi + CollectCycleIndex) % maxParticleCount` produces a rotating window. Each frame, `CollectCycleIndex` advances by the number of new emit points. Thread `gi` claims slot `addIndex` as its emission candidate, and if `addIndex` falls within the range of incoming emit points (`0 <= addIndex < newPointCount`), the thread writes a new particle:

```hlsl
if (TriggerEmit && addIndex >= 0 && addIndex < (int)newPointCount)
{
    Point emitPoint = EmitPoints[addIndex];

    Particles[gi].Position  = emitPoint.Position;
    Particles[gi].Rotation  = emitPoint.Rotation;
    Particles[gi].Radius    = emitPoint.Scale.x * RadiusFromW;
    Particles[gi].BirthTime = Time;

    float emitVelocity = InitialVelocity * (EmitVelocityFactor == 0
        ? 1
        : (EmitVelocityFactor == 1 ? emitPoint.FX1 : emitPoint.FX2));

    Particles[gi].Velocity = qRotateVec3(float3(0, 0, 1),
                                         normalize(Particles[gi].Rotation))
                             * emitVelocity;
}
```

This scheme wraps naturally. When the buffer fills up, new particles silently overwrite the oldest ones — no explicit eviction, no branch to handle the full-buffer case. The oldest particles are simply wherever `CollectCycleIndex` points next. If `LifeTime` is tuned correctly relative to `MaxParticleCount` and emission rate, the overwritten particles are already dead by the time they're recycled. If not, you get a visible pop as living particles are replaced — which is a valid visual effect, not just a bug.

The `ForLines` emit mode distributes particles evenly across the buffer rather than writing them sequentially. It's designed for line strips: when you want `N` emit points to land in `N` evenly-spaced slots rather than in a contiguous block, `ForLines` handles the index arithmetic to spread them out.

## Forces: Independent Compute Dispatches

With the simulation buffer established and the main kernel handling emission and integration, the force system adds velocity each frame. The design principle is radical simplicity: a force is nothing more than a compute shader that reads `Particles[i].Velocity` and adds something to it.

DirectionalForce is the minimal case:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl

[numthreads(64, 1, 1)]
void main(uint3 i : SV_DispatchThreadID)
{
    uint maxParticleCount, _;
    Particles.GetDimensions(maxParticleCount, _);

    if (i.x >= maxParticleCount)
        return;

    float3 offset = Direction * Amount
                    * (1 + hash11(i.x) * RandomAmount)
                    * SpeedFactor;
    Particles[i.x].Velocity += offset;
}
```

No dead-particle check needed here — if the velocity accumulates on a dead particle, the main kernel will skip it anyway. Each force binds only the `Particles` UAV; the `ResultPoints` buffer is invisible to forces. Forces accumulate velocity; the main kernel integrates position. The separation is clean.

The `SpeedFactor` parameter appears in every force shader. It's passed down from the `ParticleSystem` C# data type, which receives it from the node graph. Its job is frame-rate independence: rather than multiplying by a hardcoded delta-time, each force scales its contribution by a factor the artist controls, letting them tune the feel of the simulation independently of display rate.

More complex forces use tixl's template-based shader composition system. TurbulenceForce, for instance, accepts an optional `ValueField` input — a shader graph node that injects an SDF or field function. The HLSL template contains placeholder comments that get replaced at runtime:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl

/*{ADDITIONAL_INCLUDES}*/
/*{GLOBALS}*/
/*{RESOURCES(t0)}*/
/*{FIELD_FUNCTIONS}*/

float4 GetField(float4 p)
{
    float4 f = 1;
    /*{FIELD_CALL}*/
    return f;
}
```

When a field node is connected, the operator injects the relevant SDF function bodies into these placeholders and recompiles the shader. The result is that turbulence can be modulated by any field — a sphere SDF, a noise volume, a gradient — without TurbulenceForce needing to know about any of them. The field call is injected as source code, not passed as a texture or buffer.

> **Key Insight:** The template placeholder system is tixl's answer to shader composition. Rather than a formal module system or include hierarchy, field functions are injected as source-code strings at the use site. This keeps individual shaders simple while enabling arbitrary field expressions at the cost of needing a string-substitution preprocessing step before compilation.

The complete force inventory spans 16 distinct behaviors, organized by the kind of field they operate on:

- **Basic physics:** DirectionalForce, VelocityForce (speed clamping), AxisStepForce
- **Field-based:** TurbulenceForce (curl noise modulated by a field), FieldDistanceForce, FieldVolumeForce (SDF collision with bounce/attract/repel)
- **Mesh-based:** FollowMeshSurfaceForce, SdfForce (SDF gradient normal force)
- **Orientation:** SnapOrientationForce, SnapToAnglesForce
- **Texture-based:** ImageForce (texture lookup drives velocity), VectorFieldForce
- **Constraint:** ReconstructiveForce, VerletRibbonForce
- **Logic:** SwitchParticleForce (conditional force activation), RandomJumpForce

Each is an independent `.cs` file declaring its input slots and an independent `.hlsl` file doing the work. Adding a new force means writing one of each.

## The ParticleSystem Data Type

Between the HLSL shaders and the node graph sits the `ParticleSystem` C# class — a thin envelope that carries GPU resources across operator boundaries:

```csharp
// visual-programming/tixl/Core/DataTypes/ParticleSystem.cs

public class ParticleSystem
{
    public BufferWithViews ParticleBuffer;       // GPU buffer with SRV + UAV views
    public float           SpeedFactor;          // frame-rate independence scalar
    public bool            IsReset;              // reset signal for this frame
    public float           InitializeVelocityFactor;
}
```

`BufferWithViews` is a small wrapper around a DX11 structured buffer that keeps both a Shader Resource View (SRV, for reading in vertex/pixel shaders) and an Unordered Access View (UAV, for compute read/write) in one place. The particle buffer needs both because force shaders write via the UAV while rendering shaders read via the SRV.

The `ParticleSystem` instance flows through the node graph via context injection, not as a direct connection. The `_SetParticleSystemComponents` node sets `context.ParticleSystem` before evaluating its connected forces, and restores it afterward:

```csharp
// visual-programming/tixl/Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs

private void Update(EvaluationContext context)
{
    _particleSystem.ParticleBuffer             = PointsSimBuffer.GetValue(context);
    _particleSystem.SpeedFactor                = SpeedFactor.GetValue(context);
    _particleSystem.InitializeVelocityFactor   = InitializeVelocityFactor.GetValue(context);
    _particleSystem.IsReset                    = IsReset.GetValue(context);

    var effects = Forces.CollectedInputs;
    var keep    = context.ParticleSystem;
    if (effects != null)
    {
        context.ParticleSystem = _particleSystem;

        for (int i = 0; i < effects.Count; i++)
            effects[i].GetValue(context);
    }

    context.ParticleSystem = keep;
    Forces.DirtyFlag.Clear();
}
```

Force nodes extract the GPU resources they need via `GetParticleComponents`, which reads them back out of context:

```csharp
// visual-programming/tixl/Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs

private void Update(EvaluationContext context)
{
    ParticlesUav.Value  = context.ParticleSystem.ParticleBuffer.Uav;
    SpeedFactor.Value   = context.ParticleSystem.SpeedFactor;
    IsReset.Value       = context.ParticleSystem.IsReset;
    Length.Value        = context.ParticleSystem.ParticleBuffer.Srv.Description
                                                .Buffer.ElementCount;
}
```

This pattern — inject into context before evaluating children, restore afterward — means forces don't need explicit particle buffer connections in the node graph. The context acts as an implicit parameter channel. An artist connecting forces into the `ParticleForces` multi-slot of the ParticleSystem node gets the right buffer automatically.

## Node Graph Integration

Let's trace what happens when a ParticleSystem node evaluates. The artist has connected three force nodes (DirectionalForce, TurbulenceForce, FieldVolumeForce) into the `ParticleForces` multi-input slot:

1. The outer `ParticleSystem.cs` operator evaluates its inputs: `EmitPoints`, `MaxParticleCount`, `LifeTime`, `Speed`, `Drag`, and so on.
2. It allocates or retrieves the fixed-size GPU buffer at `MaxParticleCount` elements.
3. It dispatches the main `ParticleSystem.hlsl` compute shader, which handles emission, drag, velocity integration, lifetime check, and the copy into `ResultPoints`.
4. It passes the GPU buffer to `_SetParticleSystemComponents`, which injects it into `EvaluationContext.ParticleSystem`.
5. Each force in `ParticleForces` evaluates in order. DirectionalForce dispatches its compute shader, adding a directional velocity offset. TurbulenceForce dispatches its (potentially field-injected) curl-noise kernel. FieldVolumeForce dispatches its SDF bounce kernel.
6. All three dispatches write to the same `Particles` UAV. Velocity accumulates.
7. The context's `ParticleSystem` reference is restored for downstream operators.
8. The result `BufferWithViews` (containing both the simulation `Particles` UAV and the rendering `ResultPoints` SRV) flows downstream to whatever draw operator consumes it.

The pull-based lazy evaluation system means none of this happens if no downstream operator is consuming the output. tixl's dirty-flag mechanism ensures the particle simulation only runs when the result is actually needed on screen.

```csharp
// visual-programming/tixl/Operators/Lib/Symbols/particle/ParticleSystem.cs (slot declarations)

public readonly MultiInputSlot<T3.Core.DataTypes.ParticleSystem> ParticleForces
    = new MultiInputSlot<T3.Core.DataTypes.ParticleSystem>();
```

The `MultiInputSlot<ParticleSystem>` type signals to the runtime that multiple force nodes can connect here, and they'll be evaluated in order. The type parameter `ParticleSystem` is the C# data type, not an HLSL struct — it carries the GPU resource references and metadata needed to dispatch each force's compute shader.

## Rendering: VS-Based Geometry Expansion

The rendering side of tixl's particle architecture is completely decoupled from simulation. Any operator that produces a `BufferWithViews` containing a `Point`-structured buffer can feed into any draw mode. The particle system's `ResultPoints` buffer is structurally identical to a static point cloud, a mesh scatter, or a procedurally generated point set. That's the payoff of the shared struct layout.

All draw modes use vertex-shader-based geometry expansion with `SV_VertexID`. There are no geometry shaders. The billboard draw shader illustrates the pattern:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl

static const float3 Corners[] = {
    float3(-1, -1, 0), float3(1, -1, 0), float3(1, 1, 0),
    float3(1,  1, 0),  float3(-1, 1, 0), float3(-1, -1, 0),
};

StructuredBuffer<Point> Points : t0;

psInput vsMain(uint id : SV_VertexID)
{
    uint quadIndex = id % 6;
    uint pointId   = id / 6;

    Point p = Points[pointId];
    // ... expand point into quad ...
}
```

The draw call issues `pointCount * 6` vertices. The vertex shader recovers the point index by dividing `SV_VertexID` by 6, fetches the `Point` struct from the structured buffer, and expands it into one corner of a camera-aligned quad. No geometry shader, no instancing API — just arithmetic on `SV_VertexID` and a structured buffer read.

The billboard shader binds four additional textures that provide per-particle variation curves:

- `ColorOverW` — a 1D gradient texture sampled by a per-particle U coordinate (particle index, age, speed, or position along a line). Multiplied into point color.
- `SizeOverW` — same coordinate, drives a scale multiplier on top of the billboard size parameter.
- `FxTexture` — a screen-space texture sampled by the particle's projected screen position. Can modulate color, rotation, or scale.
- `SpriteTexture` — the actual billboard sprite, with atlas support for animated sprites.

The `FX1` field from the `Point` struct serves as the primary curve input. By connecting `SetFx1To = ParticleAge` in the particle system node, the age value flows through to the billboard shader where `SizeOverW.SampleLevel(sampler, float2(p.FX1, 0), 0)` drives size-over-lifetime. The gradient texture is the curve editor; `FX1` is the parameter that walks along it.

The full list of draw modes available for any point buffer — including particle system output — covers a wide range of visual primitives:

| Draw Mode | Description |
|---|---|
| DrawBillBoards | Camera-aligned quads, sprite atlas, FxTexture support |
| DrawPoints | Simple quads without full billboard machinery |
| DrawPointsShaded | Quads with PBR lighting |
| DrawLines | Line segments between sequential points |
| DrawLinesAlt | Alternative line rendering path |
| DrawLinesBuildup | Accumulative line drawing |
| DrawRibbons | Oriented quad strips connecting sequential points |
| DrawTubes | Cylindrical tubes along point sequences |
| DrawRayLines | Velocity-stretched ray lines |
| DrawConnectionLines | Lines connecting nearby points |
| DrawPointSprites | Screen-aligned sprites |
| DrawPointsDOF | Depth-of-field disk splatting |
| DrawMotionPoints | Motion-blur stretched points |
| DrawQuads | Arbitrary quads |
| DrawShimmer | Shimmering glitch effect |
| mesh-DrawAtPoints | Instanced mesh geometry at each point |

All of them consume the same `StructuredBuffer<Point>` at register `t0`. Switching a particle system from billboards to tubes is a one-connection change in the node graph.

## The Template-Based Shader Composition System

Several force shaders and draw shaders carry placeholder comments that look like `/*{FIELD_FUNCTIONS}*/` or `/*{RESOURCES(t0)}*/`. These aren't documentation — they're injection sites for tixl's shader graph system.

When an artist connects a field node (an SDF shape, a volume, a procedural function) to a force's `ValueField` input, tixl's `ShaderGraphNode` infrastructure generates the HLSL source for that field and splices it into the template at the placeholder. The resulting combined source is then compiled as a single shader. This happens at connection time, not each frame.

The `GetField` function wraps the injection point:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl

float4 GetField(float4 p)
{
    float4 f = 1;
    /*{FIELD_CALL}*/   // ← field function call injected here
    return f;
}
```

If no field is connected, `GetField` returns a constant `1`, and the force behaves uniformly. If a sphere SDF is connected, the sphere's distance function body and its `GetField` call are both injected, and the force modulates based on distance from that sphere's surface. The same turbulence shader handles both cases, with zero overhead in the no-field case.

This pattern appears in a dozen shaders. It's what allows FieldVolumeForce to work with any implicit surface, TurbulenceForce to be modulated by any scalar field, and DrawBillBoards to apply any field-based color modification — without any of those shaders needing to enumerate the possible field types.

## Comparison with Phoenix

Having seen both systems, the contrast is illuminating. Phoenix and tixl represent genuinely different philosophies about where particle intelligence should live.

| Aspect | tixl (GPU-first) | Phoenix (CPU-first) |
|---|---|---|
| Simulation location | Compute shaders | C++ update loop |
| Buffer ownership | GPU, fixed circular | CPU, fixed array |
| Death mechanism | NAN sentinel, no dead list | LiveCount compaction |
| Emission scheme | CollectCycleIndex circular overwrite | Sequential, tracks LiveCount |
| Force architecture | Independent compute dispatches | Affector objects in scene graph |
| Rendering expansion | VS expansion via SV_VertexID | GS expansion |
| Particle struct size | 64 bytes, 3 semantic views | ~84 bytes (dedicated fields) |
| Frame-rate independence | SpeedFactor on every force | Fixed 25 fps simulation tick |
| Parameter curves | GPU gradient textures (ColorOverW, SizeOverW) | Spline textures (1D LUTs) |
| Sorting | Not present in base system | CPU std::sort per frame |
| Shader composition | Template placeholder injection | Not applicable (C++ forces) |

The Phoenix CPU approach excels at flexibility: any C++ object can be an affector, particles can spawn sub-scenes, and the simulation can be debugged in a standard C++ debugger. tixl's GPU approach excels at scale and interactive performance: adding a force means connecting a node, and 500,000-particle systems respond in real time to parameter changes.

The NAN sentinel vs. LiveCount compaction tradeoff is worth dwelling on. Phoenix maintains an accurate count of live particles at all times, enabling tight rendering (no dead slots wasted on draw calls) and predictable behavior when the buffer is partially full. tixl's NAN approach never wastes GPU time on a sort or compaction pass, but draw calls always cover the full `MaxParticleCount` range — dead particles just produce degenerate geometry that gets discarded. At large counts, the GPU cost of discarding NAN quads is negligible compared to the cost of a sort.

## Implications for a Rust/wgpu Framework

tixl's architecture maps onto wgpu remarkably well. The design decisions that look specific to DX11 are actually more general than they appear.

The dual-buffer pattern (simulation UAV + rendering SRV from the same underlying allocation) corresponds directly to wgpu's `BufferUsages::STORAGE | BufferUsages::COPY_SRC` for compute and `BufferUsages::VERTEX` for rendering. A single `wgpu::Buffer` can carry both usage flags, letting a compute pass write to it and a render pass read from it — exactly the tixl pattern.

The fixed `[numthreads(64,1,1)]` dispatch maps to wgpu compute with a workgroup size of `@workgroup_size(64, 1, 1)` in WGSL. The arithmetic is identical.

NAN-based death works in WGSL with `bitcast` or `isNan()` (though WGSL's handling of NaN is explicitly implementation-defined in older spec versions; use with care and validate per-backend behavior). A more portable alternative would encode death as a sentinel float value just outside the valid range, such as `f32::NEG_INFINITY`, which has defined IEEE 754 behavior everywhere.

The template-based shader composition system would need a different implementation — wgpu has no runtime shader compilation in the DX11 sense. Options include using naga's shader composition API (still maturing as of early 2026), maintaining a string-template system that generates WGSL source before passing it to `wgpu::Device::create_shader_module`, or using `#define`-style conditional compilation in WGSL. The string-template approach is the most direct translation of tixl's model.

The Point/Particle struct duality suggests a single wgpu buffer with multiple bind group layouts. The same `wgpu::Buffer` could be bound as a `Particle` array in compute passes (where the struct fields carry velocity and birth time) and as a `Point` array in render passes (where the same bytes carry scale and FX attributes). Bind group layouts in wgpu describe how the GPU interprets a buffer's contents, not the buffer itself — so two layouts can describe the same memory with different field semantics, exactly as tixl does.

> **Key Insight:** The 64-byte point struct is not an arbitrary choice. It fits comfortably in a GPU cache line on most architectures, and its layout ensures the most frequently accessed fields (Position at offset 0, Color at offset 32) are naturally aligned. A Rust framework targeting wgpu should adopt this layout or something structurally equivalent, and resist the temptation to separate simulation and rendering data into distinct buffers until profiling demonstrates a clear need.

The force system's clean interface — bind the particle UAV, dispatch, add velocity — translates naturally to a Rust trait:

```rust
// conceptual mapping, not actual tixl code
trait ParticleForce {
    fn dispatch(
        &self,
        encoder:      &mut wgpu::CommandEncoder,
        particle_buf: &wgpu::Buffer,
        count:        u32,
        speed_factor: f32,
    );
}
```

Each force implementation creates its own pipeline and bind group, dispatches a compute pass, and returns. Forces chain by sharing the same `particle_buf` reference. The `_SetParticleSystemComponents` pattern — inject into context, evaluate children, restore — could map to a Rust `ForceChain` struct that holds the buffer reference and dispenses it to each force in sequence.

## Key Files Reference

| File | Role |
|---|---|
| `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point.hlsl` | Defines `Point`, `Particle`, and `LegacyPoint` structs; the shared 64-byte layout |
| `visual-programming/tixl/Core/DataTypes/ParticleSystem.cs` | C# data type carrying the GPU buffer across operator boundaries |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl` | Main simulation kernel: emission, drag, integration, lifetime, result copy |
| `visual-programming/tixl/Operators/Lib/Symbols/particle/ParticleSystem.cs` | Node operator declaring all simulation inputs and the `ParticleForces` multi-slot |
| `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs` | Injects particle state into `EvaluationContext`; evaluates force chain |
| `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs` | Extracts UAV and SpeedFactor from context for use inside force operators |
| `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/_ExecuteParticleUpdate.cs` | Batches and executes command-based simulation operations |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl` | Minimal force example: add a directional velocity offset |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl` | Template-based force with field injection: curl-noise turbulence |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/FieldVolumeForce.hlsl` | SDF collision: attract, repel, bounce off any implicit surface |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/SdfForce.hlsl` | SDF gradient normal force for surface alignment |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/VelocityForce.hlsl` | Speed clamping and acceleration along current velocity direction |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl` | Billboard renderer: SV_VertexID expansion, ColorOverW, SizeOverW, FxTexture |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawPoints.hlsl` | Simple quad renderer, illustrating the basic SV_VertexID expansion pattern |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawRibbons.hlsl` | Ribbon renderer connecting sequential points into oriented quad strips |
| `visual-programming/tixl/Operators/Lib/Symbols/particle/force/DirectionalForce.cs` | C# node wrapping DirectionalForce compute dispatch |
| `visual-programming/tixl/Operators/Lib/Symbols/particle/force/TurbulenceForce.cs` | C# node for turbulence with optional ValueField shader graph input |
