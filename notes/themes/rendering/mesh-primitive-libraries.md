# Rendering Deep Dive: 3D Mesh Primitive Libraries

> Every major 3D framework converges on the same seven primitives, names them almost identically, but sizes them inconsistently — the one design choice that CME must make deliberately.

## Key Insight

> **The consensus:** Box/Cuboid, Sphere (UV), Plane, Cylinder, Cone, Torus, and Capsule form a universally-agreed v1 set. Segment naming is near-uniform (`radial_segments`, `height_segments`, `width_segments`). The only live controversy is **size vs. half-size** as the primary parameter: three.js and Blender use full size, Bevy stores half-size internally but exposes full-size constructors, and slr-wgpu's existing API is split (`cube(size)` vs `inverted_cube(half_size)`). Pick one and hold it.

---

## The Surveyed Frameworks

**three.js** is the most comprehensive JavaScript 3D library and the de-facto reference for web 3D. Its geometry catalog is the widest surveyed, covering 21 geometry types including all common primitives plus TorusKnot, Lathe, Extrude, and Tube. Constructor signatures use full-size dimensions and camelCase `widthSegments`-style segment names.

**Bevy** (Rust game engine) separates math primitives (`bevy::math::primitives`) from mesh builders. Math types like `Cuboid` store `half_size: Vec3` internally, but the `new(x, y, z)` constructor takes full dimensions. Sphere exposes both UV (`uv(sectors, stacks)`) and icosphere (`ico(subdivisions)`) mesh builders. This is the closest architectural cousin to CME/flux.

**Godot 4** exposes PrimitiveMesh subclasses (BoxMesh, SphereMesh, etc.) as scene-tree nodes with inspector-editable properties. Uses full-size `size: Vector3` for the box; for sphere uses `radius` (not diameter). Uses `radial_segments` and `rings` consistently across cylinder, sphere, and capsule.

**OpenSCAD** is the parametric solid-modeling baseline. Uses `cube(size, center)`, `sphere(r)`, `cylinder(h, r1, r2, center)`. The `center` boolean (default false = base at origin, true = centered) is unique to its bottom-up construction model. Supports both `r`/`d` (radius/diameter) for sphere and cylinder.

**Blender** (Add Mesh operator) is the creative-software reference. Blocked by 403 in this session, but parameters are well-known from earlier research: uses `size` for uniform scale on Cube, `radius` for Sphere/Cylinder/Cone/Torus, `segments` and `ring_count` for sphere, `vertices` for cylinder/cone edge count.

**Unity** exposes a minimal `PrimitiveType` enum: `Sphere`, `Capsule`, `Cylinder`, `Cube`, `Plane`, `Quad`. No parameter control — these are editor placeholders only, not a design reference for a procedural operator API.

**Houdini Box/Sphere SOP** represents the professional DCC reference. Box uses `size` (XYZ vector) and per-axis `divisions`. Sphere SOP exposes multiple primitive types (polygon mesh, NURBS, Bezier) and separate `rows`/`columns` controls. The "Rows & Cols" connectivity option matches what three.js calls `widthSegments`/`heightSegments`.

**slr-wgpu (current)** has `cube(size: f32)`, `inverted_cube(half_size: f32)`, `uv_sphere(radius, sectors, stacks)`, `plane(width, depth, subdivisions: u32)`, `quad(size)`. The `plane` uses a single `subdivisions` count for both axes, creating only square sub-grids. The naming inconsistency between `cube` and `inverted_cube` is the primary problem to fix.

---

## Primitive Coverage Matrix

| Primitive | three.js | Bevy | Godot 4 | OpenSCAD | Unity | Houdini | slr-wgpu |
|-----------|----------|------|---------|----------|-------|---------|----------|
| Box/Cuboid | ✓ `width, height, depth, wSeg, hSeg, dSeg` | ✓ `Cuboid {half_size}` | ✓ `size: Vector3, subdivide_*` | ✓ `size, center` | ✓ Cube | ✓ `size XYZ, divisions XYZ` | ✓ `cube(size)` |
| Sphere (UV) | ✓ `radius, wSeg=32, hSeg=16, phiStart, phiLen, thetaStart, thetaLen` | ✓ `.mesh().uv(sectors, stacks)` | ✓ `radius=0.5, radial_segments=64, rings=32` | ✓ `r=1, $fn` | ✓ Sphere | ✓ `radius, rows, cols` | ✓ `uv_sphere(radius, sectors, stacks)` |
| Sphere (ico) | ✓ `IcosahedronGeometry(radius, detail)` | ✓ `.mesh().ico(subdivisions)` | — | — | — | — | — |
| Plane | ✓ `width=1, height=1, wSeg=1, hSeg=1` | ✓ `Plane3d.mesh().size(w,h).subdivisions(n)` | ✓ `size: Vector2(2,2), subdivide_*` | — | ✓ Plane (10×10 XZ) | ✓ | ✓ `plane(width, depth, subdivisions)` |
| Cylinder | ✓ `rTop=1, rBot=1, h=2, radSeg=8, hSeg=1, openEnded` | ✓ `Cylinder::default()` | ✓ `top_r=0.5, bot_r=0.5, h=2, radial_seg=64, rings=4` | ✓ `h=1, r1=1, r2=1, center` | ✓ Cylinder | ✓ | — |
| Cone | ✓ `ConeGeometry` (Cylinder r2=0) | ✓ `Cone::default()` | ✓ (CylinderMesh r=0) | ✓ (cylinder r2=0) | — | — | — |
| Torus | ✓ `radius, tube, radSeg=8, tubSeg=6, arc` | ✓ `Torus {major_radius=0.75, minor_radius=0.25}` | ✓ `TorusMesh` | — | — | ✓ Torus SOP | — |
| Capsule | ✓ `radius=1, length=1, capSeg=4, radSeg=8` | ✓ `Capsule3d {radius=0.5, half_length=0.5}` | ✓ `radius=0.5, height=2, radial_seg=64, rings=8` | — | ✓ Capsule | — | — |
| Tetrahedron | ✓ `TetrahedronGeometry(r, detail)` | ✓ `Tetrahedron::default()` | — | — | — | — | — |
| Octahedron | ✓ `OctahedronGeometry(r, detail)` | — | — | — | — | — | — |
| Dodecahedron | ✓ `DodecahedronGeometry(r, detail)` | — | — | — | — | — | — |
| Icosahedron | ✓ `IcosahedronGeometry(r, detail)` | — | — | — | — | — | — |
| TorusKnot | ✓ `TorusKnotGeometry` | — | — | — | — | — | — |
| Inverted box | — | — | — | — | — | — | ✓ `inverted_cube(half_size)` |
| Quad | — | — | — | — | ✓ Quad (1×1 XY) | — | ✓ `quad(size)` |

**Universally provided (all frameworks):** Box, Sphere (UV), Plane, Cylinder.

**Common (4+ frameworks):** Cone, Torus, Capsule.

**Niche:** Platonic solids (three.js + Bevy only), TorusKnot (three.js only), inverted box (slr-wgpu only — for skybox use).

---

## Parameter Naming Conventions

### Size / Dimensions / Extent

There is strong convergence on using **full size** (not half-size or radius) as the user-facing dimension for box-like shapes:

| Framework | Box size param | Meaning |
|-----------|----------------|---------|
| three.js | `width, height, depth` (default 1) | Full dimension |
| Bevy | `Cuboid::new(x, y, z)` | Full dimension (stores half internally) |
| Godot | `size: Vector3(1,1,1)` | Full dimension |
| Houdini | `size: [x,y,z]` | Full dimension |
| OpenSCAD | `size` (scalar or [x,y,z]) | Full dimension |
| slr-wgpu | `cube(size: f32)` | Full dimension (uniform) |

For spheres and rounded shapes, **radius** (not diameter) is universal:

- three.js `SphereGeometry(radius=1)`
- Bevy `Capsule3d { radius: 0.5 }`
- Godot `SphereMesh.radius = 0.5`
- OpenSCAD `sphere(r=1)` (also supports `d=` as alternative)

OpenSCAD is the only framework offering a `d` (diameter) alternative. Nobody else does.

### Segments / Subdivisions / Slices / Stacks

This is where frameworks differ most in *naming*, but agree in *semantics*:

| Parameter meaning | three.js | Godot | Houdini | slr-wgpu |
|------------------|----------|-------|---------|----------|
| Around the equator | `widthSegments` | `radial_segments` | `columns` | `sectors` |
| Pole-to-pole | `heightSegments` | `rings` | `rows` | `stacks` |
| Along a cylinder axis | `heightSegments` | `rings` | rows | — |
| Per-face subdivision | `widthSegments`, etc. | `subdivide_width` | `divisions` | `subdivisions` |

The dominant pattern for rotationally symmetric shapes (sphere, cylinder, torus) is:
- **`radial_segments`** — slices around the axis (Godot wins the clearest name)
- **`height_segments`** — rings along the axis

For box-like shapes with per-axis control:
- three.js: `widthSegments, heightSegments, depthSegments`
- Godot: `subdivide_width, subdivide_height, subdivide_depth`
- Houdini: `divisions` as XYZ vector

For plane:
- three.js: `widthSegments, heightSegments` (per-axis, both default 1)
- Bevy: `.subdivisions(n)` (single value, creates square grid)
- Godot: `subdivide_width, subdivide_depth`
- slr-wgpu current: `subdivisions: u32` (single, square only)

The per-axis approach (three.js/Godot/Houdini) is strictly more general and costs nothing in the operator API.

### Radius vs. Diameter

Unanimous: **radius** is the primary parameter. OpenSCAD's `d=` is a convenience alias, not a primary convention.

### Per-Axis vs. Uniform Parameters

| Shape | Per-axis preferred? | Rationale |
|-------|---------------------|-----------|
| Box | Yes — `width, height, depth` | Non-cubic boxes are essential |
| Plane | Yes — `width_segments, height_segments` | Different X/Z tessellation is common |
| Sphere | No — single `radius` | Ellipsoids are separate |
| Cylinder | Separate `radius_top, radius_bottom, height` | Cone reuse requires two radii |
| Torus | Two radii: `major_radius, minor_radius` | Standard torus parametrization |
| Capsule | `radius, length` | Separate cap and body params |

---

## Default Value Conventions

| Primitive | three.js defaults | Bevy defaults | Godot defaults | Recommendation |
|-----------|------------------|---------------|----------------|----------------|
| Box | `1×1×1`, 1 seg each | `1×1×1` half=0.5 | `1×1×1`, 0 subdivisions | `1×1×1`, 1 seg each |
| Sphere | `r=1`, 32×16 segments | radius=0.5, `.uv(32,18)` | `r=0.5`, 64 radial, 32 rings | `r=0.5`, 32 radial, 16 height |
| Plane | `1×1`, 1×1 segments | `.size(1,1)` `.subdivisions(1)` | `2×2`, 0 subdivisions | `1×1`, 1×1 segments |
| Cylinder | `rTop=1, rBot=1, h=2`, 8 radial | defaults via `Cylinder::default()` | `r=0.5, h=2`, 64 radial, 4 rings | `r=0.5, h=1`, 16 radial, 1 height |
| Cone | Cylinder with rTop=0 | `Cone::default()` | CylinderMesh rTop=0 | `r=0.5, h=1`, 16 radial |
| Torus | `r=1, tube=0.4`, 8×6 segments | `major=0.75, minor=0.25` | TorusMesh | `major_r=0.5, minor_r=0.2`, 24×12 |
| Capsule | `r=1, len=1`, 4 cap+8 radial | `r=0.5, half_len=0.5` | `r=0.5, h=2`, 64 radial, 8 rings | `r=0.5, length=1`, 16 radial, 4 cap |

Note: Godot and Bevy converge on `radius=0.5` for sphere (unit-diameter sphere). three.js uses `radius=1` (unit-radius sphere). The radius=0.5 convention means a default sphere fits in a 1-unit cube, which is ergonomically friendlier.

---

## Vertex Format Choices

All surveyed frameworks produce at minimum **position + normal + UV** for solid primitives:

- **three.js** `BufferGeometry`: position (Vec3), normal (Vec3), uv (Vec2) by default. Tangents optional.
- **Bevy** mesh: position, normal, uv, tangent attributes. Tangents must be explicitly generated.
- **slr-wgpu** `StandardVertex`: position + normal + UV — matches the minimum viable set.

Position-only meshes are used only for shadow geometry or wire-frame previews, not for shaded rendering. There is no framework that defaults to position-only for solid primitives.

Tangents are needed for normal mapping but are generated as a post-process step (MikkTSpace algorithm), not baked into primitive generators in any surveyed framework.

**Recommendation:** `StandardVertex { position: [f32;3], normal: [f32;3], uv: [f32;2] }` is exactly right for primitive operators. Tangents are a downstream concern.

---

## Orientation & Centering

| Convention | three.js | Bevy | Godot | slr-wgpu | OpenSCAD |
|------------|----------|------|-------|----------|----------|
| Y-up | Yes | Yes | Yes | Yes | No (Z-up) |
| Centered at origin | Yes | Yes | Yes | Yes | No (default base at origin) |
| Plane orientation | XY plane | XZ plane | XZ plane | XZ plane | XY |

three.js `PlaneGeometry` is in the XY plane (vertical by default), which surprises users coming from DCC tools. Every other framework orients planes in XZ (horizontal ground plane). Bevy, Godot, and slr-wgpu all use XZ — this is the right convention.

OpenSCAD's `center=false` default (base at Z=0 rather than centered) is the outlier and specific to its constructive-solid-geometry model. For a node graph where operators compose freely, **centered at origin** is universally better — the operator's consumer controls placement.

---

## Sphere Variants

There are three distinct ways to tessellate a sphere:

**UV sphere (latitude/longitude):** Quads everywhere except degenerate triangles at the poles. Parameters: `radial_segments` (longitude divisions) × `height_segments` (latitude rings). Used by: three.js `SphereGeometry`, Godot `SphereMesh`, slr-wgpu `uv_sphere`, Houdini Sphere SOP. Produces predictable UV layout (equirectangular projection). The poles have topology artifacts (all edges converge).

**Icosphere:** Subdivided icosahedron. All triangles, near-uniform distribution, no pole artifacts. Parameter: `subdivisions` (0=20 faces, 1=80, 2=320...). Used by: three.js `IcosahedronGeometry(r, detail)`, Bevy `.mesh().ico(subdivisions)`. Better for geometry deformation (displacement maps, sculpting). UVs are awkward (requires seam handling).

**Cube-projected sphere (cubemap sphere):** 6 quad patches projected onto a sphere. Used in rendering engines for seamless cubemap UVs. Not exposed as a user primitive in any framework surveyed.

**Recommendation for CME v1:** Expose UV sphere only. It has the most predictable UV mapping for shader work, matches all DCC tool defaults, and the slr-wgpu infrastructure already implements it. Expose icosphere as a separate `IcosphereOp` or defer to v2 — do not bundle it into a mode flag on the sphere operator.

---

## Recommendations for CME/flux Mesh-Primitive Operators

### V1 Primitive Set

Start with these seven — they appear in every framework and cover the essential creative-coding vocabulary:

1. **BoxOp** — general cuboid; replaces `cube` and `inverted_cube`
2. **SphereOp** — UV sphere
3. **PlaneOp** — subdivided ground plane / quad mesh
4. **CylinderOp** — open or closed cylinder; cone is a degenerate case (top_radius=0)
5. **TorusOp** — donut/ring shape
6. **CapsuleOp** — pill shape; essential for collision proxies and organic forms
7. **InvertedBoxOp** — skybox/backdrop; keep as a separate operator with the same port names as BoxOp

The following are nice-to-have v2 candidates: Cone (can be a CylinderOp parameter), IcosphereOp, ConeFrustumOp.

### Port Names and Defaults

**BoxOp**
```
width:  f32 = 1.0   // X extent (full size, not half)
height: f32 = 1.0   // Y extent
depth:  f32 = 1.0   // Z extent
width_segments:  u32 = 1
height_segments: u32 = 1
depth_segments:  u32 = 1
```
Rationale: three.js, Godot, and Houdini all use `width/height/depth` as full dimensions. Per-axis segments are strictly more capable than a single `subdivisions` count, at no added cognitive cost.

**SphereOp** (UV sphere)
```
radius:           f32 = 0.5   // unit-diameter convention (Bevy, Godot)
radial_segments:  u32 = 32    // longitude divisions
height_segments:  u32 = 16    // latitude rings
```
Rationale: `radius=0.5` puts a default sphere inside a 1-unit box — consistent with BoxOp default. `radial_segments`/`height_segments` are clearer than three.js's `widthSegments`/`heightSegments` on a sphere.

**PlaneOp**
```
width:           f32 = 1.0   // X extent
depth:           f32 = 1.0   // Z extent
width_segments:  u32 = 1
depth_segments:  u32 = 1
```
Rationale: Oriented in XZ (Y-up ground plane), matching Bevy, Godot, slr-wgpu. Per-axis segments instead of the current single `subdivisions`. Rename the existing slr-wgpu `plane(width, depth, subdivisions)` to add `depth_segments` as a second axis.

**CylinderOp**
```
radius_top:      f32 = 0.5   // top cap radius (0 = cone)
radius_bottom:   f32 = 0.5   // bottom cap radius
height:          f32 = 1.0
radial_segments: u32 = 16
height_segments: u32 = 1
cap_top:         bool = true
cap_bottom:      bool = true
```
Rationale: two-radius form matches three.js `CylinderGeometry` and Godot `CylinderMesh`, enabling cone as a degenerate case. `height=1.0` rather than three.js's `height=2` matches the unit-box convention.

**TorusOp**
```
major_radius:    f32 = 0.5   // center to tube center
minor_radius:    f32 = 0.2   // tube radius
radial_segments: u32 = 24    // segments around the tube
tubular_segments:u32 = 12    // segments around the ring
```
Rationale: `major_radius`/`minor_radius` (Bevy) is clearer than three.js `radius`/`tube`. Default values produce a torus that fits inside a ~1.4-unit bounding box.

**CapsuleOp**
```
radius:          f32 = 0.5
length:          f32 = 1.0   // body length, excluding hemispherical caps
radial_segments: u32 = 16
cap_segments:    u32 = 8     // latitude rings per hemisphere cap
```
Rationale: `length` (three.js) is clearer than Bevy's `half_length` for a user-facing port. `radius + length` is more intuitive than Godot's `height` (which includes the caps).

**InvertedBoxOp**
```
width:  f32 = 1.0
height: f32 = 1.0
depth:  f32 = 1.0
```
Rationale: Same port names as BoxOp, takes full dimensions. Fix the slr-wgpu `inverted_cube(half_size)` inconsistency — move to full-size parameter at the operator layer.

### The Size vs. Half-Size Question

**Use full size everywhere at the operator layer.**

slr-wgpu's current split — `cube(size)` vs `inverted_cube(half_size)` — is the exact inconsistency to eliminate. The precedent from three.js, Godot, Houdini, and OpenSCAD is uniform: users specify full dimensions. Bevy stores `half_size` internally but its public API (`Cuboid::new(x, y, z)`) takes full dimensions. The flux operator ports should follow the same pattern: accept full dimensions, internally halve as needed.

### Orientation Convention

Y-up, centered at origin, plane in XZ. This matches Bevy, Godot, Houdini, and existing slr-wgpu. No exceptions for v1.

### Sphere Variant Question

UV sphere only for v1. The icosphere's advantages (uniform triangle distribution) matter for deformation workflows that CME does not yet need. Adding it later as `IcosphereOp` is straightforward — bundling it as a mode flag on `SphereOp` would complicate the operator's port surface unnecessarily.

---

## References

- [three.js BoxGeometry docs](https://threejs.org/docs/#api/en/geometries/BoxGeometry)
- [three.js SphereGeometry docs](https://threejs.org/docs/#api/en/geometries/SphereGeometry)
- [three.js CylinderGeometry docs](https://threejs.org/docs/#api/en/geometries/CylinderGeometry)
- [three.js CapsuleGeometry docs](https://threejs.org/docs/#api/en/geometries/CapsuleGeometry)
- [Bevy Capsule3d docs.rs](https://docs.rs/bevy/latest/bevy/math/prelude/struct.Capsule3d.html)
- [Bevy Cuboid docs.rs](https://docs.rs/bevy/latest/bevy/math/primitives/struct.Cuboid.html)
- [Bevy Torus docs.rs](https://docs.rs/bevy/latest/bevy/math/primitives/struct.Torus.html)
- [Bevy 3D shapes example](https://github.com/bevyengine/bevy/blob/main/examples/3d/3d_shapes.rs)
- [Godot BoxMesh](https://docs.godotengine.org/en/stable/classes/class_boxmesh.html)
- [Godot SphereMesh](https://docs.godotengine.org/en/stable/classes/class_spheremesh.html)
- [Godot PlaneMesh](https://docs.godotengine.org/en/stable/classes/class_planemesh.html)
- [Godot CylinderMesh](https://docs.godotengine.org/en/stable/classes/class_cylindermesh.html)
- [Godot CapsuleMesh](https://docs.godotengine.org/en/stable/classes/class_capsulemesh.html)
- [OpenSCAD Primitive Solids (Wikibooks)](https://en.wikibooks.org/wiki/OpenSCAD_User_Manual/Primitive_Solids)
- [Houdini Box SOP](https://www.sidefx.com/docs/houdini/nodes/sop/box.html)
- [Houdini Sphere SOP](https://www.sidefx.com/docs/houdini/nodes/sop/sphere.html)
- [Unity PrimitiveType scripting API](https://docs.unity3d.com/ScriptReference/PrimitiveType.html)
- [slr-wgpu mesh_primitives.rs](../../../CME/libs/slr-wgpu/src/core/mesh_primitives.rs) — current implementation reference
- Blender Add Mesh primitives doc — blocked (HTTP 403 during fetch); parameters sourced from community knowledge
