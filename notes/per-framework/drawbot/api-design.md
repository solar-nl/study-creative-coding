# DrawBot API Design

> Python-based creative coding with flat functions, context managers, and composable rich text.

## Key Insight

> **API Design's core idea:** DrawBot achieves script-friendly ergonomics through a flat function namespace (no object instantiation needed), context managers for resource cleanup (`with savedState():`), and FormattedString for composable rich text with chainable methods.

## Flat Function Namespace

All drawing functions are module-level. Scripts read like imperative instructions without any object setup.

```python
# No setup required - just call functions directly
from drawBot import *

newPage("A4")
fill(1, 0, 0)
rect(100, 100, 200, 150)
oval(300, 300, 100, 100)
text("Hello", (100, 500))
saveImage("~/Desktop/output.pdf")
```

The magic happens in [`__init__.py`](https://github.com/robotools/drawbot/blob/master/drawBot/__init__.py) via namespace injection:

```python
# drawBot/__init__.py
from .drawBotDrawingTools import _drawBotDrawingTool

_drawBotDrawingTool._addToNamespace(globals())
```

## Namespace Injection Pattern

The `_addToNamespace()` method injects DrawBot functions plus math and random utilities into the script namespace:

```python
# drawBotDrawingTools.py, lines 105-113
def _addToNamespace(self, namespace):
    namespace.update(_getmodulecontents(self, self.__all__))
    namespace.update(_getmodulecontents(random, ["random", "randint", "choice", "shuffle"]))
    namespace.update(_getmodulecontents(math))
    namespace.update(_getmodulecontents(drawBotbuiltins))
    namespace["FormattedString"] = FormattedString
    namespace["BezierPath"] = BezierPath
    namespace["ImageObject"] = ImageObject
```

This gives scripts access to `sin()`, `cos()`, `random()`, `choice()` without explicit imports.

## Context Manager Pattern

DrawBot uses Python's `with` statement for resource management and state isolation.

### Drawing Context

```python
# drawBotDrawingTools.py, lines 193-218
@contextmanager
def drawing(self):
    """Reset and clean the drawing stack in a `with` statement."""
    self.newDrawing()
    try:
        yield
    finally:
        self.endDrawing()
        self.newDrawing()
```

### Saved State Context

```python
# drawBotDrawingTools.py, lines 539-565
@contextmanager
def savedState(self):
    """Save and restore the current graphics state in a `with` statement."""
    self.save()
    try:
        yield
    finally:
        self.restore()
```

Usage in scripts:

```python
with savedState():
    fill(1, 0, 0)
    translate(450, 50)
    rotate(45)
    rect(0, 0, 100, 100)
# State automatically restored here
rect(0, 0, 50, 50)  # Black, unrotated
```

## Named Paper Sizes

The `_paperSizes` dictionary provides named constants for common page dimensions:

```python
# drawBotDrawingTools.py, lines 58-82
_paperSizes = {
    "Letter": (612, 792),
    "Tabloid": (792, 1224),
    "Legal": (612, 1008),
    "A0": (2384, 3371),
    "A3": (842, 1190),
    "A4": (595, 842),
    "A5": (420, 595),
    # ...
}

# Automatic landscape variants
for key, (w, h) in list(_paperSizes.items()):
    _paperSizes["%sLandscape" % key] = (h, w)
```

Usage: `newPage("A4")`, `newPage("LetterLandscape")`, `size("screen")`

## FormattedString Builder

FormattedString enables composable rich text with chainable methods and operator overloading.

```python
txt = FormattedString()
txt.font("Helvetica-Bold")
txt.fontSize(24)
txt.fill(1, 0, 0)
txt += "Hello "

txt.font("Times-Italic")
txt.fill(0, 0, 1)
txt += "World"

text(txt, (100, 100))
```

Key features from [`baseContext.py`](https://github.com/robotools/drawbot/blob/master/context/baseContext.py):
- **Chainable setters**: `.font()`, `.fontSize()`, `.fill()`, `.tracking()`, `.lineHeight()`
- **Concatenation**: `txt += "more text"` or `txt1 + txt2`
- **Slicing**: `txt[5:10]` returns a new FormattedString with formatting preserved
- **Inline formatting**: `txt.append("text", font="Helvetica", fontSize=20, fill=(1, 0, 0))`

## Dual Interface Pattern

The same drawing methods work on both the global namespace and object instances like BezierPath:

```python
# Global functions
rect(0, 0, 100, 100)
oval(50, 50, 30, 30)

# Same methods on BezierPath
path = BezierPath()
path.rect(0, 0, 100, 100)
path.oval(50, 50, 30, 30)
drawPath(path)
```

BezierPath also supports operator overloading for boolean operations:

```python
path1 | path2   # union
path1 & path2   # intersection
path1 % path2   # difference
path1 ^ path2   # xor
```

## Recommendations for Your Framework

1. **Flat namespace option** - Provide a prelude that imports common functions for scripting ergonomics
2. **Context managers** - Use Rust's `Drop` trait or explicit scope guards for state save/restore
3. **Named constants** - Provide paper sizes, common colors, and blend modes as named constants
4. **Rich text builder** - Support chainable methods that return `&mut Self` for text styling
5. **Operator overloading** - Implement `Add`, `BitOr`, `BitAnd` for path operations
6. **Dual interface** - Allow both `draw.rect()` and `path.rect()` with consistent signatures
