# Point-to-Pixel: tixl's Unified Particle Rendering System

How do you turn a GPU buffer of 64-byte point structs into everything from screen-aligned billboards to PBR-lit tubes? tixl's answer is a single unified `Point` buffer that feeds sixteen different draw modes, each implemented as a vertex-shader-driven rendering pipeline that expands points into geometry without ever touching a geometry shader. The secret is `SV_VertexID` — a hardware vertex index that the vertex shader uses to derive both which point to read and which corner of the generated quad or triangle to produce.

This is a meaningful architectural choice, not just an implementation detail. Geometry shaders were once the standard way to expand particles: send one point, emit four vertices. But geometry shaders carry unpredictable performance characteristics because they break the fixed-rate data flow the GPU is designed around. The vertex shader approach trades that flexibility for a guaranteed invocation model: you ask for exactly as many vertices as you want, the GPU runs the vertex shader once per vertex, and `SV_VertexID` tells each invocation where it sits in the sequence. No amplification, no driver surprises, no variable output limits.

The result is a system where every rendering capability — whether you want a glowing spark, a metallic ribbon flowing through space, or a PBR-lit cylindrical tube — shares the same buffer format, the same binding conventions, and the same expansion trick. You can switch from billboards to tubes in the node graph without reformatting your point data. The draw mode is just a different shader consuming the same storage buffer.

The `Point` struct itself, defined in `/visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point.hlsl`, establishes what that buffer contains. Two variants coexist: the current `Point` with 64 bytes total, and a `LegacyPoint` with a slightly different layout for older operators. Understanding one makes the other obvious.

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point.hlsl
struct Point
{
    float3 Position;  // World position: 12 bytes
    float FX1;        // General-purpose attribute, often particle age: 4 bytes
    float4 Rotation;  // Quaternion orientation: 16 bytes
    float4 Color;     // RGBA color: 16 bytes
    float3 Scale;     // Non-uniform scale per axis: 12 bytes
    float FX2;        // Second general-purpose attribute: 4 bytes
};
```

Sixty-four bytes. Clean cache-line alignment on most hardware. The `FX1` and `FX2` fields are intentionally generic — they carry whatever the simulation decides they carry, and the render shaders are parameterized to interpret them in whatever way the artist configures. When a particle system sets `FX1` to normalized age (0 at birth, 1 at death), the rendering system can use it to drive color-over-lifetime and size-over-lifetime. When a line draw mode sets `FX1` to arc length, width can be mapped along the curve. The attribute slot is a contract point between simulation and rendering.

## The VS Expansion Pattern

Think of the vertex shader expansion trick as a deck of cards analogy. Your point buffer is the deck — say, 10,000 cards. Each draw call asks for 60,000 vertices (10,000 points times 6 vertices per quad). The GPU deals out vertex IDs 0 through 59,999. Each vertex shader invocation picks up its ID, divides by 6 to find which "card" (point) to read, and takes the remainder modulo 6 to find which "corner" of the quad it should become. No geometry shader needed, no indirect draw complexity — just arithmetic on a sequential counter.

The vertex shader for DrawBillboards makes this arithmetic explicit. Looking at the actual code, the per-point and per-corner decomposition happens at the very top:

```hlsl
// visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl
psInput vsMain(uint id : SV_VertexID)
{
    uint particleCount, stride;
    Points.GetDimensions(particleCount, stride);

    uint quadIndex = id % 6;    // Which corner (0-5, two triangles per quad)
    uint pointId = id / 6;      // Which point in the buffer
    float3 cornerFactors = Corners[quadIndex];

    Point p = Points[pointId];
    // ... expand into screen-aligned quad
}
```

The draw call that triggers this specifies `vertexCount = pointCount * 6`. The GPU hardware provides `SV_VertexID` as a sequential counter from 0 to that count minus one. Everything the shader does — reading point data, computing world position, expanding into a quad — derives from that single integer.

The corner lookup table is a static array of six `float3` values representing the two triangles that make a quad. The z coordinate is always 0 because these are offsets in screen or camera space, not 3D offsets:

```hlsl
// DrawBillBoards.hlsl
static const float3 Corners[] = {
    float3(-1, -1, 0),  // Triangle 1: bottom-left
    float3( 1, -1, 0),  //             bottom-right
    float3( 1,  1, 0),  //             top-right
    float3( 1,  1, 0),  // Triangle 2: top-right
    float3(-1,  1, 0),  //             top-left
    float3(-1, -1, 0),  //             bottom-left
};
```

The pattern holds across all draw modes. DrawLines uses the same 6-vertex-per-segment structure. DrawTubes uses `6 * SideCount` vertices per segment — the same division/modulo logic with an extra ring index computed from `indexInLineStep / DrawsPerQuad`. DrawConnectionLines reads an index pair from a separate buffer rather than treating consecutive points as a segment. The expansion mechanism scales naturally to any geometry complexity.

> **Key Insight:** The vertex expansion pattern eliminates geometry shaders entirely. All sixteen draw modes expand geometry through vertex ID arithmetic. This maps directly to wgpu, where `@builtin(vertex_index)` provides the same sequential counter. The GPU hardware guarantee is identical.

## Buffer Bindings

All draw modes share a binding convention with minor variations for lighting and special features. The unified point buffer always occupies texture slot 0 as a structured buffer read:

```hlsl
// Shared across all draw modes
StructuredBuffer<Point> Points : register(t0);
```

DrawBillboards adds four texture slots for its extended feature set:

```hlsl
// DrawBillBoards.hlsl — additional bindings beyond the point buffer
Texture2D<float4> SpriteTexture : register(t1);   // Sprite atlas texture
Texture2D<float4> FxTexture     : register(t2);   // Screen-space effect texture
Texture2D<float4> ColorOverW    : register(t3);   // Color gradient LUT
Texture2D<float4> SizeOverW     : register(t4);   // Size gradient LUT
```

The PBR draw modes — DrawPointsShaded, DrawRibbons, DrawTubes, DrawMeshAtPoints2 — share a richer binding set including a prefiltered specular cubemap and a BRDF lookup texture. The pattern here is additive: unlit modes need the point buffer and a sprite; PBR modes need those plus the full IBL setup. The C# operator layer is responsible for ensuring all slots are populated before issuing the draw call.

## DrawBillboards: A Deep Dive

DrawBillboards is the workhorse of the particle rendering system. It carries more than thirty parameters, supports three orientation modes, a sprite atlas system, a screen-space FX texture, fog integration, and gradient-driven color and scale variation. Unpacking it reveals the full parameter philosophy that all other draw modes inherit in simplified form.

### Three Orientation Modes

The orientation mode parameter selects between three fundamentally different approaches to placing a quad in space. The mode is read from the cbuffer and checked with a simple comparison.

The first mode, plain billboard, always faces the camera. The shader transforms the point position into camera space, then offsets quad corners in that camera space. The corner offset happens before the final projection, so the quad remains screen-parallel regardless of where in the scene the point sits:

```hlsl
// DrawBillBoards.hlsl — mode 0: camera-space billboard
float4 quadPosInCamera = mul(posInObject, ObjectToCamera);
float2 corner = float2((cornerFactors.xy + Offset.xy) * 0.010 * Stretch * ...) * float2(-1, -1);
float4 rot = qFromAngleAxis((adjustedRotate + ...) * 3.141578 / 180, RotationAxis);
corner = qRotateVec3(float3(corner, 0), rot).xy;
output.position = mul(quadPosInCamera + float4(corner * computedScale, 0, 0), CameraToClipSpace);
```

The second mode, RotatedBillboard, maintains camera-facing while respecting the point's rotation around the Y axis. This is the mode you want for effects like upright flames or vertical banners that should face the camera but not spin sideways. The implementation projects the point's up vector into camera space, extracts the Z-rotation angle, and applies it before computing the corner offset:

```hlsl
// DrawBillBoards.hlsl — mode 1: Y-rotation preserved billboard
float3 yRotated = qRotateVec3(float3(0, 1, 0), pRotation);
float4 yRotatedInCam = mul(float4(yRotated, 1), ObjectToCamera);
float a = atan2(yRotatedInCam.x, yRotatedInCam.y);
float4 xx = qFromAngleAxis(-a, float3(0, 0, 1));
rot = qMul(xx, rot);
```

The third mode uses the full point rotation quaternion to orient the quad in world space. Corners become 3D offsets rotated by the point's quaternion before object-to-clip projection:

```hlsl
// DrawBillBoards.hlsl — mode 2: full quaternion orientation
float3 axis = (cornerFactors + Offset) * 0.010 * float3(Stretch * ..., 1);
float4 rotation = qMul(normalize(pRotation), qFromAngleAxis(..., RotationAxis));
axis = qRotateVec3(axis, rotation) * computedScale;
output.position = mul(posInObject + float4(axis, 0), ObjectToClipSpace);
```

This mode is what you want for oriented debris, oriented decals, or any particle that should face a direction determined by simulation rather than the camera.

### The Distribution Mode System

Here is where the design gets interesting. Five distinct behaviors drive how color, scale, and atlas cell selection vary across the particle population. The same `GetUFromMode` function appears in nearly every draw mode — it is the shared vocabulary for "how does this attribute vary per-point?"

The function signature reveals its inputs: a mode integer, the point's sequential index, its fractional position in the buffer, a four-channel hash, its FX1 value, and its fog distance. From these ingredients, it produces a normalized U coordinate for sampling gradient textures or atlas cells.

```hlsl
// DrawBillBoards.hlsl — distribution mode function
inline float GetUFromMode(float mode, int id, float f, float4 scatter, float w, float fog)
{
    switch ((int)(mode + 0.5))
    {
    case 0: return scatter.w;           // Hash with temporal smoothing
    case 1: return hash11u(id);         // Pure per-point random
    case 2:                             // Index-based linear spread
        float f1 = (f + SpreadPhase) / SpreadLength;
        f1 = SpreadRepeat > 0.5 ? fmod(f1, 1) : f1;
        return SpreadPingPong > 0.5 ? (1 - abs(f1 * 2 - 1)) : f1;
    case 3:                             // Driven by FX1 attribute
        float w1 = (w + SpreadPhase) / SpreadLength;
        w1 = SpreadRepeat > 0.5 ? fmod(w1, 1) : w1;
        return SpreadPingPong > 0.5 ? (1 - abs(w1 * 2 - 1)) : w1;
    default: return fog;                // Driven by fog distance
    }
}
```

The mode 0 case is worth examining closely. Rather than pure `hash11u(id)`, it uses a temporally smoothed scatter value computed earlier in the vertex shader:

```hlsl
// DrawBillBoards.hlsl — temporally coherent randomness
float phase = RandomPhase + 133.1123 * f;
int phaseId = (int)phase;

float4 normalizedScatter = lerp(
    hash41u(pointId * 12341 + phaseId),
    hash41u(pointId * 12341 + phaseId + 1),
    smoothstep(0, 1, phase - phaseId)
);
```

This is the system's answer to temporal coherence. A pure hash would give each point a stable random value, but if `RandomPhase` animates over time, the hash changes abruptly — the point appears to "pop" to a new random value. By interpolating between two adjacent hash values using a smoothstep, the transition becomes gradual. The `133.1123 * f` constant ensures that different points are offset in their phase cycles, so they never all transition simultaneously.

### ColorOverW and SizeOverW Gradient Textures

The ColorOverW and SizeOverW inputs are 1D lookup textures — gradient strips that map a U coordinate to a color or scale value. They are the GPU equivalent of animation curves. The U coordinate comes from whichever distribution mode is active.

The practical payoff appears when FX1 carries normalized particle age. Set ColorVariationMode to mode 3 (UseW), and every particle samples ColorOverW at its current age. Paint a gradient that goes from orange to dark red to transparent, and you have fire that changes color as it rises and fades as it dies — all driven by a single 1D texture lookup per vertex:

```hlsl
// DrawBillBoards.hlsl — gradient-driven color and scale
float colorFxU = GetUFromMode(ColorVariationMode, pointId, f, normalizedScatter, p.FX1, output.fog);
output.color = p.Color * Color * ColorOverW.SampleLevel(texSampler, float2(colorFxU, 0), 0);

float scaleFxU = GetUFromMode(ScaleDistribution, pointId, f, normalizedScatter, p.FX1, output.fog);
float scaleFromCurve = SizeOverW.SampleLevel(texSampler, float2(scaleFxU, 0), 0).r;
```

There is a subtle guard in the scale calculation that handles a common particle system edge case:

```hlsl
// DrawBillBoards.hlsl — hiding points with undefined W
float hideUndefinedPoints = isnan(p.FX1) ? 0 : (UseWFoScale > 0.5 ? p.FX1 : 1);
float computedScale = adjustedScale * (RandomScale * scatterForScale.y * adjustedRandomize + 1)
                    * scaleFromCurve * hideUndefinedPoints;
```

When FX1 is NaN — the sentinel value used for uninitialized or dead points in some simulation passes — the scale collapses to zero. The point effectively disappears without any alpha test or discard, which is cheaper. This NaN-sentinel pattern appears throughout the codebase as a GPU-friendly null value.

### The FxTexture: Screen-Space Modulation

The FxTexture input solves a different problem: what if you want particle appearance to be affected by their position on screen, not their position in space? A volumetric fog texture projected onto the screen can make particles in the fog region appear muted. A heat distortion texture can make particles near the ground grow larger.

The implementation projects each point's center into clip space, converts to UV coordinates, and samples the FxTexture at that screen position:

```hlsl
// DrawBillBoards.hlsl — screen-space FX texture sampling
float4 centerPos = mul(float4(quadPosInCamera.xyz, 1), CameraToClipSpace);
centerPos.xyz /= centerPos.w;                                          // Perspective divide

float4 fxColor = FxTexture.SampleLevel(
    texSampler,
    (centerPos.xy * float2(1, -1) + 1) / 2,   // NDC to UV (Y flip)
    0
);
```

In mode 0 (`UseColor`), the FX texture RGBA multiplies the output color directly. In mode 1 (`RotateScaleScatter`), the four channels drive rotation, scale, randomization amount, and a strength weight respectively. This second mode gives artists the ability to paint spatial zones where particles become chaotic, clustered, or wildly scaled — all without touching the simulation.

### The Pixel Shader: Intentional Simplicity

After the substantial complexity of the vertex shader, the pixel shader for DrawBillboards is remarkably direct. Sample the sprite, multiply by vertex color, alpha test, fog blend, HDR clamp:

```hlsl
// DrawBillBoards.hlsl — pixel shader
float4 psMain(psInput input) : SV_TARGET
{
    float4 imgColor = SpriteTexture.Sample(texSampler, input.texCoord);
    float4 color = input.color * imgColor;

    if (color.a < AlphaCutOff)
        discard;

    color.rgb = lerp(color.rgb, FogColor.rgb, input.fog * FogColor.a);
    return clamp(color, 0, float4(100, 100, 100, 1));
}
```

The HDR clamp at 100 is interesting. Rather than clamping at 1.0 (which would prevent HDR bloom), tixl allows particles to output high-luminance values. Bloom post-processing then picks up those bright regions. An additive particle system can produce very bright regions by design, and clamping at 1.0 would suppress that expressiveness. The upper bound of 100 is high enough to permit HDR while still preventing GPU buffer overflow from NaN values.

## The Line Family: Screen-Space Geometry

Where billboard modes expand points into quads centered on the point's world position, the line draw modes expand segments between consecutive points. The vertex ID arithmetic shifts accordingly: rather than point index plus corner index, each invocation needs a segment index, a corner index, and — for miter joint computation — access to the neighboring points.

DrawLines reads four consecutive points for each segment: the two before the current endpoint (AA, A) and the two after (B, BB). This is the classic Catmull-Rom neighborhood that makes smooth miter joints possible.

```hlsl
// DrawLines.hlsl — four-point neighborhood for miter computation
Point pointAA = Points[particleId < 1 ? 0 : particleId - 1];
Point pointA  = Points[particleId];
Point pointB  = Points[particleId + 1];
Point pointBB = Points[particleId > SegmentCount - 2
                    ? SegmentCount - 2
                    : particleId + 2];
```

The miter joint calculation projects all four points to screen space, computes the segment direction, interpolates the normal from neighboring segment directions, then offsets the quad edge along that interpolated normal. The division by `clamp(miter, -1, -0.01)` prevents the miter from extending infinitely at very sharp angles:

```hlsl
// DrawLines.hlsl — miter joint computation
float3 normal  = normalize(cross(direction,  float3(0, 0, 1)));
float3 normalA = normalize(cross(directionA, float3(0, 0, 1)));
float3 normalB = normalize(cross(directionB, float3(0, 0, 1)));

float3 neighboarNormal = lerp(normalA, normalB, f);
float3 meterNormal = (normal + neighboarNormal) / 2;

float miter = dot(-meterNormal, normal);
pos += cornerFactors.y * 0.1 * thickness * float4(meterNormal, 0) / clamp(miter, -1, -0.01);
```

Distance-based fade prevents stretched lines from looking wrong when consecutive points are far apart. The `smoothstep` fade begins before the segment length exceeds `FadeTooLong` and reaches zero at twice that distance:

```hlsl
// DrawLines.hlsl — segment length fade
float len = length(pointAPos - pointBPos);
float fade = smoothstep(2 * FadeTooLong, FadeTooLong, len);
if (fade < 0.001)
    discardFactor = 0;
```

DrawLinesBuildup adds a VisibleRange mechanism to the line rendering. The pixel shader maps the interpolated U coordinate through a `VisibleRange` offset and applies sharp edge ramps to create the illusion of a line progressively drawing itself:

```hlsl
// DrawLinesBuildup.hlsl — animated line reveal
float f1 = saturate((input.texCoord.x + VisibleRange) * 100);
float f2 = 1 - saturate((input.texCoord.x) * 100);
col.a *= f1 * f2;
```

## Tubes and Ribbons: 3D Extrusion

Where lines remain screen-space constructs, the tube and ribbon draw modes extrude geometry in 3D using the point's orientation quaternion.

DrawRibbons stretches a flat ribbon plane between consecutive points, controlled by Spin and Twist parameters. The side offset vector rotates based on the quaternion-rotated cos/sin ring position:

```hlsl
// DrawRibbons.hlsl — helical ribbon extrusion
float spinRad = (Spin + Twist * f) * 3.141578 / 180;
float3 side = float3(cos(spinRad), 0, sin(spinRad)) * cornerFactors.y;
float3 widthV = qRotateVec3(side, p.Rotation) * Width * WidthFactor;
float3 pInObject = p.Position + widthV;
```

As `Twist * f` increases along the curve, the ribbon progressively rotates around the path axis — creating a spiral. With Spin at 90 degrees and Twist at 0, you get a flat ribbon. Increase Twist and the ribbon corkscrews through space.

DrawTubes generalizes this from a ribbon (two sides) to an N-sided cross-section. The SideCount parameter configures the polygon resolution. Each segment requires `6 * SideCount` vertices rather than 6, and the vertex shader uses an additional `sideIndex` computation to determine which face of the cross-section each vertex belongs to:

```hlsl
// DrawTubes.hlsl — tube cross-section parametrization
static int DrawsPerStep = DrawsPerQuad * SideCount;  // 6 * SideCount vertices/segment

int indexInLineStep = id % DrawsPerStep;
int cornerIndex = indexInLineStep % DrawsPerQuad;
int sideIndex = indexInLineStep / DrawsPerQuad;

float fRing = (sideIndex + (cornerFactors.y / 2 + 0.5)) / SideCount;
float spinRad = fRing * 2 * 3.141578;               // Full circle divided into SideCount steps

float3 side = float3(cos(spinRad), 0, sin(spinRad));
float3 radiusOffset = qRotateVec3(side, pointRotation) * Width * WidthFactor;
```

With SideCount at 3, you get a triangular prism. At 8, an octagonal tube. At 16, something close enough to a circle for most use cases. Both modes use the full PBR pipeline, passing a tangent-bitangent-normal basis to the pixel shader for normal mapping.

> **Key Insight:** The SideCount multiplication pattern in DrawTubes is a natural scaling problem for wgpu: the draw call vertex count is `(pointCount - 1) * 6 * SideCount`, and the vertex shader decomposes the ID with an additional integer divide and modulo. The math is identical to the billboard expansion, just with an extra dimension of parametrization.

## DrawPointsShaded: Sphere Impostors

The most visually sophisticated of the quad-based modes, DrawPointsShaded creates the illusion of a lit sphere from a flat billboard. The pixel shader reconstructs a sphere surface by treating the quad's UV coordinate as a projected circle and computing the Z component analytically.

The vertex shader is nearly identical to DrawPoints — it expands billboards in camera space — but the pixel shader diverges significantly. It maps the UV coordinate from [0,1] to [-1,1], checks if the point falls within the unit circle (discarding corners), then reconstructs the sphere normal:

```hlsl
// DrawPointsShaded.hlsl — sphere normal reconstruction from UV
float2 p = pin.texCoord * float2(2.0, 2.0) - float2(1.0, 1.0);
float d = dot(p, p);
if (d > 0.93)
    discard;               // Outside the circle: clip the quad corners

float z = sqrt(1 - d * d);
float3 normal = normalize(float3(p, z));
frag.N = mul(float4(normal, 0), CameraToWorld).xyz;
```

The resulting normal points outward from the sphere surface, which gets passed to the full Cook-Torrance BRDF calculation. From a flat quad, you get what reads as a solid, lit sphere. Specularity, roughness, metalness, and environment map reflections all work correctly because the normal is geometrically accurate for a sphere of that radius.

The quad corners are discarded rather than clipped, which means the rasterizer processes slightly more fragments than strictly necessary. The `d > 0.93` threshold rather than `d > 1.0` adds a small soft margin at the sphere edge that prevents aliased circular boundaries.

## DrawConnectionLines: Explicit Index Pairs

All the preceding draw modes treat the point buffer as an ordered sequence — either individual points or a connected path. DrawConnectionLines breaks that assumption. It reads a separate `StructuredBuffer<uint2>` that explicitly lists which pairs of points should be connected by a line:

```hlsl
// DrawConnectionLines.hlsl — explicit pair addressing
StructuredBuffer<LegacyPoint> Points : register(t0);
StructuredBuffer<uint2> LinePoints  : register(t1);

// In vsMain:
uint2 indexPair = LinePoints[particleId];
LegacyPoint pointA = Points[indexPair.x];
LegacyPoint pointB = Points[indexPair.y];
```

Points with NaN W values get silently skipped — the output position is set to zero, causing the triangle to degenerate:

```hlsl
// DrawConnectionLines.hlsl — NaN guard for dead points
if (isnan(pointA.W) || isnan(pointB.W))
{
    output.position = 0;
    return output;
}
```

This makes DrawConnectionLines ideal for network and graph visualizations where connectivity is data-driven rather than implicit in point ordering. The buildup animation reads a `progressTexture` 1D lookup at the normalized animation progress, sampling a color that modulates line alpha — lines can "travel" visually along their segments as the animation progresses.

## DrawMotionPoints: Velocity Streaks

DrawMotionPoints accepts two point buffers — current frame and previous frame — and stretches particles into velocity-aligned streaks based on their displacement between frames. The key addition over the standard DrawPoints is a second transform cbuffer for the previous frame's matrices, and the velocity computation in NDC space:

```hlsl
// DrawMotionPoints.hlsl — velocity computation in clip space
float4 clip  = mul(cam,  CameraToClipSpace);
float4 clipP = mul(camP, PrevCameraToClipSpace);
float2 ndc   = clip.xy  / max(1e-6, clip.w);
float2 ndcP  = clipP.xy / max(1e-6, clipP.w);

float2 vU = (ndc - ndcP);
vU.x *= Aspect;             // Correct for non-square pixels

float speedU = length(vU);
float2 dirVel = (speedU > 1e-6) ? normalize(vU) : ey;
```

The billboard dimensions then align to the velocity direction rather than staying axis-aligned. The VelocityStretch parameter controls how much the particle elongates at speed, with a smooth blend from round to stretched as velocity increases:

```hlsl
// DrawMotionPoints.hlsl — velocity-aligned quad construction
float stretchTarget = lerp(1.0, VelocityStretch, f);
float stretch = clamp(lerp(1.0, stretchTarget, wAlign), 0, 10);

float thickness = 0.5 * baseSize.x;
float lengthHx  = 0.5 * baseSize.y * stretch;
float2 offset = corner.x * thickness * per + corner.y * lengthHx * dir;
camQuad.xy += offset;
```

There is a jump guard that checks whether the particle moved more than `VelocityMaxJump` units between frames. When a particle teleports or wraps around a simulation domain, the displacement would create absurdly long streaks. The guard sets `useVel` to zero for such cases, returning the particle to a round dot.

## DrawPointsDOF: GPU Depth of Field

The DOF variant adds an unexpected layer of sophistication. Rather than sorting on the CPU, it reads a pre-sorted index buffer produced by a sequence of compute passes:

```hlsl
// DrawPointsDOF-template.hlsl — sorted index addressing
StructuredBuffer<uint>  SortedIndices : register(t1);
StructuredBuffer<uint>  BucketIndices : register(t2);

// In vsMain — indirect particle lookup through sorted index
int particleId = SortedIndices[id / 6];
Point pointDef = Points[particleId];
```

The BucketIndices buffer assigns each particle to a depth bucket, which the vertex shader uses to modulate color — a debug visualization showing which particles fall into which depth layer. The sorting itself happens in five compute passes that presumably perform a bucket sort by depth, giving back-to-front ordering without CPU readback. This keeps the full rendering pipeline on the GPU.

## Draw Mode Reference

Having explored the major modes in depth, the full landscape can now be summarized. Each mode makes a specific tradeoff between geometry complexity, lighting fidelity, and vertex count.

| Mode | Geometry | Lighting | Vertices/Point | Notable Feature |
|------|----------|----------|----------------|-----------------|
| Billboards | Quad | Unlit | 6 | Atlas, FxTexture, gradient LUTs |
| Points | Quad | Unlit | 6 | Shader graph template |
| PointsShaded | Quad to sphere | PBR | 6 | Normal reconstruction |
| Lines | Ribbon | Unlit | 6 | Miter joints, length fade |
| LinesAlt | Ribbon | Unlit | 6 | Alternative thickness model |
| LinesBuildup | Ribbon | Unlit | 6 | Animated progressive reveal |
| LinesShaded | Ribbon | PBR | 6 | Lit lines with normals |
| RayLines | Lines | Unlit | 6 | Point-to-point |
| Ribbons | Helical | PBR | 6 | Spin/Twist parameters |
| Tubes | Cylindrical | PBR | 6 * SideCount | N-sided cross-section |
| ConnectionLines | Lines | Unlit | 6 | Explicit index pairs |
| MeshAtPoints2 | Full mesh | PBR | Varies | Instanced, PBR per vertex |
| MovingPoints | Streak | Unlit | 6 | Velocity-based motion blur |
| PointsDOF | Quad | Unlit | 6 | GPU bucket sort |
| PointSprites | Quad | Unlit | 6 | Legacy path |
| VisualizePoints | Debug | None | 6 | Index and attribute display |

## Blend and Depth State

The rendering operators control alpha blending and depth write behavior from the C# side, configuring DX11 state objects before issuing draw calls. Most particle modes disable depth write — transparent geometry that writes depth produces incorrect occlusion when rendered without sorting. The AlphaCutOff parameter in the pixel shader provides alpha testing for hard-edged sprites without the sorting requirement.

Several draw modes expose a `TooCloseFadeOut` boolean that fades particles whose camera-space depth is very small. The implementation multiplies alpha by a factor that goes from 0 to 1 as the point moves from 0.1 units away from the camera outward:

```hlsl
// DrawBillBoards.hlsl — near-camera fade
float tooCloseFactor = saturate(-posInCamera.z / 0.1 - 1);
if (TooCloseFadeOut > 0.5)
    p.Color.a *= tooCloseFactor;
```

Without this fade, billboards near the camera could cover the entire screen as their size becomes enormous relative to their distance.

## Comparison with Phoenix

Seeing these two systems side by side clarifies where architectural choices produce real differences in what is expressible at runtime.

| Aspect | tixl | Phoenix |
|--------|------|---------|
| Expansion method | Vertex shader (SV_VertexID) | Geometry shader |
| Draw mode count | 16 | 3 (Billboard, Mesh, SubScene) |
| Lighting options | Optional PBR per mode | Full deferred PBR |
| Gradient curves | GPU texture LUTs | CPU spline textures |
| Depth sorting | Optional GPU bucket sort | CPU std::sort + upload |
| Sprite atlas | Per-point cell selection | Not present |
| Screen-space FX | FxTexture modulation | Not present |
| Distribution modes | 5 (hash, scatter, spread, attribute, fog) | Implicitly: lifetime only |

The geometry shader trade-off is the most fundamental. Phoenix's GS approach means one vertex in produces four vertices out — clean, but driver-dependent in performance. tixl's VS expansion gives explicit control: the draw call specifies exactly the vertex count needed, and no amplification hardware is involved. The practical consequence is that tixl can issue a single draw call for a million points expanding into six million billboard vertices with predictable GPU utilization.

The distribution mode system is tixl's most powerful differentiator. Phoenix drives visual variation primarily through lifetime curves — everything derives from age. tixl's five-mode system means variation can come from per-point hash, sequential spread, an arbitrary attribute, or screen-space fog depth. That generality is what allows the same `DrawBillboards` operator to function as a snow system (hash scatter), a crowd visualization (sequential spread), or a heat haze effect (fog-driven opacity) without shader changes.

## Implications for a Rust/wgpu Port

The VS expansion pattern translates directly. In WGSL, `@builtin(vertex_index)` provides the same sequential counter that `SV_VertexID` provides in HLSL. The arithmetic is identical:

```wgsl
// Equivalent VS expansion in WGSL
@vertex fn vs_main(@builtin(vertex_index) id: u32) -> VertexOutput {
    let quad_index = id % 6u;
    let point_id   = id / 6u;
    let point      = points[point_id];
    // ...
}
```

The `StructuredBuffer<Point>` binding maps to a wgpu storage buffer with read-only access. The gradient texture LUTs (ColorOverW, SizeOverW) map naturally to wgpu `Texture1d` or a narrow `Texture2d` with a height of one. The distribution mode system fits cleanly as a small uniform enum in a cbuffer equivalent.

The PBR shared library (`shared/pbr.hlsl`) that all lit draw modes include would become a shared WGSL module. wgpu's shader preprocessor supports includes through `naga_oil` or similar tools, or the PBR functions can be embedded directly in each draw mode shader. The prefiltered specular cubemap and BRDF lookup texture bindings are standard wgpu texture/sampler patterns.

The most interesting challenge is the `DrawPointsDOF` path. GPU bucket sorting requires compute passes with UAV writes, which wgpu supports through storage buffers with read-write access in compute shaders. The sorted index indirection — `points[sorted_indices[id / 6]]` — carries over without modification.

> **Key Insight:** tixl's draw mode system is designed for a visual programming environment where artists connect nodes, not for a fixed asset pipeline. The implication for framework design is that draw modes should be independently activatable and parameterizable at runtime, with per-mode cbuffer layouts that the framework binds without knowing which mode is active. A trait-based approach in Rust — where each draw mode implements a `DrawMode` trait that knows its vertex count formula and cbuffer layout — would preserve this flexibility.

## References

- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawBillBoards.hlsl` — Primary billboard implementation with full feature set
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawLines.hlsl` — Screen-space miter joint line rendering
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawLinesBuildup.hlsl` — Animated progressive line reveal
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawPointsShaded.hlsl` — Sphere impostor with PBR lighting and field template system
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawTubes.hlsl` — N-sided cylindrical tube extrusion
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawRibbons.hlsl` — Helical ribbon with Spin/Twist
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawConnectionLines.hlsl` — Explicit-pair connection lines with buildup animation
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawMotionPoints.hlsl` — Velocity-streak billboard with frame-delta motion blur
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/points/draw/DrawPointsDOF-template.hlsl` — GPU-sorted depth-of-field particles
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/shared/point.hlsl` — Canonical Point, LegacyPoint, and Particle struct definitions
- `/visual-programming/tixl/Operators/Lib/Assets/shaders/3d/mesh/mesh-DrawAtPoints2.hlsl` — Full PBR mesh instancing at point locations
