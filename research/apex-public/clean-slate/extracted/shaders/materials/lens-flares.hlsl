// Render Technique: Lens flares
// Type: ShaderToy
// GUID: 8999DDE3452C69EFEFCF4902E1EB5D39
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • RenderTarget (RenderTarget, Constant)
//   • Texture (Texture0, Variable)
//   • Threshold (Float, Variable)
//   • Zoom (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect;
}

cbuffer c : register(b1)
{
	float blursize,threshold,zoom;
	float4 color;
}

float disc(float2 t)
{
	float x = saturate(1.0f - dot(t, t));
	return x * x;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 	
	float distances[8] = {0.5f, 0.7f, 1.03f, 1.35, 1.55f, 1.62f, 2.2f, 3.9f};
	float rgbScalesGhost[3] = {1.01f, 1.00f, 0.99f};
	float rgbScalesHalo[3] = {0.98f, 1.00f, 1.02f};
	
	float2 dir = 0.5f - t;
	
	float4 ret=0;

	for (int rgb = 0; rgb < 3; rgb++)
	{
	    for (int i = 0; i < 8; i++)
    	{
        	float2 uv = t + dir*distances[i]*rgbScalesGhost[rgb]*zoom*2;
        	float4 colour = Textur.Sample(sm, uv);
			float lum=dot(colour.xyz,float3(0.299,0.587,0.114));
			colour*=lum>threshold*4;
			//r+=c*disc(sp/scale);*/

			ret[rgb] += saturate(colour[rgb] - 0.5f) * 1.5f*disc((uv-0.5)*2);
    	}
    	float2 fixedDir = dir;
    	fixedDir.y /= aspect;
	    float2 normDir = normalize(fixedDir);
    	normDir *= 0.4f * (rgbScalesHalo[rgb]);
    	normDir.y *= aspect; // Compensate back again to texture coordinates.

    	float colour = Textur.Sample(sm, t + normDir)[rgb];
	    ret[rgb] += saturate(colour - 0.5f) * 1.5f;
	}
	
	//ret+=halo;
	
	/*float2 sp=(t-0.5)*2;
	float4 r=0;
	float z=zoom;
	float scale=-z*2;//0.5-zoom;
	for (int x=0; x<6; x++)
	{
		float2 p=sp/scale*0.5+0.5;
		float4 c=Textur.Sample(sm,p);
		float lum=dot(c.xyz,float3(0.299,0.587,0.114));
		c*=lum>threshold*4;
		r+=c*disc(sp/scale);
		scale*=-1;
		z*=-1;
		scale-=z;
	}*/
	return ret;
}

// ======================================================================
// Pass 2: blurpass
//   • Input (Texture0, Constant)
//   • Output (RenderTarget, Constant)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect;
}

cbuffer c : register(b1)
{
	float blursize,power;
}

float4 dof(float2 t)
{
	float4 color=0;
	float totweight=0;
	
	for (int x=0; x<3; x++)
	for (int y=0; y<3; y++)
	{
		float2 off=float2(x,y)-1;
		float2 coord=t+off*blursize*0.1*float2(1/aspect,1);
		color+=Textur.SampleLevel(sm,coord,0);
		totweight+=1;
	}
	
	return color/totweight;
}


float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 return dof(t);//Textur.Sample(sm,t.xy);
}

// ======================================================================
// Pass 3: BokehPass1
//   • Input (Texture0, Constant)
//   • Output (RenderTarget, Constant)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect;
}

cbuffer c : register(b1)
{
	float blursize;
}

static const float PI=3.14159265;

float2 ToUnitDisk(float2 O) 
{
	float a = 2*O.x - 1;
	float b = 2*O.y - 1;
	float r=b;
	float phi=(PI/4)*(a/b) + (PI/2);

	if (a*a>b*b) 
	{ 
		r = a;
		phi = (PI/4)*(b/a);
	} 
	
	//to ngon
	if (0)
	{	
		float n=6;
		phi+=0.1;
		r*=cos(PI/n)/cos(phi-(2*PI/n)*floor((n*phi+PI)/(2*PI)));
		phi-=0.1;
	}
	
	return float2( cos(phi)/aspect, sin(phi) )*r;
}

float4 dof(float2 t)
{
	float4 color=0;
	float totweight=0;
	
	for (int x=0; x<8; x++)
	for (int y=0; y<8; y++)
	{
		float2 off=ToUnitDisk((float2(x,y)+0.5)/8.0);
		float2 coord=t+off*0.2*blursize;
		color+=Textur.Sample(sm,coord);
		totweight+=1;
	}
	
	return color/totweight;
}


float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 return dof(t);//Textur.Sample(sm,t.xy);
}

// ======================================================================
// Pass 4: BokehPass2
//   • Input (Texture0, Constant)
//   • Output (RenderTarget, Variable)
//   • Blend (BlendMode0, Variable)
//   • Power (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect;
}

cbuffer c : register(b1)
{
	float blursize,power;
}

float4 dof(float2 t)
{
	float4 color=0;
	float totweight=0;
	
	for (int x=0; x<3; x++)
	for (int y=0; y<3; y++)
	{
		float2 off=float2(x,y)-1;
		float2 coord=t+off*blursize*0.02*float2(1/aspect,1);
		color+=Textur.Sample(sm,coord);
		totweight+=1;
	}
	
	return color/totweight;
}


float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 return dof(t)*power;//Textur.Sample(sm,t.xy);
}

