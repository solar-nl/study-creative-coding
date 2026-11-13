// Texture Generator: Cells
// GUID: FB2A9ECDEE6E163BDFBBF7B84FE4DF16
// Parameters:
//   [0] Iterations (Float)
//   [0] Power (Float)
//   [0] Size (Float)
//   [1] Manhattan (Color)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D noise:register(t1);
float4 PassData:register(c0);
float4 data1:register(c1);

float le(float2 l)
{
 float k=abs(l.x)+abs(l.y);
 if (!data1.w) k=length(l);
 return k;
}

float4 GetNoise(float2 tin)
{
 return noise.Load((int3(fmod(tin*256+512,256),0)));
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float4 n=PassData.yzwy;

 float2 j=(t.xy-GetNoise(n.yz).xy);
 float l=le(frac(j)-0.5)*2/data1.y/sqrt(2)/((n.z+0.2)*data1.z*10+1);
 if (PassData.x)
 {
  float2 x=t+n.xy;
  float2 y=t+n.zw;

  float d=Textur.Sample(sm,x).x;
  float k=Textur.Sample(sm,y).x;
  l=min(l,min(d,k));
 }
 if (PassData.x+0.5>=(data1.x)*255) l=Textur.Sample(sm,t).x;

 return l;
}