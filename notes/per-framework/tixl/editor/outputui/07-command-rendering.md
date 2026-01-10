# Chapter 7: Command Rendering

> *Full GPU rendering pipeline for Command outputs*

## Key Insight

> **Command rendering's core idea:** Commands are recipes, not values—CommandOutputUi creates its own render targets, saves GPU state, runs the operator into those targets, then displays the resulting texture like any other image.

---

## The Problem: Rendering is Different

Every output type we've discussed so far has something in common: the operator produces a value, and the OutputUi displays it. A float is calculated, then drawn as a curve. A texture is created, then displayed in an image viewer.

But what about a 3D scene?

A 3D scene isn't a "value" you can just display. It's a *recipe* - a Command that says "set up these shaders, bind these textures, draw these meshes." The scene doesn't exist as pixels until someone actually executes that recipe on a GPU with a specific render target.

This is a fundamentally different problem. We don't just need to *display* the output - we need to *create* it first.

---

## Why Commands Need Special Treatment

You might wonder: can't we just let the operator render to the screen directly?

The problem is that **we don't control when the operator runs**. The evaluation system runs operators in dependency order, not in "convenient for rendering" order. By the time an operator's output is ready to display, we might be in the middle of drawing the editor UI, with totally different render targets bound.

Even worse: the same output might need to display in multiple places. The graph view shows a thumbnail. A dedicated output window shows a larger version. A pop-out viewer shows it fullscreen. Each needs its own render.

The solution is for `CommandOutputUi` to manage its own render targets. It creates private textures, sets them up as the GPU's output, runs the operator, then displays the resulting texture like any other image.

Think of it like taking a photograph. The Command is the scene. CommandOutputUi is the camera. It points the camera (sets up render targets), takes the shot (runs the operator), then shows you the photo (displays the texture).

---

## The Architecture: Owning the Pipeline

CommandOutputUi is unique among output renderers: it owns GPU resources.

```csharp
internal sealed class CommandOutputUi : OutputUi<Command>
{
    // Render resources
    private Texture2D _colorBuffer;
    private RenderTargetView _colorBufferRtv;
    private ShaderResourceView _colorBufferSrv;
    private Texture2D _depthBuffer;
    private DepthStencilView _depthBufferDsv;
}
```

Let's unpack what each of these is for:

- **_colorBuffer**: The texture where the scene is rendered. This is what we eventually display.
- **_colorBufferRtv**: A "RenderTargetView" - the GPU's handle for writing to the texture.
- **_colorBufferSrv**: A "ShaderResourceView" - the handle for reading from the texture when we display it.
- **_depthBuffer**: Stores depth information for 3D rendering (which pixel is in front).
- **_depthBufferDsv**: A "DepthStencilView" - the GPU's handle for the depth buffer.

You might wonder why we need separate "views" for the same texture. This is a Direct3D design pattern: the same texture memory can be accessed in different ways depending on what you're doing with it. Writing pixels? Use the RTV. Reading in a shader? Use the SRV. The views tell the GPU which access pattern to expect.

---

## The Key Override: Recompute()

Remember from Chapter 1 that the base class's `Recompute()` just invalidates the slot and calls `Update()`. That's fine for floats and textures - the operator calculates its value into the slot.

But Commands need more. They need render targets to be set up *before* they run. They need the GPU state restored *after* they run.

CommandOutputUi overrides `Recompute()` to wrap the evaluation in pipeline management:

```text
Normal Output:
    Invalidate → Update → Done

Command Output:
    Create/Resize Textures
    Save Current GPU State
    Bind Our Render Targets
    Clear Buffers
    Invalidate → Update (operator renders to our targets)
    Render Grid Gizmo (optional)
    Restore Previous GPU State
```

This is the key insight: **CommandOutputUi creates a "clean room" for the operator to render into**, then cleans up after it.

---

## Walking Through the Render Pipeline

Let's trace exactly what happens when a Command output is displayed:

### Step 1: Ensure Textures Exist at the Right Size

The first question is: do we have render targets, and are they the right size?

```csharp
var size = context.RequestedResolution;
UpdateTextures(device, size);
```

The `RequestedResolution` comes from the evaluation context - it might be 1920x1080 for fullscreen output, or 256x256 for a thumbnail. If our textures don't match, we need to recreate them.

Why not just create huge textures and use a portion? Memory. A 4K HDR texture is 64MB. Creating multiple at startup would waste GPU memory that could be used for actual content.

### Step 2: Save the Current GPU State

Before we change anything, we save what's currently bound:

```csharp
deviceContext.OutputMerger.GetRenderTargets(out var prevTargets);
```

This is crucial. The editor is in the middle of drawing its UI. If we just bind our targets and forget, subsequent UI drawing would go to our texture instead of the screen. Chaos.

### Step 3: Bind Our Render Targets

Now we tell the GPU: "Everything you render goes to my textures."

```csharp
deviceContext.OutputMerger.SetTargets(_depthBufferDsv, _colorBufferRtv);

deviceContext.Rasterizer.SetViewport(new Viewport(
    0, 0,
    size.Width, size.Height,
    0.0f, 1.0f
));
```

The viewport is important - it tells the GPU what region of the texture to render to. We use the full texture, but this could be used for split-screen effects.

### Step 4: Clear the Buffers

Start with a clean slate:

```csharp
var bgColor = context.BackgroundColor;
deviceContext.ClearRenderTargetView(_colorBufferRtv,
    new RawColor4(bgColor.X, bgColor.Y, bgColor.Z, bgColor.W));
deviceContext.ClearDepthStencilView(_depthBufferDsv,
    DepthStencilClearFlags.Depth | DepthStencilClearFlags.Stencil,
    1.0f, 0);
```

The background color comes from context - different scenes might want different backgrounds. The depth buffer is cleared to 1.0 (far plane) so everything rendered will be "in front" of the empty scene.

### Step 5: Run the Operator

This is the payoff. The operator runs, executing its Command, and the results land in our texture:

```csharp
StartInvalidation(slot);
slot.Update(context);
```

The operator has no idea it's rendering to a special texture. It just runs its normal rendering code. The magic is that we've redirected where the GPU writes.

### Step 6: Render the Grid Gizmo (Optional)

For 3D scenes, a reference grid helps with orientation:

```csharp
if (context.ShowGizmos != GizmoVisibility.Off)
{
    RenderGridGizmo(context);
}
```

The grid is itself an operator (looked up by GUID). We run it after the main operator so it renders on top. This is a nice example of composition - the grid is just another Command that renders to the same targets.

### Step 7: Restore Previous State

Finally, put everything back:

```csharp
deviceContext.OutputMerger.SetTargets(prevTargets);

// Clean up (GetRenderTargets increments refcount)
foreach (var target in prevTargets)
    target?.Dispose();
```

The dispose call is subtle but important. `GetRenderTargets` increments the reference count on the returned views (a COM pattern). If we don't dispose them, we leak references and the original textures can never be freed.

---

## Texture Creation: The Details Matter

Creating render targets involves several decisions:

### Color Buffer Format: HDR

```csharp
Format = Format.R16G16B16A16_Float,  // HDR
```

Why 16-bit float per channel instead of the typical 8-bit? **HDR (High Dynamic Range)**.

With 8-bit color, brightness values are clamped to 0-1. A sun that's 10x brighter than white just shows as white. With 16-bit float, we can represent that 10x brightness, then apply tone mapping later to compress it for display.

This matters for realistic lighting, bloom effects, and physically-based rendering. The extra memory cost (2x vs 8-bit) is worth it for visual quality.

### Depth Buffer Format: Typeless

```csharp
Format = Format.R32_Typeless,  // Allows both depth and shader access
```

You might wonder why "Typeless" instead of just "D32_Float" for depth.

The trick is that we might want to use the depth buffer for effects later - soft shadows, depth of field, fog. To read it in a shader, we need a ShaderResourceView. To write depth, we need a DepthStencilView.

With a typed format like D32_Float, we could only create the DepthStencilView. With R32_Typeless, we can create both:

- D32_Float view for depth testing
- R32_Float view for shader reading

Same memory, two interpretations.

### BindFlags: Multiple Uses

```csharp
BindFlags = BindFlags.RenderTarget | BindFlags.ShaderResource,
```

These flags tell Direct3D what we plan to do with the texture. `RenderTarget` means we'll write to it from the GPU. `ShaderResource` means we'll read it in shaders (specifically, when displaying it).

Both flags must be specified at creation time. You can't add capabilities later.

---

## The Grid Gizmo: Lazy Loading

The grid gizmo is an interesting detail. It's a standard operator (defined elsewhere in the project) that CommandOutputUi loads on demand:

```csharp
private void EnsureGridInstance()
{
    if (_gridInstance != null)
        return;

    var gridSymbolId = Guid.Parse("e5588101-5686-4b02-ab7d-e58199ba552e");
    var gridSymbol = SymbolRegistry.Entries[gridSymbolId];

    _gridInstance = gridSymbol.CreateInstance(Guid.NewGuid());
    _gridOutputs = _gridInstance.Outputs.OfType<Slot<Command>>().ToArray();
}
```

Why lazy loading? Most users don't need the grid. Loading it on startup would waste time and memory. Instead, we wait until someone actually enables gizmos, then load it once and cache it.

The GUID is hardcoded, which is a bit fragile - if someone deletes or renames the grid operator, this breaks. But it's a core system operator that shouldn't change.

---

## Displaying the Result

After all that rendering, displaying is anticlimactic:

```csharp
protected override void DrawTypedValue(ISlot slot, string viewId)
{
    if (_colorBuffer == null)
    {
        ImGui.TextUnformatted("No render output");
        return;
    }

    ImageOutputCanvas.Current.DrawTexture(_colorBuffer);
    ProgramWindows.Viewer?.SetTexture(_colorBuffer);
}
```

The rendered texture is handed to `ImageOutputCanvas`, which knows how to display textures with pan and zoom. It's also sent to the Viewer window for fullscreen display.

The key insight is that **after rendering, a Command output looks just like a Texture output**. All the complexity was in *creating* the texture. Displaying it is trivial.

---

## Why This Complexity is Necessary

You might be thinking: this is a lot of machinery for displaying an output. Why not just have the main render loop handle it?

The answer is **encapsulation and flexibility**.

### Encapsulation

All the render target management is hidden inside CommandOutputUi. The rest of the system doesn't know or care that Command outputs are special. It just asks for a display, and gets one.

### Flexibility

Different Command outputs might want different things:

- Different resolutions (thumbnail vs fullscreen)
- Different formats (HDR vs LDR)
- With or without gizmos

By managing its own resources, CommandOutputUi can adapt to each situation.

### Multi-View Support

The same Command output might be displayed in multiple places. Each view calls `DrawValue`, but they all see the same rendered texture. We render once, display many times.

---

## Performance Considerations

CommandOutputUi has several optimizations worth noting:

### 1. Texture Reuse

Textures are only recreated when the size changes. Same-size renders reuse existing buffers. This avoids allocation churn.

### 2. Single-Pass Gizmos

The grid gizmo renders in the same pass as the main content. No additional render target switches.

### 3. Lazy Loading

The grid symbol is only loaded if gizmos are enabled. No startup cost for most users.

### 4. Potential Future Optimization: Resource Pooling

Currently each CommandOutputUi owns its own textures. A pooling system could share textures between outputs that need similar sizes, reducing memory usage. This isn't implemented yet but the architecture supports it.

---

## The Bigger Picture

CommandOutputUi represents a pattern that appears throughout graphics programming: **wrapping external resources with controlled lifecycle management**.

The pattern is:

1. Own the resources you need (textures, buffers)
2. Create them lazily or on demand
3. Recreate them when requirements change
4. Save and restore external state you modify
5. Clean up when done

This pattern shows up everywhere: in render pipelines, in resource managers, in pooling systems. CommandOutputUi is a clean example of it in a real codebase.

---

## Summary

1. **Commands are recipes, not values.** They need to be executed with render targets to produce a displayable result.

2. **CommandOutputUi owns its render targets.** Color buffer, depth buffer, and the views needed to use them.

3. **Recompute() wraps execution in pipeline management.** Save state, bind targets, clear, run operator, restore state.

4. **HDR format preserves dynamic range.** 16-bit float per channel allows overbright values and better quality.

5. **Typeless depth format enables dual use.** The same buffer can be used for depth testing and shader reading.

6. **After rendering, it's just a texture.** All the complexity is in creation; display is trivial.

---

## What's Next

- **[Chapter 8: Extending OutputUi](08-extending-outputui.md)** - How to create your own custom output renderers
