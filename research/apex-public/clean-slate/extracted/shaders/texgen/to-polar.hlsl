// Texture Generator: To Polar
// GUID: 275747D801F268A95FBFA1B4294076EA
// Parameters:
//   [1] Polar -> Rect (Color)
//   [1] Flip y (Color)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 data1:register(c1);

float2 rect2polar(float2 t)
{
	float y=saturate(length(t-0.5)*2);
	float x=atan2(t.x-0.5,t.y-0.5)/3.14159265/2.0;
	return float2(x,y);
}

float2 polar2rect(float2 t)
{
	float r=(t.y)/2.0;
	float p=(t.x)*3.14159265*2;
	return r*float2(sin(p),cos(p))+0.5;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float2 u=t;
 if (data1.y!=0) u.y=1-u.y;
 if (data1.x==0) u=rect2polar(u);
 else u=polar2rect(u);

 return Textur.SampleLevel(sm,u,0);
}