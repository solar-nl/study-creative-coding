# Operator Family Inventory: Werkkzeug / fr_public

## Framework overview

Werkkzeug is Farbrausch's family of demoscene content-creation tools (2001-2011), where everything in a project — geometry, textures, materials, scenes, particles, fonts, even cubemaps and signed-distance fields — is authored as a node graph and generated procedurally at runtime. Three generations survive in `fr_public/`: a class-method-based **Werkkzeug3** (`werkkzeug3/`, `werkkzeug3_kkrieger/`), used to ship `.kkrieger` (a 96 KB FPS), `.debris`, `.theta`, and the bulk of Farbrausch's intro catalogue; and **Werkkzeug4** (`altona_wz4/wz4/`), the most mature and best-organized version. Wz4 uses a custom `.ops` IDL (e.g. `altona_wz4/wz4/wz4frlib/wz4_mesh_ops.ops`) that declaratively defines types, operators, their typed inputs (with `?` optional, `*` variadic, `?*` zero-or-more), parameter blocks (with `anim` markers on each animatable scalar), GUI hints (column/shortcut/customed editor), and an inline `code { ... }` C++ body — a remarkably clean format for what is otherwise a 15 000+ line operator catalogue. The 31 `.ops` files in `wz4frlib/` total roughly 15 600 lines and constitute the most complete inventory of "what a procedural-everything demoscene tool needs to ship a 64K/96K production." `werkkzeug3_kkrieger/genmesh.cpp` (5 557 lines) is the kkrieger-era mesh op library written as a single GenMesh class with one method per op; the topology is the same as wz4 but the code-organisation is not.

## Families

### Mesh primitives + procedural generators [scene] [visual]
- **Description:** Parametric-mesh sources — boxes, spheres, tori, grids, discs, cylinders, plus higher-level generators (text-as-3D, path-as-3D, font-glyph extrusion).
- **Representative ops:** `Cube`, `Sphere`, `Torus`, `Grid`, `Disc`, `Cylinder`, `Text3D`, `Path3D`, `Import` (`altona_wz4/wz4/wz4frlib/wz4_mesh_ops.ops` lines 11-20). ChaosMesh duplicates of `cube`/`sphere`/`grid`/`torus` exist in `chaosmesh_ops.ops` for the rigged-mesh pipeline.
- **Why it matters:** Already largely in flux. The interesting Werkkzeug additions over flux's current 7-primitive set are `Text3D` (extruded font glyphs → meshes — the way every Farbrausch demo gets its titles without shipping vector fonts as assets) and `Path3D` (spline-to-extruded-mesh).
- **Likely missing from flux:** partial — flux has Box/Sphere/Plane/Cylinder/Torus/Capsule/InvertedBox, missing Disc/Grid (tessellated plane), `Text3D`, `Path3D`.

### Mesh edit / modify stack [scene] [authoring]
- **Description:** Per-vertex / per-face / per-edge mesh modifiers that take a `Wz4Mesh` and return a `Wz4Mesh`, designed to compose into long chains. **This is the largest single family in Wz4.**
- **Representative ops:** `Subdivide`, `Extrude`, `ExtrudeNormal`, `Bend`, `Bevel`, `Facette`, `Crease`/`UnCrease`, `Displace` (driven by a `BitmapBase`), `Noise`, `Randomize`, `Normalize`, `Invert`, `Triangulate`, `DeleteFace`, `Mirror`, `Center`, `Splitter`, `Dual`, `Heal`, `Deform`, `Chunks`/`RandomizeChunks`, `Select`/`SelectGrow`, `SplitAlongPlane`, `TransformNonLinear`, `TransformRange`, `BakeAnim` (`altona_wz4/wz4/wz4frlib/wz4_mesh_ops.ops` lines 12-49). ~35 modifiers in total.
- **Why it matters:** This is the single biggest enabler of the procedural-everything pattern. The only realistic way to author non-primitive geometry without DCC assets is a long modifier stack on top of a parametric primitive (`Cube → Subdivide → Bend → ExtrudeNormal → Displace(Perlin) → Bevel`). `.kkrieger` levels, debris geometry, and most fr_public intro geometry are built this way. No modifier stack ⇒ no `.kkrieger`. Note the `Displace(Wz4Mesh, BitmapBase)` op specifically — mesh modify can read from any bitmap-typed input including procedurally-generated noise.
- **Likely missing from flux:** confirmed missing (entire family).

### Selection / mask region [scene] [authoring]
- **Description:** Operators that mark a sub-region of a mesh (vertices/edges/faces) for subsequent modifier ops to act on. Almost every modify op respects a selection mask.
- **Representative ops:** `Select(Wz4Mesh,?GenBitmap)`, `SelectGrow`, `SelectCube` (`wz4_mesh_ops.ops` lines 34-44, `chaosmesh_ops.ops`). The `?GenBitmap` input means a selection can be painted by a procedural texture.
- **Why it matters:** Without selection masks, the modifier stack is monolithic — every Subdivide applies to the whole mesh. Selection turns the modifier stack into a region-targeted modeling language, which is the difference between "interesting blob" and "kkrieger corridor with detailed window frames."
- **Likely missing from flux:** confirmed missing.

### Mesh instancing / iteration [scene] [authoring]
- **Description:** Take a mesh (or any render-tree node) and replicate it N times along an animatable transform delta, optionally with per-instance variation. The Werkkzeug analogue of foreach/spread.
- **Representative ops:** `Wz4Mesh MultiplyNew` (mesh-level: 1..1024 instances baked into one mesh, with Pre-Transform and per-step Scale/Rot/Trans, `wz4_mesh_ops.ops` line 1059), `Wz4Render Multiply` (render-tree-level, same delta-transform pattern but at draw-time, `wz4_demo2_ops.ops` line 604), `MultiplyMesh` (`wz4_demo2_ops.ops` line 17). Also `Wz4Render Sprites` / `Chunks` / `Debris` for particle-to-instance flows.
- **Why it matters:** **This is how Werkkzeug ships AAA scene scale from a tiny graph.** One Multiply node with Count=512 expresses 512 draw calls or 512 baked mesh copies. Every fr_public city scene, fence row, debris cloud, fr-033 forest, and fr-041 architectural backdrop runs through this op. The whole "procedural-everything" claim of demoscene tools rests heavily on this family.
- **Likely missing from flux:** confirmed missing — flux has `Region::Loop` (the building block) but no front-line instancing operator.

### Transform / scene-graph node [scene] [authoring]
- **Description:** Transform nodes in the render tree that apply a Scale/Rot/Trans (with per-channel `anim` keyframing) to all child render nodes. Animatable matrix authoring as data.
- **Representative ops:** `Transform`, `TransformPivot`, `TransformEx`, `TransformMatrix`, `TransformRange`, `TransformNonLinear`, `SplinedObject`, `LookAt` (`wz4_demo2_ops.ops` lines 421-512 and across `wz4_mesh_ops.ops`).
- **Why it matters:** This is the family flux's "rotating triangle" exercise surfaced as a missing piece. Werkkzeug has it at both levels — bake transforms into the mesh, *and* attach a transform node to the render tree. `SplinedObject` ties a transform to a path spline.
- **Likely missing from flux:** confirmed missing.

### Bitmap / texture generator + filter stack [visual] [authoring]
- **Description:** Procedural-texture sources (Flat/Perlin/Cell/Gradient/Bricks/Dots/Text) and filter chains (Color/HSCB/ColorBalance/Blur/Sharpen/Distort/Twirl/Bulge/Bump/Light/Normals/Mask/Merge/Atlas/Bitcrusher).
- **Representative ops:** `wz3_bitmap_ops.ops` (1421 lines, 37 ops, lines 1-37 listed earlier). `Wz4Cubemap Noise/Combine/Glow/HSCB/Gamma/Rotate` (`wz4_cubemap_ops.ops`) carries the same pattern into cubemaps.
- **Why it matters:** The other half of the procedural-everything story. `.kkrieger` ships **zero** baked texture files — every wall, floor, character skin is a Perlin + Cell + filters + lighting graph. This family is what made 96 KB possible.
- **Likely missing from flux:** confirmed missing — flux has LoadTextureOp + Perlin (3D noise primitive only), no filter operators.

### Material assembly (modular shader graph) [visual] [authoring]
- **Description:** A *sub-graph language* for materials. Material = `ModMaterial(ModShader*)` where each `ModShader` is a node (Lambert/Phong/BlinnPhong/Rim/Tint/Comic/NormalMap/Emissive/Specular/Diffuse/Gloss/Alpha/Kill/Displace/ExtrudeNormal/ShadowGrab/SphereFog) and `ModShaderSampler` are texture/value sources (Tex2D/Tex2DAnim/Tex2DSurround/Const/TrickLight/Mul/Add/Sub).
- **Representative ops:** `wz4_modmtrlmod_ops.ops` (~35 modular shader nodes), `wz4_modmtrl_ops.ops` (the assembly + `ModLight`/`ModLightEnv`). Older simpler material families: `wz4_mtrl_ops.ops` (single `Material(?Texture2D x6)`), `wz4_mtrl2_ops.ops` (`SimpleMaterial`, `CustomMaterial2`).
- **Why it matters:** Material is itself an op-graph in Werkkzeug. Authoring 50 distinct materials at 1000-op scale only works if materials are themselves nodal — and the modular-shader system is the precedent. Note also `BakedShadow`/`ShadowGrab` as material *inputs* (not separate light-baking passes).
- **Likely missing from flux:** confirmed missing.

### Render-tree composition (the scene DAG) [scene] [authoring]
- **Description:** A separate type `Wz4Render` representing a tree of render commands. Render nodes wrap meshes, transforms, cameras, render targets, conditional clips, faders, splines. Children get rendered relative to parents in a recursive walk. **The `Wz4Render` type is the entire scene-graph abstraction.**
- **Representative ops:** `Render` ("Add"), `RenderNull`, `Camera(?Rendertarget2D,?*Wz4Render)`, `BillboardCamera`, `RenderMesh`, `Layer2D`, `SkyCube`, `Variable` (named constants), `Spline` (named curves), `Beat`, `Shaker`, `BoneTrain` (`wz4_demo2_ops.ops`).
- **Why it matters:** The render tree is what links assets to a frame. Crucially it is **graph-structured** — a single op type both groups draws and applies effects (transforms, faders, clips). This is structurally different from flux's current pipeline-explicit model where draws are individual ops linked by buffer/texture handles.
- **Likely missing from flux:** confirmed missing (no scene-graph node type).

### Timeline / clip / fader (timeline-as-graph) [authoring]
- **Description:** Time control as ops in the render tree. `Clip` defines a time window on a "Line" (timeline track) — only renders its children when global time is within the window. `Fader` exposes 8 named float channels that drive material parameters. `Beat` triggers on music beats.
- **Representative ops:** `Clip` (StartTime/Length/Line, `wz4_demo2_ops.ops` line 635), `ClipRandomizer`, `ClipRandDuration`, `MultiClip`, `Fader`/`Fader2` (`wz4_demo2_ops.ops` line 770), `Beat`, `Variable`. Wz4 ships a `customed = Wz4TimelineCed` custom editor for these.
- **Why it matters:** A demo is fundamentally a timeline of clips. By making clip-on-track an *operator*, Werkkzeug folds the timeline view into the same data model as everything else — no separate timeline file, the project file already is the timeline. This is what lets a 4-minute demo fit in 96 KB.
- **Likely missing from flux:** confirmed missing.

### Particle system (sources, modifiers, renderers) [scene] [visual]
- **Description:** Three-tier particle pipeline. **Sources:** `Cloud`, `Cloud2`, `Mesh(Wz4Mesh)`, `FromVertex(Wz4Mesh)`, `FromMesh`, `StaticParticles`, `Ballistic`, `Lissajous`, `Exploder(Wz4Mesh,?*Wz4Explosion)`. **Modifiers:** `Wobble`, `Add`, `SplinedParticles`, `Trails`, `Bulge`, `Sparcle`, `Morph(Wz4Mesh,Wz4Mesh)`. **Renderers:** `Sprites`, `Chunks(Wz4Particles,*Wz4Mesh)`, `Debris/ExplodeChunks`, `Trails`, `Metaballs`, `MarchingCubes(Wz4Particles,Wz4Mtrl)`, `MarchingCubesColor`. Plus extensions: `PlaceOnMesh`, `SingleForceField`, `FR033_MeteorShowerSim`.
- **Representative ops:** `fxparticle_ops.ops` (24 ops), `tron_ops.ops` extras.
- **Why it matters:** The "ExplodeChunks" / `Debris` op (turn a mesh into particles, each carrying a chunk of the mesh) is the most famous Werkkzeug effect — every fr_public intro uses it. Marching cubes from particles is the procedural-blob fluid renderer used in fr-067 and others.
- **Likely missing from flux:** confirmed missing (entire family).

### Skeletal animation + skinning [scene] [visual]
- **Description:** Skeleton type, bone-chain construction, skeleton import, animation baking onto mesh chunks, fake-bone (procedural bones), animation compression, morph baking.
- **Representative ops:** `Wz4Skeleton BoneChain()`, `Wz4Skeleton ImportSkeleton()` (`wz4_anim_ops.ops`); `ChaosMesh FakeBone`, `BurnAnim`, `BakeMorph`, `MergeAnim`, `CompressAnim`, `DeleteSkeleton` (`chaosmesh_ops.ops`); `BakeAnim` (`wz4_mesh_ops.ops`). XSI import for both Wz4Mesh and ChaosMesh.
- **Why it matters:** `.kkrieger` had walking enemies. The kkrieger-era pipeline (ChaosMesh) is the most asset-heavy part of Werkkzeug — even Farbrausch acknowledged you can't fully procedural-generate compelling character animation, so they shipped an XSI importer + compression. Note that flux is targeting Decima-class which absolutely requires this family.
- **Likely missing from flux:** confirmed missing.

### Post-processing / image-postprocess (IPP) stack [visual]
- **Description:** Render-tree-level postprocess ops chained as `Wz4Render(Wz4Render)`. The current Wz4 stack: ColorCorrect, DebugChannel, Blur, DepthOfField/DoF2/DoF3, SSAO, ColorBalance, ColorSaw, ColorGrade, CrashZoom, CrackFixer, FXAA3, ColorMath, Sharpen, SBlur, Bloom, Promist, Glow, FocusBlur, CustomIPP (user-shader-string), Glitch2D, BlockTransition, VideoDistort, GrabScreen.
- **Representative ops:** `wz4_ipp_ops.ops` (15 ops), `tron_ops.ops` (Sharpen/SBlur/Bloom/Promist/DoF3/Glow/FocusBlur), `kbfx_ops.ops` (VideoDistort/BlockTransition/Glitch2D).
- **Why it matters:** Standard AAA-ish post stack delivered as composable ops. `CustomIPP(Wz4Render, TextObject, TextObject, *?Texture2D)` is notable — it lets the user write a fragment shader inline as a string parameter and feed N textures, which is the escape hatch from the fixed op library.
- **Likely missing from flux:** confirmed missing (entire family).

### Signed distance field / volumetric / BSP [visual] [scene]
- **Description:** Volumetric representations as first-class types. `Wz4ADF` (Adaptive Distance Field) and `Wz4PDF` (signed distance field with primitives like `Cube`, `Sphere`, plus `Add`, `Multiply`, `Transform`, `Twirl`, `Merge`, `FromADF`). `Wz4BSP` (BSP from mesh, slice-and-dice, BSP-to-mesh).
- **Representative ops:** `adf_ops.ops` (Import, FromMesh), `pdf_ops.ops` (8 ops), `wz4_bsp_ops.ops` (Polyhedron, FromMesh, SliceAndDice, BSPToMesh).
- **Why it matters:** Sphere-tracing fluid + organic shapes were used in fr-063 (theta) and several intros. ADF as a *type carried through the op graph* (not an internal renderer feature) is the way Werkkzeug exposed it for authoring.
- **Likely missing from flux:** confirmed missing.

### Audio / beat-reactive [authoring]
- **Description:** Audio analysis exposed as ops feeding the rest of the graph. `AudioRMS()`, `AudioSpectogram()` return PocBitmap (1D texture / strip). The `Beat` render op listens to V2 synth beat events. The V2 synth itself (`fr_public/v2/`) is part of every Farbrausch intro.
- **Representative ops:** `wz4_audio_ops.ops` (2 ops), `Beat` in `wz4_demo2_ops.ops`.
- **Why it matters:** Demos sync to music; an op that emits beat-driven scalars is the canonical way to drive parameters. Sparse but essential.
- **Likely missing from flux:** confirmed missing.

### Font / typography [visual]
- **Description:** Procedural font building. `ChaosFont Font()` (generate font from system or pattern), `AddSymbol(ChaosFont, BitmapBase)`, `MergeFont`. Coupled to `Wz4Mesh Text3D` and bitmap `Text` for actual rendering.
- **Representative ops:** `chaos_font_ops.ops` (3 ops), `Text3D` in `wz4_mesh_ops.ops`, `Text` in `wz3_bitmap_ops.ops`, `TronFont`/`TronPrint` in `tron_ops.ops`.
- **Why it matters:** Demo titles and credits. Procedural fonts mean no font file in the binary — and `TronFont`/`TronPrint` show that demos sometimes ship custom procedurally-built typefaces as part of the project.
- **Likely missing from flux:** confirmed missing.

### Demo-specific / extension ops [authoring]
- **Description:** Per-production op packs that ship alongside the framework — every fr-XYZ has its own `.ops` file with custom ops for that demo's specific effects.
- **Representative ops:** `fr033_ops.ops` (Tremble, House2Cube, FR033LimitTransform, Wz3TexPackage loader), `fr062_ops.ops` (SphereSlicer, ModSlice), `fr063_chaos/mandelbulb/sph/tron_ops.ops`, `fr067_ops.ops`, `easter_ops.ops` (CubeTrees, TVNoise, Julia4D), `kbfx_ops.ops`, `screens4_ops.ops`. Loaded as plugins.
- **Why it matters:** Demonstrates that the op set is meant to be *extended per project*. The framework ships a core, but every release is allowed to add its own ops. This is an authoring-scale story: at 1000-op scale, no one core op set can stay general — projects must contribute domain ops.
- **Likely missing from flux:** present in concept (registry exists) but the workflow precedent of "ship a `.ops` file per project" is not in flux's substrate.

## The "procedural everything" pattern

Werkkzeug's defining trick is that the on-disk project file is the only asset, and *all* runtime content is reconstructed by walking the op graph. `.kkrieger` is 96 KB because that 96 KB is roughly: the executable (compressed by kkrunchy), a tiny V2 synth, and a single project file containing the operator graph. There are no `.png`, `.dds`, `.fbx`, `.wav` files. Concretely the framework enables this through five interlocking families:

1. **Texture generators with composition** (`wz3_bitmap_ops.ops`) — 37 bitmap ops that compose into long filter chains. Perlin + Cell + Bump + Light + Color is a 5-op graph that produces a 512×512 normal-mapped stone wall. No image data ships.

2. **Mesh modifier stacks with selection** (`wz4_mesh_ops.ops`, 47 ops) — Cube → Subdivide(4) → Select(face mask) → Bevel → ExtrudeNormal → Displace(Perlin) → Crease is a 7-op graph that produces a non-trivial architectural element. The selection family is critical: without `Select`/`SelectGrow`, the modifier stack can only apply uniformly, and you lose the difference between "blob" and "building."

3. **Multiply / instancing** (`Wz4Mesh MultiplyNew`, `Wz4Render Multiply`) — One node + Count=1024 + an animated transform delta replaces what would be 1024 placed instances in a DCC tool. The Count is itself `anim`-tagged so a single Multiply can morph between 4 and 200 instances over the demo timeline. This is the single most-leveraged op in Wz4 productions.

4. **Particles + chunk renderers** (`fxparticle_ops.ops`) — `Wz4Render Debris(Wz4Particles, Wz4Mesh)` turns a single source mesh into N chunks, each carried by a particle; the famous "everything explodes into pieces" Farbrausch transitions. Cost: ~2 ops + a Multiply or Cloud source.

5. **Material as sub-graph** (`wz4_modmtrl*_ops.ops`) — Materials are themselves nodal (35+ shader-component ops) and reference textures that are themselves nodal. The whole rendering description for one surface might be a graph of 8-20 ops, all of which serialize as positions in the same project tree.

**Implication for flux's 1000-op target:** Werkkzeug's evidence is that procedural composition is not optional at this scale — *it is the only way a single authored project gets to AAA-feeling content density.* The families above don't replace asset loading (Wz4 also has `Import` ops and an XSI importer for irreducible character work), but they are what let Farbrausch ship demos with the visual mass of a much larger AAA scene from project files that are kilobytes. If flux aspires to "thousands of operators in a single project" delivering Decima-class density, the absence of any of: mesh-modifier stacks, selection regions, instancing operators, procedural-texture filter chains, and material sub-graphs effectively caps achievable density at "one explicit draw per operator." Werkkzeug's number is "thousands of draws per operator" via Multiply, "thousands of mesh chunks per operator" via Debris, "infinite procedural detail per operator" via bitmap filter chains.

A second, less obvious point: **types in Werkkzeug are domain-specific (Wz4Mesh, GenBitmap, Wz4Render, Wz4Particles, ModShader, Wz4ADF, Wz4BSP, Wz4Skeleton, ChaosFont)** rather than generic engine primitives. This typing is what makes the modifier stacks tractable — `Wz4Mesh → Wz4Mesh` chains are statically valid, and the GUI can hint compatible ops. Flux's current types (Value enum) are intentionally more generic; Werkkzeug suggests that at the modifier-stack scale, domain types may be the only thing keeping a 47-op modifier menu searchable.

## Notable patterns (not operators)

- **Inline animatable parameters (`anim` keyword)** — Every animatable scalar/vec/color in a parameter block is tagged `anim`, e.g. `anim float31 Scale (-1024..1024 step 0.01) = 1`. Animation slots live on the operator itself, not in a separate curve store; the editor surfaces them inline (`wz4_demo2_ops.ops` shows this on essentially every render op).
- **Inline per-op scripts (`string Script` parameter)** — Many render ops carry a multi-line `Script:0` parameter that runs an embedded scripting language per frame. The Transform, Multiply, Camera, Variable, Fader, Script (root) ops all carry one. The script can read/write Variable nodes and emit per-frame value changes. This is the escape hatch when graph composition isn't expressive enough — and it's not a separate file, it's a parameter on a node.
- **Custom editors per op (`customed = Wz4SplineCed`/`Wz4TimelineCed`)** — Specific ops bind to specific custom editor widgets (spline editor, timeline editor). The Spline op's editor is a curve canvas, the Clip op's editor is a timeline strip. The graph view is the default but ops can override it.
- **Type lattice with subtype-as-input-compat** (`type ModShaderSampler : ModShader`, `Rendertarget2D : Texture2D`) — Operators accept supertypes uniformly. Lets you plug a Rendertarget into anywhere a Texture2D is expected.
- **Input cardinality declared in the signature** — `Wz4Mesh Add(*?Wz4Mesh)` (one or more, all optional), `Material(?Texture2D x6)` (six optional textures), `Render(?*Wz4Render)` (zero or more). The variadic + optional combinatorics are first-class in the op declaration, not hand-coded.
- **Per-op column hints** (`column = 0`, `column = 3`) — Op declares which column of the wz4 page editor it prefers, which biases auto-layout. Primitives go to column 0, modifiers to column 3 — encoding a left-to-right pipeline reading order in the op metadata.
- **Per-op keyboard shortcuts** (`shortcut = 'm'` for Multiply, `'t'` for Transform, `'S'` for Spline) — A registered shortcut per op. At 1000-op scale, menu search is too slow; shortcut conventions become essential authoring infrastructure.
- **Flags `uncache` / `notab` / `render3d` / `hide`** — Op-level metadata controlling lifecycle: `uncache` means re-run every frame, `notab` excludes from the type browser, `render3d` puts the op output in the 3D viewport.
- **Conversion ops marked `conversion | hide`** (`ConvertFromChaosMesh`) — Type conversions are operators too, but hidden from the palette; the editor inserts them automatically when wiring incompatible types.
- **Demo-specific op packs as `.ops` plugins** — Each shipped production has its own `frXXX_ops.ops` adding custom ops alongside the core library, loaded as a distinct unit. Treats "this project's custom operators" as a normal authoring artifact.
- **Conditional parameter visibility** (`if(Mode!=3) { anim float31 Position ... }`) — The .ops format supports `if(...)` blocks inside `parameter { ... }`. Inspector folds collapse/expand based on the value of other parameters. Authoring at scale: don't show 30 parameters when 6 are relevant for the current mode.
- **Variable / Spline as named global channels** — `Wz4Render Variable` declares a named (string) global float4 channel; `Wz4Render Spline` declares a named keyframe curve. Other ops reference these by name from their inline scripts — explicit cross-graph wiring without ports.

## Sources cited

- `demoscene/fr_public/README.md`
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_mesh_ops.ops` (mesh primitives + ~35 modifiers)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_demo2_ops.ops` (render tree, transforms, multiply, clip, fader, spline, variable, script)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz3_bitmap_ops.ops` (procedural texture generators + filter ops)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_cubemap_ops.ops`
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_modmtrl_ops.ops`, `wz4_modmtrlmod_ops.ops` (modular shader graph)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_mtrl_ops.ops`, `wz4_mtrl2_ops.ops`, `wz4_rovemtrl_ops.ops`
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_ipp_ops.ops`, `tron_ops.ops`, `kbfx_ops.ops` (post-process stack)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/fxparticle_ops.ops` (particles, debris, marching cubes)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_anim_ops.ops` (skeleton)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/chaosmesh_ops.ops` (rigged-mesh pipeline, XSI import, anim compression)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/wz4_audio_ops.ops` (audio analysis)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/adf_ops.ops`, `pdf_ops.ops`, `wz4_bsp_ops.ops`, `wz4_ssao_ops.ops` (SDF/BSP/SSAO)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/chaos_font_ops.ops` (procedural fonts)
- `demoscene/fr_public/altona_wz4/wz4/wz4frlib/fr033_ops.ops`, `fr062_ops.ops`, `fr063_*_ops.ops`, `fr067_ops.ops`, `easter_ops.ops`, `screens4_ops.ops` (per-production extension op packs)
- `demoscene/fr_public/werkkzeug3_kkrieger/genmesh.cpp` (kkrieger-era class-method mesh op library, 5557 lines)
