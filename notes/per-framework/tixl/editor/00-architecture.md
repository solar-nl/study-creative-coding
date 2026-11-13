# Tooll3 Editor Architecture

> *Master reference for the Tooll3 Editor codebase*

## Key Insight

> **Editor architecture's core idea:** An ImGui-based UI where all state modifications flow through Command objects for undo/redo, with specialized subsystems (MagGraph, Timeline, Parameters) sharing a common Window base class and ScalableCanvas infrastructure.

---

## Overview

The Tooll3 Editor is an ImGui-based visual programming environment for real-time graphics. It provides a node-graph editor, timeline/animation system, parameter controls, and output visualization.

**Total Size:** ~95,000 LOC across 486 C# files

```
Editor/
├── Gui/                    380 files   ~77,000 LOC   Visual & interaction
├── UiModel/                 69 files   ~11,000 LOC   State & commands
├── Compilation/              7 files    ~1,700 LOC   Symbol compilation
├── App/                      6 files    ~1,200 LOC   Application bootstrap
├── Skills/                  19 files    ~2,400 LOC   Tutorial system
└── UiContentDrawing/        16 files      ~900 LOC   Specialized rendering
```

---

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Program.cs                                      │
│                            (Entry Point)                                     │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────────────────┐
│                         App/AppWindow.cs                                     │
│                    (Window & DirectX Setup)                                  │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────────────────┐
│                           Gui/T3UI.cs                                        │
│                      (Main UI Orchestrator)                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │  Interaction │  │    Graph     │  │   Windows    │  │   Styling    │    │
│  │   ~13K LOC   │  │   ~21K LOC   │  │   ~20K LOC   │  │   ~2K LOC    │    │
│  ├──────────────┤  ├──────────────┤  ├──────────────┤  ├──────────────┤    │
│  │ • Keyboard   │  │ • Graph/     │  │ • TimeLine/  │  │ • Themes     │    │
│  │ • MIDI       │  │   (legacy)   │  │ • Settings   │  │ • Colors     │    │
│  │ • Camera     │  │ • MagGraph/  │  │ • Parameters │  │ • Icons      │    │
│  │ • Snapping   │  │   (new)      │  │ • Output     │  │              │    │
│  │ • Gizmos     │  │              │  │ • Dialogs    │  │              │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘    │
│                                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                       │
│  │   OutputUi   │  │  UiHelpers   │  │   InputUi    │                       │
│  │   ~2.5K LOC  │  │   ~5K LOC    │  │   ~3K LOC    │                       │
│  ├──────────────┤  ├──────────────┤  ├──────────────┤                       │
│  │ Type-specific│  │ Reusable     │  │ Parameter    │                       │
│  │ output views │  │ components   │  │ input forms  │                       │
│  └──────────────┘  └──────────────┘  └──────────────┘                       │
│                                                                              │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────────────────┐
│                            UiModel/                                          │
│                    (State & Command Layer)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐    │
│  │   Commands   │  │  Selection   │  │ Modification │  │   SymbolUi   │    │
│  │   ~2K LOC    │  │   ~600 LOC   │  │   ~2K LOC    │  │   ~3K LOC    │    │
│  ├──────────────┤  ├──────────────┤  ├──────────────┤  ├──────────────┤    │
│  │ Undo/Redo    │  │ Node/param   │  │ Graph edits  │  │ UI wrappers  │    │
│  │ Graph cmds   │  │ selection    │  │ Validation   │  │ for Symbols  │    │
│  │ Anim cmds    │  │ management   │  │              │  │              │    │
│  └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘    │
│                                                                              │
└─────────────────────────────────┬───────────────────────────────────────────┘
                                  │
┌─────────────────────────────────▼───────────────────────────────────────────┐
│                         T3.Core / Operators                                  │
│                      (Simulation Engine - separate)                          │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Key Patterns

### 1. Command Pattern (Undo/Redo)
All state modifications go through `ICommand` implementations stored in `UndoRedoStack`.

```csharp
// Example: Adding a connection
var command = new AddConnectionCommand(symbol, connection, multiInputIndex);
UndoRedoStack.AddAndExecute(command);
```

### 2. MacroCommand Grouping
Multiple commands grouped for single undo step:

```csharp
context.MacroCommand.StartGroup("Move Items");
// ... multiple sub-commands ...
context.MacroCommand.CompleteGroup();
```

### 3. Window Base Class
All panels inherit from `Window` with consistent lifecycle:

```csharp
public class MyWindow : Window
{
    protected override void DrawContent() { ... }
}
```

### 4. ScalableCanvas
Shared zoom/pan infrastructure for graph and timeline:

```csharp
public class GraphCanvas : ScalableCanvas
{
    // Inherited: Scale, Scroll, TransformPosition(), InverseTransformPosition()
}
```

### 5. Factory Pattern for Type UIs
Type-specific renderers registered in factories:

```csharp
OutputUiFactory.Entries[typeof(Texture2D)] = typeof(Texture2dOutputUi);
```

---

## Subsystem Quick Reference

| Subsystem | Entry Point | Purpose |
|-----------|-------------|---------|
| App | `AppWindow.cs` | DirectX/ImGui bootstrap |
| Graph (legacy) | `GraphView.cs` | Original node editor |
| MagGraph | `MagGraphCanvas.cs` | New magnetic graph editor |
| TimeLine | `TimeLineCanvas.cs` | Dopesheet & curve editor |
| Parameters | `ParameterWindow.cs` | Parameter editing panel |
| Settings | `SettingsWindow.cs` | Global preferences |
| Interaction | `ScalableCanvas.cs` | Input handling base |
| Commands | `UndoRedoStack.cs` | Undo/redo management |
| Selection | `NodeSelection.cs` | Selection state |

---

## Documentation Status

### Completed Documentation

| Section | Location | Status |
|---------|----------|--------|
| MagGraph | [docs/maggraph/](../maggraph/) | ✅ Complete (20 chapters + 3 appendices) |
| ImGui craft | [imgui/](imgui/00-index.md) | ✅ Complete (11 chapters, each with a Rust/dear-imgui-rs translation) |

### Planned Documentation

| Priority | Section | Est. Chapters | Status |
|----------|---------|---------------|--------|
| 1 | **Timeline/Dopesheet** | 8-10 | ⬚ Not started |
| 2 | **Graph (legacy)** | 6-8 | ⬚ Not started |
| 3 | **UiModel/Commands** | 4-5 | ⬚ Not started |
| 4 | **Interaction System** | 6-8 | ⬚ Not started |
| 5 | **Window System** | 3-4 | ⬚ Not started |
| 6 | **OutputUi/InputUi** | 3-4 | ⬚ Not started |
| 7 | **Styling/Theming** | 2-3 | ⬚ Not started |
| 8 | **App Bootstrap** | 2 | ⬚ Not started |
| 9 | **Compilation** | 2-3 | ⬚ Not started |
| 10 | **Skills/Tutorials** | 2 | ⬚ Not started |

**Legend:** ✅ Complete | 🔄 In Progress | ⬚ Not started

---

## Next: Detailed Subsystem Maps

Each subsystem will get its own detailed documentation following the MagGraph pattern:
- Architecture overview
- Core concepts
- File-by-file breakdown
- Key classes and patterns
- Code examples

See individual subsystem directories:
- [Timeline Documentation](../timeline/) *(planned)*
- [Graph Documentation](../graph/) *(planned)*
- [Commands Documentation](../commands/) *(planned)*

---

## File Index

### Gui/ Directory (~77K LOC)

```
Gui/
├── Dialogs/                 18 files    ~4K LOC    Modal dialogs
├── Graph/                   30 files   ~10K LOC    Legacy graph editor
│   ├── Dialogs/             12 files               Graph-specific dialogs
│   ├── Interaction/          6 files               Graph interaction
│   └── Legacy/               4 files               Deprecated code
├── InputUi/                  7 files    ~3K LOC    Parameter input widgets
├── Interaction/             25 files   ~13K LOC    User input handling
│   ├── Camera/               5 files               3D camera control
│   ├── Keyboard/             3 files               Hotkey system
│   ├── Midi/                 8 files               MIDI device support
│   ├── Snapping/             3 files               Grid/object snapping
│   ├── TransformGizmos/      4 files               3D gizmos
│   ├── Variations/           4 files               Snapshot system
│   └── WithCurves/           6 files               Curve editing
├── MagGraph/                29 files   ~11K LOC    Magnetic graph editor
│   ├── Interaction/         17 files               Movement, browser, etc.
│   ├── Model/                4 files               Data structures
│   ├── States/               3 files               State machine
│   └── Ui/                   5 files               Rendering
├── OpUis/                    7 files    ~5K LOC    Operator-specific UIs
├── OutputUi/                24 files    ~2K LOC    Output type viewers
├── Styling/                 13 files    ~2K LOC    Theme & colors
├── Templates/                3 files               UI templates
├── UiHelpers/               34 files    ~5K LOC    Reusable utilities
└── Windows/                 80 files   ~20K LOC    UI panels
    ├── AssetLib/             5 files               Asset browser
    ├── Exploration/          4 files               Search tools
    ├── Hub/                  3 files               Project hub
    ├── Layouts/              4 files               Layout management
    ├── Output/              10 files               Output windows
    ├── RenderExport/         8 files               Export dialogs
    ├── SymbolLib/            6 files               Symbol library
    ├── TimeLine/            25 files    ~6K LOC    Timeline editor
    │   ├── Raster/           6 files               Time grid
    │   └── TimeClips/        5 files               Clip management
    └── Variations/           4 files               Variation UI
```

### UiModel/ Directory (~11K LOC)

```
UiModel/
├── Commands/                25 files    ~2K LOC    Command implementations
│   ├── Animation/            6 files               Keyframe commands
│   ├── Annotations/          2 files               Annotation commands
│   ├── Graph/               10 files               Graph commands
│   └── Variations/           3 files               Variation commands
├── Exporting/                4 files               Export logic
├── Helpers/                  6 files               Utility functions
├── InputsAndTypes/           7 files               Type wrappers
├── Modification/             8 files    ~2K LOC    Graph modification
├── ProjectHandling/          8 files               Project I/O
├── Selection/                1 file                Selection state
└── [Core files]             10 files    ~4K LOC    SymbolUi, Registry, etc.
```

---

## Cross-Cutting Concerns

### Threading
- Main thread: All UI rendering
- Background threads: Compilation, resource loading
- Thread-safe queues for cross-thread communication

### Performance
- Visibility culling in graph/timeline
- Lazy layout computation
- Cached view models (MagGraphLayout pattern)
- ImGui immediate-mode efficiency

### Persistence
- JSON for symbol UI metadata
- Project files (.t3 format)
- User settings in config files

---

## Getting Started

1. **Entry point:** `Program.cs` → `AppWindow.cs`
2. **Main loop:** `T3UI.Draw()` orchestrates all windows
3. **Graph editing:** Start with MagGraph docs or legacy Graph/
4. **Animation:** TimeLine/ subsystem
5. **Commands:** UiModel/Commands/ for undo/redo

