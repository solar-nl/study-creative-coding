// Texture Generator: DirBlur
// GUID: 30BD4D1C8F082EA0BD78D8A9DAAB0C92
// Parameters:
//   [3] Control Channel (ZFunction)
//   [0] Amount (Float)

SamplerState sm:register(s0);
float4 data1:register(c1);
Texture2D Textur:register(t0);
Texture2D DirMap:register(t1);

#define c 21

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float d=DirMap.Sample(sm,t)[(int)(data1.x*256)];
 float2 vec=float2(cos(d*3.14159265*2),sin(d*3.14159265*2));

 float4 ret=0;

 for (int x=1; x<c; x++)
  ret+=Textur.Sample(sm,t+(vec*x*data1.y*0.03));

 return ret/(c-1);
}