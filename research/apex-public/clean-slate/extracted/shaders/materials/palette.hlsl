// Render Technique: Palette
// Type: ShaderToy
// GUID: 26F0435A6BCBCCD866EE3E93DCF79AA2
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: New Pass
//   • RenderTarget (RenderTarget, Variable)
//   • Input (Texture0, Variable)
//   • Palette (Texture1, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);
Texture2D Palette:register(t1);

float4 p( float4 t:SV_POSITION ) : SV_TARGET0
{ 
	float4 col=Textur.Load(int3(t.xy,0));
	
	float4 ret;
	ret.x=Palette.SampleLevel(sm,float2(saturate(col.x),0),0).x;
	ret.y=Palette.SampleLevel(sm,float2(saturate(col.y),0),0).y;
	ret.z=Palette.SampleLevel(sm,float2(saturate(col.z),0),0).z;
	ret.w=Palette.SampleLevel(sm,float2(saturate(col.w),0),0).w;
	
	return ret;
}

