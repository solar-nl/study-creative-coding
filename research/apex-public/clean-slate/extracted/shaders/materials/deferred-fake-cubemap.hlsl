// Render Technique: Deferred Fake Cubemap
// Type: Material
// GUID: 168625FA5DABA54CC9795DAE67349F4E
// Target Layer: Lighting Layer

// ======================================================================
// Pass 1: Sphere Light
//   • Blending (BlendMode0, Constant)
//   • Culling (CullMode, Constant)
//   • Albedo and Metalness (Texture0, Constant)
//   • Normal and Roughness (Texture1, Constant)
//   • Depth (DepthTexture7, Constant)
//   • Envmap Sides (non-cube) (Texture2, Variable)
//   • Envmap Top (Texture3, Variable)
//   • Envmap Bottom (Texture4, Variable)
// ======================================================================

Texture2D t_0:register(t0);
Texture2D t_1:register(t1);
Texture2D t_2:register(t2);
Texture2D t_3:register(t3);
Texture2D t_4:register(t4);
Texture2D t_7:register(t7);
SamplerState Sampler:register(s1);

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

float radicalInverse_VdC(uint bits) {
     bits = (bits << 16u) | (bits >> 16u);
     bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
     bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
     bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
     bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
     return float(bits) * 2.3283064365386963e-10; // / 0x100000000
 }

float2 DeCube( float3 v2 )
{
	float3 absUV = abs(v2);
	float maxAxis=max(max(absUV.x,absUV.y),absUV.z);
	float2 uvc=v2.zy;
	if ( maxAxis==absUV.y ) uvc=v2.xz;
	if ( maxAxis==absUV.z ) uvc=v2.xy;
	return 0.5*(uvc/maxAxis+1);
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

float sqr(in float x)
{
    return x * x;
}

float D_ggx(in float alpha, in float NoH)
{
    float a2 = alpha*alpha;
    float cos2 = NoH*NoH;

    return (1.0f/PI) * sqr(alpha/(cos2 * (a2 - 1) + 1));
}

float4 p(VSOUT v) : SV_TARGET0
{ 
	float4 albedo=t_0.Load(int3(v.Position.xy,0));
	float4 normal=t_1.Load(int3(v.Position.xy,0));
	float depth=t_7.Load(int3(v.Position.xy,0)).x;

	float Roughness = normal.w;
	float metallic = albedo.w;
	
	float3 N=normalize(normal.xyz);
	float3 V=normalize(campos.xyz-getWorldPos(depth,v.uv));
	
	float3 F0 = lerp(0.04, albedo, metallic);
	
	float3 H = normalize(V + N);
    float3 F  = fresnelSchlick(max(dot(H, V), 0.0), F0);       
	
    float3 kD = (1 - F)*(1-metallic);
	
	int NumSamples = 32;
	
	float3 UpVector = abs(N.z) < 0.999 ? float3(0,0,1) : float3(1,0,0);
	
	float3 X=normalize(cross(N,UpVector));
	float3 Y=normalize(cross(X,N));
	float3x3 mat=float3x3(X,Y,N);
	
	float3 light = 0;
	
	for( int i = 0; i < NumSamples; i++ )
	{
		float uv = radicalInverse_VdC(i);
		float phi = uv * 2.0 * PI;
		float cosTheta = 1.0 - i/32.;
		float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
		float3 v = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);

		float3 v2=mul(v,mat);
		light+=t_2.SampleLevel( Sampler , DeCube(v2), 8 ).rgb/NumSamples*kD*albedo/PI;
	}
	
	int w,h;
	t_2.GetDimensions(w, h);
	NumSamples = 64;
	float NoV = saturate( dot( N, V ) )+0.0001;
	
	for( int ii = 0; ii < NumSamples; ii++ )
	{
		float Xi = radicalInverse_VdC(ii);

		float Phi = PI * ii/32.;
		float CosTheta = sqrt( (1 - Xi) / ( 1 + (Roughness * Roughness * Roughness * Roughness - 1) * Xi ) );
		float SinTheta = sqrt( 1 - CosTheta * CosTheta );
		float3 H = mul(float3( SinTheta * cos( Phi ), SinTheta * sin( Phi ), CosTheta),mat);

		float3 L = 2 * dot( V, H ) * H - V;
		float NoL = saturate( dot( N, L ) );
		float NoH = saturate( dot( N, H ) );
		float VoH = saturate( dot( V, H ) );

		float fPdf = D_ggx(Roughness,NoH) * NoH / (4.0f * VoH);
		float fOmegaS = 1.0 / (NumSamples * fPdf);
		float fOmegaP = 4.0 * PI / (6.0 * w * h);
       	float mipLevel = max(0.5 * log2(fOmegaS / fOmegaP), 0.0f);
		if (Roughness==0)
		 mipLevel=0;

		float3 SampleColor = t_2.SampleLevel( Sampler , DeCube(L), mipLevel ).rgb;

		float3 absUV = abs(L);
		float maxAxis=max(max(absUV.x,absUV.y),absUV.z);
		if ( maxAxis==absUV.y )
			SampleColor = L.y>0 ? t_3.SampleLevel( Sampler , DeCube(L), mipLevel ) : t_4.SampleLevel( Sampler , DeCube(L), mipLevel );
			
		float G = GeometrySmith( N, V, L, Roughness );
		float Fc = pow( 1 - VoH, 5 );
		float3 F = (1 - Fc) * F0 + Fc;
		if( NoL > 0 )
			light += SampleColor * F * G * VoH / (NoH * NoV)/NumSamples;
	}
	
	return float4(light,1);
}

