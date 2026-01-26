# Particle Simulation: Fixed Timestep Physics

> When particles need to fall at the same rate whether you're running at 24fps or 144fps

Imagine you're watching a firework display. The sparks trail downward with elegant arcs, following predictable physics. Now imagine someone suddenly cranks up the playback speed to double rate. In a naive particle system, the sparks would fall twice as fast, hitting the ground in half the time. The physics would be frame-rate dependent. Phoenix solves this with a technique borrowed from game engine physics: the fixed timestep accumulator. Particles always simulate at exactly 25 updates per second, regardless of rendering frame rate. Fast machines render more interpolated frames between physics steps. Slow machines might process multiple physics steps per render frame to catch up. The physics remains deterministic and frame-rate independent.

This matters deeply for demos. When you're synchronizing particle bursts to music beats, frame-rate dependent physics would drift out of sync on different hardware. A particle explosion timed to a kick drum on the author's machine would be early or late on someone else's. Fixed timestep keeps everything locked to absolute time, not frame time. The simulation becomes a pure function of elapsed seconds, not the accidents of rendering speed.

The simulation loop is surprisingly simple. Age particles by decrementing their life counter. Query all affectors in the scene, asking each if this particle is inside its influence volume. Accumulate forces into velocity. Update position by velocity. Update rotation by rotation speed. Rinse and repeat 25 times per second. The complexity lies in the details: emission timing to prevent clumping, transform interpolation for smooth motion blur, depth sorting for correct alpha blending, and efficient GPU buffer upload. This document traces through the update loop, showing how Phoenix balances physics accuracy with rendering performance.

## The Update Pipeline: Two Phases

Particle updates happen in response to timeline events. When the timeline triggers `EVENT_PARTICLECALC`, it calls `UpdateParticles()` with the time delta since the last update. The method does two main jobs: simulate physics at fixed timestep, then upload render data to GPU buffers.

### Entry Point

**Scene.cpp:463-606 (CphxObject_ParticleEmitter_CPU::UpdateParticles)**

```cpp
void CphxObject_ParticleEmitter_CPU::UpdateParticles(float elapsedtime, bool updatebuffer)
{
  int particlecount = 1 << BufferSize;
  Ticks += elapsedtime * PARTICLEENGINE_FRAMERATE;  // Accumulate time

  // Phase 1: Fixed timestep physics (lines 470-539)
  // Phase 2: Optional GPU buffer upload (lines 544-605)
}
```

The method signature includes `bool updatebuffer` because sometimes you want physics without rendering. During timeline scrubbing in the tool, particles need to simulate forward to reach the scrub point, but you don't need to render every intermediate frame. Setting `updatebuffer = false` skips the GPU upload, saving time.

The `Ticks` accumulator is the heart of fixed timestep. Instead of applying `elapsedtime` directly to physics, the code converts it to ticks at the engine's fixed rate. One tick equals 1/25th of a second (40 milliseconds). The loop consumes whole ticks, leaving the fractional remainder for the next frame.

### Phase 1: Physics Update

The physics loop runs while `Ticks >= 1`, meaning at least one full timestep has accumulated:

**Scene.cpp:504-539**

```cpp
while (Ticks >= 1)
{
  // Age and move particles (507-521)
  for (int y = 0; y < particlecount; y++)
  {
    if (Aging) Particles[y].LifeLeft -= 1;
    if (Particles[y].LifeLeft > 0)
    {
      // Apply affectors
      for (int x = 0; x < affectorcount; x++)
        if (affectors[x]->ParticleInside(Particles[y].Position))
          Particles[y].Velocity += affectors[x]->GetForce(&Particles[y]);

      // Integrate motion
      Particles[y].Position += Particles[y].Velocity;
      Particles[y].Rotation += Particles[y].RotationSpeed;
    }
  }

  // Spawn new particles (523-535)
  // ...

  EmissionFraction--;
  Ticks--;
}
```

Each iteration represents exactly 40ms of simulation time. If the render frame rate is 60fps (16.6ms per frame), the loop runs zero or one times most frames. If the render frame rate drops to 20fps (50ms per frame), the loop runs once or twice to catch up. If the application pauses for 5 seconds then resumes, the loop runs 125 times (5 seconds × 25 ticks/second) to advance the simulation to the correct state.

This design ensures determinism. Given the same initial particle state and the same elapsed time, the simulation produces identical results regardless of how many render frames occurred. This is critical for demo reproducibility.

### Phase 2: GPU Buffer Upload

After physics completes, the code builds a vertex buffer for rendering:

**Scene.cpp:574-605**

```cpp
if (!VertexBuffer)
  return;

D3D11_MAPPED_SUBRESOURCE ms;
phxContext->Map(VertexBuffer, NULL, D3D11_MAP_WRITE_DISCARD, NULL, &ms);

float *Data = (float*)ms.pData;

for (int y = 0; y < LiveCount; y++)
{
  int idx = DistanceBuffer[y].Idx;  // Sorted or unsorted depending on flags

  // Interpolate position by fractional tick
  D3DXVECTOR3 v = Particles[idx].Position + Particles[idx].Velocity * Ticks;

  Data[0] = v.x;
  Data[1] = v.y;
  Data[2] = v.z;
  Data[3] = 1;
  Data[4] = Aging ? (Particles[idx].LifeLeft - Ticks) / (float)Particles[idx].MaxLife : 1;
  Data[5] = Particles[idx].Rotation + Particles[idx].RotationSpeed * Ticks;
  Data[6] = Particles[idx].Chaos;
  Data[7] = 0;
  Data += 8;
}

phxContext->Unmap(VertexBuffer, NULL);
```

The buffer contains 8 floats per particle. The shader expands each particle into a billboard quad during rendering. The interpolation by `Ticks` (the fractional remainder from the fixed timestep loop) ensures smooth motion even when physics updates happen at 25fps and rendering happens at 60fps.

## Fixed Timestep Accumulator: The PARTICLEENGINE_FRAMERATE Constant

The magic number 25 appears throughout the particle system. Why 25fps for physics when rendering might be 60fps or 120fps?

### Design Rationale

**Scene.h:15**

```cpp
#define PARTICLEENGINE_FRAMERATE 25.0f
```

Twenty-five updates per second is fast enough to prevent visible stepping but slow enough to keep CPU costs reasonable. Particle lifetimes are measured in ticks, not seconds, which means a particle with `LifeLeft = 125` lives for exactly 5 seconds (125 ticks ÷ 25 ticks/second).

The fixed rate also simplifies artist workflows. When adjusting emission rates, velocities, and forces, artists think in terms of the 25fps physics rate. An emission rate of "50 particles per second" spawns exactly 2 particles per physics tick. A velocity of "0.01 units per tick" moves the particle 0.25 units per second. The predictability aids iteration.

### Accumulator Mechanics

**Scene.cpp:468**

```cpp
Ticks += elapsedtime * PARTICLEENGINE_FRAMERATE;
```

If `elapsedtime` is 0.016 seconds (60fps), this adds 0.4 ticks. The fractional tick accumulates across frames. After 2.5 render frames, `Ticks` crosses 1.0 and a physics update occurs. The fractional 0.0 remainder carries forward.

If `elapsedtime` is 0.100 seconds (10fps, maybe due to a stutter), this adds 2.5 ticks. The loop runs twice (`while (Ticks >= 1)`), consuming 2.0 ticks. The fractional 0.5 remainder carries forward.

This accumulator pattern is common in game physics. It decouples simulation rate from rendering rate, providing stability and determinism. The cost is that particle positions slightly lag the render time by up to one tick (40ms maximum). But this lag is invisible because the code interpolates positions using the fractional tick remainder.

### Tick Interpolation for Smooth Rendering

**Scene.cpp:592**

```cpp
D3DXVECTOR3 v = Particles[idx].Position + Particles[idx].Velocity * Ticks;
```

After the physics loop consumes whole ticks, the `Ticks` variable holds the fractional remainder (0.0 to 0.999). This represents how far between physics steps the current render frame sits. Multiplying velocity by this fraction gives the sub-tick position offset.

Example timeline:
- Frame 0: `elapsedtime = 0.016`, `Ticks = 0.4`
- Frame 1: `elapsedtime = 0.016`, `Ticks = 0.8`
- Frame 2: `elapsedtime = 0.016`, `Ticks = 1.2` → physics update runs, `Ticks = 0.2` after
- Frame 3: `elapsedtime = 0.016`, `Ticks = 0.6`

At Frame 2 after physics, the particle's position reflects the state at physics time T. The renderer runs at time T + 0.2 ticks. Interpolating by 0.2 ticks produces the position at render time, not physics time. This eliminates visible 25fps stepping when rendering at 60fps.

The same technique applies to rotation:

**Scene.cpp:598**

```cpp
Data[5] = Particles[idx].Rotation + Particles[idx].RotationSpeed * Ticks;
```

And to life ratio for animating opacity or color:

**Scene.cpp:597**

```cpp
Data[4] = Aging ? (Particles[idx].LifeLeft - Ticks) / (float)Particles[idx].MaxLife : 1;
```

Subtracting `Ticks` from `LifeLeft` gives the interpolated life at render time, not the discrete life at the last physics step. This ensures smooth fade-outs as particles age.

## Matrix Tracking: Motion Blur and Child Emitters

Particle emission needs to account for the emitter's movement between frames. If an emitter moves quickly and emits particles, the particles should spawn along the emitter's path, not all at its current position. Phoenix tracks both the current and previous frame's transformation matrices to interpolate emission positions.

### Current and Previous Matrices

**Scene.cpp:488-502**

```cpp
D3DXMATRIX *matrices = new D3DXMATRIX[objectcount];
D3DXMATRIX *oldmatrices = new D3DXMATRIX[objectcount];
matrices[0] = currMatrix;      // Updated this frame during scene traversal
oldmatrices[0] = prevMatrix;   // Cached from last frame

#ifdef PHX_HAS_SCENE_OBJECT_HIERARCHIES
int cnt = 1;
for (int x = 0; x < Scene->ObjectCount; x++)
  if (Scene->Objects[x]->Parent == this)
  {
    matrices[cnt] = Scene->Objects[x]->currMatrix;
    oldmatrices[cnt++] = Scene->Objects[x]->prevMatrix;
  }
#endif
```

The emitter stores its current and previous world matrices in `currMatrix` and `prevMatrix`. These are updated during scene graph traversal by the base object class:

**Scene.cpp:253-254 (from TraverseSceneGraph)**

```cpp
prevMatrix = currMatrix;
currMatrix = m;
```

Each frame, the old current becomes the new previous. The newly computed accumulated transform becomes the new current. This two-frame sliding window enables motion-based effects.

### Child Objects as Emitters

The `objectcount` variable accounts for child objects parented to the emitter. If an emitter has child objects, those children's transforms can also emit particles. This enables complex emission patterns: a spinning wheel with multiple emitter children creates a spiral pattern, each child contributing particles from its own animated position.

The code collects all child object transforms into parallel arrays. During emission, the emitter cycles through these transforms using `objIdxMod`:

**Scene.cpp:530**

```cpp
int id = (objIdxMod++) % objectcount;
SpawnParticle(EmissionFraction - (int)EmissionFraction, matrices[id], oldmatrices[id], idx / (float)cnt);
```

The modulo operation round-robins through emission objects. If `objectcount = 4` (the emitter plus 3 children), particles alternate spawning from positions 0, 1, 2, 3, 0, 1, 2, 3, etc. This distributes particles evenly across all emission sources.

### Motion Interpolation During Spawn

**Scene.cpp:426-432 (from SpawnParticle)**

```cpp
// Transform particle to world space
D3DXVECTOR4 va, vb, vc;
D3DXVec3Transform(&va, &Particles[idx].Position, &m);      // Current frame position
D3DXVec3Transform(&vb, &Particles[idx].Position, &o);      // Previous frame position
D3DXVec4Lerp(&vc, &vb, &va, 1 - mt);                       // Interpolate
Particles[idx].Position = D3DXVECTOR3(vc);
```

The parameter `mt` (motion time) ranges from 0.0 to 1.0, representing where in the frame this particle spawned. A particle spawning at the start of the frame (`mt = 0`) uses a position interpolated close to the previous frame's matrix. A particle spawning at the end of the frame (`mt = 1.0`) uses a position at the current frame's matrix.

This ensures smooth emission trails. If an emitter moves rapidly, particles spread along the motion path rather than clustering at the final position. It's a simple form of motion blur for particle birth.

## Physics Update: Aging, Affectors, and Integration

The core simulation loop is a textbook Euler integration: forces accumulate into velocity, velocity accumulates into position. Phoenix keeps this intentionally simple. There's no Runge-Kutta, no Verlet integration, no sub-stepping. Just naive forward Euler. Why? Because it's cheap, deterministic, and visually sufficient for demo effects.

### Particle Aging

**Scene.cpp:509**

```cpp
if (Aging) Particles[y].LifeLeft -= 1;
```

If the emitter has aging enabled, particles lose one tick of life per physics update. When `LifeLeft` reaches zero, the particle dies. It remains in the array but is marked as dead, eligible for reuse during the next spawn.

The `Aging` flag allows for immortal particles. Non-aging particles (`Aging = false`) live forever, useful for persistent effects like starfields or ambient dust. Their `LifeLeft` never decrements, so they remain alive until manually cleared or replaced.

### Affector Query

**Scene.cpp:472-485**

```cpp
int affectorcount = 0;
for (int x = 0; x < Scene->ObjectCount; x++)
{
  if (Scene->Objects[x]->ObjectType == Object_ParticleGravity ||
      Scene->Objects[x]->ObjectType == Object_ParticleDrag ||
      Scene->Objects[x]->ObjectType == Object_ParticleTurbulence ||
      Scene->Objects[x]->ObjectType == Object_ParticleVortex)
    affectors[affectorcount++] = (CphxObject_ParticleAffector*)Scene->Objects[x];
}
```

Before each physics update, the code scans the entire scene for affector objects, building a temporary array. This is somewhat inefficient—iterating all scene objects per frame when affectors rarely change. But the scene object count is typically small (dozens, not thousands), so the linear search is acceptable.

A more optimized approach would cache affectors and only rebuild when the scene changes. Phoenix prioritizes simplicity over micro-optimization here.

### Force Accumulation

**Scene.cpp:513-515**

```cpp
for (int x = 0; x < affectorcount; x++)
  if (affectors[x]->ParticleInside(Particles[y].Position))
    Particles[y].Velocity += affectors[x]->GetForce(&Particles[y]);
```

Each affector first tests if the particle is within its influence volume via `ParticleInside()`. This method transforms the particle's world position into the affector's local space and checks against the affector's bounds (infinite, box, etc.).

If inside, the affector's `GetForce()` calculates the force vector. This might be drag (opposing velocity), gravity (toward a point or direction), turbulence (noise-based chaos), or vortex (rotation around an axis). The force adds directly to velocity.

This is Euler integration with an implicit assumption that force equals acceleration (mass = 1 for all particles). In proper physics, `force = mass × acceleration`, so `acceleration = force / mass`, and `velocity += acceleration × dt`. Phoenix simplifies to `velocity += force`, treating force as acceleration and folding the timestep into the force magnitude. Artists adjust affector power values to achieve desired effects, so the physical accuracy doesn't matter.

### Position and Rotation Integration

**Scene.cpp:518-519**

```cpp
Particles[y].Position += Particles[y].Velocity;
Particles[y].Rotation += Particles[y].RotationSpeed;
```

Velocity directly updates position. This is forward Euler integration: `new_position = old_position + velocity × dt`. Since the timestep is implicit (one tick), the formula simplifies to `new_position = old_position + velocity`.

Rotation speed directly updates rotation angle. No quaternion smoothing, no wrap-around handling. The rotation value just accumulates. A particle with `RotationSpeed = 10` degrees per tick spins at 250 degrees per second. If rotation accumulates to 7200 degrees, so be it—the shader's sine/cosine functions handle wrapping naturally.

This naive approach occasionally causes large rotation values to lose precision in floating-point arithmetic, but only after thousands of ticks. For typical particle lifetimes (a few seconds), this is non-issue.

## Emission: Fractional Accumulator and Subframe Timing

Particle emission uses the same accumulator pattern as fixed timestep physics. A fractional counter tracks partial particles. When the counter crosses 1.0, a particle spawns. This ensures correct emission rates regardless of frame rate.

### Emission Per Second to Particles Per Tick

**Scene.cpp:524-526**

```cpp
if (SplineResults[Spline_Particle_EmissionPerSecond] > 0)
{
  int cnt = 1 + (int)((1 - fmod(EmissionFraction, 1.0f)) /
                      (PARTICLEENGINE_FRAMERATE /
                       (SplineResults[Spline_Particle_EmissionPerSecond] * objectcount)));
```

The artist-facing parameter is `Spline_Particle_EmissionPerSecond`, e.g., "emit 50 particles per second." The code converts this to particles per tick:

```
particles_per_tick = EmissionPerSecond / PARTICLEENGINE_FRAMERATE
                   = 50 / 25 = 2 particles per tick
```

If there are multiple emission objects (the emitter plus child emitters), the rate divides among them. With 4 emission objects, 50 particles/second becomes 12.5 particles/second per object, or 0.5 particles per tick per object.

### Fractional Counter Loop

**Scene.cpp:528-535**

```cpp
while (EmissionFraction < 1)
{
  int id = (objIdxMod++) % objectcount;
  SpawnParticle(EmissionFraction - (int)EmissionFraction, matrices[id], oldmatrices[id],
                idx / (float)cnt);
  EmissionFraction += PARTICLEENGINE_FRAMERATE /
                      (SplineResults[Spline_Particle_EmissionPerSecond] * objectcount);
  idx++;
}
```

Each iteration spawns one particle and advances `EmissionFraction` by the inverse emission rate. If the emission rate is 0.5 particles per tick, each spawn advances the fraction by 2.0. The loop immediately exits after one particle.

If the emission rate is 3 particles per tick, each spawn advances the fraction by 0.333. The loop runs three times before `EmissionFraction` exceeds 1.0.

At the end of the physics tick:

**Scene.cpp:537**

```cpp
EmissionFraction--;
```

The counter decrements by 1.0, leaving the fractional remainder for the next tick. This is the same pattern as `Ticks` for fixed timestep physics.

### Subframe Timing for Smooth Trails

**Scene.cpp:531**

```cpp
SpawnParticle(EmissionFraction - (int)EmissionFraction, matrices[id], oldmatrices[id],
              idx / (float)cnt);
```

The first parameter to `SpawnParticle()` is the fractional time within the current tick when this particle spawns (0.0 = start of tick, 1.0 = end of tick). The third parameter `idx / (float)cnt` is the fractional position within the emission batch for this tick (0.0 = first particle, 1.0 = last particle).

These fractional times interpolate the particle's birth position between the emitter's old and current matrices, preventing all particles from clumping at discrete frame positions. If an emitter moves quickly and spawns 10 particles per tick, those particles spread along the motion path at 0%, 10%, 20%, ..., 90% of the way between the previous and current positions.

This is a subtle detail that elevates visual quality. Without subframe timing, particles would pulse in discrete clusters, creating a strobe effect. With subframe timing, they form smooth trails.

## Particle Sorting: Back-to-Front for Alpha Blending

Alpha blending requires rendering particles in back-to-front order. Phoenix optionally sorts particles by depth before uploading to the GPU.

### Depth Calculation

**Scene.cpp:546-567**

```cpp
LiveCount = 0;

D3DXVECTOR4 cd1, cd2;
D3DXMATRIX mx;
D3DXMatrixTranspose(&mx, &phxViewMatrix);
D3DXVec3Transform(&cd1, &D3DXVECTOR3(0, 0, 1), &mx);
D3DXVec3Transform(&cd2, &D3DXVECTOR3(0, 0, 0), &mx);
D3DXVECTOR3 camdir = *(D3DXVECTOR3*)&(cd1 - cd2);

for (int y = 0; y < particlecount; y++)
{
  if (Particles[y].LifeLeft > 0)
  {
    DistanceBuffer[LiveCount].Idx = y;
    #ifdef PHX_HAS_PARTICLE_SORTING
    if (Sort)
      DistanceBuffer[LiveCount].Dist = Particles[y].Position.x * camdir.x +
                                       Particles[y].Position.y * camdir.y +
                                       Particles[y].Position.z * camdir.z;
    #endif
    LiveCount++;
  }
}
```

The code extracts the camera forward direction from the view matrix. The transposed view matrix transforms `(0,0,1)` (forward in view space) and `(0,0,0)` (origin) into world space. The difference is the camera forward vector.

For each living particle, a dot product between position and camera direction gives the signed distance along the view axis. Particles further from the camera have larger distances. Particles behind the camera have negative distances.

The `DistanceBuffer` stores index/distance pairs, separating particle identity from sort order. This allows sorting without shuffling the main particle array.

### Sort with qsort

**Scene.cpp:569-572**

```cpp
#ifdef PHX_HAS_PARTICLE_SORTING
if (Sort)
  qsort(DistanceBuffer, LiveCount, sizeof(PHXPARTICLEDISTANCE), ParticleSorter);
#endif
```

The C standard library `qsort()` sorts the distance buffer in-place using the `ParticleSorter` comparator:

**Scene.cpp:455-459**

```cpp
int _cdecl ParticleSorter(const void *a, const void *b)
{
  float d = ((PHXPARTICLEDISTANCE*)a)->Dist - ((PHXPARTICLEDISTANCE*)b)->Dist;
  return d < 0 ? -1 : 1;
}
```

The comparator returns -1 if `a` is nearer than `b`, sorting front-to-back. Wait, that seems backwards for alpha blending, which needs back-to-front. Let me check the buffer upload logic...

**Scene.cpp:584-601**

```cpp
for (int y = 0; y < LiveCount; y++)
{
  #ifdef PHX_HAS_PARTICLE_SORTING
  int idx = DistanceBuffer[y].Idx;
  #else
  int idx = y;
  #endif

  // Pack particle data...
}
```

The loop iterates `DistanceBuffer` from 0 to `LiveCount`, writing particles in sorted order to the vertex buffer. If `qsort` produces front-to-back order, the buffer contains front-to-back particles. But wait, the comparator returns `-1` when `a.Dist < b.Dist`, which means *smaller distances* (nearer particles) sort *earlier*. This is front-to-back.

So is Phoenix rendering particles front-to-back? That would only work for opaque particles or additive blending. For alpha blending, this is incorrect.

Actually, looking at the comparator again: it returns `-1` when `a.Dist < b.Dist`. Standard `qsort` interprets `-1` as "a should come before b." So smaller (nearer) distances sort earlier. This is front-to-back, not back-to-front.

This might be a bug, or Phoenix particles use additive blending or opaque rendering where sort order doesn't matter for correctness. Or possibly the shader renders in reverse order. Without the shader code, it's hard to confirm. The sorting logic exists, but the sort direction seems incorrect for transparent alpha blending. I'll note this ambiguity but proceed with the explanation.

### When to Sort

Sorting isn't always necessary:
- **Additive blending**: Order doesn't matter; all particles contribute additively regardless of depth
- **Opaque particles**: Depth testing handles occlusion; no sort needed
- **Alpha blending**: Requires back-to-front sorting for correct transparency

The `Sort` flag enables sorting per-emitter. Artists enable it only when needed, saving CPU time for emitters that don't require it.

The `qsort()` performance is O(N log N), acceptable for typical particle counts (100-1000 particles). For larger systems (10,000+ particles), this can become a bottleneck, suggesting a switch to GPU compute shaders for simulation.

## GPU Buffer Upload: Packing Data for Rendering

After physics and sorting complete, the code uploads particle data to a GPU vertex buffer for rendering. Each particle becomes 8 floats packed into the buffer.

### Buffer Mapping

**Scene.cpp:577-582**

```cpp
if (!VertexBuffer)
  return;
D3D11_MAPPED_SUBRESOURCE ms;
phxContext->Map(VertexBuffer, NULL, D3D11_MAP_WRITE_DISCARD, NULL, &ms);

float *Data = (float*)ms.pData;
```

The `D3D11_MAP_WRITE_DISCARD` flag tells the GPU driver to discard the old buffer contents and allocate a new memory region. This avoids stalling the GPU pipeline waiting for the previous frame's rendering to complete. The driver maintains multiple buffer copies (ring buffering) internally, giving the CPU fresh memory to write while the GPU reads from older copies.

This is a common pattern for dynamic vertex buffers that update every frame. Static geometry uses `D3D11_USAGE_IMMUTABLE`. Dynamic particles use `D3D11_USAGE_DYNAMIC` with `MAP_WRITE_DISCARD`.

### Particle Data Layout

**Scene.cpp:584-602**

```cpp
for (int y = 0; y < LiveCount; y++)
{
  int idx = DistanceBuffer[y].Idx;  // Handles sorted or unsorted

  // Interpolate position by fractional tick
  D3DXVECTOR3 v = Particles[idx].Position + Particles[idx].Velocity * Ticks;

  Data[0] = v.x;                    // Position X
  Data[1] = v.y;                    // Position Y
  Data[2] = v.z;                    // Position Z
  Data[3] = 1;                      // Position W (always 1)
  Data[4] = Aging ? (Particles[idx].LifeLeft - Ticks) / (float)Particles[idx].MaxLife : 1;
  Data[5] = Particles[idx].Rotation + Particles[idx].RotationSpeed * Ticks;
  Data[6] = Particles[idx].Chaos;
  Data[7] = 0;                      // Reserved
  Data += 8;
}
```

Each particle occupies 8 floats (32 bytes). The layout:

| Offset | Count | Content | Purpose |
|--------|-------|---------|---------|
| 0-2 | 3 floats | Position (x, y, z) | World space position |
| 3 | 1 float | Position (w) | Always 1 (homogeneous coordinate) |
| 4 | 1 float | Life ratio | 0.0 = just born, 1.0 = about to die |
| 5 | 1 float | Rotation | Angle in degrees |
| 6 | 1 float | Chaos | Random seed (0.0 to 1.0) |
| 7 | 1 float | Reserved | Unused, always 0 |

The position interpolation by `Ticks` is critical. As discussed earlier, `Ticks` is the fractional remainder from the fixed timestep loop. Particles at physics time plus fractional tick gives the position at render time, ensuring smooth motion.

The life ratio uses a similar interpolation:

```cpp
(Particles[idx].LifeLeft - Ticks) / (float)Particles[idx].MaxLife
```

Subtracting `Ticks` from the discrete `LifeLeft` gives the continuous life at render time. Dividing by `MaxLife` normalizes to 0-1, where 0 is full life remaining and 1 is dead. Wait, that's backwards. Let me recalculate.

If `LifeLeft = 100` and `MaxLife = 100`, the ratio is `(100 - 0) / 100 = 1.0`, which should be "full life," not "about to die." But if `LifeLeft = 1` and `MaxLife = 100`, the ratio is `(1 - 0) / 100 = 0.01`, which should be "almost dead," not "just born."

The ratio represents *life remaining*, not *life elapsed*. So 1.0 = full life, 0.0 = dead. The shader might invert this (`1.0 - lifeRatio`) to get life elapsed for fade-in/fade-out effects. Or the spline texture uses life remaining as the U coordinate. The exact interpretation depends on the shader, which isn't shown here.

The rotation is also interpolated:

```cpp
Particles[idx].Rotation + Particles[idx].RotationSpeed * Ticks
```

Continuous rotation at render time, ensuring smooth spinning even when physics runs at 25fps and rendering runs at 60fps.

The chaos value (`Data[6]`) is a random seed assigned at particle birth. The shader can use this to vary per-particle randomness: slightly different colors, sizes, or animation offsets. A common pattern is:

```glsl
float randomOffset = fract(sin(chaos * 12.9898) * 43758.5453);
color = baseColor * (0.9 + 0.2 * randomOffset);
```

This pseudo-random function produces deterministic variation based on the chaos seed, ensuring particles don't all look identical.

### Buffer Unmap

**Scene.cpp:604**

```cpp
phxContext->Unmap(VertexBuffer, NULL);
```

Unmapping flushes CPU writes and makes the buffer available to the GPU. The rendering pipeline can now access the updated particle data. The next draw call will render the particles with this frame's simulation state.

## Spline Texture: Baking Life-Based Animation

Standard particles (billboards) animate material properties over their lifetime. Opacity fades out as particles die. Color shifts from white-hot to red-cool. Size grows then shrinks. Phoenix bakes these animation curves into a 2D texture for efficient GPU sampling.

### The Texture Format

**Scene.cpp:761-765**

```cpp
D3D11_TEXTURE2D_DESC tex = {2048, splinecnt, 1, 1, DXGI_FORMAT_R32_FLOAT,
                            1, 0, D3D11_USAGE_DEFAULT,
                            D3D11_BIND_SHADER_RESOURCE, 0, 0};
D3D11_SUBRESOURCE_DATA data = {texturedata, 2048 * 4, 0};

phxDev->CreateTexture2D(&tex, &data, &SplineTexture);
phxDev->CreateShaderResourceView(SplineTexture, NULL, &SplineTextureView);
```

The texture is 2048 pixels wide by N rows, where N is the number of material parameters animated over particle lifetime. Each row is a separate animation curve. The width of 2048 provides smooth interpolation (1/2048 ≈ 0.05% granularity).

The format `DXGI_FORMAT_R32_FLOAT` stores full 32-bit floating-point values, ensuring no precision loss from curve evaluation to shader sampling. This is overkill for most parameters (16-bit floats would suffice), but the texture is tiny (2048 × N × 4 bytes), so precision beats compression.

### Baking Splines to Texture

**Scene.cpp:729-774**

```cpp
void CphxObject_ParticleEmitter_CPU::UpdateSplineTexture()
{
  // Count life-animated splines
  int splinecnt = 0;
  for (int x = 0; x < Clips[0]->MaterialSplines->SplineCount; x++)
  {
    CphxMaterialSpline *s = Clips[0]->MaterialSplines->Splines[x];
    if (s->Target->Type == PARAM_PARTICLELIFEFLOAT) splinecnt++;
  }

  // Sample each spline at 2048 points from 0 to 1
  splinecnt = 0;
  for (int x = 0; x < Clips[0]->MaterialSplines->SplineCount; x++)
  {
    CphxMaterialSpline *s = Clips[0]->MaterialSplines->Splines[x];
    if (s->Target->Type == PARAM_PARTICLELIFEFLOAT)
    {
      for (int z = 0; z < 2048; z++)
      {
        s->Splines[0]->CalculateValue(z / 2048.0f);
        texturedata[z + splinecnt * 2048] = s->Splines[0]->Value[0];
      }
      splinecnt++;
    }
  }

  // Create texture...
}
```

Only material parameters marked `PARAM_PARTICLELIFEFLOAT` get baked. Other material parameters update per-frame, not per-particle. This distinction avoids texture bloat for parameters that don't need per-particle animation.

The baking loop evaluates each spline at 2048 evenly spaced points from 0.0 to 1.0 (life elapsed). The results pack into rows of the texture. Row 0 is parameter 0's curve, row 1 is parameter 1's curve, etc.

In the shader, sampling becomes:

```glsl
float lifeElapsed = 1.0 - particleLifeRatio;  // Convert remaining → elapsed
float2 uv = float2(lifeElapsed, parameterIndex / splineCount);
float animatedValue = splineTexture.Sample(linearSampler, uv).r;
```

This converts per-particle curve evaluation (expensive) into a texture lookup (cheap). A particle system with 1000 particles and 10 animated parameters would require 10,000 spline evaluations per frame. Texture sampling costs nearly nothing in comparison.

### Updating the Texture

The spline texture is created once during particle emitter initialization. It doesn't update every frame because the curves don't change. If an artist modifies a material animation curve in the tool, the tool recreates the texture by calling `UpdateSplineTexture()`.

This is a form of shader precalculation: move computation from runtime to load time. The texture is the cached result of spline evaluation at discrete sample points. The runtime cost is a texture upload (one-time) plus texture samples (per particle per frame), which is far cheaper than evaluating cubic Catmull-Rom splines per particle.

## Mesh and Subscene Particles: Per-Particle Rendering

Mesh particles and subscene particles bypass the standard billboard rendering. Instead, each living particle spawns a full render instance (or recursive scene traversal) with a transformation matrix derived from the particle's position, rotation, and scale.

### Render Instance Creation

**Scene.cpp:608-643**

```cpp
void CphxObject_ParticleEmitter_CPU::CreateRenderDataInstances(int Clip, const D3DXMATRIX &m,
                                                                CphxScene *RootScene, void *SubSceneData)
{
  Clips[Clip]->MaterialSplines->ApplyToParameters(this);

  // Update material state (lines 614-625)
  // ...

  // Standard particles: create one render instance with vertex buffer
  if (!ObjectToEmit && !SceneToEmit)
  {
    Material->CreateRenderDataInstances(MaterialState, RootScene, VertexBuffer, LiveCount);
  }
}
```

Standard particles call `Material->CreateRenderDataInstances()` once, passing the vertex buffer and live count. The material system creates render instances for each material pass, binding the vertex buffer. The shader expands each particle to a billboard quad during rendering.

Mesh and subscene particles take a different path:

**Scene.cpp:643-723**

```cpp
else
{
  int particlecount = 1 << BufferSize;
  for (int y = 0; y < particlecount; y++)
  {
    if (Particles[y].LifeLeft > 0)
    {
      // Build transformation matrix from particle state (654-678)
      D3DXMATRIX m;
      D3DXQUATERNION q;
      // ... quaternion calculation ...

      float life = Aging ? (1 - ((Particles[y].LifeLeft - Ticks) / (float)Particles[y].MaxLife)) : 0.0f;

      // Sample life-based scale splines (682-702)
      float scale = 1;
      float scalex = 1;
      float scaley = 1;
      for (int x = 0; x < Clips[Clip]->SplineCount; x++)
      {
        if (Clips[Clip]->Splines[x]->Type == Spline_Particle_Scale)
        {
          Clips[Clip]->Splines[x]->Spline->CalculateValue(life);
          scale = max(0, Particles[y].ScaleChaos) * Clips[Clip]->Splines[x]->Spline->Value[0];
        }
        // ... similar for Stretch_X and Stretch_Y ...
      }

      D3DXVECTOR3 interpolatedPosition = Particles[y].Position + Particles[y].Velocity * Ticks;
      D3DXMatrixTransformation(&m, nullptr, nullptr,
                               &D3DXVECTOR3(scale * scalex, scale * scaley, scale),
                               nullptr, &q, &interpolatedPosition);

      // Render subscene or mesh (707-718)
      if (SceneToEmit)
      {
        SceneToEmit->UpdateSceneGraph(0, life, m, RootScene, SubSceneData ? SubSceneData : ToolData);
      }
      else
      {
        Clips[Clip]->MaterialSplines->CalculateValues(life);
        ObjectToEmit->CreateRenderDataInstances(Clips[Clip], m, RootScene, SubSceneData ? SubSceneData : ToolData);
      }
    }
  }
}
```

Each living particle:
1. Calculates a rotation quaternion (either from rotation axis or velocity direction)
2. Samples scale animation splines at the particle's life elapsed
3. Builds a transformation matrix from position, rotation, and scale
4. Calls either `SceneToEmit->UpdateSceneGraph()` or `ObjectToEmit->CreateRenderDataInstances()`

This creates hundreds or thousands of render instances, one per particle. A mesh particle system with 500 particles generates 500 mesh render instances. A subscene particle system with 100 particles recursively evaluates the subscene 100 times, each with a different transformation matrix.

### RotateToDirection: Velocity Alignment

**Scene.cpp:657-678**

```cpp
if (!RotateToDirection)
{
  D3DXQuaternionRotationAxis(&q, &Particles[y].RotationAxis,
                             (Particles[y].Rotation + Particles[y].RotationSpeed * Ticks) * 3.1415f / 180.0f);
}
else
{
  D3DXVECTOR3 xd = Particles[y].Velocity;
  D3DXVECTOR3 yd, zd;
  D3DXVec3Normalize(&xd, &xd);
  D3DXVECTOR3 up(0, 1, 0);
  D3DXVec3Normalize(&zd, D3DXVec3Cross(&zd, &xd, &up));
  D3DXVec3Normalize(&yd, D3DXVec3Cross(&yd, &zd, &xd));
  D3DXMATRIX mx;
  D3DXMatrixIdentity(&mx);
  *(D3DXVECTOR3*)mx.m[0] = xd;
  *(D3DXVECTOR3*)mx.m[1] = yd;
  *(D3DXVECTOR3*)mx.m[2] = zd;
  D3DXQuaternionRotationMatrix(&q, &mx);
  D3DXQUATERNION q2;
  D3DXQuaternionRotationAxis(&q2, &D3DXVECTOR3(1, 0, 0),
                             (Particles[y].Rotation + Particles[y].RotationSpeed * Ticks) * 3.1415f / 180.0f);
  D3DXQuaternionMultiply(&q, &q2, &q);
}
```

When `RotateToDirection = false`, particles rotate around a random axis determined at spawn time. The rotation angle accumulates based on rotation speed. This is useful for tumbling debris or spinning sparkles.

When `RotateToDirection = true`, particles align their local X axis with the velocity direction. The code builds an orthonormal basis:
- X axis = normalized velocity (forward)
- Z axis = X cross (0,1,0) (perpendicular to velocity in the horizontal plane)
- Y axis = Z cross X (completes right-handed basis)

This basis transforms into a rotation quaternion, orienting the particle to face its direction of travel. Useful for arrows, missiles, or sparks that stretch along motion paths.

The final quaternion multiplies by an additional rotation around the X axis (the velocity direction). This allows particles to spin while maintaining forward orientation, like a bullet rifling through the air.

### Life-Based Scale Animation

**Scene.cpp:682-702**

```cpp
for (int x = 0; x < Clips[Clip]->SplineCount; x++)
{
  if (Clips[Clip]->Splines[x]->Type == Spline_Particle_Scale)
  {
    Clips[Clip]->Splines[x]->Spline->CalculateValue(life);
    scale = max(0, Particles[y].ScaleChaos) * Clips[Clip]->Splines[x]->Spline->Value[0];
  }
  if (Clips[Clip]->Splines[x]->Type == Spline_Particle_Stretch_X)
  {
    Clips[Clip]->Splines[x]->Spline->CalculateValue(life);
    scalex = Clips[Clip]->Splines[x]->Spline->Value[0];
  }
  if (Clips[Clip]->Splines[x]->Type == Spline_Particle_Stretch_Y)
  {
    Clips[Clip]->Splines[x]->Spline->CalculateValue(life);
    scaley = Clips[Clip]->Splines[x]->Spline->Value[0];
  }
}
```

Three splines control scale:
- `Spline_Particle_Scale`: Uniform base scale, modulated by per-particle `ScaleChaos`
- `Spline_Particle_Stretch_X`: Non-uniform scale along X axis
- `Spline_Particle_Stretch_Y`: Non-uniform scale along Y axis

Evaluating at `life` (0.0 = birth, 1.0 = death) allows particles to grow, shrink, or pulse over their lifetime. A common pattern: small at birth, grow to full size, then shrink before death. The spline texture handles this for standard particles, but mesh particles need CPU evaluation because each particle spawns a separate render instance with its own scale.

The `ScaleChaos` multiplier adds per-particle variation. A particle with `ScaleChaos = 1.2` grows 20% larger than the base scale curve.

### Recursive Subscene Rendering

**Scene.cpp:707-711**

```cpp
if (SceneToEmit)
{
  SceneToEmit->UpdateSceneGraph(0, life, m, RootScene, SubSceneData ? SubSceneData : ToolData);
}
```

Subscene particles recursively call `UpdateSceneGraph()` on the subscene, passing the particle's transformation matrix as the root transform. The subscene evaluates all its objects, evaluates all their animations at time `life`, and creates render instances.

This enables particles that are themselves animated scenes. A flock of birds where each bird is a subscene with wing flapping animation. A swarm of spacecraft with rotating engines and blinking lights. Each particle is a complete animated entity, not just a billboard or static mesh.

The subscene evaluates at time `life` (the particle's life elapsed, 0-1), not the global timeline time. This means every particle's subscene animation loops over the particle's lifetime, regardless of when it spawned. All particles see the same animation sequence from birth to death, just offset in absolute time.

## Update Frequency and Optimization

The particle update method runs in response to timeline events, typically once per frame. But the timeline can control update frequency.

### Timeline Event Triggering

The timeline triggers `EVENT_PARTICLECALC` with a delta time. The event can fire every frame, or less frequently to save CPU. For background particles that don't need precise timing, updating at 15fps instead of 60fps reduces CPU load.

The fixed timestep accumulator compensates for variable update rates. If updates happen at 15fps (66ms per update), the accumulator adds 1.65 ticks per update. The physics loop runs once or twice per update, maintaining the 25fps physics rate. The interpolation by `Ticks` ensures smooth rendering even with infrequent updates.

### Skipping Buffer Upload

The `updatebuffer` parameter allows physics without rendering. During timeline scrubbing, the tool jumps to time T by simulating all ticks from 0 to T. It doesn't need to render each intermediate state, so it calls `UpdateParticles(dt, false)` repeatedly, only uploading the buffer at the final target time.

This drastically speeds up scrubbing. Simulating 1000 ticks of physics takes milliseconds. Uploading GPU buffers 1000 times would take seconds due to CPU-GPU synchronization overhead.

### Performance Bottlenecks

The main CPU costs are:
1. **Affector queries**: O(particles × affectors) checks per physics tick
2. **Particle sorting**: O(particles log particles) if enabled
3. **Spline evaluation for mesh particles**: O(particles × splines) per render
4. **GPU buffer mapping**: Synchronization stalls if GPU is still using the buffer

For particle counts under 1000, none of these are problematic. Phoenix targets 100-500 particles per emitter, well within comfortable CPU performance.

For larger systems (10,000+ particles), GPU compute shaders are mandatory. Phoenix has a placeholder `Object_ParticleEmitter` for GPU particles (Scene.h:383-396), but it's unimplemented in the codebase. The architecture suggests compute shaders would simulate and render entirely on GPU, eliminating CPU bottlenecks.

---

## Buffer Layout Summary

### Standard Particles (Billboard Rendering)

Each particle: 8 floats (32 bytes)

| Offset | Floats | Data | Notes |
|--------|--------|------|-------|
| 0-2 | 3 | Position (xyz) | Interpolated by fractional tick |
| 3 | 1 | Position (w) | Always 1.0 |
| 4 | 1 | Life ratio | `(LifeLeft - Ticks) / MaxLife`, 1.0 = alive, 0.0 = dead |
| 5 | 1 | Rotation | Degrees, interpolated by fractional tick |
| 6 | 1 | Chaos | Random seed for shader variation |
| 7 | 1 | Reserved | Always 0.0 |

The vertex shader expands each particle to a quad. The geometry shader (or instanced rendering) creates 4 vertices per particle. The pixel shader samples the spline texture using life ratio as U coordinate.

### Spline Texture Layout

2048 × N texture, `DXGI_FORMAT_R32_FLOAT`
- Width: 2048 samples (0.0 to 1.0 life elapsed)
- Height: N rows, one per `PARAM_PARTICLELIFEFLOAT` material parameter
- Each row: baked spline curve sampled at 2048 points

Shader sampling:
```glsl
float u = lifeElapsed;  // 0.0 to 1.0
float v = (parameterIndex + 0.5) / parameterCount;  // Row center
float value = splineTexture.Sample(linearSampler, float2(u, v)).r;
```

### Mesh Particle Rendering

No vertex buffer. Each particle generates:
- One transformation matrix (position, rotation, scale)
- One call to `ObjectToEmit->CreateRenderDataInstances()`
- Multiple render instances (one per material pass in the mesh)

For 100 particles with a mesh that has 3 material passes, this creates 300 render instances.

### Subscene Particle Rendering

No vertex buffer. Each particle generates:
- One transformation matrix (position, rotation, scale)
- One recursive call to `SceneToEmit->UpdateSceneGraph()`
- Multiple render instances (from all objects in the subscene)

For 50 particles with a subscene containing 10 objects, this creates 500+ object evaluations and potentially thousands of render instances.

---

## Implications for Rust Framework Design

Phoenix's particle simulation offers clear lessons for a Rust creative coding framework:

### Fixed Timestep Accumulator as Default

Provide a built-in fixed timestep accumulator for all time-based systems. Physics, animation, and particle updates should default to fixed rates with fractional interpolation. This prevents frame-rate dependence and ensures deterministic behavior.

```rust
struct FixedTimestep {
    rate: f32,
    accumulator: f32,
}

impl FixedTimestep {
    fn update(&mut self, delta_time: f32) -> impl Iterator<Item = ()> {
        self.accumulator += delta_time * self.rate;
        (0..(self.accumulator as usize)).map(|_| {
            self.accumulator -= 1.0;
        })
    }

    fn interpolation_factor(&self) -> f32 {
        self.accumulator
    }
}
```

### Separate Simulation from Rendering

Particle systems should have distinct `update()` and `build_render_data()` methods. Update runs physics. Build creates GPU buffers or render instances. This allows:
- Updating without rendering (timeline scrubbing)
- Rendering without updating (paused scenes)
- Multiple renders per update (motion blur, shadowmaps)

```rust
trait ParticleEmitter {
    fn update(&mut self, delta_time: f32, affectors: &[Box<dyn Affector>]);
    fn build_render_data(&self, buffer: &mut VertexBuffer);
}
```

### Fractional Emission for Smooth Spawning

Use fractional accumulators for emission rates. Don't round emission rates to whole particles per frame. Accumulate fractional particles across frames and spawn when the accumulator crosses integer thresholds.

```rust
struct EmissionState {
    rate: f32,  // Particles per second
    accumulator: f32,
}

impl EmissionState {
    fn update(&mut self, delta_time: f32) -> usize {
        self.accumulator += self.rate * delta_time;
        let count = self.accumulator.floor() as usize;
        self.accumulator -= count as f32;
        count
    }
}
```

### Bake Curves to Textures for GPU Access

Any animation curve evaluated per-particle per-frame should bake to textures or storage buffers. Opacity fade curves, color gradients, size animation, all become texture lookups. This moves spline evaluation from CPU to GPU-friendly data access.

Use compute shaders for massive particle systems. 1000 particles fit on CPU. 100,000 particles need GPU compute. Provide both implementations behind a common interface.

### Affector Pattern for Spatial Influences

The affector pattern (spatial queries with force calculation) generalizes beyond particles:
- Audio attenuation zones
- Lighting influence volumes
- Collision triggers
- Wind fields

Provide a spatial influence trait:
```rust
trait SpatialInfluence {
    fn affects(&self, position: Vec3, transform: &Mat4) -> bool;
    fn apply(&self, state: &mut EntityState);
}
```

Cache inverse transforms during scene traversal for efficient local-space testing.

### Power-of-Two Sizing for Particle Buffers

Use powers of two for particle buffer capacities. This enables efficient index wrapping with bitwise AND and simplifies allocation strategies. A custom `PowerOfTwoVec<T>` wrapper can enforce this at compile time.

### Depth Sorting with Index Buffers

Avoid shuffling particle data during sorting. Use an index buffer (like `DistanceBuffer`) that sorts indices, not particles. The particle array stays in spawn order. Sorting rearranges indices. Rendering uses the sorted index buffer.

For very large systems, use radix sort on GPU compute. `qsort` is fine for 1000 particles but doesn't scale to 100,000.

### Motion Interpolation for Trails

Track previous and current transforms for moving emitters. Interpolate particle spawn positions along the motion path to prevent clumping. This is essential for fast-moving emitters.

Store `prev_transform` and `curr_transform` per scene node. Update during traversal:
```rust
node.prev_transform = node.curr_transform;
node.curr_transform = parent_transform * node.local_transform;
```

### Optional Features via Traits

Particle sorting, aging, and special rendering modes should be opt-in. Use the type system to enforce constraints:

```rust
trait ParticleEmitter {
    fn update(&mut self, dt: f32);
}

trait Aging: ParticleEmitter {
    fn max_lifetime(&self) -> f32;
}

trait Sorted: ParticleEmitter {
    fn sort_by_depth(&mut self, camera_dir: Vec3);
}
```

Emitters implement only the traits they need. The renderer checks trait bounds at compile time.

### Hybrid CPU/GPU Particle Systems

Offer both CPU and GPU particle implementations with identical public APIs. Artists choose based on scale:
- CPU: < 1000 particles, complex logic, CPU-side collision
- GPU: > 1000 particles, simple physics, compute shaders

The scene graph doesn't care which implementation is used. Both produce render instances.

---

Phoenix's particle simulation is a masterclass in pragmatic game engine design. Fixed timestep for determinism. Fractional accumulators for smooth emission. Interpolation for visual quality. Sorting for correctness. Buffer mapping for efficiency. Each technique is simple individually but composes into a robust system. For Rust frameworks, the lesson is clear: provide solid primitives (fixed timestep, spatial queries, curve baking) and let users compose them into complex effects. The engine handles the tedious bits—timing, interpolation, GPU upload—so artists focus on the creative bits—motion, color, life.
