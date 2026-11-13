// Texture Generator: Mapdistort
// GUID: 796B58AD6BE72336D9B1BBE40125D78E
// Parameters:
//   [3] Control Channel (ZFunction)
//   [0] X Amount (Float)
//   [0] Y Amount (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D DataMap:register(t1);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float d=DataMap.Sample(sm,t)[(int)(data1.x*256)];
 float2 n=t+d*float2(data1.y,data1.z);
  return Textur.Sample(sm,n);
}