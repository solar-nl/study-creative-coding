# Theme: Animation & Timing

> Cross-cutting analysis of how frameworks handle time and animation.

## Concept Overview

Animation and timing include:
- Frame loop / update cycle
- Delta time handling
- Easing functions
- Animation systems

## Key Questions

- Fixed vs variable timestep?
- How is frame rate controlled?
- What easing functions are provided?
- Is there a tweening/animation system?

## Recommendations for Rust Framework

1. **Fixed timestep option** — For deterministic updates
2. **Delta time access** — For variable timestep
3. **Easing functions** — Common easing library
4. **Simple tweening** — Consider built-in interpolation
