// Texture Generator: Blur
// GUID: CDEDB0BD255B091EDED9D5D630AB5B75
// Parameters:
//   [0] X Amount (Float)
//   [0] Y Amount (Float)

SamplerState sm:register(s0);
float4 PassData:register(c0);
float4 data1:register(c1);
Texture2D Textur:register(t0);

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 #define oneway 24.0f
 float4 res=0;

 float XM=1;
 float YM=0;

 if (PassData.x+0.5>=3)
 {
  XM=0;
  YM=1;
 }

 float2 xd=float2(data1.x*XM,data1.y*YM)*-0.5;
 float2 xxd=float2(data1.x*XM,data1.y*YM)/oneway;

 for (float x=0; x<oneway; x++)
 {
  res+=Textur.Sample(sm,t+xd);
  xd+=xxd;
 }

 return res/oneway;
}