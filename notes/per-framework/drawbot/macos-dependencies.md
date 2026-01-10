# DrawBot - macOS Dependencies

> **Key Insight:** DrawBot is not merely "using" macOS APIs - it is built entirely on CoreText for text, Quartz for graphics, and AppKit for images. A cross-platform port requires replacing approximately 800+ platform-specific API calls spanning 3000+ lines of code.

## Framework Overview

| macOS Framework | Primary Use | API Call Count | Key Files |
|-----------------|-------------|----------------|-----------|
| **CoreText** | Text shaping, fonts, layout | ~100 calls | baseContext.py, svgContext.py, variation.py |
| **Quartz/CoreGraphics** | PDF creation, paths, rendering | ~150 calls | pdfContext.py, baseContext.py |
| **AppKit** | Images, colors, UI components | ~550 calls | imageContext.py, baseContext.py, misc.py |

## CoreText Dependencies (Critical for Typography)

CoreText is the foundation of all text rendering in DrawBot. Every text operation flows through CoreText APIs.

### Font Loading and Management

```python
# From variation.py - Getting font URL from descriptor
url = CoreText.CTFontDescriptorCopyAttribute(fontDescriptor, CoreText.kCTFontURLAttribute)
psFontName = CoreText.CTFontDescriptorCopyAttribute(fontDescriptor, CoreText.kCTFontNameAttribute)

# From variation.py - Variable font axes
variationAxesDescriptions = CoreText.CTFontCopyVariationAxes(font)
tag = convertIntToVariationTag(variationAxesDescription[CoreText.kCTFontVariationAxisIdentifierKey])
minValue = variationAxesDescription[CoreText.kCTFontVariationAxisMinimumValueKey]
```

### Text Layout Pipeline

```python
# From baseContext.py - Text framesetting
setter = newFramesetterWithAttributedString(attributedString)
frame = CoreText.CTFramesetterCreateFrame(setter, (0, 0), path, None)

# Line and run extraction
ctLines = CoreText.CTFrameGetLines(frame)
origins = CoreText.CTFrameGetLineOrigins(frame, (0, len(ctLines)), None)
ctRuns = CoreText.CTLineGetGlyphRuns(ctLine)
```

### Glyph Access and Drawing

```python
# From pdfContext.py - Drawing text runs
glyphCount = CoreText.CTRunGetGlyphCount(ctRun)
glyph = CoreText.CTRunGetGlyphs(ctRun, (i, 1), None)[0]
CoreText.CTRunDraw(ctRun, self._pdfContext, (0, 0))

# Run positioning
runPos = CoreText.CTRunGetPositions(ctRun, (0, 1), None)
```

### OpenType Features

```python
# From baseContext.py - Feature settings via font descriptor
fontAttributes[CoreText.kCTFontFeatureSettingsAttribute] = coreTextFontFeatures
fontAttributes[CoreText.NSFontVariationAttribute] = coreTextFontVariations
fontAttributes[CoreText.NSFontCascadeListAttribute] = [fallbackFontDescriptor]
```

## Quartz/CoreGraphics Dependencies (Critical for PDF)

Quartz provides all PDF creation, path operations, and low-level graphics context management.

### PDF Document Creation

```python
# From pdfContext.py - Creating PDF documents
self._pdfData = Quartz.CFDataCreateMutable(None, 0)
dataConsumer = Quartz.CGDataConsumerCreateWithCFData(self._pdfData)
self._pdfContext = Quartz.CGPDFContextCreate(dataConsumer, mediaBox, None)

# Page management
Quartz.CGContextBeginPage(self._pdfContext, mediaBox)
Quartz.CGContextEndPage(self._pdfContext)
Quartz.CGPDFContextClose(self._pdfContext)
```

### Path Operations

```python
# From baseContext.py - CGPath creation and manipulation
path = Quartz.CGPathCreateMutable()
Quartz.CGPathMoveToPoint(path, None, points[0].x, points[0].y)
Quartz.CGPathAddLineToPoint(path, None, points[0].x, points[0].y)
Quartz.CGPathAddCurveToPoint(path, None, ...)
Quartz.CGPathCloseSubpath(path)

# Path stroking (expandStroke)
strokedCGPath = Quartz.CGPathCreateCopyByStrokingPath(
    self._getCGPath(), None, width, lineCap, lineJoin, miterLimit
)
```

### Context State and Drawing

```python
# State management
Quartz.CGContextSaveGState(self._pdfContext)
Quartz.CGContextRestoreGState(self._pdfContext)
Quartz.CGContextSetAlpha(self._pdfContext, alpha)
Quartz.CGContextSetBlendMode(self._pdfContext, value)

# Drawing operations
Quartz.CGContextFillPath(self._pdfContext)
Quartz.CGContextStrokePath(self._pdfContext)
Quartz.CGContextClip(self._pdfContext)
```

### Color and Gradients

```python
# Color creation
Quartz.CGColorCreateGenericRGB(r, g, b, a)
Quartz.CGColorCreateGenericCMYK(c, m, y, k, a)
Quartz.CGColorCreateGenericGray(white, alpha)

# Gradient rendering
cgGradient = Quartz.CGGradientCreateWithColors(colorSpace, colors, positions)
Quartz.CGContextDrawLinearGradient(self._pdfContext, cgGradient, start, end, options)
Quartz.CGContextDrawRadialGradient(self._pdfContext, cgGradient, ...)
```

## AppKit Dependencies (Critical for Images)

AppKit provides all image handling, NSBezierPath operations, NSFont access, and color management.

### NSBezierPath (Foundation of BezierPath)

```python
# From baseContext.py - All path operations use NSBezierPath internally
self._path = AppKit.NSBezierPath.alloc().init()
self._path.moveToPoint_(pt)
self._path.lineToPoint_(pt)
self._path.curveToPoint_controlPoint1_controlPoint2_(pt3, pt1, pt2)
self._path.closePath()

# Path element inspection
instruction, points = self._path.elementAtIndex_associatedPoints_(i)
# Constants: NSMoveToBezierPathElement, NSLineToBezierPathElement, etc.
```

### NSFont and Font Management

```python
# Font creation
font = AppKit.NSFont.fontWithName_size_(fontName, fontSize)
font = AppKit.NSFont.fontWithDescriptor_size_(fontDescriptor, fontSize)

# Font descriptor operations
fontDescriptor = font.fontDescriptor()
fontDescriptor = fontDescriptor.fontDescriptorByAddingAttributes_(fontAttributes)
```

### Image Loading and Export

```python
# From imageContext.py - Bitmap creation
rep = AppKit.NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_...()
imageData = imageRep.representationUsingType_properties_(AppKit.NSPNGFileType, properties)

# Image loading
image = AppKit.NSImage.alloc().initByReferencingURL_(url)
data = image.TIFFRepresentation()
```

### Color System

```python
# From baseContext.py - Color creation
self._color = AppKit.NSColor.colorWithCalibratedRed_green_blue_alpha_(r, g, b, a)
self._color = AppKit.NSColor.colorWithDeviceCyan_magenta_yellow_black_alpha_(c, m, y, k, a)
self._color = self._color.colorUsingColorSpace_(colorSpace)

# Color spaces
colorSpace = AppKit.NSColorSpace.genericRGBColorSpace()
colorSpace = AppKit.NSColorSpace.genericCMYKColorSpace()
```

## Abstraction Analysis

### Fully Platform-Dependent Features

These features have no abstraction and are entirely macOS-specific:

| Feature | Dependencies | Porting Difficulty |
|---------|--------------|-------------------|
| PDF export | CGPDFContext, CGContext* | High |
| Text shaping | CTFramesetter, CTRun, CTLine | Very High |
| Variable fonts | CTFontCopyVariationAxes | High |
| Image export | NSBitmapImageRep | Medium |
| CMYK colors | NSColorSpace.genericCMYKColorSpace | Medium |

### Partially Abstractable Features

| Feature | macOS APIs | Cross-Platform Alternative |
|---------|-----------|---------------------------|
| BezierPath | NSBezierPath | [kurbo](https://github.com/linebender/kurbo), lyon |
| Color | NSColor | palette crate |
| Basic transforms | NSAffineTransform | [kurbo](https://github.com/linebender/kurbo) Transform |

### Good Model: SVGContext

The SVGContext demonstrates how DrawBot could be more portable:

```python
# SVGContext generates XML directly without macOS graphics APIs
# (though it still uses CoreText for text layout and AppKit for colors)
class SVGContext(BaseContext):
    def _svgPath(self, path, transformMatrix=None):
        # Converts NSBezierPath to SVG path string
        svg = ""
        for i in range(path.elementCount()):
            instruction, points = path.elementAtIndex_associatedPoints_(i)
            if instruction == AppKit.NSMoveToBezierPathElement:
                svg += "M%s,%s " % (...)
```

Even SVGContext requires NSBezierPath for path extraction.

## Cross-Platform Alternatives

| macOS API | Rust Crate Alternative | Notes |
|-----------|------------------------|-------|
| **CoreText** | `rustybuzz` + `fontkit-rs` | Text shaping; requires significant integration |
| CTFontManager | `font-kit` | Font enumeration and loading |
| CTFramesetter | `cosmic-text` or custom | Text layout engine |
| **Quartz** | | |
| CGPDFContext | `pdf-writer`, `lopdf`, `printpdf` | PDF generation |
| CGPath | `kurbo` or [`lyon`](https://github.com/nical/lyon) | Path representation and operations |
| CGPathCreateCopyByStrokingPath | `lyon::path::builder` | Path stroking/expansion |
| CGGradient | Custom implementation | Gradient structures |
| **AppKit** | | |
| NSBezierPath | `kurbo::BezPath` | Path abstraction |
| NSBitmapImageRep | [`image`](https://github.com/image-rs/image) crate | Bitmap encoding |
| NSColor | [`palette`](https://github.com/Ogeon/palette) crate | Color spaces and conversion |
| NSFont | `font-kit` + `rustybuzz` | Font access |
| NSImage | [`image`](https://github.com/image-rs/image) crate | Image loading |

## Recommendations for Your Framework

1. **Typography is the hardest problem.** DrawBot's tight CoreText integration makes text rendering the most complex feature to port. Consider:
   - Using `cosmic-text` for text layout
   - `rustybuzz` for OpenType shaping
   - Building a custom framesetter abstraction

2. **Define a context abstraction layer.** DrawBot's BaseContext shows how to separate drawing operations from backend. Build this abstraction from day one with platform-agnostic types.

3. **PDF generation is achievable.** Libraries like `pdf-writer` or `printpdf` can replace CGPDFContext, though integrating text requires careful coordination with the text engine.

4. **Path operations map well to Rust.** The `kurbo` crate provides excellent abstractions for paths, transforms, and geometric operations that parallel NSBezierPath/CGPath.

5. **Test SVG export first.** Since SVG is the most portable output format, implement and validate SVG export before tackling PDF or bitmap outputs.

6. **Variable font support requires care.** CoreText's variable font APIs (CTFontCopyVariationAxes) need equivalent functionality via [fontkit-rs](https://github.com/nickkraft/font-kit) or direct OpenType parsing with `read-fonts`.

## Key Source Files

- `/frameworks/drawbot/drawBot/context/baseContext.py` - BezierPath, Color, FormattedString, GraphicsState
- `/frameworks/drawbot/drawBot/context/pdfContext.py` - PDF export with Quartz
- `/frameworks/drawbot/drawBot/context/imageContext.py` - Bitmap export with AppKit
- `/frameworks/drawbot/drawBot/context/svgContext.py` - SVG export (most portable)
- `/frameworks/drawbot/drawBot/context/tools/variation.py` - Variable font axis handling
- `/frameworks/drawbot/drawBot/context/tools/openType.py` - OpenType feature extraction
