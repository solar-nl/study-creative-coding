// Texture Generator: HSL
// GUID: 21EAF46BC325662442A8AB197408A129
// Parameters:
//   [0] Hue (Float)
//   [0] Saturation (Float)
//   [0] Lightness (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

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

 float4 d=data1/256*255;

 c.xyz=rgb_to_hsv(c);

 c.x+=d.x*6;
 c.y*=d.y*4;

 if (d.z<0.5) c.z*=d.z*2;
 else c.z=lerp(c.z,1,(d.z-0.5)*2);

 c.xyz=saturate(hsv_to_rgb(c.xyz));

 return c;
}