// ============================================================================
// READABLE VERSION: LTC Sphere Area Light
// Original: ../materials/area-sphere-light-ltc.hlsl (246 lines)
//
// Algorithm: Linearly Transformed Cosines (LTC) for analytical area light
//            integration. Transforms the BRDF lobe into a clamped cosine
//            distribution that has a closed-form solution for polygonal lights.
//
// How It Works:
//   1. Approximate the visible sphere disc as a 24-vertex polygon
//   2. Look up the LTC transformation matrix from pre-computed tables
//   3. Transform the polygon by the inverse LTC matrix
//   4. Clip the transformed polygon to the upper hemisphere
//   5. Integrate the clamped cosine analytically using edge summation
//
// G-Buffer Input (from previous passes):
//   t0: Albedo.rgb, Metalness.a
//   t1: Normal.xyz, Roughness.a
//   t7: Depth buffer
//
// LTC Lookup Tables:
//   ltc1: 16x16 R16G16B16A16_FLOAT — Transformation matrix coefficients
//   ltc2: 16x16 R8G8B8A8_UNORM — Magnitude and Fresnel factors
//
// Key Insight:
//   The GGX BRDF has no analytical integral over arbitrary shapes, but
//   a clamped cosine distribution does. LTC finds a 3x3 matrix that
//   transforms GGX into cosine, enabling noise-free area light evaluation.
//
// References:
//   - "Real-Time Polygonal-Light Shading with LTC" (Heitz et al., 2016)
//   - https://eheitzresearch.wordpress.com/415-2/
// ============================================================================

// ============================================================================
// TEXTURE AND SAMPLER BINDINGS
// ============================================================================

Texture2D albedoMetalnessTexture : register(t0);   // G-Buffer RT1
Texture2D normalRoughnessTexture : register(t1);   // G-Buffer RT2
Texture2D ltcMatrixTexture : register(t4);         // LTC transformation matrix
Texture2D ltcMagnitudeTexture : register(t5);      // LTC magnitude + Fresnel
Texture2D depthTexture : register(t7);             // Depth buffer

SamplerState linearSampler : register(s2);

// ============================================================================
// LIGHT DATA STRUCTURE
// ============================================================================

struct LightData
{
    float4 position;
    float4 ambient;
    float4 diffuse;
    float4 specular;
    float4 spotDirection;
    float4 spotDirAttenuation;
};

// ============================================================================
// CONSTANT BUFFERS
// ============================================================================

cbuffer SceneBuffer : register(b0)
{
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 cameraPosition;
    float4 lightCount;
    LightData lights[8];
    float4 resolution;              // Screen resolution
    float4x4 inverseViewMatrix;     // For world position reconstruction
    float4x4 inverseProjectionMatrix;
}

cbuffer ObjectBuffer : register(b1)
{
    float4x4 worldMatrix;           // Light sphere's world transform
    float4x4 inverseTransposeWorldMatrix;
    float4 lightColor;              // RGB light color, A unused
}

// ============================================================================
// SHADER STRUCTURES
// ============================================================================

struct VertexInput
{
    float3 position : POSITION0;
    float3 position2 : POSITION1;
    float3 normal : NORMAL0;
    float4 color : COLOR0;
    float4 uv : TEXCOORD0;
    float4 uv2 : TEXCOORD1;
};

struct VertexOutput
{
    float4 clipPosition : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

// ============================================================================
// LIGHTING CONTEXT
// Collects all surface data needed for lighting calculations
// ============================================================================

struct LightingContext
{
    float3 albedo;      // Surface color
    float3 position;    // World position (reconstructed from depth)
    float3 viewDir;     // View direction (normalized)
    float3 normal;      // Surface normal
    float3 F0;          // Fresnel reflectance at normal incidence
    float3 reflection;  // Reflection direction
    float roughness;
    float metallic;
    float NdotV;        // Dot(normal, view) — used for Fresnel
    float NdotL;        // Dot(normal, light) — unused in this shader
};

// Initialize lighting context from G-Buffer data
inline LightingContext InitializeLightingContext(int2 pixelCoord, float2 screenUV)
{
    // Sample G-Buffer
    float4 albedoMetalness = albedoMetalnessTexture.Load(int3(pixelCoord, 0));
    float4 normalRoughness = normalRoughnessTexture.Load(int3(pixelCoord, 0));
    float depth = depthTexture.Load(int3(pixelCoord, 0)).x;

    LightingContext ctx;

    // Reconstruct world position from depth
    // screenUV is in [0,1], convert to clip space [-1,1]
    float4 clipPos = float4(screenUV * 2 - 1, depth, 1);
    float4 worldPos = mul(inverseViewMatrix, mul(inverseProjectionMatrix, clipPos));
    ctx.position = worldPos.xyz / worldPos.w;

    // View direction from surface to camera
    ctx.viewDir = normalize(cameraPosition.xyz - ctx.position);

    // Unpack G-Buffer data
    ctx.albedo = albedoMetalness.xyz;
    ctx.metallic = albedoMetalness.w;
    ctx.normal = normalize(normalRoughness.xyz);
    ctx.roughness = normalRoughness.w;

    // Fix normals pointing away from view (can happen with normal mapping)
    // This ensures we don't get negative lighting contributions
    float NdotV_test = dot(ctx.normal, ctx.viewDir);
    if (NdotV_test < 0)
    {
        // Nudge normal toward view direction just enough to make it positive
        ctx.normal = normalize(ctx.normal - 1.01 * ctx.viewDir * NdotV_test);
    }

    // Pre-compute common values
    ctx.NdotV = dot(ctx.normal, ctx.viewDir);
    ctx.F0 = lerp(0.04, ctx.albedo, ctx.metallic);  // Dielectric vs metallic F0
    ctx.reflection = reflect(ctx.viewDir, ctx.normal);

    return ctx;
}

// ============================================================================
// LTC COMMON DATA
// Pre-computed matrices and modifiers for diffuse and specular evaluation
// ============================================================================

struct LTCData
{
    float3 diffuseModifier;     // Color multiplier for diffuse
    float3 specularModifier;    // Color multiplier for specular
    float3x3 diffuseMatrix;     // LTC matrix for diffuse (identity in tangent space)
    float3x3 specularMatrix;    // LTC matrix for specular (transforms GGX to cosine)
};

LTCData InitializeLTC(LightingContext ctx)
{
    LTCData ltc;

    // ========================================================================
    // Sample LTC lookup tables
    // UV is parameterized by (roughness, sqrt(1 - NdotV))
    // The sqrt term provides better sampling at grazing angles where
    // the BRDF changes rapidly.
    //
    // UV offset: * 15/16 + 1/32 maps [0,1] to texel centers in a 16x16 texture
    // This avoids edge sampling artifacts.
    // ========================================================================
    float2 ltcUV = float2(ctx.roughness, sqrt(1 - ctx.NdotV)) * (15.0 / 16.0) + (1.0 / 32.0);

    float4 ltcMatrixCoeffs = ltcMatrixTexture.Sample(linearSampler, ltcUV);
    float2 ltcMagnitude = ltcMagnitudeTexture.Sample(linearSampler, ltcUV).xy;

    // ========================================================================
    // Build tangent frame
    // T1 = view direction projected onto tangent plane (perpendicular to N)
    // T2 = cross product to complete the orthonormal frame
    // ========================================================================
    float3 T1 = normalize(ctx.viewDir - ctx.normal * ctx.NdotV);
    float3 T2 = cross(ctx.normal, T1);

    // Diffuse matrix is just the tangent frame rotation (no BRDF transformation)
    ltc.diffuseMatrix = float3x3(T1, T2, ctx.normal);

    // ========================================================================
    // Expand LTC matrix from stored coefficients
    // The full 3x3 matrix has this structure (Y axis preserved):
    //   | m00   0   m02 |
    //   |  0    1    0  |
    //   | m10   0   m11 |
    //
    // Only 4 values need storage (in texture RGBA):
    //   R = m00, G = m10, B = m02, A = m11
    // ========================================================================
    float3x3 ltcInverseMatrix = float3x3(
        ltcMatrixCoeffs.x, 0, ltcMatrixCoeffs.z,
        0,                 1, 0,
        ltcMatrixCoeffs.y, 0, ltcMatrixCoeffs.w
    );

    // Combine LTC transformation with tangent frame rotation
    ltc.specularMatrix = mul(ltcInverseMatrix, ltc.diffuseMatrix);

    // ========================================================================
    // Compute energy modifiers
    // ltcMagnitude.x = LTC magnitude (energy normalization)
    // ltcMagnitude.y = Fresnel scale factor
    //
    // Specular modifier interpolates between Fresnel extremes based on F0
    // ========================================================================
    ltc.specularModifier = lerp(ltcMagnitude.y, ltcMagnitude.x, ctx.F0);

    // Diffuse modifier: albedo attenuated by (1 - metallic)
    // (metals have no diffuse component)
    ltc.diffuseModifier = ctx.albedo * (1 - ctx.metallic);

    return ltc;
}

// ============================================================================
// POLYGON STORAGE (Global for reuse across evaluations)
// ============================================================================

static uint polygonVertexCount;
static float3 polygonVertices[64];  // Light polygon in P-relative coordinates

// ============================================================================
// LTC POLYGON EVALUATION
// Clips the polygon to the upper hemisphere and integrates the clamped cosine
//
// Parameters:
//   ctx — Lighting context
//   Minv — Inverse LTC matrix (transforms BRDF space to cosine space)
//   twoSided — Whether to count contributions from both sides
//
// Returns:
//   Irradiance from the polygon (scalar, will be colored by modifier)
// ============================================================================

float EvaluateLTCPolygon(LightingContext ctx, float3x3 Minv, bool twoSided)
{
    float3 clippedVertices[64];
    uint clippedCount = 0;

    // ========================================================================
    // Sutherland-Hodgman clipping against z=0 plane
    // After LTC transformation, vertices below z=0 are below the horizon
    // and contribute no light. We clip the polygon to the upper hemisphere.
    // ========================================================================
    for (uint i = 0; i < polygonVertexCount; i++)
    {
        // Transform vertices by inverse LTC matrix
        float3 current = mul(Minv, polygonVertices[i]);
        float3 next = mul(Minv, polygonVertices[(i + 1) % polygonVertexCount]);

        // Keep vertices above horizon (z > 0)
        if (current.z > 0)
        {
            clippedVertices[clippedCount++] = normalize(current);
        }

        // If edge crosses horizon, add intersection point
        if ((current.z > 0) != (next.z > 0))
        {
            // Linear interpolation to find z=0 crossing
            float t = -current.z / (next.z - current.z);
            clippedVertices[clippedCount++] = normalize(lerp(current, next, t));
        }
    }

    // ========================================================================
    // Edge integration
    // The integral of clamped cosine over a spherical polygon equals the sum
    // of edge contributions. Each edge contributes:
    //   (v1 × v2).z × F(v1·v2)
    // where F(x) = acos(x) / sin(acos(x))
    //
    // The rational polynomial approximation avoids expensive trig functions.
    // ========================================================================
    float sum = 0;

    for (uint j = 0; j < clippedCount; j++)
    {
        float3 v1 = clippedVertices[j];
        float3 v2 = clippedVertices[(j + 1) % clippedCount];

        // Dot product between adjacent vertices (cosine of angle between them)
        float x = dot(v1, v2);
        float y = abs(x);

        // Rational polynomial approximation to theta/sin(theta)
        // This avoids acos() and sin() which are expensive
        float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
        float b = 3.4175940 + (4.1616724 + y) * y;
        float v = a / b;

        // Handle the sign: formula differs for x > 0 vs x < 0
        float theta_sintheta = (x > 0) ? v : 0.5 / sqrt(max(1 - x * x, 0.0000001)) - v;

        // Accumulate: cross product z-component gives signed area contribution
        sum += (cross(v1, v2) * theta_sintheta).z;
    }

    // Return absolute value for two-sided, or clamped negative for one-sided
    // (negative due to polygon winding convention)
    return twoSided ? abs(sum) : max(0, -sum);
}

// ============================================================================
// AXIS-ANGLE ROTATION MATRIX
// Builds a rotation matrix from axis and angle (optimized for Y=0 case)
// Used to orient the sphere's visible disc toward the shading point
// ============================================================================

float4x4 AxisAngleRotation(float cosAngle, float3 axis)
{
    float c = cosAngle;
    float s = sqrt(1 - c * c);  // sin from cos
    float t = 1 - c;
    float x = axis.x;
    float z = axis.z;

    // Rodrigues' rotation formula, simplified for axis.y = 0
    return float4x4(
        t * x * x + c,  -s * z,        t * x * z,     0,
        s * z,          c,             -s * x,        0,
        t * x * z,      s * x,         t * z * z + c, 0,
        0,              0,             0,             1
    );
}

// ============================================================================
// VERTEX SHADER
// Renders a full-screen quad for deferred lighting
// ============================================================================

VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // Full-screen triangle: positions are in [0,1], scale to [-1,1]
    // The .xzy swizzle and *2 converts from mesh UV space to clip space
    output.clipPosition = float4(input.position.xzy * 2, 1);
    output.texCoord = input.uv.xy;

    return output;
}

// ============================================================================
// PIXEL SHADER
// ============================================================================

float4 PixelMain(VertexOutput input) : SV_TARGET0
{
    float4 outputColor = float4(lightColor.xyz, 1);

    // Initialize lighting context from G-Buffer
    LightingContext ctx = InitializeLightingContext(input.clipPosition.xy, input.texCoord);

    // Transform shading point to light's local space
    float4x4 invWorldTranspose = transpose(inverseTransposeWorldMatrix);

    // ========================================================================
    // Special case: draw the light body itself
    // If normal is NaN (empty G-Buffer), check if we're on the light surface
    // ========================================================================
    if (any(isnan(ctx.normal)))
    {
        float3 localPos = mul(invWorldTranspose, float4(ctx.position, 1)).xyz;
        // Check if position is on unit sphere surface (within tolerance)
        if (length(localPos - normalize(localPos) * 0.5) < 0.01)
        {
            return float4(outputColor.xyz, 0);  // Draw light emitter
        }
        return 0;  // Empty space
    }

    // ========================================================================
    // Sphere disc approximation
    // The visible portion of a sphere from any viewpoint is a disc.
    // We approximate this disc as a 24-vertex polygon.
    // ========================================================================

    // Transform shading point and reflection to light's local space
    float3 localShadingPoint = mul(invWorldTranspose, float4(ctx.position, 1)).xyz;
    float3 localReflection = mul(invWorldTranspose, float4(ctx.reflection, 0)).xyz;

    // Direction from light center to shading point
    float3 toShadingPoint = normalize(localShadingPoint);
    float distanceToCenter = length(localShadingPoint);

    // Calculate visible disc radius
    // For a unit sphere at distance d, the visible disc subtends an angle θ
    // where sin(θ) = 1/(2d), and the disc radius is d × tan(θ)
    // Simplified: scale = d / sqrt(4d² - 1)
    float discScale = distanceToCenter / sqrt(4 * distanceToCenter * distanceToCenter - 1);

    // Build rotation matrix to orient disc perpendicular to viewing direction
    float3 up = float3(0, -1, 0);
    float3 rotationAxis = normalize(cross(-toShadingPoint, up));
    float4x4 discRotation = AxisAngleRotation(dot(toShadingPoint, up), rotationAxis);

    // Generate polygon vertices for the disc
    polygonVertexCount = 24;
    for (uint v = 0; v < polygonVertexCount; v++)
    {
        // Angle around the disc
        float angle = radians(360) * v / polygonVertexCount;

        // Vertex on unit circle in XZ plane
        float4 circlePoint = float4(cos(angle), 0, sin(angle), 0) * discScale;

        // Rotate to face shading point, transform to world space
        float4 rotatedPoint = mul(discRotation, circlePoint);
        float3 worldPoint = mul(worldMatrix, float4(rotatedPoint.xyz, 1)).xyz;

        // Store relative to shading point (P-space)
        polygonVertices[v] = worldPoint - ctx.position;
    }

    // ========================================================================
    // LTC Evaluation
    // Evaluate twice: once for diffuse (identity transform) and once for
    // specular (full LTC transform). Each uses the same clipped polygon.
    // ========================================================================

    LTCData ltc = InitializeLTC(ctx);

    float3 diffuse = EvaluateLTCPolygon(ctx, ltc.diffuseMatrix, true) * ltc.diffuseModifier;
    float3 specular = EvaluateLTCPolygon(ctx, ltc.specularMatrix, true) * ltc.specularModifier;

    return outputColor * float4(specular + diffuse, 1);
}
