// ============================================================================
// READABLE VERSION: Point Sprites
// Original: ../materials/pointsprites.hlsl (94 lines)
//
// Algorithm: Triangle-to-sprite conversion using geometry shader.
//            Each input triangle is replaced with a camera-facing quad
//            (billboard sprite) positioned at the triangle's centroid.
//
// Use Cases:
//   - Particle effects from mesh vertices
//   - Foliage imposters
//   - Point cloud visualization
//   - Decal placement on surfaces
//
// Pipeline:
//   Vertex Shader: Transform triangles to view space
//   Geometry Shader: Replace triangle with billboard quad at centroid
//   Pixel Shader: Sample sprite texture with color tint
//
// Parameters:
//   color — RGBA tint
//   scale — Sprite size in world units
//   offset — Distance to push sprite along face normal
// ============================================================================

Texture2D spriteTexture : register(t0);
SamplerState linearSampler : register(s0);

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
    float4 color;     // Sprite color tint
    float scale;      // Sprite size
    float offset;     // Normal offset distance
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
};

struct GeometryOutput
{
    float4 position : SV_POSITION;
    float2 texCoord : TEXCOORD0;
};

// ============================================================================
// Vertex Shader — Transform to View Space
// ============================================================================
float4 VertexMain(VertexInput input) : SV_POSITION
{
    float3 worldPos = mul(worldMatrix, float4(input.position, 1)).xyz;
    return mul(viewMatrix, float4(worldPos, 1));
}

// ============================================================================
// Geometry Shader — Triangle to Billboard Sprite
//
// Takes a triangle input and outputs a camera-facing quad at its center.
// The quad is offset along the triangle's face normal.
// ============================================================================
[maxvertexcount(4)]
void GeometryMain(triangle VertexOutput input[3], inout TriangleStream<GeometryOutput> outputStream)
{
    // Calculate triangle centroid (average of vertices)
    float4 center = (input[0].position + input[1].position + input[2].position) / 3.0;

    // Calculate face normal from edge vectors
    float3 edge1 = normalize(input[0].position.xyz - input[1].position.xyz);
    float3 edge2 = normalize(input[2].position.xyz - input[1].position.xyz);
    float3 faceNormal = cross(edge1, edge2);

    // Offset sprite along face normal
    center += float4(faceNormal, 0) * offset;

    // ========================================================================
    // Generate Billboard Quad
    //
    // In view space, X and Y are screen-aligned, so we expand the point
    // into a screen-facing quad using fixed offsets.
    // ========================================================================
    GeometryOutput verts[4];

    verts[0].position = mul(projectionMatrix, center + float4(-1, -1, 0, 0) * scale);
    verts[0].texCoord = float2(0, 0);

    verts[1].position = mul(projectionMatrix, center + float4(1, -1, 0, 0) * scale);
    verts[1].texCoord = float2(1, 0);

    verts[2].position = mul(projectionMatrix, center + float4(1, 1, 0, 0) * scale);
    verts[2].texCoord = float2(1, 1);

    verts[3].position = mul(projectionMatrix, center + float4(-1, 1, 0, 0) * scale);
    verts[3].texCoord = float2(0, 1);

    // Output as triangle strip
    outputStream.Append(verts[3]);
    outputStream.Append(verts[0]);
    outputStream.Append(verts[2]);
    outputStream.Append(verts[1]);
    outputStream.RestartStrip();
}

// ============================================================================
// Pixel Shader — Textured Sprite
// ============================================================================
float4 PixelMain(GeometryOutput v) : SV_TARGET0
{
    return spriteTexture.Sample(linearSampler, v.texCoord) * color;
}
