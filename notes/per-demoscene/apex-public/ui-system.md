# Whiteboard: Immediate-Mode UI Before egui

> How Conspiracy built a production-grade immediate-mode UI library in C++ for the apEx demotool, solving the same problems that egui would later tackle in Rust.

---

## The Problem: Tool UIs Demand Different Trade-offs

When you're building a game UI, you can afford retained-mode systems. Menus change infrequently. You construct a tree of widgets once, wire up event handlers, and let it sit there until the player clicks something. The programming model is verbose - lots of object lifetime management, state synchronization headaches - but the performance is excellent because rendering can be heavily optimized.

Demo tools flip this equation on its head. apEx is an interactive timeline editor, 3D scene graph browser, and parameter tweaker rolled into one application. The UI needs to reflect live scene state every frame: object positions, effect parameters, playback time. Building a retained-mode tree that mirrors all this dynamic state would be a synchronization nightmare. What happens when you scrub the timeline? Every widget showing time-dependent data needs to invalidate and update. What happens when you delete a scene object? The entire UI subtree for that object needs to be torn down and reconstructed.

Immediate-mode APIs eliminate this complexity. Instead of maintaining a parallel UI object tree, you simply regenerate the UI from scene state every frame. The library handles input, focus, hover states, and rendering. Your application code stays thin and declarative. This is the insight that made Dear ImGui revolutionary for game developers - and it's the same insight Conspiracy encoded in Whiteboard, years earlier.

The trick is achieving immediate-mode ergonomics without the naive performance pitfall: thousands of draw calls per frame. Whiteboard solves this through batched rendering. The application rebuilds the widget tree every frame using an immediate-style API, but instead of issuing GPU commands directly, widgets accumulate geometry into a unified vertex buffer. Once tree traversal completes, a single upload-and-draw operation renders the entire UI.

---

## The Mental Model: A Stage with Coordinate Transforms

Think of Whiteboard rendering like stage directions for a theater production. Each widget has a local coordinate system - its "stage" where it positions children and draws decorations. When a button says "draw a rectangle at (5, 5) with width 50," those coordinates are relative to the button's own space, not the screen.

As you traverse the widget tree, you're moving deeper into nested stages. A window contains a panel at offset (100, 50). That panel contains a button at offset (10, 20). When the button draws geometry, the rendering system needs to compose all these offsets: screen position = window offset + panel offset + button offset. The DrawAPI maintains this accumulated transform as a stack, pushing offsets on the way down the tree and popping them on the way back up.

Clipping works the same way. Each widget defines a "crop rectangle" - the visible region where its content can appear. When you nest a scrollable list inside a panel inside a window, the final visible region is the intersection of all these rectangles. Content outside the crop gets discarded before reaching the GPU. This is CPU-side scissor testing, eliminating fragment shader work for geometry that would be clipped anyway.

The beauty of this model is separation of concerns. Widget code operates in simple local coordinates. The rendering backend handles all the bookkeeping - coordinate transforms, clipping, opacity propagation. This keeps widget implementations lean and focused on their specific behavior.

---

## Using Whiteboard: The Immediate-Mode API

Here's how tool code constructs UI in apEx. The immediate feel comes from rebuilding widgets each frame:

```cpp
// Called every frame to redraw a tool panel
void MyToolPanel::OnDraw(CWBDrawAPI *DrawAPI) {
    // Create button (immediate allocation, lifetime scoped to frame)
    CWBButton *btn = new CWBButton(this, GetClientRect());
    btn->SetText(L"Generate Mesh");

    // The widget tree gets traversed and rendered by the application
    // No need to manage button lifetime - it gets deleted at frame end
}
```

That looks retained-mode, but it's not. The button exists only for this frame. Next frame, the entire UI tree gets rebuilt from scratch. State that needs to persist - which button is hovered, which panel has focus - lives in the framework, not in the widget objects themselves.

Contrast this with typical retained-mode code where you'd construct the button once during initialization, store a pointer, and update its state manually:

```cpp
// Retained-mode pattern (NOT how Whiteboard works)
class MyToolPanel {
    CWBButton *btn; // Persistent pointer

    void Initialize() {
        btn = new CWBButton(this, rect);
        btn->SetText(L"Generate Mesh");
        btn->OnClick += OnButtonClicked;  // Event wiring
    }

    void UpdateFromScene() {
        // Manual synchronization of UI state with scene state
        if (sceneChanged) {
            btn->SetEnabled(canGenerate);
            btn->SetText(meshExists ? L"Regenerate" : L"Generate");
        }
    }
};
```

Whiteboard's immediate approach collapses this into a single function. Scene state is directly queried during UI construction, so there's no synchronization logic. The button's text and enabled state automatically reflect current conditions because they're computed fresh every frame.

The rendering side works through tree traversal. After the application builds the widget tree, it calls `Root->DrawTree(DrawAPI)`, which recursively walks the hierarchy. Each widget pushes its coordinate transform, renders itself, processes children, then pops the transform. All geometry gets accumulated into the DrawAPI's display list - a flat array of vertices ready for GPU upload.

---

## Widget Architecture: CWBItem Base Class

Every UI element in Whiteboard inherits from `CWBItem`, a base class that implements the hierarchical rendering model. The key members:

**Spatial Properties** (GuiItem.h:158-162):
- `Position` - Rectangle in parent space (coordinates relative to parent widget)
- `ClientRect` - Rectangle in window space (coordinates including all ancestor offsets)
- `ScreenRect` - Rectangle in screen space (absolute pixel coordinates)
- `ContentOffset` - How much scrollable content has been shifted (for scrollbars)

**Tree Structure** (GuiItem.h:166-167):
- `Parent` - Pointer to parent widget
- `Children` - Array of child widgets

**Rendering Properties** (GuiItem.h:171-173):
- `OpacityMultiplier` - Hierarchical transparency (0.0 = invisible, 1.0 = opaque)
- `Hidden` - Visibility flag (if true, widget and children aren't drawn)
- `Disabled` - Interactivity flag (grayed out, non-responsive)

**Styling** (GuiItem.h:237):
- `CSSProperties` - State-dependent visual properties (colors, fonts, backgrounds)

The crucial method is `DrawTree()`, which implements hierarchical traversal. Here's the structure (from the code trace at GuiItem.cpp:501):

```cpp
void CWBItem::DrawTree(CWBDrawAPI *DrawAPI)
{
    if (!Hidden)
    {
        // 1. Save parent's coordinate space
        CRect OldCrop = DrawAPI->GetCropRect();
        CPoint OldOffset = DrawAPI->GetOffset();

        // 2. Calculate this widget's transform
        CRect ClientRect = GetClientRect();
        CPoint NewOffset = OldOffset + ClientRect.TopLeft();
        CRect TransformedCrop = OldCrop - OldOffset;

        // 3. Apply transform to DrawAPI (affects all subsequent geometry)
        DrawAPI->SetCropRect(TransformedCrop);
        DrawAPI->SetOffset(NewOffset);

        // 4. Widget-specific rendering (buttons draw backgrounds, text, etc.)
        OnDraw(DrawAPI);

        // 5. Recursively render children in their transformed spaces
        for (int i = 0; i < NumChildren(); i++)
            GetChild(i)->DrawTree(DrawAPI);

        // 6. Restore parent's coordinate space for siblings
        DrawAPI->SetCropRect(OldCrop);
        DrawAPI->SetOffset(OldOffset);
    }
}
```

The pattern here is classic scene graph traversal adapted for 2D UI. Each widget operates in its own local coordinate system. The DrawAPI acts as an accumulator, maintaining the current transform and clipping region as state. When a widget calls `DrawAPI->DrawRect(0, 0, 50, 50)`, those zero-based coordinates are already in widget-local space - the DrawAPI adds the accumulated offset to convert to screen space before submitting geometry.

This design keeps widget code simple. A button doesn't need to know where it sits in the overall UI hierarchy. It just draws relative to its own top-left corner and trusts the framework to handle transforms.

---

## State-Driven Styling: CSS-Like Properties

Whiteboard separates widget structure from visual appearance through a property batch system analogous to CSS. Widgets don't hardcode colors or fonts - they query state-dependent properties indexed by a `WBITEMSTATE` enum (GuiItem.h:28-37):

```cpp
enum WBITEMSTATE {
    WB_STATE_NORMAL = 0,     // Default appearance
    WB_STATE_ACTIVE = 1,     // Mouse button down or toggle pressed
    WB_STATE_HOVER = 2,      // Mouse over widget
    WB_STATE_DISABLED = 3,   // Non-interactive grayed out
    WB_STATE_DISABLED_ACTIVE = 4,  // Disabled but visually active
};
```

This maps directly to CSS pseudo-classes like `:hover`, `:active`, `:disabled`. Each widget queries its current state based on input (is the mouse over me? am I being clicked?) and retrieves the corresponding visual properties.

The property storage is `CWBDisplayProperties`, a two-dimensional lookup table indexed by `[state][component]` (GuiItem.h:121-135). Visual components include:

- `WB_ITEM_BACKGROUNDCOLOR` - Solid fill color
- `WB_ITEM_BACKGROUNDIMAGE` - Texture atlas reference for skins
- `WB_ITEM_FONTCOLOR` - Text color
- `WB_ITEM_BORDERCOLOR` - Border color
- `WB_ITEM_OPACITY` - Per-widget transparency

Here's how a button uses this system during rendering (from the code trace at Button.cpp:29):

```cpp
void CWBButton::OnDraw(CWBDrawAPI *DrawAPI)
{
    // 1. Determine current state based on input
    WBITEMSTATE State = GetState();  // Checks mouse hover, focus, etc.
    if (Pushed || TogglePushed)
        State = WB_STATE_ACTIVE;

    // 2. Query CSS-like properties for this state
    CWBCSSPropertyBatch Properties = GetDisplayProperties();

    // 3. Draw layered background using state-specific properties
    DrawBackground(DrawAPI, Properties, State);

    // 4. Render text if present
    if (GetText().Length() > 0) {
        CWBFont *Font = GetFont(State);  // State-specific font
        CColor TextColor = Properties.GetColor(State, WB_ITEM_FONTCOLOR);
        Font->Write(DrawAPI, GetText(), GetTextRect(), TextAlign, TextColor);
    }

    // 5. Draw border
    DrawBorder(DrawAPI, Properties, State);
}
```

The key insight: widget behavior (state machine logic) and widget appearance (colors, fonts, skins) are decoupled. Changing a button's hover color doesn't require touching code - just update the property batch. This is the same separation that CSS brings to web development, but implemented as C++ dictionaries instead of style sheets.

---

## Layout System: Coordinate Spaces and Transforms

Whiteboard operates across three coordinate spaces:

**Parent Space** - Widget positions are stored relative to their parent's client area. A button at (10, 20) in parent space means "10 pixels right, 20 pixels down from my parent's top-left corner."

**Window Space** - The ClientRect accumulates offsets down the widget tree. If a window is at (100, 100) and contains a panel at (20, 30) with a button at (5, 5), the button's ClientRect sits at (125, 135) in window space.

**Screen Space** - The ScreenRect adds the window's screen position. This is the absolute pixel coordinate used for input hit-testing and final rendering.

Tree traversal in `DrawTree()` performs the transformation. Each widget calculates its offset relative to its parent and adds it to the accumulated DrawAPI offset. When geometry arrives via `DrawAPI->AddDisplayRect()`, the coordinates are already in widget-local space. The DrawAPI applies the accumulated offset to produce screen-space vertices.

Clipping follows the same hierarchical model. The crop rectangle propagates down the tree as the intersection of all ancestor clipping regions. If a panel has a crop rect of (0, 0, 200, 300) and contains a scrollable list with a crop rect of (10, 10, 150, 250), the final crop region becomes (10, 10, 150, 250) - the area where both rectangles overlap. The batching pass discards geometry outside this region, saving GPU fill rate.

Scrollbars modify the coordinate transform by adjusting `ContentOffset`. When you scroll a list down by 100 pixels, the list's ContentOffset becomes (0, -100). This gets added to the drawing offset, shifting all child geometry upward. From the widget's perspective, nothing changed - children still draw at their original local coordinates. The offset trick creates the scrolling effect without touching child positions.

---

## Rendering Path: From Widgets to GPU

The rendering pipeline has three phases:

**Phase 1: Tree Traversal and Geometry Accumulation**

Starting at the application level (Application.cpp:435):

```cpp
void CWBApplication::Display(CWBDrawAPI *API)
{
    // Setup rendering context
    API->SetCropRect(GetClientRect());
    API->SetOffset(CPoint(0, 0));
    API->SetOpacity(255);

    // Clear last frame's batched geometry
    API->DisplayList.FlushFast();

    // Traverse widget tree, accumulating geometry
    if (Root)
        Root->DrawTree(API);

    // Upload and render in single draw call
    API->RenderDisplayList(Device, VertexBuffer, IndexBuffer);
}
```

Each widget's `OnDraw()` method emits primitives into the display list. Buttons draw rectangles for backgrounds, text layout emits glyph quads, borders draw line segments. Everything becomes vertices in a flat array.

**Phase 2: Primitive Batching with CPU-Side Clipping**

The workhorse is `CWBDrawAPI::AddDisplayRect()` (from the code trace at DrawAPI.cpp:17). This is where coordinate transforms, clipping, and batching happen. The key steps:

1. **Apply coordinate transform** - Add accumulated offset to convert local coords to screen space
2. **CPU-side scissor test** - Intersect geometry with crop rectangle, discard if outside
3. **UV adjustment** - When geometry is clipped, proportionally scale UVs to avoid texture distortion
4. **Hierarchical opacity** - Multiply parent opacity by widget opacity for transparency
5. **Batch management** - Flush if draw mode changes (textured vs solid)
6. **Vertex emission** - Append 4 vertices (quad as two triangles) to display list

The UV adjustment math is crucial for correct rendering. If the left edge of a quad gets clipped by 20% of its width, the U coordinate needs to advance by 20% of the UV range. Otherwise the texture would stretch across the clipped region, distorting the image. The code handles this proportionally:

```cpp
// If clipped != original, adjust UVs
if (Clipped != ScreenPos) {
    float leftClip = (Clipped.x1 - ScreenPos.x1) / ScreenPos.Width();
    float topClip = (Clipped.y1 - ScreenPos.y1) / ScreenPos.Height();

    float uvWidth = UV.Width();
    float uvHeight = UV.Height();

    AdjustedUV.x1 += leftClip * uvWidth;
    AdjustedUV.y1 += topClip * uvHeight;
    // ... same for right/bottom
}
```

This ensures textures map correctly even when widgets are partially scrolled out of view.

**Phase 3: GPU Submission**

Once tree traversal completes, all accumulated geometry gets uploaded and drawn in a single batch (DrawAPI.cpp:313):

```cpp
void CWBDrawAPI::RenderDisplayList()
{
    if (DisplayList.NumVertices == 0)
        return;

    // Lock vertex buffer with DISCARD flag (critical for performance)
    D3D11_MAPPED_SUBRESOURCE MappedResource;
    Context->Map(VertexBuffer, 0, D3D11_MAP_WRITE_DISCARD, 0, &MappedResource);

    // Upload all vertices in one memcpy
    CopyMemory(MappedResource.pData, DisplayList.Vertices,
               VertexCount * sizeof(UIVertex));
    Context->Unmap(VertexBuffer, 0);

    // Setup pipeline state (shader, texture atlas, blend mode)
    Context->IASetInputLayout(UIVertexLayout);
    Context->VSSetShader(UIVertexShader, nullptr, 0);
    Context->PSSetShader(UIPixelShader, nullptr, 0);
    Context->PSSetShaderResources(0, 1, &AtlasTexture);
    Context->OMSetBlendState(AlphaBlendState, nullptr, 0xFFFFFFFF);

    // Single draw call renders entire UI
    int IndexCount = (VertexCount / 4) * 6;  // Each quad = 6 indices
    Context->DrawIndexed(IndexCount, 0, 0);

    // Clear for next frame
    DisplayList.FlushFast();
}
```

The `D3D11_MAP_WRITE_DISCARD` flag is the key optimization. Without it, mapping the buffer would stall the CPU until the GPU finishes reading the previous frame's data - a pipeline bubble that tanks frame rate. With DISCARD, DirectX allocates a new region from a ring buffer, letting the CPU write while the GPU reads old data. No stall, smooth 60fps.

The index buffer pattern is standard: each quad uses indices `[0,1,2, 0,2,3]` to form two triangles. This shares vertices, cutting bandwidth by 33% compared to emitting six unique vertices per quad.

---

## Unified Texture Atlas: Zero Texture Binds

Every visual element in Whiteboard's UI - button backgrounds, icons, text glyphs, scrollbar skins - references a single texture atlas. This is the linchpin of batch-friendly rendering. Since all geometry uses the same texture, there's no reason to split batches. Thousands of quads can render in one draw call.

The atlas structure (conceptual, from trace context):

- **1x1 white pixel** - Used for solid color fills by sampling this texel and modulating with vertex color
- **9-slice skins** - Resizable button backgrounds, scrollbars, panels
- **Font glyphs** - Character rectangles for text rendering
- **Icons** - Decorative elements, tool icons, checkbox marks

When a widget wants to draw a solid color, it references the white pixel's UV coordinates (typically something like `[0.0, 0.0, 1.0/2048.0, 1.0/2048.0]`) and sets the vertex color to the desired hue. The pixel shader samples white, multiplies by the color, producing the requested shade.

When a widget wants to draw a textured element, it looks up the atlas handle for that skin component (e.g., `WB_ITEM_BACKGROUNDIMAGE` for a button's hover state), retrieves the UV rectangle, and submits a quad. The pixel shader samples the corresponding atlas region.

This approach eliminates texture binding overhead but requires careful atlas packing. The code trace doesn't detail the packing algorithm, but typical strategies include:

- Offline packing tools that arrange rectangles during asset build
- Runtime texture arrays for dynamic content (not possible in DX11 without extra complexity)
- Atlases partitioned by category (UI skins, fonts, icons) to simplify management

The downside is resolution limits. A single 2048x2048 atlas provides 4 megapixels of storage. For complex tools with many icons and font sizes, this can become constraining. Modern solutions like egui use texture arrays or bindless textures to scale beyond single-atlas limits, but in 2010-era DirectX 11, the unified atlas was the pragmatic choice.

---

## Font and Text Rendering

Text rendering in Whiteboard follows the same batched geometry model as other UI elements. Fonts are rasterized into the texture atlas, and text layout emits one quad per character.

The rendering process (from the code trace at Font.cpp:455):

**Step 1: Calculate Layout**

Given a string, bounding rectangle, and alignment mode, the font system computes:
- Line breaks (if text exceeds rect width)
- Cursor position for each character (accounting for kerning)
- Final text dimensions (for alignment)

**Step 2: Emit Glyph Quads**

For each character:
1. Look up glyph in atlas by character code
2. Apply kerning adjustment based on previous character (if kerning table exists)
3. Calculate glyph rectangle: `[cursor.x, cursor.y, cursor.x + glyph.width, cursor.y + glyph.height]`
4. Convert atlas pixel coordinates to normalized UVs: `[glyph.u1 / atlasWidth, ...]`
5. Submit quad via `DrawAPI->AddDisplayRect(glyphRect, glyphUV, color)`
6. Advance cursor by character width

The code handles newlines by resetting cursor.x and advancing cursor.y by line height. The layout pass computes alignment (left/center/right, top/middle/bottom) before emission by measuring total text bounds and adjusting the initial cursor position.

Kerning is crucial for professional typography. The font stores a lookup table of character-pair adjustments (e.g., "AV" should be spaced tighter than "AA"). The code applies this during layout:

```cpp
// From trace at Font.cpp:233
if (i > 0) {
    int kerning = GetKerning(Text[i - 1], c);
    Cursor.x += kerning;
}
```

Since glyphs are just textured quads in the atlas, text rendering benefits from the same batching as other UI. A paragraph of 500 characters becomes 500 quads in the display list, all using the same atlas texture. One draw call renders the entire block.

This approach is simple and fast but has limitations:

- **No subpixel anti-aliasing** - ClearType-style RGB subpixel rendering requires specialized shaders
- **Fixed atlas size** - Large fonts or wide character sets (CJK) can exhaust atlas space
- **No runtime glyph generation** - All needed glyphs must be pre-rasterized into the atlas

Modern UI libraries often use signed distance field (SDF) fonts to address these issues, encoding glyph shapes as distance fields for crisp rendering at any scale. Whiteboard predates widespread SDF adoption, sticking with the simpler rasterized atlas approach.

---

## Integration with CoRE2 Rendering Backend

Whiteboard sits atop CoRE2, apEx's DirectX 11 rendering abstraction. The separation of concerns is clean:

**Whiteboard responsibilities:**
- Widget tree management
- Input handling and event dispatch
- Geometry batching and coordinate transforms
- CPU-side clipping and opacity propagation

**CoRE2 responsibilities:**
- GPU buffer management (vertex buffer, index buffer)
- Shader compilation and pipeline state
- Texture atlas storage and sampling
- Render target management

The interface between layers is minimal. Whiteboard produces a flat array of `WBGUIVERTEX` structs (DrawAPI.h:21-48):

```cpp
struct WBGUIVERTEX {
    CVector4 Pos;    // Screen-space position (already transformed)
    CVector2 UV;     // Texture coordinates into atlas
    CColor Color;    // Modulation color (for tinting, opacity)
};
```

CoRE2 uploads this to a dynamic vertex buffer and issues a draw call. The shaders are trivial since positions are already in screen space - no matrix math needed:

```hlsl
// Vertex shader (conceptual, from trace context)
struct VSInput {
    float4 position : POSITION;
    float2 uv : TEXCOORD;
    float4 color : COLOR;
};

struct PSInput {
    float4 position : SV_POSITION;
    float2 uv : TEXCOORD;
    float4 color : COLOR;
};

PSInput VS(VSInput input) {
    PSInput output;
    output.position = input.position;  // Already in clip space
    output.uv = input.uv;
    output.color = input.color;
    return output;
}

// Pixel shader
Texture2D AtlasTexture : register(t0);
SamplerState LinearSampler : register(s0);

float4 PS(PSInput input) : SV_TARGET {
    float4 texColor = AtlasTexture.Sample(LinearSampler, input.uv);
    return texColor * input.color;  // Modulate by vertex color
}
```

The vertex shader is a passthrough. The pixel shader samples the atlas and modulates by vertex color, enabling both solid colors (white texel * color) and tinted textures (texture * color).

The system configures blend state for standard alpha blending:

```cpp
// Conceptual blend state setup
BlendDesc.RenderTarget[0].BlendEnable = TRUE;
BlendDesc.RenderTarget[0].SrcBlend = D3D11_BLEND_SRC_ALPHA;
BlendDesc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
BlendDesc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
```

This standard alpha-over-background blending suffices for UI, where widgets rarely need complex compositing modes. The hierarchical opacity system (where parent opacity multiplies child opacity) runs on the CPU during batching, so the GPU only sees pre-multiplied alpha values.

---

## Comparison with egui

Whiteboard and egui share the same core philosophy: immediate-mode API with retained-mode rendering optimization. Written a decade apart in different languages, they arrived at nearly identical solutions. The architectural parallels are striking:

**Similarities:**

1. **Immediate widget construction** - UI code runs every frame, rebuilding the widget tree from scratch
2. **Batched geometry submission** - Widgets emit primitives into a unified buffer, rendered in one draw call
3. **Unified texture atlas** - All UI elements reference a single texture to minimize state changes
4. **CPU-side clipping** - Geometry is scissored before GPU upload to save fill rate
5. **State-driven styling** - Visual properties (colors, fonts) are decoupled from widget structure

**Differences:**

1. **Language and memory model** - Whiteboard uses C++ with manual memory management; egui uses Rust with automatic memory safety
2. **Rendering backend** - Whiteboard targets DirectX 11; egui abstracts over wgpu, OpenGL, WebGL
3. **Layout system** - Whiteboard uses explicit parent-space rectangles; egui uses a constraint-based layout with automatic sizing
4. **Input model** - Whiteboard uses Win32 message loops; egui has a platform-agnostic input abstraction

The key philosophical difference is ownership. In Whiteboard, widgets are allocated every frame and deleted at frame end. This works because C++ allows manual control:

```cpp
// Whiteboard pattern
void DrawUI() {
    CWBButton *btn = new CWBButton(...);  // Heap allocation
    btn->SetText(L"Click me");
    // Widget gets deleted by framework at frame end
}
```

In egui, Rust's ownership rules require a different approach. Widgets aren't allocated at all - they're pure functions that consume state and return events:

```rust
// egui pattern
fn draw_ui(&mut self, ctx: &egui::Context) {
    if ctx.button("Click me").clicked() {
        // Handle click
    }
}
```

The egui button doesn't exist as an object. `ctx.button()` is a function call that emits geometry, updates internal state (hover, focus), and returns an event struct. This functional approach is arguably cleaner, but requires a runtime that tracks widget IDs across frames to maintain state (which egui accomplishes via hashing).

Both systems converge on the same performance characteristics: single-digit draw calls per frame, minimal GPU state changes, and sub-millisecond CPU overhead for typical UIs. The proof that this architecture works at production scale is evident in both apEx (a professional demotool used to create award-winning demos) and modern games using egui.

---

## Implications for Rust Frameworks

The Whiteboard architecture translates naturally to Rust with some adjustments:

### Adopt

**Immediate-mode API with batched rendering** - This pattern is proven. Use egui as a reference, but understand the core principles: UI as a pure function of state, geometry batching into unified buffers, minimal GPU commands.

**Unified texture atlas for UI** - Eliminates texture binding overhead. For modern Rust frameworks, consider:
- Texture arrays (supported in wgpu) for dynamic content
- Bindless textures (Vulkan/DX12) for virtually unlimited UI elements
- Runtime atlas packing for dynamic content

**CPU-side scissor clipping** - Reduces fragment shader load for partially visible widgets. Implement as an optimization pass during batching.

**Hierarchical opacity via vertex alpha** - Simpler and faster than shader-based compositing. Just multiply alpha down the tree.

**State-driven visual properties** - Separate widget behavior from appearance. Use Rust enums for state and trait-based property queries:

```rust
enum WidgetState {
    Normal,
    Hover,
    Active,
    Disabled,
}

trait StyledWidget {
    fn background_color(&self, state: WidgetState) -> Color;
    fn border_color(&self, state: WidgetState) -> Color;
}
```

### Modify

**Replace manual memory management with Rust ownership** - Instead of heap-allocating widgets every frame, use stack-allocated function calls like egui. This leverages Rust's zero-cost abstractions.

**Type-safe coordinate spaces** - Use newtype wrappers to distinguish local vs. screen coordinates at compile time:

```rust
struct LocalPos(Vec2);
struct ScreenPos(Vec2);

fn transform(local: LocalPos, offset: Vec2) -> ScreenPos {
    ScreenPos(local.0 + offset)
}
```

**Trait-based widget system** - Replace C++ virtual methods with Rust traits:

```rust
trait Widget {
    fn draw(&self, ctx: &mut DrawContext);
    fn state(&self) -> WidgetState;
}
```

**RAII guards for transform stack** - Avoid manual push/pop by using scoped guards:

```rust
impl DrawContext {
    fn with_offset(&mut self, offset: Vec2) -> OffsetGuard {
        self.offset_stack.push(offset);
        OffsetGuard { ctx: self }
    }
}

impl Drop for OffsetGuard<'_> {
    fn drop(&mut self) {
        self.ctx.offset_stack.pop();
    }
}

// Usage:
{
    let _guard = ctx.with_offset(vec2(10.0, 20.0));
    // Draw with offset
}  // Offset auto-pops on scope exit
```

**wgpu-friendly batching** - The DirectX 11 approach maps cleanly to wgpu:

```rust
// Upload vertices
queue.write_buffer(&vertex_buffer, 0, bytemuck::cast_slice(&vertices));

// Draw batched quads
render_pass.set_pipeline(&ui_pipeline);
render_pass.set_bind_group(0, &atlas_bind_group, &[]);
render_pass.set_vertex_buffer(0, vertex_buffer.slice(..));
render_pass.set_index_buffer(index_buffer.slice(..), wgpu::IndexFormat::Uint16);
render_pass.draw_indexed(0..index_count, 0, 0..1);
```

### Avoid

**Global mutable state in DrawAPI** - Rust's borrow checker will fight this. Use explicit context passing or interior mutability with `RefCell` if necessary.

**String-based property lookup** - Replace dictionary lookups with typed enums and pattern matching for compile-time safety and performance.

**Manual scissor math** - Use libraries like `glam` or `euclid` for rectangle operations. They provide optimized implementations and type safety.

**Dynamic vertex buffer with MAP_DISCARD semantics** - wgpu doesn't expose this directly. Instead, use `write_buffer()` which handles staging internally, or maintain a manual ring buffer if precise control is needed.

---

## Key Insights

Whiteboard demonstrates that immediate-mode UIs can achieve production-quality performance through intelligent architectural choices:

1. **Hybrid approach beats naive patterns** - Immediate-mode developer ergonomics don't require immediate-mode GPU submission. Batch everything.

2. **CPU-side optimization unlocks GPU efficiency** - Clipping geometry before upload saves more time than GPU scissor tests because you eliminate entire draw calls and reduce vertex processing.

3. **Unified resource binding is a force multiplier** - The texture atlas may seem like a constraint, but it enables the core performance win: minimal state changes. Modern techniques (texture arrays, bindless) extend this principle without the size limits.

4. **Hierarchical transforms simplify widget code** - When widgets operate in local coordinates, they don't need to know about ancestors. The framework manages complexity through the transform stack.

5. **State-driven styling is future-proof** - Decoupling appearance from behavior lets designers iterate on visuals without touching code. This pattern scales from simple buttons to complex themed UIs.

The fact that egui independently arrived at nearly identical solutions years later validates these design choices. Whiteboard is proof that good architecture transcends language and era - the principles of batched immediate-mode rendering are universal.

---

## Files Referenced

| File | Purpose | Key Insights |
|------|---------|--------------|
| `Bedrock/Whiteboard/Application.h:89` | Application entry point | Frame orchestration, display list management |
| `Bedrock/Whiteboard/GuiItem.h:152` | Base widget class | Tree structure, coordinate spaces, state queries |
| `Bedrock/Whiteboard/GuiItem.cpp:501` | Tree traversal implementation | Hierarchical transforms, crop rect propagation |
| `Bedrock/Whiteboard/Button.cpp:29` | Button rendering | State-based property queries, layered drawing |
| `Bedrock/Whiteboard/DrawAPI.h:57` | Batching API | Geometry accumulation, opacity, clipping |
| `Bedrock/Whiteboard/DrawAPI.cpp:17` | Primitive batching logic | Coordinate transform, UV adjustment, vertex emission |
| `Bedrock/Whiteboard/DrawAPI.cpp:313` | GPU submission | Dynamic buffer mapping, single draw call |
| `Bedrock/Whiteboard/Font.cpp:455` | Text layout | Glyph quads, kerning, alignment |
| `Bedrock/Whiteboard/Font.cpp:523` | Glyph rendering | Atlas lookup, UV calculation |
| `Bedrock/Whiteboard/CSSItem.h:5` | CSS integration | Styling abstraction, class-based selectors |
| `Bedrock/CoRE2/Core2.h` | Rendering backend | DirectX 11 abstraction (referenced, not traced) |

---

## Performance Characteristics

**Memory:**
- Display list capacity: Dynamic array, grows as needed (typical: ~2MB for 50k quads)
- Texture atlas: 2048x2048 RGBA = 16MB VRAM
- Per-widget overhead: ~200 bytes (transform, state, style properties)

**CPU Cost:**
- Tree traversal: O(n) where n = visible widgets
- Batching and clipping: O(n) where n = emitted quads
- Buffer upload: O(n) memcpy, typically <1ms for typical UIs

**GPU Cost:**
- Draw calls: 1 per frame (or per draw mode change, typically 2-4 total)
- Vertex count: ~200k vertices for complex tool UIs
- Fill rate: <10M pixels for 1920x1080 UI (most pixels are empty space)

**Bottlenecks:**
- CPU: Text layout for long strings with complex kerning
- GPU: Fragment shader on 4K displays with dense UI
- Memory: Atlas exhaustion with many large icons or font sizes

**Optimization Headroom:**
- Spatial hashing to skip traversal of invisible widgets
- Glyph cache to skip layout for static text
- Multithreaded batch building (tricky due to shared state)
- Texture arrays to bypass atlas size limits

This rendering pipeline demonstrates that immediate-mode UIs can achieve production-quality performance through intelligent batching and GPU-friendly data structures. The same principles apply to modern Rust frameworks targeting wgpu, Vulkan, or WebGPU.
