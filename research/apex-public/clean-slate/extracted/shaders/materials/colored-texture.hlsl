// Render Technique: Colored Texture
// Type: Material
// GUID: E29A95A4D3FD630C418CF73778137606
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • Texture (Texture0, Variable)
//   • Color (Color, Animated)
//   • Cullmode (CullMode, Variable)
//   • Zmode (ZMode, Variable)
//   • BlendMode (BlendMode0, Variable)
//   • AlphaTest (Float, Variable)
//   • Render Priority (RenderPriority, Variable)
//   • New Parameter (Float, Constant)
//   • New Parameter (Float, Constant)
//   • New Parameter (Float, Constant)
// ======================================================================

Texture2D t_0:register(t0);
SamplerState Sampler:register(s0);

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
	float alphatest;
	float4 color;
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
	k.Normal=0;
	return k;
}

float4 p(VSOUT v):SV_TARGET0
{
    float4 t=t_0.Sample(Sampler,v.uv.xy);
    if (alphatest>t.a*255/256.0) discard;
    return t*color;
}

