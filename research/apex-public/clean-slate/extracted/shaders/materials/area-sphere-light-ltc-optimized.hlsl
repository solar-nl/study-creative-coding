// Render Technique: [Area] Sphere Light LTC optimized
// Type: Material
// GUID: 607E4CAC87BF43864809510E0726D2E5
// Target Layer: Lighting Layer

// ======================================================================
// Pass 1: Sphere Light Optim LTC
//   • Blending (BlendMode0, Constant)
//   • Culling (CullMode, Constant)
//   • Albedo and Metalness (Texture0, Constant)
//   • Normal and Roughness (Texture1, Constant)
//   • Depth (DepthTexture7, Constant)
//   • Red (Float, Animated)
//   • Green (Float, Animated)
//   • Blue (Float, Animated)
//   • New Parameter (LTC1, Constant)
//   • New Parameter (LTC2, Constant)
//   • New Parameter (ZMode, Constant)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
Texture2D ltc1:register(t4);
Texture2D ltc2:register(t5);
Texture2D t_7:register(t7);
SamplerState Sampler:register(s2);

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
	float2 uv:TEXCOORD0;
};


struct LightingContext
{
	float3 albedo,P,V,N,f0,R;
	float  roughness,metallic;	
	float  NdotV, NdotL;
};

inline LightingContext InitLighting(int2 pixel, float2 uv)
{
	float4 t0 = t_0.Load(int3(pixel,0));
	float4 t1 = t_1.Load(int3(pixel,0));
	float   d = t_7.Load(int3(pixel,0)).x;
	
	LightingContext l;
	
	// get world position from depth
	float4 a=mul(iviewmat, mul(iprojmat, float4(uv*2-1,d,1)));
	l.P = a.xyz/a.w;
	l.V = normalize(campos.xyz-l.P);

	// data from albedo map	
	l.albedo    = t0.xyz;
	l.metallic  = t0.w;
	
	// data from normal map
	l.N = normalize(t1.xyz);
	l.roughness = t1.w;
	
	// fix normals if needed, this can possibly be omitted
	float t = dot(l.N, l.V);
	if ( t < 0 )
		l.N = normalize(l.N-1.01*l.V*t);
	
	// basic calculations
	l.NdotV = dot(l.N, l.V);
    l.f0    = lerp(0.04, l.albedo, l.metallic);
	l.R     = reflect(l.V,l.N);
	return l;
}

struct LTCCommon
{
	float3 diffuseModifier;
	float3 specularModifier;
	float3x3 ltcMatrixDiffuse;
	float3x3 ltcMatrixSpecular;
};

LTCCommon InitLTC(LightingContext l)
{
	LTCCommon c;

	float2 ltcUV = float2(l.roughness, sqrt(1 - l.NdotV)) * 15./16 + 1./32;
    float4 t1 = ltc1.Sample(Sampler,ltcUV);
    float2 t2 = ltc2.Sample(Sampler,ltcUV).xy;
	
    float3 T1 = normalize(l.V - l.N * l.NdotV);
    float3 T2 = cross(l.N, T1);
    c.ltcMatrixDiffuse = float3x3(T1, T2, l.N);	
	
	float3x3 minv =float3x3(t1.x, 0, t1.z,
	                           0, 1,    0,
	                        t1.y, 0, t1.w);
    c.ltcMatrixSpecular = mul(minv, c.ltcMatrixDiffuse);
	
	c.specularModifier = lerp(t2.y,t2.x, l.f0);
	c.diffuseModifier  = l.albedo * (1 - l.metallic);

	return c;
}

// yeah these are ugly but making these global makes LTC_Evaluate reusable
static uint vertexCount;
static float3 points[64]; // light body points converted to P space (world space orientation with P as its origin)

float LTC_Evaluate(LightingContext l, float3x3 Minv, bool twoSided)
{
    float3 L[64];
	uint   n = 0;
	
	for (uint x=0; x<vertexCount; x++)
	{
		float3 current= mul(Minv, points[x]);
		float3 next   = mul(Minv, points[(x+1)%vertexCount]);
		
		if (current.z>0)
			L[n++]=normalize(current);
		
		if ((current.z>0)!=(next.z>0))
			L[n++]=normalize(lerp(current,next, -current.z/(next.z-current.z) ));
	}
    
    float sum=0;
	
	// integrate edges
	for (uint i=0; i<n; i++)
	{
		float3 v1 = L[i];
		float3 v2 = L[(i+1)%n];
		
	    float x = dot(v1, v2);
	    float y = abs(x);
	
    	float a = 0.8543985 + (0.4965155 + 0.0145206*y)*y;
    	float b = 3.4175940 + (4.1616724 + y)*y;
    	float v = a / b;

    	float theta_sintheta = (x > 0) ? v : 0.5/sqrt(max(1 - x*x, .0000001)) - v;
    	sum += (cross(v1, v2)*theta_sintheta).z;
	}

    return twoSided ? abs(sum) : max(0, -sum);
}

float4x4 AngleAxis3x3(float cosval, float3 axis) // axis y is forced to 0!
{
    float c=cosval;
	float s=sqrt(1-c*c);
    float t=1-c;
    float x=axis.x;
    float z=axis.z;
    return float4x4(t*x*x+c,-s*z,t*x*z,0,s*z,c,-s*x,0,t*x*z,s*x,t*z*z+c,0,0,0,0,1);
}

VSOUT v(VSIN x)
{
	VSOUT k;	
	k.Position=float4(x.Position.xzy*2,1);
	k.uv=x.UV.xy;
	return k;
}

float4 p(VSOUT v) : SV_TARGET0
{ 
	float4 lightColor = float4( color.xyz, 1);
	LightingContext l = InitLighting(v.Position.xy, v.uv);
	
	float4x4 i = transpose(itworldmat);

	// draw light body
	if (any(isnan(l.N)))
	{
		float3 opp = mul(i,float4(l.P,1)).xyz;
		if ( length(opp-normalize(opp)*0.5)<0.01 )
			return lightColor;
		return 0;		
	}

	// do lighting
	vertexCount = 8;
	float3 p = mul(i,float4(l.P,1)).xyz;
	float3 r = mul(i,float4(l.R,0)).xyz;
	float3 nd = normalize(p);
	float d = length(p);
	float scale = d/sqrt(4*d*d-1);

	float3 y=float3(0,-1,0);
	float3 nx=normalize(cross(-nd,y));
	float4x4 discrotmat=AngleAxis3x3(dot(nd,y),nx);
	float4x4 ir=transpose(discrotmat);
	
	p=mul(ir,float4(p,1)).xyz;
	r=mul(ir,float4(r,0)).xyz;
	
	r=p-r*p.y/r.y; // plane-ray intersection for plane n=(0,1,0)
	p.y=0; // project to y=0
	
	float3 it=lerp(r,p,l.roughness);
	float addRot=-atan2(it.x,it.z);
	
	for (uint x=0; x<vertexCount; x++)
	{
		float r = radians(360)*x/vertexCount+ addRot;
		points[x]=mul(worldmat,float4(mul(discrotmat,float4(cos(r),0,sin(r),0)*scale).xyz,1)).xyz-l.P;
	}

	LTCCommon c = InitLTC(l);
	float3 diff = LTC_Evaluate(l, c.ltcMatrixDiffuse,  true) * c.diffuseModifier;
    float3 spec = LTC_Evaluate(l, c.ltcMatrixSpecular, true) * c.specularModifier;
	
	return lightColor * float4(spec+diff, 1);
}

