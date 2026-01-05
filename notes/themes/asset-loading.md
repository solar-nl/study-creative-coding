# Theme: Asset Loading

> Cross-cutting analysis of how frameworks load external resources.

## Concept Overview

Asset loading includes:
- Images, textures
- Fonts
- Audio files
- 3D models
- Async patterns

## Key Questions

- Sync vs async loading?
- Preload patterns?
- Caching strategies?
- Error handling?

## Recommendations for Rust Framework

1. **Async loading** — Non-blocking file I/O
2. **Preload phase** — Optional loading phase before draw
3. **Handle types** — References to loaded assets
4. **Error results** — Handle missing/corrupt files
