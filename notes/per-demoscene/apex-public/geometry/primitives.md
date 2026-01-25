# Mesh Primitives in apEx

When you need to generate a sphere, extrude a shape along a path, or scatter hundreds of objects across a surface, you're working with procedural geometry. Most creative coding frameworks provide basic primitives like cubes and cylinders, but demoscene tools need more: parametric surfaces that tessellate efficiently, spline-based path extrusion, fractal tree generation, and metaball-style isosurface extraction. All of this geometry must be generated at runtime, stored compactly, and rendered without sacrificing visual quality.

apEx addresses this through a unified mesh primitive system. Twenty primitive types cover everything from basic shapes to complex procedural generators. Each primitive type is a pure function: given a small parameter array (0-14 bytes), it generates vertices and polygons procedurally. No external mesh files. No baked data. Just algorithms that reconstruct geometry on demand. This approach minimizes executable size while giving artists control over tessellation density, surface detail, and topological variation.

The key insight is that most 3D geometry follows predictable mathematical patterns. A sphere is just subdivided UV coordinates mapped to a radius. A loft is a cross-section swept along a path with Frenet frame orientation. A tree is recursive branching governed by Weber/Penn parameters. By encoding these patterns as parameterized generators rather than storing vertex buffers, apEx achieves extreme size efficiency. A 12-parameter array generates a complete procedural tree with thousands of vertices. That's the difference between kilobytes and bytes.

Think of mesh primitives like procedural shaders for geometry. Instead of writing pixel colors, they write vertex positions. The primitive type is the shader program. The parameter array is the uniform buffer. The mesh output is the framebuffer. This mental model explains why primitives are stateless: they're pure functions with no side effects beyond mesh construction. You can regenerate the same mesh deterministically by replaying the same primitive type with the same parameters.

## System Architecture

The mesh primitive system lives in `demoscene/apex-public/apEx/Phoenix/Mesh.h` and `Mesh.cpp`. Every primitive type is defined as an enum value (`PHXMESHPRIMITIVE`) and implemented as a method on the `CphxMesh` class. The enum values map directly to generator functions through a switch statement in the project loading code.

### Primitive Enum

`demoscene/apex-public/apEx/Phoenix/Mesh.h:15-75` defines 20 primitive types as compile-time constants. Each primitive is wrapped in a feature flag (`#ifdef PHX_MESH_CUBE`) so the minimal 64k build can strip unused generators. The conditional compilation means a demo that only uses cubes and spheres doesn't pay code size for tree generation or marching tetrahedra.

```cpp
enum PHXMESHPRIMITIVE {
  Mesh_Cube = 0,       // Unit cube (8 vertices, 6 quads)
  Mesh_Plane,          // Subdivided plane grid
  Mesh_Sphere,         // UV sphere with optional caps
  Mesh_Cylinder,       // Cylindrical surface with caps
  Mesh_Cone,           // Conical surface with base cap
  Mesh_Arc,            // Partial circular arc (polyline)
  Mesh_Line,           // Straight line segment (polyline)
  Mesh_Spline,         // Cubic Bezier spline curve
  Mesh_Loft,           // Cross-section extruded along path
  Mesh_Clone,          // Reference copy (instancing)
  Mesh_Copy,           // Deep copy with transform
  Mesh_GeoSphere,      // Geodesic sphere (subdivided icosahedron)
  Mesh_Scatter,        // Object distribution on surface
  Mesh_Stored,         // Pre-built mesh asset reference
  Mesh_Tree,           // Procedural tree branches (Weber/Penn)
  Mesh_TreeLeaves,     // Billboard leaves for trees
  Mesh_Text,           // Extruded text geometry from fonts
  Mesh_Marched,        // Isosurface from metaballs (marching tetrahedra)
  Mesh_StoredMini,     // Compressed mesh storage
  Mesh_Merge           // Combine multiple meshes
};
```

Each primitive has an associated parameter count defined in `demoscene/apex-public/apEx/apEx/MinimalExport.cpp:169-191`. This array maps primitive enum values to byte counts, allowing the serialization system to pack parameter data efficiently. Primitives with zero parameters (Cube, Clone, Copy, Stored, Marched, StoredMini, Merge) generate geometry based on context or references to other objects rather than direct parameters.

### Parameter Storage

Parameters are stored as `unsigned char[14]` arrays. The maximum parameter count across all primitives is 14 bytes (Scatter primitive). This fixed-size allocation simplifies serialization and allows stack allocation in the minimal build. Parameter interpretation is type-specific: some treat bytes as integers, others pack floats as `D3DXFLOAT16` half-precision values, and some reference external data structures.

### Mesh Data Structure

All primitives output geometry to a `CphxMesh` object. The mesh class maintains three core arrays:

- `CphxArray<CphxVertex> Vertices` — Vertex positions, normals, colors, UV coordinates
- `CphxArray<CphxPolygon> Polygons` — Triangles or quads with vertex indices
- `CphxArray<CphxEdge> Edges` — Edge topology for filters like bevel

Primitives call `AddVertex(x, y, z)` to append vertices and `AddPolygon(a, b, c)` or `AddPolygon(a, b, c, d)` to define triangle/quad topology. The mesh automatically calculates normals, builds edge lists, and applies texture coordinate mapping based on primitive type.

## Basic Shape Primitives

The foundation primitives generate simple geometric shapes with controllable tessellation. These are the building blocks most demos start with.

### Cube

**Primitive ID**: `Mesh_Cube = 0`
**Parameters**: None (0 bytes)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:685-700`

Generates a unit cube centered at origin with extent -0.5 to +0.5 on all axes. The cube has 8 vertices and 6 quad faces. Vertices are defined in a static lookup table (`CubeVertexData`) and polygons reference vertex indices via `CubePolyData`. The primitive applies box mapping to all four UV channels automatically.

```cpp
void CphxMesh::CreateCube() {
  for (int x = 0; x < 8; x++)
    AddVertex(CubeVertexData + x * 3);

  char *data = (char*)CubePolyData;
  for (int y = 0; y < 6; y++) {
    AddPolygon(data[3], data[2], data[1], data[0]);
    data += 4;
  }

  for (int x = 0; x < 4; x++)
    CalculateTextureCoordinates(flareTextureMap_Box, x);
}
```

The cube is the only primitive with no subdivision parameters. For subdivided cubes, artists apply a mesh filter after generation.

### Plane

**Primitive ID**: `Mesh_Plane = 1`
**Parameters**: 2 bytes
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:752-768`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| XRes | 0 | 1-255 | Horizontal subdivision count |
| YRes | 1 | 1-255 | Vertical subdivision count |

Generates a flat plane on the XZ axis (Y=0) with extent -0.5 to +0.5. The plane is subdivided into `XRes * YRes` quads. Vertex positions are computed as `(x/XRes - 0.5, 0, y/YRes - 0.5)`, creating a regular grid. Higher resolution values produce finer tessellation for displacement mapping or smooth deformation.

The implementation creates `(XRes+1) * (YRes+1)` vertices because a grid of N quads requires N+1 vertices per axis. Planar UV mapping is applied automatically.

```cpp
void CphxMesh::CreatePlane(int XRes, int YRes) {
  for (int y = 0; y <= YRes; y++)
    for (int x = 0; x <= XRes; x++)
      AddVertex(x / (float)XRes - 0.5f, 0, y / (float)YRes - 0.5f);

  for (int y = 0; y < YRes; y++)
    for (int x = 0; x < XRes; x++)
      AddPolygon(x + (y+1)*(XRes+1), x+1 + (y+1)*(XRes+1),
                 x+1 + y*(XRes+1), x + y*(XRes+1));
}
```

### Sphere

**Primitive ID**: `Mesh_Sphere = 2`
**Parameters**: 5 bytes
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:730-749`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| XRes | 0 | 3-255 | Horizontal segments (longitude) |
| YRes | 1 | 2-255 | Vertical rings (latitude) |
| TopCut | 2 | 0-255 | Top clipping (0=bottom, 255=top) |
| BottomCut | 3 | 0-255 | Bottom clipping (0=bottom, 255=top) |
| Caps | 4 | 0-1 | Generate end caps (boolean) |

Generates a UV sphere using spherical coordinates. The surface is parameterized as:
- `theta = lerp(BottomCut/255, TopCut/255, y/YRes) * π - π/2` (latitude)
- `phi = x/XRes * 2π` (longitude)
- Position: `(cos(theta)*sin(phi)*0.5, sin(theta)*0.5, cos(theta)*cos(phi)*0.5)`

TopCut and BottomCut allow partial spheres (hemispheres, sphere slices). When cuts are active, the primitive can generate cap polygons to close the geometry. The implementation reuses cylindrical topology code (`AddCapsBuildCylindricalTopologyAndCalculateUV`) with spherical UV mapping.

This approach is more efficient than geodesic subdivision for high-resolution smooth spheres, as it generates exactly the requested vertex count without iterative refinement.

### Cylinder

**Primitive ID**: `Mesh_Cylinder = 3`
**Parameters**: 3 bytes
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:791-803`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| XRes | 0 | 3-255 | Radial segments |
| YRes | 1 | 1-255 | Height divisions |
| Caps | 2 | 0-1 | Generate top/bottom caps |

Generates a cylinder with radius 0.5 and height 1.0 (Y from -0.5 to 0.5). Vertices are placed at `(sin(t)*0.5, y/YRes - 0.5, cos(t)*0.5)` where `t = x/XRes * 2π`. The body consists of `XRes * YRes` quads wrapping around the Y axis.

When caps are enabled, the generator adds center vertices at Y=-0.5 and Y=0.5, then creates triangular fan polygons connecting perimeter vertices to the centers. Cylindrical UV mapping is applied to the body, and planar mapping to the caps.

### Cone

**Primitive ID**: `Mesh_Cone = 4`
**Parameters**: 4 bytes
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:771-788`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| XRes | 0 | 3-255 | Radial segments |
| YRes | 1 | 1-255 | Height divisions |
| TopCut | 2 | 0-255 | Height fraction (0=point, 255=flat top) |
| Caps | 3 | 0-1 | Generate bottom cap |

Similar to cylinder but with linearly decreasing radius from base (Y=-0.5, radius=0.5) to apex. The radius at height `h` is `r = 1 - h`, where `h = y/YRes * TopCut/255`. TopCut allows truncated cones: at TopCut=255, the cone becomes a cylinder.

The generator handles the degenerate apex case by omitting the top cap unless TopCut is less than 255. This avoids creating a cap polygon with zero area at the apex point.

### Arc

**Primitive ID**: `Mesh_Arc = 5`
**Parameters**: 3 bytes
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:833-865`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| Res | 0 | 2-255 | Segment count |
| Degree | 1 | 0-255 | Arc angle (fraction of 2π) |
| HaveLastSegment | 2 | 0-1 | Include final vertex |

Generates a circular arc polyline (series of connected line segments). Vertices lie on a circle of radius 0.5 in the XZ plane. The arc spans an angle of `Degree/255 * 2π` radians. `HaveLastSegment` controls whether the arc is open (Res vertices) or closed (Res+1 vertices).

The primitive stores start and end tangent directions in `ArcStartDir` and `ArcEndDir` for use by the Loft primitive. This allows smooth extrusion along arc paths without tangent discontinuities.

Arcs are rendered as degenerate quads (duplicate vertex indices) for tool visualization. The actual geometry is a polyline, not a surface.

### Line

**Primitive ID**: `Mesh_Line = 6`
**Parameters**: 1 byte
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:805-830`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| Res | 0 | 2-255 | Vertex count |

Generates a straight line segment from (0,0,-0.5) to (0,0,0.5) with `Res` evenly spaced vertices. Like Arc, this is a polyline primitive rendered as degenerate quads for visualization. Lines are primarily used as path inputs for the Loft primitive.

## Spline and Loft Primitives

These primitives create curves and surfaces by interpolation and extrusion. They're essential for organic shapes, ribbons, and cable geometry.

### Spline

**Primitive ID**: `Mesh_Spline = 7`
**Parameters**: 2 bytes (plus external key data)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:869-902`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| KeyCount | 0 | 2-255 | Number of control points |
| Resolution | 1 | 1-255 | Segments between keys |
| Loop | 2 | 0-1 | Close the spline |

Splines are cubic Bezier curves defined by key points with tangent handles. Each key is a `CphxMeshSplineKey` structure containing:
- `vx[3]` — Key position (D3DXFLOAT16 half-precision)
- `Front[3]` — Forward tangent direction
- `Back[3]` — Backward tangent direction

The spline interpolates between keys using the Bezier formula:
```cpp
P(t) = (1-t)³·P₀ + 3(1-t)²t·P₁ + 3(1-t)t²·P₂ + t³·P₃
```

Where P₀ is the current key position, P₁ = P₀ + Front, P₃ is the next key, and P₂ = P₃ + Back. This gives C1 continuity (continuous tangents) between segments.

The generator produces `KeyCount * Resolution` vertices (plus one if not looped). Each segment between keys is subdivided into `Resolution` linear steps. The implementation stores start and end tangent directions for Loft integration.

```cpp
for (int x = 0; x < KeyCnt; x++) {
  D3DXVECTOR3 k[4];
  k[0] = Keys[x].vx;
  k[1] = k[0] + D3DXVECTOR3(Keys[x].Front);
  k[3] = D3DXVECTOR3(Keys[(x+1) % KeyCount].vx);
  k[2] = k[3] + D3DXVECTOR3(Keys[(x+1) % KeyCount].Back);

  for (int y = 0; y < Resolution; y++)
    AddVertex(bezier(k[0], k[1], k[2], k[3], y / (float)Resolution));
}
```

### Loft

**Primitive ID**: `Mesh_Loft = 8`
**Parameters**: 7 bytes (plus mesh references)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:906-977`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| Path mesh ref | 0-1 | — | Index to path spline/arc/line |
| Slice mesh ref | 2-3 | — | Index to cross-section shape |
| PathClosed | 4 | 0-1 | Is path a loop? |
| SliceClosed | 5 | 0-1 | Is slice a loop? |
| Rotation | 6 | 0-255 | Twist along path (in revolutions) |
| StartScale | 7 | 0-255 | Scale at path start |
| EndScale | 8 | 0-255 | Scale at path end |

Loft sweeps a 2D cross-section (slice) along a 3D path to create a surface. This is how cables, ribbons, tentacles, and extruded shapes are generated. The core challenge is orienting the cross-section perpendicular to the path while avoiding twist discontinuities.

The algorithm uses a Frenet frame to orient the slice at each path vertex:
1. Compute path tangent: `dir = normalize(next_vertex - prev_vertex)`
2. Compute normal: `nx = normalize(cross(up, dir))`
3. Recompute binormal: `up = cross(nx, dir)`

The "up" vector starts as (0,1,0) and is iteratively rotated to follow the path. The implementation runs this calculation 101 times to stabilize the up vector orientation before generating geometry. This prevents the frame from flipping abruptly on curved paths.

```cpp
D3DXVECTOR3 nx, dir, up = yvector;

for (int z = 0; z < 101; z++) {  // Stabilization iterations
  for (int x = 0; x < PathVxCount; x++) {
    // Compute tangent from surrounding vertices
    dir = normalize(path[x+1] - path[x-1]);

    // Build orthonormal frame
    nx = normalize(cross(up, dir));
    up = -cross(nx, dir);

    if (z == 100) {  // Final iteration: generate vertices
      for (int y = 0; y < SliceVxCount; y++) {
        D3DXVECTOR3 v = slice[y].Position;
        float scale = lerp(StartScale, EndScale, x / PathVxCount);
        AddVertex((nx*v.x + up*v.z) * scale + path[x]);
      }
    }
  }
}
```

The rotation parameter twists the slice around the path axis. StartScale and EndScale allow tapering effects. The combination of loft with spline paths and shape primitives as slices gives artists extensive control over complex 3D forms.

## Geodesic Sphere

**Primitive ID**: `Mesh_GeoSphere = 11`
**Parameters**: 2 bytes
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:1439-1478`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| Iterations | 0 | 0-5 | Subdivision depth |

While UV spheres are efficient for high-resolution smooth spheres, geodesic spheres produce more uniform triangle distribution. The algorithm starts with a regular icosahedron (12 vertices, 20 equilateral triangles) and iteratively subdivides each triangle into 4 smaller triangles, projecting new vertices onto the sphere surface.

**Algorithm**:
1. Create icosahedron from lookup tables (`IcosaVertexData`, `IcosaPolyData`)
2. For each iteration:
   - Build edge list for current mesh
   - For each edge, create midpoint vertex: `v = normalize(v1 + v2) / 2`
   - Split each triangle into 4: corners + 3 midpoints
   - Replace original triangles with subdivided versions

The vertex count grows as `12 * 4^iterations`. At 5 iterations, the sphere has 20,480 triangles. Geodesic spheres are preferred over UV spheres when triangle uniformity matters (e.g., for physics simulations or when applying subdivision surfaces).

```cpp
void CphxMesh::CreateGeoSphere(int Iterations) {
  // Start with icosahedron
  for (int x = 0; x < 12; x++)
    AddVertex(IcosaVertexData + x * 3);
  for (int y = 0; y < 20; y++)
    AddPolygon(IcosaPolyData[y*3], IcosaPolyData[y*3+1], IcosaPolyData[y*3+2]);

  // Refine by subdivision
  for (int i = 0; i < Iterations; i++) {
    RebuildEdgeList();
    int originalVxCount = Vertices.NumItems();

    // Create edge midpoints
    for (int x = 0; x < Edges.NumItems(); x++) {
      D3DXVECTOR3 v = Vertices[Edges[x].VertexIDs[0]].Position +
                      Vertices[Edges[x].VertexIDs[1]].Position;
      D3DXVec3Normalize(&v, &v);
      AddVertex(v / 2.0f);
    }

    // Split triangles
    for (int z = Polygons.NumItems() - 1; z >= 0; z--) {
      for (int x = 0; x < 3; x++)
        AddPolygon(Polygons[z].VertexIDs[x],
                   originalVxCount + Polygons[z].EdgeIDs[x],
                   originalVxCount + Polygons[z].EdgeIDs[(x+2)%3]);
      Polygons[z].VertexIDs[x] = originalVxCount + Polygons[z].EdgeIDs[x];
    }
  }
}
```

## Scatter Primitive

**Primitive ID**: `Mesh_Scatter = 12`
**Parameters**: 14 bytes (plus mesh references)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:1551-1689`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| Object mesh ref | 0-1 | — | Mesh to scatter |
| Shape mesh ref | 2-3 | — | Distribution surface |
| RandSeed | 4 | 0-255 | Random seed |
| VertexProbability | 5 | 0-255 | Instance at vertices (0-100%) |
| EdgeProbability | 6 | 0-255 | Instance at edge centers |
| PolyProbability | 7 | 0-255 | Instance at polygon centers |
| MaxPerPoly | 8 | 0-255 | Max instances per polygon |
| ProbabilityTint | 9 | 0-3 | Vertex color channel for density |
| Orientation | 10 | 0-3 | Alignment mode (enum) |
| ScaleThreshold | 11 | 0-255 | Random scale variation |
| ForceYScale | 12 | 0-1 | Only scale Y axis |
| OffsetThreshold | 13 | 0-255 | Normal offset variation |
| ScaleOffsetTint | 14 | 0-3 | Vertex color channel for offset |

Scatter distributes copies of an object across the surface of a shape mesh. This is used for grass, debris fields, asteroid belts, crowds, and any scenario requiring many small objects distributed over a larger surface. The primitive supports three distribution modes: vertex placement, edge midpoint placement, and polygon centroid placement.

**Orientation modes** control how scattered instances are aligned:
- `flareScatterOrientation_Original` — No rotation (world-aligned)
- `flareScatterOrientation_Normal` — Align Y-axis to surface normal
- `flareScatterOrientation_NormalRotate` — Align to normal + random Y rotation
- `flareScatterOrientation_FullRotate` — Align to normal + random axis rotation

The implementation builds an orientation matrix using the surface normal and a computed "up" vector perpendicular to it. Random scale and offset are applied based on threshold parameters modulated by vertex color channels. This allows artists to paint density masks directly onto the shape mesh.

```cpp
void CphxMesh::Scatter(CphxMesh *Object, CphxMesh *Shape,
                       unsigned char RandSeed, float VertexProbability, ...) {
  Shape->CalculateNormals();
  srand(RandSeed);

  // Vertex scattering
  for (int x = 0; x < Shape->Vertices.NumItems(); x++) {
    CphxVertex *vx = &Shape->Vertices[x];
    float density = 1 - vx->Color[ProbabilityTint];

    if (rand() / (float)RAND_MAX < VertexProbability * density) {
      D3DXMATRIX transform = GetScatterTransformation(
        Orientation, vx->Position, vx->Normal, yvector,
        ScaleThreshold, OffsetThreshold, ...
      );
      CopyInstance(Object, &transform);
    }
  }

  // Similar loops for edges and polygons...
}
```

The probability parameters are 0-255 values interpreted as percentages. Vertex colors act as masks: darker areas (channel value near 0) get higher density, lighter areas get lower density. This gives fine control over distribution without requiring separate density maps.

## Tree Primitives

The tree generator implements the Weber/Penn algorithm from the 1995 paper "Creation and Rendering of Realistic Trees". This is a parametric model of botanical growth that produces remarkably organic-looking trees from a small set of parameters.

### Tree (Branches)

**Primitive ID**: `Mesh_Tree = 14`
**Parameters**: 6 bytes (plus species descriptor)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:1762-1772`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| Seed | 0 | 0-255 | Random seed |
| Level0Density | 1 | 0-255 | Trunk branch count |
| Level1Density | 2 | 0-255 | Primary branch count |
| Level2Density | 3 | 0-255 | Secondary branch count |
| Level3Density | 4 | 0-255 | Tertiary branch count |
| Species ref | 5 | — | Index to TREESPECIESDESCRIPTOR |

The tree primitive generates cylindrical branch geometry with tapered thickness, curved growth, and recursive splitting. A `TREESPECIESDESCRIPTOR` (defined in `demoscene/apex-public/apEx/Phoenix/Arbaro.h:90-94`) contains 93 parameters controlling:

- **Global shape**: Conical, spherical, hemispherical, cylindrical, flame
- **Growth parameters**: Levels, base size, ratio, ratio power, attraction up
- **Per-level parameters** (4 levels: trunk, primary, secondary, tertiary):
  - Branch count, length, taper, curve, curve variation
  - Split angle, rotate angle, down angle (all with variation)
  - Segment count, segment splits

The algorithm recursively generates stems starting from the trunk. Each stem subdivides into segments, and each segment can spawn child stems or leaves based on level-specific parameters. Branch thickness is computed from parent thickness scaled by the `ratio` parameter raised to the `ratioPower`.

**Branch orientation** uses the `downAngle` parameter to bend branches away from the parent axis, `rotate` to spiral them around the trunk, and `curve` to add gradual bending along the stem length. The `curveBack` parameter allows S-curve shapes.

The primitive outputs branch geometry as cylindrical segments and stores branch transform data in a GPU buffer for shader-based wind animation. Each branch is represented as a `BranchData` structure:

```cpp
struct BranchData {
  D3DXMATRIX Rotation;    // Branch orientation
  D3DXVECTOR3 Position;   // Base position
  int parentIndex;        // Parent branch for hierarchy
  float parentPosition;   // Attachment point on parent
  float baseThickness;    // Branch radius at base
  float endThickness;     // Branch radius at tip
};
```

This data allows vertex shaders to animate branches with wind forces propagated through the hierarchy.

### TreeLeaves (Foliage)

**Primitive ID**: `Mesh_TreeLeaves = 15`
**Parameters**: 7 bytes
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:1776-1782`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| (Same as Tree) | 0-5 | — | — |
| LeafShape | 6 | 0-255 | Leaf geometry type |

TreeLeaves generates billboard quads for tree foliage. Each leaf is a quad oriented to face the camera (billboarding is handled in the vertex shader). The primitive uses the same species descriptor as Tree but only generates leaf geometry, not branches.

Leaves are distributed based on the species `LeafDistrib` parameter (conical, spherical, etc.) and the per-level leaf counts. The `LeafScale`, `LeafScaleX`, and `LeafStemLen` parameters control leaf dimensions and stem attachment.

Crucially, leaf vertices store the branch attachment point in the `Position2` field. This allows the vertex shader to rotate leaves with their parent branches during wind animation. The shader reads branch transform data from the GPU buffer and applies hierarchical animation.

```cpp
void LeafImpl::BuildMesh(int branchIdx, CphxMesh *mesh, ...) {
  // Create billboard quad
  mesh->AddVertex(leafTransform.apply(D3DXVECTOR3(-scale, 0, 0)));
  mesh->AddVertex(leafTransform.apply(D3DXVECTOR3( scale, 0, 0)));
  mesh->AddVertex(leafTransform.apply(D3DXVECTOR3( scale, scale*2, 0)));
  mesh->AddVertex(leafTransform.apply(D3DXVECTOR3(-scale, scale*2, 0)));

  // Store branch attachment point in Position2
  for (int i = 0; i < 4; i++)
    mesh->Vertices[vxStart+i].Position2 = branchPosition;

  mesh->AddPolygon(vxStart, vxStart+1, vxStart+2, vxStart+3);
}
```

The combination of Tree and TreeLeaves primitives allows artists to control branch and foliage density independently, crucial for level-of-detail systems where distant trees show only branches and nearby trees show full foliage.

## Text Primitive

**Primitive ID**: `Mesh_Text = 16`
**Parameters**: 2 bytes (plus string data)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:1870-1950`

| Parameter | Byte Index | Range | Effect |
|-----------|------------|-------|--------|
| Font | 0 | 0-255 | Font index from engine font list |
| Deviation | 1 | 0-255 | Bezier curve subdivision threshold |
| Text | — | — | String data (external) |

Text generates 2D polygon outlines from TrueType fonts using Windows GDI. The primitive calls `GetGlyphOutline` to retrieve font contours as Bezier curves, then tessellates them into line segments based on the `Deviation` parameter (smaller values produce smoother curves but more vertices).

The algorithm uses recursive Bezier subdivision:
1. Evaluate Bezier curve at midpoint
2. Measure deviation of midpoint from straight line between endpoints
3. If deviation exceeds threshold, split curve and recurse on both halves
4. Otherwise, output line segment

```cpp
void CphxMesh::BInterp(D3DXVECTOR3 *pPoints, int *nPoints,
                       D3DXVECTOR2 p1, D3DXVECTOR2 p2, D3DXVECTOR2 p3,
                       float fDeviation) {
  D3DXVECTOR2 mid = bezier2D(p1, p2, p3, 0.5f);
  D3DXVECTOR2 line_mid = (p1 + p3) / 2.0f;

  if (length(mid - line_mid) > fDeviation) {
    // Subdivide
    BInterp(pPoints, nPoints, p1, bezier2D(p1,p2,p3,0.25f), mid, fDeviation);
    BInterp(pPoints, nPoints, mid, bezier2D(p1,p2,p3,0.75f), p3, fDeviation);
  } else {
    // Emit vertex
    pPoints[*nPoints] = D3DXVECTOR3(p3.x, p3.y, 0);
    (*nPoints)++;
  }
}
```

The resulting mesh is a 2D planar outline suitable for extrusion (via Loft primitive) or direct rendering as flat text. This is commonly used for title screens, credits, and on-screen text in demos.

## Marching Tetrahedra

**Primitive ID**: `Mesh_Marched = 17`
**Parameters**: None (uses external object data)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:2073-2226`

The marching tetrahedra algorithm generates isosurfaces from implicit functions. While the primitive has no direct parameters (object positions and field types come from external data), the implementation accepts:
- Grid dimensions (3D bounding box)
- Resolution (grid density: 8-64 typical)
- Surface threshold (isovalue for surface extraction)
- Object list (positions and types for field evaluation)

**Why tetrahedra instead of cubes?** Marching cubes has 256 cases due to ambiguous cube configurations. Marching tetrahedra decomposes each cube into 6 tetrahedra, reducing cases to 16 with no ambiguities. This simplifies the lookup tables and produces consistent triangulation.

**Algorithm**:
1. Divide 3D space into a grid of `resolution³` points
2. Evaluate scalar field at each point: `field[i] = Σ(1/distance_to_object_j)`
3. Mark points as inside (field > threshold) or outside (field < threshold)
4. For each cube in the grid, decompose into 6 tetrahedra
5. For each tetrahedron, use vertex inside/outside states to index a lookup table
6. Generate triangle vertices by interpolating along tetrahedron edges where inside/outside transitions occur

The field evaluation uses a sum-of-inverses: metaballs placed at object positions contribute `1/d` to the field strength. This creates organic blobby surfaces that merge smoothly when objects are close.

```cpp
void CphxMesh::CreateMarchingMesh(D3DXVECTOR3 dimensions, int objCount,
                                  char *objType, D3DXMATRIX *objPositions,
                                  float surface, char resolution) {
  GRIDPOINT* Grid = new GRIDPOINT[resolution * resolution * resolution];

  // Sample field
  for (int i = 0; i < gridSize; i++) {
    Grid[i].Pos = /* grid position */;
    Grid[i].Value = 0;
    for (int j = 0; j < objCount; j++) {
      D3DXVECTOR3 toObject = transform(Grid[i].Pos, objPositions[j]);
      Grid[i].Value += 1 / length(toObject);
    }
    Grid[i].Inside = (Grid[i].Value < surface);
  }

  // Generate triangles
  for each cube:
    for each of 6 tetrahedra in cube:
      char map = (v0.Inside<<3) + (v1.Inside<<2) + (v2.Inside<<1) + v3.Inside;
      // Use TetraMap[map] to determine triangle vertices
      // Interpolate positions along edges where inside/outside transitions occur
      AddPolygon(interpolated vertices);
}
```

The primitive computes normals from the gradient of the scalar field: `∇field ≈ (field[x+1] - field[x-1], field[y+1] - field[y-1], field[z+1] - field[z-1])`. This gives smooth shading without explicit normal calculation.

Marched meshes are used for organic shapes, liquid effects, and soft-body objects that would be difficult to model with traditional primitives.

## Instancing and Storage Primitives

These primitives reference existing mesh data rather than generating new geometry procedurally.

### Clone

**Primitive ID**: `Mesh_Clone = 9`
**Parameters**: None

Clone creates a reference copy of another mesh. The cloned mesh shares vertex and polygon data with the original but has an independent transformation matrix. This is pure instancing: modifying the original mesh updates all clones. Clone is used for repeated geometry like building windows, fence posts, or particle systems where thousands of identical objects appear with different transforms.

### Copy

**Primitive ID**: `Mesh_Copy = 10`
**Parameters**: None
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:980-985`

Copy creates a deep copy of another mesh, optionally transformed. Unlike Clone, the copied geometry is independent. Modifying the original does not affect copies. This is useful when a mesh needs to be modified per-instance (e.g., applying unique deformations or colors).

```cpp
void CphxMesh::Copy(CphxMesh *a) {
  D3DXMATRIX m;
  CopyInstance(a, D3DXMatrixIdentity(&m));
}
```

The implementation calls `CopyInstance`, which iterates over source vertices/polygons and appends transformed copies to the current mesh.

### Merge

**Primitive ID**: `Mesh_Merge = 19`
**Parameters**: None (uses external object list)
**Implementation**: `demoscene/apex-public/apEx/Phoenix/Mesh.cpp:988-993`

Merge combines multiple mesh objects into a single mesh. This is used to reduce draw calls by batching static geometry. The primitive receives a list of `CphxModelObject_Mesh` references and their world transforms, then copies all geometry into one unified mesh.

```cpp
void CphxMesh::Merge(CphxModelObject_Mesh** objects, int count) {
  for (int x = 0; x < count; x++)
    CopyInstance(&objects[x]->Mesh, &objects[x]->GetMatrix());
}
```

After merging, the combined mesh can be rendered with a single draw call instead of one per object. This optimization is crucial for hitting 60fps in complex scenes.

### Stored and StoredMini

**Primitive ID**: `Mesh_Stored = 13`, `Mesh_StoredMini = 18`
**Parameters**: None (references external asset)
**Implementation**: `Mesh.cpp:1694-1720`

Stored primitives load pre-built mesh data from asset references. This allows importing complex models created in external tools (via Assimp) or storing hand-authored geometry that doesn't fit parametric forms.

`Mesh_Stored` loads full-precision vertex data (float positions, normals, UVs). `Mesh_StoredMini` loads compressed mesh data with 8-bit quantized positions, halving storage size at the cost of precision. The mini format is used for background geometry where vertex accuracy doesn't matter.

```cpp
void CphxMesh::LoadStoredMiniMesh(unsigned char* vertices, int vxc,
                                  unsigned char* tris, int tricount) {
  for (int x = 0; x < vxc; x++)
    AddVertex(vertices[x*3] / 255.0f, vertices[x*3+1] / 255.0f,
              vertices[x*3+2] / 255.0f);
  // Mirror geometry along X axis for symmetry
  for (int x = 0; x < vxc; x++)
    AddVertex(-vertices[x*3] / 255.0f, vertices[x*3+1] / 255.0f,
              vertices[x*3+2] / 255.0f);

  for (int x = 0; x < tricount; x++)
    AddPolygon(tris[x*3], tris[x*3+1], tris[x*3+2]);
}
```

The StoredMini loader automatically mirrors geometry along the X axis, doubling vertex count. This is a size optimization: store half the model and mirror it for symmetric objects.

## Parameter Packing Reference

Parameter counts per primitive (from `demoscene/apex-public/apEx/apEx/MinimalExport.cpp:169-191`):

| Primitive | Parameter Count | Storage Format |
|-----------|----------------|----------------|
| Cube | 0 | — |
| Plane | 2 | 2 × byte (XRes, YRes) |
| Sphere | 5 | 2 × byte (XRes, YRes), 3 × byte (TopCut, BottomCut, Caps) |
| Cylinder | 3 | 2 × byte (XRes, YRes), 1 × byte (Caps) |
| Cone | 4 | 2 × byte (XRes, YRes), 2 × byte (TopCut, Caps) |
| Arc | 3 | 2 × byte (Res, Degree), 1 × byte (HaveLastSegment) |
| Line | 1 | 1 × byte (Res) |
| Spline | 2 | 2 × byte (KeyCount, Resolution, Loop) |
| Loft | 7 | 7 × byte (see parameter table) |
| Clone | 0 | — |
| Copy | 0 | — |
| GeoSphere | 2 | 1 × byte (Iterations) |
| Scatter | 14 | 14 × byte (see parameter table) |
| Stored | 0 | — |
| Tree | 6 | 6 × byte (Seed, 4 × LevelDensity, Species ref) |
| TreeLeaves | 7 | 7 × byte (Seed, 4 × LevelDensity, Species ref, LeafShape) |
| Text | 2 | 2 × byte (Font, Deviation) |
| Marched | 0 | — |
| StoredMini | 0 | — |
| Merge | 0 | — |

All primitives are accessible through the `CphxMesh` class. The mesh stores vertices in a dynamic array and automatically handles normal calculation, UV generation, and edge topology on demand. Primitives call `AddVertex()` and `AddPolygon()` to construct geometry incrementally. After primitive execution, the mesh can be processed by filters (bevel, smooth, CSG) before final GPU buffer upload.

## Implications for Framework Design

The apEx primitive system demonstrates several patterns valuable for creative coding frameworks:

**Procedural over storage**. Parametric generators compress geometry to a handful of bytes. A GeoSphere with 5 iterations (20,480 triangles) compresses to 1 byte. This trades CPU time for memory, appropriate for demos where executable size matters more than load time.

**Fixed parameter limits**. The maximum 14-byte parameter array enables stack allocation and eliminates dynamic memory in the minimal build. This constraint forces API discipline: primitives can't accumulate unbounded state.

**Separation of generation and modification**. Primitives generate base geometry. Filters (bevel, smooth, CSG, deformation) modify it. This pipeline architecture mirrors shader programming and allows complex shapes from simple primitives plus filter stacks.

**Reusable building blocks**. Loft consumes Arc/Line/Spline as paths. Scatter distributes any mesh across any surface. Text generates outlines that Loft extrudes. Composability multiplies the system's expressive power without adding primitive types.

**Deferred computation**. Primitives don't allocate GPU buffers. They populate CPU-side mesh structures. The final `BuildMesh()` call batches all vertices/indices into GPU buffers. This allows procedural modification before upload and supports level-of-detail by regenerating geometry at different resolutions.

A Rust creative coding framework could adopt these patterns with strong typing for parameter structures, trait-based primitive interfaces, and GPU buffer builders that consume mesh data. The key insight is treating geometry as the output of pure functions, not mutable objects.
