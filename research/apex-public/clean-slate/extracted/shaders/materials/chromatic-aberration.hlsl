// Render Technique: Chromatic Aberration
// Type: ShaderToy
// GUID: 5247EBE22E9C40E3FB00E44BE3EDB6EF
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: New Pass
//   • Input (Texture0, Variable)
//   • Rendertarget (RenderTarget, Variable)
//   • Power (Float, Variable)
//   • Samplecount (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect,xres,yres;
}

cbuffer c : register(b1)
{
	float power;
	float samplecnt;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float count=samplecnt*255;

	float2 dirr=(0.5-t);
	float2 dirb=dirr;
	float4 col=Textur.Sample(sm,t);
	float4 r=0;
	float4 b=0;
	for (int x=0; x<count; x++)
	{
 		r+=Textur.Sample(sm,t-dirr*x/200.0f*power);
 		b+=Textur.Sample(sm,t+dirb*x/200.0f*power);
	}

	col.x=r.x/count;
	col.z=b.z/count;

	return col;
}

