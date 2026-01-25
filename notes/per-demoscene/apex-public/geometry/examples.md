# Geometry Examples from Clean Slate

When you look at a finished demoscene production like Clean Slate, you see cassette tapes, terrain, intricate greebled surfaces, and organic shapes flowing through the timeline. But behind those visuals lies a modeling system built from parametric primitives and filter stacks. Understanding how real production content combines these building blocks reveals practical patterns that theoretical documentation can't capture.

The extracted model files from Clean Slate's production data show how artists think in this system. A cassette tape isn't a stored mesh imported from Blender—it's a stack of cubes transformed into beveled boxes, lofted cylinders for tape reels, and cloned text for label details. A terrain isn't height-mapped imagery—it's a subdivided plane displaced by filters and tinted for texture mapping. These examples teach the grammar of procedural modeling in practice.

This matters because most creative coding frameworks provide primitives but little guidance on composition. You get a sphere generator and a subdivision function, but learning to combine them effectively requires experimentation. By analyzing production models, we can extract reusable patterns: "mechanical objects use bevel for hard edges," "organic shapes combine greeble with smooth," "terrain layers tint-driven displacement with mesh smoothing." These patterns become the framework's vocabulary.

Think of this document like studying a master painter's sketchbook. The finished demo is the gallery painting, but the model files are sketches showing construction, proportions, and technique. We're not just cataloging what each model contains—we're extracting why it's built that way and what that teaches about the system's expressive potential.

## Extraction Source

Models analyzed here come from `demoscene/apex-public/Projects/Clean Slate/extracted/models/`. The extraction process parsed Clean Slate's binary project file and serialized ModelObject definitions to JSON. Each file represents one geometric object as it existed in the authoring tool before compilation into the final 64KB executable.

The JSON structure follows apEx's internal representation:
- `guid` — Unique object identifier
- `name` — Object name from the scene tree
- `objects` — Array of model objects (mesh definitions)
  - `object_type` — Primitive enum value
  - `transformations` — 12-value matrix (3x4, as fixed-point integers)
  - `parameters` — Primitive-specific byte array
  - `filters` — Stack of filter definitions with parameters

Parameter values are stored as unsigned bytes or 16-bit fixed-point integers. The fixed-point format uses 15360 as 1.0, so matrix values like `"0": 15360` represent identity scaling. Transformation values exceeding 32768 represent negative numbers (two's complement).

## Example 1: Cassette Tape (scenescasette.json)

**File:** `demoscene/apex-public/Projects/Clean Slate/extracted/models/scenescasette.json`
**Complexity:** 11 objects, mixture of primitives and loft operations
**Purpose:** Physical media object with mechanical detail

The cassette model demonstrates how to build complex mechanical assemblies from simple primitives. Rather than modeling the entire cassette as one mesh, the artist breaks it into logical components: main body, window, tape reels, text labels, and mounting plane.

### Main Body Construction

**Object:** Cube primitive (object_type 0)
**Transform:** Scaled non-uniformly (17655, 16913, 13924 in fixed-point → ~1.15, ~1.10, ~0.91)
**Parameters:** 12 bytes for resolution subdivision (9, 28, 0, 0, 10, 28, 0, 0, 11, 28, 0, 0)

The main body starts as a cube primitive but with non-zero parameters requesting subdivision. The parameter pattern `(9, 28, 0, 0)` repeated three times suggests per-axis subdivision counts, creating a more tessellated cube suitable for filter operations.

**Filter stack:**
1. **Filter type 1 (Bevel):** Parameters `(5, 0, 0)` — Bevel amount 5/255 ≈ 2% edge chamfer
2. **Filter type 4 (SmoothGroup):** Parameters `(255, 0, 0)` — Maximum smooth group separation (all hard edges)
3. **Filter type 0 (UVMap):** Complex transform suggesting box mapping

The bevel creates rounded edges on what would otherwise be a sharp-edged box. Setting SmoothGroup to 255 ensures those beveled edges render with crisp facets rather than smooth interpolation, giving a plastic/mechanical appearance. The UV mapping applies afterward to ensure texture coordinates account for beveled geometry.

This pattern—subdivided cube + bevel + hard normals—is the foundation for most mechanical rectangular objects in demoscene productions. It's cheaper than modeling chamfered boxes manually and gives consistent results.

### Window Section

**Object:** Second Cube primitive
**Transform:** Scaled (16913, 14335, 14512) with Y translation (48399 ≈ -17232 in signed → negative offset)
**Parameters:** All zeros (minimal subdivision)
**Filter stack:**
1. **UVMap** with parameters `(0, 0, 109)` — Different UV channel/mapping
2. **Filter type 5 (TintMesh):** Applies texture sampling to vertex colors
3. **Filter type 2 (MapXForm):** Transform based on vertex color
4. **UVMap** again with different transform

The double UV mapping is unusual. The first pass likely generates base coordinates, TintMesh samples a texture into vertex colors (probably a mask defining which parts are transparent), then MapXForm uses those colors to deform geometry. The second UV pass regenerates coordinates after deformation.

This creates the cassette's transparent window section. The color-driven deformation probably indents the window area slightly below the main body surface.

### Tape Reels (Loft Primitives)

**Objects:** Multiple Loft primitives (object_type 8) with Arc inputs
**Key pattern:**
- Arc primitive defines circular path
- Second Arc defines cross-section
- Loft sweeps cross-section around path
- Result: Cylindrical tape reel

Looking at the Loft parameters:
```json
"parameters": {
  "0": 8,   // Path segments
  "1": 9,   // Slice resolution
  "2": 1,   // Path closed
  "3": 1,   // Slice closed
  "4": 0,   // No rotation
  "5": 255, // Start scale 100%
  "6": 255  // End scale 100%
}
```

This generates a torus-like shape—a circle extruded around a circular path. Parameters 2 and 3 both being 1 (closed) confirm this creates a continuous surface. The segment counts (8, 9) are deliberately low to keep vertex count minimal while maintaining visual smoothness.

The cassette has two identical loft operations (objects with GUID ending in `57CF...` and `4AB0...`) with slightly different transforms, creating the two tape reels. This is instancing at the modeling level—define the geometry once, reference it with different transforms.

### Text Labels

**Object:** Text primitive (object_type 16)
**Parameters:** Font index and deviation, plus external string data (likely "TDK" or similar cassette branding)
**Transform:** Scaled very small (14391 ≈ 0.94) with specific position on cassette face

Text primitives generate 2D outlines from TrueType fonts. The transform positions this flat text on the cassette's surface. The lack of filters suggests the text is rendered as flat geometry, not extruded—appropriate for a label that's printed rather than embossed.

Multiple Clone objects (object_type 9) reference this text primitive with different transforms, placing the same text in multiple locations (both sides of cassette, different positions for branding).

### Assembly Technique

The cassette demonstrates **component-based modeling**:
1. Create base shapes (body, window)
2. Add mechanical details (reels via loft)
3. Apply surface features (text labels)
4. Use cloning for symmetry and repetition

This contrasts with **monolithic modeling** where everything is one mesh. The component approach allows:
- Independent materials per component (body vs. window vs. reels)
- Efficient updates (modify the text, all clones update)
- Logical scene hierarchy (parent the whole assembly to animate it)

The total vertex budget for this cassette is likely under 1000 vertices—remarkably efficient for an object with this much visual detail.

## Example 2: Greebled Surface (scenesgreeble1.json)

**File:** `demoscene/apex-public/Projects/Clean Slate/extracted/models/scenesgreeble1.json`
**Complexity:** Single GeoSphere with one filter
**Purpose:** Demonstration of procedural detail generation

This example is elegantly simple: take a sphere, add surface complexity. It's the "hello world" of procedural detailing.

### Base Primitive

**Object:** GeoSphere (object_type 11)
**Parameters:**
```json
"parameters": {
  "0": 1,   // Iterations (subdivision level)
  "1": 112, // Possibly random seed or additional param
  "2": 0,
  "3": 69,
  "4": 0,
  "5": 120,
  ...
}
```

GeoSphere starts with an icosahedron and subdivides. One iteration creates 80 triangles (20 faces × 4). This provides enough surface detail for the greeble filter to work with while keeping the base complexity low.

The additional parameters (112, 69, 120, etc.) might control UV mapping or vertex color initialization, preparing the sphere for the filter.

### Greeble Filter

**Filter type 10:** Greeble procedural detailing
**Parameters:** `(0, 3, 255)`
- Param 0: Random seed = 0
- Param 1: Extrusion range = 3/255 ≈ 1.2% scale factor
- Param 2: Taper = 255 (maximum taper, extruded faces are significantly smaller than base)

The greeble filter will:
1. Subdivide each face randomly (creating irregular patterns)
2. Extrude subdivided regions outward with varying heights (controlled by seed 0)
3. Taper extruded faces heavily (taper=255), creating pyramidal protrusions

With seed 0 and moderate extrusion (3/255), this creates a relatively subtle bumpy surface rather than extreme spikes. The high taper value (255) ensures protrusions narrow to points rather than maintaining face size.

### Visual Result

This produces what looks like an asteroid or alien terrain sphere. The greeble adds:
- Random surface variation (breaks up the smooth sphere silhouette)
- Self-shadowing detail (extruded faces catch light differently)
- Scalable complexity (change iterations for more/less detail)

The entire model definition is 68 bytes in JSON (excluding formatting). This generates hundreds or thousands of vertices at runtime. That's the power of procedural geometry—specify intent compactly, generate detail algorithmically.

### Common Usage Pattern

This pattern appears in many demos for:
- **Asteroids/debris:** GeoSphere + Greeble + rock texture
- **Alien worlds:** Large GeoSphere + Greeble + atmospheric shading
- **Tech surfaces:** Cube + Subdivide + Greeble (creates mechanical panel detail)

Artists vary the random seed to generate multiple unique objects from the same definition. Seed 0, seed 1, seed 2 produce three different asteroids with identical modeling effort.

## Example 3: Organic Metaball Shapes (scenesblob1.json)

**File:** `demoscene/apex-public/Projects/Clean Slate/extracted/models/scenesblob1.json`
**Complexity:** Two GeoSphere primitives with simple filters
**Purpose:** Smooth organic forms for abstract scenes

This example shows how to create blob-like organic shapes that flow into each other, likely used in Clean Slate's more abstract visual sequences.

### Blob Construction

**Object 1:** GeoSphere with parameters `(3, 0, 0, 0...)` — 3 subdivision iterations
**Object 2:** GeoSphere with parameters `(5, 0, 0, 0...)` — 5 subdivision iterations

The different iteration counts create two spheres with different tessellation densities. At 3 iterations: 1,280 triangles. At 5 iterations: 20,480 triangles. This suggests the second sphere is either larger in the scene or requires smoother deformation.

**Transform differences:**
- Object 1: Identity scale (15360 = 1.0)
- Object 2: Slightly larger (15535 ≈ 1.011)

Both have minimal scaling, meaning they're roughly unit spheres that will be positioned in the scene via object transform hierarchies.

### Filter Application

Both objects apply the same filter:

**Filter type 4 (SmoothGroup):** Parameters `(255, 0, 0)`

Wait—that's hard edges (255 = maximum separation threshold), which seems counterintuitive for "organic blobs." But remember: SmoothGroup doesn't create smoothness, it controls normal calculation. Setting it to 255 here likely means "calculate normals per-vertex based on surrounding faces" with no edge angle restrictions.

The second object adds:

**Filter type 0 (UVMap):** With transform parameters creating a planar or spherical projection

This suggests Object 2 is textured while Object 1 might be a solid color or uses material-based coloring.

### The Marching Tetrahedra Connection

While these models don't use the Marching primitive (object_type 17), they're likely inputs to a marching tetrahedra operation defined elsewhere in the scene. The pattern is:

1. Create multiple GeoSphere objects at different positions
2. Position them so they overlap slightly
3. Feed their transforms to a Marching primitive
4. The marching algorithm samples their implicit fields and generates a merged isosurface

This creates the classic "metaball" effect where spheres blend smoothly into each other. The different subdivision levels might indicate which sphere contributes more detailed geometry to the final merged mesh.

Alternatively, these could be rendered independently with a shader that creates soft edges, achieving a similar visual result without mesh merging.

### Organic Modeling Pattern

For truly organic shapes in apEx, the workflow is:
1. **Base form:** GeoSphere (not UV sphere—geodesic gives better deformation)
2. **Smooth normals:** Low SmoothGroup separation
3. **Optional displacement:** NormalDeform with noise-based vertex colors
4. **Optional merging:** Marching tetrahedra to blend multiple objects

This differs from mechanical modeling (cube + bevel + hard normals). Organic forms prioritize smooth curvature over crisp edges.

## Example 4: Terrain (scenesterrain.json)

**File:** `demoscene/apex-public/Projects/Clean Slate/extracted/models/scenesterrain.json`
**Complexity:** Subdivided plane with four-filter stack
**Purpose:** Ground surface with height variation

Terrain demonstrates how displacement mapping works in apEx's CPU-side geometry pipeline. Instead of storing height data or sampling textures in a shader, the system bakes displacement into vertex positions.

### Base Geometry

**Primitive:** Plane (object_type 1)
**Parameters:** `(253, 241, 0, 0...)` → XRes=253, YRes=241
**Result:** 253×241 = 61,073 quads = 244,292 triangles after triangulation

That's an extremely high-resolution plane. Most real-time terrain uses far fewer vertices and relies on texture detail. This suggests Clean Slate either:
- Targets high-end hardware
- Uses aggressive LOD (level of detail) where this high-res version only renders when close to camera
- Compresses the vertex data heavily in the final 64k build

### Filter Stack Analysis

**Filter 1: TintMesh (type 5)**
Parameters: `(0, 0, 0)`
- UV channel 0
- Texture operator index 0
- No saturation boost

This samples a procedural texture (likely Perlin noise or similar) and stores the result in vertex colors. Each vertex's red channel now contains a height value.

**Filter 2: MapXForm (type 2)**
Transform parameters include `(15340, 32768, 0, 0...)` with Z-axis displacement

The negative Y value (32768 = -32768 in signed 16-bit) suggests this deforms vertices downward or in a specific direction. Combined with vertex color from TintMesh, this creates the initial height variation.

**Filter 3: MeshSmooth (type 3)**
Parameters: `(0, 1, 0)` → Not linear, 1 iteration

Catmull-Clark subdivision smooths the terrain. After displacement creates sharp height variations, subdivision rounds them into rolling hills rather than stepped pyramids. One iteration is enough—it quadruples the polygon count, so we go from 61k quads to 244k quads to nearly a million triangles.

Wait, that seems excessive. Let me reconsider: the plane is 253×241, but MeshSmooth might only process a subset, or the minimal build might skip this for distant terrain. Alternatively, Clean Slate might use this as a height source for instancing or shader-based displacement rather than rendering the full mesh.

**Filter 4: SmoothGroup (type 4)**
Parameters: `(255, 0, 0)` → Hard edges everywhere

This is surprising. After smoothing geometry, why force hard normals?

One possibility: hard normals enhance shadows on terrain. Smooth normals can wash out height detail because adjacent faces average their normals. Hard normals keep each face distinct, creating more pronounced shadows that emphasize terrain features. This is a stylistic choice—realistic terrain uses smooth normals, but stylized/low-poly aesthetics use hard normals.

Another possibility: The SmoothGroup parameter might be misread. If it's actually 0 (smooth everything), the JSON encoding might have represented it differently.

### Terrain Generation Pipeline

The effective workflow is:
1. Create high-res plane
2. Sample noise texture → vertex colors (defines height)
3. Displace vertices using color-driven transform
4. Smooth geometry to reduce sharp edges
5. Set normal behavior (hard vs. soft edges)

This CPU-side approach gives complete control over terrain shape at the cost of preprocessing time and memory. Modern frameworks might do this on GPU via tessellation shaders or displacement mapping, but for 64k intros where file size matters more than runtime performance, baking makes sense.

### Accompanying Cube Object

The terrain model includes a second object:

**Primitive:** Cube (object_type 0)
**Parameters:** `(100, 54, 218, 0, 168, 241, 217, 0...)`
**Transform:** Scaled vertically (10308 ≈ 0.67 in Y) with large Y translation (41979)

The parameters suggest this might be a subdivided cube, and the transform places it far above or below the terrain (41979 is a large offset). This could be:
- **Skybox component:** A box surrounding the scene for background
- **Culling volume:** A bounding box for terrain chunks
- **Shadow receiver:** A plane positioned to catch terrain shadows

Without seeing the full scene graph, its exact purpose is unclear, but it's definitely not terrain geometry itself.

## Example 5: Oscilloscope Visualization (scenesosci.json)

**File:** `demoscene/apex-public/Projects/Clean Slate/extracted/models/scenesosci.json`
**Complexity:** Loft primitive with two filter operations
**Purpose:** Tube/ribbon geometry for waveform visualization

This model shows how to create cable-like or ribbon geometry—essential for oscilloscope displays, audio visualizations, or any flowing curved surface.

### Path and Cross-Section

**Object 1: Line** (object_type 6)
Parameters: `(28, 0, 0...)` → 28 vertices along the line

A line primitive creates a straight polyline path. With 28 vertices, this will be the "spine" along which the cross-section is extruded.

**Object 2: Arc** (object_type 5)
Parameters: `(4, 255, 0...)` → 4 segments, full circle (255 = 2π)

A circular arc with only 4 segments creates a square-ish cross-section (4 sides approaching a circle). This is the shape that will be swept along the line path.

**Object 3: Loft** (object_type 8)
Parent GUIDs reference both Line and Arc
Parameters: `(0, 1, 0, 1, 0, 255, 255, 0, 31...)`
- Path segments: 0 (use all vertices from path)
- Slice resolution: 1
- Path not closed, slice closed (creates a tube)
- Rotation: 0 (no twist)
- Scale start/end: 255 (full scale both ends)

The loft sweeps the 4-vertex arc around the 28-vertex line, creating a tube with 28×4 = 112 vertices forming the surface.

### Filter Stack

**Filter 1: UVMap (type 0)**
Transform with large X scale (22064) and specific rotation
This likely applies cylindrical UV mapping to wrap a texture around the tube.

**Filter 2: MeshSmooth (type 3)**
Parameters: `(0, 1, 0)` → Smooth subdivision, 1 iteration

After lofting creates the basic tube, subdivision rounds out the square cross-section. The 4-sided tube becomes an 8-sided tube (each edge splits), approaching a smoother cylinder.

### Why Not Use Cylinder Primitive?

The Cylinder primitive (object_type 3) could create a similar shape. Why use Line + Arc + Loft?

**Flexibility:** The Line primitive can be replaced with a Spline for curved paths. By building the model from path + cross-section + loft, the artist can easily modify the path to create curved tubes without changing the filter stack. The Cylinder primitive is locked to a straight axis.

This is a **template workflow**:
1. Define path (Line or Spline)
2. Define cross-section (Arc or other shape)
3. Loft them together
4. Apply filters for detail (smoothing, UV mapping)

Change step 1 to a spiral Spline, and you get a spiral tube. Change step 2 to a square, and you get a square-profile tube. The workflow is reusable.

### Oscilloscope Waveform Technique

For actual waveform visualization, the Line primitive's vertex positions would be animated based on audio samples. The Loft operation runs at authoring time to create the mesh topology, but at runtime, vertex positions update each frame to match the current audio buffer.

This is likely implemented by:
1. Loft generates the mesh with default straight line
2. SavePos2 filter snapshots base positions
3. At runtime, vertex shader offsets positions based on audio data
4. The tube "dances" to the music while maintaining its topology

This same pattern applies to audio waveforms, ECG displays, seismograph outputs, or any line-based data visualization.

## Example 6: Spiral Form (scenesspiral.json)

**File:** `demoscene/apex-public/Projects/Clean Slate/extracted/models/scenesspiral.json`
**Complexity:** Arc path with loft and five-filter stack
**Purpose:** Twisted ribbon or spiral geometry

The spiral demonstrates advanced loft usage with rotation and complex filtering to create organic twisted forms.

### Path Definition

**Object 1: Arc** (object_type 5)
Parameters: `(40, 255, 1, 101, 32...)`
- 40 segments
- Full circle (255)
- HaveLastSegment = 1 (closed loop)
- Additional parameters suggest extended arc behavior (possibly multi-revolution spiral encoded in parameters)

This arc serves as the path. With 40 segments and parameters suggesting multiple revolutions, it's likely a 3D helix or spiral rather than a flat circle.

**Object 2: Arc** (cross-section)
Parameters: `(4, 255, 0, 0...)`
- 4 segments, full circle
- Creates the ribbon's thickness/width profile

**Object 3: Loft**
Parameters: `(0, 2, 0, 1, 0, 255, 255, 0, 31...)`
- Path closed: 0 (spiral has start/end)
- Slice closed: 1 (ribbon thickness is continuous)
- Rotation: 0 initially (but filters will add twist)

### Advanced Filter Stack

**Filter 1: TintMesh (type 5)**
Parameters: `(0, 0, 12)` → Sample texture, seed 12

Creates gradient vertex colors along the spiral. The seed (12) selects which procedural texture to sample.

**Filter 2: MapXForm (type 2)**
Parameters: `(0, 0, 12)` with transform including rotation (15447)

Uses vertex colors from TintMesh to modulate a transformation. This creates twist along the spiral—areas with high color values rotate more, areas with low values rotate less.

**Filter 3: Replicate (type 7)**
Parameters: `(4, 1, 12)` with transform including scale reduction (15355 ≈ 0.998)

Replicates the geometry 4 times with cumulative transform. Each copy is slightly smaller (0.998 scale) and offset. This creates concentric spirals or a multi-threaded helix.

**Filter 4: SmoothGroup (type 4)**
Parameters: `(19, 0, 12)` → Low separation threshold (smooth most edges)

After all geometric operations, smooth the normals for organic appearance.

**Filter 5: UVMap (type 0)**
Complex transform for final texture coordinates

Applies after all deformations so UVs account for twisted, replicated geometry.

### Why This Pattern?

The filter sequence demonstrates **progressive refinement**:
1. Generate base geometry (loft)
2. Add color variation (tint)
3. Deform based on color (transform)
4. Multiply the form (replicate)
5. Smooth appearance (smooth group)
6. Finalize texturing (UV map)

Each step builds on previous results. This is the opposite of filtering in image processing (where order often doesn't matter). Here, order is critical:
- TintMesh before MapXForm: Color drives deformation
- MapXForm before Replicate: Deformation is replicated, not reapplied per copy
- SmoothGroup after Replicate: Smoothing considers all geometry, including replicated parts
- UVMap last: Coordinates account for all transformations

This creates complex spiral ribbons suitable for abstract visuals, DNA helices, or decorative elements. The same pattern applies to any twisted, multi-strand geometric form.

## Example 7: Head (sceneshead.json)

**File:** `demoscene/apex-public/Projects/Clean Slate/extracted/models/sceneshead.json`
**Complexity:** Stored mesh with three-filter refinement stack
**Purpose:** Organic character geometry

The head model represents a different workflow: importing external geometry and refining it with filters.

### Base Primitive

**Primitive:** Stored mesh (object_type 18)
**Parameters:** Reference to external mesh data (4 bytes: `144, 121, 150, 117`)

This loads pre-built geometry, likely created in a 3D modeling tool like Blender and imported via Assimp. The parameters encode a reference ID to the stored mesh asset.

The transform applies:
- Non-uniform scale (11459, 113, 120) — compressed in X, almost flat in Y, normal in Z
- Complex rotation/translation positioning the head in the scene

This suggests the imported mesh is oriented differently than needed, requiring correction via transform.

### Filter Stack

**Filter 1: Bevel (type 1)**
Parameters: `(45, 0, 0)` → 45/255 ≈ 17.6% bevel

A relatively large bevel percentage. For organic forms like heads, this softens edges around facial features—jawline, eye sockets, cheekbones. The bevel adds geometric detail to what might be a low-poly imported mesh.

**Filter 2: UVMap (type 0)**
Parameters suggest uniform scaling (`14677, 14677, 14677 ≈ 0.955`) with specific operation mode

Regenerates UVs after beveling. The uniform scale suggests the imported mesh had UVs but they need adjustment after geometric modification.

**Filter 3: SmoothGroup (type 4, DISABLED)**
Parameters: `(255, 0, 67)` but `enabled: false`

This filter is defined but disabled. Perhaps during authoring the artist tested hard vs. soft normals and decided soft (the default) looked better. The filter remains in the stack but doesn't execute.

**Filter 4: Greeble (type 10)**
Parameters: `(16, 1, 204)` → Seed 16, very small extrusion (1/255 ≈ 0.4%), high taper (204)

Greeble on a head? This is unconventional. Possible interpretations:
- **Subtle surface variation:** Extremely low extrusion adds micro-detail without obvious greeble pattern
- **Stylized effect:** The head isn't photorealistic—it's stylized/abstract, and greeble adds texture
- **Disabled in final:** Like the SmoothGroup filter, this might be experimentation left in the file

The seed (16) and taper (204) are specific enough that this was intentionally configured, not accidentally left enabled.

### Stored Mesh Workflow

This example shows the **import-and-refine** workflow:
1. Model complex organic forms in a full-featured 3D tool (Blender, ZBrush, etc.)
2. Export as OBJ or FBX
3. Import into apEx via Assimp
4. Store as compressed mesh primitive
5. Apply filters to integrate with procedural content (bevel, UV remap)
6. Optionally add procedural detail (greeble)

This hybrid approach combines artist sculpting for complex forms with procedural refinement for consistency. The head might have hand-modeled facial features but procedurally generated surface texture.

### Why Not Fully Procedural?

Faces are notoriously difficult to generate procedurally. Parameters for "eye size," "nose bridge height," "cheek prominence" quickly explode in complexity. It's more efficient to:
- Sculpt base topology by hand
- Use procedural techniques for variation (vertex color-driven deformation)
- Apply filters for surface detail

This is the same approach modern games use: artist-created base meshes with procedural blendshapes and detail layers.

## Common Patterns Across Examples

Analyzing these models reveals recurring compositional patterns:

### Pattern 1: Primitive + Bevel + Hard Normals = Mechanical

**Used in:** Cassette body, potentially head features
**Recipe:**
- Cube or subdivided primitive
- Bevel filter (5-20% range)
- SmoothGroup with high threshold (255 or near)

Creates crisp plastic/metal appearance. The bevel prevents infinitely sharp edges (which look unrealistic and cause aliasing), while hard normals maintain faceted appearance.

### Pattern 2: GeoSphere + Greeble + Smooth = Organic Rough

**Used in:** Greeble example, possibly terrain
**Recipe:**
- GeoSphere (2-3 iterations for base density)
- Greeble filter with low-to-medium extrusion
- SmoothGroup with low threshold (0-20)

Produces asteroids, alien terrain, rocky surfaces. Vary the greeble seed for unique instances.

### Pattern 3: Path + Cross-Section + Loft + Smooth = Cables/Tubes

**Used in:** Oscilloscope, spiral, cassette reels
**Recipe:**
- Line or Arc or Spline (path)
- Arc or simple polygon (cross-section)
- Loft primitive connecting them
- MeshSmooth to round cross-section

Flexible workflow for any extruded form. Modify the path for different trajectories, modify the cross-section for different profiles.

### Pattern 4: Plane + Tint + Deform + Smooth = Terrain

**Used in:** Terrain example
**Recipe:**
- High-res Plane primitive
- TintMesh to sample height map
- MapXForm or NormalDeform to displace
- MeshSmooth to soften peaks

CPU-side terrain generation. Trade runtime performance for size efficiency and control.

### Pattern 5: Stored + Bevel + UVMap = Imported Assets

**Used in:** Head example
**Recipe:**
- Stored or StoredMini primitive (imported mesh)
- Bevel or other refinement filters
- UVMap to regenerate coordinates after modification

Integrates artist-created content with procedural pipeline. Maintains consistency of filter-based workflow even for external assets.

## Parameter Experimentation Guide

Understanding how parameter changes affect output helps artists iterate efficiently.

### Subdivision Counts (Plane, Sphere, Cylinder)

**Low (3-10):** Fast generation, visible faceting, suitable for:
- Background elements
- Stylized/low-poly aesthetic
- Objects that will be heavily filtered (subdivision adds detail)

**Medium (10-50):** Balanced detail:
- Mid-ground objects
- Base for single-iteration smoothing
- Standard use case

**High (50-255):** Expensive, smooth curves:
- Close-up hero objects
- Terrain needing fine displacement
- Smooth organic forms without subdivision filters

**Trade-off:** Each doubling of resolution quadruples polygon count. Use the minimum resolution that achieves the desired look after filters.

### Greeble Parameters

**Seed (0-255):** Changes random pattern
- Test multiple seeds (0, 1, 2, 3...) to find visually pleasing variation
- Same seed = deterministic result (important for demo playback)
- Seeds are cheap to vary—create 10 asteroids from one definition

**Extrusion (0-255):** Height of detail
- 0-5: Subtle surface bumps
- 5-20: Noticeable detail without extreme features
- 20-50: Prominent greeble, sci-fi panel look
- 50-255: Extreme spikes, alien architecture

**Taper (0-255):** Sharpness of features
- 0: Straight extrusion (flat-topped boxes)
- 128: Moderate taper (truncated pyramids)
- 255: Maximum taper (sharp points)

**Common combinations:**
- Asteroid: Seed varied, Extrusion 10-20, Taper 200-255
- Mechanical panel: Seed varied, Extrusion 5-10, Taper 50-100
- Alien surface: Seed varied, Extrusion 30-50, Taper 150-200

### Loft Rotation (0-255)

**0:** No twist — cross-section maintains orientation
**64:** Quarter turn over path length
**128:** Half turn (180°)
**255:** Full turn (360° twist)

Creates spiral ribbons, twisted cables, DNA-like forms. Combine with multi-revolution paths (spiral arcs) for complex helical structures.

**Tip:** Rotation interacts with path tangent. Straight paths show twist clearly. Curved paths combine path curvature with rotational twist, creating complex surfaces.

### MeshSmooth Iterations (1-5)

**1 iteration:** 4× polygon count, noticeable smoothing
- Rounds sharp edges
- Good for mechanical objects needing slight softness
- Efficient performance cost

**2 iterations:** 16× polygon count, very smooth
- Organic forms (characters, creatures)
- Soft surfaces (cushions, organic shapes)
- Common for hero objects

**3+ iterations:** 64× or more polygon count, extreme smoothness
- Rarely used (polygon explosion)
- Might be used for close-up renders or pre-computed geometry
- Consider using higher base resolution instead

**Tip:** One iteration on a high-res base often looks better than multiple iterations on low-res base, with fewer polygons.

## Framework Implications

These production examples teach specific lessons for creative coding framework design:

### Lesson 1: Composition Patterns Are Reusable

The path+cross-section+loft pattern appears in oscilloscope, spiral, and cassette models. A framework should:
- Document these patterns as recipes
- Provide templates or presets for common compositions
- Enable saving custom filter stacks as reusable modifiers

**Rust implementation idea:**
```rust
struct GeometryRecipe {
    name: String,
    primitives: Vec<PrimitiveDefinition>,
    filters: Vec<FilterDefinition>,
}

impl GeometryRecipe {
    fn instantiate(&self, params: &RecipeParams) -> Mesh {
        // Apply primitives and filters with user parameters
    }
}
```

Users could define "cable" recipe once, then instantiate it with different paths.

### Lesson 2: Filter Order Matters Profoundly

The spiral example shows TintMesh → MapXForm → Replicate, where changing order breaks the effect. Frameworks should:
- Make filter stack order explicit in UI
- Provide visual indicators of data flow (colors flow into transform)
- Warn when order might cause unexpected results

**Anti-pattern:** Auto-sorting filters by type. This breaks intentional ordering.
**Best practice:** Drag-and-drop filter stack with clear execution order.

### Lesson 3: Vertex Colors Are a Hidden API

Multiple examples use vertex colors for:
- Displacement masking (terrain tint drives height)
- Gradient-driven transforms (spiral twist intensity)
- Greeble density control

This reveals vertex colors as a **data channel**, not just rendering state. Frameworks should:
- Expose all four color channels for filter communication
- Provide filters to generate gradients (TintMeshShape)
- Document which filters read vs. write colors

### Lesson 4: Hybrid Workflows Are Essential

The head model combines imported mesh with procedural filters. Frameworks must support:
- Multiple primitive types (procedural + imported)
- Consistent filter API across all mesh sources
- Ability to mix artist content with procedural content

**Real-world need:** An artist sculpts a base character, then applies procedural armor plating (greeble + bevel), procedural cloth folds (noise displacement), and procedural weathering (vertex color variations).

### Lesson 5: Low Vertex Counts Still Matter

Despite modern GPUs handling millions of vertices easily, these models use:
- Cassette: ~1000 vertices total
- Greeble sphere: ~320 base, ~5000 after filter
- Terrain: 61k base (high for this system)

Keeping counts low enables:
- Faster filter execution (CPU-side processing)
- Better CPU-side animation (vertex shaders can't do complex logic in 64k)
- More objects in scene before GPU bottleneck

Frameworks targeting real-time should provide LOD (level of detail) systems where high-res meshes generate multiple simplified versions.

### Lesson 6: Determinism Enables Variation

Every greeble, scatter, and replicate filter uses explicit seeds. This means:
- Same definition → same result (reproducible)
- Different seed → different instance (variation without new models)

Frameworks should:
- Make randomness opt-in and seeded
- Expose seed as a first-class parameter in UI
- Provide "generate variations" feature that increments seeds

**Example UX:** Right-click a greebled object → "Create 5 Variations" → Generates 5 instances with seeds 0-4.

## Conclusion

These geometry examples from Clean Slate demonstrate that procedural modeling is a **language**, not just a toolbox. Artists don't just use primitives and filters—they compose them in idiomatic patterns that emerge through practice.

The cassette tape teaches component-based assembly. The greeble sphere teaches how minimal parameters generate complexity. The terrain shows displacement pipelines. The spiral demonstrates progressive refinement through filter stacks. The head reveals hybrid workflows blending sculpting with procedures.

A creative coding framework that merely provides these primitives and filters would be functional but not fluent. True fluency comes from recognizing patterns, documenting workflows, and designing APIs that make common patterns obvious while keeping rare patterns possible.

The next step is implementing these patterns in a Rust-based framework: trait-based primitives, filter stacks as first-class types, vertex attributes as communication channels, and deterministic procedural generation. The apEx examples show what's possible when you get the abstractions right.

## References

- Model extraction files: `demoscene/apex-public/Projects/Clean Slate/extracted/models/scenes*.json`
- Primitive implementations: `notes/per-demoscene/apex-public/geometry/primitives.md`
- Filter implementations: `notes/per-demoscene/apex-public/geometry/filters.md`
- Architecture overview: `notes/per-demoscene/apex-public/architecture.md`
- Clean Slate production: Released at Revision 2017, 64KB intro by Conspiracy
