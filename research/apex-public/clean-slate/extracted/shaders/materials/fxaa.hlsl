// Render Technique: FXAA
// Type: ShaderToy
// GUID: 4EB186919A7C90223A237FC6C30F31F9
// Target Layer: NONENONENONENONE

// ======================================================================
// Pass 1: Prepass
//   • Input (Texture0, Variable)
//   • Target (RenderTarget, Constant)
//   • Luma Red (Float, Variable)
//   • Luma Green (Float, Variable)
//   • Luma Blue (Float, Variable)
// ======================================================================

SamplerState sm:register(s1);
Texture2D Textur:register(t0);

cbuffer b : register(b0)
{
	float t,aspect,xres,yres;
}

cbuffer c : register(b1)
{
	float3 rgb;
}

float4 p( float2 t:TEXCOORD0 ) : SV_TARGET0
{
	float4 c=pow(saturate(Textur.Sample(sm,t)),1/2.4)*1.055-0.055;
	c.w=dot(saturate(c.xyz),rgb/dot(rgb,1));
	return c;
}

// ======================================================================
// Pass 2: FXAA
//   • Input (Texture0, Constant)
//   • Output (RenderTarget, Variable)
//   • Subpixel (Float, Variable)
//   • Edge Threshold (Float, Variable)
//   • Edge Threshold Min (Float, Variable)
// ======================================================================

SamplerState sm : register(s1);
Texture2D t : register(t0);

float4 ft(float2 p) { return t.SampleLevel(sm, p, 0.0); }
float4 fo(float2 p, int2 o) { return t.SampleLevel(sm, p, 0.0, o); }

float4 FxaaPixelShader(float2 p, float2 fxaaQualityRcpFrame,
					   float fxaaQualitySubpix, float fxaaQualityEdgeThreshold,
					   float fxaaQualityEdgeThresholdMin)
{
	float quality[12] = { 1, 1, 1, 1, 1, 1.5, 2, 2, 2, 2, 4, 8 };

	float4 rgbyM = ft(p);
	float lS = fo(p, int2(0, 1)).w;
	float lE = fo(p, int2(1, 0)).w;
	float lN = fo(p, int2(0, -1)).w;
	float lW = fo(p, int2(-1, 0)).w;

	float rangeMax = max(max(lN, lW), max(lE, max(lS, rgbyM.w)));
	float rangeMin = min(min(lN, lW), min(lE, min(lS, rgbyM.w)));
	float rangeMaxScaled = rangeMax * fxaaQualityEdgeThreshold;
	float range = rangeMax - rangeMin;
	float rangeMaxClamped = max(fxaaQualityEdgeThresholdMin, rangeMaxScaled);
	if (range < rangeMaxClamped)
		return rgbyM;

	float lNW = fo(p, int2(-1, -1)).w;
	float lSE = fo(p, int2(1, 1)).w;
	float lNE = fo(p, int2(1, -1)).w;
	float lSW = fo(p, int2(-1, 1)).w;

	float lNS = lN + lS;
	float lWE = lW + lE;
	float subpixRcpRange = 1.0 / range;
	float subpixNSWE = lNS + lWE;
	float edgeHorz1 = (-2.0 * rgbyM.w) + lNS;
	float edgeVert1 = (-2.0 * rgbyM.w) + lWE;

	float lNESE = lNE + lSE;
	float lNWNE = lNW + lNE;
	float edgeHorz2 = (-2.0 * lE) + lNESE;
	float edgeVert2 = (-2.0 * lN) + lNWNE;

	float lNWSW = lNW + lSW;
	float lSWSE = lSW + lSE;
	float edgeHorz4 = (abs(edgeHorz1) * 2.0) + abs(edgeHorz2);
	float edgeVert4 = (abs(edgeVert1) * 2.0) + abs(edgeVert2);
	float edgeHorz3 = (-2.0 * lW) + lNWSW;
	float edgeVert3 = (-2.0 * lS) + lSWSE;
	float edgeHorz = abs(edgeHorz3) + edgeHorz4;
	float edgeVert = abs(edgeVert3) + edgeVert4;

	float subpixNWSWNESE = lNWSW + lNESE;
	float lengthSign = fxaaQualityRcpFrame.x;
	float subpixA = subpixNSWE * 2.0 + subpixNWSWNESE;
	bool horzSpan = edgeHorz >= edgeVert;

	if (!horzSpan) 
	{ 
		lN = lW;
		lS = lE;
	}
	else
		lengthSign = fxaaQualityRcpFrame.y;
	float subpixB = (subpixA * (1.0 / 12.0)) - rgbyM.w;

	float gradientN = lN - rgbyM.w;
	float gradientS = lS - rgbyM.w;
	float lNN = lN + rgbyM.w;
	float lSS = lS + rgbyM.w;
	bool pairN = abs(gradientN) >= abs(gradientS);
	float gradient = max(abs(gradientN), abs(gradientS));
	if (pairN) lengthSign = -lengthSign;
	float subpixC = saturate(abs(subpixB) * subpixRcpRange);

	float2 posB=p;
	float2 offNP;
	offNP.x = (!horzSpan) ? 0.0 : fxaaQualityRcpFrame.x;
	offNP.y = (horzSpan) ? 0.0 : fxaaQualityRcpFrame.y;
	if (!horzSpan) posB.x += lengthSign * 0.5;
	if (horzSpan) posB.y += lengthSign * 0.5;

	float2 posN=posB-offNP*quality[0];
	float2 posP=posB+offNP*quality[0];
	float subpixD = ((-2.0)*subpixC) + 3.0;
	float lEndN = ft(posN).w;
	float subpixE = subpixC * subpixC;
	float lEndP = ft(posP).w;

	if (!pairN) lNN = lSS;
	float gradientScaled = gradient * 1.0 / 4.0;
	float lMM = rgbyM.w - lNN * 0.5;
	float subpixF = subpixD * subpixE;
	bool lMLTZero = lMM < 0.0;

	lEndN -= lNN * 0.5;
	lEndP -= lNN * 0.5;
	bool doneN,doneP,doneNP;

	for (int x = 1; x < 12; x++)
	{
		doneN = abs(lEndN) >= gradientScaled;
		doneP = abs(lEndP) >= gradientScaled;
		doneNP = (!doneN) || (!doneP);
		if (!doneN) posN.x -= offNP.x * quality[x];
		if (!doneN) posN.y -= offNP.y * quality[x];
		if (!doneP) posP.x += offNP.x * quality[x];
		if (!doneP) posP.y += offNP.y * quality[x];

		if (!doneNP || x==11) break;
		if (!doneN) lEndN = ft(posN.xy).w;
		if (!doneN) lEndN = lEndN - lNN * 0.5;
		if (!doneP) lEndP = ft(posP.xy).w;
		if (!doneP) lEndP = lEndP - lNN * 0.5;
	}

	float dstN = p.x - posN.x;
	float dstP = posP.x - p.x;
	if (!horzSpan) dstN = p.y - posN.y;
	if (!horzSpan) dstP = posP.y - p.y;

	bool goodSpanN = (lEndN < 0.0) != lMLTZero;
	float spanLength = (dstP + dstN);
	bool goodSpanP = (lEndP < 0.0) != lMLTZero;
	float spanLengthRcp = 1.0 / spanLength;

	bool directionN = dstN < dstP;
	float dst = min(dstN, dstP);
	bool goodSpan = directionN ? goodSpanN : goodSpanP;
	float subpixG = subpixF * subpixF;
	float pixelOffset = (dst * (-spanLengthRcp)) + 0.5;
	float subpixH = subpixG * fxaaQualitySubpix;

	float pixelOffsetGood = goodSpan ? pixelOffset : 0.0;
	float pixelOffsetSubpix = max(pixelOffsetGood, subpixH);

	float2 posM=p;
	if (!horzSpan) posM.x += pixelOffsetSubpix * lengthSign;
	if (horzSpan) posM.y += pixelOffsetSubpix * lengthSign;
	return float4(ft(posM).xyz, rgbyM.w);
}

cbuffer b : register(b0)
{
	float time, aspect, xres, yres;
}

cbuffer c : register(b1)
{
	float subpixel;
	float edgethresh, edgethreshmin;
}

float4 p(float2 t : TEXCOORD0) : SV_TARGET0
{
	return pow((0.055+saturate(FxaaPixelShader(t, 1 / float2(xres, yres), subpixel, lerp(1 / 3.0, 0.063, edgethresh), edgethreshmin*0.0833)))/1.055,2.4);// Textur.Sample(sm,t.xy);
}

