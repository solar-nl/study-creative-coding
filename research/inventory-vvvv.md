# Operator Family Inventory: vvvv / VL

## Framework overview

vvvv is a hybrid visual + textual programming environment whose underlying language (VL) compiles a patch graph to .NET IL. It is the most mature node-based creative-coding system still under active development: patches are pure data, the type system carries generics and immutability semantics, and the runtime distinguishes "operation applications" (stateless functions) from "process applications" (stateful living nodes that carry per-instance state across frames) — see Gray Book `introduction/nodes.md`. 3D rendering is delegated to a Stride-based engine (VL.Stride; ECS scene graph + low-level draw API; both workflows freely mixable), while 2D rendering uses VL.Skia; both ship in the standard install (`reference/libraries/graphics-3d.md`, `reference/libraries/graphics-2d.md`). The library surface is enormous because every VL package on nuget is, in principle, a node family — the StandardLibs repo (`https://github.com/vvvv/VL.StandardLibs`) is the in-tree subset of that, and the Gray Book `reference/libraries/` directory is the catalog index.

## Families

### Scene Graph / ECS [scene]
- **Description:** Entity-component-tree scene with TransformComponent, ModelComponent, CameraComponent, LightComponent and arbitrary user components, plus `Group` / `Group (Spectral)` nodes to build the entity tree.
- **Representative nodes:** `SceneWindow`, `SceneTexture`, `RootScene`, `Entity`, `Group`, `ModelComponent`, `TransformComponent`, `ModelEntity`, `MeshEntity` (Gray Book `reference/libraries/3d/rendering.md`; `VL.StandardLibs/VL.Stride.Runtime/src/Engine/EntityUtils.cs`, `ComponentUtils.cs`, `SceneUtils.cs`).
- **Why it matters:** vvvv exposes a real hierarchical scene with transform inheritance — child entities inherit parent transforms, which is the load-bearing primitive for AAA-scale authoring (props parented to vehicles, joints to roots, lights to entities). Without it every operator must touch world matrices directly.
- **Likely missing from flux:** confirmed missing

### Low-level Renderer / Draw-call Composition [scene] [visual]
- **Description:** Parallel low-level path where you compose `IRenderer` implementations into a render graph independently of (or interleaved with) the ECS scene.
- **Representative nodes:** `IRenderer`, `MeshRenderer`, `QuadRenderer`, `Group [Stride.Rendering]`, `RenderEntity`, `RenderTexture`, `RenderWindow`, `RendererScheduler`, render-stage selectors (`BeforeScene`, `Opaque`, `Transparent`, `AfterScene`, `ShadowCaster*`) (Gray Book `reference/libraries/3d/rendering.md`; `VL.StandardLibs/VL.Stride.Runtime/src/Rendering/Renderers/`, `RenderFeatures/MeshRenderFeature.cs`, `RenderFeatures/MeshOutlineRenderFeature.cs`, `RenderFeatures/WireframeRenderFeature.cs`).
- **Why it matters:** Decima-class workloads need user-controlled draw-call ordering, custom render stages, and the ability to plug both high-level scene rendering and hand-rolled passes through the same compositor.
- **Likely missing from flux:** partial — flux has CreateRenderPipeline / Draw* / Region::RenderPass primitives but no render-stage / sort-mode abstraction; closer to the low-level workflow only.

### Graphics Compositor / Render-Stage Pipeline [scene] [visual]
- **Description:** Configurable graphics compositor with render stages, sort modes (`FarToNearSortMode`), forward renderer variants, camera renderer, render-texture scene renderer.
- **Representative nodes:** `VLForwardRenderer`, `CameraRenderer`, `RenderTextureSceneRenderer`, `FarToNearSortMode`, `CustomRenderStageFilter` (`VL.Stride.Runtime/src/Rendering/Compositing/`, `VLForwardRenderer.cs`, `VLForwardRenderer.LightProbes.cs`, `VLForwardRenderer.VRUtils.cs`).
- **Why it matters:** Sort modes, per-stage filters, and a named compositor are how you express "draw opaques front-to-back, transparents back-to-front, decals after opaques, UI last" without rewriting the render graph each time.
- **Likely missing from flux:** confirmed missing

### Lighting [visual]
- **Description:** Light-source family (point, spot, directional, ambient, skybox/IBL probe) attachable to any entity via component.
- **Representative nodes:** `LightComponent`, `LightSpot`, `LightPoint`, `LightDirectional`, `LightAmbient`, `LightSkybox`, `LightProbe` (`VL.Stride.Runtime/src/Rendering/Lights/LightNodes.cs`, `LightNodes.Skybox.cs`, `LightEnums.cs`).
- **Why it matters:** flux has a PointLight type but no light-authoring operator family; AAA-class fidelity needs a full light taxonomy + light probes/IBL as first-class operators.
- **Likely missing from flux:** confirmed missing

### Materials / Shading Layers [visual]
- **Description:** Layered PBR material authoring — diffuse model, specular model, normal/displacement/emissive/metalness/glossiness layers, tessellation, transparency mode; assembled compositionally.
- **Representative nodes:** Material-feature nodes generated in `MaterialNodes.cs`, `VLMaterialEmissiveFeature.cs`, `VLMaterialTesselationFeature.cs`, `MaterialCustomTessellationFeature.cs`, `MaterialExtensions.cs`, `FallbackMaterial.cs`, `MaterialEnums.cs` (`VL.Stride.Runtime/src/Rendering/Materials/`).
- **Why it matters:** No material system means every shader is hand-authored; PBR pipelines need composable feature stacks (diffuse + specular + normal + emissive + ...) shared across many meshes.
- **Likely missing from flux:** confirmed missing

### Models / Mesh I/O & Splitting [scene]
- **Description:** Load FBX/glTF/OBJ/STL/PLY/DAE/blend, split a mesh into per-stream components, dynamic-mesh construction from vertex/index data, mesh extension utilities.
- **Representative nodes:** `FileModel`, `MeshModel`, `MeshesModel`, `DynamicMesh`, `DynamicMesh (Indexed)`, `MeshSplit`, `ModelReader`, `MeshExtensions` (Gray Book `reference/libraries/3d/models.md`; `VL.Stride.Runtime/src/Rendering/Models/ModelReader.cs`, `MeshExtensions.cs`, `ModelHelpers.cs`).
- **Why it matters:** Loaded glTF/OBJ is on flux's deferred list — this confirms it as a top-of-list family. The mesh-split operators are also notable: they let downstream nodes operate on individual vertex streams.
- **Likely missing from flux:** confirmed missing (deferred-but-noted)

### Post-Processing Stack [visual]
- **Description:** Standard post chain (bloom, DoF, ambient occlusion, motion blur, AA, tonemap, color transforms, custom color transforms) integrated with the compositor.
- **Representative nodes:** `ColorTransformGroupNode`, `CustomColorTransform`, `CustomPostFX`, `ApplyImageEffect`, plus Stride's PostFX taxonomy referenced from `reference/libraries/3d/rendering.md` (`VL.Stride.Runtime/src/Rendering/PostFX/`).
- **Why it matters:** Decima-class fidelity collapses without a configurable post stack. flux has none.
- **Likely missing from flux:** confirmed missing

### TextureFX (per-pixel shader-node family) [visual] [authoring]
- **Description:** A *node convention* that turns SDSL fragment shaders into operators with a uniform interface (Filter / Mixer / Source / Util variants). Each shader file ending in `_TextureFX.sdsl` becomes a node automatically.
- **Representative nodes:** Sources (`Noise`, `Gradient`, `Checkerboard`, `Halo`, `Mandelbrot`, `BubbleNoise`, `ColorPalette`, `Liquish`, `Neurons`, `Electricity`); Filters/ColorManipulation (`Anaglyph`, `HSCB`, `Invert`, `Levels`, `Dither`, `Posterize`, `Quantize`, `Sharpen`, `Edge`, `Threshold`, `Median`, `MapColor`, `Keying`, `DropShadow`, `Premultiply`, `Lomograph`, `ShiftRGB`); Filters/Blur (`BlurPerfector`, `DirectionalBlur`); Filters/Distortion (`Displace`, `Magnify`, `Tunnels`, `PolarToCartesian`, `Bump`, `Undistort`, `Transform`); Filters/Patterns (`Kaleidoscope`, `Mosaic`, `Scanline`, `Hatch_*`, `Dots`, `CrossStitch`); Filters/Morphology (`Dilate`, `Erode`, `UVDilate`); Filters/Depth, Filters/Glow; Mixers (`BlendMixer`, `Dissolve`, `Pixelate`, `Ripple`, `Blood`). (Gray Book `reference/libraries/3d/texturefx.md`; `VL.Stride.TextureFX/shaders/{Filters,Mixers,Sources}/`).
- **Why it matters:** This is the canonical answer to "how does a node-graph framework ship 60+ compositing/effect operators without bespoke wiring per node" — a *single* shader-to-node convention with attribute-driven categorization, automatic sRGB/linear conversion, opt-in mipmap generation, declared output format, and a wrapper that handles input/sampler/control/apply/output-format/output-size/output-texture pins. Flux has CreateRenderPipeline at the primitive layer but no per-shader-family convention.
- **Likely missing from flux:** confirmed missing (the convention itself; many of the shader effects are missing too)

### ShaderFX / DrawFX / ComputeFX (typed shader-node families) [visual] [authoring]
- **Description:** Three additional shader-node conventions distinguished by suffix: `_ShaderFX` (composable shader fragment), `_DrawFX` (geometry-drawing shader), `_ComputeFX` (compute-shader node).
- **Representative nodes:** Suffix conventions described in Gray Book `reference/libraries/3d/shaders.md`; effect plumbing in `VL.Stride.Runtime/src/Effects/{ComputeFX,ShaderFX,TextureFX}/`, `VLEffectMain.sdfx`, `DrawFXEffect.sdfx`.
- **Why it matters:** Same observation as TextureFX — a *naming convention* turns shader files into typed operators, scaling shader authorship to thousands of files without per-shader registration code.
- **Likely missing from flux:** confirmed missing (flux has LoadShaderOp / CreateRenderPipeline / CreateComputePipeline — primitive-level, no convention layer)

### Graphics Resources (Buffers / Textures / Samplers / Pipeline State) [scene]
- **Description:** Low-level GPU resources as first-class nodes — typed/structured/raw buffers, texture builders, sampler-state objects, blend / depth-stencil / rasterizer state descriptors, indirect-draw mesh.
- **Representative nodes:** `GraphicsNodes.BufferBuilder`, `GraphicsNodes.TextureBuilder`, `BufferViewDescription`, `BlendStateDescriptions`, `DepthStencilStateDescriptions`, `RasterizerStateDescriptions`, `MeshDrawIndirect`, `MipMapGenerator` (`VL.Stride.Runtime/src/Graphics/`, `VL.Stride.Runtime/src/Rendering/MeshDrawIndirect.cs`, `MipMapGenerator.cs`; also the dedicated `VL.Buffers` package).
- **Why it matters:** `MeshDrawIndirect` confirms that indirect-draw is a first-class node, not a primitive. flux currently has DispatchIndirect but no DrawIndirect / DrawIndexedIndirect.
- **Likely missing from flux:** partial — flux has Create{Texture,Buffer,Sampler,RenderPipeline,BindGroup}; missing DrawIndirect family and explicit blend/depth/rasterizer-state operators.

### Spreads / Collections Operators [authoring]
- **Description:** Operations over the immutable `Spread<T>` collection (vvvv's load-bearing data type) plus sequences, dictionaries, hashsets, spread-builders; includes ForEach / Repeat / Where / Map / Filter / Aggregate node and region variants.
- **Representative nodes:** ForEach, Repeat, Where, Select, GetSlice, SetSlice, ToBuilder, ToSpread, ResampleSpread (Gray Book `introduction/lo_9_2_Spreads.md`, `reference/libraries/collections.md`; `VL.CoreLib/src/Collections/`).
- **Why it matters:** The spread operator family is what makes "1000 instances" tractable — see the *Spreads* pattern below. flux has loops but no first-class collection type flowing on ports.
- **Likely missing from flux:** confirmed missing

### Reactive / IObservable [authoring]
- **Description:** Operators over `IObservable<T>` event streams — merge, switch, filter, scan, delay, sample-and-hold, hold-latest, throttle, skip, OfType, ForEach Region (Reactive), channel hubs for global parameter routing.
- **Representative nodes:** ForEach (Reactive), HoldLatest, Sampler, S+H, OfType, Where, Skip, Delay, Delay (Selector), Scan, Switch, ChannelHub, ToObservable* (Gray Book `reference/libraries/reactive.md`; `VL.CoreLib/src/Reactive/`).
- **Why it matters:** All event-driven IO (MIDI, OSC, mouse, network) is routed through observables and converted to mainloop values via Sampler/S+H/HoldLatest. flux has no IObservable equivalent — events would have to be polled into the dataflow.
- **Likely missing from flux:** confirmed missing

### Animation: Filters & Generators [authoring] [visual]
- **Description:** Time-based and frame-based generators (LFO, Stopwatch, Ramp) and filters (Damper, Oscillator, Spring, Decay) operating on numeric / vector ports; tween primitives.
- **Representative nodes:** LFO, Stopwatch, Ramp, Damper, Oscillator, parabola/tween utilities (`VL.CoreLib/src/Animation/Animation.cs`, `Parabolas.cs`; Gray Book `reference/libraries/corelib.md` describes the *Animation* and *FrameBased* subcategories).
- **Why it matters:** flux has TypedCurve keyframe playback but no live-signal filters or generators on the operator level (no Damper for smoothing input, no Spring for follow behaviour). Filters are what make analog-feel interactivity possible.
- **Likely missing from flux:** partial — flux has SineWave/Time/Random; missing damper/oscillator/spring/decay filter family.

### Animation: Timelines / Sequencing [authoring]
- **Description:** Editor-driven keyframe sequencers and timeliners (Kairos, Tilda, Interpolator) — multi-track editor UI on top of the value-interpolation primitives.
- **Representative nodes:** `VL.Kairos`, `Tilda`, `VL.Interpolator`, `VL.LoopTool` (Gray Book `reference/libraries/animation.md`).
- **Why it matters:** AAA cinematics and beat-aligned VJ work both need a timeliner UI; flux has the underlying curve type but no operator/UI for clip-based sequencing.
- **Likely missing from flux:** partial (curves exist; no clip/timeline operator)

### State Machine / Control Flow [authoring]
- **Description:** Finite-state-machine editor (AutomataUI) and lower-level control-flow nodes (FlipFlop, MonoFlop, TogEdge, S+H, Switch, TypeSwitch).
- **Representative nodes:** FlipFlop, MonoFlop, TogEdge, Switch, TypeSwitch, `VL.AutomataUI` (Gray Book `reference/libraries/corelib.md` "Control"; `VL.CoreLib/src/Control/SwitchNodes.cs`, `TypeSwitches.cs`; `reference/libraries/animation.md`).
- **Why it matters:** flux explicitly lacks Condition / Switch / Trigger / Gate / Sample-and-hold. These are the load-bearing operators for any non-trivial interaction logic; their presence as both *operators* and *editor-with-state-machine* is significant.
- **Likely missing from flux:** confirmed missing

### Input / Devices: Mouse, Keyboard, Touch, Gesture [authoring]
- **Description:** Cross-platform input event sources flowing as IObservable, plus 2D gesture recognizer ($Q), global hooks.
- **Representative nodes:** Mouse, Keyboard, Touch, Gestures (`VL.CoreLib/src/IO/MouseNodes.cs`, `KeyboardNodes.cs`, `TouchNodes.cs`, `GestureNodes.cs`; `VL.2D.DollarQ`, `VL.IO.MouseKeyGlobal`).
- **Why it matters:** flux has no interaction operators at all (gap noted in brief).
- **Likely missing from flux:** confirmed missing

### Networking [authoring]
- **Description:** Standard protocol family: UDP, TCP, WebSocket, OSC (+ OSCQuery), TUIO, MQTT, ZMQ, RCP, HTTP/REST, web-server, NDI, Ableton Link, Spout, Redis, Pipes.
- **Representative nodes:** UDP/TCP server+client, OSCServer/OSCClient, TUIO, MQTT, ZMQ, WebServer, HTTP Get/Post, NDI Send/Receive, AbletonLink (Gray Book `reference/libraries/networking.md`, `reference/libraries/other-io.md`; `VL.IO.OSCQuery`, `VL.IO.Pipes`, `VL.IO.Redis`, `VL.IO.Midi` — separate package).
- **Why it matters:** Single largest install-with-vvvv package category. flux has none.
- **Likely missing from flux:** confirmed missing

### Audio: Playback, Recording, Synthesis, Analysis [authoring]
- **Description:** Audio I/O (WASAPI, ASIO), playback, recording, FFT/beat/pitch analysis, modular synthesis primitives, LTC timecode, FMOD integration, MIDI in/out, SuperCollider bridge.
- **Representative nodes:** AudioEngine, AudioPlayer, AudioRecorder, FFT, BeatDetector, PitchDetector, Oscillator (sound), MIDI In/Out, FMOD events (`reference/libraries/audio.md`; `VL.Audio`, `VL.Audio.GPL`, `VL.Audio.LTC`, `VL.IO.Midi`, `VL.FMODStudio`, `VL.SCSynth`).
- **Likely missing from flux:** confirmed missing

### Video: Playback, Capture, Image-Sequence [visual] [authoring]
- **Description:** Video file playback (`VL.Video`, with Hap codec via `VL.HapPlayer`), capture-card input (DeckLink), camera input (uEye, IDS, Imaging Source, DSLR), GStreamer, ImagePlayer for frame sequences, Spout/NDI for inter-process video.
- **Representative nodes:** VideoPlayer, ImagePlayer (Skia + Stride), DeckLink In/Out, Spout Sender/Receiver, NDI Send/Receive (`reference/libraries/video.md`; `VL.Video`, `VL.Stride.Runtime/src/Video/`).
- **Likely missing from flux:** confirmed missing

### Computer Vision / Tracking [authoring]
- **Description:** OpenCV pipeline (filters, calibration, blob/contour/feature/marker/QR/face/Aruco detection, background subtraction, object tracking), MediaPipe (face/hand/pose/segmentation), Augmenta people tracking.
- **Representative nodes:** `VL.OpenCV` family, `VL.MediaPipe` (face/hand/pose), `VL.Augmenta` (`reference/libraries/computervision.md`, `reference/libraries/augmentedreality.md`).
- **Likely missing from flux:** confirmed missing (out of scope for Decima-class but listed for completeness)

### Depth Cameras / Skeletal Tracking [authoring] [scene]
- **Description:** Kinect, RealSense, Astra, Femto, ZED, Orbbec, Nuitrack, Leap Motion, Dollars MoCap — depth pointcloud, skeleton, blendshape sources.
- **Representative nodes:** Kinect/RealSense/ZED capture + skeleton readers (`reference/libraries/depthcameras.md`).
- **Likely missing from flux:** confirmed missing (out of Decima scope but anchors live-input axis)

### Lights & Lasers (DMX/Art-Net/ILDA) [authoring]
- **Description:** Output to physical lighting / projectors / lasers via DMX, Art-Net, ILDA, LaserCube.
- **Representative nodes:** `VL.IO.ArtNet`, `VL.Devices.ENTTEC`, `VL.ILDA`, `VL.Devices.LaserCube` (`reference/libraries/lightsandlasers.md`).
- **Likely missing from flux:** confirmed missing (installation-art axis; out of Decima scope)

### Projection Mapping / Warp & Blend [scene] [visual]
- **Description:** Warping (homography, bezier, mesh files), softedge blending, multi-projector calibration (Scalable Display, VIOSO), domemaster, MPCDI.
- **Representative nodes:** `VL.BadMapper`, `VL.Mapper`, `VL.ScalableDisplay`, `VL.VIOSOWarpBlend` (`reference/libraries/projectionmapping.md`).
- **Likely missing from flux:** confirmed missing (installation-axis specialization; not Decima but a key node-graph use case)

### Physics / Collision [scene]
- **Description:** Bullet-style rigid-body simulation with collider components (static/dynamic/kinematic/trigger) and collider shape descriptors (box/sphere/capsule/cone/cylinder/heightfield/plane/static-plane); marked `Stride.Experimental.Physics`.
- **Representative nodes:** `StaticColliderComponent`, `DynamicColliderComponent`, `KinematicColliderComponent`, `TriggerColliderComponent`; `{Box,Sphere,Capsule,Cone,Cylinder,Heightfield,StaticPlane}ColliderShapeDesc` (`VL.Stride.Runtime/src/Engine/PhysicsNodes.cs`).
- **Likely missing from flux:** confirmed missing

### 2D Graphics (Skia) [visual]
- **Description:** Full Skia 2D pipeline as nodes — paths, primitives, image/SVG drawing, text, Lottie animation, PDF/SVG/PNG export; layout (Yoga via VL.Flex), rich text (VL.RichTextKit), widget toolkit (VL.Elementa).
- **Representative nodes:** Paint, Path, DrawText, DrawImage, Lottie, SkiaRenderer, SkiaTexture (`reference/libraries/graphics-2d.md`; `VL.Skia/src/`; `VL.Stride.Runtime/src/SkiaRenderer.cs`, `SkiaTexture.cs`).
- **Why it matters:** AAA games' UIs increasingly use 2D vector pipelines (Decima uses libnoesis-equivalents); SkiaRenderer bridges 2D-into-Stride-texture which is the canonical "draw a vector UI into a 3D scene" pattern.
- **Likely missing from flux:** confirmed missing

### ImGui (in-app dev/parameter UI) [authoring]
- **Description:** Dear-ImGui binding exposed as nodes — used inside vvvv patches to build dev UIs and parameter inspectors.
- **Representative nodes:** ImGui windows / widgets via `VL.ImGui`, `VL.ImGui.Skia`, `VL.ImGui.Stride` (`VL.StandardLibs/VL.ImGui*`).
- **Why it matters:** flux already uses ImGui through slr-imgui / flux-imgui, but as a host concern; vvvv exposes ImGui *as nodes* — meaning UI is authored in the graph, not in code.
- **Likely missing from flux:** partial (flux has ImGui but not as operators; only as host UI)

### VR / XR Output [scene] [visual]
- **Description:** OpenXR / VR output integrated into the renderer (stereo render, head-tracked camera).
- **Representative nodes:** VR nodes via `VL.Stride.Runtime/src/Engine/VRNodes.cs`, `VLForwardRenderer.VRUtils.cs` (Gray Book `reference/libraries/3d/virtual-reality.md`).
- **Likely missing from flux:** confirmed missing

### Math / Noise / Geometry Utilities [visual] [authoring]
- **Description:** Vector / matrix / quaternion math; bounding shapes; noise (simplex, fast-noise-lite, sharp-noise, FastNoise2); curve fitting; smallest-enclosing-circle; polyline simplification; Voronoi/Delaunay; bezier/polypath; geometry3Sharp / GShark recommended.
- **Representative nodes:** `Vector{2,3,4}`, `Matrix{,3x3}`, `Quaternion`, `AlignedBox`, `OrientedBoundingBox`, `BoundingFrustum`, `Ray`, simplex/perlin/value noise, `VL.FastNoise{,Lite}`, `VL.2d.Voronoi`, `VL.2D.CurveFitting`, `VL.2D.Simplify` (`VL.CoreLib/src/3D/`, `VL.CoreLib/src/Math/`, `VL.CoreLib/src/2D/`; Gray Book `reference/libraries/misc.md`).
- **Likely missing from flux:** partial (flux has Perlin 2D+3D, scalar math; missing matrix/quaternion/frustum operators, advanced noise, geometric utilities)

### Color [visual] [authoring]
- **Description:** RGBA color type, color-space conversions, palette tools (ColorBlender, ColorLovers, ColorThief), Unicolour for interpolation + space conversions, OCIO display transforms.
- **Representative nodes:** `VL.CoreLib/src/Color/`, `VL.ColorBlender`, `VL.ColorThief`, `VL.Unicolour`, `VL.OCIO` (Gray Book `reference/libraries/color.md`).
- **Likely missing from flux:** partial (flux has Color type + ColorSpace + ColorLerp; missing palette tools, OCIO display transforms, full conversion taxonomy)

### File I/O / Filesystem / Watcher [authoring]
- **Description:** File read/write, path operations, special folders, file-system change watcher, downloader, file-type-association lookups.
- **Representative nodes:** `File`, `Path`, `Watcher`, `Downloader`, `VL.FsNotify` (`VL.CoreLib/src/IO/File.cs`, `Watcher.cs`, `Downloader.cs`).
- **Likely missing from flux:** partial (flux has LoadTextureOp / LoadShaderOp; missing generic file watcher / writer / downloader)

### Serialization / Markup [authoring]
- **Description:** XML / JSON / binary serialization, both automatic (FSPickler) and manual (XElement builder, ParseJson, XPath, ToJSON, ToString); CSV-style parsing; MessagePack; raw.
- **Representative nodes:** `Serialize/Deserialize`, `ToJSON`, `Parse [XML]`, `XPathSelectElement`, `FileReader/Writer (JSON|XML)`, `VL.Serialization.MessagePack`, `VL.Serialization.FSPickler` (Gray Book `reference/libraries/serialization.md`, `reference/libraries/json.md`, `reference/libraries/xml.md`).
- **Likely missing from flux:** confirmed missing (flux has .rsym/.rgraph/.rproj at framework level but no in-graph serialization operators)

### Databases / Persistence [authoring]
- **Description:** Redis (shipping), InfluxDB, generic SQL.
- **Representative nodes:** Redis Set/Get/Subscribe via `VL.IO.Redis`; `VL.InfluxDB` (Gray Book `reference/libraries/databases.md`).
- **Likely missing from flux:** confirmed missing (out of Decima scope but anchors the breadth axis)

### Physical Computing [authoring]
- **Description:** Microcontroller communication (Arduino/Firmata, Phidgets), serial port, Modbus.
- **Representative nodes:** Firmata, Phidget devices, SerialPort, Modbus (`reference/libraries/physicalcomputing.md`, `reference/libraries/other-io.md`).
- **Likely missing from flux:** confirmed missing (out of Decima scope)

### Machine Learning [authoring]
- **Description:** YOLO object detection, ONNX runtime, OpenAI/Ollama LLM bridges, Wekinator, Dlib.
- **Representative nodes:** `VL.YoloDotNet`, ONNX nodes, `VL.OpenAI`, `VL.Ollama`, `VL.Wekinator` (`reference/libraries/machinelearning.md`).
- **Likely missing from flux:** confirmed missing (out of Decima scope)

### TPL.Dataflow / Background Work [authoring]
- **Description:** .NET TPL Dataflow blocks exposed as nodes — background CPU work, bounded queues, action/transform/broadcast blocks; the typed parallel-pipeline alternative to IObservable for non-event workloads.
- **Representative nodes:** ActionBlock, TransformBlock, BroadcastBlock variants via `VL.TPL.Dataflow`.
- **Why it matters:** Long-running background work (asset loads, ML inference) needs operators that don't block the mainloop. Distinct from IObservable: TPL is for backpressured pipelines, IObservable for event streams.
- **Likely missing from flux:** confirmed missing

### Effect / Asset Pre-load / Resource Cache [scene] [authoring]
- **Description:** Asset-and-effect cache layer of the runtime — `EffectSystemExtensions`, `Assets`, `Resources`, effect-hot-reload via the `_NodeFactory_` machinery.
- **Representative nodes:** Asset loaders, effect cache (`VL.Stride.Runtime/src/Assets/`, `Resources/`, `Effects/`, `_NodeFactory_/`).
- **Why it matters:** flux just shipped its asset substrate; vvvv has a comparable layer plus runtime *hot-reload of shaders* (each save updates the node) — confirms hot-reload as a load-bearing feature, not a nice-to-have.
- **Likely missing from flux:** partial (flux has asset loading; shader hot-reload not noted as present)

## Notable patterns (not operators)

These are vvvv-specific *patterns* that determine what the operator graph CAN do; many are the reason individual families (TextureFX, Reactive, Physics) shrink to small node counts despite huge feature scope.

### Spreads (sequence-as-input, automatic instancing)
A `Spread<T>` is an immutable, indexable collection of `T` that flows on a single port — and almost every node "spreads" automatically: passing a Spread of 1000 transforms to a node that expects a single transform causes the node to run 1000 times. The Gray Book `introduction/lo_9_2_Spreads.md` makes the immutability guarantee explicit: a spread can be fed to many sinks and all sinks see the same data; "changing" a spread returns a new spread. Modulo-indexing means asking a 4-element spread for index 6 returns index 2, which is the load-bearing trick that makes parameter spreading (one transform per N objects, automatically extended) ergonomic. *This is the single most important pattern vvvv has and flux does not.* Without it, 1000 instances means 1000 wires.

### Process vs Operation Application (stateful vs stateless nodes)
Gray Book `introduction/nodes.md` distinguishes two node flavours visible in the patch: *operation applications* (stateless — output is purely a function of inputs, like Lerp or Add) and *process applications* (stateful — carry per-instance state across frames, like FlipFlop, S+H, TogEdge, an audio player, a network client). The whole running program is itself a process; "Create" runs once, "Update" runs every frame. This is a graph-level analogue to functional vs object semantics, and it is *visible in the node's appearance*. flux currently treats all operators uniformly; vvvv's separation is what lets stateful constructs (counters, edge detectors, smoothers) be operators at all without polluting the dataflow semantics.

### Regions (control flow as graph constructs)
Gray Book `introduction/lo_6_regions.md` defines: ForEach, Repeat, If, Where, Delegate, plus the more general "Operation Region". These are loop / conditional / closure constructs that *enclose part of the patch* — not separate node families. A Repeat region runs the enclosed body N times with one slice of each input collection per iteration; Where keeps only the items for which the body returns true; Delegate captures the body as a value that can be passed to nodes like `Apply` or `Where [Spread]`. The crucial bit is that **regions are the graph's loops AND its lambdas**: a delegate-region produces a first-class function-value. flux has Region::Loop, Region::Accumulate, Region::RenderPass but no Where / Filter / If region and no Delegate-as-value.

### IObservable as a Graph Type
Reactive event streams (`IObservable<T>`) are a port type, not a separate runtime — the same graph carries dataflow values *and* event streams, and conversion is explicit via three semantically distinct nodes: HoldLatest (always returns latest), Sampler (returns all events since last frame; may be empty), S+H (returns latest until next event). The Reactive `ForEach` region runs its body once per event (possibly off-thread). Gray Book `reference/libraries/reactive.md` lists the standard combinators: Skip, Delay, Scan, Switch, Where, OfType — these are RxJava/Rx.NET as a node family. *vvvv's single biggest architectural commitment.* Routing all input devices through observables means MIDI / OSC / mouse / network all use one event-handling pattern.

### Shader-File-As-Node-Convention (filename-driven node factories)
`*_TextureFX.sdsl`, `*_ShaderFX.sdsl`, `*_DrawFX.sdsl`, `*_ComputeFX.sdsl` files placed in a `/shaders` folder next to a `.vl` document automatically become nodes of the appropriate kind, with auto-derived input pins (uniforms become pins, samplers/textures get conventional names, attributes like `[Color]` or `[EnumType("...")]` reshape the UI), automatic sRGB/linear conversion, declared OutputFormat, and `[WantsMips]` for opt-in mipmap generation. Gray Book `reference/libraries/3d/texturefx.md` is essentially a spec. **This is how vvvv ships 60+ image-effect nodes without 60 registration sites.** flux has LoadShaderOp at the primitive layer but no convention to lift a `.wgsl` into an operator with typed pins.

### Type-Driven Adaptive Nodes ([Adaptive] generic dispatch)
Gray Book `reference/libraries/corelib.md` notes the *Adaptive* category: nodes that operate across datatypes — `+ [Adaptive]` works on numbers, strings, colors, vectors; `Length [Adaptive]` works for Vector2 and Vector3. Plus VL's first-class generics (`introduction/generics.md`). The patch decides specialization at link-time based on the resolved type of inputs. This is how vvvv keeps the node count manageable: one `+` for many types, not Add(Int)/Add(Float)/Add(Vec3).

### ChannelHub / Public Channels (global parameter routing)
`VL.CoreLib/src/Reactive/ChannelHub.cs`, `PublicChannelDescription.cs`, `SubChannels.cs`, `SplitterNode.cs` implement a global publish-subscribe channel registry — operators can name a channel and any other operator in any patch can subscribe. The Gray Book references this as the basis for RCP (RabbitControl) remote-control of running patches. *This is how vvvv solves the "1000-op project can't wire everything point-to-point" problem.* Channels are named global rails; flux currently routes all values through explicit links.

### Patch-Defines-Node (composition and reuse)
Gray Book `introduction/lo_3_defAndUse.md`: a patch IS a node definition. Using it elsewhere creates an instance with its own state. Critically — *one* place defines functionality, many places use it; this differs from vvvv beta where each sub-patch instance was its own window. The compile-once / instance-many semantics is what makes deep nesting tractable. flux's `.rsym` already encodes this; vvvv's documentation makes it canonical.

### Help-Patch / Documentation-as-Patch
Every library ships `.vl` "help patches" browsable via the Help Browser — runnable examples that *are also patches you can copy from*. (Mentioned across `reference/libraries/3d/rendering.md`, `models.md`, etc.) This is documentation-as-source: you don't read about a node, you open its help patch and inspect it live. For a 1000-operator project ecosystem this is what keeps onboarding feasible.

### Aspects (Experimental / Advanced / Internal / Obsolete) and Category Hiding
Nodes can be tagged with aspects in their category string (e.g. `Filter.Experimental`) — the Node Browser hides them unless the user enables that aspect. `reference/libraries/3d/texturefx.md` and `reference/libraries/collections.md` ("Enable the Advanced aspect to get access to many more collection types") show this is how vvvv keeps the default node browser navigable while still shipping thousands of nodes. *Pure curation primitive; no operator implementation needed.*

## Sources cited

Gray Book (`references/the-gray-book/`):
- `reference/libraries/overview.md`
- `reference/libraries/corelib.md`
- `reference/libraries/collections.md`
- `reference/libraries/reactive.md`
- `reference/libraries/animation.md`
- `reference/libraries/audio.md`
- `reference/libraries/video.md`
- `reference/libraries/color.md`
- `reference/libraries/computervision.md`
- `reference/libraries/machinelearning.md`
- `reference/libraries/networking.md`
- `reference/libraries/other-io.md`
- `reference/libraries/devices.md`
- `reference/libraries/depthcameras.md`
- `reference/libraries/lightsandlasers.md`
- `reference/libraries/physicalcomputing.md`
- `reference/libraries/projectionmapping.md`
- `reference/libraries/augmentedreality.md`
- `reference/libraries/databases.md`
- `reference/libraries/serialization.md`
- `reference/libraries/robots.md`
- `reference/libraries/misc.md`
- `reference/libraries/on-demand.md`
- `reference/libraries/graphics-2d.md`
- `reference/libraries/graphics-3d.md`
- `reference/libraries/3d/rendering.md`
- `reference/libraries/3d/models.md`
- `reference/libraries/3d/geometry.md`
- `reference/libraries/3d/shaders.md`
- `reference/libraries/3d/texturefx.md`
- `introduction/lo_0_dataHubs.md`
- `introduction/lo_2_dataflow.md`
- `introduction/lo_3_defAndUse.md`
- `introduction/lo_5_Runtime.md`
- `introduction/lo_6_regions.md`
- `introduction/lo_9_2_Spreads.md`
- `introduction/nodes.md`
- `introduction/mut.md`

VL.StandardLibs (`https://github.com/vvvv/VL.StandardLibs`):
- `VL.CoreLib/src/{2D,3D,Animation,Collections,Color,Control,IO,Math,Reactive,Transformation}/`
- `VL.Stride.Runtime/src/Engine/{EntityUtils.cs,ComponentUtils.cs,SceneUtils.cs,PhysicsNodes.cs,VRNodes.cs,EngineNodes.cs}`
- `VL.Stride.Runtime/src/Rendering/{Compositing,Lights,Materials,Models,PostFX,RenderFeatures,Renderers}/`
- `VL.Stride.Runtime/src/Rendering/{MeshDrawIndirect.cs,MipMapGenerator.cs,VLForwardRenderer.cs,VLForwardRenderer.LightProbes.cs,VLForwardRenderer.VRUtils.cs}`
- `VL.Stride.Runtime/src/Graphics/{BlendStateDescriptions.cs,DepthStencilStateDescriptions.cs,RasterizerStateDescriptions.cs,BufferViewDescription.cs,GraphicsNodes.{BufferBuilder,TextureBuilder}.cs}`
- `VL.Stride.Runtime/src/Effects/{ComputeFX,ShaderFX,TextureFX,Common}/`
- `VL.Stride.TextureFX/shaders/{Filters/{Blur,ColorManipulation,Depth,Distortion,Glow,Morphology,Patterns},Mixers/{Blend,...},Sources}/`
- `VL.Skia/src/`
- `VL.ImGui*`
- `VL.Buffers`
- `VL.TPL.Dataflow`
- Top-level package list (StandardLibs root): VL.Buffers, VL.Core.Commands, VL.Core.Skia, VL.Core, VL.CoreLib, VL.EditingFramework, VL.Fundamentals, VL.FuzzySearch, VL.IO.OSCQuery, VL.IO.Pipes, VL.IO.Redis, VL.ImGui*, VL.LogView, VL.Serialization.*, VL.Skia, VL.Stride*, VL.TPL.Dataflow, VL.Video.
