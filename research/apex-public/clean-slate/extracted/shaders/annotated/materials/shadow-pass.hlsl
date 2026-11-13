// ============================================================================
// READABLE VERSION: Shadow Map Generation Pass
// Original: ../materials/shadow-pass.hlsl (113 lines)
//
// Algorithm: Renders scene depth from light's perspective for shadow mapping.
//            Outputs depth and depth-squared for Variance Shadow Maps (VSM).
//
// Shadow Mapping Overview:
//   1. Render scene from light's POV, storing depth values
//   2. In main pass, compare pixel depth to shadow map
//   3. If pixel is farther than shadow map depth, it's in shadow
//
// Output Format:
//   RG: (depth, depth^2) for variance shadow mapping
//   Depth^2 enables soft shadows via statistical analysis
//
// Matrix Construction:
//   The shader builds its own light view/projection matrices from
//   the light's position, direction, and shadow frustum dimensions.
//
// Parameters:
//   data.y — Alpha test threshold
//   lights[0].pos — Light direction
//   lights[0].spotdirection — Light position (shadow camera eye)
//   lights[0].ambient.w — Shadow ortho width
//   lights[0].diffuse.w — Shadow ortho height
// ============================================================================

Texture2D alphaTexture : register(t0);  // For alpha-tested shadows
SamplerState linearSampler : register(s0);

// ============================================================================
// Light Data Structure
// ============================================================================
struct LightData
{
    float4 position;        // xyz = direction, w = type
    float4 ambient;         // w = shadow ortho width
    float4 diffuse;         // w = shadow ortho height
    float4 specular;
    float4 spotDirection;   // xyz = shadow camera position
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
    float4 materialData;  // y = alpha test threshold
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
//
// Creates a view matrix looking from 'eye' along 'direction'.
// The up vector is assumed to be (0, 1, 0).
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
//
// Creates an orthographic projection for shadow mapping.
// Near plane at 0, far plane at 100.
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
// Vertex Shader — Transform to Light Space
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // Build light-space matrices
    float4x4 lightView = BuildLightViewMatrix(lights[0].spotDirection.xyz, lights[0].position.xyz);
    float4x4 lightProj = BuildOrthoMatrix(lights[0].ambient.w, lights[0].diffuse.w, 0);

    // Transform to world, then to light clip space
    output.lightSpacePos = mul(worldMatrix, float4(input.position, 1)).xyz;
    output.position = mul(lightProj, mul(lightView, float4(output.lightSpacePos, 1)));

    // Store normalized device coordinates
    output.lightSpacePos = output.position.xyz / output.position.w;
    output.texCoord = input.uv.xy;

    return output;
}

// ============================================================================
// Pixel Shader — Output Depth for Shadow Map
// ============================================================================
float4 PixelMain(VertexOutput v) : SV_TARGET0
{
    // Alpha test (for foliage shadows, etc.)
    float4 texColor = alphaTexture.Sample(linearSampler, v.texCoord);
    if (materialData.y < texColor.a)
        discard;

    // ========================================================================
    // Variance Shadow Map Output
    //
    // Store depth and depth^2 for statistical shadow filtering.
    // VSM uses the variance (E[x^2] - E[x]^2) to estimate shadow softness.
    // ========================================================================
    float depth = v.lightSpacePos.z;
    return float2(depth, depth * depth).xyxy;
}
