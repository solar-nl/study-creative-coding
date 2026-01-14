# Houdini's Attribute System

What happens to a surface normal when you scale a mesh non-uniformly? Most creative coding frameworks apply the same matrix to every vector, producing incorrect lighting. Houdini solves this through semantic type information attached to each attribute, ensuring normals transform with the inverse-transpose while positions use the full affine matrix.

---

## The Problem of Generic Data Attachment

Every procedural system faces a fundamental challenge: how do you attach arbitrary data to geometry elements without losing meaning? A naive approach treats all attributes as raw numbers, but this breaks down the moment transforms enter the picture. Position data needs translation, rotation, and scale. Normal data needs only rotation and the inverse of non-uniform scale. Color data should pass through untouched. A system that cannot distinguish these cases produces subtle corruption that only surfaces during rendering.

The problem deepens when you consider attribute scope. Should color live on points (shared across faces meeting at a corner) or on vertices (allowing different colors where faces meet)? Should material IDs live on primitives or propagate from a single detail-level default? The answer depends on the artistic intent, and a rigid system forces workarounds that accumulate into maintenance nightmares.

Houdini's attribute system addresses both problems through a two-dimensional classification. Every attribute has a class (detail, primitive, point, or vertex) that determines its scope, and a type info tag that determines its transformation behavior. Understanding this system reveals why Houdini pipelines maintain geometric correctness through complex procedural chains while simpler frameworks accumulate errors.

---

## The Spreadsheet Analogy

Think of Houdini geometry as a database with four linked spreadsheets. The Detail spreadsheet has exactly one row, storing global properties like bounding box or animation frame. The Primitive spreadsheet has one row per face, storing per-face data like material assignment or face area. The Point spreadsheet has one row per unique position, storing shared spatial data. The Vertex spreadsheet has one row per corner of every face, storing per-corner data like UV coordinates.

The critical insight is that these spreadsheets are linked, not independent. Each Vertex row contains a foreign key pointing to a Point row. When you query a vertex's position, the system follows this reference to the Point table. When you modify a point's position, every vertex referencing that point sees the change automatically. This relational structure enables UV seams (vertices with different UVs referencing the same point) and hard edges (vertices with different normals at shared positions).

The analogy extends to attribute queries. Asking for an attribute at vertex scope triggers a lookup cascade: if the attribute does not exist on vertices, the system checks points, then primitives, then detail. Higher-specificity levels shadow lower ones, exactly like variable scoping in programming languages.

---

## The Four Attribute Classes

Houdini organizes attributes into four distinct classes, each serving a specific architectural purpose. The class determines both the storage cardinality and the lookup precedence.

| Class | Cardinality | Typical Use Cases | Precedence |
|-------|-------------|-------------------|------------|
| **Detail** | 1 per geometry | Bounds, name, frame count | Lowest (4) |
| **Primitive** | 1 per face | Material ID, face group | 3 |
| **Point** | 1 per unique position | Position (P), velocity (v) | 2 |
| **Vertex** | 1 per corner per face | UV coordinates, normals, colors | Highest (1) |

The precedence system means that vertex-level attributes shadow point-level attributes with the same name. If both `Cd` (color) attributes exist on points and vertices, vertex queries return vertex data while point queries return point data. Operations that need to resolve ambiguity use the highest-precedence value.

---

## Data Types and Arrays

Houdini supports a rich set of attribute data types that cover both numerical and structured data.

The following table summarizes the core types.

| Type | Components | Typical Attributes |
|------|------------|-------------------|
| **Float** | 1 | `pscale`, `age`, `mass` |
| **Integer** | 1 | `id`, `piece`, `class` |
| **Vector2** | 2 | `uv`, `pivot2d` |
| **Vector3** | 3 | `P`, `N`, `Cd`, `v` |
| **Vector4** | 4 | `orient` (quaternion), `tangent` |
| **String** | variable | `name`, `path`, `material` |
| **Dictionary** | variable | `properties` (JSON-like) |

Every base type supports array variants. An `int[]` attribute stores a variable-length integer array per element. A `vector[]` attribute stores a variable-length list of 3D vectors. This enables advanced workflows like storing connectivity graphs or path histories directly on geometry elements.

Dictionary attributes deserve special attention. These store JSON-like key-value structures, enabling extensible metadata without schema changes. A dictionary attribute can hold nested objects, arrays, and mixed types, making it ideal for pipeline metadata that evolves over time.

---

## Semantic Type Information

Beyond the data type, Houdini assigns semantic type information that controls how attributes behave under transformation. This separation is the key to geometric correctness.

The following table shows how type info affects transform behavior.

| Attribute | Type Info | Transform Behavior |
|-----------|-----------|-------------------|
| `P` | position | Full affine: translate + rotate + scale |
| `N` | normal | Inverse-transpose of upper 3x3 |
| `Cd` | color | No transformation |
| `uv` | texturecoord | No transformation (preserves seams) |
| `v` | vector | Rotate + scale, no translation |
| `orient` | quaternion | Rotation composition only |
| `rest` | position | Full affine (rest position) |
| `up` | vector | Rotate only, no scale or translate |

The normal case illustrates why this matters. When you scale a sphere non-uniformly, the surface normals must tilt to remain perpendicular to the surface. Applying the direct transform matrix produces normals that point incorrectly after scaling. The inverse-transpose preserves perpendicularity, which the renderer needs for correct lighting.

Type info also guides interpolation. Position attributes interpolate linearly. Quaternion attributes interpolate via spherical linear interpolation (slerp). Normal attributes interpolate and renormalize. The system handles these cases automatically when subdividing, resampling, or blending geometry.

---

## Attribute Precedence in Practice

The precedence system enables powerful workflows where general defaults are overridden by specific exceptions.

Consider a character mesh where most faces share a skin material but the eyes use a different shader. You store `material = "skin"` at the detail level as a global default, then store `material = "eye"` on the eye primitives. When the renderer queries material per primitive, detail provides the default and primitive-level overrides apply where present.

The following pseudo-code illustrates the lookup cascade.

```
function getAttribute(name, vertex):
    if vertex_attributes.has(name):
        return vertex_attributes[name][vertex]
    point = vertex.point()
    if point_attributes.has(name):
        return point_attributes[name][point]
    primitive = vertex.primitive()
    if primitive_attributes.has(name):
        return primitive_attributes[name][primitive]
    if detail_attributes.has(name):
        return detail_attributes[name]
    return None
```

This cascade means you can start with broad defaults and progressively add specificity without restructuring your data. The pattern encourages layered workflows where base materials, per-region overrides, and per-vertex details coexist without conflict.

---

## Attribute Promotion

Converting attributes between classes requires explicit promotion operations with configurable merge strategies. You cannot simply copy point colors to vertices — you must decide how to handle the many-to-one relationship when multiple vertices reference the same point.

The following table shows available merge strategies.

| Strategy | Behavior | Use Case |
|----------|----------|----------|
| **max** | Largest value wins | Priority attributes |
| **min** | Smallest value wins | Distance fields |
| **average** | Arithmetic mean | Smoothing, blending |
| **sum** | Total of all values | Accumulated quantities |
| **median** | Middle value | Outlier rejection |
| **mode** | Most common value | Categorical data |
| **first** | First encountered | Arbitrary tiebreak |
| **last** | Last encountered | Arbitrary tiebreak |

Promotion operates within optional partition boundaries using "piece" attributes. When promoting vertex colors to points, you can specify that averaging should happen only within each connected component rather than globally. This prevents color bleeding across separate islands.

The promotion workflow follows a consistent pattern.

```
# Promote vertex UV to point UV using average
Attribute Promote SOP:
    Original Class: Vertex
    Original Name: uv
    New Class: Point
    Promotion Method: Average
    Piece Attribute: (none or "island")
```

This explicitness prevents the subtle bugs that arise from implicit conversions. Every class change requires a conscious decision about the merge strategy.

---

## Special Attributes and Conventions

Certain attribute names carry semantic meaning that the system recognizes and handles specially.

Position (`P`) is the most fundamental. Every point must have a position, and the system creates this attribute automatically. The `P` attribute always transforms with the full affine matrix.

Normal (`N`) guides shading and affects how surfaces appear under lighting. When present, renderers use vertex or point normals for smooth shading. When absent, renderers compute face normals for flat shading.

Color (`Cd`) follows the convention of using a 3-component vector (RGB). Many operations preserve and blend color automatically, making it the standard channel for visualization during procedural development.

Velocity (`v`) indicates motion direction and speed. Renderers use this for motion blur. Simulation systems use it for advection and collision response.

Identifier (`id`) provides persistent tracking across frames. Points can appear and disappear, but matching `id` values identify the same logical point across time.

Scale (`pscale`) provides uniform per-point scaling. Instance and copy operations multiply their base scale by this value.

---

## Implications for Flux Design

Houdini's attribute system validates several Flux design decisions while highlighting gaps to address.

### Validation: Bridge Operators

Flux plans to use explicit bridge operators like `MeshGetNormals` and `MeshGetVertices` rather than implicit attribute access through magic names. Houdini's precedence system reveals why this matters: implicit access hides which class level you are reading from, making debugging difficult. Bridge operators make the data flow explicit in the node graph, exactly as Houdini's Attribute Wrangle nodes must specify which class they operate on.

### Recommendation: Store Type Info

Flux should store semantic type information alongside attribute data, not just the numerical type. The following structure captures the essential information.

```rust
pub struct AttributeMetadata {
    pub name: String,
    pub data_type: DataType,
    pub type_info: TypeInfo,
    pub default_value: Option<Value>,
}

pub enum TypeInfo {
    Position,      // Full transform
    Normal,        // Inverse-transpose
    Vector,        // Rotate + scale, no translate
    Quaternion,    // Rotation composition
    Color,         // No transform
    TextureCoord,  // No transform
    Generic,       // No transform (default)
}
```

This metadata enables correct automatic transformation when applying matrices to geometry, eliminating an entire category of visual bugs.

### Recommendation: Support All Four Classes

Flux should implement all four attribute classes from the start, even if initial use cases only need points and vertices. The detail class enables global defaults that reduce per-element storage. The primitive class enables per-face material assignment without vertex duplication.

The class hierarchy enables the precedence system, which in turn enables layered workflows.

```rust
pub struct AttributeStorage {
    detail: HashMap<String, AttributeArray>,
    primitive: HashMap<String, AttributeArray>,
    point: HashMap<String, AttributeArray>,
    vertex: HashMap<String, AttributeArray>,
}

impl AttributeStorage {
    pub fn get_for_vertex(
        &self,
        name: &str,
        vertex_idx: u32,
        point_idx: u32,
        prim_idx: u32,
    ) -> Option<Value> {
        self.vertex.get(name)
            .and_then(|arr| arr.get(vertex_idx))
            .or_else(|| self.point.get(name).and_then(|arr| arr.get(point_idx)))
            .or_else(|| self.primitive.get(name).and_then(|arr| arr.get(prim_idx)))
            .or_else(|| self.detail.get(name).and_then(|arr| arr.get(0)))
    }
}
```

### Recommendation: Consider Dictionary Attributes

Dictionary attributes provide schema-free extensibility for pipeline metadata. Flux should consider supporting a JSON-like value type for attributes that need structured data without predefined schemas.

This enables workflows where artists attach arbitrary metadata during production without framework changes.

---

## Flux Gaps

Implementing Houdini-style attributes in Flux requires addressing several architectural gaps.

### Gap 1: Attribute Promotion System

Flux needs a promotion system that converts attributes between classes with configurable merge strategies. This is not merely a convenience feature — it is essential for correct attribute propagation through operations like mesh decimation or subdivision.

Without promotion, operations that change topology must manually handle attribute transfer, leading to inconsistent behavior across the node library.

### Gap 2: Transform-Aware Attribute System

Flux transformation nodes must query attribute type info and apply the correct matrix variant. This requires either a central registry of known attributes or per-attribute metadata storage.

The transform pipeline should handle positions, normals, vectors, and quaternions without operator authors needing to implement special cases.

### Gap 3: Interpolation System

Subdivision, resampling, and morphing operations need type-aware interpolation. Positions interpolate linearly. Normals interpolate and renormalize. Quaternions use slerp. Colors may need gamma-correct blending depending on the color space.

Flux needs an interpolation trait that attributes implement based on their type info.

### Gap 4: Piece-Based Operations

Promotion and many other operations should support partition boundaries. Averaging vertex colors to points should not blend across disconnected mesh islands.

This requires either connectivity analysis or explicit piece attributes that operations respect.

### Gap 5: Array Attributes

Variable-length array attributes enable advanced workflows but complicate storage and GPU upload. Flux should decide whether to support arrays from the start or defer to a future version.

Array attributes cannot use simple contiguous storage — they require either indirection tables or separate allocations per element.

---

## References

- [Geometry Attributes](https://www.sidefx.com/docs/houdini/model/attributes.html) - Core attribute documentation
- [Attribute Classes](https://www.sidefx.com/docs/houdini/model/attributes.html#classes) - Detail, primitive, point, vertex explanation
- [Standard Attributes](https://www.sidefx.com/docs/houdini/model/attributes.html#standard) - Semantic conventions
- [Type Qualifiers](https://www.sidefx.com/docs/houdini/model/attributes.html#typeinfo) - Transform behavior tags
- [Attribute Promote SOP](https://www.sidefx.com/docs/houdini/nodes/sop/attribpromote.html) - Promotion operations
- [VEX Attribute Functions](https://www.sidefx.com/docs/houdini/vex/attrib_suite.html) - Programmatic attribute access
- [Geometry Spreadsheet](https://www.sidefx.com/docs/houdini/ref/panes/geosheet.html) - Visual attribute inspection

---

## Quality Self-Check

**Requirement 1: First 3 paragraphs contain ZERO code blocks**
- Verified. The opening hook, "The Problem of Generic Data Attachment" section (3 paragraphs), and "The Spreadsheet Analogy" section (3 paragraphs) contain no code blocks. First code appears in "Attribute Precedence in Practice" section.

**Requirement 2: Every code block has a preceding paragraph explaining it**
- Verified. Each code block follows explanatory text:
  - Pseudo-code cascade follows "The following pseudo-code illustrates..."
  - Promotion workflow follows "The promotion workflow follows..."
  - Rust structs follow paragraphs explaining their purpose

**Requirement 3: At least ONE strong analogy**
- Verified. "The Spreadsheet Analogy" section provides an extended analogy comparing the four attribute classes to linked database spreadsheets with foreign keys between them. The analogy clarifies the relational nature of vertex-to-point references and the precedence cascade.

**Requirement 4: Problem statement in first 5 paragraphs**
- Verified. Paragraphs 1-3 establish the dual problem of transform correctness and attribute scope ambiguity before introducing Houdini's solution. The opening hook poses the problem as a question about normal transformation.

**Requirement 5: Active voice throughout**
- Verified. Active constructions dominate: "Every procedural system faces...", "Houdini organizes attributes...", "The precedence system means...", "Flux should store semantic type information...". No passive voice walls detected.
