# Typography Deep Dive: WebAssembly Text Shaping

> Should you use the browser's text engine, or bring your own?

## Key Insight

> **The core challenge:** Browser text APIs are free and handle complex scripts, but they are a black box—you cannot access glyph positions or paths, making creative typography impossible without bundling your own shaper (adding 100KB+ gzipped).

---

## The Dilemma: Two Paths to Text in the Browser

When you compile a Rust creative coding framework to WebAssembly, you face a choice that doesn't exist on native platforms:

**Path A: Use the browser's built-in text rendering**
- It's already there—zero bundle size impact
- Highly optimized by browser vendors
- Handles complex scripts automatically
- But it's a black box: you can't access glyph positions or paths

**Path B: Bring your own text shaping (rustybuzz, cosmic-text)**
- Full control over every glyph
- Consistent behavior across browsers and platforms
- Enables creative manipulation
- But adds hundreds of kilobytes to your WASM bundle

Neither path is obviously correct. Let's explore the trade-offs.

---

## What "Text Shaping" Actually Means

Before diving into implementation, let's clarify what text shaping does. It's the process of turning a string into positioned glyphs:

```
Input:   "Hello"
         │
         ▼
┌────────────────────────────────────────┐
│  Text Shaping                           │
│                                         │
│  1. Map characters to glyphs            │
│     'H' → glyph #72, 'e' → glyph #101   │
│                                         │
│  2. Apply substitutions                 │
│     "fi" → single ligature glyph        │
│                                         │
│  3. Calculate positions                 │
│     glyph #72 at x=0, width=15          │
│     glyph #101 at x=15, width=10        │
│     (with kerning adjustments)          │
│                                         │
└────────────────────────────────────────┘
         │
         ▼
Output:  [(glyph_id: 72, x: 0, y: 0),
          (glyph_id: 101, x: 14, y: 0),  // kerned!
          (glyph_id: 108, x: 23, y: 0),
          ...]
```

For English text, this is relatively simple. For Arabic (right-to-left, contextual letter forms), Hindi (complex ligatures, reordering), or emoji sequences—it's enormously complicated.

---

## Path A: Using the Browser's Text Engine

### The Canvas API

From WASM, you can call browser APIs through `web-sys`:

```rust
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

// Get canvas context (setup code omitted)
let context: CanvasRenderingContext2d = /* ... */;

// Draw text using browser's engine
context.set_font("24px Inter");
context.fill_text("Hello, WebAssembly!", 50.0, 100.0)?;
```

That's it. The browser handles:
- Font loading and fallback
- Complex script shaping (Arabic, Hindi, CJK)
- Kerning and ligatures
- Platform-appropriate rendering

### Measuring Text

The browser can tell you how wide text will be:

```rust
let metrics = context.measure_text("Hello")?;
let width = metrics.width();

// Extended metrics (not all browsers support all of these)
let ascent = metrics.actual_bounding_box_ascent();
let descent = metrics.actual_bounding_box_descent();
```

**Gotcha:** `TextMetrics` access through wasm-bindgen has overhead. For performance-critical code:

```rust
// Define custom binding to avoid serde overhead
#[wasm_bindgen]
extern "C" {
    pub type ExtendedTextMetrics;

    #[wasm_bindgen(method, getter)]
    pub fn width(this: &ExtendedTextMetrics) -> f64;

    #[wasm_bindgen(method, getter)]
    pub fn actualBoundingBoxAscent(this: &ExtendedTextMetrics) -> f64;
}

// Use unchecked_into (faster than into_serde)
let metrics = context.measure_text("Hello")?;
let extended: ExtendedTextMetrics = metrics.unchecked_into();
```

### What You Can't Do

The browser's text engine is a black box. You can draw text and measure it, but you **cannot**:

- Get individual glyph positions
- Access glyph outlines as paths
- Apply per-character effects
- Get consistent positioning across browsers
- Control exactly which font is used for fallback

For basic UI text, this doesn't matter. For creative typography—where you want letters to dance, explode, or follow curves—it's a showstopper.

---

## Path B: Bringing Your Own Shaping

### rustybuzz: HarfBuzz in Pure Rust

[rustybuzz](https://github.com/harfbuzz/rustybuzz) is a port of HarfBuzz (the industry-standard shaper) to Rust. It passes 2,221 of 2,252 HarfBuzz shaping tests.

Performance is excellent: **280,000+ glyphs per second** on typical hardware—about 20x faster than opentype.js (JavaScript).

```rust
use rustybuzz::{Face, UnicodeBuffer};

// Load font
let font_data = include_bytes!("Inter.ttf");
let face = Face::from_slice(font_data, 0)?;

// Shape text
let mut buffer = UnicodeBuffer::new();
buffer.push_str("Hello");

let glyph_buffer = rustybuzz::shape(&face, &[], buffer);

// Access glyph positions
for (info, pos) in glyph_buffer.glyph_infos()
    .iter()
    .zip(glyph_buffer.glyph_positions())
{
    println!(
        "glyph {} at ({}, {}), advance: {}",
        info.glyph_id,
        pos.x_offset,
        pos.y_offset,
        pos.x_advance
    );
}
```

### WASM Support

rustybuzz added official WASM bindings in v0.18.0 (August 2024):

```bash
npm install rustybuzz-wasm
```

```javascript
import init, { shape } from 'rustybuzz-wasm';

await init();
const glyphs = shape(fontData, "Hello", {});
```

### cosmic-text: The All-in-One Solution

If you need more than just shaping—layout, fallback, rendering—[cosmic-text](https://github.com/pop-os/cosmic-text) bundles it all:

```rust
use cosmic_text::{FontSystem, Buffer, Metrics};

// Font system handles discovery and fallback
let mut font_system = FontSystem::new();

// Buffer manages text and layout
let mut buffer = Buffer::new(&mut font_system, Metrics::new(24.0, 28.0));
buffer.set_text(&mut font_system, "Hello 世界", Attrs::new(), Shaping::Advanced);

// Layout is computed
for run in buffer.layout_runs() {
    for glyph in run.glyphs {
        // glyph.x, glyph.y, glyph.font_id, glyph.glyph_id
    }
}
```

**WASM support:** cosmic-text compiles to WASM, but has font fallback issues—it can panic if no default fonts are embedded. You need to bundle fonts or implement custom fallback.

### fontdue: Rasterization Only

[fontdue](https://github.com/mooman219/fontdue) is smaller but doesn't do shaping—it just rasterizes glyphs:

```rust
use fontdue::Font;

let font = Font::from_bytes(font_data, fontdue::FontSettings::default())?;
let (metrics, bitmap) = font.rasterize('A', 24.0);
```

Useful if you're handling layout yourself and just need pixel data.

---

## Bundle Size: The Elephant in the Room

Here's what bringing your own shaping costs:

| Library | Unoptimized | With wasm-opt -Oz | Gzipped |
|---------|-------------|-------------------|---------|
| rustybuzz | 600KB–1MB | 300–400KB | 80–120KB |
| cosmic-text | 800KB–1.5MB | 400–600KB | 150–250KB |
| fontdue (rasterization only) | ~200KB | ~100KB | ~50KB |

For context:
- A typical WASM creative coding framework (without text) might be 500KB–2MB gzipped
- Adding rustybuzz increases bundle by 15–25%
- Adding cosmic-text increases bundle by 30–50%

### Optimization Techniques

**Cargo build flags:**
```toml
[profile.release]
opt-level = "z"     # Optimize for size
lto = true          # Link-time optimization
codegen-units = 1   # Better optimization, slower compile
strip = true        # Strip debug symbols
```

**Post-build optimization:**
```bash
wasm-opt -Oz -o output.wasm input.wasm
```

**Feature flags:** Disable features you don't need:
```toml
[dependencies]
cosmic-text = { version = "0.11", default-features = false }
```

---

## The Hybrid Approach

The best solution might be **both**—use the browser for simple cases, bring your own for creative manipulation:

```
┌─────────────────────────────────────────────────────┐
│  Hybrid Text Strategy                                │
├─────────────────────────────────────────────────────┤
│                                                      │
│  ┌─────────────────┐     ┌─────────────────┐        │
│  │ Browser Canvas  │     │ rustybuzz/WASM  │        │
│  │ (zero cost)     │     │ (280KB gzipped) │        │
│  └────────┬────────┘     └────────┬────────┘        │
│           │                       │                  │
│           ▼                       ▼                  │
│  ┌─────────────────┐     ┌─────────────────┐        │
│  │ Simple UI text  │     │ Creative text   │        │
│  │ Labels, buttons │     │ Animations,     │        │
│  │ User input      │     │ path effects,   │        │
│  │ Static content  │     │ per-glyph style │        │
│  └─────────────────┘     └─────────────────┘        │
│                                                      │
└─────────────────────────────────────────────────────┘
```

### Implementation Pattern

```rust
// Feature-gated: only include rustybuzz when needed
#[cfg(feature = "creative-text")]
use rustybuzz;

pub enum TextMode {
    /// Use browser's Canvas API (fast, zero bundle cost)
    Browser,
    /// Use rustybuzz for full glyph access (adds ~100KB gzipped)
    Creative,
}

impl TextRenderer {
    pub fn draw_text(&self, text: &str, x: f32, y: f32, mode: TextMode) {
        match mode {
            TextMode::Browser => {
                // Call canvas.fillText()
                self.canvas_context.fill_text(text, x as f64, y as f64).ok();
            }
            #[cfg(feature = "creative-text")]
            TextMode::Creative => {
                // Shape with rustybuzz, render each glyph
                let glyphs = self.shape_text(text);
                for glyph in glyphs {
                    self.render_glyph(glyph, x, y);
                }
            }
        }
    }
}
```

---

## When to Use Each Approach

### Use Browser Canvas When:

- Drawing UI elements (buttons, labels, status text)
- Text doesn't need per-character manipulation
- Bundle size is critical
- You need complex script support without effort
- Cross-browser consistency isn't critical

### Use Your Own Shaping When:

- Animating individual characters
- Drawing text along paths
- Applying effects per-glyph (color, rotation, scale)
- Converting text to vector paths
- Needing consistent positioning across browsers/platforms
- Building a tool where users expect precise control

---

## Performance Comparison

Real-world benchmarks for text rendering in WASM:

| Operation | Browser Canvas | rustybuzz | Notes |
|-----------|---------------|-----------|-------|
| Shape "Hello World" | N/A (black box) | ~0.03ms | rustybuzz is fast |
| Draw 100 words | ~0.5ms | ~2ms | Browser batches better |
| Per-glyph animation | Not possible | ~5ms/frame | Worth the cost for effects |
| Initial load | 0ms | 10–100ms | WASM module parsing |
| Memory usage | Shared with browser | +5–20MB | Depends on fonts loaded |

**Takeaway:** Browser rendering is faster for simple cases. Custom shaping wins when you need the capabilities it provides.

---

## Industry Examples

Who uses what approach?

| Product | Approach | Why |
|---------|----------|-----|
| Figma | Custom (C++/WASM) | Needs precise, consistent rendering |
| Photopea | harfbuzzjs (WASM) | Professional tool, users expect control |
| Canva | Hybrid | Browser for preview, custom for export |
| Google Docs | Browser | Editing doesn't need glyph access |
| Prezi | Custom (HarfBuzz) | Animation requires glyph positions |

---

## Recommendations for a Rust Framework

### 1. Default to Browser for Web Target

When compiling to WASM, use Canvas API by default:

```rust
#[cfg(target_arch = "wasm32")]
fn draw_text_default(&self, text: &str, x: f32, y: f32) {
    self.canvas.fill_text(text, x, y);
}
```

### 2. Feature-Gate Creative Text

Don't force the bundle cost on users who don't need it:

```toml
[features]
default = []
creative-text = ["rustybuzz"]  # Opt-in to WASM shaping
```

### 3. Provide Clear Guidance

Document when users should enable the feature:

```rust
/// # Feature: `creative-text`
///
/// Enable this feature if you need:
/// - Per-character animation or styling
/// - Text along paths
/// - Converting text to vector shapes
/// - Consistent cross-browser glyph positions
///
/// Adds approximately 100KB (gzipped) to your WASM bundle.
pub struct CreativeText { /* ... */ }
```

### 4. Consider Progressive Loading

For web apps, load the shaping library on demand:

```rust
// Initial load: no text shaping
// When user needs creative text features:
let shaper = load_shaper_wasm().await?;
```

### 5. Cache Aggressively

Shaping results should be cached, especially for animated text:

```rust
struct ShapedTextCache {
    entries: HashMap<(String, FontId, f32), ShapedText>,
}

impl ShapedTextCache {
    fn get_or_shape(&mut self, text: &str, font: FontId, size: f32) -> &ShapedText {
        self.entries.entry((text.to_string(), font, size))
            .or_insert_with(|| shape_text(text, font, size))
    }
}
```

---

## The Future: What's Coming

The text rendering landscape is evolving:

**Wasm-fonts proposal:** Would enable more expressive fonts in WASM contexts.

**HarfBuzz drawing API:** Expected in 2025, would enable full text rendering in WASM without separate rasterizer.

**Incremental Font Transfer:** Streaming fonts over the network, reducing initial load times.

**Browser improvements:** Chrome, Firefox, and Safari continue improving Canvas text performance.

For now, the hybrid approach—browser for simple cases, custom for creative—remains the pragmatic choice.

---

## Sources

- [rustybuzz-wasm npm](https://www.npmjs.com/package/rustybuzz-wasm) — Official WASM bindings
- [rustybuzz GitHub](https://github.com/harfbuzz/rustybuzz) — The HarfBuzz port
- [cosmic-text GitHub](https://github.com/pop-os/cosmic-text) — All-in-one text handling
- [wasm-bindgen Canvas Guide](https://rustwasm.github.io/docs/wasm-bindgen/examples/2d-canvas.html) — Using Canvas from WASM
- [State of Text Rendering 2024](https://behdad.org/text2024/) — Industry overview
- [Bevy WASM Guide](https://bevy-cheatbook.github.io/platforms/wasm.html) — Practical WASM optimization
- [wasm-bindgen TextMetrics Issue](https://github.com/rustwasm/wasm-bindgen/issues/2069) — Performance optimization

---

*This document is part of the [Typography Theme](typography.md) research.*
