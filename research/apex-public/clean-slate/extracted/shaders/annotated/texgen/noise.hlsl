// ============================================================================
// READABLE VERSION: Multi-Octave Perlin Noise Generator
// Original: ../texgen/noise.hlsl (53 lines)
//
// Algorithm: Multi-octave (fractal) noise with optional smoothstep interpolation.
//            Each pass adds one octave; amplitude scales by persistence factor.
//            Uses a pre-generated 256x256 hash texture for random values.
//
// Parameters:
//   texgenParams.x — Minimum octave (encoded as value * 255, then -1)
//   texgenParams.y — Maximum octave (encoded as value * 255)
//   texgenParams.z — Persistence: amplitude multiplier per octave (0-1)
//   texgenParams.w — Interpolation mode (0 = smoothstep, 1 = linear)
//
// Multi-Pass System:
//   PassInfo.x contains the current render pass index (0-based).
//   Each pass corresponds to one noise octave.
//   Octaves outside [min, max] range are skipped.
//
// References:
//   - Ken Perlin, "An Image Synthesizer" (SIGGRAPH 1985)
//   - https://mrl.cs.nyu.edu/~perlin/paper445.pdf
// ============================================================================

// Sampler for reading from previous pass result
SamplerState linearSampler : register(s0);

// Input textures
Texture2D previousPassTexture : register(t0);  // Result from previous render pass
Texture2D hashTexture : register(t1);          // 256x256 pre-computed hash values

// Constant buffer registers
float4 passInfo : register(c0);      // x=passIndex, y=passMultiplier, z/w=unused
float4 texgenParams : register(c1);  // x=minOctave, y=maxOctave, z=persistence, w=interpMode

// ============================================================================
// Sample the hash texture at integer coordinates
// The hash texture provides pseudo-random values in a tileable 256x256 grid.
// Coordinates wrap via fmod to create seamless tiling.
//
// Parameters:
//   integerCoord — Integer coordinates to sample
//
// Returns:
//   RGBA value from the hash texture (used as random noise)
// ============================================================================
float4 SampleHashTexture(float2 integerCoord)
{
    // Scale coordinates by 256 and apply texture resolution multiplier
    // passInfo.x is the current octave, passInfo.y is a frequency multiplier
    // The (1 + passInfo.y) term allows for sub-octave frequency offsets
    float2 scaledCoord = integerCoord * 256 * (max(1, passInfo.x) * (1 + passInfo.y));

    // Wrap coordinates to 256x256 tile using fmod
    // Load from mip level 0 (no filtering - we want exact texel values)
    return hashTexture.Load(int3(fmod(scaledCoord, 256), 0));
}

// ============================================================================
// Main pixel shader entry point
// Generates one octave of noise per pass, accumulating into the output.
//
// Parameters:
//   texCoord — UV coordinates in [0, 1] range
//
// Returns:
//   Accumulated noise value (centered around 0.5 for unsigned storage)
// ============================================================================
float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Decode octave range from byte-encoded parameters
    // Parameters are stored as normalized floats (0-1) but represent integers (0-255)
    float minOctave = texgenParams.x * 255 - 1;  // -1 offset for 0-based indexing
    float maxOctave = texgenParams.y * 255;

    // Calculate which pass number this is relative to the minimum octave
    // passInfo.x is the absolute pass index; subtract minOctave to get octave number
    int relativePassIndex = passInfo.x + 0.5 - minOctave;  // +0.5 for rounding

    // Calculate the grid cell size for this octave
    // Each octave doubles the frequency, so cell size halves
    // Octave 0 = 1/4, Octave 1 = 1/8, Octave 2 = 1/16, etc.
    float cellSize = 1.0 / pow(2.0, passInfo.x + 2);

    // Calculate amplitude for this octave using persistence
    // First pass (relativePassIndex=0) has amplitude 1.0
    // Each subsequent pass multiplies by persistence factor
    // persistence < 1 gives decreasing amplitude for higher octaves (standard fbm)
    float amplitude = relativePassIndex ? pow(abs(texgenParams.z), relativePassIndex) : 1.0;

    // ========================================================================
    // Bilinear interpolation setup
    // We need to sample the noise at the four corners of the current grid cell
    // and interpolate based on position within the cell.
    // ========================================================================

    // Find the grid cell containing this UV coordinate
    float2 uv = texCoord;
    float2 fractionalPart = uv % cellSize;  // Position within cell
    uv -= fractionalPart;                    // Snap to cell corner (bottom-left)
    fractionalPart /= cellSize;              // Normalize to [0, 1] within cell

    // ========================================================================
    // Smoothstep interpolation (optional)
    // Smoothstep creates smoother transitions between grid cells by
    // applying S(t) = t²(3 - 2t) which has zero derivatives at t=0 and t=1.
    // This eliminates the "grid artifact" visible with linear interpolation.
    // ========================================================================
    if (texgenParams.w == 0)  // Mode 0 = smoothstep
    {
        // Apply smoothstep: S(t) = t² × (3 - 2t)
        // This is mathematically equivalent to: 3t² - 2t³
        fractionalPart *= fractionalPart * (3 - 2 * fractionalPart);
    }
    // Mode 1 = linear interpolation (no modification needed)

    // Calculate the opposite corner of the grid cell (with wrapping via frac)
    float2 oppositeCorner = frac(uv + cellSize);

    // ========================================================================
    // Bilinear interpolation of the four corner samples
    // Grid layout:
    //   (uv.x, oppositeCorner.y) ---- (oppositeCorner.x, oppositeCorner.y)
    //           |                              |
    //           |       (fractionalPart)       |
    //           |                              |
    //   (uv.x, uv.y) --------------- (oppositeCorner.x, uv.y)
    // ========================================================================
    float4 noiseX, noiseY;

    // Interpolate along X axis for bottom edge (y = uv.y)
    noiseX = lerp(
        SampleHashTexture(uv),                         // Bottom-left
        SampleHashTexture(float2(oppositeCorner.x, uv.y)),  // Bottom-right
        fractionalPart.x
    );

    // Interpolate along X axis for top edge (y = oppositeCorner.y)
    noiseY = lerp(
        SampleHashTexture(float2(uv.x, oppositeCorner.y)),  // Top-left
        SampleHashTexture(oppositeCorner),                   // Top-right
        fractionalPart.x
    );

    // Final interpolation along Y axis
    // Subtract 0.5 to center noise around 0 (for signed accumulation)
    // Then multiply by amplitude for this octave
    float4 noiseValue = (lerp(noiseX, noiseY, fractionalPart.y) - 0.5) * amplitude;

    // ========================================================================
    // Accumulate with previous passes
    // ========================================================================
    if (relativePassIndex > 0)
    {
        // Add this octave to the accumulated result from previous passes
        noiseValue += previousPassTexture.Sample(linearSampler, texCoord);
    }
    else
    {
        // First octave: start with 0.5 bias so result stays in [0, 1] range
        // (noise oscillates around this midpoint)
        noiseValue += 0.5;
    }

    // ========================================================================
    // Handle passes beyond max octave
    // If we've exceeded the maximum octave, just pass through the previous result
    // This allows the multi-pass system to run extra passes without affecting output
    // ========================================================================
    if (passInfo.x + 0.5 > maxOctave)
    {
        noiseValue = previousPassTexture.Sample(linearSampler, texCoord);
    }

    return noiseValue;
}
