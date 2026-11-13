// ============================================================================
// READABLE VERSION: Optimized LTC Sphere Light
// Original: ../materials/area-sphere-light-ltc-optimized.hlsl (257 lines)
//
// Algorithm: Linearly Transformed Cosines (LTC) for analytical sphere light
//            integration. Optimized version that rotates the polygon to
//            align with the estimated reflection direction, reducing error.
//
// Key Optimization:
//   The disc polygon is rotated so its center aligns with a point interpolated
//   between the reflection ray intersection and the surface projection, weighted
//   by roughness. This improves specular highlight accuracy.
//
// Parameters:
//   color.xyz — Light color (RGB)
//   LTC1 texture — Stores the inverse LTC matrix coefficients (M^-1)
//   LTC2 texture — Stores Fresnel amplitude terms
//
// References:
//   - "Real-Time Polygonal-Light Shading with LTC" (Heitz et al., 2016)
//   - https://eheitzresearch.wordpress.com/415-2/
// ============================================================================

// G-Buffer textures
Texture2D albedoMetalnessTexture : register(t0);    // RGB = albedo, A = metalness
Texture2D normalRoughnessTexture : register(t1);    // RGB = normal, A = roughness
Texture2D ltcMatrixTexture : register(t4);          // LTC inverse matrix lookup
Texture2D ltcAmplitudeTexture : register(t5);       // LTC Fresnel/amplitude lookup
Texture2D depthTexture : register(t7);              // Depth buffer

SamplerState linearSampler : register(s2);

// ============================================================================
// Light data structure (matches engine's light array format)
// ============================================================================
struct LightData
{
    float4 position;        // xyz = position, w = positional flag
    float4 ambient;         // Ambient color (w unused here)
    float4 diffuse;         // Diffuse color (w unused here)
    float4 specular;        // Specular color
    float4 spotDirection;   // Spotlight direction
    float4 spotAttenuation; // Spotlight attenuation parameters
};

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 cameraPosition;
    float4 lightCount;
    LightData lights[8];
    float4 resolution;
    float4x4 inverseViewMatrix;
    float4x4 inverseProjectionMatrix;
}

cbuffer MaterialBuffer : register(b1)
{
    float4x4 worldMatrix;        // Light's world transform
    float4x4 invTransWorldMatrix; // Inverse transpose for normals
    float4 lightColor;           // RGB light color
}

// ============================================================================
// Vertex Input/Output Structures
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
    float4 position : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

// ============================================================================
// Lighting Context — Aggregates all surface data needed for shading
// ============================================================================
struct LightingContext
{
    float3 albedo;      // Surface albedo color
    float3 P;           // World position
    float3 V;           // View direction (toward camera)
    float3 N;           // Surface normal
    float3 f0;          // Fresnel reflectance at normal incidence
    float3 R;           // Reflection direction
    float roughness;
    float metallic;
    float NdotV;
    float NdotL;        // Not used in this shader
};

// ============================================================================
// Initialize lighting context from G-Buffer
// ============================================================================
inline LightingContext InitLighting(int2 pixel, float2 uv)
{
    float4 t0 = albedoMetalnessTexture.Load(int3(pixel, 0));
    float4 t1 = normalRoughnessTexture.Load(int3(pixel, 0));
    float depth = depthTexture.Load(int3(pixel, 0)).x;

    LightingContext ctx;

    // Reconstruct world position from depth
    float4 clipPos = mul(inverseViewMatrix, mul(inverseProjectionMatrix, float4(uv * 2 - 1, depth, 1)));
    ctx.P = clipPos.xyz / clipPos.w;
    ctx.V = normalize(cameraPosition.xyz - ctx.P);

    // Unpack G-Buffer data
    ctx.albedo = t0.xyz;
    ctx.metallic = t0.w;
    ctx.N = normalize(t1.xyz);
    ctx.roughness = t1.w;

    // Fix back-facing normals (ensure normal faces toward camera)
    float facing = dot(ctx.N, ctx.V);
    if (facing < 0)
        ctx.N = normalize(ctx.N - 1.01 * ctx.V * facing);

    // Precompute common terms
    ctx.NdotV = dot(ctx.N, ctx.V);
    ctx.f0 = lerp(0.04, ctx.albedo, ctx.metallic);  // Dielectric vs metallic F0
    ctx.R = reflect(ctx.V, ctx.N);                   // Note: reflect expects incident direction

    return ctx;
}

// ============================================================================
// LTC Common Data — Precomputed LTC matrices and modifiers
// ============================================================================
struct LTCData
{
    float3 diffuseModifier;     // Albedo scaled by (1 - metallic)
    float3 specularModifier;    // Fresnel-weighted specular term
    float3x3 ltcMatrixDiffuse;  // Identity-ish for diffuse (clamped cosine)
    float3x3 ltcMatrixSpecular; // Full LTC matrix for specular
};

// ============================================================================
// Initialize LTC matrices from lookup textures
//
// The LTC technique transforms the BRDF into a clamped cosine distribution
// by applying a linear transform M. The lookup tables store M^-1 indexed
// by roughness and viewing angle.
// ============================================================================
LTCData InitLTC(LightingContext ctx)
{
    LTCData data;

    // UV mapping for 16x16 LTC lookup texture
    // Maps roughness to U, sqrt(1 - NdotV) to V
    // The 15/16 + 1/32 offset centers samples on texels
    float2 ltcUV = float2(ctx.roughness, sqrt(1 - ctx.NdotV)) * 15.0 / 16.0 + 1.0 / 32.0;

    float4 t1 = ltcMatrixTexture.Sample(linearSampler, ltcUV);
    float2 t2 = ltcAmplitudeTexture.Sample(linearSampler, ltcUV).xy;

    // Build tangent frame from view direction
    float3 T1 = normalize(ctx.V - ctx.N * ctx.NdotV);  // Tangent in view plane
    float3 T2 = cross(ctx.N, T1);                       // Bitangent
    data.ltcMatrixDiffuse = float3x3(T1, T2, ctx.N);

    // Construct inverse LTC matrix from lookup
    // The texture stores: (a, b, _, c) where M^-1 = | a 0 c |
    //                                               | 0 1 0 |
    //                                               | b 0 d |
    float3x3 Minv = float3x3(
        t1.x, 0, t1.z,
        0,    1, 0,
        t1.y, 0, t1.w
    );
    data.ltcMatrixSpecular = mul(Minv, data.ltcMatrixDiffuse);

    // Amplitude terms: lerp between Fresnel min/max based on F0
    data.specularModifier = lerp(t2.y, t2.x, ctx.f0);
    data.diffuseModifier = ctx.albedo * (1 - ctx.metallic);

    return data;
}

// ============================================================================
// Global polygon data for LTC integration
// ============================================================================
static uint vertexCount;
static float3 points[64];  // Polygon vertices in surface-local space

// ============================================================================
// LTC_Evaluate — Analytically integrate transformed polygon
//
// The key insight: after transforming the polygon by M^-1, we can integrate
// the clamped cosine distribution analytically using edge integration.
//
// Parameters:
//   ctx — Lighting context
//   Minv — Inverse LTC matrix (identity for diffuse, full matrix for specular)
//   twoSided — Whether to include back-facing contributions
//
// Returns:
//   Normalized irradiance from the polygon
// ============================================================================
float LTC_Evaluate(LightingContext ctx, float3x3 Minv, bool twoSided)
{
    float3 L[64];
    uint n = 0;

    // Transform and clip polygon to upper hemisphere (z > 0)
    for (uint x = 0; x < vertexCount; x++)
    {
        float3 current = mul(Minv, points[x]);
        float3 next = mul(Minv, points[(x + 1) % vertexCount]);

        // Keep vertices above horizon
        if (current.z > 0)
            L[n++] = normalize(current);

        // Add intersection point where edge crosses horizon
        if ((current.z > 0) != (next.z > 0))
            L[n++] = normalize(lerp(current, next, -current.z / (next.z - current.z)));
    }

    float sum = 0;

    // ========================================================================
    // Edge integration using analytic formula
    // For each edge, compute the contribution to the hemisphere integral
    // using the vector irradiance form: sum of cross(v1, v2) * angle term
    // ========================================================================
    for (uint i = 0; i < n; i++)
    {
        float3 v1 = L[i];
        float3 v2 = L[(i + 1) % n];

        float x = dot(v1, v2);
        float y = abs(x);

        // Rational polynomial approximation for acos(x) * sin(acos(x)) / pi
        // This avoids expensive trig functions
        float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
        float b = 3.4175940 + (4.1616724 + y) * y;
        float v = a / b;

        // Handle negative dot products (obtuse angles)
        float theta_sintheta = (x > 0) ? v : 0.5 / sqrt(max(1 - x * x, 0.0000001)) - v;

        // Accumulate signed area contribution
        sum += cross(v1, v2).z * theta_sintheta;
    }

    return twoSided ? abs(sum) : max(0, -sum);
}

// ============================================================================
// Build rotation matrix from axis and angle (optimized for Y=0)
//
// Creates a rotation matrix for axis-angle rotation where the axis lies
// in the XZ plane (Y component forced to 0). This is sufficient for
// rotating discs to face the surface.
// ============================================================================
float4x4 AngleAxis3x3(float cosAngle, float3 axis)
{
    float c = cosAngle;
    float s = sqrt(1 - c * c);  // sin from cos
    float t = 1 - c;             // (1 - cos) for Rodrigues formula
    float x = axis.x;
    float z = axis.z;

    // Rodrigues rotation formula with y=0
    return float4x4(
        t*x*x + c,  -s*z,      t*x*z,     0,
        s*z,         c,        -s*x,      0,
        t*x*z,       s*x,      t*z*z + c, 0,
        0,           0,        0,         1
    );
}

// ============================================================================
// Vertex Shader — Fullscreen quad pass
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;
    output.position = float4(input.position.xzy * 2, 1);  // Expand to fullscreen
    output.texCoord = input.uv.xy;
    return output;
}

// ============================================================================
// Pixel Shader — LTC sphere light evaluation
// ============================================================================
float4 PixelMain(VertexOutput input) : SV_TARGET0
{
    float4 outputColor = float4(lightColor.xyz, 1);
    LightingContext ctx = InitLighting(input.position.xy, input.texCoord);

    float4x4 invWorld = transpose(invTransWorldMatrix);

    // ========================================================================
    // Light body rendering (for pixels with no valid normal)
    // If this pixel is on the light sphere surface, output light color
    // ========================================================================
    if (any(isnan(ctx.N)))
    {
        float3 localPos = mul(invWorld, float4(ctx.P, 1)).xyz;
        // Check if point is on unit sphere surface (within tolerance)
        if (length(localPos - normalize(localPos) * 0.5) < 0.01)
            return outputColor;
        return 0;
    }

    // ========================================================================
    // Sphere-to-disc projection for LTC
    //
    // The key optimization: project the sphere to a disc as seen from
    // the surface point, then rotate that disc to align with the expected
    // reflection direction for better specular accuracy.
    // ========================================================================
    vertexCount = 8;  // Octagon approximation of disc

    // Transform surface point to light's local space
    float3 localP = mul(invWorld, float4(ctx.P, 1)).xyz;
    float3 localR = mul(invWorld, float4(ctx.R, 0)).xyz;

    // Normalized direction to light center
    float3 toLight = normalize(localP);
    float distToLight = length(localP);

    // Calculate disc scale based on subtended angle
    // d/sqrt(4d^2 - 1) gives the radius of the projected disc
    float discScale = distToLight / sqrt(4 * distToLight * distToLight - 1);

    // Build rotation to orient disc perpendicular to view direction
    float3 up = float3(0, -1, 0);
    float3 rotAxis = normalize(cross(-toLight, up));
    float4x4 discRotation = AngleAxis3x3(dot(toLight, up), rotAxis);
    float4x4 invDiscRotation = transpose(discRotation);

    // Transform to disc-aligned space
    localP = mul(invDiscRotation, float4(localP, 1)).xyz;
    localR = mul(invDiscRotation, float4(localR, 0)).xyz;

    // Find intersection of reflection ray with disc plane (y = 0)
    float3 rayPlaneIntersect = localP - localR * localP.y / localR.y;
    localP.y = 0;  // Project surface point onto disc plane

    // ========================================================================
    // Optimization: Rotate disc to align with estimated reflection point
    // Interpolate between reflection intersection and projected point
    // based on roughness (rougher = more diffuse = closer to center)
    // ========================================================================
    float3 estimatedPoint = lerp(rayPlaneIntersect, localP, ctx.roughness);
    float additionalRotation = -atan2(estimatedPoint.x, estimatedPoint.z);

    // Generate disc polygon vertices
    for (uint v = 0; v < vertexCount; v++)
    {
        float angle = radians(360) * v / vertexCount + additionalRotation;
        float3 localVertex = float3(cos(angle), 0, sin(angle)) * discScale;
        // Transform back to world space, relative to surface point
        points[v] = mul(worldMatrix, float4(mul(discRotation, float4(localVertex, 0)).xyz, 1)).xyz - ctx.P;
    }

    // Evaluate LTC for diffuse and specular
    LTCData ltc = InitLTC(ctx);
    float3 diffuse = LTC_Evaluate(ctx, ltc.ltcMatrixDiffuse, true) * ltc.diffuseModifier;
    float3 specular = LTC_Evaluate(ctx, ltc.ltcMatrixSpecular, true) * ltc.specularModifier;

    return outputColor * float4(specular + diffuse, 1);
}
