// Render Technique: aces color grading
// Type: ShaderToy
// GUID: EB1F6EC9F690F5D26947595DC41AC563
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: New Pass
//   • Input (Texture0, Variable)
//   • Rendertarget (RenderTarget, Variable)
//   • Power (Float, Variable)
//   • SampleCount (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect,xres,yres;
}

cbuffer c : register(b1)
{
	float power;
	float samplecnt;
}

float4 p( float2 t:TEXCOORD0, float4 ps:SV_POSITION ) : SV_TARGET0
{ 
	float3 color=Textur.Load(int3(ps.xy,0));

	float3x3 ACES_INPUT_MAT = float3x3(
	    0.59719, 0.35458, 0.04823,
	    0.07600, 0.90834, 0.01566,
	    0.02840, 0.13383, 0.83777);

	float3x3 ACES_OUTPUT_MAT = float3x3(
	    1.60475,-0.53108,-0.07367,
	    -0.10208, 1.10813,-0.00605,
	    -0.00327,-0.07276, 1.07602);

    color = mul(ACES_INPUT_MAT, color);

    // Apply RRT and ODT
    float3 a = color*(         color + 0.0245786) - 0.000090537;
    float3 b = color*(0.983729*color + 0.4329510) + 0.238081;
    color = a/b;

    color = mul(ACES_OUTPUT_MAT, color);

    // Clamp to [0, 1]
    color = saturate(color);

	return float4(color,1);
}

