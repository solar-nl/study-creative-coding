# Operator Family Inventory: three.js

## Framework overview

three.js is a JavaScript 3D library organized as a retained-mode scene graph: an `Object3D` tree (`src/core/Object3D.js`) traversed each frame by a renderer (`src/renderers/WebGLRenderer.js`, `src/renderers/webgpu/WebGPURenderer.js`) that resolves materials, lights, geometries, and post-processing into draw calls. It is **not** a node graph at the project level, but its breadth makes `examples/jsm/` the canonical "what does a 3D scene need" catalog — each subdirectory there (`controls/`, `loaders/`, `postprocessing/`, `objects/`, etc.) is a self-contained family of building blocks layered on top of the core. The newer TSL (Three Shading Language) subsystem (`src/nodes/`, `examples/jsm/tsl/`) **is** a node graph — but for shader authoring, not project authoring — and offers a second, parallel inventory of "node families" worth mapping against flux.

Inventory paths consulted are rooted at `libraries/web/threejs/`.

## Families

### Scene Graph & Object Hierarchy [scene] [authoring]
- **Description:** Retained `Object3D` tree with parent/child transforms, world-matrix propagation, layers, and visibility flags — the spine of every three.js project.
- **Representative APIs:** `Object3D`, `Group`, `Scene`, `Layers`, `Clock` (`src/core/Object3D.js`, `src/objects/Group.js`, `src/scenes/Scene.js`, `src/core/Layers.js`).
- **Why it matters:** Without a hierarchical scene representation, transforms must be authored in absolute world space; sub-tree visibility, grouping, masking and "draw this branch into shadow map only" all collapse. At 1000-op scale, an addressable scene graph is the substrate culling/LOD/streaming hang off.
- **Likely missing from flux:** confirmed missing (flux brief: "no scene graph, no spatial index, no culling").

### Cameras [scene] [visual]
- **Description:** Camera primitives plus multi-view / stereo / cube variants.
- **Representative APIs:** `PerspectiveCamera`, `OrthographicCamera`, `CubeCamera`, `StereoCamera`, `ArrayCamera` (`src/cameras/`).
- **Why it matters:** `CubeCamera` is how env-maps / reflection probes get captured each frame; `ArrayCamera` is the multi-viewport primitive used for VR and shadow cascades; stereo cameras are the XR foundation. Flux has Perspective + Orthographic projections but no cube/array/stereo abstractions.
- **Likely missing from flux:** partial (perspective + ortho present, cube/array/stereo confirmed missing).

### Camera Controls [authoring] [scene]
- **Description:** Input-driven camera behaviors — orbit/fly/first-person/trackball/drag/pointer-lock/transform-gizmo.
- **Representative APIs:** `OrbitControls`, `MapControls`, `FlyControls`, `FirstPersonControls`, `TrackballControls`, `PointerLockControls`, `ArcballControls`, `TransformControls`, `DragControls` (`examples/jsm/controls/`).
- **Why it matters:** Every interactive 3D viewport ships at least one of these. `TransformControls` is the gizmo for in-viewport authoring of `position`/`rotation`/`scale` — without it, scene editing means typing numbers.
- **Likely missing from flux:** confirmed missing (brief: "no orbit, first-person, dolly, jitter, shake, follow, smooth-damp").

### Geometry Primitives & Parametric Surfaces [visual] [authoring]
- **Description:** Built-in mesh generators beyond the seven flux ships.
- **Representative APIs:** `BoxGeometry`, `SphereGeometry`, `CylinderGeometry`, `TorusGeometry`, `TorusKnotGeometry`, `IcosahedronGeometry`, `DodecahedronGeometry`, `OctahedronGeometry`, `TetrahedronGeometry`, `PolyhedronGeometry`, `RingGeometry`, `CircleGeometry`, `ConeGeometry`, `LatheGeometry`, `ExtrudeGeometry`, `ShapeGeometry`, `TubeGeometry`, `EdgesGeometry`, `WireframeGeometry` (`src/geometries/`); plus `RoundedBoxGeometry`, `DecalGeometry`, `ConvexGeometry`, `TextGeometry`, `ParametricGeometry`, `TeapotGeometry`, `BoxLineGeometry` (`examples/jsm/geometries/`).
- **Why it matters:** Decals (projected textures on surfaces), text-as-geometry, lathe/extrude/shape (2D→3D), edges/wireframe (debug), and parametric surfaces are core authoring vocabulary that flux's primitive set doesn't cover.
- **Likely missing from flux:** partial (7 primitives present; lathe/extrude/shape/text/decal/edges/parametric confirmed missing per brief).

### Curves & Splines [authoring] [visual]
- **Description:** Parametric curve types — bezier, catmull-rom, ellipse, spline, NURBS — usable for paths, sweeps, motion, and tube/extrude generation.
- **Representative APIs:** `CatmullRomCurve3`, `CubicBezierCurve3`, `QuadraticBezierCurve3`, `EllipseCurve`, `SplineCurve`, `LineCurve3`, `ArcCurve` (`src/extras/curves/`); `NURBSCurve`, `NURBSSurface`, `NURBSVolume` (`examples/jsm/curves/`).
- **Why it matters:** Curve-driven authoring (camera dollies, ribbon traces, tube meshes, particle paths, sweep surfaces) and `CurveModifier` (mesh-along-curve) are absent if no curve-value family exists.
- **Likely missing from flux:** probably missing (no curve type beyond animation keyframes referenced in brief).

### Lights [visual] [scene]
- **Description:** Analytic light source types + light probes + IES profiles.
- **Representative APIs:** `AmbientLight`, `DirectionalLight`, `PointLight`, `SpotLight`, `HemisphereLight`, `RectAreaLight`, `LightProbe` (`src/lights/`); `LightProbeGenerator`, `RectAreaLightUniformsLib`, `IESLoader` (`examples/jsm/lights/`, `examples/jsm/loaders/IESLoader.js`).
- **Why it matters:** PBR requires more than a single point light. RectArea (planar emitters), hemisphere (sky/ground), and IES (measured photometric profiles, the AAA lighting-artist standard) are typical AAA needs. Flux has a `PointLight` type but no light-authoring operators.
- **Likely missing from flux:** confirmed missing (brief: "no lighting operators, no shadow op, no IBL").

### Shadows [visual] [scene]
- **Description:** Per-light shadow configuration + cascaded shadow maps for sun lights at scene-scale.
- **Representative APIs:** `DirectionalLightShadow`, `SpotLightShadow`, `PointLightShadow`, `LightShadow` (`src/lights/*Shadow.js`); CSM stack `CSM`, `CSMFrustum`, `CSMShadowNode` (`examples/jsm/csm/`); TSL `TileShadowNode` (`examples/jsm/tsl/shadows/`).
- **Why it matters:** Cascaded shadow maps are non-negotiable for AAA sun lights covering kilometer-scale scenes; tile-shadow / point-shadow / spot-shadow each need their own projection setup. Flux has none.
- **Likely missing from flux:** confirmed missing.

### Materials (Surface Shading) [visual]
- **Description:** Pre-built material types covering basic, PBR, toon, matcap, normal, depth, sprite/points, shadow-only.
- **Representative APIs:** `MeshBasicMaterial`, `MeshStandardMaterial`, `MeshPhysicalMaterial`, `MeshPhongMaterial`, `MeshLambertMaterial`, `MeshToonMaterial`, `MeshMatcapMaterial`, `MeshNormalMaterial`, `MeshDepthMaterial`, `MeshDistanceMaterial`, `ShaderMaterial`, `RawShaderMaterial`, `ShadowMaterial`, `LineBasicMaterial`, `LineDashedMaterial`, `PointsMaterial`, `SpriteMaterial` (`src/materials/`); WoodNodeMaterial, LDraw materials (`examples/jsm/materials/`).
- **Why it matters:** A node-graph framework doesn't ship "materials" as monolithic types, but each material is effectively a curated bundle of operator wiring (BSDF + texture inputs + uniforms). The list is the menu of shading models a renderer is expected to support.
- **Likely missing from flux:** probably missing (no material-authoring operator family in brief; only raw `CreateRenderPipeline` + WGSL).

### Renderable Object Types [visual] [scene]
- **Description:** Specializations of `Object3D` that carry geometry/material and trigger different render paths.
- **Representative APIs:** `Mesh`, `InstancedMesh`, `BatchedMesh`, `SkinnedMesh`, `Skeleton`, `Bone`, `Line`, `LineLoop`, `LineSegments`, `Points`, `Sprite`, `LOD`, `ClippingGroup` (`src/objects/`).
- **Why it matters:** `InstancedMesh` and `BatchedMesh` are the AAA-scale primitives (thousands of trees / props). `LOD` is the explicit level-of-detail object. `SkinnedMesh`/`Skeleton`/`Bone` are the skeletal-animation triad. None present in flux.
- **Likely missing from flux:** confirmed missing.

### Skeletal / Character Animation [visual] [scene]
- **Description:** Bones, skeletons, skinning, animation clips, mixer/action state, IK.
- **Representative APIs:** `Skeleton`, `SkinnedMesh`, `Bone` (`src/objects/`); `AnimationMixer`, `AnimationAction`, `AnimationClip`, `KeyframeTrack`, `PropertyBinding` (`src/animation/`); `CCDIKSolver` (`examples/jsm/animation/CCDIKSolver.js`); `SkeletonUtils` (`examples/jsm/utils/SkeletonUtils.js`).
- **Why it matters:** Character-driven content (the bulk of AAA game scenes) is impossible without skinning + clip blending + IK retargeting. Flux animation today only drives operator input defaults — no skeleton concept.
- **Likely missing from flux:** confirmed missing.

### Loaders (Asset Import) [authoring] [scene]
- **Description:** File-format ingestors for meshes, scenes, textures, fonts, point clouds, volumes, motion data.
- **Representative APIs:**
  - **Scene/mesh:** `GLTFLoader`, `FBXLoader`, `OBJLoader`+`MTLLoader`, `ColladaLoader`, `STLLoader`, `PLYLoader`, `3MFLoader`, `3DMLoader`, `LWOLoader`, `VRMLLoader`, `VTKLoader`, `USDLoader`, `USDZLoader`, `LDrawLoader`, `MD2Loader`, `TDSLoader`, `AMFLoader`, `XYZLoader`, `PCDLoader`, `PDBLoader`, `VOXLoader`, `KMZLoader`, `GCodeLoader`, `NRRDLoader` (`examples/jsm/loaders/`).
  - **Texture/image:** `HDRLoader`, `RGBELoader`, `EXRLoader`, `KTX2Loader`, `KTXLoader`, `DDSLoader`, `PVRLoader`, `TGALoader`, `TIFFLoader`, `HDRCubeTextureLoader`, `UltraHDRLoader`, `LottieLoader`, `SVGLoader`, `FontLoader`, `TTFLoader`.
  - **Misc:** `BVHLoader` (motion-capture), `MDDLoader` (vertex animation), `IESLoader` (light profiles), `LUTCubeLoader`/`LUT3dlLoader`/`LUTImageLoader`, `MaterialXLoader`.
  - **Compression helpers:** `DRACOLoader`, `KTX2Loader`, `meshopt_decoder` (`examples/jsm/libs/`).
  - **Core:** `TextureLoader`, `ImageLoader`, `FileLoader`, `LoadingManager`, `Cache` (`src/loaders/`).
- **Why it matters:** glTF, USD, FBX are the lingua franca; HDR/EXR is mandatory for IBL; KTX2/DRACO for transmission; LUTs for color grading; BVH for mocap; IES for photometric lights. Each format flux can't ingest is content authors can't bring in.
- **Likely missing from flux:** confirmed missing (brief: glTF/OBJ "deferred"; LoadTextureOp only).

### Exporters [authoring]
- **Description:** Outbound counterparts to the loaders.
- **Representative APIs:** `GLTFExporter`, `USDZExporter`, `OBJExporter`, `PLYExporter`, `STLExporter`, `DRACOExporter`, `EXRExporter`, `KTX2Exporter` (`examples/jsm/exporters/`).
- **Why it matters:** Scene round-tripping (export to glTF for review, USDZ for AR preview, EXR for image dumps) is a baseline authoring expectation.
- **Likely missing from flux:** confirmed missing (only `SaveImageOp` per brief).

### Post-Processing Pass Library [visual]
- **Description:** Ordered stack of fullscreen passes applied after the main render — three.js's `EffectComposer` chain is the canonical pattern.
- **Representative APIs:** `EffectComposer`, `Pass`, `RenderPass`, `ShaderPass`, `TexturePass`, `SavePass`, `MaskPass`, `ClearPass`, `OutputPass`, `CubeTexturePass`, `RenderTransitionPass` (composer infrastructure).
  - **Bloom/glow:** `BloomPass`, `UnrealBloomPass`.
  - **AA:** `FXAAPass`, `SMAAPass`, `SSAARenderPass`, `TAARenderPass`.
  - **AO:** `SSAOPass`, `SAOPass`, `GTAOPass`.
  - **Reflections:** `SSRPass`.
  - **DOF/focus:** `BokehPass`.
  - **Stylized:** `DotScreenPass`, `HalftonePass`, `FilmPass`, `GlitchPass`, `AfterimagePass`, `RenderPixelatedPass`.
  - **Color:** `LUTPass`.
  - **Selection/outline:** `OutlinePass`.
  (`examples/jsm/postprocessing/`)
- **TSL parallel:** `BloomNode`, `DepthOfFieldNode`, `MotionBlur`, `SSGINode`, `SSRNode`, `SSSNode`, `TRAANode`, `ChromaticAberrationNode`, `AnamorphicNode`, `LensflareNode`, `SobelOperatorNode`, `PixelationPassNode`, `OutlineNode`, `Lut3DNode`, `DenoiseNode`, `GaussianBlurNode`, `boxBlur`, `hashBlur`, `radialBlur`, `SMAANode`, `FXAANode`, `GTAONode`, `SSAAPassNode`, `Sepia`, `BleachBypass`, `AfterImageNode`, `RGBShiftNode`, `DotScreenNode`, `FilmNode`, `TransitionNode` (`examples/jsm/tsl/display/`).
- **Why it matters:** Post-stack is the visual-fidelity dial. Bloom/tonemap/TAA/SSAO/SSR/DOF are baseline for "looks AAA"; the EffectComposer ordering pattern (RenderPass → effect → effect → OutputPass) is itself an authoring convention worth importing.
- **Likely missing from flux:** confirmed missing.

### Color, Tonemap & Color Space [visual]
- **Description:** Color-management infrastructure: working space, output color space, tonemap operators, color adjustment.
- **Representative APIs:** `Color`, `ColorManagement` (`src/math/`); `ToneMappingNode`, `ToneMappingFunctions`, `ColorSpaceNode`, `ColorSpaceFunctions`, `ColorAdjustment`, `BlendModes`, `RenderOutputNode` (`src/nodes/display/`); `ACESFilmicToneMappingShader`, `GammaCorrectionShader`, `HueSaturationShader`, `BrightnessContrastShader`, `ColorCorrectionShader`, `ColorifyShader` (`examples/jsm/shaders/`).
- **Why it matters:** Tonemap (ACES, Reinhard, AgX) + LUT3D + working/output color spaces are mandatory for HDR pipelines. Blend modes and hue/sat/contrast are compositing essentials.
- **Likely missing from flux:** confirmed missing (brief: "no compositing", "no post-processing", though Color type exists in flux-core).

### Environment / Image-Based Lighting [visual]
- **Description:** HDR environment maps, PMREM prefiltering, IBL contribution nodes, room/debug environments.
- **Representative APIs:** `PMREMGenerator` (`src/extras/PMREMGenerator.js`); `PMREMNode`, `PMREMUtils` (`src/nodes/pmrem/`); `EnvironmentNode`, `BasicEnvironmentNode`, `IrradianceNode`, `LightProbeNode` (`src/nodes/lighting/`); `RoomEnvironment`, `DebugEnvironment` (`examples/jsm/environments/`); `HDRLoader`/`RGBELoader`/`EXRLoader`/`HDRCubeTextureLoader`/`UltraHDRLoader` (`examples/jsm/loaders/`); `GroundedSkybox`, `Sky`, `SkyMesh` (`examples/jsm/objects/`).
- **Why it matters:** PBR without IBL is plastic. PMREM (prefiltered mipmaps of an env map for varying roughness) is the standard technique; sky/skybox/grounded-skybox are the runtime sources.
- **Likely missing from flux:** confirmed missing (brief flags IBL absent; see `insights/ibl-environment-lighting.md` for prior repo analysis).

### Helpers (Visual Debug Overlays) [authoring]
- **Description:** Wire/box/axes/grid visualizations of normally-invisible scene entities — cameras, lights, bounds, normals, skeletons, octrees.
- **Representative APIs:** `AxesHelper`, `GridHelper`, `PolarGridHelper`, `BoxHelper`, `Box3Helper`, `PlaneHelper`, `CameraHelper`, `DirectionalLightHelper`, `PointLightHelper`, `SpotLightHelper`, `HemisphereLightHelper`, `SkeletonHelper`, `ArrowHelper` (`src/helpers/`); `VertexNormalsHelper`, `VertexTangentsHelper`, `RectAreaLightHelper`, `LightProbeHelper`, `OctreeHelper`, `TextureHelper`, `ViewHelper`, `PositionalAudioHelper`, `RapierHelper` (`examples/jsm/helpers/`).
- **Why it matters:** At 1000-op scale, "I can't see why this light isn't hitting that mesh" needs an in-viewport debug overlay. Helpers are the cheap-to-implement, huge-payoff authoring family.
- **Likely missing from flux:** probably missing (no helper category in brief).

### Procedural Content & Modifiers [visual] [authoring]
- **Description:** Mesh-modifying transforms (subdivide, simplify, tessellate, edge-split, curve-deform) plus procedural objects.
- **Representative APIs:** `SimplifyModifier`, `TessellateModifier`, `EdgeSplitModifier`, `CurveModifier`/`CurveModifierGPU` (`examples/jsm/modifiers/`); `MarchingCubes`, `Reflector`, `Refractor`, `Water`, `Water2`, `Sky`, `Lensflare`, `ShadowMesh`, `GroundedSkybox` (`examples/jsm/objects/`); `ConvexObjectBreaker`, `TubePainter`, `Volume`, `MorphAnimMesh`, `MorphBlendMesh` (`examples/jsm/misc/`); `BufferGeometryUtils`, `GeometryCompressionUtils`, `GeometryUtils`, `SceneOptimizer` (`examples/jsm/utils/`).
- **Why it matters:** This is the "procedural" wing — the Werkkzeug lineage in three.js form. MarchingCubes (volumetric isosurface), Water/Sky (analytical surfaces), reflector/refractor (planar reflections), and mesh modifiers are routine creative-coding needs.
- **Likely missing from flux:** confirmed missing.

### Physics [scene]
- **Description:** Thin wrappers binding external physics engines into the scene graph.
- **Representative APIs:** `AmmoPhysics`, `JoltPhysics`, `RapierPhysics` (`examples/jsm/physics/`).
- **Why it matters:** Three.js delegates physics rather than implementing it — a useful precedent: physics integration is a single family of "drive transforms from external simulation," not a renderer concern.
- **Likely missing from flux:** confirmed missing.

### Audio & Spatial Sound [scene]
- **Description:** Web Audio bindings with positional/listener support.
- **Representative APIs:** `Audio`, `PositionalAudio`, `AudioListener`, `AudioAnalyser`, `AudioContext`, `AudioLoader` (`src/audio/`, `src/loaders/AudioLoader.js`); `PositionalAudioHelper` (`examples/jsm/helpers/`).
- **Why it matters:** Audio in / spatial audio out + FFT analyser is a creative-coding staple flux currently lacks (brief lists "no audio in, no MIDI, no OSC").
- **Likely missing from flux:** confirmed missing.

### Interaction & Picking [authoring] [scene]
- **Description:** Raycasting against the scene graph, selection boxes, HTML-in-3D, drag/hover.
- **Representative APIs:** `Raycaster` (`src/core/Raycaster.js`); `SelectionBox`, `SelectionHelper`, `HTMLMesh`, `InteractiveGroup` (`examples/jsm/interactive/`); `DragControls`, `TransformControls` (`examples/jsm/controls/`).
- **Why it matters:** Mouse picking and rectangle-select are how viewport editing works; `HTMLMesh` is how DOM UI panels embed inside the 3D scene.
- **Likely missing from flux:** confirmed missing (brief: "no mouse / keyboard / touch / gamepad operators").

### WebXR (VR / AR) [scene] [visual]
- **Description:** XR session entry, controller models, hand tracking, AR planes, room-scale lighting estimation.
- **Representative APIs:** `VRButton`, `ARButton`, `XRButton`, `XRControllerModelFactory`, `XRHandModelFactory`, `OculusHandModel`, `XRPlanes`, `XREstimatedLight` (`examples/jsm/webxr/`).
- **Why it matters:** Marks XR as an entire delivery target with its own family. Out-of-scope for flux's current envelope but the **stereo / array-camera / multi-view** plumbing it relies on is shared with shadow cascades.
- **Likely missing from flux:** confirmed missing.

### Auxiliary Renderers (Non-Raster) [visual] [authoring]
- **Description:** Renderers other than the main raster path — DOM-overlay (CSS), software, vector.
- **Representative APIs:** `CSS2DRenderer`, `CSS3DRenderer`, `SVGRenderer`, `Projector` (`examples/jsm/renderers/`).
- **Why it matters:** CSS overlays for labels/UI in 3D space; SVG renderer for printable vector output; useful precedents for "the framework outputs more than one kind of frame."
- **Likely missing from flux:** confirmed missing.

### Render Targets & Texture Types [visual] [scene]
- **Description:** Off-screen render targets and the matching texture-flavor zoo.
- **Representative APIs:** `WebGLRenderTarget`, `WebGLCubeRenderTarget`, `WebGLArrayRenderTarget`, `WebGL3DRenderTarget`, `RenderTarget`, `RenderTarget3D` (`src/renderers/`, `src/core/`); `DataTexture`, `Data3DTexture`, `DataArrayTexture`, `DepthTexture`, `CubeDepthTexture`, `CubeTexture`, `CanvasTexture`, `VideoTexture`, `VideoFrameTexture`, `FramebufferTexture`, `CompressedTexture`, `CompressedArrayTexture`, `CompressedCubeTexture`, `ExternalTexture` (`src/textures/`).
- **Why it matters:** Cube / array / 3D textures + matching render targets are required for shadow cascades, env capture, volumetrics. `VideoTexture` is the canonical "live video frame as texture" path. Flux has `CreateTexture` / `CreateTextureView` but the inventory of *kinds* (cube/array/3D/video/compressed/depth/external) is the family question.
- **Likely missing from flux:** partial.

### GPU Compute / GPGPU [visual] [scene]
- **Description:** Ping-pong compute over textures (legacy) plus modern TSL compute nodes.
- **Representative APIs:** `GPUComputationRenderer` (`examples/jsm/misc/GPUComputationRenderer.js`); `BitonicSort` (`examples/jsm/gpgpu/`); `ComputeNode`, `AtomicFunctionNode`, `BarrierNode`, `WorkgroupInfoNode`, `SubgroupFunctionNode`, `ComputeBuiltinNode` (`src/nodes/gpgpu/`).
- **Why it matters:** Particles, large-N simulations (boids/fluids/cloth), GPU sort, prefix scan all live here. Flux has `CreateComputePipeline` + `ComputeDispatch` + `DispatchIndirect`; the family above it (curated compute building blocks: sort, scan, reduce, atomics) is missing.
- **Likely missing from flux:** partial.

### Shader Building Blocks (TSL Standard Library) [visual] [authoring]
- **Description:** The TSL node catalog — three.js's *actual* node graph — covers shader-level operations: math, accessors, lighting models, fog, procedural, geometry, BSDFs.
- **Representative APIs:** `accessors/` (Position, Normal, UV, Camera, Model, MVP, Instance, Batch, Morph, Bitangent, Lights, MaterialReference); `math/` (Operator, Conditional, Hash, TriNoise3D, BitcastNode); `display/` (BlendModes, ToneMapping, ColorSpace, Posterize, Viewport*, NormalMap, BumpMap); `lighting/` (Analytic/Hemisphere/Directional/Point/Spot/RectArea/Projector/IES/PointShadow lights, EnvironmentNode, ShadowFilterNode); `functions/BSDF/` (microfacet, PhysicalLightingModel, ToonLightingModel, VolumetricLightingModel); `procedural/Checker`; `shapes/`; `fog/` (`src/nodes/`).
- **Why it matters:** This is the closest analog to flux's eventual shader-graph layer. The taxonomy alone (accessors / math / display / lighting / functions / procedural / shapes / fog / gpgpu / pmrem) is a useful organising structure.
- **Likely missing from flux:** confirmed missing (no shader-graph layer in flux; only handwritten WGSL).

### Fog & Atmospherics [visual]
- **Description:** Linear / exponential fog driven from the scene.
- **Representative APIs:** `Fog`, `FogExp2` (`src/scenes/`); fog `FogNode` (`src/nodes/fog/Fog.js`).
- **Why it matters:** Cheap distance attenuation, scene-wide. A single operator could cover it.
- **Likely missing from flux:** probably missing.

### Math Primitives [visual] [scene]
- **Description:** Vector / matrix / quaternion / geometric primitives.
- **Representative APIs:** `Vector2/3/4`, `Matrix2/3/4`, `Quaternion`, `Euler`, `Color`, `Box2`, `Box3`, `Sphere`, `Plane`, `Ray`, `Frustum`, `FrustumArray`, `Triangle`, `Line3`, `Spherical`, `Cylindrical`, `SphericalHarmonics3`, `Interpolant`, `MathUtils` (`src/math/`).
- **Why it matters:** Frustum / Box3 / Sphere are the bones of culling; SphericalHarmonics3 is the IBL irradiance representation. Flux has Matrix4 + constructors; the supporting cast (frustum, bounding volumes, plane, ray, SH) is presumably missing or partial.
- **Likely missing from flux:** partial.

### Tiled / Clustered Lighting [visual] [scene]
- **Description:** Many-light path that bins lights into screen tiles or view-frustum clusters before shading.
- **Representative APIs:** `TiledLighting` (`examples/jsm/lighting/TiledLighting.js`); `TiledLightsNode` (`examples/jsm/tsl/lighting/`); `TileShadowNode` (`examples/jsm/tsl/shadows/`).
- **Why it matters:** Decima-class scenes need hundreds of dynamic lights; the forward+/clustered family is the standard answer. Flux has nothing here.
- **Likely missing from flux:** confirmed missing.

### Line Rendering (Thick Lines) [visual]
- **Description:** Screen-space-extruded lines that don't collapse at 1px regardless of GPU rasteriser.
- **Representative APIs:** `Line2`, `LineSegments2`, `LineGeometry`, `LineSegmentsGeometry`, `LineMaterial`, `Wireframe`, `WireframeGeometry2` (`examples/jsm/lines/`).
- **Why it matters:** Native GL lines are 1px on most platforms. Any data-viz / CAD / wireframe-overlay use case needs the extruded-quad approach.
- **Likely missing from flux:** confirmed missing.

### Scene Optimization & Spatial Queries [scene]
- **Description:** Utilities that pack/merge/sort/compress scenes for runtime efficiency.
- **Representative APIs:** `SceneOptimizer`, `BufferGeometryUtils`, `GeometryCompressionUtils`, `SortUtils`, `WorkerPool` (`examples/jsm/utils/`); `OctreeHelper` (`examples/jsm/helpers/`); `Frustum`, `Box3`, `Sphere` (`src/math/`).
- **Why it matters:** AAA-scale = mesh merging, attribute quantization, instance batching, octree culling. Three.js's coverage here is light (mostly utilities, not full streaming), but the family is named.
- **Likely missing from flux:** confirmed missing.

## Notable patterns (not operators)

- **Retained scene graph + frame-driven traversal.** The renderer walks the `Object3D` tree each frame (`Renderer.render(scene, camera)`); culling/sorting/render-list construction happens once per frame inside the traversal. Flux's pure-evaluation model needs an equivalent concept of "scene description that persists across frames and is walked, not re-evaluated from scratch."
- **EffectComposer pass-chain pattern.** `composer.addPass(new RenderPass(...))`, `addPass(new BloomPass(...))`, ..., `addPass(new OutputPass())` — an ordered, named, ping-pong-buffered linear chain. This is a *first-class authoring pattern* (not buried in the renderer): "build the post-stack as an explicit operator-pipeline." Tier-1 candidate for any node-graph renderer.
- **Pass.needsSwap / Pass.renderToScreen flags.** Each pass declares whether it swaps the read/write target — encodes pipeline-graph semantics ("I read FBO A, write FBO B; please swap before next pass") without a full DAG. A simple convention scaling to dozens of passes.
- **GLTFLoader extension architecture.** Each glTF extension (KHR_draco_mesh_compression, KHR_materials_clearcoat, EXT_meshopt_compression, …) registers as a plugin module against the loader. Demonstrates a **plugin-per-format-extension** pattern that scales without bloating the core loader.
- **PMREM = "pre-compute IBL the right way."** A dedicated, separate generation pass that prefilters env maps per roughness mip — a precedent for "asset-time / load-time" passes distinct from the per-frame graph.
- **CubeCamera as scene-graph object.** A camera that renders the scene six times into a cube map, **as a member of the scene** — pattern for "renderer output as graph input" without a separate orchestration layer.
- **InstancedMesh / BatchedMesh as object types, not draw-call flags.** Instancing/batching are *scene-graph object kinds*, exposed at the same level as a regular `Mesh`. Authoring-level handle on the scale primitive.
- **Helpers as parallel scene-graph entities.** Helpers (CameraHelper, SkeletonHelper, OctreeHelper) are themselves `Object3D`s — they live in the scene, render alongside real geometry, attach to a target. Debug-overlay system as ordinary scene content rather than a separate rendering pipeline.
- **TSL: a node graph for shaders, retained-mode for scene.** Three.js draws a deliberate boundary: the *scene* is retained-mode imperative; the *shader* is a node graph. Flux's bet is "node graph all the way down" — but TSL's existence is evidence that even teams who think retained-mode is fine for scenes adopt a node graph for shaders.
- **DataMap / WeakMap pattern for resource lifetimes.** GPU resources are stored in WeakMaps keyed by the JS object they back; when the JS object is GC'd, the GPU entry vanishes (per `notes/per-library/web/threejs/README.md`). Useful precedent for any pure-function-style framework that nonetheless caches GPU resources.
- **Three loader tiers: built-in / official-jsm / community.** Core (`src/loaders/`) loads three.js's own formats; `examples/jsm/loaders/` loads external formats with bundled dependencies in `examples/jsm/libs/`; everything else is community npm. A tiering hint for how flux might expose "core ops vs official ops vs community ops."

## Sources cited

- `libraries/web/threejs/src/` — core (cameras, lights, materials, objects, geometries, scenes, core, animation, audio, loaders, renderers, textures, nodes, math, extras, helpers)
- `libraries/web/threejs/examples/jsm/` — all subdirectories (controls, animation, geometries, helpers, lights, lines, materials, objects, modifiers, physics, renderers, exporters, misc, curves, environments, shaders, textures, effects, lighting, interactive, webxr, csm, gpgpu, offscreen, utils, tsl, libs, capabilities, postprocessing, loaders)
- `notes/per-library/web/threejs/README.md` — prior repo analysis of three.js renderer architecture (used for confirmation of the WeakMap/DataMap pattern only; not duplicative of family inventory)
- `notes/themes/rendering/gpu-resources/per-framework/threejs.md` — prior repo notes (consulted for context, not cited content)
