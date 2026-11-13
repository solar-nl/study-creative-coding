// Render Technique: Texture Draw
// Type: ShaderToy
// GUID: FA2C8F6BB7A84615E511F0B5458FC520
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • RenderTarget (RenderTarget, Variable)
//   • Texture (Texture0, Variable)
//   • Color (Color, Animated)
//   • BlendMode (BlendMode0, Variable)
// ======================================================================

SamplerState sm:register(s0);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float4 color;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	return Textur.Sample(sm,t)*color;
}

