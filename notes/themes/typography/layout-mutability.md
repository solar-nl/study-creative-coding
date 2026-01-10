# Typography Deep Dive: Layout Mutability

> Should text layouts be mutable for animation, or rebuilt every frame?

## Key Insight

> **The core challenge:** Text shaping is expensive but reading glyph positions is free—so the optimal pattern is immutable layouts with transforms applied at draw time, which also happens to align perfectly with Rust's ownership model.

---

## The Question

When animating text—say, a wave effect where each character bobs up and down—you need to modify glyph positions every frame. This creates a design question:

**Option A: Mutable Layout**
```rust
let mut layout = TextLayout::new("Hello");
layout.shape(&font);

// During animation loop
for frame in 0..60 {
    for (i, glyph) in layout.glyphs_mut().enumerate() {
        glyph.y_offset = (frame as f32 * 0.1 + i as f32 * 0.3).sin() * 10.0;
    }
    draw(&layout);
}
```

**Option B: Immutable Layout + Transform**
```rust
let layout = TextLayout::new("Hello").shape(&font);  // Immutable after shaping

// During animation loop
for frame in 0..60 {
    for (i, glyph) in layout.glyphs().enumerate() {
        let offset_y = (frame as f32 * 0.1 + i as f32 * 0.3).sin() * 10.0;
        draw_glyph(&glyph, glyph.x, glyph.y + offset_y);  // Transform at draw time
    }
}
```

**Option C: Rebuild Every Frame**
```rust
// During animation loop
for frame in 0..60 {
    let layout = TextLayout::new("Hello")
        .shape(&font)
        .with_per_glyph_offset(|i| {
            (frame as f32 * 0.1 + i as f32 * 0.3).sin() * 10.0
        });
    draw(&layout);
}
```

Each approach has trade-offs. Let's explore what real systems do and why.

---

## What Existing Systems Choose

### Android: StaticLayout vs DynamicLayout

Android has two text layout classes that exemplify this tension:

**StaticLayout:** Immutable after creation. If text changes, you create a new one.

```java
// Layout computed once
StaticLayout layout = StaticLayout.Builder
    .obtain(text, 0, text.length(), paint, width)
    .build();

// Draw it (can't modify glyph positions)
layout.draw(canvas);
```

**DynamicLayout:** Watches the underlying text for changes and re-layouts automatically.

```java
// Text is a SpannableStringBuilder that can be mutated
DynamicLayout layout = new DynamicLayout(
    text,           // Can be edited
    paint,
    width,
    alignment,
    spacingMult,
    spacingAdd,
    includepad
);

// When text changes, layout updates automatically
text.replace(0, 5, "Goodbye");  // Layout re-computes affected regions
```

**Android's recommendation:** Use `StaticLayout` unless you're building a text editor. `DynamicLayout` has overhead from watching for changes.

### CSS/Web: The Reflow Model

Browsers treat text layout as part of the document layout, which is:
- Expensive to compute
- Cached aggressively
- Invalidated when text, font, or container changes

For animation, browsers recommend **not** animating properties that trigger layout (like `font-size` or `width`). Instead, animate `transform`:

```css
/* BAD: Triggers layout recalculation every frame */
@keyframes bad {
    0%   { font-size: 16px; }
    100% { font-size: 24px; }
}

/* GOOD: GPU-accelerated, no layout recalculation */
@keyframes good {
    0%   { transform: scale(1); }
    100% { transform: scale(1.5); }
}
```

The FLIP technique (First, Last, Invert, Play) extends this: compute the layout positions you want, then animate there using transforms only.

### [cosmic-text](https://github.com/pop-os/cosmic-text): Buffer + Editor

[cosmic-text](https://github.com/pop-os/cosmic-text) separates concerns:

**Buffer:** Holds text and layout results. Can be mutated, but mutations trigger re-shaping:

```rust
let mut buffer = Buffer::new(&mut font_system, metrics);

// Set initial text (shapes automatically)
buffer.set_text(&mut font_system, "Hello", attrs, shaping);

// Change text (re-shapes)
buffer.set_text(&mut font_system, "Hello World", attrs, shaping);

// Changing attributes also re-shapes
buffer.set_attrs(new_attrs);
```

**Editor:** Wraps Buffer for editing scenarios (cursor, selection). Provides efficient incremental updates:

```rust
let mut editor = Editor::new(buffer);

// Efficient: only re-shapes affected portions
editor.insert_string(&mut font_system, "abc", None);
```

The pattern: **layout is recomputed when content changes**, but you can read glyph positions for rendering without triggering recomputation.

### openrndr's orx-text-writer: Token-Based Separation

openrndr separates layout from rendering through "tokens":

```kotlin
val writer = writer {
    // Layout phase: compute positions
    text("Hello", visible = false)
}

// Rendering phase: use positions creatively
for ((index, rect) in writer.glyphOutput.rectangles.withIndex()) {
    val wave = sin(time + index * 0.3) * 10.0
    drawer.rectangle(rect.x, rect.y + wave, rect.width, rect.height)
}
```

Layout is computed once, then positions are read (not mutated) during rendering. Any modification happens at draw time.

---

## The Trade-offs

### Mutable Layout

**Pros:**
- Intuitive API for animation
- Can be efficient if mutations are cheap
- Familiar to developers from OOP backgrounds

**Cons:**
- Harder to reason about (when is layout valid?)
- Difficult to cache (layout might have changed)
- Thread-safety concerns (who owns the layout?)
- Rust: ownership/borrowing becomes complex

```rust
// The borrow checker doesn't love mutable iteration
for glyph in layout.glyphs_mut() {
    glyph.y_offset = compute_offset(glyph.index, time);
    // But what if compute_offset needs to read other glyphs?
}
```

### Immutable Layout + Transform at Draw Time

**Pros:**
- Layout is always in a valid, complete state
- Easy to cache and share across threads
- Clear separation: layout is "what", drawing is "how"
- Works well with Rust's ownership model

**Cons:**
- Slightly more code for simple animations
- Must pass transforms separately
- Can feel verbose

```rust
// Layout is just data
let layout = compute_layout("Hello", &font);

// Rendering applies transforms
for (i, glyph) in layout.glyphs().enumerate() {
    let transform = Transform::translate(0.0, wave_offset(i, time));
    draw_glyph(&glyph, transform);
}
```

### Rebuild Every Frame

**Pros:**
- Simplest mental model (always fresh)
- Works for cases where layout parameters change (font size animation)
- No stale state possible

**Cons:**
- Performance cost for complex layouts
- Allocations every frame (unless using arenas/pools)
- Wasteful when layout hasn't actually changed

```rust
// Every frame, full recompute
fn draw_frame(&mut self, time: f32) {
    let layout = TextLayout::new("Hello")
        .size(24.0 + time.sin() * 4.0)  // Animating size!
        .shape(&self.font);

    draw(&layout);  // Layout discarded after this frame
}
```

---

## Performance Considerations

### What's Actually Expensive?

```
Operation               | Typical Cost  | When to Avoid
------------------------|---------------|------------------
Text shaping (HarfBuzz) | 0.01-0.1ms    | Avoid per-frame
Line breaking           | 0.1-1ms       | Avoid per-frame
Glyph rasterization     | 0.01ms/glyph  | Cache results
Position iteration      | ~0 (just reads)| Never a problem
Transform multiplication| ~0            | Never a problem
```

The expensive operations are **shaping** and **line breaking**. Reading glyph positions and applying transforms is essentially free.

This suggests the optimal pattern:

```
┌───────────────────────────────────────────────────────┐
│  Once (on text change):                                │
│    - Shape text                                        │
│    - Break lines                                       │
│    - Compute base glyph positions                      │
│    - Cache result                                      │
└───────────────────────────────────────────────────────┘
            │
            ▼
┌───────────────────────────────────────────────────────┐
│  Every frame:                                          │
│    - Read cached positions                             │
│    - Compute per-glyph transforms (cheap)              │
│    - Draw with transforms                              │
└───────────────────────────────────────────────────────┘
```

### Android's Optimization Insight

From the Android documentation and source code: `StaticLayout` is faster than `DynamicLayout` not because it's immutable, but because it doesn't maintain the machinery for incremental updates.

If you **know** text won't change, you can skip:
- Change listeners
- Dirty region tracking
- Incremental re-layout logic

This is why Android recommends `StaticLayout` for display and `DynamicLayout` only for editing.

---

## Rust-Specific Considerations

Rust's ownership model influences this choice:

### Mutable Layout Challenges

```rust
// This doesn't compile: can't mutate while iterating
for glyph in layout.glyphs_mut() {
    // What if we need to look at the next glyph?
    let next = layout.glyph(glyph.index + 1);  // Error: already borrowed mutably!
    glyph.spacing = compute_spacing(glyph, next);
}

// Workaround 1: Index-based access
for i in 0..layout.glyph_count() {
    let spacing = {
        let current = layout.glyph(i);
        let next = layout.glyph(i + 1);
        compute_spacing(current, next)
    };
    layout.glyph_mut(i).spacing = spacing;
}

// Workaround 2: Collect into Vec first (allocation!)
let modifications: Vec<_> = layout.glyphs()
    .windows(2)
    .map(|w| compute_spacing(&w[0], &w[1]))
    .collect();

for (i, spacing) in modifications.iter().enumerate() {
    layout.glyph_mut(i).spacing = *spacing;
}
```

Neither workaround is elegant. The ownership model is telling us something: maybe the API design is fighting the language.

### Immutable Layout Works Better

```rust
// Layout is immutable, transforms are separate
let layout = TextLayout::new("Hello").shape(&font);

// Compute transforms (can look at any glyphs freely)
let transforms: Vec<Transform> = layout.glyphs()
    .enumerate()
    .map(|(i, glyph)| {
        let wave = (time + i as f32 * 0.3).sin() * 10.0;
        Transform::translate(0.0, wave)
    })
    .collect();

// Draw with transforms
for (glyph, transform) in layout.glyphs().zip(transforms.iter()) {
    draw_glyph(glyph, transform);
}
```

Or even better, transform at draw time without collecting:

```rust
for (i, glyph) in layout.glyphs().enumerate() {
    let wave = (time + i as f32 * 0.3).sin() * 10.0;
    draw_glyph_at(glyph, glyph.x, glyph.y + wave);
}
```

---

## Recommended Pattern for Creative Coding

Based on this analysis, here's a pattern that balances ergonomics and performance:

### The API

```rust
// Layout is computed once (expensive)
let layout = Text::layout("Hello World")
    .font(&font)
    .size(24.0)
    .wrap_width(200.0)
    .build();

// Layout is immutable but provides rich queries
println!("Width: {}", layout.bounds().width);
println!("Line count: {}", layout.line_count());

// Drawing can apply per-glyph transforms (cheap)
draw.text(&layout)
    .position(100.0, 100.0)
    .with_glyph_transform(|i, glyph| {
        // Called for each glyph during rendering
        let wave = (time + i as f32 * 0.3).sin() * 10.0;
        Transform::translate(0.0, wave)
    });
```

### When Text Changes, Rebuild

```rust
// Text content changed? New layout.
let new_layout = Text::layout("Goodbye World")
    .font(&font)
    .size(24.0)
    .wrap_width(200.0)
    .build();
```

### For Animation That Changes Layout Parameters

Some animations require re-layout (font size, wrap width). Use caching:

```rust
struct AnimatedTextCache {
    // Cache layouts for discrete animation keyframes
    layouts: HashMap<AnimationKey, TextLayout>,
}

impl AnimatedTextCache {
    fn get(&mut self, text: &str, size: f32, font: &Font) -> &TextLayout {
        // Quantize size to reduce cache entries
        let quantized_size = (size * 2.0).round() / 2.0;  // 0.5pt increments
        let key = AnimationKey { text: text.to_string(), size: quantized_size };

        self.layouts.entry(key).or_insert_with(|| {
            Text::layout(text).font(font).size(quantized_size).build()
        })
    }
}
```

---

## Summary: The Recommended Approach

| Aspect | Recommendation | Rationale |
|--------|---------------|-----------|
| Layout mutability | **Immutable** | Plays well with Rust, easier to cache and share |
| Animation | Transform at draw time | Shaping is expensive, transforms are free |
| API style | Builder for layout, callback for transforms | Separates expensive (build) from cheap (draw) |
| Text changes | Rebuild layout | Incremental update machinery isn't worth it for most creative coding |
| Parameter animation | Cache discrete keyframes | Avoid per-frame shaping |

```rust
// The pattern in code
let layout = Text::layout("creative")     // Expensive: do once
    .font(&font)
    .size(48.0)
    .build();

// Every frame (cheap)
draw.text(&layout)
    .with_glyph_transform(|i, _| wave_transform(i, time));
```

This gives you:
- Predictable performance (shaping happens at known times)
- Thread safety (layout can be shared)
- Flexibility (arbitrary transforms at draw time)
- Rust-friendly ownership semantics

---

## Sources

- [Android StaticLayout Documentation](https://developer.android.com/reference/android/text/StaticLayout)
- [Android DynamicLayout Documentation](https://developer.android.com/reference/android/text/DynamicLayout)
- [CSS Animation Performance](https://web.dev/articles/animations-and-performance) — Transform vs layout properties
- [FLIP Animation Technique](https://css-tricks.com/animating-layouts-with-the-flip-technique/) — Layout animation optimization
- [cosmic-text](https://github.com/pop-os/cosmic-text)
- [cosmic-text](https://github.com/pop-os/cosmic-text)
- [Mastering Android Text Layout](https://medium.com/kotlin-android-chronicle/mastering-text-layout-with-staticlayout-and-dynamiclayout-in-android-52afca255820)

---

*This document is part of the [Typography Theme](typography.md) research.*
