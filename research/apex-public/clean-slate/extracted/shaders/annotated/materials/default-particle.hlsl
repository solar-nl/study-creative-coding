// ============================================================================
// READABLE VERSION: Default Particle System
// Original: ../materials/default-particle.hlsl (147 lines)
//
// Algorithm: GPU particle rendering with lifetime-driven parameter curves.
//            Each particle's visual properties (color, size, alpha) are
//            sampled from curve textures based on particle lifetime.
//
// Pipeline:
//   Vertex Shader: Sample particle curves, pass data to geometry shader
//   Geometry Shader: Expand point to camera-facing quad
//   Pixel Shader: Apply texture and particle color
//
// Particle Data Layout:
//   Position.xyzw — World position
//   Data.x — Lifetime (0 = born, 1 = dead)
//   Data.y — Rotation angle
//   Data.z — Random seed (for chaos parameters)
//   Data.w — (unused)
//
// Curve Texture Layout (t_0):
//   Row 0-4: Base curves (R, G, B, A, Size)
//   Row 5-9: Chaos curves (R, G, B, A, Size randomization)
//   Row 10: Alpha test curve
//   X axis: Lifetime (0-2048 texels = 0-1 lifetime)
//
// Parameters:
//   ParticleLifeFloat parameters control curve shapes
//   Chaos parameters add random variation per particle
// ============================================================================

// Textures
Texture2D curveTexture : register(t0);      // Particle parameter curves
Texture2D particleTexture : register(t1);   // Particle sprite texture

SamplerState linearSampler : register(s0);
SamplerState pointSampler : register(s1);

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
    float4 color;
    float alphaTest;
}

// ============================================================================
// Vertex Structures
// ============================================================================
struct VertexInput
{
    float4 position : POSITION0;   // World position
    float4 data : TEXCOORD0;       // x=lifetime, y=rotation, z=seed
};

struct VertexOutput
{
    float4 position : SV_POSITION;
    float4 color : TEXCOORD0;      // RGBA from curves
    float4 data : TEXCOORD1;       // Pass-through particle data
    float4 size : TEXCOORD2;       // Size from curve
    float alphaTest : TEXCOORD3;   // Alpha threshold from curve
};

struct GeometryOutput
{
    float4 position : SV_POSITION;
    float2 texCoord : TEXCOORD0;
    float4 data : TEXCOORD1;
    float4 color : TEXCOORD2;
    float alphaTest : TEXCOORD3;
};

// ============================================================================
// Sample Particle Curve
//
// Reads a value from the curve texture at the given lifetime position.
// Uses linear interpolation between adjacent texels for smooth curves.
//
// Parameters:
//   curveId — Row in the curve texture (0-10)
//   lifetime — Particle age (0-1)
// ============================================================================
float SampleCurve(int curveId, float lifetime)
{
    float t = 1 - lifetime;  // Reverse: 0 at death, 1 at birth

    // Sample two adjacent texels and interpolate
    float a = curveTexture.Load(int3(trunc(t * 2048), curveId, 0)).x;
    float b = curveTexture.Load(int3(trunc(t * 2048) + 1, curveId, 0)).x;

    return lerp(a, b, frac(t * 2048));
}

// ============================================================================
// Hash-Based Noise for Particle Variation
// ============================================================================
float GetNoise(float seed)
{
    return frac(sin(seed * 54.37) * 17593.1317);
}

// ============================================================================
// Sample Curve with Chaos (Random Variation)
//
// Combines base curve with chaos curve multiplied by random noise.
// This creates per-particle variation in color, size, etc.
// ============================================================================
float SampleCurveWithChaos(int baseCurveId, int chaosCurveId, float seed, float lifetime)
{
    return SampleCurve(baseCurveId, lifetime) +
           SampleCurve(chaosCurveId, lifetime) * GetNoise(seed + chaosCurveId);
}

// ============================================================================
// Vertex Shader — Sample Particle Parameters
// ============================================================================
VertexOutput VertexMain(VertexInput input)
{
    VertexOutput output;

    // Transform to view space (geometry shader will project)
    output.position = mul(viewMatrix, input.position);
    output.data = input.data;

    // Sample RGBA from curves with chaos variation
    // Curves 0-4: base, Curves 5-9: chaos
    float lifetime = input.data.x;
    float seed = input.data.z;

    output.color.r = SampleCurveWithChaos(0, 5, seed, lifetime);
    output.color.g = SampleCurveWithChaos(1, 6, seed, lifetime);
    output.color.b = SampleCurveWithChaos(2, 7, seed, lifetime);
    output.color.a = SampleCurveWithChaos(3, 8, seed, lifetime);

    output.size = SampleCurveWithChaos(4, 9, seed, lifetime);
    output.alphaTest = SampleCurve(10, lifetime);

    return output;
}

// ============================================================================
// Geometry Shader — Expand Point to Rotated Quad
//
// Creates a camera-facing quad from a single point input.
// The quad is rotated based on the particle's rotation parameter.
// ============================================================================
[maxvertexcount(4)]
void GeometryMain(point VertexOutput input[1], inout TriangleStream<GeometryOutput> outputStream)
{
    float4 center = input[0].position;
    float4 scale = 0.1 * input[0].size.x;

    // Rotation from particle data
    float rotation = 0.1 * input[0].data.y;
    float4 xAxis = float4(sin(rotation), cos(rotation), 0, 0);
    float4 yAxis = float4(-xAxis.y, xAxis.x, 0, 0);

    // Generate four corners of the quad
    GeometryOutput verts[4];

    verts[0].position = mul(projectionMatrix, center + (-xAxis - yAxis) * scale);
    verts[0].texCoord = float2(1, 1);

    verts[1].position = mul(projectionMatrix, center + (xAxis - yAxis) * scale);
    verts[1].texCoord = float2(1, 0);

    verts[2].position = mul(projectionMatrix, center + (xAxis + yAxis) * scale);
    verts[2].texCoord = float2(0, 0);

    verts[3].position = mul(projectionMatrix, center + (-xAxis + yAxis) * scale);
    verts[3].texCoord = float2(0, 1);

    // Copy shared data to all vertices
    for (int i = 0; i < 4; i++)
    {
        verts[i].data = input[0].data;
        verts[i].color = input[0].color;
        verts[i].alphaTest = input[0].alphaTest;
    }

    // Output as triangle strip (3, 0, 2, 1 order)
    outputStream.Append(verts[3]);
    outputStream.Append(verts[0]);
    outputStream.Append(verts[2]);
    outputStream.Append(verts[1]);
    outputStream.RestartStrip();
}

// ============================================================================
// Pixel Shader — Textured Particle
// ============================================================================
float4 PixelMain(GeometryOutput v) : SV_TARGET0
{
    float4 texColor = particleTexture.Sample(linearSampler, v.texCoord);

    // Dynamic alpha test based on particle lifetime
    if (texColor.w < v.alphaTest)
        discard;

    return v.color * texColor;
}
