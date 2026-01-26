# Phoenix Engine: Particle Affectors

> "To make particles dance, you need invisible choreographers."

Particles moving in straight lines are boring. Real motion has turbulence, attraction, friction. Phoenix solves this with **affectors**: invisible force fields that modify particle velocity, creating complex organic motion without complex per-particle logic.

The elegance lies in separation of concerns. Emitters spawn particles with initial velocity. Affectors modify velocity based on position. The particle system just integrates velocity into position. This composable architecture lets you layer effects—add gravity, then drag, then turbulence—and watch emergent behavior arise.

## The Problem: Complex Motion Without Complex State

Consider animating smoke. It needs to rise (gravity), slow down (drag), and swirl (turbulence). You could bake all this into custom emitter logic, but that's not reusable. Or you could add fields to each particle tracking which forces affect it, but that bloats memory (remember: 64KB demo constraints).

Phoenix's solution: affectors are scene objects that modify particles during the update loop. They have transforms (position, scale), area bounds (infinite or box), and a pure function: `GetForce(particle) -> velocity_delta`. This makes them stateless, composable, and dirt cheap per-particle (just a function call).

The key insight is treating force fields as spatial queries. "Is this particle inside the affector's volume?" If yes, apply the force. This naturally supports localized effects (a box of wind) and global effects (universal gravity) with the same code.

## The Base Class: Spatial Boundaries and Force Queries

All affectors inherit from `CphxObject_ParticleAffector` (`Scene.h:307-320`), which defines the common interface.

```cpp
class CphxObject_ParticleAffector : public CphxObject
{
public:
  unsigned char AreaType;
  bool ParticleInside( D3DXVECTOR3 v );
  virtual D3DXVECTOR3 GetForce( PHXPARTICLE *p ) = 0;
};
```

Two responsibilities:
1. **Spatial query** via `ParticleInside()`: Is this particle affected?
2. **Force calculation** via `GetForce()`: What velocity change to apply?

### Spatial Queries: Global vs. Local

The `AreaType` field determines the affector's reach:
- **0 = Infinite**: Affects all particles in the scene
- **1 = Box volume**: Affects particles within a [-0.5, 0.5]³ unit cube, transformed by the object's world matrix

Think of it like collision detection, but instead of checking for impact, you're checking if a particle is "inside" the force field. The implementation (`Scene.cpp:832-848`) uses the inverse matrix trick:

```cpp
bool CphxObject_ParticleAffector::ParticleInside( D3DXVECTOR3 v )
{
  D3DXVECTOR4 pos;
  D3DXVec3Transform( &pos, &v, &inverse );  // Transform to local space

  if ( AreaType )  // Box volume
    return pos.x<0.5f && pos.x>-0.5f &&
           pos.y<0.5f && pos.y>-0.5f &&
           pos.z<0.5f && pos.z>-0.5f;

  return true;  // Infinite
}
```

*Scene.cpp:832-848*

By transforming the particle position into the affector's local space, scaling and rotation are handled automatically. A 10x10x10 box affector? Just scale the object by 10. No special case code.

The `inverse` matrix is computed once per frame during scene graph traversal (`Scene.cpp:80-89`), so the per-particle cost is just a matrix-vector multiply and six comparisons.

## Particle Drag: Exponential Decay

The simplest affector is drag (`Scene.h:322-333`). It's like moving through water: the faster you go, the more resistance you feel.

```cpp
class CphxObject_ParticleDrag : public CphxObject_ParticleAffector
{
public:
  D3DXVECTOR3 GetForce( PHXPARTICLE *p );
};

D3DXVECTOR3 CphxObject_ParticleDrag::GetForce( PHXPARTICLE *p )
{
  return p->Velocity * (-SplineResults[ Spline_AffectorPower ]);
}
```

*Scene.h:322-333, Scene.cpp:920-925*

The force is proportional to velocity but opposite in direction. `Spline_AffectorPower` is animated (usually between 0.0 and 1.0), letting you fade drag in/out over time.

Physically, this isn't accurate (real drag is velocity squared), but for visual effects, linear drag is faster and "feels" right. A power of 0.1 causes gentle slowing, 0.5 is like moving through honey, 1.0 stops particles almost immediately.

**Use cases:**
- Air resistance for projectiles
- Water simulation (high drag)
- Energy dissipation (particles slowly coming to rest)

The exponential decay emerges from integrating `dv/dt = -kv`: velocity decreases by a constant fraction each frame, creating smooth deceleration.

## Particle Gravity: Attraction and Direction

Gravity pulls particles toward a point or in a direction (`Scene.h:335-348`). Two modes:

```cpp
class CphxObject_ParticleGravity : public CphxObject_ParticleAffector
{
public:
  bool Directional;
  D3DXVECTOR3 GetForce( PHXPARTICLE *p );
};
```

### Directional Mode

In directional mode (`Directional = true`), gravity acts like a constant acceleration (think: wind, or a tilted plane):

```cpp
D3DXVECTOR3 CphxObject_ParticleGravity::GetForce( PHXPARTICLE *p )
{
  D3DXVECTOR3 pos = WorldPosition;

  if ( Directional )
  {
    D3DXVec3Normalize( &pos, &pos );
    return pos * (SplineResults[ Spline_AffectorPower ] / 100.0f);
  }
  // ...
}
```

*Scene.cpp:927-941 (directional branch)*

The affector's world position is normalized to get a direction, then scaled by power. Position at `(0, -1, 0)` with power 100 creates downward gravity matching Earth-like acceleration. Position at `(1, 0, 0)` creates horizontal wind.

### Point Mode

In point mode (`Directional = false`), gravity follows the inverse square law (like a planet or black hole):

```cpp
  // ...
  D3DXVECTOR3 v = pos - p->Position;
  float l = D3DXVec3Length( &v );
  return v * (SplineResults[ Spline_AffectorPower ] / (l * l * l) / 100.0f);
}
```

*Scene.cpp:927-941 (point branch)*

The force is `(center - particle) / distance³`. Why divide by distance cubed? Two factors of distance for the inverse square law, one to normalize the direction vector. This is mathematically equivalent to:

```
direction = normalize(center - particle)
distance = length(center - particle)
force = direction * power / (distance * distance)
```

But dividing by `l³` skips the normalization, saving a sqrt and division.

**Use cases:**
- **Directional**: Falling rain, wind zones, conveyor belts
- **Point**: Planetary orbits, vortex centers, black hole singularities

The inverse square law creates interesting behavior: particles accelerate rapidly when close, then drift lazily when far. Combined with drag, you get stable orbital motion.

## Particle Turbulence: Fractal Noise Forces

Turbulence is where it gets interesting. Instead of a simple formula, it uses 3D noise to create chaotic, organic motion (`Scene.h:350-368`).

```cpp
class CphxObject_ParticleTurbulence : public CphxObject_ParticleAffector
{
  D3DXVECTOR3 SampleKernel( const D3DXVECTOR4& Pos );
public:
  D3DXVECTOR3 Kernel[ 32 ][ 32 ][ 32 ];
  unsigned char calculatedKernelSeed;

  void InitKernel();
  D3DXVECTOR3 GetForce( PHXPARTICLE *p );
};
```

Think of turbulence like a 3D texture where each voxel contains a force vector. Particles sample this texture at their position, reading out a direction to push them. But this isn't a static texture—it's procedurally generated Perlin-style noise.

### Kernel Initialization: Random Vectors

The kernel is a 32×32×32 grid of normalized random vectors (`Scene.cpp:852-867`):

```cpp
void CphxObject_ParticleTurbulence::InitKernel()
{
  if ( RandSeed == calculatedKernelSeed )
    return;  // Already initialized with this seed

  srand( RandSeed );
  calculatedKernelSeed = RandSeed;
  for ( int x = 0; x < 32; x++ )
    for ( int y = 0; y < 32; y++ )
      for ( int z = 0; z < 32; z++ )
      {
        for ( int i = 0; i < 3; i++ )
          Kernel[ x ][ y ][ z ][ i ] = (float)(rand() / (float)RAND_MAX) - 0.5f;
        D3DXVec3Normalize( &Kernel[ x ][ y ][ z ], &Kernel[ x ][ y ][ z ] );
      }
}
```

*Scene.cpp:852-867*

Each cell gets a random direction. The seed determines the pattern, so changing the seed gives a different "flavor" of turbulence. Normalizing ensures all vectors have the same magnitude—the kernel stores pure direction, power is applied separately.

### Trilinear Interpolation: Smooth Sampling

Particles don't align to grid cells, so we interpolate (`Scene.cpp:874-906`):

```cpp
D3DXVECTOR3 CphxObject_ParticleTurbulence::SampleKernel( const D3DXVECTOR4& Pos )
{
  int v[ 3 ];
  D3DXVECTOR3 f;
  D3DXVECTOR3 area[ 2 ][ 2 ][ 2 ];

  // Get integer cell and fractional position
  for ( int x = 0; x < 3; x++ )
  {
    v[ x ] = (int)Pos[ x ];
    if ( Pos[ x ] < 0 )
      v[ x ] -= 1;  // Floor for negatives
    f[ x ] = ( Pos[ x ] - v[ x ] );
  }

  // Sample 8 corners of the cube
  for ( int x = 0; x < 2; x++ )
    for ( int y = 0; y < 2; y++ )
      for ( int z = 0; z < 2; z++ )
        area[ x ][ y ][ z ] = Kernel[ (v[0] + x) & 31 ][ (v[1] + y) & 31 ][ (v[2] + z) & 31 ];

  // Trilinear blend
  D3DXVECTOR3 v1 = Lerp( area[0][0][0], area[1][0][0], f.x );
  D3DXVECTOR3 v2 = Lerp( area[0][1][0], area[1][1][0], f.x );
  D3DXVECTOR3 v3 = Lerp( area[0][0][1], area[1][0][1], f.x );
  D3DXVECTOR3 v4 = Lerp( area[0][1][1], area[1][1][1], f.x );
  D3DXVECTOR3 v5 = Lerp( v1, v2, f.y );
  D3DXVECTOR3 v6 = Lerp( v3, v4, f.y );
  D3DXVECTOR3 res = Lerp( v5, v6, f.z );

  D3DXVec3Normalize( &res, &res );
  return res;
}
```

*Scene.cpp:874-906*

This is standard 3D texture filtering. The `& 31` modulo wraps coordinates, making the noise tile seamlessly. Negative positions are handled by flooring correctly (C's cast-to-int truncates toward zero, but noise needs floor behavior).

The final normalization is crucial: interpolating normalized vectors can produce non-unit results, so we re-normalize to keep force magnitude consistent.

### Fractal Noise: Multiple Octaves

The full force calculation layers three octaves of noise (`Scene.cpp:909-917`):

```cpp
D3DXVECTOR3 CphxObject_ParticleTurbulence::GetForce( PHXPARTICLE *p )
{
  InitKernel();
  D3DXVECTOR4 Pos;
  D3DXVec3Transform( &Pos, &p->Position, &inverse );

  D3DXVECTOR3 v3 = SampleKernel( Pos * TurbulenceFrequency )
                 + SampleKernel( Pos * (TurbulenceFrequency * 2.0f) ) * (1 / 2.0f)
                 + SampleKernel( Pos * (TurbulenceFrequency * 4.0f) ) * (1 / 4.0f);

  D3DXVec3Normalize( &v3, &v3 );
  return v3 * (SplineResults[ Spline_AffectorPower ] / 100.0f);
}
```

*Scene.cpp:909-917*

This is **fractal Brownian motion** (fBm): sample at base frequency, then at 2× and 4× frequency with halved amplitude. The result has large-scale features (from the base octave) and fine details (from the high-frequency octaves).

`TurbulenceFrequency` controls the scale. Low values (0.1) create large, slow swirls. High values (5.0) create tight, chaotic eddies. The position is transformed to local space first, so scaling the affector object scales the noise pattern.

**Use cases:**
- Smoke plumes (low frequency, high power)
- Underwater currents (medium frequency, medium power)
- Magic spell effects (high frequency, low power for shimmer)
- Leaves blowing in wind (animated frequency)

The performance cost is notable—three kernel samples with trilinear interpolation—but it's amortized across only the particles inside the affector's bounds.

## Particle Vortex: Rotational Flow

Vortex creates spiraling motion around an axis (`Scene.h:370-381`), like a tornado or whirlpool:

```cpp
class CphxObject_ParticleVortex : public CphxObject_ParticleAffector
{
public:
  D3DXVECTOR3 GetForce( PHXPARTICLE* p );
};

D3DXVECTOR3 CphxObject_ParticleVortex::GetForce( PHXPARTICLE* p )
{
  float pwr = SplineResults[ Spline_AffectorPower ];

  D3DXVECTOR3 pos = WorldPosition;
  D3DXVECTOR3 v = pos - p->Position;
  D3DXVECTOR4 axis;
  D3DXVECTOR3 force;
  D3DXVec3Transform( &axis, &D3DXVECTOR3(0, 1, 0), &GetWorldMatrix() );
  D3DXVec3Normalize( (D3DXVECTOR3*)&axis, (D3DXVECTOR3*)&axis );
  D3DXVec3Normalize( &v, &v );
  D3DXVec3Cross( &force, (D3DXVECTOR3*)&axis, &v );
  return force * pwr;
}
```

*Scene.h:370-381, Scene.cpp:944-958*

The math is elegant. The vortex rotates around its local Y axis (transformed to world space). For each particle:
1. Find the vector from particle to vortex center: `v = center - particle`
2. Normalize it
3. Take the cross product with the axis: `force = axis × v`

The cross product is perpendicular to both the axis and the radial vector, creating tangential force. This naturally produces circular motion. The magnitude is constant regardless of distance (unlike gravity), so particles orbit at whatever radius they start.

**Use cases:**
- Tornado effects (vertical axis, high power)
- Drain vortex (vertical axis, combine with downward gravity)
- Galaxy spiral (slow rotation, combine with point gravity)
- Magic circles (horizontal axis)

The key limitation: vortex force doesn't fall off with distance. Particles far from the center get pushed just as hard as nearby ones. For realistic tornados, pair a vortex with point gravity to concentrate particles toward the center.

## Integration: The Affector Loop

Affectors are collected during scene graph traversal and stored in a global array (`Scene.cpp:476-485`):

```cpp
static CphxObject_ParticleAffector *affectors[ 256 ];

void CphxObject_ParticleEmitter_CPU::UpdateParticles( float elapsedtime, bool updatebuffer )
{
  int affectorcount = 0;

  for ( int x = 0; x < Scene->ObjectCount; x++ )
  {
    if ( Scene->Objects[ x ]->ObjectType == Object_ParticleGravity ||
         Scene->Objects[ x ]->ObjectType == Object_ParticleDrag ||
         Scene->Objects[ x ]->ObjectType == Object_ParticleTurbulence ||
         Scene->Objects[ x ]->ObjectType == Object_ParticleVortex )
      affectors[ affectorcount++ ] = (CphxObject_ParticleAffector*)Scene->Objects[ x ];
  }
  // ...
}
```

*Scene.cpp:476-485*

During the particle update loop (`Scene.cpp:507-521`), each live particle checks all affectors:

```cpp
  for ( int y = 0; y < particlecount; y++ )
  {
    if ( Aging ) Particles[ y ].LifeLeft -= 1;
    if ( Particles[ y ].LifeLeft > 0 )
    {
      // Update velocity based on affecting forces
      for ( int x = 0; x < affectorcount; x++ )
        if ( affectors[ x ]->ParticleInside( Particles[ y ].Position ) )
          Particles[ y ].Velocity += affectors[ x ]->GetForce( &Particles[ y ] );

      // Update position
      Particles[ y ].Position += Particles[ y ].Velocity;
      Particles[ y ].Rotation += Particles[ y ].RotationSpeed;
    }
  }
```

*Scene.cpp:507-521*

This is a simple nested loop: for each particle, for each affector, test and apply. No spatial acceleration structure—the demo's particle counts (typically 256-4096) and affector counts (1-8) are small enough that brute force works.

The order matters: velocity is accumulated from all affectors, then position is updated once. This is **symplectic Euler integration**: `v' = v + a*dt; p' = p + v'*dt`. It's not physically accurate (true Euler would use `v` not `v'` in the position update), but it's more stable and requires no extra storage for intermediate velocities.

## Affector Comparison Table

| Affector | Formula | Parameters | Use Cases | Cost |
|----------|---------|------------|-----------|------|
| **Drag** | `-velocity × power` | power (0-1) | Air resistance, energy loss | O(1) |
| **Gravity (Directional)** | `normalize(position) × power` | power, position | Falling, wind, tilt | O(1) |
| **Gravity (Point)** | `(center - particle) × power / distance³` | power, position | Orbits, attraction, black holes | O(1) + distance calc |
| **Turbulence** | `fBm3D(position) × power` | power, seed, frequency | Smoke, wind, chaos | O(octaves × 8 lerps) |
| **Vortex** | `cross(axis, normalize(center - particle)) × power` | power, position, rotation | Tornadoes, spirals, whirlpools | O(1) + cross product |

Performance notes:
- **Drag** is cheapest: one vector multiply
- **Gravity** adds a distance calculation but is still cheap
- **Turbulence** dominates cost with 24 kernel lookups and 12 lerps per particle per frame
- **Vortex** costs the same as directional gravity

## Edge Cases and Gotchas

### Affector Ordering

Affectors are applied in scene object order, not affector type order. If you have drag, then gravity, particles will slow down before falling. If you have gravity, then drag, they'll accelerate then slow. For most effects this doesn't matter (forces are small), but for extreme values, order affects the outcome.

Phoenix doesn't sort affectors by type or priority. If you need deterministic ordering, reorder the objects in the scene.

### Inverse Matrix Caching

The affector inverse matrix is computed during scene graph traversal (`Scene.cpp:80-89`), before particle updates. If you animate an affector's transform during a single frame (unlikely, but possible with subscenes), the inverse will be stale.

### Turbulence Kernel Regeneration

Turbulence kernels are regenerated when `RandSeed` changes (`Scene.cpp:854-855`). This happens synchronously during `GetForce()`, causing a frame stutter (32K random numbers generated). In practice, seeds are constant per scene, so this only triggers once.

For animated turbulence, change `TurbulenceFrequency` or animate the affector's transform, not the seed.

### Vortex Distance Independence

Vortex force doesn't decay with distance. This is intentional—it makes the force simpler and lets you create constant-speed rotation. But it's physically unrealistic. For realistic tornados, combine vortex with point gravity (gravity pulls inward, vortex spins).

### Affector Limit

The affector array is statically sized to 256 (`Scene.cpp:461`). Exceeding this will cause buffer overflow. In practice, demos use 2-10 affectors, so this is a non-issue. But it's a silent failure mode.

### Power Scaling

All affector powers are divided by 100 (except drag, which uses the raw value). This means `Spline_AffectorPower = 100` gives unit force. This is a UI convenience (sliders go 0-100), but it's inconsistent across affector types. Drag power of 1.0 is extreme, gravity power of 1.0 is barely visible.

## Implications for Rust Framework

Phoenix's affector architecture offers several lessons for a modern creative coding framework:

### Trait-Based Force API

The `GetForce()` interface maps perfectly to Rust traits:

```rust
trait ParticleAffector {
    fn contains(&self, position: Vec3) -> bool;
    fn force(&self, particle: &Particle) -> Vec3;
}
```

This allows user-defined affectors without modifying the core engine. The particle system just calls `affector.force(particle)` for all affectors that return `true` from `contains()`.

### Spatial Queries with enum

Phoenix's `AreaType` is a simple boolean. A Rust implementation could use an enum for extensibility:

```rust
enum AffectorRegion {
    Infinite,
    Box { transform: Mat4 },
    Sphere { center: Vec3, radius: f32 },
    Mesh { sdf: SignedDistanceField },
}
```

This makes the intent explicit and allows zero-cost dispatch (the compiler inlines based on the enum variant).

### Fractal Noise as a Utility

Turbulence's kernel+interpolation logic is generic 3D noise. Extract it to a `NoiseField3D` utility that affectors (and other systems—terrain generation, procedural textures) can reuse:

```rust
struct NoiseField3D {
    kernel: [[[Vec3; 32]; 32]; 32],
    frequency: f32,
    octaves: u8,
}

impl NoiseField3D {
    fn sample(&self, position: Vec3) -> Vec3 { /* ... */ }
}
```

This reusability is key for a creative coding framework: noise is a primitive, affectors are one application.

### Force Composition

Phoenix applies affectors in a loop, but there's no API for composing forces. A Rust framework could expose force combinators:

```rust
let wind = DirectionalGravity::new(Vec3::X, 50.0);
let drag = Drag::new(0.1);
let combined = wind.then(drag);  // Sequential
let averaged = (wind + drag) / 2.0;  // Averaged
```

This makes common patterns (gravity + drag, turbulence + vortex) first-class instead of implicit.

### Animator-Friendly Defaults

Phoenix's power-divided-by-100 is a hack for UI ergonomics. A Rust framework should choose physical units (meters/second² for forces?) or make the scaling explicit:

```rust
Gravity::new(9.8).with_unit(Unit::MetersPerSecondSquared)
// or
Gravity::new(100).with_scaling(0.01)  // explicit: 100 -> 1.0
```

This avoids the "why is gravity so weak?" confusion that comes from arbitrary scaling factors.

### Affector Hot-Reload

Since affectors are pure functions of particle state, they're trivial to hot-reload. A Rust framework with asset hot-reloading could let users tweak affector parameters (power, frequency, area) and see immediate results without restarting the simulation.

Phoenix's static affector array would become a dynamic `Vec<Box<dyn ParticleAffector>>`, and changes to affector parameters would just update the existing instances.

### Performance: Broad vs. Narrow Phase

Phoenix's brute-force O(particles × affectors) is acceptable for small counts, but modern frameworks target 100K+ particles. Consider a **broad phase** for culling:

```rust
// Spatial hash or BVH for affectors
for particle in particles {
    let nearby = affector_grid.query(particle.position);
    for affector in nearby {
        if affector.contains(particle.position) {
            particle.velocity += affector.force(&particle);
        }
    }
}
```

This amortizes the cost across many particles, keeping the simple force API while scaling to larger scenes.

---

Phoenix's particle affectors demonstrate that complex motion doesn't require complex particle state. By treating forces as composable spatial queries, the system achieves flexibility (users define force fields, not particle behaviors) and efficiency (stateless affectors, single velocity accumulator per particle). The result is a small, expressive API that creates emergent organic motion from simple mathematical primitives—exactly the kind of power-to-complexity ratio a creative coding framework should target.

## References

- `demoscene/apex-public/apEx/Phoenix/Scene.h:307-381` — Affector class definitions
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp:832-959` — Affector implementations
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp:476-521` — Affector collection and application loop
