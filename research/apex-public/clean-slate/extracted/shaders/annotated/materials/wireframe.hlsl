// ============================================================================
// READABLE VERSION: Animated Wireframe
// Original: ../materials/wireframe.hlsl (127 lines)
//
// Algorithm: Line-to-quad expansion with animated reveal and soft edges.
//            Converts mesh wireframe lines into screen-space quads with
//            controllable width, softness, and animation.
//
// Features:
//   - Per-vertex animation driven by control texture
//   - Line width control with soft anti-aliased edges
//   - Normal-direction offset for visibility
//   - Intensity overdrive for glow effects
//
// Animation System:
//   The control texture stores animation timing per vertex (0-1).
//   As the animation parameter (t.x) increases, lines "grow" from
//   vertices with low animation values to those with high values.
//
// Parameters:
//   color — Wire color
//   width.x — Line thickness
//   width.y — Edge contrast/softness (0 = soft, higher = sharper)
//   width.z — Overdrive intensity (brightness multiplier)
//   t.x — Animation progress (0-1)
//   t.y — Normal offset (push wires away from surface)
// ============================================================================

SamplerState linearSampler : register(s0);
Texture2D animationTexture : register(t0);  // Per-vertex animation timing

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    float4x4 viewMatrix;
    float4x4 projectionMatrix;
}

cbuffer MaterialBuffer : register(b1)
{
    float4x4 worldMatrix;
    float4x4 invTransWorldMatrix;
    float4 wireColor;
    float4 widthParams;    // x = width, y = contrast, z = overdrive
    float2 animParams;     // x = animation, y = normal offset
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
    float4 normal : TEXCOORD0;
    float animValue : TEXCOORD1;  // Per-vertex animation timing
};

struct GeometryOutput
{
    float4 position : SV_POSITION;
    float edgeParam : TEXCOORD0;    // -1 to 1 across line width
    float animParam : TEXCOORD1;    // Line visibility from animation
};

// ============================================================================
// Vertex Shader — Sample Animation Texture
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    output.position = float4(mul(worldMatrix, float4(input.position, 1)).xyz, 1);
    output.normal = float4(normalize(mul(worldMatrix, float4(input.normal, 1)).xyz), 1);

    // Sample animation timing from texture
    output.animValue = animationTexture.SampleLevel(linearSampler, input.uv.xy, 0).x;

    return output;
}

// ============================================================================
// Geometry Shader — Expand Line to Screen-Space Quad
//
// Takes line input and creates a screen-aligned quad.
// The quad is oriented perpendicular to the line direction in screen space.
// ============================================================================
[maxvertexcount(6)]
void GeometryMain(line VertexOutput input[2], inout TriangleStream<GeometryOutput> outputStream)
{
    // ========================================================================
    // Animation Calculation
    //
    // The line's visibility is controlled by comparing the animation parameter
    // to the average animation value of the line's endpoints.
    // tc = saturate((animParam - avgAnimValue * 0.95 * 0.5) / 0.05)
    // This creates a smooth reveal effect.
    // ========================================================================
    float avgAnimValue = (input[0].animValue + input[1].animValue) * 0.95 * 0.5;
    float lineVisibility = saturate(saturate(animParams.x - avgAnimValue) / 0.05);

    // Transform to clip space with normal offset
    float4 p1 = mul(projectionMatrix, mul(viewMatrix, input[0].position + input[0].normal * animParams.y));
    float4 p2 = mul(projectionMatrix, mul(viewMatrix, input[1].position + input[1].normal * animParams.y));

    // Animated endpoint (line "grows" based on visibility)
    p2 = lerp(p1, p2, lineVisibility);

    // ========================================================================
    // Calculate Screen-Space Perpendicular
    //
    // The line direction in NDC, then perpendicular for width expansion.
    // ========================================================================
    float2 lineDir = normalize((p2 / p2.w).xy - (p1 / p1.w).xy);
    float4 perpendicular = float4(-lineDir.y, lineDir.x, 0, 0) * widthParams.x * 0.05;

    // ========================================================================
    // Generate Two Triangles for the Line Quad
    // ========================================================================
    GeometryOutput o;
    o.animParam = lineVisibility;

    // Triangle 1: p1+n, p1-n, p2-n
    o.position = p1 + perpendicular * p1.w;
    o.edgeParam = 1;
    outputStream.Append(o);

    o.position = p1 - perpendicular * p1.w;
    o.edgeParam = -1;
    outputStream.Append(o);

    o.position = p2 - perpendicular * p2.w;
    outputStream.Append(o);
    outputStream.RestartStrip();

    // Triangle 2: p1+n, p2-n, p2+n
    o.position = p1 + perpendicular * p1.w;
    o.edgeParam = 1;
    outputStream.Append(o);

    o.position = p2 - perpendicular * p2.w;
    o.edgeParam = -1;
    outputStream.Append(o);

    o.position = p2 + perpendicular * p2.w;
    o.edgeParam = 1;
    outputStream.Append(o);
    outputStream.RestartStrip();
}

// ============================================================================
// Pixel Shader — Soft-Edged Wire with Animation
// ============================================================================
float4 PixelMain(GeometryOutput v) : SV_TARGET0
{
    // ========================================================================
    // Edge Falloff
    //
    // Creates soft edges on the wire using power function.
    // edgeParam goes from -1 to 1 across the width.
    // Higher contrast (width.y) = sharper edges.
    // ========================================================================
    float edgeFalloff = pow(abs(1 - abs(v.edgeParam)), 1 + widthParams.y * 30);

    // Discard nearly-invisible pixels
    if (edgeFalloff <= 1 / 255.0)
        discard;

    // Apply color with animation visibility and overdrive
    return edgeFalloff * wireColor * v.animParam * (1 + widthParams.z * 10);
}
