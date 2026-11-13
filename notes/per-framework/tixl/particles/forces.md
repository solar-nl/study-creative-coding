Forces in tixl are independent compute shader dispatches that chain together through the node graph. Each force reads and writes the same particle buffer, modifying velocities — or sometimes positions directly — in place. This additive, order-dependent design means the force chain is essentially a GPU pipeline: each stage transforms the particle state for the next. If gravity runs before drag, the terminal velocity behaves differently than if drag runs before gravity. The order you connect nodes in the graph determines the order the GPU processes them, making force sequencing a first-class part of the authoring experience.

Think of the force chain like a series of signal processors in an audio rack. Each unit receives the signal from the unit before it, applies its own transformation, and passes the result downstream. A compressor after a distortion sounds different from distortion after a compressor — the order matters even when the individual units are identical. In tixl, the "signal" is the particle buffer holding millions of positions and velocities on the GPU, and each "processor" is a compute shader that writes modified values back to the same buffer before the next shader reads them. This is different from systems where forces are accumulated independently and applied in a single integration step. Here, the first force in the chain sees original particle velocities; the second force sees velocities already modified by the first.

This design also means forces have no intrinsic coupling. A turbulence force knows nothing about the gravity force that ran before it. Each shader receives only the particle buffer and its own parameters. Composition emerges from sequential mutation rather than from any shared context or accumulation register. That simplicity pays off in extensibility: adding a new force type requires only a new HLSL shader and a thin C# wrapper — no changes to the core particle system.

## The Force System Architecture

The connection between the particle system and its forces runs through a single input slot named `Forces` on the `_SetParticleSystemComponents` operator. That slot is a `MultiInputSlot<ParticleSystem>`, meaning any number of force nodes can connect to it. When the particle system evaluates, it injects a `ParticleSystem` context object and then calls `GetValue` on each connected force in connection order.

The implementation in `Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs` shows the sequencing directly:

```csharp
var effects = Forces.CollectedInputs;
var keep = context.ParticleSystem;
if (effects != null)
{
    context.ParticleSystem = _particleSystem;

    for (int i = 0; i < effects.Count; i++)
    {
        effects[i].GetValue(context);  // Triggers force evaluation/dispatch
    }
}

context.ParticleSystem = keep;  // Restore previous context
```

The `context.ParticleSystem = keep` pattern at the end is significant. It means particle systems can nest: a force applied to a child system does not contaminate the parent's context. Each system owns its context scope.

When a force node evaluates, it uses `GetParticleComponents` to extract what it needs from the context. That operator — in `Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs` — pulls the UAV (unordered access view), the particle count, the SpeedFactor, and the IsReset flag from `context.ParticleSystem`. The UAV is the writable handle to the GPU buffer. Every force shader receives this UAV as its `u0` register, reads particle data, modifies it, and writes it back. The same buffer object persists across all dispatches in a single frame.

> **Key Insight:** The particle buffer is never copied between forces. Every force operates on the same GPU allocation. Sequential dispatch on a shared buffer is what makes the chain semantics work — the GPU serializes these operations by default within a single command list, so each dispatch truly sees the writes from the previous one.

The `SpeedFactor` parameter deserves special attention. It appears in nearly every force shader, and its purpose is frame-rate independence. Rather than hardcoding physics constants that assume a particular frame rate, tixl passes the delta time (scaled appropriately) through this parameter. A force that would move a particle by 1 unit per second at 60fps needs to move it by 1/60 units per frame. The `SpeedFactor` carries that scaling, computed once by the particle system and distributed to all forces automatically.

## Template-Based Shader Generation

Five of the sixteen forces use a runtime shader composition system rather than static HLSL files. This is one of tixl's most architecturally interesting patterns, and it unlocks something that simple forces cannot do: the ability to connect arbitrary SDF geometry or vector fields to a force, making the force respond to that geometry at runtime.

The mechanism is template injection. The force shader is not a complete HLSL file — it is a template with comment-delimited placeholders that get replaced at runtime with generated code. When you connect a ShaderGraph chain (a sphere SDF, a domain-repeated box, a custom vector field) to a force's field input, the `GenerateShaderGraphCode` operator traverses that graph, collects HLSL fragments from each node, and injects the assembled code into the force shader template.

The placeholders follow a consistent pattern across all template-based force shaders:

```hlsl
cbuffer Params : register(b1)
{
    /*{FLOAT_PARAMS}*/     // Injected: cbuffer declarations for graph node parameters
};

/*{GLOBALS}*/              // Injected: global variable declarations and function prototypes

/*{FIELD_FUNCTIONS}*/      // Injected: SDF and field function bodies

float4 GetField(float4 p)
{
    float4 f = 1;
    /*{FIELD_CALL}*/        // Injected: call to field evaluation entry point
    return f;
}

/*{RESOURCES(t0)}*/        // Injected: StructuredBuffer/texture register declarations
```

After injection, the force shader can call `GetField(float4(pos, 0))` at runtime and receive the result of whatever SDF or field graph the user connected — whether that is a simple sphere or a complex composition of twenty nodes. The entire field graph becomes a single inlined function call from the force's perspective.

> **Key Insight:** This is runtime shader metaprogramming. The HLSL code that actually runs on the GPU is assembled from modular pieces every time the graph topology changes. A structural change (connecting or disconnecting a node) triggers recompilation via D3DCompiler. A parameter change (adjusting the sphere's radius) only updates a constant buffer — no recompilation needed. The `StructureHash` system in `ShaderGraphNode.cs` distinguishes between these two cases to avoid unnecessary recompiles during animation.

The practical implication is that field-based forces are not limited to predefined geometry primitives. Any shape expressible in the ShaderGraph system — boxes, toruses, fractals, procedural terrain, distance-field text — can drive particle attraction, repulsion, turbulence strength, or jump magnitude. The force itself is a generic template; the geometry is a pluggable module.

## Force Catalogue

The sixteen forces decompose into seven categories by the kind of work they perform. Understanding these categories clarifies which tool to reach for when building a particle effect.

---

### Basic Physics

These three forces implement classical mechanics without any field sampling. They operate only on particle velocity using cbuffer parameters and per-particle random hashes.

**DirectionalForce** is the simplest force in the system and serves as the canonical gravity implementation. A constant direction vector multiplied by an amount and a random per-particle variation gets added to every particle's velocity each frame.

The shader in `Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl` is short enough to read in full:

```hlsl
cbuffer Params : register(b0)
{
    float3 Direction;
    float Amount;
    float RandomAmount;
    float SpeedFactor;
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

The `hash11(i.x)` call seeds a per-particle random value from the particle index. This produces deterministic variation — the same particle always gets the same random offset — while avoiding any pattern across the buffer. The `RandomAmount` parameter scales how much that variation affects the final force. At zero, every particle falls identically. At one, particles spread noticeably.

**VelocityForce** does not add a directional impulse. It modifies the magnitude of the velocity vector while preserving its direction. This makes it useful for speed ramping (acceleration) and speed clamping (terminal velocity enforcement) without disturbing the direction particles are already traveling.

The key logic from `Operators/Lib/Assets/shaders/particles/VelocityForce.hlsl`:

```hlsl
float3 velocity = Particles[i.x].Velocity;
float speed = length(velocity);

if (speed < 0.0001)
    return;  // Avoid normalizing a zero vector

float3 dir = normalize(velocity);

float rand = hash11u(i.x);
float randBias = ApplyGainAndBias(rand, VariationGainAndBias);
float3 variationFactor = (1 - (1 - randBias) * saturate(Variation));

float strength = Amount * variationFactor;
speed += Acelleration * 0.02 * strength;
speed = clamp(speed, MinSpeed, MaxSpeed);

Particles[i.x].Velocity = dir * speed;
```

The `VariationGainAndBias` parameter applies a curve remap to the random value before using it as a variation factor. Gain controls the contrast of the variation distribution; bias shifts the center. This gives fine control over whether variation is concentrated around the mean or spread toward extremes.

**AxisStepForce** is the most probabilistic of the three. Rather than affecting all particles, it first selects a random subset based on `SelectRatio` — only particles where `hash < SelectRatio` receive the impulse. For selected particles, it picks the dominant axis from a weighted random vector, randomizes the sign, and applies the impulse in that axis direction.

The axis selection from `Operators/Lib/Assets/shaders/particles/AxisStepForce.hlsl`:

```hlsl
float4 randForPos = hash41u(gi + (uint)Seed * 1103515245U);
float selected = randForPos.w < SelectRatio ? 1 : 0;

float3 axis = abs(randForPos.zyx * AxisDistribution);
float3 direction = axis.x > axis.y ? (axis.x > axis.z ? float3(1,0,0) : float3(0,0,1))
                                   : (axis.y > axis.z ? float3(0,1,0) : float3(0,0,1));
```

The `AxisDistribution` parameter biases the probability toward specific axes. Setting it to `(1, 0, 0)` makes all impulses travel along X; setting it to `(1, 1, 0)` distributes between X and Y with equal probability. When `AxisSpace` is set to Rotation mode, the selected axis gets transformed by the particle's own rotation quaternion, so the impulse fires in the particle's local coordinate frame rather than world space.

---

### Field-Based Forces

These five forces use the template injection system to sample SDF or vector field data at each particle's position. They represent tixl's most powerful force category because the "geometry" they respond to is fully composable at runtime.

**FieldDistanceForce** attracts particles toward an SDF surface when outside it and repels them when inside. The challenge is computing the direction toward the surface — the field provides only a scalar distance value at a point, not a gradient direction. The shader solves this using tetrahedral normal estimation, a technique that computes a numerical gradient using four strategically placed sample points.

The gradient estimation in `Operators/Lib/Assets/shaders/particles/FieldDistanceForce.hlsl`:

```hlsl
float3 GetFieldNormal(float3 p)
{
    return normalize(
        GetDistance(p + float3( d, -d, -d)) * float3( 1, -1, -1) +
        GetDistance(p + float3(-d,  d, -d)) * float3(-1,  1, -1) +
        GetDistance(p + float3(-d, -d,  d)) * float3(-1, -1,  1) +
        GetDistance(p + float3( d,  d,  d)) * float3( 1,  1,  1));
}
```

Where `d` is the `NormalSamplingDistance` parameter. This samples the field at four points arranged in a tetrahedron around the query position and computes their weighted sum. The result approximates the SDF gradient direction — which is equivalent to the surface normal — using only four field evaluations instead of the six required for a standard central-difference scheme.

The force application itself:

```hlsl
if (d > 0)  // Outside the field surface
{
    float decay = pow(d + 1, -DecayWithDistance);
    p.Velocity -= n * Attraction * Amount * decay;
}
else         // Inside the field surface
{
    p.Velocity += n * Repulsion * Amount;
}
```

The `DecayWithDistance` parameter controls how quickly attraction weakens with distance. A value of 1 gives inverse-linear falloff; a value of 2 gives inverse-square (like gravity). Particles far from the surface pull weakly; particles near the surface pull strongly. Inside the surface, repulsion applies uniformly without decay — pushing particles back out at full strength.

**FieldVolumeForce** adds collision detection on top of attraction and repulsion. Rather than treating the SDF as a pure attractor, it watches for particles that are about to cross the surface and reflects their velocity. The detection examines both the current position's distance and the predicted next-frame position's distance:

```hlsl
float3 posNext = pos + velocity * SpeedFactor * 0.01 * 2;
float distanceNext = GetDistance(posNext);

// Reflect if distance sign changes (surface crossing detected)
if (sign(distance * distanceNext) < 0 && distance * InvertVolumeFactor > 0)
{
    float3 v = lerp(velocity,
                    reflect(velocity, surfaceN + (RandomizeReflection * (rand.xyz - 0.5))),
                    EnableBounce);

    velocity = lerp(velocity, v * Bounciness * ..., Amount);
}
```

When the product of current and next-frame distances is negative, the particle is crossing the surface this frame. The shader reflects the velocity vector off the surface normal, optionally randomizing the normal to produce imperfect bounces. The `InvertVolume` parameter flips the inside/outside semantics, turning a volume that normally contains particles into one that bounces them away from the outside.

The `ApplyColorOnCollision` flag reveals an interesting design choice: the shader samples the field's 4th channel on collision and writes that color to the particle. This means you can encode a texture or color gradient into a field and particles acquire that color when they hit the surface — a compact way to produce surface-tinted collision effects without a separate color system.

> **Key Insight:** `FieldVolumeForce` uses predictive collision detection rather than post-hoc correction. It computes where the particle will be next frame and checks if that position crosses the surface. This avoids the tunneling problem where fast particles pass through thin surfaces without triggering a response.

**TurbulenceForce** samples curl noise at each particle's world position and adds the result to velocity. Curl noise is special: it is divergence-free by construction, meaning it preserves the local density of particles. Regular gradient noise would push particles together in some regions and pull them apart in others; curl noise keeps the density uniform while still producing swirling, organic motion.

From `Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl`:

```hlsl
float3 variationOffset = hash41u(i.x).xyz * Variation;
float3 pos = Particles[i.x].Position * 0.9; // avoid simplex noise glitch at -1,0,0
float3 noiseLookup = (pos + variationOffset + Phase * float3(1, -1, 0)) * Frequency;

float4 field = GetField(float4(pos, 0));
float fieldAmount = (field.r + field.g + field.b) / 3;

float amount = Amount / 100 * fieldAmount * SpeedFactor;
Particles[i.x].Velocity = velocity + curlNoise(noiseLookup) * amount;
```

The optional field connection modulates turbulence strength spatially: particles inside a sphere SDF could experience full turbulence while particles outside experience none. The comment about the simplex noise glitch at `-1,0,0` is a known numerical artifact in the implementation — scaling positions by 0.9 keeps lookups away from that degenerate point.

**RandomJumpForce** uses the same curl noise as TurbulenceForce but applies it to position rather than velocity. This is a categorically different effect: velocity-based turbulence produces acceleration (force), while position-based displacement produces jitter (constraint violation). Particles subjected to this force appear to teleport slightly each frame, creating a nervous, flickering motion that would be impossible to produce with velocity alone.

From `Operators/Lib/Assets/shaders/particles/RandomJumpForceTemplate.hlsl`:

```hlsl
float3 noise3 = curlNoise(noiseLookup);
noise3 *= AmountDistribution;
noise3 = qRotateVec3(noise3, normalize(p.Rotation));

Particles[i.x].Position += noise3 * amount;
```

The `AmountDistribution` parameter scales each axis independently, enabling flat disk-like jitter or elongated needle-like jitter. The rotation transform aligns the jitter distribution with the particle's own orientation — particles oriented along a trajectory will jitter along that trajectory rather than in world space.

**VectorFieldForce** samples an injected 3D vector field at each particle position and adds the sampled vector to velocity. Where TurbulenceForce and RandomJumpForce compute their field procedurally via curl noise, VectorFieldForce treats the connected ShaderGraph as a true vector-valued field. The field's xyz channels provide the velocity direction, and the w channel acts as a magnitude multiplier.

The dispatch kernel in `Operators/Lib/Assets/shaders/particles/VectorFieldForce-sg.hlsl`:

```hlsl
float3 pos = Particles[gi].Position;
float4 f = GetField(float4(pos, 0));

float3 variationFactor = hash11u(i.x) * Variation + 1;
float3 velocity = f.xyz * Amount * f.w * variationFactor;

if (!isnan(velocity.x) && !isnan(velocity.y) && !isnan(velocity.z))
    Particles[gi].Velocity += velocity;
```

The NaN guard is important here. Field evaluations can produce NaN in edge cases (division by zero in SDF operations, evaluation at degenerate points), and a single NaN particle would remain corrupted for its entire lifetime without this check. Discarding the velocity update on NaN preserves particle stability at the cost of occasionally missing a frame of force application.

---

### Mesh and Geometry-Based Forces

These two forces read structured mesh data from GPU buffers rather than procedural fields. They represent the highest-complexity forces in the catalogue.

**FollowMeshSurfaceForce** constrains particles to travel along the surface of a mesh. Each particle finds the closest point on the mesh, projects toward it with configurable offset, and derives an orientation from the surface normal. The mesh arrives as two structured buffers: `StructuredBuffer<PbrVertex> Vertices` and `StructuredBuffer<int3> Indices`.

The proximity search is a brute-force iteration over all triangles:

```hlsl
void findClosestPointAndDistance(
    in uint faceCount,
    in float3 pos,
    out uint closestFaceIndex,
    out float3 closestSurfacePoint)
{
    closestFaceIndex = -1;
    float closestDistance = 99999;

    for (uint faceIndex = 0; faceIndex < faceCount; faceIndex++)
    {
        int3 f = Indices[faceIndex];
        float3 pointOnFace = closestPointOnTriangle(
            Vertices[f[0]].Position,
            Vertices[f[1]].Position,
            Vertices[f[2]].Position,
            pos);

        float distance2 = length(pointOnFace - pos);
        if (distance2 < closestDistance)
        {
            closestDistance = distance2;
            closestFaceIndex = faceIndex;
            closestSurfacePoint = pointOnFace;
        }
    }
}
```

For meshes with hundreds of faces, this runs each frame for each particle. The O(particles × triangles) complexity makes this force expensive on dense meshes. Its practical use case is low-polygon surfaces with tens to hundreds of triangles — stylized environments, abstract shapes, character surfaces reduced to their broad form.

After finding the closest surface point, the force computes an offset direction by checking whether the particle is above or below the surface (using dot product against the vertex normal), then drives the particle toward the surface-plus-offset position. The orientation derives from the movement direction and the surface normal, producing particles that face along their travel direction while lying flat against the surface. The `Phase` parameter drives a per-particle noise animation that produces organic variation in surface placement over time.

**ReconstructiveForce** pulls particles toward a target point cloud, blending position, rotation, velocity, and color toward corresponding target points. This enables point-cloud-to-point-cloud morphing: emit particles, let other forces scatter them, then apply ReconstructiveForce with a target mesh's point cloud to reassemble the particles into the target shape.

From `Operators/Lib/Assets/shaders/particles/ReconstructiveForce.hlsl`:

```hlsl
float3 pos = Particles[gi].Position;
float4 rot = Particles[gi].Rotation;
float3 velocity = Particles[gi].Velocity;

// Compute volume falloff
float3 posInVolume = mul(float4(usedPos, 1), TransformVolume).xyz;
float d = length(posInVolume);
float t = (d + r * (FallOff - 1)) / (2 * r * FallOff);

float baseBlend = smoothstep(1, 0, t) * Strength;
float blendFactor = 1 - pow(1 - baseBlend, SpeedFactor);

Particles[gi].Position = lerp(pos, TargetPoints[targetPointIndex].Position, blendFactor);
Particles[gi].Rotation = qSlerp(rot, TargetPoints[targetPointIndex].Rotation, blendFactor);
Particles[gi].Velocity = lerp(velocity, 0, blendFactor);
Particles[gi].Color    = lerp(Particles[gi].Color, TargetPoints[targetPointIndex].Color, blendFactor);
```

The blend factor formula `1 - pow(1 - baseBlend, SpeedFactor)` deserves attention. A naive implementation would use `baseBlend * SpeedFactor`, which breaks at high frame rates (over-blending) and low frame rates (under-blending). The exponential form ensures that blending at 30fps produces visually equivalent results to blending at 120fps: the particle approaches its target at the same perceived rate regardless of frame rate.

The `TransformVolume` parameter applies a configurable transform to define the influence region: a sphere in world space that can be repositioned, scaled, and rotated. Particles inside the volume experience full blend strength (modulated by `FallOff`); particles outside experience no force. This enables spatial control of reconstruction — particles can assemble into a shape only within a region that sweeps through the scene.

---

### Orientation Forces

**SnapToAnglesForce** quantizes the angle of each particle's velocity vector to a discrete set of directions. The quantization works by projecting the velocity onto a configurable plane, computing the angle in that plane, rounding to the nearest multiple of `SnapAngle`, and reconstructing the velocity at the snapped angle.

The angle quantization core from `Operators/Lib/Assets/shaders/particles/SnapOrientationForce.hlsl`:

```hlsl
float aNormalized = ((a + PI) / (PI * 2)) % 1;
float subdivisions = 360 / SnapAngle;

float4 hash = hash41u(id + RandomSeed * _PRIME0);
if (hash.x < VariationRatio)
{
    aNormalized += (hash.y - 0.5) * Variation;
}
float t = aNormalized * subdivisions;
float tRounded = ((int)(t + 0.5)) / subdivisions;

float newAngle = lerp(aNormalized, tRounded, Amount);
```

The `VariationRatio` and `Variation` parameters introduce organic irregularity: a fraction of particles get a small random offset before quantization, so not every particle snaps to the same angle. With `SnapAngle = 45` and no variation, particles travel in eight discrete compass directions. With variation enabled, most particles travel in those eight directions but some deviate slightly, producing a crystalline-but-alive quality.

The `SpaceAndPlane` parameter selects between camera space (snapping relative to the view frustum) and three world-space planes. Camera-space snapping creates effects that feel anchored to the screen regardless of camera movement; world-space snapping preserves the quantization through camera rotation. The `KeepPlanar` parameter suppresses the velocity component perpendicular to the chosen plane, flattening three-dimensional particle movement into a two-dimensional dance.

---

### Texture-Based Forces

**ImageForce** (exposed in the UI as TextureMapForce) uses the screen-space projection of each particle's world position to sample a 2D texture, then uses the sampled RGB as a force vector. This connects the 2D image world to the 3D particle world: a normal map baked from geometry, a hand-painted flow map, or a live video feed can all drive particle motion.

The shader projects each particle through the full camera-to-clip-space transform and samples the texture at the resulting screen coordinate:

```hlsl
float4 posInObject = float4(Particles[i.x].Position, 1);
float4 posInCamera = mul(posInObject, ObjectToCamera);
float4 pos = mul(float4(posInCamera.xyz, 1), CameraToClipSpace);
pos.xyz /= pos.w;  // Perspective divide

float4 normalMap = FxTexture.SampleLevel(texSampler, (pos.xy * float2(1, -1) + 1) / 2, 0);
```

The `Twist` parameter rotates the sampled normal vector before applying it, enabling swirling motions from flat input textures. The `Confinement` parameter applies a centering force to particles that drift outside the screen boundaries — `smoothstep(0.9, 1.2, distanceFromCenter)` activates gently as particles approach the screen edge, preventing runaway drift. The `DepthConcentration` parameter pulls particles toward a configurable depth plane, collapsing three-dimensional distributions into a flat layer aligned with a specific camera distance.

---

### Constraint Forces

**VerletRibbonForce** is the only force that operates on particles as a connected chain rather than as independent points. It interprets the particle buffer as an ordered sequence of points connected by segments, applies Verlet integration to each point, and then runs iterative distance constraint solving to enforce segment length. The result is rope-like or ribbon-like behavior where particles remain connected while still responding to gravity and damping.

The force uses three separate GPU kernels defined in the same HLSL file:

The first kernel (`main`, 64 threads) performs Verlet integration. It stores the previous position in a `VerletAttributes` buffer, computes velocity from position delta, and integrates with gravity:

```hlsl
float3 velocity = pos - VerletAttributes[index].PreviousPosition;
float3 newPos = pos + velocity * Damping + Gravity * DeltaTime * DeltaTime;
Particles[index].Position = newPos;
VerletAttributes[index].PreviousPosition = pos;
```

The second kernel (`constraints`, 256 threads) solves segment-length constraints iteratively. It uses double-buffered positions in `VerletAttributes` (alternating between `Pos1` and `Pos2` each iteration) to avoid write conflicts while multiple threads adjust neighboring segment endpoints:

```hlsl
float3 delta = posB - posA;
float distance = length(delta);
float difference = distance < 0.0001 ? 0 : (distance - SegmentLength) / distance;

if (!IsPinned(indexA)) posA += delta * 0.5 * difference;
if (!IsPinned(indexB)) posB -= delta * 0.5 * difference;
```

The third kernel (`apply`, 64 threads) reads the constrained positions from the double-buffer and blends them back into the particle buffer, with an optional `RestoreFactor` that pulls particles toward reference positions — allowing the ribbon to spring back toward a rest shape.

Pinning is handled through a convention: a particle is pinned if its index is zero or if the corresponding reference point has a NaN in its stretch attribute. This lets you pin the head of a ribbon chain while the tail flows freely.

> **Key Insight:** The constraint kernel runs at 256 threads, double the thread count of the integration and apply kernels. This is intentional — constraint solving benefits from processing more adjacent segments simultaneously, and the double-buffer scheme lets even-indexed and odd-indexed constraints run in the same dispatch without overwriting each other's results.

**CollisionForce** handles particle-to-particle collisions using a spatial hash grid for broad-phase detection. Rather than testing every particle against every other particle (O(n²)), it bins particles into cells of size `CellSize` and only tests particles in the same or neighboring cells (O(n × k) where k is the average particles per cell).

---

### Utility

**SwitchParticleForce** is not a shader — it is a C# operator that selects one of N connected force chains based on an integer index. The selection happens entirely in the node graph's C# evaluation layer:

```csharp
var index = Index.GetValue(context).Mod(connections.Count);
Selected.Value = connections[index].GetValue(context);
```

This enables conditional force application: animate the index to a beat and particles switch between gravity, turbulence, and a surface force in sync with the music. The modulo arithmetic ensures the index wraps gracefully if it exceeds the connection count.

---

## Force Summary

| Force | Category | Modifies | Template? | Key Algorithm |
|---|---|---|---|---|
| DirectionalForce | Physics | Velocity | No | Constant + per-particle random |
| VelocityForce | Physics | Velocity | No | Speed ramp + clamp |
| AxisStepForce | Physics | Velocity | No | Probabilistic axis impulse |
| FieldDistanceForce | Field | Velocity | Yes | SDF tetrahedral gradient + decay |
| FieldVolumeForce | Field | Velocity | Yes | SDF predictive collision + reflect |
| TurbulenceForce | Field | Velocity | Yes | Curl noise (divergence-free) |
| RandomJumpForce | Field | Position | Yes | Curl noise displacement |
| VectorFieldForce | Field | Velocity | Yes | 3D field sampling (w as magnitude) |
| FollowMeshSurfaceForce | Mesh | Position + Rotation | No | Brute-force triangle closest-point |
| ReconstructiveForce | Mesh | All channels | No | Point cloud blend, exponential lerp |
| SnapToAnglesForce | Orientation | Velocity | No | Projected angle quantization |
| ImageForce | Texture | Velocity | No | Screen-space texture sampling |
| CollisionForce | Constraint | Velocity + Position | No | Spatial hash broad-phase |
| VerletRibbonForce | Constraint | Position | No | Verlet + distance constraints |
| SwitchParticleForce | Utility | N/A | N/A | C# graph multiplexer |

---

## Comparison with Phoenix Affectors

Phoenix (the demoscene particle system documented elsewhere in this repository) provides a useful contrast to tixl's approach. Both systems solve the same problem — applying forces to particles — but the architectural trade-offs reveal different priorities.

| Aspect | tixl Forces | Phoenix Affectors |
|---|---|---|
| Execution | GPU compute dispatches, parallel | CPU function calls, sequential |
| Chaining | MultiInputSlot (sequential dispatch) | Scene graph children |
| Composability | Template injection for SDF fields | Hard-coded affector types |
| Force count | 16 | 5 (drag, gravity, turbulence, vortex, friction) |
| Extensibility | New HLSL shader + thin C# wrapper | New C++ class |
| Frame-rate independence | SpeedFactor multiplier on every force | Fixed 25fps simulation rate |
| Particle count | Hundreds of thousands on GPU | Hundreds to low thousands on CPU |

Phoenix achieves frame-rate independence by running the simulation at a fixed 25fps timestep. Every force function assumes a 40ms step. tixl cannot do this on the GPU — there is no equivalent of a fixed-timestep accumulator that feeds sequential GPU dispatches at a controlled rate. Instead, tixl passes the frame's actual delta time through `SpeedFactor` and trusts each force to scale its effect accordingly. This works but requires every force author to handle the scaling correctly, whereas Phoenix's fixed timestep makes that concern invisible.

The composability gap is significant. Phoenix's turbulence affector uses a specific noise function with fixed parameters. You cannot connect an SDF to it or change the noise algorithm. tixl's TurbulenceForce accepts any ShaderGraph field as a modulator — you can make turbulence zero inside a box and maximum outside it, or modulate by a texture, or compose any combination. That power comes from the template injection system, which has no analogue in Phoenix's CPU affector model.

---

## Implications for Rust/wgpu

Several design patterns in tixl's force system translate directly to wgpu compute pipeline design.

The sequential-dispatch-on-shared-buffer model maps naturally to wgpu command encoders. A force chain becomes a sequence of `compute_pass.dispatch_workgroups()` calls on the same `Buffer`, all within a single `CommandEncoder`. The GPU executes them in order with appropriate memory barriers. The key difference from tixl's D3D11 approach is that wgpu requires explicit pipeline barriers — you would need to insert `wgpu::BufferBarrier` between dispatches if the buffer transitions between read and write states.

The `SpeedFactor` pattern is essential and worth systematizing. In a Rust implementation, a `ParticleSystemUniform` struct passed to every force shader would carry delta time alongside any other shared state. Forces that need frame-rate independence multiply their per-frame increments by this value. Making it part of the shared uniform — rather than per-force cbuffer — reduces the API surface that force authors need to understand.

Template injection could work in two ways in Rust. The simpler approach uses Rust string templates with the same placeholder system tixl uses, feeding the assembled HLSL (or WGSL) to `naga` for validation and compilation. The more idiomatic approach uses `naga`'s IR directly, building shader modules programmatically by composing function bodies rather than string-substituting source code. The latter approach enables type checking at composition time, not just at compilation time.

The `VerletRibbonForce`'s three-kernel approach also translates directly. In wgpu, the three kernels become three compute passes in sequence, with the double-buffer ping-pong handled by alternating which buffer views bind to which pipeline. The `UpdateCount` atomic counter that tracks iteration parity in tixl's implementation would become a small uniform buffer updated between passes — cleaner than an atomic in the shader, since wgpu command encoders can write to uniform buffers between dispatches.

The SwitchParticleForce has no direct GPU equivalent, but its concept maps to conditional resource binding. In wgpu, you might select between N `BindGroup`s at the Rust level and dispatch the appropriate pipeline based on runtime state — achieving the same branching behavior without putting any selection logic on the GPU.

---

## References

- `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/_SetParticleSystemComponents.cs` — Force chaining implementation
- `visual-programming/tixl/Operators/Lib/Symbols/point/_internal/GetParticleComponents.cs` — Context extraction per force
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/DirectionalForce.hlsl` — Canonical simple force pattern
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/FieldDistanceForce.hlsl` — SDF gradient + tetrahedral normal estimation
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/FieldVolumeForce.hlsl` — Predictive collision + reflection
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/TurbulanceForce.hlsl` — Curl noise turbulence with field modulation
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/RandomJumpForceTemplate.hlsl` — Position-space curl noise displacement
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/VectorFieldForce-sg.hlsl` — ShaderGraph vector field sampling
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/FollowMeshSurfaceForce.hlsl` — Triangle closest-point and surface orientation
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ReconstructiveForce.hlsl` — Exponential lerp for frame-rate independence
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/SnapOrientationForce.hlsl` — Angle quantization and camera-space projection
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/ImageForce.hlsl` — Screen-space texture sampling with confinement
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/VerletRibbonForce.hlsl` — Three-kernel Verlet chain with double-buffer constraints
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/VelocityForce.hlsl` — Speed ramp with gain/bias curve remapping
- `visual-programming/tixl/Operators/Lib/Assets/shaders/particles/AxisStepForce.hlsl` — Probabilistic axis impulse with rotation-space option
- `notes/per-framework/tixl/core/shadergraph/analysis.md` — ShaderGraph system and template injection mechanics
