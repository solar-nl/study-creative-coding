// Render Technique: PointSprites
// Type: Material
// GUID: DF3B04D3DDCB67A835408CE58B6BA679
// Target Layer: Transparent Layer

// ======================================================================
// Pass 1: New Pass
//   • Cullmode (CullMode, Constant)
//   • BlendMode (BlendMode0, Variable)
//   • ZMode (ZMode, Variable)
//   • Texture (Texture0, Variable)
//   • Color (Color, Variable)
//   • Sprite Size (Float, Variable)
//   • Sprite offset (Float, Variable)
// ======================================================================

Texture2D t_0:register(t0);
SamplerState Sampler:register(s0);

cbuffer b : register(b0)
{
	float4x4 viewmat;
	float4x4 projmat;
}

cbuffer c : register(b1)
{
	float4x4 worldmat;
	float4x4 itworldmat;
	float4 color;
	float scale;
	float offset;
}

struct VSIN
{
	float3 Position : POSITION0;
	float3 Position2: POSITION1;
	float3 Normal : NORMAL0;
	float4 Color : COLOR0;
	float4 UV : TEXCOORD0;
	float4 UV2: TEXCOORD1;
};

struct VSOUT
{
	float4 Position : SV_POSITION;
};

float4 v(VSIN x) : SV_POSITION
{
	return mul(viewmat,float4(mul(worldmat,float4(x.Position,1)).xyz,1));
}

struct GSOUT
{
	float4 Position : SV_POSITION;
	float2 UV : TEXCOORD0;
};

[maxvertexcount(4)]
void g(triangle VSOUT input[3], inout TriangleStream<GSOUT> OutputStream)
{
	float4 p=(input[0].Position+input[1].Position+input[2].Position)/3.0f;
	float3 a=normalize(input[0].Position.xyz-input[1].Position.xyz);
	float3 b=normalize(input[2].Position.xyz-input[1].Position.xyz);
	float3 n=cross(a,b);
	p+=float4(n,0)*offset;

	GSOUT vx[4];

	vx[0].Position=mul(projmat,p+float4(-1,-1,0,0)*scale);
	vx[0].UV=float2(0,0);
	vx[1].Position=mul(projmat,p+float4(1,-1,0,0)*scale);
	vx[1].UV=float2(1,0);
	vx[2].Position=mul(projmat,p+float4(1,1,0,0)*scale);
	vx[2].UV=float2(1,1);
	vx[3].Position=mul(projmat,p+float4(-1,1,0,0)*scale);
	vx[3].UV=float2(0,1);

	OutputStream.Append(vx[3]);
	OutputStream.Append(vx[0]);
	OutputStream.Append(vx[2]);
	OutputStream.Append(vx[1]);

	OutputStream.RestartStrip();	
}

float4 p(GSOUT v) : SV_TARGET0
{
	return t_0.Sample(Sampler,v.UV.xy)*color;
}

