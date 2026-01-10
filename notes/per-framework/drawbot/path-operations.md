# DrawBot Path Operations

> BezierPath as a universal vector container with [FontTools](https://github.com/fonttools/fonttools) pen protocol and boolean operations.

## Key Insight

> **Path Operations' core idea:** BezierPath extends [FontTools](https://github.com/fonttools/fonttools)' `BasePen`, enabling seamless glyph extraction from fonts and interoperability with the entire [fontTools](https://github.com/fonttools/fonttools) ecosystem. Boolean operations via `booleanOperations` library use Python operator overloads for expressive path combining.

## Pen Protocol Integration

BezierPath implements the [FontTools](https://github.com/fonttools/fonttools) pen protocol, making it a target for glyph outline extraction:

```python
# frameworks/drawbot/drawBot/context/baseContext.py:147
class BezierPath(BasePen, SVGContextPropertyMixin, ContextPropertyMixin):
    """Return a BezierPath object."""

    def __init__(self, path=None, glyphSet=None):
        if path is None:
            self._path = AppKit.NSBezierPath.alloc().init()
        else:
            self._path = path
        BasePen.__init__(self, glyphSet)
```

The class implements both segment pen (`moveTo`, `lineTo`, `curveTo`) and point pen (`beginPath`, `addPoint`, `endPath`) protocols:

```python
def beginPath(self, identifier=None):
    """Begin using the path as a point pen and start a new subpath."""
    from fontTools.pens.pointPen import PointToSegmentPen
    self._pointToSegmentPen = PointToSegmentPen(self)
    self._pointToSegmentPen.beginPath()

def addPoint(self, point, segmentType=None, smooth=False, name=None, ...):
    """Add a point to the current subpath."""
    self._pointToSegmentPen.addPoint(point, segmentType=segmentType, ...)
```

## Boolean Operations

DrawBot provides four boolean operations via the `booleanOperations` library, each with method and operator syntax:

| Operation    | Method           | Operator | In-place |
|-------------|------------------|----------|----------|
| Union       | `union()`        | `\|`      | `\|=`     |
| Intersection| `intersection()` | `&`      | `&=`     |
| Difference  | `difference()`   | `%`      | `%=`     |
| XOR         | `xor()`          | `^`      | `^=`     |

```python
# frameworks/drawbot/drawBot/context/baseContext.py:717-778
def union(self, other):
    """Return the union between two bezier paths."""
    import booleanOperations
    contours = self._contoursForBooleanOperations() + other._contoursForBooleanOperations()
    result = self.__class__()
    booleanOperations.union(contours, result)
    return result

def __or__(self, other):
    return self.union(other)

def __ior__(self, other):
    result = self.union(other)
    self.setNSBezierPath(result.getNSBezierPath())
    return self
```

Usage example:
```python
circle = BezierPath()
circle.oval(0, 0, 100, 100)
square = BezierPath()
square.rect(50, 50, 100, 100)

combined = circle | square     # union
overlap = circle & square      # intersection
cutout = square % circle       # difference
exclusive = circle ^ square    # xor
```

## Path Manipulation

### Stroke Expansion

Convert strokes to filled outlines using Core Graphics:

```python
# baseContext.py:794-817
def expandStroke(self, width, lineCap="round", lineJoin="round", miterLimit=10):
    """Returns a new bezier path with an expanded stroke around the original."""
    strokedCGPath = Quartz.CGPathCreateCopyByStrokingPath(
        self._getCGPath(), None, width,
        _LINECAPSTYLESMAP[lineCap], _LINEJOINSTYLESMAP[lineJoin], miterLimit
    )
    result = self.__class__()
    result._setCGPath(strokedCGPath)
    return result
```

### Dashed Strokes and Reversal

```python
def dashStroke(self, *dash, offset=0):
    """Return a new bezier path with a dashed stroke."""
    dashedCGPath = Quartz.CGPathCreateCopyByDashingPath(self._getCGPath(), None, offset, dash, len(dash))
    ...

def reverse(self):
    """Reverse the path direction."""
    self._path = self._path.bezierPathByReversingPath()

def removeOverlap(self):
    """Remove all overlaps in a bezier path (in-place union with self)."""
    contours = self._contoursForBooleanOperations()
    booleanOperations.union(contours, result)
    self.setNSBezierPath(result.getNSBezierPath())
```

## Text to Outlines

The `text()` method converts text to vector paths via CoreText glyph extraction:

```python
# baseContext.py:414-449
def text(self, txt, offset=None, font=_FALLBACKFONT, fontSize=10, align=None):
    """Draws text as vector outlines in the bezier path."""
    context = BaseContext()
    context.font(font, fontSize, fontNumber)
    attributedString = context.attributedString(txt, align)
    # Internally calls textBox which extracts glyphs via CoreText
```

The actual glyph extraction happens in `textBox()` using CoreText APIs to iterate runs and append glyph paths.

## Image Tracing

The `traceImage()` method converts raster images to vector paths using [potrace](https://potrace.sourceforge.net/)/[mkbitmap](https://potrace.sourceforge.net/):

```python
# frameworks/drawbot/drawBot/context/tools/traceImage.py:275-326
def TraceImage(path, outPen, threshold=0.2, blur=None, invert=False, turd=2, tolerance=0.2, offset=None):
    potrace = getExternalToolPath(os.path.dirname(__file__), "potrace")
    mkbitmap = getExternalToolPath(os.path.dirname(__file__), "mkbitmap")

    # 1. Save image as bitmap
    saveImageAsBitmap(image, imagePath)

    # 2. Convert to PGM with mkbitmap (threshold, blur, invert)
    cmds = [mkbitmap, "-x", "-t", str(threshold)]
    executeExternalProcess(cmds)

    # 3. Trace with potrace to SVG
    cmds = [potrace, "-s", "-t", str(turd), "-O", str(tolerance)]
    executeExternalProcess(cmds)

    # 4. Parse SVG and draw to output pen
    importSVGWithPen(svgPath, outPen, (x, y, w, h), offset)
```

## Contour Access

BezierPath provides iteration over contours and point access:

```python
# baseContext.py:909-926
def _get_contours(self):
    contours = []
    for index in range(self._path.elementCount()):
        instruction, pts = self._path.elementAtIndex_associatedPoints_(index)
        if instruction == AppKit.NSMoveToBezierPathElement:
            contours.append(self.contourClass())
        if instruction == AppKit.NSClosePathBezierPathElement:
            contours[-1].open = False
        if pts:
            contours[-1].append([(p.x, p.y) for p in pts])
    return tuple(contours)
```

BezierContour (baseContext.py:89) provides `clockwise`, `points`, and drawing methods:

```python
class BezierContour(list):
    def _get_clockwise(self):
        from fontTools.pens.areaPen import AreaPen
        pen = AreaPen()
        self.drawToPen(pen)
        return pen.value < 0
```

## Recommendations for Your Framework

1. **Implement pen protocols** - [FontTools](https://github.com/fonttools/fonttools)' pen protocol is a proven abstraction for path interchange. Consider a similar trait-based approach in Rust.

2. **Operator overloads for booleans** - Python's `|`, `&`, `%`, `^` mapping to path operations is intuitive. Rust's `BitOr`, `BitAnd`, `Rem`, `BitXor` traits enable the same pattern.

3. **Separate stroke expansion** - Converting strokes to fills is a distinct operation from drawing. Keep these as explicit path transformations.

4. **External tool integration** - [Potrace](https://[potrace](https://potrace.sourceforge.net/).sourceforge.net/) for image tracing is battle-tested. Consider optional feature flags for external tool dependencies.

5. **Contour-level access** - Exposing contours as iterables enables algorithms that need per-contour operations (winding direction, area calculation).
