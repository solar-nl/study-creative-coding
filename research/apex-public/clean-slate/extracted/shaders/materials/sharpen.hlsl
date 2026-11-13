// Render Technique: Sharpen
// Type: ShaderToy
// GUID: 3ABE85F5E14657803BD11A06958B1483
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • RenderTarget (RenderTarget, Variable)
//   • Input (Texture0, Variable)
//   • Blending (BlendMode0, Variable)
//   • Power (Float, Variable)
// ======================================================================

Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect,xres,yres;
}

cbuffer c : register(b1)
{
	float power;
}

/*float luminance(float4 c)
{
	return dot(c.xyz, float3(.2126, .7152, .0722));
}*/

float4 convolve(float3x3 kernel, int2 p)
{
	int2 maxval=int2(xres,yres)-1;
	float4 output;
	for (int x=0; x<3; x++)
	 for (int y=0; y<3; y++)
	  output+=Textur.Load(int3(max(0,min(maxval,p+int2(x,y)-1)),0))*kernel[x][y];
	return output;
}

float4 p(float4 p:SV_POSITION) : SV_TARGET0
{ 
	float4 t=Textur.Load(int3(p.x,p.y,0));
	return lerp(t,convolve(float3x3(-1,-1,-1,-1,9,-1,-1,-1,-1),p.xy),power*5);
}

