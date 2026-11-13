// ============================================================================
// READABLE VERSION: Mapped Fresnel (View-Dependent Color Blend)
// Original: ../materials/mapped-fresnel.hlsl (74 lines)
//
// Algorithm: Simple Fresnel-based color interpolation.
//            Blends between two colors based on the angle between
//            view direction and surface normal.
//
// Fresnel Effect:
//   At grazing angles (looking along the surface), different optical
//   properties emerge. This shader uses a power function to control
//   the transition rate between face-on and edge-on colors.
//
// The Fresnel term: pow(N·V, exponent)
//   - N·V = 1 when looking straight at surface → shows color1
//   - N·V = 0 at grazing angles → shows color2
//   - Exponent controls transition sharpness
//
// Use Cases:
//   - Rim lighting effect
//   - Simple subsurface scattering approximation
//   - Stylized material effects
//   - Energy shields / force fields
//
// Parameters:
//   color1.xyz — Face-on color (RGB when viewing surface head-on)
//   color1.w, color2.xy — Edge color (RGB at grazing angles)
//   color2.z — Fresnel exponent (higher = sharper transition)
// ============================================================================

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
    float4 color1;  // xyz = face-on color, w = edge color R
    float4 color2;  // xy = edge color GB, z = exponent
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

    // Transform to world space
    output.worldPos = mul(worldMatrix, float4(input.position, 1)).xyz;
    output.position = mul(projectionMatrix, mul(viewMatrix, float4(output.worldPos, 1)));

    output.texCoord = input.uv.xy;

    // Transform normal to world space (using world matrix, not inverse transpose
    // — acceptable for uniform scale)
    output.normal = mul(worldMatrix, float4(input.normal, 0)).xyz;

    return output;
}

// ============================================================================
// Pixel Shader — Fresnel Color Blend
// ============================================================================
float4 PixelMain(VertexOutput input) : SV_TARGET0
{
    // ========================================================================
    // Fresnel Calculation
    //
    // t = saturate(-V · N)
    // Where V is view direction (from surface to camera, negated)
    // and N is surface normal.
    //
    // The negation makes t=1 when looking straight at the surface
    // and t=0 at grazing angles.
    // ========================================================================
    float3 viewDir = normalize(input.worldPos - cameraPosition.xyz);
    float3 normal = normalize(input.normal);

    // Fresnel term: 1 when viewing head-on, 0 at grazing angles
    float fresnel = saturate(dot(-viewDir, normal));

    // ========================================================================
    // Color Interpolation
    //
    // Unpack colors from packed format:
    //   Face-on color (c1): color1.xyz
    //   Edge color (c2): color1.w, color2.xy
    //   Exponent: color2.z
    //
    // Apply power function for controllable transition sharpness.
    // Higher exponent = narrower rim, more concentrated edge color.
    // ========================================================================
    float3 faceColor = color1.xyz;
    float3 edgeColor = float3(color1.w, color2.xy);

    float fresnelPower = pow(fresnel, color2.z);

    // Blend: edge color at grazing angles, face color head-on
    float3 finalColor = lerp(faceColor, edgeColor, fresnelPower);

    return float4(finalColor, 1);
}
