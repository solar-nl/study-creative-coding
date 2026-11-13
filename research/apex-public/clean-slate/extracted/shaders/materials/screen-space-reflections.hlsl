// Render Technique: Screen Space Reflections
// Type: ShaderToy
// GUID: 06E5B7DE9F0382EAFD6DBF26ED1B30C9
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • Screen Buffer (Texture0, Variable)
//   • NormalZ Buffer (Texture1, Variable)
//   • Output (RenderTarget, Variable)
//   • Radius (Float, Variable)
//   • Steps (Float, Variable)
//   • Background extra (Float, Variable)
//   • Accept Bias (Float, Variable)
//   • Radius Multiplier (Float, Variable)
// ======================================================================

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D nz:register(t1);
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
	float radmult;
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
	//return getScreenCoord(p.xy).xyxy;
	
	float4 background=Textur.Load(int3(p.xy,0));
	if (background.w<=0) return background*(1+dat.z);
	//return 1;
	//return pow(depthtex.Load(int3(p.xy,0)).x,10);

	float4 dt=nz.Load(int3(p.xy,0));
	float4 normal = mul(transpose(iviewmat),float4(dt.xyz,0));
	//normal/=normal.w;
	normal.y*=-1;
	//return normal.xyzx*0.5+0.5;

	float3 vpos=getPosition(p.xy);
	//return vpos.x;
	//vpos.z*=-1;
	float3 reflected = reflect(normalize(vpos), normalize(normal.xyz));
	//return normalize(reflected.xy).x*0.5+0.5;// vpos.z*100;//reflected.xyzx;// normalize(reflected.xy).x;
	//return normal.z;// (vpos.z*200);
	//return vpos.x;// reflected.x;// xyxy*0.5+0.5;//+background*float4(0.2,0,0,0);//yzx;// vpos.xyzx;
	//return reflected.xyzx*0.5+0.5;

	float RADIUS=dat.x*64*radmult;
	float STEPS=dat.y*255;
	
//#define RADIUS 8.0
//#define STEPS 32.0
//#define ATTENUATE 16

	float3 reflected_start=reflected;
	float3 vpos_start=vpos;
	reflected*=RADIUS/(float)STEPS;
	//return reflected.y;//xyzx;

	float2 scr;
	float4 view_projected;

	for (int i=0;i<STEPS;i++)
	{
		vpos+=reflected;
		view_projected=mul(projmat,float4(vpos,1)); 
		view_projected.xyz/=view_projected.w;
		scr=view_projected.xy*0.5+0.5;
		//return background+Textur.SampleLevel(sm, scr, 0);
		float depth2 = depthtex.Load(int3(scr*float2(xres,yres),0)).x;

		float3 vpos_target = getPosition(scr*float2(xres,yres)); 
		if (length(vpos_target-vpos)<(RADIUS/(float)STEPS+dat.w*0.1))
		{
			if (depth2<view_projected.z)
			{
				vpos-=reflected;
				reflected*=0.5;  
			}
		}

	}

//	float3 normal_target = normalTextureMS.Load(int3(scr*RESOLUTION.xy,0)).xyz;

	float2 fadeout_2=saturate(abs(view_projected.xy));
	float fs=saturate(1-length(fadeout_2));// 
	//fs=1-max(fadeout_2.x, fadeout_2.y);
	//return fs==0;
	//return fs*10;
	//fs=3*fs*fs-2*fs*fs*fs;
	float fadeout_z=saturate(view_projected.z);
	float fadeout_radius=1.0-saturate(pow(length(vpos_start-vpos)/RADIUS, 16)); //16 is ATTENUATE
	//return length(vpos_start-vpos)/RADIUS/10;

	//float fadeout_normal=pow(saturate(-dot(normal_target, reflected_start)), 0.3);

	float fadeout=min(min(fs, fadeout_z), fadeout_radius);
	//return fadeout==0;
	float4 reflection=Textur.SampleLevel(sm, scr, dt.w*16);
	//return reflection;
	//return reflection*fadeout;
	
	//return background+fadeout;// fadeout*float4(1,20,1,1);
	
    return background+reflection*fadeout*background.w*(1-dt.w);//mask.z;
}

