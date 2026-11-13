// Texture Generator: Contrast
// GUID: 74DC36107DB66254A841FE48313562B1
// Parameters:
//   [0] Strength (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float4 c=Textur.Sample(sm,t);

 float s=data1.x*3;
 s*=s;
 return lerp(0.5,c,s*5);
}