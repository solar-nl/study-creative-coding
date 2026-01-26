# Phoenix Particle Emitters

> Particle birth: spawn algorithms, shape geometries, and the dance between position and velocity

When you spawn a thousand particles per second, you might assume performance demands bulk allocation. Create a batch. Fill them all at once. Get it over with. Phoenix does the opposite. Each particle spawns individually, fighting for its slot in a fixed-size circular buffer. If the buffer is full and particles refuse to die, the oldest living particle gets evicted. No dynamic allocation. No fragmentation. Just constant-time slot finding and immediate initialization. Every particle born into this world arrives with a complete identity: position within the emitter shape, velocity toward a target, rotation speed from a spline, and a lifespan counting down from the moment of creation.

The emitter is the womb. It defines where particles appear, how they move, and how much chaos perturbs their deterministic birth. Think of an emitter like a fountain: the fountain's shape determines where water emerges, the pump pressure determines exit velocity, and turbulence in the pipes adds randomness. But unlike a fountain that continuously flows, a particle emitter can burst, pulse, or spray based on timeline animation. Emission rate, velocity, and even the emitter's transform matrix all come from spline curves. When the emitter moves, particles spawn interpolated between the current and previous frame's position, eliminating visible gaps during fast motion.

This design solves a fundamental problem in real-time particle systems: how do you create thousands of ephemeral objects without destroying your frame budget? The answer is preallocated buffers with aging semantics. Allocate once during initialization. Reuse slots forever. Let dead particles sit quietly in memory until their slot gets reassigned. The CPU cost becomes purely computational: random number generation for positions, matrix transformations for spawning in world space, velocity calculations from target directions. No memory operations beyond writing particle fields. No cache thrashing from scattered allocations.

Why does this matter for creative coding frameworks? Because it reveals the trade-off between flexibility and performance. Modern particle engines often use entity-component systems where particles are generic entities with component bags. Phoenix uses plain structs in contiguous arrays. Modern engines let you spawn particle types dynamically. Phoenix decides everything at initialization. Modern engines stream particles from pools. Phoenix uses fixed-size buffers. The constraint forces efficiency. The efficiency enables quantity. And quantity, in a 64KB demo, creates the illusion of complexity from simple rules.

## The Problem: Creating Particles Without Breaking the Frame

Particle systems face a chicken-and-egg dilemma. You need many particles to create convincing visual effects. Fire needs thousands of embers. Explosions need debris clouds. Magic spells need trailing sparks. But each particle costs memory: position, velocity, rotation, lifetime. If you allocate dynamically, you pay the cost of malloc overhead and heap fragmentation. If you allocate statically, you waste memory on maximum capacity.

Phoenix's solution is the power-of-two buffer with aggressive reuse. The emitter declares its buffer size as an exponent: `BufferSize = 10` means 2^10 = 1024 particles. The particle array gets allocated once during emitter construction. After that, the system never allocates again. When you need to spawn a particle, you scan the buffer for a dead slot (LifeLeft ≤ 0). If none exist and aging is enabled, you evict the particle with the smallest remaining lifetime. Oldest dies first. Slot reuse means infinite spawning from finite memory.

The spawn algorithm must be fast because it runs multiple times per frame at high emission rates. At 25 particles per second (the default), you spawn one particle per frame at 25 FPS. But at 250 particles per second, you spawn 10 per frame. At 2500 per second, you spawn 100 per frame. The emission system uses fractional accumulation: each frame adds `1.0 / (framerate / emissionRate)` to an accumulator. When the accumulator exceeds 1.0, spawn a particle and decrement. This ensures smooth emission over time without needing floating-point frame indices.

## CphxObject_ParticleEmitter_CPU: The Spawn Controller

The emitter class inherits from `CphxObject`, gaining hierarchical transforms and spline animation, then adds particle-specific state: the particle array, emission timing, buffer configuration, and shape parameters.

### Buffer Management

**Scene.h:257-259**

```cpp
int LiveCount;
PHXPARTICLE *Particles;
PHXPARTICLEDISTANCE *DistanceBuffer;
```

`LiveCount` tracks how many particles are currently alive, used for vertex buffer updates and render submission. `Particles` points to the preallocated array of particle structs. Each particle (Scene.h:234-242) contains position, velocity, rotation, rotation speed, scale, stretch, chaos value, max lifetime, remaining lifetime, random seed, and rotation axis. The full struct is 72 bytes: 3 floats position, 3 floats velocity, 7 floats for rotation and scale parameters, 2 ints for lifetime, 1 float for random seed, 3 floats for rotation axis. Multiply by 1024 particles and you get 72 KB for the particle buffer alone. This is why buffer size matters in size-optimized demos.

`DistanceBuffer` is parallel to the particle array and stores indices with camera-space distances for depth sorting. When the `Sort` flag is enabled, particles get sorted back-to-front before rendering, ensuring correct alpha blending. The sorting uses qsort on the distance buffer, leaving the particle array untouched. Render order then follows the sorted index array.

### Emission Timing

**Scene.h:261-262**

```cpp
float EmissionFraction;
float Ticks;
```

`EmissionFraction` accumulates fractional particle births. Each frame, the emission rate calculation adds a value between 0 and 1. When the accumulator crosses 1.0, spawn a particle. This fractional approach handles non-integer emission rates smoothly. If you want 2.5 particles per frame, you spawn 2 particles every frame plus a third particle every other frame.

`Ticks` accumulates elapsed time in engine ticks (PARTICLEENGINE_FRAMERATE = 25 FPS). The particle system updates in discrete ticks regardless of actual frame rate. Each tick ages particles, moves them, and spawns new ones. The remainder after integer ticks gets used for interpolation during rendering. If Ticks = 0.3, particles render at 30% of the way between their current position and their next position, smoothing motion at frame rates above 25 FPS.

### Shape Configuration

**Scene.h:270-274**

```cpp
unsigned char BufferSize;     // 2^BufferSize particles
unsigned char EmitterType;     // 0=box, 1=sphere
unsigned char InnerRadius;     // 0-255, scaled to 0.0-1.0
unsigned char StartCount;      // 0-255, percentage of buffer
unsigned char RandSeed;        // Initial random seed
```

`BufferSize` is the exponent for particle count. `BufferSize = 8` means 256 particles. `BufferSize = 12` means 4096 particles. The power-of-two sizing simplifies modulo operations and aligns with GPU texture sizes when using texture-based particle systems.

`EmitterType` selects the spawn shape: 0 for box (uniform distribution in a cube), 1 for sphere (rejection sampling for uniform distribution on a sphere). More complex shapes (cone, torus, mesh surface) would require additional types, but these two cover most use cases: explosions use spheres, area fills use boxes.

`InnerRadius` creates a hollow shape by interpolating between an inner and outer boundary. A value of 0 means particles spawn anywhere in the volume. A value of 128 (50%) means particles spawn in an annular region between 50% and 100% radius. A value of 255 means particles spawn on the surface only. This single parameter enables rings, shells, and volumetric distributions without separate shape types.

`StartCount` determines how many particles spawn during initialization (ResetParticles). It's a percentage of the buffer: 255 means spawn a full buffer, 128 means spawn half, 0 means spawn none. Initial particle clouds use this to avoid visible fade-in at demo start.

`RandSeed` initializes the random number generator, allowing deterministic replay. Each emitter can have a different seed, creating varied patterns even with identical spline curves.

### Rendering State

**Scene.h:277-283**

```cpp
#ifdef PHX_HAS_STANDARD_PARTICLES
ID3D11Texture2D *SplineTexture;
ID3D11ShaderResourceView *SplineTextureView;

ID3D11Buffer* VertexBuffer;
CphxMaterialPassConstantState **MaterialState;
CphxMaterial *Material;
#endif
```

Standard particles render as billboarded quads using a vertex buffer and material system. The `VertexBuffer` holds per-particle data: position, lifetime (normalized 0-1), rotation angle, and chaos value. The vertex shader reads this data and generates quad corners in screen space. The geometry shader can expand points into quads, or the vertex shader can use instancing with a quad template mesh.

The `SplineTexture` holds particle-lifetime-driven material parameters sampled in shaders. Instead of uploading per-particle material data, the system bakes animated splines into a 1D texture (2048 pixels wide). The pixel shader samples this texture using normalized lifetime as the U coordinate. Different material parameters (color, opacity, size) occupy different V rows. This approach compresses animation data: 100 particles with lifetime-driven color can share a single 2048x1 texture instead of requiring 100 separate color uploads.

The `Material` pointer references the material used for rendering. The `MaterialState` array holds per-pass constant buffer states, populated during `CreateRenderDataInstances()` with animated parameter values.

### Multi-Object Emission

**Scene.h:255**

```cpp
int objIdxMod;
```

This counter cycles through spawn points when the emitter has child objects. If you parent three empty objects to the emitter, each child becomes an additional spawn point. The system distributes emission evenly across objects using `objIdxMod % objectCount`. Particle 0 spawns from object 0, particle 1 from object 1, particle 2 from object 2, particle 3 from object 0 again, and so on. This enables complex multi-source effects like firework bursts (each child is a spark source) or orbital trails (each child follows a different path) without duplicating emitter objects.

## SpawnParticle: Birth in the Buffer

The spawn function finds an available slot, initializes a particle with randomized parameters from spline values, and transforms it into world space.

### Slot Allocation

**Scene.cpp:376-399**

```cpp
int idx = -1;
int minlife = Particles[0].LifeLeft;
int particlecount = 1 << BufferSize;
for (int x = 0; x < particlecount; x++)
{
  if (Particles[x].LifeLeft <= 0)
  {
    idx = x;
    break;
  }
  if (Particles[x].LifeLeft < minlife)
  {
    idx = x;
    minlife = Particles[x].LifeLeft;
  }
}

if (idx == -1)
{
  if (Aging)
    idx = 0;
  else
    return;
}
```

The loop scans the particle array for a dead particle (LifeLeft ≤ 0). If found, that slot gets reused immediately. If all particles are alive, the loop tracks the oldest (smallest LifeLeft). After scanning, if no dead slot exists and aging is disabled, the function aborts. If aging is enabled, the oldest slot gets evicted.

This scanning approach is O(n) in buffer size, which seems inefficient. Why not maintain a free list? Because a free list requires additional pointers or indices, costing memory and complicating initialization. In practice, buffer sizes rarely exceed 1024-2048 particles, and modern CPUs scan arrays so fast that the linear scan costs less than the complexity of managing free lists. The cache-friendly sequential scan often outperforms pointer-chasing through a linked free list.

The fallback to `idx = 0` when no slot is available is a failsafe. If aging is enabled, the loop should always find a slot. The explicit assignment ensures the code never writes to invalid memory, even if logic errors occur.

### Lifetime Initialization

**Scene.cpp:401**

```cpp
Particles[idx].MaxLife = Particles[idx].LifeLeft = Aging ?
  (int)((SplineResults[Spline_Particle_Life] +
         (rand() / (float)RAND_MAX) * SplineResults[Spline_Particle_LifeChaos]) *
        PARTICLEENGINE_FRAMERATE) : 1;
```

Lifetime comes from the `Spline_Particle_Life` spline plus randomness from `Spline_Particle_LifeChaos`. If the base life is 10 seconds and chaos is 2 seconds, each particle lives between 10 and 12 seconds (uniform distribution). Multiply by the engine frame rate (25 FPS) to convert seconds to ticks. Store in both `MaxLife` (for lifetime normalization in shaders) and `LifeLeft` (for aging countdown).

If aging is disabled, lifetime is always 1 tick. Particles never die. This mode is used for persistent effects like flowing water or animated meshes where particles represent fixed points rather than ephemeral sprites.

### Position: Shape Sampling

**Scene.cpp:403-406**

```cpp
do
{
  Particles[idx].Position = D3DXVECTOR3(
    rand() / (float)RAND_MAX - 0.5f,
    rand() / (float)RAND_MAX - 0.5f,
    rand() / (float)RAND_MAX - 0.5f);
} while (!(EmitterType != 1 /*sphere*/ ||
          D3DXVec3LengthSq(&Particles[idx].Position) < 0.25));
```

Position starts in local emitter space, a cube from -0.5 to +0.5 on each axis. For box emitters (EmitterType = 0), accept immediately. For sphere emitters (EmitterType = 1), reject if the length squared exceeds 0.25 (radius 0.5). This rejection sampling ensures uniform distribution within a sphere. Naive spherical coordinates (random theta and phi) cluster particles near poles. Rejection sampling in Cartesian space gives true uniformity at the cost of wasted random samples.

The loop always terminates for spheres because the cube volume (1.0) exceeds the sphere volume (πr³ = 0.524), so approximately 52% of samples pass. The expected iteration count is 1.91, costing two random calls plus one length calculation. This is cheaper than computing spherical coordinates with trigonometry.

### Rotation Axis

**Scene.cpp:408-409**

```cpp
Particles[idx].RotationAxis = D3DXVECTOR3(
  rand() / (float)RAND_MAX - 0.5f,
  rand() / (float)RAND_MAX - 0.5f,
  rand() / (float)RAND_MAX - 0.5f);
D3DXVec3Normalize(&Particles[idx].RotationAxis, &Particles[idx].RotationAxis);
```

Each particle gets a random rotation axis for 3D spinning. This vector, combined with rotation angle and rotation speed, defines an axis-angle rotation. The normalization ensures consistent angular velocity regardless of the initial random distribution. Without normalization, particles with longer random vectors would spin faster due to quaternion construction.

### Inner Radius Adjustment

**Scene.cpp:411-424**

```cpp
D3DXVECTOR3 outerboundarypos;
D3DXVECTOR3 originalpos = Particles[idx].Position;

float originallength = D3DXVec3Length(&originalpos);

float poslength = max(max(fabs(originalpos.x), fabs(originalpos.y)),
                       fabs(originalpos.z));  // cube adjust ratio
if (EmitterType == 1)
  poslength = originallength;  // sphere adjust ratio
outerboundarypos = originalpos * 0.5f / poslength;

float outerlength = D3DXVec3Length(&outerboundarypos);
float r = lerp(InnerRadius / 255.0f, 1, originallength / outerlength);

Particles[idx].Position = outerboundarypos * r;
```

This block implements the inner radius hollowing. The original position lies somewhere inside the emitter volume. The code finds the point on the outer boundary in the same direction. For boxes, the boundary is defined by the maximum absolute coordinate (the cube face). For spheres, the boundary is at the surface (distance 0.5 from center). Then it interpolates between the inner and outer radius based on the original position's relative distance.

Here's the geometric insight: imagine a point at 60% of the way from center to boundary. With InnerRadius = 128 (50%), the lerp maps this 60% position to a position between 50% and 100% of the outer radius. The mapping preserves radial distribution while excluding the inner core. Points that spawned near the center get pushed outward to the inner boundary. Points that spawned near the outer boundary remain near the outer boundary. The distribution stays uniform in the annular region.

### World Space Transformation

**Scene.cpp:428-432**

```cpp
D3DXVECTOR4 va, vb, vc;
D3DXVec3Transform(&va, &Particles[idx].Position, &m);
D3DXVec3Transform(&vb, &Particles[idx].Position, &o);
D3DXVec4Lerp(&vc, &vb, &va, 1 - mt);
Particles[idx].Position = D3DXVECTOR3(vc);
```

Transform the local position into world space using the emitter's current matrix `m` and previous frame's matrix `o`. Then interpolate between them based on `mt`, the fractional spawn time within this frame (0.0 = spawned at frame start, 1.0 = spawned at frame end). This interpolation eliminates visible gaps when emitters move fast. Without it, all particles spawned in a frame would appear at the same location, creating a stuttering trail. With it, particles spawn continuously along the emitter's path.

The interpolation direction might seem backwards: `lerp(previous, current, 1 - mt)`. At mt = 0 (spawning early in the frame), the particle should be closer to the previous position because more time has passed since the previous frame. At mt = 1 (spawning at frame end), the particle should be at the current position because it just spawned. The `1 - mt` inverts the direction to match this logic.

### Velocity Calculation

**Scene.cpp:434-440**

```cpp
if (!Target)
{
  outerboundarypos = D3DXVECTOR3(
    rand() / (float)RAND_MAX - 0.5f,
    rand() / (float)RAND_MAX - 0.5f,
    rand() / (float)RAND_MAX - 0.5f);
  D3DXVec3Normalize(&TargetDirection, &outerboundarypos);
}

Particles[idx].Velocity = TargetDirection * 0.01f *
  (SplineResults[Spline_Particle_EmissionVelocity] +
   (rand() / (float)RAND_MAX) *
   SplineResults[Spline_Particle_EmissionVelocityChaos]);
```

Velocity direction comes from the target system. If the emitter targets another object, `TargetDirection` is already calculated (the normalized vector from emitter to target). If no target exists, generate a random direction uniformly distributed on a sphere using rejection sampling (same technique as position, reusing the `outerboundarypos` variable).

The velocity magnitude is the emission velocity spline plus random chaos, scaled by 0.01 for reasonable world-space units. At velocity 1.0, particles move 0.01 units per tick. At 25 FPS, that's 0.25 units per second. The chaos allows variation: base velocity 1.0 with chaos 0.5 gives velocities between 1.0 and 1.5.

### Rotation and Scale Parameters

**Scene.cpp:441-446**

```cpp
Particles[idx].RotationSpeed =
  SplineResults[Spline_Particle_EmissionRotation] +
  (rand() / (float)RAND_MAX) *
  SplineResults[Spline_Particle_EmissionRotationChaos];
if (rand() > RAND_MAX / 2 && TwoDirRotate)
  Particles[idx].RotationSpeed *= -1;

Particles[idx].ScaleChaos = max(0,
  1 + ((rand() / (float)RAND_MAX) * 2 - 1) *
  SplineResults[Spline_Particle_ScaleChaos]);
Particles[idx].Scale =
  SplineResults[Spline_Particle_Scale] * Particles[idx].ScaleChaos;
Particles[idx].StretchX =
  SplineResults[Spline_Particle_Stretch_X] * Particles[idx].Scale;
Particles[idx].StretchY =
  SplineResults[Spline_Particle_Stretch_Y] * Particles[idx].Scale;
```

Rotation speed comes from the emission rotation spline plus chaos. The `TwoDirRotate` flag randomly negates the rotation speed, creating bidirectional spinning. Without this, all particles rotate in the same direction, looking uniform. With it, half spin clockwise, half counterclockwise, adding visual variety.

Scale chaos is centered around 1.0. The formula `1 + (random * 2 - 1) * chaos` produces values from `1 - chaos` to `1 + chaos`. If chaos is 0.5, scales range from 0.5 to 1.5. The `max(0, ...)` clamps negative values to zero, preventing inverted particles. The base scale multiplies by the chaos factor, then stretch parameters apply per-axis scaling.

The distinction between scale and stretch is important. Scale is uniform (multiply all axes). Stretch is directional (stretch along X and Y independently). This separation enables elliptical particles and motion-blur effects (stretch along velocity direction).

### Initial Position Interpolation

**Scene.cpp:448-452**

```cpp
Particles[idx].Position += Particles[idx].Velocity * t;
Particles[idx].Rotation = Particles[idx].RotationSpeed * t;
if (RandRotate)
  Particles[idx].Rotation = (rand() / (float)RAND_MAX) * 360.0f;
Particles[idx].Chaos = rand() / (float)RAND_MAX;
```

The final step advances the particle's position and rotation by the fractional spawn time `t` (same as `mt` earlier). This ensures particles spawned mid-frame appear at their correct interpolated state, not at their birth location. Without this offset, particles would all spawn at position zero velocity zero, creating a visible cluster at the emitter center for one frame before moving outward.

If `RandRotate` is enabled, override the interpolated rotation with a completely random angle. This creates particles with random orientations at birth, useful for explosion debris or scattered foliage where uniform initial rotation looks artificial.

The `Chaos` value is a per-particle random seed used by shaders for additional variation. Some effects vary color or opacity based on this value, ensuring no two particles look identical even with the same lifetime and scale.

## Emitter Shape Geometry

Phoenix supports two shape primitives: box and sphere. These cover the majority of emission patterns. Box emitters create area fills, rectangular volumes, and directional sprays. Sphere emitters create omnidirectional bursts, volumetric clouds, and radial explosions. Complex shapes (cones, cylinders, toruses, mesh surfaces) can be approximated by combining multiple emitters or using child objects as spawn points.

### Box Shape (EmitterType = 0)

The box spans from -0.5 to +0.5 on all axes, a unit cube centered at the origin. Particles spawn uniformly within this volume using `rand() - 0.5` for each coordinate. The inner radius parameter shrinks the inner boundary toward the outer boundary, creating a hollow rectangular shell. At InnerRadius = 0, particles spawn anywhere in the volume. At InnerRadius = 255, particles spawn on the surface faces only.

The box shape's simplicity makes it computationally cheap: three random numbers, no rejection sampling, no trigonometry. The uniform distribution is exact, not approximate. The cache-friendly sequential access pattern (three consecutive random calls) keeps the random number generator's internal state hot.

Box emitters are ideal for:
- Ground-based effects (grass, dust, sparks) where particles fill a flat area
- Volume fills (fog, smoke, clouds) where particles populate a 3D region
- Directional streams (waterfalls, laser beams) stretched along one axis

### Sphere Shape (EmitterType = 1)

The sphere has radius 0.5 (diameter 1.0), centered at the origin. Particles spawn uniformly within the volume using rejection sampling: generate a random point in the enclosing cube, reject if length exceeds the radius. The inner radius parameter creates a spherical shell by interpolating between inner and outer surfaces. At InnerRadius = 0, particles spawn anywhere in the volume. At InnerRadius = 255, particles spawn on the surface only.

Rejection sampling ensures uniform distribution, critical for realistic sphere fills. Naive spherical coordinates (θ, φ) cluster particles near poles due to the non-uniform area element in spherical space. Rejection sampling in Cartesian space avoids this clustering at the cost of wasted random samples (approximately 48% rejected for a sphere inscribed in a cube).

The implementation's efficiency comes from two optimizations:
1. Compare length squared instead of length to avoid the square root
2. Use compile-time constant 0.25 (0.5²) for the rejection test

Sphere emitters are ideal for:
- Explosions and bursts where particles radiate from a point
- Volumetric clouds where particles float in all directions
- Omnidirectional emissions (fireflies, stars, magic auras)

## Emission Parameters: Spline-Driven Birth

Every aspect of emission timing and particle initialization comes from spline animation. This decouples spawn logic from timeline control. The spawn function reads current values from `SplineResults`, which get updated during scene traversal. Changing emission rate mid-flight requires no special code. Just animate the spline. The next frame's spawn calculation uses the new value.

### Emission Rate and Triggering

**Scene.h:69-70**

```cpp
Spline_Particle_EmissionPerSecond = 40,
Spline_Particle_EmissionTrigger = 41,
```

`EmissionPerSecond` controls continuous spawning. At 25 particles/second with 25 FPS, spawn one particle per frame. At 250 particles/second, spawn 10 per frame. The emission system uses fractional accumulation to handle non-integer rates smoothly.

`EmissionTrigger` implements burst emission. When the spline value transitions from low to high, the system spawns a full batch of particles immediately. This is used for explosions, impacts, and other one-shot effects that need synchronized particle birth.

### Initial Motion

**Scene.h:74-76**

```cpp
Spline_Particle_EmissionVelocity = 42,
Spline_Particle_EmissionRotation = 44,
Spline_Particle_EmissionVelocityChaos = 45,
Spline_Particle_EmissionRotationChaos = 46,
```

Velocity determines how fast particles move away from the emitter. Rotation determines how fast they spin (degrees per frame). The chaos variants add per-particle randomness. Without chaos, all particles have identical initial conditions. With chaos, each particle varies within the specified range.

The separation between base value and chaos value enables two animation approaches:
- Animate the base value, keep chaos constant: emission pattern changes over time, but variance stays consistent
- Keep base value constant, animate chaos: pattern stays the same, but consistency varies

### Lifetime

**Scene.h:72, 76**

```cpp
Spline_Particle_Life = 43,
Spline_Particle_LifeChaos = 47,
```

Life determines how many seconds (converted to ticks) particles survive before dying. Short lifetimes create sparkler effects (particles vanish quickly). Long lifetimes create lingering effects (smoke, fog, trails). The chaos variant prevents synchronized death. Without chaos, particles spawned in the same frame die in the same frame, creating visible pulsing. With chaos, deaths spread over time, maintaining visual density.

### Position Offset

**Scene.h:66-68**

```cpp
Spline_Particle_Offset_x = 37,
Spline_Particle_Offset_y = 38,
Spline_Particle_Offset_z = 39,
```

These offsets apply to the emitter's world position before spawning particles. They enable moving spawn points without transforming the emitter object itself. This is useful for effects where the emitter object needs to stay at a fixed location for targeting purposes, but the actual particle source should move (torch flames that flicker, engines that wobble).

### Scale and Stretch

**Scene.h:82-86**

```cpp
Spline_Particle_Scale = 51,
Spline_Particle_ScaleChaos = 52,
Spline_Particle_Stretch_X = 53,
Spline_Particle_Stretch_Y = 54,
```

Initial scale applies uniformly to all particle axes. Stretch applies per-axis scaling on top of the base scale. This separation enables both uniform size variation (scale chaos) and directional stretching (stretch X/Y for motion blur or raindrop shapes).

Note that stretch uses two components, not three. Most particle effects use 2D billboards facing the camera. Stretching along the view direction (Z) would be invisible. The two-component stretch aligns with typical usage: X for horizontal stretch, Y for vertical stretch. Motion blur typically stretches along velocity direction, which can be computed in the shader from previous and current positions.

## ResetParticles: Initial Population

The reset function clears all particles and spawns an initial population, used when the demo starts or when transitioning between scenes.

**Scene.cpp:777-824**

```cpp
void CphxObject_ParticleEmitter_CPU::ResetParticles()
{
  objIdxMod = 0;
  D3DXMATRIX wm = GetWorldMatrix();
  currMatrix = prevMatrix = wm;

  memset(Particles, 0, sizeof(PHXPARTICLE) * (1 << BufferSize));
  int pcount = ((1 << BufferSize) * StartCount) / 255;
  srand(RandSeed);

  DEBUGLOG("Spawning %d particles", pcount);

  int objectcount = 1;
  #ifdef PHX_HAS_SCENE_OBJECT_HIERARCHIES
  for (int x = 0; x < Scene->ObjectCount; x++)
    if (Scene->Objects[x]->Parent == this)
      objectcount++;
  #endif

  D3DXMATRIX *matrices = new D3DXMATRIX[objectcount];
  D3DXMATRIX *oldmatrices = new D3DXMATRIX[objectcount];
  matrices[0] = currMatrix;
  oldmatrices[0] = prevMatrix;

  #ifdef PHX_HAS_SCENE_OBJECT_HIERARCHIES
  int cnt = 1;
  for (int x = 0; x < Scene->ObjectCount; x++)
    if (Scene->Objects[x]->Parent == this)
    {
      matrices[cnt] = Scene->Objects[x]->currMatrix;
      oldmatrices[cnt++] = Scene->Objects[x]->prevMatrix;
    }
  #endif

  for (int x = 0; x < pcount; x++)
  {
    int id = (objIdxMod++) % objectcount;
    SpawnParticle(0, matrices[id], oldmatrices[id], 0);
  }

  delete[] oldmatrices;
  delete[] matrices;

  Ticks = 0;

  UpdateParticles(0);
}
```

### Clearing State

The function starts by resetting the multi-object emission counter (`objIdxMod = 0`) and synchronizing current and previous matrices. Setting both matrices to the same value prevents motion interpolation during initial spawn. Particles spawn at the emitter's current location, not interpolated between two different positions.

The `memset` zero-fills the entire particle buffer. This sets all lifetimes to zero, marking every particle as dead. The subsequent spawn loop will find slots immediately without scanning occupied entries.

### Spawn Count Calculation

The `StartCount` field ranges from 0-255, representing a percentage of the buffer. The calculation `(bufferSize * StartCount) / 255` maps this percentage to an actual particle count. StartCount = 128 spawns half the buffer. StartCount = 255 spawns the full buffer. StartCount = 0 spawns nothing (useful for effects that only spawn during runtime, not at initialization).

Seeding the random number generator with `RandSeed` ensures deterministic particle placement. Different emitters can use different seeds, but the same emitter will produce identical initial patterns across runs. This reproducibility is critical for demos where timing synchronizes with music.

### Multi-Object Handling

If the emitter has child objects, each child becomes a spawn point. The function collects all child matrices into an array, then cycles through them during spawning using `objIdxMod % objectcount`. This distributes particles evenly across spawn points, creating complex patterns from simple hierarchies.

For example, an explosion emitter with eight child objects arranged in a circle creates an eight-pointed starburst. Each child spawns 1/8th of the particles, and their individual positions define the starburst arms. Without this multi-object support, you'd need eight separate emitter objects, multiplying the memory and update cost.

### Spawn Loop

The loop calls `SpawnParticle` for each initial particle, passing the fractional time as 0 (spawn at frame start) and the multi-object index. After spawning, it immediately calls `UpdateParticles(0)` to apply one frame of simulation. This ensures particles don't all sit at their birth positions. They start with slight variation from velocity and rotation, preventing the initial frame from looking like a static point cloud.

## Multi-Object Emission: Child Objects as Spawn Points

One of Phoenix's clever space-saving features is reusing the scene hierarchy for emission control. Instead of defining complex spawn patterns with additional data structures, you just parent dummy objects to the emitter. Each child becomes a spawn point.

**Scene.cpp:476-502**

```cpp
int objectcount = 1;
int affectorcount = 0;

#ifdef PHX_HAS_SCENE_OBJECT_HIERARCHIES
for (int x = 0; x < Scene->ObjectCount; x++)
{
  if (Scene->Objects[x]->Parent == this)
    objectcount++;
  if (Scene->Objects[x]->ObjectType == Object_ParticleGravity ||
      Scene->Objects[x]->ObjectType == Object_ParticleDrag ||
      Scene->Objects[x]->ObjectType == Object_ParticleTurbulence ||
      Scene->Objects[x]->ObjectType == Object_ParticleVortex)
    affectors[affectorcount++] = (CphxObject_ParticleAffector*)Scene->Objects[x];
}
#endif

D3DXMATRIX *matrices = new D3DXMATRIX[objectcount];
D3DXMATRIX *oldmatrices = new D3DXMATRIX[objectcount];
matrices[0] = currMatrix;
oldmatrices[0] = prevMatrix;

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

The update loop scans the scene's object list for children of this emitter, collecting their world matrices. The spawn logic then cycles through these matrices using the `objIdxMod` counter. Each spawned particle uses one matrix, distributing emission evenly.

This design means spawn patterns come from scene animation rather than custom emitter parameters. Want a spiral trail? Animate child objects in a spiral path. Want a ring explosion? Arrange child objects in a circle. Want a random scatter? Animate children with random motion splines. The emitter just distributes particles to whatever spawn points you provide.

The cost is minimal: one pointer comparison per scene object to check parentage, one matrix copy per child object. The benefit is infinite flexibility without expanding the emitter's data footprint. Complex multi-source effects require no new features. Just add hierarchy.

## Emission Spline Types

Phoenix dedicates 18 spline slots to particle emission parameters. These slots (37-54 in the global spline enumeration) define initial spawn conditions. Additional slots (51-54) control per-particle scaling and stretching.

| Spline Type | Slot | Range | Purpose |
|-------------|------|-------|---------|
| Offset_x/y/z | 37-39 | Any | Position offset before transform |
| EmissionPerSecond | 40 | 0-∞ | Continuous spawn rate |
| EmissionTrigger | 41 | 0/1 | Burst spawn on edge |
| EmissionVelocity | 42 | 0-∞ | Initial speed magnitude |
| Life | 43 | 0-∞ seconds | Particle lifetime |
| EmissionRotation | 44 | -∞-∞ degrees/frame | Initial spin rate |
| EmissionVelocityChaos | 45 | 0-∞ | Random velocity variance |
| EmissionRotationChaos | 46 | 0-∞ | Random rotation variance |
| LifeChaos | 47 | 0-∞ seconds | Random lifetime variance |
| Scale | 51 | 0-∞ | Uniform base scale |
| ScaleChaos | 52 | 0-1 | Random scale variance |
| Stretch_X | 53 | 0-∞ | Horizontal stretch factor |
| Stretch_Y | 54 | 0-∞ | Vertical stretch factor |

Note that chaos parameters are additive (velocity chaos, life chaos) or multiplicative (scale chaos), allowing intuitive percentage-based variation. Velocity chaos of 1.0 adds ±1.0 to the base velocity. Scale chaos of 0.5 scales between 0.5× and 1.5× the base scale.

The default values (Scene.cpp:287-294) ensure reasonable behavior even without spline animation:
- EmissionPerSecond = 25 (one particle per frame at 25 FPS)
- EmissionVelocity = 1.0 (moderate speed)
- Life = 10 (10 seconds, 250 frames)
- Scale = 1.0 (unit size)
- Stretch X/Y = 1.0 (square particles)

These defaults mean you can create a basic emitter by just setting BufferSize and EmitterType. Everything else works out of the box.

## Shape Comparison: Box vs. Sphere

| Aspect | Box (Type 0) | Sphere (Type 1) |
|--------|--------------|----------------|
| **Position sampling** | Direct random [-0.5, +0.5]³ | Rejection sampling in cube |
| **Sample efficiency** | 100% (all samples valid) | ~52% (sphere volume / cube volume) |
| **Computation cost** | 3 random calls | 3 random calls + rejection loop + length² |
| **Distribution** | Uniform in volume | Uniform in volume (when rejection sampling) |
| **Inner radius shape** | Hollow rectangular shell | Hollow spherical shell |
| **Surface emission** | 6 faces (anisotropic) | Spherical surface (isotropic) |
| **Directional bias** | None (uniform) | None (uniform) |
| **Use cases** | Area fills, rectangular volumes, flat sprays | Bursts, omnidirectional emission, volume clouds |

The key difference is isotropy. Sphere emitters look the same from all viewing angles. Box emitters reveal their rectangular structure unless you apply rotation. For effects that should feel volumetric and direction-agnostic (explosions, magic auras), use spheres. For effects tied to world axes or surfaces (rain, grass, laser beams), use boxes.

## Implications for Rust Creative Coding Frameworks

Phoenix's particle emitter design offers several lessons for modern framework development:

### 1. Fixed-Size Buffers with Slot Reuse

Modern frameworks often use entity pools or free lists for particle management. Phoenix proves that linear scanning can be competitive for small-to-medium buffer sizes (< 2048 particles). The simplicity of a single contiguous array beats the complexity of linked structures until buffer sizes exceed L3 cache capacity. Consider linear scan as the default, falling back to free lists only when profiling shows a bottleneck.

Rust implementation: `Vec<Particle>` with a scan for dead particles. Use `Particle::default()` to represent dead particles (LifeLeft = 0). The scan becomes `particles.iter_mut().find(|p| p.is_dead())`. No separate free list, no unsafe pointers, no lifetime complexity.

### 2. Fractional Accumulation for Emission Timing

The emission accumulator pattern (add fractional particles per frame, spawn when accumulator >= 1.0) generalizes to any event timing system. Rust's type system can enforce correctness: `struct EmissionAccumulator { fraction: f32 }` with methods that guarantee `0.0 <= fraction < 1.0`. The spawn logic becomes a simple while loop: `while self.fraction >= 1.0 { spawn(); self.fraction -= 1.0; }`.

### 3. Spline-Driven Parameter Initialization

Separating spawn logic from animation data makes emitters reusable. The same spawn algorithm works for fire, smoke, sparks, and magic by changing spline curves. In Rust, this becomes a `SpawnConfig` struct populated from keyframe animation:

```rust
struct SpawnConfig {
    emission_rate: f32,
    velocity: f32,
    velocity_chaos: f32,
    life: f32,
    life_chaos: f32,
    // ... other parameters
}

impl EmitterState {
    fn spawn(&mut self, config: &SpawnConfig, time: f32) {
        // Use config values for initialization
    }
}
```

The emitter never hardcodes parameters. All values come from external configuration, animated or static.

### 4. Shape Sampling as Pluggable Strategy

The box/sphere distinction suggests a trait-based design for emission shapes:

```rust
trait EmissionShape {
    fn sample(&self, rng: &mut impl Rng) -> Vec3;
    fn inner_radius_adjust(&self, position: Vec3, inner_radius: f32) -> Vec3;
}

struct BoxShape;
struct SphereShape;
struct ConeShape;
struct MeshSurfaceShape { mesh: &Mesh };

impl EmissionShape for BoxShape { /* ... */ }
impl EmissionShape for SphereShape { /* ... */ }
```

Users can implement custom shapes without modifying emitter code. The emitter just calls `shape.sample(&mut rng)` and trusts the shape to return a valid local-space position.

### 5. Multi-Object Emission via Scene Hierarchy

Reusing the scene graph for spawn points eliminates the need for custom spawn pattern data structures. Rust's ownership system makes this tricky (emitter can't hold mutable references to child objects during update). Solutions:
- Pass child transforms as a slice: `spawn_with_transforms(&mut self, transforms: &[Matrix4])`
- Use indices: store child object IDs, look up transforms during spawn
- Use an ECS: query for `(Transform, ParentEmitter)` components

The ECS approach fits Rust's borrow checker naturally: systems iterate over queries, not object references.

### 6. Interpolation for Motion Blur

The current/previous matrix interpolation prevents visual gaps during fast emitter motion. Every moving object should store previous-frame transforms. Rust can enforce this with a `TransformHistory` component:

```rust
struct TransformHistory {
    current: Matrix4,
    previous: Matrix4,
}

impl TransformHistory {
    fn lerp(&self, t: f32) -> Matrix4 {
        self.previous.lerp(self.current, t)
    }
}
```

Systems that spawn or render moving particles can require this component in their queries, making interpolation opt-in but type-safe.

### 7. Chaos Parameters for Variation

The base-value-plus-chaos pattern prevents uniform repetition. Every spawn parameter should have an optional chaos variant. Rust can encode this with `Option<f32>` or a dedicated `Chaotic<T>` type:

```rust
struct Chaotic<T> {
    base: T,
    chaos: T,
}

impl Chaotic<f32> {
    fn sample(&self, rng: &mut impl Rng) -> f32 {
        self.base + rng.gen::<f32>() * self.chaos
    }
}
```

The type makes it explicit which parameters support variation and encapsulates the sampling logic.

### 8. Inner Radius for Hollow Shapes

The single-parameter inner radius control generalizes to any shape. Instead of separate "hollow box" and "hollow sphere" types, have one `inner_radius: f32` field that every shape interprets. For cones, it creates an annular cone (inner and outer cones). For cylinders, it creates a tube. For meshes, it scales distance from the barycentric center.

Rust implementation: add `inner_radius` to the `EmissionShape` trait and let each shape decide how to apply it. Default implementation (no inner radius) just returns the sampled position unchanged.

## Conclusion

Phoenix's particle emitters balance simplicity with expressiveness. The spawn algorithm is straightforward: find a slot, randomize parameters from splines, transform to world space. The shape system uses elementary geometry: boxes and spheres with rejection sampling. The emission timing uses fractional accumulation and interpolation. Yet these simple building blocks combine to create complex effects through animation and hierarchy.

The design constraints (fixed buffer size, power-of-two counts, two shape types) eliminate entire classes of edge cases. No dynamic allocation means no out-of-memory failures. No complex shapes means no degenerate geometry cases. No arbitrary emission rates means smooth fractional accumulation without floating-point drift. The constraints enable aggressive optimization: cache-friendly array scans, compile-time constants, direct memory access without indirection.

For framework designers, the lesson is that constraints can be liberating. Instead of supporting every possible feature, support a small set of composable primitives. Instead of making everything configurable, provide good defaults and let animation drive variation. Instead of adding special cases, compose existing systems (hierarchy for spawn points, splines for animation, materials for rendering). The result is less code, fewer bugs, and more expressive power than feature-checklist-driven design.

## References

**Primary Source Files:**
- `demoscene/apex-public/apEx/Phoenix/Scene.h` (lines 250-305) — CphxObject_ParticleEmitter_CPU class definition
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp` (lines 374-453) — SpawnParticle implementation
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp` (lines 777-824) — ResetParticles implementation
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp` (lines 463-606) — UpdateParticles simulation loop

**Related Documentation:**
- `notes/per-demoscene/apex-public/scene/objects.md` — Base CphxObject and type system
- `notes/per-demoscene/apex-public/spline/overview.md` — Spline animation system
- To be written: `particles/simulation.md` — Particle aging and affector forces
- To be written: `particles/rendering.md` — Vertex buffer updates and billboard rendering
