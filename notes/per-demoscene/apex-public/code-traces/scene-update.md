# Code Trace: Scene Graph Update and Render Instance Collection

When you watch a demo scene play, what you're seeing is the result of a carefully orchestrated dance between animation, transformation, and GPU state. Every frame, the engine walks through the scene graph, evaluates animation splines at the current timestamp, calculates world-space matrices, and collects rendering instructions. This document traces that process step-by-step, revealing how the Apex engine transforms hierarchical scene data into drawable GPU commands.

The challenge this system solves is deceptively complex: how do you take a tree of animated objects—cameras, lights, models, particle emitters, subscenes—and turn them into an efficient stream of draw calls? The scene might contain nested subscenes, objects targeting other objects for lighting effects, particle systems with affectors in specific spatial regions, and materials that need sorting by render priority. All of this must happen every frame, at 60fps or more, in a size-optimized executable.

Think of it like preparing a theater production. Before the curtain rises, you need to update the positions of all actors (animation), calculate their positions relative to the stage (world transforms), set up the lighting rig, sort the scene layers by depth, and prepare the stage crew with their cue cards (render instances). Only then can the show begin.

This trace follows a concrete scenario: a scene with one camera, two lights, five models, and one subscene, evaluated at time t = 0.5. We'll see how UpdateSceneGraph() orchestrates the entire update process, from clearing old state to building sorted render queues.

## Setup: The Scene Before Update

Our example scene contains:
- 1 camera object (positioned and animated)
- 2 light objects (one directional, one point light)
- 5 model objects (various meshes with materials)
- 1 subscene object (references another scene)
- Animation clip index: 0
- Time: t = 0.5 (halfway through the animation)

The scene graph forms a hierarchy. Some models are parented to the camera, creating a local coordinate system. One light has a Target pointer to a model, meaning it will aim at that model's world position. The subscene has its own internal object tree that will be recursively evaluated.

Before this frame's update, the previous frame's RenderInstances still exist in each render layer. LightCount might be set to 3 from last frame. Object matrices are outdated. We need a clean slate.

## Entry Point: CphxScene::UpdateSceneGraph()

**File:** `Scene.cpp:51-90`

The public entry point is deceptively simple:

```cpp
void CphxScene::UpdateSceneGraph( int Clip, float t )
{
  D3DXMATRIX Root;
  D3DXMatrixIdentity( &Root );
  for ( int x = 0; x < LayerCount; x++ )
    RenderLayers[ x ]->RenderInstances.FreeArray();

  LightCount = 0;
  UpdateSceneGraph( Clip, t, Root, this, NULL );
  // ...
}
```

This function is the conductor of the entire update symphony. Let's break down its responsibilities.

### Phase 1: Clear Previous Frame State

**Lines 53-58**

First, establish the root transformation as an identity matrix. Every object's world transform will be calculated relative to this root. In our case, Root is a 4x4 identity matrix—no translation, rotation, or scale.

```cpp
D3DXMATRIX Root;
D3DXMatrixIdentity( &Root );
```

Next, clear all render instances from every render layer. The scene has LayerCount render layers (typically 3-5), each with a descriptor that determines render target, depth mode, and render priority. Each layer maintains an array of CphxRenderDataInstance pointers—these are the actual drawable commands that will be issued to the GPU.

```cpp
for ( int x = 0; x < LayerCount; x++ )
  RenderLayers[ x ]->RenderInstances.FreeArray();
```

After this loop, all RenderInstances arrays are empty. Any pointers to last frame's instances are gone.

Finally, reset the light count:

```cpp
LightCount = 0;
```

The scene has space for up to MAX_LIGHT_COUNT lights (typically 8). This counter tracks how many active lights we'll collect during traversal.

### Phase 2: Recursive Scene Graph Traversal

**Line 59**

Now comes the core traversal. The public UpdateSceneGraph() delegates to a private overload:

```cpp
UpdateSceneGraph( Clip, t, Root, this, NULL );
```

This overload takes:
- **Clip**: animation clip index (0 in our case)
- **t**: normalized time 0.0-1.0 (0.5)
- **Root**: parent transform matrix (identity)
- **RootScene**: pointer to the root scene (this)
- **SubSceneData**: clone data for subscenes (NULL at top level)

The private overload (Scene.cpp:92-97) is minimal:

```cpp
void CphxScene::UpdateSceneGraph( int Clip, float t, D3DXMATRIX Root,
                                  CphxScene *RootScene, void *SubSceneData )
{
  for ( int x = 0; x < ObjectCount; x++ )
    if ( Objects[ x ]->Parent == NULL )
      Objects[ x ]->TraverseSceneGraph( Clip, t, Root, RootScene, SubSceneData );
}
```

It iterates over all scene objects and calls TraverseSceneGraph() on root-level objects (those with NULL parent pointers). In our scene, the camera has no parent. It's a root object. So are the two lights. The five models might be parented to the camera, so they won't be processed here—they'll be reached when the camera processes its children.

This design ensures depth-first traversal: process a node, then recurse to its children with the accumulated parent transform.

## Recursive Core: CphxObject::TraverseSceneGraph()

**File:** `Scene.cpp:229-272`

This is where the real work happens. Let's trace through one object—our camera—step by step.

### Step 1: Animate the Object

**Line 232**

```cpp
CalculateAnimation( Clip, t );
```

Before we can transform the object, we need to know its current animated values. This call evaluates all animation splines at time t = 0.5 and stores results in the object's SplineResults array.

The animation system in Apex uses splines for every animatable property: position (x, y, z), rotation (quaternion), scale (x, y, z), light colors, camera FOV, particle emission rates, and more. The PHXSPLINETYPE enum (Scene.h:17-92) lists 57 different spline types.

### Step 2: Build Position-Rotation-Scale Matrix

**Lines 249-251**

```cpp
D3DXMATRIX prs;
D3DXMatrixTransformation( &prs, NULL, NULL,
                         (D3DXVECTOR3*)&SplineResults[ Spline_Scale_x ],
                         NULL, &RotationResult,
                         (D3DXVECTOR3*)&SplineResults[ Spline_Position_x ] );
D3DXMatrixMultiply( &m, &prs, &CurrentMatrix );
```

D3DXMatrixTransformation() is a DirectX utility that builds a transformation matrix from scale, rotation, and translation. It takes:
- Scaling center (NULL = origin)
- Scaling rotation (NULL = no rotation before scale)
- Scale vector (from SplineResults[1,2,3])
- Rotation center (NULL = origin)
- Rotation quaternion (from RotationResult)
- Translation vector (from SplineResults[8,9,10])

The result is a local transform matrix for this object. Then multiply it by the parent's cumulative transform (CurrentMatrix) to get the world transform:

```
world_transform = local_transform * parent_transform
```

### Step 3: Store Transformation History

**Lines 253-254**

```cpp
prevMatrix = currMatrix;
currMatrix = m;
```

The engine stores both the previous frame's matrix and the current one. This is essential for motion blur effects, temporal anti-aliasing, and particle interpolation. When spawning particles, the system can interpolate between prevMatrix and currMatrix to get sub-frame accurate emission positions.

### Step 4: Calculate World-Space Position

**Lines 257-259**

```cpp
D3DXVECTOR4 v;
D3DXVec3Transform( &v, (D3DXVECTOR3*)&SplineResults[ Spline_Position_x ],
                   &CurrentMatrix );
WorldPosition = *(D3DXVECTOR3*)&v;
```

This transforms the object's local position by the parent's transform to get the world-space position. It's stored in WorldPosition, which will be used later for target direction calculation and light data collection.

Why transform the position separately? The local position spline result is in object space. If this object is parented to another object, we need to know where it sits in world space for lighting calculations and targeting.

### Step 5: Create Render Instances

**Line 262**

```cpp
CreateRenderDataInstances( Clip, m, RootScene, SubSceneData ? SubSceneData : ToolData );
```

This virtual method is where object-specific rendering data gets generated. Its behavior depends on the object type:

- **Object_Model**: Delegates to CphxObject_Model::CreateRenderDataInstances() (Scene.cpp:331-334)
- **Object_SubScene**: Recursively calls UpdateSceneGraph() on the subscene (Scene.cpp:338-365)
- **Object_ParticleEmitterCPU**: Updates particle simulation and creates material state (Scene.cpp:608-724)
- **Object_Light, Object_CamEye, Object_Dummy**: No render data (pure scene nodes)

For our camera object, CreateRenderDataInstances() is a no-op—cameras don't render. For models, it creates CphxRenderDataInstance objects and adds them to the appropriate render layers.

### Step 6: Recurse to Children

**Lines 270-271**

```cpp
for ( int x = 0; x < ChildCount; x++ )
  Children[ x ]->TraverseSceneGraph( Clip, t, m, RootScene, SubSceneData );
```

If this object has children (models parented to the camera, for example), process them now with the accumulated transform m. This is how hierarchical animations work—child transforms are multiplied by parent transforms, creating chains like camera → model → submodel.

## Animation Evaluation: CalculateAnimation()

**File:** `Scene.cpp:274-315`

Before we can build transformation matrices, we need animated values. CalculateAnimation() evaluates all splines for the current clip at time t.

### Default Values

**Lines 277-297**

First, set default values for all spline types. This is necessary because not all objects have splines for every property:

```cpp
SplineResults[ Spline_Scale_x ] = 1;
SplineResults[ Spline_Scale_y ] = 1;
SplineResults[ Spline_Scale_z ] = 1;
SplineResults[ Spline_Light_DiffuseR ] = 1;
SplineResults[ Spline_Light_DiffuseG ] = 1;
SplineResults[ Spline_Light_DiffuseB ] = 1;
// ...and so on
```

These defaults mean "normal scale, white light, 60-degree FOV" and so on. If an object has no scale animation, it defaults to uniform scale of 1. If a light has no diffuse color animation, it defaults to white.

Some defaults aren't 1:

```cpp
SplineResults[ Spline_Particle_EmissionPerSecond ] = 25;
SplineResults[ Spline_Particle_Life ] = 10;
```

Particle systems default to 25 particles per second with 10 frames of life.

### Spline Evaluation

**Lines 299-305**

Now iterate over all splines in the current clip:

```cpp
for ( int x = 0; x < Clips[ Clip ]->SplineCount; x++ )
{
  CphxClipSpline *s = Clips[ Clip ]->Splines[ x ];
  s->Spline->CalculateValue( t );
  SplineResults[ s->Type ] = s->Spline->Value[ 0 ];
  if ( s->Type == Spline_Rotation ) RotationResult = s->Spline->GetQuaternion();
}
```

Each spline has a Type (position_x, scale_y, light diffuse, etc.) and a Spline pointer. Calling CalculateValue(t) evaluates the spline curve at time t and stores the result in Spline->Value[]. For most splines, Value[0] is a float. For rotation splines, it's a quaternion (four floats).

The key insight: SplineResults is a flat array indexed by PHXSPLINETYPE. After this loop, SplineResults contains the object's complete animated state at time t.

### Material Splines

**Line 307**

```cpp
Clips[ Clip ]->MaterialSplines->CalculateValues( t );
```

Materials can also be animated. Shader parameters like color tint, emission intensity, roughness—all can change over time. This evaluates all material-related splines and prepares them for CreateRenderDataInstances().

### Subscene Target

**Line 308**

```cpp
SubSceneTarget = Clips[ Clip ]->SubSceneTarget;
```

If this object is a subscene, store which scene to render. This will be used in CreateRenderDataInstances() when the subscene recursively calls UpdateSceneGraph().

### Particle Turbulence Seed

**Lines 310-314**

```cpp
if ( ObjectType == Object_ParticleTurbulence )
{
  RandSeed = Clips[ Clip ]->RandSeed;
  TurbulenceFrequency = Clips[ Clip ]->TurbulenceFrequency;
}
```

Turbulence affectors use a 32x32x32 3D noise kernel. The seed determines the random field, and the frequency scales the sampling. These are per-clip, not per-spline, because they define the overall character of the turbulence field.

## CreateRenderDataInstances Dispatch

After animation and transformation, each object type creates GPU-drawable instances.

### Object_Model: Mesh Rendering

**File:** `Scene.cpp:331-334`

```cpp
void CphxObject_Model::CreateRenderDataInstances( int Clip, const D3DXMATRIX &m,
                                                   CphxScene *RootScene, void *SubSceneData )
{
  Model->CreateRenderDataInstances( Clips[ Clip ], m, RootScene,
                                    SubSceneData ? SubSceneData : ToolData );
}
```

The model object delegates to its CphxModel, which in turn delegates to its CphxModelObject_Mesh instances. Each mesh creates a CphxRenderDataInstance:
- Copies the world transform matrix to RDI->Matrices[0]
- Copies the previous frame matrix to RDI->Matrices[1]
- Sets vertex and index buffers
- Sets shader pointers (VS, PS, GS, HS, DS)
- Sets blend, rasterizer, and depth stencil states from the material
- Copies material constant and animated data to RDI->MaterialData[]

Finally, it calls RootScene->AddRenderDataInstance(), which adds the RDI to the appropriate render layer based on the material's render target.

### Object_SubScene: Recursive Rendering

**File:** `Scene.cpp:338-365`

Subscenes are a fascinating optimization. Instead of duplicating geometry, you can instance an entire scene multiple times with different animations:

```cpp
void CphxObject_SubScene::CreateRenderDataInstances( int Clip, const D3DXMATRIX &m,
                                                      CphxScene *RootScene, void *SubSceneData )
{
  D3DXMATRIX mtx = m;
  D3DXMATRIX prs;
  D3DXMatrixTransformation( &prs, NULL, NULL,
                           (D3DXVECTOR3*)&SplineResults[ Spline_Scale_x ],
                           NULL, &RotationResult,
                           (D3DXVECTOR3*)&SplineResults[ Spline_Position_x ] );

  int clipId = max( 0, min( SubSceneTarget->ClipCount - 1,
                            (int)SplineResults[ Spline_SubScene_Clip ] ) );
  int repeatCount = max( 1, (int)SplineResults[ Spline_SubScene_RepeatCount ] );
  float timeOffset = SplineResults[ Spline_SubScene_RepeatTimeOffset ];

  for ( int x = 0; x < repeatCount; x++ )
  {
    SubSceneTarget->UpdateSceneGraph(
      clipId,
      fabs( fmod( SplineResults[ Spline_SubScene_Time ] + timeOffset * x, 1.0f ) ),
      mtx, RootScene, SubSceneData ? SubSceneData : ToolData );

    D3DXMatrixMultiply( &mtx, &prs, &mtx );
  }

  RootScene->CollectLights( SubSceneTarget );
}
```

Notice the repeatCount loop. A subscene can be instanced multiple times with staggered time offsets. Imagine a kaleidoscope effect: the same animation repeated in a circle, each copy slightly ahead in time. Each repetition multiplies mtx by prs, creating a spatial offset.

The subscene's UpdateSceneGraph() is called with:
- **clipId**: which clip to play (animated per frame)
- **time**: animated time value plus timeOffset
- **mtx**: cumulative transform
- **RootScene**: the top-level scene that collects all render instances
- **SubSceneData**: clone data for material overrides

After updating, it collects lights from the subscene. Lights in subscenes contribute to the main scene's lighting.

### Object_ParticleEmitterCPU: Particle Rendering

**File:** `Scene.cpp:608-724`

Particle emitters are the most complex objects. Their CreateRenderDataInstances() method:

1. **Applies material splines** (line 610): Material color, emission, etc.
2. **Collects animated material data** (lines 616-622): Builds MaterialState for each render pass
3. **Assigns spline texture** (line 625): Particle life splines are baked into a 2048-pixel wide texture

For standard billboard particles, it creates a single RDI with a vertex buffer containing particle positions, life values, rotations, and chaos values (line 641).

For mesh particles and subscene particles (lines 647-723), it iterates over all living particles and creates a separate render instance for each. Each particle gets a transformation matrix that accounts for scale, stretch, rotation, and position interpolation.

## Post-Traversal: Target Direction Calculation

**File:** `Scene.cpp:61-73`

After all objects are traversed, calculate target directions for objects with Target pointers:

```cpp
for ( int x = 0; x < ObjectCount; x++ )
{
  CphxObject *o = Objects[ x ];
  if ( o->Target )
  {
    o->TargetDirection = o->Target->WorldPosition - o->WorldPosition;
    D3DXVec3Normalize( &o->TargetDirection, &o->TargetDirection );
    o->SplineResults[ Spot_Direction_X ] = o->TargetDirection.x;
    o->SplineResults[ Spot_Direction_Y ] = o->TargetDirection.y;
    o->SplineResults[ Spot_Direction_Z ] = o->TargetDirection.z;
  }
}
```

This is used for spotlights that aim at a moving target. The TargetDirection is normalized and stored in the spot direction spline results, which get copied to LIGHTDATA in CollectLights().

The key insight: target directions are calculated *after* traversal because both the targeting object and the target need their WorldPosition calculated first. This is a two-pass system—first update all positions, then resolve dependencies.

## Light Collection: CollectLights()

**File:** `Scene.cpp:101-134`

Now that all objects have animated values and world positions, collect lights into the global Lights array:

```cpp
void CphxScene::CollectLights( CphxScene* sceneToCollectFrom )
{
  for ( int x = 0; x < sceneToCollectFrom->ObjectCount; x++ )
  {
    if ( LightCount >= 8 )
      return;

    CphxObject* object = sceneToCollectFrom->Objects[ x ];

    if ( object->ObjectType == Object_Light )
    {
      memcpy( &Lights[ LightCount ], &object->SplineResults[ Spline_Position_x ],
              sizeof( LIGHTDATA ) );
      if ( object->SplineResults[ Spline_Position_w ] != 0 )
      {
        Lights[ LightCount ].Position.x = object->WorldPosition.x;
        Lights[ LightCount ].Position.y = object->WorldPosition.y;
        Lights[ LightCount ].Position.z = object->WorldPosition.z;
      }
      else
      {
        Lights[ LightCount ].SpotDirection.x = object->WorldPosition.x;
        Lights[ LightCount ].SpotDirection.y = object->WorldPosition.y;
        Lights[ LightCount ].SpotDirection.z = object->WorldPosition.z;
        Lights[ LightCount ].Ambient.w = object->SplineResults[ Spline_Light_OrthoX ];
        Lights[ LightCount ].Diffuse.w = object->SplineResults[ Spline_Light_OrthoY ];
      }
      LightCount++;
    }
  }
}
```

This function is called twice: once for the main scene (line 75) and once for each subscene (line 364).

The LIGHTDATA structure (Scene.h:131-137) matches the shader constant buffer layout:

```cpp
struct LIGHTDATA
{
  D3DXVECTOR4 Position;
  D3DXVECTOR4 Ambient, Diffuse, Specular;
  D3DXVECTOR4 SpotDirection;
  D3DXVECTOR4 SpotData; // exponent, cutoff, linear and quadratic attenuations
};
```

The clever part: SplineResults are laid out in memory to match LIGHTDATA. The memcpy() on line 112 copies 112 bytes (7 D3DXVECTOR4s) directly from the spline results into the light data structure. This is a size optimization—no intermediate copies, no data structure marshaling.

The Position.w field determines light type:
- **w != 0**: Point light. Copy WorldPosition to Position.xyz.
- **w == 0**: Directional light. Copy WorldPosition to SpotDirection.xyz. The position represents the light's direction vector origin.

The Ambient.w and Diffuse.w fields store orthographic projection parameters for shadow mapping (OrthoX, OrthoY).

## Render Layer Sorting: Priority-Based Ordering

**File:** `Scene.cpp:77-78`

With all render instances collected, sort each layer by render priority:

```cpp
for ( int x = 0; x < LayerCount; x++ )
  SortRenderLayer( RenderLayers[ x ]->RenderInstances.Array, 0,
                   RenderLayers[ x ]->RenderInstances.ItemCount - 1 );
```

SortRenderLayer() is a quicksort implementation (Scene.cpp:16-49) that sorts by RenderPriority (a signed integer). Higher priority renders first.

Why sort? Materials define render priority to control draw order:
- **Opaque geometry**: High priority (e.g., 100)
- **Alpha-blended particles**: Low priority (e.g., -100)
- **Additive glow effects**: Lowest priority (e.g., -200)

Sorting ensures opaque geometry is drawn back-to-front, then transparent geometry front-to-back (or vice versa, depending on the effect). This prevents alpha blending artifacts and maintains proper depth relationships.

The sort is stable (line 19 comment), meaning objects with the same priority maintain their relative order. This is critical for deterministic rendering across frames.

## Affector Inverse Matrices: Spatial Particle Effects

**File:** `Scene.cpp:80-89**

The final step calculates inverse matrices for particle affectors:

```cpp
for ( int x = 0; x < ObjectCount; x++ )
  if ( Objects[ x ]->ObjectType == Object_ParticleGravity ||
       Objects[ x ]->ObjectType == Object_ParticleDrag ||
       Objects[ x ]->ObjectType == Object_ParticleTurbulence ||
       Objects[ x ]->ObjectType == Object_ParticleVortex )
  {
    D3DXMATRIX m = Objects[ x ]->GetWorldMatrix();
    D3DXMatrixInverse( &Objects[ x ]->inverse, NULL, &m );
  }
```

Particle affectors apply forces in their local coordinate system. A gravity affector might be a sphere—particles inside the sphere are attracted to the center. To determine if a particle is "inside," we need to transform the particle's world position into the affector's local space.

The inverse matrix does exactly that:

```
local_position = world_position * affector_inverse_matrix
```

Once in local space, ParticleInside() (Scene.cpp:832-848) can check if the particle is within the affector's volume (sphere, box, etc.).

This inverse is stored in the object's inverse field and used every frame during particle updates (Scene.cpp:513-515 in UpdateParticles()).

## Output: Scene Ready for Render()

At this point, UpdateSceneGraph() has completed. The scene state is:

### Render Layers
Each render layer contains a sorted array of CphxRenderDataInstance pointers. For our example scene:
- **Layer 0** (opaque geometry): 5 model instances, sorted by priority
- **Layer 1** (transparent): Particle emitter instance
- **Layer 2** (post-processing): Empty

### Light Data
The Lights array contains 2 LIGHTDATA entries:
- **Lights[0]**: Directional light (Position.w = 0)
- **Lights[1]**: Point light (Position.w = 1)

Each light's position, colors, and attenuation are ready to copy to the shader constant buffer.

### Object State
Every object has:
- **SplineResults**: Animated values at t = 0.5
- **currMatrix**: Current world transformation
- **prevMatrix**: Previous frame's transformation
- **WorldPosition**: World-space position for targeting and lighting

### Particle Affectors
All affectors have inverse matrices calculated, ready for spatial queries during particle updates.

The scene is now ready for CphxScene::Render() (Scene.cpp:136-203), which will:
1. Upload Lights to the scene constant buffer
2. Upload view and projection matrices
3. Iterate over render layers
4. For each layer, call SetEnvironment() to bind render targets
5. For each render instance in the layer, call RDI->Render()

Each RDI->Render() call uploads its Matrices and MaterialData to GPU constant buffers, binds shaders and textures, and issues a draw call.

## Implications for Framework Design

This scene update system reveals several patterns worth considering for a modern creative coding framework:

### Entity-Component-System vs. Scene Graph
Apex uses a traditional scene graph with parent-child relationships. Transformation is hierarchical. This is simple and intuitive for artists, but it couples data (object type, transform, material) with behavior (rendering, animation, particle simulation).

An ECS approach would separate concerns:
- **Transform component**: Position, rotation, scale, parent relationship
- **Renderable component**: Mesh, material, render priority
- **Animated component**: Spline evaluator, current time
- **Light component**: Color, attenuation, target

Systems would process components in parallel. The animation system updates Animated components. The transform system propagates parent transforms. The render system collects Renderable+Transform pairs.

Trade-offs:
- ECS is more flexible and cache-friendly for large scenes
- Scene graphs are more intuitive for small, hierarchical scenes
- Apex's approach minimizes code size (critical for 64KB demos)

### Animation System: Splines vs. Keyframes
Apex uses float16 splines for size optimization. Modern frameworks could use:
- **Keyframe animation**: Easier authoring, larger file size
- **Procedural animation**: Code-driven movement, zero data
- **Animation curves**: Bezier/Hermite curves, interpolated per frame

The SplineResults array pattern—pre-allocate space for all possible animated properties—is a size/speed trade-off. It wastes memory for unused properties but avoids hash lookups or indirection.

### Two-Pass Update: Transform Then Resolve
The target direction calculation (Scene.cpp:61-73) happens *after* traversal because it requires both objects' world positions. This is a constraint satisfaction problem: "object A must point at object B's position."

Alternative approaches:
- **Iterative solver**: Update transforms, resolve constraints, repeat until converged
- **Lazy evaluation**: Calculate target direction only when accessed
- **Dependency graph**: Topological sort, update in dependency order

Apex's two-pass approach is simple and deterministic, but it doesn't handle chains (A→B→C→A causes errors).

### Subscene Instancing: Data Reuse
The subscene system is a form of procedural modeling. One scene (a flower) can be instanced 50 times with different transforms and animations, creating a field of flowers. This is how demos achieve complex scenes with minimal data.

Modern frameworks could generalize this:
- **Prefab instancing**: Unity-style prefabs with override support
- **Component sharing**: Multiple entities reference the same mesh/material
- **GPU instancing**: One draw call for many copies (Apex predates instanced rendering)

### Render Priority Sorting: State Change Optimization
Sorting by render priority reduces state changes. Drawing all opaque objects before transparent objects minimizes blend state toggles. Drawing all objects using MaterialA before MaterialB minimizes shader rebinds.

More sophisticated approaches:
- **Render graph**: Declare dependencies, auto-schedule passes
- **Material batching**: Group by (shader, textures, blendmode)
- **Depth pre-pass**: Draw opaque depth first, then color

### Particle Affectors: Spatial Queries
The inverse matrix approach for particle affectors is elegant but limited to analytical shapes (spheres, boxes). For arbitrary meshes, you'd need:
- **Spatial acceleration**: Octree, BVH, grid
- **Signed distance fields**: GPU-accelerated inside/outside tests
- **Physics engine integration**: Use existing collision detection

The key insight is that affectors work in *local space*. This decouples the affector's shape from its world-space transform.

## Conclusion

The scene graph update process in Apex is a masterclass in size-optimized engine design. It combines hierarchical transforms, spline animation, polymorphic rendering, and spatial queries into a single coherent system.

The two-phase approach—traverse and collect, then sort and render—separates concerns cleanly. The use of flat arrays, memory layout tricks (SplineResults matching LIGHTDATA), and minimal abstractions keeps code size tiny while maintaining clarity.

For modern frameworks targeting larger file sizes, we can borrow the conceptual patterns (hierarchical animation, render priority sorting, subscene instancing) while using more flexible implementations (ECS, render graphs, component sharing).

The core lesson: scene update is the bridge between artist intent (animation curves, object hierarchies) and GPU reality (draw calls, state changes, constant buffers). A well-designed bridge makes both sides easier to work with.

## References

**Source Files:**
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp` — Core traversal logic
- `demoscene/apex-public/apEx/Phoenix/Scene.h` — Object and scene structures
- `demoscene/apex-public/apEx/Phoenix/RenderLayer.h` — RenderDataInstance definition
- `demoscene/apex-public/apEx/Phoenix/Model.h` — Model object interfaces
- `demoscene/apex-public/apEx/Phoenix/Material.h` — Material system

**Key Functions:**
- `CphxScene::UpdateSceneGraph()` (Scene.cpp:51) — Entry point
- `CphxObject::TraverseSceneGraph()` (Scene.cpp:229) — Recursive traversal
- `CphxObject::CalculateAnimation()` (Scene.cpp:274) — Spline evaluation
- `CphxScene::CollectLights()` (Scene.cpp:101) — Light data collection
- `SortRenderLayer()` (Scene.cpp:41) — Priority-based sorting

**Related Documents:**
- `code-traces/model-rendering.md` — How RenderDataInstance draws geometry
- `code-traces/particle-system.md` — Particle emitter update and rendering
- `architecture.md` — Overall engine structure
- `rendering-pipeline.md` — From scene update to pixels
