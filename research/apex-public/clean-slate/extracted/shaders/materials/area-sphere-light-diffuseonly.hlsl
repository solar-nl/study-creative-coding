// Render Technique: [Area] Sphere Light diffuseOnly
// Type: Material
// GUID: 9644C93D8CDBDB4A456B25B09E6F73B8
// Target Layer: Lighting Layer

// ======================================================================
// Pass 1: Sphere Light LTC
//   • Blending (BlendMode0, Constant)
//   • Culling (CullMode, Constant)
//   • Albedo and Metalness (Texture0, Constant)
//   • Normal and Roughness (Texture1, Constant)
//   • Depth (DepthTexture7, Constant)
//   • New Parameter (ZMode, Constant)
//   • red (Float, Animated)
//   • green (Float, Animated)
//   • blue (Float, Animated)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
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

VSOUT v(VSIN x)
{
	VSOUT k;	
	k.Position=float4(x.Position.xzy*2,1);
	k.uv=x.UV.xy;
	return k;
}

#define PI 3.14159265

float4 p(VSOUT v) : SV_TARGET0
{ 
	int3 pixel=int3(v.Position.xy,0);
	float4 t0 = t_0.Load(pixel);
	float3 t1 = t_1.Load(pixel).xyz;
	float  depth = t_7.Load(pixel).x;
	
	// get world position from depth
	float4 P=mul(iviewmat, mul(iprojmat, float4(v.uv*2-1,depth,1)));
	P/=P.w;
	float3 V = normalize(campos.xyz-P);

	// data from normal map
	float3 N = normalize(t1);
	
	// basic calculations
	float NdotV = dot(N, V);
	
	float4x4 i = transpose(itworldmat);

	// do lighting
	float3 p = mul(i,P);
	float d = length(p);
	float3 nd = p/d;
	float scale = d/sqrt(4*d*d-1);

	float3 y=float3(0,-1,0);
	float3 nx=normalize(cross(-nd,y));
	
    float3 T1 = normalize(V - N * NdotV);
    float3 T2 = cross(N, T1);
    float3x3 Minv = float3x3(T1, T2, N);

    float3 L[64];
	int   n = 0;
	
    float c=dot(nd,y);
	float s=sqrt(1-c*c);
    float t=1-c;
    float x=nx.x;
    float z=nx.z;

	float3 current;
    float sum=0;
	
	for (int xx=0; xx<=12; xx++)
	{
		float r = xx*PI/6;

		float3 next = mul(Minv, mul(worldmat,float4(mul(float3x3(t*x*x+c,-s*z,t*x*z,s*z,c,-s*x,t*x*z,s*x,t*z*z+c),float3(cos(r),0,sin(r))*scale),1))-P);
		if (xx>0)
		{
		if (current.z>0)
			L[n++]=normalize(current);
		
		if ((current.z>0)!=(next.z>0))
			L[n++]=normalize(lerp(current,next, -current.z/(next.z-current.z) ));
		}		
		current=next;
	}
	
	
	// data from albedo map	
	float3 albedo   = t0.xyz;
	float metallic  = t0.w;
	
	// integrate edges
	for (int c=0; c<n; c++)
	{
		float3 v1 = L[c];
		float3 v2 = L[(c+1)%n];
		
	    float x = dot(v1, v2);
	    float y = abs(x);
	
    	float a = 0.8543985 + (0.4965155 + 0.0145206*y)*y;
    	float b = 3.4175940 + (4.1616724 + y)*y;
    	float v = a / b;

    	float theta_sintheta = (x > 0) ? v : 0.5/sqrt(max(1 - x*x, .0000001)) - v;
    	sum -= cross(v1, v2).z * albedo * (1 - metallic) * theta_sintheta;
	}

	return sum*color;
}

