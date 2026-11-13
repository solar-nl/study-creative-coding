// Render Technique: Mapdistort
// Type: ShaderToy
// GUID: F4E3856F6D1820356FE044FFE0B23BA8
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • RenderTarget (RenderTarget, Variable)
//   • Input (Texture0, Variable)
//   • Offset X (Float, Animated)
//   • Distortion Texture (Texture1, Variable)
//   • Offset Y (Float, Animated)
//   • Blending (BlendMode0, Variable)
// ======================================================================

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D Disto:register(t1);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float2 power;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float2 pos=Disto.Sample(sm,t)>0.5;
	if (!any(pos)) discard;
	return Textur.Sample(sm,t+pos*power);
}

