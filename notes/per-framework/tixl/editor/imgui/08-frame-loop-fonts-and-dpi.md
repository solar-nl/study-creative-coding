# Chapter 08: Frame Loop, Fonts and DPI - What Happens Before NewFrame()?

> *Dear ImGui promises "one function call per frame". The real work is everything you must do before and after that call.*

---

## The Problem: ImGui Draws Nothing Until You Feed It

Dear ImGui is a library that turns your widget calls into lists of triangles. It does not open a window, read the keyboard, pace the frame, upload textures or know how sharp a pixel is on your monitor. The backend (in ImGui terms, the `imgui_impl_*` files) does all of that. Most projects copy a stock backend and never look at it again, until the first 4K laptop screen shows blurry text, the first Alt+Tab leaves Ctrl stuck, or the first font size change crashes because the atlas was rebuilt in the middle of a frame.

tixl made a different choice: nothing comes from `imgui_impl_*`. It runs WinForms + SharpDX (DirectX 11) + ImGui.NET 1.91.x with docking, and it owns a hand-written backend. That makes the whole frame visible in one place, which makes it a good teacher. This chapter traces that frame in order, then follows two long-lived resources that must be rebuilt at safe moments (the font atlas and the style), and finally asks what the editor does when nobody is touching it.

**Mental model: a stage crew between acts.** ImGui is the performance, and each frame is one act. Anything that changes the stage itself (swapping the backdrop, resizing the set, loading a new floor plan) has to happen in the gap between acts, with the curtain down. If a crew member rebuilds the set while actors are on stage, someone gets hurt. Most of tixl's frame order is a list of "curtain down" jobs placed before `NewFrame()`, and "curtain up" jobs placed after it.

The existing chapters cover what happens inside the act (edits in [chapter 01](01-edit-lifecycle-and-undo.md), keystrokes and `FrameStats` in [chapter 02](02-input-routing-and-focus.md)). This chapter covers the gaps. At the end we translate the practices for a Rust editor on dear-imgui-rs 0.8, dear-imgui-wgpu and dear-imgui-winit.

> **Scope note.** All paths are relative to `visual-programming/tixl/` and cited as `file:line`. Claims inferred from reading rather than running are labeled **unverified**. Layout loading is only touched on briefly here; [chapter 09](09-windows-docking-and-layouts.md) owns it. The stall watchdog belongs to [chapter 10](10-per-frame-performance.md).

---

## How Does the Loop Get Driven?

tixl does not write its own `while running` loop. `Editor/Program.cs:278` calls `ProgramWindows.Main.RunRenderLoop(RenderCallback)`. That forwards to SharpDX `RenderLoop.Run(Form, callback)` (`Editor/App/AppWindow.cs:139-143`), which runs the Win32 message pump and invokes the callback whenever no messages are pending. In effect it is "drain the OS queue, then draw one frame, repeat".

Input arrives through the same form. `Editor/App/ImGuiDx11RenderForm.cs` overrides `WndProc` (:147 onward) and writes straight into ImGui's IO: `io.MouseDown[button]` (:196), `AddInputCharacter` (:231), `AddFocusEvent` (:238) and `AddKeyEvent` (:297). A file dragged over the window sets `MousePos` in `OnDragOver` (:142). One quirk: messages that arrive before `CreateContext` are dropped (:164-168), because ImGui 1.91 asserts if you touch IO without a context.

The consequence is a clean rule: input is written into IO between frames (during the message pump), and the frame callback only reads it. Nothing mutates input mid-frame.

---

## What Is the Exact Order of One Frame?

Here is where it gets interesting. `RenderCallback` in `Editor/UiContentDrawing/WindowsUiContentDrawer.cs` does seventeen distinct things, and the order is not arbitrary.

| # | Step | Where | Why it sits here |
|---|------|-------|------------------|
| 1 | `ProgramWindows.WaitForFrameLatency()` | `WindowsUiContentDrawer.cs:119` | Pace the frame on the DXGI waitable object before doing any work |
| 2 | Lock `_contextLock`, `SetCurrentContext` | :122-124 | The context is shared with other threads |
| 3 | `SetupResourcesAndFontsWithScaling()` | :125 | Font rebuild must precede NewFrame |
| 4 | If minimized and `SuspendRenderingWhenHidden`: `Sleep(100)`, return | :127-130 | Cheapest exit, taken before any ImGui work |
| 5 | `TakeMeasurement()` sets DeltaTime from a Stopwatch | :133, `Editor/UiContentDrawing/UiContentUpdate.cs:129-135` | No clamp |
| 6 | `io.DisplaySize = Main.Size` | :136 | Must be current at NewFrame |
| 7 | `LoadIniSettingsFromMemory` if a layout is pending | :143-147 | Layout can only change between frames (see [chapter 09](09-windows-docking-and-layouts.md)) |
| 8 | `ReconcileStuckModifiers()` | :151 | Alt+Tab drops key-up events |
| 9 | `ImGui.NewFrame()` | :153 | The curtain goes up |
| 10 | `OutputPresentation.UpdatePresentation()` | :163 | Evaluates and renders output-bound composites, after NewFrame |
| 11 | Output and viewer window blits | :165-205 | Copy results to their windows |
| 12 | `Main.PrepareRenderingFrame()` | :207 | Bind render target view, clear |
| 13 | `T3Ui.ProcessFrame()` | :212 | The whole UI build |
| 14 | `ImGui.Render()`, then `RenderDrawData(GetDrawData())` | :215, :222 | Triangles to the GPU |
| 15 | On `SEHException`, call `EndFrame` | :224-235 | Never leave a frame half-open |
| 16 | UI capture | :239 | Screenshot hook |
| 17 | `Present(UseVSync)` | :245 | Outside the lock, so blocking does not hold other threads |

Context setup happens once, before the loop (:71-79): `CreateContext`, `BackendFlags |= HasMouseCursors | RendererHasVtxOffset`, and `ConfigFlags |= DockingEnable`. Error recovery is configured at :91-94: `ConfigErrorRecovery` on with a tooltip and debug log, while assertions are disabled. And `IniFilename = null` (:280) tells ImGui never to touch an ini file by itself.

A condensed picture of the same sequence:

```
  PACE            CURTAIN DOWN (safe to change the world)       CURTAIN UP
 +-------+   +-----------------------------------------------+   +-------------------+
 | wait  |-->| lock ctx -> fonts -> minimized? -> dt ->      |-->| NewFrame          |
 | frame |   | display size -> pending ini -> fix modifiers  |   |  -> eval outputs  |
 | slot  |   +-----------------------------------------------+   |  -> clear RTV     |
 +-------+                                                       |  -> ProcessFrame  |
                                                                 |  -> Render + draw |
                                                                 |  -> (EndFrame on  |
                                                                 |      exception)   |
                                                                 +---------+---------+
                                                                           |
                                         unlock ctx  <------ Present(vsync)
```

### What Does ProcessFrame Do Inside the Act?

`T3Ui.ProcessFrame` (`Editor/Gui/T3Ui.Update.cs:32` onward) is the UI build. In order: drag-and-drop handling (:37), `CustomComponents` and `FormInputs` `BeginFrame` (:40-41), playback and audio sync (:53-54), `KeyActionHandling.InitializeFrame` (:82), `DockSpaceOverViewport()` (:96), `WindowManager.Draw()` (:99), `FrameStats.CompleteFrame()` (:107), global key actions (:108), the menu bar (:113-116) and dialogs (:119-131).

Note the `FrameStats.CompleteFrame()` call at :107. It swaps `(Current, Last) = (Last, Current); Current.Clear();` (`Editor/Gui/FrameStats.cs:14-15`). That is the one-frame lag from chapter 02: everything drawn this frame writes `Current`, and the swap happens once near the end of the build, so the next frame reads it as `Last`.

### The Interleaved Evaluation Order

Evaluation of the node graph does not live in one place, which is worth knowing before you copy the structure:

- Output-bound composites evaluate right after `NewFrame` and before the UI build (`WindowsUiContentDrawer.cs:163`).
- The main Output window evaluates inside `WindowManager.Draw()`. That comes from `.agentic/Plans/Plan_FrameTiming.md:49`; it is **not confirmed** in the OutputWindow code.
- `Playback.Update` runs inside `ProcessFrame`, so composites evaluated at :163 see the previous frame's time (`Plan_FrameTiming.md:44-46`).

So time advances after the work that consumed it. That is a one-frame lag on animation, the same shape of lag as `FrameStats.Last`, but here it is an accident of ordering rather than a design.

---

## Why Write the DX11 Backend by Hand?

You might wonder why a project would give up the stock backend. The code suggests two reasons (the second is partly **inferred**). First, the render engine and ImGui share one D3D11 device context, so the UI renderer cannot assume it owns the pipeline. Second, tixl shows engine textures inside the UI, which needs a cheap path from "a GPU texture" to "an ImGui image".

### Draw Data to Triangles

Each frame, `RenderDrawData` works like this (`WindowsUiContentDrawer.cs`):

- **Buffers.** Dynamic vertex and index buffers are recreated only when too small, with slack of `TotalVtxCount + 5000` and `TotalIdxCount + 10000`, and they never shrink (:293-337). The data goes in with one `Map(WriteDiscard)` per frame.
- **Indices.** 16-bit indices (:316, `R16_UInt` at :386) combined with the `RendererHasVtxOffset` backend flag (:78). With that flag ImGui can emit meshes larger than 65,535 vertices, and the draw call applies the offset: `DrawIndexed(ElemCount, idxOffset + IdxOffset, vtxOffset + VtxOffset)` (:427-429).
- **Projection and clipping.** An orthographic matrix from `DisplaySize` (:349). `DisplayPos` is subtracted from clip rects (:420), and each command sets its own scissor rectangle (:621).
- **Shaders.** Inline HLSL, `vs_4_0` and `ps_4_0` (:529-594).
- **No user callbacks.** `UserCallback != 0` throws `NotImplementedException` (:414-417).

### Textures: The ID Is the Pointer

`ImTextureID` is the raw `ID3D11ShaderResourceView*`. The draw loop reuses one wrapper object, sets `_customImageView.NativePointer = cmd.TextureId`, binds it, draws, and zeroes it (:425-433). Reusing the wrapper avoids a per-command allocation, which matters in a UI that follows a no-allocation rule ([chapter 10](10-per-frame-performance.md)).

Showing an engine texture is therefore trivial: pass its SRV pointer as the texture id. The hard part is lifetime. `SrvManager` caches one SRV per texture (`T3Ui.Update.cs:81`) so each frame hands ImGui a stable pointer instead of creating views on the fly.

### Politeness to the Shared Context

Because the context is shared, the renderer saves the full pipeline state before drawing and restores it afterwards (:353-376 and :441-461). One sampler serves everything: linear filtering, wrap addressing, `MaximumLod = float.MaxValue` (`Editor/UiContentDrawing/FontAtlasGenerator.cs:137-149`).

---

## How Does the Font Atlas Survive a Scale Change?

Fonts are where "curtain down" matters most. The atlas is one texture holding every glyph at the sizes you baked, and ImGui reads it while building draw data. Rebuild it mid-frame and widgets that already queried glyph metrics disagree with the texture the GPU samples. `.agentic/Plans/Plan_MultiViewport.md:51` states the rule explicitly: never rebuild the atlas mid-frame, or while a viewport renders.

### The Trigger: A Cheap Check Every Frame

Step 3 of the frame table, `SetupResourcesAndFontsWithScaling` (`Editor/UiContentDrawing/UiContentUpdate.cs:17-34`), compares the current scale with the one the atlas was built for. It rebuilds only when `|UiScaleFactor - _lastUiScale| > 0.005`, or when no atlas exists yet. The user scale is clamped to at least 0.1 (:24-25). A separate `RequestFontRebuild()` (:40-43) simply clears the "built" flag, so the next frame's step 3 rebuilds before `NewFrame`. `WM_DPICHANGED` calls it, which means the OS never rebuilds fonts itself; it only leaves a note for the next gap between acts.

### The Rebuild

`GenerateFontsWithScaleFactor` (:45-77) does the following:

1. Computes `dpiAwareScale = UserScale * (GetDpiForWindow / 96)` (:48-49) and stores it in `T3Ui.UiScaleFactor` (:51).
2. Calls `Fonts.Clear()` (:54).
3. Adds each font at `px * dpiAwareScale` (:61-74): Inter Regular and SemiBold at 16, Inter Regular at 12, Inter Light at 30, and JetBrainsMono at 18.
4. Restricts glyph ranges (:96-106) to Latin (0x20-0xFF), punctuation (0x2010-0x205E), arrows (0x2190-0x21FF), symbols (0x2600-0x26FF) and dingbats (0x2700-0x27BF). The ranges live in a pinned static `ushort[]` because ImGui reads them only during `Build`; if the array moved or was collected before then, the atlas would read garbage.

The key insight: fonts are baked at the final pixel size. There is no "draw at 16 and stretch". That is why the scale factor must be known before the atlas is built, and why a scale change costs a full rebuild.

### Icons Are Not a Font

Icons (`FontAtlasGenerator.cs:34-159`) do not come from a TTF. The generator calls `AddFontDefault` as a host font (:49), registers each PNG sprite with `AddCustomRectFontGlyph` (:55), and after `Build` it blits the pixels into the CPU RGBA32 atlas (:61-105). Sheets come in 1x, 2x and 3x, and the nearest to the current scale wins (`Editor/Gui/Styling/Icons.cs:350-356`, `FontAtlasGenerator.cs:15-32`). Icon size is `15 * iconScaleFactor` (:50). The upload is a new immutable `Texture2D` plus SRV (:115-135), and `io.Fonts.TexID` is set to that SRV pointer (:135).

This design gives full-color icons mixed into text, at the price of owning the blit code. Typography choices are covered in [chapter 06](06-theming-and-widget-library.md).

---

## Trace: The User Drags the Window to a Higher-DPI Monitor

1. Windows sends `WM_DPICHANGED`. The raw `WndProc` catches it, for the Main form only (`ImGuiDx11RenderForm.cs:156-162`). It calls `RequestFontRebuild()`. The code that resizes the window to the suggested rectangle was not found in this trace.
2. The message pump empties. `RenderLoop` calls `RenderCallback` for the next frame.
3. Step 1 paces. Step 2 takes the context lock.
4. Step 3 sees the "built" flag cleared. `GenerateFontsWithScaleFactor` reads `GetDpiForWindow` (now, say, 144, so a factor of 1.5), multiplies by the user scale and stores the result in `T3Ui.UiScaleFactor`.
5. `Fonts.Clear()`, every font is re-added at `px * 1.5`, icons are re-blitted from the nearest sheet, and a new SRV becomes `io.Fonts.TexID`.
6. Step 9 `NewFrame()` runs against a consistent atlas. Custom UI code that multiplies pixel literals by `UiScaleFactor` now draws at 1.5x.
7. Style values set at startup do not change. See the next section.

---

## Stated Rule vs. Code: "Every Pixel Literal Must Be Scaled"

The contributor rules say: *"Every pixel literal must be multiplied by T3Ui.UiScaleFactor. No exceptions."* (`.agentic/AGENT_INSTRUCTIONS.md:174`). For custom drawing that holds. Examples: `CustomComponents.cs:471-472` and `Buttons.cs:126`.

The code departs from the rule in the places ImGui itself owns:

| Stated rule or flag | What the code does |
|---------------------|--------------------|
| "Every pixel literal multiplied by `UiScaleFactor`" (`AGENT_INSTRUCTIONS.md:174`) | True for custom UI. `T3Style.Apply` (`Editor/Gui/Styling/T3Style.cs:32-103`) sets unscaled constants: `FramePadding` (7,4) (:30, :91), `ScrollbarRounding` 2 (:98), `TabRounding` 2 (:103), `WindowPadding` 0. |
| Style follows scale | `T3Style.Apply` runs once at startup (`Program.cs:273`). Whether the padding is re-applied anywhere else was **not checked**. |
| `ScaleAllSizes` adapts the style | Never called in the Editor (grep found none). |
| `DpiEnableScaleFonts` and `DpiEnableScaleViewports` are set (`WindowsUiContentDrawer.cs:274-275`) | These are old docking-branch auto-scaling flags. Since fonts are rebuilt manually, they are effectively cosmetic. |
| Logical pixels | `DisplayFramebufferScale` stays 1 (:705, :467). tixl works in physical pixels throughout and has no logical-pixel model. |

So at 200 percent scale the fonts and custom-drawn parts double, while ImGui's own padding and rounding stay at their 100 percent values. Whether that looks wrong in practice we did not observe (**unverified**); the point is that the rule covers the author's code and not ImGui's style struct.

### Where the Scale Comes From

DPI awareness is enabled at `Program.cs:117`, which calls `Application.SetHighDpiMode(HighDpiMode.PerMonitor)` (`MsForms/MsFormsEditor.cs:10`), per-monitor V1. `AppWindow.Dpi` reads `GetDpiForWindow(Form.Handle)` (`Editor/App/AppWindow.cs:97-100`). The code comment explains why: under V1, GDI `DpiX` and WinForms `DeviceDpi` go stale. The user's own multiplier is `UserSettings.Config.UiScaleFactor` (`Editor/Gui/UiHelpers/UserSettings.cs:102`), exposed as a slider from 0.1 to 5 (`Editor/Gui/Windows/SettingsWindow.cs:82-86`). How UI scale differs from canvas zoom is the subject of [chapter 03](03-zoomable-canvas.md).

---

## How Does a Frame Get Paced?

Pacing is where `Plan_FrameTiming.md` reads like a bug diary.

The swap chain is a flip-model chain with a `FrameLatencyWaitableObject` and `MaximumFrameLatency = 1` (`Editor/App/AppWindow.cs:183-199`). The comment at :191 reads: "A queue depth of 2 lets the loop run a frame ahead, so frame intervals alternate between ~0 and ..." In plain terms, with a queue of two the loop sprints ahead, then stalls, and the visible result is jitter. `Plan_FrameTiming.md` records the same: jitter from latency 2, fixed by latency 1 (:27-29). `WaitForFrameLatency` also drains surplus signals (`AppWindow.cs:208-219`), so a late frame does not leave extra "go" tokens that let two frames run back to back.

In stage terms, the waitable object is the cue that the next act may start. With a queue of two, the crew starts two acts back to back and then waits a long time; with a queue of one, each act starts exactly on its cue.

`Present` lives in `Editor/App/ProgramWindows.cs:382-481`. The sync interval is `useVSync ? 1 : 0` (:388). The main window (or the first bound output window) is the pacing window and does a blocking `Present`. Every other window uses `TryPresent(DoNotWait)` and drops the frame if the display is busy (:464-480). `UserSettings.TargetFrameRate` means vblanks per frame (`ProgramWindows.cs:400`). Two more notes from the plan: `Present(0)` on a flip-model chain is not uncapped without `ALLOW_TEARING` (:30-36), and nothing queries the display refresh rate (:62-65).

DeltaTime is another loose end. It comes from a Stopwatch with no clamp (`UiContentUpdate.cs:129-135`). `Plan_FrameTiming.md:52-61` notes that no delta time reaches operators and that `LastFrameDuration` is measured mid-frame, also unclamped. A stall (breakpoint, window drag, long load) therefore feeds one huge delta into the next frame.

---

## What Does the Editor Do When Nothing Is Happening?

Nothing special. There is no idle throttling. tixl redraws continuously, paced by the vsync `Present` and the latency waitable. That is a defensible choice for an editor whose main content is a live visual, and a poor one for a laptop battery while you read a menu.

The only throttle is `SuspendRenderingWhenHidden` (default true, `Editor/Gui/UiHelpers/UserSettings.cs:107`): when the window is minimized, the callback sleeps 100 ms and returns (`WindowsUiContentDrawer.cs:127-130`). An unfocused but visible window is not throttled. A separate thread, the StallWatchdog, can present a stall overlay; that is the subject of [chapter 10](10-per-frame-performance.md).

---

## Gotchas

> **Verified** means confirmed in the traced source. **Unverified** means inferred.

1. **Font rebuild before NewFrame, always (verified).** Step 3 precedes step 9, and `Plan_MultiViewport.md:51` makes it a rule. `RequestFontRebuild` defers the work to the next frame for this reason.
2. **Alt+Tab drops key-ups (verified as a comment and a call).** `ReconcileStuckModifiers()` (:151) exists because the OS swallows the release. Without it Ctrl or Alt stays "held" and every shortcut from [chapter 02](02-input-routing-and-focus.md) misbehaves.
3. **ImGui 1.91 asserts on input before `CreateContext` (verified).** The form drops early messages (`ImGuiDx11RenderForm.cs:164-168`).
4. **Possible leak per scale change (unverified).** `CreateDeviceObjectsAndFonts` (`WindowsUiContentDrawer.cs:477-500`) does not visibly dispose the previous font SRV or sampler. Each rebuild may leave one behind.
5. **One-frame time lag (verified by plan, unconfirmed in code for the main Output window).** Playback updates after output composites are evaluated.
6. **Unclamped delta time (verified).** A long stall becomes one giant step.
7. **Style does not follow DPI (verified).** `T3Style.Apply` runs once and `ScaleAllSizes` is never called.
8. **`DpiEnableScale*` flags mislead (verified as set; effect inferred).** They suggest ImGui scales for you; fonts are rebuilt by hand, so they do nothing useful.
9. **Only one window blocks on Present (verified).** Secondary windows use `TryPresent(DoNotWait)` and drop frames rather than block (`ProgramWindows.cs:464-480`), so a busy second display does not stall the pacing window.
10. **Frame left half-open on exceptions (verified).** The `SEHException` handler calls `EndFrame` (:224-235), so the next `NewFrame` does not assert.

---

## Rust Translation: dear-imgui-rs 0.8, dear-imgui-wgpu, dear-imgui-winit

Everything below is a **recommendation**, built on APIs checked against dear-imgui-rs 0.8.0. You get a head start: winit already provides the loop and input plumbing that tixl hand-wrote in `WndProc`, and dear-imgui-wgpu already provides the renderer. You still own the order.

### Step 1: Write the Frame Order Down

A numbered comment block in one function is worth more than clever abstraction. Pace first, apply pending changes, then open the frame, evaluate, build, render, present.

```
1. pace          (Fifo present + desired_maximum_frame_latency = 1, or ControlFlow::Wait)
2. skip?         (minimized / occluded: return before any ImGui work)
3. apply pending (font/scale rebuild, then prepare_font_atlas; pending layout, see chapter 09)
4. frame inputs  (clamped delta_time, display size)
5. new_frame
6. evaluate/render graph to textures   <- decide this order explicitly
7. build UI
8. render + submit draw data
9. present
```

Item 6 is the part tixl left implicit. Decide whether the graph evaluates with this frame's time or last frame's, write it in a comment, and avoid tixl's accidental one-frame time lag by advancing time before evaluating.

### Step 2: Rebuild Fonts Only Between Frames, Then Reload the Texture

dear-imgui-wgpu exposes `prepare_font_atlas(&mut self, imgui_ctx: &mut Context)` (`src/renderer/mod.rs:271`), which calls `reload_font_texture` (`src/renderer/font_atlas.rs:14`). That is the reload path tixl's `CreateDeviceObjectsAndFonts` plays. The pattern is a pending flag consumed at step 3, never from inside the UI closure.

```rust
// step 3 of the frame, before new_frame
if app.scale_changed(&window) {
    let scale = window.scale_factor() as f32 * app.user_scale.max(0.1);
    rebuild_fonts(&mut imgui, scale);              // clear + add fonts at px * scale
    app.apply_style(&mut imgui, scale);            // see Step 3
    renderer.prepare_font_atlas(&mut imgui);       // upload the new atlas texture
    app.last_scale = scale;
}
```

Use the same tolerance idea as tixl (rebuild only when the scale moved by more than a small epsilon), and request the rebuild from `WindowEvent::ScaleFactorChanged` by setting the flag rather than rebuilding in the event handler. If you hold glyph range arrays, own them for as long as the atlas build needs them (a `Vec<u32>` stored in app state, not a temporary), the Rust equivalent of tixl's pinned static.

### Step 3: Pick One DPI Model and Write It Down

tixl works in physical pixels with `DisplayFramebufferScale = 1`, and that works except where style stays unscaled. In Rust you have two coherent options:

- **Physical pixels (tixl's model).** Bake fonts at `px * scale_factor * user_scale`, keep `display_framebuffer_scale` at 1, and rebuild the style from an unscaled base each time the scale changes. The 0.8 `Style` has setters such as `set_color(StyleColor, [f32;4])` (`src/style.rs:82`), `set_frame_padding` (:212) and `set_window_padding` (:139), but **no safe `scale_all_sizes`**. The C function is reachable as `dear_imgui_rs::sys::ImGuiStyle_ScaleAllSizes(self_: *mut ImGuiStyle, scale_factor: f32)`, so wrap it in a small unsafe helper that works on a fresh copy of the base style.
- **Logical pixels with a framebuffer scale.** `Io::set_display_framebuffer_scale([f32;2])` (`src/io.rs:1172`) and `display_framebuffer_scale()` (:1105) exist. dear-imgui-winit has a `HiDpiMode` and a `hidpi_factor` in its platform (`src/platform.rs:92-93`, `set_hidpi_mode` at :155), and it converts touch positions to logical coordinates with `window.scale_factor()` (`src/events.rs:162`).

Either is fine. What hurts is mixing them. Pick one, document it, and make sure the style follows it.

A minimal helper for the physical-pixel model, applied from step 3 of the frame:

```rust
fn apply_style(imgui: &mut Context, base: &StyleSnapshot, scale: f32) {
    let style = imgui.style_mut();
    base.write_into(style);                       // unscaled constants, e.g. frame padding, rounding
    unsafe { dear_imgui_rs::sys::ImGuiStyle_ScaleAllSizes(style.raw_mut(), scale) }
}
```

The shape matters more than the names (the accessor for the raw pointer is a sketch; check it against the version you use). Always start from the base, never from the already-scaled style, or repeated changes compound.

**Check before relying on `Io::set_font_global_scale`.** It exists at `src/io.rs:1098`, but its parameter is named `_scale`, which suggests it is a no-op in this binding. This is **unverified**; test it before using it as a shortcut for runtime scaling.

### Step 4: A Texture Registry With Invalidation

tixl's `SrvManager` maps engine textures to stable SRV pointers. In wgpu the equivalent is a registry from texture id to bind group, handed to ImGui as the `TextureId`. Entries need invalidation when the texture drops or resizes, or ImGui will hold an id that points at a destroyed resource. Keep the registry in app state and prune it at the same "curtain down" point as the font rebuild.

### Step 5: Icons as a Merged Icon Font

tixl blits PNG sprites into the atlas through custom rects. That gives colored icons but means owning pixel-level atlas code and three sheet resolutions. For a Rust editor the lower-cost route is a merged icon TTF with explicit, owned glyph ranges, so the icons scale with the same `px * scale` rule as text. Choose it unless you need multi-color icons.

### Step 6: Idle and Power

Pick a mode on purpose.

- **Event-driven.** winit `ControlFlow::Wait`, and call `request_redraw` on input and while an animation or playback is active. This is the laptop-friendly mode.
- **Continuous.** vsync `Fifo` with wgpu `desired_maximum_frame_latency = 1`, the same value tixl converged on after seeing jitter at 2.

In both modes, skip rendering when the window is minimized or occluded (tixl does the minimized case with a 100 ms sleep; with `ControlFlow::Wait` you can simply not request a redraw). Reset modifier state on focus loss, as tixl's `ReconcileStuckModifiers` does. Clamp `delta_time`, and feed `FrameStats`-style flags from [chapter 02](02-input-routing-and-focus.md) at one fixed point. Finally, never leave a frame half-open: if a panic or error unwinds out of the UI build, make sure the frame is ended or the context discarded before the next `new_frame`, using ImGui's error recovery rather than relying on assertions.

### Step 7: Layouts Go Where the Font Rebuild Goes

tixl loads a pending layout with `LoadIniSettingsFromMemory` before `NewFrame` (:143-147), in the same curtain-down window as the font rebuild. Do the same: a pending-layout slot consumed at step 3. [Chapter 09](09-windows-docking-and-layouts.md) covers the layout side.

---

## Summary

- ImGui needs a backend, and tixl's hand-written DX11 one shows every piece: pacing, input, buffers, textures and pipeline state.
- The frame order is "pace, apply pending changes, NewFrame, evaluate, build, render, present". Anything that changes the stage (fonts, layouts, display size) happens before `NewFrame`.
- Fonts are baked at final pixel size and rebuilt only between frames. The scale rule in the contributor docs covers custom UI, but ImGui's style is set once and never rescaled.
- Latency 1 fixed jitter. There is no idle throttling beyond a minimized sleep.
- In Rust: write the order down, rebuild then call `prepare_font_atlas`, choose one DPI model, rescale style from an unscaled base, and choose event-driven or Fifo-latency-1 pacing deliberately.

## Next Steps

For what happens inside step 13, see [chapter 02](02-input-routing-and-focus.md) for `FrameStats` and keyboard routing, and [chapter 03](03-zoomable-canvas.md) for how UI scale differs from canvas scale. Fonts and typography are in [chapter 06](06-theming-and-widget-library.md). Layouts loaded before `NewFrame` are covered in [chapter 09](09-windows-docking-and-layouts.md). The stall watchdog and per-frame performance rules are in [chapter 10](10-per-frame-performance.md). The [index](00-index.md) lists every chapter.
