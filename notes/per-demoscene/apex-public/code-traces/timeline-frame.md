# Code Trace: Single Frame Render Through Phoenix Timeline

This document traces the complete execution path of rendering frame 1500 through the Phoenix Timeline system, from `CphxTimeline::Render()` entry to final backbuffer output.

## The Problem: Synchronized Multi-Event Rendering

Imagine you're conducting an orchestra where different sections start and stop at different times, but they all need to play together in perfect sync. The Timeline system faces this challenge: at any given frame, multiple visual events might be active—a camera shake, particle calculations, scene rendering—and they all need to contribute to the final image in the correct order.

The Phoenix Timeline solves this by treating each frame as a clean slate. Every render target gets cleared, every event gets evaluated for that exact moment in time, and the results compose into a final image. This differs from retained-mode rendering where objects persist; here, each frame is reconstructed from scratch based on temporal position.

## Setup Scenario

For this trace, we'll follow frame 1500 with three overlapping events:

- **Event 0**: `EVENT_CAMERASHAKE` (frames 1400-1600) — Adds random camera movement
- **Event 1**: `EVENT_PARTICLECALC` (frames 1000-2000) — Updates particle systems
- **Event 2**: `EVENT_RENDERSCENE` (frames 1450-1550) — Renders 3D scene with camera

The timeline has:
- Aspect ratio: 16:9 (AspectX=16, AspectY=9)
- Frame rate: 60 FPS (FrameRate=60)
- 2 render targets: RT0 (1920x1080), RT1 (512x512)
- Screen resolution: 1920x1080

## Step 1: Entry Point

**File**: `demoscene/apex-public/apEx/Phoenix/Timeline.cpp:318`

```cpp
void CphxTimeline::Render( float Frame, bool tool, bool subroutine )
{
  cameraOverride = nullptr;
  TimelineFramerate = FrameRate;
  CurrentFrame = (int)Frame;
  EyeOffset = TargetOffset = D3DXVECTOR3( 0, 0, 0 );
```

The function receives:
- `Frame = 1500.0` — Current frame position
- `tool = false` — Not rendering in editor
- `subroutine = false` — Not a recursive call from EVENT_RENDERDEMO

**State initialization**:
1. Reset `cameraOverride` to `nullptr` — Clears any camera override from previous frame
2. Store `TimelineFramerate = 60` — Global variable for event time calculations
3. Store `CurrentFrame = 1500` — Global variable for camera shake seed
4. Zero `EyeOffset` and `TargetOffset` — Camera shake will modify these later

These globals are read by event render functions. `CurrentFrame` is particularly important for `EVENT_CAMERASHAKE`, which uses it to seed deterministic random shake patterns.

## Step 2: Render Target Clearing

**File**: `Timeline.cpp:325-338`

```cpp
if ( !subroutine )
{
  Target = NULL;

  //clear rendertargets at the beginning of the frame
  if ( !tool )
    phxContext->ClearRenderTargetView( phxBackBufferView, (float*)rv );

  for ( int x = 0; x < RenderTargetCount; x++ )
    phxContext->ClearRenderTargetView( RenderTargets[ x ]->RTView, (float*)rv );
  phxContext->ClearDepthStencilView( phxDepthBufferView,
    D3D10_CLEAR_DEPTH | D3D10_CLEAR_STENCIL, 1, 0 );
}
```

Since `subroutine = false`, we enter the clearing block.

**Target tracking**:
- `Target = NULL` — This will track which render target was written to by the last event

**Backbuffer clear** (tool mode only):
- `phxBackBufferView` cleared to black `(0, 0, 0, 0)`
- Uses `rv` which is `static ID3D11ShaderResourceView *rv[8] = {0, 0, 0, 0, 0, 0, 0, 0}`
- Cast to `float*` reinterprets 8 null pointers as 8 zero floats

**Render target clear loop**:
- `RenderTargetCount = 2`
- Iteration 0: Clear RT0 (1920x1080) to black
- Iteration 1: Clear RT1 (512x512) to black

**Depth buffer clear**:
- Clear depth to 1.0 (far plane)
- Clear stencil to 0

This ensures no pixels or depth values carry over from the previous frame. Every frame starts from a pristine state.

## Step 3: Event Iteration Setup

**File**: `Timeline.cpp:340-361`

```cpp
for ( int x = 0; x < EventCount; x++ )
{
  if ( Events[ x ]->StartFrame <= (int)Frame && (int)Frame < Events[ x ]->EndFrame )
  {
    float t = ( Frame - Events[ x ]->StartFrame ) /
              ( Events[ x ]->EndFrame - Events[ x ]->StartFrame );
    float prevt = ( Frame - 1 - Events[ x ]->StartFrame ) /
                  ( Events[ x ]->EndFrame - Events[ x ]->StartFrame );
```

The loop evaluates each event to check if it's active at frame 1500.

**Temporal range check**:
- Event is active if `StartFrame <= 1500 < EndFrame`
- Uses integer comparison `(int)Frame` to avoid float precision issues
- Half-open interval: frame 1500 is IN, frame at EndFrame is OUT

**Time normalization**:
- `t` = normalized position in event [0.0, 1.0)
- `prevt` = normalized position one frame earlier (for motion blur)

This normalization is critical: events don't know their absolute frame numbers. They receive a 0-to-1 value representing their internal timeline position.

## Step 4: Time Spline Remapping

**File**: `Timeline.cpp:347-353`

```cpp
if ( Events[ x ]->Time ) //if time spline is missing, use default 0..1
{
  Events[ x ]->Time->CalculateValue( prevt );
  prevt = Events[ x ]->Time->Value[ 0 ];
  Events[ x ]->Time->CalculateValue( t );
  t = Events[ x ]->Time->Value[ 0 ];
}
```

If an event has a Time spline, linear time gets warped.

**Without spline** (most common):
- Event 0 (CAMERASHAKE): `t = (1500-1400)/(1600-1400) = 100/200 = 0.5`
- Event 1 (PARTICLECALC): `t = (1500-1000)/(2000-1000) = 500/1000 = 0.5`
- Event 2 (RENDERSCENE): `t = (1500-1450)/(1550-1450) = 50/100 = 0.5`

**With spline** (hypothetical):
- If Event 2 had an ease-in-out spline, `t=0.5` might remap to `0.7`
- `prevt=0.49` might remap to `0.68`
- This creates time warping effects (slow-mo, freeze, rewind)

Splines evaluate using `CalculateValue()` which interpolates Hermite/Bezier control points. The result is stored in `Spline->Value[0]` for float16 splines.

## Step 5: Event 0 — Camera Shake

**File**: `Timeline.cpp:355`

```cpp
Events[ x ]->Render( t, prevt, AspectX / (float)AspectY, subroutine );
```

**Call**: `Events[0]->Render(0.5, 0.49, 1.777, false)`

**File**: `Timeline.cpp:280-312` (CphxEvent_CameraShake::Render)

### Step 5a: Deterministic Random Seed Calculation

```cpp
float dist = 1 / (float)ShakesPerSec;
float currTime = CurrentFrame / (float)TimelineFramerate;
float d1 = fmod( currTime, dist );
float d = d1 / dist;
int t1 = (int)( ( currTime - d1 )*TimelineFramerate );
int t2 = (int)( ( currTime - d1 + dist )*TimelineFramerate );
```

Assume `ShakesPerSec = 10` (10 shakes per second).

**Calculation**:
- `dist = 1/10 = 0.1` seconds per shake
- `currTime = 1500/60 = 25.0` seconds since start
- `d1 = fmod(25.0, 0.1) = 0.0` — Position within current shake interval
- `d = 0.0/0.1 = 0.0` — Normalized position [0, 1) within shake
- `t1 = (int)((25.0 - 0.0) * 60) = 1500` — Frame at start of shake interval
- `t2 = (int)((25.0 + 0.1) * 60) = 1506` — Frame at start of next shake interval

These frame numbers become random seeds, ensuring the shake pattern is identical every playback at this frame.

### Step 5b: Generate Random Offsets for Interval Endpoints

```cpp
aholdrand = t1;

D3DXVECTOR3 eo1, eo2, to1, to2;

for ( int x = 0; x < 3; x++ )
{
  eo1[ x ] = arand() / (float)RAND_MAX - 0.5f;
  to1[ x ] = arand() / (float)RAND_MAX - 0.5f;
}

aholdrand = t2;

for ( int x = 0; x < 3; x++ )
{
  eo2[ x ] = arand() / (float)RAND_MAX - 0.5f;
  to2[ x ] = arand() / (float)RAND_MAX - 0.5f;
}
```

**First seed (t1 = 1500)**:
- `arand()` uses linear congruential generator: `aholdrand = aholdrand * 214013L + 2531011L`
- Generate 6 random values centered at 0.0 in range [-0.5, 0.5]
- `eo1` = eye offset at start of shake interval (e.g., `{-0.23, 0.41, -0.08}`)
- `to1` = target offset at start of shake interval (e.g., `{0.15, -0.31, 0.22}`)

**Second seed (t2 = 1506)**:
- Reset seed to frame 1506
- Generate next set of random offsets
- `eo2` = eye offset at end of shake interval (e.g., `{0.18, -0.12, 0.35}`)
- `to2` = target offset at end of shake interval (e.g., `{-0.29, 0.07, -0.16}`)

This gives us two random positions to interpolate between.

### Step 5c: Evaluate Intensity Splines

```cpp
EyeIntensity->CalculateValue( t );
TargetIntensity->CalculateValue( t );
```

At `t = 0.5`, splines evaluate to intensity scalars.

**Example values**:
- `EyeIntensity->Value[0] = 0.8` — 80% strength for eye shake
- `TargetIntensity->Value[0] = 0.3` — 30% strength for target shake

These control how much the shake affects the camera over the event's lifetime. Typically starts at 0, peaks mid-event, returns to 0.

### Step 5d: Interpolate and Apply Intensity

```cpp
EyeOffset = ( ( eo2 - eo1 )*d + eo1 )*EyeIntensity->Value[ 0 ];
TargetOffset = ( ( to2 - to1 )*d + to1 )*TargetIntensity->Value[ 0 ];
```

**Calculation**:
- `d = 0.0` — We're at the start of shake interval
- `EyeOffset = (eo2 - eo1) * 0.0 + eo1) * 0.8 = eo1 * 0.8`
- `EyeOffset = {-0.23, 0.41, -0.08} * 0.8 = {-0.184, 0.328, -0.064}`
- `TargetOffset = to1 * 0.3 = {0.15, -0.31, 0.22} * 0.3 = {0.045, -0.093, 0.066}`

These global variables are now set and will be read by the next RENDERSCENE event.

## Step 6: Event 1 — Particle Calculation

**Call**: `Events[1]->Render(0.5, 0.49, 1.777, false)`

**File**: `Timeline.cpp:236-269` (CphxEvent_ParticleCalc::Render)

### Step 6a: Time-to-Milliseconds Conversion

```cpp
if ( !Scene ) return;

int tme = ( ( EndFrame - StartFrame ) * t + StartFrame ) * 1000.0f / TimelineFramerate;
```

**Calculation**:
- `tme = ((2000 - 1000) * 0.5 + 1000) * 1000.0 / 60`
- `tme = (1000 * 0.5 + 1000) * 16.667`
- `tme = 1500 * 16.667 = 25000` milliseconds

This converts the current frame to absolute milliseconds for delta-time calculations.

### Step 6b: First-Frame Detection

```cpp
if ( !OnScreenLastFrame )
{
  lastt = t;
  lasttime = tme;
  OnScreenLastFrame = true;
}
```

Since Event 1 has been active since frame 1000, `OnScreenLastFrame = true` from previous frames. This block is skipped.

**Purpose**: On the first active frame, initialize tracking variables to prevent a large delta-time jump.

### Step 6c: Scene Graph Updates for Previous and Current Time

```cpp
Scene->UpdateSceneGraph( Clip, lastt );
Scene->UpdateSceneGraph( Clip, t );
```

Updates are called twice:
1. `UpdateSceneGraph(Clip, 0.499)` — Calculate object positions at previous frame
2. `UpdateSceneGraph(Clip, 0.5)` — Calculate object positions at current frame

This stores both `prevMatrix` and `currMatrix` for each object, used for motion blur in particle systems.

**What UpdateSceneGraph does** (simplified):
- Traverse scene hierarchy from root
- Evaluate position/rotation/scale splines at time `t`
- Build transformation matrices
- Calculate world positions for all objects

### Step 6d: Update All CPU Particle Emitters

```cpp
for ( int x = 0; x < Scene->ObjectCount; x++ )
  if ( Scene->Objects[ x ]->ObjectType == Object_ParticleEmitterCPU )
  {
    CphxObject_ParticleEmitter_CPU *p = (CphxObject_ParticleEmitter_CPU*)Scene->Objects[ x ];
    p->UpdateParticles( ( tme - lasttime ) / 1000.0f, false );
  }
```

Assume Scene has 2 objects: a mesh and a particle emitter.

**Loop iteration 0**: Mesh (skipped)
**Loop iteration 1**: ParticleEmitterCPU found

**Delta time calculation**:
- `lasttime = 24983` (from previous frame 1499)
- `tme = 25000` (current frame)
- Delta = `(25000 - 24983) / 1000.0 = 0.017` seconds (one frame at 60fps)

**Call**: `p->UpdateParticles(0.017, false)`

The `false` parameter means "don't update vertex buffer yet"—particles get sorted and buffered later during RENDERSCENE.

**What UpdateParticles does** (high-level):
- Age existing particles (decrement `LifeLeft`)
- Kill particles with `LifeLeft <= 0`
- Spawn new particles based on emission rate
- Apply forces from affectors (gravity, drag, turbulence, vortex)
- Update positions: `Position += Velocity * deltaTime`
- Update rotations: `Rotation += RotationSpeed * deltaTime`

### Step 6e: Store Timestamp for Next Frame

```cpp
lasttime = tme;
lastt = t;
```

Saves `lasttime = 25000` and `lastt = 0.5` for next frame's delta calculation.

## Step 7: Event 2 — Render Scene

**Call**: `Events[2]->Render(0.5, 0.49, 1.777, false)`

**File**: `Timeline.cpp:152-229` (CphxEvent_RenderScene::Render)

This is the most complex event, performing full 3D scene rendering.

### Step 7a: Camera Selection

```cpp
if ( !Scene || ( !Camera && !cameraOverride ) ) return;

CphxObject* actualCamera = cameraOverride ? cameraOverride : Camera;
```

- `Scene` exists (not NULL)
- `cameraOverride = nullptr` (no EVENT_CAMERAOVERRIDE active)
- `Camera` points to a camera object in the scene
- `actualCamera = Camera` — Use event's specified camera

### Step 7b: Dual Scene Graph Update for Motion Blur

```cpp
for ( int x = 0; x < 2; x++ )
{
  phxPrevFrameViewMatrix = phxViewMatrix;
  phxPrevFrameProjectionMatrix = phxProjectionMatrix;

  Scene->UpdateSceneGraph( Clip, x ? t : prevt );
```

**Iteration 0** (`x = 0`):
- Save current view/projection matrices as "previous frame" matrices
- `UpdateSceneGraph(Clip, prevt)` — Update scene at `t = 0.49`
- Builds camera matrices for frame 1499

**Iteration 1** (`x = 1`):
- Save matrices from iteration 0 as "previous frame"
- `UpdateSceneGraph(Clip, t)` — Update scene at `t = 0.5`
- Builds camera matrices for frame 1500

This gives us two sets of matrices for motion blur and temporal effects. Only the second iteration's matrices are used for actual rendering, but both are uploaded to shaders.

### Step 7c: Apply Camera Shake Offset

```cpp
actualCamera->WorldPosition += EyeOffset;
D3DXVECTOR3 eye = actualCamera->WorldPosition;
D3DXVECTOR3 dir = *( (D3DXVECTOR3*)&actualCamera->SplineResults[ Spot_Direction_X ] );
phxCameraPos = D3DXVECTOR4( eye.x, eye.y, eye.z, 1 );
```

**Before shake**:
- `WorldPosition = {5.0, 3.0, -10.0}` (from scene graph update)

**After shake**:
- `EyeOffset = {-0.184, 0.328, -0.064}` (from Event 0)
- `WorldPosition += EyeOffset = {4.816, 3.328, -10.064}`
- `eye = {4.816, 3.328, -10.064}` — Final camera position

**Camera direction**:
- `dir = {0.0, 0.0, 1.0}` — Camera looking down +Z axis
- `phxCameraPos = {4.816, 3.328, -10.064, 1.0}` — Stored for shader upload

### Step 7d: Calculate Camera Roll

```cpp
D3DXMATRIX RollMat;
D3DXVECTOR4 rolledup;
D3DXVec3Transform( &rolledup, (D3DXVECTOR3*)up,
  D3DXMatrixRotationAxis( &RollMat, &dir,
    actualCamera->SplineResults[ Spline_Camera_Roll ] * 3.14159265359f*2.0f ) );
```

**Inputs**:
- `up = {0, 1, 0}` — Default up vector (static global)
- `dir = {0, 0, 1}` — Camera look direction
- `SplineResults[Spline_Camera_Roll] = 0.05` — 5% of full rotation = 18 degrees

**Process**:
1. `Roll * 2π = 0.05 * 6.283 = 0.314` radians
2. Build rotation matrix around `dir` axis
3. Transform `up` vector by roll matrix
4. `rolledup = {-0.309, 0.951, 0.0}` — Rotated up vector

This tilts the camera, creating a Dutch angle effect.

### Step 7e: Build View Matrix with Shake

```cpp
D3DXMatrixLookAtRH( &phxViewMatrix, &( eye ), &( eye + dir + TargetOffset ),
  (D3DXVECTOR3*)&rolledup );
```

**Inputs**:
- `eye = {4.816, 3.328, -10.064}` — Camera position (with shake)
- `eye + dir + TargetOffset = {4.816, 3.328, -10.064} + {0, 0, 1} + {0.045, -0.093, 0.066}`
- `lookAt = {4.861, 3.235, -8.998}` — Target point (with shake)
- `up = {-0.309, 0.951, 0.0}` — Rolled up vector

**View matrix** (right-handed):
```
[ right.x    right.y    right.z   -dot(right, eye) ]
[ up.x       up.y       up.z      -dot(up, eye)    ]
[ -forward.x -forward.y -forward.z dot(forward, eye) ]
[ 0          0          0         1                ]
```

The shake affects both the camera position (EyeOffset) and where it's looking (TargetOffset), creating a realistic shake with independent eye and target wobble.

### Step 7f: Build Off-Center Projection Matrix

```cpp
float fovYper2 = ( actualCamera->SplineResults[ Spline_Camera_FOV ] * 3.14159265359f / 4.0f ) / 2.0f;
float zn = 0.01f;
float cotFov = cos( fovYper2 ) / sin( fovYper2 );
float t = zn / cotFov;
float r = zn * aspect / cotFov;
float xOffset = actualCamera->camCenterX / 127.0f * r;
float yOffset = actualCamera->camCenterY / 127.0f * t;

D3DXMatrixPerspectiveOffCenterRH( &phxProjectionMatrix,
  -r + xOffset, r + xOffset, -t + yOffset, t + yOffset, zn, 2000.0f );
```

**FOV calculation**:
- `SplineResults[Spline_Camera_FOV] = 1.0` — Normalized FOV value
- `FOV in radians = 1.0 * π/4 = 0.785` radians (45 degrees)
- `fovYper2 = 0.785 / 2 = 0.393` — Half vertical FOV

**Frustum dimensions at near plane**:
- `zn = 0.01` — Near clip plane distance
- `cotFov = cos(0.393) / sin(0.393) = 0.924 / 0.383 = 2.414`
- `t = 0.01 / 2.414 = 0.00414` — Half-height at near plane
- `r = 0.01 * 1.777 / 2.414 = 0.00736` — Half-width at near plane

**Off-center shift** (for lens shift effects):
- `camCenterX = 10` (signed char) — Shift right
- `camCenterY = -5` (signed char) — Shift down
- `xOffset = 10 / 127.0 * 0.00736 = 0.00058`
- `yOffset = -5 / 127.0 * 0.00414 = -0.00016`

**Frustum bounds**:
- Left: `-0.00736 + 0.00058 = -0.00678`
- Right: `0.00736 + 0.00058 = 0.00794`
- Bottom: `-0.00414 - 0.00016 = -0.00430`
- Top: `0.00414 - 0.00016 = 0.00398`
- Near: `0.01`
- Far: `2000.0`

This creates an asymmetric frustum, used for cinematic lens effects like tilt-shift.

### Step 7g: Sort Particles for Depth Ordering

```cpp
#ifdef PHX_OBJ_EMITTERCPU
  {
    for ( int x = 0; x < Scene->ObjectCount; x++ )
      if ( Scene->Objects[ x ]->ObjectType == Object_ParticleEmitterCPU )
      {
        CphxObject_ParticleEmitter_CPU *p = (CphxObject_ParticleEmitter_CPU*)Scene->Objects[ x ];
        p->UpdateParticles( 0, true );
      }
  }
#endif
```

**Call**: `p->UpdateParticles(0, true)`
- `deltaTime = 0` — No simulation, just buffer update
- `updatebuffer = true` — Sort particles and upload to GPU

**Sorting process**:
1. Calculate distance from each particle to camera
2. Store `{index, distance}` pairs in DistanceBuffer
3. Quicksort by distance (back-to-front for alpha blending)
4. Build vertex buffer with sorted particles
5. Upload to GPU via `Map(D3D11_MAP_WRITE_DISCARD)`

This ensures transparent particles render correctly without a depth buffer.

### Step 7h: Render the Scene

```cpp
Scene->Render( ClearColor, ClearZ, 0 );
```

**File**: `Scene.cpp:135-203`

This is where 3D geometry actually gets rasterized.

#### 7h-1: Calculate Inverse Matrices

```cpp
SetSamplers();

D3DXMatrixInverse( &phxIViewMatrix, NULL, &phxViewMatrix );
D3DXMatrixInverse( &phxIProjectionMatrix, NULL, &phxProjectionMatrix );
```

Inverse matrices are needed for:
- Screen-space to world-space transformations (ray picking, deferred shading)
- Reconstructing world position from depth buffer
- Normal mapping in tangent space

#### 7h-2: Loop Through Render Layers

```cpp
for ( int x = 0; x < LayerCount; x++ )
{
  RenderLayers[ x ]->Descriptor->SetEnvironment( ClearColor, ClearZ, cubeResolution );
```

**Layers organize rendering by material properties**:
- Layer 0: Opaque geometry (depth write enabled)
- Layer 1: Alpha-blended particles (depth write disabled)
- Layer 2: Additive emissive materials (additive blending)

**SetEnvironment** (sets render targets and clears):
- Binds render target(s) for this layer
- Optionally clears color to black (if `ClearColor = true`)
- Optionally clears depth to 1.0 (if `ClearZ = true`)
- Sets viewport to render target resolution

#### 7h-3: Upload Scene-Level Constant Buffer

```cpp
D3D11_MAPPED_SUBRESOURCE map;
phxContext->Map( SceneDataBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &map );
unsigned char* m = (unsigned char*)map.pData;

float LightCountData[ 4 ];
LightCountData[ 0 ] = (float)LightCount;

memcpy( m, &phxViewMatrix, sizeof( phxViewMatrix ) ); m += sizeof( phxViewMatrix );
memcpy( m, &phxProjectionMatrix, sizeof( phxProjectionMatrix ) ); m += sizeof( phxProjectionMatrix );
memcpy( m, &phxCameraPos, sizeof( phxCameraPos ) ); m += sizeof( phxCameraPos );
memcpy( m, &LightCountData, sizeof( LightCountData ) ); m += sizeof( LightCountData );
memcpy( m, Lights, sizeof( LIGHTDATA )*MAX_LIGHT_COUNT ); m += sizeof( LIGHTDATA )*MAX_LIGHT_COUNT;
```

**SceneDataBuffer layout**:
- Offset 0: `phxViewMatrix` (64 bytes) — Camera world-to-view transform
- Offset 64: `phxProjectionMatrix` (64 bytes) — View-to-clip transform
- Offset 128: `phxCameraPos` (16 bytes) — Camera world position {x, y, z, 1}
- Offset 144: `LightCountData` (16 bytes) — Number of lights in `{count, 0, 0, 0}`
- Offset 160: `Lights` (1024 bytes) — Array of 8 LIGHTDATA structs

**LIGHTDATA struct** (128 bytes each):
```
struct LIGHTDATA
{
  D3DXVECTOR4 Position;      // 16 bytes
  D3DXVECTOR4 Ambient;       // 16 bytes
  D3DXVECTOR4 Diffuse;       // 16 bytes
  D3DXVECTOR4 Specular;      // 16 bytes
  D3DXVECTOR4 SpotDirection; // 16 bytes
  D3DXVECTOR4 SpotData;      // 16 bytes (exponent, cutoff, linear, quadratic)
};
```

**Render target resolution**:
```cpp
float RTResolution[ 4 ];

if ( RenderLayers[ x ]->Descriptor->TargetCount )
{
  RTResolution[ 0 ] = (float)RenderLayers[ x ]->Descriptor->Targets[ 0 ]->XRes;
  RTResolution[ 1 ] = (float)RenderLayers[ x ]->Descriptor->Targets[ 0 ]->YRes;
  RTResolution[ 2 ] = 1 / RTResolution[ 0 ];
  RTResolution[ 3 ] = 1 / RTResolution[ 1 ];
}

memcpy( m, RTResolution, 16 ); m += 16;
```

For Layer 0 rendering to RT0:
- `RTResolution = {1920.0, 1080.0, 0.00052, 0.00093}`
- Shaders use this for screen-space calculations (pixel-to-UV conversion)

**Inverse matrices**:
```cpp
memcpy( m, &phxIViewMatrix, sizeof( phxIViewMatrix ) ); m += sizeof( phxIViewMatrix );
memcpy( m, &phxIProjectionMatrix, sizeof( phxIProjectionMatrix ) );
  m += sizeof( phxIProjectionMatrix );

phxContext->Unmap( SceneDataBuffer, 0 );
```

Total buffer size: ~1300 bytes

#### 7h-4: Bind Constant Buffers to All Shader Stages

```cpp
for ( int y = 0; y < 2; y++ )
{
  ID3D11Buffer *Buffer = y ? ObjectMatrixBuffer : SceneDataBuffer;
  phxContext->VSSetConstantBuffers( y, 1, &Buffer );
  phxContext->GSSetConstantBuffers( y, 1, &Buffer );
  phxContext->PSSetConstantBuffers( y, 1, &Buffer );
}
```

**Binding layout**:
- Slot 0: `SceneDataBuffer` — Scene-level data (camera, lights)
- Slot 1: `ObjectMatrixBuffer` — Per-object data (world matrix, material params)

All three shader stages (VS, GS, PS) can access both buffers.

#### 7h-5: Render All Instances in Layer

```cpp
for ( int y = 0; y < RenderLayers[ x ]->RenderInstances.NumItems(); y++ )
  RenderLayers[ x ]->RenderInstances[ y ]->Render();
```

**What's a RenderDataInstance?**

Each visible mesh in the scene creates one or more instances. For example:
- Sphere mesh with Material A → RenderDataInstance 0 in Layer 0
- Particle system with Material B → RenderDataInstance 1 in Layer 1
- Cube mesh with Material A → RenderDataInstance 2 in Layer 0

Instances are sorted by `RenderPriority` (higher priority renders first). This handles render order for transparency.

**File**: `RenderLayer.cpp` (CphxRenderDataInstance::Render)

```cpp
void CphxRenderDataInstance::Render()
{
  phxContext->VSSetShader( VS, NULL, 0 );
  phxContext->PSSetShader( PS, NULL, 0 );
  phxContext->GSSetShader( GS, NULL, 0 );
  phxContext->HSSetShader( HS, NULL, 0 );
  phxContext->DSSetShader( DS, NULL, 0 );

  phxContext->RSSetState( RasterizerState );
  phxContext->OMSetBlendState( BlendState, NULL, 0xffffffff );
  phxContext->OMSetDepthStencilState( DepthStencilState, 0 );
```

**Bind shaders**:
- VS: Vertex shader (transforms vertices)
- PS: Pixel shader (calculates final color)
- GS: Geometry shader (usually NULL, used for point sprites)
- HS/DS: Hull/Domain shaders (NULL unless tessellation)

**Bind render states**:
- `RasterizerState`: Cull mode, fill mode, depth clip
- `BlendState`: Alpha blending equation
- `DepthStencilState`: Depth test, depth write, stencil ops

```cpp
  phxContext->PSSetShaderResources( 0, 8, Textures );

  D3D11_MAPPED_SUBRESOURCE map;
  phxContext->Map( ObjectMatrixBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &map );
  memcpy( ( (unsigned char*)map.pData ), Matrices, sizeof( Matrices ) );
  memcpy( ( (unsigned char*)map.pData ) + sizeof( Matrices ), MaterialData,
    sizeof( MaterialData ) );
  phxContext->Unmap( ObjectMatrixBuffer, 0 );
```

**Upload per-object data**:
- `Matrices[0]` = Current frame world matrix (64 bytes)
- `Matrices[1]` = Previous frame world matrix (64 bytes, for motion blur)
- `MaterialData` = Animated material parameters (up to 3584 bytes)

**Example MaterialData contents**:
- Offset 0: Base color `{1.0, 0.5, 0.2, 1.0}` (16 bytes)
- Offset 16: Roughness `0.3` (4 bytes)
- Offset 20: Metallic `0.8` (4 bytes)
- Offset 32: UV scale `{2.0, 2.0}` (8 bytes)

```cpp
  UINT strides[] = { MESHDATASIZE };
  UINT offsets[] = { 0 };
  phxContext->IASetVertexBuffers( 0, 1, &VertexBuffer, strides, offsets );
  phxContext->IASetPrimitiveTopology( D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST );

  if ( Indexed )
  {
    phxContext->IASetIndexBuffer( IndexBuffer, DXGI_FORMAT_R32_UINT, 0 );
    phxContext->DrawIndexed( TriIndexCount, 0, 0 );
  }
  else
  {
    phxContext->Draw( TriIndexCount, 0 );
  }
```

**Draw call**:
- Bind vertex buffer (positions, normals, UVs, tangents)
- If indexed, use index buffer to avoid duplicate vertices
- `DrawIndexed(TriIndexCount, 0, 0)` — Render triangles

This is the actual GPU work: vertices flow through VS → GS → rasterizer → PS, writing to the render target.

**Wireframe rendering** (if enabled):
```cpp
  if ( Wireframe )
  {
    phxContext->IASetIndexBuffer( WireBuffer, DXGI_FORMAT_R32_UINT, 0 );
    phxContext->DrawIndexed( WireIndexCount, 0, 0 );
  }
```

Wireframe uses a separate index buffer that renders lines instead of filled triangles.

```cpp
  static ID3D11ShaderResourceView *rv[ 8 ] = { 0, 0, 0, 0, 0, 0, 0, 0 };
  phxContext->PSSetShaderResources( 0, 8, rv );
}
```

**Unbind textures**: Prevents resource hazards where a texture is both read and written in the same pass.

#### 7h-6: Generate Mipmaps

```cpp
RenderLayers[ x ]->Descriptor->GenMipmaps();
```

After all instances render to a layer's render target, generate mipmap chain for texture filtering. Uses `GenerateMips()` on each target's shader resource view.

### Step 7i: Update Timeline Target Tracking

**File**: `Timeline.cpp:357-358`

```cpp
Target = Events[ x ]->Target;
Events[ x ]->OnScreenLastFrame = true;
```

After Event 2 (RENDERSCENE) completes:
- `Target = Events[2]->Target` — Points to RT0 (1920x1080)
- `OnScreenLastFrame = true` — Event was active this frame

This `Target` will be used in the final blit to backbuffer.

## Step 8: Final Backbuffer Blit

**File**: `Timeline.cpp:363-375`

After all events have rendered, the timeline composites the final image.

```cpp
if ( Target && !tool )
{
  Prepare2dRender();
  phxContext->PSSetShader( RenderPixelShader, NULL, 0 );

  D3D11_VIEWPORT v = { ( ScreenX - Target->XRes ) / 2.0f,
                       ( ScreenY - Target->YRes ) / 2.0f,
                       (float)Target->XRes, (float)Target->YRes, 0, 1 };
  phxContext->RSSetViewports( 1, &v );
```

**Prepare2dRender** (setup for fullscreen quad):
- Binds a vertex shader that generates clip-space quad from vertex ID
- Binds null vertex buffer (vertices generated in shader)
- Sets topology to triangle list
- Binds point sampler for texture lookups

**Pixel shader**:
- `RenderPixelShader` — Simple passthrough: `output.color = texture.Sample(sampler, input.uv)`

**Viewport calculation**:
- `ScreenX = 1920`, `ScreenY = 1080` — Physical display resolution
- `Target->XRes = 1920`, `Target->YRes = 1080` — Render target resolution
- `x = (1920 - 1920) / 2 = 0`
- `y = (1080 - 1080) / 2 = 0`
- Viewport: `{0, 0, 1920, 1080, 0, 1}` — Full screen, no letterboxing

If the render target was smaller (e.g., 1280x720), the viewport would be centered with black bars.

```cpp
  phxContext->OMSetRenderTargets( 1, &phxBackBufferView, NULL );
  phxContext->PSSetShaderResources( 0, 1, &Target->View );
  phxContext->Draw( 6, 0 );
  phxContext->PSSetShaderResources( 0, 1, rv );
}
```

**Final blit**:
1. Bind backbuffer as render target (no depth buffer)
2. Bind RT0's shader resource view to texture slot 0
3. Draw 6 vertices → 2 triangles → fullscreen quad
4. Pixel shader samples RT0 and writes to backbuffer
5. Unbind texture to prevent resource hazards

The vertex shader generates quad positions:
```
Vertex 0: {-1, -1} → {0, 1}   Bottom-left
Vertex 1: { 1, -1} → {1, 1}   Bottom-right
Vertex 2: {-1,  1} → {0, 0}   Top-left
Vertex 3: {-1,  1} → {0, 0}   Top-left
Vertex 4: { 1, -1} → {1, 1}   Bottom-right
Vertex 5: { 1,  1} → {1, 0}   Top-right
```

This produces two triangles covering the entire screen in clip space.

## Step 9: Output

At this point, the frame is complete:
- Backbuffer contains the final composited image
- RT0 contains the scene render (1920x1080)
- RT1 is still clear (no events wrote to it this frame)
- Depth buffer contains final depth values

**Next steps in engine**:
1. Present backbuffer to swap chain → displays on monitor
2. Advance to frame 1501
3. Entire process repeats

## Key Insights for Framework Design

### 1. Declarative Timeline Events

Phoenix's timeline isn't imperative ("run this code at frame 1500"). It's declarative ("these events are active in these frame ranges"). Each event calculates its state based on normalized time `t ∈ [0, 1)`.

**Rust equivalent**:
```rust
pub trait TimelineEvent {
    fn render(&mut self, ctx: &RenderContext, t: f32, prev_t: f32, aspect: f32);
    fn frame_range(&self) -> Range<u32>;
}
```

### 2. Global Camera Shake State

Using global variables (`EyeOffset`, `TargetOffset`) allows camera shake to affect any RENDERSCENE event without explicit connections. Events communicate through shared state.

**Pattern**: Write-once-read-many per frame. Shake events write offsets early, render events read them later. Cleared to zero each frame.

**Rust equivalent**:
```rust
pub struct FrameContext {
    pub eye_offset: Vec3,
    pub target_offset: Vec3,
    pub camera_override: Option<CameraHandle>,
}
```

### 3. Deterministic Randomness for Shakes

Frame number as random seed ensures:
- Identical shake pattern every playback
- Scrubbing backwards shows exact same shake
- No state accumulation or drift

**Critical for demos**: Must be perfectly reproducible for competitions.

### 4. Motion Blur via Dual Scene Graph Updates

Rendering at both `t` and `prevt` stores two complete sets of matrices. Shaders can interpolate vertex positions across frames for temporal effects.

**Cost**: 2x scene graph traversal per frame, but enables true motion blur without hacks.

### 5. Time Spline Remapping

Separating linear timeline time from event-local time allows:
- Slow-motion effects (compress 100 frames into 200 event-time)
- Freeze frames (flat spline segment)
- Time reversal (negative spline slope)

**Event designers don't know they're time-warped**—they just receive `t ∈ [0, 1)`.

### 6. Render Target Clearing Philosophy

Clear all targets at frame start, not per-event. This prevents partial clearing bugs and makes multi-pass effects explicit. If an event needs to preserve a target, it must explicitly avoid clearing.

### 7. Particle Sorting Deferred Until Render

`EVENT_PARTICLECALC` simulates particles but doesn't sort them. `EVENT_RENDERSCENE` triggers sorting right before draw. This separates simulation frequency from rendering.

**Why**: Particles might be calculated at 25fps but rendered at 60fps, with sorting happening only when visible.

### 8. Letterboxing in Final Blit

Viewport calculation handles resolution mismatch between render target and display. Demo can render at 1280x720 for performance, but display on 1920x1080 screen with pillarboxing.

**Preserves aspect ratio**: No stretching, just black bars.

### 9. Scene-Level vs Object-Level Data Split

Two constant buffers:
- `SceneDataBuffer` (slot 0): Rarely changes (camera, lights)
- `ObjectMatrixBuffer` (slot 1): Changes per draw call (world matrix, material)

**Optimization**: Reduce bandwidth by only updating object buffer per instance.

### 10. Render Layers for Draw Order

Instead of sorting all geometry by depth, Phoenix groups by material properties (opaque, transparent, additive) into layers. Each layer renders in priority order.

**Benefits**:
- Minimize state changes (all opaque objects share depth write enabled)
- Explicit control over blend order
- Easier to optimize (e.g., depth pre-pass for layer 0)

## Performance Characteristics

For frame 1500 with our scenario:

**Timeline overhead**: ~50 instructions
- 3 frame range checks
- 3 time normalizations
- 6 time spline lookups

**Event 0 (CAMERASHAKE)**: ~200 instructions
- 2 random seed calculations
- 12 random number generations
- 2 spline evaluations
- 6 vector lerps

**Event 1 (PARTICLECALC)**: ~10,000 instructions per 100 particles
- Scene graph traversal: 2 × O(objects)
- Particle updates: O(particles) × O(affectors)
- No GPU work

**Event 2 (RENDERSCENE)**: ~1,000,000 instructions + GPU work
- Scene graph traversal: 2 × O(objects)
- Matrix inversions: 2 × 64 multiplies
- Constant buffer uploads: 3 × ~1KB
- Draw calls: O(render instances)
- GPU: O(triangles × pixels)

**Final blit**: ~100 instructions + GPU fullscreen quad

**Total CPU time**: ~1-2ms on modern hardware
**Total GPU time**: ~5-15ms depending on scene complexity

## Edge Cases and Gotchas

### 1. Event Overlap Order Matters

If two RENDERSCENE events overlap and render to the same target, the later event in the array wins. No blending—just overwrite.

**Solution**: Use different render targets or ensure non-overlapping frame ranges.

### 2. Camera Override Lasts Until Next RENDERSCENE

`cameraOverride` is reset to NULL at frame start, then potentially set by EVENT_CAMERAOVERRIDE. All subsequent RENDERSCENE events in that frame use the override.

**Gotcha**: If CAMERAOVERRIDE comes after a RENDERSCENE in the event array, it won't affect that render. Event order matters.

### 3. Time Spline Discontinuities

If a time spline has a vertical segment (discontinuous derivative), `prevt` and `t` might map to the same event-time, causing zero delta. Motion blur breaks.

**Solution**: Avoid discontinuous time splines, or clamp delta to minimum threshold.

### 4. Particle Simulation Without Rendering

If a PARTICLECALC event is active but no RENDERSCENE renders that scene, particles still update. This wastes CPU.

**Design pattern**: Match PARTICLECALC and RENDERSCENE frame ranges, or use nested RENDERDEMO events.

### 5. Viewport Letterboxing Doesn't Clear Bars

The final blit only renders to the viewport region. If the backbuffer was cleared to black earlier, bars are black. If not cleared, bars show garbage.

**Fix**: Always clear backbuffer at frame start (line 333).

### 6. Render Target Resolution Must Match Shader Expectations

If a shader expects 1920×1080 but renders to 512×512, screen-space effects break. RTResolution in constant buffer must be accurate.

**Phoenix solution**: Upload target resolution in SceneDataBuffer so shaders can adapt.

### 7. Mipmap Generation Requires Complete Mip Chain

`GenerateMips()` fails if the render target wasn't created with `D3D11_RESOURCE_MISC_GENERATE_MIPS`. Easy to forget during setup.

### 8. Frame 1500 vs Frame 1500.5

Events use `(int)Frame` for range checks. If you call `Render(1500.5, ...)`, it gets truncated to 1500. This means sub-frame interpolation doesn't affect event activation, only `t` calculation.

**Design choice**: Events are frame-quantized, but their internal animation is smooth.

## References

**Source files**:
- `demoscene/apex-public/apEx/Phoenix/Timeline.h` — Event type definitions
- `demoscene/apex-public/apEx/Phoenix/Timeline.cpp` — Timeline renderer and event implementations
- `demoscene/apex-public/apEx/Phoenix/Scene.h` — Scene graph object types
- `demoscene/apex-public/apEx/Phoenix/Scene.cpp` — Scene rendering and traversal
- `demoscene/apex-public/apEx/Phoenix/RenderLayer.h` — Render instance abstraction

**Related documentation**:
- `notes/per-demoscene/apex-public/rendering-pipeline.md` — High-level rendering overview
- `notes/per-demoscene/apex-public/architecture.md` — System organization
- `notes/per-demoscene/apex-public/code-traces/material-render.md` — Material system details
