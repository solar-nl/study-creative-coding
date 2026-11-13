// Render Technique: Colored Texture (uv, offset anim)
// Type: Material
// GUID: 8186E44C83B8493DDD4E7E6462EF1BEC
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • Texture (Texture0, Variable)
//   • Color (Color, Variable)
//   • Cullmode (CullMode, Variable)
//   • Zmode (ZMode, Variable)
//   • BlendMode (BlendMode0, Variable)
//   • AlphaTest (Float, Variable)
//   • Render Priority (RenderPriority, Variable)
//   • uv offset x (Float, Animated)
//   • uv offset y (Float, Animated)
//   • uv2 offset x (Float, Animated)
//   • uv2 offset y (Float, Animated)
//   • Scaled X offset (Float, Animated)
//   • Scaled Y offset (Float, Animated)
//   • Scaled Z offset (Float, Animated)
//   • Scaled Normal offset (Float, Animated)
//   • Deform Texture (Texture1, Variable)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
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
	float4 color;
	float4 alphatest;
	float4 uvoffsets;
	float normaloffset;
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

	float2 uv2Off = x.UV.zw + float2(alphatest.w,uvoffsets.x);
	float scale = t_1.SampleLevel(Sampler,uv2Off,0).x;
	
	k.p=mul(worldmat,float4(x.Position + (scale*(1-x.Color.x))*(uvoffsets.yzw + normalize(x.Normal) * normaloffset),1)).xyz;
	k.Position=mul(projmat,mul(viewmat,float4(k.p,1)));

	k.uv=x.UV.xy + alphatest.yz;
	k.Normal=0;
	return k;
}

float4 p(VSOUT v) : SV_TARGET0
{
    float4 t=t_0.Sample(Sampler,v.uv.xy);
    if (alphatest.x>t.a*255/256.0) discard;
    return t*color;
}

