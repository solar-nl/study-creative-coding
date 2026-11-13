// ============================================================================
// READABLE VERSION: Deferred Fake Cubemap Reflections
// Original: ../materials/deferred-fake-cubemap.hlsl (231 lines)
//
// Algorithm: Image-Based Lighting (IBL) using 2D texture "fake cubemap".
//            Combines hemisphere-sampled diffuse irradiance with importance-
//            sampled specular reflections using GGX distribution.
//
// Technique:
//   Instead of a true cubemap, uses DeCube() to unwrap a 2D panoramic texture.
//   Samples the environment at multiple directions using Hammersley sequence
//   for quasi-random distribution.
//
// Sampling Strategy:
//   - Diffuse: 32 samples in cosine-weighted hemisphere
//   - Specular: 64 samples using GGX importance sampling
//   - Mip level selection based on PDF for roughness-dependent blur
//
// Parameters:
//   Texture2 — Environment map (sides)
//   Texture3 — Environment map (top)
//   Texture4 — Environment map (bottom)
//
// References:
//   - "Real Shading in Unreal Engine 4" (Karis, SIGGRAPH 2013)
//   - Hammersley sequence for quasi-Monte Carlo
// ============================================================================

// G-Buffer textures
Texture2D albedoMetalnessTexture : register(t0);
Texture2D normalRoughnessTexture : register(t1);
Texture2D envMapSides : register(t2);     // Environment map (side faces)
Texture2D envMapTop : register(t3);       // Environment map (top)
Texture2D envMapBottom : register(t4);    // Environment map (bottom)
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
    float4 lightData : TEXCOORD1;
};

// ============================================================================
// Vertex Shader
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;
    output.position = float4(input.position.xzy * 2, 1);
    output.lightData.xyz = transpose(worldMatrix)[3].xyz;
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
// ============================================================================
float3 FresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

// ============================================================================
// Van der Corput Radical Inverse
//
// Part of the Hammersley sequence for quasi-random sampling.
// Reverses the bits of an integer to create low-discrepancy sequence.
// ============================================================================
float RadicalInverse_VdC(uint bits)
{
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10;  // / 0x100000000
}

// ============================================================================
// DeCube — Convert 3D direction to 2D UV for fake cubemap
//
// Projects a direction vector onto the dominant axis face and returns
// UV coordinates for sampling the 2D texture as if it were a cubemap.
// ============================================================================
float2 DeCube(float3 direction)
{
    float3 absDir = abs(direction);
    float maxAxis = max(max(absDir.x, absDir.y), absDir.z);

    // Select UV based on dominant axis
    float2 uv = direction.zy;
    if (maxAxis == absDir.y) uv = direction.xz;
    if (maxAxis == absDir.z) uv = direction.xy;

    return 0.5 * (uv / maxAxis + 1);
}

// ============================================================================
// Schlick-GGX Geometry Term (single direction)
// ============================================================================
float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;

    float num = NdotV;
    float denom = NdotV * (1.0 - k) + k;

    return num / denom;
}

// ============================================================================
// Smith Geometry Term (combined view + light)
// ============================================================================
float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);

    return ggx1 * ggx2;
}

float sqr(in float x) { return x * x; }

// ============================================================================
// GGX Normal Distribution Function
// ============================================================================
float D_GGX(in float alpha, in float NoH)
{
    float a2 = alpha * alpha;
    float cos2 = NoH * NoH;

    return (1.0 / PI) * sqr(alpha / (cos2 * (a2 - 1) + 1));
}

// ============================================================================
// Pixel Shader — IBL with Fake Cubemap
// ============================================================================
float4 PixelMain(VertexOutput input) : SV_TARGET0
{
    // Load G-Buffer
    float4 albedo = albedoMetalnessTexture.Load(int3(input.position.xy, 0));
    float4 normal = normalRoughnessTexture.Load(int3(input.position.xy, 0));
    float depth = depthTexture.Load(int3(input.position.xy, 0)).x;

    float roughness = normal.w;
    float metallic = albedo.w;

    float3 N = normalize(normal.xyz);
    float3 V = normalize(cameraPosition.xyz - GetWorldPosition(depth, input.texCoord));

    // Fresnel at normal incidence
    float3 F0 = lerp(0.04, albedo.xyz, metallic);

    // Fresnel for this view angle
    float3 H = normalize(V + N);
    float3 F = FresnelSchlick(max(dot(H, V), 0.0), F0);

    // Energy that goes into diffuse (not reflected)
    float3 kD = (1 - F) * (1 - metallic);

    int numSamples = 32;

    // ========================================================================
    // Build tangent frame for sampling hemisphere
    // ========================================================================
    float3 upVector = abs(N.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 X = normalize(cross(N, upVector));
    float3 Y = normalize(cross(X, N));
    float3x3 tangentFrame = float3x3(X, Y, N);

    float3 light = 0;

    // ========================================================================
    // Diffuse Irradiance — Hemisphere Sampling
    //
    // Sample the environment in a cosine-weighted hemisphere pattern.
    // Uses Hammersley sequence for phi angle, uniform distribution for theta.
    // ========================================================================
    for (int i = 0; i < numSamples; i++)
    {
        float uv = RadicalInverse_VdC(i);
        float phi = uv * 2.0 * PI;
        float cosTheta = 1.0 - i / 32.0;
        float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

        // Sample direction in tangent space
        float3 sampleDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

        // Transform to world space
        float3 worldDir = mul(sampleDir, tangentFrame);

        // Sample environment at high mip (blurred for diffuse)
        light += envMapSides.SampleLevel(linearSampler, DeCube(worldDir), 8).rgb / numSamples * kD * albedo.xyz / PI;
    }

    // ========================================================================
    // Specular Reflections — GGX Importance Sampling
    //
    // Generate samples distributed according to GGX NDF.
    // Compute appropriate mip level based on PDF for roughness blur.
    // ========================================================================
    int w, h;
    envMapSides.GetDimensions(w, h);
    numSamples = 64;

    float NoV = saturate(dot(N, V)) + 0.0001;

    for (int ii = 0; ii < numSamples; ii++)
    {
        float Xi = RadicalInverse_VdC(ii);

        // GGX importance sampling angles
        float Phi = PI * ii / 32.0;
        float CosTheta = sqrt((1 - Xi) / (1 + (roughness * roughness * roughness * roughness - 1) * Xi));
        float SinTheta = sqrt(1 - CosTheta * CosTheta);

        // Half vector in world space
        float3 halfVec = mul(float3(SinTheta * cos(Phi), SinTheta * sin(Phi), CosTheta), tangentFrame);

        // Reflection direction
        float3 L = 2 * dot(V, halfVec) * halfVec - V;

        float NoL = saturate(dot(N, L));
        float NoH = saturate(dot(N, halfVec));
        float VoH = saturate(dot(V, halfVec));

        // ====================================================================
        // Mip Level Selection
        //
        // Based on the solid angle of the sample vs the texel solid angle.
        // Higher PDF (more focused samples) = sharper reflections = lower mip.
        // ====================================================================
        float pdf = D_GGX(roughness, NoH) * NoH / (4.0 * VoH);
        float omegaS = 1.0 / (numSamples * pdf);
        float omegaP = 4.0 * PI / (6.0 * w * h);
        float mipLevel = max(0.5 * log2(omegaS / omegaP), 0.0);

        if (roughness == 0)
            mipLevel = 0;

        // Sample appropriate face based on L direction
        float3 sampleColor = envMapSides.SampleLevel(linearSampler, DeCube(L), mipLevel).rgb;

        // Check if we should sample top/bottom instead
        float3 absL = abs(L);
        float maxAxis = max(max(absL.x, absL.y), absL.z);
        if (maxAxis == absL.y)
            sampleColor = L.y > 0 ? envMapTop.SampleLevel(linearSampler, DeCube(L), mipLevel).rgb
                                  : envMapBottom.SampleLevel(linearSampler, DeCube(L), mipLevel).rgb;

        // ====================================================================
        // Accumulate specular contribution
        // ====================================================================
        float G = GeometrySmith(N, V, L, roughness);
        float Fc = pow(1 - VoH, 5);
        float3 fresnel = (1 - Fc) * F0 + Fc;

        if (NoL > 0)
            light += sampleColor * fresnel * G * VoH / (NoH * NoV) / numSamples;
    }

    return float4(light, 1);
}
