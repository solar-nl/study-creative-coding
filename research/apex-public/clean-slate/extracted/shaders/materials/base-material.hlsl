// Render Technique: [Base Material]
// Type: Material
// GUID: 2EC2AE23E3AA634D2FD7277D3C18D797
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: Solid Pass
//   • Texture (Texture0, Variable)
//   • Envmap (Texture1, Variable)
//   • NormalMap (Texture2, Variable)
//   • Specular Color (Color, Variable)
//   • Specular (Float, Variable)
//   • Invert Normals (Float, Variable)
//   • Culling (CullMode, Variable)
//   • ZMode (ZMode, Variable)
//   • Render Priority (RenderPriority, Variable)
//   • Blending (BlendMode0, Variable)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
Texture2D t_2:register(t2);
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
	float4 specularcolor;
	float4 specularpower;
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
	k.Normal=mul(itworldmat,float4(x.Normal,0)).xyz;
	k.Position=mul(projmat,mul(viewmat,float4(k.p,1)));
	k.uv=x.UV.xy;
	return k;
}

float4 getenvmap(VSOUT v)
{
	float3 r=reflect(normalize(mul(viewmat,float4(v.p,1)).xyz),
                     normalize(mul(viewmat,float4(v.Normal,0)).xyz));
	float m = 2.0 * sqrt( r.x*r.x + r.y*r.y + (r.z+1.0)*(r.z+1.0) );
	float2 env=r.xy/m+0.5;
	return t_1.Sample(Sampler,env);
}

float3 calculatespecular(float3 po, float3 n, float3 lightdir)
{	//blinn-phong
    float3 H=normalize(-normalize(po)+normalize(lightdir));
	//float3 incoming=reflect(lightdir,H);

	return pow(saturate(dot(normalize(n),H)),40);
}

void GetLightData( lightdata l, float3 pos, out float3 dir, out float distance, inout float spotcutoff)
{
	if (l.pos.w)
	{
		dir=l.pos.xyz-pos;
		distance=length(dir);
		dir/=distance;
		if (l.sda.y)
		{
			spotcutoff=dot(-l.spotdirection.xyz,dir);
			spotcutoff=(spotcutoff-l.sda.y)/(1-l.sda.y);
			if (spotcutoff>0)
				spotcutoff=pow(abs(saturate(spotcutoff)),l.sda.x);
			else spotcutoff=0;
		}
	}
	else
	{
		dir=normalize(l.pos.xyz);
		distance=1;
	}	
}

float3 lighting(float3 diff, float3 pos, float3 normal)
{
	float3 result=0;
	for (int x=0; x<lightcount[0]; x++)
	{
		lightdata l=lights[x];
		float3 dir;
		float dist;
		float spotcutoff=1;
		GetLightData(l,pos,dir,dist,spotcutoff);
    	float3 H=normalize(-normalize(pos-campos.xyz)+dir.xyz);

		float3 ambient=l.ambient.xyz;
		float3 diffuse=l.diffuse.xyz*saturate(dot(dir,normal))*spotcutoff;
		float3 specular=l.specular.xyz*spotcutoff*
						pow(saturate(dot(normal,H)),1/(specularpower.x+0.000001));
		float att=1+dist*(l.sda.z+l.sda.w*l.sda.w);

		result+=(diff*ambient+diff*diffuse+specular*specularcolor.xyz)/att;
	}
	return result;
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

struct PSOUT
{
	float4 c:SV_TARGET0;
	float4 am:SV_TARGET1;
	float4 nr:SV_TARGET2;
};

PSOUT p(VSOUT v)
{ 
	float normmult=1;
	if (specularpower.y>0.5) normmult=-1;

	float4 tc=t_0.Sample(Sampler,v.uv.xy);
	float4 normalMap=t_2.Sample(Sampler,v.uv.xy);

	float3 normal=perturb_normal(normalize(v.Normal)*normmult,v.p,v.uv.xy,normalMap.xyz);
	
	float3 env=getenvmap(v).xyz;
	
	PSOUT p;
	p.c.xyz=lighting(tc.xyz+env,v.p,normal);
	p.c.w=tc.w;
	p.am=tc;
	p.nr=float4(normal,0);
	
	return p;
}

