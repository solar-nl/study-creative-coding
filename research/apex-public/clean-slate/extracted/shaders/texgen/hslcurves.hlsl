// Texture Generator: HSLCurves
// GUID: D67806AC742D825550FC2D42607C0980

SamplerState sm:register(s0);
SamplerState cs:register(s1);

Texture2D Textur:register(t0);
Texture2D Curves:register(t1);

float3 rgb_to_hsv(float3 c)
{
	float3 r; 
	float Min; 

	r.z=max(max(c.x,c.y),c.z); 
	Min=min(min(c.x,c.y),c.z); 

	float delta = r.z - Min;
    if (r.z!=0)
	r.y = delta/r.z; 
	else r.y=0;

	float3 m=r.z-c;

	r.x = (m.z-m.y) / delta;
	if (c.y == r.z) r.x = (m.x-m.z) / delta + 2; 
	if (c.z == r.z) r.x = (m.y-m.x) / delta + 4; 

	if (delta==0) r.x=-1;

	return r;
} 

float3 hsv_to_rgb(float3 h) 
{ 
	float3 r; 

	h.x=fmod(h.x+6,6);

	float f = h.x - (int)h.x;

	int o = h.x; 

	r=float3(0,1-f,1);
	if (o==1) r=float3(f,0,1);
	if (o==2) r=float3(1,0,1-f);
	if (o==3) r=float3(1,f,0);
	if (o==4) r=float3(1-f,1,0);
	if (o==5) r=float3(0,1,f);

	return (1-r*h.y)*h.z; 
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float4 c=Textur.Sample(sm,t);
 c.xyz=rgb_to_hsv(c.xyz);
 float4 r;
 r.x=Curves.Sample(cs,float2(c.x/6,0)).x*6;
 r.y=Curves.Sample(cs,float2(c.y,0)).y;
 r.z=Curves.Sample(cs,float2(c.z,0)).z;
 return float4(hsv_to_rgb(r.xyz),c.w);
}