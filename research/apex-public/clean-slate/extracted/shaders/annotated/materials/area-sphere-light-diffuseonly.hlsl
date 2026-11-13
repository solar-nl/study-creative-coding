// ============================================================================
// READABLE VERSION: Diffuse-Only Sphere Light (LTC)
// Original: ../materials/area-sphere-light-diffuseonly.hlsl (165 lines)
//
// Algorithm: Simplified LTC sphere light for diffuse-only lighting.
//            Uses a 12-sided polygon (dodecagon) to approximate the projected
//            disc, then integrates using the LTC edge integration formula.
//
// Use Case:
//   Faster than full LTC when only diffuse lighting is needed.
//   Skips specular LTC matrix lookup and evaluation entirely.
//
// Parameters:
//   color.xyz — Light color (RGB)
//   worldMatrix — Transform giving light position and scale
//
// References:
//   - "Real-Time Polygonal-Light Shading with LTC" (Heitz et al., 2016)
// ============================================================================

// G-Buffer textures
Texture2D albedoMetalnessTexture : register(t0);    // RGB = albedo, A = metalness
Texture2D normalRoughnessTexture : register(t1);    // RGB = normal, A = roughness
Texture2D depthTexture : register(t7);              // Depth buffer

SamplerState linearSampler : register(s2);

// ============================================================================
// Light data structure
// ============================================================================
struct LightData
{
    float4 position;
    float4 ambient;
    float4 diffuse;
    float4 specular;
    float4 spotDirection;
    float4 spotAttenuation;
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
    float4x4 worldMatrix;
    float4x4 invTransWorldMatrix;
    float4 lightColor;
}

// ============================================================================
// Vertex Structures
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
// Vertex Shader
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;
    output.position = float4(input.position.xzy * 2, 1);
    output.texCoord = input.uv.xy;
    return output;
}

#define PI 3.14159265

// ============================================================================
// Pixel Shader — Diffuse-Only Sphere Light
// ============================================================================
float4 PixelMain(VertexOutput input) : SV_TARGET0
{
    int3 pixel = int3(input.position.xy, 0);
    float4 t0 = albedoMetalnessTexture.Load(pixel);
    float3 t1 = normalRoughnessTexture.Load(pixel).xyz;
    float depth = depthTexture.Load(pixel).x;

    // Reconstruct world position from depth
    float4 P = mul(inverseViewMatrix, mul(inverseProjectionMatrix, float4(input.texCoord * 2 - 1, depth, 1)));
    P /= P.w;
    float3 V = normalize(cameraPosition.xyz - P.xyz);

    // Surface normal
    float3 N = normalize(t1);

    // Basic lighting setup
    float NdotV = dot(N, V);

    float4x4 invWorld = transpose(invTransWorldMatrix);

    // ========================================================================
    // Calculate disc projection parameters
    //
    // Transform surface position to light's local space, then compute the
    // radius of the projected disc based on distance to sphere center.
    // ========================================================================
    float3 localP = mul(invWorld, P).xyz;
    float distToLight = length(localP);
    float3 toLight = localP / distToLight;

    // Projected disc scale: d / sqrt(4d^2 - 1)
    // This gives the apparent radius of the sphere as seen from the surface
    float discScale = distToLight / sqrt(4 * distToLight * distToLight - 1);

    // Build rotation axis to orient disc toward surface
    float3 up = float3(0, -1, 0);
    float3 rotAxis = normalize(cross(-toLight, up));

    // ========================================================================
    // Build diffuse-only LTC matrix (tangent frame aligned with view)
    // For diffuse, we use the identity transform in the tangent frame
    // ========================================================================
    float3 T1 = normalize(V - N * NdotV);  // Tangent
    float3 T2 = cross(N, T1);               // Bitangent
    float3x3 Minv = float3x3(T1, T2, N);

    // Storage for clipped polygon vertices
    float3 L[64];
    int n = 0;

    // Rotation parameters (axis-angle with y=0)
    float c = dot(toLight, up);
    float s = sqrt(1 - c * c);
    float t = 1 - c;
    float x = rotAxis.x;
    float z = rotAxis.z;

    // Build rotation matrix inline for efficiency
    float3x3 discRotation = float3x3(
        t*x*x + c,  -s*z,      t*x*z,
        s*z,         c,        -s*x,
        t*x*z,       s*x,      t*z*z + c
    );

    // ========================================================================
    // Generate 12-sided polygon and clip to hemisphere
    // ========================================================================
    float3 current;
    float sum = 0;

    for (int xx = 0; xx <= 12; xx++)
    {
        float angle = xx * PI / 6;  // 12 vertices = 30-degree increments

        // Generate vertex in local space, rotate to face surface, transform to world
        float3 localVertex = float3(cos(angle), 0, sin(angle)) * discScale;
        float3 worldVertex = mul(worldMatrix, float4(mul(discRotation, localVertex), 1)).xyz;

        // Transform to tangent space for LTC evaluation
        float3 next = mul(Minv, worldVertex - P.xyz);

        if (xx > 0)
        {
            // Clip edge to hemisphere (z > 0)
            if (current.z > 0)
                L[n++] = normalize(current);

            if ((current.z > 0) != (next.z > 0))
                L[n++] = normalize(lerp(current, next, -current.z / (next.z - current.z)));
        }
        current = next;
    }

    // ========================================================================
    // Unpack G-Buffer for diffuse calculation
    // ========================================================================
    float3 albedo = t0.xyz;
    float metallic = t0.w;

    // ========================================================================
    // LTC Edge Integration
    //
    // For each edge of the clipped polygon, compute its contribution using
    // the analytic formula for integrating over a spherical polygon.
    // ========================================================================
    for (int i = 0; i < n; i++)
    {
        float3 v1 = L[i];
        float3 v2 = L[(i + 1) % n];

        float dotV = dot(v1, v2);
        float y = abs(dotV);

        // Rational polynomial approximation for the edge integral
        float a = 0.8543985 + (0.4965155 + 0.0145206 * y) * y;
        float b = 3.4175940 + (4.1616724 + y) * y;
        float v = a / b;

        float theta_sintheta = (dotV > 0) ? v : 0.5 / sqrt(max(1 - dotV * dotV, 0.0000001)) - v;

        // Accumulate contribution (negative for correct winding)
        // Multiply by albedo and (1 - metallic) for diffuse-only
        sum -= cross(v1, v2).z * albedo * (1 - metallic) * theta_sintheta;
    }

    return sum * lightColor;
}
