// Render Technique: Ghosting
// Type: ShaderToy
// GUID: 41A51B9F622A5339E25663E47C4FCEC2
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: New Pass
//   • Input (Texture0, Variable)
//   • Rendertarget (RenderTarget, Variable)
//   • Power (Float, Variable)
//   • SampleCount (Float, Variable)
//   • Threshold (Float, Variable)
//   • Blending (BlendMode0, Variable)
//   • Direction (Float, Variable)
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
	float threshold;
	float direction;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float count=samplecnt*255+1;

	float2 dirr=float2(cos(direction*3.14159265),sin(direction*3.14159265));
	float2 dirb=dirr;
	float4 col=Textur.Sample(sm,t);
	col*=saturate(col>threshold);
	for (int x=-count/2; x<count/2; x++)
	{
		float4 tr=Textur.Sample(sm,t+dirr*x/200.0f*power);
		tr*=saturate(tr>threshold);
 		col+=tr;//saturate(tr-threshold)+threshold;
	}

	col=col/count;
	return col;
}

