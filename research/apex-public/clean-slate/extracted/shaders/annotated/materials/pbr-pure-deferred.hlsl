// ============================================================================
// READABLE VERSION: Pure Deferred PBR (G-Buffer Only)
// Original: ../materials/pbr-pure-deferred.hlsl (122 lines)
//
// Algorithm: G-Buffer fill pass for deferred PBR rendering.
//            Outputs surface properties only — no lighting calculation.
//
// Purpose:
//   Writes albedo, metalness, normal, and roughness to G-Buffer render targets.
//   Lighting is computed in a separate fullscreen pass using these values.
//
// Output Layout:
//   RT1 (am): RGB = albedo, A = metalness (modified)
//   RT2 (nr): RGB = perturbed normal, A = roughness (modified)
//
// Parameters:
//   data.x — Roughness modifier (127/255 = neutral)
//   data.y — Metalness modifier (127/255 = neutral)
//   data.z — Invert normals flag (> 0.5 = flip normal)
//
// References:
//   - "Deferred Shading" (Hargreaves & Harris, GDC 2004)
// ============================================================================

// Material textures
Texture2D albedoTexture : register(t0);    // RGB = albedo, A = metalness
Texture2D normalTexture : register(t1);    // RGB = tangent-space normal, A = roughness

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
    float4 materialParams;  // x=roughMod, y=metalMod, z=invertNormals
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
    float4 uv : TEXCOORD0;
    float3 worldPos : TEXCOORD2;
};

// ============================================================================
// Vertex Shader
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    output.worldPos = mul(worldMatrix, float4(input.position, 1)).xyz;
    output.normal = mul(invTransWorldMatrix, float4(input.normal, 0)).xyz;
    output.position = mul(projectionMatrix, mul(viewMatrix, float4(output.worldPos, 1)));
    output.uv = input.uv;

    return output;
}

// ============================================================================
// Derivative-Based Normal Perturbation
//
// Constructs a tangent frame using screen-space derivatives of position
// and UV coordinates. This eliminates the need for vertex tangent attributes.
//
// The technique works by solving for the tangent/bitangent that maps the
// UV gradients to the position gradients in 3D space.
//
// Parameters:
//   N — Interpolated vertex normal
//   worldPos — World-space position
//   uv — Texture coordinates
//   normalMap — Tangent-space normal from texture
//
// Returns:
//   World-space perturbed normal
// ============================================================================
float3 PerturbNormal(float3 N, float3 worldPos, float2 uv, float3 normalMap)
{
    // Screen-space derivatives
    float3 dp1 = ddx(worldPos);
    float3 dp2 = ddy(worldPos);
    float2 duv1 = ddx(uv);
    float2 duv2 = ddy(uv);

    // Solve linear system for tangent/bitangent
    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    // Normalize to construct orthonormal basis
    float invmax = rsqrt(max(dot(T, T), dot(B, B)));
    float3x3 TBN = float3x3(T * invmax, B * invmax, N);

    // Handle missing/black normal map (use flat normal)
    if (dot(normalMap, normalMap) == 0)
        normalMap = float3(0.5, 0.5, 1);

    // Expand from [0,1] to [-1,1] range
    normalMap = normalMap * 2 - 1;

    // Transform to world space
    return normalize(mul(normalMap, TBN));
}

// ============================================================================
// Bidirectional Modifier
//
// Applies a modifier value to a texture-sampled parameter.
// The modifier uses 127/255 (~0.498) as the neutral midpoint:
//   - Values below 0.498 scale the input down proportionally
//   - Values above 0.498 interpolate toward 1.0
//
// This allows both darkening (< 0.498) and brightening (> 0.498) of
// texture values, with 0.498 leaving the value unchanged.
//
// Parameters:
//   value — Original texture value (0-1)
//   modifier — Modifier value (0-1, neutral at 127/255)
//
// Returns:
//   Modified value (0-1)
// ============================================================================
float ApplyModifier(float value, float modifier)
{
    const float neutral = 127.0 / 255.0;

    if (modifier <= neutral)
        return value * modifier / neutral;
    else
        return lerp(value, 1, (modifier - neutral) / (128.0 / 255.0));
}

// ============================================================================
// Pixel Shader Output Structure
// ============================================================================
struct PixelOutput
{
    float4 albedoMetalness : SV_TARGET1;  // RGB = albedo, A = metalness
    float4 normalRoughness : SV_TARGET2;  // RGB = normal, A = roughness
};

// ============================================================================
// Pixel Shader — G-Buffer Fill
// ============================================================================
PixelOutput PixelMain(VertexOutput input)
{
    // Normal inversion multiplier (for back faces or inside-out geometry)
    float normalMultiplier = 1;
    if (materialParams.z > 0.5)
        normalMultiplier = -1;

    // Sample textures
    float4 albedo = albedoTexture.Sample(linearSampler, input.uv.xy);
    float4 normalMap = normalTexture.Sample(linearSampler, input.uv.xy);

    // Compute world-space normal
    float3 worldNormal = PerturbNormal(normalize(input.normal) * normalMultiplier, input.worldPos, input.uv.xy, normalMap.xyz);

    // Apply modifiers
    albedo.w = ApplyModifier(albedo.w, materialParams.y);  // Metalness

    // Output to G-Buffer
    PixelOutput output;
    output.normalRoughness = float4(worldNormal, ApplyModifier(normalMap.w, materialParams.x));
    output.albedoMetalness = albedo;

    return output;
}
