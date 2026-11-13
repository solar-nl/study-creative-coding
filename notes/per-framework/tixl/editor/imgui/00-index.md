# ImGui Craft in tixl

> **What a 134,000-line Dear ImGui editor learned the hard way**
>
> *The patterns tixl uses on top of raw ImGui, checked against its own written rules, and translated to Rust and dear-imgui-rs*

**Part of:** [Editor Documentation](../00-architecture.md) | [Progress Tracker](../PROGRESS.md)

---

## Why This Chapter Set Exists

Dear ImGui makes the first window easy and the hundredth window hard. Out of the box it gives you widgets that redraw every frame and report "I was clicked" or "I am being dragged". It says nothing about how a slider drag becomes one undo step, which window owns the Delete key while a text field has focus, how a zoomable canvas is shared by five different editors, or where selection lives when the UI has no retained tree.

tixl's editor answers all of those, at scale: about 134k lines in `Editor/Gui` on ImGui.NET 1.91. It also writes its UI rules down for contributors and coding agents (`visual-programming/tixl/.agentic/AGENT_INSTRUCTIONS.md`, "UI Implementation Guidelines"). That combination makes it an unusually good teacher: every chapter here compares **the stated rule** with **what the code actually does**, because the two do not always agree.

The existing editor notes already cover tixl's node graph in depth ([MagGraph](../maggraph/00-index.md), 20 chapters) and its output views ([OutputUi](../outputui/)). This set does not repeat them. It covers the ImGui craft underneath: the conventions that apply to every window, not just the graph.

**Who should read this:** anyone building a tool-style application on Dear ImGui, especially in Rust with dear-imgui-rs. Each chapter ends with a translation section that maps tixl's C# patterns to Rust idioms, with ImGui calls checked against dear-imgui-rs 0.8.

---

## Chapters

### Part 1: Editing Without Losing Work

| # | Chapter | The question it answers |
|---|---------|-------------------------|
| 01 | [Edit Lifecycle and Undo](01-edit-lifecycle-and-undo.md) | A slider changes a value 60 times a second. How does that become exactly one undo entry, and what happens on Escape? |
| 02 | [Input Routing and Focus](02-input-routing-and-focus.md) | Who gets the keystroke when a canvas shortcut and a text field both want it? Who gets the mouse when an overlay sits on a canvas? |

### Part 2: Canvases and State

| # | Chapter | The question it answers |
|---|---------|-------------------------|
| 03 | [The Zoomable Canvas](03-zoomable-canvas.md) | How do a node graph, a timeline and a curve editor share one zoom/pan component, and how do lines stay crisp at any zoom? |
| 04 | [Retained State Beside Immediate Mode](04-retained-state.md) | ImGui forgets everything each frame. Where do selection, navigation and in-flight interactions live, and how do they avoid going stale? |

### Part 3: Building Blocks

| # | Chapter | The question it answers |
|---|---------|-------------------------|
| 05 | [ID Stack and Widget Identity](05-id-stack-and-widget-identity.md) | 192 `PushID` sites and no written rule: what makes a widget the same widget next frame, and what breaks it? |
| 06 | [Theming and the Widget Library](06-theming-and-widget-library.md) | How do semantic colors, themes, fonts and house widgets stay consistent when push/pop is left to convention? |
| 07 | [Popups, Menus and Drag-and-Drop](07-popups-menus-and-drag-drop.md) | How do dialogs, context menus, overlays, drops and hover help float above the layout without fighting it? |

### Part 4: The Application Shell

| # | Chapter | The question it answers |
|---|---------|-------------------------|
| 08 | [Frame Loop, Fonts and DPI](08-frame-loop-fonts-and-dpi.md) | In what order does a frame happen, and how do the font atlas and DPI scaling survive a monitor change? |
| 09 | [Windows, Docking and Layouts](09-windows-docking-and-layouts.md) | How do seventeen window types, named layouts and per-project layouts share one docking space? |
| 10 | [Per-Frame Performance](10-per-frame-performance.md) | What keeps a 134k-line UI at frame rate, and which rules hold in practice? |

### Part 5: Conventions

| # | Chapter | The question it answers |
|---|---------|-------------------------|
| 11 | [Stated Rules vs. Code](11-stated-rules-vs-code.md) | tixl writes its UI rules down for contributors and agents. Which ones hold, which drift, and how should conventions be written so they don't? |

For the condensed version, see the insight note [ImGui Editor Patterns](../../../../../insights/imgui-editor-patterns.md).

---|---------|-------|
| 05 | ID stack and widget identity | 192 `PushID` sites and no written convention; the per-window ID sanity check |
| 06 | Theming and scoped styling | `UiColors`, `CustomComponents`, `IDisposable` style scopes vs RAII tokens |
| 07 | Popups, modals, menus, drag and drop | `ModalDialog`, context-menu helpers, custom graph drops, help targets |
| 08 | Frame loop, fonts and DPI | Backend integration, font atlas rebuilds, `UiScaleFactor` |
| 09 | Windows, docking and layouts | `Window` base class, `WindowManager`, in-memory ini layouts |
| 10 | Per-frame performance discipline | The no-allocation rule in practice, frame stats, stall watchdog |
| 11 | Stated rules vs. code | A full audit of the UI section of `AGENT_INSTRUCTIONS.md` |

---

## Recurring Findings So Far

Across the eleven chapters, a few themes repeat:

- **One translator per concern.** Edits go through one function (`ParameterWindow.HandleInputEditState`), shortcuts through one guard (`KeyBinding.IsContextValid`), canvases through one transform (`ScalableCanvas`). Where tixl has a single choke point, behavior is consistent; where code bypasses it, bugs collect.
- **Store ids, resolve each frame.** Selection, commands and view state hold Guids or id paths, not object references, and look them up when used. The places that still hold references are where the stale-state comments are.
- **Statics are the main debt.** The in-flight edit command, the focused project view, the dragged canvas and the UI scale factor are all static. Each works for one project in one window and needs care beyond that. In Rust these become explicit state passed by `&mut`.
- **The rules lag the code, and vice versa.** The written instructions name a command as a latent bug that has already been fixed, while other rules (undo commands must not throw) are not yet followed. Treat written rules as intent and verify against source.

## Conventions

Paths are relative to `visual-programming/tixl/` at the commit recorded in [SUBMODULE-PINS.md](../../../../SUBMODULE-PINS.md). Claims inferred from reading code rather than running it are labeled as such in each chapter.
