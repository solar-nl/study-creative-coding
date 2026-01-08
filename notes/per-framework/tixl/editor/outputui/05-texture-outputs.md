# Chapter 5: Texture Outputs

> *Visualizing 2D and 3D textures*

---

## The Problem: Images Are Not Numbers

When you're debugging a shader or image processing pipeline, the most important thing is to *see* what's happening. A shader might be technically correct but produce unexpected results because of a subtle misunderstanding. A post-processing effect might look wrong, and you need to see each stage to find where it breaks.

But displaying an image in a visual programming environment is surprisingly complex:

**Problem 1: Scale mismatch.** A 4K texture (3840x2160 pixels) won't fit in a small output preview. You need pan and zoom.

**Problem 2: Different viewing contexts.** Sometimes you want a tiny preview in the graph. Sometimes you want a full-screen view to examine details. Same texture, different presentations.

**Problem 3: Resource management.** GPU textures aren't like regular objects - they're resources that live on the graphics card, can be disposed at any time, and need special handling to display in ImGui.

**Problem 4: 3D textures.** A volume texture has depth. You can't just "show" a 3D texture - you need to slice through it.

Texture outputs solve all of these problems while maintaining the same clean architecture as scalar outputs.

---

## The Core Insight: Separation of Concerns

The solution splits responsibilities cleanly:

- **Texture2dOutputUi** decides *what* to display and handles texture-specific logic (null checks, array info, viewer sync)
- **ImageOutputCanvas** handles *how* to display it (pan, zoom, coordinate transforms, ImGui integration)
- **ScalableCanvas** (base class) provides the generic pan/zoom behavior

Think of it like a photo frame. The OutputUi is responsible for "which photo goes in the frame" and the Canvas is responsible for "how the frame displays photos." You can swap out photos without changing the frame, and you can change the frame style without affecting the photos.

---

## Texture2dOutputUi: The Most Common Case

Let's trace what happens when you view a 2D texture output.

### Step 1: Validate the Texture

```csharp
var texture = typedSlot.Value;

if (texture == null || texture.IsDisposed)
    return;
```

GPU resources can become invalid at any time - when the graphics device resets, when memory is reclaimed, when the operator that created them is removed. We check for both null and disposed before proceeding.

Why might a texture be disposed but not null? The slot still holds a reference to the texture object, but the underlying GPU resource has been freed. Attempting to use a disposed texture would crash, so we bail out early.

### Step 2: Handle Texture Arrays

```csharp
if (texture.Description.ArraySize > 1)
{
    ImGui.TextUnformatted($"Array-Size: {texture.Description.ArraySize}");
}
```

A texture array is multiple 2D textures stacked together - commonly used for cubemaps (6 faces), shadow map cascades, or animation frames. We display the array size so users know what they're looking at.

You might wonder: why not show a selector for which slice to view? That's a future enhancement. For now, we show the first slice and inform the user there are more.

### Step 3: Draw to the Canvas

```csharp
ImageOutputCanvas.Current.DrawTexture(texture);
```

This line is deceptively simple. Behind it, the canvas is:

- Transforming pixel coordinates to screen coordinates based on current pan/zoom
- Getting a shader resource view from the texture
- Drawing the image via ImGui's draw list
- Showing format information

### Step 4: Sync with External Viewer

```csharp
ProgramWindows.Viewer?.SetTexture(texture);
```

Here's a nice feature: the same texture can appear in a separate "Viewer" window. This lets users examine a texture full-screen while still seeing the graph.

The `?.` null-conditional operator means this is a no-op if no viewer window is open. Zero overhead when unused.

---

## ImageOutputCanvas: The Display Engine

The canvas handles all the complexity of interactive image display.

### Coordinate Transformation

The fundamental operation is transforming from *texture space* (pixels) to *screen space* (ImGui coordinates):

```csharp
var size = new Vector2(desc.Width, desc.Height);

var screenMin = TransformPosition(Vector2.Zero);
var screenMax = TransformPosition(size);
```

`TransformPosition` applies the current pan offset and zoom factor. If the user has zoomed to 2x and panned 100 pixels right, `TransformPosition(Vector2.Zero)` returns where the top-left corner of the texture should appear on screen.

This abstraction is powerful. The rendering code doesn't need to know about pan/zoom state - it just transforms coordinates and draws.

### Getting the Shader Resource View

```csharp
var srv = ResourceManager.GetShaderResourceView(texture);

drawList.AddImage(
    srv.NativePointer,
    screenMin,
    screenMax,
    Vector2.Zero,    // UV min
    Vector2.One      // UV max
);
```

ImGui can't draw a Texture2D directly - it needs a *shader resource view* (SRV), which is how the GPU's shader pipeline sees the texture. The SRV provides a native pointer that ImGui can use to reference the GPU resource.

The UV coordinates (0,0 to 1,1) mean we're showing the entire texture. If we wanted to show just a portion (say, for cropping), we'd adjust these values.

### Format Information Display

```csharp
var info = $"Format: {desc.Format}  {desc.Width}x{desc.Height}";
ImGui.SetCursorPos(new Vector2(5, 5));
ImGui.TextUnformatted(info);
```

The format overlay shows essential metadata: pixel format (R8G8B8A8_UNorm, R16G16B16A16_Float, etc.) and dimensions. This helps debugging - "why does my HDR texture look wrong? Oh, it's in UNORM format, not FLOAT."

---

## The ScalableCanvas Foundation

ImageOutputCanvas inherits from ScalableCanvas, which provides the pan/zoom behavior.

| Interaction  | Action              |
|--------------|---------------------|
| Mouse drag   | Pan the view        |
| Mouse wheel  | Zoom in/out         |
| Double-click | Fit image to window |

These interactions are so common in image viewers that users expect them without thinking. By putting them in a base class, every texture output automatically gets professional-quality navigation.

---

## Texture3dOutputUi: Slicing Through Volumes

3D textures present a unique visualization challenge. A volume texture might be 256x256x256 - that's 16 million voxels. You can't show them all at once.

The solution: **display a 2D slice** and let users scrub through the Z-axis.

### The Mental Model

Imagine a loaf of bread. You can't see inside the whole loaf, but you can cut a slice and examine it. That's exactly what Texture3dOutputUi does - it "cuts" the 3D texture at a specific Z position and shows that 2D slice.

```text
┌─────────────────────────────────────────────────┐
│  3D Texture: 256x256x64  Slice: 32/64           │
├─────────────────────────────────────────────────┤
│                                                 │
│                  ┌─────────┐                    │
│                  │         │                    │
│                  │ [Slice] │                    │
│                  │         │                    │
│                  └─────────┘                    │
│                                                 │
├─────────────────────────────────────────────────┤
│  Z-Slice: [====●===============] 32             │
└─────────────────────────────────────────────────┘
```

The slider at the bottom controls which slice you're viewing. Drag it to scrub through the volume and see how the data changes with depth.

### Why a Compute Shader?

You might wonder: why not just copy the slice data to the CPU and create a 2D texture?

The answer is **performance**. A 256x256 slice is 65,536 pixels. At 60fps, copying that much data from GPU to CPU and back would be painfully slow.

Instead, we use a compute shader that runs entirely on the GPU:

```hlsl
[numthreads(8, 8, 1)]
void main(uint3 DTid : SV_DispatchThreadID)
{
    float4 value = InputTexture[uint3(DTid.xy, ZPosition)];
    OutputTexture[DTid.xy] = value;
}
```

This shader reads from the 3D texture at the specified Z position and writes to a 2D texture. The entire operation happens on the GPU - no CPU round-trip, no data copying over the bus.

### The Dispatch

```csharp
context.Dispatch(
    (desc.Width + 7) / 8,
    (desc.Height + 7) / 8,
    1
);
```

The `+ 7) / 8` is a common pattern for compute shader dispatch. Since our thread group is 8x8, we need enough groups to cover the entire texture. For a 256x256 texture, that's 32x32 groups. For a 260x260 texture, we'd need 33x33 groups (the extra threads at the edges just don't write anything).

### Lazy Resource Creation

Notice how resources are created on demand:

```csharp
private void EnsureShaderLoaded()
{
    if (_sliceShader != null)
        return;

    _sliceShader = ResourceManager.LoadComputeShader(
        "Resources/lib/img/render-volume-slice-cs.hlsl"
    );
}
```

We don't load the compute shader until someone actually views a 3D texture. This is good for startup time - why load resources that might never be used?

---

## ShaderResourceViewOutputUi: The Raw Interface

Sometimes operators produce raw shader resource views rather than textures. This is lower-level - an SRV is just a "view" into GPU memory that shaders can read from.

The current implementation is minimal:

```csharp
ImGui.TextUnformatted($"ShaderResourceView: {srv.Description.Format}");
```

It just shows the format. Why not display the content? Because an SRV doesn't necessarily point to displayable image data - it could be a buffer of arbitrary floats, a structured buffer, or other non-image data. Safely displaying arbitrary SRVs requires more infrastructure.

This is an example of building incrementally. The class exists and handles the basic case. More sophisticated rendering can be added later without changing the architecture.

---

## Resource Lifecycle: A Critical Detail

GPU resources require careful handling. Let's trace the lifecycle:

```text
Operator creates Texture2D
        │
        ▼
Slot<Texture2D>.Value holds reference
        │
        ▼
Texture2dOutputUi.DrawTypedValue() is called
        │
        ├─── Check: IsDisposed? → If yes, bail out
        │
        ├─── Get ShaderResourceView → This is a "view" into the texture
        │
        └─── ImGui.AddImage(srv.NativePointer, ...) → Actual drawing
```

The key insight: **always check IsDisposed before using GPU resources**. Unlike managed objects that can't disappear while referenced, GPU resources can be explicitly disposed at any time. A disposed texture's memory might already be reused for something else.

---

## Viewer Window Integration

The external viewer window pattern deserves explanation:

```csharp
ProgramWindows.Viewer?.SetTexture(texture);
```

This creates a **secondary view** of the same texture. Why is this useful?

1. **Detail inspection**: The graph preview is tiny. The viewer window can be full-screen.
2. **Side-by-side comparison**: Compare the viewer (showing one output) with the graph (showing another).
3. **Persistent reference**: Keep watching a texture while navigating elsewhere in the graph.

The `?.` pattern is important - if no viewer window exists, this is a no-op. No null checking needed, no conditional logic cluttering the code.

---

## Common Texture Formats

When debugging, you'll see format names in the display. Here's what they mean:

| Format                 | Description                         | Use Case                   |
|------------------------|-------------------------------------|----------------------------|
| `R8G8B8A8_UNorm`       | 8-bit per channel, normalized [0,1] | Standard images            |
| `R16G16B16A16_Float`   | 16-bit float per channel            | HDR, intermediate buffers  |
| `R32G32B32A32_Float`   | 32-bit float per channel            | High precision computation |
| `R32_Float`            | Single channel, 32-bit float        | Depth buffers, masks       |
| `BC1_UNorm`            | Compressed (DXT1)                   | Asset textures             |
| `BC7_UNorm`            | High quality compression            | Asset textures             |

"UNorm" means unsigned normalized - values are stored as integers but interpreted as [0,1] floats. "Float" means actual floating-point storage, supporting values outside [0,1] and negative numbers.

Compression formats (BC1, BC7) are smaller but lose some quality. They're typically used for final art assets, not intermediate computation.

---

## Summary: From Pixels to Understanding

Texture outputs transform raw GPU resources into interactive, explorable images:

1. **Texture2dOutputUi** handles the common case - 2D images with pan/zoom and viewer sync
2. **Texture3dOutputUi** adds Z-slice navigation for volume data
3. **ImageOutputCanvas** provides the interactive display engine
4. **ScalableCanvas** gives every texture view professional navigation

The key design decisions:

- **Separation of OutputUi from Canvas** keeps each component focused
- **GPU-side slice extraction** avoids CPU round-trips for 3D textures
- **Viewer window sync** enables multiple views of the same texture
- **Defensive resource checking** handles the realities of GPU resource lifecycle
- **Format overlay** provides essential debugging information

The result: users can see their textures, zoom into details, scrub through volumes, and understand what their shaders are actually producing.

---

## Key Source Files

- `Editor/Gui/OutputUi/Texture2dOutputUi.cs`
- `Editor/Gui/OutputUi/Texture3dOutputUi.cs`
- `Editor/Gui/OutputUi/ShaderResourceViewOutputUi.cs`
- `Editor/Gui/Windows/ImageOutputCanvas.cs`

---

## What's Next

- **[Chapter 6: Collection Outputs](06-collection-outputs.md)** - How lists and dictionaries are visualized
- **[Chapter 7: Command Rendering](07-command-rendering.md)** - The full GPU render pipeline for Command outputs
