// Render Technique: Default Particle
// Type: Particle
// GUID: D9BCB25B70726C223C6F5F322777287C
// Target Layer: Transparent Layer

// ======================================================================
// Pass 1: Particle pass
//   • Culling (CullMode, Constant)
//   • Z mode (ZMode, Variable)
//   • Blending (BlendMode0, Variable)
//   • Texture (Texture1, Variable)
//   • Red (ParticleLifeFloat, Animated)
//   • Green (ParticleLifeFloat, Animated)
//   • Blue (ParticleLifeFloat, Animated)
//   • Alpha (ParticleLifeFloat, Animated)
//   • Size (ParticleLifeFloat, Animated)
//   • Red Chaos (ParticleLifeFloat, Animated)
//   • Green Chaos (ParticleLifeFloat, Animated)
//   • Blue Chaos (ParticleLifeFloat, Animated)
//   • Alpha Chaos (ParticleLifeFloat, Animated)
//   • Size Chaos (ParticleLifeFloat, Animated)
//   • alphatest (ParticleLifeFloat, Animated)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
SamplerState Sampler:register(s0);
SamplerState Smp:register(s1);

cbuffer b : register(b0)
{
	float4x4 viewmat;
	float4x4 projmat;
	float4 campos;
}

cbuffer c : register(b1)
{
	float4x4 worldmat;
	float4x4 itworldmat;
	float4 color;
	float alphatest;
}

struct VSIN
{
	float4 Position : POSITION0;
	float4 Data : TEXCOORD0;
};

struct VSOUT
{
	float4 Position : SV_POSITION;
	float4 Color:TEXCOORD0;
	float4 Data:TEXCOORD1;
	float4 Size:TEXCOORD2;
	float AlphaTest:TEXCOORD3;
};

struct GSOUT
{
	float4 Position : SV_POSITION;
	float2 UV : TEXCOORD0;
	float4 Data:TEXCOORD1;
	float4 Color:TEXCOORD2;
	float AlphaTest:TEXCOORD3;
};

[maxvertexcount(4)]
void g(point VSOUT input[1], inout TriangleStream<GSOUT> OutputStream)
{
	float4 p=input[0].Position;
	float4 scale=0.1*input[0].Size.x;
	float r=0.1*input[0].Data.y;
	float4 x=float4(sin(r),cos(r),0,0);
	float4 y=float4(-x.y,x.x,0,0);

	GSOUT vx[4];

	vx[0].Position=mul(projmat,p+(-x-y)*scale);
	vx[0].UV=float2(1,1);
	vx[1].Position=mul(projmat,p+(x-y)*scale);
	vx[1].UV=float2(1,0);
	vx[2].Position=mul(projmat,p+(x+y)*scale);
	vx[2].UV=float2(0,0);
	vx[3].Position=mul(projmat,p+(-x+y)*scale);
	vx[3].UV=float2(0,1);
	
	for (int i=0; i<4; i++)
	{
	vx[i].Data=input[0].Data;
	vx[i].Color=input[0].Color;
	vx[i].AlphaTest=input[0].AlphaTest;
	}

	OutputStream.Append(vx[3]);
	OutputStream.Append(vx[0]);
	OutputStream.Append(vx[2]);
	OutputStream.Append(vx[1]);

	OutputStream.RestartStrip();	
}

float pdata(int id, float l)
{
	float t = 1-l;
	float a = t_0.Load(int3(trunc(t*2048),id,0)).x;
	float b = t_0.Load(int3(trunc(t*2048)+1,id,0)).x;
	return lerp(a,b, frac(t*2048) );
}

float GetNoise(float tin)
{
 return frac(sin(tin*54.37)*17593.1317);
}

float pdatachaos(int id, int cid, float c, float l)
{
	return pdata(id,l)+pdata(cid,l)*GetNoise(c+cid);
}

VSOUT v(VSIN x)
{
	VSOUT k;

	k.Position=mul(viewmat,x.Position);

	k.Data=x.Data;
	k.Color.x=pdatachaos(0,5,x.Data.z,x.Data.x);
	k.Color.y=pdatachaos(1,6,x.Data.z,x.Data.x);
	k.Color.z=pdatachaos(2,7,x.Data.z,x.Data.x);
	k.Color.w=pdatachaos(3,8,x.Data.z,x.Data.x);
	k.Size=pdatachaos(4,9,x.Data.z,x.Data.x);
	k.AlphaTest=pdata(10,x.Data.x);
	return k;
}

float4 p(GSOUT v) : SV_TARGET0
{
	//return v.AlphaTest;
	float4 t = t_1.Sample(Sampler,v.UV);
	if (t.w<v.AlphaTest)
		discard;
	return v.Color*t;// v.UV.xyxy;
}

