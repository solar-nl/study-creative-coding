// Texture Generator: Invert
// GUID: 3D565B952DEB7ECA0ACF6AA456C83BD7

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	return 1-Textur.Sample(sm,t);
}