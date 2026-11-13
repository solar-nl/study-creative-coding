// Texture Generator: Curves
// GUID: E2A4E9A1C02F7E457448B289FD0F05A4

SamplerState sm:register(s0);
SamplerState cs:register(s1);

Texture2D Textur:register(t0);
Texture2D Curves:register(t1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float4 c=Textur.Sample(sm,t);
 float4 r;
 r.x=Curves.SampleLevel(cs,float2(c.x,0),0).x;
 r.y=Curves.SampleLevel(cs,float2(c.y,0),0).y;
 r.z=Curves.SampleLevel(cs,float2(c.z,0),0).z;
 r.w=Curves.SampleLevel(cs,float2(c.w,0),0).w;
 return r;
}