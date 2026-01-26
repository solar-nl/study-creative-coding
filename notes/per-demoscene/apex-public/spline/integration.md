# Phoenix Spline Integration

Splines don't exist in isolation—they're the universal parameter driver for the entire demo scene. Every animatable property routes through the spline system: object transforms, camera motion, light intensity, particle emission rates, material parameters. The genius of Phoenix's architecture is that these 57 different use cases all use the same evaluation infrastructure. Whether animating a quaternion rotation or a scalar light cutoff angle, the flow is identical: evaluate spline, store result, consume in rendering.

This integration happens through a type-tagged system. Each spline has a `PHXSPLINETYPE` enum value declaring what it controls—position X, camera FOV, particle velocity, material roughness. Objects store clips containing spline arrays. During scene graph traversal, each object evaluates its active clip's splines and stores results in a 57-element array. Specialized subsystems then read from this array to configure transforms, lights, cameras, particle systems, and materials.

The brilliance lies in decoupling. The spline system doesn't know about transforms or cameras. The transform system doesn't know about keyframe interpolation. The glue is a simple contract: splines write to indexed slots, consumers read from indexed slots. This makes animation orthogonal to behavior—you can animate any parameter without modifying the renderer, particle system, or material evaluator.

Think of `SplineResults[]` like a message bus. Splines are publishers writing to numbered channels. Render systems are subscribers reading from channels they care about. A camera reads channels 33-34 (FOV + roll). A spotlight reads channels 24-26, 28-29 (direction + cone parameters). A particle emitter reads channels 37-47 (position offset through life chaos). The timeline orchestrates everything by calling `CalculateAnimation()` each frame, which evaluates all active splines and updates the bus.

## The PHXSPLINETYPE Taxonomy

Scene.h:17-92 defines the complete enumeration of animatable properties. The 57 types span seven categories, organized roughly by subsystem. Some indices have padding gaps—these represent alignment or reserved slots for future expansion.

### Transform Splines (Types 1-4, 8-11)

These control object position, rotation, and scale in local space. The scene graph accumulates these transforms hierarchically.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 1 | `Spline_Scale_x` | Object scale on X axis | 1.0 | 0.0 → ∞ |
| 2 | `Spline_Scale_y` | Object scale on Y axis | 1.0 | 0.0 → ∞ |
| 3 | `Spline_Scale_z` | Object scale on Z axis | 1.0 | 0.0 → ∞ |
| 4 | `Spline_Rotation` | Quaternion rotation (4 values) | (0,0,0,1) | normalized |
| 8 | `Spline_Position_x` | Position on X axis | 0.0 | -∞ → ∞ |
| 9 | `Spline_Position_y` | Position on Y axis | 0.0 | -∞ → ∞ |
| 10 | `Spline_Position_z` | Position on Z axis | 0.0 | -∞ → ∞ |
| 11 | `Spline_Position_w` | Reserved / unused | 0.0 | — |

**Implementation note:** Type 4 (rotation) is special. Instead of storing its result in `SplineResults[4]`, quaternions write to a dedicated `RotationResult` member (Scene.h:153). This separation exists because quaternions need 4 floats, and mixing them with scalar results complicates indexing. Scene.cpp:304 shows the special case:

```cpp
if (s->Type == Spline_Rotation)
    RotationResult = s->Spline->GetQuaternion();
```

The position W component is never used—it exists as padding to align the position block to 4 floats. Some early code may have experimented with homogeneous coordinates, but the current engine ignores it.

### SubScene Control (Types 5-6, 55-56)

SubScene objects are like compositing layers—they instantiate entire scene hierarchies within a parent scene. These splines control which scene plays, at what time, and with what instancing parameters.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 5 | `Spline_SubScene_Clip` | Which clip index to render | 0 | 0 → clipCount-1 |
| 6 | `Spline_SubScene_Time` | Time offset within the subscene | 0.0 | 0.0 → 1.0 |
| 55 | `Spline_SubScene_RepeatCount` | Number of instances to create | 1 | 1 → ∞ |
| 56 | `Spline_SubScene_RepeatTimeOffset` | Time delta between instances | 0.0 | 0.0 → 1.0 |

**Clip animation** (type 5) is integer-valued but uses float splines. A value of 1.5 gets truncated to clip index 1. This allows smooth blending tricks—set interpolation to `CONSTANT` to switch clips at precise keyframes, or use `LINEAR` for time-remapped crossfades.

**Instancing** (types 55-56) enables effects like trailing echoes. Set `RepeatCount` to 10 and `RepeatTimeOffset` to 0.1, and you get 10 copies of the subscene, each offset by 0.1 seconds in timeline. The first instance plays at T, the second at T+0.1, the third at T+0.2, creating a temporal clone army.

### Camera Parameters (Types 33-34)

Only two spline types affect cameras because most camera behavior comes from transform splines (position, rotation). These handle lens properties.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 33 | `Spline_Camera_FOV` | Field of view angle (radians) | 1.0 | 0.1 → π |
| 34 | `Spline_Camera_Roll` | Camera roll rotation (radians) | 0.0 | -π → π |

**FOV animation** creates dramatic zoom effects without moving the camera. Increase FOV for a wide-angle panic shot, decrease for telephoto compression. The default of 1.0 represents ~57 degrees—roughly human eye perspective.

**Roll animation** tilts the horizon. Useful for disorientation effects, banking during camera flight paths, or Dutch angles in dramatic moments.

### Light Color (Types 12-14, 16-18, 20-22)

Lights use three separate RGB triplets for ambient, diffuse, and specular contributions. This follows classic Phong/Blinn-Phong lighting models.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 12 | `Spline_Light_AmbientR` | Ambient red channel | 0.0 | 0.0 → ∞ |
| 13 | `Spline_Light_AmbientG` | Ambient green channel | 0.0 | 0.0 → ∞ |
| 14 | `Spline_Light_AmbientB` | Ambient blue channel | 0.0 | 0.0 → ∞ |
| 16 | `Spline_Light_DiffuseR` | Diffuse red channel | 1.0 | 0.0 → ∞ |
| 17 | `Spline_Light_DiffuseG` | Diffuse green channel | 1.0 | 0.0 → ∞ |
| 18 | `Spline_Light_DiffuseB` | Diffuse blue channel | 1.0 | 0.0 → ∞ |
| 20 | `Spline_Light_SpecularR` | Specular red channel | 1.0 | 0.0 → ∞ |
| 21 | `Spline_Light_SpecularG` | Specular green channel | 1.0 | 0.0 → ∞ |
| 22 | `Spline_Light_SpecularB` | Specular blue channel | 1.0 | 0.0 → ∞ |

Scene.cpp:280-285 sets default diffuse and specular to 1.0, ambient to 0.0. This gives neutral white lighting with no ambient fill. Animate these to create color-shifting lights—warm to cool transitions, pulsing saturation, chromatic strobes.

Values exceeding 1.0 are valid and create HDR lighting. A diffuse of 10.0 creates an intense hotspot that blooms during post-processing.

### Light Spot/Attenuation (Types 24-31, 48-49)

Spotlights and distance-based light falloff use these parameters.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 24 | `Spot_Direction_X` | Spot direction X component | 0.0 | -1.0 → 1.0 |
| 25 | `Spot_Direction_Y` | Spot direction Y component | 0.0 | -1.0 → 1.0 |
| 26 | `Spot_Direction_Z` | Spot direction Z component | 0.0 | -1.0 → 1.0 |
| 28 | `Spline_Light_Exponent` | Spot falloff sharpness | 0.0 | 0.0 → 128 |
| 29 | `Spline_Light_Cutoff` | Spot cone angle (radians) | 0.0 | 0.0 → π/2 |
| 30 | `Spline_Light_Attenuation_Linear` | Linear distance falloff | 0.0 | 0.0 → 1.0 |
| 31 | `Spline_Light_Attenuation_Quadratic` | Quadratic distance falloff | 0.0 | 0.0 → 1.0 |
| 48 | `Spline_Light_OrthoX` | Shadow map ortho width | 1.0 | 0.0 → ∞ |
| 49 | `Spline_Light_OrthoY` | Shadow map ortho height | 1.0 | 0.0 → ∞ |

**Spot direction** defines where the cone points in object-local space. If the light object rotates, the cone rotates with it. Alternatively, animate direction splines to sweep the spotlight without rotating the object.

**Exponent** controls the falloff gradient from cone center to edge. 0 creates uniform illumination across the cone. Higher values create a focused center hotspot with rapid falloff.

**Cutoff** is the cone half-angle in radians. A cutoff of π/4 (45 degrees) creates a 90-degree cone. Animate this to expand/contract the spotlight.

**Attenuation** implements `1 / (constant + linear*d + quadratic*d²)` distance falloff. Linear attenuation creates even fading; quadratic creates physically-accurate inverse-square falloff. These don't default to 1.0—zero means infinite range.

**Ortho shadow dimensions** (types 48-49) control the shadow map frustum for directional shadows. Larger values cover more area but reduce shadow resolution.

### Particle Emitter (Types 37-47, 51-54)

The particle system exposes 18 animatable parameters covering emission, motion, and appearance.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 37 | `Spline_Particle_Offset_x` | Emission offset X | 0.0 | -∞ → ∞ |
| 38 | `Spline_Particle_Offset_y` | Emission offset Y | 0.0 | -∞ → ∞ |
| 39 | `Spline_Particle_Offset_z` | Emission offset Z | 0.0 | -∞ → ∞ |
| 40 | `Spline_Particle_EmissionPerSecond` | Emission rate (particles/sec) | 25.0 | 0.0 → ∞ |
| 41 | `Spline_Particle_EmissionTrigger` | Burst trigger threshold | 0.0 | 0.0 → 1.0 |
| 42 | `Spline_Particle_EmissionVelocity` | Initial velocity magnitude | 1.0 | 0.0 → ∞ |
| 43 | `Spline_Particle_Life` | Particle lifetime (frames) | 10.0 | 0.0 → ∞ |
| 44 | `Spline_Particle_EmissionRotation` | Initial rotation angle | 0.0 | -π → π |
| 45 | `Spline_Particle_EmissionVelocityChaos` | Velocity randomness | 0.0 | 0.0 → 1.0 |
| 46 | `Spline_Particle_EmissionRotationChaos` | Rotation randomness | 0.0 | 0.0 → 1.0 |
| 47 | `Spline_Particle_LifeChaos` | Lifetime randomness | 0.0 | 0.0 → 1.0 |
| 51 | `Spline_Particle_Scale` | Particle scale multiplier | 1.0 | 0.0 → ∞ |
| 52 | `Spline_Particle_ScaleChaos` | Scale randomness | 0.0 | 0.0 → 1.0 |
| 53 | `Spline_Particle_Stretch_X` | Stretch factor X axis | 1.0 | 0.0 → ∞ |
| 54 | `Spline_Particle_Stretch_Y` | Stretch factor Y axis | 1.0 | 0.0 → ∞ |

Scene.cpp:293-294 sets unusual defaults: emission rate defaults to 25 particles/second, lifetime defaults to 10 frames (at 25fps = 0.4 seconds). This creates a continuous stream of short-lived particles.

**Chaos parameters** (types 45-47, 52) add per-particle randomness. A chaos value of 0.5 means each particle's value varies ±50% from the base value. Scene.cpp doesn't set chaos defaults, so they remain zero (deterministic emission).

**Emission trigger** (type 41) enables burst modes. When the spline value crosses a threshold (typically 0.5), the emitter spawns particles immediately. Animate a square wave on this channel to create rhythmic bursts.

**Stretch parameters** (types 53-54) elongate particles along local axes. Motion-blur effects use high X-stretch aligned with velocity. Billboard flame particles use Y-stretch to create vertical plumes.

### Affector Power (Type 50)

Particle affectors (gravity, drag, turbulence, vortex) use this single spline to modulate force strength.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 50 | `Spline_AffectorPower` | Force strength multiplier | 1.0 | 0.0 → ∞ |

Scene.cpp:288 defaults this to 1.0, meaning full-strength forces. Animate from 0 to 1 to gradually introduce wind turbulence. Pulse between 0 and 2 to create rhythmic gusts. Negative values aren't explicitly forbidden but produce reversed forces—gravity becomes anti-gravity.

### Material Parameters (Type 0)

Type 0 is the only spline type that targets multiple different properties. It's a wildcard connected to specific material parameters via `MaterialParam` pointers.

| Index | Name | Purpose | Default | Range |
|-------|------|---------|---------|-------|
| 0 | `Spline_MaterialParam` | Dynamic material property | (varies) | (varies) |

When `Type == Spline_MaterialParam`, the `CphxClipSpline` structure contains a `MaterialParam` pointer (Scene.h:117) identifying which shader constant to animate. This enables animating roughness, metalness, emissive intensity, UV scrolling offsets, blend factors—anything exposed as a material parameter.

The material system handles these splines separately through `CphxMaterialSplineBatch` (discussed below). They don't write to `SplineResults[0]`—instead they write directly to material parameter values.

## CphxClipSpline: Spline Metadata

Scene.h:113-119 defines the structure that binds splines to properties:

```cpp
struct CphxClipSpline {
    PHXSPLINETYPE Type;
    CphxSpline *Spline;
    CphxMaterialParameter *MaterialParam;
    void *GroupingData;
};
```

**Type** identifies which property this spline drives (0-56). This determines where the evaluated value gets stored and which subsystem consumes it.

**Spline** points to the actual `CphxSpline` object containing keys, interpolation settings, and evaluation logic. This is polymorphic—could be `CphxSpline_float16` for scalars or `CphxSpline_Quaternion16` for rotations.

**MaterialParam** is only valid when `Type == Spline_MaterialParam`. It points to the specific material parameter structure this spline modulates. For all other types, this is NULL.

**GroupingData** enables batch operations. When a model has multiple materials, each material's parameters might have separate spline batches. The grouping pointer identifies which batch this spline belongs to. This is an opaque `void*`—the material system casts it to internal structures.

The structure is compact (16 bytes on 32-bit systems, 24 on 64-bit) because clips contain arrays of these. A complex animated object might have 20 splines per clip across 10 clips = 200 instances.

## CphxObjectClip: Per-Clip Animation State

Objects can have multiple clips—alternative animations for different timeline sections. Scene.h:121-129 defines clip data:

```cpp
struct CphxObjectClip {
    class CphxScene *SubSceneTarget;
    unsigned char RandSeed;
    unsigned char TurbulenceFrequency;
    int SplineCount;
    CphxClipSpline **Splines;
    CphxMaterialSplineBatch *MaterialSplines;
};
```

**SubSceneTarget** is only valid for SubScene objects. It points to the scene that gets instanced when this clip is active. For other object types, this is NULL.

**RandSeed** and **TurbulenceFrequency** are used by particle turbulence affectors (Scene.cpp:310-314). These get copied to the object during animation evaluation. Storing them in the clip rather than the object allows different clips to use different turbulence fields.

**SplineCount** and **Splines** form the main spline array. Each entry is a `CphxClipSpline*`, so this is a double-indirect pointer. The indirection allows sharing splines between clips (though the current engine doesn't exploit this).

**MaterialSplines** handles type-0 material parameter splines separately. This batch evaluates independently and writes results directly to material parameters rather than `SplineResults[]`.

## CphxObject: Spline Evaluation Host

Scene.h:139-197 defines the object base class. Key members for spline integration:

```cpp
class CphxObject {
    CphxObjectClip **Clips;
    float SplineResults[Spline_Count];
    D3DXQUATERNION RotationResult;
    // ... other members ...
    void CalculateAnimation(int Clip, float t);
};
```

**Clips** is an array of clip pointers—one per possible clip index. Not all slots are necessarily populated. The timeline system decides which clip is active based on event scheduling.

**SplineResults** is the 57-element result storage. Scene.h:152 declares it as `float SplineResults[Spline_Count]`. The `Spline_Count` enum value is 57, so this allocates 228 bytes (57 × 4) per object. Most slots remain zero—only animated properties get non-default values.

**RotationResult** is separate quaternion storage for type-4 rotation splines. Using a dedicated `D3DXQUATERNION` (16 bytes) clarifies usage and avoids indexing confusion.

**CalculateAnimation** is the evaluation entry point, called once per frame during scene graph traversal.

## Animation Evaluation Flow

Scene.cpp:274-315 implements `CphxObject::CalculateAnimation()`. The process has three phases: reset defaults, evaluate splines, evaluate material splines.

### Phase 1: Reset Defaults (Lines 276-298)

Uninitialized memory contains garbage, so the first step clears critical defaults:

```cpp
void CphxObject::CalculateAnimation(int Clip, float t) {
    // Set scale defaults to 1
    SplineResults[Spline_Scale_x] = 1;
    SplineResults[Spline_Scale_y] = 1;
    SplineResults[Spline_Scale_z] = 1;

    // Set light color defaults to 1 (white)
    SplineResults[Spline_Light_DiffuseR] = 1;
    SplineResults[Spline_Light_DiffuseG] = 1;
    SplineResults[Spline_Light_DiffuseB] = 1;
    SplineResults[Spline_Light_SpecularR] = 1;
    SplineResults[Spline_Light_SpecularG] = 1;
    SplineResults[Spline_Light_SpecularB] = 1;

    // Set camera/particle defaults to 1
    SplineResults[Spline_Camera_FOV] = 1;
    SplineResults[Spline_Particle_EmissionVelocity] = 1;
    SplineResults[Spline_AffectorPower] = 1;
    SplineResults[Spline_Particle_Scale] = 1;
    SplineResults[Spline_Particle_Stretch_X] = 1;
    SplineResults[Spline_Particle_Stretch_Y] = 1;

    // Special particle defaults
    SplineResults[Spline_Particle_EmissionPerSecond] = 25;
    SplineResults[Spline_Particle_Life] = 10;

    // Shadow ortho defaults
    SplineResults[Spline_Light_OrthoX] = 1;
    SplineResults[Spline_Light_OrthoY] = 1;
    // ... (other slots remain zero)
}
```

Only properties that need non-zero defaults get explicit initialization. Position, ambient color, rotation chaos, etc. remain zero.

This approach saves code size. Instead of looping through 57 slots and writing zeros, only the ~20 non-zero defaults get explicit assignments. The rest rely on the C++ guarantee that class members zero-initialize.

### Phase 2: Evaluate Splines (Lines 299-305)

The core loop iterates active splines and stores results:

```cpp
for (int x = 0; x < Clips[Clip]->SplineCount; x++) {
    CphxClipSpline *s = Clips[Clip]->Splines[x];
    s->Spline->CalculateValue(t);
    SplineResults[s->Type] = s->Spline->Value[0];
    if (s->Type == Spline_Rotation)
        RotationResult = s->Spline->GetQuaternion();
}
```

**CalculateValue()** performs interpolation, waveform application, and stores the result in `s->Spline->Value[4]` (see spline/overview.md and spline/interpolation.md for details).

**SplineResults[s->Type]** indexing uses the type enum directly as an array index. This is why `PHXSPLINETYPE` values must be contiguous integers from 0 to 56. Adding a new type requires inserting an enum value, updating `Spline_Count`, and expanding the results array.

**Rotation special case** extracts all four quaternion components via `GetQuaternion()` instead of just using `Value[0]`. The rotation spline still writes to `SplineResults[Spline_Rotation]` (index 4), but that value is unused—`RotationResult` is the authoritative source.

### Phase 3: Evaluate Material Splines (Line 307)

Material parameter splines evaluate separately:

```cpp
Clips[Clip]->MaterialSplines->CalculateValues(t);
```

This delegates to `CphxMaterialSplineBatch::CalculateValues()` (Material.cpp:91-95), which evaluates all material splines in the batch without writing to `SplineResults[]`. Instead, they write directly to `CphxMaterialParameter::Value` fields.

The separation exists because material splines are type-0 wildcards. There's no fixed array index for "roughness" or "emissive intensity"—these are dynamic parameters. The batch system allows objects to have arbitrary numbers of material splines without pre-allocating slots.

### Phase 4: Update Object State (Line 308-314)

Finally, some special state gets copied:

```cpp
SubSceneTarget = Clips[Clip]->SubSceneTarget;

if (ObjectType == Object_ParticleTurbulence) {
    RandSeed = Clips[Clip]->RandSeed;
    TurbulenceFrequency = Clips[Clip]->TurbulenceFrequency;
}
```

This updates the object's subscene pointer (used during traversal) and particle turbulence state. These aren't spline-driven—they're per-clip constants.

## Material Spline Integration

Material splines use a parallel evaluation system. Instead of `PHXSPLINETYPE` indices, they target `CphxMaterialParameter` pointers. This indirection enables animating any exposed shader parameter.

### CphxMaterialSpline Structure

Material.h:131-138 defines the individual spline wrapper:

```cpp
struct CphxMaterialSpline {
    CphxMaterialParameter *Target;
    void *GroupingData;
    class CphxSpline_float16 *Splines[4];
    MATERIALVALUE GetValue();
    void CalculateValue(float t);
};
```

**Target** points to the parameter being animated. This could be a float roughness value, a color tint, a UV offset—anything in the material's parameter list.

**GroupingData** matches the grouping pointer from `CphxClipSpline`. When materials are instanced across multiple objects, the grouping determines which instance this spline affects.

**Splines[4]** can hold up to 4 separate spline pointers—one per component. For scalar parameters, only `Splines[0]` is used. For color parameters, `Splines[0-3]` animate RGBA channels independently. This allows animating red and blue independently for chromatic pulsing effects.

**GetValue()** reads the current spline values and packs them into a `MATERIALVALUE` union (Material.h:102). For floats, it returns `Value[0]`. For colors, it packs all four components into `Color[4]`.

**CalculateValue()** evaluates all active component splines:

```cpp
void CphxMaterialSpline::CalculateValue(float t) {
    for (int x = 0; x < 4; x++) {
        if (Splines[x])
            Splines[x]->CalculateValue(t);
    }
}
```

This is simpler than the object spline loop because material splines always evaluate all components. The result stays in the spline's `Value[4]` array until `GetValue()` retrieves it.

### CphxMaterialSplineBatch Structure

Material.h:140-147 groups material splines for batch evaluation:

```cpp
struct CphxMaterialSplineBatch {
    int SplineCount;
    CphxMaterialSpline **Splines;

    void CalculateValues(float t);
    void ApplyToParameters(void *GroupingData);
};
```

**CalculateValues()** (Material.cpp:91-95) evaluates all splines in the batch:

```cpp
void CphxMaterialSplineBatch::CalculateValues(float t) {
    for (int x = 0; x < SplineCount; x++)
        Splines[x]->CalculateValue(t);
}
```

This gets called from `CphxObject::CalculateAnimation()` after object splines evaluate. All material splines calculate values, but they don't write to target parameters yet.

**ApplyToParameters()** (Material.cpp:84-89) commits values to material state:

```cpp
void CphxMaterialSplineBatch::ApplyToParameters(void *GroupingData) {
    for (int x = 0; x < SplineCount; x++)
        if (Splines[x]->GroupingData == GroupingData || GroupingData == NULL)
            Splines[x]->Target->Value = Splines[x]->GetValue();
}
```

The grouping filter enables selective updates. When a model has multiple materials, only the parameters matching the current grouping get updated. Passing `NULL` updates all parameters regardless of grouping.

This happens during render instance creation, not during animation evaluation. The splines calculate once per frame, but the values apply to each material instance that uses them.

### Material Spline Workflow

The full pipeline for animating a material parameter:

1. **Definition:** Tool creates a `CphxMaterialSpline` targeting a specific `CphxMaterialParameter`
2. **Registration:** Spline added to model's `CphxMaterialSplineBatch`
3. **Clip assignment:** Batch pointer stored in `CphxObjectClip::MaterialSplines`
4. **Evaluation:** `CalculateAnimation()` calls `batch->CalculateValues(t)`
5. **Storage:** Spline results stored in `CphxMaterialSpline::Splines[x]->Value[]`
6. **Application:** During rendering, `batch->ApplyToParameters(grouping)` writes to material state
7. **Shader upload:** Material parameters collected and uploaded to GPU constant buffer
8. **Rendering:** Shader reads animated values from constants

Steps 1-3 happen during project import. Steps 4-5 happen once per frame. Steps 6-8 happen per-material-instance during render layer traversal.

## Scene Graph Integration

Spline evaluation integrates into scene graph traversal (Scene.cpp:219-272). The `TraverseSceneGraph()` method:

1. Calls `CalculateAnimation(Clip, t)` to evaluate splines
2. Reads `SplineResults[]` to build local transform matrix
3. Accumulates with parent transform to get world matrix
4. Reads light spline results to populate `LIGHTDATA` structure
5. Reads camera spline results to compute view/projection matrices
6. Recursively traverses children with updated matrices

The key is that splines evaluate first, before any rendering or transform accumulation. This ensures all downstream systems see consistent, up-to-date values.

### Transform Assembly (Scene.cpp:317-357)

The `GetWorldMatrix()` method (Scene.cpp:317) builds a transform from spline results:

```cpp
D3DXMATRIX CphxObject::GetWorldMatrix() {
    D3DXMATRIX prs;

    // Scale matrix
    D3DXMATRIX scale;
    D3DXMatrixScaling(&scale,
        SplineResults[Spline_Scale_x],
        SplineResults[Spline_Scale_y],
        SplineResults[Spline_Scale_z]);

    // Rotation matrix from quaternion
    D3DXMATRIX rotation;
    D3DXMatrixRotationQuaternion(&rotation, &RotationResult);

    // Position vector
    D3DXVECTOR3 position(
        SplineResults[Spline_Position_x],
        SplineResults[Spline_Position_y],
        SplineResults[Spline_Position_z]);

    // Compose: Scale * Rotation * Translation
    D3DXMatrixMultiply(&prs, &scale, &rotation);
    prs._41 = position.x;
    prs._42 = position.y;
    prs._43 = position.z;

    return prs;
}
```

This is the standard SRT (scale-rotate-translate) composition. Position, rotation, and scale splines feed directly into matrix construction. No intermediate buffering or caching—splines are the authoritative source.

### Light Data Collection

Lights populate the `LIGHTDATA` structure (Scene.h:131-137) from spline results. The collection happens during traversal when a light object is encountered:

```cpp
struct LIGHTDATA {
    D3DXVECTOR4 Position;                // From world matrix
    D3DXVECTOR4 Ambient, Diffuse, Specular;  // From spline results
    D3DXVECTOR4 SpotDirection;           // From spline results
    D3DXVECTOR4 SpotData;                // exponent, cutoff, linear, quadratic
};
```

The spline results map directly to structure fields:

```cpp
lightData.Ambient = D3DXVECTOR4(
    SplineResults[Spline_Light_AmbientR],
    SplineResults[Spline_Light_AmbientG],
    SplineResults[Spline_Light_AmbientB],
    1.0f);

lightData.Diffuse = D3DXVECTOR4(
    SplineResults[Spline_Light_DiffuseR],
    SplineResults[Spline_Light_DiffuseG],
    SplineResults[Spline_Light_DiffuseB],
    1.0f);

// ... similar for Specular, SpotDirection, SpotData
```

These structures accumulate in `CphxScene::Lights[]` (Scene.h:403), which is then uploaded to the GPU constant buffer for shader access.

### Camera Matrix Construction

Camera objects read FOV and roll from spline results to compute projection matrices. The exact code isn't in the provided excerpts, but the pattern is:

```cpp
float fov = SplineResults[Spline_Camera_FOV];
float roll = SplineResults[Spline_Camera_Roll];

D3DXMATRIX projection;
D3DXMatrixPerspectiveFovLH(&projection, fov, aspectRatio, nearPlane, farPlane);

D3DXMATRIX rollMatrix;
D3DXMatrixRotationZ(&rollMatrix, roll);

D3DXMatrixMultiply(&finalProjection, &projection, &rollMatrix);
```

Roll rotates the projection matrix after perspective calculation, tilting the rendered image.

### Particle System Integration

Particle emitters read 18 spline values during `UpdateParticles()` calls. The emitter accesses `SplineResults[]` to configure emission:

```cpp
D3DXVECTOR3 emissionOffset(
    SplineResults[Spline_Particle_Offset_x],
    SplineResults[Spline_Particle_Offset_y],
    SplineResults[Spline_Particle_Offset_z]);

float emissionRate = SplineResults[Spline_Particle_EmissionPerSecond];
float velocity = SplineResults[Spline_Particle_EmissionVelocity];
float life = SplineResults[Spline_Particle_Life];
// ... etc
```

Each spawned particle gets initialized from current spline values. Chaos parameters add per-particle randomness:

```cpp
particle.velocity = velocity * (1.0f + chaos * Random(-1, 1));
```

This allows emission characteristics to evolve over time—emission rate ramps up, velocity pulsates, lifetime oscillates—all driven by splines.

## Spline Type Summary Tables

### Storage Location Reference

| Type Range | Category | Storage Destination | Consumer |
|------------|----------|---------------------|----------|
| 0 | Material | `MaterialParameter::Value` | Shader constants |
| 1-3 | Transform (scale) | `SplineResults[1-3]` | Matrix builder |
| 4 | Transform (rotation) | `RotationResult` (quaternion) | Matrix builder |
| 5-6 | SubScene | `SplineResults[5-6]` | SubScene renderer |
| 8-11 | Transform (position) | `SplineResults[8-11]` | Matrix builder |
| 12-14 | Light (ambient) | `SplineResults[12-14]` | Light collector |
| 16-18 | Light (diffuse) | `SplineResults[16-18]` | Light collector |
| 20-22 | Light (specular) | `SplineResults[20-22]` | Light collector |
| 24-26, 28-31 | Light (spot/atten) | `SplineResults[24-31]` | Light collector |
| 33-34 | Camera | `SplineResults[33-34]` | Camera matrix |
| 37-47 | Particle (emission) | `SplineResults[37-47]` | Particle emitter |
| 48-49 | Light (shadow ortho) | `SplineResults[48-49]` | Shadow mapper |
| 50 | Affector | `SplineResults[50]` | Particle affector |
| 51-54 | Particle (scale/stretch) | `SplineResults[51-54]` | Particle emitter |
| 55-56 | SubScene (instancing) | `SplineResults[55-56]` | SubScene renderer |

### Default Value Reference

| Value | Applied To | Rationale |
|-------|------------|-----------|
| 0.0 | Position, rotation, ambient color, most params | Neutral/off state |
| 1.0 | Scale, diffuse, specular, FOV, velocity, power | Multiplicative identity |
| 25.0 | Particle emission rate | Matches engine framerate (25fps) |
| 10.0 | Particle lifetime | 10 frames at 25fps = 0.4 seconds |

The defaults minimize surprise. Uninitialized splines produce sensible behavior: objects exist at origin, have unit scale, lights emit white diffuse, particles emit continuously.

## Implications for Rust Framework Design

Phoenix's spline integration offers several lessons for a modern framework:

**Type-safe spline targets:** The `PHXSPLINETYPE` enum is error-prone—nothing prevents writing rotation data to a position slot. Rust's type system could enforce this:

```rust
enum SplineTarget {
    Scale(Axis),
    Position(Axis),
    Rotation,  // Must be Quaternion spline
    LightColor { component: LightComponent, channel: ColorChannel },
    ParticleEmission(ParticleParam),
    MaterialParam(MaterialParamId),
}
```

Each variant statically constrains value types. A `Rotation` target only accepts `Spline<Quaternion>`, not `Spline<f32>`.

**Builder pattern for clips:** Phoenix constructs clips through opaque tool code. A Rust framework could expose:

```rust
ObjectClip::builder()
    .spline(SplineTarget::Scale(Axis::X), scale_x_curve)
    .spline(SplineTarget::Rotation, rotation_curve)
    .material_spline(material_id, param_id, roughness_curve)
    .build()
```

Type safety ensures curves match targets at compile time.

**Zero-cost abstraction over defaults:** Instead of runtime default initialization, use const generics:

```rust
struct SplineResults<const N: usize> {
    values: [f32; N],
    defaults: [f32; N],  // Compile-time constant
}

impl<const N: usize> SplineResults<N> {
    fn reset(&mut self) {
        self.values.copy_from_slice(&self.defaults);
    }
}
```

This avoids runtime branches while preserving per-type defaults.

**Trait-based material parameters:** Material splines use void pointers and runtime type checking. Rust could use:

```rust
trait AnimatableMaterialParam {
    type Value;
    fn apply(&mut self, value: Self::Value);
}

struct MaterialSpline<P: AnimatableMaterialParam> {
    target: P,
    curve: Spline<P::Value>,
}
```

The type system guarantees value types match parameter expectations.

**Batch evaluation with iterators:** Phoenix loops manually. Rust iterators enable:

```rust
splines.par_iter_mut()
    .for_each(|spline| spline.evaluate(time));
```

Rayon parallelizes evaluation across all splines automatically. For scenes with hundreds of animated objects, this could be significant.

**Enum dispatch for spline types:** Instead of 57 array indices, use:

```rust
enum SplineResult {
    Scalar(f32),
    Vector3(Vec3),
    Quaternion(Quat),
    Color(Color),
}

struct EvaluatedSplines {
    results: HashMap<SplineTarget, SplineResult>,
}
```

Type safety prevents reading quaternions as scalars. HashMap lookup is slower than array indexing, but the safety trade-off may be worth it. Alternatively, use const generics to generate type-safe fixed arrays.

**Animation graph abstraction:** Phoenix hardcodes evaluation in `CalculateAnimation()`. A higher-level API could expose dependency graphs:

```rust
AnimationGraph::new()
    .add_node(scale_spline)
    .add_node(rotation_spline)
    .add_node(position_spline)
    .connect_to(transform_builder)
    .evaluate(time)
```

This enables complex behavior like additive animation, blend trees, and IK solving without modifying the core spline system.

The fundamental insight: splines are data, not code. Phoenix's array-indexed approach works but sacrifices type safety for compactness. Rust can have both—expressive types *and* zero-overhead evaluation—by using enums, traits, and const generics.

---

## References

- Scene.h:17-92 — `PHXSPLINETYPE` enumeration
- Scene.h:113-119 — `CphxClipSpline` structure
- Scene.h:121-129 — `CphxObjectClip` structure
- Scene.h:139-197 — `CphxObject` class with spline storage
- Scene.cpp:274-315 — `CalculateAnimation()` implementation
- Material.h:131-147 — Material spline structures
- Material.cpp:84-95 — Material spline evaluation
- spline/overview.md — Core spline evaluation system
- spline/interpolation.md — Interpolation mode details
- spline/waveforms.md — Waveform modulation
- rendering/materials.md — Material parameter system
