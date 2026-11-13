// Texture Generator: Noise
// GUID: 95663E90B7E22F94ADF911ADF81B82DF
// Parameters:
//   [0] Minimum (Float)
//   [0] Maximum (Float)
//   [0] Blend (Float)
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

float4 p( float2 tt:TEXCOORD0 ) : SV_TARGET0
{
 float Min=data1.x*255-1;
 float Max=data1.y*255;

 int PassCnt=PassData.x+0.5-Min;

 float s=1/(pow(2.0f,PassData.x+2));
 float Noise=PassCnt?pow(abs(data1.z),PassCnt):1;

 float2 t=tt;
 float2 tpart=t%s;
 t-=tpart;
 tpart/=s;

 if (data1.w==0)
   tpart*=tpart*(3-2*tpart);

 float2 t4=frac(t+s);
 float4 nx,ny;

 nx=lerp(GetNoise(t),GetNoise(float2(t4.x,t.y)),tpart.x);
 ny=lerp(GetNoise(float2(t.x,t4.y)),GetNoise(t4),tpart.x);

 float4 n=(lerp(nx,ny,tpart.y)-0.5f)*Noise;

 if (PassCnt>0)
  n+=Textur.Sample(sm,tt);
 else n+=0.5f;

 if (PassData.x+0.5>Max) n=Textur.Sample(sm,tt);

 return n;
}