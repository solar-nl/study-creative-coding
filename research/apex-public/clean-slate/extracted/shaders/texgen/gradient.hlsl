// Texture Generator: Gradient
// GUID: 610C710104126E1A289510D9901D69E8
// Parameters:
//   [4] GradientType (FillMode)

float4 d:register(c1);

float4 p( float2 tt : TEXCOORD0 ) : SV_TARGET0
{
	float r=0;
	int Pattern=(int)(d.x*256);

	float2 t=tt-0.5f;

	if (Pattern==0) r=1-length(t)*2/sqrt(2);
	if (Pattern==1) r=1-max(abs(t.x),abs(t.y))*2;
	if (Pattern==2) r=tt.x;
	if (Pattern==3) r=tt.y;
	if (Pattern==4) r=1-abs(1-tt.x*2);
	if (Pattern==5) r=1-abs(1-tt.y*2);

	return r;
}