# Phoenix Arbaro Parameter Reference

You're staring at a 220-byte binary blob. Within those bytes lies the entire specification for a tree species—trunk thickness, branch angles, leaf distribution, root flare, everything. Change byte 42 from 0x7C to 0x3A and your oak becomes a willow. Flip byte 18 from 0x03 to 0x06 and your conifer inverts into a parasol. This isn't compression in the traditional sense—it's a domain-specific language for botanical form, where each parameter is a word and the tree is the sentence.

The genius of Arbaro's parameter system is its dual nature. On disk, parameters pack tightly into quantized bytes and half-floats, optimized for 64k demo constraints. At runtime, the Params constructor decodes them into full floats with proper scaling, trading 220 bytes of storage for kilobytes of accessible values. This separation lets artists work with intuitive ranges (angles in degrees, probabilities as 0-1 floats) while the binary representation squeezes every bit.

Understanding these parameters unlocks procedural botany. Most tree generation systems—SpeedTree, L-systems, algorithmic growth simulations—expose hundreds of knobs organized into inscrutable hierarchies. Arbaro distills this to 30 global parameters plus 16 per-level parameters across 4 levels, totaling around 94 values. That's the entire parameter space. Learn these 94 dimensions and you can generate any tree from coastal redwoods to Japanese maples to alien flora.

This document catalogs every parameter: storage format, decoded range, visual effect, and interactions. Think of it as the reference grammar for the tree language. Parameters don't exist in isolation—`Ratio` affects `RatioPower`, `Shape` modulates `nBranches`, `nCurve` combines with `nCurveBack` for S-shaped stems. The art is learning which combinations produce oak vs. pine vs. palm.

## Parameter Architecture

Arbaro organizes parameters into three structures, defined in Arbaro.h:

### TREEPARAMETERS: Global Tree Properties

The TREEPARAMETERS struct (Arbaro.h:54-88) holds 30 parameters affecting the entire tree. These control overall scale, shape envelope, root characteristics, leaf behavior, and pruning. One instance per tree species.

### TREELEVELPARAMETERS: Per-Level Branching Rules

The TREELEVELPARAMETERS struct (Arbaro.h:30-52) holds 16 parameters controlling branching behavior at a specific hierarchy level. Four instances per species: Level 0 (trunk), Level 1 (primary branches), Level 2 (secondary branches), Level 3 (twigs/leaves).

### TREESPECIESDESCRIPTOR: Complete Species Definition

The TREESPECIESDESCRIPTOR struct (Arbaro.h:90-94) combines four TREELEVELPARAMETERS arrays with one TREEPARAMETERS structure, creating the complete species definition:

```cpp
struct TREESPECIESDESCRIPTOR {
    TREELEVELPARAMETERS Levels[4];  // 4 levels * ~16 bytes = ~64 bytes
    TREEPARAMETERS Parameters;       // ~156 bytes
};  // Total: ~220 bytes
```

This is what gets stored in the demo executable. At runtime, the Params constructor (Arbaro.cpp:76-141) decodes it into float-based LevelParams and Params instances.

## Decoding Process

The Params constructor performs all quantization-to-float conversions:

```cpp
Params::Params(TREESPECIESDESCRIPTOR& desc, unsigned char Seed) {
    srand(Seed);  // Seed determines random variation per tree instance

    // Decode global parameters with scaling
    BaseSize = desc.Parameters.BaseSize / 255.0f;
    Ratio = desc.Parameters.Ratio / 2048.0f;
    RatioPower = desc.Parameters.RatioPower / 32.0f;
    Flare = desc.Parameters.Flare / 25.5f - 1.0f;
    LeafQuality = desc.Parameters.LeafQuality / 255.0f;
    AttractionUp = desc.Parameters.AttractionUp / 12.7f;
    LeafBend = desc.Parameters.LeafBend / 255.0f;
    Smooth = desc.Parameters.Smooth / 255.0f;
    PruneRatio = desc.Parameters.PruneRatio / 255.0f;
    PruneWidth = desc.Parameters.PruneWidth / 255.0f;
    PruneWidthPeak = desc.Parameters.PruneWidthPeak / 255.0f;

    // Direct copies for types that don't need scaling
    Levels = desc.Parameters.Levels;
    Lobes = desc.Parameters.Lobes;
    _0BaseSplits = desc.Parameters._0BaseSplits;
    Leaves = desc.Parameters.Leaves;
    Shape = (ShapeType)desc.Parameters.Shape;
    LeafDistrib = (ShapeType)desc.Parameters.LeafDistrib;
    Scale = desc.Parameters.Scale;          // Already half-float
    _0Scale = desc.Parameters._0Scale;
    _0ScaleV = desc.Parameters._0ScaleV;
    LeafScale = desc.Parameters.LeafScale;
    LeafScaleX = desc.Parameters.LeafScaleX;
    LeafStemLen = desc.Parameters.LeafStemLen;
    LobeDepth = desc.Parameters.LobeDepth;
    PrunePowerLow = desc.Parameters.PrunePowerLow;
    PrunePowerHigh = desc.Parameters.PrunePowerHigh;

    // Decode level parameters
    for (int x = 0; x < 4; x++) {
        LevelParams &p = lparams[x];
        TREELEVELPARAMETERS& tp = desc.Levels[x];

        p.level = x;
        p.nBranches = tp.nBranches;
        p.nBranchDist = tp.nBranchDist / 255.0f;
        p.nRotate = tp.nRotate;
        p.nRotateV = tp.nRotateV;
        p.nDownAngle = tp.nDownAngle;
        p.nDownAngleV = tp.nDownAngleV;
        p.nCurveRes = tp.nCurveRes;
        p.nSegSplits = tp.nSegSplits;
        p.nLength = tp.nLength;
        p.nLengthV = tp.nLengthV;
        p.nTaper = tp.nTaper / 255.0f * 3.0f;  // Map 0-255 to 0-3
        p.nCurve = tp.nCurve;
        p.nCurveV = tp.nCurveV;
        p.nCurveBack = tp.nCurveBack;
        p.nSplitAngle = tp.nSplitAngle;
        p.nSplitAngleV = tp.nSplitAngleV;

        // Mesh LOD: fewer points for higher levels
        p.mesh_points = 4 - x;
    }

    // Override trunk mesh resolution for lobes
    if (Lobes > 0)
        lparams[0].mesh_points = max((int)(Lobes * pow(2.0, 1 + 2.5*Smooth)),
                                     (int)(4 * (1 + 2*Smooth)));

    // Increase resolution for smooth mode
    for (int i = 1; i < 4; i++)
        lparams[i].mesh_points = max(3, (int)(lparams[i].mesh_points * (1 + 1.5*Smooth)));
}
```

The decoding reveals the quantization strategies:

- **Division by 255**: Maps unsigned byte (0-255) to 0.0-1.0 range
- **Division by 2048**: Packs small positive floats into unsigned byte with finer precision
- **Division by 32**: Packs signed values around zero into signed byte
- **Offset subtraction**: `Flare / 25.5 - 1.0` maps 0-255 to -1.0 to +9.0
- **Half-floats (D3DXFLOAT16)**: 16-bit IEEE 754 floats, decoded automatically by DirectX
- **Direct integers**: Counts like `Levels`, `Lobes`, `Leaves` store directly

## Global Parameters (TREEPARAMETERS)

These parameters affect the entire tree, not individual branching levels.

### Structure Parameters

#### Levels
**Purpose:** Branching hierarchy depth
**Storage:** `unsigned char` (Arbaro.h:56)
**Range:** 0-9 (practical limit: 0-4)
**Decoding:** Direct copy

Determines how many recursion levels the tree generates:
- **0**: Trunk only, no branches
- **1**: Trunk + primary branches (simple tree)
- **2**: Trunk + primary + secondary branches (typical tree)
- **3**: Trunk + primary + secondary + twigs with leaves (full tree)
- **4**: Maximum detail with sub-twigs

Higher levels exponentially increase complexity. Level 3 with 20 branches per level creates `1 + 20 + 400 + 8000 = 8,421` stems. Level 4 adds another 20x multiplier.

**Visual Effect:** More levels = bushier tree with finer branching detail
**Typical Values:** Shrubs: 2, Trees: 3, Complex trees: 4

#### Shape
**Purpose:** Overall tree silhouette envelope
**Storage:** `TREESHAPE` enum (unsigned char, Arbaro.h:60)
**Range:** 0-8 (enum values)
**Decoding:** Cast to `ShapeType` enum

Controls how branch density distributes vertically via the `getShapeRatio()` function (Arbaro.cpp:31-69). This affects branch count, length, and leaf distribution.

| Value | Name | Formula | Profile | Tree Types |
|-------|------|---------|---------|------------|
| 0 | Conical | `ratio` | Linear taper ▲ | Spruce, fir, young conifers |
| 1 | Spherical | `0.2 + 0.8*sin(π*ratio)` | Rounded ● | Oak, maple, mature deciduous |
| 2 | Hemispherical | `0.2 + 0.8*sin(π*ratio/2)` | Flat-bottom dome ◗ | Umbrella trees, some palms |
| 3 | Cylindrical | `1.0` | Uniform ▮ | Poplars, columnar trees |
| 4 | Tapered_Cylindrical | `0.5 + 0.5*ratio` | Slight taper ▱ | Generic broadleaf |
| 5 | Flame | `ratio ≤ 0.7 ? ratio/0.7 : (1-ratio)/0.3` | Bulge at 70% ⧫ | Cypress, Italian cypress |
| 6 | Inverse_Conical | `1 - 0.8*ratio` | Dense top ▼ | Willows, weeping forms |
| 7 | Tend_Flame | `ratio ≤ 0.7 ? 0.5+0.5*ratio/0.7 : 0.5+0.5*(1-ratio)/0.3` | Softer flame ◊ | Cedars |
| 8 | Envelope | Custom via pruning | User-defined ⬡ | Artistic shapes |

**Visual Effect:** Defines where branches concentrate vertically
**Typical Values:** Conifers: 0, Broadleaf: 1, Columnar: 3

#### LeafDistrib
**Purpose:** Vertical leaf distribution pattern
**Storage:** `TREESHAPE` enum (unsigned char, Arbaro.h:61)
**Range:** 0-8 (same enum as Shape)
**Decoding:** Cast to `ShapeType` enum

Uses the same shape functions as `Shape`, but applies only to leaf placement. Allows leaves to concentrate differently than branches.

**Visual Effect:** Controls where foliage appears (e.g., concentrate leaves at crown)
**Typical Values:** Often matches Shape, or Spherical (1) for canopy emphasis

#### LeafShape
**Purpose:** Leaf geometry type
**Storage:** `unsigned char` (Arbaro.h:59)
**Range:** Enum (actual values undefined in provided code)
**Decoding:** Direct copy

**Note:** The provided code doesn't show LeafShape usage in mesh generation—all leaves render as quads. This parameter likely reserved for future leaf geometry variations.

#### Lobes
**Purpose:** Number of radial lobes on trunk cross-section
**Storage:** `unsigned char` (Arbaro.h:57)
**Range:** 0-255
**Decoding:** Direct copy

Creates non-circular trunk profiles by modulating radius with `cos(Lobes * angle)` (Arbaro.cpp:876). Higher values create star-shaped cross-sections.

**Visual Effect:**
- **0**: Circular trunk (smooth bark)
- **3-5**: Subtle grooves (oak bark texture)
- **10+**: Pronounced star shape (fluted columns)

Also increases mesh resolution: `mesh_points = max(Lobes * 2^(1+2.5*Smooth), 4*(1+2*Smooth))` (Arbaro.cpp:137)

**Typical Values:** Smooth bark: 0, Textured bark: 3-7, Stylized: 10+

#### _0BaseSplits
**Purpose:** Number of trunk base splits
**Storage:** `unsigned char` (Arbaro.h:58)
**Range:** 0-255
**Decoding:** Direct copy

Forces trunk to split at base (segment 0) into multiple main stems. Creates multi-trunk trees like some oaks or birch groves.

**Visual Effect:**
- **0**: Single trunk
- **1-3**: Multi-trunk tree (Y-shaped base)
- **4+**: Grove appearance

Base splits occur at ground level, before normal segment splitting (Arbaro.cpp:889-890).

**Typical Values:** Single trunk: 0, Multi-trunk: 2-4

### Size Parameters

#### Scale
**Purpose:** Overall tree size multiplier
**Storage:** `D3DXFLOAT16` (Arbaro.h:82)
**Range:** 0.00001 to ~65504 (half-float max)
**Decoding:** Direct copy (half-float auto-converts)

Multiplies all absolute dimensions: trunk length, branch spacing, radii. Does not affect ratios or angles.

**Visual Effect:** Scales entire tree uniformly
**Typical Values:** Small tree: 5-10, Medium: 20-50, Large: 100+

#### _0Scale
**Purpose:** Trunk radius scale multiplier
**Storage:** `D3DXFLOAT16` (Arbaro.h:83)
**Range:** 0.00001 to ~65504
**Decoding:** Direct copy

Multiplies trunk radius after all other calculations. Typically 1.0, but allows thick-trunk variations without changing `Ratio`.

Applied in `stemRadius()` flare calculation (Arbaro.cpp:547):
```cpp
radius *= par._0Scale * (1 + par.Flare * (pow(100, max(0, 1 - 8*Z)) - 1) / 100.0f);
```

**Visual Effect:** Thicker/thinner trunk without changing proportions
**Typical Values:** Normal: 1.0, Thick trunk: 1.5-2.0, Thin: 0.5-0.8

#### _0ScaleV
**Purpose:** Trunk radius variation (circumference noise)
**Storage:** `D3DXFLOAT16` (Arbaro.h:84)
**Range:** 0 to ~65504
**Decoding:** Direct copy

Adds random variation to trunk circumference, creating irregular cross-sections. Applied per subsegment (Arbaro.cpp:393):
```cpp
multiplier = rad * (1 + var(par._0ScaleV) / subsegments.NumItems())
           * (1.0 + par.LobeDepth * cos(par.Lobes * angle * PI / 180));
```

**Visual Effect:** Organic irregularity, like natural bark bumps
**Typical Values:** Smooth trunk: 0, Irregular: 0.1-0.5

#### Ratio
**Purpose:** Base radius-to-length ratio
**Storage:** `unsigned char` (Arbaro.h:68)
**Range:** 0.00001 to ~0.125 (byte / 2048)
**Decoding:** `Ratio / 2048.0f` (Arbaro.cpp:88)

Defines trunk base radius as fraction of trunk length. Higher values = thicker trunks.

Applied in trunk radius calculation (Arbaro.cpp:500):
```cpp
if (stemlevel == 0)
    return stemdata.length * par.Ratio;
```

**Visual Effect:**
- **Low (0.01-0.03)**: Thin, spindly trunk
- **Medium (0.04-0.06)**: Typical tree proportions
- **High (0.08-0.12)**: Thick, stout trunk

**Typical Values:** Birch: 0.02, Oak: 0.05, Baobab: 0.15

#### RatioPower
**Purpose:** Branch radius scaling exponent
**Storage:** `char` (signed byte, Arbaro.h:72)
**Range:** -128 to 127 → -4.0 to ~3.97 (byte / 32)
**Decoding:** `RatioPower / 32.0f` (Arbaro.cpp:89)

Controls how child branch radius scales relative to parent via power law (Arbaro.cpp:503):
```cpp
radius = parent->stemdata.baseRadius
       * pow(stemdata.length / parent->stemdata.length, par.RatioPower);
```

**Visual Effect:**
- **< 0**: Child branches thicker than parent (unnatural, stylized)
- **0**: Uniform thickness (bamboo-like)
- **1**: Linear scaling (gentle taper)
- **2**: Quadratic scaling (rapid thinning, typical trees)
- **3+**: Extreme thinning (fractal trees, twigs)

**Typical Values:** Gentle taper: 1.0-1.5, Natural trees: 2.0-2.5, Fractal: 3.0+

### Trunk Parameters

#### BaseSize
**Purpose:** Trunk clear zone (no branches below this height)
**Storage:** `unsigned char` (Arbaro.h:63)
**Range:** 0.0 to 1.0 (byte / 255)
**Decoding:** `BaseSize / 255.0f` (Arbaro.cpp:85)

Specifies trunk height fraction below which no primary branches spawn. Creates clear trunk base like forest trees competing for light.

Applied in substem spawning (Arbaro.cpp:729-740):
```cpp
if (stemlevel == 0 && segment->index * stemdata.segmentLength < par.BaseSize * stemdata.length)
    return;  // Skip this segment
```

**Visual Effect:**
- **0.0**: Branches start at ground
- **0.2-0.4**: Typical forest tree
- **0.6+**: Tall clear trunk (redwood, telephone pole trees)

**Typical Values:** Shrubs: 0, Urban trees: 0.3-0.5, Forest: 0.1-0.2

#### Flare
**Purpose:** Root flare intensity at trunk base
**Storage:** `unsigned char` (Arbaro.h:67)
**Range:** -1.0 to ~9.0 (byte / 25.5 - 1.0)
**Decoding:** `Flare / 25.5f - 1.0f` (Arbaro.cpp:90)

Applies exponential radius increase in bottom ~12.5% of trunk via (Arbaro.cpp:547):
```cpp
radius *= par._0Scale * (1 + par.Flare * (pow(100, max(0, 1 - 8*Z)) - 1) / 100.0f);
```

The `pow(100, ...)` creates rapid flare near base, fading to zero at Z=0.125.

**Visual Effect:**
- **-1.0 to 0**: No flare or slight taper
- **0.5-1.0**: Gentle root buttress
- **2.0-5.0**: Pronounced flare (mature hardwoods)
- **5.0+**: Extreme buttress roots

**Typical Values:** Young trees: 0, Mature: 0.5-2.0, Tropical: 3.0-6.0

#### LobeDepth
**Purpose:** Depth of trunk lobe grooves
**Storage:** `D3DXFLOAT16` (Arbaro.h:80)
**Range:** 0 to ~65504
**Decoding:** Direct copy

Modulates radius in radial lobe formula (Arbaro.cpp:876):
```cpp
multiplier = rad * (1.0 + par.LobeDepth * cos(par.Lobes * angle * PI / 180));
```

Higher values create deeper grooves between lobes.

**Visual Effect:**
- **0**: Lobes have no depth (cosmetic only)
- **0.1-0.3**: Subtle bark texture
- **0.5-1.0**: Pronounced grooves (fluted column)

Only visible if `Lobes > 0`.

**Typical Values:** Smooth bark: 0, Oak texture: 0.1-0.2, Stylized: 0.5+

### Leaf Parameters

#### Leaves
**Purpose:** Leaf count per terminal branch
**Storage:** `short` (signed 16-bit, Arbaro.h:71)
**Range:** -32768 to 32767
**Decoding:** Direct copy

Positive values create evenly distributed leaves along terminal branches. Negative values (absolute value used) create fan arrangement at branch tips.

Applied in `leavesPerBranch()` (Arbaro.cpp:631):
```cpp
return abs(par.Leaves)
     * getShapeRatio(offset / parent->stemdata.length, par.LeafDistrib)
     * par.LeafQuality;
```

**Visual Effect:**
- **0**: No leaves
- **> 0**: Distributed leaves (10-100 typical)
- **< 0**: Fan leaves at tips (palms, ferns)

Multiplied by `LeafQuality` for final count.

**Typical Values:** Sparse: 10-30, Dense: 50-150, Fan palms: -20 to -50

#### LeafQuality
**Purpose:** Leaf density multiplier
**Storage:** `unsigned char` (Arbaro.h:64)
**Range:** 0.00001 to 1.0 (byte / 255)
**Decoding:** `LeafQuality / 255.0f` (Arbaro.cpp:94)

Multiplies final leaf count, allowing LOD scaling without changing base `Leaves` parameter.

**Visual Effect:**
- **0.25**: 25% of specified leaves (distant trees)
- **0.5**: Half density
- **1.0**: Full density

**Typical Values:** LOD far: 0.1-0.3, LOD mid: 0.5, LOD near: 1.0

#### LeafScale
**Purpose:** Leaf size (both width and height before aspect)
**Storage:** `D3DXFLOAT16` (Arbaro.h:85)
**Range:** 0.00001 to ~65504
**Decoding:** Direct copy

Base scale for leaf quad dimensions. Leaf is 1×2 unit quad scaled by this value.

Applied in `BuildMesh()` (Arbaro.cpp:244):
```cpp
D3DXVECTOR3 &vx = transf.apply(
    D3DXVECTOR3(leafVertexData[x][0] * leafScaleX, 0, leafVertexData[x][1] + leafStemLen * 2)
    * leafScale * 0.5f);
```

**Visual Effect:** Larger leaves = more foliage coverage
**Typical Values:** Small leaves: 0.1-0.3, Medium: 0.5-1.0, Large: 2.0-5.0

#### LeafScaleX
**Purpose:** Leaf width multiplier (aspect ratio)
**Storage:** `D3DXFLOAT16` (Arbaro.h:86)
**Range:** 0.00001 to ~65504
**Decoding:** Direct copy

Multiplies leaf width independently of height. Creates wide/narrow leaf shapes.

**Visual Effect:**
- **0.5**: Narrow leaves (willow, grass)
- **1.0**: Square aspect
- **2.0+**: Wide leaves (maple, oak)

**Typical Values:** Narrow: 0.3-0.7, Typical: 0.8-1.2, Wide: 1.5-3.0

#### LeafStemLen
**Purpose:** Leaf stem (petiole) length
**Storage:** `D3DXFLOAT16` (Arbaro.h:87)
**Range:** -65504 to ~65504 (half-float is signed)
**Decoding:** Direct copy

Offsets leaf quad along attachment axis. Positive values create visible stem, negative brings leaf closer to branch.

**Visual Effect:**
- **0**: Leaf attached directly to branch
- **0.5-2.0**: Visible petiole
- **< 0**: Leaf overlaps branch (useful for clustering)

**Typical Values:** Sessile leaves: 0, Typical: 0.5-1.5, Long stems: 2.0-5.0

#### LeafBend
**Purpose:** Gravity bend factor for leaves
**Storage:** `unsigned char` (Arbaro.h:65)
**Range:** 0.0 to 1.0 (byte / 255)
**Decoding:** `LeafBend / 255.0f` (Arbaro.cpp:97)

Rotates leaves toward ground based on position, simulating gravity sag (Arbaro.cpp:228-233). Higher values = more droop.

**Visual Effect:**
- **0**: Leaves rigidly perpendicular to branches
- **0.5**: Gentle droop
- **1.0**: Full gravity sag

**Typical Values:** Stiff leaves: 0-0.2, Natural droop: 0.4-0.7, Wilting: 0.8-1.0

### Pruning Parameters

Pruning cuts branches outside a defined envelope, creating shaped canopies. The envelope is defined by width and height curves with power factors.

#### PruneRatio
**Purpose:** Pruning intensity
**Storage:** `unsigned char` (Arbaro.h:74)
**Range:** 0.0 to 1.0 (byte / 255)
**Decoding:** `PruneRatio / 255.0f` (Arbaro.cpp:104)

Controls how much branches outside the envelope are shortened. 0 = no pruning, 1 = full pruning to envelope.

Applied in pruning calculation (Arbaro.cpp:580):
```cpp
stemdata.length = origlen - (origlen - stemdata.length) * par.PruneRatio;
```

**Visual Effect:**
- **0**: Natural growth, no envelope
- **0.5**: Gentle shaping
- **1.0**: Hard cut to envelope

**Typical Values:** Natural: 0, Hedges: 0.8-1.0, Topiary: 1.0

#### PruneWidth
**Purpose:** Maximum envelope width
**Storage:** `unsigned char` (Arbaro.h:75)
**Range:** 0.0 to 1.0 (byte / 255)
**Decoding:** `PruneWidth / 255.0f` (Arbaro.cpp:105)

Sets horizontal radius of pruning envelope as fraction of tree scale.

Applied in envelope test (Arbaro.cpp:881):
```cpp
return (r / par.scale_tree) < (par.PruneWidth * envelopeRatio);
```

**Visual Effect:** Wider values = broader canopy
**Typical Values:** Narrow: 0.3-0.5, Typical: 0.6-0.8, Wide: 0.9+

#### PruneWidthPeak
**Purpose:** Height of maximum envelope width
**Storage:** `unsigned char` (Arbaro.h:76)
**Range:** 0.0 to 1.0 (byte / 255)
**Decoding:** `PruneWidthPeak / 255.0f` (Arbaro.cpp:106)

Specifies normalized height (0 = base, 1 = top) where envelope reaches maximum width. Creates asymmetric shapes.

Applied in envelope ratio calculation (Arbaro.cpp:876-879):
```cpp
if (ratio < (1 - par.PruneWidthPeak))
    envelopeRatio = pow(ratio / (1 - par.PruneWidthPeak), par.PrunePowerHigh);
else
    envelopeRatio = pow((1 - ratio) / (1 - par.PruneWidthPeak), par.PrunePowerLow);
```

**Visual Effect:**
- **0.5**: Symmetric envelope (max width at mid-height)
- **< 0.5**: Top-heavy (max width in lower half)
- **> 0.5**: Bottom-heavy (max width in upper half)

**Typical Values:** Symmetric: 0.5, Rounded top: 0.3-0.4, Cone: 0.6-0.8

#### PrunePowerLow
**Purpose:** Envelope curve below peak
**Storage:** `D3DXFLOAT16` (Arbaro.h:77)
**Range:** 0 to ~65504
**Decoding:** Direct copy

Exponential factor controlling envelope curve from peak to base. Higher = sharper taper.

**Visual Effect:**
- **0.5**: Gentle curve
- **1.0**: Linear
- **2.0+**: Sharp taper

**Typical Values:** Smooth: 0.5-1.0, Natural: 1.5-2.5, Sharp: 3.0+

#### PrunePowerHigh
**Purpose:** Envelope curve above peak
**Storage:** `D3DXFLOAT16` (Arbaro.h:78)
**Range:** 0 to ~65504
**Decoding:** Direct copy

Exponential factor controlling envelope curve from peak to top. Higher = sharper taper.

**Visual Effect:** Same as PrunePowerLow but for upper portion
**Typical Values:** Match PrunePowerLow for symmetric, vary for asymmetric shapes

### Other Global Parameters

#### AttractionUp
**Purpose:** Phototropism (upward curvature tendency)
**Storage:** `char` (signed byte, Arbaro.h:70)
**Range:** -10.0 to ~10.0 (byte / 12.7)
**Decoding:** `AttractionUp / 12.7f` (Arbaro.cpp:96)

Applies upward force to branches, simulating light-seeking growth. Only affects levels ≥ 2 (Arbaro.cpp:705-711):
```cpp
if (par.AttractionUp != 0 && stemlevel >= 2) {
    D3DXVECTOR3 z = trf.getZ();
    float declination = acos(z.z);
    float curve_up = par.AttractionUp * abs(declination * sin(declination)) / lpar.nCurveRes;
    trf.rotaxis(-curve_up * 180 / PI, D3DXVECTOR3(-z.y, z.x, 0));
}
```

**Visual Effect:**
- **< 0**: Branches curve downward (weeping willow)
- **0**: No vertical bias
- **> 0**: Branches curve upward (poplar, reaching trees)

Strength proportional to horizontal deviation—vertical branches unaffected.

**Typical Values:** Weeping: -5 to -2, Natural: 0-2, Reaching: 3-7

#### Smooth
**Purpose:** Mesh smoothness via increased polygon count
**Storage:** `unsigned char` (Arbaro.h:66)
**Range:** 0.0 to 1.0 (byte / 255)
**Decoding:** `Smooth / 255.0f` (Arbaro.cpp:102)

Increases radial and segment subdivision for smoother geometry. Applied in mesh resolution calculation (Arbaro.cpp:137-140):
```cpp
if (Lobes > 0)
    lparams[0].mesh_points = max(Lobes * pow(2.0, 1 + 2.5*Smooth), 4 * (1 + 2*Smooth));

for (int i = 1; i < 4; i++)
    lparams[i].mesh_points = max(3, lparams[i].mesh_points * (1 + 1.5*Smooth));
```

**Visual Effect:**
- **0**: Faceted, low-poly appearance (3-4 sides per branch)
- **0.5**: Moderate smoothness (6-8 sides)
- **1.0**: Smooth cylinders (12+ sides)

Higher values significantly increase vertex count.

**Typical Values:** Low-poly: 0-0.2, Balanced: 0.4-0.6, Smooth: 0.8-1.0

## Per-Level Parameters (TREELEVELPARAMETERS)

These 16 parameters define branching behavior at each hierarchy level (0-3). All values stored in TREELEVELPARAMETERS (Arbaro.h:30-52), decoded by Params constructor (Arbaro.cpp:110-132).

### Branch Count

#### nBranches
**Purpose:** Number of child branches spawned from this level
**Storage:** `unsigned char` (Arbaro.h:32)
**Range:** 0 to 255
**Decoding:** Direct copy

Determines branching density. Level 0 (trunk): number of main trunks. Level 1+: branches per parent stem.

Actual count per segment calculated via error diffusion (Arbaro.cpp:743):
```cpp
int substems_eff = PropagateError(lpar.substemErrorValue, subst_per_segm);
```

**Visual Effect:**
- **0**: No branches (terminal level)
- **5-10**: Sparse branching
- **15-30**: Typical tree density
- **50+**: Very dense, shrub-like

**Typical Values:** Trunk (L0): 1, Primary (L1): 10-30, Secondary (L2): 5-20, Twigs (L3): 0-15

#### nBranchDist
**Purpose:** Distribution factor along parent stem
**Storage:** `unsigned char` (Arbaro.h:39)
**Range:** 0.0 to 1.0 (byte / 255)
**Decoding:** `nBranchDist / 255.0f` (Arbaro.cpp:116)

Controls spacing randomization of child branches along parent. Applied in substem placement (Arbaro.cpp:746-750):
```cpp
float dist = (1.0f - offs) / substems_eff * lpar_1.nBranchDist;
for (int s = 0; s < substems_eff; s++) {
    float where = offs + dist / 2 + s * dist + var(dist * 0.25f);
```

**Visual Effect:**
- **0**: Branches evenly spaced
- **0.5**: Some clustering variation
- **1.0**: Wide random variation (clustered appearance)

**Typical Values:** Even distribution: 0-0.2, Natural: 0.5-0.8, Clustered: 0.9-1.0

### Geometry Parameters

#### nCurveRes
**Purpose:** Number of segments per branch (subdivision count)
**Storage:** `unsigned char` (Arbaro.h:33)
**Range:** 1 to 255
**Decoding:** Direct copy

Determines how many segments subdivide each stem. More segments = smoother curvature but higher cost.

Applied in stem creation (Arbaro.cpp:466):
```cpp
stemdata.segmentCount = lpar.nCurveRes;
stemdata.segmentLength = stemdata.length / lpar.nCurveRes;
```

**Visual Effect:**
- **1**: Straight branch (no curvature)
- **3-5**: Visible faceting
- **8-15**: Smooth curves
- **20+**: Very smooth (expensive)

**Typical Values:** Trunk (L0): 8-15, Branches (L1-2): 5-10, Twigs (L3): 3-5

#### nTaper
**Purpose:** Thickness taper mode and rate
**Storage:** `unsigned char` (Arbaro.h:35)
**Range:** 0.0 to 2.99999 (byte / 255 * 3)
**Decoding:** `nTaper / 255.0f * 3.0f` (Arbaro.cpp:125)

Controls radius variation along stem via three modes (Arbaro.cpp:513-543):

**Mode 0-1 (Linear taper):**
```cpp
radius = stemdata.baseRadius * (1 - nTaper * Z);
```
- **0**: Cylindrical (no taper)
- **1**: Full cone (radius = 0 at tip)

**Mode 1-2 (Spherical end):**
Last segment creates rounded tip via exponential subsegment spacing (Arbaro.cpp:294-303).

**Mode 2-3 (Periodic bumps):**
```cpp
radius = (1 - depth) * radius + depth * sqrt(radius² - (Z3 - radius)²);
```
Creates periodic bulges like bamboo nodes or segmented stems.

**Visual Effect:**
- **0-0.5**: Slight taper (trunk-like)
- **0.8-1.0**: Natural branch taper
- **1.0-2.0**: Spherical tips (rounds)
- **2.0-3.0**: Bumpy stems (bamboo)

**Typical Values:** Trunk: 0.5-0.8, Branches: 0.9-1.2, Twigs: 1.5-2.0

### Branching Angles

#### nDownAngle
**Purpose:** Branching angle away from parent direction
**Storage:** `short` (signed 16-bit, Arbaro.h:42)
**Range:** -179.999 to 179.999 degrees
**Decoding:** Direct copy

Primary angle determining how far child branches deviate from parent axis. Applied via rotxz transformation (Arbaro.cpp:792):
```cpp
return trf.rotxz(downangle, rotangle);
```

**Visual Effect:**
- **0**: Child parallel to parent (upward growth)
- **45**: Moderate angle (typical broadleaf)
- **90**: Perpendicular (horizontal branches)
- **120+**: Downward branches (weeping)
- **Negative**: Upward sweep

**Typical Values:** Upright: 10-30, Spreading: 45-70, Horizontal: 80-100, Weeping: 110-140

#### nDownAngleV
**Purpose:** Variation in down angle
**Storage:** `short` (signed 16-bit, Arbaro.h:43)
**Range:** -179.999 to 179.999 degrees (special meaning if negative)
**Decoding:** Direct copy

Positive values: Random variation added to nDownAngle.

Negative values: Special mode where angle varies by position along parent (Arbaro.cpp:786-789):
```cpp
if (lpar_1.nDownAngleV >= 0) {
    downangle = lpar_1.nDownAngle + var(lpar_1.nDownAngleV);
} else {
    float len = (stemlevel == 0) ? stemdata.length*(1 - par.BaseSize) : stemdata.length;
    downangle = lpar_1.nDownAngle + lpar_1.nDownAngleV*(1 - 2*getShapeRatio(...));
}
```

**Visual Effect:**
- **Positive**: Random variation (organic irregularity)
- **Negative**: Systematic angle change along parent (branches get steeper/shallower toward tip)

**Typical Values:** Random: 10-30, Positional variation: -20 to -60

#### nRotate
**Purpose:** Rotation angle around parent stem (phyllotaxis)
**Storage:** `short` (signed 16-bit, Arbaro.h:40)
**Range:** -360 to 360 degrees
**Decoding:** Direct copy

Positive values: Cumulative spiral angle between successive branches (Arbaro.cpp:701-707):
```cpp
if (lpar_1.nRotate >= 0) {
    stemdata.substemRotangle = fmod((stemdata.substemRotangle + lpar_1.nRotate
                                   + var(lpar_1.nRotateV) + 360), 360);
    rotangle = stemdata.substemRotangle;
}
```

Negative values: Alternating left/right pattern (Arbaro.cpp:709-711):
```cpp
else {
    stemdata.substemRotangle = -stemdata.substemRotangle;  // Flip sign
    rotangle = stemdata.substemRotangle * (180 + lpar_1.nRotate + var(lpar_1.nRotateV));
}
```

**Visual Effect:**
- **137.5**: Golden angle spiral (optimal sunlight exposure, common in nature)
- **90**: 4-way symmetric (maple)
- **120**: 3-way symmetric
- **180**: Opposite pairs
- **Negative**: Alternating pattern

**Typical Values:** Spiral: 120-150, Opposite: 180, Alternating: -180, Golden: 137.5

#### nRotateV
**Purpose:** Variation in rotation angle
**Storage:** `short` (signed 16-bit, Arbaro.h:41)
**Range:** -360 to 360 degrees
**Decoding:** Direct copy

Adds random variation to nRotate. Prevents perfect symmetry.

**Visual Effect:** Higher values = more irregular spacing around stem
**Typical Values:** Low variation: 5-15, Natural: 20-40, Chaotic: 60+

### Curvature Parameters

#### nCurve
**Purpose:** Primary curvature per segment
**Storage:** `short` (signed 16-bit, Arbaro.h:45)
**Range:** -32768 to 32767 (degrees of curvature)
**Decoding:** Direct copy

Rotation applied to each segment, creating stem curvature. Applied in newDirection (Arbaro.cpp:682-695):
```cpp
if (lpar.nCurveBack == 0) {
    delta = lpar.nCurve;
} else {
    if (nsegm < (lpar.nCurveRes + 1) / 2)
        delta = lpar.nCurve * 2;  // First half
    else
        delta = lpar.nCurveBack * 2;  // Second half
}
delta = delta / lpar.nCurveRes + stemdata.splitCorrection;
trf.rotx(delta);
```

**Visual Effect:**
- **0**: Straight stems
- **Positive**: Upward/outward curve
- **Negative**: Downward curve
- **Large values**: Tight spirals

With nCurveBack, creates S-curves.

**Typical Values:** Straight: 0-10, Gentle curve: 20-50, Strong curve: 80-150

#### nCurveV
**Purpose:** Curvature variation (or helix mode if negative)
**Storage:** `short` (signed 16-bit, Arbaro.h:46)
**Range:** -90 to 32767 degrees
**Decoding:** Direct copy

Positive values: Random curvature variation per segment (Arbaro.cpp:699-703):
```cpp
if (lpar.nCurveV > 0) {
    delta = var(lpar.nCurveV) / lpar.nCurveRes;
    trf.rotaxisz(delta, 180 + var(180));  // Random axis
}
```

Negative values: **Helix mode** (Arbaro.cpp:274-287):
```cpp
if (lpar.nCurveV < 0) {
    float angle = cos(abs(lpar.nCurveV) / 180 * PI);
    float rad = sqrt(1.0f / (angle*angle) - 1) * length / PI / 2.0f;
    // Create helical stem path...
}
```

**Visual Effect:**
- **Positive**: Organic wiggle, prevents straight branches
- **Negative**: Perfect helix (vines, tendrils, DNA)

**Typical Values:** Random: 10-50, Helix: -30 to -60

#### nCurveBack
**Purpose:** Reverse curvature for S-shaped stems
**Storage:** `short` (signed 16-bit, Arbaro.h:47)
**Range:** -32768 to 32767 degrees
**Decoding:** Direct copy

Applied to second half of stem segments, creating S-curve (Arbaro.cpp:686-693):
```cpp
if (nsegm < (lpar.nCurveRes + 1) / 2)
    delta = lpar.nCurve * 2;      // Curve one way
else
    delta = lpar.nCurveBack * 2;  // Curve back
```

**Visual Effect:**
- **0**: No reverse (use nCurve only)
- **Opposite sign of nCurve**: S-curve
- **Same sign**: Continues curve

**Typical Values:** No S-curve: 0, Natural S: -50 to -150 (if nCurve positive)

### Splitting Parameters

#### nSegSplits
**Purpose:** Probability of stem splitting per segment
**Storage:** `D3DXFLOAT16` (Arbaro.h:51)
**Range:** 0 to ~65504
**Decoding:** Direct copy

Fractional split count per segment. Error diffusion converts to integer (Arbaro.cpp:892):
```cpp
seg_splits_eff = PropagateError(lpar.splitErrorValue, lpar.nSegSplits);
```

Splits create clones continuing from split point at divergent angles.

**Visual Effect:**
- **0**: No splitting
- **0.1-0.5**: Occasional forks
- **1.0+**: Frequent splitting (bushy appearance)

**Typical Values:** No split: 0, Moderate: 0.2-0.5, Heavy: 0.8-1.5

#### nSplitAngle
**Purpose:** Angle of split from parent direction
**Storage:** `unsigned char` (Arbaro.h:36)
**Range:** 0 to 180 degrees
**Decoding:** Direct copy

Applied in split transformation (Arbaro.cpp:934):
```cpp
float declination = acos(trf.getZ().z) * 180 / PI;
float split_angle = max(0, (lpar.nSplitAngle + var(lpar.nSplitAngleV) - declination));
trf.rotx(split_angle);
```

Adjusted by current stem declination—vertical stems split more, horizontal less.

**Visual Effect:**
- **0-20**: Narrow forks (Y-split)
- **30-60**: Wide forks
- **90+**: Perpendicular splits

**Typical Values:** Narrow fork: 15-30, Typical: 40-60, Wide: 70-90

#### nSplitAngleV
**Purpose:** Variation in split angle
**Storage:** `unsigned char` (Arbaro.h:37)
**Range:** 0 to 180 degrees
**Decoding:** Direct copy

Adds random variation to nSplitAngle.

**Visual Effect:** Higher values = irregular fork angles
**Typical Values:** Uniform: 5-10, Varied: 15-30

### Size Parameters

#### nLength
**Purpose:** Stem length (absolute for L0, relative for L1+)
**Storage:** `D3DXFLOAT16` (Arbaro.h:49)
**Range:** 0.00001 to ~65504
**Decoding:** Direct copy

Level 0 (trunk): Absolute length in world units (Arbaro.cpp:489):
```cpp
return (lpar.nLength + var(lpar.nLengthV)) * par.scale_tree;
```

Level 1+ (branches): Fraction of parent length, modulated by shape ratio (Arbaro.cpp:492-494):
```cpp
if (stemlevel == 1)
    return parent->stemdata.length * parent->stemdata.lengthChildMax
         * getShapeRatio(..., par.Shape);
else
    return parent->stemdata.lengthChildMax * (parent->stemdata.length - 0.6f*offset);
```

**Visual Effect:**
- **L0 high**: Tall trunk
- **L1+ high**: Long branches (spreading tree)
- **L1+ low**: Short branches (compact tree)

**Typical Values:** Trunk (L0): 10-100, Branches (L1): 0.3-0.8, Twigs (L2-3): 0.2-0.5

#### nLengthV
**Purpose:** Length variation
**Storage:** `D3DXFLOAT16` (Arbaro.h:50)
**Range:** 0 to ~65504
**Decoding:** Direct copy

Random variation added to nLength via `var(nLengthV)` (Arbaro.cpp:489).

**Visual Effect:** Higher values = irregular branch lengths
**Typical Values:** Uniform: 0-0.05, Natural: 0.1-0.3, Chaotic: 0.5+

## Parameter Interaction Examples

Understanding individual parameters is necessary but not sufficient. Trees emerge from parameter combinations. Here are species archetypes demonstrating key interactions:

### Oak (Broadleaf Deciduous)

```
Global:
  Levels: 3
  Shape: Spherical (1)           // Rounded crown
  LeafDistrib: Spherical (1)     // Leaves concentrated at mid-height
  Scale: 25.0
  Ratio: 0.025 (byte: 51)        // Moderate trunk thickness
  RatioPower: 2.0 (byte: 64)     // Natural taper
  BaseSize: 0.2 (byte: 51)       // Clear trunk base
  Flare: 0.8 (byte: 45)          // Pronounced root flare
  Lobes: 5                       // Grooved bark
  LobeDepth: 0.15
  Leaves: 120
  LeafQuality: 1.0 (byte: 255)
  AttractionUp: 1.5 (byte: 19)   // Slight upward reach

Level 0 (Trunk):
  nBranches: 1
  nCurveRes: 10
  nLength: 15.0
  nTaper: 0.7 (byte: 59)
  nCurve: 0
  nDownAngle: 0
  nRotate: 140                   // Spiral primary branches

Level 1 (Primary):
  nBranches: 25
  nCurveRes: 8
  nLength: 0.5
  nLengthV: 0.2
  nTaper: 1.0 (byte: 85)
  nCurve: 30
  nCurveBack: -40                // S-curve branches
  nDownAngle: 60
  nDownAngleV: 20
  nRotate: 140
  nRotateV: 30

Level 2 (Secondary):
  nBranches: 15
  nCurveRes: 6
  nLength: 0.4
  nTaper: 1.2 (byte: 102)        // Rounded tips
  nCurve: 20
  nDownAngle: 50
  nRotate: 140
  nSegSplits: 0.3                // Some forking

Level 3 (Twigs):
  nBranches: 8
  nCurveRes: 4
  nLength: 0.25
  nTaper: 1.5 (byte: 127)        // Spherical ends
  nCurve: 10
  nDownAngle: 40
```

**Key Interactions:**
- Spherical shape + high branch counts at L1/L2 = dense rounded crown
- S-curve (nCurve + nCurveBack) = organic branch sweep
- Lobes + LobeDepth = textured bark
- Moderate RatioPower (2.0) = natural thickness taper

### Pine (Conifer)

```
Global:
  Levels: 3
  Shape: Conical (0)             // Christmas tree silhouette
  LeafDistrib: Conical (0)
  Scale: 30.0
  Ratio: 0.015 (byte: 31)        // Thin trunk
  RatioPower: 1.5 (byte: 48)     // Gentle taper
  BaseSize: 0.1 (byte: 25)       // Branches start low
  Flare: 0.3 (byte: 32)          // Minimal flare
  Lobes: 0                       // Smooth bark
  Leaves: -40                    // Fan arrangement (needles)
  LeafScale: 0.15
  LeafScaleX: 0.05               // Narrow needles
  AttractionUp: 0.5 (byte: 6)

Level 0 (Trunk):
  nBranches: 1
  nCurveRes: 12
  nLength: 20.0
  nTaper: 0.5 (byte: 42)         // Gradual taper
  nCurve: 5                      // Nearly straight
  nDownAngle: 0
  nRotate: 0

Level 1 (Whorls):
  nBranches: 30                  // Dense whorls
  nCurveRes: 6
  nLength: 0.6
  nLengthV: 0.15
  nTaper: 0.8 (byte: 68)
  nCurve: -20                    // Downward droop
  nDownAngle: 90                 // Horizontal branches
  nDownAngleV: -40               // Steeper at top
  nRotate: 137.5                 // Golden angle
  nRotateV: 5

Level 2 (Twigs):
  nBranches: 20
  nCurveRes: 4
  nLength: 0.3
  nTaper: 1.0 (byte: 85)
  nCurve: -10
  nDownAngle: 70
  nRotate: 90

Level 3 (Needles):
  nBranches: 0                   // Leaves attach at L2
```

**Key Interactions:**
- Conical shape + nDownAngleV negative = branches steeper toward top
- Negative Leaves + thin LeafScaleX = needle clusters
- High L1 nBranches + golden angle rotation = dense whorled appearance
- Negative nCurve = drooping branch tips

### Willow (Weeping)

```
Global:
  Levels: 3
  Shape: Hemispherical (2)       // Dome crown
  LeafDistrib: Inverse_Conical (6)  // Leaves dense at tips
  Scale: 20.0
  Ratio: 0.03 (byte: 61)
  RatioPower: 2.5 (byte: 80)     // Rapid thinning
  BaseSize: 0.25 (byte: 64)
  Flare: 0.5 (byte: 37)
  Lobes: 3
  LobeDepth: 0.1
  Leaves: 200                    // Dense foliage
  LeafScale: 0.3
  LeafScaleX: 0.2                // Narrow leaves
  LeafBend: 0.7 (byte: 178)      // Strong droop
  AttractionUp: -3.0 (byte: -38) // Downward curve

Level 0 (Trunk):
  nBranches: 1
  nCurveRes: 8
  nLength: 12.0
  nTaper: 0.6 (byte: 51)
  nCurve: 10
  nDownAngle: 0
  nRotate: 0

Level 1 (Primary):
  nBranches: 20
  nCurveRes: 10
  nLength: 0.8
  nTaper: 0.9 (byte: 76)
  nCurve: 40                     // Outward then down
  nCurveBack: 80                 // Continue downward
  nDownAngle: 45
  nRotate: 137.5
  nSegSplits: 0.2

Level 2 (Weeping branches):
  nBranches: 25
  nCurveRes: 12                  // Smooth curve
  nLength: 1.0                   // Long drooping branches
  nLengthV: 0.3
  nTaper: 1.1 (byte: 93)
  nCurve: 80                     // Strong downward curve
  nCurveV: 30                    // Irregular droop
  nDownAngle: 120                // Start downward
  nRotate: 90
  nRotateV: 40

Level 3 (Leaf stems):
  nBranches: 15
  nCurveRes: 4
  nLength: 0.4
  nTaper: 1.5 (byte: 127)
  nCurve: 20
  nDownAngle: 100
```

**Key Interactions:**
- Negative AttractionUp + high L2 nCurve + nDownAngle > 90 = weeping cascade
- LeafBend + Inverse_Conical LeafDistrib = foliage at drooping tips
- High L2 nCurveRes = smooth flowing branches
- Same-sign nCurve + nCurveBack = continuous downward arc

### Palm

```
Global:
  Levels: 2                      // Just trunk and fronds
  Shape: Cylindrical (3)         // Straight trunk
  LeafDistrib: Inverse_Conical (6)  // All leaves at top
  Scale: 15.0
  Ratio: 0.04 (byte: 82)         // Thick trunk
  RatioPower: 0.0 (byte: 0)      // Uniform thickness
  BaseSize: 0.0 (byte: 0)        // Fronds from base (if multi-trunk)
  Flare: 0.0 (byte: 25)          // No flare
  Lobes: 8
  LobeDepth: 0.05                // Subtle texture
  Leaves: -30                    // Fan leaves per frond
  LeafScale: 2.0
  LeafScaleX: 0.8
  LeafStemLen: 1.5
  AttractionUp: 0.0

Level 0 (Trunk):
  nBranches: 1
  nCurveRes: 10
  nLength: 18.0
  nTaper: 2.3 (byte: 195)        // Bumpy (segments)
  nCurve: 5                      // Slight curve
  nCurveV: 10
  nDownAngle: 0
  nRotate: 0

Level 1 (Fronds):
  nBranches: 25                  // Dense crown
  nCurveRes: 8
  nLength: 3.0
  nLengthV: 0.5
  nTaper: 0.8 (byte: 68)
  nCurve: 60                     // Arching fronds
  nCurveBack: -40                // Droop at tips
  nDownAngle: 40
  nDownAngleV: 30
  nRotate: 137.5
  nRotateV: 20

Level 2 (not used):
  nBranches: 0
```

**Key Interactions:**
- Levels = 2 + Negative Leaves = all foliage as fan fronds at L1 tips
- Cylindrical Shape + RatioPower = 0 = uniform trunk
- nTaper > 2.0 = segmented trunk (palm rings)
- High L1 nBranches + Inverse_Conical LeafDistrib = dense crown
- S-curve fronds (nCurve positive, nCurveBack negative) = arch then droop

### Birch (Multi-trunk Grove)

```
Global:
  Levels: 3
  Shape: Flame (5)               // Narrow crown
  LeafDistrib: Flame (5)
  Scale: 18.0
  Ratio: 0.018 (byte: 37)        // Thin trunks
  RatioPower: 2.2 (byte: 70)
  BaseSize: 0.15 (byte: 38)
  Flare: 0.0 (byte: 25)          // No flare
  Lobes: 0                       // Smooth bark
  _0BaseSplits: 3                // Multi-trunk base
  Leaves: 80
  LeafQuality: 0.8 (byte: 204)
  AttractionUp: 2.0 (byte: 25)   // Upward reach

Level 0 (Trunks):
  nBranches: 4                   // 4 trunks in grove
  nCurveRes: 12
  nLength: 15.0
  nLengthV: 3.0                  // Varied heights
  nTaper: 0.6 (byte: 51)
  nCurve: 15                     // Slight lean
  nCurveV: 20                    // Each trunk unique
  nDownAngle: 5
  nDownAngleV: 10
  nRotate: 90                    // Spread trunks

Level 1 (Primary):
  nBranches: 18
  nCurveRes: 6
  nLength: 0.4
  nTaper: 1.0 (byte: 85)
  nCurve: 25
  nCurveBack: -15
  nDownAngle: 50
  nDownAngleV: 20
  nRotate: 140
  nSegSplits: 0.4                // Some splitting

Level 2 (Twigs):
  nBranches: 12
  nCurveRes: 4
  nLength: 0.3
  nTaper: 1.3 (byte: 110)
  nCurve: 15
  nDownAngle: 45
  nRotate: 137.5

Level 3 (Leaf stems):
  nBranches: 6
  nCurveRes: 3
  nLength: 0.2
  nTaper: 1.5 (byte: 127)
```

**Key Interactions:**
- L0 nBranches = 4 + _0BaseSplits = 3 = each trunk splits 3 ways = 12 total stems
- Flame shape + positive AttractionUp = narrow upward-reaching crown
- High L0 nLengthV = varied trunk heights (natural grove)
- Moderate L1 nSegSplits + S-curves = organic branching

## Parameter Patterns and Rules of Thumb

After analyzing the examples, several design patterns emerge:

### Shape and Distribution Alignment
Match `Shape` and `LeafDistrib` for uniform trees. Mismatch for concentrated foliage (e.g., bare lower branches with leafy crown).

### Taper Progression
Increase taper through levels:
- **L0**: 0.5-0.8 (gradual trunk taper)
- **L1**: 0.9-1.2 (moderate branch taper)
- **L2**: 1.3-1.7 (thin twigs, possibly rounded)
- **L3**: 1.5-2.0 (spherical tips)

### Curve Resolution Economy
Fewer segments for higher levels:
- **L0**: 8-15 (visible trunk curvature)
- **L1**: 6-10
- **L2**: 4-6
- **L3**: 3-5 (minimal twigs)

Total segments = `(L0_segs) + (L0_segs * L1_branches * L1_segs) + ...` grows exponentially, so higher levels need low res.

### Branch Count Decay
Reduce branches per level for balanced trees:
- **L0**: 1-4 (trunks)
- **L1**: 15-30 (primary)
- **L2**: 10-20 (secondary)
- **L3**: 5-15 (twigs)

Total stems at level N = `prod(Li_branches for i in 0..N)`. L1=20, L2=15, L3=10 = 3,000 stems at L3.

### Angle Consistency
Use similar `nRotate` across levels for coherent phyllotaxis:
- **Golden angle (137.5)**: Natural spiral, maximizes sunlight
- **90 or 180**: Symmetric patterns
- **120**: Triangular arrangement
- **Negative**: Alternating (decorative, less natural)

### S-Curve Discipline
Set `nCurveBack` to opposite sign of `nCurve` with 1.5-2x magnitude:
- `nCurve = 40`, `nCurveBack = -60`: Gentle S
- `nCurve = 80`, `nCurveBack = -120`: Pronounced S

Same sign continues curve into spiral (useful for vines if combined with helix mode).

### Pruning Symmetry
For natural canopies:
- `PruneWidthPeak = 0.4-0.5` (max width mid-to-lower crown)
- `PrunePowerLow ≈ PrunePowerHigh` (symmetric taper)

For artistic shapes, vary independently.

## Storage Optimization Analysis

The parameter quantization achieves significant space savings:

| Parameter | Type | Bytes | Range | Precision Loss |
|-----------|------|-------|-------|----------------|
| BaseSize | u8 / 255 | 1 | 0-1 | ~0.004 |
| Ratio | u8 / 2048 | 1 | 0-0.125 | ~0.00006 |
| RatioPower | i8 / 32 | 1 | -4 to 4 | ~0.03 |
| Flare | u8 / 25.5 - 1 | 1 | -1 to 9 | ~0.04 |
| AttractionUp | i8 / 12.7 | 1 | -10 to 10 | ~0.08 |
| nTaper | u8 / 255 * 3 | 1 | 0-3 | ~0.012 |
| nBranchDist | u8 / 255 | 1 | 0-1 | ~0.004 |
| nLength | f16 | 2 | 0-65504 | ~0.1% (mantissa bits) |
| nSegSplits | f16 | 2 | 0-65504 | ~0.1% |

**Total per species:**
- Global params: ~156 bytes
- Level params: 4 × 16 bytes = ~64 bytes
- **Grand total: ~220 bytes**

For comparison, equivalent full-precision floats:
- Global: ~30 params × 4 bytes = 120 bytes
- Level: 4 levels × 16 params × 4 bytes = 256 bytes
- **Total: 376 bytes**

Quantization saves ~41% space with acceptable precision loss. For demo executables where every kilobyte counts, this is significant.

## Implications for Rust Creative Coding Framework

Arbaro's parameter system offers several lessons for Rust framework design:

### Type-Safe Quantization

Rust's type system enables compile-time validated quantized types:

```rust
#[derive(Copy, Clone)]
struct Normalized<T>(T);  // 0.0 to 1.0

impl From<u8> for Normalized<f32> {
    fn from(byte: u8) -> Self {
        Normalized(byte as f32 / 255.0)
    }
}

impl From<Normalized<f32>> for u8 {
    fn from(norm: Normalized<f32>) -> Self {
        (norm.0 * 255.0).clamp(0.0, 255.0) as u8
    }
}

#[derive(Copy, Clone)]
struct Angle(f32);  // Degrees

impl From<i16> for Angle {
    fn from(value: i16) -> Self {
        Angle(value as f32)
    }
}
```

This prevents accidental mixing of quantized and decoded values at compile time.

### Builder Pattern for Species

Rather than raw structs, expose ergonomic builders:

```rust
let oak = TreeSpecies::builder()
    .levels(3)
    .shape(TreeShape::Spherical)
    .scale(25.0)
    .ratio(0.025)
    .ratio_power(2.0)
    .trunk(|trunk| trunk
        .length(15.0)
        .curve_resolution(10)
        .taper(0.7))
    .primary_branches(|branches| branches
        .count(25)
        .length(0.5)
        .down_angle(60.0)
        .rotation(140.0))
    .build();
```

Internally stores quantized bytes, but builder accepts natural units.

### Const Generic Quantization

Use const generics for range-specific types:

```rust
struct Quantized<const MIN: i32, const MAX: i32>(u8);

impl<const MIN: i32, const MAX: i32> Quantized<MIN, MAX> {
    fn decode(&self) -> f32 {
        MIN as f32 + (self.0 as f32 / 255.0) * (MAX - MIN) as f32
    }

    fn encode(value: f32) -> Self {
        let normalized = (value - MIN as f32) / (MAX - MIN) as f32;
        Quantized((normalized * 255.0).clamp(0.0, 255.0) as u8)
    }
}

type Ratio = Quantized<0, 125>;  // 0 to 0.125 range
type AttractionUp = Quantized<-10, 10>;
```

Compile-time range enforcement prevents encoding errors.

### Validation at Construction

Rust's Result type enables safe parameter validation:

```rust
impl TreeSpecies {
    pub fn from_bytes(data: &[u8; 220]) -> Result<Self, ParameterError> {
        let descriptor: TreeSpeciesDescriptor = unsafe {
            std::ptr::read(data.as_ptr() as *const _)
        };

        if descriptor.params.levels > 9 {
            return Err(ParameterError::InvalidLevels(descriptor.params.levels));
        }

        // Validate parameter ranges...

        Ok(TreeSpecies::decode(descriptor))
    }
}
```

### Serde Integration for Asset Pipeline

Use serde for human-readable editing:

```rust
#[derive(Serialize, Deserialize)]
struct TreeSpeciesJson {
    levels: u8,
    shape: TreeShape,
    scale: f32,
    // ... all params in decoded form
}

impl From<TreeSpeciesJson> for TreeSpecies {
    fn from(json: TreeSpeciesJson) -> Self {
        // Quantize and pack into 220-byte descriptor
    }
}
```

Artists edit JSON, build process encodes to binary. Runtime loads 220-byte blobs.

### Cargo Feature Flags for Pruning

Conditional compilation for optional features:

```toml
[features]
default = ["tree-pruning", "helix-mode"]
tree-pruning = []
helix-mode = []
```

```rust
#[cfg(feature = "tree-pruning")]
fn apply_pruning(&mut self) {
    // Complex envelope pruning logic
}

#[cfg(not(feature = "tree-pruning"))]
fn apply_pruning(&mut self) {
    // No-op
}
```

Minimal builds exclude pruning code entirely.

## Summary

Arbaro's 220-byte parameter system is a masterclass in domain-specific compression. By understanding botanical growth patterns—hierarchical branching, power-law radius scaling, phyllotaxis rotation, shape envelopes—the system distills tree species to 94 tunable dimensions. The dual representation (quantized storage, decoded runtime) optimizes for both space and ergonomics.

Every parameter serves a purpose: `Shape` controls overall silhouette, `nCurve` + `nCurveBack` create organic S-curves, `Ratio` and `RatioPower` govern thickness taper, `nRotate` determines phyllotaxis spirals, `nTaper` modes enable linear/spherical/bumpy stems. Parameters don't exist in isolation—they multiply and modulate each other through the generation hierarchy, creating exponential variety from linear parameter count.

For creative coders, understanding these parameters unlocks procedural botany as an expressive medium. Want a weeping willow? Negative `AttractionUp`, high `nCurve` at L2, `nDownAngle > 90`. Need a palm? `Levels = 2`, negative `Leaves`, `Cylindrical` shape, bumpy taper. Building a fantasy forest? Mix species parameters for alien flora: inverted cones with negative gravity, helical branches, extreme split angles.

The lessons extend beyond trees. Any hierarchical procedural system—terrain erosion, city generation, neural growth—benefits from compact parametric encoding. The error diffusion technique generalizes to any fractional distribution. The shape ratio concept applies to spatial falloff curves. Arbaro isn't just a tree generator—it's a reference implementation for parametric procedural generation under extreme size constraints.

## Related Documents

- **algorithm.md** — Generation process walkthrough with parameter application
- **shapes-taper.md** — Shape function analysis and taper mode visual reference
- **overview.md** — System architecture and high-level concepts
- **mesh-output.md** — How parameters affect final geometry
- **pruning.md** — Envelope pruning parameter interactions
- **species-library.md** — Example parameter sets for common tree types
