// ============================================================================
// READABLE VERSION: Sharpening Filter
// Original: ../materials/sharpen.hlsl (47 lines)
//
// Algorithm: Convolution-based unsharp mask using a Laplacian kernel.
//            Enhances edges by subtracting a blurred version from the original.
//
// Kernel Used:
//   ┌────┬────┬────┐
//   │ -1 │ -1 │ -1 │
//   ├────┼────┼────┤
//   │ -1 │  9 │ -1 │
//   ├────┼────┼────┤
//   │ -1 │ -1 │ -1 │
//   └────┴────┴────┘
//
// This is equivalent to: original + (original - blur) * k
// Where k depends on the center weight. With center=9 and sum=-8,
// this is: original + original * 8 - blur * 8 = 9*original - 8*blur
//
// The kernel sums to 1, preserving overall brightness while
// enhancing high-frequency detail.
//
// Parameters:
//   power — Blend factor between original and sharpened (0-1, scaled by 5)
// ============================================================================

Texture2D inputTexture : register(t0);

// ============================================================================
// Constant Buffers
// ============================================================================
cbuffer SceneBuffer : register(b0)
{
    float time, aspectRatio, screenWidth, screenHeight;
}

cbuffer MaterialBuffer : register(b1)
{
    float power;  // Sharpening intensity
}

// ============================================================================
// Convolution Helper
//
// Applies a 3x3 kernel to the image at the given pixel position.
// Uses Load() for exact texel access without filtering.
// Clamps coordinates to valid texture bounds.
// ============================================================================
float4 Convolve3x3(float3x3 kernel, int2 pixelPos)
{
    int2 maxPos = int2(screenWidth, screenHeight) - 1;
    float4 result = 0;

    for (int x = 0; x < 3; x++)
    {
        for (int y = 0; y < 3; y++)
        {
            // Sample neighbor (clamped to texture bounds)
            int2 samplePos = clamp(pixelPos + int2(x, y) - 1, int2(0, 0), maxPos);
            float4 sample = inputTexture.Load(int3(samplePos, 0));

            // Accumulate weighted by kernel
            result += sample * kernel[x][y];
        }
    }

    return result;
}

// ============================================================================
// Pixel Shader — Sharpening
// ============================================================================
float4 PixelMain(float4 pixelPos : SV_POSITION) : SV_TARGET0
{
    // Load original pixel value
    float4 original = inputTexture.Load(int3(pixelPos.xy, 0));

    // ========================================================================
    // Laplacian Sharpening Kernel
    //
    // Center weight of 9 with -1 for all neighbors.
    // Sum = 9 - 8 = 1 (brightness preserving)
    //
    // Effect: output = original + 8*(original - average_of_neighbors)
    // This amplifies differences from local average (edges).
    // ========================================================================
    float3x3 sharpenKernel = float3x3(
        -1, -1, -1,
        -1,  9, -1,
        -1, -1, -1
    );

    float4 sharpened = Convolve3x3(sharpenKernel, pixelPos.xy);

    // Blend between original and sharpened based on power
    // power * 5 allows subtle (0) to aggressive (5x) sharpening
    return lerp(original, sharpened, power * 5);
}
