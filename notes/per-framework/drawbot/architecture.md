# DrawBot Architecture

> Understanding DrawBot's deferred rendering model and context abstraction.

## Key Insight

> **Architecture's core idea:** DrawBot queues all drawing operations as instruction tuples in a stack, then replays them against any output context at export time. This separation enables format-independent rendering where the same code produces PDF, PNG, SVG, or video.

## Instruction Stack Pattern

The heart of DrawBot is `_instructionsStack` — a list of per-page instruction lists. Each instruction is a `(callback, args, kwargs)` tuple:

```python
# From drawBotDrawingTools.py (lines 114-131)
def _addInstruction(self, callback, *args, **kwargs):
    if callback == "newPage":
        self._instructionsStack.append([])
    if not self._instructionsStack:
        self._instructionsStack.append([])
    if self._requiresNewFirstPage and not self._hasPage:
        self._hasPage = True
        self._instructionsStack[-1].insert(0, ("newPage", [self.width(), self.height()], {}))
    self._instructionsStack[-1].append((callback, args, kwargs))

def _drawInContext(self, context):
    if not self._instructionsStack:
        return
    for instructionSet in self._instructionsStack:
        for callback, args, kwargs in instructionSet:
            attr = getattr(context, callback)
            attr(*args, **kwargs)
```

This design means `rect(10, 10, 100, 100)` does not draw immediately — it records `("rect", (10, 10, 100, 100), {})`. Only when `saveImage("output.pdf")` is called does `_drawInContext()` replay all instructions against a `PDFContext`.

## Context Hierarchy

```
BaseContext (baseContext.py)
    |
    +-- PDFContext (Quartz/CoreGraphics)
    |       |
    |       +-- ImageContext
    |               |
    |               +-- PNGContext
    |               +-- JPEGContext
    |               +-- TIFFContext
    |               +-- GIFContext (gifsicle post-processing)
    |               +-- MP4Context (ffmpeg post-processing)
    |
    +-- SVGContext (XML string generation)
    |
    +-- DummyContext (immediate queries, no output)
```

All contexts share the same drawing API. The file extension determines which context processes the instruction stack.

## DummyContext for Immediate Queries

DrawBot needs to answer questions like `textSize("Hello")` during drawing — before any export context exists. `DummyContext` inherits all `BaseContext` methods but produces no output:

```python
# dummyContext.py
class DummyContext(BaseContext):
    pass
```

This allows text measurement, path bounds, and other queries to work immediately while the instruction stack continues recording.

## Graphics State Stack

The `GraphicsState` class tracks all rendering attributes:

```python
# From baseContext.py (lines 2272-2294)
class GraphicsState:
    def __init__(self):
        self.fillColor = self._colorClass(0)
        self.strokeColor = None
        self.strokeWidth = 1
        self.opacity = 1
        self.blendMode = None
        self.lineDash = None
        self.lineCap = None
        self.lineJoin = None
        # ... text, shadow, gradient, path
```

Contexts maintain a state stack via `save()` and `restore()`:

```python
def save(self):
    self._stack.append(self._state.copy())
    self._save()

def restore(self):
    if not self._stack:
        raise DrawBotError("can't restore: no matching save()")
    self._state = self._stack.pop()
    self._state.update(self)
    self._restore()
```

## Key Files to Read

| Concept | File | Purpose |
|---------|------|---------|
| Instruction stack | `drawBot/drawBotDrawingTools.py` | `_addInstruction`, `_drawInContext` |
| Base context API | `drawBot/context/baseContext.py` | `GraphicsState`, `BaseContext` |
| Context registry | `drawBot/context/__init__.py` | `allContexts`, `getContextForFileExt()` |
| PDF rendering | `drawBot/context/pdfContext.py` | Quartz/CoreGraphics backend |
| SVG rendering | `drawBot/context/svgContext.py` | XML string generation |
| Immediate queries | `drawBot/context/dummyContext.py` | No-op context for measurements |

## Recommendations for Your Framework

1. **Deferred rendering** — Consider recording draw calls as a command buffer. This enables:
   - Format-independent export (same code produces PNG, SVG, PDF)
   - Serialization/replay of drawings
   - Easy undo/redo by manipulating the command list

2. **Context trait** — Define a `RenderContext` trait that all backends implement. The instruction replayer calls trait methods without knowing the concrete type.

3. **Query context** — Provide a lightweight context for measurements (text bounds, path areas) that does not require a full render target.

4. **State stack** — Implement `save()`/`restore()` as first-class operations. Consider making `GraphicsState` a `#[derive(Clone)]` struct for efficient stack copies.
