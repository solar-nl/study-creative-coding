# Code Trace: Planar Mirror Reflections in Clean Slate

> Tracing how Clean Slate creates mirror reflections using 2D line geometry — the simplest reflection technique in the engine, yet one that produces the most visually convincing results for flat surfaces.

Reflections are notoriously difficult to get right in real-time graphics. Screen-space reflections require ray marching through the depth buffer. Environment mapping needs pre-baked cubemaps. Both techniques struggle with edge cases: SSR can't reflect off-screen objects, and cubemaps are static. Yet for one specific scenario — a perfectly flat mirror like a floor, water surface, or glass panel — there's an elegantly simple solution that costs almost nothing.

The mirror shader in Clean Slate operates entirely in 2D screen space. It defines a line, checks which side of that line each pixel falls on, and for pixels on the reflected side, samples from the mirrored position. No ray marching. No importance sampling. No second render pass. Just vector math and a single texture sample per pixel. The technique works because it embraces its constraint: mirrors are flat, so reflection math can collapse from 3D to 2D.

This is conceptual compression at work. The shader asks: "What's the absolute minimum information needed to define a mirror?" Answer: a line in screen space. Everything else — angle, position, which side reflects — derives from that line definition. For demos targeting 64k size limits, this kind of reduction is essential.

## The Mental Model: Folding Paper

Think of folding a piece of paper along a crease. Everything on one side appears mirrored on the other. Pick up the paper and look at it — what you see is the "rendered frame." The fold line is the "mirror surface." The shader's job is to define that fold line and map each pixel to its reflection.

The paper analogy reveals why this technique is 2D. You're not simulating light bouncing off a 3D surface. You're just taking an already-rendered image and folding part of it over a line. The perspective distortion, the lighting, the material properties — all of that was handled during the original render. The mirror shader is pure geometry: reflect point A across line L to get point A'.

This explains both the technique's strength and its limitation. Strength: it's trivially cheap and produces pixel-perfect reflections for flat surfaces. Limitation: it only works for objects that are truly planar in screen space. A curved mirror or a mirror viewed at an angle would expose the illusion. But for floor reflections in a demo? Perfect.

## Mirror Line Definition

**File**: `Projects/Clean Slate/extracted/shaders/materials/mirror.hlsl:18-27`

The shader defines the mirror using three parameters:

```hlsl
cbuffer MaterialBuffer : register(b1)
{
    float direction;     // Mirror angle (0-1 → 0-90°)
    float centerX;       // Mirror line X position
    float centerY;       // Mirror line Y position
}
```

The mirror is a LINE in screen space, not a plane in 3D. This is the key insight. Given any line, you can reflect points across it using 2D vector math. The line is defined by:

- **A point on the line**: `(centerX, centerY)` in UV coordinates (0-1 range)
- **A direction**: Encoded as an angle where `direction = 0.5` means 45 degrees

The direction parameter maps 0-1 to 0-90 degrees, which converts to 0 to π/2 radians:

```hlsl
float angle = 3.14159265 * direction / 2;
```

Why 0-90 degrees instead of full 360? Because a line has no inherent "forward" direction — a line at 45° is identical to a line at 225°. The 90-degree range covers all unique line orientations. The shader converts this to a direction vector:

```hlsl
float2 D = float2(sin(angle), cos(angle));
```

At `direction = 0`: angle = 0°, so D = (0, 1) — a horizontal mirror line.
At `direction = 0.5`: angle = 45°, so D ≈ (0.707, 0.707) — a diagonal line.
At `direction = 1`: angle = 90°, so D = (1, 0) — a vertical mirror line.

The line extends infinitely in both directions. The shader doesn't need to define endpoints because it operates on the entire screen.

## Aspect Ratio Correction

**File**: `Projects/Clean Slate/extracted/shaders/materials/mirror.hlsl:46-50`

Before performing any reflection math, the shader corrects for non-square pixels:

```hlsl
float aspect = 16.0 / 9.0;

float2 P = float2(centerX, centerY);
float2 D = float2(sin(angle), cos(angle));
float2 A = texCoord;

P.y /= aspect;
A.y /= aspect;
```

Screen space is not square. A 16:9 display stretches the Y axis compared to X. Without correction, a 45-degree line would appear as approximately 26 degrees on screen. The math would still work, but the visual result wouldn't match the artist's intent.

The correction converts to a square coordinate space by dividing Y coordinates by the aspect ratio. The math is performed in this square space, then converted back for texture sampling. Notice that the direction vector `D` is NOT corrected. This is subtle but important: `D` already represents the desired visual angle after applying sin/cos. The correction only applies to points, not directions.

The hardcoded 16:9 aspect ratio is acceptable for a demo with a known target resolution. A production engine would pass this as a uniform or compute it from screen dimensions.

## Side Test: Which Pixels Reflect?

**File**: `Projects/Clean Slate/extracted/shaders/materials/mirror.hlsl:52-54`

Not every pixel needs reflection. The mirror divides the screen into two half-planes: the "keep" side (original pixels) and the "reflect" side. The shader uses a perpendicular dot product to test which side:

```hlsl
float2 perpendicular = float2(-D.y, D.x);
if (dot(A - P, perpendicular) > 0)
{
    return inputTexture.Sample(linearSampler, texCoord);
}
```

The perpendicular to direction vector D = (Dx, Dy) is (-Dy, Dx) — a 90-degree rotation. This is standard 2D vector math: rotating (x, y) by 90° gives (-y, x).

The expression `dot(A - P, perpendicular)` computes the signed distance from point A to the line. The dot product projects vector (A - P) onto the perpendicular direction:

- Positive result: Point A is on the "keep" side of the line.
- Negative result: Point A is on the "reflect" side of the line.
- Zero: Point A lies exactly on the line.

This is the half-plane test. It divides 2D space into two regions based on which side of the line a point falls on. For pixels that pass the test (positive result), the shader returns the original texture sample unchanged. No reflection needed — these pixels aren't "behind the mirror" from the viewer's perspective.

The early exit is a performance optimization. For roughly half the screen, the shader does minimal work: one dot product, one comparison, one texture sample. Only pixels on the reflected side pay the cost of the full reflection calculation.

## Reflection Calculation: The Core Math

**File**: `Projects/Clean Slate/extracted/shaders/materials/mirror.hlsl:56-62`

For pixels that fail the side test (negative dot product), the shader calculates their reflection:

```hlsl
float2 X = P + D * dot(A - P, D);     // Closest point on line
float2 reflectedA = 2 * X - A;         // Reflection formula

reflectedA.y *= aspect;                 // Convert back to screen space
```

This is textbook 2D point reflection. Let's break it down step by step:

### Step 1: Project onto the mirror line

```hlsl
float2 X = P + D * dot(A - P, D);
```

The goal is to find point X — the closest point on the mirror line to point A. Geometrically, X is where a perpendicular from A intersects the line.

The expression `dot(A - P, D)` computes the scalar projection of vector (A - P) onto the direction vector D. This gives the "distance along D" from P to reach the projection point. Multiplying by D gives the offset vector, and adding P gives the actual position:

```
X = P + (projection_distance) * D
  = P + dot(A - P, D) * D
```

This is the standard formula for projecting a point onto a line. It's the same math used in graphics to project vectors onto arbitrary axes.

### Step 2: Reflect across the projection point

```hlsl
float2 reflectedA = 2 * X - A;
```

This is the geometric definition of reflection. If X is the midpoint between A and its reflection A', then:

```
X = (A + A') / 2
```

Solving for A':

```
A' = 2X - A
```

Visually, X acts as a "mirror point." The distance from A to X equals the distance from X to A', but in the opposite direction. The formula `2X - A` encodes this symmetry.

### Step 3: Convert back to screen space

```hlsl
reflectedA.y *= aspect;
```

The reflection math was performed in square coordinate space (after dividing Y by aspect). To sample the texture, we need screen-space UV coordinates. Multiplying Y back by the aspect ratio restores the original coordinate system.

The elegance of this approach is that the reflection formula doesn't change regardless of mirror angle. The angle is entirely encoded in the direction vector D. Whether the mirror is horizontal, vertical, or diagonal, the math is identical. This is why parameterizing by direction vector is so powerful — the algorithm becomes angle-agnostic.

## Bounds Checking: Preventing Invalid Samples

**File**: `Projects/Clean Slate/extracted/shaders/materials/mirror.hlsl:64-73`

After computing the reflected coordinate, the shader checks whether it's within the valid texture range:

```hlsl
float4 result = 0;

if (length(reflectedA - clamp(reflectedA, 0, 1)) < 0.0001)
{
    result = inputTexture.Sample(linearSampler, reflectedA);
}

return result;
```

The condition `length(reflectedA - clamp(reflectedA, 0, 1)) < 0.0001` is a clever bounds check. Here's how it works:

- `clamp(reflectedA, 0, 1)` constrains the coordinate to the [0, 1] UV range.
- If `reflectedA` was already in bounds, the clamped version equals the original.
- If `reflectedA` was out of bounds, the clamped version differs from the original.
- The length of the difference measures "how far out of bounds" the coordinate is.
- If this length is near zero (within epsilon 0.0001), the coordinate is in bounds.

Why not just check `reflectedA.x >= 0 && reflectedA.x <= 1 && reflectedA.y >= 0 && reflectedA.y <= 1`? Both approaches work, but the length-based check is more concise and accounts for floating-point imprecision at exact boundaries. A coordinate like (1.0000001, 0.5) might technically be "out of bounds" but is practically on the edge.

Out-of-bounds reflections return black (`float4(0)`). This prevents sampling garbage data outside the render target. In practice, out-of-bounds reflections occur when the reflected coordinate points to a region that wasn't rendered — for example, reflecting a point near the screen edge that would mirror to a position beyond the screen.

The epsilon value (0.0001) accounts for floating-point imprecision. At exact boundaries like UV = 1.0, rounding errors might make the computed reflection slightly above 1.0. The epsilon provides a tolerance zone that accepts coordinates "close enough" to the valid range.

## Comparison: 2D vs. 3D Planar Reflections

The mirror shader's 2D approach is fundamentally different from the 3D planar reflection technique used in game engines. Understanding the difference reveals why demos favor this simpler method.

### Game Engine Approach (3D)

In a typical game engine, planar reflections work like this:

1. Define a reflection plane in world space (e.g., Y = 0 for a floor).
2. Mirror the camera across that plane: if the camera is at (x, y, z), the mirrored camera is at (x, -y, z) with an inverted view direction.
3. Render the entire scene from the mirrored camera's perspective.
4. Render the reflection plane with a material that samples the mirrored render.

This creates a proper 3D reflection with correct perspective. Objects at different depths appear at the correct reflected positions. Parallax works. The reflection updates if the camera moves or objects change.

### Clean Slate Approach (2D)

The Clean Slate shader skips all of that:

1. Render the scene once, normally.
2. For pixels on the reflected side of a screen-space line, sample from the mirrored 2D position.

This is a screen-space effect. It reflects the already-rendered 2D image, not the 3D scene. The perspective information is lost — the shader doesn't know that the pixel at (0.3, 0.5) corresponds to an object 5 meters away while (0.7, 0.5) is 20 meters away.

### Why the 2D Approach Works for Demos

For non-planar scenes, the 2D approach produces incorrect results. A tall object close to the camera would reflect at the same angle as a short object far away, because the shader only sees screen positions, not depths. But demos are carefully authored. Artists design scenes knowing the mirror's limitations:

- Place mirrors where perspective errors are minimal (e.g., horizontal floors viewed from moderate angles).
- Keep reflected objects roughly coplanar with the mirror.
- Use camera angles that minimize depth discrepancies.

The trade-off is clear: the 2D approach is faster (no second render pass), simpler (no camera math), and smaller (76 lines of shader code). For demos where visual impact per byte is crucial, this is a winning trade.

A secondary benefit: the 2D approach automatically handles dynamic content. Whatever was rendered in the first pass — including animated objects, particles, post-processing effects — appears in the reflection "for free." There's no need to re-render those systems from a different viewpoint.

## Mathematical Properties

The reflection algorithm has several interesting mathematical properties that emerge from the underlying vector geometry:

### Reflection is Self-Inverse

Reflecting a point twice returns to the original position. If `A' = 2X - A`, then reflecting A' gives:

```
A'' = 2X - A'
    = 2X - (2X - A)
    = 2X - 2X + A
    = A
```

This self-inverse property means the shader could theoretically toggle between "normal" and "mirrored" modes by applying the same transformation twice. In practice, the side test ensures each pixel is only reflected once.

### The Mirror Line is Invariant

Points that lie exactly on the mirror line (where `dot(A - P, D) = 0`) reflect to themselves. The projection step gives `X = P`, and the reflection formula gives `A' = 2P - A`. But if A is on the line, then `A = P + tD` for some scalar t, so:

```
A' = 2P - (P + tD) = P - tD
```

Wait, that's not A unless t = 0. Let me reconsider... Actually, for a point on the line, the perpendicular distance is zero, so X = A (the closest point on the line to A is A itself). Then `A' = 2A - A = A`. The line pixels don't change — they're the "seam" of the reflection.

### Angle and Position are Independent

The reflection formula separates angle (encoded in D) from position (encoded in P). You can change the mirror's angle without moving it, or move it without changing the angle. This parameter independence is valuable for animation: an artist can keyframe position and angle separately without coupling.

The shader doesn't encode any material or lighting data. It operates AFTER lighting, during post-processing. This means the reflection inherits all the lighting, shadows, and material properties from the original render. There's no need to handle PBR, BRDF, or any surface interaction — the shader is purely geometric.

### Cost is O(1) Per Pixel

The shader contains no loops. Every pixel executes the same number of instructions (ignoring the early exit for non-reflected pixels):

- 1 dot product for side test (maybe early exit)
- 1 dot product for projection
- 1 vector multiply + add for reflection
- 1 aspect correction multiply
- 1 bounds check
- 1 texture sample

This is about as cheap as a post-processing effect can get. There's no iterative refinement, no ray marching, no multi-tap filtering. It's a pure mathematical transformation.

## Implementation Notes

### Hungarian Comments

The original shader includes comments in Hungarian (the demoscene group Conspiracy is based in Hungary). These explain the math step by step:

```hlsl
//ez a dir erteket hasznalhatova teszi (0.5 = 90 fok)
// Translation: "this makes the dir value usable (0.5 = 90 degrees)"

//ez kiszamolja a tukor az adott ponthoz talalhato legkozelebbi pontjat
// Translation: "this calculates the closest point on the mirror to the given point"
```

The annotated version translates these comments and adds additional mathematical context. For code archaeology, seeing the original author's thought process — even in another language — is valuable. It confirms that the algorithm was designed with geometric clarity in mind, not just stumbled upon through trial and error.

### Hardcoded Aspect Ratio

The hardcoded 16:9 aspect ratio is noted in the shader with:

```hlsl
//aspect ratio hardkodolt :(
// Translation: "aspect ratio hardcoded :("
```

The sad emoticon suggests the author recognized this as a limitation. For a production framework, this would be a uniform parameter. For a 64k demo targeting a known display resolution, hardcoding saves a constant buffer slot.

### ShaderToy Render Technique

The shader header specifies:

```hlsl
// Render Technique: Mirror
// Type: ShaderToy
// GUID: 3239F532CED4BDB68C7BFC202017AAA9
// Target Layer: NONENONENONENONE
```

"ShaderToy" indicates this is a full-screen post-processing effect, similar to how Shadertoy.com shaders operate. The technique runs on a full-screen quad, processing each pixel independently. This is distinct from material shaders (which run per-mesh vertex/pixel) or deferred lighting shaders (which read from the G-Buffer).

## Data Flow Diagram

```
┌───────────────────────────────────────────────────────────────────────┐
│ INPUT: Rendered Frame Texture                                          │
│   • Full scene rendered (geometry, lighting, effects)                 │
│   • Texture format: RGB color + alpha (unused)                        │
└──────────────────────────────┬────────────────────────────────────────┘
                               │
                               ▼
┌───────────────────────────────────────────────────────────────────────┐
│ MIRROR SHADER                                                          │
│                                                                        │
│   For each pixel at texCoord (u, v):                                  │
│                                                                        │
│   ┌─────────────────────────────────────────────────────────────┐    │
│   │ 1. DEFINE MIRROR LINE                                       │    │
│   │    • Point P = (centerX, centerY)                           │    │
│   │    • Direction D = (sin(angle), cos(angle))                 │    │
│   │    • angle = π * direction / 2                              │    │
│   └─────────────────────────────────────────────────────────────┘    │
│                               │                                        │
│                               ▼                                        │
│   ┌─────────────────────────────────────────────────────────────┐    │
│   │ 2. ASPECT CORRECTION                                        │    │
│   │    • Convert to square coordinate space                     │    │
│   │    • P.y /= aspect                                          │    │
│   │    • A.y /= aspect (where A = texCoord)                     │    │
│   └─────────────────────────────────────────────────────────────┘    │
│                               │                                        │
│                               ▼                                        │
│   ┌─────────────────────────────────────────────────────────────┐    │
│   │ 3. SIDE TEST                                                │    │
│   │    • Perpendicular = (-D.y, D.x)                            │    │
│   │    • if dot(A - P, Perpendicular) > 0:                      │    │
│   │        → Pixel on "keep" side, return original              │    │
│   │    • else: Continue to reflection calculation               │    │
│   └─────────────────────────────────────────────────────────────┘    │
│                               │                                        │
│                               ▼                                        │
│   ┌─────────────────────────────────────────────────────────────┐    │
│   │ 4. REFLECTION CALCULATION                                   │    │
│   │    • X = P + D * dot(A - P, D)   // Project onto line       │    │
│   │    • A' = 2X - A                  // Reflect across X       │    │
│   │    • A'.y *= aspect               // Back to screen space   │    │
│   └─────────────────────────────────────────────────────────────┘    │
│                               │                                        │
│                               ▼                                        │
│   ┌─────────────────────────────────────────────────────────────┐    │
│   │ 5. BOUNDS CHECK                                             │    │
│   │    • if length(A' - clamp(A', 0, 1)) < ε:                   │    │
│   │        → A' is in bounds, sample texture                    │    │
│   │    • else:                                                  │    │
│   │        → Out of bounds, return black                        │    │
│   └─────────────────────────────────────────────────────────────┘    │
│                               │                                        │
└───────────────────────────────┼────────────────────────────────────────┘
                               │
                               ▼
┌───────────────────────────────────────────────────────────────────────┐
│ OUTPUT: Mirrored Frame                                                 │
│   • Pixels on "keep" side: original color                             │
│   • Pixels on "reflect" side: color from mirrored position            │
│   • Out-of-bounds reflections: black                                  │
└───────────────────────────────────────────────────────────────────────┘
```

## Implications for Rust Framework Design

### When to Use 2D Planar Reflections

The 2D mirror technique is appropriate when:

1. **The mirror is genuinely flat** — floors, walls, water surfaces viewed from above.
2. **The scene is authored for reflection** — objects are roughly coplanar or depth variation is small.
3. **Performance is critical** — no budget for a second render pass.
4. **Visual quality over physical accuracy** — demos and stylized games where "looks right" beats "is right."

For Rust framework design, this should be one tool among several reflection techniques. Expose it as a post-processing effect with parameters for line position and angle. Artists can choose between SSR (general-purpose, expensive), 3D planar reflection (physically accurate, moderate cost), and 2D mirror (flat surfaces only, cheap).

### API Design: Parameters vs. Constraints

The shader's parameter space is minimal:

```rust
struct MirrorEffect {
    direction: f32,  // 0.0 to 1.0 (maps to 0-90 degrees)
    center: Vec2,    // UV coordinates (0-1)
}
```

This is preferable to exposing raw geometric parameters like "line point A, line point B" because it decouples the representation (two points) from the degrees of freedom (position + angle). The artist thinks in terms of "where is the mirror and which way does it tilt?" not "what are the endpoints of the line segment?"

A production API might add:

```rust
struct MirrorEffect {
    direction: f32,
    center: Vec2,
    fade_distance: Option<f32>,  // Fade reflection based on distance from line
    tint: Vec3,                   // Color tint for stylized reflections
    aspect_ratio: f32,            // Don't hardcode!
}
```

### Shader Portability: HLSL to WGSL

The core algorithm translates directly to WGSL with only syntactic changes:

```wgsl
// WGSL version
fn pixel_main(tex_coord: vec2<f32>) -> vec4<f32> {
    let aspect = 16.0 / 9.0;
    let angle = 3.14159265 * direction / 2.0;

    var P = vec2<f32>(centerX, centerY);
    let D = vec2<f32>(sin(angle), cos(angle));
    var A = tex_coord;

    P.y /= aspect;
    A.y /= aspect;

    let perpendicular = vec2<f32>(-D.y, D.x);
    if (dot(A - P, perpendicular) > 0.0) {
        return textureSample(inputTexture, linearSampler, tex_coord);
    }

    let X = P + D * dot(A - P, D);
    var reflectedA = 2.0 * X - A;
    reflectedA.y *= aspect;

    var result = vec4<f32>(0.0);
    if (length(reflectedA - clamp(reflectedA, vec2<f32>(0.0), vec2<f32>(1.0))) < 0.0001) {
        result = textureSample(inputTexture, linearSampler, reflectedA);
    }

    return result;
}
```

The only change needed: WGSL requires explicit type annotations (`vec2<f32>`) and uses `textureSample` instead of `.Sample()`. The algorithm itself is unchanged.

### Performance Characteristics

For a 1920×1080 frame:

- Pixels on "keep" side: ~1 million pixels × (1 dot product + 1 texture sample)
- Pixels on "reflect" side: ~1 million pixels × (2 dot products + 1 vector math + 1 texture sample)

At 60 FPS, this is approximately 120 million dot products and 2 million texture samples per second. On modern GPUs, this is negligible. The texture sample is the bottleneck, and since each pixel samples once, bandwidth is equivalent to a full-screen copy — about as cheap as post-processing gets.

The lack of loops or branches (beyond the side test, which is coherent within tiles) means excellent GPU utilization. Pixels process independently with no inter-pixel communication.

## Related Documents

For complete coverage of Clean Slate's rendering system:

- **[../rendering/lighting.md](../rendering/lighting.md)** — Reflection techniques comparison (SSR, IBL, planar)
- **[../rendering/post-processing.md](../rendering/post-processing.md)** — Post-processing architecture and pass ordering
- **[../shaders/index.md](../shaders/index.md)** — Shader inventory and categorization
- **[pbr-pipeline.md](pbr-pipeline.md)** — G-Buffer generation and deferred lighting
- **[ltc-area-lighting.md](ltc-area-lighting.md)** — Area light reflections (specular highlights)

## Source References

| File | Lines | Description |
|------|-------|-------------|
| `mirror.hlsl` | 76 | Original shader with Hungarian comments |
| `annotated/materials/mirror.hlsl` | 123 | Readable version with English annotations |

The annotated version expands the original 76 lines to 123 lines by adding:
- Detailed mathematical explanations
- Step-by-step algorithm breakdown
- Geometric interpretation of each operation
- Translation of Hungarian comments

Both versions implement identical algorithms. The annotated version serves as reference documentation for understanding the technique.
