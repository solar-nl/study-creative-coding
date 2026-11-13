// ============================================================================
// READABLE VERSION: Non-LTC Sphere Light (Representative Point Method)
// Original: ../materials/area-sphere-light-non-ltc.hlsl (292 lines)
//
// Algorithm: Representative point method for sphere area lights.
//            Instead of analytically integrating over the sphere's surface,
//            finds the "most representative" point on the sphere that best
//            approximates the full integral, then applies standard BRDF.
//
// Technique Overview:
//   1. Find the closest point on the sphere to the reflection ray
//   2. Modify NoH/VoH to account for the sphere's solid angle
//   3. Apply energy normalization to maintain conservation
//   4. Use sphere horizon cosine wrapping for accurate diffuse falloff
//
// Parameters:
//   color.xyz — Light color (RGB)
//   worldMatrix — Transform giving light position and scale (radius)
//
// References:
//   - "Moving Frostbite to PBR" (Lagarde & de Rousiers, SIGGRAPH 2014)
//   - Unreal Engine 4 sphere light implementation
// ============================================================================

// G-Buffer textures
Texture2D albedoMetalnessTexture : register(t0);    // RGB = albedo, A = metalness
Texture2D normalRoughnessTexture : register(t1);    // RGB = normal, A = roughness
Texture2D depthTexture : register(t7);              // Depth buffer

SamplerState linearSampler : register(s2);

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
    float4 lightColor;
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
// G-Buffer unpacked data
// ============================================================================
struct GBufferData
{
    float3 worldNormal;
    float3 diffuseColor;
    float3 specularColor;
    float roughness;
};

// ============================================================================
// BRDF evaluation context
// Contains all dot products needed for Cook-Torrance BRDF
// ============================================================================
struct BxDFContext
{
    float NoV;  // Normal dot View
    float NoL;  // Normal dot Light
    float VoL;  // View dot Light
    float NoH;  // Normal dot Half
    float VoH;  // View dot Half
};

// ============================================================================
// Math Utilities
// ============================================================================
float Square(float x) { return x * x; }
float Pow4(float x) { float xx = x * x; return xx * xx; }
float Pow5(float x) { float xx = x * x; return xx * xx * x; }

// ============================================================================
// Energy Normalization for Sphere Lights
//
// When using a representative point, we need to account for the fact that
// the sphere subtends a solid angle. This modifies the effective roughness
// and normalizes energy to maintain conservation.
//
// Parameters:
//   a2 — Roughness squared (will be modified)
//   VoH — View dot Half vector
//   SinAlpha — Sin of the sphere's angular radius
//
// Returns:
//   Energy normalization factor
// ============================================================================
float EnergyNormalization(inout float a2, float VoH, float SinAlpha)
{
    float originalA2 = a2;
    float energy = 1;

    // Increase effective roughness based on sphere's solid angle
    // This formula from Frostbite accounts for the blur introduced
    // by integrating over the sphere's surface
    a2 = a2 + 0.25 * SinAlpha * (3.0 * sqrt(a2) + SinAlpha) / (VoH + 0.001);
    energy = originalA2 / a2;

    return energy;
}

// ============================================================================
// GGX Normal Distribution Function
// ============================================================================
float D_GGX(float a2, float NoH)
{
    float d = (NoH * a2 - NoH) * NoH + 1;
    return a2 / (3.14159265 * d * d);
}

// ============================================================================
// Schlick Fresnel Approximation
// The saturate(50 * g) term adds a subtle rim highlight for grazing angles
// ============================================================================
float3 F_Schlick(float3 specularColor, float VoH)
{
    float Fc = Pow5(1 - VoH);
    return saturate(50.0 * specularColor.g) * Fc + (1 - Fc) * specularColor;
}

// ============================================================================
// Smith Joint Visibility Approximation
// Approximates the full Smith G term for better performance
// ============================================================================
float Vis_SmithJointApprox(float a2, float NoV, float NoL)
{
    float a = sqrt(a2);
    float Vis_SmithV = NoL * (NoV * (1 - a) + a);
    float Vis_SmithL = NoV * (NoL * (1 - a) + a);
    return 0.5 * rcp(Vis_SmithV + Vis_SmithL);
}

// ============================================================================
// Specular GGX BRDF with Sphere Light Energy Normalization
// ============================================================================
float3 SpecularGGX(float roughness, float3 specularColor, BxDFContext ctx, float NoL, float sphereSinAlpha)
{
    float a2 = Pow4(roughness);
    float energy = EnergyNormalization(a2, ctx.VoH, sphereSinAlpha);
    float D = D_GGX(a2, ctx.NoH) * energy;
    float Vis = Vis_SmithJointApprox(a2, ctx.NoV, NoL);
    float3 F = F_Schlick(specularColor, ctx.VoH);
    return (D * Vis) * F;
}

// ============================================================================
// Sphere Horizon Cosine Wrapping
//
// Computes accurate diffuse irradiance from a sphere light by accounting
// for the portion of the sphere visible above the surface's horizon.
// When the sphere center is below the horizon, this calculates the
// partial visible solid angle.
//
// Parameters:
//   NoL — Normal dot (direction to sphere center)
//   SinAlphaSqr — Sin^2 of sphere's angular radius
//
// Returns:
//   Wrapped cosine term for diffuse lighting
// ============================================================================
float SphereHorizonCosWrap(float NoL, float SinAlphaSqr)
{
    float SinAlpha = sqrt(SinAlphaSqr);

    // If sphere center is below the horizon plane extended by sphere radius
    if (NoL < SinAlpha)
    {
        NoL = max(NoL, -SinAlpha);

        // Compute accurate sphere irradiance for partial visibility
        float CosBeta = NoL;
        float SinBeta = sqrt(1 - CosBeta * CosBeta);
        float TanBeta = SinBeta / CosBeta;

        float x = sqrt(1 / SinAlphaSqr - 1);
        float y = -x / TanBeta;
        float z = SinBeta * sqrt(1 - y * y);

        // Analytic formula for partially visible sphere
        NoL = NoL * acos(y) - x * z + atan(z / x) / SinAlphaSqr;
        NoL /= 3.14152965;
    }

    return saturate(NoL);
}

// ============================================================================
// Vertex Shader
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;
    output.position = float4(input.position.xzy * 2, 1);
    output.texCoord = input.uv.xy;
    return output;
}

// ============================================================================
// Pixel Shader — Non-LTC Sphere Light
// ============================================================================
float4 PixelMain(VertexOutput input) : SV_TARGET0
{
    // Load G-Buffer data
    float4 t0 = albedoMetalnessTexture.Load(int3(input.position.xy, 0));
    float4 t1 = normalRoughnessTexture.Load(int3(input.position.xy, 0));
    float depth = depthTexture.Load(int3(input.position.xy, 0)).x;

    // Reconstruct world position
    float4 clipPos = mul(inverseViewMatrix, mul(inverseProjectionMatrix, float4(input.texCoord * 2 - 1, depth, 1)));
    float3 P = clipPos.xyz / clipPos.w;
    float3 V = normalize(cameraPosition.xyz - P);
    float3 N = normalize(t1.xyz);

    float4 outputColor = float4(lightColor.xyz, 1);

    // ========================================================================
    // Light body rendering (pixels with invalid normals are light surface)
    // ========================================================================
    if (any(isnan(N)))
    {
        float4x4 invWorld = transpose(invTransWorldMatrix);
        float3 localPos = mul(invWorld, float4(P, 1)).xyz;
        if (length(localPos - normalize(localPos) * 0.5) < 0.01)
            return outputColor;
        return 0;
    }

    // ========================================================================
    // Unpack G-Buffer into rendering data
    // ========================================================================
    GBufferData gbuffer;
    gbuffer.worldNormal = N;
    gbuffer.diffuseColor = t0.xyz * (1 - t0.w);              // Albedo * (1 - metallic)
    gbuffer.specularColor = lerp(0.04, t0.xyz, t0.w);        // F0
    gbuffer.roughness = t1.w;

    // Get light radius from world matrix scale
    float lightRadius = length(mul(worldMatrix, float4(0.5, 0, 0, 0)).xyz);

    // Vector from surface to light center
    float3 toLight = mul(worldMatrix, float4(0, 0, 0, 1)).xyz - P;

    // ========================================================================
    // Distance attenuation
    // ========================================================================
    float distSqr = dot(toLight, toLight);
    float falloff = rcp(distSqr + 1);

    // Calculate sphere's angular extent
    float sinAlphaSqr = saturate(Square(lightRadius) * falloff);
    float NoL = dot(N, toLight * rsqrt(distSqr));

    // Apply horizon wrapping for diffuse
    NoL = SphereHorizonCosWrap(NoL, sinAlphaSqr);

    // Light direction (to center)
    float invDist = rsqrt(distSqr);
    float3 L = toLight * invDist;

    // Clamp roughness to avoid singularities
    gbuffer.roughness = max(gbuffer.roughness, 0.001);
    float a = Square(gbuffer.roughness);

    // Sin of sphere's angular radius, attenuated by roughness
    float sinAlpha = saturate(lightRadius * invDist * (1 - a));

    // ========================================================================
    // Initialize BRDF context
    // ========================================================================
    BxDFContext ctx;
    ctx.NoL = dot(N, L);
    ctx.NoV = dot(N, V);
    ctx.VoL = dot(V, L);

    // Half vector using efficient formula
    float invLenH = rsqrt(2 + 2 * ctx.VoL);
    ctx.NoH = saturate((ctx.NoL + ctx.NoV) * invLenH);
    ctx.VoH = saturate(invLenH + invLenH * ctx.VoL);

    // ========================================================================
    // Representative Point Correction
    //
    // For specular, we need to find the point on the sphere that contributes
    // most to the specular highlight. This involves checking if the reflection
    // vector intersects the sphere, and adjusting the half vector accordingly.
    // ========================================================================
    if (sinAlpha > 0)
    {
        float cosAlpha = sqrt(1 - Square(sinAlpha));

        // RoL = dot(R, L) where R is reflection of V about N
        float RoL = 2 * ctx.NoL * ctx.NoV - ctx.VoL;

        if (RoL >= cosAlpha)
        {
            // Reflection hits inside the sphere - use perfect mirror direction
            ctx.NoH = 1;
            ctx.VoH = abs(ctx.NoV);
        }
        else
        {
            // Find the closest point on sphere edge to reflection direction
            float rInvLengthT = sinAlpha * rsqrt(1 - RoL * RoL);
            float NoTr = rInvLengthT * (ctx.NoV - RoL * ctx.NoL);
            float VoTr = rInvLengthT * (2 * ctx.NoV * ctx.NoV - 1 - RoL * ctx.VoL);

            // Adjust NoL and VoL to point toward representative point
            ctx.NoL = ctx.NoL * cosAlpha + NoTr;
            ctx.VoL = ctx.VoL * cosAlpha + VoTr;

            // Recompute half vector terms
            float newInvLenH = rsqrt(2 + 2 * ctx.VoL);
            ctx.NoH = saturate((ctx.NoL + ctx.NoV) * newInvLenH);
            ctx.VoH = saturate(newInvLenH + newInvLenH * ctx.VoL);
        }
    }

    // Ensure NoV is positive (numerical stability)
    ctx.NoV = saturate(abs(ctx.NoV) + 0.000001);

    // ========================================================================
    // Final lighting calculation
    // ========================================================================
    float3 diffuseResult = (falloff * NoL) * gbuffer.diffuseColor / 3.14159265;
    float3 specularResult = (falloff * NoL) * SpecularGGX(gbuffer.roughness, gbuffer.specularColor, ctx, NoL, sinAlpha);

    // Scale by sqrt(lightRadius) for energy conservation
    return float4((diffuseResult + specularResult) * sqrt(lightRadius) * lightColor.xyz, 1);
}
