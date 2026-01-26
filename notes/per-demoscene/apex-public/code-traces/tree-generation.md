# Tree Generation — Complete Code Trace

You've probably seen those tiny 4KB demoscene executables that somehow generate sprawling forests with thousands of branches, each one unique, all within milliseconds. The Arbaro system is the engine behind that magic in the Apex framework.

What makes this remarkable isn't just compression—it's the way a handful of floating-point parameters expand into a recursive growth algorithm that mimics nature. The same principle that guides how a real oak tree knows when to branch, how thick each limb should be, and how much to curve toward the sun.

This trace walks through one complete tree generation cycle, from a compact species descriptor to a fully tessellated mesh. We'll see how 76 bytes of parameters become thousands of positioned vertices, and why that recursion matters.

## The Problem: Compact, Believable Trees

Demoscene productions have brutal constraints. A full 4KB executable must include textures, shaders, music synthesis, and all geometry. You can't ship even a single OBJ file—there's no room.

Trees present a unique challenge. They're structurally complex (thousands of branches), highly variable (no two identical), and viewers instantly recognize when they look wrong. The human brain has evolved to spot unnatural branching patterns.

Traditional solutions fail here. Pre-baked meshes are too large. Simple L-systems look mechanical. What you need is a parametric model that captures the essence of tree growth in minimal data.

## The Weber-Penn Model

Arbaro implements the Weber-Penn tree model, published in 1995 as a way to generate botanically plausible trees through hierarchical subdivision. The key insight: trees grow in levels, where each level follows similar rules but with parameters that scale based on their position in the hierarchy.

Think of it like a phone book for tree anatomy. Instead of hardcoding "branch 47 goes here at this angle," you define patterns: "Level 1 stems have 8-15 children, angled 45-60 degrees, distributed evenly along their length." The algorithm interprets those patterns into specific geometry.

The parameters encode biology. `nCurve` controls tropism (bending toward light). `nTaper` handles how branches thin as they grow. `BaseSize` sets where the trunk stops and branching begins. Together, these create the illusion that something grew, rather than being sculpted.

## The Species Descriptor

Everything starts with `TREESPECIESDESCRIPTOR` (Arbaro.h:90-94), a 76-byte structure that defines a tree species. It contains two sections: per-level parameters (4 levels, allowing trunk → major branches → minor branches → twigs) and global parameters controlling overall shape.

Each level gets its own `TREELEVELPARAMETERS` (Arbaro.h:30-52) specifying branch count, curve behavior, length ratios, and rotation patterns. Global `TREEPARAMETERS` (Arbaro.h:54-88) handle the envelope shape (conical, spherical, flame-shaped), pruning, leaf distribution, and scale.

The clever part: most values are packed as unsigned bytes or half-floats, then decoded at runtime. `nRotate` stores angles as shorts scaled by 100. `Ratio` packs as `unsigned char / 2048.0f` (Arbaro.cpp:88). This compression is what makes 76 bytes sufficient.

## Tree Construction

Creation begins with `Tree::Tree(desc, seed)` (Arbaro.cpp:1072-1076). The constructor delegates immediately to `Params` initialization, which is where those packed bytes expand into usable floats.

```cpp
Tree::Tree(TREESPECIESDESCRIPTOR& desc, unsigned char seed)
  : params(desc, seed)
{
}
```

The seed enables reproducibility—same descriptor + same seed = identical tree. Critical for demos where every frame must be pixel-perfect.

### Parameters Initialization

`Params::Params(desc, Seed)` (Arbaro.cpp:76-141) unpacks the descriptor into working values. It processes 23 global parameters and four sets of level-specific parameters, converting from byte-scale to float-scale.

```cpp
Ratio = desc.Parameters.Ratio / 2048.0f;
RatioPower = desc.Parameters.RatioPower / 32.0f;
Flare = desc.Parameters.Flare / 25.5f - 1.0f;
```

Each conversion reverses the packing applied during descriptor creation. `Ratio` controls trunk thickness relative to length. `RatioPower` governs how child branches scale—linear (1.0), quadratic (2.0), or somewhere between.

The level loop (Arbaro.cpp:110-132) builds four `LevelParams` structures, one for each hierarchy level. Critically, it calculates `mesh_points` (Arbaro.cpp:131), which determines cylindrical tessellation density. Level 0 gets 4 points minimum, decreasing with depth to save polygons where detail isn't visible.

```cpp
for (int x = 0; x < 4; x++) {
  LevelParams &p = lparams[x];
  TREELEVELPARAMETERS& tp = desc.Levels[x];
  p.level = x;
  p.nBranches = tp.nBranches;
  p.nBranchDist = tp.nBranchDist / 255.0f;
  // ... 10 more parameter conversions
  p.mesh_points = 4 - x;
}
```

The `srand(Seed)` call (Arbaro.cpp:134) seeds the C random generator. All subsequent calls to `var()` (Arbaro.cpp:19-22)—the variation helper—pull from this stream, ensuring determinism.

Lobes get special handling (Arbaro.cpp:136-140). If `Lobes > 0`, trunk mesh points increase based on lobe count and smoothness, creating the vertical ridges you see on oak trunks. Subsequent levels scale their mesh points by `(1 + 1.5*Smooth)` for gradual quality falloff.

## Tree::make() — Trunk Creation

After initialization, `Tree::make()` (Arbaro.cpp:1083-1100) generates the structural skeleton. It resets `trunk_rotangle` to zero, then creates `nBranches` trunks at level 0.

```cpp
void Tree::make() {
  trunk_rotangle = 0;

  Transformation transf;
  Transformation trf;

  LevelParams& lpar = params.getLevelParams(0);
  for (int i = 0; i < lpar.nBranches; i++) {
    float angle = var(360);
    float dist = var(lpar.nBranchDist);
    trf = trunkDirection(transf, lpar)
          .translate(D3DXVECTOR3(dist*sin(angle), dist*cos(angle), 0));
    StemImpl* trunk = new StemImpl(this, nullptr, 0, trf, 0);
    trunks.Add(trunk);
    trunk->make();
  }
}
```

The `trunkDirection()` call (Arbaro.cpp:1048-1070) computes orientation using `nRotate` and `nDownAngle`. For multi-trunk trees (like willows), each trunk gets a randomized position offset within `nBranchDist` radius. The transformation matrix `trf` captures both rotation and translation.

Creating `StemImpl(tree, parent, level, transform, offset)` (Arbaro.cpp:435-462) allocates a stem object. The `nullptr` parent indicates these are root-level trunks. The offset parameter (0 for trunks) tracks distance along the parent stem—used later for child branch positioning.

Calling `trunk->make()` immediately triggers recursive growth. This is where the tree unfolds.

## StemImpl::make() — Recursive Growth

Each stem's `make()` method (Arbaro.cpp:464-484) follows a consistent pattern: calculate geometry, prepare child parameters, generate segments, recurse.

```cpp
bool StemImpl::make() {
  stemdata.segmentCount = lpar.nCurveRes;
  stemdata.length = stemLength();
  stemdata.segmentLength = stemdata.length / lpar.nCurveRes;
  stemdata.baseRadius = stemBaseRadius();

  if (stemdata.length > MIN_STEM_LEN && stemdata.baseRadius > MIN_STEM_RADIUS) {
    prepareSubstemParams();
    makeSegments(0, stemdata.segmentCount);
    return true;
  }

  return false;
}
```

The `segmentCount` comes from `nCurveRes`—how many segments to subdivide this stem into. Higher values create smoother curves. `stemLength()` (Arbaro.cpp:486-495) calculates length based on level:

- **Level 0** (trunks): `(nLength + var(nLengthV)) * scale_tree`
- **Level 1**: Parent length × lengthChildMax × shape ratio
- **Level 2+**: Parent lengthChildMax × (parent length - 0.6×offset)

This creates natural tapering—branches near the trunk base are longer, branches near the tip are shorter. The shape ratio (Arbaro.cpp:31-69) applies the envelope function (conical, spherical, etc.) to modulate density.

`stemBaseRadius()` (Arbaro.cpp:497-505) uses similar logic, scaled by `Ratio` for trunks or `RatioPower` for children. The `min(radius, max_radius)` clamp (Arbaro.cpp:504) prevents children from being thicker than their parent at the attachment point—botanically impossible.

If length and radius are sufficient (avoiding degenerate twigs), `prepareSubstemParams()` (Arbaro.cpp:592-624) pre-calculates child branch distribution.

### prepareSubstemParams() — Child Allocation

This method sets up how child branches will be distributed along this stem's segments.

```cpp
void StemImpl::prepareSubstemParams() {
  LevelParams& lpar_1 = par.getLevelParams(stemlevel + 1);

  stemdata.lengthChildMax = lpar_1.nLength + var(lpar_1.nLengthV);

  float stems_max = (float)lpar_1.nBranches;
  float substem_cnt;

  if (stemlevel == 0) {
    substem_cnt = stems_max;
    stemdata.substemsPerSegment = substem_cnt / segmentCount / (1 - par.BaseSize);
  }
  // Level 1 and 2+ calculations follow...

  stemdata.substemRotangle = 0;

  if (lpar.level == par.Levels - 1)
    stemdata.leavesPerSegment = leavesPerBranch() / stemdata.segmentCount;
}
```

The key is `substemsPerSegment`, a fractional value that gets distributed via error propagation (more on that shortly). For trunks, it's total children divided by segments, adjusted for `BaseSize`—the trunk region below branching height.

Leaf-bearing stems (final level) calculate `leavesPerSegment` using `leavesPerBranch()` (Arbaro.cpp:626-634), which applies the envelope shape to determine leaf density based on position along the parent.

## makeSegments() — Structural Recursion

This is the heart of tree generation (Arbaro.cpp:636-675). It builds the segment chain, applying curvature and spawning children.

```cpp
int StemImpl::makeSegments(int start_seg, int end_seg) {
  Transformation trf = transf;

  for (int s = start_seg; s < end_seg; s++) {
    if (s != 0)
      trf = newDirection(trf, s);

    SegmentImpl* segment = new SegmentImpl(this, s, trf,
      stemRadius(s*stemdata.segmentLength),
      stemRadius((s+1)*stemdata.segmentLength));
    segment->make();
    segments.Add(segment);

    if (lpar.level < par.Levels - 1)
      makeSubstems(segment);
    else
      makeLeaves(segment);

    trf = trf.translate(trf.getZ() * stemdata.segmentLength);

    if (s < end_seg - 1) {
      int segm = makeClones(trf, s);
      if (segm >= 0) return segm;
    }
  }

  return -1;
}
```

Each iteration creates a `SegmentImpl` representing a portion of the stem. Before creating it, `newDirection()` (Arbaro.cpp:677-713) applies curvature by rotating the transformation matrix.

```cpp
Transformation StemImpl::newDirection(Transformation trf, int nsegm) {
  float delta;
  if (lpar.nCurveBack == 0) {
    delta = lpar.nCurve;
  } else {
    if (nsegm < (lpar.nCurveRes + 1) / 2) {
      delta = lpar.nCurve * 2;
    } else {
      delta = lpar.nCurveBack * 2;
    }
  }
  delta = delta / lpar.nCurveRes + stemdata.splitCorrection;

  trf.rotx(delta);

  if (lpar.nCurveV > 0) {
    delta = var(lpar.nCurveV) / lpar.nCurveRes;
    trf.rotaxisz(delta, 180 + var(180));
  }

  if (par.AttractionUp != 0 && stemlevel >= 2) {
    D3DXVECTOR3 z = trf.getZ();
    float declination = acos(z.z);
    float curve_up = par.AttractionUp * fabs(declination * sinf(declination)) / lpar.nCurveRes;
    trf.rotaxis(-curve_up * 180 / PI, D3DXVECTOR3(-z.y, z.x, 0));
  }
  return trf;
}
```

The `nCurveBack` logic creates S-curves—branch tips curve back toward the original direction. `nCurveV` adds random lateral bending. `AttractionUp` simulates phototropism, gently bending branches upward when they droop too far.

After creating the segment, the code calls either `makeSubstems()` or `makeLeaves()` depending on hierarchy level. The transformation then advances by `segmentLength` along its local Z-axis.

Finally, `makeClones()` handles splitting—when one stem divides into multiple continuations. Think of a trunk forking into two main limbs.

## makeSubstems() — Child Branch Creation

When a segment should spawn child branches, `makeSubstems()` (Arbaro.cpp:715-762) determines exactly where and how many.

```cpp
void StemImpl::makeSubstems(SegmentImpl* segment) {
  LevelParams& lpar_1 = par.getLevelParams(stemlevel + 1);

  float subst_per_segm;
  float offs = 0;

  if (stemlevel > 0) {
    subst_per_segm = stemdata.substemsPerSegment;
    if (segment->index == 0)
      offs = parent->stemRadius(offset) / stemdata.segmentLength;
  } else if (segment->index*stemdata.segmentLength > par.BaseSize*stemdata.length) {
    subst_per_segm = stemdata.substemsPerSegment;
  } else if ((segment->index + 1)*stemdata.segmentLength <= par.BaseSize*stemdata.length) {
    return;
  } else {
    offs = (par.BaseSize*stemdata.length - segment->index*stemdata.segmentLength) / stemdata.segmentLength;
    subst_per_segm = stemdata.substemsPerSegment * (1 - offs);
  }

  int substems_eff = PropagateError(lpar.substemErrorValue, subst_per_segm);
  if (substems_eff <= 0) return;

  float dist = (1.0f - offs) / substems_eff * lpar_1.nBranchDist;

  for (int s = 0; s < substems_eff; s++) {
    float where = offs + dist/2 + s*dist + var(dist*0.25f);
    float offset = (segment->index + where) * stemdata.segmentLength;

    Transformation trf = substemDirection(segment->transf, offset);
    trf = segment->substemPosition(trf, where);

    StemImpl* substem = new StemImpl(tree, this, stemlevel + 1, trf, offset);
    substem->stemdata.index = substems.NumItems();

    if (substem->make())
      substems.Add(substem);
  }
}
```

The `PropagateError()` function (Arbaro.cpp:24-29) is crucial here. Since `subst_per_segm` is often fractional (e.g., 2.3 branches per segment), you can't just round—it would create visible banding. Error diffusion distributes remainders across segments, so 2.3 branches/segment becomes 2, 2, 3, 2, 2, 3 over six segments.

```cpp
int PropagateError(float &err, float Val) {
  int eff = (int)(Val + err + 0.5);
  err -= (eff - Val);
  return eff;
}
```

The `err` parameter accumulates rounding error, spreading it naturally. This is the same technique used in dithering algorithms.

For each child branch, `substemDirection()` (Arbaro.cpp:764-793) calculates orientation using `nRotate`, `nRotateV`, `nDownAngle`, and `nDownAngleV` from the child level's parameters. The position comes from `substemPosition()` (Arbaro.cpp:330-344), which translates along the parent segment's local axis.

Creating the child `StemImpl` with `stemlevel + 1` triggers another `make()` call, recursing down the hierarchy. This continues until reaching the final level or until stems become too small.

## SegmentImpl::make() — Subsegment Detail

Each segment subdivides further into subsegments (Arbaro.cpp:268-328) for fine-grained radius variation and flare effects.

```cpp
void SegmentImpl::make() {
  int cnt = 10;

  D3DXVECTOR3 dir = transf.getZ() * (float)length;
  D3DXVECTOR3 upperPos = transf.Position + dir;

  // Spherical end for certain taper values
  if (lpar.nTaper > 1 && lpar.nTaper <= 2 && (index == stem->stemdata.segmentCount - 1)) {
    for (int i = 1; i < cnt; i++) {
      float pos = length - length / powf(2.0f, (float)i);
      subsegments.Add(new SubsegmentImpl(transf.Position + (dir*(pos/length)),
        stem->stemRadius(index*length + pos), pos, this));
    }
    subsegments.Add(new SubsegmentImpl(upperPos, _rad2, length, this));
    return;
  }

  cnt = 1;

  if (lpar.nTaper <= 2) {
    // Flare at trunk base
    if (lpar.level == 0 && par.Flare != 0 && index == 0) {
      for (int i = 9; i >= 0; i--) {
        float pos = length / powf(2.0f, (float)i);
        subsegments.Add(new SubsegmentImpl(transf.Position + (dir*(pos/length)),
          stem->stemRadius(index*length + pos), pos, this));
      }
      return;
    }
  } else {
    cnt = 20; // Normal subdivision
  }

  for (int i = 1; i < cnt + 1; i++) {
    float pos = i*length / cnt;
    subsegments.Add(new SubsegmentImpl(transf.Position + (dir*(pos/length)),
      stem->stemRadius(index*length + pos), pos, this));
  }
}
```

The flare logic (Arbaro.cpp:310-318) creates the characteristic widening at tree bases. Instead of linear subdivision, it uses exponential spacing (`2^i`), packing more subsegments near the base where radius changes rapidly.

Spherical ends (Arbaro.cpp:294-303) round off branch tips when `nTaper` is between 1 and 2, avoiding the artificial look of abruptly truncated cylinders.

Normal subsegments just evenly divide the segment. Each `SubsegmentImpl` (Arbaro.cpp:1130-1136) stores position, radius, and distance—the data needed for mesh generation later.

## makeLeaves() — Foliage Distribution

When a stem reaches the final level, `makeLeaves()` (Arbaro.cpp:795-863) populates it with leaf geometry instead of child branches.

```cpp
void StemImpl::makeLeaves(SegmentImpl* segment) {
  int leaves_eff = PropagateError(par.leavesErrorValue, stemdata.leavesPerSegment);

  if (leaves_eff <= 0)
    return;

  float offs;
  if (segment->index == 0)
    offs = parent->stemRadius(offset) / stemdata.segmentLength;
  else
    offs = 0;

  float dist = (1.0f - offs) / leaves_eff;

  for (int s = 0; s < leaves_eff; s++) {
    float where = offs + dist/2 + s*dist + var(dist/2);
    Transformation& trf = substemDirection(segment->transf,
      (segment->index + where)*stemdata.segmentLength)
      .translate(segment->transf.getZ()*(where*stemdata.segmentLength));

    LeafImpl* leaf = new LeafImpl(trf);
    leaf->make(par);
    leaves.Add(leaf);
  }
}
```

Leaves use the same error propagation and distribution logic as substems, ensuring even coverage without banding artifacts. Each `LeafImpl` (Arbaro.cpp:221-233) stores its transformation and can apply `LeafBend` to orient toward the tree center.

## makeClones() — Stem Splitting

When stems split (forking trunks, dividing branches), `makeClones()` (Arbaro.cpp:885-913) creates continuations.

```cpp
int StemImpl::makeClones(Transformation trf, int nseg) {
  int seg_splits_eff;

  if (stemlevel == 0 && nseg == 0 && par._0BaseSplits > 0)
    seg_splits_eff = par._0BaseSplits;
  else
    seg_splits_eff = PropagateError(lpar.splitErrorValue, lpar.nSegSplits);

  if (seg_splits_eff < 1) return -1;

  float s_angle = 360 / (float)(seg_splits_eff + 1);

  for (int i = 0; i < seg_splits_eff; i++) {
    StemImpl* newclone = clone(trf, nseg + 1);
    newclone->transf = newclone->split(trf, s_angle*(1+i), nseg, seg_splits_eff);

    int segm = newclone->makeSegments(nseg + 1, newclone->stemdata.segmentCount);
    if (segm >= 0) return segm;

    clones.Add(newclone);
  }

  trf = split(trf, 0, nseg, seg_splits_eff);
  return -1;
}
```

Each clone gets created via `clone()` (Arbaro.cpp:915-927), which copies `stemdata` but marks `isClone = true` and sets `startSegment` to skip already-generated segments. The `split()` method (Arbaro.cpp:929-963) applies `nSplitAngle` and divergence rotation to separate the forks.

The original stem also calls `split()` with `s_angle = 0`, adjusting its own trajectory to match the forking pattern.

## From Structure to Mesh

At this point, the tree exists as a hierarchical data structure—`Tree` contains `trunks[]`, each `StemImpl` contains `segments[]` and `substems[]`, each `SegmentImpl` contains `subsegments[]`. No vertices, no polygons. Just transformations and radii.

Mesh generation happens in two passes: `BuildTree()` for branch geometry (Arbaro.cpp:1102-1114), `BuildLeaves()` for foliage (Arbaro.cpp:1116-1128).

```cpp
int Tree::BuildTree(CphxMesh *Mesh, unsigned char* levelDensities, BranchData* branchOutput) {
  idx = 0;

  BranchData* data = branchOutput;

  aholdrand = 0;
  for (int x = 0; x < trunks.NumItems(); x++)
    trunks[x]->BuildMesh(-1, Mesh, levelDensities, data);
  Mesh->SmoothGroupSeparation = 2.0f;

  return idx;
}
```

The `levelDensities` array allows selective LOD—render only 50% of level 2 branches, 25% of level 3. The custom `aholdrand` seed (Arbaro.cpp:965-970) ensures deterministic culling across frames.

## StemImpl::BuildMesh() — Recursive Tessellation

Each stem builds its mesh recursively (Arbaro.cpp:972-1016), traversing children first (depth-first), then generating its own cylindrical geometry.

```cpp
void StemImpl::BuildMesh(int parentID, CphxMesh *mesh, unsigned char* levelDensities, BranchData *&data) {
  int currIdx = idx;

  data->parentIndex = parentID;
  data->Rotation = transf.Rotation;
  data->Position = transf.Position;

  data++;
  idx++;

  int cntr = 0;
  long ssrand = aholdrand;

  for (int x = 0; x < substems.NumItems(); x++)
    if (arand() % 255 <= *levelDensities)
      substems[x]->BuildMesh(currIdx, mesh, levelDensities + 1, data);

  aholdrand = ssrand;

  for (int x = 0; x < clones.NumItems(); x++)
    if (arand() % 255 <= *levelDensities)
      clones[x]->BuildMesh(currIdx, mesh, levelDensities + 1, data);

  aholdrand = ssrand;

  float branchDist = 0;
  float uvscale = max(1.0f, (int)(segments[0]->_rad1 * PI * 2));

  for (int x = 0; x < segments.NumItems(); x++)
    segments[x]->BuildMesh(currIdx, mesh, cntr, branchDist, uvscale, isClone);
}
```

The `BranchData` output (Arbaro.h:98-106) stores metadata for skeletal animation or procedural effects—each branch knows its parent index, rotation, position, and thickness. This enables systems like wind sway or collision response.

Restoring `aholdrand` between substems and clones (Arbaro.cpp:990, 996) ensures random culling is independent of traversal order—substems at index 5 always get the same random test regardless of how many clones preceded them.

## SegmentImpl::BuildMesh() — Cylindrical Geometry

Each segment tessellates into a cylindrical mesh section (Arbaro.cpp:411-425).

```cpp
void SegmentImpl::BuildMesh(int branchIdx, CphxMesh *mesh, int &cntr, float &branchDist, float uvscale, bool isClone) {
  if (!subsegments.NumItems() || cntr == 0)
    getSectionPoints(branchIdx, mesh, (float)_rad1*(isClone ? 0.9f : 1.0f), transf, cntr, branchDist, branchDist, uvscale);

  float last = branchDist;
  for (int x = 0; x < subsegments.NumItems(); x++) {
    D3DXVECTOR3 d = subsegments[x]->pos - transf.Position;
    float l = branchDist + D3DXVec3Length(&d);
    getSectionPoints(branchIdx, mesh, (float)subsegments[x]->rad, transf.translate(d), cntr, last, l, uvscale);
    last = l;
  }
  branchDist = last;
}
```

The first call to `getSectionPoints()` (Arbaro.cpp:360-409) creates the base ring of vertices. Then each subsegment adds another ring, and quads connect adjacent rings.

```cpp
void SegmentImpl::getSectionPoints(int branchIdx, CphxMesh *mesh, float rad, Transformation& trf, int &counter, float branchDist1, float branchDist2, float uvscale) {
  int pt_cnt = lpar.mesh_points;
  int vxb = mesh->Vertices.NumItems() - pt_cnt;

  if (rad < 0.000001) {
    // Degenerate tip - single vertex
    D3DXVECTOR3 vx = trf.apply(*(D3DXVECTOR3*)leafUVData);
    mesh->AddVertex(vx.x, vx.z, vx.y);
    // ...
  } else {
    for (int i = 0; i < pt_cnt; i++) {
      float angle = i*360.0f / pt_cnt;
      if (lpar.level == 0 && par.Lobes != 0)
        angle -= 10.0f / par.Lobes;

      D3DXVECTOR3 pt(cos(angle*PI/180), sin(angle*PI/180), 0);

      float multiplier = rad;

      if (lpar.level == 0 && (par.Lobes != 0 || par._0ScaleV != 0))
        multiplier = (rad * (1 + var(par._0ScaleV)/subsegments.NumItems())) * (1.0 + par.LobeDepth*cos(par.Lobes*angle*PI/180.0));

      pt = trf.apply(pt*multiplier);
      mesh->AddVertex(pt.x, pt.z, pt.y);

      if (counter) {
        float xc1 = i / (float)pt_cnt * uvscale;
        float xc2 = (i+1) / (float)pt_cnt * uvscale;
        mesh->AddPolygon(vxb+i+pt_cnt, vxb+(i+1)%pt_cnt+pt_cnt, vxb+(i+1)%pt_cnt, vxb+i, ...);
      }
    }
  }
  counter++;
}
```

The lobe calculation (Arbaro.cpp:392-393) modulates radius by `LobeDepth * cos(Lobes * angle)`, creating sinusoidal ridges around the cylinder. Combined with `_0ScaleV` variation, this produces organic bark textures without normal maps.

UV coordinates use `branchDist` for the V coordinate (Arbaro.cpp:404), wrapping texture vertically along the branch length. The U coordinate (Arbaro.cpp:402-403) wraps horizontally around the cylinder, scaled by `uvscale` to account for radius—thicker branches get more texture repetitions.

When radius approaches zero (Arbaro.cpp:365-378), the code collapses the ring to a single vertex to close branch tips. Quads degenerate into triangles, preventing holes.

## LeafImpl::BuildMesh() — Billboard Geometry

Leaves generate as camera-facing quads (Arbaro.cpp:235-261).

```cpp
void LeafImpl::BuildMesh(int branchIdx, CphxMesh *mesh, float leafScale, float leafScaleX, float leafStemLen) {
  int vxc = mesh->Vertices.NumItems();

  D3DXVECTOR3 root = transf.apply(D3DXVECTOR3(0, 0, 0));
  D3DXVECTOR3 dir = transf.apply(D3DXVECTOR3(0, 0, 1)) - root;

  for (int x = 0; x < 4; x++) {
    D3DXVECTOR3 &vx = transf.apply(D3DXVECTOR3(
      leafVertexData[x][0] * leafScaleX,
      0,
      leafVertexData[x][1] + leafStemLen * 2) * leafScale * 0.5f);

    mesh->AddVertex(vx.x, vx.z, vx.y);
    CphxVertex &vert = mesh->Vertices[mesh->Vertices.NumItems() - 1];
    vert.Position2 = D3DXVECTOR3(root.x, root.z, root.y);
  }

  mesh->AddPolygon(vxc+0, vxc+1, vxc+2, vxc+3, ...);

  for (int x = 0; x < 4; x++) {
    CphxPolygon &p = mesh->Polygons[mesh->Polygons.NumItems() - 1];
    p.Texcoords[x][2].x = dir.x;
    p.Texcoords[x][2].y = dir.z;
    p.Texcoords[x][3].x = dir.y;
  }
}
```

The quad vertices use `leafVertexData[]` offsets (Arbaro.cpp:16)—`{-1,0}, {1,0}, {1,2}, {-1,2}`—scaled by `leafScale` and `leafScaleX` to create rectangular billboards.

Storing `root` position in `Position2` (Arbaro.cpp:248) enables vertex shaders to anchor the leaf base while animating the tip. The `dir` vector in texture coordinates (Arbaro.cpp:257-259) provides leaf orientation for effects like directional lighting or wind alignment.

## Output and Completion

After all `BuildMesh()` calls complete, the `CphxMesh` object (passed to `Tree::BuildTree()`) contains complete vertex and polygon data. The `BranchData` array holds skeletal information for `idx` branches (Arbaro.cpp:1113).

The mesh is immediately ready for rendering. Vertex positions are in world space. Normals can be computed via standard edge-cross algorithms. UVs are pre-assigned for cylindrical unwrapping.

Because the entire generation is seeded, the same `TREESPECIESDESCRIPTOR` and seed produce pixel-identical results every time. This enables reproducible content for demos where file storage isn't possible.

## Implications for Framework Design

The Arbaro system demonstrates several patterns worth extracting:

**Hierarchical parameter propagation.** Instead of passing 30+ parameters to every function, the `Params` and `LevelParams` structures travel with each object. Child objects reference parent structures, avoiding copies. This reduces stack pressure in deeply recursive code.

**Error diffusion for fractional counts.** When distributing N items across M containers where N/M is fractional, `PropagateError()` prevents banding by accumulating rounding error. The same technique applies to particle spawning, texture sampling, or any scenario where discrete elements approximate continuous distributions.

**Transformation as state.** Rather than tracking global matrices and pushing/popping, each object stores its local `Transformation`. Children compute their own by composing with parent transforms. This eliminates stack management and naturally supports breadth-first or depth-first traversal.

**Structure-then-mesh separation.** The two-phase design (generate tree structure, then build mesh) decouples logic from rendering. The structure can be serialized, analyzed for physics collision, or rendered at multiple LODs without regenerating. A Rust implementation could use `Tree::make()` to return a pure data structure, then pass it to separate mesh builders, GPU instancers, or even network serialization.

**Deterministic randomness.** Seeding `srand()` and using `rand()` directly enables full reproducibility. Rust's `SmallRng` or `StdRng` with explicit seeding provides the same guarantees without global state. For multithreaded generation, each stem could carry its own PRNG seeded from parent offset, eliminating contention.

**Compact parametric encoding.** 76 bytes define infinite tree variations. This suggests a broader principle: encode artistic intent as parameters, not data. Procedural generation trades CPU time for storage, ideal for constrained environments or runtime variation.

## Edge Cases and Gotchas

**Pruning disabled by default.** The `#ifdef PHX_ARBARO_HAVE_PRUNING` gates (Arbaro.cpp:459-474, 552-590, 649-664, 865-883) suggest pruning is expensive. It iteratively shortens branches that extend beyond the envelope, requiring multiple `makeSegments()` passes. For demos, disabling pruning and carefully tuning envelopes is faster.

**Helix support also optional.** The `#ifdef PHX_ARBARO_HAVE_HELIX_SUPPORT` blocks (Arbaro.cpp:272-287, 332-343) enable spiral branching patterns when `nCurveV < 0`. Disabled to save code size when not needed—another example of feature gating for compression.

**Transformation matrix precision.** All transformations use `D3DXMATRIX`, which accumulates floating-point error through composition. After 20+ hierarchy levels, tips might drift slightly. For deep trees, consider periodically renormalizing rotation matrices or using quaternions.

**UV scale discontinuities.** The `uvscale` calculation (Arbaro.cpp:1001, 1005) uses `max(1.0f, (int)(rad * PI * 2))`, which can cause UV stretching if radii change drastically between parent and child. Smoothing this value across levels would improve texture coherence.

**Clone rendering offset.** Clones render at 0.9× radius (Arbaro.cpp:414) to avoid Z-fighting where splits occur. This is a cosmetic hack—proper fix would offset clone start positions slightly or use depth bias. Rust implementations should consider epsilon-offsetting vertices instead.

## References

- Weber, J., & Penn, J. (1995). "Creation and Rendering of Realistic Trees." SIGGRAPH '95.
- Arbaro implementation (Java): http://arbaro.sourceforge.net/
- Apophysis flare equations (influence on getShapeRatio): Apophysis 2.0 source
- Error diffusion (Floyd-Steinberg): R. W. Floyd and L. Steinberg (1976). "An Adaptive Algorithm for Spatial Grey Scale."
- Phoenix Engine mesh format: `/apEx/Phoenix/Mesh.h`

---

**File locations:**
- Arbaro.h: `/demoscene/apex-public/apEx/Phoenix/Arbaro.h`
- Arbaro.cpp: `/demoscene/apex-public/apEx/Phoenix/Arbaro.cpp`
