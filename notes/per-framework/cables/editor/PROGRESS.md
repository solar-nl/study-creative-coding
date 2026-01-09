# Editor Documentation Progress

> *Track documentation status for all cables.gl Editor subsystems*

Last updated: 2026-01-09

---

## Overview

| Metric | Count |
|--------|-------|
| Total subsystems | 3 |
| Completed | 3 |
| In progress | 0 |
| Not started | 0 |
| **Progress** | **100%** |

---

## Subsystem Status

### Priority 1: Node Picking & Patching

| # | Subsystem | LOC | Chapters | Status | Location |
|---|-----------|-----|----------|--------|----------|
| 1 | **OpSelect** | ~1200 | 2/2 | ✅ Complete | [opselect/](opselect/) |
| 2 | **GlPatch** | ~2500 | 1/2 | ✅ Complete | [glpatch/](glpatch/) |
| 3 | **Connections** | ~1500 | 1/2 | ✅ Complete | [connections/](connections/) |

---

## Detailed Chapter Planning

### OpSelect (Operator Browser)

| Chapter | Title | Status | Score |
|---------|-------|--------|-------|
| 01 | [The Operator Browser Dialog](opselect/01-operator-browser.md) | ✅ | 4.86/5 |
| 02 | [Search & Scoring Algorithm](opselect/02-search-scoring.md) | ✅ | 4.86/5 |

**Key Files:**
- `src/ui/dialogs/opselect.js` (~860 LOC)
- `src/ui/components/opsearch.js` (~600 LOC)
- `src/ui/components/opselect_treelist.js` (~200 LOC)

### GlPatch (Canvas Rendering)

| Chapter | Title | Status | Score |
|---------|-------|--------|-------|
| 01 | [The Patch Canvas Architecture](glpatch/01-patch-canvas.md) | ✅ | 4.86/5 |
| 02 | Operators & Rendering | ⬚ Planned | - |

**Key Files:**
- `src/ui/glpatch/glpatch.js` (~2077 LOC)
- `src/ui/glpatch/glop.js` (~400 LOC)
- `src/ui/glpatch/glviewbox.js` (~400 LOC)
- `src/ui/gldraw/glrectinstancer.js` (~700 LOC)

### Connections (Cables & Ports)

| Chapter | Title | Status | Score |
|---------|-------|--------|-------|
| 01 | [Ports & Visual Connections](connections/01-ports-connections.md) | ✅ | 4.43/5 |
| 02 | Cables & Bezier Rendering | ⬚ Planned | - |

**Key Files:**
- `src/ui/glpatch/glport.js` (~490 LOC)
- `src/ui/glpatch/gllink.js` (~785 LOC)
- `src/ui/glpatch/glcable.js` (~400 LOC)
- `src/ui/glpatch/gldragline.js` (~150 LOC)

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Complete |
| 🔄 | In progress |
| ⬚ | Not started |
| 🔶 | Needs review |

---

## Quick Stats by Area

```
src/ui/
├── dialogs/             ~4,000 LOC   (OpSelect lives here)
├── glpatch/            ~10,000 LOC   (Canvas rendering)
├── gldraw/              ~3,000 LOC   (Low-level GL primitives)
├── components/         ~15,000 LOC   (UI components, search)
└── commands/            ~2,000 LOC   (Command system)
```

---

## Architecture Comparison with tixl

| Aspect | cables.gl | tixl |
|--------|-----------|------|
| **Rendering** | WebGL 2.0 + GPU instancing | DirectX 11 + ImGui |
| **UI Framework** | Custom WebGL + DOM | Dear ImGui |
| **Search** | Word-based, popularity | Regex fuzzy, relevancy |
| **Platform** | Web (browser) | Desktop (.NET/Windows) |
| **Language** | JavaScript (ES6+) | C# |

---

## Notes

### Current Focus: OpSelect
- Modal dialog for operator selection
- Search engine with word matching and scoring
- Context-aware suggestions (port type filtering)
- Namespace tree browser

### Rendering Architecture
- GlRectInstancer for batched rendering
- GlSplineDrawer for bezier cable curves
- GlTextWriter for text rendering
- All WebGL 2.0 based
