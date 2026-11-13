// ============================================================================
// READABLE VERSION: Sphere Light Body Renderer
// Original: ../materials/area-body-sphere-light-body.hlsl (101 lines)
//
// Algorithm: Ray-sphere intersection to render the light's visible body.
//            Outputs depth only (SV_DEPTH) for proper occlusion with scene.
//
// Purpose:
//   Renders the actual sphere geometry of an area light as a solid object.
//   Uses analytic ray-sphere intersection rather than mesh geometry, allowing
//   the light body to be rendered as a perfect sphere with correct depth.
//
// Technique:
//   1. Transform camera and far-plane point into light's local space
//   2. Compute ray-sphere intersection analytically
//   3. Output the intersection depth for the depth buffer
//
// Parameters:
//   worldMatrix — Transform defining sphere position and scale
//   Sphere radius is fixed at 0.5 in local space
// ============================================================================

// Textures (not used in this depth-only pass, but declared for slot consistency)
Texture2D texture0 : register(t0);
Texture2D texture1 : register(t1);
Texture2D texture2 : register(t2);
Texture2D texture3 : register(t3);
Texture2D texture4 : register(t4);
Texture2D depthTexture : register(t7);

SamplerState linearSampler : register(s1);

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
// Vertex Shader — Fullscreen quad
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;
    output.position = float4(input.position.xzy * 2, 1);
    output.texCoord = input.uv.xy;
    return output;
}

// ============================================================================
// Reconstruct world position from depth
// ============================================================================
float3 GetWorldPosition(float depth, float2 uv)
{
    float4 clipPos = mul(inverseViewMatrix, mul(inverseProjectionMatrix, float4(uv * 2 - 1, depth, 1)));
    return clipPos.xyz / clipPos.w;
}

#define PI 3.14159265

// ============================================================================
// Pixel Shader — Depth-Only Output
//
// This shader outputs only to SV_DEPTH, not SV_TARGET. It computes the
// analytically correct depth for the sphere's front surface at each pixel.
// ============================================================================
float PixelMain(VertexOutput input) : SV_DEPTH
{
    float4x4 invWorld = transpose(invTransWorldMatrix);

    // Transform camera position to light's local space
    float3 localCameraPos = -mul(invWorld, float4(cameraPosition.xyz, 1)).xyz;

    // Get a point on the far plane and transform to local space
    float3 farPoint = mul(invWorld, float4(GetWorldPosition(1, input.texCoord), 1)).xyz;

    // Ray direction from camera through this pixel
    float3 rayDir = normalize(farPoint - localCameraPos);

    // ========================================================================
    // Ray-Sphere Intersection
    //
    // Sphere equation: |P|^2 = r^2 (centered at origin, radius 0.5)
    // Ray equation: P = O + t*D
    //
    // Substituting: |O + t*D|^2 = r^2
    // Expanding: t^2 + 2(O·D)t + (|O|^2 - r^2) = 0
    //
    // Using quadratic formula with:
    //   a = 1 (|D|^2 = 1 for normalized direction)
    //   b = O·D
    //   c = |O|^2 - r^2
    //
    // Discriminant = b^2 - c
    // ========================================================================
    float b = dot(localCameraPos, rayDir);
    float c = dot(localCameraPos, localCameraPos) - 0.25;  // 0.25 = 0.5^2 (sphere radius)

    float discriminant = b * b - c;

    // No intersection - discard this pixel
    if (discriminant < 0)
        discard;

    // ========================================================================
    // Compute front intersection point
    //
    // t = -b ± sqrt(discriminant)
    // We want the front surface (larger t value since we're inside looking out,
    // or smaller positive t if outside looking in)
    //
    // Note: The original uses -b + sqrt() which gives the far intersection.
    // This appears intentional for the specific use case.
    // ========================================================================
    float t = -b + sqrt(discriminant);
    float3 hitPoint = -localCameraPos.xyz - rayDir * t;

    // Transform hit point back to world space, then to clip space
    float4 worldHitPoint = mul(worldMatrix, float4(hitPoint, 1));
    float4 clipPoint = mul(projectionMatrix, mul(viewMatrix, worldHitPoint));

    // Return normalized device depth
    return clipPoint.z / clipPoint.w;
}
