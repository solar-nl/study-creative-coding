# Operator Family Inventory: openrndr + orx

## Framework overview

openrndr is a Kotlin-based creative coding framework with a retained-mode-ish `Drawer` API and a strong shader/filter abstraction (`Filter`, `ShadeStyle`, `ColorBuffer`, `RenderTarget` — see `frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/`). It is *not* a node graph: families show up as Kotlin classes/DSLs rather than ops, but the **orx extension catalog** (`libraries/openrndr-ecosystem/orx/README.md`) is essentially a per-family checklist — each `orx-*` module is a single curated capability with a stable name and a one-line description, exactly the granularity the brief asks for. openrndr is the closest spiritual match to flux because it is typed, modern, opinionated, multiplatform, and explicitly opts *out* of Processing-style implicit globals — fidelity and authoring posture are aligned with flux's "operator-first, no-magic" stance, even though the evaluation model differs. Existing notes at `notes/per-framework/openrndr/` are mostly placeholder stubs (e.g., `architecture.md`, `api-design.md`, `rendering-pipeline.md` are all marked "not yet documented"); the `README.md` confirms the module structure (`openrndr-application`, `openrndr-draw`, `openrndr-gl3`, `openrndr-math`, `openrndr-color`, `openrndr-shape`) and the dependency-cataloged backends (LWJGL/OpenGL, GLFW, OpenAL, FFmpeg). This inventory derives families directly from the orx README list plus the core module breakdown rather than re-deriving framework architecture.

## Families

### 2D Shape & Contour Math [scene] [authoring]
- **Description:** First-class typed 2D primitive + Bezier contour algebra (boolean ops, offsets, splits, segment math) — not just drawing, but a manipulable geometric model.
- **Representative orx modules / openrndr APIs:** `openrndr-shape/src/commonMain/kotlin/org/openrndr/shape/Shape.kt`, `ShapeContour.kt`, `Segment2D.kt`, `Path.kt`, `Triangulator.kt`; `orx-shapes/` (adjust/regular/operators); `orx-composition/`; `orx-turtle/`; `orx-text-on-contour/`.
- **Why it matters:** A retained 2D geometry algebra is what enables motion-graphics / generative-design authoring — boolean ops on contours, splitting/joining segments, adjusting individual vertices. flux currently has no 2D-shape value type at all.
- **Likely missing from flux:** confirmed missing

### Mesh Generators (Procedural 3D Primitives) [scene] [authoring]
- **Description:** Procedural mesh authoring beyond a fixed primitive list — DSL builders, revolve/sweep, taperedCylinder, hemisphere, dodecahedron, cap, etc.
- **Representative orx modules / openrndr APIs:** `orx-mesh-generators/README.md` (`buildTriangleMesh { ... }`, `sphereMesh`, `revolveMesh`, `capMesh`, `taperedCylinderMesh`, `dodecahedronMesh`, `planeMesh`).
- **Why it matters:** flux ships 7 fixed primitives but no parametric / revolve / DSL-style mesh authoring. The orx-mesh-generators DSL is the closest analogue to "mesh-modify operator family" in a code-first framework.
- **Likely missing from flux:** partial (primitives present, no DSL/sweep/revolve, no dodecahedron-class primitives)

### Mesh I/O & Mesh Data Model [scene]
- **Description:** Loading/saving mesh formats and an explicit mesh data type separate from drawing buffers.
- **Representative orx modules / openrndr APIs:** `orx-mesh/` (mesh data model), `orx-obj-loader/` (Wavefront OBJ loader/saver), `orx-jvm/orx-dnk3/` (glTF/GLB scene loader with skinning + animations).
- **Why it matters:** flux has no mesh loader; the deferred-glTF gap is well-known. orx isolates the data model (`orx-mesh`) from the parser (`orx-obj-loader`, `orx-dnk3`), which is a useful split.
- **Likely missing from flux:** confirmed missing

### Mesh Surface Sampling / Procedural Population [scene] [visual]
- **Description:** Sampling points on / distributing geometry across a mesh surface — the seed of foliage/scatter/instance workflows.
- **Representative orx modules / openrndr APIs:** `orx-mesh-noise/` ("Generate random samples on the surface of a mesh").
- **Why it matters:** A Decima-class scene needs scatter/instance tooling (foliage, debris). Surface sampling is a precursor.
- **Likely missing from flux:** confirmed missing

### Camera & Camera Controls [scene] [authoring]
- **Description:** Orbital/first-person/2D camera rigs with bound mouse+keyboard controls and debug helpers (axis gizmo, ground grid).
- **Representative orx modules / openrndr APIs:** `orx-camera/README.md` (`OrbitalCamera`, `OrbitalControls`, `AxisHelper`, `GridHelper`); openrndr-core perspective/ortho built into `Drawer`.
- **Why it matters:** flux has Perspective/Ortho + LookAtView but no orbital/first-person/dolly/follow rigs and no debug helpers. orx-camera pairs the rig with the input bindings, which is a complete authoring unit.
- **Likely missing from flux:** partial (projections only)

### Scene Graph / 3D Renderer [scene] [visual]
- **Description:** Hierarchical scene with PBR materials (basic + normal + metallic/roughness maps), skeletal skinning, animation playback, IBL.
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-dnk3/README.md` ("A scene graph based 3d renderer with support for Gltf based assets"; ticks for Scene hierarchy, Mesh data, glB, Basic materials, Normal maps, Metallic/roughness maps, Skinning, Double-sided, Animations; un-ticked for Cameras, Lights, Transparency).
- **Why it matters:** dnk3 is the most direct analogue to a "Decima-class" scene module in the openrndr world — and even it explicitly lists Cameras/Lights/Transparency as TODOs, which is a useful warning about how much work the family encompasses.
- **Likely missing from flux:** confirmed missing

### Post-FX Stack (Filter Library) [visual]
- **Description:** A broad, named, parameter-annotated GPU filter catalog with a `Post` extension that handles intermediate buffer allocation.
- **Representative orx modules / openrndr APIs:** `orx-fx/README.md` (FXAA antialias; ApproximateGaussianBlur/Bloom/BoxBlur/MipBloom/ZoomBlur/HashBlur/LineBlur; ChromaticAberration/ColorCorrection/ColorLookup/Duotone/LumaMap/Posterize/Sepia; Fisheye/Lenses/Perturb/VideoGlitch/Tiles/PolarToRectangular; ADither/CMYKHalftone/Crosshatch/LumaHalftone; LumaSobel/Contour/CannyEdgeDetector; FilmGrain; DropShadow; Uncharted2Tonemap; FlipVertically); `orx-fx/src/commonMain/kotlin/{antialias,blend,blur,color,colormap,composite,distort,dither,edges,grain,patterns,shadow,tonemap,transform}/`; `orx-fx/Post.kt`.
- **Why it matters:** flux has zero post operators. orx-fx is essentially a finished post-stack with ~50 named effects organized into categorical sub-folders.
- **Likely missing from flux:** confirmed missing

### Compositor / Layered Compositing [authoring] [visual]
- **Description:** Layer/`compose { layer { ... } }` DSL with blend modes and per-layer filter pipelines.
- **Representative orx modules / openrndr APIs:** `orx-compositor/README.md` (`compose { layer { draw { ... } } }`); `orx-fx/blend/` (Photoshop + Porter-Duff blend kernels: Multiply, Screen, Overlay, ColorBurn, SourceIn, SourceOut, SourceAtop, DestinationIn, DestinationOut, DestinationAtop, Xor).
- **Why it matters:** flux has no compositing operators — no over/under/multiply at the operator level, only what an author writes in WGSL. orx-compositor + orx-fx/blend ship a complete layered-composition substrate.
- **Likely missing from flux:** confirmed missing

### Shade Style / Procedural Fill DSL [visual] [authoring]
- **Description:** Shader-fragment fills (gradients, clip masks, hatch patterns) configured as values rather than written as full shaders.
- **Representative orx modules / openrndr APIs:** `orx-shade-styles/` (linear/radial/conic gradients, clip via star/circle/rectangle/line/ellipse, feathering); openrndr-draw `ShadeStyle.kt`, `ShadeStyleManager.kt`, `ShadeStyleGLSL.kt`.
- **Why it matters:** A "shader-as-value" pattern is what enables parameter-animated material work without round-tripping through full shader recompiles. flux currently requires authors to write WGSL for any non-trivial fill.
- **Likely missing from flux:** confirmed missing

### Shader Composition / Includes [authoring]
- **Description:** `#pragma import` semantics for GLSL: reusable shader phrases composed into final programs.
- **Representative orx modules / openrndr APIs:** `orx-shader-phrases/` ("A library that provides a `#pragma import` statement for shaders.").
- **Why it matters:** At 1000-op scale, shader text duplication becomes an authoring tax; a shader-include mechanism is part of authoring-at-scale tooling.
- **Likely missing from flux:** confirmed missing (flux WGSL is currently per-op without an import substrate)

### Noise & Procedural Random [scene] [visual]
- **Description:** Multi-kind noise (Perlin/Simplex/Value/Worley/uniform/fractal) plus composition combinators (`.fbm()`, `.withPolarInput()`).
- **Representative orx modules / openrndr APIs:** `orx-noise/README.md` (`Vector2/3/4.uniform`, `uniformRing`, `perlinLinear1D.fbm()`, `simplex2D.withPolarInput()`).
- **Why it matters:** flux has 2D + 3D Perlin and Random; orx-noise demonstrates that the family is richer (multiple noise kernels, multi-dim variants, FBM/octave combinators, polar/spherical wrappers).
- **Likely missing from flux:** partial

### Color Spaces, Palettes & Histograms [visual] [authoring]
- **Description:** Beyond an RGBA value type: named palettes, histogram analysis from images, perceptual color spaces.
- **Representative orx modules / openrndr APIs:** `openrndr-color/`; `orx-color/README.md` (presets/named colors, `calculateHistogramRGB`, `sortedColors`); `orx-palette/` ("Collections of color palettes and tools"); `orx-fx/color/RgbToOkLab`/`OkLabToRgb`.
- **Why it matters:** flux has `Color` and an animation lerp; no palette type, no histogram, no OkLab. Color-space conversion as a filter (orx-fx) is a useful pattern.
- **Likely missing from flux:** partial (Color present; palette/histogram/OkLab absent)

### Animation / Keyframe / Timeline [authoring]
- **Description:** JSON-defined keyframed timelines with easing, expressions, callbacks, scrub/reverse playback.
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-keyframer/README.md` (JSON keyframes with `time`/`easing`/property values, mathematical expressions, callbacks); `orx-easing/` (full easing function table — Quad/Cubic/Quart/Quint/Sine/Expo/Circ/Back/Elastic/Bounce In/Out/InOut); `orx-fcurve/` (SVG-path-style 1D function curves: `m/h/l/q/c` commands); `openrndr-animatable/`.
- **Why it matters:** flux has TypedCurve over Scalar/Vec2/Vec3/Vec4/Color but no timeline DSL, no easing library, no FCurve syntax, no JSON timelines. orx-keyframer's expression+callback model is closest to a "Decima-class" animation track.
- **Likely missing from flux:** partial (compound curves present; easing library + timeline DSL + FCurve syntax absent)

### Time-Domain Signal Generators (Envelopes, LFOs) [authoring]
- **Description:** ADSR envelopes, LFOs, time-based signal generators as named first-class objects.
- **Representative orx modules / openrndr APIs:** `orx-envelopes/` ("ADSR (Attack, Decay, Sustain, Release) envelopes and tools"); `orx-time-operators/` ("collection of time-sensitive functions … such as Envelope and LFO"); `orx-timer/` (`repeat`, `timeOut`).
- **Why it matters:** flux has SineWave + Time but no ADSR, no LFO bank, no scheduled-callback timers. Signal generators are the "audio-DAW-style" half of an authoring model.
- **Likely missing from flux:** partial

### MIDI / OSC / Network Input [authoring]
- **Description:** External-control input from MIDI hardware and OSC-speaking applications.
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-midi/README.md` (`listMidiDevices`, `openMidiDevice`, `controlChanged.listen`); `orx-jvm/orx-osc/README.md` (`osc.listen("/live/track2")`, `osc.send`); `orx-jvm/orx-chataigne/` (Chataigne integration via OSC); `orx-jvm/orx-rabbit-control/` (web-based remote UI).
- **Why it matters:** flux has no input operators of any kind (mouse/keyboard/MIDI/OSC). For live-performance / installation use, these are Tier-1; for film-style authoring, secondary but not negligible.
- **Likely missing from flux:** confirmed missing

### Audio I/O & Analysis [authoring]
- **Description:** Audio synthesis + spectral analysis (FFT), audio file loading.
- **Representative orx modules / openrndr APIs:** `orx-fft/` (forward/inverse FFT, Kotlin port of Minim's FFT); `orx-jvm/orx-minim/` ("sound synthesis and analysis"); LWJGL OpenAL bindings in core (`notes/per-framework/openrndr/dependencies.md`).
- **Why it matters:** Audio-reactive visuals are the canonical creative-coding output. flux has no audio.
- **Likely missing from flux:** confirmed missing

### Video & Depth-Camera Input [visual] [authoring]
- **Description:** Live video / depth-camera input as a `ColorBuffer` source.
- **Representative orx modules / openrndr APIs:** `orx-depth-camera/` (multi-platform); `orx-jvm/orx-kinect-v1/` (Kinect V1 RGB+depth); `orx-jvm/orx-depth-camera-calibrator/`; FFmpeg dependency (`dependencies.md` line 56) for video decode/encode.
- **Why it matters:** flux has no video / camera input. Decima target doesn't require Kinect, but FFmpeg-backed video texture playback is plausibly in-scope.
- **Likely missing from flux:** confirmed missing

### Video / Screen Recording Output [authoring]
- **Description:** Recording the render output to image-sequence or video formats from inside the application.
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-video-profiles/README.md` (GIF, H265, PNG, Prores, TIFF, Webp `VideoWriterProfile`s for `ScreenRecorder` / `VideoWriter`).
- **Why it matters:** flux has SaveImageOp (single-frame PNG) but no video / image-sequence recorder. For dump-and-verify and for offline render, this is part of the authoring loop.
- **Likely missing from flux:** partial

### SVG / Vector I/O [authoring]
- **Description:** SVG load/save round-trip.
- **Representative orx modules / openrndr APIs:** `orx-svg/README.md` (`loadSVG`, `parseSVG`, `Shape.toSvg()`, `ShapeContour.toSvg()`).
- **Why it matters:** Vector I/O is a code-first staple; flux has no vector pipeline. Lower priority than mesh I/O but adjacent.
- **Likely missing from flux:** confirmed missing (and dependent on the 2D Shape family above)

### Text Rendering & Layout [scene] [authoring]
- **Description:** Font loading, glyph drawing, text-on-contour layout, text writer with positioning rules.
- **Representative orx modules / openrndr APIs:** `openrndr-draw/.../font/`, `openrndr-draw/.../FontMap.kt`; `orx-text-writer/`; `orx-text-on-contour/`.
- **Why it matters:** flux has no text. Text is often punted by node-graph frameworks but is needed for UI/debug/credits.
- **Likely missing from flux:** confirmed missing

### Spatial Indices (2D/3D Nearest-Neighbour) [scene]
- **Description:** Spatial partitioning structures (quadtree, kd-tree, hash grid) for nearest-point / range queries at high point counts.
- **Representative orx modules / openrndr APIs:** `orx-quadtree/` (2D spatial range queries); `orx-hash-grid/` ("2D space partitioning for fast point queries"); `orx-kdtree/` (2D/3D/4D nearest-point); `orx-interval-tree/` (1D time-segment queries for timelines).
- **Why it matters:** At 1000-op / 1000-instance scale, spatial queries on positions are a reusable substrate (frustum culling, particle neighbour lookups, instancing decisions). flux has none.
- **Likely missing from flux:** confirmed missing

### Computational Geometry (Triangulation / Voronoi / Marching) [scene] [visual]
- **Description:** Delaunay/Voronoi diagrams, marching-squares contour extraction from scalar fields, jump-flood distance fields.
- **Representative orx modules / openrndr APIs:** `orx-triangulation/` (Delaunay + Voronoi, ports of delaunator/d3-delaunay); `orx-marching-squares/` (contour extraction from functions); `orx-jumpflood/` ("Calculates distance or direction fields from an image. GPU accelerated, 2D"); `orx-integral-image/` (summed-area tables, CPU+GPU).
- **Why it matters:** Distance fields and Voronoi diagrams are heavy-lift reusable primitives in generative work; jump-flood specifically is a GPU compute pattern flux can host.
- **Likely missing from flux:** confirmed missing

### Math Primitives Beyond Vectors [authoring]
- **Description:** Complex numbers, linear/simplex ranges, RBF (radial basis functions), expression evaluators that parse string-typed math at runtime.
- **Representative orx modules / openrndr APIs:** `orx-math/` ("complex numbers, linear ranges, simplex ranges, matrices and radial basis functions (RBF)"); `orx-expression-evaluator/` (string math expressions); `orx-expression-evaluator-typed/` (typed variant); `openrndr-math/`.
- **Why it matters:** Expression evaluators bridge UI-string-typed parameters into the value graph — relevant for any text-driven authoring (timeline expressions, label-driven derived ports).
- **Likely missing from flux:** confirmed missing

### GUI / Parameter Introspection [authoring]
- **Description:** Annotation-driven auto-generated UI from typed object properties (sliders, color pickers, etc.).
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-gui/README.md` (`GUI` extension, `add(annotated)`); `orx-parameters/` (annotations consumed by gui); `orx-jvm/orx-panel/` (HTML/CSS-like widget toolkit underneath orx-gui); `orx-jvm/orx-rabbit-control/` (web variant).
- **Why it matters:** orx-gui is the strongest reusable example of "parameters as introspected metadata" — directly parallel to what flux's port-default UI needs to scale. orx-parameters is consumed by orx-fx filters so every filter gets a free UI.
- **Likely missing from flux:** partial (flux has port metadata; auto-UI generation is in flux-imgui scope but the pattern is worth studying)

### Live-Coding / Hot Reload [authoring]
- **Description:** Re-execute the running program on source-file save.
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-olive/` ("updates a running OPENRNDR program when you save your changes"); `orx-jvm/orx-file-watcher/` ("Monitor files on disk and auto-reload them if they change"); `orx-property-watchers/` (property-watch pipelines).
- **Why it matters:** flux has shader hot-reload (via LoadShaderOp + reload triggers per memory note 2026-05-19). orx file-watcher is a more general substrate; property-watchers is a "react when a port changes" pattern.
- **Likely missing from flux:** partial

### Inter-App Frame Sharing [authoring]
- **Description:** Send/receive live frames between native apps without copy/encode.
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-syphon/README.md` (Syphon for macOS).
- **Why it matters:** VJ/multi-app workflows. flux has no Syphon/Spout/NDI equivalent.
- **Likely missing from flux:** confirmed missing

### Optimization / Search (Gradient Descent) [authoring]
- **Description:** Numerical minimizer to fit parameters to a target output.
- **Representative orx modules / openrndr APIs:** `orx-gradient-descent/` ("easy to use gradient descent based minimizer").
- **Why it matters:** Niche but characteristic of a "computational creative-coding" library. flux is unlikely to need this in the Decima target envelope; included for completeness.
- **Likely missing from flux:** confirmed missing (low priority)

### Multi-View / View-Box [authoring] [scene]
- **Description:** Multiple independent viewports inside one window with their own draw lifecycle.
- **Representative orx modules / openrndr APIs:** `orx-view-box/` ("create independent views inside one program window"); `orx-image-fit/` (fit/cover rectangle layout); `orx-no-clear/` ("draw-without-clearing-the-screen").
- **Representative core APIs:** openrndr-draw `RenderTarget.kt`, `ResizableRenderTarget.kt`.
- **Why it matters:** Multi-view (split-screen, picture-in-picture, debug viewports, shadow-cascade outputs) is foundational once a single project authors more than one camera's worth of imagery.
- **Likely missing from flux:** confirmed missing

### Plotter / Physical Output [authoring]
- **Description:** Pen-plotter (AxiDraw) control directly from the same retained-shape model used for screen rendering.
- **Representative orx modules / openrndr APIs:** `orx-jvm/orx-axidraw/` ("GUI for configuring and plotting with an Axidraw pen-plotter").
- **Why it matters:** Out-of-scope for Decima target, but worth noting as evidence that the openrndr stack treats "physical output" as just-another-sink — a pattern flux might mirror for future printers/CNC/laser sinks.
- **Likely missing from flux:** confirmed missing (low priority)

## Notable patterns (not operators)

**The orx model itself.** Every `orx-*` module is a single, named, narrow capability with its own README and (often) demos folder. Browsing `libraries/openrndr-ecosystem/orx/` reads like a feature checklist. flux's "operator family" framing is one layer coarser, but the orx pattern of *one folder = one capability = one README with a runnable demo* is directly applicable to flux's operator-cluster organization and reduces "what does this framework do" to a single `ls`.

**`extend(...)` as effect attachment.** Many orx modules expose an `Extension` rather than a class to instantiate; the user attaches the extension to the running `Program` (`extend(Post())`, `extend(camera)`, `extend(controls)`, `extend(GUI())`). This is the openrndr equivalent of "wiring an operator into the graph" and is the closest pattern to *operator-as-installable-capability*. orx-compositor's `compose { layer { ... } }` (`orx-compositor/README.md`) is the same pattern in DSL form.

**`Filter` + `Post` for intermediate-buffer management.** `orx-fx/Post.kt` and openrndr-draw's `Filter.kt` together provide a pattern where post-effects are configured as parameter-bearing objects (`blur.window = 50; blur.sigma = 50.0; blur.apply(input, output)`), with `Post` extension automatically allocating/resizing intermediate buffers (`orx-fx/README.md` example: `blur.apply(input, intermediate[0]); add.apply(arrayOf(input, intermediate[0]), output)`). This is roughly what a flux post-stack operator family would look like if each filter were one operator with intermediate textures auto-managed by the runtime.

**Annotations-as-introspection (`orx-parameters` + `orx-gui`).** Filter classes are decorated with annotations consumed at runtime to generate sliders/color-pickers (`orx-gui/README.md`: "any annotated object" can be `add`ed). This is the same pattern as flux's operator-port metadata, and orx demonstrates that once every Filter has the annotations, every filter gets free UI without per-filter code. Worth studying as a model for flux's port-default-UI to scale to hundreds of operators.

**ShadeStyle as parametric shader fragment.** Rather than recompiling shaders per parameter change, `ShadeStyle` (`openrndr-draw/.../ShadeStyle.kt`, `ShadeStyleManager.kt`) holds a fragment-shader phrase with named uniforms exposed as `parameters["x"] = value`. orx-shade-styles ships ready-made phrases (gradients, clips). This is the "shader-as-value with parameter ports" pattern flux's GPU operators implicitly want.

**Composable noise via combinators.** `orx-noise` exposes noise primitives that are *function values*, then provides combinators (`.fbm(octaves=3)`, `.withPolarInput()`) that produce new noise functions (`orx-noise/README.md`). This is a pattern flux currently bakes into individual operators (3D Perlin is its own op, 2D Perlin is another) — orx demonstrates a more compositional version where the family is a small set of primitives × a small set of combinators.

**`orx-module-catalog`.** A live module catalog (`orx-module-catalog/`) that discovers other orx modules at runtime, complementing `openrndr-module-catalog`. Implementation of "registry-driven construction" at the *module* level, not just the operator level — analogous to flux's operator registry but applied to whole capability packages.

**Time as a domain, not a clock.** Multiple modules carve "time-bound behaviour" into distinct families: `orx-timer` (one-shot/repeat), `orx-time-operators` (Envelope, LFO), `orx-envelopes` (ADSR), `orx-fcurve` (1D curves with SVG-path syntax), `orx-interval-tree` (queries on time segments), `orx-property-watchers` (react-on-change). This suggests the "time" family in flux is probably *six* families, not one.

**Spatial query as a substrate (not an op).** orx exposes `orx-hash-grid`, `orx-kdtree`, `orx-quadtree`, `orx-interval-tree` as plain data structures, separate from any drawing/rendering. flux currently has no equivalent "operator that returns a spatial index value." Worth deciding whether spatial indices are values that flow through the graph or whether they're cached side-state on operators that need them.

## Sources cited

- `notes/per-framework/openrndr/README.md`
- `notes/per-framework/openrndr/architecture.md` (stub)
- `notes/per-framework/openrndr/api-design.md` (stub)
- `notes/per-framework/openrndr/rendering-pipeline.md` (stub)
- `notes/per-framework/openrndr/dependencies.md`
- `libraries/openrndr-ecosystem/orx/README.md` (the master family catalog)
- `libraries/openrndr-ecosystem/orx/orx-fx/README.md` (post-fx breakdown, sub-directory tree)
- `libraries/openrndr-ecosystem/orx/orx-fx/src/commonMain/kotlin/{antialias,blend,blur,color,colormap,composite,distort,dither,edges,grain,patterns,shadow,tonemap,transform}/`
- `libraries/openrndr-ecosystem/orx/orx-camera/README.md`
- `libraries/openrndr-ecosystem/orx/orx-mesh-generators/README.md`
- `libraries/openrndr-ecosystem/orx/orx-shapes/README.md`
- `libraries/openrndr-ecosystem/orx/orx-noise/README.md`
- `libraries/openrndr-ecosystem/orx/orx-shade-styles/README.md`
- `libraries/openrndr-ecosystem/orx/orx-compositor/README.md`
- `libraries/openrndr-ecosystem/orx/orx-color/README.md`
- `libraries/openrndr-ecosystem/orx/orx-easing/README.md`
- `libraries/openrndr-ecosystem/orx/orx-fcurve/README.md`
- `libraries/openrndr-ecosystem/orx/orx-fft/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jumpflood/README.md`
- `libraries/openrndr-ecosystem/orx/orx-hash-grid/README.md`
- `libraries/openrndr-ecosystem/orx/orx-kdtree/README.md`
- `libraries/openrndr-ecosystem/orx/orx-quadtree/README.md`
- `libraries/openrndr-ecosystem/orx/orx-triangulation/README.md`
- `libraries/openrndr-ecosystem/orx/orx-svg/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-dnk3/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-midi/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-osc/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-gui/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-keyframer/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-panel/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-olive/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-video-profiles/README.md`
- `libraries/openrndr-ecosystem/orx/orx-jvm/orx-syphon/README.md`
- `frameworks/openrndr/openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/` (Drawer, Filter, ShadeStyle, ColorBuffer, RenderTarget, ComputeShader, Cubemap, VolumeTexture, ShaderStorageBuffer, FontMap, …)
- `frameworks/openrndr/openrndr-shape/src/commonMain/kotlin/org/openrndr/shape/` (Shape, ShapeContour, Path, Segment2D/3D, Triangulator, Sphere, Box, Rectangle, Ellipse, Triangle)
