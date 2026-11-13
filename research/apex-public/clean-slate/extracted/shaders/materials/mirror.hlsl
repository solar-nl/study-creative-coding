// Render Technique: Mirror
// Type: ShaderToy
// GUID: 3239F532CED4BDB68C7BFC202017AAA9
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: New Pass
//   • Direction (Float, Variable)
//   • Input (Texture0, Variable)
//   • Target (RenderTarget, Variable)
//   • centerx (Float, Variable)
//   • centery (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect,xres,yres;
}

cbuffer c : register(b1)
{
	float dir;
	float centerx,centery;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
 //aspect ratio hardkodolt :(
 float aspect=16/9.0f;

 //ez a dir erteket hasznalhatova teszi (0.5 = 90 fok)
 float dirr=3.14159265*dir/2;

 //p egy pont a tukrozes egyenesen
 float2 p=float2(centerx,centery);

 //d a tukor egyenes iranya
 float2 d=float2(sin(dirr),cos(dirr));
 
 //ez az aktualis pixel pozicioja
 float2 a=t;

 //ezek az osztasok arra valok hogy x es y 
 //iranyban is egyseges legyen a koordinatarendszer
 //(aspect fix)
 p.y/=aspect;
 a.y/=aspect;

 //ez megnezi hogy a tukor melyik oldalan van az adott pixel,
 //ha a nem tukrozott reszen akkor visszater es nem csinal semmit
 if (dot(a-p,float2(-d.y,d.x))>0) return Textur.Sample(sm,t);

 //ez kiszamolja a tukor az adott ponthoz talalhato legkozelebbi pontjat
 float2 x=p+d*dot(a-p,d);

 //ez tukrozi az a pontot x-re, eredmeny az a2 pont
 float2 a2=x*2-a;

 //a2-t visszascalezzuk screen space-be
 a2.y*=aspect;

 //visszateresi ertek
 float4 v=0;

 //kiolvassa a tukrozott erteket a texturabol, de csak ha nem olvasna le a texturarol
 if (length(a2-clamp(0,1,a2))<0.0001) 
 v=Textur.Sample(sm,a2);

 //tadaaa
 return v;
}

