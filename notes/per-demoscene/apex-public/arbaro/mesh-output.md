# Arbaro Mesh Output System

When you press render on a tree, the abstract structure—stems, segments, transformations—must become concrete: vertices in world space, polygons connecting them, UVs mapping textures. The mesh output system converts the recursive tree hierarchy into linear GPU buffer data. It creates cylindrical branch geometry from circular cross-sections, assembles quad leaves with wind data, and exports branch hierarchy metadata for animation.

The transformation is one-way and deterministic. The same tree structure always produces the same mesh. Yet the system supports runtime variation through level-of-detail density controls—branch culling based on distance or performance budget. A tree might have 10,000 branches defined, but render only 2,000 when viewed from afar.

The output feeds directly into Phoenix's mesh system, which handles normal calculation, smoothing groups, and GPU buffer creation. Arbaro doesn't compute normals or optimize indices—it produces raw geometry. This separation means the tree generator can focus on botanical accuracy while the mesh system handles rendering optimization.

Think of mesh generation like tracing a path with a pen that changes thickness. As you follow each branch from base to tip, you draw circular cross-sections at intervals. Connect consecutive circles with quad strips, and you have a cylindrical branch. The cross-sections vary in radius based on tapering, and their vertex count varies by level (trunks get more detail than twigs). Special cases like trunk lobes modulate the circle into organic shapes. The final mesh is thousands of connected quads, forming a watertight branching structure.

## The Problem: From Tree to Triangles

Tree generation produces hierarchical data—stems contain segments contain subsegments. Graphics hardware wants flat arrays—vertex positions, indices, texture coordinates. The gap between these representations creates several challenges:

**Connectivity**: Branch geometry must connect smoothly at junctions. A twig emerging from a limb shares the limb's circular cross-section at the connection point. If radii don't match, you get visible gaps.

**Level of Detail**: A full tree with leaves might have 500,000 vertices. Distant trees need far fewer. The system must support runtime culling without breaking connectivity or creating holes.

**UV Mapping**: Bark textures need consistent mapping across branches of different radii and lengths. The system must calculate UV coordinates that don't stretch or swim as branches curve.

**Animation Data**: Wind simulation needs to know each branch's parent and orientation. This metadata must be exported alongside geometry.

**Coordinate System**: Phoenix uses a Y-up right-handed coordinate system, but D3DX math uses Z-up. The mesh builder swaps axes during vertex creation.

The solution is two-pass generation: first build the tree structure (generation.md), then traverse it depth-first, emitting geometry. The traversal uses deterministic random number seeding to ensure the same branches are culled consistently across frames.

## BranchData: Hierarchy Metadata

Before diving into geometry, let's understand the metadata output. Each branch (stem) exports structural information for later use—primarily wind animation and hierarchy visualization.

```cpp
// Arbaro.h:98-106
struct BranchData
{
  D3DXMATRIX Rotation;
  D3DXVECTOR3 Position;
  int   parentIndex;
  float parentPosition;
  float baseThickness;
  float endThickness;
};
```

| Field | Type | Purpose |
|-------|------|---------|
| Rotation | D3DXMATRIX | Branch orientation matrix |
| Position | D3DXVECTOR3 | Branch base world position |
| parentIndex | int | Index of parent branch (-1 for trunks) |
| parentPosition | float | Offset along parent (unused currently) |
| baseThickness | float | Base radius (unused currently) |
| endThickness | float | Tip radius (unused currently) |

The parent index creates a tree hierarchy in array form. Trunk branches have `parentIndex = -1`. Level 1 branches reference their trunk. Level 2 branches reference their level 1 parent. A shader could traverse this array to propagate wind forces from roots to leaves.

The rotation matrix encodes the branch's local coordinate frame. The Z-axis points along the branch direction. This allows shaders to calculate perpendicular bending for wind effects.

Currently, only `Rotation`, `Position`, and `parentIndex` are populated. The thickness fields are reserved for future use—potentially for LOD decisions or animation scaling.

## Tree::BuildTree() — Branch Mesh Entry Point

The public API for branch mesh generation is `Tree::BuildTree()`. It iterates trunk stems and triggers recursive mesh building.

```cpp
// Arbaro.cpp:1102-1114
int Tree::BuildTree( CphxMesh *Mesh, unsigned char* levelDensities, BranchData* branchOutput )
{
  idx = 0;

  BranchData* data = branchOutput;

  aholdrand = 0;
  for ( int x = 0; x < trunks.NumItems(); x++ )
    trunks[ x ]->BuildMesh( -1, Mesh, levelDensities, data );
  Mesh->SmoothGroupSeparation = 2.0f;

  return idx;
}
```

Key points:

**Global index counter**: The static `idx` variable tracks branch count. Each stem increments it and uses the previous value as its index. This creates sequential branch IDs for the hierarchy.

**RNG initialization**: `aholdrand = 0` seeds the deterministic RNG for density culling. The same seed produces the same culling pattern across frames.

**Level densities**: The `levelDensities` array contains 4 bytes (one per tree level). Each byte is 0-255, representing inclusion probability. `levelDensities[0] = 255` renders all level 0 branches (trunks). `levelDensities[2] = 127` renders roughly half of level 2 branches.

**Smooth group separation**: After generation, the smooth group threshold is set to 2.0 degrees. This creates hard edges between branch segments with large angle changes, giving better visual definition to curved branches.

**Parent index**: Trunks are passed `-1` as parent index, marking them as roots.

**Return value**: The function returns the total branch count, which equals the number of entries written to `branchOutput`.

The function produces branch geometry only—no leaves. Leaves are generated separately via `BuildLeaves()` to allow different materials and culling strategies.

## Tree::BuildLeaves() — Leaf Mesh Entry Point

Leaf generation mirrors branch generation but produces quad geometry with specialized data channels.

```cpp
// Arbaro.cpp:1116-1128
int Tree::BuildLeaves( CphxMesh *Mesh, unsigned char* levelDensities, BranchData* branchOutput )
{
  idx = 0;

  BranchData* data = branchOutput;

  aholdrand = 0;
  for ( int x = 0; x < trunks.NumItems(); x++ )
    trunks[ x ]->BuildLeaves( -1, Mesh, levelDensities, data );
  Mesh->SmoothGroupSeparation = DEFAULTSMOOTHGROUPSEPARATION;

  return idx;
}
```

The structure is identical to `BuildTree()`. The key differences:

**Separate mesh**: Leaves are typically rendered with alpha-tested materials (for leaf texture transparency) while branches use opaque materials. Separate meshes allow different render states.

**Different traversal**: `BuildLeaves()` skips branch geometry entirely, only traversing stems and emitting leaf quads.

**Normal smooth groups**: Leaves use default smooth group separation (typically 60 degrees) rather than the hard-edged 2.0 degree threshold used for branches. This produces softer leaf normals.

**LOD flexibility**: Because leaves are separate, you can drop leaf geometry entirely for distant trees without affecting branch rendering.

The same `levelDensities` array controls both branch and leaf culling. If a branch is culled, its child branches and leaves are also culled (maintaining hierarchy consistency).

## StemImpl::BuildMesh() — Recursive Branch Building

Each stem recursively builds its mesh and that of its children. The function handles density culling, RNG state management, and UV scale calculation.

```cpp
// Arbaro.cpp:972-1016
void StemImpl::BuildMesh( int parentID, CphxMesh *mesh, unsigned char* levelDensities, BranchData *&data )
{
  int currIdx = idx;

  data->parentIndex = parentID;
  data->Rotation = transf.Rotation;
  data->Position = transf.Position;

  data++;
  idx++;

  int cntr = 0;
  long ssrand = aholdrand;

  for ( int x = 0; x < substems.NumItems(); x++ )
    if ( arand() % 255 <= *levelDensities )
      substems[ x ]->BuildMesh( currIdx, mesh, levelDensities + 1, data );

  aholdrand = ssrand;

  for ( int x = 0; x < clones.NumItems(); x++ )
    if ( arand() % 255 <= *levelDensities )
      clones[ x ]->BuildMesh( currIdx, mesh, levelDensities + 1, data );

  aholdrand = ssrand;

  float branchDist = 0;
  float uvscale;
  if ( segments.NumItems() )
    uvscale = max( 1.0f, (int)( segments[ 0 ]->_rad1 * PI * 2 ) );

  if ( isClone && clonedFrom )
  {
    uvscale = max( 1.0f, (int)( clonedFrom->segments[ 0 ]->_rad1 * PI * 2 ) );
  }

  for ( int x = 0; x < segments.NumItems(); x++ )
    segments[ x ]->BuildMesh( currIdx, mesh, cntr, branchDist, uvscale, isClone );

}
```

Let's trace the logic step by step.

### Hierarchy Export

The first block writes branch metadata:

```cpp
int currIdx = idx;

data->parentIndex = parentID;
data->Rotation = transf.Rotation;
data->Position = transf.Position;

data++;
idx++;
```

The current index is captured before incrementing. This becomes the parent index for child branches. The data pointer advances, writing to the next slot in the output array. The global index increments to reserve this branch's ID.

### Deterministic Density Culling

The RNG state is saved before processing children:

```cpp
long ssrand = aholdrand;

for ( int x = 0; x < substems.NumItems(); x++ )
  if ( arand() % 255 <= *levelDensities )
    substems[ x ]->BuildMesh( currIdx, mesh, levelDensities + 1, data );

aholdrand = ssrand;
```

Each substem checks `arand() % 255 <= *levelDensities`. The `arand()` function is a deterministic LCG (linear congruential generator):

```cpp
// Arbaro.cpp:965-970
static long aholdrand = 1L;

int __cdecl arand()
{
  return( ( ( aholdrand = aholdrand * 214013L + 2531011L ) >> 16 ) & 0x7fff );
}
```

It produces values 0-32767. Taking modulo 255 gives 0-254. If the level density is 255, all branches pass (`arand() % 255` is always <= 255). If density is 0, no branches pass. If density is 127, roughly half pass.

Crucially, the RNG state is restored after processing substems and again after processing clones. This ensures substems and clones see the same random sequence. Otherwise, culling substems would shift the sequence, causing clones to be culled inconsistently.

The `levelDensities` pointer advances (`levelDensities + 1`) when recursing to children. Each tree level has its own density byte. This allows per-level LOD—keep all trunks but cull some twigs.

### UV Scale Calculation

UV scale determines texture coordinate wrapping:

```cpp
float uvscale;
if ( segments.NumItems() )
  uvscale = max( 1.0f, (int)( segments[ 0 ]->_rad1 * PI * 2 ) );
```

The formula is `circumference = 2 * PI * radius`. For a trunk with radius 5.0, `uvscale = 31`. For a twig with radius 0.5, `uvscale = 3`. The cast to `int` quantizes the scale, preventing tiny UV differences between similar branches.

The UV V-coordinate (vertical) is measured in branch distance (world units). The U-coordinate (horizontal) wraps every `uvscale` units around the circumference. This keeps texture density consistent—thick trunks and thin twigs both map 1:1 in world space.

For cloned stems, UV scale is inherited from the original stem:

```cpp
if ( isClone && clonedFrom )
{
  uvscale = max( 1.0f, (int)( clonedFrom->segments[ 0 ]->_rad1 * PI * 2 ) );
}
```

This prevents UV discontinuities at split points. If a branch splits into three clones, all three use the parent's circumference for UV mapping. The texture wraps smoothly across the split.

### Segment Mesh Building

Finally, segments emit actual geometry:

```cpp
for ( int x = 0; x < segments.NumItems(); x++ )
  segments[ x ]->BuildMesh( currIdx, mesh, cntr, branchDist, uvscale, isClone );
```

The `cntr` variable tracks cross-section count (starts at 0). The first segment creates the initial cross-section; subsequent segments connect to it.

The `branchDist` accumulates world-space distance along the branch for UV V-coordinates.

The `isClone` flag tells segments to reduce radius slightly (0.9x) at the first cross-section, creating a smooth taper at split junctions.

## StemImpl::BuildLeaves() — Recursive Leaf Building

Leaf building follows the same recursive pattern but emits leaf quads instead of branch cylinders.

```cpp
// Arbaro.cpp:1018-1046
void StemImpl::BuildLeaves( int parentID, CphxMesh *mesh, unsigned char* levelDensities, BranchData *&data )
{
  int currIdx = idx;

  data->parentIndex = parentID;
  data->Rotation = transf.Rotation;
  data->Position = transf.Position;

  data++;
  idx++;

  long ssrand = aholdrand;

  for ( int x = 0; x < substems.NumItems(); x++ )
    if ( arand() % 255 <= *levelDensities )
      substems[ x ]->BuildLeaves( currIdx, mesh, levelDensities + 1, data );

  aholdrand = ssrand;

  for ( int x = 0; x < clones.NumItems(); x++ )
    if ( arand() % 255 <= *levelDensities )
      clones[ x ]->BuildLeaves( currIdx, mesh, levelDensities + 1, data );

  aholdrand = ssrand;

  for ( int x = 0; x < leaves.NumItems(); x++ )
    if ( arand() % 255 <= *levelDensities )
      leaves[ x ]->BuildMesh( currIdx, mesh, par.LeafScale, par.LeafScaleX, par.LeafStemLen );
}
```

The structure mirrors `BuildMesh()`:
1. Export branch metadata
2. Recursively build children with density culling
3. Emit leaf geometry (instead of branch geometry)

The key difference is the leaf loop at the end. Each leaf checks the density and calls `LeafImpl::BuildMesh()` if it passes. The leaf scale parameters are passed through from the tree parameters.

Notice the same RNG state saving around substems, clones, and leaves. This ensures leaves are culled consistently even when substems are culled differently.

## SegmentImpl::BuildMesh() — Cylindrical Geometry

Each segment creates a series of circular cross-sections connected by quad strips. This function handles the iteration and distance tracking.

```cpp
// Arbaro.cpp:411-425
void SegmentImpl::BuildMesh( int branchIdx, CphxMesh *mesh, int &cntr, float &branchDist, float uvscale, bool isClone )
{
  if ( !subsegments.NumItems() || cntr == 0 )
    getSectionPoints( branchIdx, mesh, (float)_rad1*( isClone ? 0.9f : 1.0f ), transf, cntr, branchDist, branchDist, uvscale );

  float last = branchDist;
  for ( int x = 0; x < subsegments.NumItems(); x++ )
  {
    D3DXVECTOR3 d = subsegments[ x ]->pos - transf.Position;
    float l = branchDist + D3DXVec3Length( &d );
    getSectionPoints( branchIdx, mesh, (float)subsegments[ x ]->rad, transf.translate( d ), cntr, last, l, uvscale );
    last = l;
  }
  branchDist = last;
}
```

### Initial Cross-Section

The first cross-section is created if either:
- This segment has no subsegments (rare, but possible for degenerate segments)
- This is the first cross-section in the stem (`cntr == 0`)

The radius is scaled by 0.9 for clones, creating a smooth taper at split junctions. Without this, split branches would connect at full parent radius, creating a bulge.

### Subsegment Cross-Sections

For each subsegment:
1. Calculate the vector from segment base to subsegment position
2. Calculate the distance along the branch (for UV V-coordinate)
3. Create a cross-section at the subsegment position and radius

The `transf.translate(d)` creates a transformation at the subsegment position while maintaining the segment's orientation. This keeps all cross-sections perpendicular to the branch direction.

The `last` variable tracks UV V-coordinate between cross-sections. The V-coordinate increases monotonically along the branch, preventing texture swimming.

The `branchDist` accumulates across segments. A 3-segment stem with 10 units per segment will have `branchDist` values of 0, 10, 20, 30 at segment boundaries.

## SegmentImpl::getSectionPoints() — Cross-Section Generation

This is where vertices are actually created. The function generates a circular ring of vertices, optionally modulated by trunk lobes, and connects them to the previous ring with quads.

```cpp
// Arbaro.cpp:360-409
void SegmentImpl::getSectionPoints( int branchIdx, CphxMesh *mesh, float rad, Transformation& trf, int &counter, float branchDist1, float branchDist2, float uvscale )
{
  int pt_cnt = lpar.mesh_points;
  int vxb = mesh->Vertices.NumItems() - pt_cnt;

  if ( rad < 0.000001 )
  {
    D3DXVECTOR3 vx = trf.apply( *(D3DXVECTOR3*)leafUVData );
    mesh->AddVertex( vx.x, vx.z, vx.y );
    CphxVertex &vert = mesh->Vertices[ mesh->Vertices.NumItems() - 1 ];

    if ( counter )
      for ( int i = 0; i < pt_cnt; i++ )
      {
        float xc1 = i / (float)pt_cnt*uvscale;
        float xc2 = ( i + 1 ) / (float)pt_cnt*uvscale;
        mesh->AddPolygon( vxb + pt_cnt, vxb + ( i + 1 ) % pt_cnt, vxb + i, vxb + i, D3DXVECTOR2( ( xc1 + xc2 ) / 2.0f, branchDist2 ), D3DXVECTOR2( xc1, branchDist1 ), D3DXVECTOR2( xc2, branchDist1 ), D3DXVECTOR2( 0, 0 ) );
      }
  }
  else
  {
    for ( int i = 0; i < pt_cnt; i++ )
    {
      float angle = i*360.0f / pt_cnt;
      if ( lpar.level == 0 && par.Lobes != 0 )
        angle -= 10.0f / par.Lobes;

      D3DXVECTOR3 pt( cos( (float)( angle*PI / 180 ) ), sin( (float)( angle*PI / 180 ) ), 0 );

      float multiplier = rad;

      if ( lpar.level == 0 && ( par.Lobes != 0 || par._0ScaleV != 0 ) )
        multiplier = (float)( ( rad * ( 1 + var( par._0ScaleV ) / subsegments.NumItems() ) )*( 1.0 + par.LobeDepth*cos( par.Lobes*angle*PI / 180.0 ) ) );

      pt = trf.apply( pt*multiplier );
      mesh->AddVertex( pt.x, pt.z, pt.y );
      CphxVertex &vert = mesh->Vertices[ mesh->Vertices.NumItems() - 1 ];

      if ( counter )
      {
        float xc1 = i / (float)pt_cnt*uvscale;
        float xc2 = ( i + 1 ) / (float)pt_cnt*uvscale;
        mesh->AddPolygon( vxb + i + pt_cnt, vxb + ( i + 1 ) % pt_cnt + pt_cnt, vxb + ( i + 1 ) % pt_cnt, vxb + i, D3DXVECTOR2( xc1, branchDist2 ), D3DXVECTOR2( xc2, branchDist2 ), D3DXVECTOR2( xc2, branchDist1 ), D3DXVECTOR2( xc1, branchDist1 ) );
      }
    }
  }
  counter++;
}
```

This function deserves detailed analysis—it's the core of branch geometry.

### Radial Resolution

The vertex count per cross-section comes from `lpar.mesh_points`:

```cpp
// Arbaro.cpp:131-140 (in Params constructor)
for ( int x = 0; x < 4; x++ )
{
  LevelParams &p = lparams[ x ];
  p.mesh_points = 4 - x;  // Level 0: 4, Level 1: 3, Level 2: 2, Level 3: 1
}

if ( Lobes > 0 )
  lparams[ 0 ].mesh_points = max( ( (int)( Lobes*( pow( 2.0, (int)( 1 + 2.5*Smooth ) ) ) ) ), (int)( 4 * ( 1 + 2 * Smooth ) ) );

for ( int i = 1; i < 4; i++ )
  lparams[ i ].mesh_points = max( 3, (int)( lparams[ i ].mesh_points*( 1 + 1.5*Smooth ) ) );
```

Base resolution decreases by level (4 vertices for trunks, 3 for primary branches, etc.). Trunk lobes increase resolution to capture detail. The `Smooth` parameter increases resolution across all levels for higher-quality trees.

Example: A tree with `Lobes = 5` and `Smooth = 0.5` gives:
- Level 0: `max(5 * pow(2, 2.25), 4 * 2) = max(24, 8) = 24` vertices
- Level 1: `max(3, 3 * 1.75) = 5` vertices
- Level 2: `max(3, 2 * 1.75) = 3` vertices
- Level 3: `max(3, 1 * 1.75) = 3` vertices

The `vxb` variable stores the base vertex index for connectivity:

```cpp
int vxb = mesh->Vertices.NumItems() - pt_cnt;
```

This points to the previous ring of vertices. When creating quads, we connect current ring vertex `i` to previous ring vertices `vxb + i` and `vxb + (i+1)`.

### Degenerate Cross-Sections

When radius approaches zero (branch tips), creating a full ring would produce degenerate triangles. Instead, a single center vertex is created:

```cpp
if ( rad < 0.000001 )
{
  D3DXVECTOR3 vx = trf.apply( *(D3DXVECTOR3*)leafUVData );
  mesh->AddVertex( vx.x, vx.z, vx.y );
```

The position is simply the transformation's origin. The cast `*(D3DXVECTOR3*)leafUVData` is a clever hack—`leafUVData` is a float array starting with `{0, 0, ...}`, so casting it to a vector gives `(0, 0, 0)`.

The coordinate swap `(vx.x, vx.z, vx.y)` converts from D3DX's Z-up convention to Phoenix's Y-up convention.

If this isn't the first cross-section (`counter > 0`), triangular polygons connect the previous ring to this center point:

```cpp
for ( int i = 0; i < pt_cnt; i++ )
{
  mesh->AddPolygon( vxb + pt_cnt, vxb + ( i + 1 ) % pt_cnt, vxb + i, vxb + i, ... );
}
```

The polygon indices are: `[center, prev_next, prev_current, prev_current]`. The fourth index is duplicated to create a degenerate quad (which the mesh system treats as a triangle). The UV coordinates are calculated normally, wrapping around the circumference.

### Full Cross-Sections

For normal radius values, a full circular ring is generated:

```cpp
for ( int i = 0; i < pt_cnt; i++ )
{
  float angle = i*360.0f / pt_cnt;
```

Each vertex is evenly spaced around the circle. For `pt_cnt = 8`, angles are 0°, 45°, 90°, 135°, 180°, 225°, 270°, 315°.

The base vertex position is on a unit circle in the XY plane (Z = 0):

```cpp
D3DXVECTOR3 pt( cos( (float)( angle*PI / 180 ) ), sin( (float)( angle*PI / 180 ) ), 0 );
```

### Trunk Lobes

For level 0 branches (trunks) with lobes enabled, the radius is modulated:

```cpp
if ( lpar.level == 0 && par.Lobes != 0 )
  angle -= 10.0f / par.Lobes;
```

The angle offset aligns lobes vertically across cross-sections. Without this, each segment would rotate the lobes, creating a twisted appearance.

The radius multiplier applies the lobe depth:

```cpp
multiplier = (float)( ( rad * ( 1 + var( par._0ScaleV ) / subsegments.NumItems() ) )
                      * ( 1.0 + par.LobeDepth*cos( par.Lobes*angle*PI / 180.0 ) ) );
```

Breaking this down:
- `1 + var(par._0ScaleV) / subsegments.NumItems()`: Random per-segment radius variation
- `1.0 + par.LobeDepth * cos(par.Lobes * angle * PI / 180.0)`: Lobe modulation

For `Lobes = 5` and `LobeDepth = 0.2`:
- At lobe peaks (angle = 0°, 72°, 144°, etc.): `multiplier = rad * 1.2`
- At lobe valleys (angle = 36°, 108°, etc.): `multiplier = rad * 0.8`

The cosine creates a smooth sinusoidal cross-section. Five lobes produce a five-pointed star. This simulates bark ridges on trees like oak.

The random variation (`var(_0ScaleV)`) divided by subsegment count ensures the variation changes smoothly along the branch, not abruptly between cross-sections.

### Coordinate Transform

The vertex is transformed to world space and axis-swapped:

```cpp
pt = trf.apply( pt*multiplier );
mesh->AddVertex( pt.x, pt.z, pt.y );
```

The transformation applies rotation (orienting the cross-section perpendicular to the branch) and translation (positioning it along the branch). The `pt*multiplier` scales the unit circle by the radius.

The axis swap converts from Z-up to Y-up. In D3DX convention, Z is forward/up, Y is right. In Phoenix convention, Y is up, Z is forward.

### Quad Connectivity

If this isn't the first cross-section, quads connect it to the previous ring:

```cpp
if ( counter )
{
  float xc1 = i / (float)pt_cnt*uvscale;
  float xc2 = ( i + 1 ) / (float)pt_cnt*uvscale;
  mesh->AddPolygon( vxb + i + pt_cnt, vxb + ( i + 1 ) % pt_cnt + pt_cnt, vxb + ( i + 1 ) % pt_cnt, vxb + i, D3DXVECTOR2( xc1, branchDist2 ), D3DXVECTOR2( xc2, branchDist2 ), D3DXVECTOR2( xc2, branchDist1 ), D3DXVECTOR2( xc1, branchDist1 ) );
}
```

The quad indices are:
- `vxb + i + pt_cnt`: Current ring, vertex i
- `vxb + (i+1) % pt_cnt + pt_cnt`: Current ring, vertex i+1 (wrapping)
- `vxb + (i+1) % pt_cnt`: Previous ring, vertex i+1
- `vxb + i`: Previous ring, vertex i

The modulo operation (`% pt_cnt`) wraps the last vertex back to the first, closing the cylinder.

The UV coordinates form a rectangle:
- `(xc1, branchDist2)`: Current ring, start of quad
- `(xc2, branchDist2)`: Current ring, end of quad
- `(xc2, branchDist1)`: Previous ring, end of quad
- `(xc1, branchDist1)`: Previous ring, start of quad

The U-coordinate wraps around the circumference. For `pt_cnt = 8` and `uvscale = 24`:
- Vertex 0: U = 0
- Vertex 1: U = 3
- Vertex 2: U = 6
- ...
- Vertex 7: U = 21
- Vertex 8 (wraps to 0): U = 24 (or 0 after texture wrapping)

The V-coordinate increases along the branch (`branchDist1` to `branchDist2`), creating vertical texture flow.

This UV mapping keeps texture density constant regardless of branch thickness. A thick trunk and thin twig both map 1:1 in world units, preventing stretching.

## LeafImpl::BuildMesh() — Quad Leaf Geometry

Leaves are simple quads, but they carry extra data for animation. Each leaf vertex stores the leaf's base position (for bending) and direction (for wind).

```cpp
// Arbaro.cpp:235-261
void LeafImpl::BuildMesh( int branchIdx, CphxMesh *mesh, float leafScale, float leafScaleX, float leafStemLen )
{
  int vxc = mesh->Vertices.NumItems();

  D3DXVECTOR3 root = transf.apply( D3DXVECTOR3( 0, 0, 0 ) );
  D3DXVECTOR3 dir = transf.apply( D3DXVECTOR3( 0, 0, 1 ) ) - root;

  for ( int x = 0; x < 4; x++ )
  {
    D3DXVECTOR3 &vx = transf.apply( D3DXVECTOR3( leafVertexData[ x ][ 0 ] * leafScaleX, 0, leafVertexData[ x ][ 1 ] + leafStemLen * 2 )*leafScale*0.5f );

    mesh->AddVertex( vx.x, vx.z, vx.y ); //XZY!!
    CphxVertex &vert = mesh->Vertices[ mesh->Vertices.NumItems() - 1 ];
    vert.Position2 = D3DXVECTOR3( root.x, root.z, root.y );
  }

  mesh->AddPolygon( vxc + 0, vxc + 1, vxc + 2, vxc + 3, *(D3DXVECTOR2*)leafUVData, *(D3DXVECTOR2*)( leafUVData + 4 ), *(D3DXVECTOR2*)( leafUVData + 3 ), *(D3DXVECTOR2*)( leafUVData + 2 ) );

  for ( int x = 0; x < 4; x++ )
  {
    CphxPolygon &p = mesh->Polygons[ mesh->Polygons.NumItems() - 1 ];
    p.Texcoords[ x ][ 2 ].x = dir.x;
    p.Texcoords[ x ][ 2 ].y = dir.z;
    p.Texcoords[ x ][ 3 ].x = dir.y;
  }
}
```

### Leaf Template

The leaf shape is defined by a static template:

```cpp
// Arbaro.cpp:16-17
static char leafVertexData[ 4 ][ 2 ] = { { -1, 0 },{ 1, 0 },{ 1, 2 },{ -1, 2 } };
static float leafUVData[ 6 ] = { 0, 0, 0, 1, 1, 0 };
```

The vertex data defines a 1x2 quad (width x height) in local space:
- Bottom-left: (-1, 0)
- Bottom-right: (1, 0)
- Top-right: (1, 2)
- Top-left: (-1, 2)

The UV data maps standard texture coordinates:
- UV0: (0, 0) - bottom-left
- UV1: (1, 0) - bottom-right
- UV2: (1, 1) - top-right (derived from offset)
- UV3: (0, 1) - top-left (derived from offset)

The data layout is slightly unusual—only 6 floats for 4 UV coordinates. The code accesses them via pointer arithmetic: `*(D3DXVECTOR2*)leafUVData` gives (0, 0), `*(D3DXVECTOR2*)(leafUVData + 2)` gives (0, 1), etc.

### Root and Direction

Before creating vertices, the leaf's root position and direction are calculated:

```cpp
D3DXVECTOR3 root = transf.apply( D3DXVECTOR3( 0, 0, 0 ) );
D3DXVECTOR3 dir = transf.apply( D3DXVECTOR3( 0, 0, 1 ) ) - root;
```

The root is the leaf's attachment point (the transformation's origin). The direction is the leaf's local Z-axis in world space. This will be stored for wind animation.

### Vertex Transformation

Each of the 4 vertices is transformed to world space:

```cpp
D3DXVECTOR3 &vx = transf.apply( D3DXVECTOR3( leafVertexData[ x ][ 0 ] * leafScaleX, 0, leafVertexData[ x ][ 1 ] + leafStemLen * 2 )*leafScale*0.5f );
```

Breaking this down:
1. `leafVertexData[x][0] * leafScaleX`: Scale X by width factor
2. `leafVertexData[x][1] + leafStemLen * 2`: Offset Z by stem length
3. `* leafScale * 0.5f`: Scale uniformly and halve (since template is 1x2, not 0.5x1)
4. `transf.apply(...)`: Transform to world space

The `leafScaleX` parameter allows non-square leaves. For `leafScaleX = 2.0`, leaves are twice as wide as tall.

The `leafStemLen` adds a small offset along Z, creating a visible petiole (leaf stem). For `leafStemLen = 0.2`, the base of the leaf is 0.4 units from the attachment point.

The vertex is added with axis swap:

```cpp
mesh->AddVertex( vx.x, vx.z, vx.y );
```

### Position2: Attachment Point

Immediately after adding the vertex, the attachment point is stored in `Position2`:

```cpp
CphxVertex &vert = mesh->Vertices[ mesh->Vertices.NumItems() - 1 ];
vert.Position2 = D3DXVECTOR3( root.x, root.z, root.y );
```

This secondary position channel encodes where the leaf connects to the branch. A vertex shader can interpolate between `Position` (leaf tip) and `Position2` (leaf base) to create realistic bending. Wind strength could vary from 0 at the base to 1 at the tip.

### Polygon Creation

The quad is created with standard topology:

```cpp
mesh->AddPolygon( vxc + 0, vxc + 1, vxc + 2, vxc + 3, ... );
```

Indices 0-1-2-3 form a counter-clockwise quad (assuming standard winding). The UV coordinates come from the template data via pointer casts.

### UV Channels 2 and 3: Leaf Direction

Phoenix's vertex format supports multiple UV channels. After creating the polygon, channels 2 and 3 are populated with the leaf direction:

```cpp
for ( int x = 0; x < 4; x++ )
{
  CphxPolygon &p = mesh->Polygons[ mesh->Polygons.NumItems() - 1 ];
  p.Texcoords[ x ][ 2 ].x = dir.x;
  p.Texcoords[ x ][ 2 ].y = dir.z;
  p.Texcoords[ x ][ 3 ].x = dir.y;
}
```

The direction is split across two UV channels:
- UV2.x = dir.x
- UV2.y = dir.z
- UV3.x = dir.y
- UV3.y = (unused)

This encoding stores a 3D vector in 2.5 UV channels. A shader can reconstruct the direction and use it for wind animation. The wind force could be applied perpendicular to the leaf direction, creating realistic flutter.

The axis swap (dir.z in UV2.y) again accounts for coordinate system differences.

## LOD System: Level Densities

The density array enables runtime LOD without regenerating the tree. By varying the 4 density bytes, you can cull branches at different rates per level.

Example configurations:

**Full Detail** (1.0 draw distance):
```cpp
unsigned char densities[4] = { 255, 255, 255, 255 };
```
All branches and leaves render.

**Medium Detail** (2.0 draw distance):
```cpp
unsigned char densities[4] = { 255, 255, 192, 128 };
```
- Level 0 (trunks): 100%
- Level 1 (branches): 100%
- Level 2 (twigs): 75%
- Level 3 (terminal twigs): 50%

**Low Detail** (4.0 draw distance):
```cpp
unsigned char densities[4] = { 255, 192, 64, 0 };
```
- Level 0: 100%
- Level 1: 75%
- Level 2: 25%
- Level 3: 0% (no terminal twigs or leaves)

The culling is deterministic—the same density values always cull the same branches. This prevents popping as LOD levels change (though you'd need interpolation between levels for truly smooth LOD).

The system is hierarchical: if a level 1 branch is culled, all its level 2 children are automatically culled (they're never reached during traversal). This maintains structural correctness—you never see a level 3 twig floating without its parent branch.

## Coordinate System

The axis swap throughout the code (`mesh->AddVertex(vx.x, vx.z, vx.y)`) accounts for coordinate system differences.

**D3DX Convention** (Arbaro's math):
- X: Right
- Y: Forward
- Z: Up

**Phoenix Convention** (rendering):
- X: Right
- Y: Up
- Z: Forward

The swap remaps Z (D3DX up) to Y (Phoenix up) and Y (D3DX forward) to Z (Phoenix forward). X remains unchanged.

This is done at mesh creation time, not at render time, so there's no runtime cost. The tree generation math uses D3DX conventions (since it uses D3DX matrix functions), but the output mesh uses Phoenix conventions.

An alternative would be to transform the entire tree's root transformation, but swapping individual vertices is simpler and avoids matrix operations.

## UV Mapping Details

The UV mapping system ensures textures don't stretch or swim. The U-coordinate wraps around the branch circumference. The V-coordinate flows along the branch length.

**U-Coordinate** (horizontal):
- Calculated as `i / pt_cnt * uvscale`
- For a trunk with `pt_cnt = 24`, `uvscale = 31`:
  - Vertex 0: U = 0
  - Vertex 1: U = 1.29
  - ...
  - Vertex 23: U = 29.71
  - Wraps back to 0

The texture wraps `uvscale` times around the circumference. This keeps texel density constant—each world unit around the circumference corresponds to one texel.

**V-Coordinate** (vertical):
- Measured in world-space distance along the branch
- Accumulates via `branchDist`, which increases by segment length

For a 3-segment branch with segments of length 5.0, 4.0, 3.0:
- Segment 0 base: V = 0.0
- Segment 0 tip: V = 5.0
- Segment 1 base: V = 5.0
- Segment 1 tip: V = 9.0
- Segment 2 base: V = 9.0
- Segment 2 tip: V = 12.0

The texture repeats naturally if V exceeds 1.0 (which it always does for any reasonably-sized branch). A bark texture with vertical resolution of 1.0 world units will tile 12 times along this branch.

This creates:
- No stretching: Thick and thin branches have the same texel density
- No swimming: Texture doesn't slide as branches curve
- Seamless tiling: Texture wraps continuously at V=0/V=1 boundaries

The system assumes the texture repeats naturally. Non-repeating textures would create visible seams.

## Mesh Output Summary Table

| Geometry Type | Vertex Count Formula | Polygon Count Formula | UV Channels Used |
|--------------|---------------------|----------------------|-----------------|
| Branch | `segments * subsegments * mesh_points` | `segments * subsegments * mesh_points` (quads) | UV0: Main texture |
| Branch Tip | `1` (degenerate center) | `mesh_points` (triangles) | UV0: Main texture |
| Leaf | `4` (quad) | `1` (quad) | UV0: Texture, UV2+UV3: Direction |

**Branch Data Per Stem**:
- Rotation matrix (16 floats)
- Position (3 floats)
- Parent index (1 int)
- Unused fields (3 floats)

**Total Memory Example** (4-level tree):
- 1 trunk, 20 branches, 300 twigs, 3000 terminal twigs
- Branch vertices: ~50,000 (assuming average 15 subsegments per stem, 8 vertices per cross-section)
- Leaf vertices: ~100,000 (25 leaves per terminal twig, 4 vertices per leaf)
- Branch data: 3,321 entries × 80 bytes = 265 KB
- Vertex data: 150,000 vertices × 48 bytes = 7.2 MB

## Implications for Rust Framework

The Arbaro mesh output system demonstrates several principles valuable for Rust-based procedural geometry:

**Separation of Structure and Mesh**: The tree structure (stems, segments) is generated first, then traversed to produce mesh data. A Rust implementation could enforce this with separate types:

```rust
struct TreeStructure {
  trunks: Vec<Stem>,
}

struct TreeMesh {
  vertices: Vec<Vertex>,
  indices: Vec<u32>,
  branch_data: Vec<BranchData>,
}

impl TreeStructure {
  fn build_mesh(&self, densities: &[u8; 4]) -> TreeMesh {
    // Traverse and emit geometry
  }
}
```

This separation allows the same structure to produce multiple meshes (different LODs, different materials) without regeneration.

**Deterministic Culling**: The RNG state saving ensures density culling is consistent. A Rust implementation could encapsulate this in an iterator:

```rust
struct DeterministicCull<I> {
  inner: I,
  rng_state: u64,
  density: u8,
}

impl<I: Iterator> Iterator for DeterministicCull<I> {
  type Item = I::Item;

  fn next(&mut self) -> Option<Self::Item> {
    self.inner.next().filter(|_| {
      let r = lcg_rand(&mut self.rng_state);
      (r % 255) as u8 <= self.density
    })
  }
}
```

This makes culling explicit and reusable.

**UV Scale from Circumference**: Calculating UV scale from branch circumference ensures constant texture density. A Rust implementation should document this relationship:

```rust
/// UV scale based on branch circumference.
/// Ensures texture density remains constant across different branch thicknesses.
fn calculate_uv_scale(radius: f32) -> f32 {
  (radius * std::f32::consts::TAU).max(1.0) as u32 as f32
}
```

The cast to `u32` quantizes the scale, preventing tiny UV differences between similar branches.

**Cross-Section as Slice**: The cross-section creation could use a slice pattern:

```rust
fn create_cross_section(
  mesh: &mut Mesh,
  transform: &Isometry3<f32>,
  radius: f32,
  vertex_count: usize,
  lobes: Option<(u8, f32)>,
) -> Range<usize> {
  let start = mesh.vertices.len();

  for i in 0..vertex_count {
    let angle = (i as f32 / vertex_count as f32) * TAU;
    let r = match lobes {
      Some((count, depth)) => {
        radius * (1.0 + depth * (count as f32 * angle).cos())
      }
      None => radius,
    };

    let pos = transform * Point3::new(r * angle.cos(), r * angle.sin(), 0.0);
    mesh.vertices.push(Vertex { position: pos, .. });
  }

  start..mesh.vertices.len()
}
```

Returning a range allows quad connectivity without storing indices separately.

**Secondary Vertex Channels**: Rust's vertex format could use an enum for specialized data:

```rust
#[repr(C)]
struct Vertex {
  position: [f32; 3],
  normal: [f32; 3],
  uv: [f32; 2],
  secondary_data: SecondaryData,
}

enum SecondaryData {
  None,
  LeafRoot { root: [f32; 3], direction: [f32; 3] },
  BranchWind { branch_index: u32, distance: f32 },
}
```

This makes the purpose explicit while remaining GPU-compatible (via `#[repr(C)]` and careful size matching).

**Capacity Pre-allocation**: The tree structure knows approximate vertex counts:

```rust
impl TreeStructure {
  fn estimate_mesh_size(&self) -> MeshSizeEstimate {
    let mut vertices = 0;
    let mut indices = 0;

    for stem in self.iter_stems() {
      let segments = stem.segments.len();
      let resolution = stem.level_params.mesh_points;
      vertices += segments * resolution;
      indices += (segments - 1) * resolution * 6; // Quads as triangles
    }

    MeshSizeEstimate { vertices, indices }
  }
}

let estimate = tree.estimate_mesh_size();
let mut mesh = Mesh::with_capacity(estimate.vertices, estimate.indices);
```

Pre-allocation avoids incremental reallocations during generation.

**WGPU Buffer Creation**: The final output would be WGPU buffers:

```rust
impl TreeMesh {
  fn to_wgpu_buffers(&self, device: &wgpu::Device) -> TreeBuffers {
    TreeBuffers {
      vertices: device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Tree Vertices"),
        contents: bytemuck::cast_slice(&self.vertices),
        usage: wgpu::BufferUsages::VERTEX,
      }),
      indices: device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Tree Indices"),
        contents: bytemuck::cast_slice(&self.indices),
        usage: wgpu::BufferUsages::INDEX,
      }),
      branch_data: device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some("Branch Hierarchy"),
        contents: bytemuck::cast_slice(&self.branch_data),
        usage: wgpu::BufferUsages::STORAGE,
      }),
    }
  }
}
```

The branch data becomes a storage buffer for compute shader wind simulation.

**Type Safety for Indices**: Rust's type system can prevent index mismatches:

```rust
struct CrossSectionHandle(Range<u32>);

fn connect_cross_sections(
  mesh: &mut Mesh,
  prev: CrossSectionHandle,
  curr: CrossSectionHandle,
) {
  assert_eq!(prev.0.len(), curr.0.len(), "Cross-section resolution must match");

  for i in 0..prev.0.len() {
    let i_next = (i + 1) % prev.0.len();
    mesh.add_quad(
      prev.0.start + i as u32,
      prev.0.start + i_next as u32,
      curr.0.start + i_next as u32,
      curr.0.start + i as u32,
    );
  }
}
```

This prevents connectivity bugs at compile time.

## Summary

The mesh output system converts the abstract tree hierarchy into concrete renderable geometry. Branches become cylindrical quad strips formed from circular cross-sections. Leaves become oriented quads with attachment and direction data. The system supports runtime LOD through deterministic density culling, maintains consistent UV mapping across varying branch thicknesses, and exports hierarchy metadata for animation.

The code demonstrates pragmatic engineering for size-constrained environments. Vertex formats are carefully designed to pack animation data into standard channels. Coordinate system conversions happen at output time, not throughout generation. UV mapping is world-space based to avoid stretching. The RNG state saving ensures culling consistency without complex bookkeeping.

For creative coders, this architecture shows how to design geometry generators that produce efficient, renderable output. The separation between structure generation and mesh building allows the same tree to be rendered multiple ways—different LODs, different materials, different animation systems—without regenerating the core structure. The density culling system provides smooth degradation as complexity increases, critical for real-time rendering of forests.

The mesh output is the final step in tree generation, transforming mathematical abstractions into visual reality. The trees exist as data until this point—pure information, pure potential. Mesh output makes them visible, rendering botanical algorithms as bark and leaves.
