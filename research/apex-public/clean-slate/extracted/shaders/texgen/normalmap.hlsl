// Texture Generator: Normalmap
// GUID: 43D0AFDAD2232F1D84161C800B9A683A
// Parameters:
//   [3] Control Channel (ZFunction)
//   [0] Strength (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float d=0.5/4096.0f;

 int DataChannel=data1.x*256;

 float x1=Textur.Sample(sm,t-float2(d,0))[DataChannel];
 float x2=Textur.Sample(sm,t+float2(d,0))[DataChannel];
 float y1=Textur.Sample(sm,t-float2(0,d))[DataChannel];
 float y2=Textur.Sample(sm,t+float2(0,d))[DataChannel];

 float s=(1-data1.y*255/256.0f)*1.2;
 s*=s;
 s*=s;

 float3 n=normalize(float3(x2-x1,y2-y1,s/8.0f))/2+0.5;

 return float4(n,1);
}