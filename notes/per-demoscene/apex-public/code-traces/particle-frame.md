# Code Trace: Single Frame of Particle Simulation

What happens when 256 particles move through turbulent air for one frame? This document traces the complete journey from `UpdateParticles()` entry to GPU-ready vertex data, revealing how a 4kb demoscene engine achieves real-time particle physics without middleware or dependencies.

The apEx Phoenix particle system operates at a fixed 25 fps internal tick rate while rendering at 60 fps, using fractional time accumulation and interpolation to bridge the gap. Each particle maintains 3D position, velocity, rotation, scale, and chaos parameters. Affectors like drag and turbulence modify velocities each tick. After physics simulation, particles are sorted back-to-front and packed into a vertex buffer with interpolated positions for smooth rendering at the display framerate.

This approach decouples simulation stability from rendering performance—a pattern common in game engines but implemented here in pure C++ with hand-tuned memory layouts and zero allocations per frame.

## Scenario Setup

We'll trace an emitter configured with:

- **256 particles** — BufferSize = 8, so `1 << 8 = 256` slots
- **Two affectors** — Drag (global) and Turbulence (localized 3D noise field)
- **Aging enabled** — Particles have finite lifetimes
- **60 fps rendering** — `elapsedtime = 0.016` seconds (one frame)
- **25 fps physics** — Internal tick rate defined by `PARTICLEENGINE_FRAMERATE`

The emitter spawns 25 particles per second, ages existing particles, applies forces, and renders them sorted by depth.

## Entry Point

**Scene.cpp:463** — `UpdateParticles(0.016, true)`

```cpp
void CphxObject_ParticleEmitter_CPU::UpdateParticles( float elapsedtime, bool updatebuffer )
```

The `elapsedtime` parameter is the fraction of a second since the last frame (16 milliseconds at 60 fps). The `updatebuffer` flag controls whether we pack data into the GPU vertex buffer—typically true during rendering, false during initialization.

## Time Accumulation

**Scene.cpp:467-468** — Convert elapsed time to internal ticks

```cpp
int particlecount = 1 << BufferSize;  // 256
Ticks += elapsedtime * PARTICLEENGINE_FRAMERATE;  // 0.016 * 25 = 0.4
```

The `Ticks` accumulator stores fractional simulation steps. Each "tick" represents one physics update. At 60 fps rendering and 25 fps physics, each frame adds 0.4 ticks on average. When `Ticks >= 1.0`, we execute a physics step and decrement by 1.

This creates a classic "spiral of death" protection pattern: if rendering slows down, the physics loop runs multiple times to catch up, but the frame interpolation ensures smooth visual output.

### Why Fixed Tick Rate?

Fixed-rate physics simplifies affector calculations—turbulence noise fields, drag coefficients, and gravity forces produce consistent results regardless of framerate. The interpolation between ticks (added later at Scene.cpp:592) handles the visual smoothness.

## Affector Collection

**Scene.cpp:472-485** — Build array of force-applying objects

```cpp
int affectorcount = 0;
for ( int x = 0; x < Scene->ObjectCount; x++ )
{
  if ( Scene->Objects[ x ]->ObjectType == Object_ParticleGravity ||
       Scene->Objects[ x ]->ObjectType == Object_ParticleDrag ||
       Scene->Objects[ x ]->ObjectType == Object_ParticleTurbulence ||
       Scene->Objects[ x ]->ObjectType == Object_ParticleVortex )
    affectors[ affectorcount++ ] = (CphxObject_ParticleAffector*)Scene->Objects[ x ];
}
```

The static `affectors[]` array (Scene.cpp:461) holds up to 256 affector pointers. The system scans all scene objects and collects those that implement `GetForce()`. In our scenario, this finds:

1. **Drag affector** — Applies `velocity * -power` to slow particles
2. **Turbulence affector** — Samples 3D Perlin noise to add swirling motion

Affectors are polymorphic objects inheriting from `CphxObject_ParticleAffector` (Scene.h:308), which defines `ParticleInside()` for spatial bounds checking and `GetForce()` for per-particle force calculation.

## Matrix Setup

**Scene.cpp:488-502** — Prepare transformation matrices for spawning

```cpp
D3DXMATRIX *matrices = new D3DXMATRIX[ objectcount ];
D3DXMATRIX *oldmatrices = new D3DXMATRIX[ objectcount ];
matrices[ 0 ] = currMatrix;
oldmatrices[ 0 ] = prevMatrix;
```

The emitter maintains `currMatrix` and `prevMatrix` (Scene.h:180-181) to interpolate particle spawn positions between frames. This prevents visual "popping" when the emitter moves—new particles lerp smoothly from the previous position to the current one.

Child emitters (if present) add additional matrices at indices 1+. The spawn system rotates through these matrices (Scene.cpp:530) to distribute particles across multiple emission points.

### Why Two Matrices?

When the emitter moves rapidly, particles spawned at different sub-frame times should interpolate positions. The `SpawnParticle()` function (Scene.cpp:374) uses `mt` (motion time) to lerp between `oldmatrices[id]` and `matrices[id]`.

## Physics Loop

**Scene.cpp:504-539** — Simulate fixed-timestep updates

```cpp
while ( Ticks >= 1 )
{
  // Age and move particles
  for ( int y = 0; y < particlecount; y++ )
  {
    if ( Aging ) Particles[ y ].LifeLeft -= 1;
    if ( Particles[ y ].LifeLeft > 0 )
    {
      // Apply affector forces
      for ( int x = 0; x < affectorcount; x++ )
        if ( affectors[ x ]->ParticleInside( Particles[ y ].Position ) )
          Particles[ y ].Velocity += affectors[ x ]->GetForce( &Particles[ y ] );

      // Euler integration
      Particles[ y ].Position += Particles[ y ].Velocity;
      Particles[ y ].Rotation += Particles[ y ].RotationSpeed;
    }
  }

  // Spawn new particles
  // ...

  EmissionFraction--;
  Ticks--;
}
```

Since `Ticks = 0.4` (less than 1.0), the loop body doesn't execute this frame. On a frame where `Ticks = 2.3`, it would run twice, advancing the simulation by two full steps.

### Aging Particles

**Scene.cpp:509** — `LifeLeft -= 1`

Each tick reduces `LifeLeft` by 1. When it reaches zero, the particle is considered dead and can be recycled. The `MaxLife` field (Scene.h:239) stores the initial lifetime for later normalization (Scene.cpp:597) when calculating the 0-1 life fraction for shader use.

### Force Application

**Scene.cpp:513-515** — Accumulate velocity changes

```cpp
for ( int x = 0; x < affectorcount; x++ )
  if ( affectors[ x ]->ParticleInside( Particles[ y ].Position ) )
    Particles[ y ].Velocity += affectors[ x ]->GetForce( &Particles[ y ] );
```

Each affector first checks if the particle lies within its influence volume (Scene.cpp:832-848). For our drag affector (global), `ParticleInside()` always returns true. For turbulence (box-shaped), it transforms the particle position into the affector's local space and tests cube bounds.

The `GetForce()` implementation varies by affector type:

- **Drag** (Scene.cpp:921) — `return p->Velocity * (-power)` scales velocity toward zero
- **Turbulence** (Scene.cpp:909) — Samples 3D Perlin noise at multiple octaves and returns a normalized force vector

These forces are added to `Velocity`, not `Position`. The next line applies Euler integration.

### Position Update

**Scene.cpp:518** — `Position += Velocity`

Classic Euler integration. Each tick advances the position by the current velocity vector. This assumes `Velocity` is in units per tick—hence the scaling factor when particles spawn (Scene.cpp:440 multiplies emission velocity by `0.01f`).

Rotation advances similarly (Scene.cpp:519), accumulating `RotationSpeed` into the `Rotation` angle for billboard orientation or mesh particle transforms.

## Particle Spawning

**Scene.cpp:524-535** — Emit new particles based on rate

```cpp
if ( SplineResults[ Spline_Particle_EmissionPerSecond ] > 0 )
{
  int cnt = 1 + (int)( ( 1 - fmod( EmissionFraction, 1.0f ) ) /
                       ( PARTICLEENGINE_FRAMERATE /
                         ( SplineResults[ Spline_Particle_EmissionPerSecond ] * objectcount ) ) );
  int idx = 0;
  while ( EmissionFraction < 1 )
  {
    int id = ( objIdxMod++ ) % objectcount;
    SpawnParticle( EmissionFraction - (int)EmissionFraction, matrices[ id ], oldmatrices[ id ], idx / (float)cnt );
    EmissionFraction += PARTICLEENGINE_FRAMERATE /
                        ( SplineResults[ Spline_Particle_EmissionPerSecond ] * objectcount );
    idx++;
  }
}
```

The `EmissionFraction` field (Scene.h:261) accumulates fractional particles. When it crosses 1.0, a particle spawns. The fraction `EmissionFraction - (int)EmissionFraction` determines the sub-tick spawn time (0.0 = start of tick, 0.9 = near end), which interpolates the spawn position for smooth emission.

The emission rate (25 particles/second at 25 fps physics) spawns 1 particle per tick on average. The `cnt` calculation handles burst scenarios where multiple particles should appear in a single tick.

### SpawnParticle Internals

**Scene.cpp:374-453** — Initialize a new particle

```cpp
void CphxObject_ParticleEmitter_CPU::SpawnParticle( float t, D3DXMATRIX &m, D3DXMATRIX &o, float mt )
{
  // Find dead slot or oldest particle
  int idx = -1;
  int minlife = Particles[ 0 ].LifeLeft;
  int particlecount = 1 << BufferSize;
  for ( int x = 0; x < particlecount; x++ )
  {
    if ( Particles[ x ].LifeLeft <= 0 ) { idx = x; break; }
    if ( Particles[ x ].LifeLeft < minlife ) { idx = x; minlife = Particles[ x ].LifeLeft; }
  }
```

The function scans the particle array for a dead slot (`LifeLeft <= 0`). If all particles are alive, it recycles the oldest one. This avoids dynamic allocation—the particle buffer is a fixed array allocated once at initialization.

**Scene.cpp:401** — Set lifetime

```cpp
Particles[ idx ].MaxLife = Particles[ idx ].LifeLeft = Aging ?
  (int)( ( SplineResults[ Spline_Particle_Life ] +
           ( rand() / (float)RAND_MAX ) * SplineResults[ Spline_Particle_LifeChaos ] ) *
         PARTICLEENGINE_FRAMERATE ) : 1;
```

Base life (10 units by default, Scene.cpp:294) plus chaos randomization, multiplied by 25 ticks/second = 250 ticks lifetime for a 10-second particle. The `LifeChaos` spline adds variance.

**Scene.cpp:403-406** — Random position in emitter shape

```cpp
do {
  Particles[ idx ].Position = D3DXVECTOR3( rand() / (float)RAND_MAX - 0.5f,
                                           rand() / (float)RAND_MAX - 0.5f,
                                           rand() / (float)RAND_MAX - 0.5f );
} while ( !( EmitterType != 1 /*sphere*/ || D3DXVec3LengthSq( &Particles[ idx ].Position ) < 0.25 ) );
```

The emitter shape (box or sphere) determines valid spawn positions. For a sphere, the loop rejects points outside a radius of 0.5 units (squared length < 0.25). For a box, all random positions in the cube [-0.5, 0.5] are valid.

**Scene.cpp:411-424** — Inner radius adjustment

```cpp
float originallength = D3DXVec3Length( &originalpos );
float poslength = max( max( fabs( originalpos.x ), fabs( originalpos.y ) ), fabs( originalpos.z ) );
if ( EmitterType == 1 ) poslength = originallength;
outerboundarypos = originalpos * 0.5f / poslength;
float outerlength = D3DXVec3Length( &outerboundarypos );
float r = lerp( InnerRadius / 255.0f, 1, originallength / outerlength );
Particles[ idx ].Position = outerboundarypos * r;
```

The `InnerRadius` parameter (0-255) creates hollow emitters by pushing particles outward. The calculation finds the outer boundary distance, then lerps between the inner radius fraction and the outer edge based on the random position's depth.

**Scene.cpp:426-432** — Transform and interpolate

```cpp
D3DXVECTOR4 va, vb, vc;
D3DXVec3Transform( &va, &Particles[ idx ].Position, &m );      // Current matrix
D3DXVec3Transform( &vb, &Particles[ idx ].Position, &o );      // Old matrix
D3DXVec4Lerp( &vc, &vb, &va, 1 - mt );                         // Interpolate by motion time
Particles[ idx ].Position = D3DXVECTOR3( vc );
```

The spawn position transforms by both the current and previous emitter matrices, then lerps based on `mt` (motion time, 0-1 across the tick). This produces sub-tick spawn accuracy even though physics runs at 25 fps.

**Scene.cpp:440-447** — Velocity, rotation, scale

```cpp
Particles[ idx ].Velocity = TargetDirection * 0.01f *
  ( SplineResults[ Spline_Particle_EmissionVelocity ] +
    ( rand() / (float)RAND_MAX ) * SplineResults[ Spline_Particle_EmissionVelocityChaos ] );
Particles[ idx ].RotationSpeed = SplineResults[ Spline_Particle_EmissionRotation ] +
  ( rand() / (float)RAND_MAX ) * SplineResults[ Spline_Particle_EmissionRotationChaos ];
Particles[ idx ].ScaleChaos = max(0, 1 + ( (rand() / (float)RAND_MAX) * 2 - 1 ) *
  SplineResults[ Spline_Particle_ScaleChaos ] );
```

The `TargetDirection` (Scene.h:154) points toward a target object if set, or a random direction otherwise (Scene.cpp:434-438). Velocity magnitude comes from spline parameters with added chaos. Rotation speed and scale chaos randomize appearance.

**Scene.cpp:448-449** — Sub-tick interpolation

```cpp
Particles[ idx ].Position += Particles[ idx ].Velocity * t;
Particles[ idx ].Rotation = Particles[ idx ].RotationSpeed * t;
```

The `t` parameter (0-1 sub-tick time) advances the newly spawned particle's position and rotation as if it existed for a fraction of the tick. This prevents all particles spawned in one tick from appearing at identical positions.

## Particle Sorting

**Scene.cpp:546-572** — Order particles by depth

```cpp
LiveCount = 0;

D3DXVECTOR4 cd1, cd2;
D3DXMATRIX mx;
D3DXMatrixTranspose( &mx, &phxViewMatrix );
D3DXVec3Transform( &cd1, &D3DXVECTOR3( 0, 0, 1 ), &mx );
D3DXVec3Transform( &cd2, &D3DXVECTOR3( 0, 0, 0 ), &mx );
D3DXVECTOR3 camdir = *( D3DXVECTOR3* )&( cd1 - cd2 );

for ( int y = 0; y < particlecount; y++ )
{
  if ( Particles[ y ].LifeLeft > 0 )
  {
    DistanceBuffer[ LiveCount ].Idx = y;
    if ( Sort )
      DistanceBuffer[ LiveCount ].Dist = Particles[ y ].Position.x * camdir.x +
                                          Particles[ y ].Position.y * camdir.y +
                                          Particles[ y ].Position.z * camdir.z;
    LiveCount++;
  }
}

if ( Sort )
  qsort( DistanceBuffer, LiveCount, sizeof( PHXPARTICLEDISTANCE ), ParticleSorter );
```

The system calculates the camera's forward direction by transforming basis vectors through the transposed view matrix. For each live particle, it computes the dot product with this direction—effectively the distance along the view ray.

The `DistanceBuffer` array (Scene.h:259) stores `{ Idx, Dist }` pairs. If sorting is enabled, `qsort()` (Scene.cpp:455-458) arranges particles back-to-front for correct alpha blending.

### Why Camera Direction?

A full distance calculation requires `sqrt(dx² + dy² + dz²)`, but sorting only needs relative ordering. The dot product with the camera direction provides the same ordering without expensive square roots—a classic demoscene optimization.

## GPU Upload

**Scene.cpp:574-605** — Pack interpolated data into vertex buffer

```cpp
D3D11_MAPPED_SUBRESOURCE ms;
phxContext->Map( VertexBuffer, NULL, D3D11_MAP_WRITE_DISCARD, NULL, &ms );

float *Data = (float*)ms.pData;

for ( int y = 0; y < LiveCount; y++ )
{
  int idx = DistanceBuffer[ y ].Idx;

  D3DXVECTOR3 v = Particles[ idx ].Position + Particles[ idx ].Velocity * Ticks;
  Data[ 0 ] = v.x;
  Data[ 1 ] = v.y;
  Data[ 2 ] = v.z;
  Data[ 3 ] = 1;
  Data[ 4 ] = Aging ? ( Particles[ idx ].LifeLeft - Ticks ) / (float)Particles[ idx ].MaxLife : 1;
  Data[ 5 ] = Particles[ idx ].Rotation + Particles[ idx ].RotationSpeed * Ticks;
  Data[ 6 ] = Particles[ idx ].Chaos;
  Data[ 7 ] = 0;
  Data += 8;
}

phxContext->Unmap( VertexBuffer, NULL );
```

The `D3D11_MAP_WRITE_DISCARD` flag tells the GPU to orphan the old buffer contents, preventing synchronization stalls. The CPU writes directly into GPU-accessible memory.

### Interpolation

**Scene.cpp:592** — `Position + Velocity * Ticks`

Since `Ticks = 0.4` (the unprocessed fractional tick), the position interpolates 40% of the way to the next physics step. This bridges the gap between 25 fps physics and 60 fps rendering—particles move smoothly even though they only update position discretely.

Rotation interpolates similarly (Scene.cpp:598), adding `RotationSpeed * Ticks` to the current angle.

### Vertex Layout

Each particle occupies 32 bytes (8 floats):

1. **Position XYZ** — World-space coordinates
2. **W component** — Always 1 (padding for vec4 alignment)
3. **Life fraction** — 0.0 (just spawned) to 1.0 (about to die)
4. **Rotation** — Angle in degrees for billboard orientation
5. **Chaos** — Random seed (0-1) for shader variation
6. **Reserved** — Always 0 (future expansion)

The shader reads this data as `float4 pos : POSITION` and `float4 data : TEXCOORD0`, using the life fraction to index color/size splines stored in a 1D texture (Scene.cpp:726-774).

## Output State

After `UpdateParticles()` completes:

- **VertexBuffer** contains interpolated positions for all live particles (LiveCount vertices)
- **Particles[]** array holds the discrete physics state at tick boundaries
- **Ticks = 0.4** — Carried forward to the next frame where it becomes `0.4 + 0.4 = 0.8`
- **EmissionFraction** — Decremented by 1 per executed tick (unchanged this frame since no ticks ran)

The rendering system (Scene.cpp:608-724) binds this VertexBuffer and issues `LiveCount` draw calls, expanding each vertex into a camera-facing billboard or instanced mesh via the geometry shader.

## Key Insights

### Decoupled Simulation and Rendering

Physics runs at 25 fps for determinism, rendering at 60+ fps for smoothness. The `Ticks` accumulator and per-vertex interpolation bridge the gap. This pattern appears in many game engines (Unity's FixedUpdate, Unreal's Tick groups) but is rarely seen in creative coding frameworks, where variable timestep integration dominates.

### Zero Allocations Per Frame

The `matrices` arrays (Scene.cpp:488-489) are the only heap allocations in the hot path, and they're freed immediately (Scene.cpp:541-542). The particle buffer, distance buffer, and affector array are all pre-allocated. This eliminates garbage collection pauses—critical for 4kb executables where memory pressure triggers frequent GC.

### Affector Polymorphism

The `CphxObject_ParticleAffector` base class (Scene.h:308) uses virtual `GetForce()` calls (Scene.cpp:515). In C++, virtual dispatch adds a pointer dereference, but the affector count is typically small (2-8), so the cost is negligible compared to the math in `GetForce()`.

Compare this to Processing's lack of force interfaces—users must manually call `applyForce()` on each particle. The affector pattern encapsulates behavior and enables spatial queries.

### Back-to-Front Sorting

Alpha-blended particles require depth sorting. The dot product optimization (Scene.cpp:563) avoids square roots at the cost of slight inaccuracy when particles are equidistant but in different directions. For translucent effects, this visual error is imperceptible.

Modern particle systems often use order-independent transparency (OIT) techniques, but those require shader read-write buffers unavailable in Direct3D 10, the target API for apEx.

### Sub-Tick Spawning

The motion time interpolation (Scene.cpp:431) is a subtle detail. Without it, 25 particles spawning in one tick would form a ring at identical distances from the emitter center. The `idx / (float)cnt` calculation (Scene.cpp:531) distributes spawn times evenly across the tick, creating smooth trails even during rapid emission.

## Implications for Framework Design

### Time Management

Creative coding frameworks should expose both variable and fixed timestep loops. Processing's `draw()` runs at frame rate, but adding a `fixedUpdate(delta)` callback at a guaranteed interval (like Unity) would enable stable physics without manual time accumulation.

### Particle Recycling

The oldest-particle-first recycling (Scene.cpp:377-390) prevents allocation churn. Frameworks like openFrameworks use `vector<Particle>` with `push_back()`, causing reallocation spikes. A fixed-size ring buffer with explicit recycling gives users control over maximum particle count.

### Affector Interfaces

Defining a `trait ParticleAffector { fn apply_force(&self, particle: &mut Particle); }` in Rust enables composition without hardcoding force types. Users can define custom affectors (magnetic fields, flocking behaviors) that integrate seamlessly with the engine's particle loop.

### Sorting Strategy

Exposing a `sort_particles(key: fn(&Particle) -> f32)` callback allows users to choose depth sorting, age sorting, or no sorting. The framework provides a default camera-distance key but permits overrides for artistic effects (e.g., sorting by hue for layered transparency).

## References

- **Scene.h:232-242** — Particle struct definition
- **Scene.h:250-304** — Emitter class with physics state
- **Scene.cpp:374-453** — Spawn logic with inner radius and interpolation
- **Scene.cpp:463-605** — UpdateParticles main loop
- **Scene.cpp:832-959** — Affector implementations (drag, gravity, turbulence, vortex)

The complete particle system spans ~600 lines across two files, demonstrating how fixed-timestep physics, spatial affectors, and GPU streaming can coexist in a minimal codebase without external dependencies.
