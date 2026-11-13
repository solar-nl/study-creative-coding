// ============================================================================
// READABLE VERSION: Shadow Pass with UV Offset (Vertex Displacement)
// Original: ../materials/shadow-pass-with-uv-offset.hlsl (128 lines)
//
// Algorithm: Shadow map generation with texture-driven vertex displacement.
//            Extends the basic shadow pass to support deformed geometry,
//            ensuring shadows match the displaced visible mesh.
//
// Why This Exists:
//   When using vertex displacement in the main render pass, the shadow pass
//   must apply the same displacement. Otherwise, shadows won't match the
//   visible geometry, causing visual artifacts.
//
// Displacement System:
//   Same as colored-texture-uv-offset-anim:
//   - Sample deformation texture at UV2 + offset
//   - Displace along specified direction + normal
//   - Vertex color red channel acts as mask
//
// Parameters:
//   data.y — Alpha test threshold
//   data.zw — UV2 offset for deformation texture
//   scale.xyz — Scaled vertex offset direction
//   scale.w — Normal-direction offset scale
// ============================================================================

Texture2D alphaTexture : register(t0);   // For alpha-tested shadows
Texture2D deformTexture : register(t1);  // Vertex displacement map

SamplerState linearSampler : register(s0);

// ============================================================================
// Light Data Structure
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
}

cbuffer MaterialBuffer : register(b1)
{
    float4x4 worldMatrix;
    float4x4 invTransWorldMatrix;
    float4 materialData;   // y = alpha test, zw = UV2 offset
    float4 scaleParams;    // xyz = offset direction, w = normal scale
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
    float3 lightSpacePos : TEXCOORD2;
};

// ============================================================================
// Build Light View Matrix
// ============================================================================
float4x4 BuildLightViewMatrix(float3 eye, float3 direction)
{
    float3 z = normalize(direction);
    float3 x = normalize(cross(float3(0, 1, 0), z));
    float3 y = cross(z, x);

    float4x4 view = float4x4(
        x.x, y.x, z.x, 0,
        x.y, y.y, z.y, 0,
        x.z, y.z, z.z, 0,
        -dot(x, eye), -dot(y, eye), -dot(z, eye), 1
    );
    return transpose(view);
}

// ============================================================================
// Build Orthographic Projection Matrix
// ============================================================================
float4x4 BuildOrthoMatrix(float width, float height, float range)
{
    float zFar = 100;
    float zNear = 0;

    float4x4 ortho = float4x4(
        2 / width, 0, 0, 0,
        0, 2 / height, 0, 0,
        0, 0, 1 / (zNear - zFar), 0,
        0, 0, -zNear / (zNear - zFar), 1
    );
    return transpose(ortho);
}

// ============================================================================
// Vertex Shader — Transform to Light Space with Displacement
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // Build light-space matrices
    float4x4 lightView = BuildLightViewMatrix(lights[0].spotDirection.xyz, lights[0].position.xyz);
    float4x4 lightProj = BuildOrthoMatrix(lights[0].ambient.w, lights[0].diffuse.w, 0);

    // ========================================================================
    // Apply Vertex Displacement (must match main render pass)
    // ========================================================================
    float2 uv2Offset = input.uv.zw + materialData.zw;
    float deformScale = deformTexture.SampleLevel(linearSampler, uv2Offset, 0).x;

    float3 offsetDirection = scaleParams.xyz;
    float3 normalOffset = normalize(input.normal) * scaleParams.w;

    // Apply displacement with vertex color mask
    float3 displacement = deformScale * (1 - input.color.x) * (offsetDirection + normalOffset);
    float3 worldPos = mul(worldMatrix, float4(input.position + displacement, 1)).xyz;

    // Transform to light clip space
    output.position = mul(lightProj, mul(lightView, float4(worldPos, 1)));
    output.lightSpacePos = output.position.xyz / output.position.w;
    output.texCoord = input.uv.xy;

    return output;
}

// ============================================================================
// Pixel Shader — Output Depth for Shadow Map
// ============================================================================
float4 PixelMain(VertexOutput v) : SV_TARGET0
{
    // Alpha test
    float4 texColor = alphaTexture.Sample(linearSampler, v.texCoord);
    if (materialData.y < texColor.a)
        discard;

    // Variance shadow map output
    float depth = v.lightSpacePos.z;
    return float2(depth, depth * depth).xyxy;
}
