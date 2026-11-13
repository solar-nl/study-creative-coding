# Operator Families vs flux: Cross-Reference Synthesis

**Date:** 2026-05-21
**Source brief:** `research/operator-families-research-brief.md`
**Source inventories:** `research/inventory-{tixl,cables,vvvv,werkkzeug,openrndr-orx,threejs,openframeworks,processing-toxiclibs}.md`

This document synthesizes 8 per-reference operator-family inventories into a single gap list for the *flux* realtime graphics framework. The target envelope is Decima-class on three axes: **scene scale**, **visual fidelity**, **authoring at scale** (1000+ ops per project). Each family below is tagged `[scene] [visual] [authoring]` per the axes it primarily serves.

Reference shorthand: **tixl**, **cab** (cables.gl), **vvvv**, **wz** (Werkkzeug), **orx** (openrndr+orx), **t3** (three.js), **of** (OpenFrameworks), **toxi** (Processing+toxiclibs). The first four are node-paradigm refs (closest to flux's evaluation model); the last four are code-first refs surveyed by library/addon catalog.

---

## Executive summary

**Three findings carry disproportionate weight:**

1. **Flux's planned transform model is contested by every node-paradigm reference.** cables.gl, tixl, vvvv, and Werkkzeug *all* treat transforms as render-state mutators on a scope/render-chain — **not** as `Matrix4` values flowing through ports. This is the SECOND independent vote (tixl's `Command` type, cables' render-trigger chain) that flux's "Matrix4 on a port" assumption should be revisited before implementing the transform-operator family.

2. **The biggest missing family by raw fan-out is `Mesh Modify`** — at least 35 ops in Werkkzeug, full subfamily in toxiclibs (subdivision strategies, volumetric, sweep/extrude/loft, NURBS), present in 6/8 refs, and the precondition for any non-primitive procedural geometry. Without it, flux's geometry vocabulary stays stuck at "place a box."

3. **The scaling-to-1000-ops problem has a known answer that flux currently lacks any version of:** *named channels / cross-graph wiring without literal wires*. cables.gl ships 29 typed `Var*` ops + `TriggerSendNamed`; vvvv has `ChannelHub`; tixl has `Variable`/`Spline` named globals; Werkkzeug has `Variable`/`Spline` referenced from inline scripts. **All four node-paradigm refs solved this; flux has not.**

Beyond the above, the inventories surface ~60 distinct operator families across the 8 references. Stripping reference-specific niches leaves **~25 confirmed-missing families**, **~15 likely-missing families**, and **~10 AAA-gap families** (called out by the Decima target but under-represented even in the creative-coding lineage). The revised tier ranking at the bottom of this document organizes them by leverage.

A **separate but equally important** finding: roughly **15 operator-graph *patterns*** (Spreads, Process-vs-Operation, IObservable as port type, shader-file-as-node convention, render-state-as-scope, Strategy-as-port-level-value, brush+accumulator, defensive resource ports, multi-substrate scene primitives, etc.) determine what flux's operator model *can* express. At 1000-op scale, the patterns matter as much as the operators — see the *Operator-graph patterns* section.

---

## Confirmed-missing families

Present in ≥6/8 references, or in **all** node-paradigm refs (tixl + cab + vvvv + wz). Absent from flux.

### Transform / Scene-State Mutators `[scene] [authoring]`
- **Coverage:** tixl ✓, cab ✓, vvvv ✓, wz ✓ + t3 ✓ (Object3D hierarchy)
- **Critical finding:** the four node-paradigm refs converge on **render-state-as-scope**, not Matrix4-as-value. tixl's `Transform.Update()` pushes onto `EvaluationContext.ObjectToWorld`, evaluates a `Command`-typed downstream subtree, restores; cables' `Translate.json` has a `render` trigger input and pushes onto a per-frame stack; Werkkzeug's `Transform` is a scene-graph-tree node. **Design call: revisit flux's "Matrix4 flows on a port" assumption before shipping the transform family.**
- **Representative ops:** `Transform`, `RotateAroundAxis`, `Group`, `SpreadLayout`, `TransformMesh`, `TransformPivot`, `LookAt`, `SplinedObject` (tixl + wz)
- **Subfamily — per-vec3 / per-quaternion transform math:** `TransformVec3`, `RotateVector3`, `MulMatrix` (tixl `Operators/Lib/numbers/vec3/`)

### Mesh Modify / Deform Stack `[scene] [visual] [authoring]`
- **Coverage:** tixl ✓, cab ✓, wz ✓ (35+ ops, the single biggest family in Wz4) + t3 ✓ (modifiers) + toxi ✓ (subdivision + smoothing + Laplacian) + orx Partial
- **Critical finding:** Werkkzeug's modifier stack is the single largest enabler of `.kkrieger`-scale procedural geometry. Without it, mesh authoring is stuck at primitives.
- **Representative ops:** `Subdivide`, `Extrude`, `ExtrudeNormal`, `Bend`, `Bevel`, `Displace`, `Noise`, `Mirror`, `Center`, `Splitter`, `Dual`, `Heal`, `Deform`, `Chunks`, `Triangulate`, `RecomputeNormals`, `FlipNormals`, `CombineMeshes`, `BlendMeshVertices`, `TransformMeshUVs`, `ScatterMeshFaces` (wz + tixl)
- **Subfamily — subdivision strategies as port-level values:** `MidpointSubdivision`, `DualSubdivision`, `NormalDisplacementSubdivision`, `CentroidSubdiv`, `TriSubdivision`, `LaplacianSmooth` (toxi `src.core/toxi/geom/mesh/subdiv/`) — **see the Strategy-as-port-level-value pattern below**.

### Mesh Generators Beyond Primitives `[scene] [authoring]`
- **Coverage:** tixl ✓ (`ExtrudeCurves`, `RepeatMeshAtPoints`, `Text3D`, `Path3D`), cab ✓ (`HeightMap`, `ParametricSurface`, `SplineMesh`, `TextMesh`), vvvv ✓, wz ✓ (`Text3D`, `Path3D`), orx ✓ (revolve/sweep DSL), t3 ✓ (`LatheGeometry`, `ExtrudeGeometry`, `ShapeGeometry`, `TubeGeometry`, `DecalGeometry`, `TextGeometry`, `ParametricGeometry`), toxi ✓ (`SurfaceMeshBuilder` + NURBS + sweep)
- **Critical finding:** 7/8 refs ship more than fixed-shape primitives. The most under-called subfamily across all refs combined is **sweep/extrude/loft** (`Polygon2D.extrude`, `NurbsCreator.createExtrusion`, `LatheGeometry`, `TubeGeometry`) — the only path to cables, pipes, fences, rails, hair, fabric folds in pure data.
- **Representative ops:** sweep/extrude/loft along curves; lathe/revolve; text-to-3D; path-to-mesh; parametric U/V surfaces.

### Mesh Loaders (glTF / OBJ / FBX / etc) `[scene]`
- **Coverage:** tixl ✓, cab ✓ (full glTF *family*: scene/hierarchy/node/animation/skin/morph/draco), vvvv ✓ (FBX/glTF/OBJ/STL/PLY/DAE/blend), wz ✓ (XSI + Import), orx ✓ (orx-obj-loader, orx-dnk3 glTF), t3 ✓ (>20 loaders in `examples/jsm/loaders/`), of ✓ (Assimp), toxi ✓ (STL/OBJ/PLY)
- **Coverage: 8/8 — universal.** This is the only family that appears in every reference.
- **Critical finding:** loaders are not one operator but an **extensible family** with per-format plugins (three.js GLTFLoader extensions: KHR_draco / KHR_materials_clearcoat / etc.). Flux's deferred LoadMeshOp should be a family from day 1, not a single op.

### Camera Family (orbit / first-person / cube / array / stereo) `[scene] [visual]`
- **Coverage:** tixl ✓ (`OrbitCamera`, `ActionCamera`, `BlendCameras`, `ShiftCamera`, `ReuseCamera`), cab ✓ (orbit/WASD/look-at/quaternion/device-orientation), vvvv ✓, wz ✓ (`BillboardCamera`), orx ✓ (`OrbitalCamera` + bound controls), t3 ✓ (`CubeCamera`, `StereoCamera`, `ArrayCamera`, plus `OrbitControls`/`FlyControls`/`FirstPersonControls`/`TrackballControls`/`PointerLockControls`/`ArcballControls`)
- **Critical finding:** "Cameras with rigs + bound input" is the unit, not "a projection matrix." `CubeCamera` is the env-capture path; `ArrayCamera` is the multi-viewport / VR / shadow-cascade primitive. **6/8 refs ship cube/array camera variants** — these are how multi-view rendering works.
- **Flux state:** Perspective/Ortho/LookAt views exist (shipped 2026-05-21). Cube/array/stereo, orbit/follow/dolly/jitter/shake, smooth-damp, input-bound rigs all missing.

### Materials (Composable Shading Layers) `[visual]`
- **Coverage:** tixl ✓ (`DefineMaterials`/`SetMaterial`/`UseMaterial`), cab ✓ (PBR + clear-coat + thin-film + alpha-mode as one op), vvvv ✓ (layered: diffuse/specular/normal/displacement/emissive/metalness/glossiness/tessellation), wz ✓ (~35-op modular shader graph: `ModShader` + `ModShaderSampler`), orx ✓ (ShadeStyle DSL), t3 ✓ (`MeshStandardMaterial`/`MeshPhysicalMaterial`/`MeshToonMaterial`/`MeshMatcapMaterial`/`MeshNormalMaterial`/`ShadowMaterial`/`SpriteMaterial`)
- **Critical finding:** **Materials are *themselves* nodal subgraphs in Werkkzeug** (35 component ops feed into one assembled material). A "PBR material" is not a single port-bag — it's a graph. Cab packs all the PBR knobs (RGBA diffuse + roughness + metalness + alpha-mode + clear-coat + thin-film + per-channel textures) into one op with many inputs.

### Lighting (As Operators, Not Just Types) `[visual]`
- **Coverage:** tixl ✓ (`SetPointLight`, `SetEnvironment`, `SetShadow`, `SetFog`, `_ComputeBRDFLookup`), cab ✓ (Ambient/Directional/Point/Spot + `ResetLights` + `PbrEnvironmentLight`), vvvv ✓ (Point/Spot/Directional/Ambient/Skybox/Probe), wz ✓ (in material), t3 ✓ (`AmbientLight`/`DirectionalLight`/`PointLight`/`SpotLight`/`HemisphereLight`/`RectAreaLight`/`LightProbe`/IES)
- **Flux state:** `PointLight` *type* exists on `EvalContext`; **no lighting operators of any kind.**

### Shadows / Shadow Maps `[visual] [scene]`
- **Coverage:** tixl ✓, cab ✓ (Shadow ShaderEffect), vvvv ✓ (ShadowCaster render stages), wz ✓ (ShadowGrab in material), t3 ✓ (`DirectionalLightShadow`/`SpotLightShadow`/`PointLightShadow` + CSM cascaded shadow maps + TSL `TileShadowNode`)
- **Critical finding:** Cascaded shadow maps (CSM) are AAA-class for sun lights covering kilometer-scale scenes — three.js ships them as `examples/jsm/csm/` (i.e. as an add-on pack, not core). This is also where flux's missing `array camera` / `multi-view` plumbing gets used.

### Post-Processing Pass Stack `[visual]`
- **Coverage:** tixl ✓ (DoF/MotionBlur/SSAO/GodRays/TemporalAccumulation/Bloom/Glow/StarGlowStreaks/LightRaysFx/ChromaticAbberation/Fxaa/ToneMapping/ColorGrade/ColorGradeDepth), cab ✓ (**107 unique post ops** in ImageCompose chain), vvvv ✓ (`ColorTransformGroupNode`/`CustomPostFX`/`ApplyImageEffect`), wz ✓ (15-op IPP stack: ColorCorrect/Blur/DoF*/SSAO/ColorBalance/ColorGrade/CrashZoom/CrackFixer/FXAA3/ColorMath/Sharpen/Bloom/Promist/Glow/FocusBlur/CustomIPP/Glitch2D/BlockTransition/VideoDistort/GrabScreen), orx ✓ (orx-fx: ~50 named effects), t3 ✓ (legacy `EffectComposer` chain: Bloom/UnrealBloom/FXAA/SMAA/SSAA/TAA/SSAO/SAO/GTAO/SSR/Bokeh/Dot/Halftone/Film/Glitch/Afterimage/Pixelated/LUT/Outline; plus modern TSL list adding SSGI/SSS/TRAA/MotionBlur/ChromaticAberration/Anamorphic)
- **Coverage: 6/8.** Single largest visual-fidelity family in the inventory.
- **Critical finding:** **The TSL list (`three.js examples/jsm/tsl/display/`) is the more current "what AAA post-stack needs":** SSGI, SSS, TRAA, MotionBlur, ChromaticAberration, Anamorphic. Use this list for tier ranking, not the legacy `examples/jsm/postprocessing/`.
- **Sub-pattern: EffectComposer pass-chain** is itself an authoring pattern (RenderPass → Bloom → ToneMap → OutputPass) worth importing as an explicit graph convention.

### Cubemap / Environment / IBL `[visual]`
- **Coverage:** tixl ✓ (`TextureToCubeMap` + BRDF LUT), cab ✓ (`CubeMapFromTextures`, `RenderToCubemap`, `EquirectangularTextureToCubemap`, `Skybox`, `CubeMapMaterial`), vvvv ✓ (`LightSkybox`/`LightProbe`), wz ✓ (`Wz4Cubemap` ops), t3 ✓ (PMREM + `RoomEnvironment` + `GroundedSkybox` + `Sky` + HDR/RGBE/EXR loaders)
- **Critical finding:** **PMREM** (prefiltered mipmap env maps per roughness level) is the canonical IBL technique and an *asset-time* pass, distinct from the per-frame graph — a load-bearing distinction for flux's pre-load phase.

### Skeletal Animation / Skinning `[scene] [visual]`
- **Coverage:** cab ✓ (glTF Skin + VertexAnim + Morph), vvvv ✓ (via Stride), wz ✓ (`Wz4Skeleton`, `BoneChain`, `BakeAnim`, `FakeBone`, `BurnAnim`, `BakeMorph`, `MergeAnim`, `CompressAnim`, XSI import), orx ✓ (dnk3 skinning), t3 ✓ (`SkinnedMesh`/`Skeleton`/`Bone` + `AnimationMixer`/`AnimationAction`/`AnimationClip` + `CCDIKSolver` + `SkeletonUtils`), of ✓ (`ofxAssimpSkeleton`/`ofxAssimpAnimationMixer`)
- **Coverage: 6/8.** Decima-class scenes are character-driven; this is mandatory.
- **Critical finding:** Even Werkkzeug — the "procedural-everything" tool — gave up on procedural-generating character animation and shipped an XSI importer + animation-compression pipeline. The lesson: skeletal animation is the part of "procedural everything" you don't actually do procedurally.

### Animation Filters & Generators (LFO / Damper / Spring) `[authoring]`
- **Coverage:** tixl ✓ (`Damp`, `DampAngle`, `Spring`, `Ease`, `SmoothStep`, `Accumulator`, `DetectPulse`, `PeakLevel`, `AnimValue`, `OscillateVec3`, `SequenceAnim`, `TriggerAnim`), cab ✓ (LFO, Spring, Smooth, Snap, RandomWalk, Crossfade, Timer, FrameRange, Bang, TimeDelta), vvvv ✓ (LFO/Stopwatch/Ramp/Damper/Oscillator/parabola), orx ✓ (orx-envelopes ADSR + orx-time-operators LFO/Envelope + orx-timer), toxi ✓ (FM/AM/saw/triangle/square waves + `InterpolateStrategy` family)
- **Coverage: 5/8.** Distinct from keyframe curves: these are live-signal *filters* (input → smoothed/lagged/oscillated output).
- **Flux state:** TypedCurve keyframes exist; live-signal filters don't.

### Timeline / Clip / Playback Control `[authoring]`
- **Coverage:** tixl ✓ (`TimeClip`, `SetPlaybackTime`, `SetPlaybackSpeed`, `RunTime`, `StopWatch`, BPM/Link/MIDI-time/scrub), cab ✓ (12 ops: Anim/AnimGetKey/AnimGetValue/AnimInfo/TimeLineControls/GotoFrame/PreRender/DemoPrerender/AutoPlay/TimeLineLoop), vvvv ✓ (`VL.Kairos`/`Tilda`/`VL.Interpolator`/`VL.LoopTool`), wz ✓ (`Clip`/`ClipRandomizer`/`MultiClip`/`Fader`/`Beat`/`Variable` + `Wz4TimelineCed` custom editor), orx ✓ (orx-keyframer JSON timelines + orx-fcurve SVG-path syntax), t3 ✓ (`AnimationMixer`/`AnimationAction`/`AnimationClip`)
- **Coverage: 6/8.**

### Procedural Texture Sources + Filter Chain `[visual] [authoring]`
- **Coverage:** tixl ✓ (`LinearGradient`, `RadialGradient`, `Blob`, `CheckerBoard`, `FractalNoise`, `WorleyNoise`, `MandelbrotFractal` + ~30 image stylize/distort/feedback ops), cab ✓ (CircleTexture, RectangleTexture, GridTexture, Plasma, Gradient, RGB noise variants, etc.), vvvv ✓ (TextureFX: ~70 effects across Sources/Filters/Mixers — gradient, noise, halo, mandelbrot, bubble, color palette + filter zoo), wz ✓ (37-op bitmap stack: Flat/Perlin/Cell/Gradient/Bricks/Dots/Text + color/HSCB/blur/distort/bump/light/normals/mask/merge filters)
- **Coverage: 4/4 node-paradigm refs.**
- **Critical finding:** `.kkrieger` shipped **zero baked texture files** — every wall/floor/skin is a procedural filter chain. This family is **the** prerequisite for "1000-op project without 1000 image assets."

### 2D / Image Compositing `[visual] [authoring]`
- **Coverage:** tixl ✓ (`Blend`/`BlendImages`/`BlendWithMask`/`Combine3Images`/`Layer2d`/`PickTexture`/`SwapTextures`/`FirstValidTexture`/`KeepInTextureArray`), cab ✓ (under ImageCompose), vvvv ✓ (Skia layers + TextureFX Mixers), wz ✓ (bitmap stack), orx ✓ (orx-compositor `compose { layer { ... } }` + orx-fx/blend Photoshop+Porter-Duff blend kernels: Multiply/Screen/Overlay/ColorBurn/SourceIn/SourceOut/SourceAtop/DestinationIn/DestinationOut/DestinationAtop/Xor), t3 ✓ (TSL BlendModes)
- **Coverage: 6/8.**

### Input Devices (Mouse / Keyboard / Touch / Gamepad / MIDI) `[authoring]`
- **Coverage:** tixl ✓ (MidiInput/MidiControlOutput + camera tracking PosiStage/FreeD), cab ✓ (**60 ops** typed per device: Mouse/MouseDrag/Wheel/PointerLock + KeyPress/CursorKeys/PersonController + GamePad joystick + TouchScreen/TouchGesture + Midi Input/Output/CC/NRPN/Note/Clock/Chord + browser sensors), vvvv ✓ (Mouse/Keyboard/Touch/Gestures + global hooks + $Q gesture recognizer), orx ✓ (orx-midi `controlChanged.listen` + orx-osc), t3 ✓ (`Raycaster` + `SelectionBox` + `HTMLMesh` + `DragControls`/`TransformControls`), of ✓ (full `ofEvents` system), toxi ✓ (Processing's serial/io/net)
- **Coverage: 7/8.**

### Audio I/O + FFT / Spectrum Analysis `[authoring]`
- **Coverage:** tixl ✓ (AudioReaction), cab ✓ (36 ops: AudioBufferPlayer/AnalyzerTexture/FFTAreaAverage/ClockSequencer/MicrophoneIn/Convolver/BiquadFilter/Mixer/AudioRecorder), vvvv ✓ (WASAPI/ASIO + playback/recording + FFT/Beat/Pitch + modular synthesis + LTC timecode + FMOD + MIDI in/out + SuperCollider), wz ✓ (`AudioRMS`/`AudioSpectogram` + V2 synth + Beat trigger), orx ✓ (orx-fft + orx-minim OpenAL), t3 ✓ (Audio/PositionalAudio/AudioListener/AudioAnalyser), of ✓ (`ofSoundStream`/`ofSoundBuffer`/`ofSoundPlayer` + `getSpectrum(bands)` + RMS)
- **Coverage: 7/8.**
- **Cross-domain pattern:** cables' `AnalyzerTexture` writes FFT/waveform **into a texture** so the rest of the visual graph consumes audio as texture data. Clean cross-domain bridge.

### Video Capture / Playback `[scene]`
- **Coverage:** tixl ✓ (VideoDeviceInput/VideoStreamInput/PlayVideo + Spout/NDI), cab ✓ (VideoTexture/WebcamTexture), vvvv ✓ (Decklink/uEye/IDS/DSLR + GStreamer + Spout/NDI + ImagePlayer + HapPlayer), orx ✓ (orx-kinect-v1 + orx-depth-camera + FFmpeg), t3 ✓ (`VideoTexture`/`VideoFrameTexture`), of ✓ (`ofVideoGrabber`/`ofVideoPlayer` per OS: AVFoundation/DirectShow/GStreamer)
- **Coverage: 5/8.**

### Text Rendering / Typography `[visual]`
- **Coverage:** tixl ✓ (`Text`/`TextOutlines2`/`TextSprites`/`LineTextPoints`), cab ✓ (MSDF font + TextMesh), vvvv ✓ (Skia text + VL.RichTextKit), wz ✓ (`ChaosFont` procedural fonts + `Text3D` + `Text` bitmap + `TronFont`/`TronPrint`), orx ✓ (FontMap + orx-text-writer + orx-text-on-contour), t3 ✓ (TextGeometry + FontLoader + TTFLoader), of ✓ (`ofTrueTypeFont`/`ofBitmapFont`)
- **Coverage: 7/8.**

### Color (Palettes, Theory, Spaces, OKLCh) `[visual] [authoring]`
- **Coverage:** tixl ✓ (HSB/HSL/OKLCh constructors + gradient/blend/sample + `PickColorFromImage`/`PickColorFromList`/`CombineColorLists`), cab ✓ (`ColorPalettes`/`Gradient`/`HSL`/`HEX`/`LuminanceContrast`), vvvv ✓ (`VL.ColorBlender`/`VL.ColorThief`/`VL.Unicolour`/`VL.OCIO`), orx ✓ (orx-color presets + histograms + orx-palette + OkLab conversions), t3 ✓ (ColorManagement + ACES/AgX tonemap + LUT3D), toxi ✓ (**the deepest reference** — `ColorTheoryRegistry` with Complementary/Triadic/Analogous/SplitComplementary/Tetrad/Monochrome/Compound strategies + `TColor`/`ColorList`/`ColorRange`/`Histogram`/`ToneMap`/`NamedColor`)
- **Coverage: 6/8.**
- **Critical finding:** "Generate 5 analogous colors of saturation 0.6" is one operator's worth of authoring leverage. **toxi's ColorTheoryRegistry is uniquely deep** and the closest reference for what a palette-generation family should look like.

### Math Primitives (Frustum / Quaternion / Bounding / SH) `[visual] [scene]`
- **Coverage:** tixl Partial (only vec3 math + matrix), cab ✓ (Quaternion + matrix invert/interpolate), vvvv ✓ (Vec2/3/4, Matrix/Quaternion, AlignedBox, OrientedBoundingBox, BoundingFrustum, Ray, simplex/perlin/value noise, Voronoi/Delaunay), wz ✗, orx ✓ (orx-math complex/RBF/expression-evaluator), t3 ✓ (Frustum/FrustumArray/Box2/Box3/Sphere/Plane/Ray/Triangle/Line3/Spherical/Cylindrical/SphericalHarmonics3), toxi ✓ (full math: vectors/matrices/intersectors/polygon-clip/splines)
- **Critical finding:** **`SphericalHarmonics3`** is the IBL irradiance representation; **`Frustum`** + **`Box3`** + **`Sphere`** are the bones of culling. These are all present in three.js. Flux has Matrix4; the supporting cast is largely missing.

### Noise (Multi-Kind + FBM + Polar Wrappers) `[scene] [visual]`
- **Coverage:** tixl ✓ (FractalNoise/WorleyNoise/TileableNoise/ShardNoise), cab ✓ (Plasma/Noise + Simplex), vvvv ✓ (FastNoise/FastNoiseLite/SharpNoise/FastNoise2), wz ✓ (Perlin + Cell), orx ✓ (orx-noise Perlin/Simplex/Value/Worley/uniform + `.fbm()` + `.withPolarInput()` combinators), toxi ✓ (Perlin/Simplex/FM/AM wave combinators)
- **Coverage: 6/8.**
- **Flux state:** has Perlin 2D + 3D + Random. Missing: Simplex/Value/Worley, FBM as combinator, polar wrappers, FM/AM oscillators.

### GPU Compute / GPGPU Building Blocks `[visual] [scene]`
- **Coverage:** tixl ✓ (`PrefixSum`, `ComputeShader`, `CalcDispatchCount`, `FloatsToBuffer`, `ListToBuffer`, `IsBufferDirty`, `UseFallbackBuffer`), cab ✓ (WebGpu extension: ComputeStorageInput/Output, Pipeline, ArrayToGpuBuffer), vvvv ✓ (ComputeFX + MeshDrawIndirect + MipMapGenerator), t3 ✓ (`GPUComputationRenderer` + `BitonicSort` + TSL `ComputeNode`/`AtomicFunctionNode`/`BarrierNode`/`WorkgroupInfoNode`/`SubgroupFunctionNode`/`ComputeBuiltinNode`)
- **Critical finding:** the family flux is closest to today, but missing **`DrawIndirect`/`DrawIndexedIndirect`** (DispatchIndirect exists), `PrefixSum`/`BitonicSort` as primitives, and defensive resource ops (`FirstValidTexture`/`UseFallbackBuffer`).

### Trigger / Switch / Gate / Sample-Hold / State `[authoring]`
- **Coverage:** tixl ✓ (`Switch`/`Loop`/`Once`/`ExecuteOnce`/`ExecRepeatedly`/`ResetSubtreeTrigger`/`BlendScenes` + `Accumulator`/`DetectPulse`), cab ✓ (**51 trigger ops:** Sequence/Repeat/Threshold/Gate/Switch/Route/Distribute/SendNamed/Receive/Counter/Interval/Delayed/OnChange/Probability/MonoFlop/Nth + Boolean.If/Or/And/Toggle), vvvv ✓ (FlipFlop/MonoFlop/TogEdge/Switch/TypeSwitch + `VL.AutomataUI` state machine)
- **Coverage: 3-4/8 — but UNIVERSAL in node-paradigm refs.**
- **Flux state:** `Region::Loop` exists; **no Condition/Switch/Trigger/Gate/Sample-Hold operators of any kind.**
- **Deeper gap:** flux has no concept-level slot for *stateful-per-instance* operators (vvvv's Process-vs-Operation distinction) — see Patterns section.

### Helpers / Debug Visualization `[authoring]`
- **Coverage:** tixl ✓ (`DrawBoxGizmo`/`DrawSphereGizmo`/`DrawLineGrid`/`GridPlane`/`Locator`/`DrawCamGizmos`/`PlotValueCurve`/`UVsViewer`/`VisualizeMesh`/`VisualizePoints`/`VisualizeFieldDistance`), cab ✓ (VizNumber/VizString/VizBool/VizTexture/VizGraph/VizArrayChart/VizArrayTable + Console + ProfileGL + **BranchProfiler bracket-region timing**), t3 ✓ (`AxesHelper`/`GridHelper`/`PolarGridHelper`/`BoxHelper`/`Box3Helper`/`PlaneHelper`/`CameraHelper`/`DirectionalLightHelper`/`PointLightHelper`/`SpotLightHelper`/`HemisphereLightHelper`/`SkeletonHelper`/`ArrowHelper`/`VertexNormalsHelper`/`VertexTangentsHelper`/`RectAreaLightHelper`/`LightProbeHelper`/`OctreeHelper`/`TextureHelper`/`ViewHelper`)
- **Coverage: 4/8.**
- **Critical finding:** at 1000-op scale, "I can't see why this light isn't hitting that mesh" needs in-viewport debug overlays. cables' **BranchProfiler-bracket-region inline timing** generalizes GpuTimer to the operator-graph layer.

### Parameter UI / Auto-GUI / Sliders `[authoring]`
- **Coverage:** cab ✓ (38 Sidebar ops: Sidebar/Slider/Toggle/XYPad/Presets/ColorPicker/DropDown/NumberInput/SidebarVariables/Group/SidebarText), vvvv ✓ (ImGui as nodes), wz ✓ (parameter editor per op with `customed = Wz4*Ced` custom widgets), orx ✓ (orx-gui + orx-parameters annotation-driven UI + orx-rabbit-control web variant), of ✓ (`ofParameter`/`ofParameterGroup` + `ofxPanel`/`ofxSlider`/`ofxToggle`/`ofxColorPicker`)
- **Coverage: 5/8.**
- **Critical finding:** **OF's `ofxOscParameterSync`** auto-mirrors the *same typed parameter object* over OSC bidirectionally. The flux analog: "every operator port is OSC-addressable by graph path for free" — a remote-control surface that costs nothing because the typed ports already exist.

### Named Channels / Cross-Graph Wiring (1000-op Scaling Answer) `[authoring]`
- **Coverage:** tixl ✓ (`Variable`/`Spline` as named globals referenced from inline scripts), cab ✓ (29 typed `VarSet*`/`VarGet*` ops + `TriggerSendNamed`/`TriggerReceive`), vvvv ✓ (`ChannelHub` + `PublicChannelDescription` + the basis for RCP remote control), wz ✓ (`Variable`/`Spline` referenced from inline scripts)
- **Coverage: 4/8 — but ALL FOUR node-paradigm refs ship it.**
- **Critical finding:** This is the converged answer to "1000-op projects can't wire everything point-to-point." Flux has nothing analogous. **High-priority pattern to design before the operator count grows further.**

### Subgraph Composition + Routing + Templates `[authoring]`
- **Coverage:** tixl ✓ (subgraphs as operators), cab ✓ (`SubPatch`/`SubPatchInput`/`SubPatchOutput`/`Subpatch2Template` + typed `Route*` ops + `*MultiPort` variadic variants), vvvv ✓ (`Patch-Defines-Node` + Help-Patch system + Aspects/category hiding)
- **Critical finding:** cab's **typed Route ops** (one input → many outputs by selector, or vice versa) + **`*MultiPort` variadic variants** are explicit fanout/fanin nodes that make data movement legible at scale. Flux has Symbol/Instance subgraphs but no Route family.

---

## Likely-missing families

Present in 2/3 primary or split coverage. Worth investigating but lower priority than confirmed-missing.

### Curves & Splines (Geometric, Port-Type) `[visual] [authoring]`
- **Coverage:** tixl (Spline in render tree), wz (Spline as named global), orx ✓ (2D Shape & Contour Math + orx-shapes), t3 ✓ (CatmullRomCurve3/CubicBezier/QuadraticBezier/Ellipse/Spline/Line3/Arc + NURBSCurve/NURBSSurface/NURBSVolume), toxi ✓ (BezierCurve2D/3D + Spline2D/3D + LineStrip2D/3D + BasicNurbsCurve)
- **Critical finding:** Curves are the missing port type behind **sweep / lathe / instance-along-path / particle-paths / camera-rails / motion-graphic-strokes**. Adding `Curve` as a value type unlocks an entire downstream family. **Probably should be a Tier-2 gap.**

### Point-Cloud / Spread Substrate `[scene] [authoring]`
- **Coverage:** tixl ✓ (**THE biggest single category** — generate/modify/transform/combine/draw/sim subtrees for `Point` type: `GridPoints`/`HexGridPoints`/`SpherePoints`/`RadialPoints`/`LinePoints`/`PointsOnMesh`/`PointsOnImage`/`PointTrail`; modifiers `RandomizePoints`/`AddNoise`/`MoveToSDF`/`FilterPoints`/`MapPointAttributes`/`ResampleLinePoints`; transforms `OrientPoints`/`SnapPointsToGrid`/`WrapPoints`; draws `DrawPoints`/`DrawLines`/`DrawRibbons`/`DrawTubes`/`DrawBillboards`/`DrawMeshAtPoints`), cab ✓ (PointArray.* in spread family), vvvv ✓ (Spreads as the load-bearing pattern), t3 ✓ (Points/PointsMaterial)
- **Coverage: 4/8 — but THE biggest cluster in tixl, central concept in vvvv.**
- **Critical finding:** This is how you author lines/ribbons/sprite-swarms/instanced-meshes/connection-diagrams without writing geometry shaders. **Strong candidate for a Tier-2 substrate decision.**

### Instancing / DrawIndirect / Multiply `[scene]`
- **Coverage:** tixl ✓ (`DrawInstancedIndirect`), cab ✓ (`MeshInstancerFromTexture` — GPU-driven instancing), vvvv ✓ (`MeshDrawIndirect` as first-class node), wz ✓ (**`Multiply` — the procedural-AAA primitive**: `Count(1..1024)` + delta-transform), t3 ✓ (`InstancedMesh`/`BatchedMesh` as object types)
- **Coverage: 5/8 — universal among node-paradigm refs.**
- **Critical finding:** Werkkzeug's `Multiply` is the single most-leveraged op in `.kkrieger`-style productions. **One node + Count + delta transform = 1024 draws.** Without this family, flux's "1000-op project" caps at "1 visible element per op."

### Vector Graphics / SVG / 2D Shape Algebra `[authoring] [visual]`
- **Coverage:** vvvv ✓ (full Skia 2D as nodes: paths/primitives/SVG/Lottie/PDF/SVG/PNG export + layout via Yoga + RichTextKit + widget toolkit Elementa), orx ✓ (SVG load/save + 2D Shape boolean ops + Triangulator), t3 ✓ (SVGLoader + SVGRenderer), of ✓ (`ofxSvg` + `ofPath` + `ofCairoRenderer`), toxi ✓ (PDF/SVG/DXF export)
- **Coverage: 5/8.**
- **Flux state:** textures-only as 2D primitive. Vector paths as a port type would unlock print pipelines, parametric type, plotter output, motion-graphics strokes, PDF/SVG export.

### SDF / Volumetric / Iso-Surface Modeling `[scene] [visual]`
- **Coverage:** tixl ✓ (full SDF family — `BoxSDF`/`SphereSDF`/`TorusSDF`/`CapsuleLineSDF`/`OctahedronSDF`/`FractalSDF`/`HeightMapSdf`/`Image2dSDF`/`CustomSDF`/`CombineSDF`/`BlendSDFWithSDF`/`StairCombineSDF`/`RotateField`/`TwistField`/`BendField`/`RepeatAxis`/`RepeatPolar`/`ReflectField`/`TransformField`/`RaymarchField`/`Render2dField`/`SampleFieldPoints` + `MoveToSDF`), wz ✓ (`Wz4ADF`/`Wz4PDF` SDF types + `Cube`/`Sphere` SDF primitives + `Add`/`Multiply`/`Transform`/`Twirl`/`Merge`/`FromADF`), t3 ✓ (MarchingCubes), toxi ✓ (`VolumetricSpace`/`VolumetricHashMap` + `RoundBrush`/`BoxBrush`/`PeakBrush` × `AdditiveBrush`/`MultiplyBrush`/`ReplaceBrush` + `IsoSurface`/`HashIsoSurface` + `MeshVoxelizer`), orx Partial (orx-jumpflood — 2D distance field)
- **Coverage: 5/8 — but 4 of those are deep, dedicated families.**
- **Critical finding:** SDF/Field is essentially a **fourth scene substrate alongside Mesh / Point / Particle** in tixl. Procedural blob characters, organic geometry, boolean modeling, raymarched terrain all live here.

### Particle Systems `[scene] [visual]`
- **Coverage:** tixl ✓ (`ParticleSystem` + force ops: `TurbulenceForce`/`CollisionForce`/`DirectionalForce`/`VectorFieldForce`/`FieldDistanceForce`/`VerletRibbonForce`/`VelocityForce`/`ReconstructiveForce`/`SnapToAnglesForce` + `PointSimulation` + `SimNoiseOffset`/`SimForceOffset`/`SimCentricalOffset`), cab ✓ (GlParticles extension), wz ✓ (Cloud/Cloud2/Mesh/FromVertex/FromMesh/StaticParticles/Ballistic/Lissajous/Exploder + Wobble/Add/SplinedParticles/Trails/Bulge/Sparcle/Morph + Sprites/Chunks/Debris/ExplodeChunks/Trails/Metaballs/MarchingCubes/MarchingCubesColor), toxi ✓ (Verlet — different but related)
- **Coverage: 4/8 (3 of 4 primary refs).**
- **Critical finding:** **Particles + composable forces** is a defining creative-coding capability — the force-as-node pattern lets authors compose simulations without writing compute shaders. Werkkzeug's `Debris(Wz4Particles, Wz4Mesh)` op (turn a mesh into N particle-borne chunks) is the most famous Farbrausch transition effect.

### Verlet / Physics-Lite for Secondary Motion `[scene] [visual] [authoring]`
- **Coverage:** vvvv ✓ (Bullet rigid bodies + collider shapes — experimental), cab ✓ (Ammo/Cannon extensions), t3 ✓ (Ammo/Jolt/Rapier wrappers), toxi ✓ (**deepest reference** — VerletPhysics 2D + 3D + particles/springs/constraints — Plane/Box/Cylinder/Sphere/Axis/Angular/Polygon + AttractionBehavior/GravityBehavior + ParticleString/ParticlePath)
- **Coverage: 4/8.**
- **Critical finding:** **Verlet is the right physics for creative-coding/Decima — cheap, stable, matches operator-graph mental model (particle pool + force-accumulator + constraint chain).** Distinct from a rigid-body engine. Direct path to cloth/rope/hair/jiggle/dangling-cargo-secondary-motion (Death-Stranding-style). **Ship Verlet *before* rigid-body — far cheaper, more universal in creative work.**

### Computational Geometry (Voronoi / Delaunay / MarchingSquares) `[scene] [visual]`
- **Coverage:** vvvv ✓ (`VL.2d.Voronoi`/`VL.2D.CurveFitting`/`VL.2D.Simplify`), orx ✓ (orx-triangulation Delaunay+Voronoi + orx-marching-squares + orx-jumpflood + orx-integral-image), toxi ✓ (Voronoi + DelaunayTriangulation + GridTesselator/PolygonTesselator)
- **Coverage: 3/8.**
- **Critical finding:** Voronoi+Delaunay drives biological/cellular/crystalline generative imagery; jump-flood is the GPU compute pattern for 2D distance fields. **Reference-specific but distinctive for generative work; recommend a single GPU-implemented op family.**

### Spatial Indices (kd-tree / Octree / Hash Grid) `[scene]`
- **Coverage:** orx ✓ (orx-quadtree/orx-hash-grid/orx-kdtree/orx-interval-tree), t3 ✓ (`Frustum`/`Box3`/`Sphere`/`OctreeHelper` + SceneOptimizer/GeometryCompressionUtils/SortUtils/WorkerPool), toxi ✓ (`PointOctree`/`PointQuadtree`/`SpatialBins`/`SpatialIndex`/`IndexedTriangleMesh`)
- **Coverage: 3/8.**
- **Critical finding:** At Decima scale (thousands of instances/particles/lights), every "find neighbours within radius" or "is this visible from here" query needs spatial acceleration. **Three.js/orx/toxi all expose these as plain data structures, separate from rendering** — flux should decide whether spatial indices are operator-graph values or per-operator cached state.

### Intersection / Raycast / Picking `[scene] [authoring]`
- **Coverage:** t3 ✓ (`Raycaster`), toxi ✓ (Ray3D/TriangleIntersector/SphereIntersectorReflector/BoxIntersector/PlaneIntersector + `BooleanShapeBuilder`/`SutherlandHodgemanClipper`)
- **Coverage: 2/8.**
- **Critical finding:** Surprisingly only 2 references — but flux **will** need this for any viewport-editing affordance, mouse picking, or interaction-from-data authoring (ray-from-camera hits mesh → trigger that).

### Auxiliary Renderers (Non-Raster Output Paths) `[visual]`
- **Coverage:** cab ✓ (121-op HTML/DOM/CSS family — a second renderer peer to GL), vvvv ✓ (Skia 2D as a peer renderer + SkiaRenderer bridges to Stride texture), orx ✓ (Plotter / SVG output), t3 ✓ (CSS2DRenderer/CSS3DRenderer/SVGRenderer), toxi ✓ (PDF/SVG/DXF export via PGraphics subclasses)
- **Coverage: 5/8.**
- **Cross-cutting pattern:** mature frameworks ship **multiple renderer outputs** (raster + DOM + vector + plotter) addressing the same scene description. flux is wgpu-only today.

### Extension Pack / Plugin Mechanism `[authoring]`
- **Coverage:** cab ✓ (28 extension packs under `extensions/` — physics, ML, WebGPU, particles, generators), vvvv ✓ (nuget packages = node packs), wz ✓ (per-production `.ops` files: `fr033_ops.ops`/`fr062_ops.ops`/etc.), orx ✓ (orx modules), of ✓ (`ofx*` addon ecosystem)
- **Coverage: 5/8.**
- **Critical finding:** **Mature node-graph frameworks ship heavy capabilities as extensions, not core.** Three.js does the same with `examples/jsm/` — even CSM (cascaded shadow maps), TiledLighting, and the entire post-stack live there. Precedent for flux to keep its core operator catalog small and ship AAA capabilities as packs.

### Hot Reload / File Watcher `[authoring]`
- **Coverage:** vvvv ✓ (shader hot-reload via `_NodeFactory_`), orx ✓ (orx-olive + orx-file-watcher + orx-property-watchers)
- **Coverage: 2/8.**
- **Critical finding:** vvvv calls hot-reload "load-bearing, not nice-to-have" — confirmed by the architectural support (every shader save updates the node, not just the file).

### Inter-App Frame Sharing (Spout / Syphon / NDI) `[authoring]`
- **Coverage:** tixl ✓, vvvv ✓, orx ✓ (orx-syphon)
- **Coverage: 3/8.**
- Note: installation-art / VJ specific. Worth tracking but Tier 5.

### Multi-View / Multi-Window / Multi-Camera Output `[scene] [authoring]`
- **Coverage:** vvvv ✓, orx ✓ (orx-view-box), t3 ✓ (ArrayCamera/StereoCamera)
- **Coverage: 3/8.**
- **Critical finding:** Multi-view (split-screen, picture-in-picture, debug viewports, shadow-cascade outputs) becomes foundational once a single project authors more than one camera's worth of imagery. **Likely Tier-3 in flux's roadmap.**

### Mesh Surface Sampling / Scatter (PointsOnMesh) `[scene] [visual]`
- **Coverage:** tixl ✓ (`PointsOnMesh`/`ScatterMeshFaces`/`MeshFacesPoints`), orx ✓ (orx-mesh-noise)
- **Coverage: 2/8.**
- **Critical finding:** Foliage / debris / scatter authoring depends on this. Even with `Multiply` present, scatter needs a *distribution source* — random points on a surface, weighted by area.

### Structured Data I/O (JSON / XML / CSV / HTTP) `[authoring]`
- **Coverage:** tixl ✓ (String/JSON ops + RequestUrl), cab ✓ (HttpRequest + ObjectMerge + CsvColumnArray + JSON family), vvvv ✓ (Serialization/Markup full coverage), of ✓ (ofXml/ofJson + ofxXmlSettings + ofxPoco)
- **Coverage: 4/8.**
- **Critical finding:** cables treats HTTP/CSV fetching as a *node*, not a host concern. Data-driven scenes (CSV-fed visualizations, JSON-feed dashboards) need parsed-data ops at the graph level.

### Threading / Async Background Work `[scene]`
- **Coverage:** vvvv ✓ (TPL.Dataflow — backpressured pipelines distinct from event-stream observables), of ✓ (`ofThread` + `ofThreadChannel` + `ofxThreadedImageLoader`)
- **Coverage: 2/8.**
- **Critical finding:** **Threading-as-substrate is a quiet AAA gap** — flux's Tier-1 streaming goal is unbuildable without a worker-thread + message-channel primitive **exposed at the graph level**. Most visual-programming refs hide this; OF surfaces it as first-class.

### Time-Domain Range / Distribution / Random `[authoring]`
- **Coverage:** toxi ✓ (FloatRange/IntegerRange/BiasedFloatRange/WeightedRandomSet — distribution shapes as port-level values)
- **Coverage: 1/8 but distinctive.**
- **Critical finding:** "Pick a random scale per instance, weighted toward small, biased above 0.3" is the kind of authoring micro-task that needs one operator with port inputs, not bespoke math per use.

---

## Reference-specific families

Present in only 1–2 references. Note but don't prioritize as confirmed gaps.

### Selection / Mask on Mesh `[scene] [authoring]`
- **Coverage:** wz only (`Select(Wz4Mesh, ?GenBitmap)`/`SelectGrow`/`SelectCube`)
- **Critical finding:** Werkkzeug's own assessment: **without selection masks, the modifier stack is monolithic — every Subdivide applies to the whole mesh.** This is "the difference between interesting blob and kkrieger corridor." Flag for follow-up when mesh-modify family lands.

### Cellular Automata / Reaction-Diffusion / Fluids `[visual] [authoring]`
- **Coverage:** cab (ReactionDiffusion extension), toxi ✓ (CARule + CAWolfram1D + GrayScott + DLA + ThermalErosion + TalusAngleErosion + Stam fluid solvers 2D+3D)
- **Coverage: 2/8 but signature for generative work.** Erosion specifically is required for procedural terrain.

### Computer Vision / Tracking / ML `[authoring]`
- **Coverage:** cab (Mediapipe extension), vvvv ✓ (full OpenCV + MediaPipe + YOLO + ONNX + OpenAI/Ollama), of ✓ (`ofxOpenCv` + `ofxKinect`)
- **Coverage: 3/8.** Out of immediate Decima scope but anchors live-input axis.

### Projection Mapping / Warp+Blend / DMX/Art-Net `[scene] [visual]`
- **Coverage:** vvvv ✓ (`VL.BadMapper`/`VL.Mapper`/`VL.ScalableDisplay`/`VL.VIOSOWarpBlend` + `VL.IO.ArtNet`/`VL.Devices.ENTTEC`/`VL.ILDA`), tixl Partial (DMX/sACN/Artnet ops)
- **Coverage: 2/8.** Installation-art specific; out of Decima scope.

### Per-Shader-File Convention (Auto-Node-From-Shader) `[visual] [authoring]`
- **Coverage:** vvvv ✓ (TextureFX/ShaderFX/DrawFX/ComputeFX — naming suffix + attribute decorators turn shader files into operators automatically)
- **Coverage: 1/8 — but transformative.**
- **Critical finding:** vvvv ships **60+ image-effect nodes without 60 registration sites** by using `*_TextureFX.sdsl` filename convention. Flux has LoadShaderOp at primitive layer but no convention to lift a `.wgsl` into a typed operator. **If flux adopted this pattern alone, it would multiply its visual operator surface 10x+ without a corresponding registry-code surface increase** (per the vvvv inventory's own analysis).

### Tiled / Clustered Lighting `[visual] [scene]`
- **Coverage:** t3 only (`TiledLighting` + TSL `TiledLightsNode` + `TileShadowNode`)
- **Coverage: 1/8 — but AAA-essential.** This is the standard forward+/clustered family for "hundreds of dynamic lights." Tier-3 or 4 for flux.

### VR / XR `[scene] [visual]`
- **Coverage:** vvvv ✓, t3 ✓ (WebXR — `VRButton`/`ARButton`/`XRControllerModelFactory`/`XRHandModelFactory`/`OculusHandModel`/`XRPlanes`/`XREstimatedLight`)
- **Coverage: 2/8.** Out of immediate scope but the **stereo / array-camera / multi-view plumbing it relies on is shared with shadow cascades** — same infrastructure unlocks both.

### Mobile Sensors (Accelerometer / GPS / Gyro) `[scene]`
- **Coverage:** vvvv ✓, of ✓
- **Coverage: 2/8.** Out of scope for desktop Decima target.

### Physical Computing / Serial / GPIO / Microcontroller `[authoring]`
- **Coverage:** vvvv ✓, of ✓ (`ofSerial`/`ofArduino`/Firmata), toxi (Processing)
- **Coverage: 3/8.** Out of scope for Decima target.

### Plotter / Physical Output `[authoring]`
- **Coverage:** orx (orx-axidraw), toxi (DXF/PDF export)
- **Coverage: 2/8.** Out of scope but interesting precedent — "physical output as just-another-sink."

### Databases / Persistence `[authoring]`
- **Coverage:** vvvv ✓ (Redis/InfluxDB), toxi (CSV)
- **Coverage: 2/8.** Out of scope.

### Optimization / Search (Gradient Descent) `[authoring]`
- **Coverage:** orx only (orx-gradient-descent)
- **Coverage: 1/8.** Niche; not Decima-relevant.

---

## AAA-gap section (cross-paradigm: features the creative-coding lineage UNDER-calls)

These are explicitly flagged because the brief noted the 8 references are creative-coding-lineage and will likely under-call AAA-engine features. The investigation confirms most of these are either entirely absent or present in only 1 reference.

### Streaming / Asset Hot-Residency `[scene] [authoring]`
- **Coverage:** none of the 8 references ships this as an operator family.
- **Closest analog:** vvvv has `_NodeFactory_` shader hot-reload + asset cache; OF surfaces `ofxThreadedImageLoader` + `ofThread`/`ofThreadChannel`.
- **AAA reality:** Decima streams hundreds of GB of world data via async I/O + virtual textures + asset residency tracking. **Flux's pre-load phase is a foundation, not the answer.**
- **Speculation (labeled):** flux likely needs an `AssetStreamingRegion` concept that owns async loads + a `StreamingTexture` value type whose contents are "best mip available now."

### Spatial Scene Graph + Culling (Frustum / Occlusion / Portal) `[scene]`
- **Coverage:** vvvv ✓ (ECS scene + render-stage sort modes), t3 Partial (`Frustum`/`OctreeHelper`/`SceneOptimizer` but no production culling pipeline).
- **AAA reality:** Decima uses portal culling + occlusion queries + screen-space occlusion + spatial-hash binning. Three.js's `examples/jsm/` ships utilities but no end-to-end culling.
- **Flux state:** no scene graph at all. **This is the largest single architectural gap** between flux and a Decima-class engine, and it cascades into LOD / streaming / instancing.

### Level-of-Detail (Geometric + Shading) `[scene] [visual]`
- **Coverage:** t3 ✓ (`LOD` object type + `SimplifyModifier` + `GeometryCompressionUtils`).
- **AAA reality:** Decima uses screen-space-error LOD selection + shader LOD (Lumen-equivalent), often combined with virtual geometry / Nanite-like meshlet rendering.
- **Speculation (labeled):** flux's `BoxOp`-style primitives shouldn't expose LOD; loaded meshes should ship as multi-LOD `Value::Mesh` with screen-space selection at draw time.

### GPU-Driven / Indirect / Mesh-Shader Rendering `[scene]`
- **Coverage:** tixl ✓ (`DrawInstancedIndirect`/`PrefixSum`), cab ✓ (WebGpu Pipeline + ComputeStorageInput/Output), vvvv ✓ (`MeshDrawIndirect`), t3 Partial (TSL ComputeNode family).
- **AAA reality:** Visibility-buffer rendering + mesh shaders + GPU-driven culling chains (Nanite, etc.).
- **Flux state:** has `DispatchIndirect` for compute; **missing `DrawIndirect` / `DrawIndexedIndirect`** at the operator level. This is the on-ramp; the rest builds on top.

### Virtual Textures `[scene] [visual]`
- **Coverage:** none of the 8 references — universally absent.
- **AAA reality:** Decima ships sparse-residency virtual texturing; the standard answer to "256GB of terrain detail in 8GB of VRAM."
- **Speculation (labeled):** Out of scope for flux's near-term roadmap but worth scoping as a future Tier-4 family.

### Global Illumination (Probes / Voxel-Cone / Lumen-Like) `[visual]`
- **Coverage:** vvvv ✓ (`LightProbe` component + `VLForwardRenderer.LightProbes.cs`), t3 ✓ (`LightProbe` + `LightProbeGenerator` + `IrradianceNode`).
- **AAA reality:** Decima uses GI probes + screen-space GI + voxel cone tracing. Lumen / RTX-style real-time GI is the current frontier.
- **Note:** Light probes are a stepping stone to GI; both vvvv and three.js have them. Flux could ship probes as a stand-alone family before tackling full GI.

### Skeletal Animation State Machines + Blend Trees `[scene]`
- **Coverage:** of ✓ (`ofxAssimpAnimationMixer`), t3 ✓ (`AnimationMixer`/`AnimationAction` + clip-blending API), vvvv ✓ (`VL.AutomataUI` + Stride animation), wz ✓ (`MergeAnim` + `CompressAnim`).
- **AAA reality:** Decima animation is layered state machines + IK + procedural motion warping + facial animation.
- **Note:** Bare skeletal animation is in the Confirmed-missing list above; **state machines + blend trees on top of it** are the AAA layer. CCDIKSolver in three.js is an IK starting point.

### Decals & Screen-Space Techniques `[visual]`
- **Coverage:** t3 ✓ (`DecalGeometry`), tixl Partial (`Layer2d` + render-pass composition).
- **AAA reality:** Decals (projected textures on geometry — bullet holes, blood, footprints) are a basic AAA pipeline feature. Screen-space techniques (SSR, SSAO, SSGI) are in the post-stack already; decals are different — they live in the scene, not the post-stack.
- **Note:** Likely a small operator family if `DecalGeometry`-style mesh-against-target works at the graph level.

### Multi-View Rendering (Cubemap / Shadow Cascades / Stereo) `[scene] [visual]`
- **Coverage:** cab ✓ (RenderToCubemap), vvvv ✓ (VR + Skybox), wz ✓ (`Wz4Cubemap`), t3 ✓ (`CubeCamera`/`ArrayCamera`/`StereoCamera` + CSM).
- **AAA reality:** Shadow cascades + cube reflections + stereo / multi-eye / multi-frustum rendering all share infrastructure.
- **Note:** **`ArrayCamera`-style multi-view is shared infrastructure for cascaded shadows AND XR.** Worth treating as a single family.

### Tiled / Clustered Forward+ Lighting `[visual]`
- Already called out in Reference-specific above (three.js only). **AAA-essential** for hundreds of dynamic lights.

---

## Revised tier ranking (proposal for flux's gap-analysis.md)

Using flux's existing tier vocabulary (Tier 1 = visible output, Tier 5 = production workflow). This is a proposal for the next refresh of `docs/superpowers/gap-analysis.md`; final placement is flux's call.

### Tier 1 — Visible output

- **Transform / Scene-State Mutators** (revisit design before implementation; render-state-as-scope is the strong evidence) — already in flux's tier list.
- **Player shell** — already flagged.
- **Mesh Modify family (at least: Extrude/Lathe/Sweep/Subdivide)** — the precondition for any non-primitive procedural geometry. Without this, "1000-op project" caps at "1000 boxes."

### Tier 2 — Real content

- **Mesh Loaders (glTF/OBJ + extension-plugin architecture)** — 8/8 universal. Promote from deferred.
- **Particle System** (sources + composable forces + renderers) — present in 3/4 node-paradigm refs; the force-as-node pattern is operator-graph-native.
- **Lighting operators** (Point/Directional/Spot/Hemisphere/RectArea/Probe) — `PointLight` *type* exists; operator family doesn't.
- **Material composition** (PBR + clear-coat + emissive + normal + IBL contribution — possibly as a modular shader graph per Werkkzeug `ModShader`).
- **Skeletal animation + Skinning** — confirmed-missing in 6/8 refs; Decima requires.

### Tier 3 — Dynamic content

- **Animation Filters/Generators** (LFO/Damper/Spring/Accumulator/DetectPulse/PeakLevel) — 5/8.
- **Timeline / Clip / Playback Control** (separate from keyframe curves; needs play/pause/scrub/goto-frame/prerender/autoplay/loop ops) — 6/8.
- **Trigger / Switch / Gate / Sample-Hold operators** — 3/4 node-paradigm. **Plus the underlying Process-vs-Operation design decision.**
- **Input Devices** (Mouse/Keyboard/Touch/Gamepad/MIDI) — 7/8.
- **Camera rigs** (Orbit/FirstPerson/Follow/Smooth-damp + CubeCamera + ArrayCamera) — 6/8.
- **Audio I/O + FFT analysis + Audio-to-Texture bridge** — 7/8.
- **Curves & Splines as port type** (precondition for sweep, instance-along, motion paths).

### Tier 4 — Advanced rendering

- **Post-Processing Pass Stack** (use TSL list as canonical scope: Bloom, FXAA/SMAA/SSAA/TAA/TRAA, SSAO/GTAO/SAO, SSR, SSGI, SSS, DoF, MotionBlur, ChromaticAberration, ToneMap/ACES/AgX, LUT3D, Outline). 6/8.
- **Cubemap / Environment / IBL** (including PMREM pre-process) — 5/8.
- **Shadow Maps** (including CSM cascades for sun lights) — 5/8.
- **DrawIndirect / DrawIndexedIndirect** — present in 4/8, on-ramp for GPU-driven rendering.
- **Multiply / Instancing operator** (single-op-emits-N-draws) — universal in node-paradigm refs; the procedural-AAA scaling primitive.
- **Mesh Surface Sampling / Scatter** (`PointsOnMesh` + weighted distribution) — needed for foliage / debris / instancing.
- **Point-Cloud / Spread Substrate** (parallel scene primitive — biggest family in tixl) — design call: does flux ship a `Point`/`Spread` type alongside `Mesh`?
- **SDF / Volumetric / Iso-Surface modeling** — strong in tixl + wz + toxi; possibly a separate Tier-4 substrate.
- **Tiled / Clustered Lighting** — for hundreds of dynamic lights.
- **Verlet Physics** for secondary motion (cloth/rope/hair/jiggle) — distinct from rigid-body.
- **Helpers / Debug Viz / Gizmos / In-graph viz probes / BranchProfiler bracket-region timing.**

### Tier 5 — Production workflow & scale

- **Named Channels / Cross-graph wiring** — **promote to Tier-3 if 1000-op projects are an active near-term concern** (4/4 node-paradigm refs converged on this).
- **Subgraph routing** (typed Route ops + `*MultiPort` variadic + Subpatch2Template).
- **Per-shader-file convention** (vvvv's transformative pattern) — **promote to Tier-2 if visual-op multiplication is a priority** (would 10x flux's visual surface area).
- **Parameter UI / Auto-GUI / OSC parameter-sync mirror.**
- **Threading-as-substrate** — needed for streaming.
- **Hot reload / file watcher**.
- **Procedural Texture Sources + Filter Chain** — could also be Tier-4 since it's a visual-fidelity multiplier.
- **Editor UI** — already flagged.

### AAA-gap additions (placement uncertain; flag for Decima-class envelope)

- **Spatial Scene Graph + Culling** — the largest single architectural gap, but its near-term necessity depends on flux's "thousands of meshes" envelope.
- **Level-of-Detail** (geometric + shading).
- **GPU-Driven / Indirect / Mesh-Shader rendering pipeline** — builds on `DrawIndirect`.
- **Streaming / Async Asset Loading** at the operator-graph level.
- **Virtual Textures** — likely Tier-4+.
- **Global Illumination** — probes first, then full GI.
- **Skeletal animation state machines + blend trees** — Tier-3 add-on to skeletal animation itself.
- **Decals** — small family, high authoring impact.

---

## Operator-graph patterns (cross-cutting design decisions)

These patterns shape what flux's operator model *can* express. At 1000-op scale they matter more than individual operators.

### Render-state-as-scope (vs. value-on-port)
**Refs:** tixl (`Command` type + `Transform.Update()` matrix-stack push/pop), cables (render-trigger chain + per-frame matrix stack), Werkkzeug (`Wz4Render` tree).
**Pattern:** state-setting operators (`Transform`/`SetMaterial`/`SetPointLight`/`SetFog`/`SetShadow`) push onto an evaluation-context stack, evaluate a downstream `Command`-typed subtree, then pop. This is structurally different from "Matrix4 flows on a port" — values don't leave the operator boundary.
**Implication for flux:** **revisit the transform-operator design** (and the entire scene-state authoring model) before shipping. Likely Tier-1 decision.

### Spreads (sequence-as-input → automatic instancing)
**Refs:** vvvv (`Spread<T>` — immutable, modulo-indexed, every node auto-spreads), cables (`ArrayIteratorObjects` + 217 Array ops + `*MultiPort` variants), tixl (per-vec3 spread ops).
**Pattern:** an immutable indexed collection flows through one port; nodes downstream auto-iterate. Modulo-indexing means "feed a 4-element spread to a node expecting one transform, and it runs 4 times."
**vvvv's claim:** "the single most important pattern vvvv has and flux does not. Without it, 1000 instances means 1000 wires."
**Implication for flux:** decide whether `FloatList`/`Vec3List`-as-port-type auto-spreads or requires explicit iteration. Affects entire authoring ergonomics at scale.

### Process vs Operation distinction
**Refs:** vvvv (visibly distinguishes stateless `Operation` nodes from stateful `Process` nodes).
**Pattern:** the patch UI shows two different node kinds. `Lerp`/`Add` are stateless; `FlipFlop`/`S+H`/`audio-player`/`TCP-client` are stateful and carry per-instance state across frames.
**Implication for flux:** flux currently treats all operators uniformly. The missing Condition/Switch/Trigger/Gate/Sample-Hold ops have a deeper root cause — **flux has no concept-level slot for stateful-per-instance operators at all**. This is a Tier-1 or Tier-2 design decision.

### Regions as graph constructs (ForEach / Where / Delegate as enclosures)
**Refs:** vvvv (ForEach, Repeat, If, Where, Delegate, plus "Operation Region" generic), tixl (`Region::Loop` analog with `BlendScenes`).
**Pattern:** loops / conditionals / closures *enclose part of the patch*, not separate node families. A delegate-region produces a first-class function-value passable to nodes like `Apply` or `Where [Spread]`.
**Flux state:** has `Region::Loop`/`Region::RenderPass`/`Region::Accumulate`; missing `Region::Where`/`Region::If` and delegate-as-value.

### IObservable as port type (event streams in the graph)
**Refs:** vvvv (`IObservable<T>` is a port type; HoldLatest/Sampler/S+H bridge to dataflow; Reactive `ForEach` runs body per event; all input devices routed through observables).
**Pattern:** events and dataflow share the same graph; explicit conversion via three semantically-distinct extractors (HoldLatest = always-latest; Sampler = all-since-last-frame; S+H = latest-until-next).
**Implication for flux:** if flux wires MIDI/OSC/mouse/network input, the choice is whether to poll-into-dataflow each frame or commit to an event-stream type. **vvvv's architecture commitment; worth the design call.**

### Named Channels / ChannelHub
**Refs:** vvvv (`ChannelHub` + `PublicChannelDescription` — basis for RCP remote control), cables (29 typed `Var*` ops + `TriggerSendNamed`/`TriggerReceive`), tixl (`Variable`/`Spline` named globals), Werkkzeug (`Variable`/`Spline` referenced from inline scripts).
**Pattern:** typed publish-subscribe rails addressed by name, separate from explicit wires. At 1000-op scale this is how graphs avoid being mostly wires.
**Implication for flux:** **4/4 node-paradigm refs converged on this; flux has no version of it.** High-priority for 1000-op scale.

### Shader-file-as-node convention
**Refs:** vvvv (TextureFX/ShaderFX/DrawFX/ComputeFX — naming suffix + `[Category]`/`[Color]`/`[EnumType]`/`[OutputFormat]`/`[WantsMips]` decorators).
**Pattern:** a shader file (e.g. `Blur_TextureFX.sdsl`) placed in a known folder automatically becomes a node with auto-derived pins (uniforms → ports), automatic sRGB/linear conversion, declared output format, opt-in mipmap generation.
**vvvv's leverage:** 60+ image-effect nodes from 60+ shader files with zero per-shader registration code.
**Implication for flux:** flux has `LoadShaderOp` at the primitive layer and reflection infrastructure. **Adopting this convention would multiply visual operator surface area by ~10x without registry-code growth.** Likely the single highest-leverage pattern from this research.

### Strategy-as-port-level-value (function-pointer interface as Value)
**Refs:** toxiclibs (`SurfaceMeshBuilder(SurfaceFunction)`, `subdivide(SubdivisionStrategy)`, `Lerp(a, b, t, InterpolateStrategy)`, `ProximityComparator(target, DistanceProxy)`, `ColorTheoryRegistry`).
**Pattern:** a function-pointer-like interface is *itself* the value flowing into an operator. Collapses families of N similar operators (LerpLinear/LerpCosine/LerpBezier/...) into 1+strategy-value.
**Implication for flux:** decide whether to ship N variants per family or 1 + strategy-typed port. Affects every interpolation/subdivision/sampling family in the inventory.

### Brush + Accumulator (volumetric / iso-surface authoring)
**Refs:** toxiclibs (`VolumetricSpace` + `RoundBrush`/`BoxBrush`/`PeakBrush` × `AdditiveBrush`/`MultiplyBrush`/`ReplaceBrush`).
**Pattern:** mutable accumulator field + composable brushes that paint into it; downstream extracts mesh via marching cubes.
**Flux analog:** `Region::Accumulate` is the same shape. **Worth re-checking whether flux's accumulator accepts arbitrary brush operators or only built-in blend modes.**

### Parallel Substrate Scene Primitives
**Refs:** tixl (Mesh, Point, Field/SDF, Particle — four independent scene-content types with their own generate/modify/draw vocabularies + bridging ops like `PointsOnMesh`/`MoveToSDF`/`FieldDistanceForce`/`SampleFieldPoints`/`MeshFacesPoints`).
**Pattern:** scene content is NOT funneled through one universal type; multiple types coexist with explicit bridges.
**Implication for flux:** **major architectural decision.** flux currently has only Mesh as scene content. Adding Point/SDF as parallel substrates is Tier-3+ scope but transformative for authoring vocabulary.

### Renderer as Ops (not as Host)
**Refs:** cables (`MainLoop`/`CanvasInfo`/`ClearColor`/`ClearDepth`/`BlendMode`/`FaceCulling`/`RenderToTexture` are all ops), Werkkzeug (`Wz4Render` tree composition), tixl (`Command`-typed renderer ops).
**Pattern:** frame-loop, clear, blend, cull, render-target switches are authored inside the graph. No "renderer" configured outside the patch.
**Implication for flux:** confirms the direction of flux's region operators. Probably no design change needed; pattern is already in place.

### Defensive Resource Ports (FirstValidTexture / UseFallbackBuffer)
**Refs:** tixl (`FirstValidTexture`, `FirstValidBuffer`, `UseFallbackTexture`, `UseFallbackBuffer`, `IsBufferDirty`, `HasTimeChanged`, `HasValueDecreased`, `FreezeValue`).
**Pattern:** "what if this resource isn't ready" and "what if this hasn't changed" are *authorable* decisions, not implicit framework behavior.
**Implication for flux:** flux's port readiness is implicit. **Tier-4 ergonomics improvement at 1000-op scale.**

### Texture as Cross-Domain Pivot
**Refs:** cables (AnalyzerTexture, TextTexture, HtmlToTexture, CanvasToTexture, TextureSVG, ArrayToTexture, VideoTexture).
**Pattern:** cross-domain data enters the visual graph by becoming a texture. Audio→texture, text→texture, HTML→texture, SVG→texture, array→texture all use the same pattern.
**Implication for flux:** when adding audio / video / data ops, the canonical bridge is "X→Texture" rather than per-domain types.

### Annotations-as-Introspection (auto-UI from port metadata)
**Refs:** openrndr+orx (orx-parameters annotations consumed by orx-gui; every orx-fx filter gets free UI), OF (`ofParameter` + `ofxOscParameterSync` — same parameter object mirrored bidirectionally over OSC).
**Pattern:** typed port metadata drives auto-generated UI panels AND bidirectional OSC mirroring.
**Implication for flux:** flux already has port metadata; **the architectural multiplier is making every port OSC-addressable by graph path for free.**

### Versioned Ops (`_v2`, `_v3`, … `_v9` kept side-by-side)
**Refs:** cables (ImageCompose `_v4`, Particles `_v9`, Twirl `_v4` — old versions kept in library, deprecation-flagged).
**Pattern:** breaking changes ship as new versions; existing patches don't break.
**Implication for flux:** flux uses TYPE_GUID hashes for stable identity. The cables pattern is a *catalog-management* layer on top — worth noting as a future authoring concern.

### Help-Patch / Documentation-as-Patch
**Refs:** vvvv (every library ships `.vl` help patches — runnable examples).
**Pattern:** documentation is not separate from code; it's a copyable example patch.
**Implication for flux:** the `.rsym` format is patches-as-data; this pattern is achievable.

### Extension Packs as Modularity
**Refs:** cables (28 extension packs), vvvv (nuget packages = node packs), Werkkzeug (per-production `.ops` files), orx (orx modules), OF (`ofx*` addons), three.js (`examples/jsm/` add-ons).
**Pattern:** heavy capabilities (physics, ML, alt-renderers, particles) live in extension packs; core stays small.
**Implication for flux:** **5/8 refs converged on this.** Worth designing the operator-pack distribution mechanism early.

### Per-Op Directory Layout (manifest + JS + shader + screenshot + md)
**Refs:** cables (each op = directory with .json manifest, .js runtime, per-shader .frag/.vert, screenshot.png, .md docs).
**Pattern:** an operator is a self-contained directory with everything (code, docs, manifest, example image).
**Implication for flux:** mostly a tooling decision. The `inventory::submit!` registration in flux is the analog; the directory-per-op packaging could come later.

### TSL: Node Graph for Shaders, Retained for Scenes
**Refs:** three.js (`src/nodes/` TSL is a real node graph; `src/scenes/` Scene is retained-mode imperative).
**Pattern:** a mature team deliberately drew the boundary at shader-vs-scene rather than going node-graph-all-the-way-down.
**Implication for flux:** **evidence against the "node graph everywhere" hypothesis.** Flux's bet may need to make peace with retained-mode-style scene description (or commit hard to its own node-graph-scene innovation).

---

## Sources

Per-reference inventories (read in full):
- `research/inventory-tixl.md` — 22 families, 10 patterns
- `research/inventory-cables.md` — 22 families, 10 patterns
- `research/inventory-vvvv.md` — 31 families, 10 patterns
- `research/inventory-werkkzeug.md` — 15 families + "procedural everything" section
- `research/inventory-openrndr-orx.md` — 27 families, 7 patterns
- `research/inventory-threejs.md` — 27 families, 10 patterns
- `research/inventory-openframeworks.md` — 20 families, 6 patterns
- `research/inventory-processing-toxiclibs.md` — 18 families, 10 patterns

Research brief:
- `research/operator-families-research-brief.md`

Flux context (external to this repo):
- `docs/superpowers/gap-analysis.md` (flux's existing tier ranking)
- `docs/superpowers/specs/2026-05-21-camera-projection-operators-design.md` (most recent flux operator shipment)

---

## Open design questions surfaced (for flux's author)

1. **Transform model:** ship transforms as render-state-scope (cables/tixl/Werkkzeug consensus) OR as Matrix4-values-on-ports (flux's current plan)? — Tier-1 decision, affects everything downstream.
2. **Spreads:** add `Spread<T>` / `FloatList`-as-port-type with auto-iteration semantics, OR keep loops explicit? — Tier-1 authoring ergonomics decision.
3. **Process vs Operation:** add a graph-level concept-slot for stateful-per-instance operators? — Required precondition for Trigger/Switch/Gate/Sample-Hold family.
4. **Named channels:** add typed `Var`/`Channel`/`Bus` operators? — 4/4 node-paradigm vote; high-priority for 1000-op scale.
5. **Shader-file-as-node convention:** adopt vvvv's `*_TextureFX.wgsl` filename convention? — 10x visual-op surface area for zero registry-code increase.
6. **Strategy-as-port-value:** ship N-variants-per-family (`LerpLinear`/`LerpCosine`/...) OR 1-op-plus-strategy-port? — Affects every interpolation/subdivision/sampling family.
7. **Parallel scene substrates:** ship `Point`/`SDF` types alongside `Mesh`? — Tier-3 architectural decision, transformative for authoring.
8. **Scene graph:** retained-mode imperative (three.js precedent) OR node-graph-all-the-way? — Decima-class envelope likely forces some retained-mode scene description; pure node-graph may not scale to AAA.
