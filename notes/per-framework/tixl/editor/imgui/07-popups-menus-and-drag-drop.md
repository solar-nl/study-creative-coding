# Chapter 07: Popups, Menus and Drag & Drop - Everything That Floats

> *A popup is a promise that the rest of the UI will hold still and listen. Keeping that promise across 60 redraws a second is the hard part.*

---

## The Problem: Things That Float Above a Layout That Redraws Itself

Picture a node editor on a Dear ImGui base. The user right-clicks a node and expects a menu. They press a button and expect a confirmation dialog that blocks everything behind it. They drag an asset out of a library and expect the canvas to light up where it will land. They drag a file in from the desktop and expect the same. They hover a button for a second and expect a tooltip, but not for a disabled button, unless the tooltip explains why it is disabled.

In a retained toolkit each of these is an object with a lifetime: you create the dialog, show it, and later it fires a callback. Dear ImGui has no objects. Every frame you re-describe the whole UI, and a "popup" is just a conditional branch that happens to be true for a while. That raises uncomfortable questions. Who calls `OpenPopup`, and from where? How does a dialog hand its result back when there is no callback? When a popup is open, how do the canvas and the shortcut system find out they should ignore the mouse? What does a drag carry when the drop target is drawn by a different window, possibly *earlier* in the frame than the source?

This chapter traces how tixl answers those questions, and which of its own written rules it follows while doing so. At the end we translate the practices to a Rust editor on dear-imgui-rs.

**Mental model: a hotel lobby with a desk clerk and a sign-in sheet.** The lobby (your normal layout) is redrawn from scratch every morning. Guests who need something special go to floating things. A **modal dialog** is the desk clerk who stops everyone until the form is filled out. A **context menu** is a clipboard that appears wherever you point. A **tooltip** is a small label that appears if you linger. **Drag & drop** is a parcel carried between rooms. The parcel's *contents* are too big to hand through the revolving door, so the door only carries a claim ticket, and the real contents sit on the sign-in sheet in the lobby. That last detail is the central trick of tixl's drag & drop.

> **Scope note.** All paths are relative to `visual-programming/tixl/`, cited as `Editor/...:line`. Related reading, not restated here: [FrameStats overlay flags](02-input-routing-and-focus.md), [popup ids and the ID stack](05-id-stack-and-widget-identity.md) (chapter 05, planned), [menu helper styling](06-theming-and-widget-library.md) (chapter 06, planned), the [operator browser in MagGraph](../maggraph/11-interaction-browser.md) and the [symbol browser](../graph/01-symbol-browser.md).

---

## How Does a Dialog Open When Nobody Holds a Handle to It?

The naive approach is to have a `bool showDialog` somewhere and call `OpenPopup` in the button handler. That works until the button and the dialog live in different windows, which have different ID stacks, and the popup never opens or opens under a different id.

tixl's answer is `ModalDialog`, an abstract base class (`Editor/Gui/UiHelpers/ModalDialog.cs:36`). The doc comment at `:8-33` describes the contract: the owner calls `_dialog.Draw()` **every frame**, and a button somewhere else calls `_dialog.ShowNextFrame()`. The trigger does not open anything. It only sets a flag.

`ShowNextFrame` (`:38-42`) sets `_shouldShowNextFrame = true` and fires an `OnShowNextFrame()` hook, so a subclass can reset its fields. The flag is consumed inside the dialog's own draw, at the top of `BeginDialog` (`:47-53`):

```csharp
protected bool BeginDialog(string title)
{
    if (_shouldShowNextFrame)
    {
        _shouldShowNextFrame = false;
        ImGui.OpenPopup(title);
    }
```

Why does that matter? `OpenPopup` is called from the same place, with the same ID stack, as the later `BeginPopupModal`, so both hash the title to the same id. The code does not state this reason; it is **inferred from ImGui semantics**. Chapter 05 covers why ids depend on the stack.

### What Must a Dialog Subclass Always Call?

A dialog subclass follows a three-part protocol, with one non-obvious rule. `BeginDialog` returns false while the dialog is closed. If it returns true, the subclass draws its content and calls `EndDialogContent()` (`:80`, which does `PopStyleVar` and `EndPopup`). Then, regardless of the result, it calls `EndDialog()` (`:89`) **always**, to pop the WindowPadding var that was pushed before `BeginPopupModal`. `Editor/Gui/Dialog/ExitDialog.cs:22,86,89` shows the whole shape. A static variant, `BeginStaticDialog`/`EndStaticDialog` (`:100-117`), takes a `ref bool isOpen` for dialogs that do not need the base class's trigger machinery.

Sizing has its own rule. `DialogSize` is a *minimum*, applied with `SetNextWindowSizeConstraints` (`:56-62`), and the window uses `AlwaysAutoResize` (`:67`). The comment at `:56-59` warns about a trap: a bottom-anchored child with height `Vector2(0, -h)` feeds back into `AlwaysAutoResize` and grows the window every frame.

### How Does a Dialog Return a Result?

It does not. `ModalDialog` has no return value. Dialogs mutate state, call `CloseCurrentPopup`, and take `ref`/`out` parameters. `Editor/Gui/Graph/Dialogs/RenameSymbolDialog.cs:15` takes `ref string name`; on confirm it calls `SymbolNaming.RenameSymbol` (`:54`) and closes (`:55`). That is simple, and it is also a hidden coupling: the caller must pass a mutable buffer that outlives the dialog.

### How Does the Rest of the UI Learn a Modal Is Open?

`BeginDialog` writes three fields on the per-frame stats object (`ModalDialog.cs:71-73`): `OpenedPopUpName`, `IsModalDialogOpen` and `OpenedPopupHovered`. `T3Ui.IsAnyPopupOpen` is derived from the name (`Editor/Gui/T3UI.cs:118`). Consumers read them to switch off canvas input: `Editor/UiModel/Selection/SelectionFence.cs:37` and `MagGraphCanvas.Drawing.cs:54`. [Chapter 02](02-input-routing-and-focus.md) explains the current/last flag mechanism; this chapter only adds the popup writers.

### Where Do the Dialogs Live?

Always-present dialogs are drawn unconditionally in `Editor/Gui/T3Ui.Update.cs:119-131`: search, NewProject, ShareProject, RestoreBackup, could-not-load, missing operators, CreateFromTemplate, user name, FolderImport, About, Exit, EditDescription and SkillMap. tixl queues startup dialogs with `ShowNextFrame`, gated on `!IsAnyPopupOpen` (`:143-155`), so two modals never fight over the screen.

---

## Trace: Clicking "Exit" to Seeing the Dialog

1. The user clicks the Exit menu entry (`Editor/Gui/AppMenuBar.cs:480`) or closes the main window (`Editor/App/ProgramWindows.cs:302`). Either handler calls `T3Ui.ExitDialog.ShowNextFrame()`. It sets one bool and returns.
2. Next frame, `T3Ui.Update` reaches `_exitDialog.Draw()` (`T3Ui.Update.cs:119-131`).
3. `BeginDialog("###ExitDialog")` sees the flag, clears it, calls `OpenPopup`, then `BeginPopupModal`.
4. It records `OpenedPopUpName`, `IsModalDialogOpen` and `OpenedPopupHovered` on the current-frame stats.
5. The next frame, the canvas reads the *last* frame's stats and skips its input.
6. The user presses a button. The dialog calls `CloseCurrentPopup`. Stats are no longer written, and the canvas wakes up one frame later.

The title `"###ExitDialog"` (`ExitDialog.cs:21`) is deliberate: ImGui 1.90 rejects empty popup ids, and `###` gives an id with no visible text.

---

## What Do Context Menus Look Like When Fifty Files Want One?

ImGui's built-in `BeginPopupContextItem` already opens a popup on right-click of the last item. tixl wraps it because the raw call has several problems: a right-drag (panning) should not open the menu, the caller's style (for example, thick FramePadding) would squash the menu, and every menu needs the same title line and row look.

The wrapper is `CustomComponents.ContextMenuForItem(Action drawMenuItems, string title = null, string id = "context_menu", ImGuiPopupFlags flags = MouseButtonRight)` (`Editor/Gui/Styling/CustomComponents.Menus.cs:16`). In order:

1. Return early if the right-drag delta exceeds `ClickThreshold` (`:19-24`).
2. Push four style vars, so caller FramePadding cannot squash the menu (`:26-31`).
3. Call `ImGui.BeginPopupContextItem(id, flags)` (`:33`).
4. Set `FrameStats.Current.IsItemContextMenuOpen` (`:35`).
5. Draw a small gray title (`:36-43`).
6. Invoke the callback through a static field to avoid a closure allocation (`:45-47`).

### How Are Menu Rows, Groups and Submenus Built?

Rows come from `DrawMenuItem(int id, Icon, label, shortcut, isChecked, isEnabled, ...)` (`:108`). A row is an `InvisibleButton` with a custom-drawn checkmark, icon and shortcut (`:150-196`), and it calls `CloseCurrentPopup` on click (`:198-201`). Styling details belong to chapter 06. Siblings are `DrawMenuGroupLabel` (`:58`) and `DrawSubMenu` (`:211`).

The row id is an `int` supplied by the caller, but the label also seeds the id (`:148-149`), because int ids collapsed to 0 after hot reload. `Editor/Gui/MagGraph/Interaction/GraphContextMenu.cs:33-35` uses an enum for its ids for the same reason.

Two statics, `MenuItemsDisabled` and `MenuItemsFlushLeft` (`:92,100`), are unscoped globals: set one and forget to reset it, and every later menu changes.

### What Happens When You Right-Click Empty Canvas?

Empty canvas needs a different trick, because no item is under the cursor. `DrawContextMenuForScrollCanvas` (`:277`) wraps `BeginPopupContextWindow("windows_context_menu")` (`:297`). It skips opening if an item menu is already open, after a right-drag, or when the window is not hovered (`:279-290`). When it opens, it records `ImGui.GetMousePosOnOpeningCurrentPopup()` as `ScreenPosOnOpeningContextMenu` (`:299`).

That recorded position is the key. By the time the menu is drawn, the mouse has moved to the menu. To learn *what was under the cursor at click time*, `GraphContextMenu.cs:75` hit-tests against the saved position. The call site, `MagGraphCanvas.Drawing.cs:308`, passes a capturing lambda that calls `GraphContextMenu.DrawContextMenuContent` (`GraphContextMenu.cs:50`).

The operator browser that opens from a canvas gesture is a separate system and is not restated here; see the [interaction browser](../maggraph/11-interaction-browser.md) and the [symbol browser](../graph/01-symbol-browser.md).

### Does tixl Follow Its Own Context-Menu Rules?

Here is the written guidance next to what the code does:

| Stated rule (`.agentic/AGENT_INSTRUCTIONS.md:252-273`) | What the code does |
|------|------|
| Use the `ContextMenuForItem` helper instead of raw `BeginPopupContext*` | **Partially followed.** The helper is used by SymbolLibrary, AssetLibrary.Draw, SetupEntityContextMenu, GradientEditor, ResolutionHandling and SetupPopup. Hand-rolled `BeginPopupContext*` remains at `Editor/Gui/Hub/ProjectsPanel.cs:199,302,357`, `Editor/Gui/Windows/TimeLine/TimeClips/TimeClipInteractions.cs:101` and `Editor/Gui/Windows/AssetLib/AssetLibrary.ToolsPopup.cs:18`. |
| Pass a static method group, not a lambda (avoids a per-frame closure allocation) | **Violated at two sites.** `Editor/Gui/Graph/Legacy/GraphView.cs:416` and `MagGraphCanvas.Drawing.cs:308` pass lambdas. |

We did not check per site what each hand-rolled call skips. Inferred, not verified: it can miss the right-drag guard and the style pushes the helper provides.

---

## Which Kinds of Non-Modal Popup Exist?

tixl uses three mechanisms for things that float but should not block the whole app. Seeing them side by side shows what each trades away.

### (a) A Real Popup: ColorEditPopup

The opener (`Editor/Gui/Interaction/ColorEditButton.cs:35-45`) opens on mouse *release*, and only if the click did not drag (`MouseDragMaxDistanceAbs < ClickThreshold`). It uses `AllowWhenBlockedByPopup` so you can click another swatch while one popup is open and switch instantly. It calls `OpenPopup(ColorEditPopup.PopupId)` and `SetNextWindowPos(ItemRectMax + (4, 10))`.

`DrawPopup` uses `BeginPopup` (`ColorEditPopup.cs:41`). Click-outside and Escape closing come from ImGui's defaults. Open and close are detected via `_openedId` (`:43-77`). Holding Alt adds `ImGuiWindowFlags.Modal` (`:34`) so the popup survives the eyedropper picking a color from elsewhere on screen.

### (b) A Modal Popup: CurveEditPopup

Same shape, stricter: `OpenPopup` (`Editor/Gui/Interaction/CurveEditPopup.cs:35`), then `BeginPopupModal(id, ref isOpen)` (`:59`), with `SetNextWindowSize(..., Once)` (`:54`) so the user's resize sticks.

### (c) A Custom Child Overlay: ParameterPopUp

`Editor/Gui/Graph/ParameterPopUp.cs` is not an ImGui popup at all. State is `_isOpen` plus `_selectedInstance` (open at `:46-55`). It draws `BeginChild("Popup")` (`:93`), positioned at the node (`:85-87`). Because ImGui is not managing it, the code has to do the closing itself:

- Escape (`:100-103`)
- selection lost (`:77-81`)
- the node no longer exists (`:71-75`)
- focus lost (`:116-119`)

The focus-lost check has a trap. A freshly opened child does not have focus yet, so the check would close it instantly. The fix is to force focus for three frames via `_focusDelayCount` (`:111-115`). `NoNavInputs` (`:89`) stops Tab from entering unfocused inputs. We found no clamping to window bounds (limited scope, so a popup near the edge can presumably clip; inferred).

The trade: a child overlay stays inside its parent window's z-order and ID scope and does not steal the whole screen's input, but you rebuild click-outside, Escape and focus rules by hand.

### Telling Everyone Else About an Overlay

Two frame flags carry the news (see chapter 02 for the mechanism). `OpenedPopupHovered` is set by ModalDialog (`:73`) and ParameterPopUp (`:121`), and `ScalableCanvas.cs:249` treats the canvas as not interactable. `OpenedPopupCapturedMouse` is set by custom mouse-capturing widgets: `ColorEditButton.cs:109`, `InfinitySliderOverlay.cs:66`, `GradientEditor.cs:274` and `PlaybackTimeScrubHandling.cs:58`. It is read as `FrameStats.Last` (`ScalableCanvas.cs:259`, `MagGraphCanvas.Drawing.cs:60`). The one-frame-delayed read is the design, not an accident.

---

## How Does a Drag Travel Between Windows That Draw in Any Order?

This is the section where tixl does its cleverest work. `Editor/Gui/UiHelpers/DragAndDropHandling.cs` is a static facade over ImGui's native drag & drop. Native DnD alone has two limits: the payload is a raw byte blob copied by ImGui, and the *target* only learns about it if it is drawn after the source starts the drag. Different windows draw in different orders, and some consumers are not ImGui widgets at all.

The facade removes the payload from ImGui's hands. `DragTypes` (`:276`) is an enum: Symbol, FileAsset, ExternalFile, SymbolNameSpace, SetupEntity.

### How Does a Drag Start?

`HandleDragSourceForLastItem(type, string data)` (`:65`) calls `BeginDragDropSource(SourceNoPreviewTooltip)`, marshals the data as a UTF-16 string into an HGlobal (`:75`), and calls `SetDragDropPayload(type.ToString(), ptr, bytes)` (`:79`). The payload type name is the enum name. IDs travel as strings: a Guid string or an asset address.

### How Does a Target Know It Got the Drop?

`TryHandleDropOnItem(type, out data, drawTooltip?)` (`:104`) returns one of None, Invalid, Hovering or Dropped. It draws an orange outline (`:124-127`). It accepts through `BeginDragDropTarget`/`AcceptDragDropPayload` (`:144-154`) but detects the drop with `IsMouseReleased(0)` (`:156-157`), then reads the string with `Marshal.PtrToStringAuto(payload.Data)` (`:165`), falling back to the stored `_dataString`. `TryHandleDropOnRect` (`:193`) drops onto an arbitrary rectangle without a payload round-trip.

### Where Does the Real Data Live?

Back to the lobby analogy: the real data is *also* kept in static `_dataString` and `_activeDragType`, with `TryGetDragData` for peeking (`:262`). The ImGui payload is the claim ticket; the static copy is the sign-in sheet. Non-ImGui consumers read the sheet directly: `Editor/Gui/MagGraph/Ui/DropHandling.cs:29-44` (`DrawDragIndicator`). And external OS drops never go through ImGui payloads at all, so the sheet is the only way they can participate.

### When Is the Data Freed?

`StopDragging` does not free anything. It sets `_stopRequested` (`:235`). `Update()` (`:17-26`, called from `T3Ui.Update.cs:37`) frees the HGlobal at the start of the next frame. The comment at `:231-234` says: "To prevent inconsistencies related to the order of window processing, we have to defer the end until beginning of" the next frame. A window processed later in the same frame can still see the drag as live.

An external drop that nobody claims within one frame is discarded (`:28-36`), so a stale drop cannot land on a later drop zone.

### How Does the Graph Window Consume a Drop?

`Editor/Gui/MagGraph/Ui/DropHandling.cs` shows the pattern in use. `HandleDropOnWindow` (`:46`) lays an `InvisibleButton("## drop")` over the whole window (`:51-52`) so the window itself is one drop target. It tries `TryHandleDropOnItem` for Symbol, ExternalFile and FileAsset (`:54-60`). It creates operators at the mouse (`TryCreateSymbolInstanceOnGraph`, `:232`), imports files (`:154`), and previews the result on the foreground draw list (`:186`).

### Trace: Dropping a Symbol From the Library onto the Graph

1. In the library window, a row calls `HandleDragSourceForLastItem(Symbol, guidString)`. The payload type is `"Symbol"`; the string is stored in `_dataString`.
2. The graph window, drawn at some point, has its `## drop` button. `TryHandleDropOnItem` returns `Hovering`, and an indicator draws on the foreground list.
3. The user releases. `IsMouseReleased(0)` fires, the function returns `Dropped` and the data string.
4. `TryCreateSymbolInstanceOnGraph` places the operator at the mouse.
5. `StopDragging` sets `_stopRequested`. Next frame, `Update()` frees the HGlobal.

### How Do Files Dragged In From the Desktop Arrive?

`Editor/App/ImGuiDx11RenderForm.cs` (WinForms) translates OS events into the same facade. `OnDragEnter` calls `StartExternalDrag(ExternalFile, "External Files")` (`:95`); `OnDragLeave` cancels (`:101`); `OnDragOver` writes the mouse position into `io.MousePos` (`:142`); `OnDragDrop` joins the paths with `|` and calls `CompleteExternalDrop` (`:124-126`). A single dropped folder opens `FolderImportDialog` (`:117-121`). This code is Windows-specific.

---

## When Should a Tooltip Appear, and What Does Hover Help Do?

`Editor/Gui/Styling/CustomComponents.Tooltips.cs` solves two annoyances: tooltips that appear instantly on a casual mouse sweep, and tooltips that make you wait again on every neighbouring button.

`BeginFrame` (`:11-25`) sets a global hover delay of 0.6 s, and resets it only after 0.2 s with no tooltip hovered. Moving between neighbours therefore shows the next tooltip immediately. The `TooltipForLastItem` overloads (`:27, 67, 89`) test `IsItemHovered(AllowWhenDisabled)` (`:69-70`), so disabled items can explain *why* they are disabled, and set `FrameStats.Current.SomethingWithTooltipHovered`. `BeginTooltip(wrapPos = 300)` scales the wrap width with `UiScaleFactor` (`:52-59`). The Action overload does not wrap (`:80-86`).

### Help That Follows the Hover

`Editor/Gui/Help/HoveredHelpTarget.cs` is a per-frame broker between *things that can be explained* and a help window that shows the explanation. Producers call `SetOperator(Guid)` or `SetTopic(string)`, which record the topic *and the frame number* (`:19-30`). The consumer's `TryGetHovered` accepts the same frame or the previous one (`:35`), so draw order between producer and consumer does not matter (`:11-14`).

Producers: `MagGraphCanvas.DrawNode.cs:200`, `PlaceHolderUi.cs:475`, `MarkdownOperatorLinks.cs:65,123` and `DocumentationButton.cs:39`. The consumer is `HelpWindow.cs:222`, gated on `UserSettings.Config.HelpHoverPreview`. While preview is active, the doc-button tooltip is suppressed (`DocumentationButton.cs:36-41`) so the same text does not show twice.

A `[HelpUiID("X")]` class attribute (`Editor/Gui/HelpUiIDAttribute.cs:12-18`) maps to the `ui:X` topic and sits on about 30 classes (for example `ParameterPopUp.cs:20`).

---

## Gotchas: What Bites When You Build This

> **verified** means confirmed in the traced source. **Inferred** means concluded from reading code, not observed running. **Unverified** means we did not trace it.

1. **`ImGuiWindowFlags.Popup` crashes the native call (verified in a code comment, `ModalDialog.cs:66`).** Use the Begin* popup functions instead of passing the flag.
2. **Zero WindowPadding in the global style (verified, `ModalDialog.cs:95-97`).** A plain `BeginPopupModal` renders flush against its content, which is why `BeginDialog` pushes a padding var and `EndDialog()` must always pop it. Skipping `EndDialog()` leaks a style var.
3. **Auto-resize feedback loop.** A bottom-anchored child inside an `AlwaysAutoResize` dialog grows the window every frame (`ModalDialog.cs:56-59`).
4. **Empty popup ids are rejected by ImGui 1.90** (`ExitDialog.cs:21`).
5. **Int ids collapse after hot reload** (`CustomComponents.Menus.cs:148-149`). Seed from the label or use enum ids.
6. **Unscoped menu globals.** `MenuItemsDisabled` and `MenuItemsFlushLeft` leak into later menus if not reset (inferred from being static, `:92,100`).
7. **Focus-lost check fires instantly on a new child overlay.** Hence the three-frame focus force (`ParameterPopUp.cs:111-115`).
8. **No bounds clamping on ParameterPopUp** (we found none; limited scope).
9. **Drop is detected by mouse release, not by the accept result** (`DragAndDropHandling.cs:156-157`). We did not trace why; presumably the accept result is not reliable at the release frame (unverified).
10. **`[HelpUiID]` has no reader we could find.** No reflection use in `.cs` files; it appears to be a static tag next to hand-wired `SetTopic` calls (unverified).
11. **Windows-only OS drops.** The WinForms path in `ImGuiDx11RenderForm.cs` does not exist on other platforms.
12. **Frame lag.** Canvases read `FrameStats.Last`, so a popup and the canvas disagree for one frame at open and at close.

---

## How Would This Look in Rust with dear-imgui-rs?

> The following are **recommendations**, not tixl behaviour. API names are sketches; check them against the dear-imgui-rs version you use.

### Step 1: A Dialog That Returns a Value

tixl's `ModalDialog` has the right lifecycle (owner draws every frame, trigger sets a flag, `OpenPopup` inside the dialog's own draw) and the wrong output channel. Rust gives you a better one: return an enum instead of mutating through `ref` parameters. Here is a sketch:

```rust
pub enum DialogResult<T> { Pending, Confirmed(T), Cancelled }

pub struct RenameDialog { open_requested: bool, buffer: String }

impl RenameDialog {
    pub fn show(&mut self, current: &str) {     // trigger: just sets a flag
        self.open_requested = true;
        self.buffer = current.to_owned();
    }

    pub fn draw(&mut self, ui: &Ui) -> DialogResult<String> {
        if std::mem::take(&mut self.open_requested) {
            ui.open_popup("Rename###rename");   // same ID stack as begin_modal below
        }
        // begin modal; draw input and buttons; return Confirmed(buffer.clone()) on OK
        DialogResult::Pending
    }
}
```

The owner matches on the result and applies it, so the dialog never needs a handle to application state. A closed dialog costs one bool check per frame.

### Step 2: Frame State With current and last

Replace `FrameStats.Current/Last` with an explicit struct that you swap at frame end, as in chapter 02. Here is the shape:

```rust
#[derive(Default)]
struct FrameUiState {
    opened_popup: Option<String>,
    modal_open: bool,
    popup_hovered: bool,
    popup_captured_mouse: bool,
}
struct UiFrames { current: FrameUiState, last: FrameUiState }
```

Popups and overlays write `current`; canvas and shortcut code read `last`. `any_popup_open` is derived from `opened_popup.is_some()`, the way `T3Ui.IsAnyPopupOpen` derives from `OpenedPopUpName`.

### Step 3: One Context-Menu Helper, Closures Allowed

tixl's "static method group, not lambda" rule exists to avoid a closure allocation per frame in C#. In Rust, an `impl FnOnce(&Ui)` argument is monomorphized and does not heap-allocate, so the rule is unnecessary. Keep the *other* half of the rule, one helper for everything. The signature might look like this:

```rust
pub fn context_menu(ui: &Ui, id: &str, title: Option<&str>, body: impl FnOnce(&Ui)) {
    // 1. bail if the right button dragged past the click threshold
    // 2. push the menu style (isolate from caller padding)
    // 3. begin_popup_context_item(id), record is_item_context_menu_open in state.current
    // 4. draw the small title, call body(ui)
}
```

Enforce it by API: do not re-export raw `begin_popup_context_item` to feature code (for example, keep it in a private module). tixl's rule was only prose and has five known exceptions. Use enum or `const` ids for rows, and give row ids a label seed, so ids survive reloads. For canvas background menus, store the mouse position at open time in the editor state and hit-test against it.

### Step 4: Drag Payloads Held by the Editor, Not by ImGui

Keep the real data in editor-owned state and let ImGui carry only a tag, if you use ImGui's DnD at all. A typed enum can hold the payload:

```rust
pub enum DragPayload {
    Symbol(Uuid),
    Asset(String),
    ExternalFiles(Vec<PathBuf>),
}
// app state: active_drag: Option<DragPayload>, stop_requested: bool, external_age: u32
```

A typed enum removes the string marshaling and the HGlobal lifetime entirely, and ownership gives you the cleanup for free. Keep tixl's lifecycle, though: setting `stop_requested` at drop time and clearing `active_drag` at the *start* of the next frame, so windows drawn later in the frame still see the drag. Expire an unclaimed external drop after one frame.

For OS drops, winit provides `WindowEvent::HoveredFile`, `DroppedFile` and `HoveredFileCancelled`. They arrive one event per file and carry no position, so use the last known cursor position as the drop location and collect the per-file events of a frame into one `ExternalFiles` payload.

### Step 5: Tooltips and Help

- Tooltip delay with a grace period: a global hover timer, reset only after a short span without any tooltip hovered (tixl: 0.6 s and 0.2 s).
- Use an `AllowWhenDisabled`-style hover check so disabled controls can explain themselves.
- Scale the wrap width by the DPI scale.
- Help broker: a small struct with `(topic, frame_number)`, accepting the current or previous frame. Call it explicitly, `help_target(ui, "id")`, rather than tixl's decorative attribute that nothing appears to read.

---

## What to Remember

- Dialogs are drawn every frame and opened by a flag consumed inside their own draw, so the popup id lives in one ID stack.
- One wrapper owns context menus. tixl follows it only partly, and breaks its own closure rule at two sites.
- Three kinds of non-modal popup trade ImGui's built-in behaviour against control. The custom child must reimplement closing and focus.
- Drag & drop keeps the real data in a static beside ImGui's claim ticket, frees it a frame late, and expires stale OS drops.
- Tooltips use a grace-period delay; help is a per-frame broker tolerant of draw order.

## Next Steps

For how popup flags gate canvas input, return to [chapter 02](02-input-routing-and-focus.md). For popup ids and the ID stack, see [chapter 05](05-id-stack-and-widget-identity.md); for the menu row styling, [chapter 06](06-theming-and-widget-library.md). For the operator browser itself, see the [MagGraph interaction browser](../maggraph/11-interaction-browser.md) and the [symbol browser](../graph/01-symbol-browser.md).
