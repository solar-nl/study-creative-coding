// Texture Generator: Combine
// GUID: B593A39FD1166147DB3437FD1B3DC9D3
// Parameters:
//   [4] Filter (FillMode)

SamplerState sm:register(s0);
float4 data1:register(c1);
Texture2D Textur:register(t0);
Texture2D Textur2:register(t1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	float4 v1=Textur.Sample(sm,t);
	float4 v2=Textur2.Sample(sm,t);
	float4 r=v1+v2;
	int Type=(int)(data1.x*256);
	if (Type==1) r=v1-v2;
	if (Type==2) r=v1*v2;
	if (Type==3) r=v1*(1-v2.w)+v2*v2.w;
	if (Type==4) r=min(v1,v2);
	if (Type==5) r=max(v1,v2);
	if (Type==6) r=v1/(1-v2);
	if (Type==7) r=1-(1-v1)/v2;
	if (Type==8) r=1-(1-v1)*(1-v2);
	if (Type==9) r=lerp(1-2*(1-v1)*(1-v2),2*v1*v2,v1<0.5);
	return r;
}