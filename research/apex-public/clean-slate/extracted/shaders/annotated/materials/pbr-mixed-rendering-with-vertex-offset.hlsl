// ============================================================================
// READABLE VERSION: PBR Mixed Rendering with Vertex Offset
// Original: ../materials/pbr-mixed-rendering-with-vertex-offset.hlsl (365 lines)
//
// Algorithm: Full Cook-Torrance PBR with texture-driven vertex displacement.
//            "Mixed rendering" combines forward lighting pass with G-Buffer output.
//
// Vertex Displacement:
//   Reads a deformation texture and offsets vertices along a specified direction
//   plus scaled normal direction. Useful for terrain, animated surfaces, etc.
//
// Features:
//   - Cook-Torrance BRDF (GGX NDF, Smith G, Schlick F)
//   - Derivative-based normal mapping (no vertex tangents needed)
//   - 5x5 PCF shadow mapping
//   - Bidirectional roughness/metalness modifiers
//   - Two-sided rendering with geometry shader
//   - Forward lit output + G-Buffer (albedo/metalness, normal/roughness)
//
// Parameters:
//   dat.x — Roughness modifier (127/255 = neutral)
//   dat.y — Metalness modifier (127/255 = neutral)
//   dat.z — Two-sided flag (> 0.5 = enable)
//   dat.w — Shadow bias
//   shd.x — Shadow softness
//   shd.y — Alpha test threshold
//   shd.zw — UV offset
//   scale1.xy — UV2 offset (for deform texture)
//   scale1.zw, scale2.x — Scaled vertex offset (xyz direction)
//   scale2.y — Normal-direction offset scale
//
// References:
//   - "Microfacet Models for Refraction" (Walter et al., 2007)
//   - "Real Shading in Unreal Engine 4" (Karis, SIGGRAPH 2013)
// ============================================================================

// Material textures
Texture2D albedoTexture : register(t0);         // RGB = albedo, A = metalness
Texture2D normalTexture : register(t1);         // RGB = normal, A = roughness
Texture2D emissiveTexture : register(t2);       // RGB = emissive, A = alpha
Texture2D shadowMapTexture : register(t3);      // Shadow depth map
Texture2D deformTexture : register(t4);         // Vertex displacement map

SamplerState linearSampler : register(s0);
SamplerComparisonState shadowSampler : register(s2);

// ============================================================================
// Light data structure
// ============================================================================
struct LightData
{
    float4 position;        // xyz = position, w = positional flag
    float4 ambient;         // w = shadow ortho width
    float4 diffuse;         // w = shadow ortho height
    float4 specular;
    float4 spotDirection;   // xyz = light direction for shadow
    float4 spotAttenuation; // x = spot exponent, y = spot cutoff
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
    float4 materialParams;      // x=roughMod, y=metalMod, z=twoSided, w=shadowBias
    float4 shadowParams;        // x=softness, y=alphaThreshold, zw=uvOffset
    float4 offsetParams1;       // xy=uv2Offset, zw=scaledOffset.xy
    float4 offsetParams2;       // x=scaledOffset.z, y=normalScale
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
    float3 lightSpacePos : TEXCOORD3;
};

// ============================================================================
// Build View Matrix for Shadow Mapping
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
// Build Orthographic Projection Matrix for Shadow Mapping
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
// Vertex Shader with Displacement
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // ========================================================================
    // Vertex Displacement
    //
    // Sample the deformation texture using UV2 coordinates, then offset
    // the vertex position along:
    //   1. A user-specified direction (offsetParams1.zw, offsetParams2.x)
    //   2. The vertex normal scaled by offsetParams2.y
    //
    // The displacement is masked by (1 - vertexColor.x) to allow
    // painting areas that shouldn't deform.
    // ========================================================================
    float2 uv2Offset = input.uv.zw + offsetParams1.xy;
    float deformScale = deformTexture.SampleLevel(linearSampler, uv2Offset, 0).x;

    float3 offsetDirection = float3(offsetParams1.zw, offsetParams2.x);
    float3 displacement = deformScale * (1 - input.color.x) * (offsetDirection + normalize(input.normal) * offsetParams2.y);

    // Apply displacement and transform to world space
    output.worldPos = mul(worldMatrix, float4(input.position + displacement, 1)).xyz;
    output.normal = mul(invTransWorldMatrix, float4(input.normal, 0)).xyz;
    output.position = mul(projectionMatrix, mul(viewMatrix, float4(output.worldPos, 1)));
    output.uv = input.uv;

    // ========================================================================
    // Shadow Map Coordinate Computation
    // ========================================================================
    float4x4 lightView = BuildLightViewMatrix(lights[0].spotDirection.xyz, lights[0].position.xyz);
    float4x4 lightProj = BuildOrthoMatrix(lights[0].ambient.w, lights[0].diffuse.w, 0);

    float4 lightSpacePos = mul(lightProj, mul(lightView, float4(output.worldPos, 1)));
    lightSpacePos /= lightSpacePos.w;

    // Transform to shadow map UV space
    output.lightSpacePos = lightSpacePos.xyz;
    output.lightSpacePos.y *= -1;
    output.lightSpacePos.xy = output.lightSpacePos.xy * 0.5 + 0.5;

    return output;
}

// ============================================================================
// Geometry Shader — Two-Sided Rendering
//
// Computes face normal and optionally emits back-facing duplicate.
// ============================================================================
[maxvertexcount(6)]
void GeometryMain(triangle VertexOutput input[3], inout TriangleStream<VertexOutput> outputStream)
{
    // Compute face normal from edge vectors
    float3 faceNormal = cross(
        normalize(input[2].worldPos - input[0].worldPos),
        normalize(input[1].worldPos - input[0].worldPos)
    );

    // Front face
    for (int i = 0; i < 3; i++)
    {
        VertexOutput v = input[i];
        v.normal = faceNormal;
        outputStream.Append(v);
    }
    outputStream.RestartStrip();

    // Back face (if two-sided enabled)
    if (materialParams.z > 0.5)
    {
        for (int j = 2; j >= 0; j--)
        {
            VertexOutput v = input[j];
            v.normal = -faceNormal;
            outputStream.Append(v);
        }
        outputStream.RestartStrip();
    }
}

#define PI 3.14159265

// ============================================================================
// PBR Helper Functions
// ============================================================================
float3 FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;
    return NdotV / (NdotV * (1.0 - k) + k);
}

float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    return GeometrySchlickGGX(NdotV, roughness) * GeometrySchlickGGX(NdotL, roughness);
}

float DistributionGGX(float3 N, float3 H, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;

    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return a2 / denom;
}

// ============================================================================
// Derivative-Based Normal Perturbation
// Constructs tangent frame from screen-space derivatives (no vertex tangents)
// ============================================================================
float3 PerturbNormal(float3 N, float3 worldPos, float2 uv, float3 normalMap)
{
    float3 dp1 = ddx(worldPos);
    float3 dp2 = ddy(worldPos);
    float2 duv1 = ddx(uv);
    float2 duv2 = ddy(uv);

    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    float invmax = rsqrt(max(dot(T, T), dot(B, B)));
    float3x3 TBN = float3x3(T * invmax, B * invmax, N);

    // Handle missing normal map
    if (dot(normalMap, normalMap) == 0)
        normalMap = float3(0.5, 0.5, 1);

    normalMap = normalMap * 2 - 1;
    return normalize(mul(normalMap, TBN));
}

// ============================================================================
// Bidirectional Modifier
// 127/255 is neutral; below scales down, above interpolates toward 1
// ============================================================================
float ApplyModifier(float value, float modifier)
{
    if (modifier <= 127 / 255.0)
        return value * modifier / (127 / 255.0);
    else
        return lerp(value, 1, (modifier - 127 / 255.0) / (128 / 255.0));
}

// ============================================================================
// Pixel Shader Output Structure
// ============================================================================
struct PixelOutput
{
    float4 color : SV_TARGET0;          // Forward-lit color
    float4 albedoMetalness : SV_TARGET1; // G-Buffer: albedo.rgb, metalness
    float4 normalRoughness : SV_TARGET2; // G-Buffer: normal.xyz, roughness
};

// ============================================================================
// Get Light Direction and Distance
// ============================================================================
void GetLightData(LightData light, float3 worldPos, out float3 direction, out float distance, inout float spotCutoff)
{
    if (light.position.w)  // Positional light
    {
        direction = light.position.xyz - worldPos;
        distance = length(direction);
        direction /= distance;

        // Spotlight attenuation
        if (light.spotAttenuation.y)
        {
            spotCutoff = dot(-light.spotDirection.xyz, direction);
            spotCutoff = (spotCutoff - light.spotAttenuation.y) / (1 - light.spotAttenuation.y);
            spotCutoff = (spotCutoff > 0) ? pow(abs(saturate(spotCutoff)), light.spotAttenuation.x) : 0;
        }
    }
    else  // Directional light
    {
        direction = normalize(light.position.xyz);
        distance = 1;
    }
}

// ============================================================================
// 5x5 PCF Shadow Sampling
// ============================================================================
float ShadowPCF(float2 texBase, float lightDepth, float softness)
{
    float shadow = 0;
    for (int x = 0; x < 5; x++)
        for (int y = 0; y < 5; y++)
            shadow += shadowMapTexture.SampleCmpLevelZero(shadowSampler, texBase + float2(x - 2, y - 2) * 0.02 * softness, lightDepth);
    return shadow / 25.0;
}

float ShadowTest(float3 lightSpacePos, float bias, float softness)
{
    return ShadowPCF(lightSpacePos.xy, lightSpacePos.z - 0.01 * (bias - 0.5), softness);
}

// ============================================================================
// Main Lighting Calculation
// ============================================================================
PixelOutput CalculateLighting(VertexOutput input, float4 albedo, float4 normalMap, float4 emissiveMap, float4 matParams, float4 shdParams)
{
    // Alpha test
    if (shdParams.y < emissiveMap.w)
        discard;

    float3 N = PerturbNormal(normalize(input.normal), input.worldPos, input.uv.xy, normalMap.xyz);
    float3 V = normalize(cameraPosition.xyz - input.worldPos);

    float3 F0 = 0.04;
    float metallic = ApplyModifier(albedo.w, matParams.y);
    float roughness = ApplyModifier(normalMap.w, matParams.x);
    F0 = lerp(F0, albedo.xyz, metallic);

    // Shadow
    float shadow = 1;
    if ((lights[0].ambient.w * lights[0].diffuse.w) > 0.01)
        shadow = ShadowTest(input.lightSpacePos, matParams.w, shdParams.x);

    // Accumulate lighting
    float3 Lo = emissiveMap.xyz;

    for (int i = 0; i < lightCount[0]; ++i)
    {
        LightData light = lights[i];
        float3 L;
        float dist;
        float spotCutoff = 1;
        GetLightData(light, input.worldPos, L, dist, spotCutoff);

        float3 H = normalize(V + L);
        float attenuation = 1.0 / (dist * dist);
        float3 radiance = light.diffuse.xyz * attenuation * spotCutoff;

        // Cook-Torrance BRDF
        float NDF = DistributionGGX(N, H, roughness);
        float G = GeometrySmith(N, V, L, roughness);
        float3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

        float3 kS = F;
        float3 kD = (1 - kS) * (1.0 - metallic);

        float3 numerator = NDF * G * F;
        float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
        float3 specular = numerator / max(denominator, 0.001);

        float NdotL = max(dot(N, L), 0.0);
        if (i == 0)
            NdotL *= shadow;

        Lo += (kD * albedo.xyz / PI + specular) * radiance * NdotL;
    }

    PixelOutput output;
    output.color = float4(Lo, 1.0);
    output.normalRoughness = float4(N, roughness);
    output.albedoMetalness = float4(albedo.xyz, metallic);

    return output;
}

// ============================================================================
// Pixel Shader Entry Point
// ============================================================================
PixelOutput PixelMain(VertexOutput input)
{
    float2 uv = input.uv.xy + shadowParams.zw;

    float4 albedo = albedoTexture.Sample(linearSampler, uv);
    float4 normalMap = normalTexture.Sample(linearSampler, uv);
    float4 emissiveMap = emissiveTexture.Sample(linearSampler, uv);

    return CalculateLighting(input, albedo, normalMap, emissiveMap, materialParams, shadowParams);
}
