// Texture Generator: Mix
// GUID: 78968182F312130C262FC5DAFC189C2D
// Parameters:
//   [0] Amount (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
Texture2D Tex2:register(t1);
float4 data1:register(c1);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 return lerp(Textur.Sample(sm,t),Tex2.Sample(sm,t),data1.x);
}