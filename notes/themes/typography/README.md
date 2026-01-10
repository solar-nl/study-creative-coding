# Theme: Typography

> Why is drawing text so much harder than drawing shapes?

## Key Insight

> **The core challenge:** Text rendering spans three distinct problems—font parsing, text shaping, and glyph rendering—each complex enough to be its own library, and creative coders want to manipulate text at all three levels.

---

## The Problem: Text Is Deceptively Complex

You might think rendering text would be simple. After all, fonts are just collections of shapes, right? Load the file, get the shapes, draw them. Done.

But try to actually implement text rendering, and you'll quickly discover a rabbit hole:

- **Fonts are complex binary formats.** TrueType, OpenType, WOFF—each with their own tables, encoding schemes, and quirks. Just parsing them correctly is a project in itself.

- **Characters aren't independent.** The space between "AV" should be different from "AI" (that's kerning). Some character pairs combine into single glyphs (ligatures: "fi" → "ﬁ"). Languages like Arabic change letter shapes based on position in a word.

- **Performance matters.** A naive approach renders each character separately—thousands of draw calls per frame. Real-time creative coding demands batching.

- **Scaling is tricky.** Bitmap fonts blur when scaled. Vector fonts need GPU tessellation. Both have trade-offs.

- **Platforms differ.** The same font renders slightly differently on macOS, Windows, and Linux. Users notice.

Creative coding adds another dimension: we often want to **treat text as graphic material**—animate individual letters, fill text with textures, convert characters to paths for generative effects. Most text systems optimize for reading, not art.

Let's explore how six creative coding frameworks tackle these challenges, and what we can learn from their approaches.

---

## The Mental Model: Three Layers of Typography

Before diving into implementations, it helps to understand what any text system must do:

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 1: Font Parsing                                      │
│  "Turn a .ttf file into usable glyph data"                 │
│  Libraries: FreeType, opentype.js, RustType, STB TrueType  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 2: Text Shaping                                      │
│  "Turn a string into positioned glyphs"                     │
│  Handles: kerning, ligatures, line breaking, alignment      │
│  Libraries: HarfBuzz, CoreText, platform-native APIs        │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  Layer 3: Rendering                                         │
│  "Turn positioned glyphs into pixels on screen"            │
│  Approaches: Bitmap atlas, SDF, vector tessellation        │
└─────────────────────────────────────────────────────────────┘
```

Think of it like a translation pipeline. A font file is like a dictionary—it contains all the letter shapes. Text shaping is like grammar—it decides how letters combine and flow. Rendering is like handwriting—actually putting ink on paper.

Different frameworks make different choices at each layer, with profound implications for features and performance.

---

## Framework Deep Dives

### p5.js: The Dual-System Dilemma

**The approach:** p5.js uses [opentype.js](https://github.com/opentypejs/opentype.js) to parse fonts in JavaScript, then renders via Canvas 2D or WebGL.

**What makes this interesting:** p5.js faces a uniquely web-specific challenge. Browsers already have powerful text rendering built in—the Canvas API's `fillText()` handles fonts, kerning, and even complex scripts automatically. So why not just use that?

The answer is: creative coders want more than just *displaying* text. They want to *manipulate* it. And here's where `fillText()` falls short—it's a black box. You can't ask "where exactly is each letter?" or "give me the outline of this character."

That's why p5.js brings in [opentype.js](https://github.com/opentypejs/opentype.js). It can parse font files directly and expose glyph data:

```javascript
// This is why opentype.js exists in p5.js
let points = font.textToPoints('hello', 0, 0, 72, {
  sampleFactor: 0.5
});

// Now we have actual coordinate data to play with
for (let p of points) {
  // Each point has x, y, and even the angle of the curve at that point
  ellipse(p.x, p.y, 4);
}
```

This enables generative typography—particles flowing along letter shapes, text that wiggles, characters that explode into fragments.

**The catch:** Now p5.js has two text systems that don't quite agree. Use `text()` for basic rendering (fast, uses browser's engine). Use `textToPoints()` for creative manipulation (slower, uses [opentype.js](https://github.com/opentypejs/opentype.js)). But they can behave differently—alignment might not match perfectly, certain fonts work in one but not the other.

The community has been wrestling with this tension for years. GitHub issue [#6391](https://github.com/processing/p5.js/issues/6391) is a fascinating read—it explores potential solutions like SDF fonts or unifying on [opentype.js](https://github.com/opentypejs/opentype.js), each with trade-offs.

**Key files to study:**
- `src/typography/p5.Font.js` — The `textToPoints()` magic lives here
- `src/typography/loading_displaying.js` — Font loading and the `text()` function
- `src/webgl/text.js` — How text works in 3D mode (texture-mapped Bezier curves!)

---

### Processing: The Lazy Approach (In a Good Way)

**The approach:** Processing uses Java's built-in AWT font system, with a clever twist for OpenGL rendering.

**The key insight:** Most programs only use a fraction of a font's characters. Loading all 65,000+ Unicode glyphs upfront wastes memory. Processing's solution? Load glyphs on demand.

Here's how it works. When you call `createFont("Helvetica", 32)`, Processing doesn't render every character immediately. Instead, it creates a `PFont` object that knows *how* to render characters but hasn't done so yet. The first time you actually draw a specific character, Processing:

1. Asks Java's AWT to render that character to a small offscreen image
2. Scans the image to find the actual glyph bounds (not all characters use their full cell)
3. Extracts the bitmap and stores it for future use

This lazy loading is why you'll sometimes see a tiny pause the first time a character appears—especially with CJK fonts that have thousands of characters.

For OpenGL rendering, Processing packs these bitmaps into a texture atlas (see `FontTexture.java`). There's a subtle detail here: each glyph gets a 1-pixel transparent border. Why? When the GPU samples textures, it can blend neighboring pixels. Without borders, you'd see ghostly fragments of adjacent glyphs bleeding into your text.

**The limitation you'll hit:** Processing treats fonts as bitmaps. Great for consistency, but you can't get vector paths out. If you want to draw text as shapes, fill it with a gradient, or animate individual control points... you'll need a different framework.

**Key files to study:**
- `core/src/processing/core/PFont.java` — The `Glyph` inner class shows the bitmap extraction logic
- `core/src/processing/opengl/FontTexture.java` — Atlas packing with those crucial 1-pixel borders

---

### OpenFrameworks: The FreeType Powerhouse

**The approach:** OpenFrameworks wraps FreeType, the industry-standard open-source font engine.

**Why this matters:** FreeType is battle-tested. It's what renders fonts on Linux, Android, and many game engines. Using it means OpenFrameworks gets excellent font compatibility and features that would take years to implement from scratch.

But raw FreeType is low-level—you're dealing with fixed-point math, manual memory management, and callback-based outline traversal. OpenFrameworks wraps this complexity in a friendlier API while still exposing the power underneath.

The most interesting part is the contour system. When you load a font with `settings.contours = true`, OpenFrameworks extracts the actual Bezier curves that define each character:

```cpp
ofTrueTypeFontSettings settings("font.ttf", 64);
settings.contours = true;  // This is the magic flag

ofTrueTypeFont font;
font.load(settings);

// Now you can get actual vector paths
vector<ofPath> paths = font.getStringAsPoints("hello", true, true);

// Each path has moveTo, lineTo, curveTo commands you can inspect or modify
for (auto& path : paths) {
    for (auto& cmd : path.getCommands()) {
        // Do something creative with each point
    }
}
```

Under the hood, this uses FreeType's outline decomposition API. The font file stores outlines as a series of points with on-curve/off-curve flags. FreeType walks through these and calls back with move, line, conic (quadratic), and cubic commands. OpenFrameworks translates these to its `ofPath` type.

**What you should know about:** Unicode ranges. OpenFrameworks lets you specify exactly which character sets to load—Latin, Greek, Cyrillic, CJK, Emoji. This matters because pre-rendering all glyphs (required for the contour system) can be slow and memory-intensive for large character sets.

```cpp
settings.ranges = {
    ofUnicode::Latin,
    ofUnicode::LatinExtendedA,
    ofUnicode::Emoji  // Why not?
};
```

**Key files to study:**
- `libs/openFrameworks/graphics/ofTrueTypeFont.cpp` — Lines 188-229 show the FreeType outline callback magic

---

### Cinder: The Platform-Native Pragmatist

**The approach:** Cinder delegates to platform APIs—CoreText on macOS, GDI+ on Windows, FreeType on Linux.

**The philosophy here is pragmatic:** Apple and Microsoft have spent decades perfecting text rendering for their platforms. Their engines handle complex scripts (Arabic, Hindi, Chinese), advanced OpenType features (stylistic alternates, contextual ligatures), and accessibility requirements. Reimplementing all that would be enormous effort.

So Cinder says: use what the platform provides, wrap it in a consistent API.

The `TextBox` class exemplifies Cinder's builder-pattern approach:

```cpp
auto text = TextBox()
    .text("Hello, world!")
    .font(Font("Garamond", 24))
    .size(vec2(400, TextBox::GROW))  // Fixed width, auto height
    .alignment(TextBox::CENTER)
    .color(Color::white())
    .backgroundColor(ColorA(0, 0, 0, 0.5f));

// Compute the layout
vec2 size = text.measure();

// Render to a Surface (CPU) or use TextureFont for GPU
Surface rendered = text.render();
```

**The GPU side:** `TextureFont` pre-renders a character set to a texture atlas, similar to other frameworks. But Cinder adds some nice touches—you can specify custom shaders for effects, and there's per-glyph color support:

```cpp
vector<ColorA8u> colors = { RED, RED, GREEN, GREEN, BLUE };
textureFont->drawGlyphs(glyphs, baseline, options, colors);
```

**The trade-off:** Platform-native rendering means platform-specific behavior. The same font at the same size might render a pixel or two differently on macOS vs Windows. For most applications, this is fine. For pixel-perfect cross-platform consistency, it's a problem. See [issue #416](https://github.com/cinder/Cinder/issues/416) for war stories.

**Key files to study:**
- `src/cinder/Text.cpp` — The `calculateLineBreaks()` function shows platform-specific line breaking
- `src/cinder/gl/TextureFont.cpp` — Atlas generation and batch rendering

---

### openrndr: The Pluggable Architecture

**The approach:** openrndr uses a driver abstraction with STB TrueType as the default backend, plus a sophisticated layout library (`orx-text-writer`).

**The design pattern that stands out:** openrndr separates the "how to parse fonts" question from the "how to use fonts" question:

```kotlin
interface FontDriver {
    fun loadFace(fileOrUrl: String): Face
}

interface Face {
    fun glyphForCharacter(character: Char): Glyph
    fun kernAdvance(scale: Double, left: Char, right: Char): Double
    // ...
}

interface Glyph {
    fun shape(scale: Double): Shape  // Vector outline!
    fun advanceWidth(scale: Double): Double
    // ...
}
```

This means you could swap STB TrueType for FreeType, or a platform-native backend, without changing user code. In practice, most people just use the default, but the abstraction is there.

**Where openrndr really shines:** The `orx-text-writer` extension library. It introduces a concept of "tokens"—computed text positions before any drawing happens:

```kotlin
writer {
    text("hello world", visible = false)  // Layout only, don't draw yet

    // Now glyphOutput.rectangles contains where each glyph would be drawn
    // We can transform these however we want before actually drawing
}
```

This separation of layout and rendering enables effects that would be awkward otherwise—text that follows curves, per-character animation, custom hit-testing.

The `WriteStyle` class shows what typographic controls the library exposes:

```kotlin
class WriteStyle {
    var leading = 0.0         // Extra line spacing
    var tracking = 0.0        // Letter spacing (kerning adjustment)
    var horizontalAlign = 0.0 // 0.0 = left, 0.5 = center, 1.0 = right
    var verticalAlign = 0.0   // 0.0 = top, 0.5 = center, 1.0 = bottom
    var ellipsis: String? = "…"  // Overflow handling
}
```

**Key files to study:**
- `openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/font/Font.kt` — The Face/Glyph interfaces
- `libraries/orx/orx-text-writer/src/commonMain/kotlin/TextWriter.kt` — The token-based layout system

---

### nannou: The Rust-Native Solution

**The approach:** nannou uses RustType for font parsing and lyon for path tessellation—pure Rust, no C dependencies.

**Why this matters for Rust developers:** RustType parses fonts and generates glyph outlines. Lyon tessellates vector paths into triangles. Both are idiomatic Rust with proper memory safety. No unsafe FFI to C libraries means easier compilation, better error messages, and integration with Rust's tooling.

The API uses nannou's characteristic builder pattern:

```rust
draw.text("Hello, nannou!")
    .font_size(48)
    .color(BLACK)
    .center_justify()      // Horizontal alignment
    .align_middle_y()      // Vertical alignment
    .wh(rect.wh());        // Bounding box
```

**The generative capability:** Converting text to paths works through RustType's shape extraction, then lyon's path builder:

```rust
// Build the text layout
let text_layout = text("creative")
    .font_size(128)
    .build(win_rect);

// Draw it as a filled path instead of textured quads
draw.path()
    .fill()
    .color(BLACK)
    .events(text_layout.path_events());
```

Under the hood, `path_events()` iterates through RustType's glyph contours (sequences of lines and quadratic Beziers) and yields lyon `PathEvent`s. This means you can fill text with gradients, stroke outlines, or feed the paths into any lyon-compatible system.

**Per-glyph coloring** is a nice touch:

```rust
draw.text("rainbow")
    .glyph_colors(vec![RED, ORANGE, YELLOW, GREEN, BLUE, INDIGO, VIOLET]);
```

**The current limitation:** nannou is undergoing a major refactor to integrate with Bevy. The text system is partially implemented—see [issue #1003](https://github.com/nannou-org/nannou/issues/1003). If you're starting a project today, check the current state of `bevy_nannou_draw`.

**Key files to study:**
- `nannou/src/text/glyph.rs` — The RustType-to-lyon conversion in `contours_to_path()`
- `nannou/src/draw/primitive/text.rs` — The builder pattern implementation

---

### DrawBot: The Typography Specialist

**The approach:** DrawBot uses macOS CoreText for text shaping and rendering, with [fontTools](https://github.com/fonttools/fonttools) for font inspection. This is a *platform-native* approach like Cinder, but from the type design community rather than creative coding.

**Why DrawBot is different:** Unlike other creative coding frameworks that add typography as a feature, DrawBot was built *by type designers for type designers*. Its heritage shows—OpenType features, variable fonts, and multi-page documents are first-class citizens, not afterthoughts.

**Variable fonts work here:** DrawBot is the only creative coding framework studied that fully exposes variable font axes:

```python
# Load a variable font and set axes
font("Inter-Variable.ttf")
fontVariations(wght=650, wdth=87.5)

# Query available axes
for axis, info in listFontVariations().items():
    print(f"{axis}: {info['minValue']}–{info['maxValue']}")

# Use designer-defined named instances
fontNamedInstance("Bold Condensed")
```

This enables smooth weight animation—impossible with traditional fonts—by interpolating axis values each frame.

**OpenType feature discovery and control:** DrawBot doesn't just *support* OpenType features; it lets you *discover* what a font offers:

```python
# See what features this font supports
features = listOpenTypeFeatures()
# Returns: {'liga': True, 'smcp': True, 'onum': True, 'ss01': True, ...}

# Enable specific features
openTypeFeatures(liga=True, smcp=True)  # Ligatures + small caps

# Or disable defaults
openTypeFeatures(liga=False)  # Turn off ligatures
```

This introspection capability is rare—most frameworks let you *request* features but don't tell you what's available.

**Rich text via FormattedString:** DrawBot's `FormattedString` class enables per-character styling:

```python
txt = FormattedString()
txt.append("Hello ", font="Helvetica", fontSize=24)
txt.append("World", font="Helvetica-Bold", fontSize=36, fill=(1, 0, 0))
text(txt, (100, 100))
```

Each segment can have different fonts, sizes, colors, and even different OpenType features.

**Text-to-path conversion:** Like OpenFrameworks and nannou, DrawBot provides vector path access:

```python
# Get text as a BezierPath for creative manipulation
path = BezierPath()
path.text("creative", font="Helvetica", fontSize=200)

# Now path.points contains all the control points
for contour in path.contours:
    for point in contour:
        # Each point has x, y, and type (onCurve, offCurve)
        pass
```

Under the hood, this uses CoreText's `CTRunGetGlyphs()` and `CTFontCreatePathForGlyph()` to extract glyph paths.

**The limitation:** macOS only. DrawBot is built on PyObjC and requires CoreText, making it impossible to run on Windows or Linux. For cross-platform projects, you'll need a different framework.

**Key files to study:**
- `drawBot/drawBotDrawingTools.py` — The user-facing API including `font()`, `fontVariations()`, `openTypeFeatures()`
- `drawBot/context/baseContext.py` — Lines 1400-1537 show text attribute handling
- `drawBot/context/tools/openType.py` — The `getFeatureTagsForFont()` implementation
- `drawBot/context/tools/variation.py` — Variable font axis discovery

---

## The Trade-offs, Visualized

Here's how the frameworks compare on key dimensions:

```
                    Vector Paths?    Complex Scripts?    Pure Language?
                    (generative)     (Arabic, etc.)      (no C deps)
                         │                 │                  │
    p5.js          ●●●●●○○○         ○○○○○○○○          ●●●●●●●●
    Processing     ○○○○○○○○         ●●●○○○○○          ●●●●●●●●
    OpenFrameworks ●●●●●●●●         ●●●○○○○○          ○○○○○○○○
    Cinder         ●●●●●●○○         ●●●●●●●●          ○○○○○○○○
    openrndr       ●●●●●●●○         ●●●○○○○○          ●●●●●●●●
    nannou         ●●●●●●●●         ○○○○○○○○          ●●●●●●●●
    DrawBot        ●●●●●●●●         ●●●●●●●●          ●●●●●●●●  (macOS only)
```

| Framework | Font Library | What It Gets You | What You Give Up |
|-----------|-------------|------------------|------------------|
| p5.js | [opentype.js](https://github.com/opentypejs/opentype.js) | `textToPoints()` for generative art | Consistency (dual-system issues) |
| Processing | Java AWT | Reliability, lazy loading | No path access |
| OpenFrameworks | FreeType | Industry-standard rendering, full Unicode | C++ dependency complexity |
| Cinder | Platform-native | Best OS integration, ligatures | Cross-platform consistency |
| openrndr | STB TrueType | Pluggable architecture, token-based layout | Basic shaping only |
| nannou | RustType | Pure Rust, clean path API | Limited feature set |
| DrawBot | CoreText | Variable fonts, OpenType features, [fontTools](https://github.com/fonttools/fonttools) inspection | macOS only |

---

## What We Can Learn for a Rust Framework

After studying these implementations, several patterns emerge as worth adopting:

### Separate Layout from Rendering

openrndr's token-based approach is powerful. Compute where glyphs go first, *then* decide how to draw them. This enables:

- Pre-render inspection ("how wide will this text be?")
- Per-glyph transformation (animation, effects)
- Alternative renderers (fill vs. stroke vs. texture)

```rust
// Proposed pattern
let layout = Text::layout("hello")
    .font(&font)
    .size(24.0)
    .wrap_width(200.0)
    .build();

// Inspect before drawing
println!("Text width: {}", layout.bounds().width);

// Draw with transformations
for (i, glyph) in layout.glyphs().enumerate() {
    let wave = (i as f32 * 0.5 + time).sin() * 10.0;
    draw.glyph(&glyph).offset_y(wave);
}
```

### Use Builder Patterns for Configuration

Both Cinder and nannou demonstrate that typography has too many options for positional parameters. Builders make code readable:

```rust
// Clear and self-documenting
draw.text("Hello")
    .font(&font)
    .size(24.0)
    .color(WHITE)
    .align(HAlign::Center, VAlign::Top)
    .tracking(1.5)   // Letter spacing
    .leading(1.2);   // Line height multiplier
```

### Make Path Extraction First-Class

Every creative coding framework eventually adds path access because users demand it. Build it in from the start:

```rust
// Should be this easy
let path = text_layout.to_path();
draw.path(&path).fill(gradient);
```

### Consider the Shaping Gap

None of the pure-language solutions (p5.js, openrndr, nannou) properly handle complex scripts. For a Rust framework, [rustybuzz](https://github.com/RazrFalcon/rustybuzz) (a [HarfBuzz](https://github.com/harfbuzz/harfbuzz) port) could fill this gap:

```
Font Parsing      Text Shaping         Rendering
     │                 │                   │
     ▼                 ▼                   ▼
 cosmic-text  ──▶  rustybuzz  ──▶  wgpu texture atlas
 (or fontdue)      (HarfBuzz)      (with glyph caching)
```

### Don't Forget Resource Management

Several frameworks have had memory leak issues with font caching (Cinder [#524](https://github.com/cinder/Cinder/issues/524), nannou [#786](https://github.com/nannou-org/nannou/issues/786)). Rust's ownership system is an advantage here—make `Font` and `GlyphCache` lifetimes explicit:

```rust
// Explicit lifetime, automatic cleanup
let font = Font::load("font.ttf")?;
let cache = GlyphCache::new(&device);

// When `cache` drops, GPU resources are freed
```

---

## Deep Dives: Further Research

These topics warranted their own detailed analysis:

- **[Font Fallback](typography-font-fallback.md)** — What happens when a font doesn't have a glyph? How do platform APIs, [HarfBuzz](https://github.com/harfbuzz/harfbuzz), and [cosmic-text](https://github.com/pop-os/cosmic-text) handle missing characters? How should a Rust framework specify fallback chains?

- **[Variable Fonts](typography-variable-fonts.md)** — Modern fonts with continuous weight/width axes. How the fvar table works, what [swash](https://github.com/dfrg/swash) provides, and API design patterns for creative coding.

- **[WebAssembly Text Shaping](typography-wasm-shaping.md)** — Should you use the browser's native text engine or bring your own ([rustybuzz](https://github.com/RazrFalcon/rustybuzz))? Bundle size trade-offs, the hybrid approach, and when each makes sense.

- **[Layout Mutability](typography-layout-mutability.md)** — Should `TextLayout` be mutable for animation, or always rebuilt? Lessons from Android's StaticLayout/DynamicLayout, CSS FLIP technique, and Rust ownership patterns.

---

## Where to Go Next

- **If you're implementing typography in Rust:** Start with [cosmic-text](https://github.com/pop-os/cosmic-text), which handles shaping and layout. Pair with [lyon](https://github.com/nical/lyon) for path rendering.

- **If you want to understand font internals:** The [OpenType spec](https://learn.microsoft.com/en-us/typography/opentype/spec/) is dense but authoritative. [The Raster Tragedy](http://rastertragedy.com/) explains why font rendering is hard.

- **If you're debugging text issues:** Each framework's GitHub issues are goldmines. Search for "font", "text", "typography", "kerning"—you'll find the edge cases others have hit.

---

## Source Files Reference

| Framework | Key Typography Files |
|-----------|---------------------|
| p5.js | `src/typography/p5.Font.js`, `src/typography/loading_displaying.js` |
| Processing | `core/src/processing/core/PFont.java`, `core/src/processing/opengl/FontTexture.java` |
| OpenFrameworks | `libs/openFrameworks/graphics/ofTrueTypeFont.cpp` |
| Cinder | `include/cinder/Font.h`, `src/cinder/gl/TextureFont.cpp`, `include/cinder/Text.h` |
| openrndr | `openrndr-draw/.../font/Font.kt`, `orx-text-writer/.../TextWriter.kt` |
| nannou | `nannou/src/text/font.rs`, `nannou/src/text/glyph.rs`, `nannou/src/draw/primitive/text.rs` |
| DrawBot | `drawBot/drawBotDrawingTools.py`, `drawBot/context/tools/openType.py`, `drawBot/context/tools/variation.py` |

---

## GitHub Issues Worth Reading

These discussions reveal real-world pain points and design debates:

| Issue | Framework | What You'll Learn |
|-------|-----------|-------------------|
| [#6391](https://github.com/processing/p5.js/issues/6391) | p5.js | The [opentype.js](https://github.com/opentypejs/opentype.js) vs CSS @font-face architectural tension |
| [#5607](https://github.com/processing/p5.js/issues/5607) | p5.js | Why variable fonts are hard to support |
| [#1131](https://github.com/openframeworks/openFrameworks/issues/1131) | OpenFrameworks | Feature discussion for ofTrueTypeFont redesign |
| [#825](https://github.com/openframeworks/openFrameworks/issues/825) | OpenFrameworks | Small font rendering quality issues |
| [#416](https://github.com/cinder/Cinder/issues/416) | Cinder | Cross-platform text inconsistencies |
| [#1003](https://github.com/nannou-org/nannou/issues/1003) | nannou | Current state of Bevy integration |
