# Particle Simulation: One Dispatch to Rule Them All

> When a single GPU compute pass handles birth, physics, death, and output in 163 lines of HLSL

There is a particular elegance to a system that does exactly one thing per frame and does it completely. Tixl's particle simulation is that system. Every frame, a single compute dispatch fires across the entire particle buffer — every thread independently decides whether to emit a new particle, skip a dead slot, integrate physics, orient toward velocity, or retire an aged particle and hide it from the renderer. No CPU loops. No intermediate staging buffers. No ping-pong between passes. One dispatch, all phases, done. The result lands directly in a `Point` buffer that the rendering nodes read on the very next stage.

This matters because the alternative is complexity. Most GPU particle systems separate emission from simulation from culling, each phase requiring its own pass and often its own buffer layout. Tixl collapses all four concerns into `ParticleSystem.hlsl`, exploiting a key insight: since every slot in the fixed-size buffer is always either dead or alive, there is no need to compact or sort the live set. Every thread knows its own slot. Every thread runs exactly once. The shader is unconditionally parallel with zero inter-thread communication.

The problem this solves is the particle system bottleneck that plagues CPU-side tools. Phoenix, the demoscene-adjacent particle engine this document compares against, simulates at a fixed 25Hz on the CPU and uploads results to the GPU each frame. That works well for hundreds of particles but becomes painful at tens of thousands. Tixl puts the simulation entirely on the GPU and drives it from a `Speed` parameter that acts as a continuous time multiplier. You want double-speed particles? Increase `Speed`. You want physics consistent across frame rates? The `pow(1 - Drag, Speed)` formula handles that. The entire physics model fits in a constant buffer that updates once per frame.

## The Struct Layout: Two Buffers, One Invariant

Before tracing the shader phases, you need a firm grip on the two buffer types and how they relate. Think of the `Particle` buffer as the simulation's private memory — the working set the physics operates on — and the `Point` buffer as the renderer's read-only snapshot, published at the end of each frame. The two structures are defined in `Operators/Lib/Assets/shaders/shared/point.hlsl`:

```hlsl
// Operators/Lib/Assets/shaders/shared/point.hlsl:19-37
struct Point
{
    float3 Position;
    float FX1;
    float4 Rotation;
    float4 Color;
    float3 Scale;
    float FX2;
};

struct Particle
{
    float3 Position;
    float Radius;
    float4 Rotation;
    float4 Color;
    float3 Velocity;
    float BirthTime;
};
```

The structures are the same size and stride — 16 floats each — but they pack different semantics into those slots. Where `Point` has `Scale` and `FX1`/`FX2` for renderer-facing data, `Particle` has `Velocity` and `BirthTime` for physics. The `Radius` field in `Particle` occupies the same byte offset as `FX1` in `Point`. This alignment is intentional: it makes the buffer swap at the end of the frame a simple field-by-field copy rather than a layout transformation.

> **Key Insight:** The dual-buffer design separates concerns cleanly. The simulation writes to `Particles` continuously. The renderer reads from `ResultPoints` continuously. The copy at the end of each dispatch is the only synchronization point between them. This means the renderer never sees a partially-updated particle state.

## The Shader Signature

The compute shader receives its configuration through two constant buffers — one float, one int — and operates on three buffer resources. Here is the complete declaration as it appears in the shader:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:1-31
#include "shared/point.hlsl"
#include "shared/quat-functions.hlsl"

cbuffer Params : register(b0)
{
    float Speed;
    float Drag;
    float InitialVelocity;
    float Time;
    float OrientTowardsVelocity;
    float RadiusFromW;
    float LifeTime;
}

cbuffer IntParams : register(b1)
{
    int TriggerEmit;
    int TriggerReset;
    int CollectCycleIndex;
    int SetFx1To;
    int SetFx2To;
    int EmitMode;
    int IsAutoCount;
    int EmitVelocityFactor;
}

StructuredBuffer<Point> EmitPoints : t0;
RWStructuredBuffer<Particle> Particles : u0;
RWStructuredBuffer<Point> ResultPoints : u1;
```

The thread group is `[numthreads(64, 1, 1)]`. Every dispatch covers exactly `maxParticleCount / 64` groups. Each thread ID `gi` maps one-to-one to a slot in the particle buffer. There are no atomics, no inter-thread barriers, no shared memory. The shader is embarrassingly parallel in the exact technical sense of that phrase.

## Phase 1: Reset

The reset path is the fastest and simplest. Three field writes and the thread is done for this frame. The C# side sends `TriggerReset = 1` when the user presses the reset button or when `IsReset` propagates through the force chain.

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:49-54
if (TriggerReset > 0.5)
{
    Particles[gi].BirthTime = NAN;
    Particles[gi].Position = NAN;
    ResultPoints[gi].Scale = NAN;
}
```

Three fields, three choices. Setting `Position` to NAN ensures any force shader that accidentally runs on this slot produces NAN velocities — harmless because integration also propagates NAN outward. Setting `Scale` to NAN in `ResultPoints` is the rendering kill switch: vertex shaders that read NAN positions produce degenerate triangles that the GPU discards before rasterization. Setting `BirthTime` to NAN triggers the early-return guard in Phase 3 for subsequent frames.

Notice what the reset does not do: it does not zero out `Velocity`, `Rotation`, or `Color`. Those fields are irrelevant while `BirthTime` is NAN because the thread exits at Phase 3 before reaching any code that would read them.

## Phase 2: Emission — The Circular Buffer Mechanism

This is the most conceptually dense part of the shader. Tixl does not maintain a write pointer or a free list. Instead, it uses a rotating offset — `CollectCycleIndex` — to select which slots in the fixed buffer receive new particles each frame. Picture a clock hand sweeping around the buffer. Each frame the hand advances by the number of new emit points. Slots that fall within the current sweep window get overwritten with fresh particle data.

Two emit modes exist, selectable via the `EmitMode` integer. Sequential mode distributes new particles into consecutive slots. ForLines mode distributes them into evenly-spaced blocks, which suits line-based particle effects where you want each segment of a source curve to maintain its own particle history.

### Sequential Mode

In sequential mode, each thread computes an `addIndex` that determines which emit point (if any) it should spawn from:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:58-61
if (EmitMode == 0)
{
    addIndex = (gi + CollectCycleIndex + maxParticleCount) % maxParticleCount;
}
```

Here `gi` is the thread ID (0 to `maxParticleCount - 1`), and `CollectCycleIndex` is a monotonically incrementing integer driven by the C# side — it advances each frame by the number of new points emitted. The `+ maxParticleCount` before the modulo prevents negative results from integer wrapping at the buffer boundary.

The check that gates emission follows immediately after the mode calculation:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:71
if (TriggerEmit && addIndex >= 0 && addIndex < (int)newPointCount)
```

Only threads whose `addIndex` falls within `[0, newPointCount)` actually emit. Since `newPointCount` is typically much smaller than `maxParticleCount`, only a small fraction of threads write new particles each frame. The rest skip to Phase 3.

### ForLines Mode

ForLines mode is more involved. The goal is to distribute particles evenly so that each source point on the emitter curve "owns" a contiguous block of particle slots. When that source point emits a new particle, it overwrites only the head of its own block. The geometry of the block — one slot at the boundary, the rest persisting from previous frames — produces a trail behind each curve point.

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:63-69
int t = (gi + CollectCycleIndex / newPointCount) % maxParticleCount;
int blockSize = maxParticleCount / newPointCount;
int particleBlock = t / blockSize;
int t2 = t - (particleBlock * blockSize);
addIndex = t2 > 0 ? -1 : particleBlock;
```

The integer division `CollectCycleIndex / newPointCount` advances the block rotation more slowly than in sequential mode — once per full sweep of all blocks rather than once per individual slot. `particleBlock` identifies which source point owns this slot. `t2` is the position within that block: if `t2 > 0`, this slot is in the interior of the block and does not emit this frame (`addIndex = -1`). Only the block head (`t2 == 0`) emits, and its `addIndex` becomes the owning source point's index.

ForLines mode also kills the previous block-tail particle to maintain visual continuity. When a block head emits, the shader explicitly invalidates the slot just before it in the buffer:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:73-77
if (EmitMode != 0)
{
    Particles[(gi - 1) % maxParticleCount].BirthTime = NAN;
    Particles[(gi - 1) % maxParticleCount].Radius = NAN;
}
```

This prevents a gap from appearing at the oldest end of each trail when the block rotates.

### Emission Data Copy

When a thread has determined it should emit — `addIndex` is valid — it copies the emitter point's data into its slot and computes the initial velocity:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:79-96
Point emitPoint = EmitPoints[addIndex];

Particles[gi].Position = emitPoint.Position;
Particles[gi].Rotation = emitPoint.Rotation;
Particles[gi].Radius = emitPoint.Scale.x * RadiusFromW;
Particles[gi].BirthTime = Time;

float emitVelocity = InitialVelocity * (EmitVelocityFactor == 0 ? 1
    : (EmitVelocityFactor == 1 ? emitPoint.FX1 : emitPoint.FX2));

Particles[gi].Velocity = qRotateVec3(float3(0, 0, 1),
    normalize(Particles[gi].Rotation)) * emitVelocity;

// These will not change over lifetime...
Particles[gi].Color = emitPoint.Color;
ResultPoints[gi].Scale = emitPoint.Scale;
ResultPoints[gi].FX1 = emitPoint.FX1;
ResultPoints[gi].FX2 = emitPoint.FX2;
ResultPoints[gi].Color = emitPoint.Color;
```

Several details here are worth examining. The `Radius` field receives the emit point's `Scale.x` multiplied by the `RadiusFromW` parameter — this lets you control whether the particle's radius comes from the emitter point's size or from a global scale factor. Setting `BirthTime = Time` starts the lifetime clock from the current absolute time; age is later computed as `Time - BirthTime` rather than being counted down.

The initial velocity direction is always along the emitter's local Z axis. The `qRotateVec3(float3(0, 0, 1), normalize(Particles[gi].Rotation))` call takes that local-space forward vector and rotates it into world space using the emitter point's quaternion. The `EmitVelocityFactor` parameter lets `FX1` or `FX2` on the emit point scale the velocity magnitude — useful when you want spray angle or speed to vary per-point along a source curve.

Finally, notice the comment: `// These will not change over lifetime`. The `Scale`, `FX1`, `FX2`, and `Color` values written to `ResultPoints` at emission time persist across frames unless overridden by the FX attribute mapping in Phase 7. This is a deliberate performance choice — there is no need to copy them every frame if they do not change.

## Phase 3: The Dead-Particle Guard

After the emission block, every thread hits the same early-exit check:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:99-100
if (Particles[gi].BirthTime == NAN)
    return;
```

Dead particles exit here. All subsequent phases — integration, orientation, the dual-buffer copy, FX mapping, and age-based death — only execute for live particles. This means the GPU wave execution does not waste time computing force accumulation or quaternion slerps for empty slots. The cost of dead particles is literally two memory reads (BirthTime and the NAN comparison) and a branch that retires the thread.

> **Key Insight:** NAN as a sentinel is an elegant choice because IEEE 754 guarantees that `x == NAN` is always false for any real value of `x`, and `NAN == NAN` is always false too. Tixl exploits this by using `sqrt(-1)` to generate NAN at the HLSL level (`const static float NAN = sqrt(-1)` in `quat-functions.hlsl`). The comparison `BirthTime == NAN` only evaluates true when `BirthTime` is NAN — which is precisely the sentinel state. This works correctly even on hardware with aggressive NaN propagation modes.

## Phase 4: Integration — Drag and Position

The integration model is Euler integration: velocity changes first by drag, then position changes by velocity. Two lines handle the physics step, but the formula for drag deserves close attention:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:104-113
// drag step (frame-rate independent)
// velocity *= (1 - Drag);
velocity *= pow(1.0f - Drag, Speed); // improved version that better aligns
Particles[gi].Velocity = velocity;

// position step
float3 pos = Particles[gi].Position;
pos += velocity * Speed * 0.01;
Particles[gi].Position = pos;
```

The commented-out naive version `velocity *= (1 - Drag)` is multiplicative damping applied once per frame. That makes physics frame-rate-dependent: at 30fps each particle loses `(1 - Drag)^30` of its velocity per second; at 60fps it loses `(1 - Drag)^60`. The second version uses `Speed` as an exponent. When `Speed` is 1.0, the damping is `(1 - Drag)^1` per frame — identical to the naive version. When `Speed` doubles to 2.0, the damping becomes `(1 - Drag)^2` — the squared version of a single-frame decay, which is exactly what you would get from two consecutive single-frame applications. Multiplicative damping compounds correctly under this formulation.

The `* 0.01` scale factor on the position update is a unit conversion. Velocity in tixl's internal units maps to world-space positions where 1 unit represents a typical scene scale. Without this factor, even small velocities would produce enormous position displacements.

`Speed` appears in two places in this section: as the drag exponent and as the position displacement multiplier. This makes `Speed` behave like a global time dilation for the simulation — faster `Speed` means both more displacement and more drag compounding per frame, which preserves the qualitative character of the motion even as tempo changes.

## Phase 5: Orientation Toward Velocity

Particles that have initial rotation set by their emitter often need to reorient as they move. A smoke particle emitted straight up should gradually tilt to face the direction it is actually traveling. The orientation block handles this with a spherical linear interpolation — slerp — between the particle's current rotation and a quaternion that looks along the velocity vector:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:115-120
float speed = length(velocity);
if (speed > 0.0001)
{
    float f = saturate(speed * OrientTowardsVelocity);
    Particles[gi].Rotation = qSlerp(Particles[gi].Rotation,
        qLookAt(velocity / speed, float3(0, 1, 0)), f);
}
```

The speed threshold `> 0.0001` prevents division by zero in the `velocity / speed` normalization and avoids calling `qLookAt` with a degenerate zero-length direction. When velocity is negligible, no orientation occurs.

The `f` factor ties orientation aggressiveness to current speed: `saturate(speed * OrientTowardsVelocity)`. At low speed, `f` approaches zero and the particle barely rotates. At high speed, `f` approaches 1.0 and the particle snaps toward its direction of travel. This creates the intuitive behavior where fast-moving particles face their direction of travel strongly, while nearly-stationary particles maintain their emitted orientation. Setting `OrientTowardsVelocity` to 0 disables the effect entirely. Setting it very high causes near-instant orientation alignment even at modest speeds.

The `qLookAt` function in `Operators/Lib/Assets/shaders/shared/quat-functions.hlsl` constructs the target quaternion from a rotation matrix built from the forward vector (velocity direction) and world up (`float3(0, 1, 0)`). `qSlerp` then interpolates smoothly along the great circle arc on the quaternion hypersphere between current and target orientations — the quaternion equivalent of lerping between two angles, but without the gimbal lock that plagues Euler-based rotation interpolation.

## Phase 6: The Dual-Buffer Copy

With physics and orientation complete, the shader publishes the updated state to `ResultPoints`. This is the moment when the simulation's private working set becomes the renderer's public snapshot:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:122-127
// Copy result
ResultPoints[gi].Position = Particles[gi].Position;
ResultPoints[gi].Rotation = Particles[gi].Rotation;
ResultPoints[gi].Color = Particles[gi].Color;
```

Notice what is not copied: `Scale`, `FX1`, and `FX2`. Those were written to `ResultPoints` at emission time and persist there across frames. The copy only updates the three fields that change each frame: position (from integration), rotation (from orientation), and color. The color copy is noted in a comment as a potential optimization target — if color does not change after emission, this write is redundant. For now it copies unconditionally.

The commented-out line above the copy reveals a design consideration that was explored and abandoned:

```hlsl
// Attempt with lerping to smooth position updates
// ResultPoints[gi].position = lerp(Particles[gi].p.position, ResultPoints[gi].position, 0);
```

Position lerping between the previous and current frame would give sub-frame motion smoothing without a fixed timestep accumulator. The lerp factor of 0 makes this a no-op, and the entire idea was discarded. Tixl accepts the frame-step granularity of its integration rather than adding complexity to smooth it.

## Phase 7: FX Attribute Mapping

The `FX1` and `FX2` fields in the `Point` struct serve as general-purpose scalar attributes. Rendering nodes like `DrawBillboards` or `ColorOverW` read these to modulate size, color, or alpha over a particle's lifetime. The simulation can override the emission-time values with derived quantities:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:133-156
float lifeTime = LifeTime < 0.0
    ? (IsAutoCount ? 100000 : (float)(maxParticleCount / (newPointCount * 60.0)))
    : LifeTime;

float normalizedAge = (IsAutoCount && LifeTime < 0) ? 1
    : (Time - Particles[gi].BirthTime) / lifeTime;

if (SetFx1To == W_PARTICLE_AGE)
    ResultPoints[gi].FX1 = normalizedAge;
else if (SetFx1To == W_PARTICLE_SPEED)
    ResultPoints[gi].FX1 = speed * 100;

if (SetFx2To == W_PARTICLE_AGE)
    ResultPoints[gi].FX2 = normalizedAge;
else if (SetFx2To == W_PARTICLE_SPEED)
    ResultPoints[gi].FX2 = speed * 100;
```

Three modes per channel, selected by the `SetFx1To`/`SetFx2To` integer parameters:

- **KeepOriginal (0):** The value set at emission time persists. Use this when FX1 encodes per-emitter metadata — a cluster ID, a curve parameter, or a random seed — that should remain constant over the particle's life.
- **ParticleAge (1):** `normalizedAge` runs from 0.0 at birth to 1.0 at death. This is the primary driver for effects like fade-in, grow-then-shrink, or color-over-lifetime gradients in a downstream `ColorOverW` node.
- **ParticleSpeed (2):** `speed * 100` maps the current velocity magnitude to a 0–100 range (the factor exists because internal velocity units are small). Useful for making fast particles glow brighter, grow larger, or shift color.

The lifetime calculation itself has two special paths. When `LifeTime >= 0`, particles live for exactly that many seconds. When `LifeTime < 0` and `IsAutoCount` is false, the system derives lifetime from the buffer geometry: `maxParticleCount / (newPointCount * 60.0)`. This formula assumes 60fps emission and calculates how long a particle must live before the circular buffer wraps back around to overwrite its slot. It makes the buffer feel "full" at steady state without particles overlapping themselves.

When `IsAutoCount` is true and `LifeTime < 0`, particles are treated as immortal (`normalizedAge = 1` always). This mode is for when an external system manages particle count rather than the internal lifetime mechanism.

## Phase 8: Death by Age

The last phase of the shader handles particles that have exceeded their lifetime:

```hlsl
// Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl:158-161
if (tooOld)
{
    ResultPoints[gi].Scale = NAN;
}
```

When `normalizedAge > 1`, the particle's `Scale` in `ResultPoints` becomes NAN. The rendering vertex shader reads this value to determine billboard size. NAN positions produced by NAN scale cause the GPU rasterizer to discard the triangle entirely — the particle becomes invisible without any conditional rendering on the CPU side.

This is the counterpart to the NAN guard in Phase 3. The `Scale = NAN` signal persists in `ResultPoints` until the slot is either overwritten by a new emission or reset. Meanwhile, `BirthTime` in `Particles` is left alone — the slot remains "alive" from the simulation's perspective, continuing to run through integration each frame, until the circular emission mechanism loops around and overwrites it with a fresh particle. This means aged particles continue consuming compute resources until overwritten, but the cost is low: their velocity is already near zero from drag, their integration changes nothing significant, and the copy goes to a renderer that ignores them.

> **Key Insight:** The asymmetry between how particles die visually (NAN scale in ResultPoints) and how they die in simulation (slot overwrite by emission) is a deliberate tradeoff. Immediately setting BirthTime to NAN would save a tiny amount of work per dead particle but would complicate the emission logic — the slot would no longer be available for overwrite by the circular mechanism, because a NAN-birthtime slot would exit at Phase 3 without checking for emission. By keeping dead-but-not-overwritten slots in the simulation, the circular mechanism can naturally reclaim them.

## The C# Operator: Wiring the Graph

The `ParticleSystem.hlsl` shader does not dispatch itself. The dispatch is owned by the C# operator node, which also defines all the user-facing parameters. The node class illustrates tixl's slot-based API pattern clearly:

```csharp
// Operators/Lib/Symbols/particle/ParticleSystem.cs:3-75
[Guid("e44ae9b6-cd56-4224-8a5d-118eda4cd3f4")]
internal sealed class ParticleSystem : Instance<ParticleSystem>
{
    [Output(Guid = "51b9c6bd-b7cc-48a4-979b-3febcac914c2")]
    public readonly Slot<BufferWithViews> OutBuffer = new();

    [Input(Guid = "ba08e719-a1d1-4ac6-9c8c-076478a65a81")]
    public readonly InputSlot<BufferWithViews> EmitPoints = new();

    [Input(Guid = "7a320c47-14ed-4637-928b-25f87bd32c26")]
    public readonly InputSlot<bool> Emit = new();

    [Input(Guid = "c6bdbb07-6996-4e5b-a058-37c9cbeca6fe")]
    public readonly InputSlot<bool> Reset = new();

    [Input(Guid = "cab3072c-694e-4278-9b1e-e30beb95e5c8")]
    public readonly InputSlot<bool> Update = new();

    [Input(Guid = "1eb32e4c-6785-4649-b0bf-7c70cddee619")]
    public readonly InputSlot<int> MaxParticleCount = new();

    [Input(Guid = "38392c86-4a1b-4b6f-ac32-26920a73e1e2")]
    public readonly InputSlot<float> EmitVelocity = new();

    [Input(Guid = "54b8bfc1-98b1-4cec-b008-8615c20ebb43", MappedType = typeof(StrengthFactors))]
    public readonly InputSlot<int> EmitVelocityFactor = new();

    [Input(Guid = "b2c8f7cf-fdf5-4819-98ec-2c70ee9e8bc6")]
    public readonly InputSlot<float> RadiusFactor = new();

    [Input(Guid = "21c666bb-a28f-498c-a834-a2ba4aca78a7", MappedType = typeof(EmitModes))]
    public readonly InputSlot<int> EmitMode = new();

    [Input(Guid = "4ca2f43a-ed90-4388-ae6f-2687e85db5a6")]
    public readonly InputSlot<float> LifeTime = new();

    [Input(Guid = "9642f5c6-5ad2-4d35-a5ed-a3fde10817ae")]
    public readonly InputSlot<float> Speed = new();

    [Input(Guid = "4b0ccec5-b72e-4834-80d4-77225f30d2a9")]
    public readonly InputSlot<float> OrientTowardsVelocity = new();

    [Input(Guid = "5a61994e-42c7-47e7-b0a5-5beb48f4a34b")]
    public readonly InputSlot<float> Drag = new();

    [Input(Guid = "a7350ba8-08be-4afc-92f1-d223ee9bcbeb", MappedType = typeof(SetWModes))]
    public readonly InputSlot<int> SetF1To = new();

    [Input(Guid = "4c555ac3-3d62-47a7-9d1a-49e4d5808635", MappedType = typeof(SetWModes))]
    public readonly InputSlot<int> SetF2To = new();

    [Input(Guid = "c41d9633-1397-4602-a5f8-7808c3d63108")]
    public readonly MultiInputSlot<T3.Core.DataTypes.ParticleSystem> ParticleForces = new();

    private enum SetWModes { KeepOriginal, ParticleAge, ParticleSpeed }
    private enum EmitModes { Sequential, ForLines }
    private enum StrengthFactors { None = 0, F1 = 1, F2 = 2 }
}
```

The `MappedType` attribute on integer inputs is tixl's mechanism for showing enum dropdowns in the graph editor UI while keeping the underlying value as an integer passed to the shader. The `MultiInputSlot<ParticleSystem>` for `ParticleForces` allows multiple force nodes to connect to a single particle system — the graph wires up a chain of force dispatches that each run before the main ParticleSystem dispatch.

## SpeedFactor: Propagating Time Into Force Shaders

You might notice that `DirectionalForce.hlsl` accepts a `SpeedFactor` parameter that is not present in its C# node's input list. This is because `SpeedFactor` does not come from the graph connection — it travels through a side channel called `EvaluationContext`.

The mechanism works in three stages. First, `_SetParticleSystemComponents.cs` receives a `SpeedFactor` input and stores it onto a `ParticleSystem` data object in the context:

```csharp
// Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs:17-18
_particleSystem.ParticleBuffer = PointsSimBuffer.GetValue(context);
_particleSystem.SpeedFactor = SpeedFactor.GetValue(context);
// ...
context.ParticleSystem = _particleSystem;
```

Second, each force node uses `GetParticleComponents.cs` to extract the SpeedFactor from the context:

```csharp
// Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs:40-42
ParticlesUav.Value = context.ParticleSystem.ParticleBuffer.Uav;
SpeedFactor.Value = context.ParticleSystem.SpeedFactor;
IsReset.Value = context.ParticleSystem.IsReset;
```

Third, the force shader multiplies its effect by `SpeedFactor`. Here is the pattern from `DirectionalForce.hlsl`:

```hlsl
// Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl:25-26
float3 offset = Direction * Amount * (1 + hash11(i.x) * RandomAmount) * SpeedFactor;
Particles[i.x].Velocity += offset;
```

And from `TurbulanceForce.hlsl`:

```hlsl
// Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl:69-70
float amount = Amount / 100 * fieldAmount * (SpeedFactor);
Particles[i.x].Velocity = velocity + curlNoise(noiseLookup) * amount;
```

The invariant is: every force that modifies velocity multiplies its contribution by `SpeedFactor`. When `SpeedFactor` matches the main shader's `Speed`, forces scale consistently with the integration step. A user who dials `Speed` to 2.0 gets twice the displacement from integration and twice the force impulse from every force node — the system maintains its qualitative behavior at higher tempo.

## Execution Order Within a Frame

To understand the system fully, you need to trace a complete frame through the evaluation graph. Tixl's lazy pull-based evaluation means execution follows the output request backward through the graph. A rendering node requesting the `ResultPoints` buffer triggers this sequence:

The `ParticleSystem` operator evaluates, which first requests its `ParticleForces` multi-input. Each force node evaluates in connection order. Force evaluation triggers `GetParticleComponents`, which reads `context.ParticleSystem` injected by `_SetParticleSystemComponents` earlier in the frame. Each force dispatches a compute shader that modifies `Particles[u0]` in place. After all forces complete, the main `ParticleSystem.hlsl` dispatch runs — emission, death check, integration, orientation, copy. The `ResultPoints` UAV is now populated with the frame's final state. Any downstream rendering node reads from this buffer.

The force execution order is intentional: forces accumulate velocity changes into `Particles.Velocity` before the main dispatch reads that velocity and integrates it into position. This means a directional force applied this frame affects the particle's position in the same frame, not the next. The simulation is single-frame-latency from force to motion.

## Comparison with Phoenix Simulation

Comparing tixl's approach against Phoenix, the demoscene CPU particle engine, illuminates the design choices each makes:

| Aspect | tixl | Phoenix |
|--------|------|---------|
| Update frequency | Every frame (variable) | Fixed 25fps timestep |
| Simulation location | GPU compute shader | CPU loop |
| Integration formula | `pos += vel * Speed * 0.01` | `pos += vel` per tick |
| Drag model | `pow(1 - Drag, Speed)` | `vel *= (1 - drag)` per tick |
| Orientation | `qSlerp` toward velocity | Direct set from velocity |
| Death signal | NAN in `ResultPoints.Scale` | LiveCount decrement |
| Emission strategy | Circular buffer overwrite | Append to array with LiveCount |
| Force model | Separate compute dispatches | Affector volume queries per particle |
| Frame-rate independence | Through `Speed` exponent | Through fixed timestep accumulator |

Phoenix achieves frame-rate independence by running physics at a constant 25Hz regardless of render rate, accepting the interpolation cost between physics steps. Tixl achieves it through the `pow(1 - Drag, Speed)` exponent formulation, which keeps physics continuous with the render rate but compensates multiplicatively.

Phoenix's `LiveCount` approach means only live particles execute physics — dead slots are never touched. Tixl's NAN-guard approach means dead slots run through the guard check each frame before exiting, a small but real cost for very sparse buffers. The tradeoff is simplicity: tixl never needs to maintain a free list or compact the live set, and its buffer structure stays flat and GPU-friendly.

Phoenix handles thousands of particles comfortably on CPU. Tixl handles hundreds of thousands comfortably on GPU. The target scale is different enough that direct performance comparison is not meaningful.

## Key Files Reference

| File | Purpose |
|------|---------|
| `Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl` | Main compute shader: all simulation phases |
| `Operators/Lib/Symbols/particle/ParticleSystem.cs` | C# operator node: inputs, dispatch, buffer management |
| `Operators/Lib/Assets/shaders/shared/point.hlsl` | `Point` and `Particle` struct definitions |
| `Operators/Lib/Assets/shaders/shared/quat-functions.hlsl` | `qSlerp`, `qLookAt`, `qRotateVec3`, NAN definition |
| `Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs` | Injects particle buffer and SpeedFactor into EvaluationContext |
| `Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs` | Extracts buffer UAV and SpeedFactor from EvaluationContext |
| `Operators/Lib/Symbols/point/_internal/_ExecuteParticleUpdate.cs` | Sequences force command execution within the graph |
| `Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl` | Example force shader: velocity += Direction * Amount * SpeedFactor |
| `Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl` | Example force shader: curl noise velocity perturbation |
| `Core/DataTypes/ParticleSystem.cs` | Runtime data container: ParticleBuffer, SpeedFactor, IsReset |

## References

- `Operators/Lib/Assets/shaders/particles/ParticleSystem.hlsl` — complete shader source
- `Operators/Lib/Assets/shaders/shared/point.hlsl` — struct layout definitions
- `Operators/Lib/Assets/shaders/shared/quat-functions.hlsl` — quaternion math library, NAN sentinel definition
- `Operators/Lib/Symbols/particle/ParticleSystem.cs` — operator node declaration
- `Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs` — context injection pattern
- `Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs` — context extraction pattern
- `Core/DataTypes/ParticleSystem.cs` — `ParticleSystem` data type definition
- `Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl` — SpeedFactor usage in force shaders
- `Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl` — field-modulated force with SpeedFactor
