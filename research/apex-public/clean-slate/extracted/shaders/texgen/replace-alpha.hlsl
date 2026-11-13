// Texture Generator: Replace Alpha
// GUID: C04016CFF84460CF565CAA51C0E728EE

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D Textur2:register(t1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float4 c=Textur.Sample(sm,t);
 float4 c2=Textur2.Sample(sm,t);

 return float4(c.xyz,c2.x);
}