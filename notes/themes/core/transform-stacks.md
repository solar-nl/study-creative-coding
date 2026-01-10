# Theme: Transform Stacks

> Not yet complete. This theme document needs cross-framework analysis.

Cross-cutting analysis of how frameworks handle transformations.

## Concept Overview

Transform stacks manage:
- Translation, rotation, scaling
- push/pop state management
- Matrix composition
- Coordinate systems

## Key Questions

- How is the matrix stack implemented?
- What coordinate system is used (y-up, y-down)?
- How are transforms composed?
- How does 3D transform differ from 2D?

## Recommendations for Rust Framework

1. **Matrix stack** — Push/pop with save/restore semantics
2. **[glam](https://github.com/bitshifter/glam-rs) for math** — Use established linear algebra crate
3. **Builder methods** — `.translate()`, `.rotate()`, `.scale()`
4. **Clear coordinate system** — Document y-direction, units
