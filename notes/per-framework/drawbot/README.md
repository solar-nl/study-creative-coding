# DrawBot Study

> Python-based creative coding for macOS with exceptional typography support

---

## Why Study DrawBot?

DrawBot comes from the type design community, not the generative art world. This heritage shows in its priorities: OpenType features, variable fonts, multi-page documents, and PDF export are first-class citizens. While Processing focuses on real-time graphics and p5.js on web accessibility, DrawBot optimizes for print-quality output and typographic precision.

The framework offers unique perspectives on:
- **Typography-first design** — Font loading, OpenType features, text shaping are central, not afterthoughts
- **Multi-page documents** — Native support for creating booklets, zines, print layouts
- **Export diversity** — PDF, SVG, PNG, JPEG, TIFF, animated GIF, MP4 from the same code
- **Context-based rendering** — Clean separation between drawing API and output format

For the Rust framework, DrawBot provides patterns for professional print output that other creative coding frameworks often neglect. Its Python API is also remarkably clean — worth studying for ergonomics.

---

## Key Areas to Study

- **Context architecture** — How one API produces PDF, SVG, GIF, MP4 through different contexts
- **Typography system** — Font loading, OpenType features, variable font axes, text measurement
- **Page model** — Multi-page documents, page sizes, margins
- **Path operations** — Boolean operations, bezier manipulation
- **Image handling** — Image tracing, filters, compositing
- **Animation** — Frame-based animation to GIF/MP4

**Source locations:**
- `drawBot/` — Main module
- `drawBot/context/baseContext.py` — Core drawing API
- `drawBot/context/tools/openType.py` — OpenType feature support
- `drawBot/context/tools/variation.py` — Variable font handling
- `drawBot/ui/` — macOS application (separate from core module)
- `examples/` — Example scripts

---

## Repository Structure

```
drawbot/
├── drawBot/
│   ├── __init__.py              # API surface
│   ├── drawBotDrawingTools.py   # Core drawing functions
│   ├── context/
│   │   ├── baseContext.py       # Abstract drawing context
│   │   ├── pdfContext.py        # PDF output
│   │   ├── svgContext.py        # SVG output
│   │   ├── imageContext.py      # Raster image output
│   │   ├── gifContext.py        # Animated GIF
│   │   ├── mp4Context.py        # Video output
│   │   └── tools/
│   │       ├── openType.py      # OpenType features
│   │       ├── variation.py     # Variable fonts
│   │       └── imageObject.py   # Image manipulation
│   └── ui/                      # macOS application UI
├── examples/                    # Example scripts
├── docs/                        # Documentation
└── scripting/                   # Scripting utilities
```

---

## API Pattern: Context Manager

DrawBot's signature pattern — wrap drawing in a context:

```python
import drawBot

with drawBot.drawing():
    drawBot.newPage(1000, 1000)
    drawBot.rect(10, 10, 100, 100)
    drawBot.saveImage("~/Desktop/output.pdf")
```

This ensures proper cleanup of fonts and drawing state.

---

## Typography Features

DrawBot excels at typography:

```python
# Variable font axes
drawBot.font("MyVariableFont.ttf")
drawBot.fontVariations(wght=700, wdth=85)

# OpenType features
drawBot.openTypeFeatures(liga=True, smcp=True)

# Text box with alignment
drawBot.textBox("Hello", (100, 100, 200, 50), align="center")
```

---

## Comparison with Other Frameworks

| Aspect | DrawBot | Processing | p5.js |
|--------|---------|------------|-------|
| Language | Python | Java | JavaScript |
| Platform | macOS only | Cross-platform | Browser |
| Typography | Exceptional | Basic | Basic |
| Multi-page | Native | Manual | N/A |
| PDF export | Native, high-quality | Via library | Via library |
| Real-time | Limited | Primary focus | Primary focus |
| Variable fonts | Full support | Limited | Limited |

---

## Documents to Create

- [ ] `architecture.md` — Context system, drawing stack, page model
- [ ] `typography.md` — Font handling, OpenType features, variable fonts, text layout
- [ ] `api-design.md` — Function naming, context managers, Python idioms
- [ ] `export-pipeline.md` — How different contexts produce different formats
- [ ] `path-operations.md` — Boolean operations, bezier manipulation

---

## Related Studies

- [Processing](../processing/) — Java-based creative coding (more general-purpose)
- [p5.js](../p5js/) — JavaScript port of Processing
- [openrndr](../openrndr/) — Kotlin framework with strong typography support
- Typography theme study (when created)
