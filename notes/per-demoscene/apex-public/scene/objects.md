# Phoenix Scene Objects

> Building blocks of animation: 12 object types, all sharing spline-driven transforms

When you think of scene graphs, you might picture game engines with elaborate component systems. Objects might have mesh renderers, colliders, audio sources, and script components all attached dynamically. Phoenix takes a different approach. Each object has a fixed type determined at creation. Once you're a light, you're always a light. Once you're a particle emitter, you're always a particle emitter. No runtime polymorphism beyond virtual dispatch. No component soup. Just 12 distinct object types, each with specialized behavior but all sharing a common foundation of hierarchical transforms and spline animation.

This design constraint forces clarity. You can't attach arbitrary behaviors to objects because there's no attachment mechanism. Instead, functionality is baked into type-specific subclasses. Models render geometry. Lights contribute to the lighting array. Particle emitters simulate and render particle systems. Camera eyes define view frustums. Dummies exist purely for hierarchical grouping. Each type knows exactly what it does, and that knowledge lives in its `CreateRenderDataInstances()` implementation.

The genius of this system is how it balances flexibility with simplicity. All objects share the same animation and transform infrastructure. Position, rotation, scale, and target tracking work identically whether you're animating a light or a spaceship model. The 57-element `SplineResults` array holds animated values for every possible parameter. Objects only read the values they care about. A camera extracts FOV and roll. A particle emitter reads emission rate and velocity. The infrastructure is shared. The interpretation is specialized.

Think of scene objects like actors in a play. Everyone follows the same blocking and timing system, receiving direction from the same script. But when the spotlight hits, each actor performs their unique role. The lead actor delivers dialogue, the lighting technician adjusts spots, the stagehands move props. During traversal, every object gets the same treatment: evaluate animation, accumulate transforms, call into specialized behavior. During rendering, each type reveals its distinct purpose.

Why does this matter for creative coding frameworks? Because it illustrates a fundamental trade-off between runtime flexibility and code simplicity. Modern game engines prioritize the former: entity-component systems let you compose behaviors dynamically. Phoenix prioritizes the latter: fixed types with virtual dispatch. Both are valid. The choice depends on your constraints. When executable size matters more than design-time flexibility, Phoenix's approach wins.

## The Challenge: One Base Class, Many Behaviors

The scene graph needs to support wildly different objects. Rendering a mesh requires vertex buffers, materials, and transformation matrices. Simulating a particle system requires position arrays, velocity updates, and affector queries. Defining a camera requires FOV, projection matrix construction, and target tracking. How do you unify these behaviors without bloating every object with unused fields?

Phoenix's solution is classical object-oriented design: a base class with virtual methods and type-specific subclasses. The `CphxObject` base class (Scene.h:139-197) contains all shared data: parent/child links, animation results, transformation matrices, target pointers. Subclasses add type-specific fields: models hold mesh pointers, particle emitters hold particle arrays, subscenes hold clip indices.

The key virtual method is `CreateRenderDataInstances()`. During scene traversal, every object's base class evaluates animation, accumulates transforms, and calls this virtual method. Most object types do nothing: lights and cameras don't create render instances, they just update shared state. Model objects delegate to their mesh, which expands materials into render instances. Particle emitters update simulation, build vertex buffers, and create instances for their material. Subscenes recursively traverse their own scene graph.

This design keeps the traversal logic simple. One recursive function handles all object types. Type-specific behavior happens through virtual dispatch, not conditional branching. The code doesn't check "if model, do X; if light, do Y." It just calls `CreateRenderDataInstances()` and trusts polymorphism to invoke the right implementation.

## Base CphxObject: Shared Infrastructure

Every object inherits from `CphxObject`, which provides the common plumbing for scene graph membership, animation evaluation, and hierarchical transformation.

### Scene Graph Links

**Scene.h:144-149**

```cpp
class CphxScene *Scene;
class CphxScene *SubSceneTarget;

CphxObject *Parent;
int ChildCount;
CphxObject **Children;
```

The `Scene` pointer identifies which scene owns this object. The `Parent` and `Children` pointers form the hierarchy tree. Each object knows its parent and maintains an array of child pointers. This structure supports standard depth-first traversal: visit object, recurse to children, accumulate transforms down the tree.

The `SubSceneTarget` pointer is used by subscene objects to reference the scene they instantiate. Most objects leave this NULL. Subscene objects set it from their clip animation data, allowing one scene to recursively embed another.

### Animation Storage

**Scene.h:152-154**

```cpp
float SplineResults[Spline_Count];  // 57 elements, Scene.h:17-91
D3DXQUATERNION RotationResult;
D3DXVECTOR3 TargetDirection;
```

The `SplineResults` array is the heart of animation. Every frame, `CalculateAnimation()` evaluates all splines attached to this object and stores results in this array. The array has 57 slots, covering every possible animatable parameter: position (x/y/z/w), scale (x/y/z), rotation quaternion, light colors (ambient/diffuse/specular RGB), camera FOV and roll, particle emission parameters, material properties, and more.

Not all slots are used by all objects. A light reads position and color slots. A camera reads FOV and roll. A particle emitter reads emission rate, velocity, and life. The unused slots just sit there, wasting a few bytes per object. In a size-optimized engine, this might seem wasteful. But the alternative is dynamic allocation or per-type arrays, both of which cost more code bytes than the memory waste.

The `RotationResult` stores the evaluated quaternion separately because rotation splines need special handling. Instead of animating four quaternion components independently, rotation splines interpolate through 3D rotation space using Catmull-Rom basis. The evaluated quaternion applies directly to transformation matrix construction.

The `TargetDirection` vector stores the normalized direction from this object to its target object (if it has one). This is calculated after scene traversal completes. Lights use it for spotlight direction. Cameras use it for look-at rotation. Particle emitters use it for initial emission direction.

### Transformation Matrices

**Scene.h:180-182**

```cpp
D3DXMATRIX currMatrix;
D3DXMATRIX prevMatrix;
D3DXMATRIX inverse;
```

The `currMatrix` holds this object's final world transformation after hierarchy accumulation. The `prevMatrix` holds the previous frame's transformation, enabling motion blur and velocity-based effects. Shaders can sample both matrices to compute per-vertex velocity vectors.

The `inverse` matrix is only used by particle affectors (gravity, drag, turbulence, vortex). Affectors need to transform particle positions from world space into local space to determine if a particle is inside their area of effect. Rather than computing inverses every frame during particle update, the engine calculates them once after scene traversal (Scene.cpp:80-89) and caches the result.

### Target System

**Scene.h:176-177**

```cpp
CphxObject *Target;
int TargetID;
```

Objects can link to other objects as targets. Lights target the object they illuminate for spotlight direction. Cameras target the object they look at for automatic framing. Particle emitters target the object they shoot particles toward.

The `Target` pointer is resolved from `TargetID` during minimal import deserialization. The target direction calculation happens after traversal:

**Scene.cpp:62-73**

```cpp
for (int x = 0; x < ObjectCount; x++)
{
  CphxObject *o = Objects[x];
  if (o->Target)
  {
    o->TargetDirection = o->Target->WorldPosition - o->WorldPosition;
    D3DXVec3Normalize(&o->TargetDirection, &o->TargetDirection);
    o->SplineResults[Spot_Direction_X] = o->TargetDirection.x;
    o->SplineResults[Spot_Direction_Y] = o->TargetDirection.y;
    o->SplineResults[Spot_Direction_Z] = o->TargetDirection.z;
  }
}
```

The calculated direction overwrites the spot direction spline results. This means explicit spline animation of spotlight direction is ignored if a target is set. The target always wins.

### Camera-Specific Fields

**Scene.h:171-173**

```cpp
char camCenterX;
char camCenterY;
CphxRenderTarget* cameraCubeMapTarget;
```

Camera objects use these fields for off-center projection matrices and cubemap rendering. The `camCenterX` and `camCenterY` values shift the projection frustum, useful for stereoscopic rendering or tiled projections.

Interestingly, these same fields are repurposed for logic objects. The `camCenterX` stores the logic object type, and `camCenterY` stores its data. This field reuse saves a few bytes per object. Since cameras and logic objects are mutually exclusive types, the fields never conflict.

The `cameraCubeMapTarget` points to a cubemap render target when this camera renders to a cube texture (for environment mapping). This is only set when the camera's render layer uses cubemap mode.

### Clip Data

**Scene.h:159**

```cpp
CphxObjectClip **Clips;
```

Objects can have multiple animation clips, analogous to animation states in game engines. A spaceship might have an "idle" clip with gentle floating animation and an "attack" clip with aggressive maneuvers. The current clip determines which splines are active.

Each clip contains:

**Scene.h:121-129**

```cpp
struct CphxObjectClip
{
  class CphxScene *SubSceneTarget;
  unsigned char RandSeed;
  unsigned char TurbulenceFrequency;
  int SplineCount;
  CphxClipSpline **Splines;
  CphxMaterialSplineBatch *MaterialSplines;
};
```

The `SubSceneTarget` is only used by subscene objects. The `RandSeed` is only used by turbulence affectors to initialize their noise kernel. The `TurbulenceFrequency` scales the noise sampling. The `Splines` array contains all animation curves for this clip, and `MaterialSplines` contains curves that animate material parameters.

### Key Methods

**Scene.h:184-186**

```cpp
virtual void CreateRenderDataInstances(int Clip, const D3DXMATRIX &m,
                                       CphxScene *RootScene, void *SubSceneData);
void TraverseSceneGraph(int Clip, float t, D3DXMATRIX CurrentMatrix,
                        CphxScene *RootScene, void *SubSceneData);
void CalculateAnimation(int Clip, float t);
```

`TraverseSceneGraph()` is the main recursion entry point. It calls `CalculateAnimation()` to evaluate splines, builds the local transformation matrix, multiplies against the parent's accumulated matrix, calls `CreateRenderDataInstances()` for type-specific behavior, and finally recurses to children.

`CalculateAnimation()` sets default values for all spline slots, then iterates through the clip's splines, evaluating each at time `t` and storing results in `SplineResults`. Material splines are evaluated separately through `MaterialSplines->CalculateValues()`.

`CreateRenderDataInstances()` is the virtual hook for type-specific rendering behavior. The base class implementation is empty. Subclasses override it to create render instances, update particle systems, or recursively traverse subscenes.

## Object_Model: Geometry Rendering

Models are the simplest specialized object type. They exist solely to bridge the object system and the model/material system.

**Scene.h:199-213**

```cpp
class CphxObject_Model : public CphxObject
{
public:
  CphxModel *Model;

  virtual void CreateRenderDataInstances(int Clip, const D3DXMATRIX &m,
                                         CphxScene *RootScene, void *SubSceneData);
};
```

The single `Model` pointer references a `CphxModel` instance containing mesh data, materials, and object-indexed geometry. The implementation is trivial:

**Scene.cpp:330-335**

```cpp
void CphxObject_Model::CreateRenderDataInstances(int Clip, const D3DXMATRIX &m,
                                                 CphxScene *RootScene, void *SubSceneData)
{
  Model->CreateRenderDataInstances(Clips[Clip], m, RootScene,
                                   SubSceneData ? SubSceneData : ToolData);
}
```

All the real work happens in `CphxModel::CreateRenderDataInstances()`, which calculates inverse-transpose matrices, applies animated material parameters, and expands materials into per-pass render instances. The object is just a scene graph node that delegates to the model system.

This separation is important. Models can be shared between multiple objects. Two spaceship objects can reference the same mesh data but render at different positions with different materials. The object provides transformation and animation. The model provides geometry and rendering.

## Object_Light: Scene Illumination

Light objects don't create render instances. Instead, they contribute to a global light array that's uploaded to shaders.

Lights use the base `CphxObject` class without a specialized subclass. Their type is identified by `ObjectType == Object_Light`. All light parameters come from spline results.

### Light Data Structure

**Scene.h:131-137**

```cpp
struct LIGHTDATA
{
  D3DXVECTOR4 Position;
  D3DXVECTOR4 Ambient, Diffuse, Specular;
  D3DXVECTOR4 SpotDirection;
  D3DXVECTOR4 SpotData;  // exponent, cutoff, linear and quadratic attenuations
};
```

This structure maps directly to the fixed-function lighting model from OpenGL/DirectX 9 era. Each light has ambient, diffuse, and specular color contributions. Spotlights have a direction, cone exponent, cutoff angle, and distance attenuation factors.

### Light Collection

Lights are collected after scene traversal completes:

**Scene.cpp:101-133**

```cpp
void CphxScene::CollectLights(CphxScene* sceneToCollectFrom)
{
  for (int x = 0; x < sceneToCollectFrom->ObjectCount; x++)
  {
    if (LightCount >= 8)
      return;

    CphxObject* object = sceneToCollectFrom->Objects[x];

    if (object->ObjectType == Object_Light)
    {
      memcpy(&Lights[LightCount], &object->SplineResults[Spline_Position_x],
             sizeof(LIGHTDATA));

      if (object->SplineResults[Spline_Position_w] != 0)
      {
        Lights[LightCount].Position.x = object->WorldPosition.x;
        Lights[LightCount].Position.y = object->WorldPosition.y;
        Lights[LightCount].Position.z = object->WorldPosition.z;
      }
      else
      {
        Lights[LightCount].SpotDirection.x = object->WorldPosition.x;
        Lights[LightCount].SpotDirection.y = object->WorldPosition.y;
        Lights[LightCount].SpotDirection.z = object->WorldPosition.z;
        Lights[LightCount].Ambient.w = object->SplineResults[Spline_Light_OrthoX];
        Lights[LightCount].Diffuse.w = object->SplineResults[Spline_Light_OrthoY];
      }
      LightCount++;
    }
  }
}
```

The code copies the entire `LIGHTDATA` structure from spline results using `memcpy`. This works because the spline slots are carefully laid out to match the structure's memory layout. `Spline_Position_x` through `Spline_Light_Attenuation_Quadratic` occupy contiguous array slots that match the `LIGHTDATA` fields.

### Directional vs Point Lights

The `Spline_Position_w` component determines light type. When non-zero, it's a point light. The `Position` field uses the object's world position, transforming the light through the scene hierarchy.

When `Position.w == 0`, it's a directional light. Directional lights have no position, only direction. The code stores the world position in `SpotDirection` instead. This reuses the spotlight direction field for directional light direction. The shader can distinguish them by checking `Position.w`.

The `Ambient.w` and `Diffuse.w` fields are also repurposed for directional lights, storing orthographic projection dimensions (`OrthoX` and `OrthoY`). These are used when rendering shadow maps with orthographic projection, common for directional lights where parallel projection matches the light's infinite distance.

### Light Limit

Phoenix supports a maximum of 8 lights per scene. This is hardcoded in `MAX_LIGHT_COUNT`. The collection loop stops when it reaches 8 lights. If more lights exist, they're silently ignored.

This limit is common in real-time rendering. Fixed-size arrays avoid dynamic allocation and keep shader code simple. Eight lights is enough for most demo scenes: a key light, fill light, rim light, and a few accent lights for specific elements.

## Object_CamEye: View Frustum Definition

Camera objects define view frustums for rendering. Like lights, they use the base `CphxObject` without a specialized subclass.

Camera-specific parameters come from splines and special fields:

- `SplineResults[Spline_Camera_FOV]`: Field of view in degrees (default 1.0, Scene.cpp:286)
- `SplineResults[Spline_Camera_Roll]`: Camera roll rotation around the view direction (default 0)
- `camCenterX`: Horizontal projection center offset for off-center framing
- `camCenterY`: Vertical projection center offset for off-center framing
- `Target`: Optional look-at target object

The projection matrix construction happens in timeline code, using the camera's world position, target direction, FOV, and roll. The off-center projection shifts the frustum, useful for stereoscopic rendering where left and right eyes need asymmetric frusta.

The camera object doesn't create render instances. Its purpose is to provide transformation and animation for the camera's view matrix. The timeline extracts the camera's accumulated matrix and inverts it to form the view matrix.

## Object_Dummy: Pure Transform Node

Dummy objects exist solely for hierarchical grouping. They have no specialized behavior and don't create render instances.

**Scene.h:100** lists `Object_Dummy` as a type, but there's no subclass. Dummies use the base `CphxObject` class with `ObjectType == Object_Dummy`. The default `CreateRenderDataInstances()` implementation does nothing.

Why have explicit dummy objects? Because complex hierarchies need organizational structure. Imagine a mechanical arm with multiple joints. Each joint is a dummy object with rotation animation. The hand, fingers, and weapon are model objects parented to the appropriate joint dummies. Animating the arm's elbow joint automatically moves everything attached to it through hierarchy propagation.

Dummy objects also serve as animation targets. A camera might target a dummy that follows a complex path, allowing the camera's look-at direction to animate independently from its position.

## Object_SubScene: Recursive Scene Embedding

Subscenes instantiate complete scene graphs within other scenes, enabling reusable animation clips and complex hierarchical effects.

**Scene.h:215-229**

```cpp
class CphxObject_SubScene : public CphxObject
{
public:
  virtual void CreateRenderDataInstances(int Clip, const D3DXMATRIX &m,
                                         CphxScene *RootScene, void *SubSceneData);
};
```

The subclass has no additional fields because all subscene data lives in the clip:

**Scene.cpp:337-366**

```cpp
void CphxObject_SubScene::CreateRenderDataInstances(int Clip, const D3DXMATRIX &m,
                                                    CphxScene *RootScene, void *SubSceneData)
{
  D3DXMATRIX mtx = m;
  D3DXMATRIX prs;
  D3DXMatrixTransformation(&prs, NULL, NULL,
                           (D3DXVECTOR3*)&SplineResults[Spline_Scale_x],
                           NULL, &RotationResult,
                           (D3DXVECTOR3*)&SplineResults[Spline_Position_x]);

  int clipId = max(0, min(SubSceneTarget->ClipCount - 1,
                          (int)SplineResults[Spline_SubScene_Clip]));
  int repeatCount = max(1, (int)SplineResults[Spline_SubScene_RepeatCount]);
  float timeOffset = SplineResults[Spline_SubScene_RepeatTimeOffset];

  for (int x = 0; x < repeatCount; x++)
  {
    SubSceneTarget->UpdateSceneGraph(
      clipId,
      fabs(fmod(SplineResults[Spline_SubScene_Time] + timeOffset * x, 1.0f)),
      mtx, RootScene, SubSceneData ? SubSceneData : ToolData);

    D3DXMatrixMultiply(&mtx, &prs, &mtx);
  }

  RootScene->CollectLights(SubSceneTarget);
}
```

### Subscene Parameters

Three splines control subscene playback:

- `Spline_SubScene_Clip`: Which animation clip to play (integer index)
- `Spline_SubScene_Time`: Current time in clip, normalized 0-1 with wrapping via `fmod`
- `Spline_SubScene_RepeatCount`: Number of times to instantiate the subscene (default 1)
- `Spline_SubScene_RepeatTimeOffset`: Time offset between repeated instances

The repeat system enables particle-like effects without actual particles. A subscene containing a single petal can be repeated 20 times with time offsets to create a spiral of petals, each at a different animation phase. Each repeat multiplies the transformation matrix by the subscene's local PRS matrix, spacing instances in a pattern.

### Recursive Scene Traversal

The key line is the recursive `UpdateSceneGraph()` call. The subscene evaluates its own scene graph, including animation evaluation, hierarchy traversal, and render instance creation. Any objects in the subscene that create render instances add them to the root scene's render layers.

This recursion can nest arbitrarily deep. A subscene can contain subscene objects, which instantiate their own scenes, which might contain more subscenes. Phoenix doesn't protect against infinite recursion. A subscene that references itself would stack overflow. In practice, demo artists don't create cyclic subscene graphs.

### Light Collection

After processing the subscene, the code collects lights from it into the root scene's light array. This allows subscenes to contribute lighting. A "glowing portal" subscene might include animated lights that illuminate the surrounding scene.

## Object_ParticleEmitterCPU: CPU-Simulated Particles

Particle emitters are the most complex object type, simulating physics on the CPU and rendering particles as billboards or instanced meshes.

**Scene.h:250-305**

```cpp
class CphxObject_ParticleEmitter_CPU : public CphxObject
{
public:
  int objIdxMod;

  int LiveCount;
  PHXPARTICLE *Particles;
  PHXPARTICLEDISTANCE *DistanceBuffer;

  float EmissionFraction;
  float Ticks;
  bool Aging;
  bool RandRotate;
  bool TwoDirRotate;
  bool Sort;
  bool RotateToDirection;
  unsigned char BufferSize;  // 2^BufferSize particles

  unsigned char EmitterType;  // 0=box, 1=sphere
  unsigned char InnerRadius;
  unsigned char StartCount, RandSeed;

  // Standard particles (billboards)
  ID3D11Texture2D *SplineTexture;
  ID3D11ShaderResourceView *SplineTextureView;
  ID3D11Buffer* VertexBuffer;
  CphxMaterialPassConstantState **MaterialState;
  CphxMaterial *Material;

  // Mesh particles
  CphxModel *ObjectToEmit;

  // Subscene particles
  CphxScene *SceneToEmit;

  virtual void CreateRenderDataInstances(int Clip, const D3DXMATRIX &m,
                                         CphxScene *RootScene, void *SubSceneData);
  virtual void UpdateParticles(float elapsedtime, bool updatebuffer = true);
  void SpawnParticle(float t, D3DXMATRIX &mat, D3DXMATRIX &o, float mt);
  void UpdateSplineTexture();
  void ResetParticles();
};
```

### Particle Structure

Each particle is a complete physics entity:

**Scene.h:234-242**

```cpp
struct PHXPARTICLE
{
  D3DXVECTOR3 Position;
  D3DXVECTOR3 Velocity;
  float Rotation, RotationSpeed, Chaos, Scale, ScaleChaos, StretchX, StretchY;
  int MaxLife, LifeLeft;  // particle alive if LifeLeft > 0
  float RandSeed;
  D3DXVECTOR3 RotationAxis;
};
```

The particle array is allocated as `new PHXPARTICLE[1 << BufferSize]`, allowing 1, 2, 4, 8, ..., 256, 512, ... particles depending on `BufferSize`. This power-of-two sizing is common for particle systems because it simplifies indexing and memory alignment.

### Emission

Particles spawn based on the `Spline_Particle_EmissionPerSecond` parameter:

**Scene.cpp:524-535**

```cpp
if (SplineResults[Spline_Particle_EmissionPerSecond] > 0)
{
  int cnt = 1 + (int)((1 - fmod(EmissionFraction, 1.0f)) /
                      (PARTICLEENGINE_FRAMERATE /
                       (SplineResults[Spline_Particle_EmissionPerSecond] * objectcount)));
  int idx = 0;
  while (EmissionFraction < 1)
  {
    int id = (objIdxMod++) % objectcount;
    SpawnParticle(EmissionFraction - (int)EmissionFraction,
                  matrices[id], oldmatrices[id], idx / (float)cnt);
    EmissionFraction += PARTICLEENGINE_FRAMERATE /
                        (SplineResults[Spline_Particle_EmissionPerSecond] * objectcount);
    idx++;
  }
}
```

The code maintains a fractional emission counter. Each frame, it advances by the emission rate. When the counter crosses 1.0, a particle spawns. The fractional time is used to interpolate the particle's initial position between the emitter's old and current matrices, ensuring smooth emission without frame-rate dependence.

### Spawn Logic

**Scene.cpp:374-453** implements particle spawning:

1. Find a dead particle or the oldest living particle (least life remaining)
2. Initialize lifetime: `Life + rand() * LifeChaos` frames at 25 fps
3. Generate random position within emitter shape (box or sphere)
4. Adjust for `InnerRadius` by scaling position toward outer boundary
5. Transform position from local to world space
6. Initialize velocity toward `TargetDirection` with `EmissionVelocity + rand() * EmissionVelocityChaos`
7. Initialize rotation: `EmissionRotation + rand() * EmissionRotationChaos`
8. Initialize scale: `Scale * (1 + rand() * ScaleChaos)`
9. Interpolate position using fractional time for smooth subframe emission

The emitter shape logic is interesting. For box emitters, particles spawn uniformly in a [-0.5, 0.5] cube. For sphere emitters, particles spawn uniformly in a sphere of radius 0.5, rejecting positions until `length(pos) < 0.25` (radius 0.5 squared).

The inner radius creates a hollow emitter. A value of 128 (middle of the 0-255 range) creates a shell where particles only spawn near the outer surface. This is computed by lerping the random position toward the outer boundary:

```cpp
float r = lerp(InnerRadius / 255.0f, 1, originallength / outerlength);
Particles[idx].Position = outerboundarypos * r;
```

### Physics Update

**Scene.cpp:507-521** updates living particles each frame:

```cpp
for (int y = 0; y < particlecount; y++)
{
  if (Aging) Particles[y].LifeLeft -= 1;
  if (Particles[y].LifeLeft > 0)
  {
    // Update velocity based on affecting forces
    for (int x = 0; x < affectorcount; x++)
      if (affectors[x]->ParticleInside(Particles[y].Position))
        Particles[y].Velocity += affectors[x]->GetForce(&Particles[y]);

    // Update position and calculate collisions
    Particles[y].Position += Particles[y].Velocity;
    Particles[y].Rotation += Particles[y].RotationSpeed;
  }
}
```

The engine runs at 25 fps physics rate (PARTICLEENGINE_FRAMERATE = 25.0f). The `Ticks` accumulator converts elapsed time to simulation steps. Multiple physics steps can occur in one render frame if the game runs faster than 25 fps.

Affectors are collected from the scene's object list. Any object of type `Object_ParticleGravity`, `Object_ParticleDrag`, `Object_ParticleTurbulence`, or `Object_ParticleVortex` is considered an affector. Each frame, particles check if they're inside each affector's area and apply the resulting force to their velocity.

### Rendering Modes

Phoenix supports three particle rendering modes:

**Standard Particles**: Billboards rendered with a custom material. The vertex buffer contains particle positions and per-particle data. The material's shaders expand each particle to a quad facing the camera. Animated material parameters come from the spline texture.

**Mesh Particles**: Each particle spawns an instance of a specified model. The `ObjectToEmit` points to a `CphxModel`. During `CreateRenderDataInstances()`, the code iterates living particles and calls `ObjectToEmit->CreateRenderDataInstances()` for each, passing a transformation matrix built from the particle's position, rotation, and scale.

**Subscene Particles**: Each particle spawns an instance of a complete scene. The `SceneToEmit` points to a `CphxScene`. During rendering, the code calls `SceneToEmit->UpdateSceneGraph()` for each living particle, passing the particle's transformation matrix. This allows particles that are themselves animated scenes, like a flock of birds where each bird has its own wing flapping animation.

### Spline Texture System

Standard particles use a unique animation system. Material parameters can animate over particle lifetime, but evaluating splines per particle per frame is expensive. Instead, the engine bakes spline curves into a texture:

**Scene.cpp:729-774**

```cpp
void CphxObject_ParticleEmitter_CPU::UpdateSplineTexture()
{
  // Count splines marked as particle life animated
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

  // Create 2048×N texture (DXGI_FORMAT_R32_FLOAT)
  D3D11_TEXTURE2D_DESC tex = {2048, splinecnt, 1, 1, DXGI_FORMAT_R32_FLOAT,
                              1, 0, D3D11_USAGE_DEFAULT,
                              D3D11_BIND_SHADER_RESOURCE, 0, 0};
  D3D11_SUBRESOURCE_DATA data = {texturedata, 2048 * 4, 0};

  phxDev->CreateTexture2D(&tex, &data, &SplineTexture);
  phxDev->CreateShaderResourceView(SplineTexture, NULL, &SplineTextureView);
}
```

The particle shader samples this texture using the particle's lifetime as the U coordinate and the parameter index as the V coordinate. This converts per-particle curve evaluation into simple texture lookups. The 2048-sample resolution provides smooth interpolation without visible stepping.

Material parameters marked as `PARAM_PARTICLELIFEFLOAT` get baked into the texture. Other parameters use standard per-frame evaluation. This hybrid approach balances visual quality with performance: common parameters like opacity and scale animate smoothly per particle, while less critical parameters can use per-frame updates.

### Particle Sorting

**Scene.cpp:547-572** optionally sorts particles by depth:

```cpp
for (int y = 0; y < particlecount; y++)
{
  if (Particles[y].LifeLeft > 0)
  {
    DistanceBuffer[LiveCount].Idx = y;
    if (Sort)
      DistanceBuffer[LiveCount].Dist = Particles[y].Position.x * camdir.x +
                                       Particles[y].Position.y * camdir.y +
                                       Particles[y].Position.z * camdir.z;
    LiveCount++;
  }
}

if (Sort)
  qsort(DistanceBuffer, LiveCount, sizeof(PHXPARTICLEDISTANCE), ParticleSorter);
```

The distance calculation is a dot product between the particle position and the camera forward direction. This gives depth along the view direction. The `qsort` sorts particles back-to-front for correct alpha blending.

Sorting is optional because it costs CPU time and isn't always needed. Additive blending doesn't require sorting. Opaque particles don't need sorting. Only alpha-blended particles where order matters need the sort.

## Particle Affectors: Forces and Fields

Affectors modify particle velocity based on spatial position. All affectors share a common base class:

**Scene.h:307-320**

```cpp
class CphxObject_ParticleAffector : public CphxObject
{
public:
  unsigned char AreaType;
  bool ParticleInside(D3DXVECTOR3 v);
  virtual D3DXVECTOR3 GetForce(PHXPARTICLE *p) = 0;
};
```

The `AreaType` determines the affector's influence volume. Value 0 means infinite (affects all particles). Value 1 means box-shaped volume (affect particles within a 1×1×1 box in local space). The code only implements these two modes, though comments suggest sphere and cylinder were planned.

**Scene.cpp:832-848**

```cpp
bool CphxObject_ParticleAffector::ParticleInside(D3DXVECTOR3 v)
{
  D3DXVECTOR4 pos;
  D3DXVec3Transform(&pos, &v, &inverse);

  if (AreaType)
    return pos.x<0.5f && pos.x>-0.5f && pos.y<0.5f && pos.y>-0.5f &&
           pos.z<0.5f && pos.z>-0.5f;

  return true;
}
```

The particle position transforms into the affector's local space using the cached inverse matrix. This allows affectors to be positioned, rotated, and scaled in the scene. A rotated box affector creates an angled force field.

### Object_ParticleDrag

Drag opposes particle motion, slowing particles over time.

**Scene.h:322-333**

```cpp
class CphxObject_ParticleDrag : public CphxObject_ParticleAffector
{
public:
  D3DXVECTOR3 GetForce(PHXPARTICLE *p);
};
```

**Scene.cpp:920-925**

```cpp
D3DXVECTOR3 CphxObject_ParticleDrag::GetForce(PHXPARTICLE *p)
{
  return p->Velocity * (-SplineResults[Spline_AffectorPower]);
}
```

The force is the particle's velocity multiplied by negative power. Higher power means stronger drag. A power of 0.1 applies gentle drag. A power of 1.0 stops particles within one second.

This is linear drag, not physically accurate quadratic air resistance. But it's simple, cheap to compute, and visually sufficient for demo effects. Accuracy doesn't matter when you're creating abstract particle trails and glowing orbs.

### Object_ParticleGravity

Gravity pulls particles toward a point or in a constant direction.

**Scene.h:335-348**

```cpp
class CphxObject_ParticleGravity : public CphxObject_ParticleAffector
{
public:
  bool Directional;
  D3DXVECTOR3 GetForce(PHXPARTICLE *p);
};
```

**Scene.cpp:927-942**

```cpp
D3DXVECTOR3 CphxObject_ParticleGravity::GetForce(PHXPARTICLE *p)
{
  D3DXVECTOR3 pos = WorldPosition;

  if (Directional)
  {
    D3DXVec3Normalize(&pos, &pos);
    return pos * (SplineResults[Spline_AffectorPower] / 100.0f);
  }

  D3DXVECTOR3 v = pos - p->Position;
  float l = D3DXVec3Length(&v);
  return v * (SplineResults[Spline_AffectorPower] / (l * l * l) / 100.0f);
}
```

Directional gravity uses the affector's world position as the direction vector (normalized). The force is constant across the entire field. This simulates Earth-like gravity where the direction is "down."

Point gravity uses inverse-square falloff: `force = power / distance²`. The formula includes an extra division by `l` (the third `/l`) which normalizes the direction vector `v`. This is a clever optimization: instead of normalizing `v` and then multiplying by `power / (l * l)`, the code multiplies by `power / (l * l * l)`, achieving both normalization and distance falloff in one operation.

The `/100.0f` scales the power values. Material artists work with power values like "10" or "50" rather than tiny fractions like "0.1". The division keeps the internal math consistent.

### Object_ParticleTurbulence

Turbulence applies chaotic noise-based forces, creating swirling, unpredictable particle motion.

**Scene.h:350-368**

```cpp
class CphxObject_ParticleTurbulence : public CphxObject_ParticleAffector
{
  D3DXVECTOR3 SampleKernel(const D3DXVECTOR4& Pos);
public:
  D3DXVECTOR3 Kernel[32][32][32];
  unsigned char calculatedKernelSeed;

  void InitKernel();
  D3DXVECTOR3 GetForce(PHXPARTICLE *p);
};
```

The `Kernel` array stores 32×32×32 = 32,768 random direction vectors. This is substantial memory: 32,768 vectors × 12 bytes = 384 KB per turbulence object. But the procedural noise provides high-quality turbulence without shader complexity.

**Scene.cpp:852-867** initializes the kernel with normalized random vectors:

```cpp
void CphxObject_ParticleTurbulence::InitKernel()
{
  if (RandSeed == calculatedKernelSeed)
    return;

  srand(RandSeed);
  calculatedKernelSeed = RandSeed;
  for (int x = 0; x < 32; x++)
    for (int y = 0; y < 32; y++)
      for (int z = 0; z < 32; z++)
      {
        for (int i = 0; i < 3; i++)
          Kernel[x][y][z][i] = (float)(rand() / (float)RAND_MAX) - 0.5f;
        D3DXVec3Normalize(&Kernel[x][y][z], &Kernel[x][y][z]);
      }
}
```

The kernel is lazily initialized when the `RandSeed` changes. This allows artists to keyframe the seed value, morphing the turbulence field over time.

**Scene.cpp:909-917** applies turbulence with multi-octave sampling:

```cpp
D3DXVECTOR3 CphxObject_ParticleTurbulence::GetForce(PHXPARTICLE *p)
{
  InitKernel();
  D3DXVECTOR4 Pos;
  D3DXVec3Transform(&Pos, &p->Position, &inverse);
  D3DXVECTOR3 v3 = SampleKernel(Pos * TurbulenceFrequency) +
                   SampleKernel(Pos * (TurbulenceFrequency * 2.0f)) * (1 / 2.0f) +
                   SampleKernel(Pos * (TurbulenceFrequency * 4.0f)) * (1 / 4.0f);
  D3DXVec3Normalize(&v3, &v3);
  return v3 * (SplineResults[Spline_AffectorPower] / 100.0f);
}
```

The multi-octave sampling combines three noise samples at different frequencies with decreasing amplitudes: base frequency × 1.0, double frequency × 0.5, quadruple frequency × 0.25. This creates fractal turbulence with both large-scale flow and small-scale detail.

**Scene.cpp:874-906** implements trilinear interpolation:

```cpp
D3DXVECTOR3 CphxObject_ParticleTurbulence::SampleKernel(const D3DXVECTOR4& Pos)
{
  int v[3];
  D3DXVECTOR3 f;
  D3DXVECTOR3 area[2][2][2];

  for (int x = 0; x < 3; x++)
  {
    v[x] = (int)Pos[x];
    if (Pos[x] < 0)
      v[x] -= 1;
    f[x] = (Pos[x] - v[x]);
  }

  for (int x = 0; x < 2; x++)
    for (int y = 0; y < 2; y++)
      for (int z = 0; z < 2; z++)
        area[x][y][z] = Kernel[(v[0] + x) & 31][(v[1] + y) & 31][(v[2] + z) & 31];

  D3DXVECTOR3 v1 = Lerp(area[0][0][0], area[1][0][0], f.x);
  D3DXVECTOR3 v2 = Lerp(area[0][1][0], area[1][1][0], f.x);
  D3DXVECTOR3 v3 = Lerp(area[0][0][1], area[1][0][1], f.x);
  D3DXVECTOR3 v4 = Lerp(area[0][1][1], area[1][1][1], f.x);
  D3DXVECTOR3 v5 = Lerp(v1, v2, f.y);
  D3DXVECTOR3 v6 = Lerp(v3, v4, f.y);
  D3DXVECTOR3 res = Lerp(v5, v6, f.z);
  D3DXVec3Normalize(&res, &res);

  return res;
}
```

The code extracts integer and fractional parts of the position. The integer part indexes the 8-corner cube in the kernel. The fractional parts drive trilinear interpolation: lerp along X for the 4 edges parallel to X, lerp along Y for the 2 edges parallel to Y, lerp along Z for the final result.

The `& 31` operation wraps the indices, making the kernel tileable. Particles can move outside the 32×32×32 cube and the noise pattern repeats seamlessly.

### Object_ParticleVortex

Vortex affectors create rotational flow, swirling particles around an axis.

**Scene.h:370-381**

```cpp
class CphxObject_ParticleVortex : public CphxObject_ParticleAffector
{
public:
  D3DXVECTOR3 GetForce(PHXPARTICLE* p);
};
```

**Scene.cpp:944-959**

```cpp
D3DXVECTOR3 CphxObject_ParticleVortex::GetForce(PHXPARTICLE* p)
{
  float pwr = SplineResults[Spline_AffectorPower];

  D3DXVECTOR3 pos = WorldPosition;
  D3DXVECTOR3 v = pos - p->Position;
  D3DXVECTOR4 axis;
  D3DXVECTOR3 force;
  D3DXVec3Transform(&axis, &D3DXVECTOR3(0, 1, 0), &GetWorldMatrix());
  D3DXVec3Normalize((D3DXVECTOR3*)&axis, (D3DXVECTOR3*)&axis);
  D3DXVec3Normalize(&v, &v);
  D3DXVec3Cross(&force, (D3DXVECTOR3*)&axis, &v);
  return force * pwr;
}
```

The vortex axis is the affector's local Y axis transformed to world space. The direction from particle to affector center is `v`. The cross product `axis × v` produces a force perpendicular to both, creating circular motion around the axis.

The force magnitude is constant regardless of distance, unlike gravity. This creates a uniform rotation field. Particles near the center spin at the same rate as particles far away. For tornado-like effects, you'd combine a vortex with a point gravity pulling inward.

## Object_LogicObject: Scripting Hook

Logic objects are placeholders for custom scripting behavior, though the actual scripting system isn't visible in the Phoenix source.

**Scene.h:108** lists `Object_LogicObject` as a type, but there's no subclass. Logic objects use the base `CphxObject` with repurposed fields:

- `camCenterX`: Logic object type identifier
- `camCenterY`: Logic object data byte

These fields are reused from the camera object fields since cameras and logic objects are mutually exclusive types. This saves a few bytes per object at the cost of semantic confusion.

The `CreateRenderDataInstances()` implementation is empty (the base class default). Logic objects don't render. They exist purely for the tool's scripting system to query and manipulate. Demo artists can place logic objects in scenes and reference them from scripts to trigger effects, synchronize timing, or communicate data between systems.

## Object Type Summary

| Type | Subclass | Key Members | CreateRenderDataInstances Behavior |
|------|----------|-------------|----------------------------------|
| **Object_Model** | CphxObject_Model | Model pointer | Delegates to Model->CreateRenderDataInstances(), expanding materials into per-pass render instances |
| **Object_Light** | CphxObject (base) | SplineResults for colors/position | No render instances. Contributes to Lights[] array via CollectLights() |
| **Object_CamEye** | CphxObject (base) | FOV, Roll, camCenterX/Y, Target | No render instances. Defines view frustum for rendering |
| **Object_Dummy** | CphxObject (base) | None (pure transform) | No render instances. Exists for hierarchical grouping |
| **Object_SubScene** | CphxObject_SubScene | SubSceneTarget, Clip, Time, RepeatCount | Recursively calls SubSceneTarget->UpdateSceneGraph(), collects lights |
| **Object_ParticleEmitterCPU** | CphxObject_ParticleEmitter_CPU | Particles[], Material, ObjectToEmit, SceneToEmit | Renders standard billboards, instanced meshes, or subscenes per particle |
| **Object_ParticleDrag** | CphxObject_ParticleDrag | AreaType, AffectorPower | No render instances. Applies velocity * -power force to particles |
| **Object_ParticleGravity** | CphxObject_ParticleGravity | Directional flag, AffectorPower | No render instances. Applies constant or inverse-square force to particles |
| **Object_ParticleTurbulence** | CphxObject_ParticleTurbulence | Kernel[32][32][32], TurbulenceFrequency | No render instances. Applies multi-octave noise force to particles |
| **Object_ParticleVortex** | CphxObject_ParticleVortex | AffectorPower | No render instances. Applies cross-product rotation force to particles |
| **Object_LogicObject** | CphxObject (base) | camCenterX (type), camCenterY (data) | No render instances. Hook for scripting system |
| **Object_ParticleEmitter** | (GPU version, incomplete) | Not implemented in codebase | Planned compute shader particles, not present in final code |

## Particle Affector Comparison

| Affector | Force Formula | Use Case |
|----------|---------------|----------|
| **Drag** | `velocity * -power` | Slow particles over time, simulate air resistance |
| **Gravity (Directional)** | `normalize(position) * power` | Constant downward pull, rain, snow |
| **Gravity (Point)** | `(center - pos) * power / distance³` | Attract to or repel from point, orbital motion |
| **Turbulence** | `TrilinearNoise(pos * freq) * power` | Chaotic swirling, smoke, magical effects |
| **Vortex** | `cross(axis, direction) * power` | Rotation around axis, tornadoes, spirals |

## Implications for Rust Creative Coding Framework

Phoenix's object system offers several lessons for framework design:

### Fixed Types vs Component Systems

Phoenix uses classical OOP with fixed object types. Modern engines favor entity-component systems (ECS) for flexibility. Which is better?

For size-optimized or embedded systems, fixed types win. No component lookup tables, no dynamic attachment, no system scheduling. The code is straightforward: `if (type == Light) collectLight(); else if (type == Model) renderModel();`. This compiles to a simple switch statement.

For larger frameworks where artists need flexibility, ECS wins. Want a particle emitter that also emits light? Add both components. Want collision detection on specific objects? Add a collider component. The object type doesn't constrain behavior.

A Rust framework could offer both: fixed types for built-in scene graph nodes (Camera, Light, Mesh, ParticleEmitter) and an optional component system for user-defined behaviors. The core engine uses fixed types for predictable performance. User code extends via components for flexibility.

### Shared Animation Infrastructure

Every Phoenix object uses the same spline system. Material parameters, transforms, light colors, particle emission rates, all animate through splines. This uniformity simplifies tooling: one animation editor handles everything.

A Rust framework should provide a single animation abstraction: `Animatable<T>` where `T` can be floats, vectors, colors, quaternions, enums, or custom types. The spline evaluation logic is generic. Type-specific behavior (quaternion interpolation vs linear interpolation) happens through traits.

```rust
trait Interpolate {
    fn interpolate(&self, other: &Self, t: f32) -> Self;
}

struct Spline<T: Interpolate> {
    keyframes: Vec<(f32, T)>,
}

impl<T: Interpolate> Spline<T> {
    fn evaluate(&self, time: f32) -> T {
        // Generic spline evaluation
    }
}
```

### Virtual Dispatch for Type-Specific Behavior

Phoenix uses `virtual void CreateRenderDataInstances()` for polymorphism. Rust would use trait objects: `Box<dyn SceneNode>` or `&dyn SceneNode`.

The performance cost is minimal for scene graphs. Most scenes have hundreds of objects, not millions. One virtual call per object per frame is negligible. The code clarity is worth it.

For performance-critical cases (particle systems with 10,000 particles), avoid virtual dispatch. Use fixed types or generic code that monomorphizes.

### Separate Simulation from Rendering

Phoenix separates particle simulation (CPU physics) from rendering (vertex buffer generation, instancing). The `UpdateParticles()` method runs physics. The `CreateRenderDataInstances()` method creates render instances. This separation enables:

- Running simulation at a different rate than rendering (25fps physics, 60fps rendering)
- Updating particles during timeline scrubbing without rendering
- Rendering the same particles multiple times (motion blur, shadows) without re-simulation

A Rust framework should maintain this boundary. Scene nodes should have separate methods:

```rust
trait SceneNode {
    fn update(&mut self, delta_time: f32, scene: &Scene);
    fn create_render_instances(&self, context: &mut RenderContext);
}
```

### Power-of-Two Sizing for Arrays

Phoenix particle buffers use `1 << BufferSize` particles. Powers of two simplify memory allocation and indexing. It also enables clever bit masking for wrapping indices.

Rust frameworks should consider power-of-two sizing for dynamic arrays when appropriate. The `Vec` type doesn't enforce this, but custom allocators or wrapper types can:

```rust
struct PowerOfTwoVec<T> {
    data: Vec<T>,
    size_log2: u8,
}

impl<T> PowerOfTwoVec<T> {
    fn capacity(&self) -> usize {
        1 << self.size_log2
    }

    fn wrap_index(&self, idx: usize) -> usize {
        idx & ((1 << self.size_log2) - 1)
    }
}
```

### Memory Layout for Fast Copying

Phoenix uses `memcpy` to bulk-copy spline results into light data. This only works because the memory layout is carefully matched. Rust can achieve this with `#[repr(C)]` and manual layout control.

For performance-critical code, consider data-oriented design where related fields are contiguous in memory. The `bytemuck` crate enables safe casting between types with matching layouts.

But be cautious. Memory layout optimizations tie code to specific representations. If the spline slot order changes, the memcpy breaks. Document these dependencies clearly or use safer abstractions.

### Affector Pattern for Spatial Effects

The particle affector system is elegant: objects that implement `ParticleInside()` and `GetForce()` can influence particles. This is a simple form of spatial query: "which affectors affect this particle?"

A Rust framework could generalize this to spatial event systems:

```rust
trait SpatialInfluence {
    fn affects(&self, position: Vec3) -> bool;
    fn apply(&self, target: &mut ParticleState);
}
```

The particle system queries all `SpatialInfluence` objects during update. The trait is generic enough to support forces, collision volumes, trigger zones, audio attenuation, lighting influence, and more.

Phoenix's inverse matrix approach for local-space testing is clever. Cache inverse transforms during traversal. Use them for spatial queries. This avoids recalculating inverses per-particle per-affector.

### Spline Texture Baking for GPU Animation

Phoenix's particle spline texture is a brilliant optimization. Evaluating splines per-particle per-frame on the CPU is expensive. Baking curves into textures moves the work to GPU texture sampling, which is essentially free.

Modern frameworks should extend this idea. Any animation curve that's evaluated frequently can be baked into a texture. UI transitions, color gradients, easing curves, all become texture lookups.

WebGPU's storage buffers offer an alternative: upload curve data as a buffer and use compute shaders to evaluate. This provides more precision than textures but requires compute shader support.

### Hybrid CPU/GPU Particle Systems

Phoenix's CPU particle system is simple but flexible. All the Rust code is in one place. Debugging is straightforward. But it doesn't scale to millions of particles.

A modern framework should offer both CPU and GPU particle systems:

- **CPU particles**: Simple, flexible, good for < 10,000 particles with complex logic
- **GPU particles**: Fast, scalable, good for > 10,000 particles with simple physics

The scene graph interface should be the same for both. Artists choose the implementation based on their needs. The rendering pipeline doesn't care which type is used.

---

Phoenix's scene objects balance simplicity and capability. Fixed types with virtual dispatch provide clear semantics. Shared infrastructure (spline animation, hierarchical transforms) reduces code duplication. Type-specific behavior (particle physics, mesh rendering) lives in focused subclasses. The result is a system that's easy to understand, easy to extend, and efficient enough for real-time demo rendering.

For Rust frameworks, the takeaways are clear: use classical OOP patterns where they fit, provide shared infrastructure for common tasks, separate simulation from rendering, and optimize judiciously based on actual performance needs, not premature assumptions.
