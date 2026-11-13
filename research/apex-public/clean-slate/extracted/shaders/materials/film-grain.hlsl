// Render Technique: Film Grain
// Type: ShaderToy
// GUID: ECF4076818404D3D65ABCBC0061DCE3A
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: New Pass
//   • Rendertarget (RenderTarget, Variable)
//   • Input (Texture0, Variable)
//   • Color Amount (Float, Variable)
//   • Luminance (Float, Variable)
//   • Grain Size (Float, Variable)
//   • Grain Amount (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float timer,aspect,width,height;
}

cbuffer c : register(b1)
{
	float coloramount,lumamount;
	float grainsiz,grainam;
}

//a random texture generator, but you can also use a pre-computed perturbation texture
float4 rnm(float2 tc) 
{
	return frac((sin(dot(tc + float2(timer,timer),float2(12.9898,78.233))) * 43758.5453)*float4(1,1.2154,1.3453,1.3647))*2-1;
}

float fade(float t) 
{
	return t*t*t*(t*(t*6.0-15.0)+10.0);
}

float pnoise3D(float3 p)
{
	float permTexUnit = 1.0/256.0;		// Perm texture texel-size
	float permTexUnitHalf = 0.5/256.0;	// Half perm texture texel-size

	float3 pi = permTexUnit*floor(p)+permTexUnitHalf; // Integer part, scaled so +1 moves permTexUnit texel
	// and offset 1/2 texel to sample texel centers
	float3 pf = frac(p);     // Fractional part for interpolation

	float n[8];
	for (int x=0; x<2; x++)
	 for (int y=0; y<2; y++)
	  for (int z=0; z<2; z++)
	   n[x*4+y*2+z]=dot(rnm(float2(rnm(pi.xy+permTexUnit*float2(x,y)).w, pi.z+ permTexUnit*z)).xyz * 4.0 - 1.0,pf-float3(x,y,z));
	   
	// Blend contributions along x
	float4 n_x = lerp(float4(n[0], n[1], n[2], n[3]), float4(n[4], n[5], n[6], n[7]), fade(pf.x));

	// Blend contributions along y
	float2 n_xy = lerp(n_x.xy, n_x.zw, fade(pf.y));

	// Blend contributions along z
	float n_xyz = lerp(n_xy.x, n_xy.y, fade(pf.z));

	// We're done, return the final noise value.
	return n_xyz;
}

//2d coordinate orientation thing
float2 coordRot(float2 tc, float angle)
{
	tc.x*=aspect;
	tc = mul(float2x2(cos(angle),-sin(angle),sin(angle),cos(angle)),tc);
	tc.x/=aspect;
	return tc;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	float grainsize=lerp(1.5,2.5,grainsiz);
	float2 m = float2(width/grainsize,height/grainsize);

	float2 rotCoordsR = coordRot(t, timer + 1.425)*m;
	float2 rotCoordsG = coordRot(t, timer + 3.892)*m;
	float2 rotCoordsB = coordRot(t, timer + 5.835)*m;
	
	float3 noise = float3(pnoise3D(float3(rotCoordsR,0)),
	                      pnoise3D(float3(rotCoordsG,1)),
	                      pnoise3D(float3(rotCoordsB,2)));
	noise=lerp(noise.r,noise,coloramount);
	
	float3 col = Textur.Sample(sm,t); // this was originally saturated

	//noisiness response curve based on scene luminance
	float luminance = lerp(0.0,dot(col, float3(0.3,0.587,0.114)),lumamount);
	float lum = smoothstep(0.2,0.0,luminance) + luminance;
	
	return float4(col+lerp(noise,0,pow(lum,4))*grainam*0.1,1);
}

