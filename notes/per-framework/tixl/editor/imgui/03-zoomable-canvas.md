# Chapter 03: The Zoomable Canvas - One Transform, Many Editors

> *Storing a zoom value is easy. Making it mean something, in five different editors, without blurry lines, is the actual job.*

---

## The Problem: A Zoom Value Nobody Applies

Picture a node-canvas widget with a `zoom: f32` field. The mouse wheel changes it. Nothing on screen changes. Every draw call still places nodes at `pos + pan`, because the code that should multiply by `zoom` was never written. Adding it means touching every draw call, every hit test, every drag handler. Miss one and a node draws at one scale while its click target sits at another.

That bug is the visible symptom of a deeper gap. A zoomable surface needs a single object that owns the mapping between "where things live" and "where pixels land". Without it, each editor reinvents the mapping slightly differently. The graph gets one rounding rule, the timeline another, and the curve editor flips its Y axis in a third way.

tixl solved this once, in `ScalableCanvas`, and reuses it across the node graph, the timeline, the curve editors, the variations browser and the image viewer. This chapter studies that component as a **reusable part**: what state it owns, how it moves smoothly, where subclasses plug in, and how it interacts with pixel-crisp drawing. We finish with a Rust design for a shared canvas in a `dear-imgui-rs` editor, built on tixl's own refactoring TODO.

The mapping math itself, plus fit, culling and draw lists inside MagGraph, is already covered in [MagGraph Chapter 14: Canvas Rendering](../maggraph/14-rendering-canvas.md). Read that first if you have not. Here we skip those basics and focus on reuse, input, pixel rules, UI scale versus canvas scale, and level-of-detail thresholds. For frame-cost considerations see [MagGraph 18: Performance](../maggraph/18-performance.md), and for general ImGui idioms see [MagGraph B: ImGui Patterns](../maggraph/B-imgui-patterns.md).

---

## The Mental Model: A Camera on a Table

Think of the canvas as a camera hovering over a huge table. The nodes, keyframes or thumbnails lie on the table at fixed positions, measured in table units. Those units never change. The camera has two properties: where it points (the **scroll**, the table coordinate under the window's top-left corner) and how close it is (the **scale**). Zooming moves the camera closer. Panning slides it sideways. The table does not care.

Two consequences follow, and both drive the design:

1. **Canvas units are unscaled and DPI-free.** A node at (100, 200) stays at (100, 200) whether you view it on a laptop or a 4K display, zoomed in or out.
2. **Scale is a `Vector2`, not a float.** A timeline wants to stretch time horizontally without touching value rows. A curve editor wants Y pointing up, which means a *negative* Y scale. The analogy still holds: think of a camera with a squeezable lens.

If you keep this picture in mind, everything below is detail about how the camera is steered smoothly, and how the pictures it takes stay sharp.

---

## What the Component Owns

`ScalableCanvas` (`Editor/Gui/Interaction/ScalableCanvas.cs`) holds six pieces of state:

| State | Lines | Meaning |
|-------|-------|---------|
| `WindowPos`, `WindowSize` | 179-180 | Where the canvas sits on screen this frame |
| `Scale`, `ScaleTarget` | 182-183 | Current (damped) and wanted zoom, as `Vector2` |
| `Scroll`, `ScrollTarget` | 187-188 | Current and wanted canvas coordinate at the window's top-left |

The *current* values are what you draw with. The *target* values are where input pushes. Each frame the current values chase the targets. This split is the heart of the smooth feel: input is instant, presentation is eased.

A negative Y scale marks a curve canvas: `IsCurveCanvas => Scale.Y < 0` (463). The same transform code handles the flip for free, because multiplication by a negative number is the flip.

---

## The Transform Family

The core mapping is two lines, shown in Chapter 14 and repeated here because every variant below derives from it:

```
TransformPositionFloat:        (posOnCanvas - Scroll) * Scale + WindowPos     // :73
InverseTransformPositionFloat: (screenPos - WindowPos) / Scale + Scroll       // :107
```

Around those two lines, tixl grew a family. The differences are about rounding, and they matter more than they look.

| Method | Lines | Behavior |
|--------|-------|----------|
| `TransformPositionFloat` | 73 | Exact float result |
| `TransformPosition` | 77-81 | **Truncates** to int |
| `TransformX` | 87 | Truncated to int |
| `TransformY` | 96 | Float, not truncated |
| `TransformDirection` | 132 | `T(v) - T(0)`, so translation cancels |
| `TransformDirectionFloored` | 137 | Floored direction |
| `TransformRect` | 152-163 | Floors min **and size** (not min/max) |
| `InverseTransformRect` | - | Float |
| `ChildPosFromCanvas` | 174 | Window-relative, for child windows |

The `TransformRect` choice deserves a closer look, because its comment (154) explains it: flooring min and size, instead of min and max, avoids size jitter while panning. Imagine a 20.4 px wide box. If you round both edges, its width flips between 20 and 21 as it slides across pixel boundaries, and the box seems to breathe. If you round only the origin and the size, the width stays constant and the box just steps. This is a good rule to copy.

The family is also where tixl contradicts itself: `TransformX` truncates while `TransformY` does not, and `TransformPosition` truncates while the stroke helpers round. We return to this in the "Stated rule vs. code" box.

---

## One Frame in the Life of the Canvas

Subclasses call `UpdateCanvas(out InteractionState, flags)` (37-49) before they draw anything. It runs four steps in a fixed order:

```
UpdateCanvas
  1. UpdateWindowRect          where is the window this frame?
  2. HandleRequestedTransitions apply any "go here" request queued earlier
  3. DampScaling(io.DeltaTime)  move current toward target
  4. HandleInteraction          read mouse, update targets
```

Order matters. Step 2 runs after the window rect is known, because a "fit these nodes" request needs the window size. Step 3 runs before step 4, so the transform you draw with this frame reflects last frame's input plus this frame's easing. Step 4 only edits targets, never the transform you are about to draw with.

Step 1 has two modes. `FillWindow` uses `GetWindowPos` plus 1 px of padding so the focus border stays visible (53-58). `FillAvailableContentRegion` uses `GetContentRegionAvail` and `GetCursorScreenPos` (62-63), which is what you want when the canvas lives inside a larger layout, such as a curve area embedded in a timeline row.

---

## Why Damping Lerps the Visible Rectangle, Not the Scale

The naive way to ease a zoom is `scale = lerp(scale, target, k)`. It looks wrong. Zoom is multiplicative: going from 1x to 2x is the same perceptual step as 2x to 4x, but a linear lerp spends most of its time near the large end, and the scroll lerps independently, so the content swings sideways while it grows.

tixl does something smarter (190-234). It converts both current and target transforms into **the canvas rectangle that is visible**, lerps the rectangle's min and max, and then recomputes `Scale = WindowSize / (max - min)` and `Scroll = min`. Because the corners travel in straight lines in canvas space, the picture appears to glide in, with scale and scroll always consistent with each other. The analogy is a movie camera operator who frames the shot by its corners, not by dialing focal length and pan separately.

A few details protect this from edge cases:

- **Snap:** when scroll is within 1 canvas unit and scale within 0.05 of the target, it jumps to the target (192-195), so the animation terminates.
- **NaN recovery:** a bad value in the state is repaired instead of poisoning every later frame.
- **Sign-flip guard (223):** a negative-Y curve canvas must not flip sign mid-animation.
- **Smoothing factor:** `min(dt / ScrollSmoothing.Clamp(0.01, 0.99), 1)` (210).

That last line is the weak spot: the factor depends on `dt`, but not through an exponential. At 144 Hz the canvas settles at a different speed than at 30 Hz. We fix this in the Rust section.

---

## Zooming Around the Cursor

Chapter 14 shows the "adjust scroll after scaling" trick. tixl uses a closed form instead (`ApplyZoomDelta`, 393-426):

```
var focusCenterOnCanvas = InverseTransformPositionFloat(position);
ScrollTarget += (focusCenterOnCanvas - ScrollTarget) * (zoom - Vector2.One) / zoom;
// and ScaleTarget *= zoom
```

The formula says: slide the target scroll toward the focus point by the fraction `(zoom - 1) / zoom`. Check it by hand: with scale doubling (`zoom = 2`) the scroll moves half the distance toward the cursor's canvas point, which is exactly what keeps that point under the cursor.

There is a subtlety. The *math* runs on the targets, but the focus point is computed with `InverseTransformPositionFloat`, which uses the **current, damped** transform (424). While an animation is in flight, the pivot is therefore taken from a transform that is not the one being edited. The pivot may drift during rapid wheel spinning (inferred, not verified at runtime). The fix is cheap: compute the focus point from the target transform. The Rust section does this.

The numbers: one wheel notch multiplies zoom by 1.2, clamped to 0.02..100 (465-488). Dragging to zoom uses `1.13^(-d/40)` (494-527). Both are exponential in input, which is what makes zoom feel uniform.

---

## Input Mapping

The input rules live in `HandleInteraction` and are the part most worth copying wholesale, because they encode a lot of hand-feel.

| Gesture | Effect | Lines |
|---------|--------|-------|
| Right-drag (no Alt) | Pan | 261-275 |
| Middle-drag | Pan (unless `MiddleMouseButtonZooms`) | 261-275 |
| Alt + left-drag | Pan, only if `PansWithAltDrag` | 261-275 |
| Wheel | Zoom around cursor | 296 |
| Shift + right-drag, or middle-drag | Drag zoom (`ZoomWithDrag`) | 494-527 |
| Curve canvases: Alt held | Lock X zoom | 407-417 |
| Curve canvases: Shift held | Lock Y zoom | 407-417 |
| Trackpad mode: two-finger scroll | Pan, `MouseWheel * 220 / ScaleTarget` | 280-293 |
| Trackpad mode: pinch | `MouseWheelPanning.PinchZoomDelta` | 280-293 |

Two details deserve a note.

**Pan delta is divided by scale.** The delta is `mouseDelta / (parentScaleTarget * ScaleTarget)`, so dragging 100 pixels moves the canvas the same *screen* distance at any zoom. It divides by the *target* scale, not the damped one, so a fast drag during an animation does not overshoot.

**One drag owner.** A static `_draggedCanvas` (304) records which canvas currently owns a drag. With a timeline and a curve area both on screen, only one reacts to a given drag, even if the cursor wanders over the other.

### The Trackpad Pinch Hack

Windows delivers a trackpad pinch as a wheel message with Ctrl held. `Editor/App/MouseWheelPanning.cs` installs a Windows-only WndProc hook to interpret that:

- It detects pinch as wheel plus Ctrl (37-39, 44).
- It normalizes to 120 per notch (35).
- ImGui's own wheel receives notches / 2 (55).
- After a pinch, an 80 ms "sticky" window keeps classifying wheel events as zoom (44).
- Pinch notches are added twice (46-47), which looks like a hack.

You will need an equivalent on any platform where pinch does not arrive as a clean event. On macOS and Wayland-style backends the windowing library usually gives you a magnify gesture directly, so you can skip the heuristics. Plan an input abstraction (`pan_delta`, `zoom_delta`, `pivot`) so the canvas never sees raw wheel events.

---

## Reuse: Customization Points

tixl's reuse works by inheritance. Here are the subclasses, from the trace:

| Subclass | Location |
|----------|----------|
| `MagGraphView` | `Editor/Gui/MagGraph/Ui/MagGraphView.cs:22` |
| Legacy `GraphView` | `Editor/Gui/Graph/Legacy/GraphView.cs:31` |
| `AnimationCanvas` | `Editor/Gui/Interaction/WithCurves/AnimationCanvas.cs:14` |
| `TimeLineCanvas` (under AnimationCanvas) | `Editor/Gui/Windows/TimeLine/TimeLineCanvas.cs:33` |
| `SingleAnimationCanvas` (under AnimationCanvas) | `Editor/Gui/InputUi/CombinedInputs/CurveInputEditing.cs:273` |
| `InlineCurveArea` | `Editor/Gui/Windows/TimeLine/InlineCurveArea.cs:20` |
| `VariationBaseCanvas` (preset, snapshot canvases) | `Editor/Gui/Windows/Variations/VariationBaseCanvas.cs:28` |
| `ImageOutputCanvas` | `Editor/Gui/Windows/ImageOutputCanvas.cs:15` |
| `BoardCanvas` | `Editor/Gui/Windows/OutputSetup/SetupOutputView.Board.cs:2168` |
| `HexCanvas` | `Editor/Skills/Ui/HexCanvas.cs:6` |
| `CurrentGraphSubCanvas` (empty) | `Editor/Gui/Interaction/ScalableGraphSubCanvas.cs:5` |

Think of the base class as a recipe with blanks. The blanks are a small set of virtuals and properties:

| Hook | Lines | What subclasses do with it |
|------|-------|----------------------------|
| `PansWithAltDrag` | 311 | Off for the timeline (`TimeLineCanvas.cs:36`) and Board (`Board.cs:2171`), where Alt+drag means something else |
| `ClampScaleToValidRange` | 314-322 | Default 0.02..40. Timeline 0.01..5000. Curve canvases unclamped. Overridden in timeline, `InlineCurveArea` (140) and Board (2173) |
| `ApplyZoomDelta` | 393 | Overridden by the timeline (361) and `InlineCurveArea` (144) to lock axes |
| `TransformPanDelta` | 342 | Restricts pan axes, for example horizontal-only |
| `Parent` | 539 | Nested canvases; checked ones return null |
| `FillMode`, `EnableParentZoom`, `EditingFlags` | - | Layout and behavior switches |

Clamping runs on `ScaleTarget` after interaction (301), so the damped value can never run past the limit.

There are also helpers that exist only because canvases need to cooperate. `SyncXFrom` / `SyncXTo` (348-363) keep the X axis of two panes locked, which is how the timeline and its inline curve areas share time. `AdoptViewFrom` (386) copies another canvas's view. `ImageOutputCanvas.SetScaleToMatchPixels` (159) sets scale for 1:1 image pixels.

One comment explains a subtle trap (135-140, `AnimationCanvas` and `InlineCurveArea`): the override of the clamp exists because a **synced parent scale must not be clamped away**. If the child clamps to its own default range, it would quietly fight the timeline that is driving it.

---

## Deferred Transitions: Asking for a View Before You Know the Window

Suppose code calls "show these nodes" while a window is still opening. The window size is unknown, so computing a fit transform would use garbage. `ScalableCanvas.Scope.cs` solves this by queuing the request: `RequestTargetViewAreaWithTransition` (176-179) stores it, and `HandleRequestedTransitions` applies it on the next `UpdateCanvas`, after the window rect is known (remark at 7-12). It is like leaving a note for the camera operator: "frame this when you arrive".

The supporting vocabulary:

- `CanvasScope { Scale, Scroll }` (331) is a tiny view-transform struct, with `Get/SetTargetScope` (15-28) and `SetScopeInstant` (30).
- `GetScopeForCanvasArea` (248-280) computes a uniform contain-fit, centered, and takes a `flipY` flag for curve canvases.
- `SetScopeToCanvasArea` (56) adds padding, enforces a 20 px minimum, and guards against invalid scales.
- `ScrollToMakeAreaVisible` (135) shifts minimally, rather than recentering.
- `GetVisibleCanvasArea` (162) returns the rect for culling.
- Transitions: `Instant`, `JumpIn` (zoom 14), `JumpOut` (0.05), `Smooth` (322-328).

A practical gotcha from `SetScopeToCanvasArea` (49-52): if called from a popup, `GetWindowSize()` returns the *popup's* size, so use the stored window size.

Finally, `Editor/Gui/UiHelpers/CanvasHelpers.cs` is not input handling, despite its name. Its one function, `GetSavedOrValidViewForComposition` (7-41), restores a saved view if it still contains any item, and otherwise falls back to the content bounds expanded by 400. That is a good rule for persisted views: never restore a view that shows nothing.

---

## Pixel Alignment: Why Lines Go Soft

Any canvas draws lines at arbitrary transformed positions, so most land between pixels. A 1 px line centered on a pixel *boundary* covers half of each neighboring pixel at 50 percent intensity: a gray smear two pixels wide. A 1 px line centered on a pixel *center* covers exactly one pixel. Crispness is the art of centering odd-width strokes on `.5` and even-width strokes on whole numbers.

The rule is stated in `AGENT_INSTRUCTIONS.md:182-207` and implemented in `Editor/Gui/Windows/OutputSetup/SetupStrokes.cs`. The key doc comment (14-18) says, in gist: `AddRect` and `AddLine` already shift their input by half a pixel, so odd-width strokes come out centered when given whole numbers. Adding another half would put them back on the boundary. `AddRectFilled` and `AddPolyline` do **not** shift, which is why graph connections add the half themselves.

So the same visual intent requires different code depending on which ImGui call you use. The helpers apply it:

| Helper | Line | Rule |
|--------|------|------|
| `Snap` | 25 | Round to whole pixels |
| Frame, outside | 40 | Offset by `thickness * 0.5 + 0.5` |
| Inline | 50 | Offset by `thickness * 0.5 - 0.5` |
| Crisp line | 64-69 | Snapped; even width gets -0.5 |
| Stroke width | 96 | `max(1, round(w * UiScaleFactor))` |
| Anti-aliasing | 77-84 | Cleared for straight edges, then restored; kept when rounding > 0 |

Anti-aliasing off for axis-aligned edges is the last piece: with AA on, even a perfectly aligned edge picks up a faint fringe from the filtering. tixl clears `ImDrawListFlags.AntiAliasedLines` around the straight call and restores it afterward. Free-angle lines and circles are not snapped at all; snapping them would distort the shape.

---

## UI Scale Versus Canvas Scale

Two scale factors live in any editor, and mixing them is the quickest way to get a UI that is subtly wrong.

- **Canvas scale** is zoom: how big the table looks through the camera.
- **UI scale** is DPI or user preference: how big a "16 px" button should be.

tixl keeps them apart at the canvas level. `T3Ui.UiScaleFactor` is a static, settable global (`Editor/Gui/T3Ui.cs:117`), and `ScalableCanvas` never references it. Canvas units are DPI-independent and `Scale` is pure zoom. The rule at `AGENT_INSTRUCTIONS.md:179` reads `value / UiScaleFactor * CanvasScale`, which says: the item's size in canvas units, converted to screen with the zoom, not the DPI.

In practice, MagGraph blends the two, depending on whether something is "content" (scales with zoom) or "chrome" (fixed on screen):

| Use | Location | Formula idea |
|-----|----------|--------------|
| Small font | `DrawNode.cs:411` | `FontSmall.FontSize / UiScaleFactor * ... * smallFontScaleFactor` |
| Label scale | `DrawNode.cs:274` | `min(1/UiScaleFactor, avail/required)` |
| Bar thickness | `DrawNode.cs:1107` | `max(2 * UiScaleFactor, 3 * CanvasScale)` |
| Section chrome | `DrawSection.cs:69-147` | Fixed pixels |

The bar thickness line is the instructive one: it is a floor in UI pixels *or* a zoom-scaled size, whichever is larger, so the bar neither vanishes when zoomed out nor bloats when zoomed in.

---

## Stated Rule vs. Code

> **Stated rule vs. code**
>
> | The rule says | The code does |
> |---|---|
> | `AGENT_INSTRUCTIONS.md:182-207`: snap strokes to whole pixels, centre odd widths | `SetupStrokes.Snap` **rounds** (25), but `ScalableCanvas.TransformPosition` **truncates** (77-81), so two parts of the same editor disagree on where a pixel boundary is |
> | Same section: consistent snapping of canvas positions | `TransformX` truncates (87) while `TransformY` stays float (96) |
> | `AGENT_INSTRUCTIONS.md:179`: `value / UiScaleFactor * CanvasScale`, one place for DPI | A mutable global `UiScaleFactor` that other code temporarily overwrites: `TimeLineCanvas.cs:119,150` saves and restores it (comment at 118: "Very ugly hack to prevent scaling the output above window size"), and `CurveEditPopup.cs:68-73` sets it to 1. `ScalableCanvas` itself is DPI-independent, but every caller must remember to compensate with the global, and these hacks show what happens when one needs an exception |
> | `AGENT_INSTRUCTIONS.md:214-215`: "Prefer a single draw list. Z-order by call sequence. Split channels only when needed, merge immediately" | Followed: canvas code calls `TransformPosition` per element and draws in screen space, with `PushClipRect` used only locally (`MagGraphCanvas.DrawSection.cs:41,219`) |
>
> The lesson: the rules are right, but the enforcement is manual. A global plus a truncating transform means correctness depends on discipline. Our Rust design makes both explicit parameters.

---

## Tracing a Wheel Notch

Let's trace what happens when you spin the wheel one notch over a node while the canvas sits at `Scale = (1,1)`, `Scroll = (0,0)`, window at screen (100, 50), cursor at screen (500, 350).

1. `UpdateCanvas` runs. `UpdateWindowRect` stores `WindowPos = (100, 50)`.
2. `HandleInteraction` sees the wheel and calls `ApplyZoomDelta` with `zoom = 1.2`.
3. Focus on canvas: `(500-100, 350-50) / 1 + 0 = (400, 300)`.
4. `ScrollTarget += (400,300 - 0) * 0.2 / 1.2 = (66.7, 50)`.
5. `ScaleTarget = (1.2, 1.2)`. `ClampScaleToValidRange` runs on it (301).
6. `DampScaling` next frame lerps the visible rect toward the new one. Scale and scroll move together.
7. When scroll is within 1 canvas unit and scale within 0.05, the state snaps.
8. Target check: `(400 - 66.7) * 1.2 + 100 = 500`. The point stays under the cursor.

Step 4's pivot came from the current transform, as noted earlier. During the first notch it is exact. During the third notch in 100 ms, the current transform lags the target, which is where drift may show up.

---

## LOD Thresholds as a Table

Zooming out should *remove* detail, not shrink it into mush. MagGraph's `DrawNode` uses `CanvasScale` (which is `Scale.X`, `MagGraphView.cs:549`) to decide what to draw. All lines are in `Editor/Gui/MagGraph/Ui/MagGraphCanvas.DrawNode.cs`:

| Feature | Threshold | Line |
|---------|-----------|------|
| Thumbnails | `CanvasScale > 0.2` | 225 |
| Labels and input details | `> 0.25` | 404 |
| Values | `> 0.4` | 489 |
| Corner rounding | 0 below 0.5 | 127, 149 |
| Anchors | Simplified below 0.5 | 628 |
| Label alpha | `CanvasScale.RemapAndClamp(0.3, 0.7, 0, 1)` | 286 |
| Small font factor | `CanvasScale.Clamp(0.5, 2)` | 54 |
| Font size | `FontNormal * (down * CanvasScale).Clamp(0.1, 1)` | 276 |

There are two kinds of threshold here. **Hard gates** (`>` comparisons) switch a feature on and off. **Soft ramps** (`RemapAndClamp`, `Clamp`) fade or size continuously. The label alpha line is the good model: it fades from 0.3 to 0.7 so labels do not pop. Where tixl uses hard gates (thumbnails at 0.2), a pop is visible but cheap, and skipping the draw also saves work (see [Performance](../maggraph/18-performance.md)).

Culling has a timing quirk of its own. `_visibleCanvasArea = GetVisibleCanvasArea()` is computed before `UpdateCanvas` (`MagGraphCanvas.Drawing.cs:51`), so culling uses last frame's view, a one-frame lag that can briefly hide an item at the viewport edge during a fast pan (inferred, not verified at runtime). `IsRectVisible` is a rect-overlap test (`MagGraphView.cs:366-369`), used at `DrawNode.cs:33`.

---

## Gotchas

1. **Truncation versus rounding, and mixed X/Y behavior.** Position transforms truncate while stroke helpers round, so a snapped line can land one pixel from the shape it should hug. `TransformX` truncates but `TransformY` does not (87 vs 96), so axis-specific code can disagree.
2. **Pivot drift during animation.** Zoom math edits targets, but the focus uses the damped transform (424). Inferred, not verified at runtime.
3. **Frame-rate-dependent damping.** The factor `min(dt / smoothing, 1)` (210) gives different settle times at different refresh rates.
4. **Culling lag.** The visible area is computed before `UpdateCanvas` (`MagGraphCanvas.Drawing.cs:51`), so it reflects the previous frame. Inferred, not verified at runtime.
5. **Global UI scale overrides.** Code that sets and restores `UiScaleFactor` breaks if it returns early or throws (`TimeLineCanvas.cs:119,150`). Inferred from the save/restore pattern, not verified at runtime.
6. **Popup window size.** Inside a popup, `GetWindowSize()` is the popup's (`Scope.cs` 49-52).
7. **RectOnly hover.** ImGui 1.91 forbids `RectOnly` for window hover (`ScalableCanvas.cs:244`), so the old hover test needed changing.
8. **Dead and odd lines.** The Instant case assigns `Scroll = ScaleTarget;` (230) before setting it properly. Harmless, but a sign the code grew by patching. `ZoomWithDrag` carries a comment at 525: "FIXME: unclear what this does". Pinch notches are added twice (`MouseWheelPanning.cs:46-47`). Do not copy these.

---

## Rust / dear-imgui-rs Translation

tixl's author left a TODO at `ScalableCanvas.cs:17-23`. Verbatim:

> This should be refactored into two parts: - struct ViewTransform {Scroll, Zoom} -> For all transforms and conversion operations - sealed class InteractiveCanvas -> For transitions, interactions, etc. Other canvas should not inherit from this but use composition. IScalableCanvas should be removed

`CanvasScope` and `Get/SetCurrentScope` (366-372) are a first step. Rust makes the TODO natural: a `Copy` struct for the math, a struct that *contains* it for behavior, and traits or config for variation. The code below uses `glam::Vec2` and keeps ImGui calls out of the core on purpose, so you can unit-test it.

### Step 1: The Pure Transform

Start with the transform. Every method takes `window_pos` explicitly, so the struct stores nothing about the frame and can be copied, compared and saved:

```rust
use glam::Vec2;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect { pub min: Vec2, pub max: Vec2 }

/// Pure view math. No window state, no ImGui. Canvas units are DPI-free.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ViewTransform {
    pub scroll: Vec2, // canvas coordinate at window top-left
    pub scale: Vec2,  // per-axis zoom; negative y = y-up curve canvas
}

impl ViewTransform {
    pub fn to_screen(&self, p: Vec2, window_pos: Vec2) -> Vec2 {
        (p - self.scroll) * self.scale + window_pos
    }
    pub fn to_canvas(&self, s: Vec2, window_pos: Vec2) -> Vec2 {
        (s - window_pos) / self.scale + self.scroll
    }
    pub fn dir_to_screen(&self, d: Vec2) -> Vec2 { d * self.scale }
    pub fn dir_to_canvas(&self, d: Vec2) -> Vec2 { d / self.scale }

    /// Origin and size rounded separately, so size stays constant while panning.
    pub fn rect_to_screen_snapped(&self, r: Rect, window_pos: Vec2) -> Rect {
        let min = self.to_screen(r.min, window_pos).round();
        let size = self.dir_to_screen(r.max - r.min).round();
        Rect { min, max: min + size }
    }

    /// Canvas rect currently visible; use it for culling.
    pub fn visible_rect(&self, window_pos: Vec2, window_size: Vec2) -> Rect {
        let a = self.to_canvas(window_pos, window_pos);
        let b = self.to_canvas(window_pos + window_size, window_pos);
        Rect { min: a.min(b), max: a.max(b) } // min/max handles the flipped y
    }

    /// Zoom while keeping the canvas point under `pivot_screen` fixed.
    /// tixl's closed form: scroll += (focus - scroll) * (zoom - 1) / zoom.
    pub fn zoomed_about(&self, pivot_screen: Vec2, window_pos: Vec2, zoom: Vec2) -> Self {
        let focus = self.to_canvas(pivot_screen, window_pos);
        Self {
            scroll: self.scroll + (focus - self.scroll) * (zoom - Vec2::ONE) / zoom,
            scale: self.scale * zoom,
        }
    }
}
```

Note what changed from tixl. `zoomed_about` is a method on whichever transform you hand it, so the pivot is computed from the same transform being edited. That removes the pivot-drift question entirely: pass the *target* and you get a consistent result. `rect_to_screen_snapped` rounds origin and size, honoring tixl's anti-jitter reasoning while using the same `round` as the stroke helpers.

### Step 2: Interaction by Composition

Next comes the part tixl wanted in a separate class. It holds the current and target transforms, the window rect, and a pending fit request. It does not inherit from anything:

```rust
pub struct CanvasConfig {
    pub min_scale: Vec2,
    pub max_scale: Vec2,        // use f32::INFINITY per axis for "unclamped"
    pub pans_with_alt: bool,    // off where Alt+drag means something else
    pub pan_axes: Vec2,         // (1,1) both, (1,0) horizontal only
    pub zoom_axes: Vec2,        // (1,0) = timeline: zoom time only
    pub tau: f32,               // damping time constant, seconds
}

pub struct InteractiveCanvas {
    pub current: ViewTransform,
    pub target: ViewTransform,
    pub window: Rect,
    pub pending_fit: Option<Rect>, // canvas area to frame next frame
    pub config: CanvasConfig,
}
```

The `config` replaces tixl's virtual overrides. Where tixl overrides `PansWithAltDrag`, you set a bool. Where it overrides `ClampScaleToValidRange`, you set `min_scale` / `max_scale`. Where it overrides `TransformPanDelta`, you set `pan_axes`. The table below maps one to the other:

| tixl virtual | Rust equivalent |
|--------------|-----------------|
| `PansWithAltDrag` | `config.pans_with_alt` |
| `ClampScaleToValidRange` | `config.min_scale` / `max_scale` |
| `TransformPanDelta` | `config.pan_axes` |
| `ApplyZoomDelta` (axis lock) | `config.zoom_axes` |
| `Parent` / `SyncXFrom` | A function `sync_x(&mut self, other: &ViewTransform)` |

If one editor needs behavior config cannot express (a custom snapping zoom, for example), add a small trait with default methods, and make `InteractiveCanvas<B: CanvasBehavior>` generic. Start with config; reach for the trait only when a real second case demands it.

The frame update mirrors tixl's four steps, using the deferred-fit idea so window size is known:

```rust
impl InteractiveCanvas {
    pub fn update(&mut self, window: Rect, dt: f32) {
        self.window = window;                                  // 1. window rect
        if let Some(area) = self.pending_fit.take() {          // 2. deferred request
            self.target = fit_contain(area, window, 20.0, self.target.scale.y < 0.0);
        }
        self.damp(dt);                                         // 3. ease toward target
        // 4. the caller feeds input via zoom_at() / pan_by() before drawing
    }

    pub fn zoom_at(&mut self, pivot_screen: Vec2, zoom: Vec2) {
        let z = Vec2::ONE + (zoom - Vec2::ONE) * self.config.zoom_axes;
        let t = self.target.zoomed_about(pivot_screen, self.window.min, z); // target in, target out
        self.target = self.clamped(t);
    }

    pub fn pan_by(&mut self, screen_delta: Vec2) {
        self.target.scroll -= screen_delta * self.config.pan_axes / self.target.scale;
    }

    fn clamped(&self, mut t: ViewTransform) -> ViewTransform {
        let sign = t.scale.signum(); // keep the curve-canvas flip
        t.scale = (t.scale.abs()).clamp(self.config.min_scale, self.config.max_scale) * sign;
        t
    }
}
```

`pending_fit` is the "note for the camera operator". `fit_contain` is your version of tixl's `GetScopeForCanvasArea`: uniform scale, centered, padded, with the flip flag. Everything else in this block follows the trace. Note that `pan_by` divides by the *target* scale, as tixl does.

### Step 3: Frame-Rate-Independent Damping

Replace tixl's `min(dt / smoothing, 1)` with an exponential. The factor `1 - exp(-dt / tau)` gives the same settling time at any frame rate, because two steps of `dt/2` compose exactly to one step of `dt`. We keep tixl's rect-lerp, because it is the part that feels right:

```rust
impl InteractiveCanvas {
    fn damp(&mut self, dt: f32) {
        let a = 1.0 - (-dt / self.config.tau.max(1e-4)).exp();
        let size = self.window.max - self.window.min;
        let rect = |t: &ViewTransform| {
            let other = t.scroll + size / t.scale; // may be "smaller" than scroll if y flipped
            (t.scroll, other)
        };
        let (c0, c1) = rect(&self.current);
        let (t0, t1) = rect(&self.target);
        let (n0, n1) = (c0.lerp(t0, a), c1.lerp(t1, a));
        let span = n1 - n0;
        // Guard: NaN, zero span, or a flipped sign means: snap instead of animate.
        let same_sign = (span * self.target.scale).min_element() > 0.0;
        self.current = if span.is_finite() && same_sign {
            ViewTransform { scroll: n0, scale: size / span }
        } else {
            self.target
        };
        // Snap when closer than half a pixel: ends the animation for good.
        let px = (self.current.scroll - self.target.scroll).abs() * self.target.scale.abs();
        let ds = (self.current.scale / self.target.scale - Vec2::ONE).abs();
        if px.max_element() < 0.5 && ds.max_element() < 1e-3 {
            self.current = self.target;
        }
    }
}
```

The `same_sign` guard plays the role of tixl's sign-flip guard (223): `span` carries the sign of the scale, so a span whose sign disagrees with the target (or a NaN, or zero) means "snap instead of animate". Unit-test it with a flipped-Y canvas. The snap thresholds here are in **screen pixels**, my choice instead of tixl's canvas-unit constants (1 unit, 0.05), so the stop condition does not depend on zoom.

### Step 4: DPI-Free Canvas, Explicit UI Scale

Pass `ui_scale` into drawing as a value, so there is no global to save and restore. A small context struct bundles what draw code needs:

```rust
#[derive(Clone, Copy)]
pub struct DrawCtx {
    pub view: ViewTransform,
    pub window_pos: Vec2,
    pub ui_scale: f32, // DPI / user preference. Never touches canvas units.
}

impl DrawCtx {
    pub fn pos(&self, p: Vec2) -> Vec2 { self.view.to_screen(p, self.window_pos) }
    /// Size that follows zoom (content).
    pub fn zoomed(&self, canvas_len: f32) -> f32 { canvas_len * self.view.scale.x.abs() }
    /// Size that follows DPI only (chrome): a button, a border.
    pub fn chrome(&self, base_px: f32) -> f32 { base_px * self.ui_scale }
    /// tixl's "floor in px or follow zoom, whichever is larger".
    pub fn bar(&self, base_px: f32, canvas_len: f32) -> f32 {
        self.chrome(base_px).max(self.zoomed(canvas_len))
    }
}
```

tixl's `TimeLineCanvas` hack exists because one code path needs "scale to window" behavior. Here you would create a second `DrawCtx` with a different `ui_scale` for that sub-region. A value that you pass cannot be left modified by an early return.

### Step 5: LOD Helper and Stroke Snapping

Two small helpers capture the rest of the chapter. First, `lod` expresses tixl's hard gates and soft ramps as data, so thresholds live in one table per editor:

```rust
pub struct Lod { pub scale: f32 }

impl Lod {
    pub fn new(view: &ViewTransform) -> Self { Self { scale: view.scale.x.abs() } }
    /// Hard gate: draw the feature at all?
    pub fn at_least(&self, min_scale: f32) -> bool { self.scale > min_scale }
    /// Soft ramp 0..1 between lo and hi (like RemapAndClamp(lo, hi, 0, 1)).
    pub fn fade(&self, lo: f32, hi: f32) -> f32 {
        ((self.scale - lo) / (hi - lo)).clamp(0.0, 1.0)
    }
}
```

Second, the stroke snapper. The rule from `SetupStrokes` becomes one function: decide where the stroke *centre* should be, then subtract whatever shift the draw call applies on its own. This is my derivation of tixl's documented behavior, verify it against your backend with a pixel-readback test before trusting it:

```rust
/// One axis of a straight stroke. `api_half_shift` is true for calls that add
/// 0.5 px themselves (tixl: AddLine/AddRect), false for those that do not
/// (AddRectFilled/AddPolyline).
pub fn crisp(v: f32, width_px: f32, api_half_shift: bool) -> f32 {
    let w = width_px.round().max(1.0);
    let odd = (w as i32) % 2 == 1;
    let centre = if odd { v.round() + 0.5 } else { v.round() };
    if api_half_shift { centre - 0.5 } else { centre }
}
```

With a shifting API, odd widths get whole numbers and even widths get `-0.5`, matching `SetupStrokes.cs:64-69`. Always round, never truncate, and use the same `round` in the transform and the stroke code. That one decision removes tixl's truncate-versus-round inconsistency.

### Reuse Across Editors

Each editor owns an `InteractiveCanvas` by value, with its own `CanvasConfig`:

| Editor | Config |
|--------|--------|
| Node graph | Default min/max scale (say 0.02..40), `pans_with_alt: true`, both axes |
| Timeline | Wide X range, `pans_with_alt: false`, `zoom_axes: (1, 0)` |
| Curve editor | Negative Y scale, unclamped, Alt/Shift axis locks mapped onto `zoom_axes` per frame |
| Inline curve area under a timeline | `sync_x` from the timeline each frame, X clamp disabled so the synced scale is not clamped away |

Persist only `ViewTransform` (it is `Copy` and trivially serializable), and apply tixl's restore rule: if the saved view contains none of the items, fall back to content bounds plus margin.

---

## What to Take Away

- Own the mapping in **one** pure, copyable struct. Pass `window_pos` in, store nothing about the frame.
- Keep *current* and *target* transforms; input edits the target, drawing reads the current.
- Damp the visible **rectangle**, with an exponential factor so it is frame-rate independent.
- Compute zoom pivots from the transform you are editing.
- Replace virtual overrides with a config struct, and compose rather than inherit.
- Keep canvas units DPI-free. Pass `ui_scale` explicitly.
- Round everywhere, centre odd strokes on `.5`, and know which draw calls add their own half pixel.
- Put LOD thresholds in a table and prefer soft ramps to hard pops.

---

## Next Steps

- [MagGraph 14: Canvas Rendering](../maggraph/14-rendering-canvas.md) - the transform, fit and culling in the node graph
- [MagGraph 18: Performance](../maggraph/18-performance.md) - what culling and LOD buy you per frame
- [MagGraph B: ImGui Patterns](../maggraph/B-imgui-patterns.md) - the idioms this chapter assumes

## References

All paths relative to `visual-programming/tixl/`:

- `Editor/Gui/Interaction/ScalableCanvas.cs`, `ScalableCanvas.Scope.cs`
- `Editor/Gui/Interaction/WithCurves/AnimationCanvas.cs`, `Editor/Gui/Windows/TimeLine/TimeLineCanvas.cs`, `InlineCurveArea.cs`
- `Editor/Gui/MagGraph/Ui/MagGraphView.cs`, `MagGraphCanvas.Drawing.cs`, `MagGraphCanvas.DrawNode.cs`
- `Editor/Gui/Windows/OutputSetup/SetupStrokes.cs`
- `Editor/App/MouseWheelPanning.cs`, `Editor/Gui/UiHelpers/CanvasHelpers.cs`, `Editor/Gui/T3Ui.cs`
- `AGENT_INSTRUCTIONS.md` (lines 179, 182-207, 214-215)
