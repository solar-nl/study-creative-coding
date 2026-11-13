// Texture Generator: SmoothStep
// GUID: BDFC449886C9303D387A1E9FCEB74833
// Parameters:
//   [0] Power (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	return smoothstep(0,data1.x,Textur.Sample(sm,t));
}