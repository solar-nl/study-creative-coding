// ============================================================================
// READABLE VERSION: Colored Texture with UV Offset Animation
// Original: ../materials/colored-texture-uv-offset-anim.hlsl (87 lines)
//
// Algorithm: Textured material with animated UV coordinates and vertex
//            displacement driven by a deformation texture.
//
// Features:
//   - Animated UV offset for texture scrolling
//   - Vertex displacement from deformation texture
//   - Alpha testing
//   - Color tint
//
// Vertex Displacement:
//   Samples a deformation texture using UV2 coordinates, then displaces
//   vertices along a user-defined direction plus the normal direction.
//   Vertex color (red channel) acts as a mask to control displacement.
//
// Parameters:
//   color — RGBA tint
//   alphatest.x — Alpha cutoff threshold
//   alphatest.yz — UV offset for texture scrolling
//   alphatest.w, uvoffsets.x — UV2 offset for deformation texture
//   uvoffsets.yzw — Scaled vertex offset direction (XYZ)
//   normaloffset — Normal-direction displacement scale
// ============================================================================

Texture2D diffuseTexture : register(t0);    // Color texture
Texture2D deformTexture : register(t1);     // Deformation/displacement map

SamplerState linearSampler : register(s0);

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 cameraPosition;
}

cbuffer MaterialBuffer : register(b1)
{
    float4x4 worldMatrix;
    float4x4 invTransWorldMatrix;
    float4 tintColor;         // Color tint
    float4 alphaTestParams;   // x=threshold, yz=uv offset, w=uv2 offset X
    float4 uvOffsets;         // x=uv2 offset Y, yzw=scaled offset
    float normalOffset;       // Normal direction offset scale
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
    float3 normal : TEXCOORD1;
    float2 texCoord : TEXCOORD0;
    float3 worldPos : TEXCOORD2;
};

// ============================================================================
// Vertex Shader with Displacement
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // ========================================================================
    // UV2-Based Vertex Displacement
    //
    // 1. Sample deformation texture at UV2 + offset
    // 2. Multiply by vertex color mask (1 - red channel)
    // 3. Displace along specified direction + normal
    // ========================================================================
    float2 uv2Offset = input.uv.zw + float2(alphaTestParams.w, uvOffsets.x);
    float deformScale = deformTexture.SampleLevel(linearSampler, uv2Offset, 0).x;

    float3 offsetDirection = uvOffsets.yzw;
    float3 normalDir = normalize(input.normal) * normalOffset;

    // Apply displacement (vertex color red channel masks the effect)
    float3 displacement = deformScale * (1 - input.color.x) * (offsetDirection + normalDir);
    output.worldPos = mul(worldMatrix, float4(input.position + displacement, 1)).xyz;

    output.position = mul(projectionMatrix, mul(viewMatrix, float4(output.worldPos, 1)));

    // Apply UV offset for texture scrolling
    output.texCoord = input.uv.xy + alphaTestParams.yz;
    output.normal = 0;

    return output;
}

// ============================================================================
// Pixel Shader
// ============================================================================
float4 PixelMain(VertexOutput v) : SV_TARGET0
{
    float4 texColor = diffuseTexture.Sample(linearSampler, v.texCoord);

    // Alpha test
    if (alphaTestParams.x > texColor.a * 255 / 256.0)
        discard;

    return texColor * tintColor;
}
