// Texture Generator: Pixelize
// GUID: 4F957825D86CF31FAF087B0235A6BACD
// Parameters:
//   [0] x count (Float)
//   [0] y count (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	float2 size = 1.0f/(data1.xy*255);
	float2 t2 = t-fmod(t,size)+size/2.0f;	
	return Textur.SampleLevel(sm,t2,0);
}