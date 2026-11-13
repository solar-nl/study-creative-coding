// Texture Generator: Translate
// GUID: 5991AF84E2A68B22C341B55B5B8784CF
// Parameters:
//   [1] Rotate45 (Color)
//   [0] X Offset (Float)
//   [0] Y Offset (Float)

SamplerState sm:register(s0);
Texture2D Textur:register(t0);
float4 PassData:register(c0);
float4 data1:register(c1);

float4 p(float2 p:TEXCOORD0) : SV_TARGET0
{
 float2 uv=p;

 if (data1.x>0)
 {
   float f=3.14159265/4.0f;
   uv=mul(float2x2(cos(f),-sin(f),sin(f),cos(f))/sqrt(2),(uv-0.5f)*2.0)/2.0f+0.5f;
 } 

 return Textur.Sample(sm,uv+data1.yz*255/256.0f);
}