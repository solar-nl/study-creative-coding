// ============================================================================
// READABLE VERSION: Deferred Ambient Light
// Original: ../materials/deferred-ambient-light.hlsl (115 lines)
//
// Algorithm: Simple ambient/diffuse IBL approximation for deferred rendering.
//            Computes a single-sample diffuse environment contribution using
//            Fresnel-weighted diffuse term.
//
// Purpose:
//   Provides a fast ambient light pass that accounts for material properties.
//   Not full IBL (no environment map sampling), but applies physically-based
//   energy conservation using Fresnel attenuation.
//
// Parameters:
//   lightColor.xyz — Ambient light color/intensity
//
// Output:
//   Diffuse ambient contribution = (1 - F) * (1 - metallic) * albedo * lightColor / PI
//
// References:
//   - Basic PBR ambient term derivation from Epic's PBR notes
// ============================================================================

// G-Buffer textures
Texture2D albedoMetalnessTexture : register(t0);    // RGB = albedo, A = metalness
Texture2D normalRoughnessTexture : register(t1);    // RGB = normal, A = roughness
Texture2D depthTexture : register(t7);              // Depth buffer

SamplerState linearSampler : register(s0);

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
    float4 lightColor;  // Ambient light color
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
    float4 lightData : TEXCOORD1;  // xyz = light position, w = radius
};

// ============================================================================
// Vertex Shader
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;
    output.position = float4(input.position.xzy * 2, 1);

    // Extract light position from world matrix
    output.lightData.xyz = transpose(worldMatrix)[3].xyz;
    // Extract light radius from world matrix scale
    output.lightData.w = length(mul(worldMatrix, float4(0, 1, 0, 0)));

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
// Schlick Fresnel Approximation
// F(theta) = F0 + (1 - F0) * (1 - cos(theta))^5
// ============================================================================
float3 FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

// ============================================================================
// Diffuse IBL Contribution
//
// Computes the diffuse ambient term with Fresnel attenuation.
// The (1 - F) term accounts for energy that isn't reflected (goes into diffuse).
// The (1 - metallic) term zeros out diffuse for pure metals.
//
// Parameters:
//   N — Surface normal
//   V — View direction
//   F0 — Fresnel reflectance at normal incidence
//   albedo — Surface albedo color
//   metallic — Metalness value (0 = dielectric, 1 = metal)
//
// Returns:
//   Diffuse ambient color contribution
// ============================================================================
float3 DiffuseIBL(float3 N, float3 V, float3 F0, float3 albedo, float metallic)
{
    // Use N as the "light direction" for ambient (hemisphere average approximation)
    float3 H = normalize(V + N);
    float3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

    // Diffuse = (1 - F) * (1 - metallic) * albedo * lightColor / PI
    return (1 - F) * (1.0 - metallic) * lightColor.xyz * albedo / PI;
}

// ============================================================================
// Pixel Shader — Ambient Light Pass
// ============================================================================
float4 PixelMain(VertexOutput input) : SV_TARGET0
{
    // Load G-Buffer data
    float4 albedo = albedoMetalnessTexture.Load(int3(input.position.xy, 0));
    float4 normal = normalRoughnessTexture.Load(int3(input.position.xy, 0));
    float depth = depthTexture.Load(int3(input.position.xy, 0)).x;

    float roughness = normal.w;
    float metallic = albedo.w;

    // Reconstruct vectors
    float3 N = normalize(normal.xyz);
    float3 V = normalize(cameraPosition.xyz - GetWorldPosition(depth, input.texCoord));

    // Compute Fresnel at normal incidence (F0)
    // Dielectrics use 0.04, metals use their albedo color
    float3 F0 = 0.04;
    F0 = lerp(F0, albedo.xyz, metallic);

    // Output diffuse ambient contribution
    return float4(DiffuseIBL(N, V, F0, albedo.xyz, metallic), 1);
}
