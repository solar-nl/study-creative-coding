# Typography Deep Dive: Font Fallback

> What happens when a font doesn't have the character you need?

---

## The Problem: Fonts Have Holes

You've carefully chosen a beautiful display font for your creative coding project. It renders your title perfectly. Then you add some mathematical symbols, or a user submits text with emoji, or you need to display Japanese kanji alongside English—and suddenly your elegant design shows placeholder boxes: □ □ □

This is the **missing glyph problem**. No single font file contains every character in Unicode (which now has over 150,000). Even "comprehensive" fonts like Noto cover only a subset. When your text contains a character that isn't in the loaded font, something has to happen.

The solution is **font fallback**—automatically trying other fonts until one can render the missing character. But the details of how to implement this are surprisingly nuanced.

---

## How Font Fallback Actually Works

Most people think of fallback as "if Font A doesn't work, use Font B instead." But that's not how good text systems work. They do fallback **per-character**, not per-block:

```
Input:   "Hello こんにちは 👋"
         │      │          │
         ▼      ▼          ▼
Font 1:  "Hello"(Helvetica)
Font 2:         "こんにちは"(Hiragino)
Font 3:                    "👋"(Apple Color Emoji)

Output: Mixed fonts, seamless to the user
```

This means a single line of text might use three or four different fonts—and the user never notices because the system made good choices.

### The Detection Mechanism

How does a system know a font is missing a glyph? At the lowest level, it's about **glyph IDs**:

```
┌─────────────────────────────────────────────────┐
│ Font Lookup Flow                                 │
├─────────────────────────────────────────────────┤
│                                                  │
│  Character 'A' (U+0041)                          │
│       │                                          │
│       ▼                                          │
│  Font's cmap table → Glyph ID 36                 │
│       │                                          │
│       ▼                                          │
│  Glyph ID 36 found? YES → Render it              │
│                                                  │
│  Character '漢' (U+6F22)                         │
│       │                                          │
│       ▼                                          │
│  Font's cmap table → Glyph ID 0                  │
│       │                     ▲                    │
│       ▼                     │                    │
│  Glyph ID 0 means "NOT FOUND"                    │
│       │                                          │
│       ▼                                          │
│  Try next font in fallback chain...              │
│                                                  │
└─────────────────────────────────────────────────┘
```

**Glyph ID 0** is the universal signal for "this font doesn't have this character." Every font reserves ID 0 for the `.notdef` glyph—that little box you see when things go wrong.

---

## Platform-Native Approaches

Operating systems have spent decades building sophisticated fallback systems. Understanding how they work reveals what's possible—and what's hard to replicate.

### macOS: CoreText

Apple's CoreText provides two approaches:

**1. Get the fallback chain upfront:**
```objc
// "Give me all fonts that might substitute for this one"
NSArray *cascadeList = CFBridgingRelease(
    CTFontCopyDefaultCascadeListForLanguages(font, languages)
);
```

**2. Per-character lookup:**
```objc
// "Give me a font that can render this specific string"
CTFontRef fallback = CTFontCreateForString(font, string, range);
```

The second approach is more flexible but has per-call overhead. It's what you'd use when you can't predict what characters you'll encounter.

### Windows: DirectWrite

Microsoft's approach is more complex but equally powerful:

```cpp
// Get system fallback logic
IDWriteFontFallback* fallback;
factory->GetSystemFontFallback(&fallback);

// For each run of text, find which font can render it
fallback->MapCharacters(
    textAnalysis,
    0,
    textLength,
    fontCollection,
    baseFamilyName,
    weight, style, stretch,
    &mappedLength,
    &mappedFont,
    &scale
);
```

DirectWrite can map entire text runs at once, finding the minimal set of fonts needed.

### Linux: fontconfig

The open-source approach uses XML configuration files:

```xml
<fontconfig>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>DejaVu Sans</family>
      <family>Noto Sans CJK</family>
      <family>Noto Color Emoji</family>
    </prefer>
  </alias>
</fontconfig>
```

This is the most explicit—users can see and customize exactly what fonts substitute for what. But it requires system-level configuration.

---

## CSS: The Mental Model Most Developers Know

If you've written CSS, you've already used font fallback:

```css
font-family: "My Custom Font", "Helvetica Neue", Helvetica, Arial, sans-serif;
```

This is a **fallback chain**. The browser tries fonts left to right, per-character. The final `sans-serif` is a **generic family** that maps to the OS default.

What many developers don't realize: this happens *per character*, not per element. The browser might pull glyphs from three different fonts in the same `<p>` tag.

Modern CSS adds metric overrides to prevent layout shift:

```css
@font-face {
  font-family: "Fallback Font";
  src: local("Helvetica");
  ascent-override: 105%;   /* Match primary font's metrics */
  descent-override: 20%;
  line-gap-override: 0%;
}
```

This ensures that when the browser substitutes fonts, the line height stays consistent.

---

## The Rust Ecosystem: cosmic-text

For a Rust creative coding framework, [cosmic-text](https://github.com/pop-os/cosmic-text) provides the most complete fallback implementation.

### The Fallback Trait

cosmic-text defines a `Fallback` trait that lets you customize behavior:

```rust
pub trait Fallback {
    fn get(&self, character: char, cmap_ids: &[u16]) -> Option<FallbackFont>;
}
```

The library ships with platform-specific fallback lists borrowed from Chromium and Firefox—years of refinement on what fonts to try for which scripts.

### Granularity Options

cosmic-text supports three fallback granularities:

**Per-character** (most flexible):
```rust
// Each character can come from a different font
"Hello 世界" → [Helvetica, Helvetica, Helvetica, ..., Noto Sans CJK, ...]
```

**Per-line** (compromise):
```rust
// Font can change between lines, but consistent within a line
Line 1: all Helvetica
Line 2: all Noto Sans CJK
```

**Per-locale** (for international text):
```rust
// Choose fonts based on language tag
FontSystem::new()
    .with_locale("ja")  // Japanese locale
    // Will prefer Japanese fonts even for Han characters
```

The per-locale option matters because of **Han unification**—Chinese, Japanese, and Korean share many characters that look slightly different in each culture. Without locale hints, you might get the "wrong" variant.

---

## HarfBuzz: The Shaping Perspective

When using HarfBuzz (or rustybuzz), fallback detection integrates with the shaping loop:

```
┌──────────────────────────────────────────────────────────┐
│  HarfBuzz Fallback Loop                                   │
├──────────────────────────────────────────────────────────┤
│                                                           │
│  1. Shape text with primary font                          │
│     │                                                     │
│     ▼                                                     │
│  2. Scan output buffer for glyph_id == 0                  │
│     │                                                     │
│     ├── All glyphs found? DONE                            │
│     │                                                     │
│     ▼                                                     │
│  3. Identify clusters with missing glyphs                 │
│     │                                                     │
│     ▼                                                     │
│  4. For each missing cluster:                             │
│     │   a. Get fallback font from font system             │
│     │   b. Re-shape that cluster                          │
│     │   c. Insert shaped result into output               │
│     │                                                     │
│     ▼                                                     │
│  5. Repeat until no glyph_id == 0 remains                 │
│                                                           │
└──────────────────────────────────────────────────────────┘
```

The key insight: **you re-shape with the fallback font**, you don't just swap glyphs. This matters for complex scripts where context affects rendering.

```rust
// Pseudocode for the fallback loop
let mut buffer = shape_text(&primary_font, text);

loop {
    let missing = buffer.glyphs()
        .filter(|g| g.glyph_id == 0)
        .collect::<Vec<_>>();

    if missing.is_empty() {
        break;
    }

    for cluster in missing.clusters() {
        if let Some(fallback) = find_fallback_font(cluster.chars()) {
            let shaped = shape_text(&fallback, cluster.text());
            buffer.replace_cluster(cluster, shaped);
        }
    }
}
```

---

## What the Creative Coding Frameworks Do

Most creative coding frameworks... don't do much:

| Framework | Fallback Support |
|-----------|------------------|
| p5.js | Browser handles it for `text()`, not for `textToPoints()` |
| Processing | None—if the font lacks a glyph, you get `.notdef` |
| OpenFrameworks | None—you manually specify Unicode ranges to load |
| Cinder | Platform-native (but only for TextBox, not TextureFont) |
| openrndr | None—single font per text draw |
| nannou | None—uses whatever RustType returns |

This is actually reasonable for creative coding. When you're designing visuals, you typically control the text and can ensure your font covers it. Fallback matters more for user-input scenarios.

---

## API Design Considerations

If you're building a Rust framework that supports fallback, here are patterns to consider:

### Pattern 1: Explicit Fallback Stack

```rust
let fonts = FontStack::new()
    .primary("MyDisplayFont.ttf")
    .fallback("NotoSans.ttf")
    .fallback("NotoSansCJK.ttf")
    .fallback("NotoColorEmoji.ttf")
    .system_fallback(true);  // Use OS as last resort

draw.text("Hello 世界 👋").fonts(&fonts);
```

**Pro:** User has full control over what fonts are used.
**Con:** User must know what fonts they need.

### Pattern 2: Automatic System Fallback

```rust
let font = Font::load("MyDisplayFont.ttf")?
    .with_system_fallback();  // Let OS handle missing glyphs

draw.text("Hello 世界 👋").font(&font);
```

**Pro:** Just works for most text.
**Con:** Results vary by platform; might get unexpected fonts.

### Pattern 3: Fail-Fast with Diagnostics

```rust
let font = Font::load("MyDisplayFont.ttf")?;

// Check coverage before drawing
let missing = font.missing_characters("Hello 世界 👋");
if !missing.is_empty() {
    println!("Font missing: {:?}", missing);
    // User can decide what to do
}
```

**Pro:** No surprises; user knows exactly what's happening.
**Con:** More work for the user; might seem unfriendly.

---

## Performance Implications

Font fallback isn't free:

| Operation | Cost |
|-----------|------|
| Check if glyph exists | Fast (cmap lookup) |
| Find fallback font | Moderate (iterate fonts, check cmaps) |
| Re-shape with new font | Expensive (full shaping pass) |
| Render with multiple fonts | Memory cost (multiple atlases) |

For real-time creative coding, you generally want to **pre-compute fallback** during setup, not during animation. cosmic-text's shape run cache helps with this.

---

## Recommendations for a Rust Framework

Based on this research:

1. **Use cosmic-text's Fallback trait** rather than implementing from scratch. It embeds years of browser fallback knowledge.

2. **Default to per-character fallback** for text that might contain mixed scripts.

3. **Provide an escape hatch** for creative coders who want single-font rendering (faster, predictable).

4. **Cache aggressively**—once you know which fonts handle which characters, remember it.

5. **Consider locale awareness** if you're targeting international users. Han unification is a real source of visual bugs.

```rust
// Proposed API
let font_system = FontSystem::new()
    .with_locale("en")
    .with_fallback_fonts(&["Noto Sans", "Noto Sans CJK", "Noto Emoji"]);

let text_buffer = Buffer::new(&font_system)
    .set_text("Hello 世界 👋")
    .set_size(24.0);

// Fallback happens during shaping, cached for reuse
text_buffer.shape();
```

---

## Sources

- [cosmic-text GitHub](https://github.com/pop-os/cosmic-text) — Pure Rust text handling with built-in fallback
- [CSS font-family MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/font-family) — How browser fallback works
- [Chrome Improved Font Fallbacks](https://developer.chrome.com/blog/font-fallbacks) — Metric override technique
- [HarfBuzz Missing Glyphs Discussion](https://lists.freedesktop.org/archives/harfbuzz/2015-May/004854.html) — Why glyph_id == 0 means missing
- [DirectWrite Documentation](https://learn.microsoft.com/en-us/windows/win32/directwrite/introducing-directwrite) — Windows fallback API
- [Mozilla Font Fallback Investigation](https://bugzilla.mozilla.org/show_bug.cgi?id=1238863) — CoreText fallback deep dive

---

*This document is part of the [Typography Theme](typography.md) research.*
