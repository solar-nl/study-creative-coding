// Texture Generator: Glass
// GUID: 34B09455D52F207AB927E837C9D2034D
// Parameters:
//   [3] Control Channel (ZFunction)
//   [0] Amount (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D DataMap:register(t1);
float4 data1:register(c1);

#define c 3
#define Scatter 1/32.0f

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float4 dx=DataMap.Sample(sm,float2(t.x+Scatter,t.y));
 float4 dy=DataMap.Sample(sm,float2(t.x,t.y+Scatter));

 float d=DataMap.Sample(sm,t)[(int)(data1.x*256)];

 float2 dv=float2(d-dx.x,d-dy.y);
 float2 n=t+dv*(data1.y-0.5);

 return Textur.Sample(sm,n);
}