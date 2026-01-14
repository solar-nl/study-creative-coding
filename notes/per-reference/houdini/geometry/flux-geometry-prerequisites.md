# Flux Geometry Prerequisites

This document consolidates the architectural gaps and required changes identified across all Houdini geometry study documents. It serves as a roadmap for implementing geometry support in Flux.

---

## Executive Summary

Adding geometry support to Flux requires changes across multiple layers:

1. **Core type system** — New Value variants for Mesh, Curve, Volume, PointCloud
2. **Attribute infrastructure** — Four-level attribute classes with type metadata
3. **Operator patterns** — Category traits, group propagation, bridge operators
4. **Memory efficiency** — Arc-wrapped sharing, packed primitives, lazy evaluation
5. **Composition primitives** — Loop nodes, conditional groups, piece tracking

---

## Priority 1: Foundation (Required First)

### 1.1 Value::Mesh Type

**Source**: geometry-data-model.md

Add a Mesh variant to the Value enum implementing Houdini's four-level hierarchy.

```rust
pub struct Mesh {
    // Detail level (whole geometry)
    detail_attributes: AttributeMap,

    // Points (shared spatial data)
    points: Arc<Vec<Point>>,  // Arc for zero-copy sharing

    // Primitives (topology containers)
    primitives: Vec<Primitive>,

    // Vertices (per-corner references)
    vertices: Vec<Vertex>,

    // Attribute storage by level
    point_attributes: AttributeStorage,
    vertex_attributes: AttributeStorage,
    primitive_attributes: AttributeStorage,
}
```

**Key insight**: Vertices are references to points, not data containers. This enables per-face-per-corner data without duplicating positions.

### 1.2 Attribute Type Metadata

**Source**: attribute-system.md

Attributes must carry semantic type information that controls transform behavior.

```rust
pub enum AttributeTypeInfo {
    Position,    // Full transform (translate+rotate+scale)
    Normal,      // Inverse-transpose
    Vector,      // Rotate+scale only
    Color,       // No transform
    TextureCoord,// Preserves seams
    Quaternion,  // Rotation only
    Generic,     // No special handling
}
```

Transform operators must consult type info to apply correct transformations. A normal cannot be translated; a position must be.

### 1.3 Bridge Operators

**Source**: attribute-system.md, geometry-operators.md

Implement explicit operators for extracting mesh data rather than implicit attribute access.

| Operator | Input | Output |
|----------|-------|--------|
| `MeshGetPositions` | Mesh | Vec3List |
| `MeshGetNormals` | Mesh | Vec3List |
| `MeshGetUVs` | Mesh | Vec2List |
| `MeshGetFaceIndices` | Mesh | IntList |
| `MeshFromVertices` | Vec3List, IntList | Mesh |
| `MeshTransform` | Mesh, Matrix4 | Mesh |

Bridge operators make data flow explicit and avoid hidden precedence rules.

---

## Priority 2: Core Operators

### 2.1 Geometry Generators

**Source**: geometry-operators.md

Implement primitive generators with consistent parameter patterns.

| Operator | Parameters |
|----------|-----------|
| `BoxMesh` | size: Vec3, center: Vec3, divisions: Vec3 |
| `SphereMesh` | radius: f32, frequency: i32 |
| `GridMesh` | size: Vec2, rows: i32, cols: i32 |
| `LineMesh` | origin: Vec3, direction: Vec3, points: i32 |

All generators should support primitive type selection (Polygon, Mesh, Points) where applicable.

### 2.2 Geometry Modifiers

| Operator | Purpose |
|----------|---------|
| `MeshSubdivide` | Catmull-Clark subdivision with crease weights |
| `MeshSmooth` | Relax point positions |
| `MeshExtrude` | Extrude faces with distance/inset |
| `MeshDelete` | Remove elements by group/expression |

Modifiers must interpolate attributes during topology changes.

### 2.3 Geometry Combiners

| Operator | Purpose |
|----------|---------|
| `MeshMerge` | Combine multiple meshes |
| `MeshBoolean` | Union/intersect/subtract with piece tracking |

Boolean operations must generate output groups (inside, outside, seam) for downstream selection.

---

## Priority 3: Instancing Infrastructure

### 3.1 Instance Attribute Conventions

**Source**: instancing-and-efficiency.md

Standardize point attributes that drive instance transforms.

| Attribute | Type | Purpose |
|-----------|------|---------|
| `P` | Vec3 | Position |
| `orient` | Vec4 | Quaternion rotation |
| `pscale` | Float | Uniform scale |
| `scale` | Vec3 | Non-uniform scale |
| `N` | Vec3 | Normal (Z-axis orientation) |
| `up` | Vec3 | Up vector (Y-axis) |

### 3.2 CopyToPoints Operator

```rust
pub struct CopyToPoints {
    pub pack_and_instance: bool,  // Use Arc sharing vs real copies
}
```

When `pack_and_instance` is true, the operator creates packed primitives that share geometry via Arc references.

### 3.3 Packed Primitive Support

Add a PackedPrimitive value type that references geometry without copying.

```rust
pub struct PackedPrimitive {
    pub geometry: Arc<Mesh>,
    pub transform: Matrix4,
    pub attributes: AttributeMap,  // Per-instance overrides
}
```

---

## Priority 4: Composition Primitives

### 4.1 Group System

**Source**: procedural-composition.md

Implement groups as dynamically-computed filters.

```rust
pub enum GroupQuery {
    ByExpression(String),    // "@P.y > 0"
    ByAttribute(String, Predicate),
    Union(Box<GroupQuery>, Box<GroupQuery>),
    Intersect(Box<GroupQuery>, Box<GroupQuery>),
    Subtract(Box<GroupQuery>, Box<GroupQuery>),
}
```

Groups enable targeting operations to geometry subsets without structural changes.

### 4.2 Loop Nodes

Support two loop modes as graph templates.

**Feedback Loop**: Iterative refinement where each iteration's output feeds the next iteration's input.

**Piecewise Loop**: Process each piece (identified by attribute) independently, then merge results.

Loop nodes must expose iteration metadata (iteration, numiterations, value) to interior subgraphs.

### 4.3 Attribute Promotion

Implement promotion between attribute levels with configurable merge strategies.

| Strategy | Behavior |
|----------|----------|
| Average | Mean of contributing values |
| Maximum | Largest value |
| Minimum | Smallest value |
| Sum | Sum of all values |
| First | First contributing element |
| Mode | Most common value |

---

## Priority 5: Extended Types

### 5.1 Value::Curve

**Source**: non-mesh-geometry.md

```rust
pub struct Curve {
    pub control_vertices: Vec<Vec3>,
    pub knots: Vec<f32>,
    pub degree: u32,
    pub curve_type: CurveType,  // Polyline, Bezier, NURBS
}
```

### 5.2 Value::PointCloud

```rust
pub struct PointCloud {
    pub positions: Arc<Vec<Vec3>>,
    pub attributes: AttributeStorage,
}
```

Point clouds are attribute-heavy geometry without connectivity.

### 5.3 Value::Volume (Future)

```rust
pub enum Volume {
    Dense { data: Vec<f32>, dimensions: [u32; 3] },
    Sparse { /* VDB-style sparse tree */ },
}
```

Volumes should default to sparse representation for memory efficiency.

---

## Implementation Order

### Phase 1: Minimum Viable Geometry
1. Value::Mesh with four-level hierarchy
2. Attribute type metadata
3. MeshGetPositions, MeshGetNormals, MeshFromVertices
4. BoxMesh, SphereMesh, GridMesh generators
5. MeshTransform modifier

### Phase 2: Instancing
1. Instance attribute conventions (P, orient, pscale)
2. CopyToPoints operator
3. PackedPrimitive value type
4. Arc-based geometry sharing

### Phase 3: Operations
1. MeshSubdivide with crease weights
2. MeshBoolean with output groups
3. MeshMerge
4. MeshDelete with group targeting

### Phase 4: Composition
1. Group system (expression-based filtering)
2. Feedback loop node
3. Piecewise loop node
4. Attribute promotion operator

### Phase 5: Extended Types
1. Value::Curve
2. Value::PointCloud
3. Curve operators (Resample, Sweep)
4. Scatter operator

---

## Complexity Estimates

| Component | Files Changed | Estimated Effort |
|-----------|---------------|------------------|
| Value::Mesh | flux-core/src/value/ | Medium |
| Attribute type info | flux-core/src/value/ | Small |
| Bridge operators | flux-operators/src/ | Medium |
| Generators | flux-operators/src/ | Medium |
| CopyToPoints | flux-operators/src/ | Medium |
| PackedPrimitive | flux-core/src/value/ | Medium |
| Group system | flux-graph/src/ | Large |
| Loop nodes | flux-graph/src/ | Large |
| Curve type | flux-core/src/value/ | Medium |
| PointCloud type | flux-core/src/value/ | Small |

---

## Dependencies

```
Value::Mesh
    ├── Attribute type info (required)
    ├── Bridge operators (depends on Mesh)
    └── Generators (depends on Mesh)

CopyToPoints
    ├── Instance attribute conventions (required)
    └── PackedPrimitive (for pack_and_instance mode)

Group system
    └── Expression parsing (required)

Loop nodes
    ├── Group system (for piecewise loops)
    └── Piece attribute tracking (required)
```

---

## Validation Checklist

After implementation, verify:

- [ ] Mesh stores four attribute levels (detail, primitive, vertex, point)
- [ ] Points are shared across primitives (not duplicated)
- [ ] Attribute type info controls transform behavior
- [ ] Bridge operators produce correct Vec3List/IntList outputs
- [ ] Generators create valid mesh topology
- [ ] CopyToPoints reads standard instance attributes
- [ ] PackedPrimitive shares geometry via Arc
- [ ] Groups filter elements by expression
- [ ] Loop nodes expose iteration metadata
- [ ] Attribute promotion uses configurable merge strategies

---

## References

Study documents informing these requirements:

1. [geometry-data-model.md](./geometry-data-model.md) — Four-level hierarchy, points vs vertices
2. [attribute-system.md](./attribute-system.md) — Attribute classes, type info, precedence
3. [geometry-operators.md](./geometry-operators.md) — Generator/modifier/combiner patterns
4. [instancing-and-efficiency.md](./instancing-and-efficiency.md) — Packed primitives, memory strategies
5. [procedural-composition.md](./procedural-composition.md) — Workflow patterns, loops, groups
6. [non-mesh-geometry.md](./non-mesh-geometry.md) — Curves, volumes, point clouds
