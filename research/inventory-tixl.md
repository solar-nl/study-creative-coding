# Operator Family Inventory: tixl / Tooll3

## Framework overview
TiXL (Tooll3) is a Windows-only, C#/.NET realtime motion-graphics tool descended from Werkkzeug. It is a pure-data node graph (`.t3` symbol files alongside `.cs` operator definitions) running on DirectX 11 / SharpDX, targeting VJ / motion-graphics / interactive-installation work but with serious 3D, PBR, post-FX, and SDF-modeling depth. Operators are C# classes deriving from `Instance<TSelf>` with `[Input]` / `[Output]` slot fields; downstream evaluation is pull-based via `Slot.UpdateAction` (see `Operators/Lib/Symbols/render/transform/Transform.cs` and `Core/Operator/EvaluationContext.cs`).

## Families

### Transform & Spatial Hierarchy [scene] [authoring]
- **Description:** Push/pop matrices on an evaluation-context stack to nest child draw commands in a coordinate frame.
- **Representative ops:** `Transform`, `RotateAroundAxis`, `RotateTowards`, `Shear`, `Group`, `SpreadLayout` (`Operators/Lib/render/transform/`); plus per-vec3 ops `TransformVec3`, `RotateVector3`, `MulMatrix` (`Operators/Lib/numbers/vec3/`).
- **Why it matters:** Without a Transform-as-scope operator, you cannot author nested rigs (vehicle-body → wheel → hubcap), camera-relative gizmos, or instancing layouts in pure data. Every scene above one object collapses.
- **Likely missing from flux:** confirmed missing (flagged in brief).

### Camera Family [scene] [visual] [authoring]
- **Description:** A full set of camera authoring + blending + rig operators, not just a projection matrix.
- **Representative ops:** `Camera`, `OrbitCamera`, `ActionCamera`, `BlendCameras`, `ShiftCamera`, `CameraWithRotation`, `ReuseCamera`, `CurrentCamMatrices` (`Operators/Lib/render/camera/`).
- **Why it matters:** Multi-camera switching/blending and orbit/action presets are core to motion-graphics authoring; `ReuseCamera` enables off-screen passes (reflection, shadow, picking) to share the main viewpoint.
- **Likely missing from flux:** partial (perspective/ortho + LookAt exist, no orbit/action/blend/reuse).

### Lighting & Materials [visual]
- **Description:** Stack-based light registration, PBR material definition, fog, environment IBL, shadow setup.
- **Representative ops:** `PointLight`, `SetPointLight`, `DefineMaterials`, `SetMaterial`, `UseMaterial`, `SetEnvironment`, `SetFog`, `SetShadow`, `TextureToCubeMap`, `_ComputeBRDFLookup` (`Operators/Lib/render/shading/`, `Operators/Lib/render/_/`). `EvaluationContext.PointLights` + `Materials` + `ContextTextures` carry them.
- **Why it matters:** Decima-class fidelity requires PBR + IBL + shadow + fog as authoring primitives, not hand-rolled WGSL. Flux has the `PointLight` *type* on context but no authoring operators.
- **Likely missing from flux:** confirmed missing (lighting/material ops).

### Post-Process Stack [visual]
- **Description:** Screen-space passes chained on the rendered scene.
- **Representative ops:** `DepthOfField`, `MotionBlur`, `SSAO`, `GodRays`, `TemporalAccumulation` (`Operators/Lib/render/postfx/`); plus `Bloom`, `Glow`, `StarGlowStreaks`, `LightRaysFx`, `ChromaticAbberation`, `Fxaa`, `ToneMapping`, `ColorGrade`, `ColorGradeDepth` (`Operators/Lib/image/fx/`, `Operators/Lib/image/color/`, `Operators/Lib/image/use/`).
- **Why it matters:** Tier-2 visual fidelity baseline. Flux currently has zero post ops.
- **Likely missing from flux:** confirmed missing.

### Image / 2D Compositing [visual] [authoring]
- **Description:** Blend, mask, layer, mix, swap, and combine 2D textures as first-class ops.
- **Representative ops:** `Blend`, `BlendImages`, `BlendWithMask`, `Combine3Images`, `Layer2d`, `PickTexture`, `SwapTextures`, `FirstValidTexture`, `KeepInTextureArray` (`Operators/Lib/image/use/`, `Operators/Lib/Symbols/render/basic/Layer2d.cs`).
- **Why it matters:** Compositing is the bridge between offscreen passes and final output; without it every multi-pass effect requires custom WGSL.
- **Likely missing from flux:** confirmed missing.

### Image Generators (procedural texture sources) [visual] [authoring]
- **Description:** Procedural images as nodes — gradients, noise, fractals, patterns, checkerboards, blobs.
- **Representative ops:** `LinearGradient`, `RadialGradient`, `BoxGradient`, `Blob`, `CheckerBoard`, `RoundedRect`, `NGon`, `FractalNoise`, `WorleyNoise`, `TileableNoise`, `ShardNoise`, `MandelbrotFractal`, `Raster`, `Rings`, `RyojiPattern1` (`Operators/Lib/image/generate/basic|noise|fractal|pattern/`).
- **Why it matters:** Procedural-first authoring (the Werkkzeug lineage) — material/wall/floor texture lives are built without shipping image assets. Reduces asset pipeline weight at 1000-op scale.
- **Likely missing from flux:** probably missing.

### Image Stylize / Distort / Glitch / Feedback [visual]
- **Description:** Artistic transforms on images — feedback loops, distortion, dither, mosaic, ASCII, polar-coord warps.
- **Representative ops:** `AdvancedFeedback`, `AfterGlow`, `FluidFeedback`, `SimpleLiquid` (`image/fx/feedback/`); `Displace`, `PolarCoordinates`, `KochKaleidoskope` (`image/fx/distort/`); `Dither`, `Pixelate`, `Steps`, `AsciiRender`, `MosiacTiling`, `VoronoiCells` (`image/fx/stylize/`).
- **Why it matters:** A central VJ vocabulary. Less Decima-relevant but defines the framework's stylistic surface area.
- **Likely missing from flux:** probably missing (only authorable in WGSL today).

### Mesh Generators (beyond primitives) [scene]
- **Description:** Procedural mesh sources plus repeat/scatter/extrude operators.
- **Representative ops:** `CubeMesh`, `SphereMesh`, `IcosahedronMesh`, `NGonMesh`, `QuadMesh`, `TorusMesh`, `CylinderMesh`, `ExtrudeCurves`, `RepeatMeshAtPoints`, `LoadObj`, `LoadGltf` (`Operators/Lib/mesh/generate/`, `Operators/Lib/mesh/_/`).
- **Why it matters:** flux has the primitives; the gap is *mesh-from-data* (extrude along a curve, repeat at points), and asset loaders.
- **Likely missing from flux:** partial (primitives present, no extrude/repeat/load).

### Mesh Modify / Deform / Operate [scene] [visual]
- **Description:** Mesh-level deformation, noise displacement, UV transform, normal recomputation, vertex blend, scatter-to-points.
- **Representative ops:** `DeformMesh`, `DisplaceMesh`, `DisplaceMeshNoise`, `TextureDisplaceMesh`, `DisplaceMeshVAT`, `BlendMeshVertices`, `CombineMeshes`, `RecomputeNormals`, `FlipNormals`, `TransformMesh`, `TransformMeshUVs`, `ScatterMeshFaces`, `MeshFacesPoints` (`Operators/Lib/mesh/modify/`).
- **Why it matters:** Procedural geometry editing without round-tripping to a DCC. VAT (Vertex Animation Texture) is a real game-engine feature.
- **Likely missing from flux:** confirmed missing.

### Point Cloud Substrate (a parallel scene primitive) [scene] [visual] [authoring]
- **Description:** "Point" is a first-class data type with generate/modify/transform/combine/draw/sim subtrees — essentially a parallel scene graph for sprite/line/ribbon/billboard/particle work. Sources include grids, spheres, hex grids, spline samples, mesh-vertex sampling, SVG, points-on-image.
- **Representative ops:** `GridPoints`, `HexGridPoints`, `RadialPoints`, `SpherePoints`, `LinePoints`, `PointsOnMesh`, `PointsOnImage`, `PointTrail` (`point/generate/`); `RandomizePoints`, `AddNoise`, `MoveToSDF`, `FilterPoints`, `MapPointAttributes`, `ResampleLinePoints` (`point/modify/`); `TransformPoints`, `OrientPoints`, `SnapPointsToGrid`, `WrapPoints` (`point/transform/`); `DrawPoints`, `DrawLines`, `DrawRibbons`, `DrawTubes`, `DrawBillboards`, `DrawMeshAtPoints` (`point/draw/`).
- **Why it matters:** This is Tooll3's biggest single category. It's how you author lines / ribbons / sprite swarms / instanced meshes / connection diagrams without writing geometry shaders. Without it, "draw N things at positions defined by a procedural process" requires custom GPU code each time.
- **Likely missing from flux:** confirmed missing — flux has no point cloud type.

### Particle Simulation [scene] [visual]
- **Description:** GPU particle system with composable forces.
- **Representative ops:** `ParticleSystem` (`Operators/Lib/Symbols/particle/ParticleSystem.cs`); forces: `TurbulenceForce`, `CollisionForce`, `DirectionalForce`, `VectorFieldForce`, `FieldDistanceForce`, `VerletRibbonForce`, `VelocityForce`, `ReconstructiveForce`, `SnapToAnglesForce` (`Operators/Lib/particle/force/`); related `PointSimulation` + `SimNoiseOffset`/`SimForceOffset`/`SimCentricalOffset` (`Operators/Lib/point/sim/`).
- **Why it matters:** Particles + forces as nodes is a defining creative-coding capability; the force-as-node pattern lets authors compose simulation without writing compute shaders.
- **Likely missing from flux:** confirmed missing.

### Signed Distance Field (SDF) / Field Modeling [scene] [visual]
- **Description:** Composable 3D fields with primitives, boolean combiners, space-warps, and a raymarch renderer — an entirely separate modeling pipeline alongside meshes.
- **Representative ops:** `BoxSDF`, `SphereSDF`, `TorusSDF`, `CapsuleLineSDF`, `OctahedronSDF`, `FractalSDF`, `HeightMapSdf`, `Image2dSDF`, `CustomSDF` (`Operators/Lib/field/generate/sdf/`); combiners `CombineSDF`, `BlendSDFWithSDF`, `StairCombineSDF`; space-warps `RotateField`, `TwistField`, `BendField`, `RepeatAxis`, `RepeatPolar`, `ReflectField`, `TransformField` (`field/space/`); renderers `RaymarchField`, `Render2dField`, `SampleFieldPoints` (`field/render/`); `MoveToSDF` for hybrid point/field workflow.
- **Why it matters:** Procedurally-authored organic / boolean / fractal geometry that meshes can't easily express. Werkkzeug lineage. Compresses to nothing — important for "1000 ops without 1000 assets" scaling.
- **Likely missing from flux:** confirmed missing.

### Flow / Subgraph Control [authoring]
- **Description:** Subgraph activation, branching, looping, sound-locked execution, once-only, blend-between-scenes.
- **Representative ops:** `Switch`, `Loop`, `Once`, `ExecuteOnce`, `Execute`, `ExecRepeatedly`, `BlendScenes`, `ResetSubtreeTrigger`, `TimeClip`, `LoadSoundtrack` (`Operators/Lib/flow/`).
- **Why it matters:** At 1000-op scale, conditional sub-tree activation (don't evaluate disabled branches) and scene-blending are fundamental. `BlendScenes` in particular is how a VJ rig swaps full subgraphs over time.
- **Likely missing from flux:** partial — flux has `Region::Loop`; no `Switch`/`Once`/`BlendScenes`/`ResetSubtreeTrigger`/conditional execution.

### Animation Sources & Processing [authoring]
- **Description:** Procedural value sources (oscillators, sequencers, triggers) plus signal conditioners (damp, spring, ease, accumulator, pulse-detect, peak-level).
- **Representative ops:** `AnimValue`, `AnimVec2`, `AnimVec3`, `OscillateVec3`, `SequenceAnim`, `TriggerAnim` (`numbers/anim/animators/`); `Damp`, `DampAngle`, `Spring`, `Ease`, `SmoothStep`, `Accumulator`, `DetectPulse`, `PeakLevel`, `Lerp`, `RemapValues` (`numbers/float/process/`); `Counter` (`numbers/anim/_obsolete/`).
- **Why it matters:** Signal-processing-as-graph is what turns a static rig into a reactive one. Damp/Spring/SmoothDamp are essential for tactile camera and UI feel; Accumulator/PulseDetect are state primitives.
- **Likely missing from flux:** confirmed missing — flux has TypedCurve animation but no Damp/Spring/Ease/Accumulator/PulseDetect operators.

### Time / Clock / VJ Sync [authoring]
- **Description:** Multiple time bases, BPM control, beat taps, Ableton Link sync, MIDI time, time-clip stretching.
- **Representative ops:** `Time`, `SetTime`, `SetPlaybackSpeed`, `SetPlaybackTime`, `RunTime`, `LastFrameDuration`, `StopWatch`, `ConvertTime`, `ClipTime`, `GetFrameSpeedFactor`, `HasTimeChanged` (`numbers/anim/time/`); `AbletonLinkSync`, `GetBpm`, `SetBpm`, `ForwardBeatTaps`, `SetSpeedFactors` (`numbers/anim/vj/`); `LinkToMidiTime`, `MidiClip` (`io/midi/`).
- **Why it matters:** Beat-locked, BPM-stretched, scrubable time is the difference between a render and a VJ rig. Multiple cooperating time bases are the canonical pain point.
- **Likely missing from flux:** mostly missing — flux has scalar `Time`, no BPM/Link/time-clip/scrub/per-subtree time override.

### I/O — External Signal Inputs [authoring]
- **Description:** Live signal ingress from MIDI, OSC, DMX/sACN/Artnet, serial, TCP/UDP, websocket, HTTP, audio, video device, video stream, image-from-URL, file watcher, JSON.
- **Representative ops:** `MidiInput`, `MidiControlOutput` (`io/midi/`); `OscInput`/`OscOutput` (`io/osc/`); `ArtnetInput`/`SacnInput`/`DMXOutput` (`io/dmx/`); `SerialInput` (`io/serial/`); `TcpClient`/`UDPInput`/`WebSocketClient`/`WebServer` (`io/tcp|udp|websocket|http/`); `VideoDeviceInput`/`VideoStreamInput`/`PlayVideo` (`io/video/`); `AudioReaction` (`io/audio/`); `ReadFile`/`FilesInFolder`/`WriteToFile` (`io/file/`); `GetAttributeFromJsonString`/`RequestUrl` (`io/json/`); `SpoutInput`/`SpoutOutput` (`Operators/Spout/`); `NdiInput`/`NdiOutput`/`ScreenCapture` (`Operators/Ndi/`); `PosiStageInput`, `FreeDInput` (camera tracking).
- **Why it matters:** This is the entire "live and reactive" surface area. Without it, the framework is render-only.
- **Likely missing from flux:** confirmed missing across the board.

### String / Data Manipulation [authoring]
- **Description:** Strings as first-class operator-graph data — split, concat, search/replace, filepath parts, datetime formatting, json extract, build random strings.
- **Representative ops:** `CombineStrings`, `SplitString`, `SearchAndReplace`, `SubString`, `IndexOf`, `PickStringFromList`, `FilePathParts`, `DateTimeToString`, `FloatToString`, `BuildRandomString` (`Operators/Lib/string/`).
- **Why it matters:** Generating labels/text/HUD/path strings procedurally; driving file loaders with computed paths. Easy to underestimate until needed.
- **Likely missing from flux:** probably missing (no String type / ops in flux).

### Text Rendering & Typography [visual]
- **Description:** Render strings as textured triangles / sprites / outlines, including grid-laid-out text and text-on-points.
- **Representative ops:** `Text`, `TextOutlines2`, `TextSprites`, `LineTextPoints` (`render/basic/`, `render/sprite/`, `point/io/`).
- **Why it matters:** Typographic motion graphics is half of motion-graphics work; titles/HUD/captions/diagram labels.
- **Likely missing from flux:** confirmed missing.

### Color & Gradient Authoring [visual] [authoring]
- **Description:** Color types with HSB/HSL/OKLCh constructors, gradient building/blending/sampling, color list pickers, gradients-to-texture.
- **Representative ops:** `HSBToColor`, `HSLToColor`, `OKLChToColor`, `BuildGradient`, `DefineGradient`, `SampleGradient`, `GradientsToTexture`, `BlendGradients`, `PickColorFromImage`, `PickColorFromList`, `CombineColorLists` (`Operators/Lib/numbers/color/`).
- **Why it matters:** OKLCh + gradient sampling as first-class ops is the difference between hardcoded palettes and palette-driven projects. Drives a lot of authoring expressiveness for less code.
- **Likely missing from flux:** partial — flux has Color + animation; no gradient/palette ops.

### Gizmos & Debug Visualization [authoring]
- **Description:** Render-overlay helpers visible only in the editor — wire boxes, line grids, locators, sphere/cam gizmos, curve plots, UV map viewer, point-attribute visualizers.
- **Representative ops:** `DrawBoxGizmo`, `DrawSphereGizmo`, `DrawLineGrid`, `GridPlane`, `Locator`, `DrawCamGizmos`, `PlotValueCurve`, `VisibleGizmos` (`render/gizmo/`); `UVsViewer`, `VisualizeMesh` (`mesh/_/`); `VisualizePoints` (`point/draw/`); `VisualizeFieldDistance` (`field/analyze/`). `EvaluationContext.ShowGizmos` controls.
- **Why it matters:** At 1000-op scale you cannot debug visually without these. Distinct from final-output rendering by a render-state flag, not by separate paths.
- **Likely missing from flux:** confirmed missing.

### GPU Resource & Pipeline Primitives [scene] [authoring]
- **Description:** Explicit shader stage / blend state / depth-stencil / rasterizer / buffer / sampler nodes, plus utility primitives like `PrefixSum`, `GenerateMips`, `CalcDispatchCount`, `DrawInstancedIndirect`.
- **Representative ops:** `VertexShader`/`PixelShader`/`ComputeShader`/`GeometryShader` + `*Stage`, `BlendState`, `DepthStencilState`, `RasterizerState`, `SamplerState`, `StructuredBuffer`, `IndirectBuffer`, `Texture2d`, `Texture3d` (`Operators/TypeOperators/Gfx/`); `Draw`, `DrawInstancedIndirect`, `GenerateMips`, `ClearRenderTarget`, `CalcDispatchCount`, `FloatsToBuffer` (`Operators/Lib/render/_dx11/api/`); `ListToBuffer`, `SwapBuffers`, `IsBufferDirty`, `PickBuffer`, `UseFallbackBuffer` (`render/_dx11/buffer/`); `PrefixSum`, `ExecuteBufferUpdate`, `ExecuteTextureUpdate` (`render/_dx11/fxsetup/`).
- **Why it matters:** flux covers most of this. Notable specifics tixl ships that flux lacks: `DrawInstancedIndirect` (DrawIndirect generally), `PrefixSum` as an operator, "fallback buffer" / "first valid texture" defensive patterns, `IsBufferDirty` for evaluation gating.
- **Likely missing from flux:** partial (core present; DrawIndirect/PrefixSum/dirty-flag gating/defensive fallbacks missing).

### Collections / Lists [authoring]
- **Description:** Typed homogeneous lists (Float/Int/String/Color) plus `DataList` as first-class node-graph values, with combine / keep / zip / pick.
- **Representative ops:** `FloatList`, `IntList`, `StringList`, `ColorList`, `DataList`, `DefineFloatList` (`Operators/TypeOperators/Collections/`); list-ops `JoinStringList`, `KeepStrings`, `ZipStringList`, `PickStringFromList`, `KeepColors`, `CombineColorLists`.
- **Why it matters:** Lists-as-ports avoids needing array-typed connections everywhere; lets authors stay in the graph for set-based work.
- **Likely missing from flux:** probably missing.

### Audio Reaction [authoring]
- **Description:** Audio in + analysis as nodes feeding the graph — fft bands, beat detection, levels.
- **Representative ops:** `AudioReaction` (`io/audio/AudioReaction.cs`); related downstream sinks `LoadSoundtrack`, `PlayAudioClip`; `WaveForm`, `DetectPulse`, `PeakLevel`.
- **Why it matters:** Defining feature of VJ workflows.
- **Likely missing from flux:** confirmed missing.

## Notable patterns (not operators)

- **Matrix-stack scope pattern:** `Transform.Update()` pushes `ObjectToWorld`, evaluates the `Command` input (which pulls the downstream subtree), then restores. Same shape for `SetMaterial`, `SetPointLight`, `SetFog`, `SetShadow`, `SetEnvironment`, `SetPlaybackTime`, `SetRequestedResolution`. The "command" port type is essentially a "subtree to execute under modified context" handle — this is how tixl turns ambient state (camera, material, light, time) into composable, authorable scope. Flux's region operators are the closest analog.
- **Pull-based dirty propagation with explicit gates:** Slots cache values and re-evaluate when dirty; explicit operators like `IsBufferDirty`, `HasTimeChanged`, `HasValueDecreased`, `HasStringChanged`, `HasVec3Changed`, `FreezeValue` let authors gate downstream re-evaluation, which matters at high op counts.
- **Per-type math op fanout:** Separate `AddVec3` / `LerpVec3` / `DampVec3` / `BlendValues` operators per concrete type instead of a generic numeric op. This is verbose but easy to dispatch over and easy to search by name; tixl pays the catalog cost in exchange for typed simplicity.
- **Defensive resource ports:** `FirstValidTexture`, `FirstValidBuffer`, `UseFallbackTexture`, `UseFallbackBuffer` are explicit operators rather than implicit per-port behavior, making "what if this resource isn't ready" an authorable decision.
- **Parallel-substrate scene primitives:** Mesh, Point, Field (SDF), and Particle are four independent "scene contents" with their own generate/modify/draw vocabularies; nothing forces them through a single scene-graph type. Cross-substrate ops (`PointsOnMesh`, `MoveToSDF`, `FieldDistanceForce`, `SampleFieldPoints`, `MeshFacesPoints`) bridge them.
- **`Command` as the universal draw-output type:** Renderers, transform-scopes, light/material setters, post-FX all emit `Command`. Composing a render pipeline is wiring Commands together rather than wiring meshes + materials separately.
- **Multiple time bases on the context:** `Playback`, `LocalTime`, `LocalFxTime`, with `SetPlaybackTime` / `SetTime` operators to override locally — supports time-clips and scrubable sub-graphs without re-architecting evaluation.
- **Operator GUIDs in source:** Every `[Input]` / `[Output]` / class carries a GUID literal — operator/port identity is stable across renames, which is what makes the file-based `.t3` graphs round-trippable and the catalog refactorable at 1000-op scale.
- **`ExecuteRepeatedly` / `ExecuteOnce` / `ResetSubtreeTrigger`:** State-machine primitives at the subgraph level, not the value level — declarative way to say "run this branch on a trigger" without per-frame conditionals.
- **`BlendScenes`:** A first-class operator for cross-fading whole subgraphs, presupposing scenes are pure-data values you can interpolate; this is how VJ sets are authored.

## Sources cited

- `Operators/Lib/` (top-level tree: `field/`, `flow/`, `image/`, `io/`, `mesh/`, `numbers/`, `particle/`, `point/`, `render/`, `string/`)
- `Operators/TypeOperators/` (`Collections/`, `Gfx/`, `Values/`)
- `Operators/Spout/lib/io/video/` and `Operators/Ndi/lib/io/video/`
- `Core/Operator/EvaluationContext.cs`, `Core/Operator/Slots/`, `Core/Operator/Instance.cs`
- `Operators/Lib/Symbols/render/transform/Transform.cs` (matrix-stack scope pattern reference)
- `README.md` (project framing and lineage)
