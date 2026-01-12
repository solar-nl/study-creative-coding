# Node Graph Systems

Comparative analysis of visual programming / operator graph systems across creative coding frameworks.

## Documents

| Document | Focus |
|----------|-------|
| [node-graph-systems.md](./node-graph-systems.md) | Overview — three dialects (Werkkzeug4, cables.gl, tixl) |
| [node-graph-architecture.md](./node-graph-architecture.md) | Node representation, execution models, type systems, caching |
| [node-graph-editor-ux.md](./node-graph-editor-ux.md) | Canvas rendering, connections, operator search, undo/redo |
| [node-graph-rendering.md](./node-graph-rendering.md) | GPU pipelines, resource management, frame timing |
| [list-handling-patterns.md](./list-handling-patterns.md) | How systems handle lists, spreading, iteration |

## Key Systems Studied

- **Werkkzeug4** (2004-2011) — Demoscene, compile-then-execute
- **cables.gl** (2015-present) — Web, trigger + value dual execution
- **tixl** (2020-present) — Desktop, pull-based lazy evaluation
- **vvvv gamma / VL** — Explicit iteration, spreads

## Related Per-Framework Notes

- `notes/per-framework/cables/` — cables.gl deep dive
- `notes/per-framework/tixl/` — tixl deep dive (51 documents)
- `notes/per-demoscene/fr_public/werkkzeug4/` — Werkkzeug4 analysis
- `references/the-gray-book/` — vvvv gamma documentation
