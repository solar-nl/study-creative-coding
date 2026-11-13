// Render Technique: Shadow Pass with UV Offset
// Type: Material
// GUID: D67B791119C88E4EAA4A95A10267E430
// Target Layer: Shadow Layer

// ======================================================================
// Pass 1: Shadow Pass
//   • Shadowmap Alphatest Texture (Texture0, Variable)
//   • Invert Normals (Float, Variable)
//   • ZMode (ZMode, Variable)
//   • Shadowmap Culling (CullMode, Variable)
//   • ShadowMap Alpha Test Cutoff (Float, Animated)
//   • Shadow UV 2 Offset X (Float, Animated)
//   • Shadow UV 2 Offset Y (Float, Animated)
//   • Shadow Scaled X offset (Float, Animated)
//   • Shadow Scaled Y offset (Float, Animated)
//   • Shadow Scaled Z offset (Float, Animated)
//   • Shadow Scaled Normal offset (Float, Animated)
//   • Shadow Deform Texture (Texture1, Variable)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
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
}

cbuffer c : register(b1)
{
	float4x4 worldmat;
	float4x4 itworldmat;
	float4 data;
	float4 scale;
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
	float3 p:TEXCOORD2;
};

float4x4 buildLightMatrix( float3 eye, float3 dir)
{
	float3 z = normalize(dir);
	float3 x = normalize(cross(float3(0,1,0), z));
	float3 y = cross(z, x);

	float4x4 viewmat=float4x4(x.x,y.x,z.x,0,
	                          x.y,y.y,z.y,0,
	                          x.z,y.z,z.z,0,
	                          -dot(x,eye), -dot(y,eye), -dot(z,eye),1);
	return transpose(viewmat);
}

float4x4 buildOrthoMatrix( float w, float h, float r )
{
	float zf=100;
	float zn=0;
	float4x4 orthomat=float4x4(2/w,0,0,0,
	                           0,2/h,0,0,
	                           0,0,1/(zn-zf),0,
	                           0,0,-zn/(zn-zf),1);
	return transpose(orthomat);
}

VSOUT v(VSIN x)
{
	VSOUT k;
	
	float4x4 lm=buildLightMatrix(lights[0].spotdirection.xyz,lights[0].pos.xyz);
	float4x4 om=buildOrthoMatrix(lights[0].ambient.w,lights[0].diffuse.w,0);

	float2 uv2Off = x.UV.zw + data.zw;
	float scaleV = t_1.SampleLevel(Sampler,uv2Off,0).x;

	float3 uvoffset = scale.xyz;
	k.p=mul(worldmat,float4(x.Position  + (scaleV*(1-x.Color.x))*(uvoffset + normalize(x.Normal) * scale.w),1)).xyz;

	//k.p=mul(worldmat,float4(x.Position,1)).xyz;
	k.Position=mul(om,mul(lm,float4(k.p,1)));
	k.p=k.Position.xyz/k.Position.w;
	k.uv=x.UV.xy;

	return k;
}

float4 p(VSOUT v) : SV_TARGET0
{ 
	float4 tc=t_0.Sample(Sampler,v.uv.xy);
	
	if (data.y<tc.a) discard;
	
	//float4x4 lm=buildLightMatrix(lights[0].spotdirection.xyz,float3(1,0,0)+lights[0].pos.xyz,1,1,0);
	
	//float4 p=mul(lm,float4(0,0,-1,1));
	
	return float2(v.p.z,v.p.z*v.p.z).xyxy;//lights[0].spotdirection.z;// -p.xyzx;// lights[0].pos;// abs(lights[0].pos.xyzx)*1000;
}

