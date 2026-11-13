// Texture Generator: CellEdges
// GUID: 4B841EDD9D4EE4288164844C5FBAA768
// Parameters:
//   [0] X Count (Float)
//   [0] Y Count (Float)
//   [0] Thickness (Float)

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
 
	float2 mr;

    float res = 128.0;
    for (int j=-1; j<=1; j++)
		for (int i=-1; i<=1; i++)
		{			  
		     float2 b=float2(i,j);   
		     float2 r=b-f+GetNoise(p+b,grid).xy;   
		     float d=dot(r,r);
			   
		     if (d<res)
		     {
				res=d;
				mr=r;
			 }
		}
	
    res = 128.0;
    for (int k=-2; k<=2; k++)
    	for (int l=-2; l<=2; l++)
    	{
        	float2 b=float2(l,k);
        	float2 r=b-f+GetNoise(p+b,grid).xy;
        	float d=dot(0.5*(mr+r),normalize(r-mr));
		    if (length(r-mr)>0)
        	res=min(res,d);
    	}
	
	return res;	
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	float2 grid=data1.xy*255;
	float dis=voronoi(t*grid,grid);
    return 1-dis/data1.z;
}