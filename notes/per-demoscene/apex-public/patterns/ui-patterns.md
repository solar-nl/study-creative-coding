# UI Patterns: Transferable Lessons from Whiteboard

> Extracting architectural patterns from apEx's immediate-mode UI library that apply to modern Rust frameworks like egui.

---

## Why Extract Patterns?

When you study a mature codebase from a different era or language, the specific implementation details often feel irrelevant. DirectX 11 calls, Hungarian notation, manual memory management - these are artifacts of their time. But beneath the surface lies something more valuable: architectural decisions that solve timeless problems.

Whiteboard is apEx's immediate-mode UI library, written in C++ around 2010 for a demoscene tool. A decade later, egui would become Rust's dominant immediate-mode UI solution, independently arriving at nearly identical architectural choices. This convergence isn't coincidence - it's evidence that certain patterns are fundamental to high-performance immediate-mode UI, regardless of implementation language.

The patterns documented here focus on the transferable insights: the "why" behind design decisions, not the "how" of DirectX buffer mapping or C++ virtual methods. Each pattern identifies a specific problem, explores the solution space, and sketches how it translates to modern Rust with wgpu. The goal is to inform future framework design, not to replicate Whiteboard's implementation verbatim.

---

## Pattern 1: Hybrid Immediate-Retained Architecture

### The Problem: Ergonomics vs Performance

Immediate-mode UI APIs are a joy to use. You write code that reads like a description of the interface, calling functions like `button("Save")` or `slider(&mut value, 0.0..1.0)`. State management disappears - no widget object lifetimes to track, no manual synchronization between data and display. The UI is simply a pure function of your application state, called every frame.

But naive immediate-mode implementations have a fatal flaw: they couple the programming model to the rendering strategy. If each button call issues a GPU draw command, you end up with thousands of draw calls per frame. State changes between calls - texture binds, shader swaps, blend mode toggles - destroy batching efficiency. The result is beautiful code that runs at 15fps.

Retained-mode systems flip the equation. They build a persistent tree of widget objects, carefully batch rendering, and achieve single-digit draw call counts. Performance is excellent, but ergonomics suffer. You manage object lifetimes, wire up event handlers, manually invalidate when data changes. Synchronization bugs plague development: the UI shows stale data because you forgot to trigger an update somewhere.

The question demoscene developers faced in 2010 - and that Rust framework designers face today - is whether we must choose between these extremes.

### The Solution: Decouple API from Rendering

Whiteboard's insight is that the immediate-mode programming model is independent from immediate-mode rendering. You can rebuild the UI tree every frame (immediate API) while accumulating geometry into batched buffers (retained rendering). The application sees a simple, stateless interface. The framework handles the performance optimization transparently.

Here's how it works. Each frame, application code constructs widgets by calling functions or allocating short-lived objects. These widgets emit rendering primitives - rectangles, text glyphs, borders - into a shared accumulator called the display list. The accumulator is just a dynamic array of vertices, growing as widgets contribute geometry. Once tree traversal completes, the entire display list uploads to a GPU buffer in one operation and renders via a single draw call.

From the application's perspective, this feels immediate. You write procedural UI code that runs top-to-bottom every frame. But the rendering backend is fully retained - it batches aggressively, reuses buffers, minimizes state changes. The hybrid approach delivers immediate-mode ergonomics with retained-mode performance.

egui uses this exact pattern. When you call `ui.button("Click")`, that function doesn't draw anything. It computes layout, checks input, updates internal state, and emits a rectangle into a tessellation buffer. After your UI function returns, egui uploads all accumulated geometry and renders it in one or two draw calls. Whiteboard proved this architecture works at production scale years before egui existed.

Think of it like this: imagine writing a document in a word processor. You type continuously, inserting paragraphs, formatting text, adding images. From your perspective, it's a stream of immediate edits. But the word processor doesn't re-render the entire document after each keystroke. It batches changes, updates affected regions, and repaints efficiently. You get the ergonomics of direct manipulation with the performance of intelligent rendering. UI frameworks work the same way.

### Implementation Approach

The core abstraction is a DrawContext (or DrawAPI in Whiteboard's terminology) that accumulates rendering commands:

```rust
struct DrawContext {
    display_list: Vec<UIVertex>,
    offset_stack: Vec<Vec2>,
    crop_stack: Vec<Rect>,
    opacity_stack: Vec<u8>,
}

impl DrawContext {
    fn add_rect(&mut self, pos: Rect, uv: Rect, color: Color) {
        // Apply transforms and accumulate vertices
        let screen_pos = self.transform_to_screen(pos);
        self.display_list.extend_from_slice(&[
            UIVertex { position: screen_pos.min, uv: uv.min, color },
            UIVertex { position: screen_pos.max_x_min_y(), uv: uv.max_x_min_y(), color },
            // ... other corners
        ]);
    }
}
```

Widgets call methods on this context during traversal. The context handles coordinate transforms, clipping, and batching. After traversal, a single upload-and-render operation processes the accumulated geometry.

The frame loop structure looks like this in practice. Application code builds the UI declaratively, the framework accumulates geometry, then a single render call submits everything to the GPU. No manual draw call management, no widget object lifetimes to track.

```rust
fn render_frame(&mut self) {
    // Clear accumulator from previous frame
    self.draw_ctx.clear();

    // Application builds UI (immediate-mode API)
    self.build_ui(&mut self.draw_ctx);

    // Upload and render in one batch (retained optimization)
    self.draw_ctx.render(&self.queue, &mut render_pass);
}
```

### Trade-offs

**Advantages**:
- Immediate-mode ergonomics without performance penalty
- No widget object lifetime management
- Automatic state synchronization (UI rebuilds from data every frame)
- Single-digit draw call counts for complex interfaces

**Disadvantages**:
- Higher CPU cost than retained-mode (rebuilding UI every frame)
- Can't trivially skip rendering for unchanged regions
- Requires careful batching to achieve good GPU efficiency

**When to use**: Any real-time interactive application where UI needs to reflect dynamic state. Demo tools, game editors, dev tools, creative coding environments.

**When to avoid**: Static UIs that rarely change (where retained-mode overhead pays off) or applications with extreme frame budgets (VR, mobile) where CPU cost is critical.

### Rust Translation

The pattern translates naturally to Rust with some improvements. Instead of allocating widget objects, use stack-allocated function calls. Rust's ownership system ensures the display list can't outlive the rendering context, preventing whole classes of C++ memory bugs.

Here's a sketch showing the Rust approach. The widget builder pattern leverages borrowing to guarantee correct usage, and RAII guards handle transform stack management automatically.

```rust
trait Widget {
    fn draw(&self, ctx: &mut DrawContext);
}

struct Button<'a> {
    text: &'a str,
    rect: Rect,
    state: WidgetState,
}

impl Widget for Button<'_> {
    fn draw(&self, ctx: &mut DrawContext) {
        let bg_color = self.color_for_state();
        ctx.add_rect(self.rect, SOLID_UV, bg_color);

        if !self.text.is_empty() {
            ctx.draw_text(self.text, self.rect, self.text_color());
        }
    }
}

// Usage: pure functional style
fn build_ui(ctx: &mut DrawContext) {
    Button { text: "Save", rect: Rect::new(10, 10, 100, 40), state: WidgetState::Normal }
        .draw(ctx);
}
```

The key Rust advantage is compile-time guarantees about borrowing. The DrawContext can't be accidentally used after render() consumes it, and widgets can't outlive their data sources. This eliminates entire categories of C++ bugs without runtime overhead.

---

## Pattern 2: State-Driven Styling

### The Problem: Coupling Behavior to Appearance

When you hardcode visual properties into widget implementations, every styling change requires touching code. Want to change the button hover color from light blue to light gray? Edit the button source, recompile, redeploy. Want different themes for light/dark mode? Add conditional logic throughout the widget hierarchy. Want designers to iterate on visual polish? They need C++ knowledge.

This coupling between widget behavior and widget appearance creates friction. Buttons know how to handle clicks, manage focus, emit events - that's behavioral logic that belongs in code. But they shouldn't hardcode that hovered buttons are #3399FF while active buttons are #1177DD. Those are presentation details that change frequently and vary by theme.

Web developers solved this in the 1990s with CSS: separate structure from style. HTML describes the widget tree and semantic structure. CSS describes colors, fonts, spacing. A designer can iterate on CSS without touching JavaScript logic. The same principle applies to native UI libraries, but implementing it requires careful architecture.

### The Solution: Property Lookup by Widget State

Whiteboard implements CSS-like styling through property batches indexed by widget state. Each widget queries visual properties based on its current state (normal, hovered, active, disabled) rather than hardcoding them. A button in the hovered state looks up its background color from a property table, retrieves the corresponding value, and uses that for rendering. Change the table entry, change the appearance - no code modification required.

The state enumeration maps directly to CSS pseudo-classes. Normal is the default state, like an unstyled HTML element. Hover applies when the mouse is over the widget, equivalent to `:hover`. Active represents interaction, like `:active` in CSS. Disabled indicates non-interactive widgets, matching `:disabled`. This isn't coincidence - both systems model the same underlying UI state machine.

Property batches store state-indexed lookups for every visual component: background colors, foreground colors, border styles, fonts, texture atlas regions for skinned widgets. When a button needs to render, it determines its state (checking hover, pressed, enabled flags), queries the property batch, and retrieves state-specific values. The same button code renders completely different appearances based on what the property batch contains.

Think of it like a phone book for visual properties. Instead of the button saying "I'm always light blue," it says "look me up in the phone book under 'button, hovered state, background color.'" The phone book can change without the button caring. You can swap phone books entirely to implement themes - dark mode gets one property batch, light mode gets another, but widget behavior code stays identical.

### Implementation Approach

The pattern requires two components: a state enumeration and a property lookup structure. The state enum defines the UI states widgets can occupy, while the property structure maps state-component pairs to values.

```rust
#[derive(Copy, Clone, PartialEq, Eq, Hash)]
enum WidgetState {
    Normal,
    Hover,
    Active,
    Disabled,
}

#[derive(Copy, Clone, PartialEq, Eq, Hash)]
enum VisualProperty {
    BackgroundColor,
    BackgroundImage,
    FontColor,
    BorderColor,
    Font,
}

struct PropertyBatch {
    colors: HashMap<(WidgetState, VisualProperty), Color>,
    atlas_regions: HashMap<(WidgetState, VisualProperty), Rect>,
    fonts: HashMap<WidgetState, FontHandle>,
}
```

Widgets query properties during rendering rather than storing them. This keeps widget state minimal and makes theming a simple matter of swapping property batches. The query pattern becomes the standard idiom throughout the UI system.

```rust
impl Button {
    fn draw(&self, ctx: &mut DrawContext, props: &PropertyBatch) {
        let state = self.current_state(); // Hover? Active? Disabled?

        let bg_color = props.get_color(state, VisualProperty::BackgroundColor);
        let font_color = props.get_color(state, VisualProperty::FontColor);

        ctx.add_rect(self.rect, SOLID_UV, bg_color);
        ctx.draw_text(self.text, self.rect, font_color);
    }
}
```

### Trade-offs

**Advantages**:
- Visual iteration without code changes
- Theme support via property batch swapping
- Designer-friendly workflow (edit data, not code)
- Centralized style definitions reduce duplication

**Disadvantages**:
- Runtime lookup overhead vs hardcoded values
- Less type-safe than compile-time constants
- Requires convention around state/property naming
- Can become complex with many visual states

**When to use**: Applications with theming requirements, tools where designers need iteration control, UIs that need runtime skinning.

**When to avoid**: Single-theme applications where compile-time constants suffice, performance-critical UIs where lookup overhead matters, simple prototypes that don't need styling flexibility.

### Rust Translation

Rust's type system can improve on the C++ implementation with compile-time safety. Instead of string-based property names or magic numbers, use enums for type-safe lookups. Pattern matching provides exhaustive state handling.

The Rust version gains compile-time guarantees. If you add a new VisualProperty variant, the compiler forces you to handle it in all property batch implementations. Forgetting to provide a value becomes a compile error, not a runtime lookup failure.

```rust
struct PropertyBatch {
    colors: HashMap<(WidgetState, VisualProperty), Color>,
}

impl PropertyBatch {
    fn get_color(&self, state: WidgetState, prop: VisualProperty) -> Color {
        self.colors.get(&(state, prop))
            .copied()
            .unwrap_or_else(|| self.default_color(prop))
    }

    fn default_color(&self, prop: VisualProperty) -> Color {
        match prop {
            VisualProperty::BackgroundColor => Color::WHITE,
            VisualProperty::FontColor => Color::BLACK,
            VisualProperty::BorderColor => Color::GRAY,
            _ => Color::TRANSPARENT,
        }
    }
}

// Builder pattern for ergonomic initialization
impl PropertyBatch {
    fn new() -> Self {
        Self { colors: HashMap::new() }
    }

    fn with_color(mut self, state: WidgetState, prop: VisualProperty, color: Color) -> Self {
        self.colors.insert((state, prop), color);
        self
    }
}

// Usage
let dark_theme = PropertyBatch::new()
    .with_color(WidgetState::Normal, VisualProperty::BackgroundColor, Color::rgb(0.2, 0.2, 0.2))
    .with_color(WidgetState::Hover, VisualProperty::BackgroundColor, Color::rgb(0.3, 0.3, 0.3))
    .with_color(WidgetState::Normal, VisualProperty::FontColor, Color::rgb(0.9, 0.9, 0.9));
```

---

## Pattern 3: Unified Texture Atlas

### The Problem: Texture Binding Overhead

Modern GPUs amortize their fixed overhead across large batches of work. Setting up a draw call - binding textures, configuring shaders, updating uniforms - takes microseconds. Drawing a million triangles with that configuration takes milliseconds. The ratio matters: if setup dominates execution, you're wasting GPU potential.

UI rendering seems designed to thwart batching. A typical interface mixes dozens of visual elements: buttons with different background images, icons in various styles, text glyphs from multiple fonts, colored rectangles for separators and panels. If each element requires its own texture binding, you shatter batching into hundreds of tiny draw calls. The GPU spends more time switching state than rendering pixels.

The classic solution is texture atlases: pack many small images into one large texture, reference different regions via UV coordinates. But this raises a new problem - how do you handle heterogeneous content? Buttons need skinned backgrounds. Icons need crisp vector graphics. Text needs anti-aliased glyphs. Solid colors need... nothing, really. Do you build separate atlases and resign yourself to multiple draw calls?

### The Solution: Single Atlas with White Pixel for Solids

Whiteboard's approach is elegant: every visual element references the same unified texture atlas, including solid color fills. The atlas contains UI skins, icons, and pre-rasterized font glyphs. It also contains one critical element: a single white pixel at a known location.

When a widget needs to draw a solid color rectangle, it doesn't switch to a different rendering mode or bind a different texture. It draws a textured quad referencing the white pixel's UV coordinates - typically something tiny like (0.0, 0.0) to (1.0/2048.0, 1.0/2048.0) - and sets the vertex color to the desired hue. The pixel shader samples white, multiplies by the vertex color, and outputs the requested color. From the GPU's perspective, it's just another textured quad in the same batch.

This enables perfect batching. Thousands of quads can render in one draw call regardless of whether they're textured buttons, colored panels, icons, or text glyphs. Everything uses the same texture binding. The shader doesn't need conditional logic - it always samples and modulates. The rendering path is completely unified.

Think of it like a universal adapter. Instead of needing different drawing methods for different content types, you normalize everything to "textured quad with color modulation." The adapter is the white pixel - it makes solid colors look like a special case of textured rendering, not a different operation entirely. This keeps the rendering pipeline simple and maximally batch-friendly.

### Implementation Approach

The atlas layout reserves a small region (often just a single pixel) for solid color rendering. The UV coordinates for this region become a constant that widgets use when drawing untextured geometry.

```rust
// Atlas contains:
// - (0, 0): 1x1 white pixel for solid fills
// - (1, 0) to (1024, 512): UI skin elements
// - (0, 512) to (1024, 1024): Font glyphs
// - (1024, 0) to (2048, 1024): Icons

const SOLID_UV: Rect = Rect {
    min: Vec2::new(0.0, 0.0),
    max: Vec2::new(1.0 / 2048.0, 1.0 / 2048.0),
};

struct DrawContext {
    atlas_texture: TextureHandle,
}

impl DrawContext {
    fn draw_solid_rect(&mut self, pos: Rect, color: Color) {
        // Use white pixel UV, modulate with vertex color
        self.add_rect(pos, SOLID_UV, color);
    }

    fn draw_textured_rect(&mut self, pos: Rect, uv: Rect, tint: Color) {
        // Use actual texture region UV, modulate with tint
        self.add_rect(pos, uv, tint);
    }

    // Both call the same underlying implementation!
    fn add_rect(&mut self, pos: Rect, uv: Rect, color: Color) {
        // Emit quad vertices, all using the same atlas texture
    }
}
```

The pixel shader is trivial because it handles all cases uniformly. No branching, no mode checks, just sample and multiply. This is optimal for GPU execution.

```wgsl
@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let tex_color = textureSample(atlas_texture, atlas_sampler, in.uv);
    return tex_color * in.color;  // Modulate by vertex color
}

// For solid colors:
//   tex_color = vec4(1.0, 1.0, 1.0, 1.0)  // white pixel
//   in.color = vec4(r, g, b, a)           // desired color
//   result = vec4(r, g, b, a)             // the color we want!

// For textured quads:
//   tex_color = vec4(...)                 // sampled texture
//   in.color = vec4(1.0, 1.0, 1.0, 1.0)   // white tint (no modification)
//   result = tex_color                    // untinted texture
```

### Trade-offs

**Advantages**:
- Perfect batching: entire UI renders in 1-2 draw calls
- Unified rendering path: no mode switching or shader variants
- Simplified shader logic: always sample-and-modulate
- Cache coherency: GPU texture cache benefits from locality

**Disadvantages**:
- Atlas size limits: fixed resolution constrains total content
- Packing complexity: requires offline or runtime atlas building
- Wasted space: rectangular packing leaves gaps
- Resolution constraints: can't dynamically scale content

**When to use**: UI systems prioritizing batch efficiency, fixed-resolution applications, content with known asset lists.

**When to avoid**: Dynamic content with unpredictable textures, high-DPI interfaces needing arbitrary resolution, applications requiring texture streaming.

### Rust Translation

Modern Rust graphics APIs like wgpu provide alternatives to single-atlas constraints while preserving batching. Texture arrays allow indexing multiple textures in one bind group, and bindless textures (on supporting hardware) eliminate binding overhead entirely.

The wgpu approach extends the pattern rather than replacing it. You still batch geometry into unified buffers, but you can reference different textures via per-vertex indices. This combines atlas-style batching with dynamic texture flexibility.

```rust
// Modern variant: texture array for heterogeneous content
struct DrawContext {
    atlas_array: wgpu::TextureView,  // Array of 2D textures
    solid_layer: u32,                // Index of white pixel texture
}

#[repr(C)]
struct UIVertex {
    position: [f32; 2],
    uv: [f32; 2],
    color: [f32; 4],
    texture_index: u32,  // Which layer in the texture array
}

impl DrawContext {
    fn draw_solid(&mut self, pos: Rect, color: Color) {
        self.add_quad(pos, SOLID_UV, color, self.solid_layer);
    }

    fn draw_icon(&mut self, pos: Rect, icon: IconHandle) {
        let (uv, texture_index) = self.get_icon_uv(icon);
        self.add_quad(pos, uv, Color::WHITE, texture_index);
    }
}
```

The shader indexes into the texture array, maintaining unified batching while allowing heterogeneous content. This is the best of both worlds: batch efficiency with texture flexibility.

```wgsl
@group(0) @binding(0) var atlas_array: texture_2d_array<f32>;
@group(0) @binding(1) var atlas_sampler: sampler;

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let tex_color = textureSample(atlas_array, atlas_sampler, in.uv, in.texture_index);
    return tex_color * in.color;
}
```

---

## Pattern 4: Hierarchical Coordinate Spaces

### The Problem: Global Coordinates Are Fragile

When widgets use absolute screen coordinates, the entire UI becomes brittle. A button at pixel position (150, 200) works fine until you add a menu bar at the top. Now every widget below the menu needs to shift down by the menu's height. Embed the button in a scrollable panel, and you need to manually adjust its position based on scroll offset. Move the panel, and the button's absolute position changes again.

This global coordinate approach forces widgets to know about their entire containment hierarchy. A deeply nested widget needs to account for every ancestor's position and transform. If any ancestor moves, scrolls, or resizes, descendants must recalculate. The coupling is extreme: changing a top-level layout requires updating code throughout the tree.

Scene graphs solved this problem decades ago for 3D rendering. Each node operates in its own local coordinate system. A child positioned at (5, 10) means "5 units right, 10 units down from my parent's origin," not "5 pixels from the screen's top-left corner." When the parent moves, children move automatically because their local coordinates don't change.

### The Solution: Transform Stack with Local Coordinates

Whiteboard applies scene graph principles to 2D UI. Each widget operates in its own local coordinate space. When a button says "draw a rectangle at (5, 5)," those coordinates are relative to the button's top-left corner. The framework maintains a transform stack that accumulates offsets as it traverses the widget tree. Drawing a rectangle applies the accumulated transform to convert local coordinates to screen space.

Tree traversal manages the transform stack automatically. When entering a widget during tree walk, push its offset onto the stack. Render the widget using the accumulated transform. Recursively render children (who push their own offsets). Pop the offset when exiting. This ensures sibling widgets don't interfere with each other's transforms, and deeply nested widgets automatically inherit all ancestor transforms.

The pattern mirrors function call stacks in programming. Each function has local variables that exist while the function executes. When you call another function, it gets its own locals without affecting the caller. When it returns, its locals disappear and the caller's locals are unchanged. Transform stacks work the same way: each widget gets a local coordinate system that exists during its render pass and vanishes when rendering returns to the parent.

Think of it like nested picture frames. The innermost picture doesn't care how many frames surround it - it's painted in its own coordinate space. The gallery curator can move the outer frame, and all nested frames move together automatically. That's what hierarchical coordinates do for UI: insulate components from layout changes in their ancestors.

### Implementation Approach

The DrawContext maintains a stack of coordinate offsets. As tree traversal descends, offsets accumulate. When a widget emits geometry, the current offset transforms local coordinates to screen space.

```rust
struct DrawContext {
    offset_stack: Vec<Vec2>,
    display_list: Vec<UIVertex>,
}

impl DrawContext {
    fn current_offset(&self) -> Vec2 {
        self.offset_stack.iter().sum()
    }

    fn push_offset(&mut self, offset: Vec2) {
        let accumulated = self.current_offset() + offset;
        self.offset_stack.push(accumulated);
    }

    fn pop_offset(&mut self) {
        self.offset_stack.pop();
    }

    fn add_rect(&mut self, local_pos: Rect, uv: Rect, color: Color) {
        let screen_pos = local_pos.translate(self.current_offset());
        // Emit vertices using screen_pos
    }
}
```

Widgets use RAII guards to ensure balanced push/pop operations. This prevents stack corruption from early returns or panics.

```rust
struct OffsetGuard<'a> {
    ctx: &'a mut DrawContext,
}

impl Drop for OffsetGuard<'_> {
    fn drop(&mut self) {
        self.ctx.pop_offset();
    }
}

impl DrawContext {
    fn with_offset<F>(&mut self, offset: Vec2, f: F)
    where F: FnOnce(&mut Self)
    {
        self.push_offset(offset);
        let _guard = OffsetGuard { ctx: self };
        f(self);
        // Guard auto-pops on drop
    }
}

// Usage
fn draw_panel(&self, ctx: &mut DrawContext) {
    ctx.with_offset(self.position, |ctx| {
        // All drawing in here uses panel-local coordinates
        ctx.add_rect(Rect::new(0, 0, 100, 50), SOLID_UV, Color::BLUE);

        self.draw_children(ctx);
    });
    // Offset automatically popped
}
```

### Trade-offs

**Advantages**:
- Widget code uses simple local coordinates
- Moving ancestors automatically moves descendants
- No coupling to container hierarchy
- Scroll and pan become offset modifications

**Disadvantages**:
- Runtime transform overhead (multiply on every vertex)
- Stack management complexity
- Debugging requires understanding transform accumulation
- Input hit-testing needs inverse transforms

**When to use**: Any hierarchical UI with nesting, scrolling, or dynamic layout. Essential for tools with complex widget trees.

**When to avoid**: Flat UIs with no nesting, performance-critical rendering where transform overhead matters.

### Rust Translation

Rust's RAII and borrowing eliminate manual stack management bugs. Guards ensure offsets always pop, and the borrow checker prevents using contexts with mismatched stack state.

The type system can encode coordinate spaces at compile time. This catches bugs where screen coordinates are used where local coordinates are expected.

```rust
// Type-safe coordinate spaces
struct LocalPos(Vec2);
struct ScreenPos(Vec2);

impl DrawContext {
    fn to_screen(&self, local: LocalPos) -> ScreenPos {
        ScreenPos(local.0 + self.current_offset())
    }

    fn add_rect(&mut self, local: Rect<LocalPos>, uv: Rect, color: Color) {
        let screen = Rect {
            min: self.to_screen(local.min),
            max: self.to_screen(local.max),
        };
        // Emit with screen coordinates
    }
}

// Compile error if you pass ScreenPos where LocalPos expected!
```

---

## Pattern 5: CPU-Side Scissor Clipping

### The Problem: GPU Wastes Work on Invisible Pixels

When a widget is partially off-screen or hidden behind a scroll container, naive rendering still submits all its geometry to the GPU. The vertex shader processes every vertex, transforming positions, interpolating UVs, passing data to the rasterizer. The rasterizer generates fragments for the entire primitive. The pixel shader executes for every covered pixel. Finally, the scissor test or depth test discards fragments outside the visible region.

This is wasteful. Why transform vertices, rasterize triangles, and execute pixel shaders for geometry that will be discarded anyway? The GPU is burning fill rate on invisible content. For complex UIs with thousands of widgets, most of which are scrolled out of view or behind other panels, this waste compounds. Frame rate suffers not from visible complexity, but from processing geometry that never contributes to the final image.

GPU scissor tests help by discarding fragments outside a rectangle, but they only activate after the pixel shader runs. The shader still executes for every fragment in the primitive, even those destined for discard. For large off-screen widgets, this means thousands of wasted shader invocations. Vertex shaders still process geometry that produces zero visible pixels.

### The Solution: Clip Geometry Before GPU Submission

Whiteboard implements scissor clipping on the CPU during geometry batching. When a widget emits a rectangle, the batching code intersects it with the current crop region (the visible area based on ancestor clipping). If the intersection is empty, the geometry is discarded immediately - no vertices enter the display list. If the intersection is partial, the geometry is trimmed to fit the visible region before vertex emission.

This moves clipping earlier in the pipeline. Instead of letting the GPU discover that geometry is invisible after processing it, the CPU prevents invisible geometry from reaching the GPU at all. Scrolled-off widgets contribute zero vertices to the batch. Partially visible widgets contribute only the visible portion. The display list contains exactly the renderable geometry, nothing more.

The UV coordinate adjustment is crucial. When a quad is clipped, its texture coordinates must be adjusted proportionally to avoid distortion. If the left edge is clipped by 20% of the quad's width, the U coordinate must advance by 20% of the UV range. Otherwise, the texture stretches across the clipped region, distorting the image. Whiteboard computes this adjustment during clipping: measure how much geometry was trimmed, scale UVs by the same proportion.

Think of it like cropping photos before uploading them to social media. You could upload full-resolution images and let the server crop them server-side, but that wastes bandwidth. Better to crop locally, then upload only the relevant pixels. CPU-side clipping is the same optimization: trim geometry locally (on the CPU) before uploading to the GPU.

### Implementation Approach

The crop rectangle propagates down the widget tree like the coordinate offset. Each widget can define a clipping region, and the final crop is the intersection of all ancestor regions.

```rust
struct DrawContext {
    crop_stack: Vec<Rect>,
}

impl DrawContext {
    fn current_crop(&self) -> Rect {
        self.crop_stack.iter()
            .fold(Rect::MAX, |acc, &rect| acc.intersect(rect))
    }

    fn add_rect(&mut self, pos: Rect, uv: Rect, color: Color) {
        let screen_pos = self.transform_to_screen(pos);
        let crop = self.current_crop();

        // Intersect with crop region
        let Some(clipped_pos) = screen_pos.intersect(crop) else {
            return; // Completely outside visible region, skip
        };

        // Adjust UVs proportionally
        let adjusted_uv = if clipped_pos != screen_pos {
            adjust_uvs_for_clip(uv, screen_pos, clipped_pos)
        } else {
            uv
        };

        // Emit only the visible portion
        self.emit_quad(clipped_pos, adjusted_uv, color);
    }
}

fn adjust_uvs_for_clip(uv: Rect, original: Rect, clipped: Rect) -> Rect {
    let left_clip = (clipped.min.x - original.min.x) / original.width();
    let top_clip = (clipped.min.y - original.min.y) / original.height();
    let right_clip = (original.max.x - clipped.max.x) / original.width();
    let bottom_clip = (original.max.y - clipped.max.y) / original.height();

    Rect {
        min: Vec2::new(
            uv.min.x + left_clip * uv.width(),
            uv.min.y + top_clip * uv.height(),
        ),
        max: Vec2::new(
            uv.max.x - right_clip * uv.width(),
            uv.max.y - bottom_clip * uv.height(),
        ),
    }
}
```

### Trade-offs

**Advantages**:
- Reduces GPU vertex processing for invisible geometry
- Eliminates pixel shader invocations for clipped fragments
- Smaller vertex buffer uploads
- More efficient use of GPU fill rate

**Disadvantages**:
- CPU cost for clipping math
- More complex batching logic
- Doesn't help with transparency or overlapping widgets
- Requires careful UV adjustment to avoid distortion

**When to use**: UIs with scrollable regions, deep widget hierarchies, lots of off-screen content. Critical for performance on low-end GPUs.

**When to avoid**: Simple UIs where everything fits on-screen, CPU-bound applications where GPU has spare cycles.

### Rust Translation

The Rust version benefits from explicit Option types for intersection results. The borrow checker ensures crop stack management is correct.

Using geometric libraries like euclid or glam provides battle-tested rectangle operations. These libraries handle edge cases around empty rectangles, floating-point precision, and UV scaling.

```rust
use euclid::{Rect, Point2D};

fn clip_and_adjust(
    geometry: Rect<f32>,
    uv: Rect<f32>,
    crop: Rect<f32>,
) -> Option<(Rect<f32>, Rect<f32>)> {
    let clipped_geom = geometry.intersection(&crop)?; // Returns None if no overlap

    if clipped_geom == geometry {
        // No clipping occurred
        return Some((geometry, uv));
    }

    // Calculate proportional UV adjustment
    let x_scale = clipped_geom.width() / geometry.width();
    let y_scale = clipped_geom.height() / geometry.height();

    let left_offset = (clipped_geom.min_x() - geometry.min_x()) / geometry.width();
    let top_offset = (clipped_geom.min_y() - geometry.min_y()) / geometry.height();

    let adjusted_uv = Rect::new(
        Point2D::new(
            uv.min_x() + left_offset * uv.width(),
            uv.min_y() + top_offset * uv.height(),
        ),
        Size2D::new(
            uv.width() * x_scale,
            uv.height() * y_scale,
        ),
    );

    Some((clipped_geom, adjusted_uv))
}
```

---

## Pattern 6: Opacity Propagation

### The Problem: Independent Widget Transparency Creates Inconsistency

When widgets manage opacity independently, parent transparency doesn't affect children. You set a panel to 50% opacity, expecting it to fade out with all its contents, but the buttons inside remain fully opaque. This breaks visual hierarchy - nested elements should inherit ancestor transparency to maintain consistent appearance.

Implementing per-widget fade-out manually is tedious. You'd need to traverse the tree, tracking ancestor opacity at each level, manually multiplying values. Miss a widget, and it pops into full opacity despite being in a faded panel. This is error-prone and creates maintenance burden - every widget needs opacity-aware rendering code.

Compositing-based solutions require rendering to intermediate textures. Render the panel and children to a texture, then composite that texture at reduced opacity. This works but carries significant cost: allocating render targets, binding them, multiple render passes, potential bandwidth overhead. For simple UI fading, the overhead seems excessive.

### The Solution: Hierarchical Alpha Multiplication

Whiteboard treats opacity as a hierarchical property that propagates down the widget tree through multiplication. Each widget has an opacity value (0.0 for invisible, 1.0 for fully opaque). When rendering, the framework multiplies the widget's opacity by all ancestor opacities to compute final vertex alpha. A button at 100% opacity inside a panel at 50% opacity renders at 50%. Nest another panel at 75% opacity in between, and the button renders at 37.5% (1.0 * 0.75 * 0.5).

The implementation mirrors the coordinate transform stack. As tree traversal descends, opacity values push onto a stack. When emitting geometry, multiply all stacked opacities to get the final alpha value, write that to vertex color. Pop opacity when exiting a widget. Siblings don't affect each other because their opacities are on separate stack branches.

This enables fade effects on entire subtrees with zero per-widget code. Animate a panel's opacity from 1.0 to 0.0, and every descendant fades automatically. The rendering code in buttons, labels, icons doesn't need opacity awareness - the framework handles propagation transparently. Widgets just specify their own opacity (usually 1.0), and the batching system computes the final value.

Think of opacity like volume controls on a mixing board. Each track has its own volume slider, but there's also a master volume. The final output is each track's volume multiplied by the master. If you lower the master, everything gets quieter together. Same with UI opacity: widgets have local opacity, parents act as masters, and the final alpha is the product of all controls.

### Implementation Approach

Add an opacity stack to the DrawContext. Widgets push their opacity multipliers during rendering. The add_rect function computes final alpha by multiplying all stack values.

```rust
struct DrawContext {
    opacity_stack: Vec<u8>, // 0-255 opacity values
}

impl DrawContext {
    fn current_opacity(&self) -> u8 {
        self.opacity_stack.iter()
            .fold(255u16, |acc, &o| (acc * o as u16) / 255) as u8
    }

    fn with_opacity<F>(&mut self, opacity: u8, f: F)
    where F: FnOnce(&mut Self)
    {
        self.opacity_stack.push(opacity);
        let _guard = OpacityGuard { ctx: self };
        f(self);
        // Auto-pops on drop
    }

    fn add_rect(&mut self, pos: Rect, uv: Rect, color: Color) {
        let final_alpha = (color.a as u16 * self.current_opacity() as u16 / 255) as u8;
        let final_color = Color { a: final_alpha, ..color };

        // Emit vertices with multiplied alpha
        self.emit_quad(pos, uv, final_color);
    }
}
```

Widgets specify their own opacity when starting their render pass. The framework handles the rest.

```rust
impl Panel {
    fn draw(&self, ctx: &mut DrawContext) {
        ctx.with_opacity(self.opacity, |ctx| {
            // Draw panel background
            ctx.add_rect(self.rect, SOLID_UV, self.bg_color);

            // Draw children - they inherit this panel's opacity
            for child in &self.children {
                child.draw(ctx);
            }
        });
    }
}
```

### Trade-offs

**Advantages**:
- Fade entire widget subtrees with single opacity value
- No intermediate render targets needed
- Zero per-widget opacity code
- Natural hierarchical behavior matches UI structure

**Disadvantages**:
- No control over child opacity relative to parent (always multiplies)
- Can't override ancestor fading
- Integer math may accumulate rounding error in deep trees
- Doesn't affect texture sampling (only vertex alpha)

**When to use**: UIs with fade-in/out animations, modal overlays that dim background, hierarchical transparency requirements.

**When to avoid**: Cases requiring independent child opacity, high precision alpha (medical imaging, scientific visualization), complex compositing effects.

### Rust Translation

The pattern translates directly with improved type safety. Use RAII guards and normalized floats for better precision.

Rust's f32 provides better opacity arithmetic than u8. Multiplication and division are exact (within floating-point precision) without integer rounding errors. Convert to u8 only when writing to vertex buffer.

```rust
struct DrawContext {
    opacity_stack: Vec<f32>, // 0.0-1.0 range
}

impl DrawContext {
    fn current_opacity(&self) -> f32 {
        self.opacity_stack.iter().product()
    }

    fn add_rect(&mut self, pos: Rect, uv: Rect, color: Color) {
        let final_alpha = color.a * self.current_opacity();
        let final_color = Color { a: final_alpha, ..color };

        self.emit_quad(pos, uv, final_color);
    }
}

// Usage with RAII guard
impl Widget for Panel {
    fn draw(&self, ctx: &mut DrawContext) {
        let _opacity = ctx.push_opacity(self.opacity);

        ctx.draw_rect(self.rect, self.bg_color);
        self.draw_children(ctx);

        // Opacity auto-pops on _opacity drop
    }
}

struct OpacityGuard<'a>(&'a mut DrawContext);

impl Drop for OpacityGuard<'_> {
    fn drop(&mut self) {
        self.0.opacity_stack.pop();
    }
}
```

---

## Implications for Modern Rust Frameworks

### What to Adopt Directly

The hybrid immediate-retained architecture is proven at production scale. Implement immediate-mode APIs that accumulate into retained buffers. This pattern appears in egui, Dear ImGui, and Whiteboard - independent implementations converging on the same solution is strong validation.

Unified texture atlases eliminate binding overhead. Modern variants using texture arrays or bindless textures extend this without the single-atlas size limit. The core insight - minimize state changes by normalizing heterogeneous content to unified resources - applies regardless of specific GPU API.

CPU-side clipping reduces GPU waste. Implement it as an optimization pass during batching. The math is straightforward, libraries like euclid provide robust implementations, and the performance win is measurable on any GPU.

State-driven styling separates structure from appearance. Use Rust enums for compile-time safety, trait-based property queries for extensibility. This enables theming and designer iteration without code changes.

Hierarchical transforms and opacity via stacks are fundamental to nested UIs. Implement with RAII guards to ensure correct management. These patterns have worked in scene graphs for decades; applying them to 2D UI is natural and proven.

### What to Improve with Rust's Features

Replace C++'s manual stack management with RAII guards and Drop implementations. This eliminates balance bugs where offsets or opacities don't pop. The borrow checker ensures guard lifetimes are correct.

Use type-safe coordinate spaces via newtype wrappers. Distinguish LocalPos from ScreenPos at compile time. This catches coordinate system mismatches that would be runtime bugs in C++.

Leverage trait-based polymorphism instead of inheritance. Widget traits with default implementations provide extension points without virtual dispatch overhead.

Use normalized floats (0.0-1.0) for opacity instead of bytes (0-255). This avoids integer rounding errors and simplifies math. Convert to bytes only when writing vertex data.

Apply builder patterns for ergonomic property batch construction. Chaining methods enables readable initialization without verbose constructors.

### What to Avoid

Don't use global mutable state for DrawContext. Pass contexts explicitly or use scoped guards. Rust's borrow checker fights globals; work with it, not against it.

Avoid string-based property lookups. Use typed enums and match expressions for compile-time safety and better performance.

Don't allocate widgets per-frame if avoidable. Prefer functional-style builder calls (like egui) that emit geometry without allocation.

Skip manual vertex buffer management. Use Vec for display lists, let wgpu/vulkan handle staging buffers. Explicit ring buffers are only needed for specific performance tuning.

Avoid hardcoded coordinate math. Use geometric libraries (glam, euclid) for rectangle operations, transforms, and intersections. They're battle-tested and handle edge cases.

---

## Key Insights

Whiteboard demonstrates that immediate-mode UI can achieve production performance through architectural choices, not micro-optimizations. The patterns that matter are batching geometry, minimizing state changes, and using CPU computation to reduce GPU waste.

The convergence between Whiteboard (2010, C++, DirectX 11) and egui (2020, Rust, wgpu) validates these patterns. When independent implementations in different languages and graphics APIs arrive at the same solutions, those solutions likely represent fundamental truths about the problem domain.

Hierarchy is the key abstraction. Transform stacks, opacity propagation, and crop regions all leverage the widget tree structure. Instead of fighting hierarchy with global state, embrace it through stack-based propagation. This mirrors how programming languages handle scoped variables - a proven pattern.

Separating concerns enables iteration. State-driven styling decouples appearance from behavior. Immediate-mode APIs decouple UI structure from rendering batching. These separations create flexibility: designers can tweak visuals without touching code, rendering can optimize without affecting application logic.

Modern Rust frameworks inherit these insights and can improve on them. Type-safe coordinate spaces catch bugs at compile time. RAII guards eliminate stack management errors. Traits provide extensibility without inheritance overhead. The patterns remain the same; Rust makes them safer and more ergonomic.

The real lesson is that good architecture transcends implementation details. DirectX vs Vulkan, C++ vs Rust, 2010 vs 2025 - the underlying problems and solutions remain constant. Study patterns, not code.

---

## Files Referenced

| File | Purpose | Key Insights |
|------|---------|--------------|
| `notes/per-demoscene/apex-public/tool/ui-system.md` | System overview | Immediate-mode philosophy, architecture decisions, egui comparison |
| `notes/per-demoscene/apex-public/code-traces/ui-rendering.md` | Implementation trace | Transform stacks, batching, GPU submission, clipping math |
| `Bedrock/Whiteboard/DrawAPI.cpp` | Batching implementation | CPU-side clipping, UV adjustment, opacity propagation |
| `Bedrock/Whiteboard/GuiItem.cpp` | Widget base class | Hierarchical traversal, coordinate transforms |
| `Bedrock/Whiteboard/Application.cpp` | Frame loop | Display list management, render orchestration |
