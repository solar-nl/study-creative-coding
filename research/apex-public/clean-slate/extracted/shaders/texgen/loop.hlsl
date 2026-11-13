// Texture Generator: Loop
// GUID: 506B597216634E783F90399B9D8891B7
// Parameters:
//   [0] X Loop (Float)
//   [0] Y Loop (Float)

SamplerState sm:register(s0);
float4 data1:register(c1);
Texture2D Textur:register(t0);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 return Textur.Sample(sm,t*float2(data1.x*255.0f,data1.y*255.0f));
}