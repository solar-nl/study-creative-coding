// Render Technique: Wireframe
// Type: Material
// GUID: 2A9BCBB81A1352D113B8B5BF0982D887
// Target Layer: Solid Layer

// ======================================================================
// Pass 1: Wireframe Pass
//   • Color (Color, Variable)
//   • BlendMode (BlendMode0, Variable)
//   • Zmode (ZMode, Constant)
//   • Width (Float, Variable)
//   • New Parameter (FillMode, Constant)
//   • New Parameter (CullMode, Constant)
//   • Contrast (Float, Variable)
//   • Animation Control Texture (Texture0, Variable)
//   • Render Priority (RenderPriority, Variable)
//   • OverDrive (Float, Variable)
//   • New Parameter (Float, Constant)
//   • Animation (Float, Animated)
//   • Offset (Float, Animated)
//   • Z Mode (ZFunction, Variable)
// ======================================================================

SamplerState sm:register(s0);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float4x4 viewmat;
	float4x4 projmat;
}

cbuffer c : register(b1)
{
	float4x4 worldmat;
	float4x4 itworldmat;
	float4 color;
	float4 width;
	float2 t;
}

struct VSIN
{
	float3 Position : POSITION0;
	float3 Position2 : POSITION1;
	float3 Normal : NORMAL0;
	float4 Color : COLOR0;
	float4 UV : TEXCOORD0;
	float4 UV2: TEXCOORD1;
};

struct VSOUT
{
	float4 Position : SV_POSITION;
	float4 Normal : TEXCOORD0;
	float anim: TEXCOORD1;
};

VSOUT v(VSIN x)
{
	VSOUT o;
	o.Position=float4(mul(worldmat,float4(x.Position,1)).xyz,1);
	o.Normal=float4(normalize(mul(worldmat,float4(x.Normal,1)).xyz),1);
	o.anim=Textur.SampleLevel(sm,x.UV.xy,0).x;
	return o;
}

struct GSOUT
{
	float4 Position : SV_POSITION;
	float t : TEXCOORD0;
	float c : TEXCOORD1;
};

[maxvertexcount(6)]
void g( line VSOUT input[2], inout TriangleStream<GSOUT> OutputStream )
{
	float tc=saturate(saturate(t.x-(input[0].anim+input[1].anim)*0.95*0.5)/0.05);

	float4 p1=mul(projmat,mul(viewmat,input[0].Position+input[0].Normal*t.y));
	float4 p2=mul(projmat,mul(viewmat,input[1].Position+input[1].Normal*t.y));
	
	p2=lerp(p1,p2,tc);
	
	float2 d = normalize((p2/p2.w).xy-(p1/p1.w).xy);
	float4 n = float4(-d.y,d.x,0,0)*width.x*0.05;
	
	GSOUT o;
	o.c=tc;//input[0].anim;
	
	o.Position=p1+n*p1.w;
	o.t=1;
	OutputStream.Append(o);

	o.Position=p1-n*p1.w;
	o.t=-1;
	OutputStream.Append(o);

	o.Position=p2-n*p2.w;
	OutputStream.Append(o);
	
	OutputStream.RestartStrip();	

	o.Position=p1+n*p1.w;
	o.t=1;
	OutputStream.Append(o);

	o.Position=p2-n*p2.w;
	o.t=-1;
	OutputStream.Append(o);

	o.Position=p2+n*p2.w;
	o.t=1;
	OutputStream.Append(o);
	
	OutputStream.RestartStrip();	
}

float4 p(GSOUT v) : SV_TARGET0
{
	float r=pow(abs(1-abs(v.t)),1+width.y*30);
	if (r<=1/255.0f)
		discard;
	return r*color*v.c*(1+width.z*10);;
}

