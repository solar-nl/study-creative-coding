// Texture Generator: Solid Color
// GUID: 743EC986A0A46B1C288ADFB64F131C23
// Parameters:
//   [2] New Parameter (ZMode)

float4 data1:register(c1);

float4 p(float4 p:TEXCOORD0) : SV_TARGET0
{
 return data1;
}