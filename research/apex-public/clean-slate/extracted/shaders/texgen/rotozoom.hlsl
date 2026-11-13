// Texture Generator: Rotozoom
// GUID: 38B05423B059B345938B2FEB8E2E7264
// Parameters:
//   [0] Rotation (Float)
//   [0] Zoom (Float)
//   [0] X Center (Float)
//   [0] Y Center (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float2 cntr=data1.zw;

 float z=0.25/(data1.y*255/256.0f);
 float2 t2=(t-cntr*255/256.0f);
 float l=data1.x*255/256.0f*3.14159265*2;

 float2 dpr=float2(cos(l),sin(l));

 t=float2(t2.x*dpr.x+t2.y*dpr.y,t2.y*dpr.x-t2.x*dpr.y)*z+0.5;

 return Textur.Sample(sm,t);
}