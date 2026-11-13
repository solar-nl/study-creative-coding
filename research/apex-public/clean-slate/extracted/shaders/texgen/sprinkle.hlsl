// Texture Generator: Sprinkle
// GUID: 2715D5D2B1AF57A28976C8784BEB3FB3
// Parameters:
//   [0] Quantity (Float)
//   [0] Minimum Size (Float)
//   [0] Maximum Size (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D noise:register(t1);
float4 PassData:register(c0);
float4 data1:register(c1);

float4 GetNoise(float2 tin)
{
	return noise.Load(int3(fmod(tin*256*(max(1,PassData.x)*(1+PassData.y)),256),0));
}

float2 GetUV(float2 t, float4 r)
{
	float s = lerp(data1.y,data1.z,r.z);
	
	float sf = sin(r.w*6);
	float cf = cos(r.w*6);
	float2 t2 = (t-r.xy)/s;
	t2=float2(t2.x*cf-t2.y*sf,t2.y*cf+t2.x*sf);
	
	return saturate(t2+0.5);
}

float4 p( float2 tt:TEXCOORD0 ) : SV_TARGET0
{
	float4 r = 0;
	
	for (int x=0; x<data1.x*255; x++)
	{
	  for (int a=0; a<3; a++)
	   for (int b=0; b<3; b++)
		{
		float2 t=GetUV(tt+float2(a,b)-1,GetNoise(x/255.));
		float4 v=Textur.Sample(sm,t);
        r = lerp(r,v,v.a);
		}
	}
	
	return r;
}