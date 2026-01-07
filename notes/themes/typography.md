# Theme: Typography

> Cross-cutting analysis of how different creative coding frameworks handle text rendering, font loading, and typography.

## Concept Overview

Typography in creative coding requires balancing multiple concerns:
- **Accessibility**: Simple API for beginners to display text
- **Flexibility**: Font loading from files, system fonts, or URLs
- **Performance**: GPU-accelerated rendering via texture atlases
- **Expressiveness**: Path-based text for generative art, per-glyph manipulation
- **Cross-platform**: Consistent rendering across OS/GPU combinations

Creative coding typography differs from traditional GUI text in its emphasis on **visual expressiveness** - text as graphic element rather than just information carrier.

## Framework Implementations

### p5.js
**Approach**: JavaScript + opentype.js for font parsing, Canvas 2D/WebGL rendering

**Key files**:
- `src/typography/p5.Font.js`
- `src/typography/loading_displaying.js`
- `src/webgl/text.js`

```javascript
// Font loading
let font;
function preload() {
  font = loadFont('assets/inconsolata.otf');
}

// Basic text rendering
function draw() {
  textFont(font);
  textSize(32);
  textAlign(CENTER, CENTER);
  text('Hello p5.js', width/2, height/2);
}

// Path extraction for generative art
let points = font.textToPoints('p5*js', 50, 100, 64, {
  sampleFactor: 0.5
});
for (let p of points) {
  ellipse(p.x, p.y, 4);
}
```

**Strengths**:
- `textToPoints()` enables powerful generative text effects
- Supports TTF, OTF, WOFF, WOFF2 formats
- Automatic @font-face injection for CSS compatibility
- WebGL text rendering with texture-mapped Bezier curves

**Weaknesses**:
- Dual system tension: opentype.js vs CSS @font-face (see [#6391](https://github.com/processing/p5.js/issues/6391))
- No variable font support ([#5607](https://github.com/processing/p5.js/issues/5607))
- textToPoints alignment inconsistencies ([#8315](https://github.com/processing/p5.js/issues/8315))

---

### Processing
**Approach**: Java AWT fonts with bitmap caching, OpenGL texture atlas for 3D

**Key files**:
- `core/src/processing/core/PFont.java`
- `core/src/processing/core/PGraphics.java`
- `core/src/processing/opengl/FontTexture.java`

```java
// Dynamic font creation
PFont font = createFont("Helvetica", 32, true);

// Bitmap font loading (.vlw format)
PFont bitmapFont = loadFont("MyFont-48.vlw");

// Drawing
textFont(font);
textSize(24);
textAlign(CENTER, TOP);
text("Hello Processing", width/2, 50);
```

**Strengths**:
- Lazy glyph loading - renders characters on-demand
- Pre-baked .vlw bitmap fonts for consistent rendering
- OpenGL texture atlas with 1-pixel borders prevents sampling artifacts
- Extensive default character set (Latin-1 + math symbols)

**Weaknesses**:
- Binary search for Unicode glyph lookup (O(log n) vs O(1) for ASCII)
- No vector path access from user code
- Bitmap scaling can blur at large sizes

---

### OpenFrameworks
**Approach**: FreeType for font parsing and rasterization, OpenGL texture atlas

**Key files**:
- `libs/openFrameworks/graphics/ofTrueTypeFont.h`
- `libs/openFrameworks/graphics/ofTrueTypeFont.cpp`

```cpp
// Font loading with settings
ofTrueTypeFontSettings settings("fonts/arial.ttf", 32);
settings.antialiased = true;
settings.contours = true;  // Enable path access
settings.dpi = 72;
settings.ranges = { ofUnicode::Latin1Supplement };

ofTrueTypeFont font;
font.load(settings);

// Drawing
font.drawString("Hello OpenFrameworks", 100, 100);

// Vector paths
font.drawStringAsShapes("Outline text", 100, 200);
vector<ofPath> paths = font.getStringAsPoints("Path text", true, true);
```

**Strengths**:
- Full FreeType integration with kerning support
- Contour decomposition to ofPath (moveTo, lineTo, bezierTo)
- Unicode range support (Latin, Greek, Cyrillic, CJK, Emoji)
- Bidirectional text (LTR/RTL)
- Mesh-based batch rendering

**Weaknesses**:
- Small font glyph simplification ([#825](https://github.com/openframeworks/openFrameworks/issues/825))
- DPI scaling issues ([#6970](https://github.com/openframeworks/openFrameworks/issues/6970))
- No HarfBuzz for complex text shaping

---

### Cinder
**Approach**: Platform-native backends (CoreText/GDI+/FreeType) + GPU TextureFont

**Key files**:
- `include/cinder/Font.h`
- `src/cinder/gl/TextureFont.cpp`
- `include/cinder/Text.h`

```cpp
// Font loading
auto font = Font("Arial", 48);
auto fontFromFile = Font(loadFile("font.ttf"), 48);

// TextureFont for GPU rendering
auto textureFont = gl::TextureFont::create(font,
    gl::TextureFont::Format()
        .textureWidth(2048)
        .enableMipmapping(true),
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789");

// Draw with options
textureFont->drawString("Hello Cinder", vec2(100, 100),
    gl::TextureFont::DrawOptions()
        .scale(2.0f)
        .ligate(true)
        .pixelSnap(true));

// TextBox for layout
auto tb = TextBox()
    .text("Lorem ipsum...")
    .font(font)
    .size(400, TextBox::GROW)
    .alignment(TextBox::CENTER);

vec2 size = tb.measure();
Surface textSurface = tb.render();
```

**Strengths**:
- Platform-native text shaping (CoreText on macOS, GDI+ on Windows)
- Builder pattern APIs (TextBox, DrawOptions, Format)
- Custom shader support for text effects
- Per-glyph color support
- Ligature support

**Weaknesses**:
- Cross-platform rendering inconsistencies ([#416](https://github.com/cinder/Cinder/issues/416))
- Font memory leaks ([#524](https://github.com/cinder/Cinder/issues/524))
- TextBox measurement accuracy ([#347](https://github.com/cinder/Cinder/issues/347))

---

### openrndr
**Approach**: STB TrueType driver + FontImageMap texture atlas + orx-text-writer for advanced layout

**Key files**:
- `openrndr-draw/src/commonMain/kotlin/org/openrndr/draw/font/Font.kt`
- `openrndr-jvm/openrndr-fontdriver-stb/src/main/kotlin/FontDriverStbTt.kt`
- `libraries/orx/orx-text-writer/src/commonMain/kotlin/TextWriter.kt`

```kotlin
// Font loading
drawer.fontMap = loadFont("fonts/IBMPlexMono-Regular.ttf", 24.0)

// Basic drawing
drawer.text("Hello OPENRNDR", Vector2(100.0, 100.0))

// Advanced layout with TextWriter
writer {
    style.horizontalAlign = 0.5  // Center
    style.tracking = 2.0         // Letter spacing
    style.leading = 10.0         // Line spacing
    box = Rectangle(0.0, 0.0, 400.0, 300.0)
    newLine()
    text("Multi-line text layout")
}

// Glyph-level access for effects
writer {
    text(text, visible = false)  // Layout only
    // Transform glyphs individually
    drawer.image((drawer.fontMap as FontImageMap).texture,
        glyphOutput.rectangles.mapIndexed { index, it ->
            Pair(it.first, it.second.movedBy(
                Vector2(0.0, 20.0 * cos(index * 0.5 + seconds * 10.0))
            ))
        }
    )
}
```

**Strengths**:
- Driver pattern allows swappable font implementations
- Face/Glyph interfaces provide shape() for vector paths
- orx-text-writer provides sophisticated layout (alignment, tracking, leading)
- Token-based layout enables pre-render inspection
- GlyphOutput capture for post-render effects
- Kerning table support

**Weaknesses**:
- FontImageMap texture binding conflicts ([#394](https://github.com/openrndr/openrndr/issues/394))
- STB TrueType lacks HarfBuzz-level shaping
- No variable font support

---

### nannou
**Approach**: RustType for font parsing + lyon for path tessellation

**Key files**:
- `nannou/src/text/font.rs`
- `nannou/src/text/glyph.rs`
- `nannou/src/draw/primitive/text.rs`

```rust
// Font loading
let font = text::font::from_file("assets/fonts/NotoSans.ttf")?;

// Builder pattern for text
draw.text("Hello nannou")
    .font(font.clone())
    .font_size(24)
    .color(BLACK)
    .wh(win_rect.wh())
    .center_justify()
    .align_middle_y();

// Per-glyph colors
draw.text(text)
    .glyph_colors(vec![BLUE, BLUE, RED, RED, GREEN]);

// Path extraction
let text_layout = text("nannou")
    .font_size(128)
    .build(win_rect);

draw.path()
    .fill()
    .color(BLACK)
    .events(text_layout.path_events());
```

**Strengths**:
- Builder pattern with method chaining
- Glyph-to-lyon path conversion for fill/stroke
- Iterator-based lazy evaluation
- GPU cache integration (RustType)
- Separate X (Justify) and Y (Align) alignment

**Weaknesses**:
- Incomplete draw.text() in Bevy refactor ([#1003](https://github.com/nannou-org/nannou/issues/1003))
- Memory leaks reported ([#786](https://github.com/nannou-org/nannou/issues/786))
- RustType maintenance status uncertain
- No OpenType feature support ([#364](https://github.com/nannou-org/nannou/issues/364))

---

## Comparison Matrix

| Framework | Font Library | Formats | Glyph Path Access | Text Shaping | GPU Atlas | Kerning |
|-----------|-------------|---------|-------------------|--------------|-----------|---------|
| p5.js | opentype.js | TTF/OTF/WOFF/WOFF2 | textToPoints() | Basic | WebGL textures | Via opentype.js |
| Processing | Java AWT | TTF/OTF/.vlw | None | Java 2D | FontTexture | FontMetrics |
| OpenFrameworks | FreeType | TTF/OTF | getStringAsPoints() | FreeType | Texture atlas | FT_Get_Kerning |
| Cinder | Platform-native + FreeType | TTF/OTF | getGlyphShape() | CoreText/GDI+ | TextureFont | Platform-native |
| openrndr | STB TrueType | TTF/OTF | glyph.shape() | Basic | FontImageMap | kernAdvance() |
| nannou | RustType | TTF/OTF | path_events() | Basic | GPU cache | Via RustType |

| Framework | Variable Fonts | Complex Scripts | Line Wrap | Text Alignment | Per-Glyph Color |
|-----------|---------------|-----------------|-----------|----------------|-----------------|
| p5.js | No ([#5607](https://github.com/processing/p5.js/issues/5607)) | No | Word/Char | H + V | No |
| Processing | No | Limited | Box bounds | H + V | No |
| OpenFrameworks | No | Unicode ranges | Manual | Manual | No |
| Cinder | Via CoreText | Via platform | TextBox | H + V | Yes |
| openrndr | No | Unicode ranges | orx-text-writer | H + V | Via GlyphOutput |
| nannou | No | No | Word/Char | Justify + Align | glyph_colors() |

## Best Practices Extracted

1. **Builder Pattern**: Cinder's TextBox and nannou's draw.text() demonstrate ergonomic configuration APIs:
   ```rust
   draw.text("hello")
       .font_size(24)
       .center_justify()
       .color(WHITE)
   ```

2. **Separate Alignment Axes**: nannou separates horizontal (Justify: Left/Center/Right) from vertical (Align: Start/Middle/End) for clarity.

3. **Lazy Glyph Loading**: Processing's on-demand glyph rendering prevents wasted memory for unused characters.

4. **Token-Based Layout**: OPENRNDR's TextWriter returns `List<TextToken>` before rendering, enabling inspection and transformation.

5. **Path Conversion**: All mature frameworks convert glyphs to vector paths (Bezier curves) for generative applications.

6. **Driver Abstraction**: OPENRNDR's FontDriver interface allows swapping implementations (STB, FreeType, platform-native).

## Anti-Patterns to Avoid

1. **Dual System Confusion**: p5.js's split between opentype.js and CSS @font-face creates user confusion about capabilities.

2. **Fixed Character Sets**: Pre-baking only ASCII/Latin limits international use. Use Unicode ranges or lazy loading.

3. **Platform Rendering Differences**: Cinder's cross-platform inconsistencies show the danger of relying on platform-native APIs without normalization.

4. **Undocumented Leaks**: Memory leaks in font caching (Cinder #524, nannou #786) indicate need for explicit resource management.

5. **Missing Scaling Consideration**: OpenFrameworks' DPI issues show importance of HiDPI-aware design from the start.

## Recommendations for Rust Framework

### Suggested Approach

Use a layered architecture:
1. **Font Parsing**: cosmic-text or fontdue for parsing (actively maintained, pure Rust)
2. **Text Shaping**: rustybuzz (HarfBuzz port) for complex scripts
3. **Path Output**: lyon for tessellation
4. **GPU Rendering**: wgpu texture atlas with glyph caching

### API Sketch

```rust
// Font loading with Into<FontSource> for flexibility
let font = Font::load("assets/font.ttf")?;
let font = Font::load(FontSource::Bytes(bytes))?;
let font = Font::system("Helvetica")?;

// Builder pattern for text configuration
draw.text("Hello")
    .font(&font)
    .size(24.0)
    .color(Color::WHITE)
    .align(HAlign::Center, VAlign::Middle)
    .wrap(Wrap::Word)
    .tracking(1.5)      // Letter spacing
    .leading(1.2);      // Line height multiplier

// Layout inspection before rendering
let layout = Text::layout("Hello")
    .font(&font)
    .size(24.0)
    .wrap_width(200.0)
    .build();

for glyph in layout.glyphs() {
    // Access position, bounds, path
}

// Path extraction for generative use
let path: Path = layout.to_path();
draw.path(&path).fill(Color::BLACK);

// Per-glyph transformation
for (i, glyph) in layout.glyphs().enumerate() {
    let offset = (i as f32 * 0.5 + time).sin() * 10.0;
    draw.glyph(&glyph)
        .offset(0.0, offset)
        .color(rainbow(i));
}
```

### Key Design Decisions

1. **Use `cosmic-text`** for text shaping - actively maintained, supports complex scripts
2. **Separate layout from drawing** - compute layout once, render multiple times
3. **Glyph iteration** - first-class support for per-glyph manipulation
4. **Path extraction** - convert any text to lyon Path for generative effects
5. **Resource management** - explicit Font lifetime with Arc<> sharing

### Trade-offs

- **Pro**: Pure Rust stack avoids C/C++ dependencies
- **Pro**: HarfBuzz-level shaping via rustybuzz
- **Pro**: Clean builder API learned from nannou/Cinder
- **Con**: cosmic-text less mature than FreeType
- **Con**: No variable font support in pure Rust (yet)

### Open Questions

- How to handle font fallback chains for missing glyphs?
- Should layout be mutable for animation, or always rebuild?
- How to expose OpenType features (ligatures, stylistic alternates)?
- Web target: use browser's text shaping or bring own?
