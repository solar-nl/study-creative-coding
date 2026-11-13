// Texture Generator: Colorize
// GUID: 293BDFEFE6E78D39BF95D34A9138F5BB
// Parameters:
//   [2] Color 1 (ZMode)
//   [2] Color 2 (ZMode)
//   [3] Control Channel (ZFunction)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 Color1:register(c1);
float4 Color2:register(c2);
float4 Data1:register(c3);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float f=Textur.Sample(sm,t)[(int)(Data1.x*256)];
 return lerp(Color1,Color2,f);
}