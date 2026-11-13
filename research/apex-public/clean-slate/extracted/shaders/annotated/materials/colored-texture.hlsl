// ============================================================================
// READABLE VERSION: Colored Texture
// Original: ../materials/colored-texture.hlsl (75 lines)
//
// Algorithm: Simple textured material with color tint and alpha testing.
//            The most basic material for rendering textured geometry.
//
// Use Cases:
//   - UI elements
//   - Decals
//   - Simple props without lighting
//   - Transparency with alpha cutout
//
// Parameters:
//   color — RGBA tint multiplied with texture
//   alphatest — Alpha threshold (pixels with alpha below this are discarded)
// ============================================================================

Texture2D diffuseTexture : register(t0);
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
    float alphaTest;    // Alpha cutoff threshold
    float4 tintColor;   // Color multiplier
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
// Vertex Shader
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    output.worldPos = mul(worldMatrix, float4(input.position, 1)).xyz;
    output.position = mul(projectionMatrix, mul(viewMatrix, float4(output.worldPos, 1)));
    output.texCoord = input.uv.xy;
    output.normal = 0;  // Not used for unlit material

    return output;
}

// ============================================================================
// Pixel Shader — Textured with Alpha Test
// ============================================================================
float4 PixelMain(VertexOutput v) : SV_TARGET0
{
    float4 texColor = diffuseTexture.Sample(linearSampler, v.texCoord);

    // ========================================================================
    // Alpha Test
    //
    // Discard pixels below the alpha threshold. The 255/256 scaling
    // accounts for byte-to-float conversion precision.
    // ========================================================================
    if (alphaTest > texColor.a * 255 / 256.0)
        discard;

    // Apply color tint
    return texColor * tintColor;
}
