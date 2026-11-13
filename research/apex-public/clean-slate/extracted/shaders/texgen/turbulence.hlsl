// Texture Generator: Turbulence
// GUID: 83CFD1468ED7650077C6401142C9A58C
// Parameters:
//   [3] Control Channel (ZFunction)
//   [0] Amount (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D DataMap:register(t1);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float f=DataMap.Sample(sm,t)[(int)(data1.x*256)]*3.14159265*2;
 t+=float2(cos(f),sin(f))*data1.y;

 return Textur.Sample(sm,t);
}