// Texture Generator: Envmap
// GUID: 6E7AC8C30D6A76F0515EAF6A96B435B1
// Parameters:
//   [0] Outer Radius (Float)
//   [0] Inner Radius (Float)
//   [0] X Scale (Float)
//   [0] Y Scale (Float)

float4 radius:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	float d=radius.x-radius.y;
	float2 scle=(t-0.5)/(radius.zw*radius.x);
	float l=length(scle);
	return 1+(radius.y-l)/d;
}