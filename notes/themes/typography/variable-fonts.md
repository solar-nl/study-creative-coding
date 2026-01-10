# Typography Deep Dive: Variable Fonts

> One font file, infinite weights—how does that work?

---

## The Problem: Font Proliferation

Traditional type families are collections of separate font files:

```
Helvetica/
  ├── Helvetica-Light.ttf
  ├── Helvetica-Regular.ttf
  ├── Helvetica-Medium.ttf
  ├── Helvetica-Bold.ttf
  ├── Helvetica-Black.ttf
  ├── Helvetica-LightItalic.ttf
  ├── Helvetica-Italic.ttf
  ├── Helvetica-MediumItalic.ttf
  ├── Helvetica-BoldItalic.ttf
  └── Helvetica-BlackItalic.ttf
```

That's 10 files just for basic weights and italics. Want condensed versions? Double it. Extended? Triple. Some professional families have over 100 individual font files.

For creative coding, this means:
- **Loading time:** More files to fetch
- **Memory:** Each font occupies GPU texture space
- **Animation constraints:** You can only jump between discrete weights, not smoothly interpolate

Variable fonts solve this by putting all variations into a single file, with **continuous interpolation** between them.

---

## How Variable Fonts Work

The magic happens through **variation axes**. Think of them like sliders in a design tool:

```
                               Variable Font
                                    │
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
               Weight (wght)   Width (wdth)    Slant (slnt)
                    │               │               │
            ┌───────┼───────┐   ────┼────      ────┼────
            │       │       │   │       │      │       │
          100     400     900  75     125   -12      0
         Thin  Regular  Black  Cond.  Exp.  Italic  Upright
```

A single font file contains **master outlines** at extreme positions (e.g., the lightest weight and heaviest weight). The font engine interpolates between them for any value in between.

### The fvar Table

Variable fonts store their axis definitions in the `fvar` (Font Variations) table:

```
┌─────────────────────────────────────────────────────────┐
│  fvar Table Contents                                     │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  Axis 1: wght (Weight)                                   │
│    ├── minValue: 100 (Thin)                              │
│    ├── defaultValue: 400 (Regular)                       │
│    └── maxValue: 900 (Black)                             │
│                                                          │
│  Axis 2: wdth (Width)                                    │
│    ├── minValue: 75 (Condensed)                          │
│    ├── defaultValue: 100 (Normal)                        │
│    └── maxValue: 125 (Extended)                          │
│                                                          │
│  Named Instances:                                        │
│    ├── "Light" → wght: 300                               │
│    ├── "Regular" → wght: 400                             │
│    ├── "Bold" → wght: 700                                │
│    └── "Bold Condensed" → wght: 700, wdth: 75            │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

**Named instances** are pre-defined positions on the axes—like bookmarks the type designer provided. But you're not limited to them; you can request any coordinate within the axes' ranges.

### Registered vs. Custom Axes

OpenType defines five **registered axes** with standardized semantics:

| Tag | Name | Typical Range | What It Controls |
|-----|------|---------------|------------------|
| `wght` | Weight | 100–900 | Thin to Black |
| `wdth` | Width | 75–125 | Condensed to Extended |
| `ital` | Italic | 0–1 | Upright to Italic (binary) |
| `slnt` | Slant | -20–0 | Oblique angle in degrees |
| `opsz` | Optical Size | 8–144 | Optimized for point size |

Foundries can also define **custom axes** for creative effects:

- `GRAD` — Grade (weight without width change)
- `XTRA` — Counter width
- `YTAS` — Ascender height
- `CASL` — Casual vs. formal (for scripts like Arabic)

Custom axis tags must start with an uppercase letter: `GRAD`, not `grad`.

---

## Normalized Coordinates: The Implementation Detail

Internally, variation coordinates are stored as **normalized values** between -1.0 and 1.0:

```
User Space (what you specify):    100 ←───────→ 400 ←───────→ 900
                                   │            │            │
                                   ▼            ▼            ▼
Normalized Space (internal):     -1.0          0.0          1.0
```

This matters when working directly with font libraries. The [swash](https://github.com/dfrg/swash) library in Rust offers two ways to set axes:

**By tag and value (user-friendly but slower):**
```rust
let mut scaler = Scaler::new(&font)
    .variations(&[("wght", 650.0)])  // User-space coordinate
    .build();
```

**By normalized coordinates (faster):**
```rust
// Pre-compute normalized coordinates once
let coords = variation.normalize(650.0);  // → 0.416...

let mut scaler = Scaler::new(&font)
    .normalized_coords(&[coords])  // Skip conversion each frame
    .build();
```

The second approach matters for animation—you can interpolate normalized values directly without re-normalizing each frame.

---

## What Creative Coding Frameworks Expose

Disappointingly little:

| Framework | Variable Font Support |
|-----------|----------------------|
| p5.js | None—uses browser CSS, doesn't expose to `textToPoints()` |
| Processing | None—bitmap approach incompatible with variable fonts |
| OpenFrameworks | None—FreeType supports it, but OF doesn't wrap it |
| Cinder | None—platform APIs support it, but not exposed |
| openrndr | None—STB TrueType doesn't support variable fonts |
| nannou | None—RustType has limited support, not exposed |

This is a significant gap. Variable fonts enable effects that are otherwise impossible:

```
Frame 1:  Weight 400  →  "Hello"
Frame 2:  Weight 420  →  "Hello" (slightly bolder)
Frame 3:  Weight 440  →  "Hello" (bolder still)
...
Frame 30: Weight 900  →  "Hello" (maximum black)
```

Smooth weight animation, impossible with traditional fonts, becomes trivial.

---

## The Rust Ecosystem: swash

The [swash](https://github.com/dfrg/swash) library provides the most complete variable font support in the Rust ecosystem:

```rust
use swash::{FontRef, Setting, Variation};

// Load font
let font_data = std::fs::read("Inter-Variable.ttf")?;
let font = FontRef::from_index(&font_data, 0)?;

// Query available axes
for axis in font.variations() {
    println!(
        "Axis: {} ({}) range: {}–{} default: {}",
        axis.tag(),
        axis.name(),
        axis.min_value(),
        axis.max_value(),
        axis.default_value()
    );
}

// Set variation values
let settings = [
    Setting::new(swash::tag_from_bytes(b"wght"), 650.0),
    Setting::new(swash::tag_from_bytes(b"wdth"), 87.5),
];

// Build scaler with variations
let mut scaler = font.scaler(&settings)
    .size(24.0)
    .build();
```

### Integration with cosmic-text

[cosmic-text](https://github.com/pop-os/cosmic-text) uses swash under the hood but doesn't currently expose variation axes to users. There's an [open issue #406](https://github.com/pop-os/cosmic-text/issues/406) discussing this—variable fonts work, but the UI controls for axes aren't wired up.

This means: the capability exists at the library level, but you'd need to patch or fork cosmic-text to expose it.

---

## API Design for Variable Fonts

How should a creative coding framework expose variable fonts? Here are patterns to consider:

### Pattern 1: Discrete Axis Setting

```rust
let font = Font::load("Inter-Variable.ttf")?
    .with_variation("wght", 650.0)
    .with_variation("wdth", 87.5);

draw.text("Hello").font(&font);
```

**Pro:** Simple, familiar API.
**Con:** Can't animate without recreating font object.

### Pattern 2: Per-Draw Variations

```rust
let font = Font::load("Inter-Variable.ttf")?;

draw.text("Hello")
    .font(&font)
    .weight(400.0 + t * 500.0)  // Animate from 400 to 900
    .width(100.0);
```

**Pro:** Animation-friendly.
**Con:** Must map axis tags to method names; custom axes awkward.

### Pattern 3: Raw Axis Access

```rust
let font = Font::load("Inter-Variable.ttf")?;

draw.text("Hello")
    .font(&font)
    .variation("wght", lerp(400.0, 900.0, t))
    .variation("wdth", lerp(100.0, 75.0, t))
    .variation("CASL", 0.5);  // Custom axis works too
```

**Pro:** Complete flexibility; custom axes just work.
**Con:** Users must know axis tags.

### Pattern 4: Named Instance Shorthand

```rust
let font = Font::load("Inter-Variable.ttf")?;

// Use designer's named instance
draw.text("Hello")
    .font(&font)
    .instance("Bold Condensed");

// Or access raw axes
draw.text("Hello")
    .font(&font)
    .variation("wght", 700.0)
    .variation("wdth", 75.0);
```

**Pro:** Best of both worlds; discoverability through named instances.
**Con:** More complex implementation.

---

## Animation Considerations

Variable fonts are perfect for kinetic typography. Consider these patterns:

### Per-Character Weight Waves

```rust
for (i, glyph) in layout.glyphs().enumerate() {
    let phase = (time + i as f32 * 0.2).sin();
    let weight = 400.0 + phase * 250.0;  // Oscillate 150–650

    draw.glyph(&glyph)
        .variation("wght", weight);
}
```

### Responsive Weight Based on Size

Variable fonts often include an `opsz` (optical size) axis for this:

```rust
fn optimal_weight(point_size: f32) -> f32 {
    // Smaller sizes need heavier weight for legibility
    if point_size < 12.0 {
        450.0
    } else if point_size < 24.0 {
        400.0
    } else {
        380.0  // Large sizes can be lighter
    }
}

draw.text("Hello")
    .size(point_size)
    .variation("wght", optimal_weight(point_size))
    .variation("opsz", point_size);  // If font has optical sizing
```

### Caching for Performance

Variable fonts require re-rasterizing glyphs when axes change. For animation:

```rust
// BAD: Re-rasterizes every frame
for frame in 0..60 {
    let weight = 400.0 + frame as f32 * 8.33;
    draw.text("Hello").variation("wght", weight);
}

// GOOD: Pre-cache discrete steps
let weights: Vec<f32> = (0..10).map(|i| 400.0 + i as f32 * 50.0).collect();
let cached_glyphs: Vec<_> = weights.iter()
    .map(|w| cache_glyphs(&font, *w))
    .collect();

// Animate between cached versions
let weight_index = ((time * 10.0).floor() as usize).min(9);
draw.text("Hello").cached(&cached_glyphs[weight_index]);
```

---

## CSS Integration (for Web Targets)

When targeting WASM/web, browsers handle variable fonts natively:

```css
@font-face {
    font-family: 'Inter Variable';
    src: url('Inter-Variable.woff2') format('woff2-variations');
    font-weight: 100 900;  /* Declare weight range */
}

.animated-text {
    font-family: 'Inter Variable';
    font-weight: var(--weight);  /* Animate via CSS variable */
    font-variation-settings: 'wdth' var(--width), 'CASL' var(--casual);
}
```

For a WASM creative coding framework, you might want to:
1. Use CSS for basic variable font support (free, optimized)
2. Bring your own (swash) only when you need glyph-level access

---

## Recommendations for a Rust Framework

1. **Support variable fonts from day one.** The complexity is mostly in the font library (swash handles it); exposing axes is straightforward.

2. **Use Pattern 3 (raw axis access)** as the foundation—it's the most flexible. Layer convenience methods on top:

```rust
// Foundation: raw axis access
draw.text("Hello").variation("wght", 650.0);

// Convenience: common axes get methods
draw.text("Hello").weight(650.0);  // Maps to "wght"

// Discovery: list available axes
for axis in font.axes() {
    println!("{}: {} ({}–{})", axis.tag, axis.name, axis.min, axis.max);
}
```

3. **Cache normalized coordinates** for animation. Let users work in user-space values but convert to normalized internally:

```rust
let font = Font::load("variable.ttf")?;

// Pre-normalize for animation
let weight_range = font.axis("wght").unwrap();
let normalized = |w| weight_range.normalize(w);

// During animation, use pre-computed values
let coords = [normalized(lerp(400.0, 900.0, t))];
draw.text("Hello").normalized_coords(&coords);
```

4. **Don't forget named instances.** They're a great way for users to discover what a font can do:

```rust
for instance in font.named_instances() {
    println!("{}: {:?}", instance.name, instance.coordinates);
}
// Output:
// "Light": {"wght": 300}
// "Regular": {"wght": 400}
// "Bold Condensed": {"wght": 700, "wdth": 75}
```

---

## Sources

- [OpenType fvar Table Spec](https://learn.microsoft.com/en-us/typography/opentype/spec/fvar) — The authoritative reference
- [Variable Fonts Introduction](https://medium.com/variable-fonts/https-medium-com-tiro-introducing-opentype-variable-fonts-12ba6cd2369) — John Hudson's excellent overview
- [Google Fonts Variable Guide](https://googlefonts.github.io/gf-guide/variable.html) — Practical implementation guide
- [swash Documentation](https://docs.rs/swash/latest/swash/) — Rust library with full variation support
- [cosmic-text Issue #406](https://github.com/pop-os/cosmic-text/issues/406) — Variable font UI discussion
- [State of Text Rendering 2024](https://behdad.org/text2024/) — Industry overview including variable fonts

---

*This document is part of the [Typography Theme](typography.md) research.*
