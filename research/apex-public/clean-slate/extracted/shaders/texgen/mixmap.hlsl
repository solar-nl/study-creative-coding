// Texture Generator: MixMap
// GUID: 8BAD614103780E399528190CD2B331BE
// Parameters:
//   [3] Control Channel (ZFunction)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D Tex2:register(t1);
Texture2D MixMap:register(t2);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float Amount=MixMap.Sample(sm,t)[(int)(data1.x*256)];
 return lerp(Textur.Sample(sm,t),Tex2.Sample(sm,t),Amount);
}