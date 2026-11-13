// Render Technique: Glow
// Type: ShaderToy
// GUID: 33AEA5F0F3B498146DA6A11BA7474CDF
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: To Back X/2 Y/1
//   • Input (Texture0, Variable)
//   • Rendertarget (RenderTarget, Constant)
//   • threshold (Float, Variable)
//   • Power (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float4 blur;
	float threshold;
	float power;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 col=0;
	float cnt=blur.z*255;

	for (int x=0; x<cnt; x++)
	{
		float p=(x-(cnt-1)/2.)*blur.x/cnt/4.0f;
		float4 c=Textur.Sample(sm,t.xy+p*float2(1,0));
		float4 cm=c>=threshold;
		col+=((c-threshold)*(1+power*1000)+threshold)*cm;
	}

  return col/cnt;
}

// ======================================================================
// Pass 2: To Back X/2 Y/2
//   • Rendertarget (RenderTarget, Constant)
//   • Input (Texture0, Constant)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float2 blur;
	float samplecount;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 col=0;
	float cnt=samplecount*255;

	for (int x=0; x<cnt; x++)
	{
		float p=(x-(cnt-1)/2.)*blur.y/cnt/4.0f;
		col+=Textur.Sample(sm,t.xy+p*float2(0,1));
	}

  return col/cnt;
}

// ======================================================================
// Pass 3: To Back X/4 Y/2
//   • Rendertarget (RenderTarget, Constant)
//   • Input (Texture0, Constant)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float2 blur;
	float samplecount;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 col=0;
	float cnt=samplecount*255;

	for (int x=0; x<cnt; x++)
	{
		float p=(x-(cnt-1)/2.)*blur.x/cnt/4.0f;
		col+=Textur.Sample(sm,t.xy+p*float2(1,0));
	}

  return col/cnt;
}

// ======================================================================
// Pass 4: To Back X/4 Y/4
//   • Rendertarget (RenderTarget, Constant)
//   • Input (Texture0, Constant)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float2 blur;
	float samplecount;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 col=0;
	float cnt=samplecount*255;

	for (int x=0; x<cnt; x++)
	{
		float p=(x-(cnt-1)/2.)*blur.y/cnt/4.0f;
		col+=Textur.Sample(sm,t.xy+p*float2(0,1));
	}

  return col/cnt;
}

// ======================================================================
// Pass 5: To Back X/8 Y/4
//   • Rendertarget (RenderTarget, Constant)
//   • Input (Texture0, Constant)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float2 blur;
	float samplecount;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 col=0;
	float cnt=samplecount*255;

	for (int x=0; x<cnt; x++)
	{
		float p=(x-(cnt-1)/2.)*blur.x/cnt/4.0f;
		col+=Textur.Sample(sm,t.xy+p*float2(1,0));
	}

  return col/cnt;
}

// ======================================================================
// Pass 6: To Back X/8 Y/8
//   • Rendertarget (RenderTarget, Constant)
//   • Input (Texture0, Constant)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float2 blur;
	float samplecount;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{ 
	float4 col=0;
	float cnt=samplecount*255;

	for (int x=0; x<cnt; x++)
	{
		float p=(x-(cnt-1)/2.)*blur.y/cnt/4.0f;
		col+=Textur.Sample(sm,t.xy+p*float2(0,1));
	}

  return col/cnt;
}

// ======================================================================
// Pass 7: Output
//   • Output (RenderTarget, Variable)
//   • Input (Texture0, Constant)
//   • Color (Color, Variable)
//   • Blend (BlendMode0, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
}

cbuffer c : register(b1)
{
	float4 blur;
	float4 color;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 return Textur.Sample(sm,t.xy)*color;
}

