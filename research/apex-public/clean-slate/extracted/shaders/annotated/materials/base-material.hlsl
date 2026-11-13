// ============================================================================
// READABLE VERSION: Base Material (Blinn-Phong)
// Original: ../materials/base-material.hlsl (197 lines)
//
// Algorithm: Classic Blinn-Phong shading with environment mapping.
//            A simpler alternative to PBR for basic lit surfaces.
//
// Features:
//   - Blinn-Phong specular highlights
//   - Spherical environment mapping for reflections
//   - Derivative-based normal mapping
//   - Multi-light support with spotlight attenuation
//   - G-Buffer output for hybrid rendering
//
// Blinn-Phong Model:
//   specular = (N · H)^power
//   Where H = normalize(V + L) is the half-vector
//
// Parameters:
//   specularcolor.xyz — Specular highlight color
//   specularpower.x — Specular exponent (sharpness)
//   specularpower.y — Invert normals flag
//
// Output:
//   RT0: Lit color
//   RT1: Albedo + envmap
//   RT2: World normal
// ============================================================================

// Textures
Texture2D diffuseTexture : register(t0);   // Diffuse/albedo map
Texture2D envMapTexture : register(t1);    // Environment map (sphere map)
Texture2D normalTexture : register(t2);    // Normal map

SamplerState linearSampler : register(s0);

// ============================================================================
// Light data structure
// ============================================================================
struct LightData
{
    float4 position;        // xyz = position, w = positional flag
    float4 ambient;
    float4 diffuse;
    float4 specular;
    float4 spotDirection;
    float4 spotAttenuation; // x = exponent, y = cutoff, z/w = attenuation
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
    float4 specularColor;
    float4 specularPower;  // x = power, y = invert normals
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
    output.normal = mul(invTransWorldMatrix, float4(input.normal, 0)).xyz;
    output.position = mul(projectionMatrix, mul(viewMatrix, float4(output.worldPos, 1)));
    output.texCoord = input.uv.xy;

    return output;
}

// ============================================================================
// Spherical Environment Mapping
//
// Classic technique for reflections using a 2D texture as an environment.
// The texture is a photograph of a mirrored sphere, mapped by:
//   1. Computing view-space reflection vector
//   2. Projecting onto sphere surface: UV = R.xy / (2 * sqrt(R.z + 1))
// ============================================================================
float4 GetEnvironmentMap(VertexOutput v)
{
    // Transform to view space
    float3 viewPos = mul(viewMatrix, float4(v.worldPos, 1)).xyz;
    float3 viewNormal = mul(viewMatrix, float4(v.normal, 0)).xyz;

    // Compute reflection in view space
    float3 r = reflect(normalize(viewPos), normalize(viewNormal));

    // Spherical mapping formula
    float m = 2.0 * sqrt(r.x * r.x + r.y * r.y + (r.z + 1.0) * (r.z + 1.0));
    float2 envUV = r.xy / m + 0.5;

    return envMapTexture.Sample(linearSampler, envUV);
}

// ============================================================================
// Get Light Direction and Attenuation
// ============================================================================
void GetLightData(LightData light, float3 worldPos, out float3 direction, out float distance, inout float spotCutoff)
{
    if (light.position.w)  // Positional light
    {
        direction = light.position.xyz - worldPos;
        distance = length(direction);
        direction /= distance;

        // Spotlight calculation
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
// Multi-Light Blinn-Phong Lighting
// ============================================================================
float3 CalculateLighting(float3 diffuseColor, float3 worldPos, float3 normal)
{
    float3 result = 0;

    for (int i = 0; i < lightCount[0]; i++)
    {
        LightData light = lights[i];
        float3 L;
        float dist;
        float spotCutoff = 1;
        GetLightData(light, worldPos, L, dist, spotCutoff);

        // Blinn-Phong half-vector
        float3 V = normalize(cameraPosition.xyz - worldPos);
        float3 H = normalize(V + L);

        // Light components
        float3 ambient = light.ambient.xyz;
        float3 diffuse = light.diffuse.xyz * saturate(dot(L, normal)) * spotCutoff;
        float3 specular = light.specular.xyz * spotCutoff *
                          pow(saturate(dot(normal, H)), 1 / (specularPower.x + 0.000001));

        // Distance attenuation
        float attenuation = 1 + dist * (light.spotAttenuation.z + light.spotAttenuation.w * light.spotAttenuation.w);

        result += (diffuseColor * ambient + diffuseColor * diffuse + specular * specularColor.xyz) / attenuation;
    }

    return result;
}

// ============================================================================
// Derivative-Based Normal Perturbation
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

    if (dot(normalMap, normalMap) == 0)
        normalMap = float3(0.5, 0.5, 1);

    normalMap = normalMap * 2 - 1;
    return normalize(mul(normalMap, TBN));
}

// ============================================================================
// Pixel Shader Output
// ============================================================================
struct PixelOutput
{
    float4 color : SV_TARGET0;
    float4 albedoMetalness : SV_TARGET1;
    float4 normalRoughness : SV_TARGET2;
};

// ============================================================================
// Pixel Shader
// ============================================================================
PixelOutput PixelMain(VertexOutput v)
{
    float normalMult = (specularPower.y > 0.5) ? -1 : 1;

    float4 diffuse = diffuseTexture.Sample(linearSampler, v.texCoord);
    float4 normalMap = normalTexture.Sample(linearSampler, v.texCoord);

    float3 normal = PerturbNormal(normalize(v.normal) * normalMult, v.worldPos, v.texCoord, normalMap.xyz);
    float3 envColor = GetEnvironmentMap(v).xyz;

    PixelOutput output;
    output.color.xyz = CalculateLighting(diffuse.xyz + envColor, v.worldPos, normal);
    output.color.w = diffuse.w;
    output.albedoMetalness = diffuse;
    output.normalRoughness = float4(normal, 0);

    return output;
}
