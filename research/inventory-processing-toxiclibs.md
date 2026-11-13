# Operator Family Inventory: Processing + toxiclibs

## Framework overview

Processing (`frameworks/processing/`) is the original creative-coding framework — a Java immediate-mode sketchbook centered on `PApplet`'s `setup()`/`draw()` lifecycle and the `PGraphics` rendering abstraction (renderers `JAVA2D`, `P2D`, `P3D`, `PDF`, `SVG`). Its built-in module set (`java/libraries/{dxf,io,net,pdf,serial,svg}`) is intentionally thin and weighted toward I/O and 2D vector export; the family-rich inventory lives in companion libraries. toxiclibs (`libraries/processing-ecosystem/toxiclibs/`, Karsten Schmidt) is the seminal Processing companion — it ships split top-level packages (`src.core/toxi/{geom,math}`, `src.color`, `src.volume`, `src.physics`, `src.sim`, `src.audio`, `src.image`, `src.data`, `src.net`, `src.newmesh`) that together form the deepest publicly-readable inventory of *computational design* primitives: winged-edge meshes, mesh subdivision strategies, marching-cubes iso-surfaces, Verlet particle physics, parametric surface builders, color theory schemes, reaction-diffusion / fluid / CA simulators. Taken as one inventory, Processing+toxiclibs is the strongest reference for procedural-geometry and physics-style families that Tooll3/cables/orx tend to under-call: parametric surfaces, mesh subdivision, voxel/iso-surface, color-harmony generation, and Verlet soft-body chains.

## Families

### Mesh Modify — Subdivision & Smoothing [scene] [visual] [authoring]
- **Description:** Take a triangle/winged-edge mesh and refine it via subdivision schemes or relaxation, producing higher-density and smoother meshes downstream of primitives or loaded geometry.
- **Representative APIs:** `WETriangleMesh.subdivide(SubdivisionStrategy)` with strategies `MidpointSubdivision`, `MidpointDisplacementSubdivision`, `DualSubdivision`, `DualDisplacementSubdivision`, `NormalDisplacementSubdivision`, `CentroidSubdiv`, `TriSubdivision` (`toxiclibs/src.core/toxi/geom/mesh/subdiv/`); `LaplacianSmooth` (`toxiclibs/src.core/toxi/geom/mesh/LaplacianSmooth.java`); `WingedEdge` / `WEFace` / `WEVertex` topology (`toxiclibs/src.core/toxi/geom/mesh/WingedEdge.java`).
- **Why it matters:** A winged-edge mesh + pluggable subdivision-strategy interface is exactly the operator-graph pattern: pipe a low-poly mesh through a chain of subdivide/smooth/displace operators. Visual-programming tools that only expose mesh primitives ("box", "sphere") collapse on any organic / sculpted form. Catmull-Clark-style refinement is a distinct family from "make me a denser sphere."
- **Likely missing from flux:** confirmed missing

### Mesh Modify — Volumetric / Iso-Surface [scene] [visual]
- **Description:** Build a scalar field on a regular or hashed 3D grid, deposit shapes with additive/multiplicative "brushes," then extract a triangle mesh via marching cubes. The canonical pipeline for metaball / SDF-blend / voxel-sculpt geometry.
- **Representative APIs:** `VolumetricSpace` / `VolumetricSpaceArray` / `VolumetricHashMap` (`toxiclibs/src.volume/toxi/volume/`); brushes `RoundBrush`, `BoxBrush`, `PeakBrush` with modes `AdditiveBrush`, `MultiplyBrush`, `ReplaceBrush`; extraction `IsoSurface` / `ArrayIsoSurface` / `HashIsoSurface` (marching cubes); `MeshVoxelizer`, `MeshLatticeBuilder`, `MarchingCubesIndex`.
- **Why it matters:** Volumetric → iso-surface is the single most "AAA-feeling-from-pure-data" pipeline in toxiclibs; .kkrieger-style organic forms, blob characters, melting / fusing geometry, and SDF-style modeling all flow through this. Tooll3 / cables / orx ship volumetric textures but not this CPU-side volumetric→mesh extraction with paintable brushes. Note: this is a strong candidate for a *GPU* family rather than a 1:1 CPU port.
- **Likely missing from flux:** confirmed missing

### Parametric Surfaces & NURBS [scene] [visual] [authoring]
- **Description:** Generate meshes from analytic surface functions or NURBS control-net inputs — superellipsoids, spherical harmonics, swept-profile surfaces, parametric U/V evaluators.
- **Representative APIs:** `SurfaceMeshBuilder(SurfaceFunction)` + concrete functions `SphereFunction`, `SuperEllipsoid`, `SphericalHarmonics` (`toxiclibs/src.core/toxi/geom/mesh/SurfaceMeshBuilder.java`); `BezierPatch`; full NURBS package `BasicNurbsCurve`, `BasicNurbsSurface`, `NurbsCreator`, `NurbsMeshCreator`, `KnotVector`, `ControlNet`, `CurveCreator` (`toxiclibs/src.core/toxi/geom/nurbs/`); `Terrain` (heightfield mesh).
- **Why it matters:** Spherical-harmonics / super-formula / NURBS surfaces drive an enormous slice of demoscene & generative-art output (and `SurfaceMeshBuilder(SurfaceFunction)` is *literally* the function-pointer-into-mesh-operator pattern flux already uses). Heightfield → terrain mesh is the standard procedural-landscape entry point. Tooll3 has parametric primitives but not pluggable `SurfaceFunction` interfaces.
- **Likely missing from flux:** confirmed missing

### Mesh Modify — Sweep / Extrude / Loft [scene] [visual]
- **Description:** Take a 2D profile (polygon, polyline, Bezier curve) and sweep/extrude/loft it along a path to produce a 3D mesh — ribbons, pipes, tubes, lathe-of-revolution surfaces.
- **Representative APIs:** `Polygon2D.extrude` (path in `toxiclibs/src.core/toxi/geom/Polygon2D.java`); `NurbsCreator.createExtrusion(...)` & `createRevolution(...)` (`toxiclibs/src.core/toxi/geom/nurbs/NurbsCreator.java`); profile types `Spline2D`/`Spline3D`, `BezierCurve2D`/`BezierCurve3D`, `LineStrip2D`/`LineStrip3D`; `PolygonTesselator`, `GridTesselator`.
- **Why it matters:** Extrude/sweep/lathe is the *most-asked-for missing operator* in any node-graph 3D tool that ships only volumetric primitives — there's no other way to author cables, pipes, fences, rails, hair strands, fabric folds, or any cross-section-along-a-curve geometry in pure data. Distinct from "Mesh Modify — Subdivision" because input is a curve/profile, not a mesh.
- **Likely missing from flux:** confirmed missing

### Mesh I/O — Format Readers/Writers [authoring]
- **Description:** Read and write meshes from common interchange formats so authored geometry can round-trip with external DCC tools.
- **Representative APIs:** `STLReader`, `STLWriter`, `MaterialiseSTLColorModel`, `DefaultSTLColorModel` (`toxiclibs/src.core/toxi/geom/mesh/`); `OBJWriter`; `PLYWriter`; Processing's `PShapeOBJ`, `PShapeSVG` (`frameworks/processing/core/src/processing/core/`); `RawDXF` (`frameworks/processing/java/libraries/dxf/`).
- **Why it matters:** Loaded glTF/OBJ meshes is already on flux's known-deferred list; this calls out that STL/PLY/DXF (3D-print + CAD) are *separately interesting* for fabrication/installation work, and OBJ-write/STL-write is the export side that visual tools routinely punt on.
- **Likely missing from flux:** confirmed missing

### Curves & Splines (1D primitives) [visual] [authoring]
- **Description:** Author and evaluate 2D/3D Bezier, B-spline, Catmull-Rom curves as first-class operators — distinct from "animation curves," these are *geometric* curves consumed by sweep/extrude/path-follow.
- **Representative APIs:** `BezierCurve2D`, `BezierCurve3D`, `BernsteinPolynomial`, `Spline2D`, `Spline3D` (`toxiclibs/src.core/toxi/geom/`); `LineStrip2D`, `LineStrip3D`; `NurbsCurve` / `BasicNurbsCurve` (`toxiclibs/src.core/toxi/geom/nurbs/`); Processing `PApplet.bezier()`, `bezierPoint()`, `curve()` API.
- **Why it matters:** Without a Curve type and ops that produce/consume it, every path-follow / camera-rail / instance-along-spline / motion-graphic-stroke task gets re-implemented as bespoke math. Curve-as-value is the central missing port type behind sweep, lathe, instance-along, particle-paths.
- **Likely missing from flux:** confirmed missing

### Verlet Particle Physics [scene] [visual] [authoring]
- **Description:** Position-based / Verlet integrator with particles, springs, constraints, behaviors — soft-body chains, cloth, rope, hair, jiggle, attractor fields. Distinct from rigid-body physics.
- **Representative APIs:** `VerletPhysics2D`, `VerletPhysics3D`, `VerletParticle2D/3D`, `VerletSpring2D/3D`, `VerletMinDistanceSpring2D/3D`, `VerletConstrainedSpring2D/3D`, `PullBackSpring2D/3D`, `ParticleString2D/3D`, `ParticlePath2D/3D` (`toxiclibs/src.physics/`); behaviors `AttractionBehavior2D/3D`, `GravityBehavior2D/3D`, `ConstantForceBehavior2D/3D`; constraints `AxisConstraint`, `CircularConstraint`, `RectConstraint`, `PolygonConstraint`, `AngularConstraint`, `SphereConstraint`, `BoxConstraint`, `SoftBoxConstraint`, `CylinderConstraint`, `PlaneConstraint`.
- **Why it matters:** Verlet is the *standard* creative-coding physics flavor — cheap, stable, and matches the operator-graph mental model (particle pool + accumulating force operators + constraint operators). The brief explicitly flags this family as deep in toxiclibs; it covers cloth, hair-card, rope, dangling chains, dynamic UI motion, and signature "Death Stranding cargo wobble"-style secondary motion. Distinct from a rigid-body engine (Bullet/PhysX) — and worth shipping *before* rigid-body because it's far cheaper and covers more creative-coding use cases.
- **Likely missing from flux:** confirmed missing

### Spatial Indexing [scene] [authoring]
- **Description:** Octrees, quadtrees, spatial-bin hashes for nearest-neighbour queries, broad-phase collision, particle-particle interaction, instance culling.
- **Representative APIs:** `PointOctree`, `PointQuadtree`, `OctreeVisitor`, `QuadtreeVisitor`, `SpatialBins`, `SpatialIndex` (`toxiclibs/src.core/toxi/geom/`); `IndexedTriangleMesh`, `SpatialIndex` in `src.newmesh`.
- **Why it matters:** At Decima scale (thousands of instances, particles, lights) every "find neighbours within radius" or "is this visible from here" query needs spatial acceleration. Visual-programming tools almost never expose spatial indices *as operators* — they hide them inside renderers. Exposing them lets users build their own boid systems, proximity-trigger fields, density visualizations, etc.
- **Likely missing from flux:** confirmed missing

### Intersection & Containment [scene] [authoring]
- **Description:** Ray/AABB/sphere/plane/triangle/cylinder intersection, point-in-polygon, polygon clipping (Boolean ops), reflection — primitive geometric predicates used for picking, raycasts, mouse-over, CSG-lite, collision response.
- **Representative APIs:** `Ray3D`, `Ray3DIntersector`, `TriangleIntersector`, `SphereIntersectorReflector`, `BoxIntersector`, `PlaneIntersector`, `CircleIntersector`, `Reflector3D`, `Intersector2D`/`Intersector3D`, `IsectData2D`/`IsectData3D` (`toxiclibs/src.core/toxi/geom/`); `BooleanShapeBuilder`, `SutherlandHodgemanClipper`, `ConvexPolygonClipper`, `PolygonClipper2D`; `MeshIntersector` (`toxiclibs/src.core/toxi/geom/mesh/`).
- **Why it matters:** Picking is the smallest example; the bigger one is *authoring* interactivity in pure data — "ray from camera hits this mesh → trigger that" needs intersector operators with typed `Ray3D` and `IsectData3D` outputs. Boolean polygon clipping is the standard for 2D-overlay UI and motion-graphic compositing.
- **Likely missing from flux:** confirmed missing

### 2D Computational Geometry [visual] [authoring]
- **Description:** Delaunay triangulation, Voronoi diagrams, convex/concave hull, tessellation — the foundation of "scatter points → get faces / regions" generative workflows.
- **Representative APIs:** `Voronoi`, `DelaunayTriangulation`, `DelaunayTriangle`, `DelaunayVertex` (`toxiclibs/src.core/toxi/geom/mesh2d/`); `GridTesselator`, `GlobalGridTesselator`, `LocalGridTesselator`, `PolygonTesselator`; `Polygon2D`, `Shape2D`, `Rect`, `Ellipse`, `Circle`, `Triangle2D`.
- **Why it matters:** Voronoi+Delaunay is the workhorse of biological / cellular / crystalline generative imagery; it's also the standard generator for procedural city/road layouts, crack patterns, low-poly stylization, and dual-mesh construction. Tooll3 / cables don't ship this as a first-class operator family; orx does (via JTS bindings) which signals real demand.
- **Likely missing from flux:** confirmed missing

### Color — Theory & Palette Generation [visual] [authoring]
- **Description:** Color-theory schemes (complementary, triadic, analogous, split-complementary, tetrad, monochrome, compound) that generate harmonic palettes from a seed color, plus named-color libraries, palette histograms, tone mapping, and palette-distance queries.
- **Representative APIs:** `ColorTheoryRegistry` with strategies `ComplementaryStrategy`, `TriadTheoryStrategy`, `AnalogousStrategy`, `SplitComplementaryStrategy`, `LeftSplitComplementaryStrategy`, `RightSplitComplementaryStrategy`, `TetradTheoryStrategy`, `MonochromeTheoryStrategy`, `CompoundTheoryStrategy`, `SingleComplementStrategy` (`toxiclibs/src.color/toxi/color/theory/`); `TColor`, `ColorList`, `ColorRange`, `ColorTheme`, `ColorGradient`, `NamedColor`, `Histogram`, `ToneMap`; accessors `RGBAccessor`, `HSVAccessor`, `CMYKAccessor`, `LuminanceAccessor`, `AlphaAccessor`, distance proxies `RGBDistanceProxy`/`HSVDistanceProxy`/`CMYKDistanceProxy`.
- **Why it matters:** Flux has color animation (TypedCurve over Color) but no *palette-generation* operators. A "give me 5 analogous colors of saturation 0.6" operator turns into infinite design-time leverage at scale (thousands of instances colored by procedural palette). This is uniquely deep in toxiclibs and uniquely missing from every node-paradigm reference I've seen.
- **Likely missing from flux:** confirmed missing

### Noise & Wave Sources [authoring]
- **Description:** Beyond `random()` / `noise()`: oscillators with phase, frequency modulation, amplitude modulation; 2D noise; deterministic seeded streams; interpolation strategies as first-class function-pointer values.
- **Representative APIs:** `PerlinNoise`, `SimplexNoise` (`toxiclibs/src.core/toxi/math/noise/`); `SineWave`, `FMSineWave`, `AMFMSineWave`, `FMSquareWave`, `FMTriangleWave`, `FMSawtoothWave`, `FMHarmonicSquareWave`, `ConstantWave`, `AbstractWave`, `WaveState`, `Wave2D` (`toxiclibs/src.core/toxi/math/waves/`); interpolation strategies `LinearInterpolation`, `CosineInterpolation`, `BezierInterpolation`, `CircularInterpolation`, `SigmoidInterpolation`, `ExponentialInterpolation`, `ZoomLensInterpolation`, `ThresholdInterpolation`, `DecimatedInterpolation` implementing `InterpolateStrategy`; `ScaleMap`, `NonLinearScaleMap`, `SinCosLUT`; Processing `PApplet.noise()` / `noiseDetail()` / `random()` / `randomGaussian()`.
- **Why it matters:** Flux has SineWave + Perlin; toxiclibs shows the *family* extends to FM/AM oscillators (one of the cheapest ways to get "interesting" animation), and to pluggable interpolation strategies as a port-level value — `Lerp(a, b, t, strategy)` where strategy is a value, not a hardcoded shape. That pattern lets one Lerp operator replace ten.
- **Likely missing from flux:** partial (have noise + sine; missing FM/AM oscillator family and the *interpolation-strategy-as-value* pattern)

### Range & Distribution Sources [authoring]
- **Description:** Typed numeric ranges with sampling — uniform, biased, weighted-random — as first-class operators producing scalar streams. Bridges "constant" and "noise" with controllable shape.
- **Representative APIs:** `FloatRange`, `IntegerRange`, `DoubleRange`, `BiasedFloatRange`, `BiasedIntegerRange`, `BiasedDoubleRange`, `WeightedRandomSet`, `WeightedRandomEntry`, `IntegerSet`, `GenericSet` (`toxiclibs/src.core/toxi/util/datatypes/`).
- **Why it matters:** "Pick a random scale per instance, weighted toward the small end, biased above 0.3" is the kind of authoring micro-task that needs one operator with port inputs, not bespoke math per use. At 1000-op scale, having a *vocabulary* of distribution-shape operators is what keeps procedural content from being rebuilt every time.
- **Likely missing from flux:** confirmed missing

### Cellular Automata & Reaction-Diffusion [visual] [authoring]
- **Description:** Grid-based simulation kernels: Wolfram 1D CA, 2D CA, Gray-Scott reaction-diffusion, diffusion-limited aggregation, thermal/talus-angle erosion — all producing animated 2D textures or scalar fields consumable downstream.
- **Representative APIs:** `CARule`, `CARule2D`, `CAWolfram1D`, `CAMatrix`, `EvolvableMatrix`, `MatrixEvolver` (`toxiclibs/src.sim/toxi/sim/automata/`); `GrayScott` (`toxiclibs/src.sim/toxi/sim/grayscott/`); `DLA`, `DLAParticle`, `DLASegment`, `DLAGuideLines`, `DLAConfiguration` (`toxiclibs/src.sim/toxi/sim/dla/`); `ThermalErosion`, `TalusAngleErosion`, `ErosionFunction` (`toxiclibs/src.sim/toxi/sim/erosion/`).
- **Why it matters:** Reaction-diffusion / CA / DLA produce *signature* organic patterns — fingerprints, coral, leaf veins, lichen, blood vessels — that no node-paradigm reference I've seen ships as first-class operators (orx has a few, Tooll3 doesn't). Erosion specifically (`ThermalErosion`, `TalusAngleErosion`) is the standard procedural-terrain weathering pass; at Decima scale, terrain authoring without erosion is a non-starter. These are natural compute-shader ports.
- **Likely missing from flux:** confirmed missing

### Fluid Simulation [visual]
- **Description:** Stam-style stable-fluids solvers in 2D and 3D producing velocity/density fields.
- **Representative APIs:** `FluidSolver2D`, `FluidSolver3D` (`toxiclibs/src.sim/toxi/sim/fluids/`).
- **Why it matters:** Smoke/ink/fluid is a distinct family from particle physics (Eulerian grid, not Lagrangian particles). One operator per solver + density-field-as-texture-output gives a complete "smoke/ink" workflow at flux's GPU-pipeline layer. Worth calling out separately because creative-coding refs habitually under-call fluid solvers (cables/tixl don't ship them; Houdini does, which is its main differentiator).
- **Likely missing from flux:** confirmed missing

### Interactive / Hardware I/O [authoring]
- **Description:** Real-world input/output — serial (Arduino), GPIO/I2C/SPI/PWM (Raspberry Pi), UDP/TCP networking, RSS/Atom feed parsing, CSV ingest.
- **Representative APIs:** Processing `serial/Serial.java`; `io/GPIO.java`, `io/I2C.java`, `io/SPI.java`, `io/PWM.java`, `io/LED.java`, `io/SoftwareServo.java`; `net/Client.java`, `net/Server.java` (`frameworks/processing/java/libraries/`); toxiclibs `src.net/com/toxi/net/UDPClient`, `UDPServer`, `UDPSyncClient`, `UDPSyncServer`; `src.data/toxi/data/csv/CSVParser`, `src.data/toxi/data/feeds/{RSSFeed,AtomFeed}`.
- **Why it matters:** Flux is currently zero-input (no mouse, no MIDI, no audio, no network). Processing's I/O library set is the standard "installation/physical-computing" inventory: serial + GPIO + UDP + CSV covers the bulk of museum/exhibition/data-driven art. Network in particular maps cleanly to operator-graph (one Server-as-source operator producing typed packet streams).
- **Likely missing from flux:** confirmed missing

### Vector-Graphics Export [visual] [authoring]
- **Description:** Capture a render frame as resolution-independent vector output for print/laser/plotter/film-pipeline downstream — PDF, SVG, DXF.
- **Representative APIs:** `processing.pdf.PGraphicsPDF` (`frameworks/processing/java/libraries/pdf/src/processing/pdf/`); `processing.svg.PGraphicsSVG`, `WriteSVG`, `GradientExtensionHandler` (`frameworks/processing/java/libraries/svg/src/`); `processing.dxf.RawDXF` (`frameworks/processing/java/libraries/dxf/src/`).
- **Why it matters:** A vector-export sink as an operator (alongside flux's existing `SaveImageOp`) gives motion-graphic / generative-print / fabrication workflows the export path they need. Distinct from raster image saving because it requires capturing the *call sequence*, not the framebuffer. PGraphicsPDF/SVG are implemented as renderers (`PGraphics` subclasses), which is the conceptual model for "Record region into vector buffer."
- **Likely missing from flux:** confirmed missing

## Notable patterns (not operators)

- **`setup()` / `draw()` lifecycle (Processing).** `PApplet.setup()` runs once, `PApplet.draw()` once per frame — flux's `Operator::preload()` vs per-frame eval mirrors this exactly. Worth naming the analogy when documenting flux's two-phase model.
- **`PGraphics` as renderer-as-value (Processing).** Any sketch can `createGraphics(...)` an off-screen `PGraphics`, render into it, and use it as a texture downstream. The single most-copied pattern in Processing tutorials; flux's render-to-texture region is the same concept.
- **`SurfaceFunction` / `InterpolateStrategy` / `SubdivisionStrategy` (toxiclibs).** A *function-pointer* interface is passed *into* a builder/operator, which then drives the data flow. Maps cleanly to flux's "operator parameter typed as a Curve / Function value." `SurfaceMeshBuilder(SurfaceFunction)` and `WETriangleMesh.subdivide(SubdivisionStrategy)` and `Lerp(a, b, t, InterpolateStrategy)` are all the same pattern.
- **Brush + accumulator (toxiclibs `VolumetricSpace`).** Mutable accumulator (volumetric field) + composable brushes (`AdditiveBrush`, `MultiplyBrush`, `PeakBrush`, `ReplaceBrush`) that *paint* into it. Maps directly to flux's `Region::Accumulate`. Worth re-checking whether flux's accumulator can accept arbitrary brush operators or only the built-in blend modes.
- **Builder-style mesh construction (toxiclibs).** `WETriangleMesh()` then `.addFace(...)` / `.subdivide(...)` / `.faceOutwards()` / `.computeVertexNormals()` builds a mesh through a chain of mutation calls — the operator-chain pattern in object form. Naturally maps to a per-step operator with mesh in / mesh out.
- **Immutable read-only vector types (`ReadonlyVec3D` / `ReadonlyVec2D` / `ReadonlyVec4D` / `ReadonlyTColor`).** toxiclibs distinguishes mutable vs read-only at the type level — the equivalent of Rust's `&Vec3` vs `&mut Vec3` borrow distinction. Validates flux's design choice to have typed-value ports flowing between operators rather than shared mutable state.
- **Winged-edge topology (`WingedEdge`, `WEFace`, `WEVertex`, `WETriangleMesh`).** Edge-centric mesh data structure enables face-adjacency queries that flat index buffers can't. Required for most mesh-modify algorithms (subdivision, smoothing, decimation). Worth flagging that *which mesh data structure flux's port type uses* will determine which downstream operators are even possible.
- **Color accessor pattern.** `RGBAccessor` / `HSVAccessor` / `CMYKAccessor` / `LuminanceAccessor` / `AlphaAccessor` give a *uniform* way to read one channel from a color regardless of space — the operator-graph equivalent is `GetChannel(color, ChannelSelector)`. Better than separate `GetRed`/`GetHue`/`GetCyan` operators at scale.
- **Pluggable distance proxy.** `ProximityComparator(target, DistanceProxy)` — distance metric is itself a port-level value. Same shape as `InterpolateStrategy`; powers nearest-color/nearest-neighbour queries with user-selectable metric.
- **Operator-as-strategy registry (`ColorTheoryRegistry`, `SubdivisionStrategy` lookup).** toxiclibs registers strategies by name string so user code can pick "complementary" at runtime. Maps to flux's registry-driven construction pattern.

## Sources cited

- `frameworks/processing/core/src/processing/core/` — PApplet, PGraphics, PVector, PMatrix, PShape, PShapeOBJ, PShapeSVG
- `frameworks/processing/core/src/processing/opengl/` — PGraphicsOpenGL, PShader, FrameBuffer, Texture
- `frameworks/processing/java/libraries/{dxf,io,net,pdf,serial,svg}/src/` — built-in Processing libraries
- `libraries/processing-ecosystem/toxiclibs/src.core/toxi/geom/` — vectors, matrices, intersectors, spatial indices, polygon clipping, splines
- `libraries/processing-ecosystem/toxiclibs/src.core/toxi/geom/mesh/` — TriangleMesh, WingedEdge, SurfaceMeshBuilder, LaplacianSmooth, STL/OBJ/PLY writers, SphericalHarmonics, Terrain
- `libraries/processing-ecosystem/toxiclibs/src.core/toxi/geom/mesh/subdiv/` — SubdivisionStrategy family
- `libraries/processing-ecosystem/toxiclibs/src.core/toxi/geom/mesh2d/` — Voronoi, DelaunayTriangulation
- `libraries/processing-ecosystem/toxiclibs/src.core/toxi/geom/nurbs/` — NURBS curves & surfaces
- `libraries/processing-ecosystem/toxiclibs/src.core/toxi/math/{noise,waves,conversion}/` + interpolation strategies — noise, FM/AM waves, InterpolateStrategy
- `libraries/processing-ecosystem/toxiclibs/src.core/toxi/util/datatypes/` — ranges, weighted random
- `libraries/processing-ecosystem/toxiclibs/src.color/toxi/color/` + `src.color/toxi/color/theory/` — TColor, palette/theory strategies
- `libraries/processing-ecosystem/toxiclibs/src.volume/toxi/volume/` — VolumetricSpace, brushes, IsoSurface, MarchingCubes, MeshVoxelizer
- `libraries/processing-ecosystem/toxiclibs/src.physics/toxi/{physics2d,physics3d}/` + `behaviors/` + `constraints/` — Verlet physics
- `libraries/processing-ecosystem/toxiclibs/src.sim/toxi/sim/{automata,grayscott,dla,erosion,fluids}/` — CA, Gray-Scott, DLA, erosion, Stam fluid
- `libraries/processing-ecosystem/toxiclibs/src.{audio,data,net,newmesh,image}/` — audio, CSV/RSS/Atom, UDP, indexed mesh, tiled exporter
- `notes/per-framework/processing/README.md` — existing repo notes (stubs)
