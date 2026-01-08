# Editor Documentation Progress

> *Track documentation status for all Editor subsystems*

Last updated: 2026-01-01

---

## Overview

| Metric | Count |
|--------|-------|
| Total subsystems | 10 |
| Completed | 2 |
| In progress | 0 |
| Not started | 8 |
| **Progress** | **20%** |

---

## Subsystem Status

### Priority 1: Core Editing

| # | Subsystem | LOC | Chapters | Status | Location |
|---|-----------|-----|----------|--------|----------|
| 1 | **MagGraph** | ~11K | 20 + 3 appendices | ✅ Complete | [docs/maggraph/](../maggraph/) |
| 2 | **Timeline/Dopesheet** | ~6K | 0/8 | ⬚ Not started | *docs/timeline/* |
| 3 | **Graph (legacy)** | ~10K | 0/6 | ⬚ Not started | *docs/graph/* |

### Priority 2: Infrastructure

| # | Subsystem | LOC | Chapters | Status | Location |
|---|-----------|-----|----------|--------|----------|
| 4 | **UiModel/Commands** | ~4K | 0/5 | ⬚ Not started | *docs/commands/* |
| 5 | **Interaction System** | ~13K | 0/8 | ⬚ Not started | *docs/interaction/* |
| 6 | **Window System** | ~14K | 0/4 | ⬚ Not started | *docs/windows/* |

### Priority 3: Specialized

| # | Subsystem | LOC | Chapters | Status | Location |
|---|-----------|-----|----------|--------|----------|
| 7 | **OutputUi** | ~2.5K | 8/8 | ✅ Complete | [outputui/](outputui/) |
| 8 | **Styling/Theming** | ~2K | 0/3 | ⬚ Not started | *styling/* |

### Priority 4: Supporting

| # | Subsystem | LOC | Chapters | Status | Location |
|---|-----------|-----|----------|--------|----------|
| 9 | **App Bootstrap** | ~1K | 0/2 | ⬚ Not started | *docs/app/* |
| 10 | **Compilation** | ~2K | 0/3 | ⬚ Not started | *docs/compilation/* |

---

## Detailed Chapter Planning

### Timeline/Dopesheet (Priority 2)

| Chapter | Title | Status |
|---------|-------|--------|
| 01 | Architecture Overview | ⬚ |
| 02 | TimeLineCanvas & Core | ⬚ |
| 03 | DopeSheetArea | ⬚ |
| 04 | Curve Editing | ⬚ |
| 05 | Time Raster System | ⬚ |
| 06 | TimeClips & Layers | ⬚ |
| 07 | Playback & Controls | ⬚ |
| 08 | Animation Commands | ⬚ |

### Graph Legacy (Priority 3)

| Chapter | Title | Status |
|---------|-------|--------|
| 01 | Architecture Overview | ⬚ |
| 02 | GraphView & Canvas | ⬚ |
| 03 | GraphNode Rendering | ⬚ |
| 04 | Connection System | ⬚ |
| 05 | Interaction Handling | ⬚ |
| 06 | Graph Dialogs | ⬚ |

### UiModel/Commands (Priority 4)

| Chapter | Title | Status |
|---------|-------|--------|
| 01 | Command Pattern Overview | ⬚ |
| 02 | UndoRedoStack | ⬚ |
| 03 | Graph Commands | ⬚ |
| 04 | Animation Commands | ⬚ |
| 05 | MacroCommand Pattern | ⬚ |

### Interaction System (Priority 5)

| Chapter | Title | Status |
|---------|-------|--------|
| 01 | Architecture Overview | ⬚ |
| 02 | ScalableCanvas Base | ⬚ |
| 03 | Keyboard/Hotkeys | ⬚ |
| 04 | MIDI Integration | ⬚ |
| 05 | Camera Controls | ⬚ |
| 06 | Snapping System | ⬚ |
| 07 | Transform Gizmos | ⬚ |
| 08 | Variations/Snapshots | ⬚ |

---

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Complete |
| 🔄 | In progress |
| ⬚ | Not started |
| 🔶 | Needs review |

---

## Notes

### MagGraph (Completed)
- 20 chapters covering Model, States, Interaction, Rendering
- 3 appendices: File Reference, ImGui Patterns, Legacy Comparison
- Follows O'Reilly-style technical documentation

### Next Recommended: Timeline
- Similar patterns to MagGraph (ScalableCanvas, state machine)
- Relatively self-contained subsystem
- ~6K LOC, manageable scope

### Dependencies
- **Commands** should be documented before Graph/Timeline deep-dives (shared pattern)
- **Interaction** is foundational but large - consider doing after core editors

---

## Quick Stats by Area

```
Gui/                    ~77,000 LOC   (80% of editor)
├── MagGraph/            11,000 LOC   ✅ Documented
├── Graph/               10,000 LOC   ⬚ Pending
├── TimeLine/             6,000 LOC   ⬚ Pending
├── Interaction/         13,000 LOC   ⬚ Pending
├── Windows/ (other)     14,000 LOC   ⬚ Pending
├── UiHelpers/            5,000 LOC   ⬚ Pending
├── OutputUi/InputUi/     5,000 LOC   ⬚ Pending
└── Styling/              2,000 LOC   ⬚ Pending

UiModel/                ~11,000 LOC   (12% of editor)
├── Commands/             2,000 LOC   ⬚ Pending
├── SymbolUi/             4,000 LOC   ⬚ Pending
└── Other/                5,000 LOC   ⬚ Pending

Other/                   ~7,000 LOC   (8% of editor)
├── App/                  1,200 LOC   ⬚ Pending
├── Compilation/          1,700 LOC   ⬚ Pending
├── Skills/               2,400 LOC   ⬚ Pending
└── UiContentDrawing/       900 LOC   ⬚ Pending
```

