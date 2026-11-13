// Render Technique: Depth of Field
// Type: ShaderToy
// GUID: D1D027627A83342BB02D6FA59A20960B
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: Calculate Coc
//   • Output (RenderTarget, Constant)
//   • Color (Texture0, Constant)
//   • Focal Distance (Float, Animated)
//   • Focal Length (Float, Animated)
//   • Aperture (Float, Animated)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Color:register(t0);
Texture2D z:register(t7);

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
	float4 blurdat;
	float4 camdat;
}

float getLinearDepth(float2 uv)
{
	float depth=z.Sample(sm,uv).x;
	float4 a=mul(iprojmat, float4(uv*2-1,depth,1));
 	return -a.z/a.w;
}

float getcoc(float2 t)
{
	float S1=camdat.x*10; //focal distance
	float f=camdat.y/10; //focal length
	float A=camdat.z/5; //0.024; //aperture size
	
	float S2=getLinearDepth(t);// Normalz.Sample(sm,t).x;
	float c=A*abs((S2-S1))/S2*(f/(S1-f));
	float percent=c/0.024;
	return clamp(percent,0.0001,0.12)*0.3;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 col=Color.Sample(sm,t);
	col.w=getcoc(t);
	//col.xyz*=col.w;
	return col;
}

// ======================================================================
// Pass 2: Pass 1
//   • Color (Texture0, Constant)
//   • Output (RenderTarget, Constant)
// ======================================================================

SamplerState i:register(s1);Texture2D w:register(t0),D:register(t7);cbuffer b:register(b0){float tt,T,tf,to;float4x4 te,ta;float4 tl;float4x4 tr,z;}cbuffer c:register(b1){float4 y;}float b(float2 u){float4 r=mul(z,float4(u*2-1,D.Sample(i,u).x,1));return -r.z/r.w;}float2 u(float2 r){float a=2*r.x-1,o=2*r.y-1,e=o,t=3.1415/4*(a/o)+3.1415/2;if(a*a>o*o){e=a;t=3.1415/4*(o/a);}if(0){float l=6;t+=.1;e*=cos(3.1415/l)/cos(t-2*3.1415/l*floor((l*t+3.1415)/(2*3.1415)));t-=.1;}return float2(cos(t)/T,sin(t))*e;}float4 r(float2 a){float o=y.y/10.,e=y.x*255.,t=b(a),l=0;float4 m=w.Sample(i,a),S=0;for (int x=0;x<8;x++){for (int c=0;c<8;c++){float2 s=a+u((float2(x,c)+.5)/8.)*m.a;float4 n=w.Sample(i,s);float f=b(s)<t?n.a*e:1;f=((m.a>n.a+o)?f:1);f=saturate(f);if(length(saturate(s))!=length(s))f=0;S+=n*f;l+=f;}}return S/l;}float4 p(float2 o:texcoord0):sv_target0{return r(o);}

// ======================================================================
// Pass 3: Pass 2
//   • Color (Texture0, Constant)
//   • Output (RenderTarget, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Color:register(t0);
Texture2D z:register(t7);

cbuffer b : register(b0)
{
	float t,aspect,xres,yres;
	float4x4 viewmat;
	float4x4 projmat;
	float4 campos;
	float4x4 iviewmat;
	float4x4 iprojmat;
}

cbuffer c : register(b1)
{
	float4 blurdat;
}

float getLinearDepth(float2 uv)
{
	float depth=z.Sample(sm,uv).x;
	float4 a=mul(iprojmat, float4(uv*2-1,depth,1));
 	return -a.z/a.w;
}

float4 dof(float2 t)
{
	float bleedbias=blurdat.y/10.0f;//0.02f;
	float bleedmult=blurdat.x*255.0f;//30.0f;
	float4 centerpix=Color.Sample(sm,t);
	float centerdepth=getLinearDepth(t);
	
	float4 color=0;
	float totweight=0;
	
	for (int x=0; x<3; x++)
	for (int y=0; y<3; y++)
	{
		float2 off=float2(x-1,y-1)*0.085;
		float2 coord=t+off*centerpix.a;
		float4 samplepix=Color.Sample(sm,coord);
		float sampledepth=getLinearDepth(coord);
		float weight=sampledepth<centerdepth?samplepix.a*bleedmult:1;
		weight=(centerpix.a>samplepix.a+bleedbias)?weight:1;
		weight=saturate(weight);
		color+=samplepix*weight;
		totweight+=weight;
	}
	
	return color/totweight;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 c=dof(t);
	//c.xyz/=c.w;
	return c;
}

