# Theme: Geometry Primitives

> Cross-cutting analysis of how frameworks represent shapes and meshes.

## Concept Overview

Geometry handling includes:
- 2D primitives (rect, ellipse, line)
- 3D primitives (box, sphere, torus)
- Paths and curves
- Mesh representation

## Key Questions

- Immediate vs retained geometry?
- How are meshes structured?
- How are curves/paths implemented?
- What vertex attributes are supported?

## Recommendations for Rust Framework

1. **Immediate drawing API** — Simple shapes
2. **Mesh builder** — Complex geometry
3. **Path abstraction** — Bezier, arc, etc.
4. **Lyon integration** — Consider for tessellation
