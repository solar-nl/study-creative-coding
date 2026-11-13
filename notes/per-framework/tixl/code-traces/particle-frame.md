This code trace follows a single frame through tixl's particle system — from the operator graph evaluating `ParticleSystem.cs`, through context injection and force chain execution, the core compute shader dispatch (emission, integration, death, dual-buffer copy), to the final `DrawBillboards` pixel output. Every step from force dispatch onward runs on the GPU. The CPU's role is brief: evaluate input slots, set up the context, and hand control to the driver.

The key thing to hold in mind before reading any code is that tixl's particle system is not a simulation that runs and then uploads results. There is no upload. The canonical particle state lives in a GPU buffer from the moment it is born, and it stays there. Forces are not C# objects that iterate a list — they are compute shader dispatches that write directly into that same buffer. The C# code you will read is orchestration, not simulation.

Think of it like a restaurant kitchen. The head chef (the C# graph evaluator) reads the ticket, assembles the right ingredients (GPU buffer references, speed factors, reset signals), and hands them to the line cooks (compute shader dispatches) in order. Each cook reads from a shared prep surface (the `Particles` UAV) and puts their contribution back. The final plating (the `DrawBillboards` vertex shader) reads the completed prep surface and arranges it for the guest. The head chef never touches the food directly.

This particular frame has 10,000 particles active, three force nodes connected (DirectionalForce, TurbulenceForce, a second DirectionalForce), and a DrawBillboards node consuming the output. The artist has set `SetFx1To = ParticleAge` so that normalized lifetime flows into the billboard shader's size and color curves.

## The Scenario

- **10,000 MaxParticleCount** — fixed buffer size allocated at startup
- **Three forces connected** — DirectionalForce (gravity), TurbulenceForce (curl noise), DirectionalForce (wind)
- **Sequential emit mode** — new particles fill slots in circular order
- **SetFx1To = ParticleAge** — FX1 carries normalized age for downstream curve sampling
- **DrawBillboards** — VS-expansion, no geometry shader, 6 vertices per point

## Phase 1: Graph Evaluation Triggers ParticleSystem

Pull-based lazy evaluation means nothing runs until something asks for a result. The rendering system asks `DrawBillboards` for a `Command` to execute. `DrawBillboards` needs a `StructuredBuffer<Point>` — the `OutBuffer` slot of the upstream `ParticleSystem` node. That request propagates backward through the graph until it reaches `ParticleSystem.cs`.

`ParticleSystem.cs` is a thin shell. Its output slot is declared at:

```csharp
// visual-programming/tixl/Operators/Lib/Symbols/particle/ParticleSystem.cs:7-8
[Output(Guid = "51b9c6bd-b7cc-48a4-979b-3febcac914c2")]
public readonly Slot<BufferWithViews> OutBuffer = new();
```

The actual computation happens inside a compound operator — a `.t3` file that wires together the internal nodes `_SetParticleSystemComponents` and the main simulation compute dispatch. When `OutBuffer` is evaluated as dirty, the graph walks into those internal nodes. The entry point into live code is `_SetParticleSystemComponents`.

## Phase 2: _SetParticleSystemComponents — Inject Context

`_SetParticleSystemComponents` is the orchestrator for the entire force chain. Its job is to take the particle buffer and associated scalars, package them into a `ParticleSystem` C# object, and make that object available to all downstream force nodes through a side channel: the `EvaluationContext`.

```csharp
// visual-programming/tixl/Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs:14-41
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
        {
            effects[i].GetValue(context);
        }
    }

    context.ParticleSystem = keep;
    Forces.DirtyFlag.Clear();
}
```

Step by step: the method pulls `PointsSimBuffer` (the `BufferWithViews` wrapping the fixed-size GPU buffer), `SpeedFactor`, `InitializeVelocityFactor`, and the `IsReset` flag from their input slots. These go into `_particleSystem`, which is a `T3.Core.DataTypes.ParticleSystem` — a tiny C# class holding those scalars plus the GPU buffer reference:

```csharp
// visual-programming/tixl/Core/DataTypes/ParticleSystem.cs:8-14
public class ParticleSystem
{
    public BufferWithViews ParticleBuffer;
    public float           SpeedFactor;
    public bool            IsReset;
    public float           InitializeVelocityFactor;
}
```

`BufferWithViews` itself is equally minimal:

```csharp
// visual-programming/tixl/Core/DataTypes/BufferWithViews.cs:5-10
public sealed class BufferWithViews : IDisposable
{
    public SharpDX.Direct3D11.Buffer              Buffer;
    public SharpDX.Direct3D11.ShaderResourceView  Srv;
    public SharpDX.Direct3D11.UnorderedAccessView Uav;
}
```

The same buffer carries both a Shader Resource View (SRV, for read-only access in vertex and pixel shaders) and an Unordered Access View (UAV, for compute read-write). Forces bind the UAV. The billboard renderer later binds the SRV. One GPU allocation, two API views.

The nesting trick is the critical design move: `context.ParticleSystem = _particleSystem` injects the object into the evaluation context before calling `effects[i].GetValue(context)` for each force. After all forces have run, `context.ParticleSystem = keep` restores whatever was there before. This means force nodes never need an explicit buffer connection in the graph — they read from context, which acts as an implicit parameter channel. An artist connecting forces to the `ParticleForces` multi-slot gets the right buffer automatically, and nested particle systems can coexist safely because each restores the previous value on exit.

## Phase 3: Force Chain Execution

The `Forces.CollectedInputs` list holds three items in this frame: DirectionalForce (gravity), TurbulenceForce (curl noise), DirectionalForce (wind). Each is evaluated sequentially by `effects[i].GetValue(context)`. Evaluation of each force ultimately dispatches a compute shader against the shared `Particles` UAV.

Force nodes extract what they need from context via `GetParticleComponents`:

```csharp
// visual-programming/tixl/Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs:40-46
ParticlesUav.Value = context.ParticleSystem.ParticleBuffer.Uav;
SpeedFactor.Value  = context.ParticleSystem.SpeedFactor;
IsReset.Value      = context.ParticleSystem.IsReset;
Length.Value       = context.ParticleSystem.ParticleBuffer.Srv.Description.Buffer.ElementCount;
```

These four output slots — the UAV, the speed scalar, the reset flag, and the element count — flow into the force's compute dispatch.

### Step 3a: DirectionalForce (Gravity)

DirectionalForce is the minimal example of a force. The HLSL is 27 lines:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl:1-27
#include "shared/hash-functions.hlsl"
#include "shared/point.hlsl"

cbuffer Params : register(b0)
{
    float3 Direction;
    float  Amount;
    float  RandomAmount;
    float  SpeedFactor;
}

RWStructuredBuffer<Particle> Particles : u0;

[numthreads(64, 1, 1)] void main(uint3 i : SV_DispatchThreadID)
{
    uint maxParticleCount, _;
    Particles.GetDimensions(maxParticleCount, _);

    if (i.x >= maxParticleCount)
        return;

    float3 offset = Direction * Amount * (1 + hash11(i.x) * RandomAmount) * SpeedFactor;
    Particles[i.x].Velocity += offset;
}
```

The dispatch covers `ceil(10000 / 64) = 157` thread groups, 64 threads each. Every thread handles one particle slot. There is no dead-particle check — if a dead particle accumulates velocity, the main simulation kernel will skip it anyway. The force does not care. It simply adds `Direction * Amount * SpeedFactor` (with per-particle hash noise scaled by `RandomAmount`) to whatever velocity is already there.

The `SpeedFactor` parameter appears in every force shader. It is the frame-rate independence mechanism. Rather than multiplying by delta-time, each force scales its contribution by a factor the artist controls. Frame timing is encoded in this scalar, not in explicit timing logic inside the shader.

### Step 3b: TurbulenceForce (Curl Noise)

TurbulenceForce shows the template placeholder system. The shader carries injection sites for field functions:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl:6-71
/*{ADDITIONAL_INCLUDES}*/

cbuffer Params : register(b0)
{
    float Amount;
    float Frequency;
    float Phase;
    float Variation;
    float SpeedFactor;
}

RWStructuredBuffer<Particle> Particles : u0;

/*{GLOBALS}*/
/*{RESOURCES(t0)}*/
/*{FIELD_FUNCTIONS}*/

float4 GetField(float4 p)
{
    float4 f = 1;
    /*{FIELD_CALL}*/
    return f;
}

[numthreads(64, 1, 1)] void main(uint3 i : SV_DispatchThreadID)
{
    uint maxParticleCount, _;
    Particles.GetDimensions(maxParticleCount, _);
    if (i.x >= maxParticleCount)
        return;

    float3 variationOffset = hash41u(i.x).xyz * Variation;
    float3 pos = Particles[i.x].Position * 0.9;
    float3 noiseLookup = (pos + variationOffset + Phase * float3(1, -1, 0)) * Frequency;

    float4 field = GetField(float4(pos, 0));
    float  fieldAmount = (field.r + field.g + field.b) / 3;

    float amount = Amount / 100 * fieldAmount * SpeedFactor;
    Particles[i.x].Velocity = Particles[i.x].Velocity + curlNoise(noiseLookup) * amount;
}
```

In this frame, no field node is connected, so `GetField` returns the constant `float4(1,1,1,1)` and `fieldAmount` is 1.0 — the force applies uniformly across all particles. When a field is connected, tixl injects the field function body and its call at the placeholder sites and recompiles the shader. This happens at connection time, not each frame.

The curl noise itself is sampled at each particle's current position scaled by `Frequency`, offset by `Phase` and a per-particle `Variation` hash. The result is a divergence-free velocity field — particles appear to swirl and spiral rather than converging or diverging, which is the characteristic look of turbulence in particle systems.

After TurbulenceForce executes, every particle's velocity carries contributions from gravity and curl noise simultaneously. The buffers are not separate: it is the same `Particles[i.x].Velocity` field, accumulated in-place.

### Step 3c: DirectionalForce (Wind)

The second DirectionalForce executes identically to the first, with a different `Direction` and `Amount` from its cbuffer. After this dispatch, each live particle's velocity is the sum of three contributions: gravity downward, curl-noise swirl, and wind sideways. The force chain is complete.

Here's where it gets interesting: nothing prevents a dead particle's velocity from accumulating these contributions. The NAN sentinel on `BirthTime` is not checked in force shaders at all. The main simulation kernel handles that gate. Forces are intentionally ignorant of particle state — they apply their delta uniformly, and the main kernel decides what to do with the result.

## Phase 4: Core Compute Shader — ParticleSystem.hlsl

With all three forces dispatched, the main simulation kernel runs. This shader handles six distinct responsibilities in a single pass: reset, emission, death gate, velocity integration, orientation, and the dual-buffer copy. Thread dispatch is the same pattern: `[numthreads(64, 1, 1)]` across `ceil(10000 / 64) = 157` groups.

The shader binds three buffers simultaneously:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:29-31
StructuredBuffer<Point>    EmitPoints   : t0;  // input: new particles to emit
RWStructuredBuffer<Particle> Particles  : u0;  // simulation state: read/write
RWStructuredBuffer<Point>  ResultPoints : u1;  // rendering output: write
```

Each thread takes `uint gi = i.x` as its particle index and proceeds through the phases in sequence.

### Phase 4a: Reset

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:49-54
if (TriggerReset > 0.5)
{
    Particles[gi].BirthTime = NAN;
    Particles[gi].Position  = NAN;
    ResultPoints[gi].Scale  = NAN;
}
```

If the reset flag is set, all 10,000 threads simultaneously write NAN to their respective slots. This is instant — no loop, no CPU involvement, just a massively parallel write. After this block executes on every thread, the entire buffer is marked dead. This frame does not trigger reset; the condition is false, and all threads skip past it.

### Phase 4b: Emission

The circular buffer emission logic resolves which slot each thread will try to claim as an emission target:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:57-60
int addIndex = 0;
if (EmitMode == 0)  // Sequential
{
    addIndex = (gi + CollectCycleIndex + maxParticleCount) % maxParticleCount;
}
```

`CollectCycleIndex` is a monotonically incrementing counter passed as an integer constant. It advances by the number of new emit points each frame, so the emission window rotates through the buffer over time. Thread `gi` computes its `addIndex` — if that value falls within `[0, newPointCount)`, this thread has won the right to emit a particle into slot `gi`:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:71-97
if (TriggerEmit && addIndex >= 0 && addIndex < (int)newPointCount)
{
    Point emitPoint = EmitPoints[addIndex];

    Particles[gi].Position = emitPoint.Position;
    Particles[gi].Rotation = emitPoint.Rotation;
    Particles[gi].Radius   = emitPoint.Scale.x * RadiusFromW;
    Particles[gi].BirthTime = Time;

    float emitVelocity = InitialVelocity * (EmitVelocityFactor == 0 ? 1
        : (EmitVelocityFactor == 1 ? emitPoint.FX1 : emitPoint.FX2));

    Particles[gi].Velocity = qRotateVec3(float3(0, 0, 1),
        normalize(Particles[gi].Rotation)) * emitVelocity;

    Particles[gi].Color      = emitPoint.Color;
    ResultPoints[gi].Scale   = emitPoint.Scale;
    ResultPoints[gi].FX1     = emitPoint.FX1;
    ResultPoints[gi].FX2     = emitPoint.FX2;
    ResultPoints[gi].Color   = emitPoint.Color;
}
```

Notice what gets written where. `Particles[gi]` receives the simulation fields: position, rotation, radius (a physics quantity), birth time (a simulation timestamp), velocity (derived from the rotation quaternion and the initial speed scalar). `ResultPoints[gi]` receives the rendering fields: scale (which the billboard shader reads to size the quad), FX1, FX2, and color. These two writes happen simultaneously to two different UAV bindings from the same thread.

The `qRotateVec3(float3(0, 0, 1), normalize(Rotation))` expression converts the emission point's quaternion orientation into a world-space direction, then scales it by `emitVelocity`. This means particles inherit the orientation of their emit point — a particle emitted from a mesh face pointing upward will launch upward.

### Phase 4c: Death Gate

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:99-100
if (Particles[gi].BirthTime == NAN)
    return;
```

Any thread whose particle slot has `BirthTime == NAN` returns here. No integration, no copy, no output. The slot is invisible to everything downstream.

You might wonder: how does this interact with the forces that already ran? Those forces wrote velocity into every slot, including dead ones. That velocity sits there, unused. When the circular buffer eventually recycles the slot for a new particle, the emission code overwrites velocity with `qRotateVec3(...) * emitVelocity`, discarding whatever the forces accumulated. The dead slot's accumulated velocity is harmless noise that gets clobbered at next emission.

### Phase 4d: Velocity Integration

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:102-113
float3 velocity = Particles[gi].Velocity;

velocity *= pow(1.0f - Drag, Speed);  // frame-rate-independent drag
Particles[gi].Velocity = velocity;

float3 pos = Particles[gi].Position;
pos += velocity * Speed * 0.01;       // position step
Particles[gi].Position = pos;
```

Drag is applied as `pow(1.0 - Drag, Speed)` rather than a simple `velocity *= (1 - Drag)`. This is the improved version (noted by the comment on line 105 that a simpler version was replaced). The `pow` formulation keeps the drag behavior consistent regardless of `Speed`, since `Speed` also scales the position step. If an artist doubles `Speed`, the drag factor compensates so that the feel of the simulation stays similar.

Position advances by `velocity * Speed * 0.01`. The `0.01` is a global scale factor that keeps typical velocity values in a human-friendly range — an artist types `1.0` for gravity rather than `0.01`.

### Phase 4e: Orientation

After velocity integration, the main kernel optionally re-orients particles to face their direction of travel:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:115-120
float speed = length(velocity);
if (speed > 0.0001)
{
    float f = saturate(speed * OrientTowardsVelocity);
    Particles[gi].Rotation = qSlerp(Particles[gi].Rotation,
        qLookAt(velocity / speed, float3(0, 1, 0)), f);
}
```

`OrientTowardsVelocity` is 0 by default, making `f = 0` and leaving rotation unchanged. At `OrientTowardsVelocity = 1`, fast-moving particles fully align with their velocity vector. At values in between, the slerp blends between original orientation and velocity-aligned orientation. The `speed` threshold prevents division by zero and suppresses orientation updates for nearly stationary particles.

### Phase 4f: Dual-Buffer Copy

With simulation complete, the main kernel copies the updated position, rotation, and color into `ResultPoints`:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:122-127
ResultPoints[gi].Position = Particles[gi].Position;
ResultPoints[gi].Rotation = Particles[gi].Rotation;
ResultPoints[gi].Color    = Particles[gi].Color;
```

Note what is not copied: `Velocity` and `BirthTime` from the `Particle` view become `Scale` and `FX2` in the `Point` view at the same memory offsets. The copy does not touch those fields. They were written during emission and remain as set — `Scale` holds the emitted size (set at birth), and `FX2` holds whatever emission point attribute was there. The copy transfers only the fields that change every frame due to physics.

### Phase 4g: FX Attribute Mapping and Death by Age

The final block writes the FX attributes and tests for lifetime expiry:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:133-161
float lifeTime = LifeTime < 0.0
    ? (IsAutoCount ? 100000 : (float)(maxParticleCount / (newPointCount * 60.0)))
    : LifeTime;

float normalizedAge = (IsAutoCount && LifeTime < 0)
    ? 1
    : (Time - Particles[gi].BirthTime) / lifeTime;
bool tooOld = normalizedAge > 1;

if (SetFx1To == W_PARTICLE_AGE)
    ResultPoints[gi].FX1 = normalizedAge;
else if (SetFx1To == W_PARTICLE_SPEED)
    ResultPoints[gi].FX1 = speed * 100;

if (SetFx2To == W_PARTICLE_AGE)
    ResultPoints[gi].FX2 = normalizedAge;
else if (SetFx2To == W_PARTICLE_SPEED)
    ResultPoints[gi].FX2 = speed * 100;

if (tooOld)
    ResultPoints[gi].Scale = NAN;
```

In this frame, `SetFx1To = W_PARTICLE_AGE`, so `ResultPoints[gi].FX1 = normalizedAge` runs for every live particle. A particle born at frame 0 of a 5-second lifetime is at age 0.0; halfway through it's at 0.5; at expiry it's at 1.0 and `tooOld` becomes true.

Death by age writes `NAN` to `ResultPoints[gi].Scale`. The `Particles[gi].BirthTime` remains intact. This is intentional: force shaders test `BirthTime` to skip dead slots, while rendering shaders test `Scale` (through the implicit NAN-scale-to-zero behavior in the vertex shader). The slot will be reclaimed naturally the next time `CollectCycleIndex` rotates around to it.

## Phase 5: DrawBillboards — Point to Pixels

The `ResultPoints` buffer now holds the state for all 10,000 slots: live particles with valid position, rotation, color, and FX1 (normalized age); dead particles with NAN in Scale. The billboard renderer consumes this buffer.

### Step 5a: C# Draw Call Setup

The `DrawBillboards` C# operator sets up DX11 state: blend mode, depth test, sampler, constant buffers (camera matrices, fog parameters, billboard parameters). It then issues:

```
Draw(vertexCount: 10000 * 6 = 60000, startVertex: 0)
```

No index buffer. No geometry shader. Just 60,000 vertices flowing into the vertex shader, with `SV_VertexID` as the only input.

### Step 5b: Vertex Shader — One Point, Six Invocations

The billboard shader binds `ResultPoints` as `StructuredBuffer<Point>` at register `t0`:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl:5-13
static const float3 Corners[] = {
    float3(-1, -1, 0), float3(1, -1, 0), float3(1,  1, 0),
    float3(1,  1, 0),  float3(-1, 1, 0), float3(-1, -1, 0),
};

StructuredBuffer<Point> Points : t0;
```

The vertex shader entry point takes only a vertex ID:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl:130-146
psInput vsMain(uint id : SV_VertexID)
{
    uint quadIndex = id % 6;    // which corner of this quad (0-5)
    uint pointId   = id / 6;    // which particle (0-9999)
    float3 cornerFactors = Corners[quadIndex];

    Point p = Points[pointId]; // read from ResultPoints
```

For `id = 0..5`, `pointId = 0` — all six invocations read the same first particle. For `id = 6..11`, `pointId = 1` — second particle. And so on. The two triangles that form each quad (vertices 0,1,2 and vertices 3,4,5 from the `Corners` array, sharing an edge) are generated without any instancing API.

For dead particles, `p.Scale` is NAN. This flows into `computedScale`:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl:227-229
float hideUndefinedPoints = isnan(p.FX1) ? 0 : (UseWFoScale > 0.5 ? p.FX1 : 1);
float computedScale = adjustedScale * ... * scaleFromCurve * hideUndefinedPoints;
```

When `p.FX1` is NAN (which it will be for a properly dead particle, since FX1 was set to NAN at death), `hideUndefinedPoints` evaluates to 0 and the entire scale collapses to zero. The particle's quad degenerates to a point and produces no rasterized fragments. Dead particles cost one vertex shader invocation each but zero pixel shader invocations and zero pixel output.

The color path reads `FX1` (the normalized age written by the main simulation kernel) through `ColorOverW`, a 1D gradient texture sampled as:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl:199
output.color = p.Color * Color * ColorOverW.SampleLevel(texSampler, float2(colorFxU, 0), 0) * colorFromPoint;
```

Here is the payoff of `SetFx1To = ParticleAge`: the artist drew a gradient in the `ColorOverW` texture — orange at birth, fading to dark red at death — and connected it. The particle's `FX1` field walks along that gradient automatically over its lifetime, without any additional node connections.

Size works the same way. `SizeOverW` is sampled with the `ScaleDistribution`-driven U coordinate, producing a size multiplier that the artist shapes as a curve. Particles can grow and shrink over their lifetime through texture lookups, not per-particle CPU state.

The orientation path computes billboard position in camera space, then projects:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl:183-247
float4 quadPosInCamera = mul(posInObject, ObjectToCamera);

float2 corner = float2((cornerFactors.xy + Offset.xy) * 0.010 * Stretch ...) * float2(-1, -1);
float4 rot = qFromAngleAxis((adjustedRotate + ...) * 3.141578 / 180, RotationAxis);
corner = qRotateVec3(float3(corner, 0), rot).xy;
output.position = mul(quadPosInCamera + float4(corner * computedScale, 0, 0), CameraToClipSpace);
```

The corner offset is applied in camera space, then the combined position is projected. This guarantees the billboard always faces the camera regardless of particle orientation — the quad's plane is always perpendicular to the view axis because the expansion happens after the world-to-camera transform.

### Step 5c: Pixel Shader — Sprite and Alpha

The pixel shader runs for every rasterized fragment inside the six triangles that form a live particle's quad:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl:259-269
float4 psMain(psInput input) : SV_TARGET
{
    float4 imgColor = SpriteTexture.Sample(texSampler, input.texCoord);
    float4 color    = input.color * imgColor;

    if (color.a < AlphaCutOff)
        discard;

    color.rgb = lerp(color.rgb, FogColor.rgb, input.fog * FogColor.a);
    return clamp(color, 0, float4(100, 100, 100, 1));
}
```

`SpriteTexture` is the actual billboard image — a soft circle, a spark, a snowflake. `input.color` arrived from the vertex shader carrying the per-particle tint (from `ColorOverW` sampling and `p.Color`). The two multiply. If the resulting alpha falls below `AlphaCutOff`, the fragment is discarded. This enables per-particle transparency without sorting, at the cost of hard edges at the cutoff boundary.

The fog blend is applied to RGB only, not alpha. Fog makes distant particles take on the fog color rather than becoming transparent — appropriate for volumetric particle effects where you want to see the fog, not see through the particles.

The `clamp` on output caps RGB at 100, allowing HDR-range values that downstream tone mapping and bloom can process, while preventing runaway accumulation in additive blend modes.

## Phase 6: Rasterizer and Output Merger

DX11's rasterizer processes the triangles from each live particle's quad. For 10,000 particles with, say, an average screen coverage of 20x20 pixels, the pixel shader runs approximately 4 million times. Each run is independent — no communication between fragments, no shared state.

The output merger applies depth test and blend state. Particle rendering typically uses depth read without depth write: a particle behind a solid mesh gets culled by the depth test, but the particle itself does not write to the depth buffer, so a second particle behind the first will be tested against the solid mesh, not against the first particle. Particles correctly occlude behind solid geometry but do not occlude each other through depth.

The final blended color accumulates in the render target. For additive blend (`SrcBlend = ONE, DstBlend = ONE`), overlapping particles add their colors together, producing the characteristic bright halos where many particles cluster. For alpha blend, front-to-back ordering matters and the lack of sorting in this system can produce artifacts — tixl does not sort particles in the base system, leaving sort-order correctness as the artist's responsibility (or choosing effects that look plausible without sorting, like additive-blended sparks).

## Data Flow Summary

```
EmitPoints buffer (StructuredBuffer<Point> at t0)
    |
    v
ParticleSystem.hlsl (emission phase)
    |
    v
Particles UAV (u0) — simulation state, persists across frames
    |
    +---> DirectionalForce.hlsl  — Particles[i].Velocity += direction * amount
    |
    +---> TurbulenceForce.hlsl   — Particles[i].Velocity += curlNoise(pos) * amount
    |
    +---> DirectionalForce.hlsl  — Particles[i].Velocity += wind * amount
    |
    v
ParticleSystem.hlsl (integration + copy phase)
    | drag → position → orientation → copy to ResultPoints
    v
ResultPoints UAV (u1) — refreshed each frame from Particles
    |
    v
DrawBillBoards.hlsl (vertex shader, 6 invocations per point)
    | SV_VertexID → pointId = id/6, quadIndex = id%6
    | p = Points[pointId] (reads ResultPoints as SRV at t0)
    | → camera-space quad expansion → clip-space projection
    v
DrawBillBoards.hlsl (pixel shader)
    | SpriteTexture.Sample() * input.color
    | → alpha cutoff → fog blend → clamp
    v
Output Merger: depth test, alpha/additive blend → Render Target
```

## Buffer Lifetime Within Frame

```
+---------------------------------------------------------------+
| Particles (UAV u0)                                            |
|  Written: emission (new slot claim), force dispatches         |
|           (velocity accumulate), integration (drag, position, |
|           orientation)                                        |
|  Read:    integration reads back its own writes; forces read  |
|           velocity and position for field calculations        |
|  State:   PERSISTS across frames — simulation is stateful     |
+---------------------------------------------------------------+
| ResultPoints (UAV u1)                                         |
|  Written: emission (Scale, FX1, FX2, Color at birth);        |
|           integration (Position, Rotation, Color each frame); |
|           death (Scale = NAN when age > 1)                    |
|  Read:    DrawBillboards vertex shader (as SRV at t0)         |
|  State:   REFRESHED each frame from Particles                 |
+---------------------------------------------------------------+
| EmitPoints (SRV t0)                                           |
|  Written: upstream point generation operator (not this frame) |
|  Read:    emission phase only                                 |
|  State:   TRANSIENT — provided by upstream, not owned         |
+---------------------------------------------------------------+
```

The statefulness of `Particles` is the key architectural fact. Every other buffer in tixl is computed fresh each frame from the graph. `Particles` is not. It carries physics state — velocity, birth time, position — that accumulates over many frames of simulation. This is why the buffer must be fixed-size and GPU-resident: any upload would require synchronizing decades of simulation history, which is impractical.

## Timing

All operations except C# graph evaluation run on the GPU. For 10,000 particles with three forces:

| Stage | Work | Estimated Cost |
|---|---|---|
| C# evaluation | Slot reads, context setup | ~10-50 microseconds |
| DirectionalForce dispatch | 157 thread groups x 64 threads | ~0.1-0.3 ms |
| TurbulenceForce dispatch | 157 thread groups, curl noise | ~0.3-0.8 ms |
| DirectionalForce dispatch | 157 thread groups x 64 threads | ~0.1-0.3 ms |
| ParticleSystem.hlsl dispatch | 157 thread groups, all phases | ~0.5-1.5 ms |
| DrawBillboards VS | 60,000 vertex invocations | ~0.2-0.5 ms |
| DrawBillboards PS | ~4M pixel invocations (estimated) | ~1-4 ms |
| Output merger | Depth test, blend, write | ~0.5-1 ms |
| **Total GPU** | | **~3-9 ms** |

These are rough estimates — actual cost depends heavily on GPU generation, shader occupancy, and texture cache behavior. The force chain dispatches are small and fast individually. The pixel shader cost dominates at any particle count where the quads are large on screen. At 100,000 particles with small quads, the pattern reverses: compute dispatches dominate and the pixel shader cost drops.

## Key Files Referenced

| File | Role in This Trace |
|---|---|
| `visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point.hlsl` | Defines `Point`, `Particle`, and `LegacyPoint` — the shared 64-byte struct layout |
| `visual-programming/tixl/Core/DataTypes/ParticleSystem.cs` | C# envelope carrying GPU buffer and scalars across operator boundaries |
| `visual-programming/tixl/Core/DataTypes/BufferWithViews.cs` | Wraps DX11 buffer with both SRV and UAV in one object |
| `visual-programming/tixl/Core/Operator/EvaluationContext.cs` | Context object with `ParticleSystem` field used as implicit parameter channel |
| `visual-programming/tixl/Operators/Lib/Symbols/particle/ParticleSystem.cs` | Node operator declaring `OutBuffer`, `ParticleForces` multi-slot, and all simulation inputs |
| `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs` | Orchestrator: injects particle state into context, evaluates force chain, restores context |
| `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs` | Extracts UAV, SpeedFactor, IsReset, and Length from context for force operators |
| `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/_ExecuteParticleUpdate.cs` | Batch command executor used for command-based simulation operations |
| `visual-programming/tixl/Operators/Lib/Symbols/particle/force/DirectionalForce.cs` | C# node for DirectionalForce — declares Direction, Amount, RandomAmount input slots |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl` | Minimal force kernel: `Particles[i].Velocity += direction * amount * hash * SpeedFactor` |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl` | Template-based force: curl noise with `/*{FIELD_CALL}*/` injection site for field modulation |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl` | Main simulation kernel: reset, emission, death gate, drag, integration, orientation, copy |
| `visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl` | Billboard renderer: `SV_VertexID` expansion, ColorOverW/SizeOverW sampling, fog, alpha cutoff |
