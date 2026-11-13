// Texture Generator: SubPlasma
// GUID: 2578CABBE41C0B2F486AE25D11F88423
// Parameters:
//   [0] Density (Float)
//   [1] Linear (Color)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D noise:register(t1);
float4 PassData:register(c0);
float4 data1:register(c1);

float4 GetNoise(float2 tin)
{
	return noise.Load(int3(fmod(tin*256*(max(1,PassData.x)*(1+PassData.y)),256),0));
}

float4 CatmullRom(float4 v0, float4 v1, float4 v2, float4 v3, float t)
{ 
 float4 P = (v3 - v2) - (v0 - v1);
 float4 Q = (v0 - v1) - P;
 float4 R =  v2 - v0;
 float4 r = (((P*t)+Q)*t+R)*t + v1;
 return r;
}

float4 p( float2 tt:TEXCOORD0 ) : SV_TARGET0
{
 float Step=1/(pow(2.0f,data1.x*255.0f+1));

 float2 t=tt;
 float2 tpart=t%Step;
 t=(t-tpart);

 float4 n=GetNoise(t);

 if (PassData.x>0)
 {
  float2 s=float2(Step,0);
  if (PassData.x+0.5>=2) s=float2(0,Step);
  float4 v[4];
  for (int x=0; x<4; x++)
   v[x]=Textur.Sample(sm,tt+s*x);

  float k=tpart.x;
  if (PassData.x+0.5>=2) k=tpart.y;
  
  if (!(data1.y>0))
  	n=CatmullRom(v[0],v[1],v[2],v[3],k/Step);
  else n=lerp(v[1],v[2],k/Step);
 }

 return n;
}