# DrawBot Typography

> Typography-first design with full CoreText integration for professional type manipulation.

## Key Insight

> **Typography's core idea:** DrawBot exposes full OpenType feature control and variable font axes through CoreText, with FormattedString enabling per-character styling while [fontTools](https://github.com/fonttools/fonttools) provides direct access to GPOS/GSUB tables.

## Font Loading

DrawBot accepts both PostScript names and file paths for font specification. When a path is given, the font is temporarily installed for script duration.

```python
# By PostScript name
font("Helvetica-Bold")

# By file path (auto-installed temporarily)
font("/path/to/MyFont.otf")

# With font size
font("Times-Italic", 48)

# Font collections (.ttc/.otc) with index
font("MyFontCollection.ttc", fontNumber=1)
```

From [`drawBotDrawingTools.py`](https://github.com/robotools/drawbot/blob/master/drawBotDrawingTools.py):
```python
def font(self, fontNameOrPath: SomePath, fontSize: float | None = None, fontNumber: int = 0):
    """Set a font with the name of the font.
    If a font path is given the font will be installed and used directly."""
    font = getNSFontFromNameOrPath(fontNameOrPath, fontSize or 10, fontNumber)
```

## OpenType Features

Direct control over GPOS (positioning) and GSUB (substitution) tables via keyword arguments.

```python
# Enable small caps and ligatures
openTypeFeatures(smcp=True, liga=True)

# Enable old-style numerals
openTypeFeatures(onum=True)

# Stylistic sets
openTypeFeatures(ss01=True, ss02=True)

# Reset to defaults
openTypeFeatures(resetFeatures=True)

# Introspection: list available features
print(listOpenTypeFeatures())  # ['calt', 'kern', 'liga', 'smcp', ...]
```

From [`openType.py`](https://github.com/robotools/drawbot/blob/master/context/tools/openType.py), feature discovery uses [fontTools](https://github.com/fonttools/fonttools) to parse GPOS/GSUB tables:
```python
@memoize
def getFeatureTagsForFont(font):
    featureTags = set()
    if "GPOS" in ft and ft["GPOS"].table.FeatureList is not None:
        for record in ft["GPOS"].table.FeatureList.FeatureRecord:
            featureTags.add(record.FeatureTag)
    if "GSUB" in ft and ft["GSUB"].table.FeatureList is not None:
        for record in ft["GSUB"].table.FeatureList.FeatureRecord:
            featureTags.add(record.FeatureTag)
```

## Variable Font Axes

Full variable font support with axis value control and introspection.

```python
font("Skia")

# Query available axes
for axis, data in listFontVariations().items():
    print(axis, data)
# wght {'name': 'Weight', 'minValue': 0.48, 'maxValue': 3.2, 'defaultValue': 1.0}

# Set axis values
fontVariations(wght=0.6)
fontVariations(wght=3, wdth=1.2)

# Named instances
print(listNamedInstances())  # {'SkiaRegular': {'wght': 1.0}, ...}
fontNamedInstance("SkiaBlack")
```

From [`variation.py`](https://github.com/robotools/drawbot/blob/master/context/tools/variation.py), axes are retrieved via CoreText:
```python
@memoize
def getVariationAxesForFont(font):
    axes = OrderedDict()
    variationAxesDescriptions = CoreText.CTFontCopyVariationAxes(font)
    for desc in variationAxesDescriptions:
        tag = convertIntToVariationTag(desc[CoreText.kCTFontVariationAxisIdentifierKey])
        axes[tag] = dict(name=..., minValue=..., maxValue=..., defaultValue=...)
```

## FormattedString Rich Text

Per-run text attributes enabling mixed styling within a single text block.

```python
txt = FormattedString()

# Different styles per append
txt.append("hello", font="Helvetica", fontSize=100, fill=(1, 0, 0))
txt.append("world", font="Times-Italic", fontSize=50, fill=(0, 1, 0))

# OpenType features per segment
txt.append("SMALL", font="Didot", fontSize=50, openTypeFeatures=dict(smcp=True))

# Variable fonts per segment
txt.append("Bold", fontVariations=dict(wght=700))

# Draw combined string
text(txt, (10, 30))
```

The `_formattedAttributes` dict defines all available per-run properties:
```python
_formattedAttributes = dict(
    font=_FALLBACKFONT, fontSize=10, fill=(0, 0, 0), stroke=None,
    strokeWidth=1, align=None, lineHeight=None, tracking=None,
    baselineShift=None, underline=None, openTypeFeatures=dict(),
    fontVariations=dict(), language=None, writingDirection=None, ...
)
```

## Text Layout

CoreText framesetter for multi-line text with hyphenation and language-aware shaping.

```python
# Text box with alignment
overflow = textBox("Long text...", (x, y, w, h), align="justified")

# Hyphenation (language-aware)
hyphenation(True)
language("nl")  # Dutch hyphenation rules
textBox(txt, box)

# Alignment options: "left", "center", "right", "justified"

# Get baseline positions for custom rendering
baselines = textBoxBaselines(txt, box)  # [(x1, y1), (x2, y2), ...]

# Get per-run bounding boxes
bounds = textBoxCharacterBounds(txt, box)  # [(bounds, baseline, substring), ...]
```

## Text Measurement

Measure text dimensions before drawing for layout calculations.

```python
# Basic measurement
width, height = textSize("Hello World")

# With width constraint (returns required height)
w, h = textSize(longText, width=200)

# With height constraint (returns required width)
w, h = textSize(longText, height=100)
```

## Recommendations for Your Framework

1. **Font path flexibility** — Accept both system names and file paths with temporary installation
2. **OpenType as keyword args** — `opentype_features(smcp=true)` is discoverable and type-safe
3. **Introspection APIs** — `list_font_variations()`, `list_opentype_features()` enable runtime discovery
4. **Rich text builder** — Per-segment styling via append/chaining pattern maps well to Rust builders
5. **Variable font support** — Essential for modern typography; expose axis metadata
6. **Layout introspection** — Provide baseline positions and character bounds for advanced effects
7. **Language-aware shaping** — Integrate ICU or similar for proper hyphenation and locl features
