# Operator Family Inventory: cables.gl

## Framework overview

cables.gl is a pure-data node-graph creative-coding tool targeting the browser (WebGL/WebGPU, Web Audio, HTML/CSS as first-class outputs). Each op is a self-contained directory with a `.js` runtime, a `.json` port-layout/metadata manifest, and per-shader `.frag/.vert` includes; an op's port "type" is a small integer enum (`0` value/scalar, `1` trigger/render-flow, `2` object — texture/geometry/shader/material — and `3` array/matrix) and execution is driven by a `render→trigger` chain rather than pure dataflow. Source surveyed at `visual-programming/cables/src/ops/` — **~1733 ops in `base/`** and ~28 extension packs in `extensions/` (e.g. `Ops.Extension.AmmoPhysics`, `Ops.Extension.WebGpu`, `Ops.Extension.Mediapipe`, `Ops.Extension.GlParticles`, `Ops.Extension.LSystem`).

## Families

### Transform / Matrix [scene] [authoring]
- **Description:** Per-op model/view/matrix mutators chained on the render path — Translate, Rotate, Scale, Shear, multiply/invert, billboard, look-at, screen-to-3d projection, quaternion ops.
- **Representative ops:** `Ops.Gl.Matrix.Translate`, `Ops.Gl.Matrix.Scale`, `Ops.Gl.Matrix.Shear`, `Ops.Gl.Matrix.MultiplyModelMatrix`, `Ops.Gl.Matrix.InvertMatrix`, `Ops.Gl.Matrix.InterpolateMatrix`, `Ops.Gl.Matrix.Quaternion`, `Ops.Gl.Matrix.Billboard`, `Ops.Gl.Matrix.ScreenPosTo3d_v3`, `Ops.Gl.Matrix.MatrixTranslation` (cite: `cables/src/ops/base/Ops.Gl.Matrix.*`).
- **Why it matters:** This is the single biggest family the brief flagged as missing in flux. cables exposes 40 distinct matrix ops; the *Translate* op manifest (`Ops.Gl.Matrix.Translate.json`) shows a render-trigger input + x/y/z scalar inputs + trigger output — i.e. transforms mutate a stack inside the render chain rather than emit a `Matrix4` value, which is a different shape than flux's "Matrix4 value flows on a port" plan.
- **Likely missing from flux:** confirmed missing

### Camera + Camera Controls [scene] [authoring]
- **Description:** Camera ops plus interactive control rigs: orbit/WASD/look-at/device-orientation, plus separable get/set/transform of view & projection matrices and screen-pos<->3d conversions.
- **Representative ops:** `Ops.Gl.Matrix.Camera_v2`, `Ops.Gl.Matrix.LookatCamera`, `Ops.Gl.Matrix.WASDCamera_v2`, `Ops.Gl.Matrix.QuaternionCamera`, `Ops.Gl.Matrix.DeviceOrientationCamera`, `Ops.Gl.Matrix.GetViewMatrix`, `Ops.Gl.Matrix.GetProjectionMatrix`, `Ops.Gl.Matrix.SetProjectionMatrix`, `Ops.Gl.Matrix.CameraPosition`, `Ops.Gl.Matrix.CameraInfo`, `Ops.Dev.Gl.OrbitControlsBlueprint` (cite: `cables/src/ops/base/Ops.Gl.Matrix.*Camera*`).
- **Why it matters:** flux has projection + LookAt views but no interactive camera rigs. cables ships dedicated WASD/orbit/device-orientation/quaternion cameras as ops, not as host code.
- **Likely missing from flux:** confirmed missing

### Lighting (Phong + PBR + Environment) [visual] [scene]
- **Description:** Per-light ops (ambient/directional/point/spot), Lambert/Phong/PBR material ops with clear-coat/thin-film/IBL, environment-light op for IBL.
- **Representative ops:** `Ops.Gl.Phong.AmbientLight_v4`, `Ops.Gl.Phong.DirectionalLight_v5`, `Ops.Gl.Phong.PointLight_v5`, `Ops.Gl.Phong.SpotLight_v5`, `Ops.Gl.Phong.PhongMaterial_v6`, `Ops.Gl.Phong.LambertMaterial_v2`, `Ops.Gl.Phong.ResetLights`, `Ops.Gl.Pbr.PbrMaterial`, `Ops.Gl.Pbr.PbrEnvironmentLight` (cite: `cables/src/ops/base/Ops.Gl.Phong.*`, `Ops.Gl.Pbr.*`).
- **Why it matters:** PbrMaterial.json exposes diffuse RGBA + roughness/metalness + alpha-mode (Opaque/Masked/Dithered/Blend) + clear-coat + thin-film iridescence + per-channel texture inputs — i.e. an authored, parameterised, glTF-2-class material as a single op. flux has a `PointLight` *type* on EvalContext but **no lighting ops at all** and **no PBR material op**.
- **Likely missing from flux:** confirmed missing

### Image Compose / Post-FX [visual]
- **Description:** 107 unique post-process / texture-effect ops chained through an `ImageCompose` framebuffer wrapper: blur (Fast/Zoom/OnePass), bloom-adjacent (LensDirt, LensScratches, PseudoLensFlares), color (Levels, ColorBalance, GammaCorrection, Vibrance, Hue, Desaturate, BrightnessContrast, ColorMap/LUT), distortion (BarrelDistortion, Twirl, Wobble, Kaleidoscope, BulgePinch, PixelDisplacement), AA (FXAA), film (ChromaticAberration, Dither, Posterize, Pixelate, Interlace, Vignette, GrainNoise via Noise.*), normal/SSAO/depth helpers, generators (CircleTexture, RectangleTexture, GridTexture, Plasma, Gradient, RGB noise variants).
- **Representative ops:** `Ops.Gl.ImageCompose.ImageCompose_v4`, `Ops.Gl.ImageCompose.FastBlur_v2`, `Ops.Gl.ImageCompose.FXAA`, `Ops.Gl.ImageCompose.ChromaticAberration_v2`, `Ops.Gl.ImageCompose.LUTMap`, `Ops.Gl.ImageCompose.ToNormalMap_v2`, `Ops.Gl.ImageCompose.Vignette_v3`, `Ops.Gl.ImageCompose.LensDirt_v2`, `Ops.Gl.ImageCompose.Noise.SimplexNoise_v2`, `Ops.Dev.Gl.ImageCompose.ToneMap` (cite: `cables/src/ops/base/Ops.Gl.ImageCompose.*`).
- **Why it matters:** This is the single largest sub-family in cables. The `ImageCompose_v4.json` manifest shows the pattern: each effect op takes a `render` trigger + a `Base Texture` + an `UV Texture` + sizing/filter/wrap parameters and chains into the next — i.e. post-FX is composed in-graph, not authored as a fixed pipeline. flux has zero post-FX ops.
- **Likely missing from flux:** confirmed missing

### Shader Effects (Mesh-level vertex/fragment effects) [visual] [authoring]
- **Description:** Per-material modifiers that splice into the shader chain at vertex or fragment level — bend/twist/wobble/explode/displace/scale-by-normal/clamp-vertex, plus area-bounded variants (`AreaTranslateMeshes`, `AreaRotate`, `AreaScaler`, `ColorArea`), texture-driven vertex displacement, fog effect, fresnel rim, shadow.
- **Representative ops:** `Ops.Gl.ShaderEffects.Twist_v3`, `Ops.Gl.ShaderEffects.Bend_v2`, `Ops.Gl.ShaderEffects.VertexDisplacementMap_v5`, `Ops.Gl.ShaderEffects.FresnelGlow`, `Ops.Gl.ShaderEffects.FogEffect`, `Ops.Gl.ShaderEffects.Shadow_v3`, `Ops.Gl.ShaderEffects.AreaScaler_v3`, `Ops.Gl.ShaderEffects.ExplodeDividedMesh_v2`, `Ops.Gl.ShaderEffects.SplineDeform_v2` (cite: `cables/src/ops/base/Ops.Gl.ShaderEffects.*` — 66 ops).
- **Why it matters:** Authoring-level: lets users add procedural deformation to a material without writing WGSL. flux's only equivalent today is hand-written `CustomShader`. cables' model is "splice an effect into the existing material shader" — that's a graph pattern, not just an op.
- **Likely missing from flux:** confirmed missing

### Mesh Primitives + Mesh Modifiers / Geometry Ops [scene] [authoring]
- **Description:** Two-layer split: (a) primitives (Cube/Sphere/Cylinder/Cone/Torus/Pyramid/Icosahedron/Polyhedron/Helix/HeightMap/ParametricSurface/TextMesh/SplineMesh/FullscreenRectangle/Rectangle9Slice/RoundedRect/FreeFormPlane/PointCloud), and (b) **geometry modifiers** that operate on a mesh value: align, bounding-box, calculate normals, divide, flip-normals, extrude, merge, scale, transform, subdivide, tesselate, sort-by-axis, un-index, randomise triangles, svg-path-to-geometry, triangulate-2d-path, freeze.
- **Representative ops:** `Ops.Gl.Meshes.HeightMap`, `Ops.Gl.Meshes.ParametricSurface`, `Ops.Gl.Meshes.SplineMesh_v2`, `Ops.Gl.Meshes.TextMesh_v2`, `Ops.Gl.Meshes.PointCloudFromTexture`, `Ops.Graphics.Geometry.CalculateNormals`, `Ops.Graphics.Geometry.GeometryExtrude`, `Ops.Graphics.Geometry.TesselateGeometry`, `Ops.Graphics.Geometry.GeometryMerge`, `Ops.Graphics.Geometry.TransformGeometry`, `Ops.Graphics.Geometry.SvgPathToGeometry_v2` (cite: `cables/src/ops/base/Ops.Gl.Meshes.*`, `Ops.Graphics.Geometry.*`, `Ops.Graphics.Meshes.*`).
- **Why it matters:** flux has 7 primitives but **no mesh-modifier family** at all. The cables split makes the gap concrete: primitives are cheap, but the modifiers (extrude, subdivide, recalc-normals, merge, transform, un-index) are what turns "primitives" into "scenes". Also note `TextMesh_v2`, `SplineMesh_v2`, `HeightMap`, `ParametricSurface` as primitive *categories* beyond the regular-polyhedron set flux ships.
- **Likely missing from flux:** confirmed missing

### Texture Sources / Texture I/O [visual] [scene]
- **Description:** Texture generators and loaders beyond simple file-load: VideoTexture, WebcamTexture, ExrTexture (HDR), TextureSVG, TextTexture (rasterised text), GraphTexture, NoiseTexture, GradientTexture, PaletteTexture, RandomNumberTexture, ColorTexture, ArrayToTexture (data→texture upload), TextureToArray (readback), Base64<->texture, CombineTextures, MontageTextures, CopyTexture, CanvasToTexture, RenderToTexture/RenderToTextures (MRT), Histogram, SSAO, DownloadTexture (file out).
- **Representative ops:** `Ops.Gl.Textures.VideoTexture_v3`, `Ops.Gl.Textures.WebcamTexture_v3`, `Ops.Gl.Textures.ExrTexture`, `Ops.Gl.Textures.NoiseTexture`, `Ops.Gl.Textures.PaletteTexture`, `Ops.Gl.ArrayToTexture_v2`, `Ops.Gl.Textures.SSAO`, `Ops.Gl.Textures.Histogram`, `Ops.Gl.RenderToTextures_v3`, `Ops.Gl.DownloadTexture_v3` (cite: `cables/src/ops/base/Ops.Gl.Textures.*`, `Ops.Gl.RenderToTexture*`).
- **Why it matters:** flux has `LoadTextureOp` and `SaveImageOp`. cables shows the *catalog* of texture sources expected of a creative-coding tool: HDR (EXR), video, webcam, procedural (noise/gradient/palette/random/text), MRT, array<->texture round-trip, histogram. Several of these (video, webcam, EXR) are first-tier authoring sources.
- **Likely missing from flux:** confirmed missing

### glTF / Model Pipeline [scene] [visual]
- **Description:** Dedicated glTF op family covering loader, hierarchy/scene/nodes, transforms, animation array, vertex+morph+skin animation, Draco compression, set-material.
- **Representative ops:** `Ops.Gl.GLTF.GltfScene_v4`, `Ops.Gl.GLTF.GltfHierarchy`, `Ops.Gl.GLTF.GltfNodeTransforms_v3`, `Ops.Gl.GLTF.GltfAnimationArray`, `Ops.Gl.GLTF.GltfVertexAnim`, `Ops.Gl.GLTF.GltfMorphTargets`, `Ops.Gl.GLTF.GltfSkin`, `Ops.Gl.GLTF.GltfDracoCompression`, `Ops.Gl.GLTF.GltfSetMaterial` (cite: `cables/src/ops/base/Ops.Gl.GLTF.*` — 26 ops).
- **Why it matters:** The brief flags loaded meshes (glTF/OBJ) as deferred in flux. cables ships **a full glTF *family*** — scene/hierarchy/node/animation/skin/morph/draco — not a single LoadMesh op. Skinning + morph targets + node animation are all separate ops. This is also flux's only path to "skeletal animation".
- **Likely missing from flux:** confirmed missing

### CubeMap / Skybox / IBL [visual]
- **Description:** Cubemap construction from 6 textures, render-to-cubemap, equirectangular<->cubemap conversion, skybox, cubemap material.
- **Representative ops:** `Ops.Gl.CubeMap.CubeMapFromTextures_v2`, `Ops.Gl.CubeMap.RenderToCubemap_v3`, `Ops.Gl.CubeMap.EquirectangularTextureToCubemap`, `Ops.Gl.CubeMap.CubemapToEquirectangularTexture_v2`, `Ops.Gl.CubeMap.Skybox`, `Ops.Gl.CubeMap.CubeMapMaterial_v2` (cite: `cables/src/ops/base/Ops.Gl.CubeMap.*`).
- **Why it matters:** Backbone of IBL and reflective materials. Render-to-cubemap is the multi-view pattern (cite from the brief's AAA-gap list: cubemap == 6-face render pass). flux has neither cubemap value types nor render-to-cubemap ops.
- **Likely missing from flux:** confirmed missing

### Animation Generators (host-time + LFO + smoothing) [authoring]
- **Description:** Procedural animation as ops, not curves: LFOs, sine, random-walk, smooth/spring filters, snap, crossfade, timer, frame-range, bang/trigger-on-condition, time-delta. Distinct from the timeline/keyframe family.
- **Representative ops:** `Ops.Anim.LFO_v3`, `Ops.Anim.SineAnim`, `Ops.Anim.RandomAnim_v2`, `Ops.Anim.Smooth`, `Ops.Anim.Spring`, `Ops.Anim.Snap`, `Ops.Anim.Crossfade`, `Ops.Anim.Timer_v2`, `Ops.Anim.FrameRangeAnim_v2`, `Ops.Anim.Bang`, `Ops.Anim.TimeDelta` (cite: `cables/src/ops/base/Ops.Anim.*` — 23 ops).
- **Why it matters:** flux's animation system is keyframe-curve-driven (TypedCurve). cables also ships **filter/generator ops as first-class** (Smooth, Spring, LFO, Snap) — these are different from curves: they consume a live value and produce a smoothed/lagged/oscillated one. Spring damping and exponential smoothing are common authoring primitives.
- **Likely missing from flux:** confirmed missing

### Timeline + Playback Control [authoring]
- **Description:** A separate cluster from Anim — timeline-keyed animation: `Anim` (keyframe curve), `AnimGetKey`, `AnimGetValue`, `AnimInfo`, autoplay, prerender/demo-prerender, timeline controls, frame goto, length, loop.
- **Representative ops:** `Ops.TimeLine.Anim`, `Ops.TimeLine.AnimGetKey`, `Ops.TimeLine.AnimGetValue`, `Ops.TimeLine.TimeLineControls`, `Ops.TimeLine.GotoFrame`, `Ops.TimeLine.PreRender`, `Ops.TimeLine.DemoPrerender`, `Ops.TimeLine.AutoPlay`, `Ops.TimeLine.TimeLineLoop` (cite: `cables/src/ops/base/Ops.TimeLine.*` — 12 ops).
- **Why it matters:** flux has keyframe curves driving operator inputs each frame, but no timeline-controls operator family (play/pause/scrub, goto-frame, prerender, autoplay, loop). For a demoscene/non-linear-motion-graphics use case these are required.
- **Likely missing from flux:** present (partial — curves), but timeline-controls confirmed missing

### Trigger / Control Flow [authoring]
- **Description:** A complete first-class subsystem: triggers are a port type (`type: 1` in the JSON manifest), and cables ships **51 trigger ops** — sequence, repeat, threshold, gate, route, switch, distribute-by-value, send/receive (named), counter, interval, delayed-trigger, on-change, probability-trigger, monoflop, n-th, triggers-per-second.
- **Representative ops:** `Ops.Trigger.Sequence`, `Ops.Trigger.Repeat_v2`, `Ops.Trigger.Threshold`, `Ops.Trigger.GateTrigger`, `Ops.Trigger.SwitchTrigger`, `Ops.Trigger.RouteTriggerMultiPort_v2`, `Ops.Trigger.TriggerSendNamed`, `Ops.Trigger.TriggerReceive`, `Ops.Trigger.Interval`, `Ops.Trigger.NthTrigger_v2`, `Ops.Trigger.MonoFlop` (cite: `cables/src/ops/base/Ops.Trigger.*`). Plus Boolean.If/Or/And/Toggle/MonoFlop (`Ops.Boolean.*`) and Number switches (`Ops.Number.Switch*`).
- **Why it matters:** The brief flags flux as missing Condition/Switch/Trigger/Gate/Sample-and-hold ops. cables' answer is a *family* with dedicated semantics (named send/receive for cross-graph triggers, gate, threshold, route-by-port, sequencer). At 1000-op scale, named TriggerSend/TriggerReceive is how you avoid spaghetti.
- **Likely missing from flux:** confirmed missing

### Spread / Array / Iterator (cables' answer to vvvv spreads + TouchDesigner CHOPs) [scene] [authoring]
- **Description:** 217 array ops covering: per-element math (ArrayMath, ArrayMathArray, ArrayMathExpression), reductions (Min/Max/Sum/Average), structure (Chunk, Merge, Append, Lookup, Sort), explicit iterators that *fire triggers per element* (ArrayIteratorNumbers/Strings/Objects/Textures/Arrays), buffers, point-array constructors (CircularPoints, PointsCube, PointsSphereRandom, PointsHexagonGrid, PointsPlane), filters/searches, push/pop primitives separated by type, ramp/distribute/interpolate, vector-length, modulo, fract, clamp, abs, lookup-by-index-array.
- **Representative ops:** `Ops.Array.ArrayIteratorObjects`, `Ops.Array.ArrayMathExpression`, `Ops.Array.ArrayChunk`, `Ops.Array.ArrayMerge_v3`, `Ops.Array.ArrayLookup`, `Ops.Array.ArrayNumberRamp_v2`, `Ops.Array.PointArray.PointsHexagonGrid`, `Ops.Array.PointArray.PointsSphereRandom`, `Ops.Array.PointArray.ArraySpray`, `Ops.Array.PointArray.RedistributeSplinePoints`, `Ops.Array.PointArray.TransformArray3` (cite: `cables/src/ops/base/Ops.Array.*`).
- **Why it matters:** This is the largest non-GL family in cables and the most under-represented one in flux. cables' iterators (ArrayIteratorObjects firing a trigger per element) are how cables expresses "spread / for-each over data" — i.e. it's structurally identical to flux's `Region::Loop` but exposed as a first-class operator, **typed per element type**. Point-array constructors (`PointsHexagonGrid`, `PointsSphereRandom`, `ArraySpray`) are the data half of an instancing pipeline.
- **Likely missing from flux:** confirmed missing

### Instancing / Instanced Draw [scene]
- **Description:** Drive thousands of mesh instances from a texture or array via dedicated ops.
- **Representative ops:** `Ops.Gl.Meshes.MeshInstancerFromTexture_v3`, `Ops.Gl.MeshInstancer`, `Ops.Gl.Matrix.RandomGridPlacement`, `Ops.Gl.Matrix.RandomGridPlacementArrays`, `Ops.Gl.Matrix.ArrayPathFollow`, `Ops.Gl.Matrix.ArrayPathFollowParticles_v2`, `Ops.Gl.ShaderEffects.InstancedDisplacementMap_v2`, `Ops.Gl.ShaderEffects.InstancedPerlinPosition_v2`, `Ops.Extension.WebGpu.MeshInstancer` (cite: `cables/src/ops/base/Ops.Gl.Meshes.MeshInstancer*`, `Ops.Gl.Matrix.RandomGridPlacement*`).
- **Why it matters:** Scene-scale only works with instancing. cables has dedicated MeshInstancerFromTexture (per-instance transform read from a texture — the GPU-driven instancing pattern), plus shader-effect ops that *also* understand instancing (`InstancedDisplacementMap`, `InstancedPerlinPosition`). flux has indirect compute dispatch but no draw-indirect / instanced-draw / instance-from-texture op family.
- **Likely missing from flux:** confirmed missing

### Input Devices (Mouse / Keyboard / Touch / Gamepad / MIDI / Gyro / Mobile) [authoring]
- **Description:** Per-device families — Mouse (drag, wheel, pointer-lock, MouseButtons), Keyboard (KeyPress with learn-mode, CursorKeys, PersonController), GamePad (per-axis joystick), TouchScreen, TouchGesture, MIDI (input/output devices + CC + NRPN + Note + clock + chord + monitor), browser sensors (DeviceVibrate, GeoLocation, ColorScheme, History, UserActivation, WebShare).
- **Representative ops:** `Ops.Devices.Mouse.Mouse_v4`, `Ops.Devices.Mouse.MouseDrag`, `Ops.Devices.Keyboard.KeyPress_v2`, `Ops.Devices.Keyboard.PersonController`, `Ops.Devices.GamePad.GamePad`, `Ops.Devices.TouchGesture`, `Ops.Devices.Midi.MidiInputDevice_v2`, `Ops.Devices.Midi.MidiCC_v3`, `Ops.Devices.Midi.MidiClock`, `Ops.Devices.Browser.JsExpression` (cite: `cables/src/ops/base/Ops.Devices.*` — 60 ops).
- **Why it matters:** Brief flags interaction as confirmed-missing. cables ships an entire **typed-per-device** family (60 ops). Notably: KeyPress has a *learn* variant (capture the next key), MIDI has both input *and* output ops, and `Ops.Devices.Keyboard.PersonController` is a packaged FPS-character controller as a single op.
- **Likely missing from flux:** confirmed missing

### Audio (WebAudio + analysis + sequencer) [authoring]
- **Description:** Audio I/O + DSP (Gain, BiquadFilter, Convolver, Delay, Mixer, Waveshaper, 3-band EQ, CutFilter, Output), audio sources (AudioBufferPlayer, MicrophoneIn), analysis with texture output (AnalyzerTexture, AudioAnalyzer, FFTAreaAverage), playback control (BpmTap, ClockSequencer, MusicalScales, KeyPiano, MidiValueToFrequency).
- **Representative ops:** `Ops.WebAudio.AudioBufferPlayer_v2`, `Ops.WebAudio.AnalyzerTexture_v2`, `Ops.WebAudio.FFTAreaAverage_v3`, `Ops.WebAudio.ClockSequencer`, `Ops.WebAudio.MicrophoneIn_v2`, `Ops.WebAudio.Convolver_v2`, `Ops.WebAudio.BiquadFilter_v2`, `Ops.WebAudio.Mixer`, `Ops.WebAudio.AudioRecorder` (cite: `cables/src/ops/base/Ops.WebAudio.*` — 36 ops).
- **Why it matters:** Demoscene/VJ workloads are audio-driven. The pattern that matters most: **AnalyzerTexture writes FFT/waveform into a texture** so the rest of the visual graph consumes audio as a texture — a clean cross-domain bridge. flux has zero audio ops.
- **Likely missing from flux:** confirmed missing

### Variables / Named Channels (cross-graph value plumbing) [authoring]
- **Description:** Per-type `VarSet*` / `VarGet*` ops let you publish a value under a name in one place and consume it elsewhere without wiring — typed: Number/String/Array/Object/Texture, plus trigger-on-get variants.
- **Representative ops:** `Ops.Vars.VarSetNumber`, `Ops.Vars.VarGetNumber_v2`, `Ops.Vars.VarGetTexture_v2`, `Ops.Vars.VarSetArray_v2`, `Ops.Vars.VarGetObject_v2`, `Ops.Vars.TriggerVarGetNumber` (cite: `cables/src/ops/base/Ops.Vars.*` — 29 ops).
- **Why it matters:** This is cables' answer to the 1000-op-scale wiring problem: rather than a single global variable bag, cables ships a **typed named-channel system** as ops. Same answer pattern as `Ops.Trigger.TriggerSendNamed` / `Ops.Trigger.TriggerReceive` for triggers. flux has nothing analogous; at 1000-op scale this is what keeps the graph readable.
- **Likely missing from flux:** confirmed missing

### Sidebar / Parameter UI [authoring]
- **Description:** A dedicated family of UI ops that build a sidebar parameter panel: sliders, toggles, dropdowns, color-pickers, XY-pad, text-input, presets, number-input, incrementor, groups, dynamic variables, an entire sub-DSL.
- **Representative ops:** `Ops.Sidebar.Sidebar`, `Ops.Sidebar.Slider_v3`, `Ops.Sidebar.Toggle_v4`, `Ops.Sidebar.XYPad`, `Ops.Sidebar.Presets_v2`, `Ops.Sidebar.ColorPicker_v3`, `Ops.Sidebar.DropDown_v2`, `Ops.Sidebar.NumberInput_v2`, `Ops.Sidebar.SidebarVariables`, `Ops.Sidebar.Group`, `Ops.Sidebar.SidebarText_v3` (cite: `cables/src/ops/base/Ops.Sidebar.*` — 38 ops).
- **Why it matters:** This is **runtime control-panel UI as ops**, not editor UI. Authors assemble a parameter panel for the running patch by dropping Slider/Toggle/Color ops. The Presets op is interesting on its own — it lets the *end user* of the running cables piece save/load parameter snapshots. flux-imgui exists, but cables shows that parameter-UI-as-ops is itself a family.
- **Likely missing from flux:** confirmed missing

### Patch Composition (subpatches + routing + named inputs/outputs) [authoring]
- **Description:** Ops that define the graph composition mechanism itself: SubPatch (encapsulate a region), SubPatchInput / SubPatchOutput (declared subpatch ports), Subpatch2Template (promote a subpatch to a reusable template), per-type Route ops (RouteNumber, RouteString, RouteArray, RouteObject, RouteTrigger), CallBack (programmable callback into JS).
- **Representative ops:** `Ops.Ui.SubPatch`, `Ops.Ui.SubPatchInput`, `Ops.Ui.SubPatchOutput`, `Ops.Ui.Subpatch2Template`, `Ops.Ui.Routing.RouteNumber`, `Ops.Ui.Routing.RouteArray`, `Ops.Ui.Routing.RouteTrigger`, `Ops.Ui.PatchInput`, `Ops.Ui.PatchOutput`, `Ops.Cables.Function_v2`, `Ops.Cables.CallBack_v2` (cite: `cables/src/ops/base/Ops.Ui.SubPatch*`, `Ops.Ui.Routing.*`, `Ops.Cables.*`).
- **Why it matters:** flux has subgraph instantiation. cables additionally has **typed route ops** and a **subpatch-to-template promotion op**. The Route ops have one input and many outputs (or vice versa via MultiPort variants) — they're explicit fanout/fanin nodes that make data movement legible at large graph sizes.
- **Likely missing from flux:** partial (subgraphs present, no Route family, no Template-promotion)

### Visualisation / Debug Probes (in-graph) [authoring]
- **Description:** In-graph value visualisers: VizNumber, VizString, VizBool, VizTexture, VizGraph (time-series plot), VizArrayChart, VizArrayTable_v2, VizLogger, VizTrigger, VizObject. Plus Console, GlLogErrors, ProfileGL, BranchProfiler / BranchProfilerBranchEnd (timed-region profiling around an op chain), StepDebugger.
- **Representative ops:** `Ops.Ui.VizNumber`, `Ops.Ui.VizGraph`, `Ops.Ui.VizArrayTable_v2`, `Ops.Ui.VizTexture`, `Ops.Ui.VizLogger`, `Ops.Debug.Console`, `Ops.Debug.ProfileGL`, `Ops.Dev.BranchProfilerBranch`, `Ops.Dev.BranchProfilerBranchEnd`, `Ops.Debug.StepDebugger.StepDebugNumber` (cite: `cables/src/ops/base/Ops.Ui.Viz*`, `Ops.Debug.*`, `Ops.Dev.BranchProfiler*`).
- **Why it matters:** These are debug *ops* — drop one into the graph at the suspect wire and see the value live. BranchProfiler is the standout: bracket an op chain with `BranchProfilerBranch` / `BranchProfilerBranchEnd` and you get a timed-region profile inline with the graph. This generalises GpuTimer at the operator-graph layer.
- **Likely missing from flux:** confirmed missing

### HTML / DOM / CSS [authoring]
- **Description:** 121 ops to manipulate the surrounding DOM as part of the graph — append-child, CSS variables, CSSTransform, CSS3D, element attributes, classlist, scrollbar, sizing, padding, border, shadow, background-image, page-level CSS injection. Effectively a cross-domain renderer (HTML/CSS) accessible from the same graph as the WebGL renderer.
- **Representative ops:** `Ops.Html.AppendChild_v2`, `Ops.Html.CSS.CSS_v3`, `Ops.Html.CSS.ElementCssTransform_v2`, `Ops.Html.CSS.ElementCss3DTransform`, `Ops.Html.CSS.TransformCSS3DElement`, `Ops.Html.CSS.SetCssVariableColor`, `Ops.Html.CSS.SetCssVariableNumber` (cite: `cables/src/ops/base/Ops.Html.*`).
- **Why it matters:** Reference-specific — flux is not browser-targeted, so the surface area isn't transferable. But the *pattern* is: **a second renderer (DOM/CSS) as a peer to the GL renderer, sharing the same op graph and the same animation values**. Cross-domain authoring through one graph.
- **Likely missing from flux:** N/A (reference-specific; pattern interesting)

### Extensions (opt-in heavy capability packs) [scene] [visual]
- **Description:** 28 extension packs in `cables/src/ops/extensions/` that ship as separate ops bundles: physics (`AmmoPhysics`, `CannonJs`), WebGPU pipeline (`Ops.Extension.WebGpu` — alternate renderer with ComputeStorageInput/Output, Pipeline, ArrayToGpuBuffer), ML/CV (`Mediapipe` for face/hand/pose tracking; `TeachableMachines`; `Trackingjs`; `DetectGpu`; `Voice`), Three.js bridge (`Ops.Extension.Three.*` — full set of geometries/lights/materials/loaders as an *alternative* render path), GPU particles (`GlParticles`), procedural generators (`LSystem`, `ReactionDiffusion`, `SuperShapes`), AI (`Ai`, `OpenType`), HTML→Texture (`HtmlToTexture`, `RecklessHtml`), Lottie animation, OSC bridge (`Osc2Ws`), socket networking (`SocketCluster`, `WebSocket`), charting (`ECharts`), `Standalone` (desktop runtime), `Deprecated`, `Testing`, `FxHash` (generative-art seed).
- **Representative ops:** `Ops.Extension.AmmoPhysics.AmmoWorld`, `Ops.Extension.AmmoPhysics.AmmoBody`, `Ops.Extension.AmmoPhysics.AmmoCharacter`, `Ops.Extension.AmmoPhysics.AmmoRaycast`, `Ops.Extension.WebGpu.Pipeline`, `Ops.Extension.WebGpu.ComputeStorageInput`, `Ops.Extension.Mediapipe.MpHandTracking`, `Ops.Extension.Mediapipe.FaceMesh`, `Ops.Extension.LSystem.*`, `Ops.Extension.ReactionDiffusion.*`, `Ops.Extension.GlParticles.Dev.ParticleSystem_v9` (cite: `cables/src/ops/extensions/Ops.Extension.*/`).
- **Why it matters:** Architectural: cables uses **extension packs as the modularity story for heavy capabilities** (physics, ML, alt-renderers, particles) rather than putting them in core. Three.js is shipped as an *extension*, not the renderer, so the same graph can host both renderers. Physics has a complete first-class family (world, body, collisions, character controller, raycast, emitter, debug-renderer, gltf-bodies). Particles live in an extension. ML/CV (Mediapipe) is in an extension.
- **Likely missing from flux:** physics (confirmed missing), particles (confirmed missing), ML/CV input (confirmed missing), extension/packaging mechanism itself (likely missing as a first-class concept)

### Misc auxiliaries (JSON, HTTP, Date, MSDF fonts, Color theory) [authoring]
- **Description:** Clustered support: JSON object construction/access/keys/merge/parse/stringify + `HttpRequest` + `CorsProxy`; date math; MSDF font + text rendering (`FontMSDF_v2`, `TextMeshMSDF`, `LineFont`); color (`ColorPalettes`, `Gradient`, `HSLtoRGB`, `HexToRGB_v2`, `EyeDropper`, `LuminanceContrast`).
- **Representative ops:** `Ops.Json.HttpRequest_v4`, `Ops.Json.ObjectMerge`, `Ops.Json.CsvColumnArray_v2`, `Ops.Gl.FontMSDF_v2`, `Ops.Gl.TextMeshMSDF`, `Ops.Color.ColorPalettes`, `Ops.Color.Gradient`, `Ops.Color.LuminanceContrast` (cite: `cables/src/ops/base/Ops.Json.*`, `Ops.Color.*`, `Ops.Gl.FontMSDF*`).
- **Why it matters:** Three to flag specifically: (a) **HTTP/CSV ops are first-class** — cables treats fetching JSON or CSV as a node, not a host concern; (b) **MSDF font rendering is a dedicated op family** (text is hard and ships as ops); (c) **Color is a small family with palettes and luminance-contrast** alongside the usual conversions.
- **Likely missing from flux:** partial (HSL/Color util present); HTTP/CSV/MSDF-text confirmed missing

## Notable patterns (not operators)

- **Render-trigger chain instead of pure dataflow.** Every render-side op has a `render` input (port type 1) and a `trigger` output. Execution order is determined by which trigger fires which trigger, *not* by pure data dependency. Transforms and material binds mutate a per-frame stack (modelMatrix, lights, shader state) inside this chain. This is the opposite of flux's "Matrix4 flows as a value" plan; cables transform ops *don't emit* a matrix — they push one onto a stack during the render pass. (Source: `Ops.Gl.Matrix.Translate.json` ports.)

- **`_v2`, `_v3`, ... `_v9` versioned ops kept side-by-side.** ImageCompose has up to v4, Particles up to v9, Twirl up to v4. Old versions are not deleted — they remain in the library, deprecation flagged in metadata, so existing patches don't break. This is cables' answer to operator-evolution at 1000-op scale. ImageCompose alone has 193 ops largely because of versioning.

- **Typed Var ops as a named-channel system.** `Ops.Vars.VarSetNumber` / `VarGetNumber` exist as separate ops per type (Number/String/Array/Object/Texture). The Var name is a parameter; consumers reference by name. Same pattern for triggers (`TriggerSendNamed` / `TriggerReceive`). This avoids wire-spaghetti at scale and is **typed by op identity, not by string lookup**.

- **Subpatch with declared input/output ports + Subpatch2Template.** Subpatches are not just visual grouping — they have declared port ops (`SubPatchInput` / `SubPatchOutput`) defining their interface, and a dedicated op (`Subpatch2Template`) promotes a subpatch into a reusable template. Closest analog to flux's Symbol/Instance, but as an in-graph authoring action.

- **In-graph Viz / Debug ops as a debugging surface.** Drop `VizNumber` / `VizTexture` / `VizGraph` / `VizArrayTable` on a wire to see the value. `BranchProfilerBranch` / `BranchProfilerBranchEnd` bracket a chain and time it inline. The graph is the inspector.

- **MultiPort variants for dynamic port count.** Many ops have `*MultiPort` variants (`Ops.Boolean.AndMultiPort_v2`, `Ops.Trigger.RouteTriggerMultiPort_v2`, `Ops.String.ConcatMultiPort_v2`, `Ops.Number.SwitchNumberMultiPort_v2`, `Ops.Array.ArrayMerge_v3`). Same op semantics, dynamic port arity — cables' answer to "how do you handle variadic inputs without inflating the op count".

- **Renderer as ops, not as host.** `Ops.Gl.MainLoop`, `Ops.Gl.CanvasInfo_v3`, `Ops.Gl.ClearColor`, `Ops.Gl.ClearDepth`, `Ops.Gl.BlendMode`, `Ops.Gl.FaceCulling_v2`, `Ops.Gl.RenderToTexture_v3` — frame-loop, clear, blend, cull, and render-target switches are all ops authored inside the graph. There is no "renderer" you configure outside the patch.

- **Texture as the cross-domain pivot.** Audio→texture (`AnalyzerTexture`), text→texture (`TextTexture_v6`), HTML→texture (`Ops.Extension.HtmlToTexture`), canvas→texture (`CanvasToTexture`), SVG→texture (`TextureSVG_v2`), arbitrary array→texture (`ArrayToTexture_v2`), video→texture (`VideoTexture_v3`). Cross-domain data enters the visual graph by becoming a texture.

- **Extension packs as the modularity story.** Heavy capabilities (physics, ML/CV, alt-renderers, particles, OSC bridge, AI, LSystem, reaction-diffusion) live in `extensions/` and are opt-in. Three.js is shipped as an *extension*, peer to the native cables renderer. WebGPU is also an extension, not a replacement.

- **`Anim` separate from `TimeLine`.** Two distinct families: `Ops.Anim.*` are generators/filters (LFO, SineAnim, Smooth, Spring, Snap), `Ops.TimeLine.*` are keyframe-curve readers + playback control. The separation acknowledges that procedural and authored animation are different authoring acts.

- **op directory layout = manifest + JS + per-shader includes + screenshot + markdown.** `Ops.Gl.Pbr.PbrMaterial/` contains `.json` (port layout, docs, changelog, license, coreLibs, exampleProjectId, youtubeid), `.js` (runtime), `att_BasicPBR.frag` + `att_BasicPBR.vert` + multiple `att_light_*.frag` includes (per-light-type shader fragments composited at runtime), `screenshot.png`, `.md` (longform docs). The per-op self-containedness is enforced by directory structure.

## Sources cited

- Op directories: `visual-programming/cables/src/ops/base/` (1733 ops) and `visual-programming/cables/src/ops/extensions/` (28 packs)
- Port-typing convention: `visual-programming/cables/op.schema.json`
- Concrete op manifests inspected: `Ops.Gl.Matrix.Translate/Ops.Gl.Matrix.Translate.json`, `Ops.Gl.Matrix.MultiplyModelMatrix/*.json`, `Ops.Gl.ImageCompose.ImageCompose_v4/*.json`, `Ops.Gl.Pbr.PbrMaterial/*.json` (+ `att_BasicPBR.{vert,frag}`, `att_light_*.frag`)
- `visual-programming/cables/README.md`
- Public op listing referenced from README: https://cables.gl (per `README.md`)
