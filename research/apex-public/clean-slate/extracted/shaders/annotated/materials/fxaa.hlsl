// ============================================================================
// READABLE VERSION: Fast Approximate Anti-Aliasing (FXAA)
// Original: ../materials/fxaa.hlsl (202 lines)
//
// Algorithm: Two-pass edge-aware anti-aliasing.
//   Pass 1: Compute luminance and store in alpha channel
//   Pass 2: Detect edges via luminance contrast, blend along edges
//
// This is FXAA 3.11 quality preset, adapted for demoscene use.
// Uses 12 quality steps for edge tracing.
//
// Parameters:
//   Pass 1:
//     rgb — Luminance weights (typically 0.299, 0.587, 0.114 for standard luma)
//   Pass 2:
//     subpixel — Subpixel anti-aliasing amount (0-1)
//     edgethresh — Edge detection threshold
//     edgethreshmin — Minimum edge threshold
//
// References:
//   - Timothy Lottes, "FXAA" (NVIDIA, 2009)
//   - FXAA 3.11 whitepaper
// ============================================================================

// ============================================================================
// PASS 1: LUMINANCE PREPASS
// Converts image to linear space and computes luminance for edge detection
// ============================================================================

SamplerState linearSampler_Pass1 : register(s1);
Texture2D inputTexture_Pass1 : register(t0);

cbuffer SceneBuffer_Pass1 : register(b0)
{
    float time_p1, aspectRatio_p1, screenWidth_p1, screenHeight_p1;
}

cbuffer MaterialBuffer_Pass1 : register(b1)
{
    float3 luminanceWeights;  // RGB weights for luminance calculation
}

float4 LuminancePrepass(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Sample and convert from sRGB to linear (approximate gamma 2.4)
    // Formula: linear = ((sRGB / 1.055) + 0.055)^2.4
    float4 color = pow(saturate(inputTexture_Pass1.Sample(linearSampler_Pass1, texCoord)), 1 / 2.4) * 1.055 - 0.055;

    // Compute luminance and store in alpha channel
    // Normalize weights so they sum to 1
    color.w = dot(saturate(color.xyz), luminanceWeights / dot(luminanceWeights, 1));

    return color;
}

// ============================================================================
// PASS 2: FXAA EDGE DETECTION AND BLENDING
// Detects edges via luminance contrast, traces along edges, blends to smooth
// ============================================================================

SamplerState linearSampler_Pass2 : register(s1);
Texture2D fxaaTexture : register(t0);

// Helper functions for texture sampling
float4 SampleTexture(float2 uv)
{
    return fxaaTexture.SampleLevel(linearSampler_Pass2, uv, 0.0);
}

float4 SampleTextureOffset(float2 uv, int2 offset)
{
    return fxaaTexture.SampleLevel(linearSampler_Pass2, uv, 0.0, offset);
}

// ============================================================================
// Main FXAA Algorithm
// ============================================================================
float4 FxaaPixelShader(
    float2 position,
    float2 rcpFrame,           // 1/resolution
    float qualitySubpix,       // Subpixel AA amount
    float qualityEdgeThreshold,    // Edge detection threshold
    float qualityEdgeThresholdMin) // Minimum edge threshold
{
    // Quality step multipliers for edge tracing (FXAA preset 39)
    // Higher values = longer jumps = faster but less precise
    float quality[12] = { 1, 1, 1, 1, 1, 1.5, 2, 2, 2, 2, 4, 8 };

    // Sample center pixel and 4-connected neighbors (N, S, E, W)
    float4 rgbyM = SampleTexture(position);
    float lumaS = SampleTextureOffset(position, int2(0, 1)).w;
    float lumaE = SampleTextureOffset(position, int2(1, 0)).w;
    float lumaN = SampleTextureOffset(position, int2(0, -1)).w;
    float lumaW = SampleTextureOffset(position, int2(-1, 0)).w;

    // ========================================================================
    // Early exit: skip pixels with low contrast (not on an edge)
    // ========================================================================
    float rangeMax = max(max(lumaN, lumaW), max(lumaE, max(lumaS, rgbyM.w)));
    float rangeMin = min(min(lumaN, lumaW), min(lumaE, min(lumaS, rgbyM.w)));
    float rangeMaxScaled = rangeMax * qualityEdgeThreshold;
    float range = rangeMax - rangeMin;
    float rangeMaxClamped = max(qualityEdgeThresholdMin, rangeMaxScaled);

    if (range < rangeMaxClamped)
        return rgbyM;  // No edge detected, return original

    // ========================================================================
    // Sample diagonal neighbors for edge direction detection
    // ========================================================================
    float lumaNW = SampleTextureOffset(position, int2(-1, -1)).w;
    float lumaSE = SampleTextureOffset(position, int2(1, 1)).w;
    float lumaNE = SampleTextureOffset(position, int2(1, -1)).w;
    float lumaSW = SampleTextureOffset(position, int2(-1, 1)).w;

    // Compute edge detection gradients
    float lumaNS = lumaN + lumaS;
    float lumaWE = lumaW + lumaE;
    float subpixRcpRange = 1.0 / range;
    float subpixNSWE = lumaNS + lumaWE;

    // Second derivative (Laplacian) for edge detection
    float edgeHorz1 = (-2.0 * rgbyM.w) + lumaNS;
    float edgeVert1 = (-2.0 * rgbyM.w) + lumaWE;

    float lumaNESE = lumaNE + lumaSE;
    float lumaNWNE = lumaNW + lumaNE;
    float edgeHorz2 = (-2.0 * lumaE) + lumaNESE;
    float edgeVert2 = (-2.0 * lumaN) + lumaNWNE;

    float lumaNWSW = lumaNW + lumaSW;
    float lumaSWSE = lumaSW + lumaSE;
    float edgeHorz4 = (abs(edgeHorz1) * 2.0) + abs(edgeHorz2);
    float edgeVert4 = (abs(edgeVert1) * 2.0) + abs(edgeVert2);
    float edgeHorz3 = (-2.0 * lumaW) + lumaNWSW;
    float edgeVert3 = (-2.0 * lumaS) + lumaSWSE;
    float edgeHorz = abs(edgeHorz3) + edgeHorz4;
    float edgeVert = abs(edgeVert3) + edgeVert4;

    // ========================================================================
    // Determine edge orientation (horizontal vs vertical)
    // ========================================================================
    float subpixNWSWNESE = lumaNWSW + lumaNESE;
    float lengthSign = rcpFrame.x;
    float subpixA = subpixNSWE * 2.0 + subpixNWSWNESE;
    bool horzSpan = edgeHorz >= edgeVert;  // True = horizontal edge

    // Swap directions based on edge orientation
    if (!horzSpan)
    {
        lumaN = lumaW;
        lumaS = lumaE;
    }
    else
    {
        lengthSign = rcpFrame.y;
    }

    float subpixB = (subpixA * (1.0 / 12.0)) - rgbyM.w;

    // ========================================================================
    // Find edge direction (positive or negative)
    // ========================================================================
    float gradientN = lumaN - rgbyM.w;
    float gradientS = lumaS - rgbyM.w;
    float lumaNNorm = lumaN + rgbyM.w;
    float lumaSNorm = lumaS + rgbyM.w;
    bool pairN = abs(gradientN) >= abs(gradientS);
    float gradient = max(abs(gradientN), abs(gradientS));

    if (pairN)
        lengthSign = -lengthSign;

    float subpixC = saturate(abs(subpixB) * subpixRcpRange);

    // ========================================================================
    // Edge tracing: walk along the edge in both directions
    // ========================================================================
    float2 posB = position;
    float2 offNP;
    offNP.x = (!horzSpan) ? 0.0 : rcpFrame.x;
    offNP.y = (horzSpan) ? 0.0 : rcpFrame.y;

    if (!horzSpan)
        posB.x += lengthSign * 0.5;
    if (horzSpan)
        posB.y += lengthSign * 0.5;

    float2 posN = posB - offNP * quality[0];  // Negative direction
    float2 posP = posB + offNP * quality[0];  // Positive direction

    float subpixD = ((-2.0) * subpixC) + 3.0;
    float lumaEndN = SampleTexture(posN).w;
    float subpixE = subpixC * subpixC;
    float lumaEndP = SampleTexture(posP).w;

    if (!pairN)
        lumaNNorm = lumaSNorm;

    float gradientScaled = gradient * 1.0 / 4.0;
    float lumaMM = rgbyM.w - lumaNNorm * 0.5;
    float subpixF = subpixD * subpixE;
    bool lumaMMLTZero = lumaMM < 0.0;

    lumaEndN -= lumaNNorm * 0.5;
    lumaEndP -= lumaNNorm * 0.5;
    bool doneN, doneP, doneNP;

    // Iteratively trace along edge until we find the endpoints
    for (int x = 1; x < 12; x++)
    {
        doneN = abs(lumaEndN) >= gradientScaled;
        doneP = abs(lumaEndP) >= gradientScaled;
        doneNP = (!doneN) || (!doneP);

        if (!doneN)
        {
            posN.x -= offNP.x * quality[x];
            posN.y -= offNP.y * quality[x];
        }
        if (!doneP)
        {
            posP.x += offNP.x * quality[x];
            posP.y += offNP.y * quality[x];
        }

        if (!doneNP || x == 11)
            break;

        if (!doneN)
        {
            lumaEndN = SampleTexture(posN.xy).w;
            lumaEndN = lumaEndN - lumaNNorm * 0.5;
        }
        if (!doneP)
        {
            lumaEndP = SampleTexture(posP.xy).w;
            lumaEndP = lumaEndP - lumaNNorm * 0.5;
        }
    }

    // ========================================================================
    // Compute final blend amount based on edge endpoints
    // ========================================================================
    float dstN = position.x - posN.x;
    float dstP = posP.x - position.x;
    if (!horzSpan)
    {
        dstN = position.y - posN.y;
        dstP = posP.y - position.y;
    }

    bool goodSpanN = (lumaEndN < 0.0) != lumaMMLTZero;
    float spanLength = (dstP + dstN);
    bool goodSpanP = (lumaEndP < 0.0) != lumaMMLTZero;
    float spanLengthRcp = 1.0 / spanLength;

    bool directionN = dstN < dstP;
    float dst = min(dstN, dstP);
    bool goodSpan = directionN ? goodSpanN : goodSpanP;
    float subpixG = subpixF * subpixF;
    float pixelOffset = (dst * (-spanLengthRcp)) + 0.5;
    float subpixH = subpixG * qualitySubpix;

    float pixelOffsetGood = goodSpan ? pixelOffset : 0.0;
    float pixelOffsetSubpix = max(pixelOffsetGood, subpixH);

    // Sample at the computed offset position
    float2 posM = position;
    if (!horzSpan)
        posM.x += pixelOffsetSubpix * lengthSign;
    if (horzSpan)
        posM.y += pixelOffsetSubpix * lengthSign;

    return float4(SampleTexture(posM).xyz, rgbyM.w);
}

// Main pass 2 entry point
cbuffer SceneBuffer_Pass2 : register(b0)
{
    float time, aspectRatio, screenWidth, screenHeight;
}

cbuffer MaterialBuffer_Pass2 : register(b1)
{
    float subpixelAmount;
    float edgeThreshold, edgeThresholdMin;
}

float4 PixelMain(float2 texCoord : TEXCOORD0) : SV_TARGET0
{
    // Apply FXAA and convert back to sRGB
    float4 result = FxaaPixelShader(
        texCoord,
        1 / float2(screenWidth, screenHeight),
        subpixelAmount,
        lerp(1 / 3.0, 0.063, edgeThreshold),  // Map threshold to useful range
        edgeThresholdMin * 0.0833             // Scale minimum threshold
    );

    // Convert from linear to sRGB (inverse of prepass)
    return pow((0.055 + saturate(result)) / 1.055, 2.4);
}
