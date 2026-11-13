// Texture Generator: Tiles
// GUID: 3123710457D98941287248E4BE10D618
// Parameters:
//   [0] X Count (Float)
//   [0] Y Count (Float)
//   [0] Offset (Float)
//   [0] Border (Float)

float4 data:register(c1);

float DrawRect(float2 t, float4 rect)
{
	rect.xz-=floor(rect.x);
	return (all(t>rect.xy) && all(t<rect.zw)) || (all(t+float2(1,0)>rect.xy) && all(t+float2(1,0)<rect.zw));
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	int2 c=data.xy*255;
	float cnt=c.x*c.y;
	float2 s=1.0/c;
	float border = min(s.x,s.y)*data.w;
	
	float col=0;
	
	float2 pos=0;
	
	int brickCount=1;
	
	for (int y=0; y<c.y; y++)
	{
		for (int x=0; x<c.x; x++)
		{
			col+= DrawRect(t,float4(pos+border,pos+s-border))*(brickCount/cnt);
			pos.x+=s.x;
			brickCount++;
		}
		pos.x+=data.z*s.x;
		pos.y+=s.y;
	}
	
	return col;
}