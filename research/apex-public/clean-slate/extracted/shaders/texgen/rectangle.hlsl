// Texture Generator: Rectangle
// GUID: AEEBD61B8F7C0EE35D488607F798CA72
// Parameters:
//   [0] X1 (Float)
//   [0] Y1 (Float)
//   [0] X2 (Float)
//   [0] Y2 (Float)
//   [0] Chamfer (Float)
//   [0] Falloff (Float)

float4 data1:register(c1);
float4 data2:register(c2);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 float dc=(1+data2.x)/2; 
 float2 c=data1.xy-t+0.5/255.0f;
 float2 d=abs(c/data1.zw/dc); 
 float l=1-saturate(sqrt(pow(d.x,2/data2.x)+pow(d.y,2/data2.x))); 
 return pow(abs(l+0.5),1/data2.y*10);
}