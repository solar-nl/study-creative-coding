// Render Technique: [PBR Pure Deferred]
// Type: Material
// GUID: DD2ED55A6A7511D4AE7A47FC3A9561F4
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: Solid Pass
//   • Albedo Map (alpha is Metalness) (Texture0, Variable)
//   • Normal Map (Alpha is Roughness) (Texture1, Variable)
//   • Roughness Modifier (Float, Variable)
//   • Metalness Modifier (Float, Variable)
//   • Invert Normals (Float, Variable)
//   • Culling (CullMode, Variable)
//   • ZMode (ZMode, Constant)
//   • Render Priority (RenderPriority, Variable)
//   • Blending (BlendMode0, Constant)
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
	float4 data;
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
	float4 uv:TEXCOORD0;
	float3 p:TEXCOORD2;
};

VSOUT v(VSIN x)
{
	VSOUT k;
	
	k.p=mul(worldmat,float4(x.Position,1)).xyz;
	k.Normal=mul(itworldmat,float4(x.Normal,0)).xyz;
	k.Position=mul(projmat,mul(viewmat,float4(k.p,1)));
	k.uv=x.UV;
	return k;
}

float3 perturb_normal(float3 N, float3 p, float2 uv, float3 map)
{
    float3 dp1 = ddx( p );
    float3 dp2 = ddy( p );
    float2 duv1 = ddx( uv );
    float2 duv2 = ddy( uv );
 
    // solve the linear system
    float3 dp2perp = cross( dp2, N );
    float3 dp1perp = cross( N, dp1 );
    float3 T = dp2perp * duv1.x + dp1perp * duv2.x;
    float3 B = dp2perp * duv1.y + dp1perp * duv2.y;
 
    // construct a scale-invariant frame 
    float invmax = rsqrt( max( dot(T,T), dot(B,B) ) );

	float3x3 tangentFrame=float3x3( T * invmax, B * invmax, N );
	
	if (dot(map,map)==0) map=float3(0.5,0.5,1); //hack to fix not selected texture
	
	map=map*2-1;

	return normalize( mul( map, tangentFrame ) );
}

float ApplyModifier( float value, float modifier )
{
	if (modifier<=127/255.0)
		return value*modifier/(127/255.0);
	else
		return lerp(value,1,(modifier-127/255.0)/(128/255.0));	
}

struct PSOUT
{
	float4 am:SV_TARGET1;
	float4 nr:SV_TARGET2;
};

PSOUT p(VSOUT v)
{
	float normmult=1;
	if (data.z>0.5) normmult=-1;

	float4 albedo=t_0.Sample(Sampler,v.uv.xy);
	float4 normalMap=t_1.Sample(Sampler,v.uv.xy);

	float3 normal=perturb_normal(normalize(v.Normal)*normmult,v.p,v.uv.xy, normalMap.xyz);
	albedo.w=ApplyModifier(albedo.w,data.y);
	
	PSOUT p;
	p.nr=float4(normal,ApplyModifier(normalMap.w,data.x));
	p.am=albedo;
	return p;
}

