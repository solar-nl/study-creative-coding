# Theme: Asset Loading

> Not yet complete. This theme document needs cross-framework analysis of loading *patterns* (sync vs async, preload, caching). The *format* half is done: [`research/open-formats/framework-support-matrix.md`](../../../research/open-formats/framework-support-matrix.md) records which framework reads and writes which format and through what mechanism, [`research/open-formats/README.md`](../../../research/open-formats/README.md) is the landscape of open formats, and [`insights/open-formats.md`](../../../insights/open-formats.md) is the Flux tiering.

Cross-cutting analysis of how frameworks load external resources.

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
