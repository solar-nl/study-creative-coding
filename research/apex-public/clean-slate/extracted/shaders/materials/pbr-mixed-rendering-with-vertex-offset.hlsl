// Render Technique: [PBR Mixed Rendering with vertex offset]
// Type: Material
// GUID: AECBA6264493E2316649DA3F4DF38344
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: Solid Pass
//   • Albedo Map (alpha is Metalness) (Texture0, Variable)
//   • Normal Map (Alpha is Roughness) (Texture1, Variable)
//   • Emissive Map (Alpha is alpha) (Texture2, Variable)
//   • Roughness Modifier (Float, Variable)
//   • Metalness Modifier (Float, Variable)
//   • two sided rendering (Float, Variable)
//   • Culling (CullMode, Variable)
//   • ZMode (ZMode, Constant)
//   • Render Priority (RenderPriority, Variable)
//   • Blending (BlendMode0, Constant)
//   • AlphaTest Cutoff (Float, Animated)
//   • Shadowmap (Texture3, Constant)
//   • Shadow Bias (Float, Variable)
//   • Shadow Softness (Float, Variable)
//   • UV Offset X (Float, Animated)
//   • uv offset Y (Float, Animated)
//   • uv2 offset x (Float, Animated)
//   • uv2 offset Y (Float, Animated)
//   • Scaled X offset (Float, Animated)
//   • Scaled Y offset (Float, Animated)
//   • Scaled Z offset (Float, Animated)
//   • Scaled Normal offset (Float, Animated)
//   • Deform Texture (Texture4, Variable)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
Texture2D t_2:register(t2);
Texture2D t_3:register(t3);
Texture2D t_4:register(t4);
SamplerState Sampler:register(s0);
SamplerComparisonState Sampler3:register(s2);

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
	float4 dat;
	float4 shd;
	float4 scale1;
	float4 scale2;
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
	float3 lp:TEXCOORD3;
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

	float2 uv2Off = x.UV.zw + scale1.xy;
	float scale = t_4.SampleLevel(Sampler,uv2Off,0).x;

	float3 uvoffset = float3(scale1.zw,scale2.x);
	k.p=mul(worldmat,float4(x.Position+ (scale*(1-x.Color.x))*(uvoffset + normalize(x.Normal) * scale2.y),1)).xyz;
	k.Normal=mul(itworldmat,float4(x.Normal,0)).xyz;
	k.Position=mul(projmat,mul(viewmat,float4(k.p,1)));
	k.uv=x.UV;

	float4x4 lm=buildLightMatrix(lights[0].spotdirection.xyz,lights[0].pos.xyz);
	float4x4 om=buildOrthoMatrix(lights[0].ambient.w,lights[0].diffuse.w,0);
	
	float4 lp=mul(om,mul(lm,float4(k.p,1)));
	lp/=lp.w;
	k.lp=lp.xyz;
	k.lp.y*=-1;
	k.lp.xy=k.lp.xy*0.5+0.5;

	return k;
}

/*struct GSOUT
{
	float4 Position : SV_POSITION;
	float2 UV : TEXCOORD0;
};*/

[maxvertexcount(6)]
void g(triangle VSOUT input[3], inout TriangleStream<VSOUT> OutputStream)
{
	float3 normal = cross(normalize(input[2].p-input[0].p),normalize(input[1].p-input[0].p));
	
	for (int x=0; x<3; x++)
	{
		VSOUT v=input[x];
		v.Normal=normal;
		OutputStream.Append(v);
	}
	
	OutputStream.RestartStrip();	
	
	if (dat.z>0.5) 
	{
		for (int x=2; x>=0; x--)
		{
			VSOUT v=input[x];
			v.Normal=-normal;
	  		OutputStream.Append(v);
		}
		OutputStream.RestartStrip();
	}
	
}


#define PI 3.14159265

float3 fresnelSchlick(float cosTheta, float3 F0)
{
    return F0 + (1.0 - F0) * pow(1.0 - cosTheta, 5.0);
}  

float GeometrySchlickGGX(float NdotV, float roughness)
{
    float r = (roughness + 1.0);
    float k = (r*r) / 8.0;

    float num   = NdotV;
    float denom = NdotV * (1.0 - k) + k;
	
    return num / denom;
}

float GeometrySmith(float3 N, float3 V, float3 L, float roughness)
{
    float NdotV = max(dot(N, V), 0.0);
    float NdotL = max(dot(N, L), 0.0);
    float ggx2  = GeometrySchlickGGX(NdotV, roughness);
    float ggx1  = GeometrySchlickGGX(NdotL, roughness);
	
    return ggx1 * ggx2;
}

float DistributionGGX(float3 N, float3 H, float roughness)
{
    float a      = roughness*roughness;
    float a2     = a*a;
    float NdotH  = max(dot(N, H), 0.0);
    float NdotH2 = NdotH*NdotH;
	
    float num   = a2;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
	
    return num / denom;
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
	float4 c:SV_TARGET0;
	float4 am:SV_TARGET1;
	float4 nr:SV_TARGET2;
};

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

float VSM(float2 TexBase, float LightCompare, float shdw)
{
	float shadow=0;

	for (int x=0; x<5; x++)
		for (int y=0; y<5; y++)
			shadow+=t_3.SampleCmpLevelZero(Sampler3, TexBase+float2(x-2,y-2)*0.02*shdw, LightCompare);
	
	return shadow/25.0f;
}

float VSM2(float3 LightMap, float bias, float shdw)
{
	return VSM(LightMap.xy, LightMap.z - 0.01*(bias-0.5), shdw);//saturate((max(VSM(LightMap.xy, LightMap.z - 0.01*(windoffset.x-0.5)), 0.0)-0.0)/1.0);
}

PSOUT CalcLight(VSOUT v, float4 albedo, float4 normalMap, float4 emissiveMap, float4 data, float4 shdw)
{
	if (shdw.y<emissiveMap.w)
	  discard;

	float3 N=perturb_normal(normalize(v.Normal),v.p,v.uv.xy, normalMap.xyz);
	float3 V=normalize(campos.xyz-v.p);
	
	float3 F0 = 0.04;
	float metallic=ApplyModifier(albedo.w,data.y);
	float roughness=ApplyModifier(normalMap.w,data.x);
    F0 = lerp(F0, albedo.xyz, metallic);

	float shadow=1;
	if ( (lights[0].ambient.w*lights[0].diffuse.w)>0.01)
	 shadow=VSM2(v.lp.xyz,data.w,shdw.x);

	
	float3 Lo = emissiveMap.xyz;
    for(int i = 0; i < lightcount[0]; ++i)
    {
		lightdata l=lights[i];
		float3 L;
		float distance;
		float spotcutoff=1;
		GetLightData(l,v.p,L,distance,spotcutoff);

		// calculate per-light radiance
        float3 H = normalize(V + L);
        //float distance    = length(l.pos.xyz - v.p);
        float attenuation = 1.0 / (distance * distance);
        float3 radiance     = l.diffuse.xyz * attenuation * spotcutoff;
        
        // cook-torrance brdf
        float NDF = DistributionGGX(N, H, roughness);        
        float G   = GeometrySmith(N, V, L, roughness);      
        float3 F  = fresnelSchlick(max(dot(H, V), 0.0), F0);       
        
        float3 kS = F;
        float3 kD = 1 - kS;
        kD *= 1.0 - metallic;	  
        
        float3 numerator    = NDF * G * F;
        float denominator = 4.0 * max(dot(N, V), 0.0) * max(dot(N, L), 0.0);
        float3 specular     = numerator / max(denominator, 0.001);  
            
        // add to outgoing radiance Lo
        float NdotL = max(dot(N, L), 0.0);  
		if ( i == 0 )
		  NdotL *= shadow;              
        Lo += (kD * albedo.xyz / PI + specular) * radiance * NdotL; 
    }   
  
	PSOUT p;
	p.c=float4(Lo, 1.0);
	p.nr=float4(N,roughness);
	p.am=float4(albedo.xyz,metallic);
	
	return p;
}

PSOUT p(VSOUT v)
{
	float2 uv = v.uv.xy+shd.zw;
	
	float4 albedo=t_0.Sample(Sampler,uv);
	float4 normalMap=t_1.Sample(Sampler,uv);
	float4 emissiveMap=t_2.Sample(Sampler,uv);

	return CalcLight(v,albedo,normalMap,emissiveMap,dat,shd);	
}

