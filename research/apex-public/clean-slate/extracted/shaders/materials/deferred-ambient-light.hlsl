// Render Technique: Deferred Ambient Light
// Type: Material
// GUID: 07D72FA094C9ACA3EA268BA044F3E496
// Target Layer: Lighting Layer

// ======================================================================
// Pass 1: Sphere Light
//   • Blending (BlendMode0, Constant)
//   • Culling (CullMode, Constant)
//   • Albedo and Metalness (Texture0, Constant)
//   • Normal and Roughness (Texture1, Constant)
//   • Depth (DepthTexture7, Constant)
//   • Light Color (Color, Animated)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
Texture2D t_2:register(t7);
SamplerState Sampler:register(s0);

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
	float4 lightColor;
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
	float4 pos:TEXCOORD1;
};

VSOUT v(VSIN x)
{
	VSOUT k;	
	k.Position=float4(x.Position.xzy*2,1);
	k.pos.xyz=transpose(worldmat)[3].xyz;
	k.pos.w=length(mul(worldmat,float4(0,1,0,0)));
	k.uv=x.UV.xy;
	return k;
}

float3 getWorldPos(float depth, float2 uv)
{
	float4 a=mul(iviewmat,mul(iprojmat, float4(uv*2-1,depth,1)));
	return a.xyz/a.w;	
}

#define PI 3.14159265

float3 fresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}  

float3 DiffuseIBL(float3 N, float3 V, float3 F0, float3 albedo, float metallic)
{
	float3 H = normalize(V + N);
    float3 F = fresnelSchlick(max(dot(H, V), 0.0), F0);       
	return (1 - F) * (1.0 - metallic)*lightColor.xyz*albedo/PI;
}

float4 p(VSOUT v) : SV_TARGET0
{ 
	float4 albedo=t_0.Load(int3(v.Position.xy,0));
	float4 normal=t_1.Load(int3(v.Position.xy,0));
	float depth=t_2.Load(int3(v.Position.xy,0)).x;

	float roughness = normal.w;
	float metallic = albedo.w;
	
	float3 N=normalize(normal.xyz);
	float3 V=normalize(campos.xyz-getWorldPos(depth,v.uv));
	
	float3 F0 = 0.04;
    F0 = lerp(F0, albedo.xyz, metallic);
	
	return float4(DiffuseIBL(N,V,F0,albedo.xyz,metallic),1); 
}

