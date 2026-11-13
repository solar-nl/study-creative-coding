// Render Technique: SSAO
// Type: ShaderToy
// GUID: EA40B8D85658316A8334200753B031EA
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: New Pass
//   • output (RenderTarget, Constant)
//   • depth (DepthTexture7, Constant)
//   • Normal and Roughness (Texture0, Constant)
//   • BlendMode (BlendMode0, Variable)
//   • power (Float, Variable)
//   • Samples (Float, Variable)
//   • Diameter (Float, Variable)
//   • bias (Float, Variable)
//   • MaxDistance (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D nz:register(t0);
Texture2D depthtex:register(t7);

cbuffer b : register(b0)
{
	float tme,aspect,xres,yres;
	float4x4 viewmat;
	float4x4 projmat;
	float4 campos;
	float4x4 iviewmat;
	float4x4 iprojmat;
}

cbuffer c : register(b1)
{
	float4 dat;
	float4 dat2;
}

#define MAX_DISTANCE 0.07

float hash12(float2 p)
{
	float3 p3  = frac(float3(p.xyx) * float3(.1031,.11369,.13787));
    p3 += dot(p3, p3.yzx + 19.19);
    return frac((p3.x + p3.y) * p3.z);
}

float3 getPosition(float depth, float2 uv)
{
	float4 a=mul(iprojmat, float4(uv*2-1,depth,1));
 	return a.xyz/a.w;
}

float3 getPosition(int2 uv)
{
	float4 a=mul(iprojmat, float4(uv/float2(xres,yres)*2-1,depthtex.Load(int3(uv,0)).x,1));
 	return a.xyz/a.w;
}


float4 p( float2 t:TEXCOORD0, float4 p:SV_POSITION ) : SV_TARGET0
{ 
	float4 dt=nz.Load(int3(p.xy,0));
	float3 n = normalize(mul(transpose(iviewmat),float4(dt.xyz,0)).xyz);
	n.y*=-1;
	
	float3 pos = getPosition(p.xy);

    float ao = 0.;
    float radius = 0.;

    float rotatePhase = hash12( p.xy*100. ) * 6.28;
    float rStep = dat.z*0.2/dat.y/255;

    for (int i = 0; i < dat.y*255; i++) 
	{
    	float2 spiralUV = float2(sin(rotatePhase),cos(rotatePhase));
        radius += rStep;
    	float3 diff = getPosition(p.xy + (spiralUV * radius)*float2(xres,yres)) - pos;
    	float l = length(diff);
    	float3 v = diff/l;
    	ao += max(0.0,dot(n,v)-dat.w)*(1.0/(1.0+l)) * smoothstep(dat2.x,dat2.x * 0.5, l);
        rotatePhase += 2.4; //goldenangle
    }
    ao /= dat.y*255;
	
	return saturate(1-ao*dat.x);
}

