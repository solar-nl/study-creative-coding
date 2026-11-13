// Texture Generator: Mirror
// GUID: AD8210B48E4E3D9A1A24E5A726D0C339
// Parameters:
//   [1] axis (Color)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float2 t2 = 0.5-abs(t-0.5);
 return Textur.Sample(sm,float2(data1.x?t.x:t2.x,!data1.x?t.y:t2.y));
}