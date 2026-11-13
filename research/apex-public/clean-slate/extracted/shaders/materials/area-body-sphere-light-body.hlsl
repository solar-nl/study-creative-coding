// Render Technique: [Area body] Sphere Light Body
// Type: Material
// GUID: C276B9A01961CCA3210802EC0B5E022F
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: Sphere Light Body
//   • Blending (BlendMode0, Constant)
//   • Culling (CullMode, Constant)
//   • New Parameter (ZMode, Constant)
//   • New Parameter (ZFunction, Constant)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
Texture2D t_2:register(t2);
Texture2D t_3:register(t3);
Texture2D t_4:register(t4);
Texture2D t_7:register(t7);
SamplerState Sampler:register(s1);

struct lightdata
{
	float4 pos;
	float4 ambient;
	float4 diffuse;
	float4 specular;
	float4 spotdirection;
	float4 sda;
};

cbuffer b : register(b0)
{
	float4x4 viewmat;
	float4x4 projmat;
	float4 campos;
	float4 lightcount;
	lightdata lights[8];
	float4 res;
	float4x4 iviewmat;
	float4x4 iprojmat;
}

cbuffer c : register(b1)
{
	float4x4 worldmat;
	float4x4 itworldmat;
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
	float2 uv:TEXCOORD0;
};

VSOUT v(VSIN x)
{
	VSOUT k;	
	k.Position=float4(x.Position.xzy*2,1);
	k.uv=x.UV.xy;
	return k;
}

float3 getWorldPos(float depth, float2 uv)
{
	float4 a=mul(iviewmat,mul(iprojmat, float4(uv*2-1,depth,1)));
	return a.xyz/a.w;	
}

#define PI 3.14159265

float p(VSOUT v):SV_DEPTH
{ 
	float4x4 i=transpose(itworldmat);
	float3 cp=-mul(i,float4(campos.xyz,1)).xyz;
	float3 pos=mul(i,float4(getWorldPos(1,v.uv),1)).xyz;
	float3 d=normalize(pos-cp);
	float b=dot(cp,d);
	float c=dot(cp,cp)-0.25;
	float discr = b*b-c;
	if (discr<0)
	  discard;
	
	float t=-b+sqrt(discr);
	float3 p=-cp.xyz-d*t;
	float4 vp = mul(projmat,mul(viewmat,mul(worldmat,float4(p,1))));
	
	return vp.z/vp.w;
}

