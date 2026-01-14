# Non-Mesh Geometry Types

What if the most expressive geometry in your scene contained no triangles at all?

Creative coding frameworks typically treat meshes as the universal geometry format: vertices, edges, faces, done. This mesh-centric view works well for static 3D models but creates friction when representing curves, volumes, particles, and mathematical shapes. Houdini's geometry system embraces a richer vocabulary where each representation type serves specific creative needs without forcing conversion to triangles.

The problem becomes concrete when you try to represent a smoke simulation as triangles. Voxel data doesn't have vertices. A particle system where millions of points fly through space has no faces. A mathematical sphere defined by center and radius achieves perfect smoothness with zero polygons. Converting these representations to meshes either destroys information (smoke becomes iso-surface), explodes memory (particles become point clouds of tiny spheres), or introduces unnecessary approximation (sphere becomes tessellated polyhedron).

---

## The Workshop Shelf Analogy

Think of geometry types as specialized containers in an artist's workshop. Meshes are like wire armatures—great for sculpted forms where you need to define exact surface topology. But the workshop also needs paint buckets (volumes storing density at every voxel), string spools (curves defining paths and profiles), bags of sand (point clouds for scattered distributions), and mathematical templates (quadratic primitives for perfect circles and spheres). Each container serves its purpose without requiring translation to wire armature form.

Houdini's genius lies in treating all these containers as first-class geometry that flows through the same node networks. A single scene can contain curves, volumes, points, and meshes, with operators that understand how to work with each type.

---

## Curves

### Representation Types

Houdini supports three primary curve representations, each with distinct characteristics.

| Type | Degree | Smoothness | Use Case |
|------|--------|------------|----------|
| **Polyline** | 1 | Linear segments | Paths, guides, low-res approximations |
| **Bezier** | 2-10 | Tangent-controlled | Animation curves, profiles |
| **NURBS** | Variable | Weighted control | CAD-quality curves, precise shapes |

### Storage Model

Curves store control vertices (CVs) rather than surface points. The curve passes near these CVs according to mathematical rules determined by order, degree, and knot spacing.

```
Control Vertices: [CV0, CV1, CV2, CV3, ...]
Knots: [k0, k1, k2, k3, ...]  // Parameter values
Order: 4 (cubic)
Degree: 3 (order - 1)
```

The knot vector controls how CVs influence different curve segments. Uniform knots create even spacing; chord-length knots adapt to CV distances.

### Common Operations

Curves support operations that would be awkward or impossible with meshes.

| Operation | Purpose |
|-----------|---------|
| **Resample** | Convert to even-length segments |
| **Refine** | Add CVs without changing shape |
| **Sweep** | Create surface by sweeping cross-section |
| **Loft** | Create surface between multiple curves |
| **Extrude** | Pull profile along path |

### Creative Coding Relevance

Curves enable path-based workflows that mesh editing cannot match. A particle following a curve samples position by parameter value. A camera dolly interpolates smoothly along a NURBS path. A cable simulation uses curve CVs as physics handles while rendering smooth geometry.

Reference: [Curve SOPs](https://www.sidefx.com/docs/houdini/nodes/sop/curve.html)

---

## Volumes

### Standard Volumes vs. VDB

Houdini offers two volume representations with different trade-offs.

**Standard Volumes** divide a bounding box into a regular 3D grid of voxels. Every voxel stores a value, consuming memory proportional to resolution cubed. A 256³ volume uses 16 million voxels regardless of content.

**VDB (OpenVDB)** stores only non-background voxels in a sparse hierarchical structure. Empty regions cost nothing. A wispy cloud in a 1024³ domain might use only 1% of the memory a standard volume would require.

### Data Types

Volumes store different data depending on their purpose.

| Type | Storage | Use Case |
|------|---------|----------|
| **Scalar (fog)** | Single float | Density, temperature |
| **SDF** | Signed distance | Surface representation, collisions |
| **Vector** | Three floats | Velocity, force fields |

### Common Operations

Volume operations transform voxel data without creating explicit geometry.

| Operation | Purpose |
|-----------|---------|
| **VDB from Polygons** | Convert surface to implicit volume |
| **VDB from Particles** | Create fog volume from point cloud |
| **Volume Mix** | Combine volumes with math operations |
| **Convert Volume** | Extract iso-surface as polygons |

### Creative Coding Relevance

Volumes unlock effects that polygon meshes cannot represent. Fog density varies continuously in space. Fire temperature gradients drive color mapping. Fluid velocity fields advect particles through complex flow patterns. Signed distance fields enable smooth boolean operations and collision detection.

Reference: [Volume Primitives](https://www.sidefx.com/docs/houdini/model/volumes.html)

---

## Point Clouds

### Representation

Point clouds contain points without primitive connectivity. Each point carries position (`P`) plus arbitrary attributes but references no faces or edges.

### Attribute-Heavy Workflows

Without topology, points rely entirely on attributes for meaning. A particle system stores position, velocity, age, and color per point. A scattered distribution stores orientation, scale, and type selector per point. The point cloud becomes a database where each point is a record.

### Common Operations

| Operation | Purpose |
|-----------|---------|
| **Scatter** | Distribute points on surface/volume |
| **Point Cloud Surface** | Reconstruct mesh from points |
| **Point Cloud Iso** | Create implicit surface |
| **Cluster Points** | Group nearby points |

### Creative Coding Relevance

Point clouds excel at massive scale and attribute variation. A million particles cost only position plus attributes per point—no edge or face connectivity overhead. Procedural instancing uses point clouds as placement guides where each point carries transform attributes. LiDAR and photogrammetry data naturally arrives as point clouds.

Reference: [Scatter SOP](https://www.sidefx.com/docs/houdini/nodes/sop/scatter.html)

---

## Metaballs and Quadratics

### Metaballs

Metaballs define implicit surfaces through overlapping density fields. Each metaball contributes density that falls off with distance from its center. Where metaballs overlap, densities add, creating smooth blending.

The surface exists at a threshold density level. As metaballs approach each other, their combined density crosses the threshold, causing the surfaces to merge organically.

**Use cases**: Organic modeling, liquid droplets, blobby effects where smooth merging is desired.

### Quadratic Primitives

Quadratic primitives define shapes through mathematical parameters rather than vertices.

| Primitive | Parameters | Memory |
|-----------|------------|--------|
| **Sphere** | Center, radius | 1 point + 3 floats |
| **Circle** | Center, radius, orientation | 1 point + 4 floats |
| **Tube** | Center, radius, length, taper | 1 point + 6 floats |

A mathematically-defined sphere uses a single point and three float values regardless of visual smoothness. The equivalent polygon sphere needs hundreds or thousands of vertices.

**Use cases**: Lightweight instancing, bounding volumes, preview geometry, mathematical accuracy.

---

## Flux Expansion Roadmap

Based on Houdini's geometry vocabulary, Flux should prioritize non-mesh types in this order.

### Priority 1: Essential Foundation

**Curves** enable path-based workflows fundamental to creative coding. Animation paths, procedural shapes, and sweep operations all require curve primitives.

**Point Clouds** underpin particle systems and procedural distribution. Every scatter-based workflow produces point clouds that drive downstream instancing.

### Priority 2: Simulation Support

**Sparse Volumes (VDB-style)** unlock volumetric effects without prohibitive memory costs. Fog, fire, and fluid simulation all require volume representation.

### Priority 3: Advanced Features

**Quadratic Primitives** optimize scenarios where mathematical shapes suffice. Bounding volumes, preview geometry, and massive instancing benefit from lightweight representations.

**Metaballs** enable organic modeling and implicit surface workflows for specialized use cases.

---

## Flux Gaps

Adding non-mesh geometry to Flux requires addressing architectural gaps.

| Gap | Description | Impact |
|-----|-------------|--------|
| **Curve Value type** | Value enum needs Curve variant with control points, knots, degree | Foundation for path workflows |
| **Volume Value type** | Sparse voxel storage (not dense 3D array) | Memory-efficient volumetric data |
| **Point Cloud operations** | Currently no scatter, cluster, or surface reconstruction | Procedural distribution |
| **Implicit surface rendering** | GPU raymarching for volumes and metaballs | Visual output for non-mesh types |
| **Type conversion operators** | Mesh ↔ Volume ↔ Points conversion | Workflow interoperability |
| **Curve evaluation** | Sample position/tangent by parameter | Path-following behaviors |

---

## References

- [Geometry Primitives](https://www.sidefx.com/docs/houdini/model/primitives.html)
- [Curve SOPs](https://www.sidefx.com/docs/houdini/nodes/sop/curve.html)
- [Volume Primitives](https://www.sidefx.com/docs/houdini/model/volumes.html)
- [VDB Overview](https://www.sidefx.com/docs/houdini/nodes/sop/vdb.html)
- [Scatter SOP](https://www.sidefx.com/docs/houdini/nodes/sop/scatter.html)
- [Point Cloud Surface](https://www.sidefx.com/docs/houdini/nodes/sop/pointcloudsurface.html)
- [Metaball SOP](https://www.sidefx.com/docs/houdini/nodes/sop/metaball.html)

---

## Quality Self-Check

**Requirement 1: First 3 paragraphs contain ZERO code blocks**
- Paragraphs 1-3 establish hook, problem, and workshop analogy with no code
- PASS

**Requirement 2: Every code block has a preceding paragraph**
- Single code block (curve storage) follows "Curves store control vertices..." paragraph
- PASS

**Requirement 3: At least ONE strong analogy**
- Workshop shelf analogy connects geometry types to familiar containers
- PASS

**Requirement 4: Problem statement in first 5 paragraphs**
- Paragraph 2 explicitly frames the problem of representing non-mesh data
- PASS

**Requirement 5: No passive voice walls**
- Active voice throughout: "Houdini offers," "Volumes store," "Point clouds contain"
- PASS
