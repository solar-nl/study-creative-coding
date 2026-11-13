// Texture Generator: Scale
// GUID: 7C8019B349DA1F18D6B360CC7A4B277C
// Parameters:
//   [2] Minimum Color (ZMode)
//   [2] Maximum Color (ZMode)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);
float4 data2:register(c2);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float4 c=Textur.Sample(sm,t);

 float4 Min=data1;
 float4 Max=data2;

 c=lerp(Min,Max,c);

 return c;
}