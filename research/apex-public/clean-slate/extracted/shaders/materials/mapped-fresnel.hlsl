// Render Technique: Mapped Fresnel
// Type: Material
// GUID: 07BB59072BA1AB798DC667BE9DB88EEF
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • Cullmode (CullMode, Variable)
//   • Zmode (ZMode, Variable)
//   • BlendMode (BlendMode0, Variable)
//   • Render Priority (RenderPriority, Variable)
//   • red1 (Float, Animated)
//   • green1 (Float, Animated)
//   • blue1 (Float, Animated)
//   • red2 (Float, Animated)
//   • green2 (Float, Animated)
//   • blue2 (Float, Animated)
//   • exponent (Float, Animated)
// ======================================================================

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
	float4 color1;
	float4 color2;
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
	float3 Normal: TEXCOORD1;
	float2 uv:TEXCOORD0;
	float3 p:TEXCOORD2;
};

VSOUT v(VSIN x)
{
	VSOUT k;

	k.p=mul(worldmat,float4(x.Position,1)).xyz;
	k.Position=mul(projmat,mul(viewmat,float4(k.p,1)));

	k.uv=x.UV.xy;
	k.Normal=mul(worldmat,float4(x.Normal,0)).xyz;
	return k;
}

float4 p(VSOUT v):SV_TARGET0
{
	float t = saturate(dot(-normalize(v.p-campos.xyz),normalize(v.Normal.xyz)));
	float3 c1=color1.xyz;
	float3 c2=float3(color1.w,color2.xy);
    return float4(lerp(c1,c2,pow(t,color2.z)),1);
}

