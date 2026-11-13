// Render Technique: [Area] Sphere Light Non-LTC
// Type: Material
// GUID: CE7BDB55E5BE9F75DDF4B6C46E6F5E32
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

struct FGBufferData
{
	float3 WorldNormal;
	float3 DiffuseColor;
	float3 SpecularColor;
	float Roughness;
};

float Square( float x )
{
	return x*x;
}

struct BxDFContext
{
	float NoV;
	float NoL;
	float VoL;
	float NoH;
	float VoH;
};

float Pow4( float x )
{
	float xx = x*x;
	return xx * xx;
}

float Pow5( float x )
{
	float xx = x*x;
	return xx * xx * x;
}

float EnergyNormalization( inout float a2, float VoH, float	SinAlpha )
{
	float Sphere_a2 = a2;
	float Energy = 1;
	Sphere_a2 = a2 + 0.25 * SinAlpha * (3.0 * sqrt(a2) + SinAlpha) / ( VoH + 0.001 );
	Energy = a2 / Sphere_a2;

	return Energy;
}

float D_GGX( float a2, float NoH )
{
	float d = ( NoH * a2 - NoH ) * NoH + 1;
	return a2 / ( 3.14159265*d*d );
}

float3 F_Schlick( float3 SpecularColor, float VoH )
{
	float Fc = Pow5( 1 - VoH );
	return saturate( 50.0 * SpecularColor.g ) * Fc + (1 - Fc) * SpecularColor;	
}

float Vis_SmithJointApprox( float a2, float NoV, float NoL )
{
	float a = sqrt(a2);
	float Vis_SmithV = NoL * ( NoV * ( 1 - a ) + a );
	float Vis_SmithL = NoV * ( NoL * ( 1 - a ) + a );
	return 0.5 * rcp( Vis_SmithV + Vis_SmithL );
}

float3 SpecularGGX( float Roughness, float3 SpecularColor, BxDFContext Context, float NoL, float SphereSinAlpha )
{
	float a2 = Pow4( Roughness );
	float Energy = EnergyNormalization( a2, Context.VoH, SphereSinAlpha );
	float D = D_GGX( a2, Context.NoH ) * Energy;
	float Vis = Vis_SmithJointApprox( a2, Context.NoV, NoL );
	float3 F = F_Schlick( SpecularColor, Context.VoH );
	return (D * Vis) * F;
}

float SphereHorizonCosWrap( float NoL, float SinAlphaSqr )
{
	float SinAlpha = sqrt( SinAlphaSqr );

	if( NoL < SinAlpha )
	{
		NoL = max( NoL, -SinAlpha );
		// Accurate sphere irradiance
		float CosBeta = NoL;
		float SinBeta = sqrt( 1 - CosBeta * CosBeta );
		float TanBeta = SinBeta / CosBeta;

		float x = sqrt( 1 / SinAlphaSqr - 1 );
		float y = -x / TanBeta;
		float z = SinBeta * sqrt(1 - y*y);

		NoL = NoL * acos(y) - x * z + atan( z / x ) / SinAlphaSqr;
		NoL /= 3.14152965;
	}
	return saturate( NoL );
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
	float4 t0 = t_0.Load(int3(v.Position.xy,0));
	float4 t1 = t_1.Load(int3(v.Position.xy,0));
	float   d = t_7.Load(int3(v.Position.xy,0)).x;

	float4 ap=mul(iviewmat, mul(iprojmat, float4(v.uv*2-1,d,1)));
	float3 P = ap.xyz/ap.w;
	float3 V = normalize(campos.xyz-P);
	float3 N = normalize(t1.xyz);
	
	float4 lightColor = float4( color.xyz, 1);

	// draw light body
	if (any(isnan(N)))
	{
		float4x4 i = transpose(itworldmat);
		float3 opp = mul(i,float4(P,1)).xyz;
		if ( length(opp-normalize(opp)*0.5)<0.01 )
			return lightColor;
		return 0;		
	}/**/

	FGBufferData GBuffer;

	GBuffer.WorldNormal = N;
	GBuffer.DiffuseColor = t0.xyz*(1-t0.w);
	GBuffer.SpecularColor = lerp(0.04, t0.xyz, t0.w);
	GBuffer.Roughness = t1.w;
	
	float lightRadius = length(mul(worldmat,float4(0.5,0,0,0)).xyz); 
	
	float3 diffuse=0;
	float3 specular=0;

	float3 ToLight = mul(worldmat,float4(0,0,0,1)).xyz - P;
	
	float DistSqr = dot( ToLight, ToLight );
	float Falloff = rcp( DistSqr + 1 );

	float SinAlphaSqr = saturate( Square( lightRadius ) * Falloff );
	float NoL =  dot( N, ToLight * rsqrt( DistSqr ) );

	NoL = SphereHorizonCosWrap( NoL, SinAlphaSqr );

	float InvDist = rsqrt( DistSqr );
	float3 L = ToLight * InvDist;
	
	GBuffer.Roughness = max( GBuffer.Roughness, 0.001 ); // 0.001 = min roughness
	float a = Square( GBuffer.Roughness );
    
	float SinAlpha = saturate( lightRadius * InvDist * (1 - a) );
	
	BxDFContext Context;

	Context.NoL = dot(N, L);
	Context.NoV = dot(N, V);
	Context.VoL = dot(V, L);
	float InvLenH = rsqrt( 2 + 2 * Context.VoL );
	Context.NoH = saturate( ( Context.NoL + Context.NoV ) * InvLenH );
	Context.VoH = saturate( InvLenH + InvLenH * Context.VoL );

	if( SinAlpha > 0 )
	{
		float CosAlpha = sqrt( 1 - Square( SinAlpha ) );
	
		float RoL = 2 * Context.NoL * Context.NoV - Context.VoL;
		if( RoL >= CosAlpha )
		{
			Context.NoH = 1;
			Context.VoH = abs( Context.NoV );
		}
		else
		{
			float rInvLengthT = SinAlpha * rsqrt( 1 - RoL*RoL );
			float NoTr = rInvLengthT * ( Context.NoV - RoL * Context.NoL );
			float VoTr = rInvLengthT * ( 2 * Context.NoV*Context.NoV - 1 - RoL * Context.VoL );

			/*
			//if (bNewtonIteration)
			//{
				// dot( cross(N,L), V )
				float NxLoV = sqrt( saturate( 1 - Square(Context.NoL) - Square(Context.NoV) - Square(Context.VoL) + 2 * Context.NoL * Context.NoV * Context.VoL ) );

				float NoBr = rInvLengthT * NxLoV;
				float VoBr = rInvLengthT * NxLoV * 2 * Context.NoV;

				float NoLVTr = Context.NoL * CosAlpha + Context.NoV + NoTr;
				float VoLVTr = Context.VoL * CosAlpha + 1   + VoTr;

				float p = NoBr   * VoLVTr;
				float q = NoLVTr * VoLVTr;
				float s = VoBr   * NoLVTr;

				float xNum = q * ( -0.5 * p + 0.25 * VoBr * NoLVTr );
				float xDenom = p*p + s * (s - 2*p) + NoLVTr * ( (Context.NoL * CosAlpha + Context.NoV) * Square(VoLVTr) + q * (-0.5 * (VoLVTr + Context.VoL * CosAlpha) - 0.5) );
				float TwoX1 = 2 * xNum / ( Square(xDenom) + Square(xNum) );
				float SinTheta = TwoX1 * xDenom;
				float CosTheta = 1.0 - TwoX1 * xNum;
				NoTr = CosTheta * NoTr + SinTheta * NoBr;
				VoTr = CosTheta * VoTr + SinTheta * VoBr;
			//}/**/

			Context.NoL = Context.NoL * CosAlpha + NoTr;
			Context.VoL = Context.VoL * CosAlpha + VoTr;

			float InvLenH = rsqrt( 2 + 2 * Context.VoL );
			Context.NoH = saturate( ( Context.NoL + Context.NoV ) * InvLenH );
			Context.VoH = saturate( InvLenH + InvLenH * Context.VoL );
		}
	}

	Context.NoV = saturate(abs( Context.NoV ) + 0.000001);

	float3 diffuseResult = (Falloff * NoL) * GBuffer.DiffuseColor / 3.14159265;
	float3 specularResult = (Falloff * NoL) * SpecularGGX(GBuffer.Roughness, GBuffer.SpecularColor, Context, NoL, SinAlpha);

	return float4((diffuseResult+specularResult)*sqrt(lightRadius)*color.xyz,1);
}

