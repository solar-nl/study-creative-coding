// Texture Generator: Text
// GUID: 17C8685B8902A0F1DF8367B6119C5DB6

SamplerState sm:register(s0);
Texture2D Textur:register(t0);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 return Textur.Sample(sm,t);
}