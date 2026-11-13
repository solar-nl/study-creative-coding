// Texture Generator: Palette
// GUID: 46BA05677674B159E87978EF31E0007F
// Parameters:
//   [3] Control Channel (ZFunction)
//   [0] Palette Line (Float)
//   [1] Selected Channel For All (Color)

SamplerState cm:register(s0);
SamplerState sm:register(s1);
Texture2D Textur:register(t0);
Texture2D DataMap1:register(t1);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
    int ch=(int)(data1.x*256);
	if (data1.z==0)
	{
    	float c=Textur.Sample(sm,t)[ch];
    	return DataMap1.Sample(sm,float2(c,data1.y));
	}

	float4 c=Textur.Sample(cm,t);
	float4 r;
	r.x=DataMap1.SampleLevel(sm,float2(c.x,data1.y),0)[ch];
	r.y=DataMap1.SampleLevel(sm,float2(c.y,data1.y),0)[ch];
	r.z=DataMap1.SampleLevel(sm,float2(c.z,data1.y),0)[ch];
	r.w=DataMap1.SampleLevel(sm,float2(c.w,data1.y),0)[ch];
	return r;
}