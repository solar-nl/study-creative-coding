# Mesh Filters in apEx

In apEx's procedural modeling system, primitives define the initial shape—a cube, sphere, or spline—but filters transform that raw geometry into the final form. Think of filters as the difference between cutting a diamond from rough stone versus mining the stone itself. The primitive gives you material to work with; filters sculpt it into something useful.

This filter stack architecture solves a fundamental problem in demoscene tools: how do you build complex geometry from simple building blocks while keeping executable size minimal? apEx's answer is to apply a sequence of modifiers, each performing one focused transformation. A sphere primitive becomes an alien landscape through a stack like: create sphere → greeble (add surface detail) → normal deform (displace vertices) → UV map (prepare for texturing).

The system's elegance lies in its composability. Each filter operates on the mesh's current state—vertices, polygons, edges, normals, UV coordinates—and passes the modified result to the next filter in the chain. This means you can combine simple operations to create complex results without specialized code for every possible shape.

## Filter Execution Model

The 13 filter types live in `Mesh.h:77-117` as the `PHXMESHFILTER` enum. Each filter enum value corresponds to a specific method on `CphxMesh`, and when a model is generated at runtime, the filter stack is applied sequentially in `Project.cpp:907-976`. The order matters—applying bevel before smooth produces different results than smooth before bevel.

Here's the complete filter enumeration:

```cpp
enum PHXMESHFILTER {
  ModelFilter_UVMap = 0,           // Generate texture coordinates
  ModelFilter_Bevel = 1,           // Create beveled edges
  ModelFilter_MapXForm = 2,        // Transform UV coordinates
  ModelFilter_MeshSmooth = 3,      // Catmull-Clark subdivision
  ModelFilter_SmoothGroup = 4,     // Control normal smoothing
  ModelFilter_TintMesh = 5,        // Sample texture to vertex colors
  ModelFilter_TintMeshShape = 6,   // Generate gradient vertex colors
  ModelFilter_Replicate = 7,       // Array/duplicate geometry
  ModelFilter_NormalDeform = 8,    // Displace along normals
  ModelFilter_CSG = 9,             // Boolean operations
  ModelFilter_Greeble = 10,        // Procedural surface detail
  ModelFilter_Invert = 11,         // Flip polygon winding
  ModelFilter_SavePos2 = 12,       // Snapshot positions for animation
};
```

Each filter type has associated parameter counts (defined in `Project.cpp:131-144`) and may carry additional transform data. The execution loop unpacks these parameters and dispatches to the appropriate mesh method.

## UV Map Filter

**Purpose:** Generate texture coordinates from vertex positions.
**Implementation:** `Mesh.cpp:1004-1113`
**Parameters:** Projection type, UV channel, clip flag, transform (scale/rotate/translate)

UV mapping solves the problem of wrapping a 2D texture onto 3D geometry. apEx provides four projection modes plus a special transform mode:

- **Planar** — Projects positions onto a plane, like shining a slide projector
- **Spherical** — Wraps around a sphere using latitude/longitude
- **Cylindrical** — Wraps around a cylinder, with planar mapping for top/bottom
- **Box** — Projects from six directions, choosing the face most aligned with each polygon
- **TransformOriginal** — Applies a matrix to existing UVs instead of regenerating

The implementation converts each vertex position to local space via the provided transformation matrix, then calculates UV coordinates based on the projection mode. For spherical mapping, it uses `atan2` to find the angle around the Y-axis and `acos` for the angle from the north pole (`Mesh.cpp:1049-1051`):

```cpp
float tanval = -atan2f(vn.z, vn.x) / (2 * pi) + 0.5f;
p->Texcoords[y][Channel] = D3DXVECTOR2(-tanval, acos(vn.y) / pi);
```

A multi-pass approach handles the spherical seam. The first pass generates UVs and tracks whether vertices straddle the seam (checking if both positive and negative X values exist with negative Z). The second pass adds 1.0 to the U coordinate of vertices on the "wrong" side of the seam to prevent interpolation wrapping. The third pass fixes pole singularities by averaging surrounding U values (`Mesh.cpp:1103-1110`).

This filter is almost always the first or last in a stack—first to set up UVs before operations that preserve them, or last to generate UVs after geometric transformations are complete.

## Bevel Filter

**Purpose:** Create beveled edges by shrinking polygons and building edge strips.
**Implementation:** `Mesh.cpp:1282-1391`
**Parameters:** Bevel amount (percent shrinkage)

Bevel transforms sharp edges into smoothed transitions. Think of it like chamfering the edges of a wooden box—each face shrinks slightly, and new faces connect the original edges to the shrunken versions.

The algorithm runs in two phases:

**Phase 1: Shrink polygons** (`Mesh.cpp:1309-1350`)
For each polygon, calculate its center, then create new vertices by interpolating between each original vertex and the center:

```cpp
D3DXVECTOR3 center = nullvector3;
for (int y = 0; y < p->VertexCount; y++)
  center += Vertices[p->VertexIDs[y]].Position;
center /= (float)p->VertexCount;

// Create shrunken vertex
D3DXVECTOR3 nv = (Vertices[p->VertexIDs[y]].Position - center) * (1 - Percent) + center;
```

The clever part is tracking which new vertices belong to which edges. Each edge can have up to four new vertices (two endpoints, each potentially split for two adjacent polygons). The code stores these in `CphxEdge::NewVertexIDs[2][2]`, indexed by endpoint (0 or 1) and side (determined by cross product with polygon normal).

**Phase 2: Build edge strips** (`Mesh.cpp:1357-1389`)
For edges with both sides defined, create a quad connecting the four new vertices (`Mesh.cpp:1360-1362`). For vertices at corners, create triangular "cap" faces connecting the original vertex to its surrounding edge vertices. The algorithm uses the vertex normal and cross products to determine correct winding order.

The filter temporarily sets `SmoothGroupSeparation = 2.0f` to force hard edges everywhere during normal calculation (`Mesh.cpp:1284-1290`). This ensures the bevel creates crisp facets rather than smoothed transitions.

## Map Transform Filter

**Purpose:** Transform geometry using vertex color as interpolation factor.
**Implementation:** `Mesh.cpp:1262-1279`
**Parameters:** Scale, rotation (quaternion), translation

This filter applies a transformation to each vertex, but scales the transformation amount by that vertex's red channel color value. It's a way to create non-uniform deformations—vertices with `Color[0] = 0` stay put, vertices with `Color[0] = 1` get the full transformation.

The implementation converts the quaternion rotation to an axis-angle representation, then builds a transformation matrix that scales by the color value:

```cpp
float col = Vertices[x].Color[0];
D3DXQUATERNION q;
D3DXQuaternionRotationAxis(&q, &Axis, Angle * col);
D3DXMatrixTransformation(&m, NULL, NULL, &(D3DXVECTOR3(1,1,1) + Scale * col),
                         NULL, &q, &(Translate * col));
D3DXVec3Transform3(&Vertices[x].Position, &Vertices[x].Position, &m);
```

This becomes powerful when combined with `TintMeshShape` to create gradients. For example: tint vertices based on height, then use MapXForm to twist only the top half of a mesh.

## Mesh Smooth Filter (Catmull-Clark Subdivision)

**Purpose:** Subdivide and smooth polygonal meshes.
**Implementation:** `Mesh.cpp:521-644`
**Parameters:** Linear mode flag, iteration count

Subdivision surfaces are the demoscene's answer to the question "how do I get smooth organic shapes from a low-poly mesh?" Catmull-Clark subdivision takes a coarse polygon mesh and refines it into a smoother version with four times as many polygons per iteration.

The algorithm runs three steps per iteration:

**Step 1: Add face centroids** (`Mesh.cpp:531-542`)
For each polygon, average all vertices to find the center, then add that center as a new vertex. This will become the center of the subdivided quads.

**Step 2: Add edge midpoints** (`Mesh.cpp:544-556`)
For each edge, add a vertex at the midpoint. But here's where smooth vs. linear matters. In linear mode, it's just the average of the two endpoints. In smooth mode, it averages the endpoints plus the two adjacent face centroids:

```cpp
if (!Linear && e->PolyIDs[0] != -1 && e->PolyIDs[1] != -1)
  Vertices.Add((Vertices[e->VertexIDs[0]] +
                Vertices[e->VertexIDs[1]] +
                Vertices[e->PolyIDs[0] + OriginalVertexCount] +
                Vertices[e->PolyIDs[1] + OriginalVertexCount]) / 4.0f);
```

**Step 3: Reposition original vertices** (`Mesh.cpp:565-600`)
Original vertices move to weighted averages of their neighbors. The formula is:

```
NewPosition = (R2F + (n-3) * S) / n
```

Where:
- `R2F` is the sum of edge midpoints (R×2) plus face centroids (F)
- `S` is the original vertex position
- `n` is the vertex valence (number of edges)

The implementation accumulates both edge midpoints and face centroids in one loop, relying on the fact that each face is visited twice (once per edge) to automatically get the 2× multiplier for edge midpoints.

**Step 4: Retopologize** (`Mesh.cpp:602-640`)
Replace each n-sided polygon with n quads. Each quad connects: face centroid → edge midpoint → original vertex → next edge midpoint. The code carefully interpolates UV coordinates to maintain texture mapping across subdivision.

Running multiple iterations creates increasingly smooth geometry. Two iterations is often enough for demoscene use—it turns a cube into something organic while keeping vertex count manageable.

## Smooth Group Filter

**Purpose:** Control which edges appear hard vs. smooth.
**Implementation:** `Mesh.h:218`, `Project.cpp:930-931`
**Parameters:** Separation threshold (0-2, where 0 = smooth everything, 2 = hard edges everywhere)

This filter doesn't modify geometry—it controls normal calculation. The `SmoothGroupSeparation` value determines how different two adjacent polygon normals can be before their shared edge is treated as hard.

The value represents `1 - cos(angle)`. A separation of 0 means smooth all edges. A separation of 2 (representing 180°) means every edge is hard. The default is 0, and typical values are:
- 0.0 → All smooth (like a sphere)
- 0.3 → Soft edges only (roughly 72° threshold)
- 1.0 → 90° threshold (cube edges hard, angled surfaces smooth)
- 2.0 → All hard edges

The actual smoothing happens during normal calculation (`CalculateNormals`), which checks this threshold when deciding whether to average normals across edges.

## Tint Mesh Filter

**Purpose:** Sample a texture and store colors in vertex color channels.
**Implementation:** `Mesh.cpp:1121-1197`
**Parameters:** UV channel to sample, texture operator index, saturation boost

This filter bakes texture data into vertex colors, enabling color-driven deformations via MapXForm or NormalDeform. It's useful when you want texture patterns to affect geometry—imagine using a noise texture to determine which vertices get displaced.

The implementation:
1. Saves the texture to DDS format in memory (`D3DX11SaveTextureToMemory`)
2. Parses the DDS header to get dimensions
3. For each polygon vertex, samples the texture at that vertex's UV coordinate
4. Accumulates sampled colors, then averages them per vertex
5. Applies saturation boost: `Color[y] = min(1, Color[y] * (1 + Saturation))`

The averaging is necessary because vertices shared by multiple polygons may have different UVs per polygon (due to UV seams). The filter accumulates all samples and divides by `ColorCount` to get the final vertex color.

## Tint Mesh Shape Filter

**Purpose:** Generate gradient vertex colors based on geometric shapes.
**Implementation:** `Mesh.cpp:1201-1259`
**Parameters:** Shape type, blend operation, power, transform (SRT)

Unlike TintMesh which samples existing textures, TintMeshShape generates gradients procedurally. It's like painting your mesh with invisible gradients that other filters can use for masking or attenuation.

Three shape types are supported:

**Box gradient** (`Mesh.cpp:1220`)
```cpp
val = 1 - max(max(fabs(pos.x), fabs(pos.y)), fabs(pos.z)) * 2.0f;
```
Creates a gradient from center (1.0) to edges (0.0) of a box. Vertices inside the transformed box get high values, vertices outside get negative values.

**Sphere gradient** (`Mesh.cpp:1223`)
```cpp
val = 1 - D3DXVec3Length((D3DXVECTOR3*)&pos) * 2.0f;
```
Distance-based falloff from the sphere center.

**Plane gradient** (`Mesh.cpp:1226`)
```cpp
val = pos.y;
```
Simple linear gradient along the Y axis of the transformed space. Useful for height-based effects.

The transform matrix positions and scales the gradient volume in mesh space. The `power` parameter scales the gradient (`val /= p / 16.0f`), allowing you to control falloff sharpness.

Four blend operations combine new values with existing vertex colors:
- **0 (Set):** Replace — `Color[y] = val`
- **1 (Add):** Accumulate — `Color[y] += val`
- **2 (Subtract):** Remove — `Color[y] -= val`
- **3 (Multiply):** Modulate — `Color[y] *= val`

Values are clamped to [0, 1] after blending.

## Replicate Filter

**Purpose:** Duplicate geometry multiple times with cumulative transformation.
**Implementation:** `Mesh.cpp:2023-2068`
**Parameters:** Copy count, transformation matrix (stored as half-floats)

Replicate is how apEx creates arrays—think columns in a temple, teeth on a gear, or petals on a flower. It copies the entire mesh N times, applying the transformation cumulatively to each copy.

The algorithm is straightforward:

```cpp
D3DXMATRIX transform = Transformation;

// Transform base object
for (int x = 0; x < vxcount; x++) {
  D3DXVec3Transform3(&vx->Position, &vx->Position, &transform);
  D3DXVec3Transform3(&vx->Position2, &vx->Position2, &transform);
}

// Create new copies
for (int z = 0; z < Count; z++) {
  // Copy all vertices, transform by current matrix
  // Copy all polygons, update vertex IDs
  D3DXMatrixMultiply(&transform, &transform, &Transformation);
}
```

The key is `D3DXMatrixMultiply(&transform, &transform, &Transformation)` at the end of each iteration—this makes the transformation cumulative. If Transformation is "rotate 30° around Y", you get copies at 30°, 60°, 90°, etc.

Both `Position` and `Position2` are transformed, maintaining any animation reference frames set by SavePos2.

Common patterns:
- **Circular array:** Rotation matrix around Y-axis
- **Linear array:** Translation matrix along an axis
- **Spiral:** Combined rotation + translation

The transformation matrix is stored as 12 `D3DXFLOAT16` values (3×4 matrix, fourth row is implicit [0,0,0,1]). This saves space in the compressed project file.

## Normal Deform Filter

**Purpose:** Displace vertices along their normals, modulated by vertex color.
**Implementation:** `Mesh.cpp:648-659`
**Parameters:** Displacement factor

This is the simplest displacement filter—move vertices in the direction of their normals. The displacement amount is scaled by the vertex's red channel color value, allowing gradients to control the effect.

```cpp
CalculateNormals();
for (int x = 0; x < Vertices.NumItems(); x++) {
  float col = Vertices[x].Color[0];
  Vertices[x].Position += Vertices[x].Normal * factor * col;
}
```

The filter first recalculates normals to ensure they're current (previous filters may have modified geometry). Then it's a simple per-vertex displacement.

Typical usage pattern:
1. Apply TintMeshShape to create a color gradient
2. Apply NormalDeform to "inflate" the colored regions

For example, using a sphere gradient centered on one side of a mesh will create a bulge. Using a noise texture (via TintMesh) creates organic bumps and dents.

The factor can be negative to create indentations rather than extrusions.

## CSG Filter (Constructive Solid Geometry)

**Purpose:** Boolean operations between two meshes (union, difference, intersection).
**Implementation:** `Mesh.cpp:2230-2730`
**Parameters:** Operation type (0=union, 1=difference, 2=intersection), target mesh index

CSG is how you subtract one shape from another—think drilling holes in geometry or merging objects. The implementation uses BSP trees to classify and clip polygons, a classic algorithm from the 1990s demoscene and game development era.

**Data structures** (`Mesh.cpp:2232-2312`):

```cpp
struct CSGPlane {
  D3DXVECTOR3 normal;
  float w;  // distance from origin
};

struct CSGPoly {
  CphxArray<int> vertexIDs;
  CphxArray<CphxUV> UVs;  // UV coords + vertex normal per vertex
  CSGPlane plane;
};

struct BSPNode {
  BSPNode* nodes[2];      // front and back children
  CSGPlane plane;
  CphxArray<CSGPoly> polys;
};
```

**Algorithm overview:**

**Step 1: Convert meshes to CSG representation** (`Mesh.cpp:2441-2482`)
Both input meshes are converted to `CSGMesh` structures. Quads are triangulated to ensure all polygons are planar. Vertex positions are transformed by the object's transform matrix. Normals are transformed by the inverse-transpose matrix to maintain correctness under non-uniform scaling.

**Step 2: Build BSP trees** (`Mesh.cpp:2493-2514`)
Each mesh gets a BSP tree where each node:
- Stores a splitting plane (taken from the first polygon)
- Stores polygons coplanar with that plane
- Recursively splits remaining polygons into front/back child nodes

The split function (`SplitPoly`, `Mesh.cpp:2316-2433`) classifies each polygon vertex as front, back, or coplanar relative to the plane. If all vertices are on one side, the polygon goes to that child. If the polygon spans the plane, it's clipped by interpolating new vertices at the plane intersection and creating two new polygons.

**Step 3: Perform operation** (`Mesh.cpp:2623-2654`)

**Union** (A ∪ B):
```
A.ClipTo(B)           // Remove parts of A inside B
B.ClipTo(A)           // Remove parts of B inside A
B.Invert()            // Flip B's polygons
B.ClipTo(A)           // Remove parts of B outside A
B.Invert()            // Flip back
Combine A and B
```

**Difference** (A - B):
```
A.Invert()            // Flip A
A.ClipTo(B)           // Keep only parts of A outside B
B.ClipTo(A)           // Remove parts of B outside flipped A
B.Invert()            // Flip B
B.ClipTo(A)           // Remove parts of B outside A
B.Invert()            // Flip back
Combine A and B
A.Invert()            // Flip result back
```

**Intersection** (A ∩ B):
```
A.Invert()
B.ClipTo(A)
B.Invert()
A.ClipTo(B)
B.ClipTo(A)
Combine A and B
A.Invert()
```

**Step 4: Reconstruct mesh** (`Mesh.cpp:2657-2725`)
The resulting CSG polygons are converted back to the engine's mesh format. Vertices from both input meshes are merged. Polygons are triangulated (since CSG can create arbitrary n-gons). UV coordinates and vertex normals are interpolated correctly across clipped edges.

The algorithm uses an epsilon of 0.0001 (`Mesh.cpp:2314`) for floating-point comparisons. This prevents precision issues from creating polygon artifacts.

CSG is expensive—BSP tree construction and polygon clipping involve lots of allocation and recursion. It's typically used sparingly in 64k productions, reserved for specific modeling needs that simpler filters can't achieve.

## Greeble Filter

**Purpose:** Add procedural surface detail through random subdivision and extrusion.
**Implementation:** `Mesh.cpp:2734-2879`
**Parameters:** Random seed, extrusion range, taper amount

Greeble is named after the film industry term for surface detailing on models (think the Death Star surface). It transforms flat or simple geometry into complex mechanical or organic surfaces through randomized operations.

The algorithm runs two passes:

**Pass 1: Random subdivision** (`Mesh.cpp:2794-2815`)

The `Greeble_SplitPoly` function (`Mesh.cpp:2736-2782`) splits a polygon into three pieces:
1. Pick a random edge as the "start"
2. Pick the opposite edge as the "destination"
3. Add vertices at the midpoints of both edges
4. Create two new polygons:
   - Triangle or quad from start midpoint to the intermediate vertex
   - Quad connecting destination back to start
5. Mark the original polygon as "split" using `TouchedByNormalCalculator` flag

The split creates an internal diagonal across the polygon. Running this twice (with the second pass operating on first-pass results) creates a random internal structure.

Here's a conceptual before/after for a quad:

```
Before:              After split:
+-----+              +--+--+
|     |              |\ | /|
|     |      →       | \|/ |
|     |              | /|\ |
+-----+              |/ | \|
                     +--+--+
```

The randomness comes from which edge is chosen and which polygons get split (`if (rand() & 1)`).

After subdivision, only the non-split polygons (the "leaves" of the subdivision tree) are kept. The original polygons that were split are discarded (`Mesh.cpp:2810-2815`).

**Pass 2: Random extrusion** (`Mesh.cpp:2817-2877`)

For each leaf polygon:
1. Calculate random extrusion distance: `dist = (rand() & 0xff) / 255.0f * extrude`
2. Find the polygon's center (average of vertices)
3. Create new vertices by moving original vertices toward/away from center based on taper, then displacing along polygon normal
4. Build connecting "walls" between original and new vertices
5. Replace the original polygon with the displaced version

The taper calculation (`Mesh.cpp:2853`) pulls vertices toward the center before extruding:

```cpp
Vertices.Add((Vertices[oldID] + (center / -1.0f)) / (1.0f / taper) + center);
Vertices[newID].Position += normal * dist;
```

With `taper = 1.0`, vertices don't move toward the center (straight extrusion). With `taper > 1.0`, the extruded face is smaller (tapered extrusion).

The UV coordinate interpolation (`Mesh.cpp:2862-2865`) proportionally adjusts UVs based on how far the vertex moved, preventing texture stretching.

Greeble is one of the most visually impressive filters because it can turn a simple sphere into an asteroid or a cube into a detailed mechanical component with just three parameters. The randomness is seeded, so the same seed always produces the same result—important for deterministic demo playback.

## Invert Filter

**Purpose:** Reverse polygon winding order to flip normals.
**Implementation:** `Mesh.cpp:2882-2894`
**Parameters:** None

Sometimes you need to turn geometry inside-out—perhaps you're creating a skybox and want to see the inside faces, or you've just performed a CSG operation that left some polygons facing the wrong way.

The implementation simply reverses the vertex ID array for each polygon:

```cpp
for (int x = 0; x < Polygons.NumItems(); x++) {
  for (int y = 0; y < Polygons[x].VertexCount; y++) {
    auto& p = Polygons[x];
    int n1 = p.VertexIDs[y];
    p.VertexIDs[y] = p.VertexIDs[p.VertexCount - y - 1];
    p.VertexIDs[p.VertexCount - y - 1] = n1;
  }
}
```

This swaps the winding order from clockwise to counter-clockwise (or vice versa), which flips the polygon normal direction due to the right-hand rule. Backface culling will now cull the opposite side of the geometry.

Note that this doesn't modify the `Normals` array stored per vertex per polygon—those will be recalculated when the mesh is next used. The inversion only affects topology.

## SavePos2 Filter

**Purpose:** Snapshot current vertex positions into the `Position2` field.
**Implementation:** `Mesh.cpp:2898-2903`
**Parameters:** None

This is apEx's animation reference system. Every vertex has two positions: `Position` (current position) and `Position2` (reference position). By saving a snapshot at a specific point in the filter stack, you can create morph-like effects.

```cpp
void CphxMesh::SavePos2() {
  for (int x = 0; x < Vertices.NumItems(); x++)
    Vertices[x].Position2 = Vertices[x].Position;
}
```

The primary use case is tree leaves. The tree generation algorithm creates leaves in "wind blowing" positions, but you want them to animate. The filter stack looks like:

1. Create tree mesh (branches + leaves)
2. **SavePos2** — Store "neutral" positions
3. Deform leaves (via NormalDeform or other filters)
4. Final positions are in `Position`, original positions in `Position2`

At runtime, the shader interpolates between `Position2` and `Position` based on a time-varying parameter, creating wind animation.

Other uses include:
- Procedural animation of mechanical parts
- Soft-body simulation starting states
- GPU particle systems where `Position2` stores velocity

The filter is extremely cheap (just a memory copy) but enables powerful runtime effects.

## Filter Stack Execution

In `Project.cpp:907-976`, the filter application loop looks like:

```cpp
for (int z = 0; z < m->FilterCount; z++) {
  unsigned char* filterparams = m->FilterData[z].FilterParams;
  D3DXFLOAT16* filtertransform = m->FilterData[z].filtertransform;

  switch (m->FilterData[z].Type) {
    case ModelFilter_UVMap:
      m->Mesh.CalculateTextureCoordinates(
        (PHXTEXTUREMAPTYPE)filterparams[0],
        filterparams[1] & 0x0f,
        (filterparams[1] & 0xf0) != 0,
        D3DXVECTOR3(filtertransform) + one,
        D3DXQUATERNION(filtertransform + 3),
        D3DXVECTOR3(filtertransform + 7)
      );
      break;
    case ModelFilter_Bevel:
      m->Mesh.Bevel(filterparams[0] / 255.0f);
      break;
    // ... etc
  }
}
```

Parameters are stored as byte arrays, with transforms as half-precision floats (2 bytes per component). This compression is critical for 64k size limits—a full transform matrix in floats would be 48 bytes, but as half-floats it's 24 bytes.

## Framework Implications

apEx's filter stack offers several lessons for creative coding frameworks:

**Composability over specialization**
Rather than building a "create detailed asteroid" function, apEx combines: GeoSphere → Greeble → NormalDeform (with noise tint). The primitives and filters are generic, but their combinations are expressive.

**Separation of concerns**
UV mapping is a filter, not built into primitives. This means any primitive can use any UV projection, and UV generation can happen before or after geometric modifications.

**Stateful vertex data**
Vertices carry not just position but color channels, dual positions, normals. Filters use and modify this rich state, enabling filters to communicate through vertex attributes rather than external parameters.

**Deterministic randomness**
Filters like Greeble and Scatter use explicit seeds. This ensures the same model definition always generates the same mesh, crucial for demos that must play back identically.

**CPU-side processing**
All filters run on the CPU before upload to GPU. This contrasts with modern approaches that might use compute shaders for subdivision or displacement. The tradeoff: more flexible (can do CSG, complex topology changes) but potentially slower for very dense meshes.

**Size-conscious parameter encoding**
Half-float transforms, byte-packed parameters, and bit-packed flags squeeze every filter into minimal bytes. A Bevel filter is 1 byte enum + 1 byte parameter = 2 bytes in the project file.

A modern framework might implement this as a trait-based system in Rust:

```rust
trait MeshFilter {
    fn apply(&self, mesh: &mut Mesh) -> Result<()>;
}

struct FilterStack {
    filters: Vec<Box<dyn MeshFilter>>,
}

impl FilterStack {
    fn execute(&self, mesh: &mut Mesh) -> Result<()> {
        for filter in &self.filters {
            filter.apply(mesh)?;
        }
        Ok(())
    }
}
```

The key insight is that filters are pure transformations—they read mesh state, compute new state, and write it back. This functional approach makes filter stacks easy to reason about, debug, and extend.
