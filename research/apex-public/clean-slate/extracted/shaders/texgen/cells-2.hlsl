// Texture Generator: Cells 2
// GUID: 85A3A4598546B52869B4E5B1CEBD2B16
// Parameters:
//   [0] X Count (Float)
//   [0] Y Count (Float)

float4 PassData:register(c0);
float4 data1:register(c1);
Texture2D noise:register(t0);

float4 GetNoise(float2 tin, float2 grid)
{
 return noise.Load((int3(fmod(tin/grid*256+512,256),0)));
}

float voronoi(float2 x, float2 grid)
{
    float2 p=floor(x);
    float2 f=frac(x);

    float res=8.0;
	
    for (int j=-1; j<=1; j++)
	    for (int i=-1; i<=1; i++)
		{
			float2 b=float2(i,j);
			float2 r=b-f+GetNoise(p+b,grid).xy;
			float d=dot(r,r);
			res=min(res,d);
		}
	
    return sqrt(res);
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	float2 grid=data1.xy*255;
	return voronoi(t*grid,grid);
}