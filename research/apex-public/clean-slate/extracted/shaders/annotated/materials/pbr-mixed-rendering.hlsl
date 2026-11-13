// ============================================================================
// READABLE VERSION: PBR Mixed Rendering (Forward + Deferred Hybrid)
// Original: ../materials/pbr-mixed-rendering.hlsl (337 lines)
//
// Algorithm: Cook-Torrance microfacet BRDF with metallic-roughness workflow.
//            Combines forward lighting for primary lights with deferred
//            G-Buffer output for secondary lighting passes.
//
// Pipeline:
//   Vertex → Geometry (optional two-sided) → Pixel → MRT Output
//
// G-Buffer Layout (Multiple Render Targets):
//   RT0: Albedo.rgb + Metalness.a
//   RT1: Normal.xyz + Roughness.a (accumulated radiance written to RGB)
//   RT2: Emissive.rgb + Alpha.a
//
// Key Features:
//   - GGX/Trowbridge-Reitz normal distribution function
//   - Schlick-GGX geometry term (Smith formulation)
//   - Schlick Fresnel approximation
//   - Derivative-based normal mapping (no tangent attributes needed)
//   - PCF shadow mapping (5×5 kernel)
//   - Two-sided rendering via geometry shader
//   - Bidirectional roughness/metalness modifiers
//
// References:
//   - "Real Shading in Unreal Engine 4" (Brian Karis, SIGGRAPH 2013)
//   - "Microfacet Models for Refraction" (Walter et al., EGSR 2007)
// ============================================================================

// ============================================================================
// TEXTURE AND SAMPLER BINDINGS
// ============================================================================

Texture2D albedoTexture : register(t0);      // RGB=Albedo, A=Metalness
Texture2D normalTexture : register(t1);       // RGB=Normal, A=Roughness
Texture2D emissiveTexture : register(t2);     // RGB=Emissive, A=Alpha mask
Texture2D shadowMapTexture : register(t3);    // Directional light shadow map

SamplerState textureSampler : register(s0);
SamplerComparisonState shadowSampler : register(s2);  // Hardware PCF comparison

// ============================================================================
// LIGHT DATA STRUCTURE
// ============================================================================

struct LightData
{
    float4 position;        // xyz=position (point/spot) or direction (directional), w=isPointLight
    float4 ambient;         // xyz=ambient color, w=shadow map width
    float4 diffuse;         // xyz=diffuse color, w=shadow map height
    float4 specular;        // xyz=specular color, w=unused
    float4 spotDirection;   // xyz=spotlight direction, w=unused
    float4 spotDirAttenuation;  // x=spotlight power, y=spotlight cutoff angle cosine, zw=unused
};

// ============================================================================
// CONSTANT BUFFERS
// ============================================================================

// Per-frame scene data (shared across all objects)
cbuffer SceneBuffer : register(b0)
{
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
    float4 cameraPosition;
    float4 lightCount;        // x=number of active lights
    LightData lights[8];      // Up to 8 lights
}

// Per-object material data
cbuffer ObjectBuffer : register(b1)
{
    float4x4 worldMatrix;
    float4x4 inverseTransposeWorldMatrix;  // For correct normal transformation
    float4 materialParams;    // x=roughnessMod, y=metalnessMod, z=twoSided, w=shadowBias
    float4 shadowParams;      // x=shadowSoftness, y=alphaTestCutoff, zw=albedoMultiplier.rg
    float4 albedoMultiplier;  // x=albedoMultiplier.b, yzw=unused
}

// ============================================================================
// VERTEX SHADER STRUCTURES
// ============================================================================

struct VertexInput
{
    float3 position : POSITION0;
    float3 position2 : POSITION1;   // Secondary position (unused in this shader)
    float3 normal : NORMAL0;
    float4 color : COLOR0;
    float4 uv : TEXCOORD0;          // xy=primary UV, zw=secondary UV
    float4 uv2 : TEXCOORD1;
};

struct VertexOutput
{
    float4 clipPosition : SV_POSITION;
    float3 worldNormal : TEXCOORD1;
    float4 texCoord : TEXCOORD0;
    float3 worldPosition : TEXCOORD2;
    float3 lightSpacePosition : TEXCOORD3;  // For shadow mapping
};

// ============================================================================
// SHADOW MAPPING UTILITIES
// ============================================================================

// Build a view matrix looking from the light's perspective
float4x4 BuildLightViewMatrix(float3 lightPosition, float3 lightDirection)
{
    float3 z = normalize(lightDirection);
    float3 x = normalize(cross(float3(0, 1, 0), z));
    float3 y = cross(z, x);

    // Construct view matrix (world-to-light-space)
    float4x4 lightViewMatrix = float4x4(
        x.x, y.x, z.x, 0,
        x.y, y.y, z.y, 0,
        x.z, y.z, z.z, 0,
        -dot(x, lightPosition), -dot(y, lightPosition), -dot(z, lightPosition), 1
    );
    return transpose(lightViewMatrix);
}

// Build an orthographic projection matrix for directional light shadows
float4x4 BuildOrthographicMatrix(float width, float height, float range)
{
    float zFar = 100;
    float zNear = 0;

    float4x4 orthoMatrix = float4x4(
        2 / width, 0, 0, 0,
        0, 2 / height, 0, 0,
        0, 0, 1 / (zNear - zFar), 0,
        0, 0, -zNear / (zNear - zFar), 1
    );
    return transpose(orthoMatrix);
}

// ============================================================================
// VERTEX SHADER
// ============================================================================

VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // Transform position to world space
    output.worldPosition = mul(worldMatrix, float4(input.position, 1)).xyz;

    // Transform normal using inverse-transpose for correct scaling
    output.worldNormal = mul(inverseTransposeWorldMatrix, float4(input.normal, 0)).xyz;

    // Transform to clip space (world → view → projection)
    output.clipPosition = mul(projectionMatrix, mul(viewMatrix, float4(output.worldPosition, 1)));

    // Pass through texture coordinates
    output.texCoord = input.uv;

    // ========================================================================
    // Shadow map coordinate calculation
    // Transform world position to light's clip space for shadow lookup
    // ========================================================================
    float4x4 lightViewMatrix = BuildLightViewMatrix(
        lights[0].spotDirection.xyz,  // Light position (stored in spotDirection for directional)
        lights[0].position.xyz        // Light direction (stored in position.xyz)
    );

    // Shadow map dimensions stored in ambient.w and diffuse.w
    float4x4 lightProjectionMatrix = BuildOrthographicMatrix(
        lights[0].ambient.w,
        lights[0].diffuse.w,
        0
    );

    // Transform to light's clip space
    float4 lightClipPosition = mul(lightProjectionMatrix, mul(lightViewMatrix, float4(output.worldPosition, 1)));
    lightClipPosition /= lightClipPosition.w;

    // Convert from [-1, 1] to [0, 1] UV space, flip Y for texture coordinates
    output.lightSpacePosition = lightClipPosition.xyz;
    output.lightSpacePosition.y *= -1;
    output.lightSpacePosition.xy = output.lightSpacePosition.xy * 0.5 + 0.5;

    return output;
}

// ============================================================================
// GEOMETRY SHADER (Two-Sided Rendering)
// When materialParams.z > 0.5, emit the triangle twice: once normally,
// once with reversed winding and flipped normals for back-face lighting.
// ============================================================================

[maxvertexcount(6)]
void GeometryMain(triangle VertexOutput input[3], inout TriangleStream<VertexOutput> outputStream)
{
    // Emit front faces (original winding)
    for (int i = 0; i < 3; i++)
    {
        outputStream.Append(input[i]);
    }
    outputStream.RestartStrip();

    // Optionally emit back faces with flipped normals
    if (materialParams.z > 0.5)  // twoSided flag
    {
        // Reverse vertex order for opposite winding
        for (int j = 2; j >= 0; j--)
        {
            VertexOutput vertex = input[j];
            vertex.worldNormal *= -1;  // Flip normal for back-face lighting
            outputStream.Append(vertex);
        }
        outputStream.RestartStrip();
    }
}

// ============================================================================
// PBR BRDF FUNCTIONS
// ============================================================================

#define PI 3.14159265

// Schlick's Fresnel approximation
// F0 = reflectance at normal incidence
// cosTheta = dot(H, V) or dot(N, V)
float3 FresnelSchlick(float cosTheta, float3 F0)
{
    // F(θ) = F0 + (1 - F0)(1 - cosθ)^5
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}

// Schlick-GGX geometry term for a single direction
// Models self-shadowing from microfacet occlusion
float GeometrySchlickGGX(float NdotV, float roughness)
{
    // Remapped roughness for direct lighting (not IBL)
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;

    // G1(v) = n·v / (n·v(1-k) + k)
    float numerator = NdotV;
    float denominator = NdotV * (1.0 - k) + k;

    return numerator / denominator;
}

// Smith's geometry function (combined view and light directions)
float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);

    // G(l, v, h) = G1(l) × G1(v)
    float ggx1 = GeometrySchlickGGX(NdotL, roughness);
    float ggx2 = GeometrySchlickGGX(NdotV, roughness);

    return ggx1 * ggx2;
}

// GGX/Trowbridge-Reitz normal distribution function
// Models the statistical distribution of microfacet normals
float DistributionGGX(float3 N, float3 H, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH = max(dot(N, H), 0.0);
    float NdotH2 = NdotH * NdotH;

    // D(h) = α² / (π × ((n·h)²(α² - 1) + 1)²)
    float numerator = a2;
    float denominator = (NdotH2 * (a2 - 1.0) + 1.0);
    denominator = PI * denominator * denominator;

    return numerator / denominator;
}

// ============================================================================
// DERIVATIVE-BASED NORMAL MAPPING
// Constructs tangent frame from screen-space derivatives, avoiding the need
// for pre-computed tangent attributes.
// ============================================================================

float3 PerturbNormal(float3 N, float3 worldPosition, float2 texCoord, float3 normalMapSample)
{
    // Screen-space derivatives of position and UV
    float3 dp1 = ddx(worldPosition);
    float3 dp2 = ddy(worldPosition);
    float2 duv1 = ddx(texCoord);
    float2 duv2 = ddy(texCoord);

    // Solve the linear system to find tangent and bitangent
    float3 dp2perp = cross(dp2, N);
    float3 dp1perp = cross(N, dp1);
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;

    // Construct scale-invariant tangent frame
    float invmax = rsqrt(max(dot(T, T), dot(B, B)));
    float3x3 tangentFrame = float3x3(T * invmax, B * invmax, N);

    // Handle missing normal map (black texture = use geometric normal)
    if (dot(normalMapSample, normalMapSample) == 0)
    {
        normalMapSample = float3(0.5, 0.5, 1);  // Neutral normal pointing up
    }

    // Decode normal from [0,1] to [-1,1] range
    normalMapSample = normalMapSample * 2 - 1;

    // Transform normal map sample to world space
    return normalize(mul(normalMapSample, tangentFrame));
}

// ============================================================================
// BIDIRECTIONAL MODIFIER
// Applies a texture value modification where 127/255 (≈0.498) is neutral.
// Below neutral: scales the value down
// Above neutral: interpolates toward 1.0
//
// This allows artists to both reduce AND increase values from the texture.
// ============================================================================

float ApplyModifier(float value, float modifier)
{
    // Neutral point: 127/255 ≈ 0.498
    const float neutralPoint = 127.0 / 255.0;

    if (modifier <= neutralPoint)
    {
        // Below neutral: scale down (0 = black, 0.498 = unchanged)
        return value * modifier / neutralPoint;
    }
    else
    {
        // Above neutral: interpolate toward 1.0 (0.498 = unchanged, 1.0 = white)
        return lerp(value, 1, (modifier - neutralPoint) / (128.0 / 255.0));
    }
}

// ============================================================================
// PIXEL SHADER OUTPUT STRUCTURE (Multiple Render Targets)
// ============================================================================

struct PixelOutput
{
    float4 radiance : SV_TARGET0;           // Accumulated lighting + future G-Buffer read
    float4 albedoMetalness : SV_TARGET1;    // G-Buffer: Albedo.rgb, Metalness
    float4 normalRoughness : SV_TARGET2;    // G-Buffer: Normal.xyz, Roughness
};

// ============================================================================
// LIGHT EVALUATION
// ============================================================================

// Extract light direction and distance, handling both directional and point lights
void GetLightData(LightData light, float3 worldPosition,
                  out float3 lightDirection, out float distance, inout float spotlightFactor)
{
    if (light.position.w)  // Point/spot light (w=1)
    {
        // Vector from surface to light
        lightDirection = light.position.xyz - worldPosition;
        distance = length(lightDirection);
        lightDirection /= distance;

        // Spotlight cone attenuation
        if (light.spotDirAttenuation.y)  // Has spotlight cutoff
        {
            // Angle between light direction and spotlight direction
            spotlightFactor = dot(-light.spotDirection.xyz, lightDirection);

            // Map from [cutoff, 1] to [0, 1]
            spotlightFactor = (spotlightFactor - light.spotDirAttenuation.y) /
                              (1 - light.spotDirAttenuation.y);

            // Apply power falloff
            if (spotlightFactor > 0)
            {
                spotlightFactor = pow(abs(saturate(spotlightFactor)), light.spotDirAttenuation.x);
            }
            else
            {
                spotlightFactor = 0;
            }
        }
    }
    else  // Directional light (w=0)
    {
        lightDirection = normalize(light.position.xyz);
        distance = 1;  // No attenuation for directional lights
    }
}

// ============================================================================
// PCF SHADOW SAMPLING
// 5×5 Percentage-Closer Filtering for soft shadow edges
// (Named VSM in original, but actually implements PCF)
// ============================================================================

float SampleShadowPCF(float2 shadowUV, float compareDepth, float softness)
{
    float shadow = 0;

    // 5×5 kernel sampling
    for (int x = 0; x < 5; x++)
    {
        for (int y = 0; y < 5; y++)
        {
            // Offset from center, scaled by softness parameter
            float2 offset = float2(x - 2, y - 2) * 0.02 * softness;

            // Hardware PCF comparison: returns 1 if fragment passes depth test
            shadow += shadowMapTexture.SampleCmpLevelZero(
                shadowSampler,
                shadowUV + offset,
                compareDepth
            );
        }
    }

    // Average 25 samples
    return shadow / 25.0;
}

// Wrapper that applies bias adjustment
float CalculateShadow(float3 lightSpacePosition, float bias, float softness)
{
    // Bias shifts the comparison depth to reduce shadow acne
    // bias parameter is in [0,1], centered at 0.5
    float adjustedDepth = lightSpacePosition.z - 0.01 * (bias - 0.5);

    return SampleShadowPCF(lightSpacePosition.xy, adjustedDepth, softness);
}

// ============================================================================
// MAIN LIGHTING CALCULATION
// ============================================================================

PixelOutput CalculateLighting(VertexOutput input, float4 albedo, float4 normalMap,
                               float4 emissiveMap, float4 matParams, float4 shdParams)
{
    // Alpha test: discard fragments below cutoff
    if (shdParams.y < emissiveMap.w)
    {
        discard;
    }

    // Perturb geometric normal with normal map
    float3 N = PerturbNormal(normalize(input.worldNormal), input.worldPosition,
                             input.texCoord.xy, normalMap.xyz);

    // View direction
    float3 V = normalize(cameraPosition.xyz - input.worldPosition);

    // Apply bidirectional modifiers to texture values
    float metallic = ApplyModifier(albedo.w, matParams.y);
    float roughness = ApplyModifier(normalMap.w, matParams.x);

    // Base reflectance: dielectric = 0.04, metallic = albedo color
    float3 F0 = 0.04;
    F0 = lerp(F0, albedo.xyz, metallic);

    // Calculate shadow for primary light (light 0)
    float shadow = 1;
    if ((lights[0].ambient.w * lights[0].diffuse.w) > 0.01)  // Has shadow map
    {
        shadow = CalculateShadow(input.lightSpacePosition.xyz, matParams.w, shdParams.x);
    }

    // ========================================================================
    // Light loop: accumulate radiance from all active lights
    // ========================================================================
    float3 Lo = emissiveMap.xyz;  // Start with emissive contribution

    for (int i = 0; i < lightCount[0]; ++i)
    {
        LightData light = lights[i];
        float3 L;
        float distance;
        float spotlightFactor = 1;

        GetLightData(light, input.worldPosition, L, distance, spotlightFactor);

        // Half vector between view and light
        float3 H = normalize(V + L);

        // Distance attenuation (inverse square law)
        float attenuation = 1.0 / (distance * distance);

        // Incoming radiance from this light
        float3 radiance = light.diffuse.xyz * attenuation * spotlightFactor;

        // ====================================================================
        // Cook-Torrance BRDF
        // f(l,v) = (D × G × F) / (4 × (n·l) × (n·v))
        // ====================================================================

        float NDF = DistributionGGX(N, H, roughness);       // Normal distribution
        float G = GeometrySmith(N, V, L, roughness);        // Geometry/shadowing
        float3 F = FresnelSchlick(max(dot(H, V), 0.0), F0); // Fresnel

        // Specular and diffuse energy conservation
        float3 kS = F;                    // Specular reflection fraction
        float3 kD = 1 - kS;               // Diffuse fraction (what's not reflected)
        kD *= 1.0 - metallic;             // Metals have no diffuse

        // Cook-Torrance specular term
        float3 numerator = NDF * G * F;
        float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
        float3 specular = numerator / max(denominator, 0.001);

        // Combine diffuse and specular
        float NdotL = max(dot(N, L), 0.0);

        // Apply shadow only to primary light
        if (i == 0)
        {
            NdotL *= shadow;
        }

        // Accumulate: diffuse (Lambertian) + specular (Cook-Torrance)
        Lo += (kD * albedo.xyz / PI + specular) * radiance * NdotL;
    }

    // ========================================================================
    // Output to multiple render targets
    // ========================================================================
    PixelOutput output;
    output.radiance = float4(Lo, 1.0);
    output.normalRoughness = float4(N, roughness);
    output.albedoMetalness = float4(albedo.xyz, metallic);

    return output;
}

// ============================================================================
// PIXEL SHADER ENTRY POINT
// ============================================================================

PixelOutput PixelMain(VertexOutput input)
{
    // Sample textures
    float4 albedo = albedoTexture.Sample(textureSampler, input.texCoord.xy);

    // Apply albedo color multiplier (set per-material for tinting)
    // shadowParams.zw = red/green multiplier, albedoMultiplier.x = blue multiplier
    albedo.xyz *= float3(shadowParams.zw, albedoMultiplier.x);

    float4 normalMap = normalTexture.Sample(textureSampler, input.texCoord.xy);
    float4 emissiveMap = emissiveTexture.Sample(textureSampler, input.texCoord.xy);

    return CalculateLighting(input, albedo, normalMap, emissiveMap, materialParams, shadowParams);
}
